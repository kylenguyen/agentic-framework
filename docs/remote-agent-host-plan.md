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
- Both Macs may run the built-in SSH server (Remote Login) restricted to the tailnet. This is what the clipboard bridge relies on.

Verified on as1 while planning:

- tmux 3.6, Docker, Tailscale, OpenSSH 10.2 present and active. ufw installed but state unknown (needs sudo). mosh, mise, gh, Node, xclip absent.
- sshd: `KbdInteractiveAuthentication no` in the main config; `/etc/ssh/sshd_config.d/50-cloud-init.conf` exists and is root-only, so `PasswordAuthentication` is unconfirmed. Phase 1 test settles it.
- Claude Code 2.1.269 has `--print`, `--output-format stream-json`, `--permission-mode`, `--max-budget-usd`, `--worktree`, `--tmux=classic`, `--bg` / `claude agents|attach|logs`, `--remote-control`.
- Claude Code on Linux reads clipboard images by running `xclip -selection clipboard -t TARGETS -o`, then `xclip -selection clipboard -t image/png -o`, with `wl-paste` as fallback. Text via `xclip -selection clipboard -t text/plain -o`. Copy-out uses `xclip`/`xsel`/`wl-copy` or OSC 52. The clipboard bridge (phase 4) hooks exactly these calls.

## 1. Target architecture

```
  macbook / mini (WezTerm, Remote Login on)
        │  ssh / mosh  →                ← ssh back for clipboard
        │        Tailscale only (100.64.0.0/10), LAN fallback for ssh
  ┌─────▼──────────────────────────────────────────────┐
  │ as1                                                │
  │  sshd key-only + mosh-server                       │
  │  tmux: one session per repo, "agents" for jobs     │
  │  harnesses: claude, opencode, aider, omp           │
  │  clipboard bridge: xclip shim → ssh <mac> pbpaste  │
  │  automation: agent CLI, systemd timers,            │
  │              GitHub runner, queue worker           │
  │  optional: Docker sandbox per repo                 │
  └─────────────────────┬──────────────────────────────┘
                        │ HTTPS
             Anthropic / OpenAI / other LLM APIs
```

Text copy: remote → Mac via OSC 52 (tmux passes it through, WezTerm writes the Mac clipboard). Mac → remote via ordinary paste.
Image paste: Claude Code calls `xclip`; the shim on as1 fetches the PNG from the attached Mac over SSH.

## 2. Phase 1: access and hardening

### On as1

1. Confirm your key already works from the Mac before changing anything (`ssh as1 true` from the Mac). Keep that session open while editing sshd.
2. Create `/etc/ssh/sshd_config.d/10-hardening.conf` (kept in this repo at `config/sshd/10-hardening.conf`):
   ```
   PasswordAuthentication no
   KbdInteractiveAuthentication no
   PermitRootLogin no
   AllowUsers kyle
   ClientAliveInterval 30
   ClientAliveCountMax 4
   X11Forwarding no
   ```
   Files in `sshd_config.d` are read in lexical order and the first value wins, so `10-` beats `50-cloud-init.conf`. Check that file anyway: `sudo cat /etc/ssh/sshd_config.d/50-cloud-init.conf`.
3. `sudo sshd -t && sudo systemctl reload ssh`.
4. Firewall (`config/ufw.sh`):
   ```
   sudo ufw default deny incoming
   sudo ufw default allow outgoing
   sudo ufw allow in on tailscale0
   sudo ufw allow from 192.168.10.0/24 to any port 22 proto tcp
   sudo ufw enable
   ```
   Docker publishes ports around ufw; do not rely on ufw for containers.
5. `sudo apt install mosh` (UDP 60000–61000 is covered by the tailscale0 allow rule).
6. `loginctl enable-linger kyle` so user systemd units and tmux survive logout.
7. `sudo tailscale set --auto-update` and confirm unattended-upgrades is enabled: `systemctl status unattended-upgrades`.
8. Optional: `sudo tailscale up --ssh` for identity-based SSH via Tailscale ACLs. Keep OpenSSH as well; mosh and the clipboard bridge use plain sshd.

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
sudo sshd -T | grep -iE '^(passwordauthentication|permitrootlogin|allowusers|kbdinteractive)'
sudo ufw status verbose
sudo ss -lntup | grep -E ':22 |mosh'    # sshd listening; mosh-server appears only when a client connects
loginctl show-user kyle | grep Linger    # Linger=yes
ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no kyle@localhost   # expect: Permission denied
```

### Test the Mac alone

```
ssh -G as1 | grep -E '^(hostname|user|identityfile)'   # config parsed as intended
tailscale status | grep as1                            # or /Applications/Tailscale.app/Contents/MacOS/Tailscale status
dns-sd -G v4 as1.manee-goby.ts.net                     # MagicDNS resolves
mosh --version
```

### Joint checkpoint

From the Mac: `ssh as1 true` succeeds; `ssh -o PreferredAuthentications=password kyle@as1` is refused; `mosh as1` connects and survives toggling Wi-Fi off and on; `ssh as1-lan true` works on the home LAN.

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
3. Session convention: `tmux new -As <repo>` for interactive work; an `agents` session with one window per unattended job.

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

Problem: a headless box has no clipboard, so Ctrl+V of a screenshot in Claude Code on as1 finds nothing. Claude Code shells out to `xclip`; a shim named `xclip` earlier in `PATH` serves the attached Mac's clipboard instead.

### On as1

1. `bin/xclip` (installed to `~/.local/bin/xclip`, which is ahead of `/usr/bin` in PATH; do **not** `apt install xclip`). Behaviour:

   | Call Claude Code makes | Shim action |
   |---|---|
   | `xclip -selection clipboard -t TARGETS -o` | `ssh <mac> clip-client targets` → prints `image/png` when the Mac clipboard holds an image, else `text/plain UTF8_STRING` |
   | `xclip -selection clipboard -t image/png -o` | `ssh <mac> clip-client image` → raw PNG on stdout |
   | `xclip -selection clipboard -t text/plain -o` (or `-o` alone) | `ssh <mac> clip-client text` |
   | `xclip -selection clipboard` / `-selection primary` with stdin | `ssh <mac> clip-client copy` (stdin → pbcopy) |

   Any other argument pattern: exit 1 so Claude Code falls through to its next option.
2. Client discovery inside the shim:
   - `ip=$(tmux show-environment SSH_CONNECTION 2>/dev/null || echo "$SSH_CONNECTION")`, take the first field. tmux refreshes SSH_CONNECTION on every attach, so the most recent attacher wins.
   - `host=$(tailscale whois --json "$ip" | jq -r '.Node.ComputedName')`.
   - `CLIP_BRIDGE_HOST` env var overrides discovery; `CLIP_BRIDGE_FAKE=/path/to.png` makes the shim serve a local file, used for testing as1 alone.
3. SSH from as1 to the Macs: `~/.ssh/config` on as1 (repo `config/ssh_config.as1`):
   ```
   Host macbook mini
     User <macuser>
     IdentityFile ~/.ssh/id_ed25519
     BatchMode yes
     ConnectTimeout 3
     StrictHostKeyChecking accept-new
   ```
   The shim must finish in about 2 s; Claude Code's clipboard calls have short timeouts. `ControlMaster auto` with `ControlPersist 10m` in the same block keeps a warm connection so later calls take milliseconds.
4. `sudo apt install jq`.

### On the Mac

1. Remote Login: System Settings → General → Sharing → Remote Login, on, "Allow access for: only these users: <macuser>". Or `sudo systemsetup -setremotelogin on`.
2. Restrict sshd to the tailnet: in `/etc/ssh/sshd_config.d/100-tailnet.conf`
   ```
   PasswordAuthentication no
   KbdInteractiveAuthentication no
   AllowUsers <macuser>@100.64.0.0/10 <macuser>@192.168.10.0/24
   ```
   then `sudo launchctl kickstart -k system/com.openssh.sshd`.
3. Append as1's public key (`ssh kyle@as1 cat ~/.ssh/id_ed25519.pub`) to `~/.ssh/authorized_keys` on the Mac, mode 600, `~/.ssh` mode 700.
4. `brew install pngpaste`.
5. `clip-client` script (repo `bin/clip-client-mac.sh`) installed to `/usr/local/bin/clip-client` so it is on the non-interactive SSH PATH:
   ```
   targets: osascript -e 'clipboard info' | grep -q 'PNGf\|TIFF' && echo image/png || echo 'text/plain UTF8_STRING'
   image:   pngpaste -
   text:    pbpaste
   copy:    pbcopy
   ```
   Non-interactive SSH sessions get a minimal PATH; `/usr/local/bin` and `/opt/homebrew/bin` must be spelled out inside the script.
6. Mac firewall: if the application firewall is on, allow `sshd-keygen-wrapper`; the `AllowUsers` rule above does the network scoping.

### Test as1 alone

```
ls -l ~/.local/bin/xclip && command -v xclip        # shim wins over /usr/bin
CLIP_BRIDGE_FAKE=/usr/share/pixmaps/debian-logo.png xclip -selection clipboard -t TARGETS -o   # image/png
CLIP_BRIDGE_FAKE=/usr/share/pixmaps/debian-logo.png xclip -selection clipboard -t image/png -o | file -   # PNG image data
tailscale whois --json 100.93.240.89 | jq -r .Node.ComputedName    # macbook
```
Then start `claude` in tmux with `CLIP_BRIDGE_FAKE` exported, press Ctrl+V: the prompt shows an attached image. This proves the Claude Code ↔ shim contract without any Mac involvement.

### Test the Mac alone

In a local terminal after Cmd+Shift+Ctrl+4 (screenshot to clipboard):

```
clip-client targets        # image/png
clip-client image | file - # PNG image data
printf plain | pbcopy; clip-client targets; clip-client text
ssh -o BatchMode=yes <macuser>@localhost clip-client targets     # exercises the non-interactive PATH and sshd config
sudo sshd -T | grep -iE '^(passwordauthentication|allowusers)'
```

### Joint checkpoint

1. On as1: `ssh macbook clip-client text` returns the Mac clipboard in under a second; second call is faster (ControlMaster warm).
2. From WezTerm on the Mac, `ssh as1`, in tmux start `claude`. Take a screenshot with Cmd+Shift+Ctrl+4, press Ctrl+V in Claude Code: the image attaches. Ask "what is in this image" to confirm it arrived intact.
3. Attach from `mini` instead; repeat. The shim follows the most recent attacher.
4. Over `mosh as1` repeat step 2. If SSH_CONNECTION is missing under mosh, set `CLIP_BRIDGE_HOST` in that shell; note the result in the runbook.

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
bin/            agent, agent-worker, xclip (shim), clip-client-mac.sh
config/         tmux.conf, sshd/10-hardening.conf, ufw.sh, ssh_config.as1, ssh_config.mac,
                wezterm-as1.lua, claude-settings.json, bashrc.d/tmux-autoattach.sh, bashrc.d/agents-env.sh
systemd/        agent@.service, agent-worker.service, agent-<job>.timer templates
docker/         Dockerfile.agent-sandbox
docs/           this plan, runbook (attach/steer/kill/clean), mac-client-setup.md
env.example     variable names only
install-as1.sh  idempotent: symlinks configs, installs bin/, enables units, prints manual sudo steps
install-mac.sh  idempotent: brew installs, clip-client, ssh config, prints the Remote Login steps
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
- macOS login names on macbook and mini, and whether both Macs get Remote Login or only macbook.
- Notification channel for finished jobs (ntfy assumed).
- First repo and prompt for a scheduled job.
- Claude Code `--remote-control` availability on your plan, only if the phone path matters.

## Sources

- OpenCode install: https://opencode.ai/docs/
- Aider install via uv: https://aider.chat/docs/install.html
- Oh My Pi: https://github.com/can1357/oh-my-pi , https://www.npmjs.com/package/@oh-my-pi/pi-coding-agent
