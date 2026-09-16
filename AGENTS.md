# AGENTS.md: working on agentic-framework

Instructions for any coding agent (Claude Code, OpenCode, Oh My Pi) that edits this repo.
The house rules in `~/workspace/CLAUDE.md` / `~/workspace/AGENTS.md` (kept here as
`config/workspace/CLAUDE.md`) apply first; this file adds what is specific to this repo.

## Purpose

This repo is the source of truth for the agent host (the name, address, login and
LAN address are parameters, see README.md "Parameters" and `lib/params.sh`), a headless Ubuntu box on the tailnet
that runs coding agents on behalf of the operator's other devices. The design, in one line: the Macs
reach the host over Tailscale with SSH or mosh from WezTerm, land in tmux, and run one of four
harnesses there. Automation on the host covers on-demand jobs launched from any device, scheduled jobs
via systemd timers, git-event jobs via a self-hosted GitHub runner, and a long-running queue worker.
Every unattended job works in its own git worktree, on an `agent/<slug>` branch, and ends in a
pull request, never a merge.

Everything an agent needs to install, configure or verify the host and the Macs lives here: scripts,
configs, and the phase-by-phase plan. `docs/remote-agent-host-plan.md` is the authoritative design;
`README.md` is the ordered runbook from bare machines to the working setup, with the verify block for
each script, the joint checkpoints, Mac rollback, and the parameters table. When code and docs
disagree, fix one to match the other in the same change.

## Status

Do not assume something exists because the plan describes it. Check this table and the tree.

| Phase | Scope | State |
|---|---|---|
| 1 access | apt (tmux mosh gh zsh git curl file jq unattended-upgrades), zsh + chsh, linger, auto-updates; sshd and firewall left at OS defaults | scripted (`install-host.sh` phase 1) |
| 2 sessions | tmux, auto-attach, zsh + oh-my-zsh, WezTerm domain | scripted (`config/tmux.conf`, `config/zshenv`, `config/zshrc`, `config/bashrc.d`, `config/wezterm-agent-host.lua.in`) |
| 3 harnesses | mise, uv, gh, three harnesses, secrets file, shared rules, Claude settings | scripted (`install-host.sh` phases 2 to 4) |
| 4 clipboard bridge | Mac pushes images on Cmd+V; `clip-put` spool and `xclip` shim on the host | scripted (`bin/xclip`, `bin/clip-put`, `bin/clip-push-mac.sh.in`, Cmd+V in `config/wezterm-agent-host.lua.in`) |
| 5 automation | `agent` CLI, `agent-worker`, systemd units, GitHub runner workflow | planned, not started |
| 6 isolation | `docker/Dockerfile.agent-sandbox`, `agent run --sandbox` | planned, not started |

When you implement part of phase 5 or 6, update this table and section 8 of the plan doc.

## Layout

| Path | What it is | Installed to |
|---|---|---|
| `README.md` | orientation: which doc to read, what the two scripts do | read only |
| `lib/params.sh` | the parameters: `.env` loading without executing it, validators, derivation from the system on the host (`hostname -s`, Tailscale DNS name, default route), `params_render` for `.in` templates, the Mac's ssh config text | sourced by both install scripts and the tests |
| `.env.example` | the four `AGENT_HOST_*` parameters with example values; copied to `.env` (gitignored) | `.env` at the repo root on host and Macs |
| `tests/params-test.sh` | unit tests for the library, every rendered template checked with real tools (`ssh -G`, `bash -n`), a Linux dry run of `install-mac.sh` against a throwaway HOME, and the literal scan | run anywhere, no sudo, no network |
| `tests/e2e/` | two Docker containers, a host (`box`, real sshd, login `alice`, systemd/tailscale shimmed and logged) and a Mac stand-in with two Mac users (brew, osascript, pbpaste, pngpaste stubbed; Lua 5.4 for the WezTerm module): both install scripts run twice against each other; password path, key login and idempotency; Cmd+V routing through the rendered WezTerm module (`wezterm-paste.lua`, stub `wezterm` table, real `clip-push`, real host) for text, image, local, ssh, mosh and failed-push cases; the `xclip` calls Claude Code makes after Ctrl+V with a byte-exact PNG check; OSC 52 copy-back; a second Mac installing and pushing against the same host | `bash tests/e2e/run.sh`; needs docker without sudo, network for the image builds only |
| `install-host.sh` | idempotent host setup, phases 1 to 4, run as the host login. Loads `.env`, derives the rest, writes `.env` when absent and prints it for the Macs at the end. Phase 1 (apt tmux mosh gh zsh git curl file jq unattended-upgrades, chsh to zsh, linger, tailscale auto-update, unattended-upgrades; sshd and the firewall are not touched) goes through the `as_root` helper one `sudo` command at a time, each behind a no-sudo state check, so a configured host never prompts; `--no-root` skips it. Phases 2 to 4 symlink configs, then oh-my-zsh, toolchains and harnesses (Claude Code via the native installer when absent) behind `--no-tools` | run in place |
| `install-mac.sh` | idempotent Mac client setup, phases 1, 2 and 4; no sudo; settles its parameters first (`.env`, a prompt on a terminal, or exit 2); renders the ssh config block (`agent-host` marker) and `clip-push`; writes a minimal `wezterm.lua` when none exists, otherwise inserts the `wezterm-agent-host` require before the final `return <config>` (backup `.before-agent-host`; exits 1 with the line to add when the file ends some other way); `path` marker block in `~/.zshrc`; ends by making `ssh <alias>` keyless: stores the host key on first contact (fingerprint printed), installs the repo key over an already-trusted key with `ssh-copy-id -f`, or runs `ssh-copy-id` and asks for the host password once; never deletes a stored host key or edits `authorized_keys` directly; exits 1 with the fix when it cannot finish | run on the Mac |
| `bin/xclip` | clipboard shim; serves the spool the Mac pushed (`~/.clip/latest`) to Claude Code, copies go back via OSC 52 | `~/.local/bin/xclip` on the host |
| `bin/clip-put` | stdin to the spool, atomic, mode 600; `--clear` | `~/.local/bin/clip-put` on the host |
| `bin/clip-push-mac.sh.in` | template: pngpaste or pbpaste piped over `ssh <alias>-clip` into `clip-put`, prints the type; WezTerm runs `--if-image` on Cmd+V | rendered to `~/.local/bin/clip-push` on the Mac |
| `config/tmux.conf` | OSC 52 passthrough, mouse, history, SSH_CONNECTION refresh | `~/.tmux.conf` (symlink) |
| `config/zshenv` | sources `agents-env.sh` for every zsh, incl. `ssh <host> <cmd>` | `~/.zshenv` (symlink) |
| `config/zshrc` | oh-my-zsh (robbyrussell, git plugin, updates off) then the interactive fragments | `~/.zshrc` (symlink) |
| `config/bashrc.d/agents-env.sh` | PATH and secrets for every shell, including non-interactive SSH; POSIX sh, shared by bash and zsh | sourced at top of `~/.bashrc` and from `~/.zshenv` |
| `config/bashrc.d/mise.sh`, `tmux-autoattach.sh` | interactive-only shell bits, valid in bash and zsh | sourced at bottom of `~/.bashrc` and end of `~/.zshrc` |
| `config/ssh_config.mac.in` | template: `Host <alias>`, `<alias>-lan` (dropped without a LAN address), `<alias>-clip` (BatchMode, ControlMaster) for the push | `agent-host` marker block in `~/.ssh/config` on the Mac |
| `config/wezterm-agent-host.lua.in` | template: SSH domain `<alias>`, Cmd+Shift+A tab, Cmd+V image push, default `color_scheme` (Tokyo Night) | `~/.config/wezterm/wezterm-agent-host.lua` |
| `config/claude-settings.json` | Claude Code allow and deny lists, model, status line command | `~/.claude/settings.json` (symlink) |
| `config/statusline-command.sh` | Claude Code status line, two lines: dir, branch, model, effort; context tokens and 5h/7d rate limits. Needs jq (phase 1) | `~/.claude/statusline-command.sh` (symlink) |
| `config/workspace/CLAUDE.md` | house rules for all repos under `~/workspace`; one file linked under both names | `~/workspace/CLAUDE.md` and `~/workspace/AGENTS.md` (symlinks) |
| `secrets.env.example` | secret variable names only | copied to `~/.config/agents/env` once, mode 600 |
| `README.md` | ordered runbook: prerequisites, the three scripts with verify blocks, logins, joint checkpoints, rollback, parameters table | read only |
| `docs/` | `remote-agent-host-plan.md` (design, per-phase tests); operations runbook for phase 5 to be written | read only |

Planned but absent: `bin/agent`, `bin/agent-worker`, `systemd/`, `docker/`, `docs/runbook.md`.

## Install contract

The install scripts are re-run after every change and must stay idempotent. Preserve these
mechanisms rather than inventing new ones:

- **Parameters, not literals.** Host name, address, login and LAN address come from `lib/params.sh`: `.env`,
  or the system on the host. A file that needs one is a `.in` template with `@AGENT_...@` placeholders, rendered
  by the install script with `params_render`, which fails on any placeholder left over. Never install a template
  directly, and never write a host name, a login or an address into a script, template or config outside comments and
  `.env.example`; the literal scan in `tests/params-test.sh` fails the build if you do. New parameters go in
  `PARAMS_NAMES`, `.env.example`, the README table and the tests together.
- **Symlinks, not copies**, for configs on the host. `install-host.sh` has a `link` helper that backs up
  a real file in the way and is a no-op when the link already points at the repo. Edit configs in
  the repo, never the installed copy.
- **Marker blocks** for files the scripts share with the user, such as `~/.bashrc` on the host,
  and `~/.ssh/config` and `~/.zshrc` on the Mac. The `block` helper wraps content in `# >>> agentic-framework:<marker> >>>` and
  `# <<< agentic-framework:<marker> <<<` and replaces the block in place on re-run. Use a new
  marker name for new content; never append unmarked lines.
- **No Mac login names anywhere.** Nothing on the host needs to know who is at the Mac; the push is
  anonymous and the last pusher wins. Do not reintroduce a `__MACUSER__`-style placeholder.
- **Network installs are behind `--no-tools`** in `install-host.sh`. Anything that downloads goes in
  that branch, guarded with `command -v` (or `[ -d ]` for `~/.oh-my-zsh`) so a re-run skips it.
- **Shell fragments run under bash and zsh.** `~/.zshrc` and `~/.zshenv` source the same
  `config/bashrc.d/*.sh` files as `~/.bashrc`; keep them POSIX or `[[ ]]`-only and branch on
  `$ZSH_VERSION` where the shells differ, rather than duplicating a zsh copy.
- **Root steps only through `as_root`, only when needed.** `install-host.sh` runs as the user and refuses to
  run as root. Every root command in phase 1 goes through the `as_root` helper (one `sudo` call per command,
  never a root shell) and sits behind a check that needs no sudo (`cmp` against the installed file,
  `dpkg-query`, `getent`, `/var/lib/systemd/linger`, `systemctl is-enabled`), so a
  configured host never prompts and `--no-root` skips the phase entirely. Nothing outside phase 1 may call
  `sudo`. `install-mac.sh` must stay sudo-free: a managed laptop should need no system changes.

## Change conventions

- Shell is bash with `set -euo pipefail` (the `xclip` shim uses `set -u` only, on purpose: it
  must fail soft so Claude Code falls through). Run `bash -n`, and `shellcheck` where available,
  on every script you touch. Header comments state what the file does and where it is installed; keep them current.
- Configs are declarative and commented. Say why a setting exists, not what it does.
- Secrets never enter the repo. `secrets.env.example` carries names only. `.gitignore` excludes `env`,
  `.env` and `*.local`; if you add a file that can hold a value, add it there too. `.env` is not a secret
  (host name, address, login) and agents may read it; `~/.config/agents/env` they may not.
- Docs move with code. A change to a script or config updates the matching phase in
  `docs/remote-agent-host-plan.md`, including the test commands, and the matching section of `README.md`
  (what the script does, its verify block, the parameters table).
- Keep the Macs interchangeable. Nothing may depend on one particular Mac; the spool holds
  whatever the last Mac pushed and nothing identifies a client.
- Claude Code specifics belong in `config/claude-settings.json`; cross-harness rules belong in
  `config/workspace/CLAUDE.md`. Do not put Claude-only behaviour in the shared rules.

## Verification

Run these on the host without sudo before you open a PR. `shellcheck` is not installed on the host yet;
`mise use -g shellcheck@latest` adds it without sudo, otherwise skip that line and say so.

```
bash tests/params-test.sh            # library, rendered templates, install-mac.sh dry run, literal scan; N passed, 0 failed
bash tests/e2e/run.sh                # both scripts, Cmd+V routing, clipboard round trip and a second Mac, in two containers (about 3 min); N passed, 0 failed
shellcheck -x install-host.sh install-mac.sh bin/xclip bin/clip-put config/statusline-command.sh config/bashrc.d/*.sh
shellcheck -x -s bash lib/params.sh tests/params-test.sh bin/clip-push-mac.sh.in
bash -n install-host.sh install-mac.sh bin/xclip bin/clip-put bin/clip-push-mac.sh.in config/statusline-command.sh lib/params.sh
printf '{"model":{"display_name":"M"},"workspace":{"current_dir":"%s"}}' "$PWD" | bash config/statusline-command.sh   # two lines: ➜ agentic-framework git:(branch) [M], then ctx —
zsh -n config/zshenv config/zshrc config/bashrc.d/*.sh
NO_TMUX=1 zsh -ic 'echo $ZSH_THEME; type omz; command -v mise'   # robbyrussell, function, mise path
tmux -f config/tmux.conf new -d -s check && tmux show -s set-clipboard && tmux kill-session -t check
CLIP_BRIDGE_SPOOL=/usr/share/pixmaps/debian-logo.png bin/xclip -selection clipboard -t TARGETS -o    # image/png
CLIP_BRIDGE_SPOOL=/usr/share/pixmaps/debian-logo.png bin/xclip -selection clipboard -t image/png -o | file -
S=$(mktemp); printf plain | CLIP_BRIDGE_SPOOL=$S bin/clip-put && CLIP_BRIDGE_SPOOL=$S bin/xclip -selection clipboard -o; echo; rm -f $S   # plain
python3 -m json.tool config/claude-settings.json >/dev/null
```

`./install-host.sh --no-tools --no-root` is safe to re-run on the host and is the real idempotency test, but it
rewrites `~/.bashrc`, `~/.zshrc`, `~/.zshenv`, `~/.claude/settings.json` and `~/.claude/statusline-command.sh` on this host, and
it points every symlink at the checkout it runs from: never run it from a worktree, only from `~/workspace/agentic-framework`.
Run it only when your change touches those paths and say so in the PR.

Needs a human, do not attempt on this host: phase 1 of `install-host.sh` (anything through `as_root`),
`install-mac.sh`, and every joint checkpoint in the docs that involves a Mac. Inside the e2e containers
all of that is fair game and is what `tests/e2e/run.sh` does, including the Cmd+V decision of the WezTerm module (run
under Lua 5.4 with a stub `wezterm` table) and the `xclip` calls Claude Code makes; what it cannot cover is real systemd
and tailscale, macOS itself (BSD awk, bash 3.2), WezTerm's own runtime and the tailnet. Report those as unverified
in the PR body. A change to `config/wezterm-agent-host.lua.in` that uses a new `wezterm` API needs the stub in
`tests/e2e/wezterm-paste.lua` extended in the same change.

## Boundaries

In addition to the workspace house rules:

- Never run or "test" phase 1 of `install-host.sh`, and never touch sshd, the firewall or `tailscale`.
  A mistake there locks the only operator out of a headless box.
- Never read, print or alter key material: `~/.ssh/id_ed25519`, `authorized_keys`,
  `~/.config/agents/env`. Treat `~/.clip/latest` the same way: it holds whatever the user last pasted.
- Never `apt install xclip` or otherwise put a real `xclip` ahead of the shim.
- Do not reintroduce sshd or firewall configuration into the scripts without a note in the PR title;
  a reviewer must see it before merge.
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
- Git events: self-hosted runner labelled after the host, workflow triggered by `/agent ` issue comments and
  the `agent-review` PR label. No inbound ports.
- Queue: `agent-worker` watches `~/agents/queue/*.md`, moves to `done/` or `failed/`, `MAX_PARALLEL=2`,
  notifies via ntfy.
- Permissions: `--permission-mode acceptEdits` for headless runs on the host;
  `--dangerously-skip-permissions` only inside the Docker sandbox with the worktree mounted at `/work`.
- From a Mac the entry point is `alias agent='ssh -q <host> agent'`; non-interactive SSH must never
  auto-attach to tmux, which is why `tmux-autoattach.sh` checks `SSH_TTY` and `$-`.
