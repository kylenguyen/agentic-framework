# Remote coding-agent host: setup plan

Date: 12 Sep 2026. Target: one headless Ubuntu Server LTS box on a Tailscale tailnet, called `<host>` below, with a single
login `<user>`; several macOS clients, each running WezTerm, reach it over the tailnet with a LAN fallback for SSH. The real
names, addresses and login are parameters (`.env` or the system, see `lib/params.sh` and README "Parameters"); the repo
carries none of them. `<lan-ip>` stands for the host's LAN address. Windows and phone clients
are deferred; the design does not block them.

Each phase below has four parts: what to set up on <host>, what to set up on the Mac, how to test <host> on its own, how to test the Mac on its own. A final joint checkpoint closes the phase. This document explains the design and the per-phase tests; the ordered from-nothing procedure, including the steps before phase 1 (OS install, Tailscale join, key provisioning), is the README.

## 0. Decisions and assumptions

Decided:

- Terminal over SSH only. No IDE remote, no remote desktop.
- Harnesses: Claude Code (primary), OpenCode, Oh My Pi. API keys only, no local models.
- Automation: on-demand from other PCs, scheduled runs, git-event triggers, long-running loops.

Assumed (correct me if wrong):

- Access over the tailnet, with the LAN as a fallback path for SSH. The host runs no firewall of its own and sshd keeps the OS defaults; the router keeps it off the internet.
- Repos live under `~/workspace/<repo>`. This repo (`agentic-framework`) holds all scripts, configs and docs from this plan.
- Git hosting is GitHub.
- Nothing connects into the Macs. The clipboard bridge is a push from the Mac (Cmd+V in WezTerm) over the same Mac → <host> SSH path; Remote Login on the Macs is not required.
- <host> sshd is whatever the Ubuntu installer left (password login on unless a key was imported at install). Keys are the default for the Macs and for everything non-interactive (mosh, the clipboard bridge, `ssh <host> agent`); `install-mac.sh` installs the Mac key over the password path once.

Verified on the reference host while planning:

- tmux 3.6, Docker, Tailscale, OpenSSH 10.2 present and active. ufw installed but state unknown (needs sudo). mosh, mise, gh, Node, xclip absent.
- sshd: `KbdInteractiveAuthentication no` in the main config; `/etc/ssh/sshd_config.d/50-cloud-init.conf` exists and is root-only. Nothing in this repo changes sshd.
- Claude Code 2.1.269 has `--print`, `--output-format stream-json`, `--permission-mode`, `--max-budget-usd`, `--worktree`, `--tmux=classic`, `--bg` / `claude agents|attach|logs`, `--remote-control`.
- Claude Code on Linux reads clipboard images by running `xclip -selection clipboard -t TARGETS -o`, then `xclip -selection clipboard -t image/png -o`, with `wl-paste` as fallback. Text via `xclip -selection clipboard -t text/plain -o`. Copy-out uses `xclip`/`xsel`/`wl-copy` or OSC 52. The clipboard bridge (phase 4) hooks exactly these calls.

## 1. Target architecture

```
  Macs (WezTerm)
        │  ssh / mosh  →        image push on Cmd+V  →
        │        Tailscale (100.64.0.0/10), LAN fallback for ssh
  ┌─────▼──────────────────────────────────────────────┐
  │ <host>                                             │
  │  sshd as installed by Ubuntu + mosh-server        │
  │  tmux: one session per repo, "agents" for jobs     │
  │  harnesses: claude, opencode, omp                  │
  │  clipboard: Mac push → clip-put spool → xclip shim │
  │  automation: agent CLI, systemd timers,            │
  │              GitHub runner, queue worker           │
  │  optional: Docker sandbox per repo                 │
  └─────────────────────┬──────────────────────────────┘
                        │ HTTPS
             Anthropic / OpenAI / other LLM APIs
```

Text copy: remote → Mac via OSC 52 (tmux passes it through, WezTerm writes the Mac clipboard). Mac → remote via ordinary paste.
Image paste: Cmd+V in WezTerm runs `clip-push --if-image` on the Mac, which pipes the image into `clip-put` on <host>; WezTerm then sends Ctrl+V, Claude Code calls `xclip` and the shim serves that file.

## 2. Phase 1: access

### On the host

1. Confirm your key already works from the Mac (`ssh <host> true`), or that password login is on (`sudo sshd -T | grep -i ^passwordauthentication`) so `install-mac.sh` can put the key there. sshd and the firewall are left as the installer set them; nothing in this repo edits `/etc/ssh` or runs ufw.
2. `sudo apt install tmux mosh gh zsh git curl file jq unattended-upgrades` (tmux is not on a stock Ubuntu Server image, so phase 1 of `install-host.sh` owns it); `chsh -s /usr/bin/zsh <user>`. Shell config is phase 2.
3. `loginctl enable-linger <user>` so user systemd units and tmux survive logout.
4. `sudo tailscale set --auto-update` and confirm unattended-upgrades is enabled: `systemctl status unattended-upgrades`.
5. Optional: `sudo tailscale up --ssh` for identity-based SSH via Tailscale ACLs. Keep OpenSSH as well; mosh and the clipboard push use plain sshd.

### On the Mac

1. `~/.ssh/config` entries (also `config/ssh_config.mac` in this repo):
   ```
   Host <host>
     HostName <host>
     User <user>
     IdentityFile ~/.ssh/id_ed25519
     ServerAliveInterval 30
     ForwardAgent no
   ```
   `<host>` resolves via MagicDNS. Add `Host <host>-lan` with `HostName <lan-ip>` for the LAN fallback.
2. `brew install mosh`.
3. Make sure the Tailscale app is running and set to start at login.

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

From the Mac: `ssh <host> true` succeeds without a prompt (key path); `ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no <user>@<host> true` asks for the password and then succeeds (password path); `mosh <host>` connects and survives toggling Wi-Fi off and on; `ssh <host>-lan true` works on the home LAN.

## 3. Phase 2: sessions and terminal

### On the host

1. `~/.tmux.conf` → symlink to `config/tmux.conf`:
   ```
   set -g default-terminal "tmux-256color"
   set -as terminal-features ",xterm-256color:clipboard,wezterm:clipboard"
   set -s set-clipboard on            # pass OSC 52 to the outer terminal
   set -g allow-passthrough on
   set -g mouse on
   set -g history-limit 100000
   set -ga update-environment " SSH_CLIENT SSH_TTY"   # SSH_CONNECTION is already in the default list
   set -g focus-events on
   set -g escape-time 10
   ```
2. Shell profile (`config/bashrc.d/tmux-autoattach.sh`): for interactive SSH logins only, `tmux new -As main`. Guard with `[[ $- == *i* && -n $SSH_TTY && -z $TMUX ]]` so `ssh <host> <command>` and automation never trigger it.
3. Login shell: zsh with oh-my-zsh, so interactive work on <host> gets completion, git prompt and history search without per-device setup. Phase 1 of `install-host.sh` installs `zsh` and runs `chsh` for `<user>` through sudo; phase 2 clones `~/.oh-my-zsh` and symlinks `~/.zshenv` → `config/zshenv` and `~/.zshrc` → `config/zshrc`.
   - `~/.zshenv` sources `bashrc.d/agents-env.sh`, because `ssh <host> <command>` under a zsh login shell runs `zsh -c`, which reads only `.zshenv`. This mirrors the env block at the top of `~/.bashrc`.
   - `~/.zshrc` loads oh-my-zsh (theme `robbyrussell`, plugin `git`, auto-update disabled so an update prompt can never block an unattended tmux window) and then the same `bashrc.d/mise.sh` and `bashrc.d/tmux-autoattach.sh` bash sources. The fragments are written to run under both shells; `mise.sh` selects `mise activate zsh` or `bash` from `$ZSH_VERSION`.
   - bash stays fully configured: `ssh -t <host> 'NO_TMUX=1 bash -l'` still works, and scripts keep `#!/usr/bin/env bash`.
   - tmux picks its default shell from `$SHELL` when the server starts, so an existing `main` session keeps bash until `tmux kill-server` or a reboot.
4. Session convention: `tmux new -As <repo>` for interactive work; an `agents` session with one window per unattended job.

### On the Mac

1. WezTerm config `~/.config/wezterm/wezterm.lua` (repo: `config/wezterm-agent-host.lua.in`, rendered by `install-mac.sh` and included from your main config):
   ```lua
   config.ssh_domains = {
     { name = "<host>", remote_address = "<host>", username = "<user>", multiplexing = "None" },
   }
   config.term = "xterm-256color"
   -- OSC 52 clipboard writes are on by default in WezTerm
   ```
2. Optional keybinding: `SpawnCommandInNewTab { domain = { DomainName = "<host>" } }` so one key opens a tab on <host>.
3. Optional: `brew install tmux` only if you want the same copy-mode locally; not required.

### Test the host alone

```
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

From the Mac `ssh <host>` lands in tmux session `main`. Open a second Mac terminal, `ssh <host>`, both attached. Enter tmux copy-mode, select text, press `y` or Enter, then `pbpaste` on the Mac shows it. Select text with the mouse in a Claude Code session on <host> and Cmd+C in WezTerm; paste back with Cmd+V. Text works both ways with no bridge involved.

## 4. Phase 3: toolchains, harnesses, secrets

### On the host

1. Toolchains: `curl https://mise.run | sh`, then `mise use -g node@lts bun@latest python@3.12`. `curl -LsSf https://astral.sh/uv/install.sh | sh`. `sudo apt install gh` (or the GitHub apt repo for a newer version), then `gh auth login` with a fine-grained token scoped to the repos the agents may touch.
2. Harnesses:

   | Harness | Install | Check |
   |---|---|---|
   | Claude Code | native installer `curl -fsSL https://claude.ai/install.sh \| bash` when absent (to `~/.local/bin`), then `claude update` | `claude doctor` |
   | OpenCode | `curl -fsSL https://opencode.ai/install \| bash` (or `npm i -g opencode-ai`) | `opencode --version` |
   | Oh My Pi | `curl -fsSL https://omp.sh/install \| sh` (or `npm i -g @oh-my-pi/pi-coding-agent`) | binary name per install output, expected `omp` |

3. Secrets file `~/.config/agents/env`, mode 600, owner <user>:
   ```
   ANTHROPIC_API_KEY=...
   OPENAI_API_KEY=...
   OPENROUTER_API_KEY=...
   GH_TOKEN=...
   ```
   Shell profile sources it with `set -a; . ~/.config/agents/env; set +a`. systemd units use `EnvironmentFile=%h/.config/agents/env`. Repo carries `secrets.env.example` with names only and `.gitignore` excludes `env`.
4. Shared agent context: `~/workspace/CLAUDE.md` and `~/workspace/AGENTS.md` (house rules: branch naming `agent/<slug>`, commit style, never force-push, never touch `~/.config/agents`). Claude Code user settings `~/.claude/settings.json` → symlink to `config/claude-settings.json` with the Bash allowlist and hooks from phase 5; its status line command `~/.claude/statusline-command.sh` → symlink to `config/statusline-command.sh`.

### On the Mac

Nothing required. Optional: `brew install gh` so you can review PRs the agents open.

### Test the host alone

```
mise doctor; node -v; bun -v; python3.12 --version; uv --version; gh auth status
stat -c '%a %U' ~/.config/agents/env          # 600 <user>
claude --bare -p 'reply with the single word ok'      # uses ANTHROPIC_API_KEY only, no OAuth
opencode run 'reply with the single word ok'
omp --help                                     # then one trivial prompt with the flags it documents
git -C ~/workspace/agentic-framework check-ignore -q env && echo 'env ignored'
```

### Test the Mac alone

Nothing to test beyond `gh auth status` if installed.

### Joint checkpoint

From the Mac, `ssh <host> 'claude --bare -p "reply ok"'` returns text. This proves the env file is loaded for non-interactive SSH commands, which phase 5 depends on.

## 5. Phase 4: clipboard bridge for images

Problem: a headless box has no clipboard, so pasting a screenshot into Claude Code on <host> finds nothing. A terminal carries text only, so the image has to travel separately. Claude Code shells out to `xclip`; a shim named `xclip` earlier in `PATH` serves a file that the Mac pushed a moment earlier.

Design: push, not pull. Cmd+V in WezTerm runs `clip-push --if-image` on the Mac. Text is not pushed at all; WezTerm pastes it natively. An image is piped as PNG over the existing Mac → <host> SSH path into `clip-put` on <host>, which writes `~/.clip/latest` atomically. WezTerm then sends Ctrl+V (the key Claude Code reads the clipboard on), Claude Code calls `xclip`, the shim reads the file. The first design had <host> SSH back into the Mac (Remote Login, an sshd drop-in, <host>'s key in `authorized_keys`); it was dropped because a managed Mac should not run an SSH server for this, and because a pull exposes the whole clipboard on demand while a push moves only what is deliberately pasted.

### On the host

1. `bin/xclip` (installed to `~/.local/bin/xclip`, ahead of `/usr/bin` in PATH; do **not** `apt install xclip`). Behaviour:

   | Call Claude Code makes | Shim action |
   |---|---|
   | `xclip -selection clipboard -t TARGETS -o` | `image/png` if `~/.clip/latest` starts with the PNG magic, else `text/plain UTF8_STRING` |
   | `xclip -selection clipboard -t image/png -o` | the file, raw PNG; exit 1 if it is not a PNG |
   | `xclip -selection clipboard -t text/plain -o` (or `-o` alone) | the file; exit 1 if it is a PNG |
   | `xclip -selection clipboard` / `-selection primary` with stdin | stdin → the file, plus an OSC 52 write to the terminal so the Mac clipboard follows (tmux `set-clipboard on` forwards it) |

   Missing or empty file, or any other argument pattern: exit 1 so Claude Code falls through to its next option.
   `CLIP_BRIDGE_SPOOL=/path` moves the file (point it at any PNG to test <host> alone); `CLIP_BRIDGE_DEBUG=1` traces to stderr.
2. `bin/clip-put` (installed to `~/.local/bin/clip-put`): stdin → `~/.clip/latest`, directory mode 700, file mode 600, written through a temp file and `mv` so the shim never sees a half-written PNG. `clip-put --clear` deletes it. The Mac calls it by absolute path, so the minimal PATH of a non-interactive SSH command does not matter.
3. Nothing else: no `jq`, no `tailscale whois`, no SSH config towards the Macs. The last Mac to push wins, which is what "the Mac I am typing on" means in practice.

### On the Mac

1. `brew install pngpaste` (turns whatever image class the clipboard holds into PNG on stdout).
2. `bin/clip-push-mac.sh.in`, rendered and installed to `~/.local/bin/clip-push`, no sudo. `osascript -e 'clipboard info'` decides image or text and the type is printed first; `pngpaste -` or `pbpaste` is piped to `ssh <host>-clip '~/.local/bin/clip-put'`. With `--if-image` text is reported but not pushed. WezTerm starts it with a minimal environment, so the script sets its own PATH. `CLIP_PUSH_HOST=<host>-lan` when off the tailnet.
3. `Host <host>-clip` in `~/.ssh/config` (repo `config/ssh_config.mac.in`): same key as `<host>`, `BatchMode yes`, `ConnectTimeout 3`, `ControlMaster auto` with `ControlPersist 10m` so every push after the first takes milliseconds. Separate from `Host <host>` so interactive sessions and mosh keep their own settings.
4. `config/wezterm-agent-host.lua.in` binds Cmd+V: if the pane is the `<host>` SSH domain, or a local pane whose foreground process is `ssh` or `mosh-client`, run `clip-push --if-image` synchronously (`wezterm.run_child_process`). Type `text/plain`: ordinary `PasteFrom Clipboard`. Type `image/png` and the push succeeded: send Ctrl+V to the pane. Push failed: a toast shows the error and no key is sent, so a stale image is never pasted. Any other pane gets the ordinary paste. Ctrl+V is left unbound.

### Test the host alone

```
ls -l ~/.local/bin/xclip ~/.local/bin/clip-put && command -v xclip       # shim wins over /usr/bin
CLIP_BRIDGE_SPOOL=/usr/share/pixmaps/debian-logo.png xclip -selection clipboard -t TARGETS -o             # image/png
CLIP_BRIDGE_SPOOL=/usr/share/pixmaps/debian-logo.png xclip -selection clipboard -t image/png -o | file -  # PNG image data
printf plain | clip-put && xclip -selection clipboard -t TARGETS -o && xclip -selection clipboard -o; echo # text/plain UTF8_STRING, plain
clip-put --clear; xclip -selection clipboard -t TARGETS -o; echo "exit $?"                                # exit 1
```
Then start `claude` in tmux with `CLIP_BRIDGE_SPOOL=/usr/share/pixmaps/debian-logo.png` exported, press Ctrl+V: the prompt shows an attached image. This proves the Claude Code ↔ shim contract without any Mac involvement.

Automated: `tests/e2e/run.sh` runs the rendered WezTerm module under Lua 5.4 in the Mac container, lets its Cmd+V handler call the real `clip-push` against the host container, then makes the `xclip` calls Claude Code makes after Ctrl+V and compares the PNG bytes. Text, local-pane, ssh-pane, mosh-pane and failed-push cases, OSC 52 copy-back and a second Mac are covered there; only WezTerm's own runtime and macOS are left to the joint checkpoint.

### Test the Mac alone

After Cmd+Shift+Ctrl+4 (screenshot to clipboard), in a local terminal:

```
clip-push && ssh <host> 'file ~/.clip/latest'                                 # PNG image data
printf plain | pbcopy; clip-push && ssh <host> 'cat ~/.clip/latest'; echo     # plain
time clip-push                                                             # second run well under 1 s (ControlMaster warm)
clip-push --clear && ssh <host> 'ls ~/.clip'                                  # nothing listed
```

### Joint checkpoint

1. Cmd+Shift+A (<host> tab), `claude` in tmux, Cmd+Shift+Ctrl+4, Cmd+V in Claude Code: the image attaches. Ask "what is in this image" to confirm it arrived intact.
2. Same from a local WezTerm tab via `ssh <host>`, then via `mosh <host>`: the binding recognises both foreground processes.
3. Repeat from a second Mac. Whatever was pushed last is what pastes.
4. Cmd+V of text into a shell on <host> pastes at once and does not touch the spool (`ls -l ~/.clip/latest` on <host> keeps its timestamp); Cmd+V in a local shell tab is the plain WezTerm paste.
5. Copy inside Claude Code or tmux copy mode still lands on the Mac clipboard via OSC 52 (phase 2).

Fallbacks that always work: `tailscale file cp shot.png <host>:` then `tailscale file get ~/inbox` on <host> and paste the path into the prompt; or `claude --remote-control` and attach the image from claude.ai in a browser.

## 6. Phase 5: automation

### On the host

1. `bin/agent` CLI (installed to `~/.local/bin/agent`):
   - `agent run <repo> "<task>" [--harness claude|opencode|omp] [--interactive] [--budget 5]`
     - `git -C ~/workspace/<repo> worktree add ../<repo>.wt/<slug> -b agent/<slug>`
     - new window `<slug>` in tmux session `agents`
     - headless: `claude -p "<task>" --permission-mode acceptEdits --max-budget-usd <budget> --output-format stream-json | tee ~/agents/logs/<slug>.jsonl`
     - on exit: commit, push, `gh pr create --fill --head agent/<slug>`, print PR URL to stdout and to `~/agents/logs/<slug>.url`
     - `--interactive`: run the harness normally in the window so any PC can `tmux attach -t agents` and steer
   - `agent ls | attach <slug> | logs <slug> | stop <slug> | clean <slug>` wrap tmux and worktree removal.
   - Claude Code's own `--bg`, `claude agents`, `claude attach` are equivalent for Claude only; the wrapper gives one interface across the three harnesses.
2. Scheduled jobs: `systemd/agent@.service` template plus per-job timers, e.g. `agent-deps-review.timer` (Mon 03:00) → `ExecStart=%h/.local/bin/agent run <repo> --prompt-file %h/agents/prompts/deps-review.md`. `EnvironmentFile=%h/.config/agents/env`. Install with `systemctl --user enable --now agent-deps-review.timer`.
3. Git events (GitHub): self-hosted Actions runner on <host> as a systemd service, label `<host>`. Repo workflow `.github/workflows/agent.yml` on `issue_comment` starting with `/agent ` and on `pull_request` labelled `agent-review`, running `agent run` with the comment body. The runner long-polls GitHub, so no inbound port. Use a dedicated runner user only if repos are untrusted; otherwise run as <user>.
4. Long-running loop: `systemd/agent-worker.service` runs `bin/agent-worker`: watches `~/agents/queue/*.md`, takes the oldest, runs `agent run` with the file as prompt and a budget cap, moves it to `done/` or `failed/` with the log, posts the summary line to an ntfy topic (or PR comment). `MAX_PARALLEL=2`; RAM is the usual limit.
5. Guardrails in `config/claude-settings.json`: Bash allowlist (`git *`, `npm test`, `uv run *`, …), deny `git push --force*`, `rm -rf /*`, anything under `~/.config/agents`; a `PreToolUse` hook that blocks writes outside the current worktree. `--dangerously-skip-permissions` only inside the phase 6 sandbox.

### On the Mac

1. Shell alias in `~/.zshrc`: `alias agent='ssh -q <host> agent'` so `agent run <repo> "add tests for X"` works from any Mac terminal.
2. Optional: `brew install ntfy` (or the ntfy iOS app on the phone) subscribed to the topic the worker posts to.

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

From the Mac: `agent run <repo> "add a README badge"` prints a PR URL within a few minutes. `ssh <host> agent attach <slug>` shows the live tmux window. Comment `/agent fix the failing test` on a PR: the runner picks it up and a new commit appears. A queued file in `~/agents/queue` produces an ntfy push on the phone.

## 7. Phase 6: isolation (optional)

### On the host

1. `docker/Dockerfile.agent-sandbox`: Ubuntu 26.04 + mise toolchains + the three harnesses + gh. Build once, tag `agent-sandbox`.
2. `agent run --sandbox`: `docker run --rm -v <worktree>:/work -v ~/.claude:/root/.claude --env-file ~/.config/agents/env --network bridge agent-sandbox claude -p ... --dangerously-skip-permissions`. Only sandbox runs may skip permissions.
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

A sandboxed run from the Mac completes with changes only inside the mounted worktree, verified with `git status` in the worktree and `ls -la /etc` unchanged on the host.

## 8. Repo layout for agentic-framework

```
README.md       which doc to read, what the three scripts do
AGENTS.md       status table, layout, install contract and boundaries for agents editing this repo
bin/            agent, agent-worker, xclip (shim), clip-put, clip-push-mac.sh.in (template)
config/         tmux.conf, zshenv, zshrc, ssh_config.mac.in, wezterm-agent-host.lua.in,
                claude-settings.json, statusline-command.sh, bashrc.d/{agents-env,mise,tmux-autoattach}.sh
lib/            params.sh: .env loading, validation, derivation on the host, template rendering
tests/          params-test.sh (library, templates, install-mac.sh dry run, literal scan)
systemd/        agent@.service, agent-worker.service, agent-<job>.timer templates
docker/         Dockerfile.agent-sandbox
docs/           this plan,
                operations runbook for phase 5 (attach/steer/kill/clean, to be written)
.env.example    host parameters (AGENT_HOST, address, login, LAN address); copied to .env, gitignored
secrets.env.example  secret variable names only
install-host.sh  idempotent: derives the parameters and writes .env; phase 1 via sudo, one command at a time and only where the host differs; symlinks configs, installs bin/, toolchains, harnesses
install-mac.sh  idempotent, no sudo: reads .env (or asks), brew installs, rendered clip-push, ssh config block, WezTerm include
```

## 9. Order and time

| Phase | Effort | Blocks |
|---|---|---|
| 1 access | 30 min | everything |
| 2 sessions | 30 min | 4, 5 |
| 3 harnesses | 1 h | 4, 5 |
| 4 clipboard bridge | 2 h | nothing else; can slip |
| 5 automation | 2–3 h | 6 |
| 6 sandbox | 1 h | — |

## 10. Open items

- Git host confirmation (GitHub assumed).
- Notification channel for finished jobs (ntfy assumed).
- First repo and prompt for a scheduled job.
- Claude Code `--remote-control` availability on your plan, only if the phone path matters.

## Sources

- OpenCode install: https://opencode.ai/docs/
- Oh My Pi: https://github.com/can1357/oh-my-pi , https://www.npmjs.com/package/@oh-my-pi/pi-coding-agent
