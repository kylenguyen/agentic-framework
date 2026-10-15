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
// Shape, kept for the reconnecting mode the plan adds later: spawnServer() is the only place a server starts,
// onServerExit() decides what its exit means, onClientLine() routes the harness's messages, and inject() is the only
// way a response of the relay's own reaches stdout.
import { spawn } from 'node:child_process';
import { writeFileSync, rmSync } from 'node:fs';
import { constants } from 'node:os';

const say = (msg) => process.stderr.write(`sim-mcp: ${msg}\n`);

// --- arguments ---------------------------------------------------------------------------------------------------
function parseArgs(argv) {
  const opts = { platform: '', slot: '', wake: '', pgidFile: '', server: [] };
  const keys = { '--platform': 'platform', '--slot': 'slot', '--wake': 'wake', '--pgid-file': 'pgidFile' };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--') { opts.server = argv.slice(i + 1); break; }
    const key = keys[argv[i]];
    if (!key || i + 1 >= argv.length) usage();
    opts[key] = argv[++i];
  }
  if (!opts.server.length) usage();
  return opts;
}
function usage() {
  process.stderr.write('usage: sim-mcp-relay.mjs --platform P --slot N --wake "<cmd>" --pgid-file F -- <server...>\n');
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
let server = null;            // the ChildProcess
let pgid = 0;
let state = 'running';        // running -> stopping (session ending) -> exiting

function spawnServer() {
  const child = spawn(opts.server[0], opts.server.slice(1), { stdio: ['pipe', 'pipe', 'inherit'], detached: true });
  child.on('error', (err) => { say(`cannot start ${opts.server[0]}: ${err.message}`); finish(1); });
  if (child.pid === undefined) return child;
  pgid = child.pid;           // detached: the server leads a new session and process group
  try { writeFileSync(opts.pgidFile, `${pgid}\n`); } catch { /* no pgid file: bin/sim cannot clean up after us */ }
  child.stdin.on('error', () => {});                               // EPIPE when the server is already gone
  const feed = lineSplitter(onServerLine);
  child.stdout.on('data', (chunk) => feed(chunk));
  child.stdout.on('end', () => feed.flush());
  child.on('exit', (code, signal) => onServerExit(code, signal));
  return child;
}

function onServerLine(line) { out(line); }

function onServerExit(code, signal) {
  const rc = code ?? 128 + (constants.signals[signal] || 15);
  // Whatever the server left in its group (a helper, a `sleep &`) goes with it; then its last output, then exit.
  killGroup().then(() => {
    const done = () => finish(rc);
    if (server.stdout.readableEnded || server.stdout.destroyed) done();
    else { server.stdout.once('close', done); setTimeout(done, 1000).unref(); }
  });
}

function toServer(line) {
  if (server && server.stdin.writable) server.stdin.write(Buffer.concat([line, NL]));
}

// killGroup(): TERM the server's process group, KILL it after 5 s if anything is left; resolves when it is empty.
let killing = null;
function killGroup() {
  if (killing) return killing;
  killing = new Promise((resolve) => {
    if (!pgid) return resolve();
    signalGroup(pgid, 'SIGTERM');
    const t0 = Date.now();
    const poll = setInterval(() => {
      if (!groupAlive(pgid)) { clearInterval(poll); resolve(); return; }
      if (Date.now() - t0 >= 5000) { signalGroup(pgid, 'SIGKILL'); clearInterval(poll); setTimeout(resolve, 100); }
    }, 50);
  });
  return killing;
}
function signalGroup(id, sig) { try { process.kill(-id, sig); } catch { /* already gone */ } }
function groupAlive(id) { try { process.kill(-id, 0); return true; } catch (e) { return e.code === 'EPERM'; } }

function finish(rc) {
  if (state === 'exiting') return;
  state = 'exiting';
  process.exitCode = rc;
  if (wakeProc) signalGroup(wakeProc.pid, 'SIGTERM');
  try { rmSync(opts.pgidFile, { force: true }); } catch { /* nothing to remove */ }
  // Let stdout drain before exiting: on a pipe Node writes synchronously on Linux, but not everywhere.
  if (process.stdout.writableLength) process.stdout.once('drain', () => process.exit(rc));
  else process.exit(rc);
  setTimeout(() => process.exit(rc), 2000).unref();
}

// shutdown(why): the session ends. The server's stdin is closed so it can exit by itself; after 5 s its group is
// killed. The server's exit (onServerExit) does the rest.
let shutdownTimer = null;
function shutdown(why) {
  if (state !== 'running') return;
  state = 'stopping';
  if (wakeProc) signalGroup(wakeProc.pid, 'SIGTERM');
  if (!server || server.pid === undefined) { finish(1); return; }
  if (server.exitCode !== null || server.signalCode !== null) return;   // onServerExit is already on it
  if (why && why !== 'eof') say(`${why}: stopping the server`);
  server.stdin.end();
  shutdownTimer = setTimeout(() => killGroup(), 5000);
  shutdownTimer.unref?.();
}
for (const sig of ['SIGTERM', 'SIGINT', 'SIGHUP']) process.on(sig, () => shutdown(sig));

// --- tool calls and the wake -------------------------------------------------------------------------------------
const queue = [];             // [{ id, line }] tool calls waiting for the device
let wakeProc = null;
let stdinEnded = false;

function drain() {
  if (wakeProc || !queue.length || state !== 'running') return;
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
    if (state !== 'running') return;
    flushQueue(code === 0 && !signal ? 0 : 1, last || `the device did not wake (exit ${code ?? signal})`);
    if (stdinEnded) shutdown('eof');
  });
}

function flushQueue(rc, reason) {
  const calls = queue.splice(0);
  for (const c of calls) {
    if (rc === 0) toServer(c.line);
    else inject({ jsonrpc: '2.0', id: c.id,
      result: { content: [{ type: 'text', text: `sim: ${reason.replace(/^sim(-mcp)?: /, '')}` }], isError: true } });
  }
  drain();
}

// --- the harness's messages --------------------------------------------------------------------------------------
function onClientLine(line) {
  let msg;
  try { msg = JSON.parse(line.toString('utf8')); } catch { msg = undefined; }
  if (msg && typeof msg === 'object' && !Array.isArray(msg) && msg.method === 'tools/call' && msg.id !== undefined) {
    queue.push({ id: msg.id, line });
    drain();
    return;
  }
  toServer(line);
}

server = spawnServer();
const feedStdin = lineSplitter(onClientLine);
process.stdin.on('data', (chunk) => { if (state === 'running') feedStdin(chunk); });
process.stdin.on('end', () => {
  feedStdin.flush();
  stdinEnded = true;
  if (!wakeProc && !queue.length) shutdown('eof');   // else the wake's end shuts down, once the queue is answered
});
process.stdin.on('error', () => shutdown('eof'));
