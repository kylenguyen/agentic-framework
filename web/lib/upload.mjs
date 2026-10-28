// web/lib/upload.mjs: POST /api/sessions/:name/upload (docs/web-dashboard-plan.md T8), the server half of pasting
// an image or dropping a file on the web terminal. The page sends the file's raw bytes with its Content-Type and
// an X-File-Name header, and types the returned path into the session, the way WezTerm's Cmd+V does over SSH.
//
//   image/png    piped to clip-put ($CLIP_PUT, else the working tree's bin/clip-put) with the server's env, so
//                CLIP_BRIDGE_SPOOL picks the spool; clip-put's printed path is the answer. The PNG signature is
//                checked first: clip-put files anything else as clipboard text over ~/.clip/latest and prints
//                nothing, so a mislabelled body is a 415 here rather than a clobbered clipboard. A clip-put that
//                fails or prints no .png path is a 502 naming it, so the page's toast says what went wrong.
//   image/*      415: the page converts other images to PNG before sending.
//   anything     written to $AGENT_WEB_FILES/<UTC stamp>-<random>-<sanitised name>, mode 600 in a 700 directory;
//                files there older than 24 h are pruned on every upload (there is no timer).
// Bodies are capped at 20 MB (413), by Content-Length before reading and by count while reading (readBody).
//
// X-File-Name is the browser's file name URL-encoded with encodeURIComponent, since a header is Latin-1 only; a
// value that does not decode is used as sent. Either way it is reduced to [A-Za-z0-9._-]: no '/', no spaces (Oh
// My Pi splits a pasted line on whitespace), no leading dot, at most 80 characters with the extension kept.

import { spawn } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { chmod, mkdir, readdir, stat, unlink, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { HttpError, UPLOAD_LIMIT, readBody } from './auth.mjs';
import { findSession } from './agent.mjs';

const REPO_CLIP_PUT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../bin/clip-put');
const PNG_MAGIC = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
const KEEP_MS = 24 * 3600 * 1000;
const CLIP_TIMEOUT_MS = 15000;
const NAME_MAX = 80;
// What this route writes, and so the only names the prune may delete: AGENT_WEB_FILES may be shared with
// something else, and clip-put's own spool rule (one directory for nothing else) is not promised here.
const OURS = /^\d{8}T\d{6}Z-[0-9a-f]{8}-/;

export const clipPutBin = (env) => env.CLIP_PUT || REPO_CLIP_PUT;

export function decodeName(raw) {
  const v = String(raw ?? '');
  try {
    return decodeURIComponent(v);
  } catch {
    return v;
  }
}

// 'a b/../c.txt' -> 'a_b_.._c.txt'. Runs of anything outside the set become one '_'; leading dots and '_' go, so
// the name is never hidden and never '..' on its own (the stamp prefix would stop that anyway).
export function sanitiseName(name) {
  let s = String(name ?? '').replace(/[^A-Za-z0-9._-]+/g, '_').replace(/^[._]+/, '');
  if (s.length > NAME_MAX) {
    const dot = s.lastIndexOf('.');
    const ext = dot > 0 && s.length - dot <= 16 ? s.slice(dot) : '';
    s = s.slice(0, NAME_MAX - ext.length) + ext;
  }
  return s || 'file';
}

export function stamp(d = new Date()) {
  return d.toISOString().replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z');
}

function mediaType(req) {
  return String(req.headers['content-type'] ?? '').split(';')[0].trim().toLowerCase();
}

function clipPut(env, body) {
  return new Promise((resolve, reject) => {
    // No shell, the server's env (CLIP_BRIDGE_SPOOL), the body on stdin, its own session like runCommand.
    const child = spawn(clipPutBin(env), [], { env, detached: true, stdio: ['pipe', 'pipe', 'pipe'] });
    const out = [];
    const err = [];
    let failed = '';
    const timer = setTimeout(() => {
      failed = 'timed out';
      child.kill('SIGKILL');
    }, CLIP_TIMEOUT_MS);
    child.stdout.on('data', (b) => out.push(b));
    child.stderr.on('data', (b) => err.push(b));
    child.stdin.on('error', () => {});   // EPIPE when clip-put dies early; the exit status says why
    child.on('error', (e) => { failed = e.code ?? e.message; });
    child.on('close', (code) => {
      clearTimeout(timer);
      const printed = Buffer.concat(out).toString('utf8').trim().split('\n').at(-1) ?? '';
      if (failed || code !== 0 || !path.isAbsolute(printed) || !printed.endsWith('.png')) {
        const why = failed || `exit ${code}`;
        console.error(`clip-put: ${why}: ${Buffer.concat(err).toString('utf8').trim()}`);
        reject(new HttpError(502, `clip-put failed (${why})`));
        return;
      }
      resolve(printed);
    });
    child.stdin.end(body);
  });
}

async function prune(dir, now = Date.now()) {
  let names;
  try {
    names = await readdir(dir);
  } catch {
    return;
  }
  await Promise.all(names.filter((n) => OURS.test(n)).map(async (n) => {
    const p = path.join(dir, n);
    try {
      const st = await stat(p);
      if (st.isFile() && now - st.mtimeMs > KEEP_MS) await unlink(p);
    } catch { /* gone already, or not ours to read */ }
  }));
}

async function saveFile(dir, name, body) {
  await mkdir(dir, { recursive: true, mode: 0o700 });
  await chmod(dir, 0o700);
  await prune(dir);
  const file = path.join(dir, `${stamp()}-${randomBytes(4).toString('hex')}-${sanitiseName(name)}`);
  // wx: a name that somehow exists already is an error, never an overwrite.
  await writeFile(file, body, { mode: 0o600, flag: 'wx' });
  return file;
}

export async function uploadFile(req, res, ctx) {
  await findSession(ctx.env, ctx.params.name);
  const type = mediaType(req);
  if (type.startsWith('image/') && type !== 'image/png') {
    throw new HttpError(415, 'only image/png is accepted for images: convert it first');
  }
  const body = await readBody(req, UPLOAD_LIMIT);
  if (type === 'image/png') {
    if (body.length < PNG_MAGIC.length || !body.subarray(0, PNG_MAGIC.length).equals(PNG_MAGIC)) {
      throw new HttpError(415, 'image/png body is not a PNG');
    }
    return { path: await clipPut(ctx.env, body) };
  }
  return { path: await saveFile(ctx.config.files, decodeName(req.headers['x-file-name']), body) };
}
