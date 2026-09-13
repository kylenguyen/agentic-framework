# House rules for agents working under ~/workspace on the agent host

These apply to every harness (Claude Code, OpenCode, Oh My Pi) and every repo in this directory.
Repo-level CLAUDE.md / AGENTS.md files add to these; they do not override them.

## Git

- Work on a branch named `agent/<slug>`; never commit directly to `main`.
- Unattended runs use a git worktree under `~/workspace/<repo>.wt/<slug>`. Never operate on a checkout another agent is using.
- Commit style: imperative subject line under 72 characters, blank line, short body explaining why.
- Never force-push. Never rewrite history that has been pushed. Never delete branches you did not create.
- Open a pull request instead of merging. Do not merge your own PRs.

## Boundaries

- Never read, print or modify `~/.config/agents` (secrets) or `~/.ssh`.
- Never run `sudo`, change system services, firewall or sshd settings.
- Stay inside the repo you were given. Do not touch other repos under ~/workspace.
- No destructive shell commands (`rm -rf` outside the worktree, `git clean -fdx` on shared checkouts, dropping databases).

## Working style

- Run the repo's tests before committing. If they fail and you cannot fix them, say so in the PR body.
- Keep changes scoped to the task. Do not reformat unrelated files.
- Prefer small commits with clear messages over one large commit.
- Report what was verified and what was not.
