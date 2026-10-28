// tests/web/helpers.mjs: shared setup for the tests/web/*.test.mjs files that tests/web-test.sh runs under
// node:test. Each test file runs in its own process, so each gets its own throwaway HOME and its own tmux socket
// (aw-test-<pid>); the live tmux server, ~/workspace and ~/.clip are never touched. Everything is removed when the
// process exits.
//
//   fixture()                       the throwaway host, made on first call: {root, home, bin, workspace, demo,
//                                   socket, env, tm(...args)}. home/workspace/demo is a git repo (branch main, one
//                                   empty commit). home/bin is first on PATH and holds the stand-in harnesses
//                                   (claude, codex, omp, opencode: record their cwd in ~/standin.cwd, then block
//                                   on a read as a process named claude-proc, as in tests/agent-test.sh) and links
//                                   to the working tree's bin/agent and bin/clip-put. env is the environment for
//                                   anything under test: that HOME and PATH, AGENT_TMUX_SOCKET, CLIP_BRIDGE_SPOOL,
//                                   AGENT_WEB_ALLOW=ALLOWED, AGENT_WEB_STATE and AGENT_WEB_FILES under root,
//                                   AGENT_WEB_PORT=0; TMUX, TMUX_PANE and SSH_* removed. tm() runs tmux on the
//                                   test socket and returns trimmed stdout.
//   startServer(env?, opts?)        starts web/server.mjs on a free port with fixture().env plus env (a value of
//                                   undefined removes a variable) and waits until it listens. Resolves to
//                                   {url, port, logs, req, ws, stop, proc | app}. By default a child process
//                                   (`node web/server.mjs`); opts.inProcess runs createServer() in this process
//                                   instead, so routes the test adds with addRoute exist. stop(signal='SIGTERM')
//                                   resolves to {code, signal, ms} (in-process: {code: 0}). Rejects, with .code
//                                   and .stderr, when the child exits before listening.
//   req(path, opts?)                one HTTP request to the last started server (or opts.base), the path sent
//                                   raw (no URL normalising, so /../ reaches the server). opts: login (default
//                                   ALLOWED; null sends no Tailscale-User-Login), method (default POST with a
//                                   body, else GET), headers (a null value drops a default header), body (an
//                                   object or array is sent as JSON; a Buffer or string as is). A POST gets
//                                   X-Agent-Web: 1 by default. Resolves to {status, headers, text, json, body}.
//   wsConnect(path, opts?)          opens a WebSocket (the ws package) to the last started server. opts: login,
//                                   origin (default the server's own), headers, base. Resolves to the open
//                                   socket; rejects with err.status when the handshake is refused.
//   waitFor(cond, opts?)            polls cond() (sync or async) until truthy: {timeout=5000, interval=50}.
//   cleanup()                       kills started servers and the test tmux server, removes root. Runs on exit.

import { execFileSync, spawn } from 'node:child_process';
import { copyFileSync, mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import http from 'node:http';
import { createRequire } from 'node:module';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
export const WEB = path.join(REPO, 'web');
export const SERVER = path.join(WEB, 'server.mjs');
export const ALLOWED = 'tester@example.test';
export const SOCKET = `aw-test-${process.pid}`;

const { WebSocket } = createRequire(path.join(WEB, 'package.json'))('ws');

let fx = null;
const running = new Set();
let lastBase = null;

const STANDIN = `#!/bin/sh
pwd > "$HOME/standin.cwd"
exec claude-proc -c 'read line'
`;

export function fixture() {
  if (fx) return fx;
  const root = realpathSync(mkdtempSync(path.join(os.tmpdir(), 'aw-test-')));
  const home = path.join(root, 'home');
  const bin = path.join(home, 'bin');
  const workspace = path.join(home, 'workspace');
  const demo = path.join(workspace, 'demo');
  mkdirSync(bin, { recursive: true });
  mkdirSync(demo, { recursive: true });
  // A copy of sh rather than a link to sleep: coreutils is one multi-call binary that refuses another argv[0].
  copyFileSync(realpathSync('/bin/sh'), path.join(bin, 'claude-proc'));
  for (const h of ['claude', 'codex', 'omp', 'opencode']) writeFileSync(path.join(bin, h), STANDIN, { mode: 0o755 });
  symlinkSync(path.join(REPO, 'bin/agent'), path.join(bin, 'agent'));
  symlinkSync(path.join(REPO, 'bin/clip-put'), path.join(bin, 'clip-put'));

  const env = { ...process.env };
  for (const k of Object.keys(env)) {
    if (/^(TMUX|TMUX_PANE|SSH_CLIENT|SSH_CONNECTION|SSH_TTY|AGENT_DEVICE)$/.test(k) || k.startsWith('AGENT_WEB_')) {
      delete env[k];
    }
  }
  // mise shims look their versions up against $HOME, which the throwaway HOME does not have.
  const syspath = (process.env.PATH ?? '').split(':').filter((p) => p && !p.endsWith('/mise/shims'));
  Object.assign(env, {
    HOME: home,
    PATH: [bin, ...syspath].join(':'),
    AGENT_TMUX_SOCKET: SOCKET,
    CLIP_BRIDGE_SPOOL: path.join(root, 'clip/latest'),
    AGENT_WEB_ALLOW: ALLOWED,
    AGENT_WEB_STATE: path.join(root, 'state'),
    AGENT_WEB_FILES: path.join(root, 'files'),
    AGENT_WEB_PORT: '0',
  });

  const git = (...args) => execFileSync('git', ['-C', demo, ...args], { env, stdio: 'ignore' });
  git('init', '-q', '-b', 'main');
  git('-c', 'user.email=t@example', '-c', 'user.name=t', 'commit', '-q', '--allow-empty', '-m', 'init');

  const tm = (...args) => execFileSync('tmux', ['-L', SOCKET, ...args], { env, encoding: 'utf8' }).trim();
  fx = { root, home, bin, workspace, demo, socket: SOCKET, env, tm };
  return fx;
}

function mergeEnv(extra) {
  const env = { ...fixture().env };
  for (const [k, v] of Object.entries(extra)) {
    if (v === undefined) delete env[k];
    else env[k] = String(v);
  }
  return env;
}

export async function startServer(extra = {}, opts = {}) {
  const env = mergeEnv(extra);
  const s = opts.inProcess ? await startInProcess(env) : await startChild(env);
  s.req = (p, o = {}) => req(p, { base: s.url, ...o });
  s.ws = (p, o = {}) => wsConnect(p, { base: s.url, ...o });
  lastBase = s.url;
  return s;
}

async function startInProcess(env) {
  const { createServer } = await import(SERVER);
  const logs = [];
  const app = createServer(env, { log: (line) => logs.push(line) });
  const addr = await app.listen();
  const s = { app, port: addr.port, url: `http://127.0.0.1:${addr.port}`, logs };
  let stopped = false;
  s.kill = () => {
    if (!stopped) app.server.closeAllConnections();
  };
  s.stop = async () => {
    if (!stopped) await app.close();
    stopped = true;
    running.delete(s);
    return { code: 0, signal: null };
  };
  running.add(s);
  return s;
}

function startChild(env) {
  return new Promise((resolve, reject) => {
    const proc = spawn(process.execPath, [SERVER], { env, stdio: ['ignore', 'pipe', 'pipe'] });
    const logs = [];
    let stderr = '';
    let buf = '';
    let listening = false;
    const exited = new Promise((res) => proc.on('exit', (code, signal) => res({ code, signal })));
    const s = { proc, logs, stderr: () => stderr };
    s.kill = () => proc.exitCode === null && proc.signalCode === null && proc.kill('SIGKILL');
    s.stop = async (signal = 'SIGTERM') => {
      const t0 = Date.now();
      if (proc.exitCode === null && proc.signalCode === null) proc.kill(signal);
      const r = await exited;
      running.delete(s);
      return { ...r, ms: Date.now() - t0 };
    };
    running.add(s);
    proc.stderr.on('data', (c) => { stderr += c; });
    proc.stdout.on('data', (c) => {
      buf += c;
      let i;
      while ((i = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, i);
        buf = buf.slice(i + 1);
        logs.push(line);
        const m = !listening && /listening on (http:\/\/\S+)/.exec(line);
        if (m) {
          listening = true;
          s.url = m[1];
          s.port = Number(new URL(m[1]).port);
          resolve(s);
        }
      }
    });
    exited.then(({ code, signal }) => {
      if (listening) return;
      running.delete(s);
      reject(Object.assign(new Error(`server exited (${code ?? signal}) before listening: ${stderr}`), { code, signal, stderr }));
    });
  });
}

export function req(p, opts = {}) {
  const { login = ALLOWED, headers = {}, body, base = lastBase } = opts;
  const method = opts.method ?? (body === undefined ? 'GET' : 'POST');
  const h = {};
  if (login !== null) h['tailscale-user-login'] = login;
  if (method === 'POST') h['x-agent-web'] = '1';
  let data;
  if (Buffer.isBuffer(body) || typeof body === 'string') data = body;
  else if (body !== undefined) {
    data = JSON.stringify(body);
    h['content-type'] = 'application/json';
  }
  for (const [k, v] of Object.entries(headers)) {
    if (v === null) delete h[k.toLowerCase()];
    else h[k.toLowerCase()] = v;
  }
  if (data !== undefined) h['content-length'] = Buffer.byteLength(data);
  const { hostname, port } = new URL(base);
  return new Promise((resolve, reject) => {
    const r = http.request({ host: hostname, port, path: p, method, headers: h }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        const buf = Buffer.concat(chunks);
        const text = buf.toString('utf8');
        let json;
        if (String(res.headers['content-type'] ?? '').startsWith('application/json')) {
          try {
            json = JSON.parse(text);
          } catch { /* left undefined */ }
        }
        resolve({ status: res.statusCode, headers: res.headers, text, json, body: buf });
      });
    });
    // The server may answer (413, 403) and close before the whole body is written.
    r.on('error', (e) => (e.code === 'EPIPE' || e.code === 'ECONNRESET' ? null : reject(e)));
    if (data !== undefined) r.end(data);
    else r.end();
  });
}

export function wsConnect(p, opts = {}) {
  const { login = ALLOWED, headers = {}, base = lastBase } = opts;
  const origin = 'origin' in opts ? opts.origin : base;
  const h = { ...headers };
  if (login !== null) h['Tailscale-User-Login'] = login;
  if (origin !== null) h.Origin = origin;
  const url = base.replace(/^http/, 'ws') + p;
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url, { headers: h });
    ws.once('open', () => resolve(ws));
    ws.once('unexpected-response', (_req, res) => {
      reject(Object.assign(new Error(`handshake refused: ${res.statusCode}`), { status: res.statusCode }));
      ws.terminate();
    });
    ws.once('error', (e) => reject(e));
  });
}

export async function waitFor(cond, { timeout = 5000, interval = 50 } = {}) {
  const end = Date.now() + timeout;
  for (;;) {
    const v = await cond();
    if (v) return v;
    if (Date.now() > end) throw new Error(`waitFor: timed out after ${timeout} ms`);
    await new Promise((r) => setTimeout(r, interval));
  }
}

export function cleanup() {
  for (const s of running) {
    try {
      s.kill();
    } catch { /* already gone */ }
  }
  running.clear();
  if (!fx) return;
  try {
    execFileSync('tmux', ['-L', SOCKET, 'kill-server'], { env: fx.env, stdio: 'ignore' });
  } catch { /* no server was started */ }
  // tmux leaves its socket file behind; the name is this process's own, so removing it is safe.
  const uid = process.getuid?.() ?? 0;
  rmSync(path.join(process.env.TMUX_TMPDIR || '/tmp', `tmux-${uid}`, SOCKET), { force: true });
  rmSync(fx.root, { recursive: true, force: true });
  fx = null;
}

process.on('exit', cleanup);
