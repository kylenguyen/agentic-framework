// web/lib/sim.mjs: GET /api/sim, the simulator slots for the dashboard's Devices panel (docs/web-dashboard-plan.md
// T9). It runs `sim status --json` (bin/sim, the simulator service) and passes its slots through unchanged.
//
//   getSim(req, res, ctx)        the route: {available: false} or {available: true, slots: [...]}
//   simStatus(env, {timeout})    the same result, for the route and the tests
//   simBin(env)                  $SIM_BIN, else `sim` looked up on env.PATH
//
// slots is the array `sim status --json` prints, one object per slot in sim's order (platform by platform):
//   {platform: "android"|"web"|"ios", slot: N, device: str|null, state: str|null, idle_secs: N|null,
//    lease: null|{kind: "mcp"|"cli", pid, root, since, until}, tunnel: [port...]}
// device and state are null for web slots, idle_secs null for a slot never used, lease.root the leasing
// worktree's absolute path, tunnel the ports of an iOS slot's background tunnel. sim prints a bare array; an
// object wrapper with a slots array (should a later contract add a version field around it) is unwrapped too.
// Anything else, a non-zero exit, no sim at all or no answer within 10 s means the service is unavailable, and
// the page hides the panel.

import { runCommand } from './agent.mjs';

export const SIM_TIMEOUT_MS = 10000;

export function simBin(env) {
  return env.SIM_BIN || 'sim';
}

// One `sim status` at a time per command and PATH: every open page polls, and on a host with iOS slots a status
// may reach the Mac over ssh. Later callers share the run in flight; nothing is cached after it ends, so a page
// never sees an answer older than its own request.
const inFlight = new Map();

export function simStatus(env, { timeout = SIM_TIMEOUT_MS } = {}) {
  const key = `${simBin(env)}\0${env.PATH ?? ''}`;
  let p = inFlight.get(key);
  if (!p) {
    p = run(env, timeout).finally(() => inFlight.delete(key));
    inFlight.set(key, p);
  }
  return p;
}

async function run(env, timeout) {
  const r = await runCommand(simBin(env), ['status', '--json'], env, { timeout });
  if (r.code !== 0 || r.timedOut) return { available: false };
  let data;
  try {
    data = JSON.parse(r.stdout);
  } catch {
    return { available: false };
  }
  const slots = Array.isArray(data) ? data : data?.slots;
  if (!Array.isArray(slots)) return { available: false };
  return { available: true, slots: slots.filter((s) => s && typeof s === 'object' && !Array.isArray(s)) };
}

export function getSim(req, res, ctx) {
  return simStatus(ctx.env);
}
