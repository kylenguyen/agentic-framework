// tests/e2e/web/helpers.mjs: what the specs need besides the browser. Specs run inside the tests/e2e/web.sh
// container, next to the server, as the same login with the same environment (HOME=/work/home,
// AGENT_TMUX_SOCKET, AGENT_WEB_*), so a command run here acts on exactly the host the page shows.
//
//   BASE, LOGIN             the server's URL and the allowed login
//   sh(cmd)                 run a shell command in the container, return trimmed stdout (throws on non-zero)
//   agent(...args)          run bin/agent with that environment, return trimmed stdout
//   sessions()              `agent ls --json`, parsed
//   tag(testInfo)           a short per-project suffix ("c" for chromium, "w" for webkit), so both projects can
//                           make sessions and worktrees without clashing on one host
//   newShell(slug?)         `agent new demo --harness shell [--slug S] --no-attach`; returns the session name
//   restartServer()         SIGTERM to the running server; fixture.sh's supervisor starts a new one. Resolves
//                           once the new process answers /api/health
//   termText(page)          the xterm buffer as text (needs the page loaded with ?test=1)
//   home, workspace         paths in the container

import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import path from 'node:path';

export const LOGIN = process.env.AGENT_WEB_ALLOW ?? 'tester@example.test';
export const BASE = `http://127.0.0.1:${process.env.AGENT_WEB_PORT ?? 7690}`;
export const home = process.env.HOME;
export const workspace = path.join(home, 'workspace');
const PIDFILE = '/work/server.pid';

export function sh(cmd) {
  return execFileSync('sh', ['-c', cmd], { encoding: 'utf8' }).trim();
}

export function agent(...args) {
  return execFileSync('agent', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
}

export const sessions = () => JSON.parse(agent('ls', '--json'));

export const tag = (testInfo) => (testInfo.project.name.includes('webkit') ? 'w' : 'c');

export function newShell(slug) {
  const args = ['new', 'demo', '--harness', 'shell'];
  if (slug) args.push('--slug', slug);
  return agent(...args, '--no-attach').split('\n').at(-1);
}

async function healthy() {
  try {
    const r = await fetch(`${BASE}/api/health`, { headers: { 'Tailscale-User-Login': LOGIN } });
    return r.ok;
  } catch {
    return false;
  }
}

export async function restartServer() {
  const old = readFileSync(PIDFILE, 'utf8').trim();
  process.kill(Number(old), 'SIGTERM');
  const end = Date.now() + 15000;
  while (Date.now() < end) {
    const now = readFileSync(PIDFILE, 'utf8').trim();
    if (now !== old && await healthy()) return;
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error('the server did not come back within 15 s');
}

export function termText(page) {
  return page.evaluate(() => {
    const b = window.__term?.buffer.active;
    if (!b) return '';
    const lines = [];
    for (let i = 0; i < b.length; i++) lines.push(b.getLine(i)?.translateToString(true) ?? '');
    return lines.join('\n');
  });
}
