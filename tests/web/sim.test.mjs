// tests/web/sim.test.mjs: T9, GET /api/sim. A stand-in `sim` in the fixture's bin prints the captured
// `sim status --json` (tests/web/fixtures/sim-status.json: three Android and two web slots), or exits 1, or is not
// there at all. The server's PATH is the fixture bin and the system directories only, so the host's real sim
// (~/.local/bin) is never run. The server looks sim up on its PATH per request, so the cases swap the stand-in
// under one server.

import assert from 'node:assert/strict';
import { readFileSync, rmSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { after, before, describe, test } from 'node:test';
import { fixture, REPO, startServer } from './helpers.mjs';
import { simStatus } from '../../web/lib/sim.mjs';

const FIXTURE = path.join(REPO, 'tests/web/fixtures/sim-status.json');
const slots = JSON.parse(readFileSync(FIXTURE, 'utf8'));

describe('sim API', () => {
  let s;
  let fx;
  let stub;
  let env;
  const standIn = (body) => writeFileSync(stub, `#!/bin/sh\n${body}\n`, { mode: 0o755 });

  before(async () => {
    fx = fixture();
    stub = path.join(fx.bin, 'sim');
    env = { PATH: `${fx.bin}:/usr/bin:/bin` };
    s = await startServer(env);
  });
  after(() => s.stop());

  test('the fixture is the captured shape: three Android and two web slots', () => {
    assert.deepEqual(slots.map((x) => `${x.platform} ${x.slot}`),
      ['android 1', 'android 2', 'android 3', 'web 1', 'web 2']);
    for (const x of slots) {
      assert.deepEqual(Object.keys(x).sort(), ['device', 'idle_secs', 'lease', 'platform', 'slot', 'state', 'tunnel']);
    }
  });

  test('a sim that prints its status gives the slots unchanged', async () => {
    standIn(`[ "$*" = "status --json" ] || exit 9\ncat '${FIXTURE}'`);
    const r = await s.req('/api/sim');
    assert.equal(r.status, 200, r.text);
    assert.deepEqual(r.json, { available: true, slots });
  });

  test('a sim that exits 1 is unavailable', async () => {
    standIn(`cat '${FIXTURE}'\nexit 1`);
    const r = await s.req('/api/sim');
    assert.equal(r.status, 200, r.text);
    assert.deepEqual(r.json, { available: false });
  });

  test('no sim on PATH is unavailable', async () => {
    rmSync(stub, { force: true });
    const r = await s.req('/api/sim');
    assert.equal(r.status, 200, r.text);
    assert.deepEqual(r.json, { available: false });
  });

  test('output that is not a slot list is unavailable', async () => {
    for (const out of ['not json', '{"contract":3}', '"x"']) {
      standIn(`echo '${out}'`);
      assert.deepEqual((await s.req('/api/sim')).json, { available: false }, out);
    }
  });

  test('an object wrapper with a slots array is unwrapped', async () => {
    writeFileSync(path.join(fx.root, 'wrapped.json'), JSON.stringify({ contract: 3, slots }));
    standIn(`cat '${path.join(fx.root, 'wrapped.json')}'`);
    assert.deepEqual((await s.req('/api/sim')).json, { available: true, slots });
  });

  test('$SIM_BIN wins over PATH', async () => {
    standIn('exit 1');
    const other = path.join(fx.root, 'sim-elsewhere');
    writeFileSync(other, `#!/bin/sh\ncat '${FIXTURE}'\n`, { mode: 0o755 });
    const s2 = await startServer({ ...env, SIM_BIN: other });
    try {
      assert.deepEqual((await s2.req('/api/sim')).json, { available: true, slots });
    } finally {
      await s2.stop();
    }
  });

  test('a sim that does not answer in time is unavailable, and concurrent calls share one run', async () => {
    const count = path.join(fx.root, 'sim-runs');
    // Not exec: the sleep is a grandchild holding stdout open, as sim's ssh to the Mac would be.
    standIn(`echo x >> '${count}'\nsleep 5\necho late`);
    const e = { ...fx.env, ...env };
    const t0 = Date.now();
    const [a, b] = await Promise.all([simStatus(e, { timeout: 300 }), simStatus(e, { timeout: 300 })]);
    assert.deepEqual(a, { available: false });
    assert.deepEqual(b, { available: false });
    assert.ok(Date.now() - t0 < 3000, `took ${Date.now() - t0} ms`);
    assert.equal(readFileSync(count, 'utf8'), 'x\n');
  });

  test('the route needs an allowed login like every other', async () => {
    const r = await s.req('/api/sim', { login: null });
    assert.notEqual(r.status, 200);
  });
});
