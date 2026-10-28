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
