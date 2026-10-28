# AGENTS.md: working on agentic-framework

Instructions for any coding agent (Claude Code, Codex, OpenCode, Oh My Pi) that edits this repo. The house
rules in `config/workspace/CLAUDE.md` (installed as `~/workspace/CLAUDE.md`, `~/workspace/AGENTS.md` and
`~/.codex/AGENTS.md`) apply first; this file adds what is specific to this repo.

## Purpose

Source of truth for one headless Ubuntu host on a Tailscale tailnet that runs coding agents, and for the Mac and
Linux desktop clients that reach it from WezTerm over SSH or mosh, land in tmux and run one of the four harnesses. The host name,
address, login and LAN address are parameters (`lib/params.sh`, README "Parameters"), never literals.

`README.md` is the runbook: install order, what each script does, verify blocks, joint checkpoints, rollback,
parameters table. `docs/remote-agent-host-plan.md` is the design, including phases 5 and 6, which are not
built. When code and docs disagree, fix one to match the other in the same change.

## Status

Do not assume something exists because the plan describes it. Check this table and the tree.

| Phase | Scope | State |
|---|---|---|
| 1 access | apt packages, zsh as login shell, linger, auto-updates; sshd and firewall left at OS defaults | `install-host.sh` phase 1 |
| 2 sessions | tmux, session picker (`bin/agent`), zsh + oh-my-zsh, WezTerm domain | `bin/agent`, `config/` |
| 3 harnesses | mise, uv, gh, the four harnesses, the Oh My Pi `pi-web-access` plugin, secrets file, shared rules, Claude settings, Codex global rules and config block | `install-host.sh` phases 2 to 4 |
| 4 clipboard bridge | Cmd+V on a Mac (Ctrl+V or Ctrl+Shift+V on Linux) pushes an image to `~/.clip/<stamp>.png` on the host and pastes that path into the pane; Ctrl+V in Claude Code is served by the `xclip` shim; copies return over OSC 52 | `bin/clip-put`, `bin/xclip`, `bin/clip-push-mac.sh.in`, `bin/clip-push-linux.sh.in`, `config/wezterm-agent-host.lua.in` |
| simulators | Android emulators and headless browsers on the host, iOS simulators on a Mac over ssh, one slot per harness session through MCP; opt-in per repo with `sim enable` (docs/simulators-plan.md) | `bin/sim`, `bin/sim-mcp`, `bin/sim-mcp-relay.mjs`, `lib/sim.sh`, `config/systemd/agent-sim-android@.service`, `install-ios-runner.sh`, `install-host.sh` |
| 5 automation | `agent run`/`logs`/`stop`/`clean`, `agent-worker`, systemd units, GitHub runner workflow | planned, not started |
| 6 isolation | `docker/Dockerfile.agent-sandbox`, `agent run --sandbox` | planned, not started |

Planned but absent: `bin/agent-worker`, `systemd/`, `docker/`, `docs/runbook.md`. (The simulator unit lives in
`config/systemd/`; phase 5's `systemd/` is still to come.) When you build part of
phase 5 or 6, update this table and section 8 of the plan doc.

## Layout

| Path | What it is | Installed to |
|---|---|---|
| `lib/params.sh` | the parameters: `.env` loading without executing it, validators, derivation from the system on the host, `params_render` for `.in` templates, the clients' ssh config text. Must run under macOS bash 3.2 | sourced by every install script and the tests |
| `lib/client.sh` | the client steps shared by `install-mac.sh` and `install-linux.sh`: `.env` bootstrap, `block`, ssh config and key, WezTerm include, `clip-push` and PATH block, key login, the closing summary. Must run under macOS bash 3.2 and BSD tools | sourced by the client scripts |
| `lib/sim.sh` | the device simulation service: pinned versions, apt list, slot ports, leases (flock), the per-harness MCP file writers, rsync filter, the `.sim/config` reader and the `sim_stack_*` seam (Expo). Host only, bash 5 | sourced by `bin/sim`, `bin/sim-mcp`, `install-host.sh`, `tests/sim-test.sh` |
| `.env.example` | the four `AGENT_HOST_*` parameters with example values, and the optional simulator ones commented out | copied to `.env` (gitignored) on host and clients |
| `secrets.env.example` | secret variable names only | copied once to `~/.config/agents/env`, mode 600 |
| `install-host.sh` | idempotent host setup, phases 1 to 4, run as the host login, never root. Phase 1 (root steps via `as_root`) is skipped by `--no-root`; network installs (oh-my-zsh, mise toolchains, uv, harnesses) by `--no-tools`. Phases 2 to 4 symlink configs, write marker blocks, install `bin/` | run in place |
| `install-mac.sh` | idempotent Mac client setup, no sudo: `.env` (prompted when absent), mosh, pngpaste, `~/.ssh/config` block, WezTerm include, `clip-push`, PATH block in `~/.zshrc`, then key login to the host (`ssh-copy-id`, one password prompt at most). Exits 1 with the fix when it cannot finish | run on the Mac |
| `install-linux.sh` | the same for a Linux desktop: the ssh client, mosh, wl-clipboard and xclip (gawk where awk is absent) through apt, dnf, pacman or zypper (`sudo` via `as_root`, only for what is missing; `sudo -A` when `SUDO_ASKPASS` is set; `--no-packages` skips it), then the shared steps with the Linux `clip-push` and the PATH block in the login shell's rc file. Refuses to run as root or on the host (`~/.local/bin/clip-put` present) | run on the Linux client |
| `bin/agent` | sessions on the host: `new`, `ls [--porcelain\|--json]`, `attach`, `pick [--switch]`, `switch`, `kill [--force] [--keep-worktree]`, `attention set\|clear` (needs-input flag for hooks; exits 0 silently when it cannot resolve a session). One harness run in one repo is one base tmux session; each device attaches its own grouped view (`AGENT_DEVICE` overrides the ssh address). `pick` is the login landing. tmux is the only state. Header comment has the model and the test hooks | `~/.local/bin/agent` |
| `bin/sim` | the simulators from the shell: `status`, `version`, `enable [--check\|--print-agents]`, `wait`, `env`, `run`, `build`, `maestro [--fresh\|--cold]`, `metro`, `android start\|stop\|restart\|logs`, `doctor`, `ios sync\|prepare\|bootstrap\|gc`, `lease`, `release`, `tunnel`; `--json` on `status`, `ports`, `lease`, `doctor`, `version`. Acts on the slot the worktree's MCP server (or `sim lease`) holds | `~/.local/bin/sim` |
| `bin/sim-mcp` | stdio MCP launcher a harness starts per platform: leases a slot, runs Playwright MCP, mobile-mcp (private adb server) or XcodeBuildMCP over ssh through the relay, frees the slot on exit | `~/.local/bin/sim-mcp` |
| `bin/sim-mcp-relay.mjs` | the MCP stdio relay sim-mcp runs (Node 20+, no dependencies): owns the server in its own process group (pgid in `$SIM_STATE/<p>/<N>.pgid`), runs the hidden `sim _wake P N` before tool calls and answers a call whose device does not come up with a tool error, forwards everything else at once. For ios (`--reconnect`) a dropped Mac keeps the session and lease: calls get a "reconnecting" tool error while it respawns the server with backoff and replays initialize and `session_set_defaults` | run from the repo by `bin/sim-mcp` (path resolved through the symlink) |
| `config/sim/Dockerfile.maestro`, `config/sim/maestro-entry.sh` | the `agent-sim-maestro:<version>-<hash>` image `sim maestro` builds on first use: Maestro in a network namespace where adb ports 5037 and 5038 lead to one slot's adb server | docker image, built by `bin/sim` |
| `config/systemd/agent-sim-android@.service` | emulator for slot N, started on lease, never at boot | `~/.config/systemd/user/` |
| `install-ios-runner.sh` | Mac half of the simulators, as the dedicated non-admin runner, no sudo, bash 3.2: mise, Node 22, Ruby 3.4, CocoaPods, XcodeBuildMCP, `agent-ios-N`, `~/.local/bin/sim-xcodebuildmcp` | piped over ssh by `sim ios bootstrap` |
| `bin/clip-put` | stdin to `~/.clip`: a PNG becomes `<UTC stamp>-<random>.png` and its path is printed, `latest` is repointed at it; text replaces `latest`. Prunes `.png` older than `CLIP_KEEP_MINUTES` (1440) on every push; `--clear` empties the spool | `~/.local/bin/clip-put` |
| `bin/xclip` | clipboard shim: serves `~/.clip/latest` to Claude Code on Ctrl+V; copies go back via OSC 52 | `~/.local/bin/xclip` |
| `bin/clip-push-mac.sh.in` | template: pngpaste or pbpaste piped over `ssh <alias>-clip` into `clip-put`; prints the type, then the host path for an image. WezTerm runs `--if-image` on Cmd+V and pastes line 2 | `~/.local/bin/clip-push` on the Mac |
| `bin/clip-push-linux.sh.in` | template: the same contract, reading the clipboard with `wl-paste` (Wayland) or `xclip` (X11); only `image/png` is an image | `~/.local/bin/clip-push` on a Linux client |
| `config/tmux.conf` | OSC 52 passthrough, mouse, history; prefix `g` opens the picker in a popup, prefix `c` keeps the cwd, `status-left` shows session and harness | `~/.tmux.conf` |
| `config/zshenv` | sources `agents-env.sh` for every zsh, including `ssh <host> <cmd>` | `~/.zshenv` |
| `config/zshrc` | oh-my-zsh (robbyrussell, git plugin, updates off), then the interactive fragments | `~/.zshrc` |
| `config/bashrc.d/agents-env.sh` | PATH and secrets for every shell, including non-interactive SSH; POSIX sh | top of `~/.bashrc`, and from `~/.zshenv` |
| `config/bashrc.d/mise.sh`, `tmux-autoattach.sh` | interactive-only bits, valid in bash and zsh; `tmux-autoattach.sh` runs `agent pick` for interactive SSH logins and logs out on exit 3 | bottom of `~/.bashrc` and end of `~/.zshrc` |
| `config/ssh_config.client.in` | template: `Host <alias>`, `<alias>-lan` (dropped without a LAN address), `<alias>-clip` (BatchMode, ControlMaster) | `agent-host` marker block in `~/.ssh/config` on each client |
| `config/wezterm-agent-host.lua.in` | template: SSH domain `<alias>`, new-tab key, paste key with image push then paste of the host path, default colour scheme. Keys follow `wezterm.target_triple`: Cmd+Shift+A and Cmd+V on macOS, Ctrl+Shift+A, Ctrl+V and Ctrl+Shift+V elsewhere | `~/.config/wezterm/wezterm-agent-host.lua` |
| `config/claude-settings.json` | Claude Code allow and deny lists, model, status line command | `~/.claude/settings.json` |
| `config/statusline-command.sh` | Claude Code status line, two lines; needs jq | `~/.claude/statusline-command.sh` |
| `config/workspace/CLAUDE.md` | house rules for every repo under `~/workspace` and every harness | `~/workspace/CLAUDE.md`, `~/workspace/AGENTS.md`, `~/.codex/AGENTS.md` |
| `tests/agent-test.sh` | unit tests for `bin/agent` and the login fragment: throwaway HOME, stand-in harness, own tmux socket | anywhere; no sudo, network or Docker |
| `tests/sim-test.sh`, `tests/sim/` | unit tests for `lib/sim.sh`, `bin/sim`, `bin/sim-mcp` and its relay from a temp copy of the repo with shims (systemctl, ssh, rsync, mise, the server). The runner sources `tests/sim/harness.sh` (setup, shims) then each `tests/sim/NN-<topic>.sh`; `bash tests/sim-test.sh <pattern>` runs only matching files. Add cases as new numbered files (numbering in the runner header) | anywhere; no sudo, network, emulator or Mac |
| `tests/mcp-probe.mjs` | a stdio MCP client: initialize, tools/list, `--call`s; drives the live simulator checks in README section 6 | node |
| `tests/params-test.sh` | unit tests for `lib/params.sh`, every rendered template checked with real tools, dry runs of `install-mac.sh` and `install-linux.sh --no-packages`, and the literal scan | anywhere; no sudo or network |
| `tests/e2e/run.sh` | two Docker containers, a host (`box`, real sshd, login `alice`) and a Mac stand-in with two Mac users: both install scripts twice against each other, key login, idempotency, Cmd+V routing through the rendered WezTerm module under Lua 5.4 (`wezterm-paste.lua`, stub `wezterm` table), the spool, the `xclip` calls Claude Code makes, OSC 52, a second Mac, and the picker under `AGENT_PICK_FILTER` | docker without sudo; network for the image builds |
| `tests/e2e/linux.sh` | `install-linux.sh` on Ubuntu, Debian, Fedora, Arch and openSUSE (`Dockerfile.linux`, `DISTROS=` for a subset) against the run.sh host image: packages through sudo with a password (`shims/linux/askpass`), key login, `clip-push` against a real X clipboard (Xvfb) and on Ubuntu a real Wayland one (headless sway), the Linux paste key through `wezterm-paste.lua`, a second run with no prompts, and the refusal on the host | docker without sudo; network during the run (distro mirrors) |
| `tests/e2e/sim-mac.sh` | the iOS sim path over real ssh and rsync: a Debian "host" running `sim` and `sim-mcp` from the working tree, and a fake Mac (`Dockerfile.simmac`, sshd, zsh login `runner`, shims in `shims/simmac`, the real `sim-maestro` launcher): sync, `sim-mcp ios` through `mcp-probe.mjs`, leases, `sim maestro ios` (run directories, a report brought home), `sim reap`, a simulator that does not boot (tool error), a dropped link that the session survives (reconnect, replay, same lease), a worktree path with a space and a `'`, `sim ios gc` by the sync stamp, a frozen Mac (`unreachable`, exit 3), `sim tunnel ios` and `sim maestro ios --forward`, or `forward_ios` in `.sim/config` (the Mac reaching a server on the host), `sim doctor ios` up and frozen. `AF_SIM_PREFIX` names its containers, `KEEP=1` | docker without sudo; network for the image builds |
| `tests/e2e/tui.sh` | the picker as a human meets it: keystrokes into a real `agent pick` over `ssh -tt`, every menu row and flow, two Macs on one session | same containers; about 12 min |
| `tests/e2e/harness-paste.sh` | a pasted image path attached inside the real Claude Code, Oh My Pi and OpenCode (`Dockerfile.harness`, versions pinned to the live host). The indicator strings are version-specific; run it when a harness is upgraded | docker without sudo; network and a few hundred MB for the first build |

Configs on the host are symlinks into the checkout at `~/workspace/agentic-framework`. Edit the repo file,
never the installed copy.

## Install contract

The install scripts are re-run after every change and must stay idempotent. Use these mechanisms; do not
invent new ones.

- **Parameters, not literals.** Host name, address, login and LAN address come from `lib/params.sh` (`.env`,
  or the system on the host). A file that needs one is a `.in` template with `@AGENT_...@` placeholders,
  rendered by the install script with `params_render`, which fails on any placeholder left over. Never
  install a template directly, and never write a host name, login or address into a script, template, config
  or doc outside `.env.example`; the literal scan in `tests/params-test.sh` fails if you do. A new parameter
  goes into `PARAMS_NAMES`, `.env.example`, the README table and the tests together.
- **Symlinks, not copies**, for configs on the host, through the `link` helper in `install-host.sh` (backs up
  a real file in the way, no-op when the link is right).
- **Marker blocks** for files the scripts share with the user or a tool: `~/.bashrc` and `~/.codex/config.toml`
  on the host (Codex writes into that file itself, so it cannot be a symlink), `~/.ssh/config` and `~/.zshrc`
  on the Mac, `~/.ssh/config` and the login shell's rc file on a Linux client. The `block` helper (in
  `lib/client.sh` for the clients) wraps content in `# >>> agentic-framework:<marker> >>>` and
  `# <<< agentic-framework:<marker> <<<` and replaces the block in place. New content gets a new marker
  name; never append unmarked lines.
- **Nothing on the host identifies a client.** Every client uses the same `.env`, the push is anonymous and the
  last pusher wins. No client login names or per-client placeholders anywhere.
- **Network installs sit behind `--no-tools`** in `install-host.sh`, each guarded with `command -v` (or
  `[ -d ]` for `~/.oh-my-zsh`) so a re-run skips it.
- **Shell fragments run under bash and zsh.** `~/.zshrc` and `~/.zshenv` source the same
  `config/bashrc.d/*.sh` as `~/.bashrc`; keep them POSIX or `[[ ]]`-only and branch on `$ZSH_VERSION`
  rather than keeping a zsh copy.
- **Root steps only through `as_root`, only in phase 1, only when needed.** One `sudo` call per command,
  never a root shell, each behind a check that needs no sudo (`cmp`, `dpkg-query`, `getent`,
  `/var/lib/systemd/linger`, `systemctl is-enabled`), so a configured host never prompts. Nothing outside
  phase 1 calls `sudo`. `install-mac.sh` stays sudo-free. `install-linux.sh` has its own `as_root`, used only by
  its package step and only for packages whose command is missing (`command -v`), under the same rules.
- **sshd, the firewall and `tailscale` are out of scope** for the scripts. Do not add configuration for them.

## Conventions

- Shell is bash with `set -euo pipefail`; `bin/xclip` uses `set -u` only, on purpose, so Claude Code falls
  through when the shim fails. Run `bash -n`, and `shellcheck` where available, on every script you touch.
  Header comments say what the file does and where it is installed; keep them current.
- Configs are declarative and commented. Say why a setting exists, not what it does.
- Secrets never enter the repo. `.gitignore` excludes `env`, `.env` and `*.local`; a new file that can hold a
  value goes there too. `.env` (host name, address, login) is not a secret and agents may read it;
  `~/.config/agents/env` they may not.
- Docs move with code. A change to a script or config updates the matching phase in
  `docs/remote-agent-host-plan.md` and the matching section of `README.md` (what the script does, its
  verify block, the parameters table).
- Claude Code specifics belong in `config/claude-settings.json`, Codex specifics in the `codex` block
  `install-host.sh` writes to `~/.codex/config.toml`; cross-harness rules in `config/workspace/CLAUDE.md`.
  Nothing harness-specific goes into the shared rules.
- `agent ls --porcelain` is the interface the tests and the phase 5 subcommands consume; keep its columns
  stable. Non-interactive SSH must never auto-attach to tmux, which is why `tmux-autoattach.sh` checks
  `SSH_TTY` and `$-`.
- A change to `config/wezterm-agent-host.lua.in` that uses a new `wezterm` API extends the stub in
  `tests/e2e/wezterm-paste.lua` in the same change.

## Verification

Run these on the host without sudo before you open a PR. If `shellcheck` is missing,
`mise use -g shellcheck@latest` adds it without sudo; otherwise skip those lines and say so.

```
bash tests/agent-test.sh             # N passed, 0 failed
bash tests/params-test.sh            # N passed, 0 failed
bash tests/e2e/run.sh                # about 3 min; N passed, 0 failed
bash tests/e2e/linux.sh              # about 10 min with five distros; N passed, 0 failed
bash tests/e2e/sim-mac.sh            # under a minute after the image builds; N passed, 0 failed
bash tests/e2e/tui.sh                # about 12 min; N passed, 0 failed
bash tests/e2e/harness-paste.sh      # about 4 min plus the first image build; N passed, 0 failed
shellcheck -x install-host.sh install-mac.sh install-linux.sh tests/e2e/linux.sh bin/agent bin/xclip bin/clip-put config/statusline-command.sh config/bashrc.d/*.sh tests/e2e/harness-paste.sh
shellcheck -x -s bash lib/params.sh lib/client.sh tests/params-test.sh tests/agent-test.sh bin/clip-push-mac.sh.in bin/clip-push-linux.sh.in
bash -n install-host.sh install-mac.sh install-linux.sh bin/agent bin/xclip bin/clip-put bin/clip-push-mac.sh.in bin/clip-push-linux.sh.in config/statusline-command.sh lib/params.sh lib/client.sh
printf '{"model":{"display_name":"M"},"workspace":{"current_dir":"%s"}}' "$PWD" | bash config/statusline-command.sh   # two lines: ➜ agentic-framework git:(branch) [M], then ctx —
zsh -n config/zshenv config/zshrc config/bashrc.d/*.sh
NO_TMUX=1 zsh -ic 'echo $ZSH_THEME; type omz; command -v mise'   # robbyrussell, function, mise path
tmux -f config/tmux.conf -L check new -d -s check && tmux -L check show -s set-clipboard && tmux -L check list-keys -T prefix | grep -E ' (g|c) ' && tmux -L check kill-server
AGENT_TMUX_SOCKET=scratch bin/agent ls && env -u TMUX AGENT_TMUX_SOCKET=scratch bin/agent pick --switch; echo "$? (2: --switch needs tmux)"
CLIP_BRIDGE_SPOOL=/usr/share/pixmaps/debian-logo.png bin/xclip -selection clipboard -t TARGETS -o    # image/png
CLIP_BRIDGE_SPOOL=/usr/share/pixmaps/debian-logo.png bin/xclip -selection clipboard -t image/png -o | file -
S=$(mktemp); printf plain | CLIP_BRIDGE_SPOOL=$S bin/clip-put && CLIP_BRIDGE_SPOOL=$S bin/xclip -selection clipboard -o; echo; rm -f $S   # plain
python3 -m json.tool config/claude-settings.json >/dev/null
```

Which suite to run: `sim-test.sh` for `lib/sim.sh`, `bin/sim`, `bin/sim-mcp`, its relay or the unit, `e2e/sim-mac.sh` as well
when the iOS path, ssh or the relay changes, plus the live
checks in README section 6 when the emulator, an MCP version or the Mac side changes; `agent-test.sh` for `bin/agent` or the login fragment; `params-test.sh` for anything
under `lib/`, a template, or a doc (the literal scan); `e2e/run.sh` for any install script, `lib/client.sh` or the
clipboard bridge; `e2e/linux.sh` as well for `install-linux.sh`, `lib/client.sh`, the Linux `clip-push` or the
WezTerm module; `e2e/tui.sh` for the picker's menus; `e2e/harness-paste.sh` when a harness is upgraded
or the paste path changes.

`./install-host.sh --no-tools --no-root` is the real idempotency test, but it rewrites `~/.bashrc`,
`~/.zshrc`, `~/.zshenv`, `~/.claude/*`, `~/.codex/AGENTS.md` and the `codex` block of
`~/.codex/config.toml` on this host, and points every symlink at the checkout it runs from. Run it only
from `~/workspace/agentic-framework`, never from a worktree, only when your change touches those paths,
and say so in the PR.

Needs a human, never attempt on this host: phase 1 of `install-host.sh`, `install-mac.sh`, `install-linux.sh`
(it refuses here anyway), and every joint checkpoint in the README that involves a client. Inside the e2e containers all of that is fair game. What the
containers cannot cover, report as unverified in the PR body: real systemd and tailscale, macOS itself (BSD
awk, bash 3.2), a real Linux desktop session (what WezTerm passes to `clip-push`), WezTerm's own runtime, and the
tailnet.

## Boundaries

In addition to the house rules:

- Never run or "test" phase 1 of `install-host.sh`, and never touch sshd, the firewall or `tailscale`. A
  mistake there locks the only operator out of a headless box.
- Never read, print or alter key material: `~/.ssh/id_ed25519`, `authorized_keys`, `~/.config/agents/env`.
  Treat all of `~/.clip/` the same way: it holds every image the operator pasted in the last day.
- Never `apt install xclip` or otherwise put a real `xclip` ahead of the shim.
- Never edit `~/.bashrc`, `~/.zshrc`, `~/.zshenv`, `~/.ssh/config`, `~/.claude/settings.json` or the `codex`
  block in `~/.codex/config.toml` by hand; change the repo file and let the install script render it.
- One agent per worktree. If `~/workspace/agentic-framework.wt/<slug>` exists for another job, pick a new
  slug.

## Phase 5 and 6 contract

The shape the automation must take, so every device gets the same interface regardless of harness. Details
are in sections 6 and 7 of the plan doc.

- `agent run <repo> "<task>" [--harness claude|codex|opencode|omp] [--interactive] [--budget N] [--sandbox]`
  creates `~/workspace/<repo>.wt/<slug>` on branch `agent/<slug>`, runs the harness headless with a budget
  cap, logs to `~/agents/logs/<slug>.jsonl`, then commits, pushes and opens a PR, printing its URL.
- `agent logs | stop | clean <slug>` join the existing session subcommands rather than replacing them.
- Headless runs on the host use `--permission-mode acceptEdits`; `--dangerously-skip-permissions` only
  inside the Docker sandbox with the worktree mounted at `/work`.
- From a Mac the entry point is `alias agent='ssh -q <host> agent'`.
