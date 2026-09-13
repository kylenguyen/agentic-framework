# as1: remote coding-agent host — setup plan

Date: 12 Sep 2026. Host: `as1` (Ubuntu 26.04 LTS, 12 cores, 14 GB RAM, headless, Tailscale `as1.manee-goby.ts.net`, 100.112.145.54).
Clients in scope: macOS only for now — `macbook` (100.93.240.89) and `mini` (100.84.188.45), both on the tailnet, both running WezTerm. Windows (kylepc) and phone are deferred; the design does not block them.

Each phase below has four parts: what to set up on as1, what to set up on the Mac, how to test as1 on its own, how to test the Mac on its own. A final joint checkpoint closes the phase. Replace `<macuser>` with your macOS login name.

## 0. Decisions and assumptions

Decided:

- Terminal over SSH only. No IDE remote, no remote desktop.
- Harnesses: Claude Code (primary), OpenCode, Aider, Oh My Pi. API keys only, no local models.
- Automation: on-demand from other PCs, scheduled runs, git-event triggers, long-running loops.

Assumed (correct me if wrong):

- Tailnet-only access. Nothing exposed to the internet. LAN 192.168.10.0/24 kept as a fallback path for SSH.
- Repos live under `~/workspace/<repo>`. This repo (`agentic-framework`) holds all scripts, configs and docs from this plan.
- Git hosting is GitHub.
- Nothing connects into the Macs. The clipboard bridge is a push from the Mac (Cmd+V in WezTerm) over the same Mac → as1 SSH path; Remote Login on the Macs is not required.
- as1 sshd accepts key or password for `kyle`. Password login exists so a device without a provisioned key can still get in; ufw limits who can even reach port 22 (tailnet and home LAN only), and `AllowUsers` plus `PermitEmptyPasswords no` limit what a guess can hit. Keys stay the default for the Macs and for everything non-interactive (mosh, the clipboard bridge, `ssh as1 agent`).

Verified on as1 while planning:

- tmux 3.6, Docker, Tailscale, OpenSSH 10.2 present and active. ufw installed but state unknown (needs sudo). mosh, mise, gh, Node, xclip absent.
- sshd: `KbdInteractiveAuthentication no` in the main config; `/etc/ssh/sshd_config.d/50-cloud-init.conf` exists and is root-only. Phase 1 sets `PasswordAuthentication yes` explicitly in `10-hardening.conf` so the cloud-init value no longer matters.
- Claude Code 2.1.269 has `--print`, `--output-format stream-json`, `--permission-mode`, `--max-budget-usd`, `--worktree`, `--tmux=classic`, `--bg` / `claude agents|attach|logs`, `--remote-control`.
- Claude Code on Linux reads clipboard images by running `xclip -selection clipboard -t TARGETS -o`, then `xclip -selection clipboard -t image/png -o`, with `wl-paste` as fallback. Text via `xclip -selection clipboard -t text/plain -o`. Copy-out uses `xclip`/`xsel`/`wl-copy` or OSC 52. The clipboard bridge (phase 4) hooks exactly these calls.

## 1. Target architecture

```
  macbook / mini (WezTerm)
        │  ssh / mosh  →        image push on Cmd+V  →
        │        Tailscale only (100.64.0.0/10), LAN fallback for ssh
  ┌─────▼──────────────────────────────────────────────┐
  │ as1                                                │
  │  sshd key or password (kyle only) + mosh-server    │
  │  tmux: one session per repo, "agents" for jobs     │
  │  harnesses: claude, opencode, aider, omp           │
  │  clipboard: Mac push → clip-put spool → xclip shim │
  │  automation: agent CLI, systemd timers,            │
  │              GitHub runner, queue worker           │
  │  optional: Docker sandbox per repo                 │
  └─────────────────────┬──────────────────────────────┘
                        │ HTTPS
             Anthropic / OpenAI / other LLM APIs
```

Text copy: remote → Mac via OSC 52 (tmux passes it through, WezTerm writes the Mac clipboard). Mac → remote via ordinary paste.
Image paste: Cmd+V in WezTerm runs `clip-push --if-image` on the Mac, which pipes the image into `clip-put` on as1; WezTerm then sends Ctrl+V, Claude Code calls `xclip` and the shim serves that file.

## 2. Phase 1: access and hardening

### On as1

1. Confirm your key already works from the Mac before changing anything (`ssh as1 true` from the Mac). Keep that session open while editing sshd.
2. Confirm `kyle` has a real password: `passwd -S kyle` must show `P` in the second field. If it shows `NP` or `L`, run `sudo passwd kyle` first. `install-as1-root.sh` refuses to continue otherwise: with no password set, `PermitEmptyPasswords no` would silently refuse every password attempt and the fallback path would not exist.
3. Create `/etc/ssh/sshd_config.d/10-hardening.conf` (kept in this repo at `config/sshd/10-hardening.conf`):
   ```
   PasswordAuthentication yes
   PermitEmptyPasswords no
   MaxAuthTries 4
   KbdInteractiveAuthentication no
   PermitRootLogin no
   AllowUsers kyle
   ClientAliveInterval 30
   ClientAliveCountMax 4
   X11Forwarding no
   ```
   Files in `sshd_config.d` are read in lexical order and the first value wins, so `10-` beats `50-cloud-init.conf`. Check that file anyway: `sudo cat /etc/ssh/sshd_config.d/50-cloud-init.conf`.
   Password login is deliberate (see section 0). The firewall in the next step is what keeps it off the internet; do not enable password login without it.
4. `sudo sshd -t && sudo systemctl reload ssh`.
5. Firewall (`config/ufw.sh`):
   ```
   sudo ufw default deny incoming
   sudo ufw default allow outgoing
   sudo ufw allow in on tailscale0
   sudo ufw allow from 192.168.10.0/24 to any port 22 proto tcp
   sudo ufw enable
   ```
   Docker publishes ports around ufw; do not rely on ufw for containers.
6. `sudo apt install mosh zsh` (UDP 60000–61000 is covered by the tailscale0 allow rule); `chsh -s /usr/bin/zsh kyle`. Shell config is phase 2.
7. `loginctl enable-linger kyle` so user systemd units and tmux survive logout.
8. `sudo tailscale set --auto-update` and confirm unattended-upgrades is enabled: `systemctl status unattended-upgrades`.
9. Optional: `sudo tailscale up --ssh` for identity-based SSH via Tailscale ACLs. Keep OpenSSH as well; mosh and the clipboard push use plain sshd.

### On the Mac

1. `~/.ssh/config` entries (also `config/ssh_config.mac` in this repo):
   ```
   Host as1
     HostName as1
     User kyle
     IdentityFile ~/.ssh/id_ed25519
     ServerAliveInterval 30
     ForwardAgent no
   ```
   `as1` resolves via MagicDNS. Add `Host as1-lan` with `HostName 192.168.10.2` for the LAN fallback.
2. `brew install mosh`.
3. Make sure the Tailscale app is running and set to start at login.

### Test as1 alone

```
sudo sshd -T | grep -iE '^(passwordauthentication|permitemptypasswords|maxauthtries|permitrootlogin|allowusers|kbdinteractive)'
sudo ufw status verbose
sudo ss -lntup | grep -E ':22 |mosh'    # sshd listening; mosh-server appears only when a client connects
loginctl show-user kyle | grep Linger    # Linger=yes
passwd -S kyle                           # field 2 is P
ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no kyle@localhost true   # expect: password prompt, then success
ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no root@localhost true   # expect: Permission denied even with the right password (PermitRootLogin no)
```

### Test the Mac alone

```
ssh -G as1 | grep -E '^(hostname|user|identityfile)'   # config parsed as intended
tailscale status | grep as1                            # or /Applications/Tailscale.app/Contents/MacOS/Tailscale status
dns-sd -G v4 as1.manee-goby.ts.net                     # MagicDNS resolves
mosh --version
```

### Joint checkpoint

From the Mac: `ssh as1 true` succeeds without a prompt (key path); `ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no kyle@as1 true` asks for the password and then succeeds (password path); `mosh as1` connects and survives toggling Wi-Fi off and on; `ssh as1-lan true` works on the home LAN.

## 3. Phase 2: sessions and terminal

### On as1

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
2. Shell profile (`config/bashrc.d/tmux-autoattach.sh`): for interactive SSH logins only, `tmux new -As main`. Guard with `[[ $- == *i* && -n $SSH_TTY && -z $TMUX ]]` so `ssh as1 <command>` and automation never trigger it.
3. Login shell: zsh with oh-my-zsh, so interactive work on as1 gets completion, git prompt and history search without per-device setup. Root script installs `zsh` and runs `chsh` for `kyle`; `install-as1.sh` clones `~/.oh-my-zsh` and symlinks `~/.zshenv` → `config/zshenv` and `~/.zshrc` → `config/zshrc`.
   - `~/.zshenv` sources `bashrc.d/agents-env.sh`, because `ssh as1 <command>` under a zsh login shell runs `zsh -c`, which reads only `.zshenv`. This mirrors the env block at the top of `~/.bashrc`.
   - `~/.zshrc` loads oh-my-zsh (theme `robbyrussell`, plugin `git`, auto-update disabled so an update prompt can never block an unattended tmux window) and then the same `bashrc.d/mise.sh` and `bashrc.d/tmux-autoattach.sh` bash sources. The fragments are written to run under both shells; `mise.sh` selects `mise activate zsh` or `bash` from `$ZSH_VERSION`.
   - bash stays fully configured: `ssh -t as1 'NO_TMUX=1 bash -l'` still works, and scripts keep `#!/usr/bin/env bash`.
   - tmux picks its default shell from `$SHELL` when the server starts, so an existing `main` session keeps bash until `tmux kill-server` or a reboot.
4. Session convention: `tmux new -As <repo>` for interactive work; an `agents` session with one window per unattended job.

### On the Mac

1. WezTerm config `~/.config/wezterm/wezterm.lua` (repo: `config/wezterm-as1.lua`, include it from your main config):
   ```lua
   config.ssh_domains = {
     { name = "as1", remote_address = "as1", username = "kyle", multiplexing = "None" },
   }
   config.term = "xterm-256color"
   -- OSC 52 clipboard writes are on by default in WezTerm
   ```
2. Optional keybinding: `SpawnCommandInNewTab { domain = { DomainName = "as1" } }` so one key opens a tab on as1.
3. Optional: `brew install tmux` only if you want the same copy-mode locally; not required.

### Test as1 alone

```
tmux -f ~/.tmux.conf new -d -s t && tmux show -s set-clipboard && tmux show -g allow-passthrough && tmux kill-session -t t
tmux show -g update-environment | grep SSH_CONNECTION
bash -lc 'echo $TMUX'                 # empty: non-interactive login must not auto-attach
getent passwd kyle | cut -d: -f7       # /usr/bin/zsh after the root script
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

From the Mac `ssh as1` lands in tmux session `main`. Open a second Mac terminal, `ssh as1`, both attached. Enter tmux copy-mode, select text, press `y` or Enter, then `pbpaste` on the Mac shows it. Select text with the mouse in a Claude Code session on as1 and Cmd+C in WezTerm; paste back with Cmd+V. Text works both ways with no bridge involved.

## 4. Phase 3: toolchains, harnesses, secrets

### On as1

1. Toolchains: `curl https://mise.run | sh`, then `mise use -g node@lts bun@latest python@3.12`. `curl -LsSf https://astral.sh/uv/install.sh | sh`. `sudo apt install gh` (or the GitHub apt repo for a newer version), then `gh auth login` with a fine-grained token scoped to the repos the agents may touch.
2. Harnesses:

   | Harness | Install | Check |
   |---|---|---|
   | Claude Code | already installed natively; `claude update` | `claude doctor` |
   | OpenCode | `curl -fsSL https://opencode.ai/install \| bash` (or `npm i -g opencode-ai`) | `opencode --version` |
   | Aider | `uv tool install --force --python python3.12 --with pip aider-chat@latest` | `aider --version` |
   | Oh My Pi | `curl -fsSL https://omp.sh/install \| sh` (or `npm i -g @oh-my-pi/pi-coding-agent`) | binary name per install output, expected `omp` |

3. Secrets file `~/.config/agents/env`, mode 600, owner kyle:
   ```
   ANTHROPIC_API_KEY=...
   OPENAI_API_KEY=...
   OPENROUTER_API_KEY=...
   GH_TOKEN=...
   ```
   Shell profile sources it with `set -a; . ~/.config/agents/env; set +a`. systemd units use `EnvironmentFile=%h/.config/agents/env`. Repo carries `env.example` with names only and `.gitignore` excludes `env`.
4. Shared agent context: `~/workspace/CLAUDE.md` and `~/workspace/AGENTS.md` (house rules: branch naming `agent/<slug>`, commit style, never force-push, never touch `~/.config/agents`). Claude Code user settings `~/.claude/settings.json` → symlink to `config/claude-settings.json` with the Bash allowlist and hooks from phase 5.

### On the Mac

Nothing required. Optional: `brew install gh` so you can review PRs the agents open.

### Test as1 alone

```
mise doctor; node -v; bun -v; python3.12 --version; uv --version; gh auth status
stat -c '%a %U' ~/.config/agents/env          # 600 kyle
claude --bare -p 'reply with the single word ok'      # uses ANTHROPIC_API_KEY only, no OAuth
opencode run 'reply with the single word ok'
aider --yes --no-git --message 'reply with the single word ok'
omp --help                                     # then one trivial prompt with the flags it documents
git -C ~/workspace/agentic-framework check-ignore -q env && echo 'env ignored'
```

### Test the Mac alone

Nothing to test beyond `gh auth status` if installed.

### Joint checkpoint

From the Mac, `ssh as1 'claude --bare -p "reply ok"'` returns text. This proves the env file is loaded for non-interactive SSH commands, which phase 5 depends on.

## 5. Phase 4: clipboard bridge for images

Problem: a headless box has no clipboard, so pasting a screenshot into Claude Code on as1 finds nothing. A terminal carries text only, so the image has to travel separately. Claude Code shells out to `xclip`; a shim named `xclip` earlier in `PATH` serves a file that the Mac pushed a moment earlier.

Design: push, not pull. Cmd+V in WezTerm runs `clip-push --if-image` on the Mac. Text is not pushed at all; WezTerm pastes it natively. An image is piped as PNG over the existing Mac → as1 SSH path into `clip-put` on as1, which writes `~/.clip/latest` atomically. WezTerm then sends Ctrl+V (the key Claude Code reads the clipboard on), Claude Code calls `xclip`, the shim reads the file. The first design had as1 SSH back into the Mac (Remote Login, an sshd drop-in, as1's key in `authorized_keys`); it was dropped because a managed Mac should not run an SSH server for this, and because a pull exposes the whole clipboard on demand while a push moves only what is deliberately pasted.

### On as1

1. `bin/xclip` (installed to `~/.local/bin/xclip`, ahead of `/usr/bin` in PATH; do **not** `apt install xclip`). Behaviour:

   | Call Claude Code makes | Shim action |
   |---|---|
   | `xclip -selection clipboard -t TARGETS -o` | `image/png` if `~/.clip/latest` starts with the PNG magic, else `text/plain UTF8_STRING` |
   | `xclip -selection clipboard -t image/png -o` | the file, raw PNG; exit 1 if it is not a PNG |
   | `xclip -selection clipboard -t text/plain -o` (or `-o` alone) | the file; exit 1 if it is a PNG |
   | `xclip -selection clipboard` / `-selection primary` with stdin | stdin → the file, plus an OSC 52 write to the terminal so the Mac clipboard follows (tmux `set-clipboard on` forwards it) |

   Missing or empty file, or any other argument pattern: exit 1 so Claude Code falls through to its next option.
   `CLIP_BRIDGE_SPOOL=/path` moves the file (point it at any PNG to test as1 alone); `CLIP_BRIDGE_DEBUG=1` traces to stderr.
2. `bin/clip-put` (installed to `~/.local/bin/clip-put`): stdin → `~/.clip/latest`, directory mode 700, file mode 600, written through a temp file and `mv` so the shim never sees a half-written PNG. `clip-put --clear` deletes it. The Mac calls it by absolute path, so the minimal PATH of a non-interactive SSH command does not matter.
3. Nothing else: no `jq`, no `tailscale whois`, no SSH config towards the Macs. The last Mac to push wins, which is what "the Mac I am typing on" means in practice.

### On the Mac

1. `brew install pngpaste` (turns whatever image class the clipboard holds into PNG on stdout).
2. `bin/clip-push-mac.sh` installed to `~/.local/bin/clip-push`, no sudo. `osascript -e 'clipboard info'` decides image or text and the type is printed first; `pngpaste -` or `pbpaste` is piped to `ssh as1-clip '~/.local/bin/clip-put'`. With `--if-image` text is reported but not pushed. WezTerm starts it with a minimal environment, so the script sets its own PATH. `CLIP_PUSH_HOST=as1-lan` when off the tailnet.
3. `Host as1-clip` in `~/.ssh/config` (repo `config/ssh_config.mac`): same key as `as1`, `BatchMode yes`, `ConnectTimeout 3`, `ControlMaster auto` with `ControlPersist 10m` so every push after the first takes milliseconds. Separate from `Host as1` so interactive sessions and mosh keep their own settings.
4. `config/wezterm-as1.lua` binds Cmd+V: if the pane is the `as1` SSH domain, or a local pane whose foreground process is `ssh` or `mosh-client`, run `clip-push --if-image` synchronously (`wezterm.run_child_process`). Type `text/plain`: ordinary `PasteFrom Clipboard`. Type `image/png` and the push succeeded: send Ctrl+V to the pane. Push failed: a toast shows the error and no key is sent, so a stale image is never pasted. Any other pane gets the ordinary paste. Ctrl+V is left unbound.

### Test as1 alone

```
ls -l ~/.local/bin/xclip ~/.local/bin/clip-put && command -v xclip       # shim wins over /usr/bin
CLIP_BRIDGE_SPOOL=/usr/share/pixmaps/debian-logo.png xclip -selection clipboard -t TARGETS -o             # image/png
CLIP_BRIDGE_SPOOL=/usr/share/pixmaps/debian-logo.png xclip -selection clipboard -t image/png -o | file -  # PNG image data
printf plain | clip-put && xclip -selection clipboard -t TARGETS -o && xclip -selection clipboard -o; echo # text/plain UTF8_STRING, plain
clip-put --clear; xclip -selection clipboard -t TARGETS -o; echo "exit $?"                                # exit 1
```
Then start `claude` in tmux with `CLIP_BRIDGE_SPOOL=/usr/share/pixmaps/debian-logo.png` exported, press Ctrl+V: the prompt shows an attached image. This proves the Claude Code ↔ shim contract without any Mac involvement.

### Test the Mac alone

After Cmd+Shift+Ctrl+4 (screenshot to clipboard), in a local terminal:

```
clip-push && ssh as1 'file ~/.clip/latest'                                 # PNG image data
printf plain | pbcopy; clip-push && ssh as1 'cat ~/.clip/latest'; echo     # plain
time clip-push                                                             # second run well under 1 s (ControlMaster warm)
clip-push --clear && ssh as1 'ls ~/.clip'                                  # nothing listed
```

### Joint checkpoint

1. Cmd+Shift+A (as1 tab), `claude` in tmux, Cmd+Shift+Ctrl+4, Cmd+V in Claude Code: the image attaches. Ask "what is in this image" to confirm it arrived intact.
2. Same from a local WezTerm tab via `ssh as1`, then via `mosh as1`: the binding recognises both foreground processes.
3. Repeat from `mini`. Whatever was pushed last is what pastes.
4. Cmd+V of text into a shell on as1 pastes at once and does not touch the spool (`ls -l ~/.clip/latest` on as1 keeps its timestamp); Cmd+V in a local shell tab is the plain WezTerm paste.
5. Copy inside Claude Code or tmux copy mode still lands on the Mac clipboard via OSC 52 (phase 2).

Fallbacks that always work: `tailscale file cp shot.png as1:` then `tailscale file get ~/inbox` on as1 and paste the path into the prompt; or `claude --remote-control` and attach the image from claude.ai in a browser.

## 6. Phase 5: automation

### On as1

1. `bin/agent` CLI (installed to `~/.local/bin/agent`):
   - `agent run <repo> "<task>" [--harness claude|opencode|aider|omp] [--interactive] [--budget 5]`
     - `git -C ~/workspace/<repo> worktree add ../<repo>.wt/<slug> -b agent/<slug>`
     - new window `<slug>` in tmux session `agents`
     - headless: `claude -p "<task>" --permission-mode acceptEdits --max-budget-usd <budget> --output-format stream-json | tee ~/agents/logs/<slug>.jsonl`
     - on exit: commit, push, `gh pr create --fill --head agent/<slug>`, print PR URL to stdout and to `~/agents/logs/<slug>.url`
     - `--interactive`: run the harness normally in the window so any PC can `tmux attach -t agents` and steer
   - `agent ls | attach <slug> | logs <slug> | stop <slug> | clean <slug>` wrap tmux and worktree removal.
   - Claude Code's own `--bg`, `claude agents`, `claude attach` are equivalent for Claude only; the wrapper gives one interface across the four harnesses.
2. Scheduled jobs: `systemd/agent@.service` template plus per-job timers, e.g. `agent-deps-review.timer` (Mon 03:00) → `ExecStart=%h/.local/bin/agent run <repo> --prompt-file %h/agents/prompts/deps-review.md`. `EnvironmentFile=%h/.config/agents/env`. Install with `systemctl --user enable --now agent-deps-review.timer`.
3. Git events (GitHub): self-hosted Actions runner on as1 as a systemd service, label `as1`. Repo workflow `.github/workflows/agent.yml` on `issue_comment` starting with `/agent ` and on `pull_request` labelled `agent-review`, running `agent run` with the comment body. The runner long-polls GitHub, so no inbound port. Use a dedicated runner user only if repos are untrusted; otherwise run as kyle.
4. Long-running loop: `systemd/agent-worker.service` runs `bin/agent-worker`: watches `~/agents/queue/*.md`, takes the oldest, runs `agent run` with the file as prompt and a budget cap, moves it to `done/` or `failed/` with the log, posts the summary line to an ntfy topic (or PR comment). `MAX_PARALLEL=2`; RAM is the limit at 14 GB.
5. Guardrails in `config/claude-settings.json`: Bash allowlist (`git *`, `npm test`, `uv run *`, …), deny `git push --force*`, `rm -rf /*`, anything under `~/.config/agents`; a `PreToolUse` hook that blocks writes outside the current worktree. `--dangerously-skip-permissions` only inside the phase 6 sandbox.

### On the Mac

1. Shell alias in `~/.zshrc`: `alias agent='ssh -q as1 agent'` so `agent run ezbus "add tests for X"` works from any Mac terminal.
2. Optional: `brew install ntfy` (or the ntfy iOS app on the phone) subscribed to the topic the worker posts to.

### Test as1 alone

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
ssh -q as1 true && echo 'non-interactive ssh ok'    # must not land in tmux
type agent                                          # alias resolves
curl -s https://ntfy.sh/<topic>/json?poll=1 | head -1   # if ntfy is used
```

### Joint checkpoint

From the Mac: `agent run ezbus "add a README badge"` prints a PR URL within a few minutes. `ssh as1 agent attach <slug>` shows the live tmux window. Comment `/agent fix the failing test` on a PR: the runner picks it up and a new commit appears. A queued file in `~/agents/queue` produces an ntfy push on the phone.

## 7. Phase 6: isolation (optional)

### On as1

1. `docker/Dockerfile.agent-sandbox`: Ubuntu 26.04 + mise toolchains + the four harnesses + gh. Build once, tag `agent-sandbox`.
2. `agent run --sandbox`: `docker run --rm -v <worktree>:/work -v ~/.claude:/root/.claude --env-file ~/.config/agents/env --network bridge agent-sandbox claude -p ... --dangerously-skip-permissions`. Only sandbox runs may skip permissions.
3. One worktree per concurrent agent; never two agents in one checkout.
4. GitHub token for agents scoped to contents:write and pull_requests:write on named repos only.

### On the Mac

Nothing.

### Test as1 alone

```
docker run --rm agent-sandbox claude --version
agent run agentic-framework "touch /etc/should-fail" --sandbox --budget 1   # container exits, host /etc untouched
docker run --rm -v $PWD:/work agent-sandbox sh -c 'touch /work/ok && ls /work/ok'
```

### Joint checkpoint

A sandboxed run from the Mac completes with changes only inside the mounted worktree, verified with `git status` in the worktree and `ls -la /etc` unchanged on the host.

## 8. Repo layout for agentic-framework

```
bin/            agent, agent-worker, xclip (shim), clip-put, clip-push-mac.sh
config/         tmux.conf, zshenv, zshrc, sshd/10-hardening.conf, ufw.sh, ssh_config.mac,
                wezterm-as1.lua, claude-settings.json, bashrc.d/{agents-env,mise,tmux-autoattach}.sh
systemd/        agent@.service, agent-worker.service, agent-<job>.timer templates
docker/         Dockerfile.agent-sandbox
docs/           this plan, runbook (attach/steer/kill/clean), mac-client-setup.md
env.example     variable names only
install-as1.sh  idempotent: symlinks configs, installs bin/, enables units, prints manual sudo steps
install-mac.sh  idempotent, no sudo: brew installs, clip-push, ssh config block, WezTerm include
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
- Aider install via uv: https://aider.chat/docs/install.html
- Oh My Pi: https://github.com/can1357/oh-my-pi , https://www.npmjs.com/package/@oh-my-pi/pi-coding-agent
