// web/lib/term.mjs: the terminal WebSocket, WS /api/sessions/:name/term?cols=&rows= (docs/web-dashboard-plan.md,
// section 2 "Terminal protocol"). Each socket runs `python3 web/pty-bridge.py --cols C --rows R -- agent attach
// <name>`, so a browser tab is one more device with its own grouped view <name>@<n>, exactly as an ssh login is.
//
// Binary frames are raw terminal bytes both ways; text frames are JSON: {"type":"resize","cols","rows"} in, and
// {"type":"exit","code"} out just before the server closes because the bridge exited. A closed socket hangs the
// bridge up (SIGHUP), the tmux client goes and destroy-unattached removes the view. An unknown session closes
// with 4404 before any data. Terminal bytes are never logged.

import { spawn } from 'node:child_process';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { agentBin, findSession } from './agent.mjs';
import { HttpError } from './auth.mjs';

const BRIDGE = fileURLToPath(new URL('../pty-bridge.py', import.meta.url));

// Mutable so an in-process test can shorten the ping and lower the cap; nothing else changes them.
export const limits = { max: 16, pingMs: 25000, highWater: 1 << 20 };

const bridges = new Set();
let reserved = 0;

const clamp = (v, lo, hi, dflt) => {
  const n = Number.parseInt(v, 10);
  return Number.isFinite(n) ? Math.min(hi, Math.max(lo, n)) : dflt;
};
const size = (cols, rows) => [clamp(cols, 20, 500, 80), clamp(rows, 5, 200, 24)];

// A missing session is still upgraded, then closed with 4404: a browser never sees a refused handshake's status,
// and the UI needs to tell "gone" from "cannot connect".
async function sessionExists(env, name) {
  try {
    await findSession(env, name);
    return true;
  } catch (err) {
    if (err instanceof HttpError && err.status === 404) return false;
    throw err;
  }
}

// The bridge is a device of its own, not the ssh login or tmux client the server may have been started from.
function bridgeEnv(env) {
  const out = { ...env, AGENT_DEVICE: 'web', TERM: 'xterm-256color' };
  for (const k of ['TMUX', 'TMUX_PANE', 'SSH_CLIENT', 'SSH_CONNECTION', 'SSH_TTY']) delete out[k];
  return out;
}

const exitCode = (code, signal) => code ?? 128 + (os.constants.signals[signal] ?? 0);

// WS route handler. The slot is taken before the first await so concurrent handshakes cannot overrun the cap.
export async function openTerminal(req, ctx) {
  if (bridges.size + reserved >= limits.max) throw new HttpError(503, 'too many terminals');
  reserved += 1;
  let ws;
  let found;
  try {
    found = await sessionExists(ctx.env, ctx.params.name);
    ws = await ctx.upgrade();
  } finally {
    reserved -= 1;
  }
  if (!found) {
    ws.close(4404, 'no such session');
    return;
  }
  run(ws, ctx);
}

function run(ws, ctx) {
  if (ws.readyState !== ws.OPEN) return;
  const [cols, rows] = size(ctx.query.get('cols'), ctx.query.get('rows'));
  const child = spawn('python3', [BRIDGE, '--cols', String(cols), '--rows', String(rows), '--',
    agentBin(ctx.env), 'attach', ctx.params.name], { env: bridgeEnv(ctx.env), stdio: ['pipe', 'pipe', 'ignore', 'pipe'] });
  const ctl = child.stdio[3];
  const closed = new Promise((resolve) => child.on('close', resolve));
  const entry = { child, closed };
  bridges.add(entry);
  for (const s of [child.stdin, ctl]) s.on('error', () => {});

  const hangUp = () => {
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGHUP');
  };

  // Backpressure: a slow browser stops the bridge reading the pty (it has its own 64 KiB stop) rather than
  // letting output pile up here. ws has no drain event, so poll until the socket buffer is back under the mark.
  let drain = null;
  child.stdout.on('data', (chunk) => {
    if (ws.readyState !== ws.OPEN) return;
    ws.send(chunk, { binary: true });
    if (ws.bufferedAmount > limits.highWater && !drain) {
      child.stdout.pause();
      drain = setInterval(() => {
        if (ws.readyState === ws.OPEN && ws.bufferedAmount > limits.highWater) return;
        clearInterval(drain);
        drain = null;
        child.stdout.resume();
      }, 20);
    }
  });

  ws.on('message', (data, isBinary) => {
    if (isBinary) {
      if (child.stdin.writable) child.stdin.write(data);
      return;
    }
    let msg;
    try {
      msg = JSON.parse(data.toString('utf8'));
    } catch {
      return;
    }
    if (msg?.type === 'resize' && ctl.writable) ctl.write(`${size(msg.cols, msg.rows).join(' ')}\n`);
  });

  // A tab that went away without a close (laptop lid, lost network) is noticed by a missed pong.
  let alive = true;
  ws.on('pong', () => { alive = true; });
  const ping = setInterval(() => {
    if (!alive) {
      ws.terminate();
      return;
    }
    alive = false;
    ws.ping();
  }, limits.pingMs);

  ws.on('close', () => {
    clearInterval(ping);
    hangUp();
  });
  ws.on('error', () => {});

  child.on('error', () => {
    if (ws.readyState === ws.OPEN) ws.close(1011, 'bridge failed');
  });
  child.on('close', (code, signal) => {
    bridges.delete(entry);
    clearInterval(ping);
    if (drain) clearInterval(drain);
    // After a hangup the socket is already closing; tmux attach's exit 1 then means nothing.
    if (ws.readyState !== ws.OPEN) return;
    ws.send(JSON.stringify({ type: 'exit', code: exitCode(code, signal) }));
    ws.close(1000);
  });
}

// For onShutdown: hang every bridge up and wait (briefly) for them, so no tmux client outlives the server.
export async function hangUpTerminals(waitMs = 1000) {
  const all = [...bridges];
  for (const { child } of all) {
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGHUP');
  }
  await Promise.race([Promise.all(all.map((b) => b.closed)), new Promise((r) => setTimeout(r, waitMs).unref())]);
}

// The number of live bridges, for the tests.
export const terminalCount = () => bridges.size;
