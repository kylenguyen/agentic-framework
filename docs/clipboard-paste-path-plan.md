# Clipboard bridge: Cmd+V pastes an image path, so every harness gets the image

Design record for phase 4, the clipboard bridge. `README.md` sections 3 and 5 describe it for the operator;
`docs/remote-agent-host-plan.md` section 5 places it in the phase plan; `bin/clip-put`, `bin/xclip`,
`bin/clip-push-mac.sh.in` and `config/wezterm-agent-host.lua.in` carry the mechanics in their header comments.

## 1. Goal and decisions

Goal: on any Mac, in WezTerm, Cmd+C copies and Cmd+V pastes, text or screenshot, into whichever harness is running
on the host.

| Question | Decision |
|---|---|
| How an image reaches the harness | WezTerm pastes the path of the pushed file; Claude Code, Oh My Pi and OpenCode all attach a pasted image path |
| Cmd+C | WezTerm's native copy; tmux and the harnesses copy back over OSC 52 |
| Retention of pushed images on the host | one `.png` per paste; each push deletes files older than 24 hours. No timer, so a file can outlive 24 h until the next push. Text in `latest` is not pruned |
| Non-harness panes (shell, editor) | get the path pasted as text, like any other pane connected to the host |
| xclip shim | serves Ctrl+V in Claude Code; `latest` follows the newest image |
| Harness test | a separate script, `tests/e2e/harness-paste.sh`, with its own Docker image; `run.sh` stops at the pasted path |

Non-goals: per-Mac spool directories, encrypting the spool, an upstream fix to Oh My Pi, Windows client changes,
any change to how text is pasted (it never touches the host).

## 2. Why a pasted path

Facts reproduced on the host, each in a scratch tmux session:

- Oh My Pi never runs `xclip` for an image. Its clipboard code returns "no image" on Linux when `DISPLAY` and
  `WAYLAND_DISPLAY` are both unset, which is always the case on the host; with a display it uses a native library
  that talks to an X server, not to `xclip`. A delivery step that relies on the harness calling the `xclip` shim
  therefore works for Claude Code only.
- With a fake `DISPLAY`, Oh My Pi's text read does go through `xclip -selection clipboard -o`, but the image read
  waits about 3 seconds for the X11 connection to time out first. Not a usable path.
- Bracketed text paste into every harness inside tmux works. The broken part is Cmd+V while the Mac clipboard holds
  an image, when WezTerm would otherwise send Ctrl+V.
- All three harnesses attach a pasted absolute path to a `.png` as an image when it arrives as one bracketed paste:
  Claude Code shows `[Image #1]`, Oh My Pi a preview and `🖼 #1`, OpenCode `[Image 1]`. Oh My Pi reads the file
  bytes into the attachment at paste time; whether Claude Code and OpenCode read at paste time or at send time is
  not verified, so a prune by any Mac's push can in principle remove a file a harness has attached but not sent.
- Detection is by extension, so the file must end in `.png`. Oh My Pi splits a pasted line on whitespace, so the
  path must contain no spaces.
- To reach a prompt without a login: Claude Code with `ANTHROPIC_API_KEY` set shows a theme chooser, an API key
  confirmation, the security notes and a trust prompt, two of which preselect the answer that quits, so a test has
  to drive them by what is on screen. A key without the `sk-ant-` prefix is not detected at all. Oh My Pi's
  provider wizard is skipped by a `~/.omp/agent/config.yml` containing `setupVersion: 2`. OpenCode with no
  provider goes straight to its prompt and attaches a pasted image path.

## 3. Design

Data flow on Cmd+V in a WezTerm pane connected to the host (its SSH domain, or a local pane running `ssh` or
`mosh-client`); any other pane gets WezTerm's ordinary paste:

1. WezTerm runs `~/.local/bin/clip-push --if-image` synchronously.
2. `clip-push` asks `osascript` what the clipboard holds. Text: prints `text/plain`, pushes nothing, exits 0, and
   WezTerm performs its native paste.
3. Image: prints `image/png`, pipes `pngpaste -` over `ssh <alias>-clip` into `~/.local/bin/clip-put` on the host.
4. `clip-put` writes stdin to a temp file under `~/.clip` (dir 700, file 600), sees the PNG magic, renames it to
   `~/.clip/<UTC stamp>-<random>.png` (sorts by time, no spaces, two pushes in one second stay apart), repoints the
   symlink `~/.clip/latest` at it atomically, prints the absolute path, then deletes `*.png` and `.put.*` older
   than `CLIP_KEEP_MINUTES` (default 1440) in that directory. A text payload replaces `latest` as a regular file
   and prints nothing (plain `clip-push` pushes text).
5. `clip-push`'s stdout is two lines, type then path. WezTerm takes line 2 and calls `pane:paste(path)`, which
   arrives as a bracketed paste when the pane has enabled it, so the harness sees one paste and attaches the image.
   If the push failed or no path came back, WezTerm shows a toast and pastes nothing, so a stale or guessed path is
   never attached. A successful push with no path means the host's `clip-put` is older than the Mac's config.
6. The `xclip` shim follows `latest` (`head -c 8`, `cat` and `[ -s ]` all resolve the symlink), so Ctrl+V in Claude
   Code serves the newest image, and text copies go back to the Mac as OSC 52. After a prune `latest` may dangle;
   the shim then exits 1, which callers handle.
7. `clip-put --clear` removes `latest`, every `.png` and any `.put.*` leftovers.

Trade-offs accepted: a shell pane receives a path string where a harmless Ctrl+V would otherwise land;
Confidential screenshots sit on the host until the first push more than a day later (a quiet weekend keeps
Friday's screenshot until Monday's first paste), and the directory is shared by every Mac that pushes. A
`CLIP_BRIDGE_SPOOL` override must point into a dedicated directory, because every push prunes `*.png` older than
the retention there.

## 4. Test layers

**`tests/e2e/run.sh`** covers the push and the paste decision: the push prints `/home/alice/.clip/<stamp>-<random>.png`,
the file is a PNG with mode 600 in a 700 directory, `latest` is a symlink to it and `xclip -t TARGETS -o` over ssh
says `image/png`; a second push leaves the first file, a file aged 25 hours is gone after the next push, `--clear`
empties the directory; Cmd+V into the host domain, a local `ssh` pane and a local `mosh-client` pane each print
`paste <path>` from the rendered WezTerm module under Lua 5.4 (`tests/e2e/wezterm-paste.lua`, stub `wezterm`
table with `pane.paste`) and the path holds the pushed PNG byte for byte; a text clipboard yields WezTerm's native
paste with the spool untouched; a failed push yields a toast and no paste; the `xclip` calls Claude Code makes on
Ctrl+V return the same bytes.

**`tests/e2e/harness-paste.sh`** takes the path into the real harnesses, in containers, with no credentials.
`tests/e2e/Dockerfile.harness` layers mise, Node, Bun (Oh My Pi's launcher is `#!/usr/bin/env bun`), Oh My Pi,
OpenCode and Claude Code onto the e2e host image, every version pinned by a build arg and checked with
`--version`; `DISABLE_AUTOUPDATER=1` keeps the Claude Code pin. The Mac container holds a tmux server whose one
pane runs `ssh -tt box`, the stand-in for the WezTerm pane, so a paste into it crosses ssh and reaches the host
tmux as a client would deliver it; a paste injected on the box would skip the step that matters, the host tmux
recognising a bracketed paste from its client and forwarding it whole. The box gets a placeholder
`ANTHROPIC_API_KEY` (fake, in a throwaway container; nothing reaches Anthropic) and the Oh My Pi config that skips
its wizard. Per harness: `agent new standin --harness <h> --name <h>-standin --no-attach`; the first-run dialogs
are cleared reactively until the empty editor's placeholder is on screen (`Try "`, `π >`, `Ask anything`; the
footer is not used because Claude Code's footer is this repo's status line and wraps at 80 columns); the Mac pane
attaches with `agent attach`; text arrives through `tmux paste-buffer -p`, which wraps it in bracketed-paste
markers as WezTerm's native paste does; the rendered WezTerm module pushes the fixture and the path it prints is
pasted the same way, and the indicator must appear; a path to no file must not produce the second indicator
(Claude Code and OpenCode leave the token in the editor, Oh My Pi drops it, so the absence of the indicator is the
only common assertion); detach, `agent kill`. The run prints the three harness versions next to its totals,
because the indicator strings are version-specific. Run it when a harness is upgraded on the host.

**Static.** `shellcheck -x bin/clip-put bin/xclip tests/e2e/run.sh tests/e2e/harness-paste.sh`; the `.in` template
is linted after rendering, as `tests/params-test.sh` does. The Lua is checked by the `apply` scenario of
`wezterm-paste.lua` against a rendered copy inside the Mac container, since `lua5.4` is not on the host.

**Manual, on a Mac against the live host** (after `git pull`, `./install-mac.sh` to re-render `clip-push`, and a
WezTerm reload). The host side needs no re-render, since `clip-put` and `xclip` are symlinks into the checkout.

| Step | Expect |
|---|---|
| Screenshot, then Cmd+V in Oh My Pi, Claude Code and OpenCode on the host | the image preview and `🖼 #1`; `[Image #1]`; `[Image 1]` |
| The same from a local pane running `ssh <host>` and one running `mosh <host>` | the same indicators; mosh must pass bracketed paste both ways |
| In Claude Code and OpenCode: Cmd+V an image, `rm` the file on the host, send "describe the image" | tells whether the file is read at paste time or send time; record the answer in section 2 |
| Cmd+V of the same image into a plain shell on the host | one line, `/home/<login>/.clip/<stamp>-<random>.png` |
| `host$ ls -l ~/.clip` | the `.png` files, mode 600, `latest -> <newest>.png` |
| Cmd+V of text into any harness | pastes at once, `ls -l ~/.clip` unchanged |
| Mouse selection, Cmd+C, Cmd+V elsewhere on the Mac | the text (native WezTerm copy) |
| tmux copy mode, then `mac$ pbpaste` | the copied text (OSC 52) |
| Ctrl+V in Claude Code after an image Cmd+V | `[Image #2]` from the shim, same image |
| `host$ touch -d '25 hours ago' ~/.clip/*.png`, then one image Cmd+V | old files gone; the new one and `latest` remain |
| `mac$ clip-push --clear && ssh <host> 'ls -A ~/.clip'` | nothing listed |
| `mac$ time clip-push` with an image on the clipboard | well under 1 s on the second run, two output lines |
