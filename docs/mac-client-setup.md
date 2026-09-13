# Mac client setup for as1 (phases 1–4)

Companion to `remote-agent-host-plan.md`. Do these steps on `macbook` first, then repeat on `mini`.
Everything here runs in a local terminal on the Mac unless it says "on as1". Nothing needs sudo.

Prerequisites: Homebrew, the Tailscale app signed in to the same tailnet, WezTerm, and an
`~/.ssh/id_ed25519` key whose public half is in `~/.ssh/authorized_keys` on as1. On a brand-new Mac none
of these exist yet: `setup-from-scratch.md` parts B and C get you to this point (the installer below
generates the key and puts it on as1, asking for kyle's password once), and as1 itself must have been through parts A and D.

Fast path: clone this repo on the Mac and run `./install-mac.sh`. It does steps 1.1, 1.2, 2.1 (including a
minimal `wezterm.lua` when you have none), 4.1 and 4.2, and ends by making `ssh as1` log in by key with no prompt:
host key on first contact, then `ssh-copy-id` with kyle's password once if as1 trusts no local key
(`setup-from-scratch.md`, part C, lists the cases and where it stops on purpose).
Steps 1.3 and 2.2 are manual. The rest of this document is the same work step by step, plus the verification
for each phase.

```
mkdir -p ~/workspace && git clone https://github.com/kylenguyen/agentic-framework.git ~/workspace/agentic-framework
cd ~/workspace/agentic-framework && ./install-mac.sh
```

## Phase 1: access

### 1.1 SSH client config

The installer writes the content of `config/ssh_config.mac` into a marker block in `~/.ssh/config`
(between `# >>> agentic-framework:as1 >>>` and `# <<< agentic-framework:as1 <<<`, replaced in place on re-run).
By hand, append:

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

Host as1-clip
  HostName as1
  User kyle
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
  BatchMode yes
  ConnectTimeout 3
  ControlMaster auto
  ControlPath ~/.ssh/cm-%r@%h:%p
  ControlPersist 10m
  ForwardAgent no
  LogLevel ERROR
```

`as1` resolves through MagicDNS (`as1.manee-goby.ts.net`). `as1-lan` is the home-LAN fallback. `as1-clip` is
the same host with settings for the clipboard push (phase 4): it never prompts, gives up after 3 s, and keeps one
connection warm for 10 minutes so a push takes milliseconds.

### 1.2 mosh

```
brew install mosh
```

### 1.3 Tailscale at login

Tailscale menu bar icon → Preferences → tick "Start Tailscale on login". "Allow incoming connections" can stay
off; nothing on as1 connects into the Mac.

### Verify Phase 1 (Mac alone)

```
ssh -G as1 | grep -E '^(hostname|user|identityfile) '   # hostname as1, user kyle, identityfile ~/.ssh/id_ed25519
ssh -G as1-clip | grep -E '^(batchmode|controlmaster|connecttimeout) '   # yes, auto, 3
/Applications/Tailscale.app/Contents/MacOS/Tailscale status | grep as1   # as1 listed, not offline
dns-sd -G v4 as1.manee-goby.ts.net                        # Ctrl+C after it prints 100.112.145.54
mosh --version | head -1
```

### Joint checkpoint Phase 1 (needs `install-as1-root.sh` done on as1)

```
ssh as1 true && echo key-login-ok
ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no kyle@as1 true && echo password-login-ok   # prompts for kyle's password
ssh as1-lan true && echo lan-ok            # only while on the 192.168.10.0/24 LAN
mosh as1                                   # lands in tmux "main"; toggle Wi-Fi off/on, session survives
```

`ssh as1 true` must not prompt: the Mac's key is the everyday path, and mosh, the clipboard push and `ssh as1 agent` all depend on it. If it asks for a password, as1 does not trust `~/.ssh/id_ed25519`; re-run `./install-mac.sh` in a terminal, which installs the key (over another key of yours that as1 trusts, or with kyle's password once). The password test is the fallback for a device without a provisioned key; if it says "Permission denied (publickey)" the root script on as1 has not run yet.

## Phase 2: terminal

### 2.1 WezTerm include

Copy `config/wezterm-as1.lua` to `~/.config/wezterm/wezterm-as1.lua`, then in `~/.config/wezterm/wezterm.lua`
add this line before `return config`:

```lua
require("wezterm-as1").apply(config)
```

If you do not have a `wezterm.lua` yet, `install-mac.sh` writes this minimal file for you (it never edits an
existing one):

```lua
local wezterm = require("wezterm")
local config = wezterm.config_builder()
require("wezterm-as1").apply(config)
return config
```

What it does: registers an SSH domain named `as1` (plain ssh, no WezTerm multiplexing, tmux on as1 does that),
sets `TERM=xterm-256color`, binds Cmd+Shift+A to open a new tab on as1, and takes over Cmd+V for the clipboard
push described in phase 4 (in every other pane Cmd+V is the ordinary paste). OSC 52 clipboard writes are on by default in WezTerm, so text copied inside tmux on as1
lands on the Mac clipboard without any bridge.

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

The Mac pushes; as1 never connects back. When you press Cmd+V in a pane connected to as1, WezTerm first runs
`clip-push --if-image`. If the clipboard holds text, nothing is pushed and WezTerm pastes it the normal way. If it
holds an image, `clip-push` pipes it as PNG over `ssh as1-clip` into `clip-put` on as1, which stores it as
`~/.clip/latest`; WezTerm then sends Ctrl+V, the key Claude Code reads the clipboard on, Claude Code calls `xclip`,
and the shim on as1 serves that file. No Remote Login, no sshd change, no key from as1, no sudo, and only the
images you deliberately paste leave the Mac.

Panes that get this treatment: as1 SSH domain tabs (Cmd+Shift+A) and local tabs whose foreground process is `ssh`
or `mosh-client`. Everywhere else Cmd+V is the ordinary paste. If an image push fails, WezTerm shows a toast and
does not send Ctrl+V, so Claude Code never pastes a stale image. Ctrl+V itself is not bound: pressing it in Claude
Code reads whatever as1 last received.

### 4.1 pngpaste

```
brew install pngpaste
```

### 4.2 clip-push

```
install -d ~/.local/bin && install -m 755 bin/clip-push-mac.sh ~/.local/bin/clip-push
```

WezTerm starts it with a minimal environment, so the script sets its own PATH (Homebrew for `pngpaste`) and the
Lua config calls it by absolute path. For the commands below, typed in a shell, `~/.local/bin` must be on PATH:
`install-mac.sh` adds a marker block (`agentic-framework:path`) to `~/.zshrc` for that; open a new shell after the
first run. `CLIP_PUSH_HOST=as1-lan clip-push` pushes over the LAN when off the tailnet.

### 4.3 Reload WezTerm

Cmd+Shift+R. The Cmd+V binding is in the same `wezterm-as1.lua` you installed in 2.1.

### Verify Phase 4 (Mac alone; as1 must have run `install-as1.sh`)

Take a screenshot to the clipboard with Cmd+Shift+Ctrl+4, then:

```
clip-push && ssh as1 'file ~/.clip/latest'                    # prints image/png, then: PNG image data
printf plain | pbcopy; clip-push && ssh as1 'cat ~/.clip/latest'; echo   # text/plain, then plain
clip-push --if-image                                          # text/plain, and ~/.clip/latest on as1 is unchanged
time clip-push                                                # well under 1 s on the second run (ControlMaster warm)
ls ~/.ssh/cm-kyle@as1:22                                      # control socket, lives 10 min after the last push
clip-push --clear && ssh as1 'ls ~/.clip'                     # nothing listed
```

### Joint checkpoint Phase 4

1. Cmd+Shift+A (as1 tab), in tmux run `claude`. Cmd+Shift+Ctrl+4, select an area, then in Claude Code press
   Cmd+V. The prompt shows `[Image #1]`. Ask "what is in this image".
2. Same from a local WezTerm tab via `ssh as1`, then via `mosh as1`: the binding recognises both.
3. Repeat step 1 from `mini`. Whatever was pushed last is what pastes.
4. Cmd+V of text into a shell on as1 pastes at once and leaves the spool alone: `ls -l ~/.clip/latest` on as1
   keeps its timestamp. Cmd+V in a local shell tab is the plain WezTerm paste.
5. Debugging: on as1 `CLIP_BRIDGE_DEBUG=1 xclip -selection clipboard -t TARGETS -o` prints the spool path and
   the decision; on the Mac run `clip-push` in a local terminal to see the ssh error the toast summarised.

Hygiene: the last pushed item sits on as1 in `~/.clip/latest` (directory 700, file 600) until the next push.
`clip-push --clear` from the Mac or `clip-put --clear` on as1 deletes it.

Fallbacks that always work: `tailscale file cp shot.png as1:` on the Mac, then `tailscale file get ~/inbox`
on as1 and give Claude Code the path; or `claude --remote-control` and attach the image from claude.ai.

## Redo on mini

Same steps; nothing is per-Mac. In the checkpoints, a push from mini simply replaces what macbook pushed.

## Rollback

- Remove the clipboard push: `rm ~/.local/bin/clip-push`, delete the `Host as1-clip` block from `~/.ssh/config`
  (inside the `agentic-framework:as1` markers), reload WezTerm. On as1: `rm ~/.local/bin/clip-put ~/.local/bin/xclip`
  and `rm -rf ~/.clip`.
- Remove the WezTerm include: delete the `require("wezterm-as1")` line.
- Remove the ssh config: delete the block between the `agentic-framework:as1` markers.
- If the earlier pull design was installed (as1 SSHing into the Mac): `sudo systemsetup -setremotelogin off`,
  `sudo rm /etc/ssh/sshd_config.d/100-tailnet.conf /usr/local/bin/clip-client`, remove the `kyle@as1` line from
  `~/.ssh/authorized_keys`. On as1, `install-as1.sh` removes the old `Host macbook mini` block from `~/.ssh/config`.
