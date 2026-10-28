// web/lib/static.mjs: files for GET and HEAD outside /api/. Two sources only: web/public/ and a fixed list of
// vendor files out of web/node_modules (served as is, no bundler). Anything that would leave web/public/, any
// directory other than the root (which gives index.html) and any non-regular file is a 404: no listings.

import { createReadStream } from 'node:fs';
import { realpath, stat } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const WEB = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
export const PUBLIC = path.join(WEB, 'public');
const MODULES = path.join(WEB, 'node_modules');

// The browser imports these paths; the files are the ESM builds the pinned packages ship.
export const VENDOR = {
  '/vendor/xterm.mjs': path.join(MODULES, '@xterm/xterm/lib/xterm.mjs'),
  '/vendor/xterm.css': path.join(MODULES, '@xterm/xterm/css/xterm.css'),
  '/vendor/addon-fit.mjs': path.join(MODULES, '@xterm/addon-fit/lib/addon-fit.mjs'),
  '/vendor/addon-clipboard.mjs': path.join(MODULES, '@xterm/addon-clipboard/lib/addon-clipboard.mjs'),
};

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.webmanifest': 'application/manifest+json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
  '.txt': 'text/plain; charset=utf-8',
};

// URL pathname -> absolute file under PUBLIC, or null. The pathname is already normalised by URL parsing; the
// segment check catches what decoding brings back (%2e%2e, %2f) and the prefix check is the fence behind it.
export function resolvePublic(pathname) {
  let rel;
  try {
    rel = decodeURIComponent(pathname);
  } catch {
    return null;
  }
  if (rel.includes('\0') || rel.includes('\\')) return null;
  if (rel.split('/').some((s) => s === '..')) return null;
  if (rel === '/') rel = '/index.html';
  const file = path.join(PUBLIC, rel);
  return file.startsWith(PUBLIC + path.sep) ? file : null;
}

// Serves the file and returns true, or returns false for the caller's 404. Symlinks are followed only when they
// stay inside PUBLIC.
export async function serveStatic(req, res, pathname, headers = {}) {
  let file = VENDOR[pathname];
  if (!file) {
    file = resolvePublic(pathname);
    if (!file) return false;
    try {
      const real = await realpath(file);
      if (!real.startsWith(PUBLIC + path.sep)) return false;
      file = real;
    } catch {
      return false;
    }
  }
  let st;
  try {
    st = await stat(file);
  } catch {
    return false;
  }
  if (!st.isFile()) return false;
  res.writeHead(200, {
    ...headers,
    'Content-Type': TYPES[path.extname(file)] ?? 'application/octet-stream',
    'Content-Length': st.size,
    // The page and the vendor files change with a git pull and a restart; revalidating keeps a phone from
    // running yesterday's app against today's API.
    'Cache-Control': 'no-cache',
    'Last-Modified': st.mtime.toUTCString(),
  });
  if (req.method === 'HEAD') {
    res.end();
    return true;
  }
  createReadStream(file).on('error', () => res.destroy()).pipe(res);
  return true;
}
