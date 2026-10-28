// tests/web/auth.test.mjs: T2, the server skeleton. The security rules of docs/web-dashboard-plan.md section 2
// (loopback, login, POST guard, WebSocket Origin, headers, body caps), static and vendor files, startup and
// shutdown. Most cases use one child-process server, as systemd runs it; the stub routes (a POST echo, a raw
// upload sink, a WS echo) only exist in an in-process server, added through addRoute.

import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { after, before, describe, test } from 'node:test';
import { ALLOWED, SERVER, fixture, startServer } from './helpers.mjs';
import { addRoute, createServer, readBody, readJson } from '../../web/server.mjs';
import { isLoopback, parseAllow } from '../../web/lib/auth.mjs';

const CSP = "default-src 'self'; connect-src 'self'; img-src 'self' data:";

function assertSecurityHeaders(r) {
  assert.equal(r.headers['content-security-policy'], CSP);
  assert.equal(r.headers['x-frame-options'], 'DENY');
}

describe('child-process server', () => {
  let s;
  before(async () => {
    s = await startServer({ AGENT_WEB_ALLOW: `someone@example.test, ${ALLOWED}` });
  });
  after(() => s.stop());

  test('no login header is 403', async () => {
    const r = await s.req('/api/health', { login: null });
    assert.equal(r.status, 403);
    assert.deepEqual(r.json, { error: 'forbidden' });
  });

  test('a browser without a login gets the 403 page', async () => {
    const r = await s.req('/', { login: null, headers: { Accept: 'text/html' } });
    assert.equal(r.status, 403);
    assert.match(r.headers['content-type'], /^text\/html/);
    assert.match(r.text, /403 Forbidden/);
    assertSecurityHeaders(r);
  });

  test('a login not in the list is 403', async () => {
    assert.equal((await s.req('/api/health', { login: 'mallory@example.test' })).status, 403);
    assert.equal((await s.req('/', { login: 'mallory@example.test' })).status, 403);
  });

  test('a repeated login header is 403', async () => {
    // Node joins repeats with ", "; two allowed logins together are still not one login.
    const r = await s.req('/api/health', { login: `someone@example.test, ${ALLOWED}` });
    assert.equal(r.status, 403);
  });

  test('an allowed login gets /api/health and /api/me', async () => {
    const h = await s.req('/api/health');
    assert.equal(h.status, 200);
    assert.deepEqual(h.json, { ok: true });
    const me = await s.req('/api/me');
    assert.equal(me.status, 200);
    assert.deepEqual(me.json, { login: ALLOWED });
    const other = await s.req('/api/me', { login: 'someone@example.test' });
    assert.deepEqual(other.json, { login: 'someone@example.test' });
  });

  test('security headers on every kind of answer', async () => {
    for (const r of [
      await s.req('/api/health'),
      await s.req('/api/health', { login: null }),
      await s.req('/api/nosuch'),
      await s.req('/'),
      await s.req('/vendor/xterm.css'),
    ]) assertSecurityHeaders(r);
  });

  test('a POST without X-Agent-Web is 403', async () => {
    const r = await s.req('/api/health', { body: {}, headers: { 'X-Agent-Web': null } });
    assert.equal(r.status, 403);
  });

  test('a POST that is not JSON is 403', async () => {
    const r = await s.req('/api/health', { body: 'a=1', headers: { 'Content-Type': 'application/x-www-form-urlencoded' } });
    assert.equal(r.status, 403);
    const t = await s.req('/api/health', { body: '{}', headers: { 'Content-Type': 'text/plain' } });
    assert.equal(t.status, 403);
  });

  test('other methods are refused', async () => {
    for (const method of ['PUT', 'DELETE', 'PATCH']) {
      assert.equal((await s.req('/api/health', { method, body: {} })).status, 403, method);
    }
  });

  test('a guarded POST to an unknown route is 404', async () => {
    assert.equal((await s.req('/api/nosuch', { body: {} })).status, 404);
  });

  test('the page and the four vendor files', async () => {
    const index = await s.req('/');
    assert.equal(index.status, 200);
    assert.match(index.headers['content-type'], /^text\/html/);
    const x = await s.req('/vendor/xterm.mjs');
    assert.equal(x.status, 200);
    assert.match(x.headers['content-type'], /^text\/javascript/);
    assert.match(x.text, /export\s*\{/);
    for (const [p, type] of [
      ['/vendor/xterm.css', /^text\/css/],
      ['/vendor/addon-fit.mjs', /^text\/javascript/],
      ['/vendor/addon-clipboard.mjs', /^text\/javascript/],
    ]) {
      const r = await s.req(p);
      assert.equal(r.status, 200, p);
      assert.match(r.headers['content-type'], type, p);
    }
    const head = await s.req('/vendor/xterm.mjs', { method: 'HEAD' });
    assert.equal(head.status, 200);
    assert.equal(head.body.length, 0);
  });

  test('nothing outside web/public and the vendor list', async () => {
    for (const p of [
      '/../package.json',
      '/vendor/../../server.mjs',
      '/%2e%2e/package.json',
      '/..%2fserver.mjs',
      '/vendor/..%2f..%2fserver.mjs',
      '/vendor/xterm.mjs.map',
      '/vendor/',
      '/node_modules/ws/package.json',
      '/server.mjs',
      '/lib/auth.mjs',
      '/index.html%00.js',
      '/..\\server.mjs',
    ]) {
      const r = await s.req(p);
      assert.equal(r.status, 404, p);
      assert.doesNotMatch(r.text, /"name"|import /, p);
    }
  });

  test('one log line per request: method, path, status, ms', async () => {
    await s.req('/api/me');
    const line = s.logs.find((l) => /^GET \/api\/me 200 \d+ms$/.test(l));
    assert.ok(line, s.logs.join('\n'));
  });
});

describe('startup and shutdown', () => {
  test('an empty AGENT_WEB_ALLOW refuses to start with exit 2', async () => {
    for (const allow of ['', ' , ', undefined]) {
      const err = await startServer({ AGENT_WEB_ALLOW: allow }).then(() => null, (e) => e);
      assert.ok(err, `started with AGENT_WEB_ALLOW=${allow}`);
      assert.equal(err.code, 2);
      assert.match(err.stderr, /AGENT_WEB_ALLOW/);
    }
  });

  test('a bad port refuses to start with exit 2', async () => {
    const err = await startServer({ AGENT_WEB_PORT: '70000' }).then(() => null, (e) => e);
    assert.equal(err?.code, 2);
  });

  test('listens on 127.0.0.1 only', async () => {
    const app = createServer({ ...fixture().env }, { log: () => {} });
    const addr = await app.listen();
    try {
      assert.equal(addr.address, '127.0.0.1');
      assert.equal(app.server.address().address, '127.0.0.1');
    } finally {
      await app.close();
    }
  });

  test('SIGTERM exits 0 within 2 s, with a keep-alive connection open', async () => {
    const s = await startServer();
    await s.req('/api/health');   // Node's global agent keeps the connection open afterwards
    const r = await s.stop('SIGTERM');
    assert.equal(r.code, 0);
    assert.ok(r.ms < 2000, `took ${r.ms} ms`);
  });

  test('importing server.mjs does not start it', async () => {
    // Only running it as argv[1] calls main(); the tests and later modules import it.
    const proc = spawn(process.execPath, ['-e', `import(${JSON.stringify(SERVER)}).then(() => console.log('imported'))`],
      { env: fixture().env });
    let out = '';
    proc.stdout.on('data', (c) => { out += c; });
    const code = await new Promise((r) => proc.on('exit', r));
    assert.equal(code, 0);
    assert.equal(out.trim(), 'imported');
  });
});

describe('in-process server with stub routes', () => {
  let s;
  before(async () => {
    addRoute('POST', '/api/echo', async (req) => ({ got: await readJson(req) }));
    addRoute('POST', '/api/sink', async (req) => ({ bytes: (await readBody(req)).length }), { raw: true });
    addRoute('GET', '/api/things/:name', (req, res, ctx) => ({ name: ctx.params.name }));
    addRoute('WS', '/api/echo', async (req, ctx) => {
      if (ctx.query.get('refuse')) {
        const { HttpError } = await import('../../web/server.mjs');
        throw new HttpError(503, 'busy');
      }
      const ws = await ctx.upgrade();
      ws.on('message', (data, binary) => ws.send(data, { binary }));
    });
    s = await startServer({}, { inProcess: true });
  });
  after(() => s.stop());

  test('a guarded JSON POST reaches the route', async () => {
    const r = await s.req('/api/echo', { body: { a: 1 } });
    assert.equal(r.status, 200);
    assert.deepEqual(r.json, { got: { a: 1 } });
  });

  test('the POST guard applies to real routes', async () => {
    assert.equal((await s.req('/api/echo', { body: { a: 1 }, headers: { 'X-Agent-Web': null } })).status, 403);
    assert.equal((await s.req('/api/echo', { body: '{}', headers: { 'Content-Type': 'text/plain' } })).status, 403);
    assert.equal((await s.req('/api/echo', { body: { a: 1 }, login: null })).status, 403);
  });

  test('bad JSON is 400 and a JSON body over 1 MB is 413', async () => {
    const bad = await s.req('/api/echo', { body: '{nope', headers: { 'Content-Type': 'application/json' } });
    assert.equal(bad.status, 400);
    const arr = await s.req('/api/echo', { body: [1] });
    assert.equal(arr.status, 400);
    const big = await s.req('/api/echo', { body: { x: 'a'.repeat(1024 * 1024 + 10) } });
    assert.equal(big.status, 413);
  });

  test('a raw route takes any declared type up to 20 MB', async () => {
    const ok = await s.req('/api/sink', { body: Buffer.alloc(1000), headers: { 'Content-Type': 'image/png' } });
    assert.deepEqual(ok.json, { bytes: 1000 });
    const none = await s.req('/api/sink', { body: Buffer.alloc(10) });
    assert.equal(none.status, 403);
    const big = await s.req('/api/sink', { body: Buffer.alloc(21 * 1024 * 1024), headers: { 'Content-Type': 'image/png' } });
    assert.equal(big.status, 413);
  });

  test('bodies are never logged', async () => {
    await s.req('/api/echo', { body: { secret: 'body-marker-42' } });
    assert.ok(s.logs.some((l) => /^POST \/api\/echo 200 \d+ms$/.test(l)), s.logs.join('\n'));
    assert.ok(!s.logs.join('\n').includes('body-marker-42'));
  });

  test('route parameters arrive decoded', async () => {
    const r = await s.req('/api/things/a%20b');
    assert.deepEqual(r.json, { name: 'a b' });
    assert.equal((await s.req('/api/things/%E0%A4')).status, 400);
  });

  test('a WebSocket with a matching Origin is accepted', async () => {
    const ws = await s.ws('/api/echo');
    const reply = new Promise((r) => ws.once('message', (d) => r(String(d))));
    ws.send('ping');
    assert.equal(await reply, 'ping');
    ws.close();
    assert.ok(s.logs.some((l) => /^WS \/api\/echo 101 \d+ms$/.test(l)), s.logs.join('\n'));
  });

  test('a WebSocket with a mismatched or missing Origin is refused', async () => {
    for (const origin of ['http://evil.example', `http://127.0.0.1:${s.port + 1}`, 'null', null]) {
      const err = await s.ws('/api/echo', { origin }).then(() => null, (e) => e);
      assert.equal(err?.status, 403, String(origin));
    }
  });

  test('a WebSocket without an allowed login is refused', async () => {
    assert.equal((await s.ws('/api/echo', { login: null }).catch((e) => e)).status, 403);
    assert.equal((await s.ws('/api/echo', { login: 'mallory@example.test' }).catch((e) => e)).status, 403);
  });

  test('a WebSocket handler can refuse with a status, and unknown paths are 404', async () => {
    assert.equal((await s.ws('/api/echo?refuse=1').catch((e) => e)).status, 503);
    assert.equal((await s.ws('/api/nosuch').catch((e) => e)).status, 404);
  });

  test('shutdown closes open WebSockets (runs last: it stops this server)', async () => {
    const ws = await s.ws('/api/echo');
    const closed = new Promise((r) => ws.once('close', r));
    const t0 = Date.now();
    await s.stop();
    await closed;
    assert.ok(Date.now() - t0 < 2000);
  });
});

describe('auth helpers', () => {
  test('isLoopback', () => {
    for (const a of ['127.0.0.1', '127.1.2.3', '::1', '::ffff:127.0.0.1']) assert.ok(isLoopback(a), a);
    for (const a of ['100.64.0.2', '192.168.1.5', '::ffff:10.0.0.1', 'fe80::1', '', undefined, '127.0.0.1.evil']) {
      assert.ok(!isLoopback(a), String(a));
    }
  });

  test('parseAllow drops empty entries', () => {
    assert.deepEqual([...parseAllow(' a@x ,, b@y ,')], ['a@x', 'b@y']);
    assert.equal(parseAllow('').size, 0);
    assert.equal(parseAllow(undefined).size, 0);
  });
});
