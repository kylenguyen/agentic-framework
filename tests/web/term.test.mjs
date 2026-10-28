// tests/web/term.test.mjs: the terminal WebSocket (web/lib/term.mjs) against real tmux on this file's own socket.
// Sessions are `shell` sessions made with `agent new --no-attach` and named t5<pid>-<n>, so the bridges this run
// starts carry the pid in their command line and "none left behind" is one pgrep that matches nothing else.
// The server is a child process except where a case changes limits (cap, ping), which needs it in this process.
// Usage: bash tests/web-test.sh term
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { fixture, startServer, waitFor } from './helpers.mjs';

const fx = fixture();
const TAG = `t5${process.pid}`;
// sh, not the login shell: a zsh with an empty throwaway HOME would open its new-user menu instead of a prompt.
const shellEnv = { ...fx.env, SHELL: '/bin/sh' };
let seq = 0;

function newSession() {
  const name = `${TAG}-${++seq}`;
  const out = execFileSync('agent', ['new', 'demo', '--harness', 'shell', '--name', name, '--no-attach'],
    { env: shellEnv, encoding: 'utf8' }).trim();
  assert.equal(out, name);
  return name;
}

const sessions = () => fx.tm('list-sessions', '-F', '#{session_name}').split('\n');
const hasSession = (n) => sessions().includes(n);
const lsJson = () => JSON.parse(execFileSync('agent', ['ls', '--json'], { env: fx.env, encoding: 'utf8' }));

function bridgesLeft() {
  try {
    return execFileSync('pgrep', ['-f', `pty-bridge\\.py .* attach ${TAG}-`], { encoding: 'utf8' }).trim();
  } catch (e) {
    if (e.status === 1) return '';
    throw e;
  }
}

// term(server, name, query) opens a terminal and records what arrives: out() is the binary stream as text,
// msgs the JSON control messages, closed resolves to {code, reason} and dataBeforeClose says whether any terminal
// bytes came at all.
async function term(srv, name, query = 'cols=80&rows=24') {
  const ws = await srv.ws(`/api/sessions/${encodeURIComponent(name)}/term?${query}`);
  const chunks = [];
  const msgs = [];
  ws.on('message', (data, isBinary) => {
    if (isBinary) chunks.push(data);
    else msgs.push(JSON.parse(data.toString('utf8')));
  });
  const closed = new Promise((resolve) => ws.on('close', (code, reason) => resolve({ code, reason: String(reason) })));
  const out = () => Buffer.concat(chunks).toString('latin1');
  const type = (s) => ws.send(Buffer.from(s), { binary: true });
  return { ws, out, msgs, closed, type, bytes: () => chunks.length };
}

const servers = [];
async function server(extra, opts) {
  const s = await startServer(extra, opts);
  servers.push(s);
  return s;
}

after(async () => {
  for (const s of servers) await s.stop();
  // Hangups after stop() are asynchronous; the suite fails rather than leaving a bridge behind.
  await waitFor(() => bridgesLeft() === '', { timeout: 5000 });
});

test('a terminal echoes what is typed and opens a web view of the session', async () => {
  const srv = await server();
  const name = newSession();
  const t = await term(srv, name);
  const marker = `marker-${Math.floor(Math.random() * 1e6)}`;
  // Wait for the view before typing: the first keys could otherwise reach the pty before tmux attaches.
  await waitFor(() => hasSession(`${name}@1`));
  t.type(`echo ${marker}\r`);
  await waitFor(() => t.out().split(/\r?\n/).some((l) => l.trim() === marker));
  assert.equal(fx.tm('show-options', '-v', '-t', `${name}@1`, '@device'), 'web');
  assert.deepEqual(lsJson().find((s) => s.name === name).devices, ['web']);
  t.ws.close();
  await t.closed;
});

test('a second terminal opens <name>@2 and both see the same input', async () => {
  const srv = await server();
  const name = newSession();
  const a = await term(srv, name);
  await waitFor(() => hasSession(`${name}@1`));
  const b = await term(srv, name);
  await waitFor(() => hasSession(`${name}@2`));
  const marker = `both-${Math.floor(Math.random() * 1e6)}`;
  a.type(`echo ${marker}\r`);
  await waitFor(() => b.out().includes(marker));
  a.ws.close();
  b.ws.close();
  await Promise.all([a.closed, b.closed]);
});

test('resize messages set the client size, clamped to the limits', async () => {
  const srv = await server();
  const name = newSession();
  const view = `${name}@1`;
  const size = () => fx.tm('display-message', '-p', '-t', view, '#{client_width}x#{client_height}');
  const t = await term(srv, name, 'cols=1&rows=1000');
  await waitFor(() => hasSession(view));
  await waitFor(() => size() === '20x200');
  t.ws.send(JSON.stringify({ type: 'resize', cols: 120, rows: 40 }));
  await waitFor(() => size() === '120x40');
  t.ws.send('not json');
  t.ws.send(JSON.stringify({ type: 'resize', cols: 9999, rows: 0 }));
  await waitFor(() => size() === '500x5');
  t.ws.close();
  await t.closed;
});

test('closing the socket removes the view within 2 s and keeps the base', async () => {
  const srv = await server();
  const name = newSession();
  const t = await term(srv, name);
  await waitFor(() => hasSession(`${name}@1`));
  t.ws.close();
  await waitFor(() => !hasSession(`${name}@1`), { timeout: 2000 });
  assert.ok(hasSession(name));
  assert.equal(lsJson().find((s) => s.name === name).state, 'running');
});

// remain-on-exit keeps a dead harness pane on screen, so `exit` alone does not end tmux attach (an ssh login
// sees the same "Pane is dead" screen). The bridge exits when the session goes, e.g. through `agent kill`.
test('exit in the shell leaves the dead pane; killing the session sends {"type":"exit"} and closes', async () => {
  const srv = await server();
  const name = newSession();
  const t = await term(srv, name);
  await waitFor(() => hasSession(`${name}@1`));
  t.type('exit\r');
  await waitFor(() => lsJson().find((s) => s.name === name).state === 'exited');
  await waitFor(() => t.out().includes('Pane is dead'));
  assert.equal(t.ws.readyState, t.ws.OPEN);
  assert.equal(t.msgs.length, 0);
  execFileSync('agent', ['kill', name, '--force'], { env: fx.env, stdio: 'ignore' });
  const c = await t.closed;
  assert.equal(c.code, 1000);
  assert.equal(t.msgs.length, 1);
  assert.equal(t.msgs[0].type, 'exit');
  assert.equal(typeof t.msgs[0].code, 'number');
  assert.ok(!hasSession(`${name}@1`) && !hasSession(name));
});

test('an unknown session closes with 4404 before any data, and a name never reaches a shell', async () => {
  const srv = await server();
  const mark = path.join(fx.root, 'pwned');
  for (const name of ['no-such-session', `x;touch ${mark}`, `$(touch ${mark})`, `${TAG}-1@1`]) {
    const t = await term(srv, name);
    const c = await t.closed;
    assert.equal(c.code, 4404, name);
    assert.equal(t.bytes(), 0, name);
    assert.equal(t.msgs.length, 0, name);
  }
  assert.ok(!existsSync(mark));
});

test('a bad Origin is refused at the handshake', async () => {
  const srv = await server();
  const name = newSession();
  await assert.rejects(srv.ws(`/api/sessions/${name}/term`, { origin: 'https://evil.example' }), { status: 403 });
  await assert.rejects(srv.ws(`/api/sessions/${name}/term`, { origin: null }), { status: 403 });
  assert.ok(!hasSession(`${name}@1`));
});

test('terminals beyond the cap are refused with 503', async () => {
  const { limits } = await import('../../web/lib/term.mjs');
  const srv = await server({}, { inProcess: true });
  const name = newSession();
  const max = limits.max;
  limits.max = 2;
  try {
    const a = await term(srv, name);
    const b = await term(srv, name);
    await assert.rejects(srv.ws(`/api/sessions/${name}/term`), { status: 503 });
    a.ws.close();
    await a.closed;
    // The slot frees when the bridge exits, not when the socket closes.
    const { terminalCount } = await import('../../web/lib/term.mjs');
    await waitFor(() => terminalCount() === 1);
    const c = await term(srv, name);
    b.ws.close();
    c.ws.close();
    await Promise.all([b.closed, c.closed]);
  } finally {
    limits.max = max;
  }
});

test('a client that stops answering pings is dropped and its view removed', async () => {
  const { limits } = await import('../../web/lib/term.mjs');
  const srv = await server({}, { inProcess: true });
  const name = newSession();
  const ping = limits.pingMs;
  limits.pingMs = 200;
  try {
    const t = await term(srv, name);
    await waitFor(() => hasSession(`${name}@1`));
    // A paused socket reads nothing, so the server's pings go unanswered.
    t.ws._socket.pause();
    await waitFor(() => !hasSession(`${name}@1`), { timeout: 3000 });
    assert.ok(hasSession(name));
    t.ws.terminate();
  } finally {
    limits.pingMs = ping;
  }
});

test('SIGTERM to the server hangs up every bridge', async () => {
  const srv = await startServer();
  const name = newSession();
  const a = await term(srv, name);
  const b = await term(srv, name);
  await waitFor(() => hasSession(`${name}@1`) && hasSession(`${name}@2`));
  const r = await srv.stop('SIGTERM');
  assert.equal(r.code, 0);
  await Promise.all([a.closed, b.closed]);
  await waitFor(() => !hasSession(`${name}@1`) && !hasSession(`${name}@2`), { timeout: 2000 });
  assert.ok(hasSession(name));
  assert.equal(bridgesLeft(), '');
});
