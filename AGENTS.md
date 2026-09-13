# AGENTS.md: working on agentic-framework

Instructions for any coding agent (Claude Code, OpenCode, Aider, Oh My Pi) that edits this repo.
The house rules in `~/workspace/CLAUDE.md` / `~/workspace/AGENTS.md` (kept here as
`config/workspace/CLAUDE.md`) apply first; this file adds what is specific to this repo.

## Purpose

This repo is the source of truth for `as1`, a headless Ubuntu box on the tailnet that runs
coding agents on behalf of Kyle's other devices. The design, in one line: Macs (`macbook`, `mini`)
reach as1 over Tailscale with SSH or mosh from WezTerm, land in tmux, and run one of four
harnesses there. Automation on as1 covers on-demand jobs launched from any device, scheduled jobs
via systemd timers, git-event jobs via a self-hosted GitHub runner, and a long-running queue worker.
Every unattended job works in its own git worktree, on an `agent/<slug>` branch, and ends in a
pull request, never a merge.

Everything an agent needs to install, configure or verify as1 and the Macs lives here: scripts,
configs, and the phase-by-phase plan. `docs/remote-agent-host-plan.md` is the authoritative design;
`docs/mac-client-setup.md` is the Mac companion. When code and docs disagree, fix one to match the
other in the same change.

## Status

Do not assume something exists because the plan describes it. Check this table and the tree.

| Phase | Scope | State |
|---|---|---|
| 1 access | sshd hardening, ufw, mosh, linger | scripted (`install-as1-root.sh`, `config/sshd`, `config/ufw.sh`) |
| 2 sessions | tmux, auto-attach, WezTerm domain | scripted (`config/tmux.conf`, `config/bashrc.d`, `config/wezterm-as1.lua`) |
| 3 harnesses | mise, uv, gh, four harnesses, secrets file, shared rules, Claude settings | scripted (`install-as1.sh`) |
| 4 clipboard bridge | `xclip` shim on as1, `clip-client` on the Mac | scripted (`bin/xclip`, `bin/clip-client-mac.sh`) |
| 5 automation | `agent` CLI, `agent-worker`, systemd units, GitHub runner workflow | planned, not started |
| 6 isolation | `docker/Dockerfile.agent-sandbox`, `agent run --sandbox` | planned, not started |

When you implement part of phase 5 or 6, update this table and section 8 of the plan doc.

## Layout

| Path | What it is | Installed to |
|---|---|---|
| `install-as1.sh` | idempotent user-level setup on as1, phases 2 to 4, plus toolchains and harnesses | run in place |
| `install-as1-root.sh` | phase 1 root steps: password check, sshd, ufw, apt, linger, tailscale | run by a human with sudo |
| `install-mac.sh` | idempotent Mac client setup, phases 1 to 4 | run on the Mac |
| `bin/xclip` | clipboard shim; serves the attached Mac's clipboard to Claude Code | `~/.local/bin/xclip` on as1 |
| `bin/clip-client-mac.sh` | `targets`/`image`/`text`/`copy` over pbpaste, pngpaste, pbcopy | `/usr/local/bin/clip-client` on the Mac |
| `config/tmux.conf` | OSC 52 passthrough, mouse, history, SSH_CONNECTION refresh | `~/.tmux.conf` (symlink) |
| `config/bashrc.d/agents-env.sh` | PATH and secrets for every shell, including non-interactive SSH | sourced at top of `~/.bashrc` |
| `config/bashrc.d/mise.sh`, `tmux-autoattach.sh` | interactive-only shell bits | sourced at bottom of `~/.bashrc` |
| `config/sshd/10-hardening.conf` | key or password for `kyle` (no empty passwords, `MaxAuthTries 4`), no root, `AllowUsers kyle` | `/etc/ssh/sshd_config.d/` (root script) |
| `config/ufw.sh` | tailnet-only inbound, LAN SSH fallback | run by root script |
| `config/ssh_config.as1` | as1 to Mac SSH block for the shim; `__MACUSER__` placeholder | marker block in `~/.ssh/config` on as1 |
| `config/ssh_config.mac` | `Host as1` and `as1-lan` | marker block in `~/.ssh/config` on the Mac |
| `config/wezterm-as1.lua` | SSH domain `as1`, Cmd+Shift+A tab | `~/.config/wezterm/wezterm-as1.lua` |
| `config/claude-settings.json` | Claude Code allow and deny lists | `~/.claude/settings.json` (symlink) |
| `config/workspace/CLAUDE.md` | house rules for all repos under `~/workspace` | `~/workspace/CLAUDE.md` and `~/workspace/AGENTS.md` (symlinks) |
| `config/as1.pub` | as1's public key, for Mac `authorized_keys` when as1 is unreachable | appended by `install-mac.sh` |
| `env.example` | secret variable names only | copied to `~/.config/agents/env` once, mode 600 |
| `docs/` | plan, Mac setup, runbook (to be written) | read only |

Planned but absent: `bin/agent`, `bin/agent-worker`, `systemd/`, `docker/`, `docs/runbook.md`.

## Install contract

The install scripts are re-run after every change and must stay idempotent. Preserve these
mechanisms rather than inventing new ones:

- **Symlinks, not copies**, for configs on as1. `install-as1.sh` has a `link` helper that backs up
  a real file in the way and is a no-op when the link already points at the repo. Edit configs in
  the repo, never the installed copy.
- **Marker blocks** for files the scripts share with the user, such as `~/.bashrc` and
  `~/.ssh/config`. The `block` helper wraps content in `# >>> agentic-framework:<marker> >>>` and
  `# <<< agentic-framework:<marker> <<<` and replaces the block in place on re-run. Use a new
  marker name for new content; never append unmarked lines.
- **Placeholders** are rendered at install time: `__MACUSER__` in `config/ssh_config.as1`
  (from `MAC_USER=`), `<macuser>` in the docs. Do not hardcode a login name.
- **Network installs are behind `--no-tools`** in `install-as1.sh`. Anything that downloads goes in
  that branch, guarded with `command -v` so a re-run skips it.
- **Root and user steps stay in separate scripts.** Nothing in `install-as1.sh` or `install-mac.sh`
  may call `sudo` on as1; `install-mac.sh` may sudo only for the two documented steps.

## Change conventions

- Shell is bash with `set -euo pipefail` (the `xclip` shim uses `set -u` only, on purpose: it
  must fail soft so Claude Code falls through). Run `bash -n`, and `shellcheck` where available,
  on every script you touch. Header comments state what the file does and where it is installed; keep them current.
- Configs are declarative and commented. Say why a setting exists, not what it does.
- Secrets never enter the repo. `env.example` carries names only. `.gitignore` excludes `env`,
  `.env` and `*.local`; if you add a file that can hold a value, add it there too.
- Docs move with code. A change to a script or config updates the matching phase in
  `docs/remote-agent-host-plan.md` or `docs/mac-client-setup.md`, including the test commands.
- Keep the two Macs interchangeable. Nothing may depend on `macbook` specifically; the shim
  discovers the attached client via `SSH_CONNECTION` and `tailscale whois`.
- Claude Code specifics belong in `config/claude-settings.json`; cross-harness rules belong in
  `config/workspace/CLAUDE.md`. Do not put Claude-only behaviour in the shared rules.

## Verification

Run these on as1 without sudo before you open a PR. `shellcheck` is not installed on as1 yet;
`mise use -g shellcheck@latest` adds it without sudo, otherwise skip that line and say so.

```
shellcheck install-as1.sh install-mac.sh install-as1-root.sh bin/xclip bin/clip-client-mac.sh config/ufw.sh config/bashrc.d/*.sh
bash -n install-as1.sh install-mac.sh install-as1-root.sh bin/xclip
tmux -f config/tmux.conf new -d -s check && tmux show -s set-clipboard && tmux kill-session -t check
CLIP_BRIDGE_FAKE=/usr/share/pixmaps/debian-logo.png bin/xclip -selection clipboard -t TARGETS -o     # image/png
CLIP_BRIDGE_FAKE=/usr/share/pixmaps/debian-logo.png bin/xclip -selection clipboard -t image/png -o | file -
python3 -m json.tool config/claude-settings.json >/dev/null
```

`./install-as1.sh --no-tools` is safe to re-run on as1 and is the real idempotency test, but it
rewrites `~/.bashrc`, `~/.ssh/config` and `~/.claude/settings.json` on this host. Run it only when
your change touches those paths and say so in the PR.

Needs a human, do not attempt: `install-as1-root.sh`, `config/ufw.sh`, anything under
`config/sshd`, `install-mac.sh`, and every joint checkpoint in the docs that involves a Mac.
Report those as unverified in the PR body.

## Boundaries

In addition to the workspace house rules:

- Never run or "test" the root script, the ufw script or an sshd config, and never reload
  `ssh`, `ufw` or `tailscale`. A mistake there locks the only operator out of a headless box.
- Never read, print or alter key material: `~/.ssh/id_ed25519`, `authorized_keys`,
  `~/.config/agents/env`. `config/as1.pub` is the one public key in the repo and may be read.
- Never `apt install xclip` or otherwise put a real `xclip` ahead of the shim.
- Never change the `AllowUsers`, `PasswordAuthentication` or firewall defaults without a note in
  the PR title; a reviewer must see it before merge.
- Do not edit `~/.bashrc`, `~/.ssh/config` or `~/.claude/settings.json` by hand; change the repo
  file and let the install script render it.
- One agent per worktree. If `~/workspace/agentic-framework.wt/<slug>` exists for another job,
  pick a new slug.

## Automation model

Phase 5 and 6 work should fit this shape, taken from the plan doc, so that every device gets the
same interface regardless of harness:

- `agent run <repo> "<task>" [--harness claude|opencode|aider|omp] [--interactive] [--budget N] [--sandbox]`
  creates `~/workspace/<repo>.wt/<slug>` on branch `agent/<slug>`, opens window `<slug>` in tmux
  session `agents`, runs the harness headless with a budget cap, logs to `~/agents/logs/<slug>.jsonl`,
  then commits, pushes and runs `gh pr create`, printing the PR URL to stdout and `~/agents/logs/<slug>.url`.
- `agent ls | attach | logs | stop | clean <slug>` wrap tmux and `git worktree remove`.
- Scheduled: `systemd/agent@.service` plus `agent-<job>.timer`, `EnvironmentFile=%h/.config/agents/env`,
  prompts in `~/agents/prompts/*.md`, enabled with `systemctl --user`.
- Git events: self-hosted runner labelled `as1`, workflow triggered by `/agent ` issue comments and
  the `agent-review` PR label. No inbound ports.
- Queue: `agent-worker` watches `~/agents/queue/*.md`, moves to `done/` or `failed/`, `MAX_PARALLEL=2`,
  notifies via ntfy.
- Permissions: `--permission-mode acceptEdits` for headless runs on the host;
  `--dangerously-skip-permissions` only inside the Docker sandbox with the worktree mounted at `/work`.
- From a Mac the entry point is `alias agent='ssh -q as1 agent'`; non-interactive SSH must never
  auto-attach to tmux, which is why `tmux-autoattach.sh` checks `SSH_TTY` and `$-`.
