// web/lib/push.mjs: Web Push for the needs-input alerts (docs/web-dashboard-plan.md T10), with the pinned
// web-push package. State lives in $AGENT_WEB_STATE (dir 700, files 600, written whole through a rename):
//   vapid.json          {publicKey, privateKey, subject?}, made on first start. subject is the Origin of the first
//                       subscription that came over https (tailscale serve's https://<host>.<tailnet>.ts.net).
//   subscriptions.json  [{endpoint, keys:{p256dh, auth}}], one per endpoint
// Push services want a VAPID subject that is an https: URL or a mailto: address. Until an https Origin has been
// seen (the tests run on plain http), FALLBACK_SUBJECT stands in: a mailto: on the reserved .invalid domain, so it
// can never be a real mailbox.
//
// An endpoint must be https, except plain http on a loopback host, which only the tests' local sink uses: web-push
// always speaks TLS, so such an endpoint is sent through LoopbackAgent, which hands it a plain TCP socket. A real
// push service is never on loopback, and only an allowed login can subscribe.
//
//   pushFor(config)   the Push for one server (cached per config): keys(), subject(), list(), subscribe(sub,
//                     origin), unsubscribe(endpoint), sendAll(payload) -> {sent, removed, failed}. A 404 or 410
//                     from the push service removes that subscription.
//   createPush(dir, {send})   the same for a directory; send defaults to web-push's sendNotification (tests wrap it)
//   route handlers: getPushKey, pushSubscribe, pushUnsubscribe, pushTest

import { chmodSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import https from 'node:https';
import net from 'node:net';
import path from 'node:path';
import { createRequire } from 'node:module';
import { HttpError, readJson } from './auth.mjs';

const webpush = createRequire(import.meta.url)('web-push');

export const FALLBACK_SUBJECT = 'mailto:agent-web@example.invalid';
export const TTL = 3600;
const LOOPBACK = new Set(['127.0.0.1', 'localhost', '[::1]']);
const MAX_SUBS = 50;

class LoopbackAgent extends https.Agent {
  // The agent uses a returned socket as is; no TLS is layered on it.
  createConnection(opts) {
    return net.connect({ host: opts.host, port: opts.port });
  }
}
const loopbackAgent = new LoopbackAgent();

function endpointUrl(endpoint) {
  let u;
  try {
    u = new URL(endpoint);
  } catch {
    return null;
  }
  if (u.protocol === 'https:') return u;
  if (u.protocol === 'http:' && LOOPBACK.has(u.hostname)) return u;
  return null;
}

const B64URL = /^[A-Za-z0-9_-]+={0,2}$/;

// Only what the push needs is kept: a browser's toJSON() also has expirationTime, which is not used.
export function cleanSubscription(sub) {
  const endpoint = sub?.endpoint;
  const p256dh = sub?.keys?.p256dh;
  const auth = sub?.keys?.auth;
  if (typeof endpoint !== 'string' || endpoint.length > 2048 || !endpointUrl(endpoint)) {
    throw new HttpError(400, 'subscription endpoint must be an https URL');
  }
  for (const [k, v] of [['p256dh', p256dh], ['auth', auth]]) {
    if (typeof v !== 'string' || v.length > 200 || !B64URL.test(v)) throw new HttpError(400, `subscription keys.${k} is missing`);
  }
  return { endpoint, keys: { p256dh, auth } };
}

export function createPush(dir, { send = (...a) => webpush.sendNotification(...a) } = {}) {
  const vapidFile = path.join(dir, 'vapid.json');
  const subsFile = path.join(dir, 'subscriptions.json');

  function ensureDir() {
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    chmodSync(dir, 0o700);
  }

  function read(file, fallback) {
    try {
      return JSON.parse(readFileSync(file, 'utf8'));
    } catch (err) {
      if (err.code === 'ENOENT') return fallback;
      throw new Error(`${file} is not readable JSON: ${err.message}`);
    }
  }

  function write(file, value) {
    ensureDir();
    const tmp = `${file}.${process.pid}.tmp`;
    writeFileSync(tmp, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
    chmodSync(tmp, 0o600);
    renameSync(tmp, file);
  }

  function keys() {
    const v = read(vapidFile, null);
    if (v?.publicKey && v?.privateKey) return v;
    const fresh = webpush.generateVAPIDKeys();
    write(vapidFile, fresh);
    return fresh;
  }

  function subject() {
    return keys().subject || FALLBACK_SUBJECT;
  }

  function list() {
    const subs = read(subsFile, []);
    return Array.isArray(subs) ? subs : [];
  }

  function subscribe(sub, origin) {
    const clean = cleanSubscription(sub);
    const v = keys();
    if (!v.subject && typeof origin === 'string' && /^https:\/\/[^/\s]+$/.test(origin)) {
      write(vapidFile, { ...v, subject: origin });
    }
    const subs = list().filter((s) => s.endpoint !== clean.endpoint);
    subs.push(clean);
    write(subsFile, subs.slice(-MAX_SUBS));
    return subs.length;
  }

  function unsubscribe(endpoint) {
    const subs = list();
    const left = subs.filter((s) => s.endpoint !== endpoint);
    if (left.length !== subs.length) write(subsFile, left);
    return subs.length - left.length;
  }

  async function sendAll(payload) {
    const subs = list();
    if (!subs.length) return { sent: 0, removed: 0, failed: 0 };
    const v = keys();
    const body = JSON.stringify(payload);
    const gone = new Set();
    let sent = 0;
    let failed = 0;
    await Promise.all(subs.map(async (sub) => {
      const opts = {
        TTL,
        timeout: 10000,
        vapidDetails: { subject: v.subject || FALLBACK_SUBJECT, publicKey: v.publicKey, privateKey: v.privateKey },
      };
      if (endpointUrl(sub.endpoint)?.protocol === 'http:') opts.agent = loopbackAgent;
      try {
        await send(sub, body, opts);
        sent += 1;
      } catch (err) {
        if (err.statusCode === 404 || err.statusCode === 410) {
          gone.add(sub.endpoint);
        } else {
          failed += 1;
          console.error(`agent-web: push to ${new URL(sub.endpoint).host} failed: ${err.statusCode ?? err.message}`);
        }
      }
    }));
    // Read again: a subscribe may have landed while the sends were out.
    if (gone.size) write(subsFile, list().filter((s) => !gone.has(s.endpoint)));
    return { sent, removed: gone.size, failed };
  }

  return { keys, subject, list, subscribe, unsubscribe, sendAll };
}

const pushes = new WeakMap();
export function pushFor(config) {
  let p = pushes.get(config);
  if (!p) {
    p = createPush(config.state);
    pushes.set(config, p);
  }
  return p;
}

export function getPushKey(req, res, ctx) {
  return { publicKey: pushFor(ctx.config).keys().publicKey };
}

export async function pushSubscribe(req, res, ctx) {
  const body = await readJson(req);
  const count = pushFor(ctx.config).subscribe(body, req.headers.origin);
  return { ok: true, count };
}

export async function pushUnsubscribe(req, res, ctx) {
  const { endpoint } = await readJson(req);
  if (typeof endpoint !== 'string') throw new HttpError(400, 'endpoint is required');
  return { ok: true, removed: pushFor(ctx.config).unsubscribe(endpoint) };
}

export async function pushTest(req, res, ctx) {
  const p = pushFor(ctx.config);
  if (!p.list().length) throw new HttpError(409, 'no subscriptions: enable alerts first');
  return p.sendAll({ title: 'Agents', body: 'Test alert from the dashboard', url: '/', tag: 'agent-web-test' });
}
