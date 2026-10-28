// web/public/app.mjs: the dashboard page (docs/web-dashboard-plan.md T6). Plain ES modules, no framework, no
// bundler: xterm.js and its addons come from /vendor/ (the pinned packages, served by web/lib/static.mjs).
//
// Two views on hash routes: #/ is the session list (a 3 s poll of /api/sessions), #/s/<name> is a full-window
// terminal on WS /api/sessions/<name>/term. The poll runs on both, so the terminal's state pill follows too.
//
// Hooks for the later sections of this file (phone, paste, sim, alerts), so each adds its own code instead of
// editing the code above it:
//   hooks.sessions     (list) => list      reorder or merge the polled sessions before they render
//   hooks.card         (li, session)       decorate one list card after it is built (data-attention badge)
//   hooks.rendered     (list)              after every list render (document title count)
//   hooks.view         (route)             after a route change; route = {view:'list'} | {view:'term', name}
//   hooks.terminalOpen ({term, name, el})  a terminal view was built (once per visit, not per reconnect)
//   hooks.terminalClose({term, name})      the terminal view is being torn down
//   sendInput(data)    a string or Uint8Array to the open terminal, as if typed; false when not connected
//   fitTerminal()      refit after a layout change (a bar shown or hidden, a font size change)
//   api(path, opts)    fetch with the POST guard header; JSON in, JSON out, throws Error(message) on failure
//   slots              the data-slot elements: headerActions, listPanels, termActions, termFooter
//   currentTerminal()  {term, name, connected} or null
//
// ?test=1 exposes the open xterm as window.__term for the Playwright suite (tests/e2e/web), and nothing else.

import { Terminal } from '/vendor/xterm.mjs';
import { FitAddon } from '/vendor/addon-fit.mjs';
import { ClipboardAddon } from '/vendor/addon-clipboard.mjs';

const TEST = new URLSearchParams(location.search).has('test');
const POLL_MS = 3000;
const $ = (id) => document.getElementById(id);

// --- CSP bridge ------------------------------------------------------------------------------------------------
// The CSP has no 'unsafe-inline' for styles, and xterm.js uses two inline mechanisms it would block: <style>
// elements it fills with its theme and cell size, and style="" attributes on truecolor cells. CSSOM is not
// subject to that rule. So a <style> that script asks for is an inert <inline-style> stand-in (xterm only sets
// its textContent and removes it) whose text is mirrored into an adopted stylesheet, and setAttribute('style')
// becomes a cssText assignment. Only script on this origin reaches either path; markup is still held to the CSP.
const mirrored = new Map();   // stand-in element -> {sheet, text}
function syncStyles() {
  for (const [el, m] of mirrored) {
    if (!el.isConnected) {
      mirrored.delete(el);
    } else if (m.text !== el.textContent) {
      m.text = el.textContent;
      m.sheet.replaceSync(m.text);
    }
  }
  document.adoptedStyleSheets = [...mirrored.values()].map((m) => m.sheet);
}
const createElement = Document.prototype.createElement;
Document.prototype.createElement = function (tag, opts) {
  if (String(tag).toLowerCase() !== 'style') return createElement.call(this, tag, opts);
  const el = createElement.call(this, 'inline-style');
  mirrored.set(el, { sheet: new CSSStyleSheet(), text: null });
  new MutationObserver(syncStyles).observe(el, { childList: true, characterData: true, subtree: true });
  queueMicrotask(syncStyles);
  return el;
};
const setAttribute = Element.prototype.setAttribute;
Element.prototype.setAttribute = function (name, value) {
  if (String(name).toLowerCase() === 'style' && this.style) {
    this.style.cssText = String(value);
    return;
  }
  setAttribute.call(this, name, value);
};
if (TEST) {
  window.__csp = [];
  document.addEventListener('securitypolicyviolation', (e) => window.__csp.push(`${e.violatedDirective} ${e.blockedURI}`));
}

// --- shared ----------------------------------------------------------------------------------------------------
export const hooks = { sessions: [], card: [], rendered: [], view: [], terminalOpen: [], terminalClose: [] };
export const slots = {
  headerActions: $('header-actions'),
  listPanels: $('list-panels'),
  termActions: $('term-actions'),
  termFooter: $('term-footer'),
};

function run(list, ...args) {
  for (const fn of list) {
    try {
      fn(...args);
    } catch (err) {
      console.error(err);
    }
  }
}

export async function api(path, { method, body } = {}) {
  const opts = { method: method ?? (body === undefined ? 'GET' : 'POST'), headers: {}, cache: 'no-store' };
  if (opts.method === 'POST') {
    opts.headers['X-Agent-Web'] = '1';
    opts.headers['Content-Type'] = 'application/json';
    opts.body = JSON.stringify(body ?? {});
  }
  const res = await fetch(path, opts);
  let data = null;
  try {
    data = await res.json();
  } catch { /* not JSON: the message below says so */ }
  if (!res.ok) throw Object.assign(new Error(data?.error ?? `${res.status} ${res.statusText}`), { status: res.status });
  return data;
}

function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
}

const none = (v) => v === undefined || v === null || v === '' || v === '-';

function ago(epoch) {
  const s = Math.max(0, Math.floor(Date.now() / 1000 - epoch));
  if (s < 60) return 'now';
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  if (s < 86400) return `${Math.floor(s / 3600)}h`;
  return `${Math.floor(s / 86400)}d`;
}

const HARNESS_LABEL = { claude: 'Claude', codex: 'Codex', omp: 'Oh My Pi', opencode: 'OpenCode', shell: 'shell' };

// --- session poll ----------------------------------------------------------------------------------------------
let sessions = [];
let pollTimer = null;
let pollFailed = false;

async function poll() {
  clearTimeout(pollTimer);
  try {
    let list = await api('/api/sessions');
    for (const fn of hooks.sessions) list = fn(list) ?? list;
    sessions = list;
    pollFailed = false;
  } catch (err) {
    pollFailed = err.message;
  }
  renderList();
  renderTermState();
  pollTimer = setTimeout(poll, POLL_MS);
}

const findSession = (name) => sessions.find((s) => s.name === name);

// --- list view -------------------------------------------------------------------------------------------------
const listEl = $('sessions');
const cardCache = new Map();   // name -> {key, li}: an unchanged session keeps its element (hover, focus)

function card(s) {
  const li = el('li', `card state-${s.state}`);
  li.dataset.name = s.name;

  const open = el('a', 'card-open');
  open.href = `#/s/${encodeURIComponent(s.name)}`;
  open.setAttribute('aria-label', `Open ${s.name}`);

  const dot = el('span', 'dot');
  dot.title = s.state;
  const main = el('span', 'card-main');
  const title = el('span', 'card-title');
  title.append(el('span', 'name', s.name));
  const att = el('span', 'badge attention');
  att.dataset.attention = s.attention?.reason ?? '';
  if (s.attention) att.textContent = s.attention.reason;
  title.append(att);
  const meta = el('span', 'card-meta');
  if (!none(s.repo)) meta.append(el('span', 'repo', s.repo));
  if (!none(s.branch)) {
    const br = el('span', 'branch', s.branch);
    if (s.worktree) br.classList.add('worktree');
    br.title = s.worktree ? `worktree ${s.cwd}` : s.cwd;
    meta.append(br);
  }
  if (s.worktree) meta.append(el('span', 'wt-mark', 'worktree'));
  if (!meta.childElementCount) meta.append(el('span', 'cwd', s.cwd));
  main.append(title, meta);

  const harness = el('span', `chip harness h-${s.harness}`, HARNESS_LABEL[s.harness] ?? s.harness);
  const devices = el('span', 'devices');
  if (s.devices?.length) {
    for (const d of s.devices) devices.append(el('span', 'device', d));
  } else {
    devices.append(el('span', 'device none', 'detached'));
  }
  const age = el('span', 'age', ago(s.created));
  age.title = `started ${new Date(s.created * 1000).toLocaleString()}`;
  const state = el('span', 'state-label', s.state);

  open.append(dot, main, harness, devices, state, age);

  const kill = el('button', 'btn small danger-ghost kill', 'Kill');
  kill.type = 'button';
  kill.addEventListener('click', () => openKill(s.name));
  li.append(open, kill);
  run(hooks.card, li, s);
  return li;
}

function renderList() {
  const notice = $('list-notice');
  notice.hidden = !pollFailed;
  if (pollFailed) notice.textContent = `Cannot load sessions (${pollFailed}). Retrying every ${POLL_MS / 1000} s.`;

  const seen = new Set();
  const items = sessions.map((s) => {
    seen.add(s.name);
    // ago() changes over time, so the minute goes into the key; everything else is the session itself.
    const key = JSON.stringify(s) + ago(s.created);
    const hit = cardCache.get(s.name);
    if (hit && hit.key === key) return hit.li;
    const li = card(s);
    cardCache.set(s.name, { key, li });
    return li;
  });
  for (const name of cardCache.keys()) if (!seen.has(name)) cardCache.delete(name);
  // Reorder or replace only when something differs, so an idle list never touches the DOM.
  const same = items.length === listEl.children.length && items.every((li, i) => listEl.children[i] === li);
  if (!same) listEl.replaceChildren(...items);

  $('empty').hidden = sessions.length > 0 || pollFailed !== false;
  $('count').textContent = sessions.length ? String(sessions.length) : '';
  if (route.view === 'list') document.title = 'Agents';
  run(hooks.rendered, sessions);
}

// --- new session dialog ----------------------------------------------------------------------------------------
const newDialog = $('new-dialog');

async function openNew() {
  $('new-error').hidden = true;
  $('new-create').disabled = false;
  const select = $('new-repo');
  const keep = select.value;
  try {
    const repos = await api('/api/repos');
    select.replaceChildren(...repos.map((r) => {
      const o = el('option', null, r);
      o.value = r;
      return o;
    }));
    if (repos.includes(keep)) select.value = keep;
    if (!repos.length) showError('new-error', 'No git repositories under ~/workspace.');
  } catch (err) {
    showError('new-error', `Cannot list repositories: ${err.message}`);
  }
  newDialog.showModal();
}

function showError(id, text) {
  const p = $(id);
  p.textContent = text;
  p.hidden = false;
}

$('new-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const slug = $('new-slug').value.trim();
  const body = { repo: $('new-repo').value, harness: $('new-harness').value };
  if (slug) body.slug = slug;
  $('new-create').disabled = true;
  $('new-error').hidden = true;
  try {
    const { name } = await api('/api/sessions', { body });
    newDialog.close();
    $('new-slug').value = '';
    location.hash = `#/s/${encodeURIComponent(name)}`;
    poll();
  } catch (err) {
    showError('new-error', err.message);
  } finally {
    $('new-create').disabled = false;
  }
});

$('new-btn').addEventListener('click', openNew);
$('empty-new').addEventListener('click', openNew);
for (const b of document.querySelectorAll('dialog [data-close]')) {
  b.addEventListener('click', () => b.closest('dialog').close());
}

// --- kill dialog -----------------------------------------------------------------------------------------------
const killDialog = $('kill-dialog');
let killTarget = null;

async function openKill(name) {
  killTarget = name;
  $('kill-name').textContent = name;
  $('kill-error').hidden = true;
  $('kill-files').hidden = true;
  for (const id of ['kill-keep', 'kill-force', 'kill-go']) $(id).hidden = true;
  $('kill-text').textContent = 'Checking the worktree…';
  killDialog.showModal();
  let wt;
  try {
    wt = await api(`/api/sessions/${encodeURIComponent(name)}/worktree`);
  } catch (err) {
    $('kill-text').textContent = '';
    showError('kill-error', err.message);
    return;
  }
  if (killTarget !== name) return;
  if (wt.dirty) {
    $('kill-text').textContent = 'The worktree has changes that are not committed:';
    const files = $('kill-files');
    files.replaceChildren(...wt.files.map((f) => el('li', 'mono', f)));
    files.hidden = false;
    $('kill-keep').hidden = false;
    $('kill-force').hidden = false;
  } else {
    $('kill-text').textContent = wt.worktree
      ? 'The harness stops and its clean worktree is removed. The branch stays.'
      : 'The harness and every view of this session stop.';
    $('kill-go').hidden = false;
  }
}

async function doKill(body) {
  const name = killTarget;
  for (const id of ['kill-keep', 'kill-force', 'kill-go']) $(id).disabled = true;
  try {
    await api(`/api/sessions/${encodeURIComponent(name)}/kill`, { body });
    killDialog.close();
    if (route.view === 'term' && route.name === name) location.hash = '#/';
    poll();
  } catch (err) {
    showError('kill-error', err.message);
  } finally {
    for (const id of ['kill-keep', 'kill-force', 'kill-go']) $(id).disabled = false;
  }
}

$('kill-go').addEventListener('click', () => doKill({}));
$('kill-keep').addEventListener('click', () => doKill({ keepWorktree: true }));
$('kill-force').addEventListener('click', () => doKill({ force: true }));
killDialog.addEventListener('close', () => { killTarget = null; });
$('term-kill').addEventListener('click', () => route.name && openKill(route.name));

// --- terminal view ---------------------------------------------------------------------------------------------
// The terminal is dark in both page themes: harness output assumes a dark background.
const THEME = {
  background: '#0d1117', foreground: '#d6dde6', cursor: '#e6edf3', cursorAccent: '#0d1117',
  selectionBackground: '#3b5070',
  black: '#1b2028', red: '#f07178', green: '#9ece6a', yellow: '#e6b450', blue: '#6cb6ff', magenta: '#d2a8ff',
  cyan: '#56d4dd', white: '#c9d1d9', brightBlack: '#6e7681', brightRed: '#ff8f95', brightGreen: '#b5e48c',
  brightYellow: '#ffd479', brightBlue: '#9ecbff', brightMagenta: '#e2c5ff', brightCyan: '#8ce6ee',
  brightWhite: '#ffffff',
};

let tv = null;   // {name, term, fit, ws, ended, retry, attempts, observer}
const encoder = new TextEncoder();

export function currentTerminal() {
  return tv && { term: tv.term, name: tv.name, connected: tv.ws?.readyState === WebSocket.OPEN };
}

export function sendInput(data) {
  if (!tv?.ws || tv.ws.readyState !== WebSocket.OPEN) return false;
  tv.ws.send(typeof data === 'string' ? encoder.encode(data) : data);
  return true;
}

export function fitTerminal() {
  if (!tv) return;
  try {
    tv.fit.fit();
  } catch { /* not laid out yet */ }
}

function banner(text, { retry = false } = {}) {
  const b = $('banner');
  if (text === null) {
    b.hidden = true;
    fitTerminal();
    return;
  }
  $('banner-text').textContent = text;
  $('banner-retry').hidden = !retry;
  b.hidden = false;
  fitTerminal();
}

function renderTermState() {
  if (route.view !== 'term') return;
  const s = findSession(route.name);
  const state = tv?.ended ?? (s ? s.state : pollFailed ? 'unknown' : 'gone');
  $('term-state').textContent = state;
  $('term-state').dataset.state = state;
  $('term-dot').className = `dot state-${state}`;
}

function openTerminal(name) {
  closeTerminal();
  $('term-name').textContent = name;
  document.title = name;
  banner(null);
  const term = new Terminal({
    theme: THEME,
    fontFamily: 'ui-monospace, "SF Mono", "JetBrains Mono", Menlo, "DejaVu Sans Mono", Consolas, monospace',
    fontSize: 14,
    lineHeight: 1.1,
    cursorBlink: true,
    scrollback: 5000,
    allowProposedApi: true,
    macOptionIsMeta: true,
  });
  const fit = new FitAddon();
  term.loadAddon(fit);
  term.loadAddon(new ClipboardAddon());
  const box = $('term');
  term.open(box);
  tv = { name, term, fit, ws: null, ended: null, retry: null, attempts: 0 };
  if (TEST) window.__term = term;
  fitTerminal();
  tv.observer = new ResizeObserver(() => fitTerminal());
  tv.observer.observe(box);

  term.onData((d) => sendInput(d));
  term.onBinary((d) => sendInput(Uint8Array.from(d, (c) => c.charCodeAt(0) & 0xff)));
  term.onResize(({ cols, rows }) => {
    if (tv?.ws?.readyState === WebSocket.OPEN) tv.ws.send(JSON.stringify({ type: 'resize', cols, rows }));
  });
  run(hooks.terminalOpen, { term, name, el: box });
  connect();
  term.focus();
  renderTermState();
}

function connect() {
  if (!tv) return;
  clearTimeout(tv.retry);
  const t = tv;
  const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  const url = `${proto}//${location.host}/api/sessions/${encodeURIComponent(t.name)}/term`
    + `?cols=${t.term.cols}&rows=${t.term.rows}`;
  const ws = new WebSocket(url);
  ws.binaryType = 'arraybuffer';
  t.ws = ws;
  let exited = false;
  ws.onopen = () => {
    if (tv !== t) return;
    t.attempts = 0;
    banner(null);
    // The size may have changed while the socket was down.
    ws.send(JSON.stringify({ type: 'resize', cols: t.term.cols, rows: t.term.rows }));
    renderTermState();
  };
  ws.onmessage = (e) => {
    if (tv !== t) return;
    if (typeof e.data !== 'string') {
      t.term.write(new Uint8Array(e.data));
      return;
    }
    let msg;
    try {
      msg = JSON.parse(e.data);
    } catch {
      return;
    }
    if (msg.type === 'exit') exited = true;
  };
  ws.onclose = (e) => {
    if (tv !== t || t.ws !== ws) return;
    if (e.code === 4404) {
      t.ended = 'gone';
      banner('This session no longer exists.');
    } else if (exited) {
      t.ended = 'ended';
      banner('The session ended.');
    } else {
      // Server restart (1012), a network drop or a sleeping laptop: retry with backoff, and offer it now.
      t.attempts += 1;
      const wait = Math.min(10000, 500 * 2 ** Math.min(t.attempts, 5));
      banner(`Connection lost. Reconnecting in ${Math.round(wait / 1000)} s…`, { retry: true });
      t.retry = setTimeout(connect, wait);
    }
    renderTermState();
  };
}

function closeTerminal() {
  if (!tv) return;
  const t = tv;
  tv = null;
  clearTimeout(t.retry);
  t.observer?.disconnect();
  run(hooks.terminalClose, { term: t.term, name: t.name });
  if (t.ws && t.ws.readyState <= WebSocket.OPEN) t.ws.close(1000);
  t.term.dispose();
  $('term').replaceChildren();
  syncStyles();
  if (TEST) delete window.__term;
}

$('banner-retry').addEventListener('click', () => {
  if (!tv || tv.ended) return;
  banner('Reconnecting…');
  connect();
});

// --- routing ---------------------------------------------------------------------------------------------------
let route = { view: 'list' };

function parseRoute() {
  const m = /^#\/s\/(.+)$/.exec(location.hash);
  if (!m) return { view: 'list' };
  try {
    return { view: 'term', name: decodeURIComponent(m[1]) };
  } catch {
    return { view: 'list' };
  }
}

function onRoute() {
  const next = parseRoute();
  if (next.view === route.view && next.name === route.name && (next.view === 'list' || tv)) return;
  route = next;
  $('view-list').hidden = route.view !== 'list';
  $('view-term').hidden = route.view !== 'term';
  if (route.view === 'term') {
    openTerminal(route.name);
  } else {
    closeTerminal();
    document.title = 'Agents';
    renderList();
  }
  run(hooks.view, route);
}

window.addEventListener('hashchange', onRoute);
// A tab that comes back from the background polls at once rather than showing a list up to 3 s old.
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') poll();
});

// --- start -----------------------------------------------------------------------------------------------------
// A microtask, so the sections appended below (phone, paste, sim, alerts) have registered their hooks before the
// first route and poll: the whole module body runs first.
queueMicrotask(() => {
  route = { view: null };
  onRoute();
  poll();
});

// --- paste -----------------------------------------------------------------------------------------------------
// T8: an image pasted into the terminal, a file dropped on the page, or one picked with the paperclip goes to
// POST /api/sessions/<name>/upload, and the path the server answers with is typed into the session followed by a
// space, the way WezTerm's Cmd+V reaches a harness over SSH. Images other than PNG are converted here first (the
// server only takes image/png, which clip-put files as an image). A text paste never comes this way: the paste
// listener only claims clipboards that carry a file, and leaves the rest to xterm.
const UPLOAD_MAX = 20 * 1024 * 1024;
const pasteToast = $('paste-toast');
let toastTimer = null;

function toast(text, kind = 'info', ms = 0) {
  clearTimeout(toastTimer);
  pasteToast.textContent = text;
  pasteToast.dataset.kind = kind;
  pasteToast.hidden = false;
  if (ms) toastTimer = setTimeout(() => { pasteToast.hidden = true; }, ms);
}

async function toPng(file) {
  const bitmap = await createImageBitmap(file);
  try {
    const { width, height } = bitmap;
    if (typeof OffscreenCanvas !== 'undefined') {
      const canvas = new OffscreenCanvas(width, height);
      canvas.getContext('2d').drawImage(bitmap, 0, 0);
      return await canvas.convertToBlob({ type: 'image/png' });
    }
    const canvas = document.createElement('canvas');
    canvas.width = width;
    canvas.height = height;
    canvas.getContext('2d').drawImage(bitmap, 0, 0);
    return await new Promise((resolve, reject) => {
      canvas.toBlob((b) => (b ? resolve(b) : reject(new Error('the canvas made no PNG'))), 'image/png');
    });
  } finally {
    bitmap.close?.();
  }
}

// A pasted screenshot has no name, or the browser's generic "image.png".
const baseName = (file) => (file.name || 'pasted').replace(/\.[^.]*$/, '');

async function uploadOne(name, file) {
  let body = file;
  let type = file.type || 'application/octet-stream';
  let fileName = file.name || 'pasted';
  if (type.startsWith('image/') && type !== 'image/png') {
    try {
      body = await toPng(file);
    } catch {
      throw new Error(`cannot convert ${fileName} (${type}) to PNG`);
    }
    type = 'image/png';
    fileName = `${baseName(file)}.png`;
  }
  if (body.size > UPLOAD_MAX) throw new Error(`${fileName} is over 20 MB`);
  const res = await fetch(`/api/sessions/${encodeURIComponent(name)}/upload`, {
    method: 'POST',
    // X-File-Name is URL-encoded: header values are Latin-1, file names are not (web/lib/upload.mjs).
    headers: { 'X-Agent-Web': '1', 'Content-Type': type, 'X-File-Name': encodeURIComponent(fileName) },
    body,
    cache: 'no-store',
  });
  let data = null;
  try {
    data = await res.json();
  } catch { /* the status says enough */ }
  if (!res.ok || typeof data?.path !== 'string') throw new Error(data?.error ?? `${res.status} ${res.statusText}`);
  return data.path;
}

// One file at a time, in order, so several paths arrive in the order they were picked.
async function uploadFiles(files) {
  const t = currentTerminal();
  if (!t || !files.length) return;
  for (const [i, file] of files.entries()) {
    const label = files.length > 1 ? ` (${i + 1}/${files.length})` : '';
    toast(`Uploading ${file.name || 'image'}${label}…`);
    let p;
    try {
      p = await uploadOne(t.name, file);
    } catch (err) {
      toast(`Upload failed: ${err.message}`, 'error', 6000);
      return;
    }
    // The view may have changed while the upload ran; the path belongs to the session it was meant for.
    if (currentTerminal()?.name !== t.name || !sendInput(`${p} `)) {
      toast(`Uploaded to ${p}, but the terminal is not connected`, 'error', 8000);
      return;
    }
  }
  toast(files.length > 1 ? `Pasted ${files.length} paths` : 'Pasted the path', 'ok', 1500);
  currentTerminal()?.term.focus();
}

const filesOf = (dt) => [...(dt?.items ?? [])].filter((it) => it.kind === 'file').map((it) => it.getAsFile()).filter(Boolean);
const hasFiles = (dt) => [...(dt?.types ?? [])].includes('Files');

hooks.terminalOpen.push(({ el: box }) => {
  // Capture phase on the box: this runs before xterm's own listener on its textarea, and stops the event only
  // when the clipboard holds a file. Plain text goes on to xterm unchanged (bracketed paste and all).
  box.addEventListener('paste', (e) => {
    const files = filesOf(e.clipboardData);
    if (!files.length) return;
    e.preventDefault();
    e.stopPropagation();
    uploadFiles(files);
  }, { capture: true });
});

// Drops are taken on the whole window, so a file that misses the terminal never makes the browser navigate away
// from the dashboard. Only the terminal view uploads; elsewhere the drop is just swallowed.
const termView = $('view-term');
let dragDepth = 0;
window.addEventListener('dragenter', (e) => {
  if (!hasFiles(e.dataTransfer)) return;
  dragDepth += 1;
  if (currentTerminal()) termView.classList.add('paste-drop');
});
window.addEventListener('dragleave', () => {
  dragDepth = Math.max(0, dragDepth - 1);
  if (!dragDepth) termView.classList.remove('paste-drop');
});
window.addEventListener('dragover', (e) => {
  if (!hasFiles(e.dataTransfer)) return;
  e.preventDefault();
  e.dataTransfer.dropEffect = currentTerminal() ? 'copy' : 'none';
});
window.addEventListener('drop', (e) => {
  dragDepth = 0;
  termView.classList.remove('paste-drop');
  const files = [...(e.dataTransfer?.files ?? [])];
  if (!files.length) return;
  e.preventDefault();
  uploadFiles(files);
});

// The paperclip: any file type, several at once. On a phone the picker also offers the camera.
const picker = el('input');
picker.type = 'file';
picker.multiple = true;
picker.hidden = true;
picker.id = 'paste-picker';
picker.addEventListener('change', () => {
  const files = [...picker.files];
  picker.value = '';
  uploadFiles(files);
});
const clip = el('button', 'btn ghost icon paste-attach');
clip.type = 'button';
clip.id = 'paste-attach';
clip.title = 'Attach a file or image';
clip.setAttribute('aria-label', 'Attach a file or image');
clip.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M21 11.5l-8.6 8.6a5 5 0 0 1-7.1-7.1l8.6-8.6a3.5 3.5 0 0 1 5 5l-8.6 8.6a2 2 0 0 1-2.8-2.8l7.9-7.9"/></svg>';
clip.addEventListener('click', () => picker.click());
slots.termActions.append(clip, picker);

// --- phone -----------------------------------------------------------------------------------------------------
// docs/web-dashboard-plan.md T7. Below 700 px the terminal gets the #phone-footer bar (index.html) in the
// term-footer slot: soft keys a phone keyboard lacks, a sticky Ctrl, a line box and the font size. The page also
// registers sw.js, which with manifest.webmanifest makes it installable; T10 adds push to that worker.
const PHONE = matchMedia('(max-width: 700px)');
const FONT_KEY = 'agent-web.fontSize';
const FONT_MIN = 12;
const FONT_MAX = 18;
const LINE_KEY = 'agent-web.lineMode';
const CSI = (final, mod) => (mod ? `\x1b[1;5${final}` : `\x1b[${final}`);

// localStorage throws in some private modes and is empty in others; neither may break the page.
function stored(key) {
  try {
    return localStorage.getItem(key);
  } catch {
    return null;
  }
}
function store(key, value) {
  try {
    localStorage.setItem(key, String(value));
  } catch { /* the setting lasts this visit only */ }
}

function fontSize() {
  const n = Number(stored(FONT_KEY));
  return Number.isInteger(n) && n >= FONT_MIN && n <= FONT_MAX ? n : null;
}

let ctrlArmed = false;
let phoneBar = null;   // the footer's clone while it is mounted

function armCtrl(on) {
  ctrlArmed = on;
  phoneBar?.querySelector('[data-key="ctrl"]').setAttribute('aria-pressed', String(on));
}

// Ctrl applies to whatever the next key is, so the conversion sits where every key ends up: the terminal
// socket's send. xterm's onData (the on-screen keyboard, IME, a hardware keyboard) and the soft keys all reach it
// through sendInput(); hooking the send keeps one place for all of those input paths. Only binary frames to a
// /term socket are touched; resize messages are text and pass by.
const wsSend = WebSocket.prototype.send;
WebSocket.prototype.send = function (data) {
  if (ctrlArmed && data instanceof Uint8Array && this.url.includes('/term')) {
    armCtrl(false);
    if (data.length === 1) data = Uint8Array.of(ctrlByte(data[0]));
  }
  return wsSend.call(this, data);
};

// a-z and A-Z (iOS capitalises the first letter) and @[\]^_ map to 0x00-0x1f, ? to DEL, space to NUL and / to
// ^_, as a hardware keyboard sends them; anything else goes as typed.
function ctrlByte(b) {
  if (b === 0x3f) return 0x7f;
  if (b === 0x20) return 0x00;
  if (b === 0x2f) return 0x1f;
  if ((b >= 0x40 && b <= 0x5f) || (b >= 0x61 && b <= 0x7a)) return b & 0x1f;
  return b;
}

function arrow(final) {
  const ctrl = ctrlArmed;
  armCtrl(false);
  if (ctrl) return CSI(final, true);
  // Full-screen programs (less, vim, the harness TUIs) switch the cursor keys to application mode.
  return currentTerminal()?.term.modes.applicationCursorKeysMode ? `\x1bO${final}` : CSI(final);
}

const KEYS = {
  esc: () => '\x1b',
  tab: () => '\t',
  up: () => arrow('A'),
  down: () => arrow('B'),
  right: () => arrow('C'),
  left: () => arrow('D'),
  '|': () => '|',
  '/': () => '/',   // armed Ctrl turns it into ^_ in the send hook, as a keyboard would
  '~': () => '~',
  'ctrl-c': () => '\x03',
  'ctrl-b': () => '\x02',
};

function setFont(delta) {
  const t = currentTerminal();
  const now = t?.term.options.fontSize ?? fontSize() ?? 14;
  const next = Math.min(FONT_MAX, Math.max(FONT_MIN, now + delta));
  store(FONT_KEY, next);
  if (t) {
    t.term.options.fontSize = next;
    fitTerminal();
  }
}

function setLineMode(on, { focus = true } = {}) {
  if (!phoneBar) return;
  const form = phoneBar.querySelector('.phone-line');
  form.hidden = !on;
  phoneBar.querySelector('[data-key="line"]').setAttribute('aria-pressed', String(on));
  store(LINE_KEY, on ? 1 : 0);
  fitTerminal();
  if (!focus) return;
  if (on) form.querySelector('input').focus();
  else currentTerminal()?.term.focus();
}

function onKey(key) {
  if (key === 'ctrl') return armCtrl(!ctrlArmed);
  if (key === 'font-down') return setFont(-1);
  if (key === 'font-up') return setFont(1);
  if (key === 'line') return setLineMode(phoneBar.querySelector('.phone-line').hidden);
  const seq = KEYS[key]?.();
  if (seq === undefined) return;
  // Esc, Tab and ^C/^B are already what Ctrl would make of them; a held Ctrl ends with this key either way.
  if (key !== '/' && key !== '|' && key !== '~') armCtrl(false);
  sendInput(seq);
}

function mountPhoneBar() {
  if (phoneBar) return;
  const box = el('div', 'phone-bar');
  box.append(...$('phone-footer').content.cloneNode(true).children);
  phoneBar = box;
  // A tap on a key must not move focus: the on-screen keyboard would close and the terminal lose its input.
  // So pointerdown is cancelled, and with it the mouse events that would move focus; iOS WebKit then sends no
  // click either, so a key acts on pointerup over the key it went down on. A swipe along the strip scrolls it
  // and cancels the pointer instead. click is left to a key pressed from a hardware keyboard (detail 0).
  let down = null;
  box.addEventListener('pointerdown', (e) => {
    down = e.target.closest('.key');
    if (down) e.preventDefault();
  });
  box.addEventListener('mousedown', (e) => {
    if (e.target.closest('.key')) e.preventDefault();
  });
  box.addEventListener('pointerup', (e) => {
    const k = e.target.closest('.key');
    if (k && k === down) onKey(k.dataset.key);
    down = null;
  });
  box.addEventListener('pointercancel', () => { down = null; });
  box.addEventListener('click', (e) => {
    const k = e.target.closest('.key');
    if (k && e.detail === 0) onKey(k.dataset.key);
  });
  const form = box.querySelector('.phone-line');
  const input = form.querySelector('input');
  // The line box sidesteps the iOS keyboard's trouble with xterm's hidden textarea (autocorrect, dictation,
  // swallowed keys): the text is edited as plain text and goes over in one piece with Enter.
  form.addEventListener('submit', (e) => {
    e.preventDefault();
    if (sendInput(`${input.value}\r`)) input.value = '';
    input.focus();
  });
  slots.termFooter.append(box);
  armCtrl(false);
  setLineMode(stored(LINE_KEY) === '1', { focus: false });
}

function unmountPhoneBar() {
  if (!phoneBar) return;
  phoneBar.remove();
  phoneBar = null;
  armCtrl(false);
  fitTerminal();
}

function syncPhone() {
  if (PHONE.matches && route.view === 'term') mountPhoneBar();
  else unmountPhoneBar();
}

PHONE.addEventListener('change', syncPhone);
hooks.view.push(syncPhone);
hooks.terminalOpen.push(({ term }) => {
  const size = fontSize();
  if (size && size !== term.options.fontSize) {
    term.options.fontSize = size;
    fitTerminal();
  }
});

// iOS keeps the layout viewport full height under the on-screen keyboard, so a 100dvh terminal view would put
// the key bar behind it. The visual viewport is the part above the keyboard; the phone CSS sizes the view to it.
if (window.visualViewport) {
  const vv = window.visualViewport;
  const root = document.documentElement;
  const sync = () => {
    root.style.setProperty('--vv-height', `${Math.round(vv.height)}px`);
    root.style.setProperty('--vv-top', `${Math.round(vv.offsetTop)}px`);
  };
  vv.addEventListener('resize', sync);
  vv.addEventListener('scroll', sync);
  sync();
}

// The worker caches nothing (sw.js); registering it is what makes the page installable and, with T10, lets
// push reach it. Not available on plain http other than localhost, which only the tests use.
if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('/sw.js').catch((err) => console.warn('service worker:', err.message));
}
// --- sim ---
// The Devices panel (T9) in slots.listPanels: GET /api/sim every 10 s, and only while the list view shows, since
// a status may reach the Mac over ssh. Slots are grouped by platform in the order sim prints them. The panel is
// out of the DOM while the service is unavailable (no sim, or it failed), so the slot stays empty and hidden; a
// failed fetch keeps what was shown. Open or collapsed is remembered per browser.
const SIM_POLL_MS = 10000;
const SIM_PLATFORM = { android: 'Android', ios: 'iOS', web: 'Web' };
const SIM_OPEN_KEY = 'agent-web.sim-open';
let simTimer = null;
let simGen = 0;
let simKey = null;

const simPanel = el('details', 'panel sim-panel');
simPanel.id = 'sim-panel';
const simSummary = el('summary', 'panel-head');
const simCount = el('span', 'count');
simSummary.append(el('h2', null, 'Devices'), simCount);
const simBody = el('div', 'sim-groups');
simPanel.append(simSummary, simBody);
try {
  simPanel.open = localStorage.getItem(SIM_OPEN_KEY) !== '0';
} catch {
  simPanel.open = true;
}
// Saved on the summary's click (keyboard activation is a click too) rather than on 'toggle', which setting .open
// above fires as well. The click comes before the toggle it causes, so the state to save is the opposite one.
simSummary.addEventListener('click', () => {
  try {
    localStorage.setItem(SIM_OPEN_KEY, simPanel.open ? '0' : '1');
  } catch { /* storage blocked: the panel opens next time */ }
});

function idleText(secs) {
  if (secs === null || secs === undefined) return 'unused';
  if (secs < 60) return 'used just now';
  if (secs < 3600) return `idle ${Math.floor(secs / 60)}m`;
  if (secs < 86400) return `idle ${Math.floor(secs / 3600)}h`;
  return `idle ${Math.floor(secs / 86400)}d`;
}

const holderOf = (lease) => (lease?.root ? lease.root.replace(/\/+$/, '').split('/').at(-1) : null);

function simRow(s) {
  const li = el('li', 'sim-slot');
  li.dataset.platform = s.platform;
  li.dataset.slot = String(s.slot);
  const head = el('span', 'sim-head');
  head.append(el('span', 'sim-num', `#${s.slot}`));
  head.append(el('span', 'sim-device mono', s.device ?? `${SIM_PLATFORM[s.platform] ?? s.platform} slot ${s.slot}`));
  if (s.state) {
    const st = el('span', 'pill sim-state', s.state);
    st.dataset.state = s.state;
    head.append(st);
  }
  const meta = el('span', 'sim-meta');
  const holder = holderOf(s.lease);
  const lease = el('span', `sim-lease${holder ? ' held' : ''}`, holder ?? 'free');
  if (holder) lease.title = `${s.lease.kind ?? ''} lease, ${s.lease.root}`.trim();
  meta.append(lease, el('span', 'sim-idle', idleText(s.idle_secs)));
  if (s.tunnel?.length) meta.append(el('span', 'sim-tunnel mono', `tunnel ${s.tunnel.join(', ')}`));
  li.append(head, meta);
  return li;
}

function renderSim(data) {
  const slotsList = data?.available ? data.slots ?? [] : [];
  if (!slotsList.length) {
    simPanel.remove();
    simKey = null;
    return;
  }
  const key = JSON.stringify(slotsList);
  if (key !== simKey) {
    simKey = key;
    const groups = new Map();
    for (const s of slotsList) {
      if (!groups.has(s.platform)) groups.set(s.platform, []);
      groups.get(s.platform).push(s);
    }
    simBody.replaceChildren(...[...groups].map(([platform, list]) => {
      const g = el('section', 'sim-group');
      g.dataset.platform = platform;
      const h = el('h3', 'sim-group-title', SIM_PLATFORM[platform] ?? platform);
      h.append(el('span', 'muted', ` ${list.length}`));
      const ul = el('ul', 'sim-slots');
      ul.append(...list.map(simRow));
      g.append(h, ul);
      return g;
    }));
    simCount.textContent = String(slotsList.length);
  }
  if (!simPanel.isConnected) slots.listPanels.append(simPanel);
}

async function simPoll() {
  clearTimeout(simTimer);
  const gen = ++simGen;
  let data;
  try {
    data = await api('/api/sim');
  } catch {
    data = undefined;
  }
  if (gen !== simGen || route.view !== 'list') return;
  if (data !== undefined) renderSim(data);
  simTimer = setTimeout(simPoll, SIM_POLL_MS);
}

function simStop() {
  clearTimeout(simTimer);
  simGen += 1;
}

hooks.view.push((r) => (r.view === 'list' ? simPoll() : simStop()));
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible' && route.view === 'list') simPoll();
});
