// web/lib/agent.mjs: the server's only way to run bin/agent (and the other commands a route needs). Everything
// goes through spawn with an argument array, never a shell (security rule 5), with the server's ctx.env so
// the tests' throwaway HOME and tmux socket reach the child.
//
//   runCommand(file, args, env, opts?)   -> {code, signal, timedOut, stdout, stderr}; never throws for a non-zero
//                                           exit. opts: timeout (ms, default 15000), cwd.
//   runAgent(args, env, opts?)           -> {stdout, stderr} on exit 0; otherwise throws HttpError mapped from
//                                           the failure (see agentError).
//   listSessions(env)                    -> the `agent ls --json` array.
//   findSession(env, name)               -> that base session's object from the list, or HttpError 404. Every
//                                           route that takes a session name calls this first.
//   agentBin(env)                        -> $AGENT_BIN, else the working tree's bin/agent.

import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { HttpError } from './auth.mjs';

// Next to server.mjs's ../bin, so a server started from a worktree runs that worktree's agent.
const REPO_AGENT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../bin/agent');
export const TIMEOUT_MS = 15000;

export function agentBin(env) {
  return env.AGENT_BIN || REPO_AGENT;
}

export function runCommand(file, args, env, { timeout = TIMEOUT_MS, cwd } = {}) {
  return new Promise((resolve) => {
    // spawn rather than execFile, which drops `detached`: the child needs a session of its own with no
    // controlling terminal, because `agent kill` asks about a dirty worktree on /dev/tty and a server started
    // from a terminal would sit there until the timeout. Still an argument array and no shell (rule 5).
    const child = spawn(file, args, { env, cwd, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
    const out = [];
    const err = [];
    let timedOut = false;
    let spawnError = '';
    child.stdout.on('data', (b) => out.push(b));
    child.stderr.on('data', (b) => err.push(b));
    const timer = setTimeout(() => {
      timedOut = true;
      // The whole group: 'close' waits for the pipes, which a grandchild (sim's ssh to the Mac) would hold open
      // past the timeout if only the direct child went.
      try {
        process.kill(-child.pid, 'SIGTERM');
      } catch {
        child.kill('SIGTERM');
      }
    }, timeout);
    child.on('error', (e) => { spawnError = `${file}: ${e.code ?? e.message}`; });
    child.on('close', (code, signal) => {
      clearTimeout(timer);
      resolve({
        code: spawnError ? null : code,
        signal,
        timedOut,
        stdout: Buffer.concat(out).toString('utf8'),
        stderr: Buffer.concat(err).toString('utf8') || spawnError,
      });
    });
  });
}

function lastLine(text) {
  const lines = String(text).split('\n').map((l) => l.trim()).filter(Boolean);
  return (lines.at(-1) ?? '').replace(/^agent: /, '');
}

// The order matters: "no such session" and "no such repo" are exit 2 as well, and a failed `git worktree add`
// (the branch is checked out elsewhere, say) is the one conflict `agent new` reports, with exit 1.
export function agentError(r, args) {
  const msg = lastLine(r.stderr);
  if (/no such session/.test(r.stderr)) return new HttpError(404, msg);
  if (/no such repo/.test(r.stderr)) return new HttpError(400, msg);
  if (/git worktree add failed/.test(r.stderr)) return new HttpError(409, msg);
  if (r.code === 2) return new HttpError(400, msg || 'bad request');
  console.error(`agent ${args[0] ?? ''}: ${r.timedOut ? 'timed out' : `exit ${r.code ?? r.signal}`}: ${msg}`);
  return new HttpError(500, msg || 'agent failed');
}

export async function runAgent(args, env, opts) {
  const r = await runCommand(agentBin(env), args, env, opts);
  if (r.code !== 0) throw agentError(r, args);
  return { stdout: r.stdout, stderr: r.stderr };
}

export async function listSessions(env) {
  const { stdout } = await runAgent(['ls', '--json'], env);
  try {
    return JSON.parse(stdout);
  } catch {
    throw new HttpError(500, 'agent ls --json printed something that is not JSON');
  }
}

// Names are compared against the list, never passed on unchecked: what reaches `agent` is a name tmux already
// has, and execFile means a shell character in it is only ever a character.
export async function findSession(env, name) {
  const found = (await listSessions(env)).find((s) => s.name === name);
  if (!found) throw new HttpError(404, `no such session: ${name}`);
  return found;
}
