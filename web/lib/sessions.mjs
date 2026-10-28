// web/lib/sessions.mjs: the session and repo routes of docs/web-dashboard-plan.md section 2 (HTTP API), as
// route handlers server.mjs lists. Each input is validated here before it reaches bin/agent (security rule 5);
// bin/agent repeats its own checks, so this is the first wall, not the only one.
//
// GET /api/sessions lives in attention.mjs, which merges the server's attention into the list.

import { existsSync, readdirSync, statSync } from 'node:fs';
import path from 'node:path';
import { HttpError, readJson } from './auth.mjs';
import { findSession, runAgent, runCommand } from './agent.mjs';

export const HARNESSES = ['claude', 'codex', 'omp', 'opencode', 'shell'];
const REPO_RE = /^[A-Za-z0-9._-]+$/;
const SLUG_RE = /^[a-z0-9][a-z0-9-]{0,40}$/;
const MAX_FILES = 50;

function workspace(env) {
  return path.join(env.HOME || '/', 'workspace');
}

// The same test as bin/agent's repo_list: a directory directly under ~/workspace with a .git (a directory, or
// the file a linked worktree has), not one of the <repo>.wt folders that hold worktrees.
export function isRepo(env, name) {
  if (typeof name !== 'string' || !REPO_RE.test(name) || name === '.' || name === '..' || name.endsWith('.wt')) {
    return false;
  }
  const dir = path.join(workspace(env), name);
  try {
    return statSync(dir).isDirectory() && existsSync(path.join(dir, '.git'));
  } catch {
    return false;
  }
}

export function listRepos(env) {
  let names;
  try {
    names = readdirSync(workspace(env));
  } catch {
    return [];
  }
  return names.filter((n) => isRepo(env, n)).sort();
}

export function getRepos(req, res, ctx) {
  return listRepos(ctx.env);
}

export async function createSession(req, res, ctx) {
  const { repo, harness, slug } = await readJson(req);
  if (typeof repo !== 'string' || !REPO_RE.test(repo) || repo.endsWith('.wt')) {
    throw new HttpError(400, 'repo must be a directory name under ~/workspace');
  }
  if (!isRepo(ctx.env, repo)) throw new HttpError(400, `no such repo: ${repo}`);
  if (!HARNESSES.includes(harness)) throw new HttpError(400, `harness must be one of: ${HARNESSES.join(' ')}`);
  const args = ['new', repo, '--harness', harness];
  if (slug !== undefined && slug !== null && slug !== '') {
    if (typeof slug !== 'string' || !SLUG_RE.test(slug)) {
      throw new HttpError(400, 'slug must be lower-case letters, digits and -, at most 41 characters');
    }
    args.push('--slug', slug);
  }
  args.push('--no-attach');
  // With --no-attach the name is the only thing on stdout; notes and git's output go to stderr. `agent new` is
  // the one call that can start the tmux server, hence the scope (agent.mjs, scoped).
  const { stdout } = await runAgent(args, ctx.env, { scope: true });
  const name = stdout.trim().split('\n').at(-1);
  if (!name) throw new HttpError(500, 'agent new printed no session name');
  return { name };
}

// The lines are git's porcelain v1 as is ("XY path"): the leading space of " M a.txt" is part of the status.
export async function worktreeStatus(req, res, ctx) {
  const s = await findSession(ctx.env, ctx.params.name);
  if (!s.worktree || !existsSync(s.cwd)) return { worktree: false, dirty: false, files: [] };
  const r = await runCommand('git', ['-C', s.cwd, 'status', '--porcelain'], ctx.env);
  if (r.code !== 0) throw new HttpError(500, `git status failed in ${s.cwd}`);
  const lines = r.stdout.split('\n').filter(Boolean);
  return { worktree: true, dirty: lines.length > 0, files: lines.slice(0, MAX_FILES) };
}

// Neither flag: bin/agent has no terminal to ask on (runCommand detaches), so a dirty worktree is kept and a
// clean one removed, which is what the kill dialog promises.
export async function killSession(req, res, ctx) {
  const body = await readJson(req);
  const s = await findSession(ctx.env, ctx.params.name);
  const args = ['kill', s.name];
  if (body.force === true) args.push('--force');
  if (body.keepWorktree === true) args.push('--keep-worktree');
  const { stdout } = await runAgent(args, ctx.env);
  return { output: stdout.trim() };
}
