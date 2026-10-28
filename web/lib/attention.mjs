// web/lib/attention.mjs: which sessions need the user (docs/web-dashboard-plan.md T10). Three sources, in the
// order the effective attention takes them:
//   - a hook: the session's own `attention` from `agent ls --json` (Claude Code hooks, T11), passed through as is
//   - an exit: the state went from running to exited while the server watched -> {reason:'exited', source:'tmux'}
//   - the quiet heuristic, for harnesses without a usable hook (HARNESS_ALERTS): the harness window was active
//     within ACTIVE_SECS at an earlier poll and has now been silent for quietSecs or more -> {reason:'quiet',
//     source:'heuristic'}; cleared when its activity moves again
// The last two live only in this process. Opening a session (POST /seen) clears them as well as the tmux options,
// and they stay clear until the next rising edge: new activity then silence, or another exit.
//
//   createAttention({quietSecs, now, onRaise})  the pure state machine. update(list) takes one `agent ls --json`
//       array and returns it with the effective attention; onRaise(session, attention) runs once per rising edge
//       (null to set, or a new since), never for what was already set at the first poll. now() is epoch seconds.
//       merge(list) applies what is held without advancing anything; clear(name) is the /seen side.
//   createWatcher({list, attention, intervalMs, log})  polls list() into attention.update(). A tick is skipped
//       while the previous one runs; a failing list() is logged once per run of failures and polled again.
//   startAlerts(env, config) / stopAlerts()  the server's wiring: a watcher on listSessions every 2 s, pushing
//       each rising edge (push.mjs). Route handlers: getSessions (GET /api/sessions with the effective attention)
//       and markSeen (POST /api/sessions/:name/seen).

import { findSession, listSessions, runAgent } from './agent.mjs';
import { pushFor } from './push.mjs';

// T11: Codex's `notify` appends a JSON argument that `agent attention set` would read as a session name, so Codex
// is watched like omp and opencode. A harness missing here (shell) never gets the heuristic.
export const HARNESS_ALERTS = { claude: 'hook', codex: 'heuristic', omp: 'heuristic', opencode: 'heuristic' };
export const ACTIVE_SECS = 10;
export const POLL_MS = 2000;

const key = (a) => (a ? `${a.reason}|${a.source}|${a.since}` : '');

export function createAttention({ quietSecs = 45, now = () => Date.now() / 1000, onRaise = () => {} } = {}) {
  const mem = new Map();   // name -> {state, armed, activity, quiet, exited, last}
  let primed = false;

  function effective(s, m) {
    return s.attention ?? m?.exited ?? m?.quiet ?? null;
  }

  function update(list) {
    const t = now();
    const seen = new Set();
    const out = list.map((s) => {
      seen.add(s.name);
      let m = mem.get(s.name);
      if (!m) {
        m = { state: s.state, armed: false, activity: s.activity, quiet: null, exited: null, last: null };
        mem.set(s.name, m);
      }
      if (m.state === 'running' && s.state === 'exited') {
        m.exited = { reason: 'exited', source: 'tmux', since: Math.floor(t) };
      } else if (s.state === 'running') {
        m.exited = null;
      }
      m.state = s.state;

      if (s.state === 'running' && HARNESS_ALERTS[s.harness] === 'heuristic') {
        if (m.quiet && s.activity > m.activity) m.quiet = null;
        const silent = t - s.activity;
        if (silent <= ACTIVE_SECS) {
          m.armed = true;
        } else if (m.armed && silent >= quietSecs) {
          m.armed = false;
          m.quiet = { reason: 'quiet', source: 'heuristic', since: Math.floor(t) };
        }
      } else {
        m.armed = false;
        m.quiet = null;
      }
      m.activity = s.activity;

      const att = effective(s, m);
      const k = key(att);
      if (k && k !== m.last && primed) onRaise(s, att);
      m.last = k;
      return { ...s, attention: att };
    });
    for (const name of mem.keys()) if (!seen.has(name)) mem.delete(name);
    primed = true;
    return out;
  }

  function merge(list) {
    return list.map((s) => ({ ...s, attention: effective(s, mem.get(s.name)) }));
  }

  // The hook's own attention goes with `agent attention clear`; what is held here goes now, and armed with it,
  // so a quiet session raises again only after it has been active again.
  function clear(name) {
    const m = mem.get(name);
    if (!m) return;
    m.quiet = null;
    m.exited = null;
    m.armed = false;
  }

  return { update, merge, clear };
}

export function createWatcher({ list, attention, intervalMs = POLL_MS, log = (line) => console.error(line) }) {
  let busy = false;
  let failing = false;
  let timer = null;

  async function tick() {
    if (busy) return false;
    busy = true;
    try {
      attention.update(await list());
      if (failing) log('agent-web: attention watcher: agent ls works again');
      failing = false;
    } catch (err) {
      if (!failing) log(`agent-web: attention watcher: ${err.message}`);
      failing = true;
    } finally {
      busy = false;
    }
    return true;
  }

  return {
    tick,
    start() {
      if (timer) return;
      timer = setInterval(tick, intervalMs);
      timer.unref?.();
      tick();
    },
    stop() {
      clearInterval(timer);
      timer = null;
    },
  };
}

// --- server wiring ---------------------------------------------------------------------------------------------
// Keyed by the server's config object, which every ctx carries, so in-process test servers each keep their own.
const alerts = new WeakMap();
const watchers = new Set();

export function pushPayload(s, att) {
  return {
    title: `${s.name} needs you`,
    body: `${att.reason} · ${s.harness}`,
    url: `/#/s/${encodeURIComponent(s.name)}`,
    tag: s.name,
  };
}

export function startAlerts(env, config) {
  const push = pushFor(config);
  try {
    push.keys();   // VAPID keys on first start, not on the first subscribe
  } catch (err) {
    console.error(`agent-web: cannot set up push keys in ${config.state}: ${err.message}`);
  }
  const attention = createAttention({
    quietSecs: config.quietSecs,
    onRaise: (s, att) => {
      push.sendAll(pushPayload(s, att)).catch((err) => console.error(`agent-web: push: ${err.message}`));
    },
  });
  const watcher = createWatcher({ list: () => listSessions(env), attention });
  alerts.set(config, { attention, watcher });
  watchers.add(watcher);
  watcher.start();
  return { attention, watcher };
}

export function stopAlerts() {
  for (const w of watchers) w.stop();
  watchers.clear();
}

export async function getSessions(req, res, ctx) {
  const list = await listSessions(ctx.env);
  const a = alerts.get(ctx.config);
  return a ? a.attention.merge(list) : list;
}

export async function markSeen(req, res, ctx) {
  const s = await findSession(ctx.env, ctx.params.name);
  await runAgent(['attention', 'clear', s.name], ctx.env);
  alerts.get(ctx.config)?.attention.clear(s.name);
  return { ok: true };
}
