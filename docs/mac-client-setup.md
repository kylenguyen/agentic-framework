# Mac client setup for as1 (phases 1–4)

Companion to `remote-agent-host-plan.md`. Do these steps on `macbook` first, then repeat on `mini`.
Everything here runs in a local terminal on the Mac unless it says "on as1".
`<macuser>` is your macOS login name (`id -un`). Replace `macbook` with `mini` when doing the second Mac.

Prerequisites: Homebrew, the Tailscale app signed in to the same tailnet, WezTerm, and an
`~/.ssh/id_ed25519` key whose public half is already in `~/.ssh/authorized_keys` on as1
(it is; `ssh kyle@as1` already works from macbook).

Fast path: clone this repo on the Mac and run `./install-mac.sh`. It does steps 1.1, 1.2, 2.1, 4.3, 4.4, 4.5
and writes the sshd file from 4.2. Steps 1.3, 2.2 and 4.1 are manual. The rest of this document is the
same work step by step, plus the verification for each phase.

```
git clone git@github.com:kylenguyen/agentic-framework.git ~/workspace/agentic-framework
cd ~/workspace/agentic-framework && ./install-mac.sh
```

## Phase 1: access

### 1.1 SSH client config

Append to `~/.ssh/config` (content also in `config/ssh_config.mac`):

```
Host as1
  HostName as1
  User kyle
  IdentityFile ~/.ssh/id_ed25519
  ServerAliveInterval 30
  ServerAliveCountMax 4
  ForwardAgent no

Host as1-lan
  HostName 192.168.10.2
  User kyle
  IdentityFile ~/.ssh/id_ed25519
  ServerAliveInterval 30
  ForwardAgent no
```

`as1` resolves through MagicDNS (`as1.manee-goby.ts.net`). `as1-lan` is the home-LAN fallback.

### 1.2 mosh

```
brew install mosh
```

### 1.3 Tailscale at login

Tailscale menu bar icon → Preferences → tick "Start Tailscale on login". Leave "Allow incoming connections" on;
the clipboard bridge (phase 4) needs as1 to reach the Mac.

### Verify Phase 1 (Mac alone)

```
ssh -G as1 | grep -E '^(hostname|user|identityfile) '   # hostname as1, user kyle, identityfile ~/.ssh/id_ed25519
/Applications/Tailscale.app/Contents/MacOS/Tailscale status | grep as1   # as1 listed, not offline
dns-sd -G v4 as1.manee-goby.ts.net                        # Ctrl+C after it prints 100.112.145.54
mosh --version | head -1
```

### Joint checkpoint Phase 1 (needs `install-as1-root.sh` done on as1)

```
ssh as1 true && echo key-login-ok
ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no kyle@as1   # expect: Permission denied (publickey)
ssh as1-lan true && echo lan-ok            # only while on the 192.168.10.0/24 LAN
mosh as1                                   # lands in tmux "main"; toggle Wi-Fi off/on, session survives
```

If the password test does not say "Permission denied", the root script on as1 has not run yet.

## Phase 2: terminal

### 2.1 WezTerm include

Copy `config/wezterm-as1.lua` to `~/.config/wezterm/wezterm-as1.lua`, then in `~/.config/wezterm/wezterm.lua`
add this line before `return config`:

```lua
require("wezterm-as1").apply(config)
```

If you do not have a `wezterm.lua` yet, the minimal file is:

```lua
local wezterm = require("wezterm")
local config = wezterm.config_builder()
require("wezterm-as1").apply(config)
return config
```

What it does: registers an SSH domain named `as1` (plain ssh, no WezTerm multiplexing, tmux on as1 does that),
sets `TERM=xterm-256color`, and binds Cmd+Shift+A to open a new tab on as1. OSC 52 clipboard writes are on
by default in WezTerm, so text copied inside tmux on as1 lands on the Mac clipboard without any bridge.

### 2.2 Reload WezTerm

Cmd+Shift+R (ReloadConfiguration) or restart WezTerm. A config error shows in a red banner; fix and reload.

### Verify Phase 2 (Mac alone, in a local WezTerm tab)

```
printf '\e]52;c;%s\a' "$(printf hello-osc52 | base64)"; pbpaste    # prints hello-osc52
wezterm ssh --help >/dev/null && echo ok
wezterm show-keys --lua 2>/dev/null | grep -c as1                   # 1 or more: keybinding registered
```

### Joint checkpoint Phase 2

1. `ssh as1` from WezTerm: you land in tmux session `main` (green status bar at the bottom).
2. Open a second WezTerm tab, `ssh as1` again: both tabs show the same session.
3. In tmux: Ctrl+B `[` to enter copy mode, move, Space to start a selection, Enter to copy. Then in a
   local tab `pbpaste` shows the text.
4. Start `claude` on as1, drag-select some output with the mouse, Cmd+C, then Cmd+V pastes it back.
5. `ssh as1 'echo $TMUX'` prints an empty line: non-interactive commands do not attach to tmux.
6. Cmd+Shift+A opens a new as1 tab directly.

## Phase 3: harnesses

Nothing is required on the Mac. Optional:

```
brew install gh && gh auth login     # review PRs the agents open
```

### Joint checkpoint Phase 3

```
ssh as1 'claude --bare -p "reply with the single word ok"'
```

This proves `~/.config/agents/env` is loaded for non-interactive SSH commands. It needs `ANTHROPIC_API_KEY`
filled in on as1 (`~/.config/agents/env`); until then it fails with an authentication error, which is expected.
`ssh as1 'claude -p "reply ok"'` (without `--bare`) uses the OAuth login already on as1 and should answer now.

## Phase 4: clipboard bridge (image paste into Claude Code on as1)

as1 fetches the Mac clipboard by SSHing back to the Mac and running `clip-client`. Four things must be true:
Remote Login on, sshd restricted to the tailnet, as1's key authorised, `clip-client` and `pngpaste` installed.

### 4.1 Remote Login

System Settings → General → Sharing → Remote Login: on. Click the (i) button and set
"Allow access for: Only these users" → add `<macuser>` only. Leave "Allow full disk access for remote users" off.

Terminal alternative: `sudo systemsetup -setremotelogin on`.

### 4.2 Restrict sshd to key-only and the tailnet

```
sudo tee /etc/ssh/sshd_config.d/100-tailnet.conf >/dev/null <<'CONF'
PasswordAuthentication no
KbdInteractiveAuthentication no
AllowUsers <macuser>@100.64.0.0/10 <macuser>@192.168.10.0/24
CONF
sudo sshd -t && sudo launchctl kickstart -k system/com.openssh.sshd
```

macOS 13 and later already have `Include /etc/ssh/sshd_config.d/*` in `/etc/ssh/sshd_config`; check with
`grep Include /etc/ssh/sshd_config`. Replace `<macuser>` literally, e.g. `AllowUsers alice@100.64.0.0/10 alice@192.168.10.0/24`.

### 4.3 Authorise as1's key

```
ssh as1 cat .ssh/id_ed25519.pub >> ~/.ssh/authorized_keys
chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys
```

The same key is in `config/as1.pub` in this repo if as1 is unreachable.

### 4.4 pngpaste

```
brew install pngpaste
```

### 4.5 clip-client

```
sudo install -m 755 bin/clip-client-mac.sh /usr/local/bin/clip-client
```

It must live in `/usr/local/bin` because non-interactive SSH sessions get a minimal PATH. The script itself
adds `/opt/homebrew/bin` so it can find `pngpaste`.

### 4.6 Application firewall

If System Settings → Network → Firewall is on: it prompts the first time sshd receives a connection, allow it.
Or add it up front: `sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add /usr/libexec/sshd-keygen-wrapper`.
Network scoping is done by the `AllowUsers` line, not by the firewall.

### Verify Phase 4 (Mac alone)

Take a screenshot to the clipboard with Cmd+Shift+Ctrl+4, then:

```
clip-client targets            # image/png
clip-client image | file -     # PNG image data
printf plain | pbcopy; clip-client targets; clip-client text; echo     # text/plain UTF8_STRING, then "plain"
ssh -o BatchMode=yes <macuser>@localhost clip-client targets   # exercises the non-interactive PATH and sshd
sudo sshd -T | grep -iE '^(passwordauthentication|allowusers)'   # no, and your AllowUsers line
sudo systemsetup -getremotelogin                                 # Remote Login: On
```

The `localhost` test will be refused by `AllowUsers` if you connect from 127.0.0.1, because only tailnet and LAN
sources are allowed. That refusal is itself a correct result; use your tailnet IP instead:
`ssh -o BatchMode=yes <macuser>@100.93.240.89 clip-client targets` (mini: `100.84.188.45`).

### Joint checkpoint Phase 4

1. On as1 (`ssh as1`): `time ssh macbook clip-client text` returns the Mac clipboard in under a second;
   run it twice, the second is faster (ControlMaster keeps the connection warm for 10 minutes).
   First run may print a "Permanently added" host-key line; that is `StrictHostKeyChecking accept-new`.
2. From WezTerm on the Mac: `ssh as1`, in tmux run `claude`. Cmd+Shift+Ctrl+4, select an area, then in
   Claude Code press Ctrl+V. The prompt shows `[Image #1]`. Ask "what is in this image".
3. Repeat step 2 from `mini`. The shim follows the most recent attacher (tmux refreshes `SSH_CONNECTION`
   on each attach).
4. Repeat step 2 over `mosh as1`. If the paste finds nothing, run `echo $SSH_CONNECTION` on as1: mosh may not
   set it. Workaround in that shell: `export CLIP_BRIDGE_HOST=macbook`, then start `claude`. Note the result
   in the runbook.
5. Debugging on as1: `CLIP_BRIDGE_DEBUG=1 xclip -selection clipboard -t TARGETS -o` prints the discovered IP
   and host, then the ssh result.

Fallbacks that always work: `tailscale file cp shot.png as1:` on the Mac, then `tailscale file get ~/inbox`
on as1 and give Claude Code the path; or `claude --remote-control` and attach the image from claude.ai.

## Redo on mini

Same steps. In 4.2 use mini's own `<macuser>`. In the checkpoints, `tailscale whois --json 100.84.188.45`
on as1 must return `mini`, and as1's `~/.ssh/config` block `Host macbook mini ...` already covers it;
if mini's login name differs from macbook's, add a `Host mini` block with its own `User` above the shared block.

## Rollback

- Remove the bridge: on the Mac `sudo systemsetup -setremotelogin off`, delete
  `/etc/ssh/sshd_config.d/100-tailnet.conf`, remove the `kyle@as1` line from `~/.ssh/authorized_keys`.
- Remove the WezTerm include: delete the `require("wezterm-as1")` line.
- Remove the ssh config: delete the `Host as1` and `Host as1-lan` blocks (between the `agentic-framework:as1` markers
  if `install-mac.sh` added them).
