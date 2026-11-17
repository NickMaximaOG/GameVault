// GameVault web server (Node.js).
//
// What it does
//  * serves the single-page app from ./public
//  * is the ONLY thing the browser talks to: /api/* is forwarded to the Java backend
//  * keeps the login token in an HttpOnly cookie (backend-for-frontend pattern), so JavaScript
//    in the page can never read it, and adds it as a Bearer header when forwarding
//  * blocks cross-site writes (SameSite=Strict cookie + required X-Requested-With header
//    + Origin check) and sets strict security headers, including a CSP with no inline script
//
// Settings (environment): PORT=3000  BACKEND_URL=http://localhost:8080
//                         COOKIE_SECURE=true (set when served over HTTPS)  TRUST_PROXY=false
import express from 'express';
import helmet from 'helmet';
import path from 'node:path';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const COOKIE = 'gv_session';
const here = path.dirname(fileURLToPath(import.meta.url));

export function parseCookies(header = '') {
  const out = {};
  for (const part of header.split(';')) {
    const i = part.indexOf('=');
    if (i > 0) out[part.slice(0, i).trim()] = decodeURIComponent(part.slice(i + 1).trim());
  }
  return out;
}

export function createApp({ backendUrl, cookieSecure = false, trustProxy = false } = {}) {
  const app = express();
  app.disable('x-powered-by');
  app.set('trust proxy', trustProxy);

  app.use(
    helmet({
      contentSecurityPolicy: {
        useDefaults: false,
        directives: {
          defaultSrc: ["'self'"],
          scriptSrc: ["'self'"],
          styleSrc: ["'self'", 'https://fonts.googleapis.com'],
          fontSrc: ["'self'", 'https://fonts.gstatic.com', 'data:'],
          imgSrc: ["'self'", 'data:', 'https:'],
          connectSrc: ["'self'"],
          objectSrc: ["'none'"],
          baseUri: ["'self'"],
          formAction: ["'self'"],
          frameAncestors: ["'none'"],
        },
      },
      referrerPolicy: { policy: 'no-referrer' },
      crossOriginEmbedderPolicy: false,
    }),
  );

  app.get('/healthz', (_req, res) => res.json({ status: 'UP' }));

  const setSession = (res, token, seconds) =>
    res.append(
      'Set-Cookie',
      `${COOKIE}=${encodeURIComponent(token)}; HttpOnly; SameSite=Strict; Path=/; Max-Age=${seconds}${cookieSecure ? '; Secure' : ''}`,
    );
  const clearSession = (res) =>
    res.append('Set-Cookie', `${COOKIE}=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0${cookieSecure ? '; Secure' : ''}`);
  const fail = (res, status, code, message) => res.status(status).json({ error: { code, message } });

  // ---- API proxy -------------------------------------------------------------------------------
  app.use('/api/', express.raw({ type: () => true, limit: '1mb' }));
  app.all('/api/*', async (req, res) => {
    const unsafe = !['GET', 'HEAD', 'OPTIONS'].includes(req.method);
    if (unsafe) {
      if (req.get('x-requested-with') !== 'gamevault') return fail(res, 403, 'csrf', 'Missing request header');
      const origin = req.get('origin');
      if (origin && new URL(origin).host !== req.get('host')) return fail(res, 403, 'csrf', 'Cross-site request blocked');
    }

    const token = parseCookies(req.headers.cookie)[COOKIE];
    const headers = { accept: 'application/json', 'x-forwarded-for': req.ip };
    if (req.get('content-type')) headers['content-type'] = req.get('content-type');
    if (req.get('user-agent')) headers['user-agent'] = req.get('user-agent');
    if (token) headers.authorization = `Bearer ${token}`;
    const hasBody = Buffer.isBuffer(req.body) && req.body.length > 0;

    let upstream, buf;
    try {
      upstream = await fetch(new URL(req.originalUrl, backendUrl), {
        method: req.method,
        headers,
        body: hasBody ? req.body : undefined,
        redirect: 'manual',
        signal: AbortSignal.timeout(15_000),
      });
      buf = Buffer.from(await upstream.arrayBuffer());
    } catch {
      return fail(res, 502, 'backend_unreachable', 'The game service is not responding. Try again in a moment.');
    }

    for (const h of ['content-type', 'x-request-id', 'retry-after']) {
      const v = upstream.headers.get(h);
      if (v) res.set(h, v);
    }
    const route = `${req.method} ${req.path}`;

    if (route === 'POST /api/v1/auth/login' && upstream.status === 200) {
      const data = JSON.parse(buf.toString('utf8'));
      setSession(res, data.token, data.expiresInSeconds);
      return res.status(200).json({ user: data.user, expiresInSeconds: data.expiresInSeconds });   // token never reaches the page
    }
    if (route === 'POST /api/v1/auth/logout' || (upstream.status === 401 && token)) clearSession(res);

    res.status(upstream.status);
    return upstream.status === 204 ? res.end() : res.send(buf);
  });

  // ---- static app -------------------------------------------------------------------------------
  const webRoot = existsSync(path.join(here, 'dist')) ? path.join(here, 'dist') : path.join(here, 'public');
  app.use(express.static(webRoot, { maxAge: '5m', index: 'index.html' }));
  // Keep old public assets available for backwards-compatible test/docs links.
  if (webRoot !== path.join(here, 'public')) app.use(express.static(path.join(here, 'public'), { maxAge: '5m' }));
  app.use((_req, res) => fail(res, 404, 'not_found', 'Page not found'));
  return app;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const port = Number(process.env.PORT ?? 3000);
  const app = createApp({
    backendUrl: process.env.BACKEND_URL ?? 'http://localhost:8080',
    cookieSecure: process.env.COOKIE_SECURE === 'true',
    trustProxy: process.env.TRUST_PROXY === 'true',
  });
  const server = app.listen(port, () => console.log(JSON.stringify({ level: 'INFO', detail: `GameVault web on http://localhost:${port}` })));
  for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, () => server.close(() => process.exit(0)));
}
