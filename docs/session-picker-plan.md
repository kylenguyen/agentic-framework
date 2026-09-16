# Session picker: many Macs, many harness sessions, attach any from anywhere

Implementation plan for the next change to this repo. Written 16 Sep 2026 after the operator answered the design
questions in section 1; treat those answers as fixed unless the operator revises them. Read `AGENTS.md` first
(house rules, install contract), then this file. `README.md` and `docs/remote-agent-host-plan.md` describe what
exists today; this plan changes phase 2 (sessions) and is the base that phase 5 (`agent run`) later builds on.

## 1. Goal and decisions

Goal: the operator logs in from any Mac and sees every running Claude Code / Oh My Pi / OpenCode session on the
host, picks one, and gets it on that Mac's screen. Several Macs may be on the same or different sessions at once.

Decisions (operator, 16 Sep 2026):

| Question | Decision |
|---|---|
| Unit of a session | one harness run in one repo, 1:1 with a tmux session |
| Two devices on one session | independent views (tmux grouped sessions), not mirror, not take-over |
| Picker location | on the host, as the landing of every interactive SSH/mosh login; no WezTerm launcher in v1 |
| Resume depth | re-attach to live processes only; no conversation-ID registry, no restore after reboot |
| Where a new session runs | `~/workspace/<repo>` by default; `~/workspace/<repo>.wt/<slug>` on branch `agent/<slug>` on request |
| Picker detail | process facts only: harness, repo, branch, cwd, age, running/exited, attached devices; no hooks |
| Plain shells | "shell" is a session type in the picker; `main` stops being the forced landing |

Non-goals for this change: harness conversation resume (`claude --resume`, `omp --resume`), "waiting for you"
indicators, WezTerm-side pickers, session restore at boot, per-device identities beyond the client address.

Verified on the live host (tmux 3.6) during design, so the implementer need not re-derive them:

- tmux rewrites `.` in a session name to `_`, and `.` / `:` in a `-t` target are separators. Session names must
  never contain them; target sessions by `#{session_id}` (`$N`) internally, never by name.
- `tmux new-session -t <existing session>` puts the new session in a group named after the existing one
  (`session_group` = its name, `session_grouped` = 1 on both). Grouped sessions share windows and processes;
  current window, size and scroll position are per session.
- `-t` cannot be combined with `-n` or a shell command, so the base session is created plain with the harness as
  its command, and views are added afterwards.
- When the harness process exits, its window closes in every session of the group; with nothing else in the
  group, base and views all disappear. (`remain-on-exit`, below, is what stops that.)
- `destroy-unattached on` on a view destroys it as soon as it has no client, including a view created detached.
- fzf is not installed on the host; `apt` candidate is 0.67.0. `agent` is a free command name.

Not verified, check first during implementation (both are one-minute manual checks on a real terminal):

1. A view created attached (`tmux new-session -t ... \; set destroy-unattached on`, no `-d`) stays alive while its
   client is attached and dies on detach. The design spike could not allocate a pty for a fake client.
2. A harness started as the tmux session command (`tmux new-session -s <name> -c <cwd> claude`) inherits PATH and
   the secrets file. tmux runs the command through `default-shell -c`, which is zsh on the host and reads
   `~/.zshenv`, so it should; confirm with `tmux new-session -d -s t 'echo $PATH; env | grep -c ANTHROPIC' `.

## 2. Architecture

```
Mac A  ssh/mosh ─┐                                  tmux server (one, per host login)
Mac B  ssh/mosh ─┼─ login shell ─ agent pick ─┐     ┌────────────────────────────────────────────┐
Mac C  ssh/mosh ─┘   (fzf loop)               │     │ base  claude-ezbus      win1: claude  win2 │
                                              ├──►  │ view  claude-ezbus@1  (Mac A, own cur win) │
   ssh <host> <cmd>  ── never touches this ── │     │ view  claude-ezbus@2  (Mac B)              │
                                              │     │ base  omp-agentic-framework-docs  win1: omp│
                                              └──►  │ view  omp-agentic-framework-docs@1 (Mac C) │
                                                    │ base  shell-scratch   win1: zsh            │
                                                    │ main  (pre-existing, listed as shell)      │
                                                    └────────────────────────────────────────────┘
```

**Base session.** `agent new` creates `tmux new-session -d -s <name> -c <cwd> <harness command>`, then sets on it:
`remain-on-exit on` (a finished or crashed harness leaves its last screen and shows as exited in the picker until
killed), and user options `@harness`, `@repo`, `@cwd`, `@branch`, `@created`. Window 1 is the harness; the operator
opens more windows with the prefix, and they start in `#{pane_current_path}`. No registry file: tmux is the state.

**Views.** `agent attach <name>` runs `tmux new-session -t <base id> -s <name>@<n> \; set destroy-unattached on
\; set @device <ip>` (foreground, so it attaches). `<n>` is the lowest free integer. `@device` is the first field of
`SSH_CLIENT`, i.e. the Mac's Tailscale or LAN address. Detaching destroys the view; the base stays. Nobody ever
attaches the base itself, so window size follows the attached views (`window-size latest`, tmux default).

**Picker.** `agent pick` is an fzf loop: build the list (`agent ls --porcelain`), show it with a preview of the
session's last screen (`tmux capture-pane -p -e -t <id>`), act, repeat. Rows, in order: `new session`, `new shell`,
one row per base session (harness, repo, branch, `wt` if a worktree, age, `running`/`exited`, attached devices),
`plain shell here`, `log out`. Attach runs in the foreground; when it returns (detach, kill, harness death after a
kill) the loop shows the list again. `new session` asks in fzf for the repo (directories under `~/workspace` with a
`.git`, `.wt` trees excluded), then the harness (`claude`, `omp`, `opencode`, `shell`), then an optional slug; a
slug means a worktree. `plain shell here` exits 0 and the login shell continues outside tmux; `log out` exits 3 and
the login fragment logs out. Inside tmux, prefix `g` opens the same picker in `display-popup -E` with `--switch`,
which creates the target view and `switch-client`s to it; the abandoned view is destroyed by `destroy-unattached`.

**Landing.** `config/bashrc.d/tmux-autoattach.sh` keeps its guard (`$- == *i*`, `SSH_TTY` set, `TMUX` empty,
`NO_TMUX` empty, command present) and runs `agent pick` instead of `exec tmux new -As main`. Non-interactive
`ssh <host> <cmd>` is untouched, `ssh -t <host> 'NO_TMUX=1 zsh -l'` still bypasses everything. Pre-existing tmux
sessions without `@harness` (today's `main`) are listed as `shell` sessions and are never killed by the tooling.

**Naming.** `<harness>-<repo>` plus `-<slug>` when given, `[.:]` replaced by `_`, `-2`, `-3` on collision. Views
are `<name>@<n>`. Names are for display; commands resolve a name to a session id once, then use the id.

**Unchanged.** WezTerm module, `~/.ssh/config`, mosh, clipboard bridge, the harness installs, `~/.zshenv`
environment loading. Cmd+Shift+A still opens a host tab, which now lands in the picker.

## 3. `bin/agent` contract

bash, `set -euo pipefail`, shellcheck clean, installed by `install-host.sh` phase 4 with the existing `link`
helper (`~/.local/bin/agent`, like `bin/xclip`). Runs against the default tmux server unless `AGENT_TMUX_SOCKET` is
set, in which case every tmux call gets `-L "$AGENT_TMUX_SOCKET"` (the tests use this to stay off the live server).

| Command | Behaviour | Exit |
|---|---|---|
| `agent new <repo> [--harness claude\|omp\|opencode\|shell] [--slug <slug>] [--name <name>] [--no-attach]` | validate repo dir; with `--slug`, `git worktree add ~/workspace/<repo>.wt/<slug> -b agent/<slug>` from the main checkout (reuse if the worktree exists); create base session as above; attach unless `--no-attach` | 0; 2 usage or unknown repo/harness; 1 tmux/git failure |
| `agent ls [--porcelain]` | one line per base session (grouped or not, excluding names matching `*@[0-9]*` that are in a group). Human: aligned columns. Porcelain: tab-separated `name harness repo branch cwd state created_epoch devices`, `devices` comma-separated `@device` values of the group's attached views, `-` if none; harness `shell` and repo `-` for sessions without `@harness` | 0; 0 with no output when no server |
| `agent attach <name>` | create a view and attach; refuse if `<name>` is itself a view | 0 on detach; 2 unknown name |
| `agent pick [--switch]` | the fzf loop; `--switch` only inside tmux | 0 plain shell / 3 log out / 2 no fzf |
| `agent kill <name>` | `kill-session` on every view of the group, then on the base id; worktrees are not removed, print the `git worktree remove` command instead | 0; 2 unknown |
| `agent switch` | alias for `pick --switch` | as pick |

Test seam: when `AGENT_PICK_FILTER` is set, `agent pick` runs fzf with `--filter="$AGENT_PICK_FILTER"` and takes the
first match, no tty needed, and runs a single iteration. Nothing else in the tool is test-only. `--porcelain` is
the interface phase 5 and the tests consume; keep its columns stable.

## 4. Changes, in commit order

1. `bin/agent` with `ls`, `new`, `attach`, `kill` (no picker yet) and `tests/agent-test.sh` green.
2. `agent pick` / `--switch`, `AGENT_PICK_FILTER`, and the picker tests.
3. `config/bashrc.d/tmux-autoattach.sh` runs the picker; `config/tmux.conf` gains `bind g display-popup -E -w 80% -h 70% 'agent pick --switch'`, `bind c new-window -c '#{pane_current_path}'`, and `#S #{@harness}` in `status-left`.
4. `install-host.sh`: `fzf` in the phase 1 apt list (and in the `Parameters`/README package list), `link` for `bin/agent` in phase 4. `tests/e2e/Dockerfile.host`: add `fzf` to the preinstalled packages, as that list mirrors phase 1.
5. e2e additions in `tests/e2e/run.sh` (section 5).
6. Docs: README section 3 verify block (`command -v agent fzf`), section 5 checkpoints (below), the phase 1 package
   list in the script table; AGENTS.md status table row `2 sessions` (add "session picker, `bin/agent`") and layout
   table rows for `bin/agent`, `tests/agent-test.sh`; `docs/remote-agent-host-plan.md` section 3 item 2 and 4
   (picker replaces `main`, `bin/agent` owns the convention), section 6 item 1 (`agent run` extends `bin/agent`),
   section 8 layout. When code and docs disagree, fix both in the same commit.

Keep every change idempotent and re-runnable; `install-host.sh --no-tools` twice must print no diff and no sudo
prompt on a configured host. No host name, address or login anywhere but comments and `.env.example`; the literal
scan in `tests/params-test.sh` enforces it, and the e2e values (`box`, `alice`) are the only literals allowed in
tests.

## 5. Tests: write them with the behaviour, run them before every commit

All three layers below are required. Record in the PR body which ran, on what, and paste the final `N passed, 0
failed` lines. Where a check cannot be automated, say so in the PR and list the manual result.

**Unit, `tests/agent-test.sh`** (new; no sudo, no network, no Docker; run with `bash tests/agent-test.sh`). Uses
`AGENT_TMUX_SOCKET=af-test-$$` and a throwaway `HOME` with a fake `~/workspace/<repo>` git repo, and a stand-in
harness (`sleep` or a tiny script on PATH named `claude`), so the live tmux server and real harnesses are never
touched. Cases:

- `new` creates base with `@harness`, `@repo`, `@cwd`, `@branch`, `remain-on-exit on`; window 1's
  `pane_current_command` is the stand-in; cwd is the repo.
- name sanitising: repo `a.b:c` gives `claude-a_b_c`; second `new` for the same repo gives `-2`.
- `--slug x` creates `~/workspace/<repo>.wt/x` on branch `agent/x`; a second `new --slug x` reuses it.
- `ls --porcelain` columns and ordering; a pre-existing plain session (`tmux new -d -s main`) is listed as
  `shell`; views are not listed.
- `attach` under `script -qfc` (a pty): a view `<name>@1` exists while attached, `@device` is set from
  `SSH_CLIENT`; after `tmux detach-client -s <view>` the view is gone and the base remains. If `script` cannot
  provide a working client in the CI environment, the test must skip with an explicit `skip` line, not pass.
- harness exit: the stand-in exits; base remains with `pane_dead` = 1 and `ls` says `exited`.
- `kill` removes base and all views; worktree left in place and the removal command printed. (Implementation
  note, 16 Sep 2026: the design's "views die with the base" is wrong for tmux 3.6. Grouped sessions share a
  window list, not a lifetime: killing the base leaves each view attached to a session nobody owns. `agent kill`
  kills the views first, then the base.)
- `pick` with `AGENT_PICK_FILTER` selecting a session row creates a view (detached client is fine here: assert
  the `new-session -t` happened by checking the view exists immediately with `destroy-unattached` off during the
  test, or by `agent ls --porcelain` devices), selecting `log out` returns 3, `plain shell here` returns 0.
- landing fragment sourced in bash and zsh with `SSH_TTY` set and unset, interactive and not, `TMUX` set,
  `NO_TMUX=1`: `agent pick` is invoked exactly in the interactive+SSH_TTY+no-TMUX case (stub `agent` on PATH
  that records its argv).
- `shellcheck bin/agent tests/agent-test.sh`.

**Containers, `tests/e2e/run.sh`** (extend; `bash tests/e2e/run.sh`, needs Docker without sudo). The existing run
already has one host container (`box`, login `alice`) and one Mac container with two Mac users (`macuser`,
`macuser2`); those two users are the two devices. Add, after the existing second-Mac block:

- `box`: `agent` linked, `fzf` present, `agent ls --porcelain` empty before any session.
- `macuser`: `ssh -o BatchMode=yes box 'echo tmux=$TMUX; agent ls --porcelain | wc -l'` still prints `tmux=` and
  `0` (non-interactive login untouched).
- `macuser`: `ssh -tt box 'AGENT_PICK_FILTER="new shell" agent pick'` under `docker exec -t` in the background,
  then from `box`: one base `shell-*` session and one view with `@device` equal to the Mac container's address.
- `macuser2`: the same against the same session (`AGENT_PICK_FILTER=<name>`): two views, `session_group_size` 3,
  each view's `session_attached` 1. Change the current window on view 1 (`tmux select-window -t <view1>:2` after
  `new-window`), confirm view 2's current window is unchanged (independent views).
- `tmux detach-client -s <view1>` on `box`: view 1 gone, base and view 2 remain, the `macuser` ssh has exited 0.
- `agent kill <name>` on `box`: everything gone; the `macuser2` ssh has exited.
- `agent new ezbus-stand-in --harness claude --no-attach` with a stub `claude` on the box PATH that prints its
  cwd and sleeps: `ls` shows `running`, cwd is the repo dir; kill the stub, `ls` shows `exited`.
- second `./install-host.sh --no-tools` run still idempotent (the existing check), and `readlink ~/.local/bin/agent`
  points into the repo.

Interactive ssh in Docker: use `docker exec -t ... ssh -tt box '<cmd>'` and background it from `run.sh`; if the
pty does not survive backgrounding, wrap in `script -qfc`. The existing `run` / `check` / `has` helpers and the
`box` / `mac` / `mac2` wrappers are the pattern; do not add a new runner.

**Manual, README section 5 checkpoints** (add these rows; run them on the live host before the PR and report):

| Check | Expect |
|---|---|
| `mac$ ssh <host>` and `mac$ mosh <host>` | the picker, not `main`; `q`/`log out` closes the connection |
| `new session`, repo `agentic-framework`, `claude` | Claude Code starts in the repo dir with the API key env present |
| second Mac, pick the same session | both see the harness; switching windows on one does not move the other |
| Ctrl+B `g` | popup picker; choosing another session switches; `tmux ls` shows the old view gone |
| Cmd+V of an image in that session | still `[Image #1]` (clipboard bridge unaffected) |
| `/exit` in the harness | row shows `exited`, last screen visible; `agent kill` clears it |
| `mac$ ssh <host> 'echo $TMUX'` | empty line |

## 6. Done criteria

- All of section 5 green, `bash tests/params-test.sh` green, shellcheck clean.
- `install-host.sh --no-tools` run twice on the live host from `~/workspace/agentic-framework`: second run prints
  no changes, asks for no sudo, and `ssh <host>` lands in the picker.
- PR from branch `agent/session-picker` (never `main`), body lists what was verified where, and the two "not
  verified" items in section 1 are reported with their outcome. Do not merge it.
- AGENTS.md status table updated, `docs/remote-agent-host-plan.md` sections 3, 6 and 8 updated, this file's
  section 1 left as the record of decisions.
