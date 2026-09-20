# House rules for agents working under ~/workspace on the agent host

These apply to every harness (Claude Code, Codex, OpenCode, Oh My Pi) and every repo in this directory.
Repo-level CLAUDE.md / AGENTS.md files add to these; they do not override them.

## Git

- Committing and pushing straight to `main` is allowed when the operator asks for it: these repos have one
  author, so a tested change does not need a branch or a review to land. Fast-forward or rebase onto
  `origin/main`; never merge `main` back in, and never push work whose tests you have not run and reported.
- Branches named `agent/<slug>` remain the default for anything unattended, unfinished, or meant to be read
  before it lands, and for any repo that gains a second author.
- Unattended runs use a git worktree under `~/workspace/<repo>.wt/<slug>`. Never operate on a checkout another agent is using.
- Commit style: imperative subject line under 72 characters, blank line, short body explaining why.
- Never force-push. Never rewrite history that has been pushed. Never delete branches you did not create.
- A pull request is for when the operator wants one. Do not merge anyone else's.

## Boundaries

- Never read, print or modify `~/.config/agents` (secrets) or `~/.ssh`.
- Never run `sudo`, change system services, firewall or sshd settings.
- Stay inside the repo you were given. Do not touch other repos under ~/workspace.
- No destructive shell commands (`rm -rf` outside the worktree, `git clean -fdx` on shared checkouts, dropping databases).

## Working style

- Run the repo's tests before committing. If they fail and you cannot fix them, say so in the commit body,
  or in the PR body where there is a PR.
- Keep changes scoped to the task. Do not reformat unrelated files.
- Prefer small commits with clear messages over one large commit.
- Report what was verified and what was not.
