# Session picker: many Macs, many harness sessions, attach any from anywhere

Design record for `bin/agent` and the login picker (phase 2, sessions). `README.md` section 3 is the user-facing
description; `AGENTS.md` has the layout and the test suites; phase 5 (`agent run`) builds on the command contract
in section 3.

## 1. Goal and decisions

Goal: the operator logs in from any Mac and sees every running Claude Code / Codex / Oh My Pi / OpenCode session on
the host, picks one, and gets it on that Mac's screen. Several Macs may be on the same or different sessions at
once.

| Question | Decision |
|---|---|
| Unit of a session | one harness run in one repo, 1:1 with a tmux session |
| Two devices on one session | independent views (tmux grouped sessions), not mirror, not take-over |
| Picker location | on the host, as the landing of every interactive SSH/mosh login; no WezTerm launcher |
| Resume depth | re-attach to live processes only; no conversation-ID registry, no restore after reboot |
| Where a new session runs | `~/workspace/<repo>` by default; `~/workspace/<repo>.wt/<slug>` on branch `agent/<slug>` on request |
| Picker detail | process facts only: harness, repo, branch, cwd, age, running/exited; no hooks |
| Plain shells | "shell" is a session type in the picker; a pre-existing plain session is listed as one and left alone |

Non-goals: harness conversation resume (`claude --resume`, `omp --resume`), "waiting for you" indicators,
WezTerm-side pickers, session restore at boot, per-device identities beyond the client address.

tmux facts (3.4 on Ubuntu 24.04, 3.6 on the host) the design rests on:

- tmux rewrites `.` in a session name to `_`, and `.` / `:` in a `-t` target are separators. Session names never
  contain them; commands target sessions by `#{session_id}` (`$N`), never by name.
- `tmux new-session -t <existing session>` puts the new session in a group with the existing one. Grouped sessions
  share windows and processes; current window, size and scroll position are per session.
- `-t` cannot be combined with `-n` or a shell command, so the base session is created plain with the harness as
  its command, and views are added afterwards.
- Grouped sessions share a window list, not a lifetime: killing the base leaves each view attached to a session
  nobody owns, so `agent kill` kills the views first, then the base.
- When the harness process exits its window closes in every session of the group, and with nothing else in the
  group base and views all disappear; `remain-on-exit` on the base is what stops that.
- `destroy-unattached on` on a view destroys it as soon as it has no client.
- A harness started as the tmux session command runs through `default-shell -c`, which is zsh on the host and
  reads `~/.zshenv`, so PATH and the secrets file reach it.

## 2. Architecture

```
Mac A  ssh/mosh ─┐                                  tmux server (one, per host login)
Mac B  ssh/mosh ─┼─ login shell ─ agent pick ─┐     ┌────────────────────────────────────────────┐
Mac C  ssh/mosh ─┘   (fzf loop)               │     │ base  ezbus             win1: claude  win2 │
                                              ├──►  │ view  ezbus@1  (Mac A, own cur win)        │
   ssh <host> <cmd>  ── never touches this ── │     │ view  ezbus@2  (Mac B)                     │
                                              │     │ base  agentic-framework-docs  win1: omp    │
                                              └──►  │ view  agentic-framework-docs@1 (Mac C)     │
                                                    │ base  scratch   win1: zsh                  │
                                                    │ main  (pre-existing, listed as shell)      │
                                                    └────────────────────────────────────────────┘
```

**Base session.** `agent new` creates `tmux new-session -d -s <name> -c <cwd> <harness command>`, then sets on it
`remain-on-exit on` (a finished or crashed harness leaves its last screen and shows as exited in the picker until
killed) and the user options `@harness`, `@repo`, `@cwd`, `@branch`, `@created`. Window 1 is the harness; further
windows opened with the prefix start in `#{pane_current_path}`. No registry file: tmux is the state.

**Views.** `agent attach <name>` runs `tmux new-session -t <base id> -s <name>@<n> \; set destroy-unattached on
\; set @device <ip>` in the foreground. `<n>` is the lowest free integer; `@device` is the first field of
`SSH_CLIENT`, the Mac's Tailscale or LAN address. Detaching destroys the view; the base stays. Nobody attaches the
base itself, so window size follows the attached views.

**Picker.** `agent pick` is an fzf loop: build the list from `agent ls --porcelain`, show it, act, repeat. Rows, in
order: `new session`, `new shell`, one row per base session (harness, repo, branch, `wt` for a worktree, age,
`running`/`exited`), `kill session`, `plain shell here`, `log out`. No preview window. Attach runs
in the foreground; when it returns (detach, kill, harness death) the loop shows the list again.

- `new session` asks for the repo (directories under `~/workspace` with a `.git`, `.wt` trees excluded), the
  harness (`claude`, `codex`, `omp`, `opencode`, `shell`) and an optional slug; a slug means a worktree. A slug
  whose `agent/<slug>` branch exists without a worktree is checked out again rather than passed to
  `worktree add -b`.
- `new shell` asks for a name (empty gives `scratch`).
- `kill session` shows the session list again under its own prompt and runs `agent kill` on the row chosen there,
  never on the highlighted row of the main list, so a stray Enter cannot destroy a harness; Esc backs out. The
  session's worktree goes with it, after one question on the terminal if it has uncommitted work.
- `plain shell here` exits 0 and the login shell continues outside tmux; `log out` exits 3 and the login fragment
  logs out.

**Entering a session.** Every row that leads to a session ends the picker's job, and the mechanism is decided by
`$TMUX`, not by the menu: `new-session -t` refuses to nest, so a terminal inside tmux can only have its client
switched, and one outside can only attach. `enter_session` picks accordingly, which is also what puts `pick` in
switch mode without `--switch`. In switch mode the loop returns instead of going round, so the popup closes over
the session it moved to. A session is created detached and entered afterwards, so `new session` chosen in the
popup starts the harness in the client behind it, not in the popup, where it would die with the popup. Nothing in
a picker flow may `exit`: that process is the login shell, so a flow that cannot finish sets a note, returns
non-zero, and the next menu shows the note as its header.

**Popup.** Inside tmux, prefix `g` opens the same picker in `display-popup -E` with `--switch`; a client under 100
columns gets a full-screen popup. Choosing a session creates the target view and `switch-client`s to it; the
abandoned view is destroyed by `destroy-unattached`. `log out` in the popup cannot exit the login shell, which is
in another process tree: the popup sets `AGENT_LOGOUT_<client tty>` in the tmux server environment and detaches the
client; the login shell's picker loop, returning from its foreground attach, claims the mark and exits 3. A mark is
claimed once and removed; a fresh login on that tty drops any mark left behind.

**Look.** The menu is read on a Mac in WezTerm and on a phone, so it is drawn from the width `tput cols` reports.
Under 70 columns a session row is NAME AGE STATE, under 106 it adds HARNESS and BRANCH, wider is the whole of
`agent ls`; the name is the only column that gives way, cut with an ellipsis. Five colours carry meaning: green
starts or runs, red ends, amber warns, blue is the accent, grey is context; each harness has a hue of its own. Rows
are painted with SGR codes and fzf runs with `--ansi`, which strips them from the row it hands back, so the first
word is the name. The verbs, the sessions and the ways out are three groups separated by rules, with a column
header over the sessions; the header starts with two spaces and fzf matches on the first `^  `-delimited field
only, so no query can land on it. Every menu carries a header with what it is for and what the keys do. A rounded
border with `agent · <host>` frames the login picker on 80 columns or more; inside tmux the popup's border is the
frame. Long prompts (`kill>`, `slug>`, `name>`) sit in headers, because a phone leaves a long prompt no room for the
answer. Floor is fzf 0.44.1 (Ubuntu 24.04); the gutter colour is set explicitly because fzf 0.6x draws a rail on
every row in it and `gutter:-1` makes that rail the foreground colour.

**Landing.** `config/bashrc.d/tmux-autoattach.sh` guards on `$- == *i*`, `SSH_TTY` set, `TMUX` empty, `NO_TMUX`
empty and the command present, then runs `agent pick`. Non-interactive `ssh <host> <cmd>` is untouched;
`ssh -t <host> 'NO_TMUX=1 zsh -l'` bypasses everything. tmux sessions without `@harness` are listed as `shell` and
never killed by the tooling.

**Naming.** `<repo>` plus `-<slug>` when given, `[.:]` replaced by `_`, `-2`, `-3` on collision. Views are
`<name>@<n>`. Names are for display; commands resolve a name to a session id once, then use the id.

**Unchanged by the picker.** WezTerm module, `~/.ssh/config`, mosh, clipboard bridge, the harness installs,
`~/.zshenv` environment loading. Cmd+Shift+A opens a host tab, which lands in the picker.

## 3. `bin/agent` contract

bash, `set -euo pipefail`, shellcheck clean, installed by `install-host.sh` phase 4 through the `link` helper as
`~/.local/bin/agent`. Runs against the default tmux server unless `AGENT_TMUX_SOCKET` is set, in which case every
tmux call gets `-L "$AGENT_TMUX_SOCKET"`; the tests use this to stay off the live server.

| Command | Behaviour | Exit |
|---|---|---|
| `agent new <repo> [--harness claude\|codex\|omp\|opencode\|shell] [--slug <slug>] [--name <name>] [--no-attach]` | validate repo dir; with `--slug`, `git worktree add ~/workspace/<repo>.wt/<slug> -b agent/<slug>` from the main checkout (reuse the worktree if it exists, check out `agent/<slug>` if only the branch does); create the base session; enter it unless `--no-attach` (switch inside tmux, attach outside) | 0; 2 usage or unknown repo/harness; 1 tmux/git failure |
| `agent ls [--porcelain]` | one line per base session. Human: aligned columns. Porcelain: tab-separated `name harness repo branch cwd state created_epoch devices`; `devices` is the comma-separated `@device` values of the group's attached views, `-` if none; harness `shell` and repo `-` for sessions without `@harness` | 0; 0 with no output when no server |
| `agent attach <name>` | create a view and attach; refuse if `<name>` is itself a view | 0 on detach; 2 unknown name |
| `agent pick [--switch]` | the fzf loop; `--switch` only inside tmux, and implied by `$TMUX` | 0 plain shell / 3 log out / 2 no fzf |
| `agent kill <name> [--force] [--keep-worktree]` | `kill-session` on every view, then on the base; a worktree under `~/workspace/<repo>.wt/` goes with it, the `agent/<slug>` branch never does. A dirty worktree is asked about on `/dev/tty` and kept on anything but yes, including when there is no terminal to ask; `--force` removes it without asking, `--keep-worktree` keeps it. A kept worktree prints the `git worktree remove` command | 0; 2 unknown |
| `agent switch` | alias for `pick --switch` | as pick |

Test seam: with `AGENT_PICK_FILTER` set, `agent pick` runs fzf with `--filter` and takes the first match, no tty
needed, for a single iteration. The value is `;`-separated, one filter per menu of the flow, because the kill row
asks twice. Nothing else in the tool is test-only. `--porcelain` is the interface phase 5 and the tests consume;
keep its columns stable.

## 4. Test layers

**Unit, `tests/agent-test.sh`** (no sudo, network or Docker). `AGENT_TMUX_SOCKET=af-test-$$`, a throwaway `HOME`
with a fake `~/workspace/<repo>` git repo, and a stand-in harness on PATH, so the live tmux server and real
harnesses are never touched. Covers: `new` sets the options and starts the stand-in in the repo; name sanitising
and `-2` on collision; `--slug` creates and reuses a worktree; `ls --porcelain` columns, a pre-existing plain
session listed as `shell`, views not listed; `attach` under `script` creates a view with `@device` and detaching
removes it; harness exit leaves the base as `exited`; `kill` removes base, views and a clean worktree while the
branch survives, keeps a dirty worktree when nobody can be asked (`setsid`), removes it under `--force`, keeps it
under `--keep-worktree`; `pick` under `AGENT_PICK_FILTER` for a session row, `log out` (3), `plain shell here` (0)
and the two-step kill flow; `log out` from a `--switch` picker driven into a pane, which detaches the client, exits
the login-side picker with 3 and leaves no `AGENT_LOGOUT_*` behind; the landing fragment under bash and zsh with
every combination of `SSH_TTY`, interactive, `TMUX` and `NO_TMUX`, invoking a stub `agent` only in the
interactive SSH case. A check that cannot run in the environment (no `script`, `setsid`, `fzf` or `shellcheck`)
prints a `skip` line rather than passing.

**Containers, `tests/e2e/run.sh`** (Docker without sudo). The host container `box` (login `alice`) and the Mac
container's two users are the two devices. Covers: `agent` linked and `fzf` present; non-interactive
`ssh box '...'` sees no tmux; a picker driven over `ssh -tt` from both users onto one session, two views with
independent current windows; detaching one view leaves the base and the other; `agent kill` removes everything and
ends the second ssh; `agent new --no-attach` with a stub harness shows `running`, then `exited` once the stub is
killed; `install-host.sh --no-tools` re-runs cleanly.

**Interactive, `tests/e2e/tui.sh`** (same containers). The real `agent pick` on a real pty, with `send-keys` as
typing and `capture-pane` as the screen, for every menu row and flow, including the popup, two Macs on one session,
an exited harness and Esc. Sets no `AGENT_PICK_FILTER`.

**Manual, on a Mac against the live host.** The rows in README section 5 that involve a Mac: ssh and mosh land in
the picker, a second Mac on the same session keeps its own current window, the popup switches and logs out, an
image paste in a picked session still attaches, `ssh <host> 'echo $TMUX'` prints an empty line.
