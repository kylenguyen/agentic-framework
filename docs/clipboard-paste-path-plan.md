# Clipboard bridge v2: Cmd+V pastes an image path, so every harness gets the image

Implementation plan for the next change to the clipboard bridge (phase 4). Written 20 Sep 2026 after the operator
answered the design questions in section 1; treat those answers as fixed unless the operator revises them. Read
`AGENTS.md` first (house rules, install contract), then this file. `README.md` and `docs/remote-agent-host-plan.md`
section 5 describe the bridge as it exists today; this plan replaces its delivery step and leaves its push step.

Work is on branch `agent/sonet` (worktree `~/workspace/agentic-framework.wt/sonet`). Section 4 says which steps are
already in the working tree, uncommitted, and which are still to do. Nothing has been committed.

## 1. Goal and decisions

Goal: on any Mac, in WezTerm, Cmd+C copies and Cmd+V pastes, text or screenshot, into whichever harness is running
on the host: Claude Code, Oh My Pi or OpenCode. Today an image paste reaches Claude Code only.

Decisions (operator, 20 Sep 2026):

| Question | Decision |
|---|---|
| How an image reaches the harness | WezTerm pastes the path of the pushed file; the harness attaches a pasted image path (all three do) |
| Cmd+C | nothing new; WezTerm's native copy stays, tmux and the harnesses copy back over OSC 52 as today |
| Retention of pushed images on the host | one `.png` per paste; each push deletes files older than 24 hours. No timer: a file can outlive 24 h until the next push, and that is accepted (operator, 20 Sep 2026). Text in `latest` is not pruned |
| Non-harness panes (shell, editor) | get the path pasted as text, same as any other pane connected to the host |
| xclip shim | unchanged; Ctrl+V in Claude Code keeps working, `latest` follows the newest image |
| Harness test | a separate script, `tests/e2e/harness-paste.sh`, with its own Docker image; `run.sh` stays as it is |

Non-goals: per-Mac spool directories, encrypting the spool, an upstream fix to Oh My Pi, Windows client changes,
any change to how text is pasted (it never touches the host).

## 2. Why: what was verified on the host, 20 Sep 2026

Facts, each reproduced on the live host in a scratch tmux session; nothing here is inferred.

- Oh My Pi 18.1.18 never runs `xclip` for an image. Its clipboard code (`src/utils/clipboard.ts` in the installed
  package) returns "no image" on Linux when `DISPLAY` and `WAYLAND_DISPLAY` are both unset, which is always the case on
  the host, and with a display it uses a native library (arboard) that talks to an X server, not to `xclip`. Its
  Ctrl+V handler then falls back to a text read that also needs a display, and shows "Clipboard is empty". So the
  bridge's Ctrl+V step, which relies on the harness calling the `xclip` shim, works for Claude Code only.
- With a fake `DISPLAY`, Oh My Pi's text read does go through `xclip -selection clipboard -o` and the shim serves it,
  but the image read waits about 3 seconds for the X11 connection to time out first. Not a usable path.
- Bracketed text paste into Oh My Pi inside tmux works. Plain Cmd+V of text is not the broken part; pressing Ctrl+V
  (Oh My Pi's own paste key) is, and so is Cmd+V while the Mac clipboard holds an image, because WezTerm then sends
  Ctrl+V instead of pasting.
- All three harnesses attach a pasted absolute path to a `.png` as an image, when it arrives as one bracketed paste:
  Claude Code 2.1.278 shows `[Image #1]`, Oh My Pi 18.1.18 shows a preview and `🖼 #1`, OpenCode 1.18.30 shows
  `[Image 1]`. Oh My Pi reads the file bytes into the attachment at paste time (`src/utils/image-loading.ts`), so a
  later change to the file does not affect an attached image. Whether Claude Code and OpenCode read the file at paste
  time or only when the message is sent is not verified (operator, 20 Sep 2026: unknown); section 5.4 checks it, and
  until then a prune by any Mac's push can in principle remove a file a harness has attached but not yet sent.
- Detection is by extension, so the file must end in `.png`. Oh My Pi splits a pasted line on whitespace, so the
  path must contain no spaces.
- The current spool `~/.clip/latest` has no extension and is overwritten by every push; on the host it held a
  screenshot from 18 Sep 2026, so pushed images already persist indefinitely.
- Claude Code in a fresh `HOME` with `ANTHROPIC_API_KEY` set shows a theme chooser, then "Do you want to use this API
  key?" with "No" preselected (Up, Enter accepts), then the prompt. Seeding `~/.claude.json` did not skip the key
  dialog; driving it with keys does. Oh My Pi in a fresh `HOME` shows a provider setup wizard ("esc skip"); a
  `~/.omp/agent/config.yml` containing `setupVersion: 2` skips it. OpenCode in a fresh `HOME` with no provider goes
  straight to its prompt with a "/connect" tip, and still attaches a pasted image path.

## 3. Design

Data flow on Cmd+V in a WezTerm pane connected to the host (its SSH domain, or a local pane running `ssh` or
`mosh-client`); any other pane gets WezTerm's ordinary paste:

1. WezTerm runs `~/.local/bin/clip-push --if-image` synchronously.
2. `clip-push` asks `osascript` what the clipboard holds. Text: prints `text/plain`, pushes nothing, exits 0;
   WezTerm performs its native paste. Nothing changes for text.
3. Image: prints `image/png`, pipes `pngpaste -` over `ssh <alias>-clip` into `~/.local/bin/clip-put` on the host.
4. `clip-put` writes stdin to a temp file under `~/.clip` (dir 700, file 600), sees the PNG magic, renames it to
   `~/.clip/<UTC stamp>-<6 random>.png` (for example `20260920T080428Z-WXwDkX.png`: sorts by time, no spaces, two
   pushes in one second stay apart), repoints the symlink `~/.clip/latest` at it atomically, prints the absolute
   path, then deletes `*.png` and `.put.*` older than `CLIP_KEEP_MINUTES` (default 1440) in that directory.
   A text payload still replaces `latest` as a regular file and prints nothing (plain `clip-push` pushes text).
5. `clip-push`'s stdout is now two lines, type then path. WezTerm takes the path from line 2 and calls
   `pane:paste(path)`, which WezTerm delivers as a bracketed paste when the pane has enabled bracketed paste, so the
   harness sees one paste and attaches the image. If the push failed or no path came back, WezTerm shows a toast
   and pastes nothing, so a stale or guessed path is never attached.
6. The `xclip` shim is untouched: `latest` is a symlink to the newest image, `head -c 8`, `cat` and `[ -s ]` follow
   it, so Ctrl+V in Claude Code still serves the newest image, and text copies still go back to the Mac as OSC 52.
   After a prune `latest` may dangle; the shim then exits 1, which callers already handle.
7. `clip-put --clear` removes `latest`, every `.png` and any `.put.*` leftovers.

Trade-offs accepted: the same bytes are not written twice (symlink, not copy); a shell pane receives a path string
where it used to receive a harmless Ctrl+V; Confidential screenshots sit on the host until the first push more than a
day later (there is no timer, so a quiet weekend keeps Friday's screenshot until Monday's first paste) and the
directory is shared by every Mac that pushes (the README already says the spool is shared).

## 4. Changes, in commit order

Status: steps 1 to 5 are in the working tree, uncommitted, and passed `tests/e2e/run.sh` (section 5.1). Steps 6
to 9 are not started. Commit style per `~/workspace/CLAUDE.md`: imperative subject under 72 characters, a body that
says why, tests run and reported.

| # | Change | Files | Status |
|---|---|---|---|
| 1 | `clip-put`: one `.png` per image with the stamp name, `latest` symlink, print the path, 24 h prune, `--clear` removes all; `CLIP_KEEP_MINUTES` override; header comment says why | `bin/clip-put` | done, uncommitted |
| 2 | WezTerm Cmd+V handler: parse line 2 of `clip-push` output as the path, `pane:paste(path)` instead of `SendKey Ctrl+V`, toast when no path; comment block rewritten | `config/wezterm-agent-host.lua.in` | done, uncommitted |
| 3 | Comments only: `clip-push` documents the second output line and that `--clear` is optional; the `xclip` shim's data-flow comment says the image half is off the Cmd+V path | `bin/clip-push-mac.sh.in`, `bin/xclip` | done, uncommitted |
| 4 | Lua stub gains `pane.paste` (prints `paste <text>`); header lists the new event | `tests/e2e/wezterm-paste.lua` | done, uncommitted |
| 5 | `run.sh`: clipboard section checks path shape, file bytes, `latest` symlink, modes, second push keeps the first, prune, `--clear`; Cmd+V section expects `paste /home/alice/.clip/*.png` for domain, ssh and mosh panes and byte-exact content; failure case pastes nothing; second-Mac checks read line 1 of the push | `tests/e2e/run.sh` | done, uncommitted |
| 6 | Harness image: e2e host image plus mise, Node, Oh My Pi (npm), OpenCode and Claude Code installers, as the login; every version pinned by a build arg (`NODE`, `OMP`, `OPENCODE`, `CLAUDE`, defaults in the Dockerfile, the pin flag of each installer confirmed while building); build fails if any of the three is missing | `tests/e2e/Dockerfile.harness` | file written, never built; pins to add |
| 7 | Harness test script, section 5.2 | `tests/e2e/harness-paste.sh` | to do |
| 8 | Docs: README checkpoints, bridge section and the "Clipboard bridge checks" block (`file ~/.clip/latest` and `ls ~/.clip` change), `docs/remote-agent-host-plan.md` section 5, `AGENTS.md` rows for `clip-put`, `clip-push`, `xclip`, `tests/e2e/`, phase 4 status, and the Boundaries line that names `~/.clip/latest` (now the whole `~/.clip/` directory); `install-mac.sh` note text (line 108) still reads correctly and needs no change | `README.md`, `docs/remote-agent-host-plan.md`, `AGENTS.md` | to do |
| 9 | Live check from a Mac (section 5.4), then push | | to do |

Suggested commits: (a) steps 1 to 5 together, "Paste the pushed image's path instead of sending Ctrl+V";
(b) steps 6 and 7, "Drive the three harnesses with a pasted image path in a container"; (c) step 8, "Document
the pasted-path clipboard bridge". Each commit body names the tests run and their counts.

Review follow-ups (20 Sep 2026), small code edits that ride in commit (a) unless marked open:

- `clip-put` header: a `CLIP_BRIDGE_SPOOL` override must point into a dedicated directory, because every push now
  prunes `*.png` older than the retention in that directory.
- WezTerm toast when the push succeeded but no path came back: say "host clip-put is older than this Mac's config;
  git pull on the host", since that is the one way it happens.
- Decision 1: no timer; prune on the next push only. The `clip-put` header and the docs must say "until the next
  push more than 24 h later", not "within 24 h".
- Decision 4: the harness test pastes through the Mac-side tmux and `ssh -tt` (section 5.2 step 5), the route
  WezTerm's paste really takes.
- Decision 6: the container test seeds a placeholder `ANTHROPIC_API_KEY` for Claude Code. It is a fake string in a
  throwaway container, nothing reaches Anthropic and nothing is billed; the operator's own login is a subscription
  and is never copied anywhere. Use a value without the `sk-ant-` prefix if Claude Code accepts one, so secret
  scanners stay quiet; if it insists on the prefix, keep `sk-ant-placeholder` and say so in the script comment.

## 5. Verification

### 5.1 `tests/e2e/run.sh` (already run, 20 Sep 2026)

Result: 135 passed, 1 failed. The failure is `host: tests/params-test.sh`, the deployment-literal scan on
`config/claude-settings.json`, which is red at `main` and unrelated (see memory note "params-test red at main").
Every clipboard, Cmd+V, copy-back and second-Mac check passed, including the new ones:

- the push prints `/home/alice/.clip/<stamp>-<random>.png`; that file is a PNG, mode 600, directory 700
- `latest` is a symlink to it and `xclip -t TARGETS -o` over ssh still says `image/png`
- a second push creates a second file and leaves the first; a file aged 25 hours is gone after the next push while
  the younger one stays; `--clear` leaves the directory empty
- Cmd+V into the host domain, a local `ssh` pane and a local `mosh-client` pane each print `paste <path>` and the
  path holds the pushed PNG byte for byte, with no spaces; a text clipboard still yields `action PasteFrom Clipboard`
  with the spool untouched; a failed push yields a toast and no `paste`/`action` line
- Ctrl+V in Claude Code still works: `xclip -t image/png -o` returns the same bytes, a text request exits 1

Re-run after any further edit to steps 1 to 5: `bash tests/e2e/run.sh` (about 3 minutes, Docker without sudo).

### 5.2 `tests/e2e/harness-paste.sh` (to write)

Purpose: prove the whole path from a Mac clipboard fixture to an attached image inside each real harness, in
containers, with no credentials. `run.sh` stops at the pasted path; this script starts from it. The paste goes
through a Mac-side tmux pane running `ssh -tt`, not through `paste-buffer` on the box, because the step that
matters live is the host tmux recognising a bracketed paste arriving from its client and forwarding it whole; a
paste injected on the box would skip that step.

Layout, reusing the helpers and conventions of `run.sh` and `tui.sh` (`ok`, `bad`, `check`, `has`, `say`,
`cleanup` with `KEEP=1`, `box`/`mac` wrappers, `await` polling of `capture-pane`):

1. Build `af-e2e-host` (as `run.sh` does), then `af-e2e-harness` from `tests/e2e/Dockerfile.harness` with
   `--build-arg BASE=af-e2e-host --build-arg LOGIN=alice`, then `af-e2e-mac`. Network `af-hp`, containers
   `af-hp-box` (from the harness image, hostname `box`) and `af-hp-mac`. On the Mac, a tmux server of its own
   (socket `term`, as `tui.sh` does) whose one pane runs `ssh -tt -o BatchMode=yes box`: that pane is the stand-in
   for the WezTerm pane, so a paste into it crosses ssh and reaches the host tmux as a client would deliver it.
2. Copy the working tree into both (no `.git`, no `.env`); wait for sshd; `install-host.sh --no-tools` on the box;
   `.env` and `install-mac.sh` on the Mac through the askpass password path, as in `run.sh`. Check both exit 0.
3. Seed what the harnesses need to reach a prompt without a login: append `ANTHROPIC_API_KEY=sk-ant-placeholder`
   to `/home/alice/.config/agents/env` (sourced by `zshenv`, so the harness started by `agent new` sees it);
   write `/home/alice/.omp/agent/config.yml` with `setupVersion: 2`. Create the stand-in repo
   `/home/alice/workspace/standin` (`git init`, one empty commit) as `run.sh` does.
4. Put the 16x16 PNG fixture on the Mac (`/tmp/clipboard.png`, base64 embedded in the script; a 1x1 PNG is not
   used in case a harness rejects it) and `png` in `/tmp/clipboard.kind`.
5. For each harness in `claude omp opencode`:
   - `agent new standin --harness <h> --no-attach` on the box; check it prints `<h>-standin`.
   - `await` the prompt on the pane, up to 90 seconds, answering dialogs as they appear: Claude Code's theme chooser
     (Enter), "Do you want to use this API key?" (Up, Enter), a trust dialog (Enter), until `❯` is on screen;
     Oh My Pi until `π >`, pressing Escape if "esc skip" appears; OpenCode until "Ask anything".
   - Attach: in the Mac-side pane, type `agent attach <h>-standin` (or the picker route `tui.sh` uses), `await` the
     harness prompt on the Mac-side screen. From here every keystroke and paste goes through ssh and the host tmux.
   - Text: `tmux set-buffer` on the Mac with `hello-from-mac` and `tmux paste-buffer -p -t term`. `-p` wraps it in
     bracketed-paste markers exactly as WezTerm's native paste does; ssh carries them, the host tmux recognises the
     paste from its client and forwards it to the harness as one paste. `await` the text in the editor.
   - Image: run the rendered WezTerm module on the Mac, `lua5.4 tests/e2e/wezterm-paste.lua domain`, check the one
     line `paste /home/alice/.clip/*.png` and that the file's sha256 equals the fixture's; then deliver that path the
     way `pane:paste` would, `tmux set-buffer` and `tmux paste-buffer -p -t term` on the Mac; `await` the indicator:
     `[Image #1]` for Claude Code, `🖼 #1` for Oh My Pi, `[Image 1]` for OpenCode.
   - Negative: paste the path of a file that does not exist the same way and check no indicator appears (guards the
     assertion).
   - Detach with the tmux prefix and `d` on the Mac-side pane, so the next harness attaches into a clean pane.
   - `agent kill <h>-standin`; check `agent ls --porcelain` is empty.
6. Print the three harness versions (`claude --version`, `omp --version`, `opencode --version`) next to
   `N passed, M failed`; exit 0 only when M is 0. The indicator strings in step 5 are version-specific, so a run's
   result means nothing without the versions it saw.

Expected duration: image build several minutes the first time (network), then about 4 minutes. Document in the
README "More" list and `AGENTS.md` tests table as the check to run when a harness is upgraded on the host.

Known unknowns to resolve while writing it, each with the fallback if the first attempt fails:

- Claude Code inside the container may show dialogs in a different order or a "trust this folder" prompt; the
  `await` loop must react to whatever is on screen rather than script a fixed key sequence.
- The container has outbound network through Docker's bridge; if a harness's update check slows startup, set
  `DISABLE_AUTOUPDATER=1` for Claude Code and accept a longer `await`.
- If `agent new` cannot find `omp` because the mise shim is not on PATH under `zsh -c`, the `Dockerfile.harness`
  `ENV PATH` does not reach login shells; the fix is in the image (a symlink into `~/.local/bin`), not in the repo's
  shell config.

### 5.3 Unit and static checks

- `bash tests/agent-test.sh` (no Docker): must stay green; `bin/agent` is not touched by this change.
- `bash tests/params-test.sh`: expect 90 passed, 1 failed, the pre-existing literal scan only. Any new failure in
  the template render or dry-run sections is a regression from step 2 (the WezTerm template).
- `shellcheck -x bin/clip-put bin/xclip tests/e2e/run.sh tests/e2e/harness-paste.sh`; shellcheck cannot lint the
  `.in` template with `@AGENT_HOST@` in place, so render it first via the params library as `params-test.sh` does.
- `lua5.4 -e 'loadfile("/tmp/rendered.lua")'` or the `apply` scenario of `wezterm-paste.lua` against a rendered
  copy, to catch a syntax slip in the Lua before a Mac reloads it. `lua5.4` is not installed on the host; run this
  inside the mac container (`run.sh` already does the `apply` scenario there).

### 5.4 Live check on a Mac and the host (before pushing)

From a Mac after `git pull` and `./install-mac.sh` (re-renders `clip-push`), then WezTerm reload (Cmd+Shift+R):

| Step | Expect |
|---|---|
| Cmd+Shift+Ctrl+4, then Cmd+V in an Oh My Pi session on the host | the image preview and `🖼 #1` in the editor |
| Same in Claude Code | `[Image #1]` |
| Same in OpenCode | `[Image 1]` |
| Cmd+V of an image in a local WezTerm pane running `ssh <host>` (not the domain) into any harness | the same indicator |
| Same in a local pane running `mosh <host>` | the same indicator; mosh must pass bracketed paste both ways (Mac mosh assumed latest, 1.4.0) |
| In Claude Code and in OpenCode: Cmd+V an image, then `host$ rm ~/.clip/<that file>.png`, then send "describe the image" | the model describes it (file read at paste time) or an error (read at send time); record the answer in section 2 |
| Cmd+V of the same image into a plain shell on the host | one line: `/home/<login>/.clip/<stamp>-<random>.png` |
| `host$ ls -l ~/.clip` | the `.png` files, mode 600, `latest -> <newest>.png` |
| Cmd+V of text into any of the three | pastes at once, `ls -l ~/.clip` unchanged |
| Select text with the mouse in a harness, Cmd+C, Cmd+V elsewhere on the Mac | the text (native WezTerm copy) |
| tmux copy mode (Ctrl+B `[`, Space, Enter), then `mac$ pbpaste` | the copied text (OSC 52, unchanged) |
| Ctrl+V in Claude Code after an image Cmd+V | `[Image #2]` from the shim, same image |
| `host$ touch -d '25 hours ago' ~/.clip/*.png` then one Cmd+V image push | old files gone, only the new one and `latest` remain |
| `mac$ clip-push --clear && ssh <host> 'ls -A ~/.clip'` | nothing listed |
| `mac$ time clip-push` with an image on the clipboard | well under 1 s on the second run, two output lines |

On the host, the change takes effect as soon as the repo checkout under `~/workspace/agentic-framework` has it,
because `~/.local/bin/clip-put` and `xclip` are symlinks into that checkout. The Mac side needs the re-render.

## 6. Done criteria

- `bash tests/e2e/run.sh`: every clipboard, Cmd+V and copy check green; only the pre-existing literal-scan failure.
- `bash tests/e2e/harness-paste.sh`: text and image paste green for all three harnesses, exit 0.
- `bash tests/agent-test.sh` green; `tests/params-test.sh` unchanged from `main`.
- Section 5.4 table checked on at least one Mac against the live host, with Oh My Pi as the first case.
- README, `docs/remote-agent-host-plan.md` and `AGENTS.md` describe the pasted-path flow and no longer describe
  Ctrl+V as the delivery step; the README rollback line for the bridge still works (`rm -rf ~/.clip` removes the
  files and the symlink).
- Commits pushed to `agent/sonet`; compare URL given to the operator (gh is not authenticated on the host).
