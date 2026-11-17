import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { createApp, parseCookies } from '../server.js';

let fake, web, seen, fakeUrl, webUrl;
const listen = (srv) => new Promise((r) => srv.listen(0, '127.0.0.1', () => r(`http://127.0.0.1:${srv.address().port}`)));

before(async () => {
  seen = [];
  fake = http.createServer((req, res) => {
    let body = '';
    req.on('data', (c) => (body += c));
    req.on('end', () => {
      seen.push({ method: req.method, url: req.url, auth: req.headers.authorization, body });
      res.setHeader('content-type', 'application/json');
      if (req.url === '/api/v1/auth/login') return res.end(JSON.stringify({ token: 'tok123', expiresInSeconds: 3600, user: { username: 'u' } }));
      if (req.url === '/api/v1/auth/logout') { res.statusCode = 204; return res.end(); }
      if (req.url === '/api/v1/expired') { res.statusCode = 401; return res.end('{"error":{"code":"unauthorized","message":"x"}}'); }
      res.end('{"ok":true}');
    });
  });
  fakeUrl = await listen(fake);
  web = http.createServer(createApp({ backendUrl: fakeUrl }));
  webUrl = await listen(web);
});
after(() => { fake.close(); web.close(); });

const call = (path, opts = {}) => fetch(webUrl + path, { redirect: 'manual', ...opts, headers: { 'x-requested-with': 'gamevault', 'content-type': 'application/json', ...(opts.headers ?? {}) } });

test('parseCookies handles encoded values and spaces', () => {
  assert.deepEqual(parseCookies('a=1; gv_session=ab%20c'), { a: '1', gv_session: 'ab c' });
  assert.deepEqual(parseCookies(undefined), {});
});

test('login moves the token into an HttpOnly SameSite=Strict cookie and hides it from the body', async () => {
  const r = await call('/api/v1/auth/login', { method: 'POST', body: '{"username":"u","password":"p"}' });
  assert.equal(r.status, 200);
  const cookie = r.headers.get('set-cookie');
  assert.match(cookie, /gv_session=tok123/);
  assert.match(cookie, /HttpOnly/);
  assert.match(cookie, /SameSite=Strict/);
  const body = await r.json();
  assert.equal(body.token, undefined);
  assert.equal(body.user.username, 'u');
});

test('cookie is forwarded to the backend as a Bearer token', async () => {
  seen.length = 0;
  await call('/api/v1/auth/me', { headers: { cookie: 'gv_session=tok123' } });
  assert.equal(seen.at(-1).auth, 'Bearer tok123');
});

test('no cookie means no Authorization header', async () => {
  seen.length = 0;
  await call('/api/v1/catalog/games');
  assert.equal(seen.at(-1).auth, undefined);
});

test('writes without the X-Requested-With header are refused (CSRF)', async () => {
  const r = await fetch(webUrl + '/api/v1/me/collection', { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}' });
  assert.equal(r.status, 403);
});

test('writes from another origin are refused', async () => {
  const r = await call('/api/v1/me/collection', { method: 'POST', body: '{}', headers: { origin: 'https://evil.example' } });
  assert.equal(r.status, 403);
});

test('same-origin writes pass through with their body', async () => {
  seen.length = 0;
  const r = await call('/api/v1/me/ratings/1', { method: 'PUT', body: '{"rating":8}', headers: { origin: webUrl } });
  assert.equal(r.status, 200);
  assert.equal(seen.at(-1).body, '{"rating":8}');
});

test('logout and an upstream 401 clear the cookie', async () => {
  const out = await call('/api/v1/auth/logout', { method: 'POST', headers: { cookie: 'gv_session=tok123' } });
  assert.equal(out.status, 204);
  assert.match(out.headers.get('set-cookie'), /gv_session=; .*Max-Age=0/);
  const exp = await call('/api/v1/expired', { headers: { cookie: 'gv_session=tok123' } });
  assert.equal(exp.status, 401);
  assert.match(exp.headers.get('set-cookie'), /Max-Age=0/);
});

test('backend down gives a clear 502', async () => {
  const dead = http.createServer(createApp({ backendUrl: 'http://127.0.0.1:1' }));
  const url = await listen(dead);
  const r = await fetch(url + '/api/v1/health');
  assert.equal(r.status, 502);
  assert.equal((await r.json()).error.code, 'backend_unreachable');
  dead.close();
});

test('security headers: strict CSP with no inline script or style, no framing', async () => {
  const r = await fetch(webUrl + '/');
  const csp = r.headers.get('content-security-policy');
  assert.match(csp, /script-src 'self'/);
  assert.match(csp, /style-src 'self'/);
  assert.doesNotMatch(csp, /unsafe-inline/);
  assert.match(csp, /frame-ancestors 'none'/);
  assert.equal(r.headers.get('x-powered-by'), null);
});

test('static app is served and unknown paths 404 as JSON', async () => {
  assert.equal((await fetch(webUrl + '/')).status, 200);
  assert.equal((await fetch(webUrl + '/js/app.js')).status, 200);
  const nf = await fetch(webUrl + '/nope');
  assert.equal(nf.status, 404);
  assert.equal((await nf.json()).error.code, 'not_found');
});

test('shipped pages contain no inline scripts, styles or handlers (CSP-safe)', async () => {
  const html = await (await fetch(webUrl + '/')).text();
  assert.doesNotMatch(html, /<script(?![^>]*\bsrc=)/);
  assert.doesNotMatch(html, /\sstyle=|\sonclick=/);
});
