# AGENTS.md: working on agentic-framework

Instructions for any coding agent (Claude Code, OpenCode, Oh My Pi) that edits this repo.
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
`docs/mac-client-setup.md` is the Mac companion; `docs/setup-from-scratch.md` is the ordered runbook
from bare machines to the working setup, and lists every value the repo hardcodes. When code and docs
disagree, fix one to match the other in the same change.

## Status

Do not assume something exists because the plan describes it. Check this table and the tree.

| Phase | Scope | State |
|---|---|---|
| 1 access | sshd hardening, ufw, apt (tmux mosh gh zsh git curl file jq unattended-upgrades), zsh + chsh, linger | scripted (`install-as1-root.sh`, `config/sshd`, `config/ufw.sh`) |
| 2 sessions | tmux, auto-attach, zsh + oh-my-zsh, WezTerm domain | scripted (`config/tmux.conf`, `config/zshenv`, `config/zshrc`, `config/bashrc.d`, `config/wezterm-as1.lua`) |
| 3 harnesses | mise, uv, gh, three harnesses, secrets file, shared rules, Claude settings | scripted (`install-as1.sh`) |
| 4 clipboard bridge | Mac pushes images on Cmd+V; `clip-put` spool and `xclip` shim on as1 | scripted (`bin/xclip`, `bin/clip-put`, `bin/clip-push-mac.sh`, Cmd+V in `config/wezterm-as1.lua`) |
| 5 automation | `agent` CLI, `agent-worker`, systemd units, GitHub runner workflow | planned, not started |
| 6 isolation | `docker/Dockerfile.agent-sandbox`, `agent run --sandbox` | planned, not started |

When you implement part of phase 5 or 6, update this table and section 8 of the plan doc.

## Layout

| Path | What it is | Installed to |
|---|---|---|
| `README.md` | orientation: which doc to read, what the three scripts do | read only |
| `install-as1.sh` | idempotent user-level setup on as1, phases 2 to 4, plus oh-my-zsh, toolchains and harnesses (Claude Code via the native installer when absent) | run in place |
| `install-as1-root.sh` | phase 1 root steps: password check, sshd, ufw, apt (tmux mosh gh zsh git curl file jq unattended-upgrades), chsh to zsh, linger, tailscale | run by a human with sudo |
| `install-mac.sh` | idempotent Mac client setup, phases 1, 2 and 4; no sudo; writes a minimal `wezterm.lua` only when none exists; `path` marker block in `~/.zshrc`; ends by making `ssh as1` keyless: stores as1's host key on first contact (fingerprint printed), installs the repo key over an already-trusted key with `ssh-copy-id -f`, or runs `ssh-copy-id` and asks for kyle's password once; never deletes a stored host key or edits `authorized_keys` directly; exits 1 with the fix when it cannot finish | run on the Mac |
| `bin/xclip` | clipboard shim; serves the spool the Mac pushed (`~/.clip/latest`) to Claude Code, copies go back via OSC 52 | `~/.local/bin/xclip` on as1 |
| `bin/clip-put` | stdin to the spool, atomic, mode 600; `--clear` | `~/.local/bin/clip-put` on as1 |
| `bin/clip-push-mac.sh` | pngpaste or pbpaste piped over `ssh as1-clip` into `clip-put`, prints the type; WezTerm runs `--if-image` on Cmd+V | `~/.local/bin/clip-push` on the Mac |
| `config/tmux.conf` | OSC 52 passthrough, mouse, history, SSH_CONNECTION refresh | `~/.tmux.conf` (symlink) |
| `config/zshenv` | sources `agents-env.sh` for every zsh, incl. `ssh as1 <cmd>` | `~/.zshenv` (symlink) |
| `config/zshrc` | oh-my-zsh (robbyrussell, git plugin, updates off) then the interactive fragments | `~/.zshrc` (symlink) |
| `config/bashrc.d/agents-env.sh` | PATH and secrets for every shell, including non-interactive SSH; POSIX sh, shared by bash and zsh | sourced at top of `~/.bashrc` and from `~/.zshenv` |
| `config/bashrc.d/mise.sh`, `tmux-autoattach.sh` | interactive-only shell bits, valid in bash and zsh | sourced at bottom of `~/.bashrc` and end of `~/.zshrc` |
| `config/sshd/10-hardening.conf` | key or password for `kyle` (no empty passwords, `MaxAuthTries 4`), no root, `AllowUsers kyle` | `/etc/ssh/sshd_config.d/` (root script) |
| `config/ufw.sh` | tailnet-only inbound, LAN SSH fallback | run by root script |
| `config/ssh_config.mac` | `Host as1`, `as1-lan`, and `as1-clip` (BatchMode, ControlMaster) for the push | marker block in `~/.ssh/config` on the Mac |
| `config/wezterm-as1.lua` | SSH domain `as1`, Cmd+Shift+A tab, Cmd+V image push | `~/.config/wezterm/wezterm-as1.lua` |
| `config/claude-settings.json` | Claude Code allow and deny lists, model, status line command | `~/.claude/settings.json` (symlink) |
| `config/statusline-command.sh` | Claude Code status line, two lines: dir, branch, model, effort; context tokens and 5h/7d rate limits. Needs jq (root script) | `~/.claude/statusline-command.sh` (symlink) |
| `config/workspace/CLAUDE.md` | house rules for all repos under `~/workspace`; one file linked under both names | `~/workspace/CLAUDE.md` and `~/workspace/AGENTS.md` (symlinks) |
| `env.example` | secret variable names only | copied to `~/.config/agents/env` once, mode 600 |
| `docs/` | `setup-from-scratch.md` (ordered runbook, parameters), `mac-client-setup.md`, `remote-agent-host-plan.md`; operations runbook for phase 5 to be written | read only |

Planned but absent: `bin/agent`, `bin/agent-worker`, `systemd/`, `docker/`, `docs/runbook.md`.

## Install contract

The install scripts are re-run after every change and must stay idempotent. Preserve these
mechanisms rather than inventing new ones:

- **Symlinks, not copies**, for configs on as1. `install-as1.sh` has a `link` helper that backs up
  a real file in the way and is a no-op when the link already points at the repo. Edit configs in
  the repo, never the installed copy.
- **Marker blocks** for files the scripts share with the user, such as `~/.bashrc` and
  `~/.ssh/config` on as1, and `~/.ssh/config` and `~/.zshrc` on the Mac. The `block` helper wraps content in `# >>> agentic-framework:<marker> >>>` and
  `# <<< agentic-framework:<marker> <<<` and replaces the block in place on re-run. Use a new
  marker name for new content; never append unmarked lines.
- **No Mac login names anywhere.** Nothing on as1 needs to know who is at the Mac; the push is
  anonymous and the last pusher wins. Do not reintroduce a `__MACUSER__`-style placeholder.
- **Network installs are behind `--no-tools`** in `install-as1.sh`. Anything that downloads goes in
  that branch, guarded with `command -v` (or `[ -d ]` for `~/.oh-my-zsh`) so a re-run skips it.
- **Shell fragments run under bash and zsh.** `~/.zshrc` and `~/.zshenv` source the same
  `config/bashrc.d/*.sh` files as `~/.bashrc`; keep them POSIX or `[[ ]]`-only and branch on
  `$ZSH_VERSION` where the shells differ, rather than duplicating a zsh copy.
- **Root and user steps stay in separate scripts.** Nothing in `install-as1.sh` or `install-mac.sh`
  may call `sudo`. The Mac side must stay sudo-free: a managed laptop should need no system changes.

## Change conventions

- Shell is bash with `set -euo pipefail` (the `xclip` shim uses `set -u` only, on purpose: it
  must fail soft so Claude Code falls through). Run `bash -n`, and `shellcheck` where available,
  on every script you touch. Header comments state what the file does and where it is installed; keep them current.
- Configs are declarative and commented. Say why a setting exists, not what it does.
- Secrets never enter the repo. `env.example` carries names only. `.gitignore` excludes `env`,
  `.env` and `*.local`; if you add a file that can hold a value, add it there too.
- Docs move with code. A change to a script or config updates the matching phase in
  `docs/remote-agent-host-plan.md` or `docs/mac-client-setup.md`, including the test commands, and the
  matching part of `docs/setup-from-scratch.md` (what the script does, its verify block, the parameters table).
- Keep the two Macs interchangeable. Nothing may depend on `macbook` specifically; the spool holds
  whatever the last Mac pushed and nothing identifies a client.
- Claude Code specifics belong in `config/claude-settings.json`; cross-harness rules belong in
  `config/workspace/CLAUDE.md`. Do not put Claude-only behaviour in the shared rules.

## Verification

Run these on as1 without sudo before you open a PR. `shellcheck` is not installed on as1 yet;
`mise use -g shellcheck@latest` adds it without sudo, otherwise skip that line and say so.

```
shellcheck install-as1.sh install-mac.sh install-as1-root.sh bin/xclip bin/clip-put bin/clip-push-mac.sh config/ufw.sh config/statusline-command.sh config/bashrc.d/*.sh
bash -n install-as1.sh install-mac.sh install-as1-root.sh bin/xclip bin/clip-put bin/clip-push-mac.sh config/statusline-command.sh
printf '{"model":{"display_name":"M"},"workspace":{"current_dir":"%s"}}' "$PWD" | bash config/statusline-command.sh   # two lines: ➜ agentic-framework git:(branch) [M], then ctx —
zsh -n config/zshenv config/zshrc config/bashrc.d/*.sh
NO_TMUX=1 zsh -ic 'echo $ZSH_THEME; type omz; command -v mise'   # robbyrussell, function, mise path
tmux -f config/tmux.conf new -d -s check && tmux show -s set-clipboard && tmux kill-session -t check
CLIP_BRIDGE_SPOOL=/usr/share/pixmaps/debian-logo.png bin/xclip -selection clipboard -t TARGETS -o    # image/png
CLIP_BRIDGE_SPOOL=/usr/share/pixmaps/debian-logo.png bin/xclip -selection clipboard -t image/png -o | file -
S=$(mktemp); printf plain | CLIP_BRIDGE_SPOOL=$S bin/clip-put && CLIP_BRIDGE_SPOOL=$S bin/xclip -selection clipboard -o; echo; rm -f $S   # plain
python3 -m json.tool config/claude-settings.json >/dev/null
```

`./install-as1.sh --no-tools` is safe to re-run on as1 and is the real idempotency test, but it
rewrites `~/.bashrc`, `~/.ssh/config`, `~/.zshrc`, `~/.zshenv`, `~/.claude/settings.json` and `~/.claude/statusline-command.sh` on this host. Run it only when
your change touches those paths and say so in the PR.

Needs a human, do not attempt: `install-as1-root.sh`, `config/ufw.sh`, anything under
`config/sshd`, `install-mac.sh`, and every joint checkpoint in the docs that involves a Mac.
Report those as unverified in the PR body.

## Boundaries

In addition to the workspace house rules:

- Never run or "test" the root script, the ufw script or an sshd config, and never reload
  `ssh`, `ufw` or `tailscale`. A mistake there locks the only operator out of a headless box.
- Never read, print or alter key material: `~/.ssh/id_ed25519`, `authorized_keys`,
  `~/.config/agents/env`. Treat `~/.clip/latest` the same way: it holds whatever the user last pasted.
- Never `apt install xclip` or otherwise put a real `xclip` ahead of the shim.
- Never change the `AllowUsers`, `PasswordAuthentication` or firewall defaults without a note in
  the PR title; a reviewer must see it before merge.
- Do not edit `~/.bashrc`, `~/.zshrc`, `~/.zshenv`, `~/.ssh/config` or `~/.claude/settings.json` by hand; change the repo
  file and let the install script render it.
- One agent per worktree. If `~/workspace/agentic-framework.wt/<slug>` exists for another job,
  pick a new slug.

## Automation model

Phase 5 and 6 work should fit this shape, taken from the plan doc, so that every device gets the
same interface regardless of harness:

- `agent run <repo> "<task>" [--harness claude|opencode|omp] [--interactive] [--budget N] [--sandbox]`
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
