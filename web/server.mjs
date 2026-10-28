#!/usr/bin/env node
// web/server.mjs: the web dashboard service on the host (docs/web-dashboard-plan.md). Run as
// `node web/server.mjs` by the agent-web user unit; it listens on 127.0.0.1:$AGENT_WEB_PORT only and is reached
// through `tailscale serve`, which proves who the caller is with the Tailscale-User-Login header. Node 20 or later,
// ES modules, the pinned packages in web/package.json and nothing else.
//
// Environment (section 2 of the plan): AGENT_WEB_PORT (7690; 0 picks a free port, for tests), AGENT_WEB_ALLOW
// (comma list of logins, required: exit 2 when empty), AGENT_WEB_STATE, AGENT_WEB_FILES, AGENT_WEB_QUIET_SECS.
// HOME, AGENT_TMUX_SOCKET and CLIP_BRIDGE_SPOOL pass through to the commands the routes run; that is how the tests
// keep off the live tmux and ~/.clip.
//
// Every request goes through the same gate before any route runs: loopback peer, an allowed login, and for
// anything but GET or HEAD a POST with X-Agent-Web: 1 and a JSON body (auth.mjs). WebSocket upgrades also need
// an Origin matching Host. One log line per request: method, path, status, ms; never bodies or terminal data.
//
// Routes: one [method, pattern, handler, opts?] line each in ROUTES below; later tasks add lines there (or call
// addRoute). Patterns are paths with :name segments, which arrive URL-decoded in ctx.params.
//   - HTTP handler: async (req, res, ctx). A returned value is sent as JSON with 200; throw HttpError(status,
//     message) for {"error": message}; or write to res directly and return undefined. Read a POST body with
//     readJson(req) (or readBody(req) on an opts.raw route, which may take any Content-Type).
//   - 'WS' handler: async (req, ctx). Call `const ws = await ctx.upgrade()` to accept (a ws WebSocket); throwing
//     HttpError before that refuses the handshake with that status; returning without upgrading is a 404.
//   ctx = {params, query (URLSearchParams), pathname, login, env, config}. env is the server's environment: pass
//   it to child processes rather than reading process.env, so an in-process server keeps its test HOME.
// onShutdown(fn) registers cleanup (e.g. SIGHUP to terminal bridges) run on SIGTERM before the process exits.

import http from 'node:http';
import path from 'node:path';
import { realpathSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { WebSocketServer } from 'ws';
import {
  HttpError, SECURITY_HEADERS, checkLogin, checkOrigin, checkPeer, checkPost, loginOf, parseAllow,
} from './lib/auth.mjs';
import { serveStatic } from './lib/static.mjs';
import { createSession, getRepos, killSession, worktreeStatus } from './lib/sessions.mjs';
import { getSessions, markSeen, startAlerts, stopAlerts } from './lib/attention.mjs';
import { getPushKey, pushSubscribe, pushTest, pushUnsubscribe } from './lib/push.mjs';
import { hangUpTerminals, openTerminal } from './lib/term.mjs';
import { uploadFile } from './lib/upload.mjs';
import { getSim } from './lib/sim.mjs';

export { HttpError, readBody, readJson } from './lib/auth.mjs';

const routes = [];
const shutdownHooks = [];

// '/api/sessions/:name/kill' -> a matcher. Parameters never span a '/'.
export function addRoute(method, pattern, handler, opts = {}) {
  const keys = [];
  const src = pattern.split('/').map((seg) => {
    if (!seg.startsWith(':')) return seg.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    keys.push(seg.slice(1));
    return '([^/]+)';
  }).join('/');
  routes.push({ method: method.toUpperCase(), pattern, re: new RegExp(`^${src}$`), keys, handler, opts });
}

export function onShutdown(fn) {
  shutdownHooks.push(fn);
}

// --- route table: one line per route ---------------------------------------------------------------------------
const ROUTES = [
  ['GET', '/api/health', () => ({ ok: true })],
  ['GET', '/api/me', (req, res, ctx) => ({ login: ctx.login })],
  ['GET', '/api/sessions', getSessions],
  ['GET', '/api/repos', getRepos],
  ['POST', '/api/sessions', createSession],
  ['GET', '/api/sessions/:name/worktree', worktreeStatus],
  ['POST', '/api/sessions/:name/kill', killSession],
  ['WS', '/api/sessions/:name/term', openTerminal],
  ['POST', '/api/sessions/:name/upload', uploadFile, { raw: true }],
  ['GET', '/api/sim', getSim],
  ['POST', '/api/sessions/:name/seen', markSeen],
  ['GET', '/api/push/key', getPushKey],
  ['POST', '/api/push/subscribe', pushSubscribe],
  ['POST', '/api/push/unsubscribe', pushUnsubscribe],
  ['POST', '/api/push/test', pushTest],
];
for (const r of ROUTES) addRoute(...r);
onShutdown(hangUpTerminals);
onShutdown(stopAlerts);

function match(method, pathname) {
  for (const r of routes) {
    if (r.method !== method) continue;
    const m = r.re.exec(pathname);
    if (!m) continue;
    const params = {};
    try {
      r.keys.forEach((k, i) => { params[k] = decodeURIComponent(m[i + 1]); });
    } catch {
      throw new HttpError(400, 'bad path');
    }
    return { route: r, params };
  }
  return null;
}

export class ConfigError extends Error {}

export function loadConfig(env) {
  const allow = parseAllow(env.AGENT_WEB_ALLOW);
  if (allow.size === 0) {
    throw new ConfigError('AGENT_WEB_ALLOW is empty: set it to your tailnet login (comma-separated for several)');
  }
  const portText = env.AGENT_WEB_PORT || '7690';
  const port = Number(portText);
  if (!/^\d+$/.test(portText) || port > 65535) throw new ConfigError(`AGENT_WEB_PORT is not a port: ${portText}`);
  const quietText = env.AGENT_WEB_QUIET_SECS || '45';
  if (!/^\d+$/.test(quietText)) throw new ConfigError(`AGENT_WEB_QUIET_SECS is not a number: ${quietText}`);
  const home = env.HOME || '/';
  return {
    port,
    allow,
    state: env.AGENT_WEB_STATE || path.join(home, '.local/state/agent-web'),
    files: env.AGENT_WEB_FILES || path.join(home, '.clip/files'),
    quietSecs: Number(quietText),
  };
}

function wantsHtml(req) {
  return req.method === 'GET' && String(req.headers.accept ?? '').includes('text/html');
}

// The 403 a browser sees when it is not coming through tailscale serve as an allowed login.
const FORBIDDEN_PAGE = '<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">'
  + '<title>Forbidden</title><body>'
  + '<h1>403 Forbidden</h1><p>Open this page through <code>tailscale serve</code> with an allowed login.</p>';

function sendError(req, res, err) {
  const status = err instanceof HttpError ? err.status : 500;
  if (res.headersSent) {
    res.destroy();
    return;
  }
  if (status === 403 && wantsHtml(req)) {
    res.writeHead(403, { ...SECURITY_HEADERS, 'Content-Type': 'text/html; charset=utf-8' });
    res.end(FORBIDDEN_PAGE);
    return;
  }
  sendJson(res, status, { error: status === 500 ? 'internal error' : err.message });
}

export function sendJson(res, status, value) {
  const body = JSON.stringify(value);
  res.writeHead(status, {
    ...SECURITY_HEADERS,
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-store',
  });
  res.end(body);
}

function parseUrl(req) {
  try {
    return new URL(req.url, 'http://localhost');
  } catch {
    return null;
  }
}

export function createServer(env = process.env, { log = (line) => console.log(line) } = {}) {
  const config = loadConfig(env);
  startAlerts(env, config);   // the attention watcher (web/lib/attention.mjs), stopped by stopAlerts on shutdown
  const wss = new WebSocketServer({ noServer: true });

  async function onRequest(req, res) {
    const t0 = performance.now();
    const url = parseUrl(req);
    res.on('close', () => {
      log(`${req.method} ${url ? url.pathname : '-'} ${res.statusCode} ${Math.round(performance.now() - t0)}ms`);
    });
    try {
      if (!url) throw new HttpError(400, 'bad request');
      const denied = checkPeer(req) || checkLogin(req, config.allow);
      if (denied) throw denied;
      const read = req.method === 'GET' || req.method === 'HEAD';
      const found = match(read ? 'GET' : 'POST', url.pathname);
      if (!read) {
        const refused = checkPost(req, found?.route.opts);
        if (refused) throw refused;
      }
      if (found) {
        const ctx = { params: found.params, query: url.searchParams, pathname: url.pathname, login: loginOf(req), env, config };
        const out = await found.route.handler(req, res, ctx);
        if (out !== undefined && !res.headersSent) sendJson(res, 200, out);
        else if (!res.headersSent && !res.writableEnded) throw new Error(`no response from ${found.route.pattern}`);
        return;
      }
      if (read && !url.pathname.startsWith('/api/') && await serveStatic(req, res, url.pathname, SECURITY_HEADERS)) return;
      throw new HttpError(404, 'not found');
    } catch (err) {
      if (!(err instanceof HttpError)) console.error(err);
      sendError(req, res, err);
    }
  }

  async function onUpgrade(req, socket, head) {
    const t0 = performance.now();
    const url = parseUrl(req);
    let upgraded = false;
    let accepted = null;
    const done = (status) => log(`WS ${url ? url.pathname : '-'} ${status} ${Math.round(performance.now() - t0)}ms`);
    const refuse = (status) => {
      if (!socket.destroyed) {
        socket.end(`HTTP/1.1 ${status} ${http.STATUS_CODES[status]}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
      }
      done(status);
    };
    socket.on('error', () => {});
    try {
      if (!url) throw new HttpError(400, 'bad request');
      const denied = checkPeer(req) || checkLogin(req, config.allow) || checkOrigin(req);
      if (denied) throw denied;
      const found = match('WS', url.pathname);
      if (!found) throw new HttpError(404, 'not found');
      const ctx = {
        params: found.params, query: url.searchParams, pathname: url.pathname, login: loginOf(req), env, config,
        upgrade: () => new Promise((resolve) => {
          upgraded = true;
          wss.handleUpgrade(req, socket, head, (ws) => {
            accepted = ws;
            done(101);
            resolve(ws);
          });
        }),
      };
      await found.route.handler(req, ctx);
      if (!upgraded) throw new HttpError(404, 'not found');
    } catch (err) {
      if (!(err instanceof HttpError)) console.error(err);
      if (!upgraded) refuse(err instanceof HttpError ? err.status : 500);
      else if (accepted) accepted.close(1011);
      else socket.destroy();
    }
  }

  const server = http.createServer(onRequest);
  server.on('upgrade', onUpgrade);

  return {
    server,
    config,
    listen() {
      return new Promise((resolve, reject) => {
        server.once('error', reject);
        server.listen(config.port, '127.0.0.1', () => {
          server.off('error', reject);
          resolve(server.address());
        });
      });
    },
    async close() {
      for (const fn of shutdownHooks) {
        try {
          await fn();
        } catch (err) {
          console.error(err);
        }
      }
      for (const ws of wss.clients) ws.terminate();
      await new Promise((resolve) => {
        server.close(() => resolve());
        server.closeAllConnections();
      });
    },
  };
}

async function main() {
  let app;
  try {
    app = createServer(process.env);
  } catch (err) {
    if (!(err instanceof ConfigError)) throw err;
    console.error(`agent-web: ${err.message}`);
    process.exit(2);
  }
  let addr;
  try {
    addr = await app.listen();
  } catch (err) {
    console.error(`agent-web: cannot listen on 127.0.0.1:${app.config.port}: ${err.code ?? err.message}`);
    process.exit(1);
  }
  console.log(`agent-web listening on http://${addr.address}:${addr.port}`);
  let stopping = false;
  const stop = () => {
    if (stopping) return;
    stopping = true;
    // systemd waits 90 s by default; a hung hook must not hold the restart that long.
    setTimeout(() => process.exit(0), 1500).unref();
    app.close().then(() => process.exit(0), () => process.exit(0));
  };
  process.on('SIGTERM', stop);
  process.on('SIGINT', stop);
}

// Run when started as the entry point (also through a symlink), not when imported by the tests.
function entryUrl() {
  try {
    return pathToFileURL(realpathSync(process.argv[1])).href;
  } catch {
    return '';
  }
}
if (entryUrl() === import.meta.url) main();
