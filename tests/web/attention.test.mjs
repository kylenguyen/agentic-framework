// tests/web/attention.test.mjs: T10's needs-input detection. The state machine (web/lib/attention.mjs) runs on a
// fake clock against hand-made `agent ls --json` lists; the watcher against stub list functions; then a child
// server on the test tmux socket with AGENT_WEB_QUIET_SECS=1 shows the same on real sessions, and /seen.

import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { describe, test } from 'node:test';
import { createAttention, createWatcher, HARNESS_ALERTS, pushPayload } from '../../web/lib/attention.mjs';
import { fixture, startServer, waitFor } from './helpers.mjs';

const T0 = 1_800_000_000;

function machine(quietSecs = 45) {
  const clock = { t: T0 };
  const raised = [];
  const a = createAttention({ quietSecs, now: () => clock.t, onRaise: (s, att) => raised.push([s.name, att]) });
  return { a, clock, raised };
}

const sess = (o = {}) => ({
  name: 'demo', harness: 'omp', state: 'running', activity: T0, attention: null, ...o,
});
const att = (list, name = 'demo') => list.find((s) => s.name === name).attention;

describe('attention state machine', () => {
  test('codex is watched by the heuristic, claude by its hook, shell by neither', () => {
    assert.equal(HARNESS_ALERTS.codex, 'heuristic');
    assert.equal(HARNESS_ALERTS.claude, 'hook');
    assert.equal(HARNESS_ALERTS.omp, 'heuristic');
    assert.equal(HARNESS_ALERTS.opencode, 'heuristic');
    assert.equal(HARNESS_ALERTS.shell, undefined);
  });

  test('a hook attention passes through, and pushes once per since', () => {
    const { a, clock, raised } = machine();
    a.update([sess({ harness: 'claude' })]);
    const hook = { reason: 'permission', source: 'claude', since: T0 + 1 };
    clock.t += 2;
    assert.deepEqual(att(a.update([sess({ harness: 'claude', attention: hook })])), hook);
    clock.t += 2;
    a.update([sess({ harness: 'claude', attention: hook })]);
    assert.equal(raised.length, 1);
    assert.deepEqual(raised[0], ['demo', hook]);
    const again = { ...hook, since: T0 + 9 };
    a.update([sess({ harness: 'claude', attention: again })]);
    assert.equal(raised.length, 2, 'a new since is a new rising edge');
    a.update([sess({ harness: 'claude' })]);
    a.update([sess({ harness: 'claude', attention: again })]);
    assert.equal(raised.length, 3, 'null then set again is a rising edge');
  });

  test('attention already set at the first poll is shown but not pushed', () => {
    const { a, raised } = machine();
    const hook = { reason: 'done', source: 'claude', since: T0 - 100 };
    assert.deepEqual(att(a.update([sess({ harness: 'claude', attention: hook })])), hook);
    assert.equal(raised.length, 0);
  });

  test('quiet raises only after 45 s of silence that followed activity', () => {
    const { a, clock, raised } = machine();
    const active = T0;
    for (let i = 0; i <= 44; i += 2) {
      clock.t = T0 + i;
      assert.equal(att(a.update([sess({ activity: active })])), null, `at ${i} s`);
    }
    clock.t = T0 + 46;
    const q = att(a.update([sess({ activity: active })]));
    assert.deepEqual(q, { reason: 'quiet', source: 'heuristic', since: T0 + 46 });
    assert.equal(raised.length, 1);
    clock.t = T0 + 120;
    assert.deepEqual(att(a.update([sess({ activity: active })])), q, 'stays raised while silent');
    assert.equal(raised.length, 1, 'one rising edge, one push');
  });

  test('a session that was always idle never raises', () => {
    const { a, clock, raised } = machine();
    for (let i = 0; i < 200; i += 2) {
      clock.t = T0 + 3600 + i;
      assert.equal(att(a.update([sess({ activity: T0 })])), null);
    }
    assert.equal(raised.length, 0);
  });

  test('resumed activity clears, and a new silence raises again', () => {
    const { a, clock, raised } = machine();
    a.update([sess({ activity: T0 })]);
    clock.t = T0 + 50;
    assert.ok(att(a.update([sess({ activity: T0 })])));
    clock.t = T0 + 52;
    assert.equal(att(a.update([sess({ activity: T0 + 51 })])), null);
    clock.t = T0 + 100;
    assert.equal(att(a.update([sess({ activity: T0 + 51 })])).reason, 'quiet');
    assert.equal(raised.length, 2);
  });

  test('shell and claude never get the heuristic', () => {
    for (const harness of ['shell', 'claude']) {
      const { a, clock } = machine();
      a.update([sess({ harness, activity: T0 })]);
      clock.t = T0 + 100;
      assert.equal(att(a.update([sess({ harness, activity: T0 })])), null, harness);
    }
  });

  test('running to exited raises once; exited sessions get no heuristic', () => {
    const { a, clock, raised } = machine();
    a.update([sess({ harness: 'shell' })]);
    clock.t = T0 + 2;
    const e = att(a.update([sess({ harness: 'shell', state: 'exited' })]));
    assert.deepEqual(e, { reason: 'exited', source: 'tmux', since: T0 + 2 });
    for (let i = 0; i < 5; i += 1) {
      clock.t += 2;
      a.update([sess({ harness: 'shell', state: 'exited' })]);
    }
    assert.equal(raised.length, 1);

    const m = machine();
    m.a.update([sess({ state: 'exited', activity: T0 })]);
    m.clock.t = T0 + 100;
    assert.equal(att(m.a.update([sess({ state: 'exited', activity: T0 })])), null, 'exited from the start: nothing');
  });

  test('clear drops quiet and exited until the next rising edge; merge applies what is held', () => {
    const { a, clock, raised } = machine();
    a.update([sess({ activity: T0 })]);
    clock.t = T0 + 50;
    a.update([sess({ activity: T0 })]);
    assert.equal(att(a.merge([sess({ activity: T0 })])).reason, 'quiet');
    a.clear('demo');
    assert.equal(att(a.merge([sess({ activity: T0 })])), null);
    clock.t = T0 + 200;
    assert.equal(att(a.update([sess({ activity: T0 })])), null, 'still silent: not raised again');
    clock.t = T0 + 202;
    a.update([sess({ activity: T0 + 201 })]);
    clock.t = T0 + 260;
    assert.equal(att(a.update([sess({ activity: T0 + 201 })])).reason, 'quiet');
    assert.equal(raised.length, 2);
  });

  test('a session that goes away is forgotten', () => {
    const { a, clock, raised } = machine();
    a.update([sess({ harness: 'shell' })]);
    a.update([]);
    clock.t += 2;
    a.update([sess({ harness: 'shell', state: 'exited' })]);
    assert.equal(raised.length, 0, 'a new session seen exited is not an exit');
  });

  test('the push payload carries only the name, reason and harness', () => {
    const p = pushPayload(sess({ cwd: '/secret', repo: 'r', branch: 'b' }), { reason: 'quiet', source: 'heuristic', since: 1 });
    assert.deepEqual(p, { title: 'demo needs you', body: 'quiet · omp', url: '/#/s/demo', tag: 'demo' });
  });
});

describe('attention watcher', () => {
  test('a tick is skipped while the previous one runs', async () => {
    let calls = 0;
    let release;
    const list = () => {
      calls += 1;
      return new Promise((r) => { release = () => r([]); });
    };
    const w = createWatcher({ list, attention: createAttention(), log: () => {} });
    const first = w.tick();
    assert.equal(await w.tick(), false);
    assert.equal(await w.tick(), false);
    release();
    assert.equal(await first, true);
    assert.equal(calls, 1);
    const next = w.tick();
    release();
    await next;
    assert.equal(calls, 2);
  });

  test('a failing agent ls is logged once and polled again', async () => {
    const logs = [];
    let fail = true;
    const seen = [];
    const attention = { update: (l) => seen.push(l) };
    const w = createWatcher({
      list: async () => {
        if (fail) throw new Error('agent ls failed');
        return [sess()];
      },
      attention,
      log: (l) => logs.push(l),
    });
    await w.tick();
    await w.tick();
    await w.tick();
    assert.equal(logs.length, 1);
    fail = false;
    await w.tick();
    assert.equal(seen.length, 1);
    assert.match(logs.at(-1), /works again/);
  });

  test('start polls on an interval, stop ends it', async () => {
    let calls = 0;
    const w = createWatcher({ list: async () => { calls += 1; return []; }, attention: createAttention(), intervalMs: 20 });
    w.start();
    await waitFor(() => calls >= 3);
    w.stop();
    const n = calls;
    await new Promise((r) => setTimeout(r, 80));
    assert.ok(calls <= n + 1);
  });
});

describe('attention through the server', () => {
  test('quiet, exited and /seen on real sessions', async () => {
    const fx = fixture();
    const s = await startServer({ AGENT_WEB_QUIET_SECS: '1' });
    try {
      const ag = (...args) => execFileSync('agent', args, { env: fx.env, encoding: 'utf8' }).trim();
      const quiet = ag('new', 'demo', '--harness', 'omp', '--no-attach').split('\n').at(-1);
      const shell = ag('new', 'demo', '--harness', 'shell', '--slug', 'sh', '--no-attach').split('\n').at(-1);
      const get = async (name) => (await s.req('/api/sessions')).json.find((x) => x.name === name)?.attention;

      // The stand-in prints nothing after starting: active at the first poll, then silent.
      const q = await waitFor(() => get(quiet), { timeout: 15000, interval: 200 });
      assert.equal(q.reason, 'quiet');
      assert.equal(q.source, 'heuristic');

      let r = await s.req(`/api/sessions/${encodeURIComponent(quiet)}/seen`, { body: {} });
      assert.equal(r.status, 200, r.text);
      assert.equal(await get(quiet), null);
      await new Promise((res) => setTimeout(res, 4500));
      assert.equal(await get(quiet), null, 'seen holds until the window is active again');

      // A hook's attention comes from tmux; /seen clears it there too.
      ag('attention', 'set', '--reason', 'permission', '--source', 'claude', shell);
      assert.equal((await get(shell)).reason, 'permission');
      r = await s.req(`/api/sessions/${encodeURIComponent(shell)}/seen`, { body: {} });
      assert.equal(r.status, 200, r.text);
      assert.equal(await get(shell), null);
      assert.equal(JSON.parse(ag('ls', '--json')).find((x) => x.name === shell).attention, null);

      // End the stand-in: remain-on-exit keeps the session, now exited.
      fx.tm('send-keys', '-t', `=${quiet}:`, 'Enter');
      const e = await waitFor(async () => {
        const a = await get(quiet);
        return a?.reason === 'exited' && a;
      }, { timeout: 10000, interval: 200 });
      assert.equal(e.source, 'tmux');

      assert.equal((await s.req('/api/sessions/nope/seen', { body: {} })).status, 404);
      assert.equal((await s.req(`/api/sessions/${quiet}/seen`, { method: 'GET' })).status, 404);
    } finally {
      await s.stop();
    }
  });
});
