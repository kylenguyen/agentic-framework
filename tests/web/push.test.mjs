// tests/web/push.test.mjs: T10's Web Push (web/lib/push.mjs). A plain-HTTP sink on loopback stands in for the push
// service; the subscription's keys are a real P-256 pair and auth secret made here, as a browser would.

import assert from 'node:assert/strict';
import { createECDH, randomBytes } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs';
import http from 'node:http';
import { createRequire } from 'node:module';
import os from 'node:os';
import path from 'node:path';
import { after, before, describe, test } from 'node:test';
import { createPush, FALLBACK_SUBJECT, TTL } from '../../web/lib/push.mjs';
import { fixture, startServer, WEB } from './helpers.mjs';

function clientKeys() {
  const ecdh = createECDH('prime256v1');
  ecdh.generateKeys();
  return { p256dh: ecdh.getPublicKey().toString('base64url'), auth: randomBytes(16).toString('base64url') };
}

// Answers each POST with the status `next` holds for its path (201 by default), and records it.
function sink() {
  const s = { hits: [], status: {} };
  s.server = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      s.hits.push({ method: req.method, url: req.url, headers: req.headers, body: Buffer.concat(chunks) });
      res.writeHead(s.status[req.url] ?? 201);
      res.end();
    });
  });
  return new Promise((resolve) => s.server.listen(0, '127.0.0.1', () => {
    s.base = `http://127.0.0.1:${s.server.address().port}`;
    resolve(s);
  }));
}

const mode = (p) => statSync(p).mode & 0o777;

describe('push store and send', () => {
  let dir;
  let sk;
  before(async () => {
    dir = path.join(mkdtempSync(path.join(os.tmpdir(), 'aw-push-')), 'state');
    sk = await sink();
  });
  after(() => {
    sk.server.close();
    rmSync(path.dirname(dir), { recursive: true, force: true });
  });

  test('VAPID keys are made once, in a 700 directory and a 600 file', () => {
    const p = createPush(dir);
    const k = p.keys();
    assert.match(k.publicKey, /^[A-Za-z0-9_-]{80,}$/);
    assert.deepEqual(createPush(dir).keys(), k);
    assert.equal(mode(dir), 0o700);
    assert.equal(mode(path.join(dir, 'vapid.json')), 0o600);
    assert.equal(p.subject(), FALLBACK_SUBJECT);
  });

  test('subscriptions are kept once per endpoint in a 600 file; bad ones are refused', () => {
    const p = createPush(dir);
    const keys = clientKeys();
    p.subscribe({ endpoint: `${sk.base}/a`, keys, expirationTime: null }, 'http://127.0.0.1:7690');
    p.subscribe({ endpoint: `${sk.base}/a`, keys }, 'http://127.0.0.1:7690');
    p.subscribe({ endpoint: `${sk.base}/b`, keys: clientKeys() });
    assert.deepEqual(p.list().map((s) => s.endpoint), [`${sk.base}/a`, `${sk.base}/b`]);
    assert.deepEqual(Object.keys(p.list()[0]).sort(), ['endpoint', 'keys']);
    assert.equal(mode(path.join(dir, 'subscriptions.json')), 0o600);
    assert.equal(p.subject(), FALLBACK_SUBJECT, 'an http Origin is not a subject');
    for (const bad of [
      { endpoint: 'http://push.example.test/x', keys },
      { endpoint: 'file:///etc/passwd', keys },
      { endpoint: `${sk.base}/c` },
      { endpoint: `${sk.base}/c`, keys: { p256dh: 'a b', auth: 'x' } },
      null,
    ]) {
      assert.throws(() => p.subscribe(bad), (e) => e.status === 400, JSON.stringify(bad));
    }
    assert.equal(p.unsubscribe(`${sk.base}/b`), 1);
    assert.equal(p.list().length, 1);
  });

  test('the first https Origin becomes the subject', () => {
    const p = createPush(dir);
    p.subscribe({ endpoint: `${sk.base}/a`, keys: clientKeys() }, 'https://host.tailnet.example.test');
    p.subscribe({ endpoint: `${sk.base}/a`, keys: clientKeys() }, 'https://other.example.test');
    assert.equal(p.subject(), 'https://host.tailnet.example.test');
  });

  test('a send reaches the endpoint encrypted, with TTL and VAPID; a 410 removes the subscription', async () => {
    const sent = [];
    const webpush = createRequire(path.join(WEB, 'package.json'))('web-push');
    const p = createPush(dir, {
      send: (sub, body, opts) => {
        sent.push(sub.endpoint);
        return webpush.sendNotification(sub, body, opts);
      },
    });
    p.subscribe({ endpoint: `${sk.base}/gone`, keys: clientKeys() });
    sk.status['/gone'] = 410;
    sk.hits.length = 0;
    const r = await p.sendAll({ title: 'demo needs you', body: 'permission · claude', url: '/#/s/demo', tag: 'demo' });
    assert.deepEqual(r, { sent: 1, removed: 1, failed: 0 });
    assert.deepEqual(sent.sort(), [`${sk.base}/a`, `${sk.base}/gone`]);
    const hit = sk.hits.find((h) => h.url === '/a');
    assert.equal(hit.method, 'POST');
    assert.equal(hit.headers['content-encoding'], 'aes128gcm');
    assert.equal(hit.headers.ttl, String(TTL));
    assert.equal(TTL, 3600);
    assert.match(hit.headers.authorization, /^vapid t=[\w-]+\.[\w-]+\.[\w-]+, k=[\w-]+$/);
    assert.ok(!hit.body.includes('demo needs you'), 'the payload is encrypted');
    assert.deepEqual(p.list().map((s) => s.endpoint), [`${sk.base}/a`]);
    assert.equal(mode(path.join(dir, 'subscriptions.json')), 0o600);
  });

  test('a push service error other than 404/410 keeps the subscription', async () => {
    const p = createPush(dir);
    sk.status['/a'] = 500;
    const r = await p.sendAll({ title: 't' });
    delete sk.status['/a'];
    assert.deepEqual(r, { sent: 0, removed: 0, failed: 1 });
    assert.equal(p.list().length, 1);
  });
});

describe('push routes', () => {
  let s;
  let sk;
  let state;
  before(async () => {
    state = fixture().env.AGENT_WEB_STATE;
    sk = await sink();
    s = await startServer();
  });
  after(async () => {
    await s.stop();
    sk.server.close();
  });

  test('keys exist from the first start; /api/push/key serves the public one', async () => {
    const vapid = JSON.parse(readFileSync(path.join(state, 'vapid.json'), 'utf8'));
    const r = await s.req('/api/push/key');
    assert.equal(r.status, 200);
    assert.deepEqual(r.json, { publicKey: vapid.publicKey });
    assert.equal(mode(state), 0o700);
  });

  test('test with no subscription is a 409', async () => {
    const r = await s.req('/api/push/test', { body: {} });
    assert.equal(r.status, 409);
  });

  test('subscribe, test reaches the sink, unsubscribe', async () => {
    const endpoint = `${sk.base}/route`;
    let r = await s.req('/api/push/subscribe', { body: { endpoint, keys: clientKeys() }, headers: { origin: s.url } });
    assert.equal(r.status, 200, r.text);
    assert.equal(r.json.count, 1);
    r = await s.req('/api/push/subscribe', { body: { endpoint: 'http://push.example.test/', keys: clientKeys() } });
    assert.equal(r.status, 400);
    r = await s.req('/api/push/test', { body: {} });
    assert.equal(r.status, 200, r.text);
    assert.deepEqual(r.json, { sent: 1, removed: 0, failed: 0 });
    assert.equal(sk.hits.at(-1).url, '/route');
    r = await s.req('/api/push/unsubscribe', { body: { endpoint } });
    assert.deepEqual(r.json, { ok: true, removed: 1 });
    assert.deepEqual(JSON.parse(readFileSync(path.join(state, 'subscriptions.json'), 'utf8')), []);
  });

  test('a rising edge from a hook pushes once', async () => {
    const endpoint = `${sk.base}/edge`;
    await s.req('/api/push/subscribe', { body: { endpoint, keys: clientKeys() } });
    const { execFileSync } = await import('node:child_process');
    const ag = (...args) => execFileSync('agent', args, { env: fixture().env, encoding: 'utf8' }).trim();
    const name = ag('new', 'demo', '--harness', 'shell', '--no-attach').split('\n').at(-1);
    await new Promise((r) => setTimeout(r, 2500));   // a poll that sees it with no attention
    const before = sk.hits.filter((h) => h.url === '/edge').length;
    ag('attention', 'set', '--reason', 'permission', '--source', 'claude', name);
    const end = Date.now() + 8000;
    while (Date.now() < end && sk.hits.filter((h) => h.url === '/edge').length === before) {
      await new Promise((r) => setTimeout(r, 100));
    }
    await new Promise((r) => setTimeout(r, 4500));   // two more polls: no second push
    assert.equal(sk.hits.filter((h) => h.url === '/edge').length - before, 1);
  });
});
