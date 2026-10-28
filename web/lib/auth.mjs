// web/lib/auth.mjs: the security rules from docs/web-dashboard-plan.md section 2 that apply to every request, so
// routes never repeat them. server.mjs calls checkPeer and checkLogin on every request and WebSocket upgrade,
// checkPost on every request that is not GET or HEAD, and checkOrigin on every upgrade. Each returns null when the
// request may go on, or an HttpError to answer with.
//
// The trust model: tailscale serve terminates TLS on the tailnet, proxies to 127.0.0.1 and sets
// Tailscale-User-Login to the caller's login. Anything else reaching the port is either not loopback (refused) or
// a local process, which can forge the header; that residual risk is documented in the plan, not mitigated.

export class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

// Every response carries these, errors included: the page loads nothing from elsewhere and is never framed.
export const SECURITY_HEADERS = {
  'Content-Security-Policy': "default-src 'self'; connect-src 'self'; img-src 'self' data:",
  'X-Frame-Options': 'DENY',
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'no-referrer',
};

export const LOGIN_HEADER = 'tailscale-user-login';
export const JSON_LIMIT = 1024 * 1024;
export const UPLOAD_LIMIT = 20 * 1024 * 1024;

// "a@x, b@y" -> Set. Empty entries are dropped, so a stray comma cannot allow the empty login.
export function parseAllow(value) {
  return new Set(String(value ?? '').split(',').map((s) => s.trim()).filter(Boolean));
}

export function isLoopback(address) {
  if (!address) return false;
  const a = address.startsWith('::ffff:') ? address.slice(7) : address;
  return a === '::1' || /^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(a);
}

// Rule 1. The server only listens on 127.0.0.1, so this is a second fence in case that ever changes.
export function checkPeer(req) {
  return isLoopback(req.socket.remoteAddress) ? null : new HttpError(403, 'not loopback');
}

// Rule 2. A repeated header arrives joined with ", " and so never matches a single allowed login.
export function loginOf(req) {
  const v = req.headers[LOGIN_HEADER];
  return typeof v === 'string' ? v.trim() : '';
}

export function checkLogin(req, allow) {
  const login = loginOf(req);
  return login && allow.has(login) ? null : new HttpError(403, 'forbidden');
}

// Rule 3. X-Agent-Web is not a CORS-safelisted header, so a cross-site page cannot send it without a preflight,
// which this server never answers. JSON is required too, except on routes that take a raw upload body (opts.raw),
// where any declared type will do and the route decides what it accepts.
export function checkPost(req, opts = {}) {
  if (req.method !== 'POST') return new HttpError(403, 'POST only');
  if (req.headers['x-agent-web'] !== '1') return new HttpError(403, 'missing X-Agent-Web');
  const type = String(req.headers['content-type'] ?? '').split(';')[0].trim().toLowerCase();
  if (opts.raw ? !type : type !== 'application/json') return new HttpError(403, 'bad content type');
  return null;
}

// Rule 4. Browsers always send Origin on a WebSocket handshake; a page on another site sends its own.
export function checkOrigin(req) {
  const origin = req.headers.origin;
  const host = req.headers.host;
  if (!origin || !host) return new HttpError(403, 'bad origin');
  try {
    return new URL(origin).host === host ? null : new HttpError(403, 'bad origin');
  } catch {
    return new HttpError(403, 'bad origin');
  }
}

// Rule 7: bodies are read into memory up to a cap, never logged. Content-Length is checked first so an oversized
// upload is refused before it is read; a body without one is counted as it arrives.
export function readBody(req, limit = UPLOAD_LIMIT) {
  return new Promise((resolve, reject) => {
    const declared = Number(req.headers['content-length']);
    if (declared > limit) {
      req.resume();
      reject(new HttpError(413, 'body too large'));
      return;
    }
    const chunks = [];
    let size = 0;
    let failed = false;
    req.on('data', (c) => {
      if (failed) return;
      size += c.length;
      if (size > limit) {
        failed = true;
        reject(new HttpError(413, 'body too large'));
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => failed || resolve(Buffer.concat(chunks)));
    req.on('error', (e) => failed || reject(e));
  });
}

// The JSON body of a POST as an object; an empty body is {}, anything that is not an object is a 400.
export async function readJson(req, limit = JSON_LIMIT) {
  const buf = await readBody(req, limit);
  if (buf.length === 0) return {};
  let v;
  try {
    v = JSON.parse(buf.toString('utf8'));
  } catch {
    throw new HttpError(400, 'invalid JSON');
  }
  if (v === null || typeof v !== 'object' || Array.isArray(v)) throw new HttpError(400, 'expected a JSON object');
  return v;
}
