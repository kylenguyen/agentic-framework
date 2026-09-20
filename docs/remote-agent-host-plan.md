# Remote coding-agent host: design

Target: one headless Ubuntu Server LTS box on a Tailscale tailnet, called `<host>` below, with a single login
`<user>`; several macOS clients, each running WezTerm, reach it over the tailnet with a LAN fallback for SSH. The
real names, addresses and login are parameters (`.env` or the system; see `lib/params.sh` and README "Parameters");
the repo carries none of them. `<lan-ip>` stands for the host's LAN address. Windows and phone clients are out of
scope; the design does not block them.

Each phase has four parts: what to set up on <host>, what to set up on the Mac, how to test <host> alone, how to
test the Mac alone. A joint checkpoint closes the phase. This document holds the design and the per-phase tests; the
ordered procedure from bare machines, including the steps before phase 1, is the README. Phases 1 to 4 are built;
phases 5 and 6 are design only (AGENTS.md "Status").

## 0. Decisions and assumptions

Decided:

- Terminal over SSH only. No IDE remote, no remote desktop.
- Harnesses: Claude Code (primary), Codex, OpenCode, Oh My Pi. API keys only, no local models.
- Automation: on-demand from other devices, scheduled runs, git-event triggers, long-running loops.
- Git hosting is GitHub.

Assumed:

- Access over the tailnet, with the LAN as a fallback path for SSH. The host runs no firewall of its own and sshd
  keeps the OS defaults; the router keeps it off the internet.
- Repos live under `~/workspace/<repo>`. This repo holds every script, config and doc.
- Nothing connects into the Macs. The clipboard bridge is a push from the Mac (Cmd+V in WezTerm) over the same
  Mac → <host> SSH path; Remote Login on the Macs is not required.
- <host> sshd is whatever the Ubuntu installer left (password login on unless a key was imported at install). Keys
  are the default for the Macs and for everything non-interactive (mosh, the clipboard bridge, `ssh <host> agent`);
  `install-mac.sh` installs the Mac key over the password path once.
- Claude Code on Linux reads clipboard images by running `xclip -selection clipboard -t TARGETS -o`, then
  `xclip -selection clipboard -t image/png -o`; text via `xclip -selection clipboard -t text/plain -o`; copy-out
  through `xclip`/`xsel`/`wl-copy` or OSC 52. The clipboard bridge (phase 4) hooks exactly these calls.

## 1. Target architecture

```
  Macs (WezTerm)
        │  ssh / mosh  →        image push on Cmd+V  →
        │        Tailscale (100.64.0.0/10), LAN fallback for ssh
  ┌─────▼──────────────────────────────────────────────┐
  │ <host>                                             │
  │  sshd as installed by Ubuntu + mosh-server        │
  │  tmux: one base session per harness run,          │
  │        one view per device (bin/agent)             │
  │  harnesses: claude, codex, opencode, omp           │
  │  clipboard: Mac push → clip-put spool → xclip shim │
  │  automation: agent CLI, systemd timers,            │
  │              GitHub runner, queue worker           │
  │  optional: Docker sandbox per repo                 │
  └─────────────────────┬──────────────────────────────┘
                        │ HTTPS
             Anthropic / OpenAI / other LLM APIs
```

Text copy: remote → Mac via OSC 52 (tmux passes it through, WezTerm writes the Mac clipboard). Mac → remote via
ordinary paste. Image paste: Cmd+V in WezTerm runs `clip-push --if-image` on the Mac, which pipes the image into
`clip-put` on <host>; `clip-put` stores it as `~/.clip/<stamp>.png` and prints that path, and WezTerm pastes the
path into the pane, which every harness attaches as an image.

## 2. Phase 1: access

### On the host

1. A Mac key already works (`ssh <host> true`), or password login is on
   (`sudo sshd -T | grep -i ^passwordauthentication`) so `install-mac.sh` can put the key there. sshd and the
   firewall are left as the installer set them; nothing in this repo edits `/etc/ssh` or runs ufw.
2. `sudo apt install tmux mosh gh zsh fzf git curl file jq unattended-upgrades`; `chsh -s /usr/bin/zsh <user>`.
   Shell config is phase 2.
3. `loginctl enable-linger <user>` so user systemd units and tmux survive logout.
4. `sudo tailscale set --auto-update`; unattended-upgrades enabled.
5. Optional: `sudo tailscale up --ssh` for identity-based SSH via Tailscale ACLs. Keep OpenSSH as well; mosh and
   the clipboard push use plain sshd.

### On the Mac

1. `~/.ssh/config` entries, rendered from `config/ssh_config.mac.in`:
   ```
   Host <host>
     HostName <host>
     User <user>
     IdentityFile ~/.ssh/id_ed25519
     ServerAliveInterval 30
     ForwardAgent no
   ```
   `<host>` resolves via MagicDNS. `Host <host>-lan` with `HostName <lan-ip>` is the LAN fallback.
2. `brew install mosh`.
3. The Tailscale app running and set to start at login.

### Test the host alone

```
sudo ss -lntup | grep -E ':22 |mosh'    # sshd listening; mosh-server appears only when a client connects
loginctl show-user <user> | grep Linger    # Linger=yes
getent passwd <user> | cut -d: -f7         # /usr/bin/zsh
```

### Test the Mac alone

```
ssh -G <host> | grep -E '^(hostname|user|identityfile)'   # config parsed as intended
tailscale status | grep <host>                            # or /Applications/Tailscale.app/Contents/MacOS/Tailscale status
dns-sd -G v4 <host>.<tailnet>.ts.net                     # MagicDNS resolves
mosh --version
```

### Joint checkpoint

From the Mac: `ssh <host> true` succeeds without a prompt (key path);
`ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no <user>@<host> true` asks for the password and
then succeeds (password path); `mosh <host>` connects and survives toggling Wi-Fi off and on; `ssh <host>-lan true`
works on the home LAN.

## 3. Phase 2: sessions and terminal

### On the host

1. `~/.tmux.conf` → symlink to `config/tmux.conf`: `tmux-256color`, clipboard terminal features, `set-clipboard on`
   (OSC 52 to the outer terminal), `allow-passthrough`, mouse, 100000 lines of history, `SSH_CLIENT SSH_TTY` in
   `update-environment`, focus events, `escape-time 10`. Prefix `g` opens the picker in a popup; prefix `c` opens a
   window in the current directory; `status-left` shows session and harness.
2. Shell profile (`config/bashrc.d/tmux-autoattach.sh`): interactive SSH logins run `agent pick`, the session
   picker, guarded with `[[ $- == *i* && -n $SSH_TTY && -z $TMUX && -z $NO_TMUX ]]` so `ssh <host> <command>` and
   automation never trigger it. The picker exits 0 for "plain shell here" (the login shell carries on outside tmux)
   and 3 for "log out" (the fragment exits the shell).
3. Login shell: zsh with oh-my-zsh, so interactive work on <host> gets completion, git prompt and history search
   without per-device setup. Phase 1 installs `zsh` and runs `chsh`; phase 2 clones `~/.oh-my-zsh` and symlinks
   `~/.zshenv` → `config/zshenv` and `~/.zshrc` → `config/zshrc`.
   - `~/.zshenv` sources `bashrc.d/agents-env.sh`, because `ssh <host> <command>` under a zsh login shell runs
     `zsh -c`, which reads only `.zshenv`. This mirrors the env block at the top of `~/.bashrc`.
   - `~/.zshrc` loads oh-my-zsh (theme `robbyrussell`, plugin `git`, auto-update disabled so an update prompt can
     never block an unattended tmux window) and then the same `bashrc.d/mise.sh` and `bashrc.d/tmux-autoattach.sh`
     as bash. The fragments run under both shells; `mise.sh` selects `mise activate zsh` or `bash` from
     `$ZSH_VERSION`.
   - bash stays fully configured: `ssh -t <host> 'NO_TMUX=1 bash -l'` works, and scripts keep `#!/usr/bin/env bash`.
   - tmux picks its default shell from `$SHELL` when the server starts, so a server started under bash keeps bash
     until `tmux kill-server` or a reboot.
4. Sessions are owned by `bin/agent` (design in `docs/session-picker-plan.md`): one harness run in one repo is one
   base session named `<repo>[-<slug>]`, created by `agent new` with the harness as the session command,
   `remain-on-exit on` so a finished harness leaves its last screen, and `@harness`, `@repo`, `@cwd`, `@branch`,
   `@created`, `@hwin` for the picker to read. tmux is the only state; there is no registry file and nothing
   survives a reboot.
   - Each device attaches its own view: `agent attach` creates `<name>@<n>` grouped with the base, sets `@device`
     from `SSH_CLIENT` and `destroy-unattached on`, so two Macs share the processes but keep their own current
     window, size and scroll, and detaching leaves the harness running. Nobody attaches a base directly.
   - `agent pick` is the fzf loop behind all of it, a plain list with no preview window; prefix `g` opens it in
     `display-popup -E` with `--switch`. `agent ls --porcelain` is the stable machine interface
     (`name harness repo branch wt cwd state created_epoch devices`).
   - Session names never contain `.` or `:`: tmux rewrites the first and treats both as target separators.
     Commands resolve a name to a `#{session_id}` once and use that.
   - Sessions that predate the tooling have no `@harness`, are listed as shells, and are never killed by it.
5. `fzf` comes from phase 1; without it the picker exits 2 and says so rather than dropping the login nowhere.

### On the Mac

1. WezTerm include `~/.config/wezterm/wezterm-agent-host.lua` (repo `config/wezterm-agent-host.lua.in`, rendered
   by `install-mac.sh` and required from the main config):
   ```lua
   config.ssh_domains = {
     { name = "<host>", remote_address = "<host>", username = "<user>", multiplexing = "None" },
   }
   config.term = "xterm-256color"
   -- OSC 52 clipboard writes are on by default in WezTerm
   ```
   Cmd+Shift+A is `SpawnCommandInNewTab { domain = { DomainName = "<host>" } }`; the include sets `color_scheme`
   (Tokyo Night) unless the main config set one first.
2. Optional: `brew install tmux` only for the same copy-mode locally; not required.

### Test the host alone

```
bash tests/agent-test.sh              # bin/agent and the login fragment, own tmux socket and HOME; N passed, 0 failed
command -v agent fzf                  # ~/.local/bin/agent, then an fzf path
agent ls                              # a header and one row per base session; views are not listed
tmux -f ~/.tmux.conf new -d -s t && tmux show -s set-clipboard && tmux show -g allow-passthrough && tmux kill-session -t t
tmux show -g update-environment | grep SSH_CONNECTION
bash -lc 'echo $TMUX'                 # empty: non-interactive login must not auto-attach
getent passwd <user> | cut -d: -f7       # /usr/bin/zsh after phase 1
zsh -c 'command -v mise; [ -n "$ANTHROPIC_API_KEY" ] && echo secrets-ok'   # non-interactive zsh: PATH and secrets via ~/.zshenv
zsh -lc 'echo $TMUX'                  # empty, same rule as bash
NO_TMUX=1 zsh -ic 'echo $ZSH_THEME; type omz'   # robbyrussell, omz is a shell function
script -qc 'printf "\e]52;c;%s\a" "$(printf ok | base64)"' /dev/null | od -c | head -2   # tmux/terminal passthrough emits the sequence unchanged
```

### Test the Mac alone

In a local WezTerm tab:

```
printf '\e]52;c;%s\a' "$(printf hello-osc52 | base64)"; pbpaste   # prints hello-osc52 → WezTerm honours OSC 52
wezterm ssh --help >/dev/null && echo ok
```

### Joint checkpoint

From the Mac `ssh <host>` lands in the picker. Open a second Mac terminal, `ssh <host>`, pick the same session: both
see the harness, each has its own view, and changing window on one does not move the other. Detaching one leaves the
harness and the other view alone. Enter tmux copy-mode, select text, press `y` or Enter, then `pbpaste` on the Mac
shows it. Select text with the mouse in a Claude Code session on <host> and Cmd+C in WezTerm; paste back with Cmd+V.
Text works both ways with no bridge involved.

## 4. Phase 3: toolchains, harnesses, secrets

### On the host

1. Toolchains: `curl https://mise.run | sh`, then `mise use -g node@lts bun@latest python@3.12`.
   `curl -LsSf https://astral.sh/uv/install.sh | sh`. `gh` from apt (phase 1), then `gh auth login` with a
   fine-grained token scoped to the repos the agents may touch.
2. Harnesses, each installed only when absent:

   | Harness | Install | Check |
   |---|---|---|
   | Claude Code | native installer `curl -fsSL https://claude.ai/install.sh \| bash` (to `~/.local/bin`) | `claude doctor` |
   | OpenCode | `curl -fsSL https://opencode.ai/install \| bash` (to `~/.opencode/bin`) | `opencode --version` |
   | Oh My Pi | `npm i -g @oh-my-pi/pi-coding-agent` under mise's Node | `omp --version` |
   | Codex | `npm i -g @openai/codex` under mise's Node | `codex --version`; `codex login status` |

3. Secrets file `~/.config/agents/env`, mode 600, owner <user>:
   ```
   ANTHROPIC_API_KEY=...
   OPENAI_API_KEY=...
   OPENROUTER_API_KEY=...
   GH_TOKEN=...
   ```
   `bashrc.d/agents-env.sh` sources it with `set -a; . ~/.config/agents/env; set +a`. systemd units use
   `EnvironmentFile=%h/.config/agents/env`. The repo carries `secrets.env.example` with names only and
   `.gitignore` excludes `env`.
4. Shared agent context: `config/workspace/CLAUDE.md` (house rules: branch naming `agent/<slug>`, commit style,
   never force-push, never touch `~/.config/agents`) linked as `~/workspace/CLAUDE.md` and `~/workspace/AGENTS.md`.
   Codex reads instructions from the git root down and never above it, so the same file is linked to
   `~/.codex/AGENTS.md` as well, and `~/.codex/config.toml` carries a marker block that raises
   `project_doc_max_bytes` to 128 KiB, because the 32 KiB default cuts the combined house rules and repo
   `AGENTS.md` short. The block sits at the top of the file so the key stays top-level ahead of the tables Codex
   writes itself (trusted projects). `docs/agents-md-two-layer-plan.md` describes moving the other three harnesses
   onto global files the same way. Claude Code user settings `~/.claude/settings.json` → symlink to
   `config/claude-settings.json` (allow and deny lists, model, status line); `~/.claude/statusline-command.sh` →
   symlink to `config/statusline-command.sh`.

### On the Mac

Nothing required. Optional: `brew install gh` to review PRs the agents open.

### Test the host alone

```
mise doctor; node -v; bun -v; python3.12 --version; uv --version; gh auth status
stat -c '%a %U' ~/.config/agents/env          # 600 <user>
claude --bare -p 'reply with the single word ok'      # uses ANTHROPIC_API_KEY only, no OAuth
opencode run 'reply with the single word ok'
codex login status && codex exec 'reply with the single word ok'   # ChatGPT device login or OPENAI_API_KEY via codex login --with-api-key
omp --help                                     # then one trivial prompt with the flags it documents
git -C ~/workspace/agentic-framework check-ignore -q env && echo 'env ignored'
```

### Test the Mac alone

Nothing beyond `gh auth status` if installed.

### Joint checkpoint

From the Mac, `ssh <host> 'claude --bare -p "reply ok"'` returns text. This proves the env file is loaded for
non-interactive SSH commands, which phase 5 depends on.

## 5. Phase 4: clipboard bridge for images

Problem: a headless box has no clipboard, so pasting a screenshot into a harness on <host> finds nothing. A terminal
carries text only, so the image has to travel separately.

Design: push, not pull. Cmd+V in WezTerm runs `clip-push --if-image` on the Mac. Text is not pushed at all; WezTerm
pastes it natively. An image is piped as PNG over the existing Mac → <host> SSH path into `clip-put` on <host>,
which stores it as `~/.clip/<UTC stamp>-<random>.png`, points `~/.clip/latest` at it and prints the path. WezTerm
then pastes that path into the pane: Claude Code, Oh My Pi and OpenCode all attach a pasted absolute path to a
`.png` as an image, so one key works in every harness and a shell simply receives the path. Claude Code also reads
the clipboard itself on Ctrl+V by shelling out to `xclip`; a shim named `xclip` earlier in `PATH` serves
`~/.clip/latest` to it and carries copies back over OSC 52. A pull design, with <host> connecting back into the
Mac, is rejected: a managed Mac should not run an SSH server for this, and a pull exposes the whole clipboard on
demand while a push moves only what is deliberately pasted.

### On the host

1. `bin/xclip` (installed to `~/.local/bin/xclip`, ahead of `/usr/bin` in PATH; do **not** `apt install xclip`):

   | Call Claude Code makes | Shim action |
   |---|---|
   | `xclip -selection clipboard -t TARGETS -o` | `image/png` if `~/.clip/latest` starts with the PNG magic, else `text/plain UTF8_STRING` |
   | `xclip -selection clipboard -t image/png -o` | the file, raw PNG; exit 1 if it is not a PNG |
   | `xclip -selection clipboard -t text/plain -o` (or `-o` alone) | the file; exit 1 if it is a PNG |
   | `xclip -selection clipboard` / `-selection primary` with stdin | stdin → the file, plus an OSC 52 write to the terminal so the Mac clipboard follows (tmux `set-clipboard on` forwards it) |

   Missing or empty file, or any other argument pattern: exit 1 so Claude Code falls through to its next option.
   `CLIP_BRIDGE_SPOOL=/path` moves the file (point it at any PNG to test <host> alone); `CLIP_BRIDGE_DEBUG=1`
   traces to stderr.
2. `bin/clip-put` (installed to `~/.local/bin/clip-put`): stdin → `~/.clip`, directory mode 700, file mode 600,
   written through a temp file and `mv` so nothing sees a half-written PNG. A PNG becomes
   `~/.clip/<UTC stamp>-<random>.png`, `latest` is repointed at it as a symlink and the absolute path is printed on
   stdout; text replaces `latest` as a regular file and prints nothing. One file per paste, so a later push cannot
   overwrite an image a harness has attached but not yet sent. Every push deletes `.png` files older than
   `CLIP_KEEP_MINUTES` (default 1440) in that directory; there is no timer, so a file can outlive a quiet weekend.
   `clip-put --clear` removes the lot. The Mac calls it by absolute path, so the minimal PATH of a non-interactive
   SSH command does not matter.
3. Nothing else: no SSH config towards the Macs. `~/.clip` is shared by every Mac that pushes, and the last one to
   push owns `latest`.

### On the Mac

1. `brew install pngpaste` (turns whatever image class the clipboard holds into PNG on stdout).
2. `bin/clip-push-mac.sh.in`, rendered and installed to `~/.local/bin/clip-push`, no sudo.
   `osascript -e 'clipboard info'` decides image or text and the type is printed first; `pngpaste -` or `pbpaste` is
   piped to `ssh <host>-clip '~/.local/bin/clip-put'`, and for an image the host path `clip-put` printed follows on
   a second line. With `--if-image` text is reported but not pushed. WezTerm starts it with a minimal environment,
   so the script sets its own PATH. `CLIP_PUSH_HOST=<host>-lan` when off the tailnet.
3. `Host <host>-clip` in `~/.ssh/config` (repo `config/ssh_config.mac.in`): same key as `<host>`, `BatchMode yes`,
   `ConnectTimeout 3`, `ControlMaster auto` with `ControlPersist 10m` so every push after the first takes
   milliseconds. Separate from `Host <host>` so interactive sessions and mosh keep their own settings.
4. `config/wezterm-agent-host.lua.in` binds Cmd+V: if the pane is the `<host>` SSH domain, or a local pane whose
   foreground process is `ssh` or `mosh-client`, run `clip-push --if-image` synchronously
   (`wezterm.run_child_process`). Type `text/plain`: ordinary `PasteFrom Clipboard`. Type `image/png` and the push
   succeeded: `pane:paste` of the path on line 2, delivered as one bracketed paste, so the harness sees a paste and
   attaches the image. Push failed, or no path came back: a toast shows why and nothing is pasted, so a stale or
   guessed path is never attached. Any other pane gets the ordinary paste. Ctrl+V is left unbound.

### Test the host alone

```
ls -l ~/.local/bin/xclip ~/.local/bin/clip-put && command -v xclip       # shim wins over /usr/bin
CLIP_BRIDGE_SPOOL=/usr/share/pixmaps/debian-logo.png xclip -selection clipboard -t TARGETS -o             # image/png
CLIP_BRIDGE_SPOOL=/usr/share/pixmaps/debian-logo.png xclip -selection clipboard -t image/png -o | file -  # PNG image data
printf plain | clip-put && xclip -selection clipboard -t TARGETS -o && xclip -selection clipboard -o; echo # text/plain UTF8_STRING, plain
clip-put --clear; xclip -selection clipboard -t TARGETS -o; echo "exit $?"                                # exit 1
```
Then start `claude` in tmux with `CLIP_BRIDGE_SPOOL=/usr/share/pixmaps/debian-logo.png` exported, press Ctrl+V: the
prompt shows an attached image. This proves the Claude Code ↔ shim contract without any Mac involvement.

Automated: `tests/e2e/run.sh` runs the rendered WezTerm module under Lua 5.4 in the Mac container, lets its Cmd+V
handler call the real `clip-push` against the host container, and checks the path it pastes back holds the pushed
PNG byte for byte; it also covers text, local-pane, ssh-pane, mosh-pane and failed-push cases, the spool's naming,
modes, prune and `--clear`, the `xclip` calls Claude Code makes on Ctrl+V, OSC 52 copy-back and a second Mac.
`tests/e2e/harness-paste.sh` pastes that path into Claude Code, Oh My Pi and OpenCode in a container of their own
and checks each attaches the image. WezTerm's own runtime and macOS are left to the joint checkpoint.

### Test the Mac alone

After Cmd+Shift+Ctrl+4 (screenshot to clipboard), in a local terminal:

```
clip-push && ssh <host> 'file ~/.clip/latest'                                 # PNG image data
printf plain | pbcopy; clip-push && ssh <host> 'cat ~/.clip/latest'; echo     # plain
time clip-push                                                             # second run well under 1 s (ControlMaster warm)
clip-push --clear && ssh <host> 'ls ~/.clip'                                  # nothing listed
```

### Joint checkpoint

1. Cmd+Shift+A (<host> tab), `claude` in tmux, Cmd+Shift+Ctrl+4, Cmd+V in Claude Code: the image attaches. Ask
   "what is in this image" to confirm it arrived intact.
2. Same from a local WezTerm tab via `ssh <host>`, then via `mosh <host>`: the binding recognises both foreground
   processes.
3. Repeat from a second Mac. Whatever was pushed last is what pastes.
4. Cmd+V of text into a shell on <host> pastes at once and does not touch the spool (`ls -l ~/.clip` on <host> is
   unchanged); Cmd+V in a local shell tab is the plain WezTerm paste.
5. Copy inside Claude Code or tmux copy mode lands on the Mac clipboard via OSC 52 (phase 2).

Fallbacks that always work: `tailscale file cp shot.png <host>:` then `tailscale file get ~/inbox` on <host> and
paste the path into the prompt; or `claude --remote-control` and attach the image from claude.ai in a browser.

## 6. Phase 5: automation

Not built. Open: the notification channel (ntfy assumed) and the first repo and prompt for a scheduled job.

### On the host

1. `bin/agent` CLI, extending the session subcommands phase 2 ships (`new`, `ls`, `attach`, `pick`, `switch`,
   `kill`) rather than replacing them; `agent ls --porcelain` stays the interface:
   - `agent run <repo> "<task>" [--harness claude|codex|opencode|omp] [--interactive] [--budget 5]`
     - `git -C ~/workspace/<repo> worktree add ../<repo>.wt/<slug> -b agent/<slug>`
     - new window `<slug>` in tmux session `agents`
     - headless: `claude -p "<task>" --permission-mode acceptEdits --max-budget-usd <budget> --output-format stream-json | tee ~/agents/logs/<slug>.jsonl`
     - on exit: commit, push, `gh pr create --fill --head agent/<slug>`, print the PR URL to stdout and to
       `~/agents/logs/<slug>.url`
     - `--interactive`: run the harness normally in the window so any device can attach and steer
   - `agent logs <slug> | stop <slug> | clean <slug>`, wrapping tmux and worktree removal.
   - Claude Code's own `--bg`, `claude agents`, `claude attach` are equivalent for Claude only; the wrapper gives
     one interface across the four harnesses.
2. Scheduled jobs: `systemd/agent@.service` template plus per-job timers, e.g. `agent-deps-review.timer`
   (Mon 03:00) → `ExecStart=%h/.local/bin/agent run <repo> --prompt-file %h/agents/prompts/deps-review.md`.
   `EnvironmentFile=%h/.config/agents/env`. Install with `systemctl --user enable --now agent-deps-review.timer`.
3. Git events (GitHub): self-hosted Actions runner on <host> as a systemd service, label `<host>`. Repo workflow
   `.github/workflows/agent.yml` on `issue_comment` starting with `/agent ` and on `pull_request` labelled
   `agent-review`, running `agent run` with the comment body. The runner long-polls GitHub, so no inbound port. A
   dedicated runner user only if repos are untrusted; otherwise run as <user>.
4. Long-running loop: `systemd/agent-worker.service` runs `bin/agent-worker`: watches `~/agents/queue/*.md`, takes
   the oldest, runs `agent run` with the file as prompt and a budget cap, moves it to `done/` or `failed/` with the
   log, posts the summary line to an ntfy topic (or PR comment). `MAX_PARALLEL=2`; RAM is the usual limit.
5. Guardrails in `config/claude-settings.json`: Bash allowlist (`git *`, `npm test`, `uv run *`, …), deny
   `git push --force*`, `rm -rf /*`, anything under `~/.config/agents`; a `PreToolUse` hook that blocks writes
   outside the current worktree. `--dangerously-skip-permissions` only inside the phase 6 sandbox.

### On the Mac

1. Shell alias in `~/.zshrc`: `alias agent='ssh -q <host> agent'` so `agent run <repo> "add tests for X"` works
   from any Mac terminal.
2. Optional: `brew install ntfy` (or the ntfy app on a phone) subscribed to the topic the worker posts to.

### Test the host alone

```
agent run agentic-framework "create docs/hello.md containing the word hello" --budget 1     # returns a PR URL
agent ls; agent logs <slug> | tail; agent clean <slug>
systemd-analyze --user verify ~/.config/systemd/user/agent-*.service
systemctl --user start agent-deps-review.service && journalctl --user -u agent-deps-review -n 20
systemctl --user list-timers | grep agent
cp ~/agents/prompts/smoke.md ~/agents/queue/; sleep 60; ls ~/agents/done                      # worker picked it up
gh api repos/<owner>/<repo>/actions/runners --jq '.runners[].status'                            # online
```

### Test the Mac alone

```
ssh -q <host> true && echo 'non-interactive ssh ok'    # must not land in tmux
type agent                                          # alias resolves
curl -s https://ntfy.sh/<topic>/json?poll=1 | head -1   # if ntfy is used
```

### Joint checkpoint

From the Mac: `agent run <repo> "add a README badge"` prints a PR URL within a few minutes.
`ssh <host> agent attach <slug>` shows the live tmux window. Comment `/agent fix the failing test` on a PR: the
runner picks it up and a new commit appears. A queued file in `~/agents/queue` produces an ntfy push on the phone.

## 7. Phase 6: isolation (optional)

Not built.

### On the host

1. `docker/Dockerfile.agent-sandbox`: Ubuntu LTS + mise toolchains + the four harnesses + gh. Build once, tag
   `agent-sandbox`.
2. `agent run --sandbox`: `docker run --rm -v <worktree>:/work -v ~/.claude:/root/.claude --env-file ~/.config/agents/env --network bridge agent-sandbox claude -p ... --dangerously-skip-permissions`.
   Only sandbox runs may skip permissions.
3. One worktree per concurrent agent; never two agents in one checkout.
4. GitHub token for agents scoped to contents:write and pull_requests:write on named repos only.

### On the Mac

Nothing.

### Test the host alone

```
docker run --rm agent-sandbox claude --version
agent run agentic-framework "touch /etc/should-fail" --sandbox --budget 1   # container exits, host /etc untouched
docker run --rm -v $PWD:/work agent-sandbox sh -c 'touch /work/ok && ls /work/ok'
```

### Joint checkpoint

A sandboxed run from the Mac completes with changes only inside the mounted worktree, verified with `git status` in
the worktree and `ls -la /etc` unchanged on the host.

## 8. Repo layout for agentic-framework

Entries marked (phase 5) or (phase 6) do not exist yet.

```
README.md       runbook: which doc to read, what the two scripts do, verify blocks, joint checkpoints
AGENTS.md       status table, layout, install contract and boundaries for agents editing this repo
bin/            agent (sessions: new/ls/attach/pick/switch/kill; phase 5 adds run/logs/stop/clean),
                xclip (shim), clip-put, clip-push-mac.sh.in (template), agent-worker (phase 5)
config/         tmux.conf, zshenv, zshrc, ssh_config.mac.in, wezterm-agent-host.lua.in,
                claude-settings.json, statusline-command.sh, bashrc.d/{agents-env,mise,tmux-autoattach}.sh,
                workspace/CLAUDE.md (house rules)
lib/            params.sh: .env loading, validation, derivation on the host, template rendering
tests/          params-test.sh (library, templates, install-mac.sh dry run, literal scan)
                agent-test.sh (bin/agent and the login fragment, own tmux socket and HOME)
                e2e/ (containers: both install scripts, the clipboard bridge, the session picker, the harnesses)
systemd/        agent@.service, agent-worker.service, agent-<job>.timer templates (phase 5)
docker/         Dockerfile.agent-sandbox (phase 6)
docs/           this design, session-picker-plan.md, clipboard-paste-path-plan.md, agents-md-two-layer-plan.md,
                runbook.md for phase 5 operations (phase 5)
.env.example    host parameters (AGENT_HOST, address, login, LAN address); copied to .env, gitignored
secrets.env.example  secret variable names only
install-host.sh  idempotent: derives the parameters and writes .env; phase 1 via sudo, one command at a time and
                only where the host differs; symlinks configs, installs bin/, toolchains, harnesses
install-mac.sh  idempotent, no sudo: reads .env (or asks), brew installs, rendered clip-push, ssh config block,
                WezTerm include, key login to the host
```

## Sources

- OpenCode install: https://opencode.ai/docs/
- Oh My Pi: https://github.com/can1357/oh-my-pi , https://www.npmjs.com/package/@oh-my-pi/pi-coding-agent
- Codex: https://github.com/openai/codex , https://developers.openai.com/codex/guides/agents-md (global
  `~/.codex/AGENTS.md`, `project_doc_max_bytes`), https://developers.openai.com/codex/auth (device login, API key)
