#!/usr/bin/env node
// sim-mcp-relay.mjs: the MCP stdio relay between a harness and one slot's MCP server, run by bin/sim-mcp (which holds
// the lease) as `sim-mcp-relay.mjs --platform P --slot N --wake "<cmd>" --pgid-file F -- <server...>`. Node 20 or
// later, no dependencies.
//
// It owns the server process and is the only writer of stdout. One JSON-RPC message per line (MCP stdio):
//   - A tools/call request goes into an ordered queue. Each drain of the queue runs the wake command once (bin/sim
//     _wake P N: start or boot the slot's device and wait for it). Exit 0 forwards the queued calls in order; any
//     other exit answers each of them with a tool error carrying the wake's last stderr line, and the server never
//     sees them.
//   - Everything else (initialize, tools/list, ping, notifications, responses, lines that are not JSON) goes to the
//     server at once, even while a wake runs, byte for byte.
//   - Server stdout is passed on in whole lines, so an injected response never lands inside a server message.
// The server runs in a process group of its own; its pgid is written to F for bin/sim (CLI leases) and the whole group
// is killed when the session ends: on stdin EOF (after up to 5 s for the server to exit by itself), on SIGTERM, SIGINT
// or SIGHUP (bin/sim-mcp forwards its signals here), and when the server exits, which takes anything it left running.
// The exit code is the server's.
//
// --reconnect (sim-mcp passes it for ios, with --host user@mac, --on-drop and --on-up commands): a server that exits
// non-zero while stdin is still open is the Mac dropping off, not the end of the session. The relay keeps the
// session, so the lease stays, and only exits on stdin EOF or a signal:
//   - It remembers the client's initialize and notifications/initialized, the last tools/list result, and the last
//     successful tools/call of each tool named in SIM_REPLAY_TOOLS (comma list, default session_set_defaults).
//   - On the drop every request forwarded and not yet answered gets its answer from the relay (a tools/call an
//     isError result, anything else error -32000), so no call hangs; then --on-drop runs (sim _mac down N: the Mac is
//     cached as down, its shared ssh master dropped).
//   - Then it respawns the server after the delays in SIM_RECONNECT_DELAYS (seconds, comma list, the last repeats;
//     default 5,10,30,60). An attempt is up once the server answers the replayed initialize (id "sim-replay-1"); then
//     notifications/initialized and the remembered tool calls are replayed (ids "sim-replay-<k>") and their responses
//     dropped. An attempt not up within SIM_RECONNECT_TIMEOUT seconds (45) is killed and the next one waits its turn.
//   - Once the replay is answered, --on-up runs (sim _mac up N: the Mac cached as up, N.booted removed so the next
//     wake checks the simulator), the relay logs "reconnected to <host> after Xs" and runs as before.
//   - Meanwhile a tools/call gets an isError result "sim: mac unreachable (<host>), reconnecting, attempt k; ...",
//     tools/list the remembered result, ping {}, any other request error -32000 with that text.
// Responses with a "sim-replay-" id never reach the harness. Without --reconnect server output is passed on unparsed.
//
// Shape: spawnServer() is the only place a server starts, onServerExit() decides what its exit means, onClientLine()
// routes the harness's messages, and inject() is the only way a response of the relay's own reaches stdout.
import { spawn } from 'node:child_process';
import { writeFileSync, rmSync } from 'node:fs';
import { constants } from 'node:os';

const say = (msg) => process.stderr.write(`sim-mcp: ${msg}\n`);

// --- arguments ---------------------------------------------------------------------------------------------------
function parseArgs(argv) {
  const opts = { platform: '', slot: '', wake: '', pgidFile: '', host: '', onDrop: '', onUp: '', reconnect: false,
    server: [] };
  const keys = { '--platform': 'platform', '--slot': 'slot', '--wake': 'wake', '--pgid-file': 'pgidFile',
    '--host': 'host', '--on-drop': 'onDrop', '--on-up': 'onUp' };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--') { opts.server = argv.slice(i + 1); break; }
    if (argv[i] === '--reconnect') { opts.reconnect = true; continue; }
    const key = keys[argv[i]];
    if (!key || i + 1 >= argv.length) usage();
    opts[key] = argv[++i];
  }
  if (!opts.server.length) usage();
  return opts;
}
function usage() {
  process.stderr.write('usage: sim-mcp-relay.mjs --platform P --slot N --wake "<cmd>" --pgid-file F '
    + '[--reconnect --host H --on-drop "<cmd>" --on-up "<cmd>"] -- <server...>\n');
  process.exit(2);
}
const opts = parseArgs(process.argv.slice(2));

// --- line splitting ----------------------------------------------------------------------------------------------
// lineSplitter(onLine): a function to feed Buffers to; calls onLine(Buffer) for every complete line, without its
// newline. Chunks are joined only once a newline arrives, so a 1 MB message costs one copy.
function lineSplitter(onLine) {
  let parts = [];
  const feed = (chunk) => {
    let start = 0, nl;
    while ((nl = chunk.indexOf(10, start)) !== -1) {
      parts.push(chunk.subarray(start, nl));
      onLine(parts.length === 1 ? parts[0] : Buffer.concat(parts));
      parts = [];
      start = nl + 1;
    }
    if (start < chunk.length) parts.push(chunk.subarray(start));
  };
  feed.flush = () => {                  // a last line without a newline still counts as a line
    if (parts.length) { const rest = Buffer.concat(parts); parts = []; if (rest.length) onLine(rest); }
  };
  return feed;
}
const NL = Buffer.from('\n');

// --- stdout: the only writer -------------------------------------------------------------------------------------
function out(line) { process.stdout.write(Buffer.concat([line, NL])); }
function inject(msg) { out(Buffer.from(JSON.stringify(msg))); }
process.stdout.on('error', () => shutdown('stdout closed'));   // the harness is gone

// --- the server --------------------------------------------------------------------------------------------------
let server = null;            // the ChildProcess; each has its own .killing (see killGroup)
let state = 'running';        // running -> stopping (session ending) -> exiting; with --reconnect also
                              // running -> reconnecting (Mac gone, attempts) -> running

function spawnServer() {
  const child = spawn(opts.server[0], opts.server.slice(1), { stdio: ['pipe', 'pipe', 'inherit'], detached: true });
  child.on('error', (err) => {
    say(`cannot start ${opts.server[0]}: ${err.message}`);
    if (state === 'reconnecting' && child.pid === undefined) scheduleAttempt(); else finish(1);
  });
  if (child.pid === undefined) return child;
  // detached: the server leads a new session and process group, whose id is its pid
  try { writeFileSync(opts.pgidFile, `${child.pid}\n`); } catch { /* no pgid file: bin/sim cannot clean up after us */ }
  child.stdin.on('error', () => {});                               // EPIPE when the server is already gone
  const feed = lineSplitter(onServerLine);
  child.stdout.on('data', (chunk) => feed(chunk));
  child.stdout.on('end', () => feed.flush());
  child.on('exit', (code, signal) => onServerExit(child, code, signal));
  return child;
}

function onServerLine(line) {
  if (!opts.reconnect) { out(line); return; }
  let msg;
  try { msg = JSON.parse(line.toString('utf8')); } catch { msg = undefined; }
  if (msg && typeof msg === 'object' && !Array.isArray(msg) && msg.id !== undefined && msg.method === undefined) {
    if (isReplayId(msg.id)) { onReplayResponse(msg); return; }
    const key = JSON.stringify(msg.id);
    const req = pending.get(key);
    if (req) {
      pending.delete(key);
      if (req.method === 'tools/list' && msg.result) toolsList = msg.result;
      const name = req.msg.params?.name;
      if (req.method === 'tools/call' && msg.result && !msg.result.isError && REPLAY_TOOLS.has(name)) {
        replayCalls.delete(name);           // re-inserted: the replay keeps the order the calls last succeeded in
        replayCalls.set(name, req.msg);
      }
    }
  }
  out(line);
}

function onServerExit(child, code, signal) {
  const rc = code ?? 128 + (constants.signals[signal] || 15);
  clearTimeout(attemptTimer);
  if (opts.reconnect && state === 'running' && rc !== 0 && !stdinEnded) {
    state = 'reconnecting';               // from now on the harness's calls are answered here
    dropRc = rc; droppedAt = Date.now(); attempt = 0; dropping = true;
    say(`lost ${opts.host || 'the server'} (exit ${rc}); reconnecting`);
  }
  // Whatever the server left in its group (a helper, a `sleep &`) goes with it, then its last output.
  settling++;
  killGroup(child).then(() => new Promise((resolve) => {
    if (child.stdout.readableEnded || child.stdout.destroyed) resolve();
    else { child.stdout.once('close', resolve); setTimeout(resolve, 1000).unref(); }
  })).then(() => {
    settling--;
    if (state !== 'reconnecting') { finish(dropRc ?? rc); return; }
    if (dropping) {
      dropping = false;
      // Requests the dead server took and never answered: answered here, so no call hangs.
      for (const req of pending.values()) answerReconnecting(req.msg);
      pending.clear();
      for (const c of queue.splice(0)) answerReconnecting(c.msg);
      runHook(opts.onDrop);
    }
    scheduleAttempt();
  });
}

function toServer(line) {
  if (server && server.stdin.writable) server.stdin.write(Buffer.concat([line, NL]));
}

// killGroup(child): TERM the child's process group, KILL it after 5 s if anything is left; resolves when it is empty.
function killGroup(child = server) {
  if (!child || child.pid === undefined) return Promise.resolve();
  if (child.killing) return child.killing;
  const id = child.pid;
  child.killing = new Promise((resolve) => {
    signalGroup(id, 'SIGTERM');
    const t0 = Date.now();
    const poll = setInterval(() => {
      if (!groupAlive(id)) { clearInterval(poll); resolve(); return; }
      if (Date.now() - t0 >= 5000) { signalGroup(id, 'SIGKILL'); clearInterval(poll); setTimeout(resolve, 100); }
    }, 50);
  });
  return child.killing;
}
function signalGroup(id, sig) { try { process.kill(-id, sig); } catch { /* already gone */ } }
function groupAlive(id) { try { process.kill(-id, 0); return true; } catch (e) { return e.code === 'EPERM'; } }

function finish(rc) {
  if (state === 'exiting') return;
  state = 'exiting';
  process.exitCode = rc;
  clearTimeout(retryTimer); clearTimeout(attemptTimer);
  if (wakeProc) signalGroup(wakeProc.pid, 'SIGTERM');
  if (hookProc) hookProc.kill('SIGTERM');
  try { rmSync(opts.pgidFile, { force: true }); } catch { /* nothing to remove */ }
  // Let stdout drain before exiting: on a pipe Node writes synchronously on Linux, but not everywhere.
  if (process.stdout.writableLength) process.stdout.once('drain', () => process.exit(rc));
  else process.exit(rc);
  setTimeout(() => process.exit(rc), 2000).unref();
}

// shutdown(why): the session ends. The server's stdin is closed so it can exit by itself; after 5 s its group is
// killed. The server's exit (onServerExit) does the rest. While reconnecting there is nothing to wait for: the next
// attempt is called off and one under way is killed.
let shutdownTimer = null;
function shutdown(why) {
  if (state !== 'running' && state !== 'reconnecting') return;
  const was = state;
  state = 'stopping';
  if (wakeProc) signalGroup(wakeProc.pid, 'SIGTERM');
  if (was === 'reconnecting') {
    clearTimeout(retryTimer); clearTimeout(attemptTimer);
    if (server && server.pid !== undefined && server.exitCode === null && server.signalCode === null) killGroup(server);
    else if (!settling) finish(dropRc ?? 1);
    return;                               // else onServerExit finishes
  }
  if (!server || server.pid === undefined) { finish(1); return; }
  if (server.exitCode !== null || server.signalCode !== null) return;   // onServerExit is already on it
  if (why && why !== 'eof') say(`${why}: stopping the server`);
  server.stdin.end();
  shutdownTimer = setTimeout(() => killGroup(), 5000);
  shutdownTimer.unref?.();
}
for (const sig of ['SIGTERM', 'SIGINT', 'SIGHUP']) process.on(sig, () => shutdown(sig));

// --- reconnecting (--reconnect) ----------------------------------------------------------------------------------
const DELAYS = (process.env.SIM_RECONNECT_DELAYS || '5,10,30,60').split(',').map(Number).filter((d) => d >= 0);
if (!DELAYS.length) DELAYS.push(5, 10, 30, 60);
const ATTEMPT_TIMEOUT = 1000 * (Number(process.env.SIM_RECONNECT_TIMEOUT) || 45);
const REPLAY_TOOLS = new Set((process.env.SIM_REPLAY_TOOLS ?? 'session_set_defaults').split(',')
  .map((t) => t.trim()).filter(Boolean));
const REPLAY = 'sim-replay-';
const isReplayId = (id) => typeof id === 'string' && id.startsWith(REPLAY);
const pending = new Map();    // JSON id -> { method, msg }: requests the current server took and has not answered
const replayCalls = new Map(); // tool name -> its last successful tools/call
let initMsg = null;           // the client's initialize request
let initializedLine = null;   // and its notifications/initialized, as sent
let toolsList = null;         // the last tools/list result
let dropRc = null, droppedAt = 0, attempt = 0, dropping = false, settling = 0;
let retryTimer = null, attemptTimer = null;
let replayWaiting = new Set(); // replayed ids not answered yet in this attempt

const reconnectingText = () => `sim: mac unreachable (${opts.host}), reconnecting, attempt ${Math.max(attempt, 1)}; `
  + 'try again in about a minute (sim status)';
function answerReconnecting(msg) {
  if (msg.method === 'tools/call') {
    inject({ jsonrpc: '2.0', id: msg.id, result: { content: [{ type: 'text', text: reconnectingText() }], isError: true } });
  } else {
    inject({ jsonrpc: '2.0', id: msg.id, error: { code: -32000, message: reconnectingText() } });
  }
}

function scheduleAttempt() {
  if (state !== 'reconnecting') return;
  const delay = DELAYS[Math.min(attempt, DELAYS.length - 1)];
  attempt++;
  retryTimer = setTimeout(startAttempt, delay * 1000);
}

function startAttempt() {
  retryTimer = null;
  if (state !== 'reconnecting') return;
  replayWaiting = new Set();
  server = spawnServer();
  if (server.pid === undefined) return;   // its 'error' schedules the next attempt
  if (!initMsg) { onUp(); return; }       // the harness never initialized: nothing to replay, nothing to wait for
  replayWaiting.add(`${REPLAY}1`);
  toServer(Buffer.from(JSON.stringify({ ...initMsg, id: `${REPLAY}1` })));
  const child = server;
  attemptTimer = setTimeout(() => {
    say(`attempt ${attempt}: no answer from ${opts.host} within ${ATTEMPT_TIMEOUT / 1000} s`);
    killGroup(child);                     // its exit schedules the next attempt
  }, ATTEMPT_TIMEOUT);
}

function onReplayResponse(msg) {
  if (state !== 'reconnecting' || !replayWaiting.delete(msg.id)) return;
  if (msg.id === `${REPLAY}1`) {
    if (msg.error) { say(`attempt ${attempt}: initialize failed: ${msg.error.message}`); killGroup(server); return; }
    toServer(initializedLine || Buffer.from('{"jsonrpc":"2.0","method":"notifications/initialized"}'));
    let k = 1;
    for (const call of replayCalls.values()) {
      const id = `${REPLAY}${++k}`;
      replayWaiting.add(id);
      toServer(Buffer.from(JSON.stringify({ ...call, id })));
    }
  } else if (msg.error || msg.result?.isError) {
    say(`replayed call ${msg.id} failed: ${msg.error?.message || JSON.stringify(msg.result.content ?? '')}`);
  }
  if (!replayWaiting.size) onUp();
}

function onUp() {
  clearTimeout(attemptTimer);
  state = 'running';
  say(`reconnected to ${opts.host} after ${Math.round((Date.now() - droppedAt) / 1000)}s`);
  dropRc = null;
  runHook(opts.onUp);
  if (stdinEnded) shutdown('eof'); else drain();
}

// runHook(cmd): run a --on-drop / --on-up command, one at a time; wakes wait for it (drain), so the next wake sees
// the Mac's state as the hook left it.
let hookChain = Promise.resolve();
let hooksBusy = 0;
let hookProc = null;
function runHook(cmd) {
  if (!cmd) return;
  hooksBusy++;
  hookChain = hookChain.then(() => new Promise((resolve) => {
    const proc = spawn('bash', ['-c', cmd], { stdio: ['ignore', 'ignore', 'inherit'] });
    hookProc = proc;
    proc.on('error', resolve);
    proc.on('close', resolve);
  })).then(() => { hookProc = null; hooksBusy--; drain(); });
}

// --- tool calls and the wake -------------------------------------------------------------------------------------
const queue = [];             // [{ id, line, msg }] tool calls waiting for the device
let wakeProc = null;
let stdinEnded = false;

function drain() {
  if (wakeProc || hooksBusy || !queue.length || state !== 'running') return;
  if (!opts.wake) { flushQueue(0, ''); return; }
  let last = '';
  const proc = spawn('bash', ['-c', opts.wake], { stdio: ['ignore', 'ignore', 'pipe'], detached: true });
  wakeProc = proc;
  // The wake's messages ("starting emulator-5600; this call waits...") reach the harness's log; its last line is the
  // reason a failed call gets.
  proc.stderr.on('data', (chunk) => {
    process.stderr.write(chunk);
    const lines = chunk.toString('utf8').split('\n').map((l) => l.trim()).filter(Boolean);
    if (lines.length) last = lines[lines.length - 1];
  });
  proc.on('error', (err) => { last = `cannot run the wake command: ${err.message}`; });
  proc.on('close', (code, signal) => {
    wakeProc = null;
    if (state !== 'running') return;      // reconnecting: the queue was answered at the drop
    flushQueue(code === 0 && !signal ? 0 : 1, last || `the device did not wake (exit ${code ?? signal})`);
    if (stdinEnded) shutdown('eof');
  });
}

function flushQueue(rc, reason) {
  const calls = queue.splice(0);
  for (const c of calls) {
    if (rc === 0) {
      if (opts.reconnect) pending.set(JSON.stringify(c.id), { method: 'tools/call', msg: c.msg });
      toServer(c.line);
    } else {
      inject({ jsonrpc: '2.0', id: c.id,
        result: { content: [{ type: 'text', text: `sim: ${reason.replace(/^sim(-mcp)?: /, '')}` }], isError: true } });
    }
  }
  drain();
}

// --- the harness's messages --------------------------------------------------------------------------------------
function onClientLine(line) {
  let msg;
  try { msg = JSON.parse(line.toString('utf8')); } catch { msg = undefined; }
  if (!msg || typeof msg !== 'object' || Array.isArray(msg)) msg = undefined;
  const request = msg && typeof msg.method === 'string' && msg.id !== undefined;
  if (opts.reconnect && msg) {
    if (request && msg.method === 'initialize') initMsg = msg;
    if (msg.method === 'notifications/initialized' && msg.id === undefined) initializedLine = line;
    if (state === 'reconnecting') {
      if (!request) return;               // notifications and responses have no server to go to
      if (msg.method === 'tools/list' && toolsList) inject({ jsonrpc: '2.0', id: msg.id, result: toolsList });
      else if (msg.method === 'ping') inject({ jsonrpc: '2.0', id: msg.id, result: {} });
      else answerReconnecting(msg);
      return;
    }
  }
  if (request && msg.method === 'tools/call') {
    queue.push({ id: msg.id, line, msg });
    drain();
    return;
  }
  if (opts.reconnect && request) pending.set(JSON.stringify(msg.id), { method: msg.method, msg });
  toServer(line);
}

server = spawnServer();
const feedStdin = lineSplitter(onClientLine);
process.stdin.on('data', (chunk) => { if (state === 'running' || state === 'reconnecting') feedStdin(chunk); });
process.stdin.on('end', () => {
  feedStdin.flush();
  stdinEnded = true;
  // else the wake's end shuts down, once the queue is answered
  if (state === 'reconnecting' || (!wakeProc && !queue.length)) shutdown('eof');
});
process.stdin.on('error', () => shutdown('eof'));
