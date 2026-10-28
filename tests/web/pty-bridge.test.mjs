// tests/web/pty-bridge.test.mjs: checks for web/pty-bridge.py, the pty the web terminal runs `agent attach` on.
// node:test only, no tmux, no network. Each case runs the bridge as the server will (stdio pipe x4, fd 3 for
// resizes) on a small sh command. Child processes are tagged with a per-run marker in a `sleep` duration, so
// "nothing left behind" is a pgrep away and never matches anything else on the host.
// Usage: node --test tests/web/pty-bridge.test.mjs
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const BRIDGE = fileURLToPath(new URL('../../web/pty-bridge.py', import.meta.url));
const MARK = `${process.pid}${Date.now() % 100000}`;   // digits only: it rides in a sleep duration

// A failed case must not leave a bridge behind to hold the run open.
const started = new Set();
after(() => { for (const c of started) c.kill('SIGKILL'); });

// bridge(args, {fd3}) starts the bridge; out() is everything on stdout so far, as text; done resolves to
// {code, ms} when it exits.
function bridge(args, { fd3 = true } = {}) {
  const t0 = Date.now();
  const child = spawn('python3', [BRIDGE, ...args], { stdio: fd3 ? ['pipe', 'pipe', 'pipe', 'pipe'] : ['pipe', 'pipe', 'pipe'] });
  started.add(child);
  const chunks = [];
  let err = '';
  child.stdout.on('data', (b) => chunks.push(b));
  child.stderr.on('data', (b) => { err += b; });
  child.stdin.on('error', () => {});
  const done = new Promise((resolve) => child.on('close', (code, signal) => resolve({ code, signal, ms: Date.now() - t0, err })));
  const out = () => Buffer.concat(chunks).toString('latin1');
  return { child, out, done, ctl: fd3 ? child.stdio[3] : null };
}

// until(fn, ms): poll, because the bridge, the pty and the shell are three other processes.
async function until(fn, ms = 5000) {
  const end = Date.now() + ms;
  for (;;) {
    if (fn()) return true;
    if (Date.now() > end) return false;
    await new Promise((r) => setTimeout(r, 25));
  }
}

function leftovers(tag) {
  try {
    return execFileSync('pgrep', ['-f', `^sleep 100.${tag}$`]).toString().trim();
  } catch (e) {
    if (e.status === 1) return '';
    throw e;
  }
}

const lines = (s) => s.split(/\r?\n/);
// line(s, l): l is a whole line of output, allowing for a shell prompt printed in front of it, since the shell
// prints its prompt and our typing echoes back in whatever order they happen.
const line = (s, l) => lines(s).some((x) => x === l || x.endsWith(`$ ${l}`));

test('starts the pty at the size given', async () => {
  const b = bridge(['--cols', '91', '--rows', '33', '--', 'sh', '-c', 'stty size; echo "term=$TERM"'], { fd3: false });
  const r = await b.done;
  assert.equal(r.code, 0);
  assert.ok(lines(b.out()).includes('33 91'), JSON.stringify(b.out()));
  assert.ok(lines(b.out()).includes('term=xterm-256color'), JSON.stringify(b.out()));
});

test('relays stdin to the pty and the pty to stdout', async () => {
  const b = bridge(['--cols', '80', '--rows', '24', '--', 'sh']);
  b.child.stdin.write('echo hi\n');
  assert.ok(await until(() => line(b.out(), 'hi')), JSON.stringify(b.out()));
  b.child.stdin.write('exit\n');
  assert.equal((await b.done).code, 0);
});

test('a "<cols> <rows>" line on fd 3 resizes the pty', async () => {
  const b = bridge(['--cols', '80', '--rows', '24', '--', 'sh']);
  b.ctl.write('120 ');                      // a line split across writes still counts once it is whole
  b.ctl.write('40\nnonsense\n');
  await new Promise((r) => setTimeout(r, 300));
  b.child.stdin.write('stty size\n');
  assert.ok(await until(() => line(b.out(), '40 120')), JSON.stringify(b.out()));
  b.child.stdin.write('exit\n');
  assert.equal((await b.done).code, 0);
});

test('a closed fd 3 changes nothing', async () => {
  const b = bridge(['--cols', '70', '--rows', '20', '--', 'sh']);
  b.ctl.end();
  b.child.stdin.write('stty size\n');
  assert.ok(await until(() => line(b.out(), '20 70')), JSON.stringify(b.out()));
  b.child.stdin.write('exit\n');
  assert.equal((await b.done).code, 0);
});

test("exits with the command's status", async () => {
  const b = bridge(['--', 'sh', '-c', 'exit 7']);
  assert.equal((await b.done).code, 7);
});

test('128+signal when a signal killed the command', async () => {
  const b = bridge(['--', 'sh', '-c', 'kill -TERM $$']);
  assert.equal((await b.done).code, 128 + 15);
});

test('a command that is not there exits 127 with the reason on the terminal', async () => {
  const b = bridge(['--', 'no-such-command-' + MARK]);
  const r = await b.done;
  assert.equal(r.code, 127);
  assert.match(b.out(), /no-such-command-.*No such file/);
});

// The child is sh with a sleep in the background and one in front: SIGHUP must reach the whole group.
const sleeper = (tag, extra = '') => ['--', 'sh', '-c', `${extra}sleep 100.${tag} & sleep 100.${tag}; :`];

test('stdin EOF ends the bridge in under 3 s and leaves no process behind', async () => {
  const tag = `${MARK}1`;
  const b = bridge(sleeper(tag));
  assert.ok(await until(() => leftovers(tag).split('\n').length === 2), 'both sleeps started');
  b.child.stdin.end();
  const r = await b.done;
  assert.ok(r.ms < 3000, `took ${r.ms} ms`);
  assert.equal(r.code, 128 + 1);
  assert.equal(leftovers(tag), '');
});

test('SIGTERM ends the bridge in under 3 s and leaves no process behind', async () => {
  const tag = `${MARK}2`;
  const b = bridge(sleeper(tag));
  assert.ok(await until(() => leftovers(tag).split('\n').length === 2), 'both sleeps started');
  b.child.kill('SIGTERM');
  const r = await b.done;
  assert.ok(r.ms < 3000, `took ${r.ms} ms`);
  assert.equal(leftovers(tag), '');
});

test('SIGHUP does the same', async () => {
  const tag = `${MARK}3`;
  const b = bridge(sleeper(tag));
  assert.ok(await until(() => leftovers(tag) !== ''), 'sleep started');
  b.child.kill('SIGHUP');
  const r = await b.done;
  assert.ok(r.ms < 3000, `took ${r.ms} ms`);
  assert.equal(leftovers(tag), '');
});

test('a group that ignores SIGHUP is killed after the 2 s grace', async () => {
  const tag = `${MARK}4`;
  const b = bridge(sleeper(tag, 'trap "" HUP; '));
  assert.ok(await until(() => leftovers(tag).split('\n').length === 2), 'both sleeps started');
  const t0 = Date.now();
  b.child.kill('SIGTERM');
  const r = await b.done;
  const ms = Date.now() - t0;
  assert.ok(ms >= 1900 && ms < 3500, `took ${ms} ms`);
  assert.equal(r.code, 128 + 9);
  assert.ok(await until(() => leftovers(tag) === '', 1000), 'no sleep left');
});

// od of 1 MB: `-v` so od does not fold the zeros into `*`, 16 bytes a line, so 62500 lines then the end offset.
const odCheck = (text) => {
  const ls = lines(text).filter((l) => l !== '');
  assert.equal(ls.length, 62501, `got ${ls.length} lines`);
  assert.equal(ls[ls.length - 1], '3641100');   // 1000000 in octal
};

test('1 MB of output arrives complete', async () => {
  const b = bridge(['--', 'sh', '-c', 'head -c 1000000 /dev/zero | od'], { fd3: false });
  assert.equal((await b.done).code, 0);
  assert.deepEqual(lines(b.out()).filter((l) => l !== ''), ['0000000 000000 000000 000000 000000 000000 000000 000000 000000', '*', '3641100']);
  const v = bridge(['--', 'sh', '-c', 'head -c 1000000 /dev/zero | od -v'], { fd3: false });
  assert.equal((await v.done).code, 0);
  odCheck(v.out());
});

test('a slow reader slows the command down instead of losing output', async () => {
  const b = bridge(['--', 'sh', '-c', 'head -c 1000000 /dev/zero | od -v'], { fd3: false });
  b.child.stdout.pause();
  await new Promise((r) => setTimeout(r, 1000));
  // Paused for a second: the command must still be running, blocked on a full pty.
  assert.equal(b.child.exitCode, null, 'bridge still running');
  const other = bridge(['--', 'true']);   // a second bridge meanwhile is unaffected
  assert.equal((await other.done).code, 0);
  b.child.stdout.resume();
  assert.equal((await b.done).code, 0);
  odCheck(b.out());
});
