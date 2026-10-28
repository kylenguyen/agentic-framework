// tests/web/upload.test.mjs: T8, POST /api/sessions/:name/upload (web/lib/upload.mjs) against the fixture's spools:
// a PNG through the working tree's bin/clip-put into the test CLIP_BRIDGE_SPOOL, any other file into the test
// AGENT_WEB_FILES, and every refusal (415, 413, 404, 403). Never the operator's ~/.clip.
// Usage: bash tests/web-test.sh upload
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import {
  existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, readlinkSync, statSync, utimesSync, writeFileSync,
} from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { after, before, describe, test } from 'node:test';
import { fixture, startServer } from './helpers.mjs';
import { sanitiseName } from '../../web/lib/upload.mjs';

const fx = fixture();
const SPOOL = path.dirname(fx.env.CLIP_BRIDGE_SPOOL);
const FILES = fx.env.AGENT_WEB_FILES;
const NAME = `t8${process.pid}`;
// A real 1x1 PNG, so clip-put's own signature check sees what a browser would send.
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==', 'base64');
const JPEG = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0, 16, 0x4a, 0x46, 0x49, 0x46, 0, 1]);
const url = `/api/sessions/${NAME}/upload`;
const ls = (dir) => (existsSync(dir) ? readdirSync(dir).filter((n) => !n.startsWith('.')).sort() : []);
const mode = (p) => statSync(p).mode & 0o777;

describe('upload API', () => {
  let s;
  const up = (body, type, name, headers = {}) => s.req(url, {
    body, headers: { 'content-type': type, ...(name === undefined ? {} : { 'x-file-name': name }), ...headers },
  });

  before(async () => {
    execFileSync('agent', ['new', 'demo', '--harness', 'shell', '--name', NAME, '--no-attach'],
      { env: { ...fx.env, SHELL: '/bin/sh' }, encoding: 'utf8' });
    s = await startServer();
  });
  after(() => s.stop());

  test('a PNG goes through clip-put into the test spool, content intact', async () => {
    const r = await up(PNG, 'image/png', 'Screen Shot.png');
    assert.equal(r.status, 200, r.text);
    const p = r.json.path;
    assert.equal(path.dirname(p), SPOOL);
    assert.match(path.basename(p), /^\d{8}T\d{6}Z-[A-Za-z0-9]+\.png$/);
    assert.deepEqual(readFileSync(p), PNG);
    assert.equal(readlinkSync(fx.env.CLIP_BRIDGE_SPOOL), p);
  });

  test('a JPEG is 415 and stores nothing', async () => {
    const before = ls(SPOOL);
    const r = await up(JPEG, 'image/jpeg', 'x.jpg');
    assert.equal(r.status, 415, r.text);
    assert.deepEqual(ls(SPOOL), before);
  });

  test('image/png that is not a PNG is 415 and leaves the clipboard alone', async () => {
    const latest = readlinkSync(fx.env.CLIP_BRIDGE_SPOOL);
    const r = await up(Buffer.from('not a png'), 'image/png', 'x.png');
    assert.equal(r.status, 415, r.text);
    assert.ok(lstatSync(fx.env.CLIP_BRIDGE_SPOOL).isSymbolicLink());
    assert.equal(readlinkSync(fx.env.CLIP_BRIDGE_SPOOL), latest);
  });

  test('a text file lands in AGENT_WEB_FILES, mode 600 in a 700 directory, with a sanitised name', async () => {
    const body = Buffer.from('hello\n');
    const r = await up(body, 'text/plain', encodeURIComponent('a b/../c.txt'));
    assert.equal(r.status, 200, r.text);
    const p = r.json.path;
    assert.equal(path.dirname(p), FILES);
    const base = path.basename(p);
    assert.match(base, /^\d{8}T\d{6}Z-[0-9a-f]{8}-[A-Za-z0-9._-]+$/);
    assert.ok(base.endsWith('c.txt'), base);
    assert.doesNotMatch(base, /[/ ]/);
    assert.deepEqual(readFileSync(p), body);
    assert.equal(mode(p), 0o600);
    assert.equal(mode(FILES), 0o700);
  });

  test('names are reduced to [A-Za-z0-9._-] and keep their extension', async () => {
    assert.equal(sanitiseName('a b/../c.txt'), 'a_b_.._c.txt');
    assert.equal(sanitiseName('../../etc/passwd'), 'etc_passwd');
    assert.equal(sanitiseName('.bashrc'), 'bashrc');
    assert.equal(sanitiseName(''), 'file');
    assert.equal(sanitiseName('...'), 'file');
    const long = sanitiseName(`${'x'.repeat(200)}.tar.gz`);
    assert.equal(long.length, 80);
    assert.ok(long.endsWith('.gz'));
    // A header value that is not URL-encoding is used as sent; a missing one gets a placeholder.
    const r = await up(Buffer.from('x'), 'application/octet-stream', 'r%zz e.bin');
    assert.equal(r.status, 200, r.text);
    assert.match(r.json.path, /-r_zz_e\.bin$/);
    const r2 = await up(Buffer.from('x'), 'application/octet-stream');
    assert.match(r2.json.path, /-file$/);
    const r3 = await up(Buffer.from('x'), 'text/plain', encodeURIComponent('résumé ✓.txt'));
    assert.match(r3.json.path, /-r_sum_.txt$/);
  });

  test('files older than 24 h that the route wrote are pruned; anything else is left', async () => {
    const old = (Date.now() - 25 * 3600 * 1000) / 1000;
    const ours = path.join(FILES, '20200101T000000Z-0123abcd-old.txt');
    const fresh = path.join(FILES, '20200101T000000Z-0123abce-fresh.txt');
    const other = path.join(FILES, 'notes.txt');
    for (const f of [ours, fresh, other]) writeFileSync(f, 'x');
    utimesSync(ours, old, old);
    utimesSync(other, old, old);
    const r = await up(Buffer.from('y'), 'text/plain', 'y.txt');
    assert.equal(r.status, 200, r.text);
    assert.ok(!existsSync(ours));
    assert.ok(existsSync(fresh));
    assert.ok(existsSync(other));
  });

  test('21 MB is 413, by Content-Length and while streaming without one', async () => {
    const big = Buffer.alloc(21 * 1024 * 1024, 0x61);
    const before = ls(FILES);
    const r = await up(big, 'text/plain', 'big.txt');
    assert.equal(r.status, 413, r.text);
    // Chunked: no Content-Length, so only the count while reading can stop it.
    const status = await new Promise((resolve, reject) => {
      const { port } = new URL(s.url);
      const q = http.request({
        host: '127.0.0.1', port, path: url, method: 'POST',
        headers: { 'tailscale-user-login': 'tester@example.test', 'x-agent-web': '1', 'content-type': 'text/plain' },
      }, (res) => {
        res.resume();
        resolve(res.statusCode);
      });
      q.on('error', (e) => (e.code === 'EPIPE' || e.code === 'ECONNRESET' ? null : reject(e)));
      for (let i = 0; i < 21; i++) q.write(big.subarray(0, 1024 * 1024));
      q.end();
    });
    assert.equal(status, 413);
    assert.deepEqual(ls(FILES), before);
  });

  test('an unknown session is 404', async () => {
    const r = await s.req('/api/sessions/no-such-session/upload',
      { body: Buffer.from('x'), headers: { 'content-type': 'text/plain' } });
    assert.equal(r.status, 404, r.text);
  });

  test('a missing X-Agent-Web or Content-Type is 403', async () => {
    let r = await up(Buffer.from('x'), 'text/plain', 'x.txt', { 'x-agent-web': null });
    assert.equal(r.status, 403, r.text);
    r = await s.req(url, { body: Buffer.from('x') });
    assert.equal(r.status, 403, r.text);
  });

  test('a clip-put that fails is a 502 that says so, not a path', async () => {
    const stub = path.join(fx.root, 'clip-put-fails');
    writeFileSync(stub, '#!/bin/sh\ncat >/dev/null\necho broken >&2\nexit 3\n', { mode: 0o755 });
    mkdirSync(SPOOL, { recursive: true });
    const other = await startServer({ CLIP_PUT: stub });
    try {
      const r = await other.req(url, { body: PNG, headers: { 'content-type': 'image/png' } });
      assert.equal(r.status, 502, r.text);
      assert.match(r.json.error, /clip-put failed/);
    } finally {
      await other.stop();
    }
  });
});
