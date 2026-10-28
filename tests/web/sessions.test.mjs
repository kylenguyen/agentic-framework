// tests/web/sessions.test.mjs: T4, the session and repo routes (list, repos, create, worktree status, kill)
// against a real tmux on the test socket and the fixture's throwaway ~/workspace. One child-process server, as
// systemd runs it; the cases run in order and build on each other's sessions.

import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { after, before, describe, test } from 'node:test';
import { fixture, startServer } from './helpers.mjs';
import { runCommand } from '../../web/lib/agent.mjs';

const enc = encodeURIComponent;

describe('sessions API', () => {
  let s;
  let fx;
  const git = (dir, ...args) => execFileSync('git', ['-C', dir, ...args], { env: fx.env, encoding: 'utf8' }).trim();
  const names = async () => (await s.req('/api/sessions')).json.map((x) => x.name);
  const create = (body) => s.req('/api/sessions', { body });

  before(async () => {
    fx = fixture();
    // Not repos: a worktree folder with a .git inside, and a plain directory.
    mkdirSync(path.join(fx.workspace, 'other.wt/.git'), { recursive: true });
    mkdirSync(path.join(fx.workspace, 'plain'), { recursive: true });
    s = await startServer();
  });
  after(() => s.stop());

  test('no sessions and no tmux server is an empty list', async () => {
    const r = await s.req('/api/sessions');
    assert.equal(r.status, 200);
    assert.deepEqual(r.json, []);
  });

  test('create a shell session in the main checkout', async () => {
    const r = await create({ repo: 'demo', harness: 'shell' });
    assert.equal(r.status, 200, r.text);
    assert.deepEqual(r.json, { name: 'demo' });
    const list = (await s.req('/api/sessions')).json;
    const demo = list.find((x) => x.name === 'demo');
    assert.ok(demo, JSON.stringify(list));
    assert.equal(demo.harness, 'shell');
    assert.equal(demo.worktree, false);
  });

  test('a second session in the same repo gets a fresh name', async () => {
    const r = await create({ repo: 'demo', harness: 'claude' });
    assert.equal(r.status, 200, r.text);
    assert.equal(r.json.name, 'demo-2');
  });

  test('a slug makes the worktree and its branch', async () => {
    const r = await create({ repo: 'demo', harness: 'shell', slug: 'x' });
    assert.equal(r.status, 200, r.text);
    assert.equal(r.json.name, 'demo-x');
    assert.ok(existsSync(path.join(fx.workspace, 'demo.wt/x')));
    assert.equal(git(fx.demo, 'rev-parse', '--verify', '-q', 'refs/heads/agent/x').length, 40);
    assert.ok((await names()).includes('demo-x'));
  });

  test('bad input is a 400 and creates nothing', async () => {
    const before = await names();
    const cases = [
      [{ repo: '../etc', harness: 'shell' }, /repo/],
      [{ repo: '..', harness: 'shell' }, /repo/],
      [{ repo: 'demo.wt', harness: 'shell' }, /repo/],
      [{ repo: 'other.wt', harness: 'shell' }, /repo/],
      [{ repo: 'plain', harness: 'shell' }, /no such repo/],
      [{ repo: 'missing', harness: 'shell' }, /no such repo/],
      [{ repo: ['demo'], harness: 'shell' }, /repo/],
      [{ harness: 'shell' }, /repo/],
      [{ repo: 'demo', harness: 'bash' }, /harness/],
      [{ repo: 'demo' }, /harness/],
      [{ repo: 'demo', harness: 'shell', slug: 'X Y' }, /slug/],
      [{ repo: 'demo', harness: 'shell', slug: '-x' }, /slug/],
      [{ repo: 'demo', harness: 'shell', slug: 'a'.repeat(42) }, /slug/],
      [{ repo: 'demo', harness: 'shell', slug: 7 }, /slug/],
    ];
    for (const [body, err] of cases) {
      const r = await create(body);
      assert.equal(r.status, 400, `${JSON.stringify(body)}: ${r.text}`);
      assert.match(r.json.error, err, JSON.stringify(body));
    }
    assert.deepEqual(await names(), before);
  });

  test('a branch checked out elsewhere is a 409', async () => {
    const busy = path.join(fx.workspace, 'busy');
    mkdirSync(busy);
    git(busy, 'init', '-q', '-b', 'agent/held');
    git(busy, '-c', 'user.email=t@example', '-c', 'user.name=t', 'commit', '-q', '--allow-empty', '-m', 'init');
    const r = await create({ repo: 'busy', harness: 'shell', slug: 'held' });
    assert.equal(r.status, 409, r.text);
    assert.match(r.json.error, /worktree add failed/);
  });

  test('/api/repos lists git dirs directly under ~/workspace, not *.wt', async () => {
    const r = await s.req('/api/repos');
    assert.equal(r.status, 200);
    assert.deepEqual(r.json, ['busy', 'demo']);
  });

  test('worktree status: none, clean, then dirty with the file', async () => {
    let r = await s.req('/api/sessions/demo/worktree');
    assert.equal(r.status, 200, r.text);
    assert.deepEqual(r.json, { worktree: false, dirty: false, files: [] });

    r = await s.req('/api/sessions/demo-x/worktree');
    assert.deepEqual(r.json, { worktree: true, dirty: false, files: [] });

    writeFileSync(path.join(fx.workspace, 'demo.wt/x/touched.txt'), 'x\n');
    r = await s.req('/api/sessions/demo-x/worktree');
    assert.deepEqual(r.json, { worktree: true, dirty: true, files: ['?? touched.txt'] });
  });

  test('worktree status lists at most 50 files', async () => {
    const r0 = await create({ repo: 'demo', harness: 'shell', slug: 'many' });
    assert.equal(r0.status, 200, r0.text);
    const dir = path.join(fx.workspace, 'demo.wt/many');
    for (let i = 0; i < 60; i++) writeFileSync(path.join(dir, `f${String(i).padStart(2, '0')}.txt`), '');
    const r = await s.req('/api/sessions/demo-many/worktree');
    assert.equal(r.json.dirty, true);
    assert.equal(r.json.files.length, 50);
  });

  test('kill without force keeps a dirty worktree', async () => {
    const r = await s.req('/api/sessions/demo-x/kill', { body: {} });
    assert.equal(r.status, 200, r.text);
    assert.match(r.json.output, /^worktree kept: /);
    assert.ok(!(await names()).includes('demo-x'));
    assert.ok(existsSync(path.join(fx.workspace, 'demo.wt/x/touched.txt')));
  });

  test('kill with force removes a dirty worktree and keeps the branch', async () => {
    const r = await s.req('/api/sessions/demo-many/kill', { body: { force: true } });
    assert.equal(r.status, 200, r.text);
    assert.match(r.json.output, /^worktree removed: /);
    assert.ok(!(await names()).includes('demo-many'));
    assert.ok(!existsSync(path.join(fx.workspace, 'demo.wt/many')));
    assert.equal(git(fx.demo, 'rev-parse', '--verify', '-q', 'refs/heads/agent/many').length, 40);
  });

  test('kill with keepWorktree keeps a clean worktree; plain kill removes one', async () => {
    let r = await create({ repo: 'demo', harness: 'shell', slug: 'keep' });
    assert.equal(r.status, 200, r.text);
    r = await s.req('/api/sessions/demo-keep/kill', { body: { keepWorktree: true } });
    assert.equal(r.status, 200, r.text);
    assert.match(r.json.output, /^worktree kept: /);
    assert.ok(existsSync(path.join(fx.workspace, 'demo.wt/keep')));

    r = await create({ repo: 'demo', harness: 'shell', slug: 'clean' });
    assert.equal(r.status, 200, r.text);
    r = await s.req('/api/sessions/demo-clean/kill', { body: {} });
    assert.match(r.json.output, /^worktree removed: /);
    assert.ok(!existsSync(path.join(fx.workspace, 'demo.wt/clean')));
  });

  test('kill in the main checkout leaves it alone', async () => {
    const r = await s.req('/api/sessions/demo-2/kill', { body: {} });
    assert.equal(r.status, 200, r.text);
    assert.equal(r.json.output, '');
    assert.ok(existsSync(fx.demo));
    assert.ok(!(await names()).includes('demo-2'));
  });

  test('an unknown name is a 404', async () => {
    for (const r of [
      await s.req('/api/sessions/nope/worktree'),
      await s.req('/api/sessions/nope/kill', { body: {} }),
      // a view is not a base session, and a prefix of a real name is not that name
      await s.req(`/api/sessions/${enc('demo@1')}/kill`, { body: {} }),
      await s.req('/api/sessions/dem/kill', { body: {} }),
    ]) {
      assert.equal(r.status, 404, r.text);
      assert.match(r.json.error, /no such session/);
    }
    assert.ok((await names()).includes('demo'));
  });

  test('shell characters in names and inputs never execute', async () => {
    const marker = path.join(fx.root, 'pwned');
    const evil = [`x;touch ${marker}`, `$(touch ${marker})`, `\`touch ${marker}\``, `demo;touch ${marker}`,
      `demo && touch ${marker}`, `-x;touch ${marker}`];
    for (const name of evil) {
      const w = await s.req(`/api/sessions/${enc(name)}/worktree`);
      assert.equal(w.status, 404, `${name}: ${w.text}`);
      const k = await s.req(`/api/sessions/${enc(name)}/kill`, { body: { force: true } });
      assert.equal(k.status, 404, `${name}: ${k.text}`);
      const c1 = await create({ repo: name, harness: 'shell' });
      assert.equal(c1.status, 400, `${name}: ${c1.text}`);
      const c2 = await create({ repo: 'demo', harness: name });
      assert.equal(c2.status, 400, `${name}: ${c2.text}`);
      const c3 = await create({ repo: 'demo', harness: 'shell', slug: name });
      assert.equal(c3.status, 400, `${name}: ${c3.text}`);
    }
    assert.ok(!existsSync(marker), 'marker file appeared');
    assert.ok((await names()).includes('demo'));
  });

  test('state-changing routes keep the POST guard', async () => {
    const r = await s.req('/api/sessions', { body: { repo: 'demo', harness: 'shell' }, headers: { 'X-Agent-Web': null } });
    assert.equal(r.status, 403);
    const k = await s.req('/api/sessions/demo/kill', { body: {}, headers: { 'X-Agent-Web': null } });
    assert.equal(k.status, 403);
    assert.ok((await names()).includes('demo'));
  });
});

describe('runCommand', () => {
  // A plain kill on a dirty worktree must not wait on a question nobody can answer, even when the server was
  // started from a terminal (run this file under `script` to see the difference).
  test('children have no controlling terminal', async () => {
    const r = await runCommand('sh', ['-c', '(exec 3<>/dev/tty) 2>/dev/null && echo tty || echo notty'], fixture().env);
    assert.equal(r.stdout.trim(), 'notty');
  });

  test('a timeout kills the child and says so', async () => {
    const r = await runCommand('sleep', ['5'], fixture().env, { timeout: 200 });
    assert.equal(r.timedOut, true);
    assert.notEqual(r.code, 0);
  });

  test('a missing program is a failure, not a throw', async () => {
    const r = await runCommand('no-such-program-aw', [], fixture().env);
    assert.equal(r.code, null);
    assert.match(r.stderr, /ENOENT/);
  });
});
