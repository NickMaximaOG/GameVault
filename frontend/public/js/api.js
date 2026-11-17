// Talks to the Node server's /api proxy. The login token lives in an HttpOnly cookie, never in JS.
export class ApiError extends Error {
  constructor(status, code, message, requestId) {
    super(message);
    this.status = status;
    this.code = code;
    this.requestId = requestId;
  }
}

export const session = { user: null, onExpired: () => {} };

export async function api(method, path, body) {
  let res;
  try {
    res = await fetch('/api/v1' + path, {
      method,
      credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json', 'X-Requested-With': 'gamevault' },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  } catch {
    throw new ApiError(0, 'network', 'Cannot reach the server. Check your connection and try again.');
  }
  if (res.status === 204) return null;
  let data = null;
  try { data = await res.json(); } catch { /* empty or non-JSON body */ }
  if (!res.ok) {
    const e = data?.error ?? {};
    if (res.status === 401 && session.user && path !== '/auth/login') session.onExpired();
    throw new ApiError(res.status, e.code ?? 'error', e.message ?? `Request failed (${res.status})`, e.requestId);
  }
  return data;
}

export const qs = (obj) => {
  const p = new URLSearchParams();
  for (const [k, v] of Object.entries(obj)) if (v !== '' && v !== null && v !== undefined) p.set(k, v);
  const s = p.toString();
  return s ? '?' + s : '';
};
