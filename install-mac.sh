#!/usr/bin/env bash
# Idempotent macOS client setup for as1 (phases 1-4). Run on the Mac from a clone of this repo.
# Usage: ./install-mac.sh          (prompts for sudo twice: clip-client install, sshd tailnet config)
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MACUSER=$(id -un)
say()  { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }

say "Phase 1: brew packages, ssh config"
command -v brew >/dev/null || { echo "Homebrew missing: https://brew.sh"; exit 1; }
brew list mosh >/dev/null 2>&1 || brew install mosh
brew list pngpaste >/dev/null 2>&1 || brew install pngpaste
brew list gh >/dev/null 2>&1 || note "optional: brew install gh"
install -d -m 700 "$HOME/.ssh"; touch "$HOME/.ssh/config"; chmod 600 "$HOME/.ssh/config"
if grep -q '^Host as1$' "$HOME/.ssh/config"; then note "ok   ~/.ssh/config already has Host as1"
else { printf '\n# >>> agentic-framework:as1 >>>\n'; grep -v '^#' "$REPO/config/ssh_config.mac"; printf '# <<< agentic-framework:as1 <<<\n'; } >> "$HOME/.ssh/config"; note "added Host as1 / as1-lan"; fi
[ -f "$HOME/.ssh/id_ed25519" ] || { note "no ~/.ssh/id_ed25519; generating"; ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N '' -C "$MACUSER@$(hostname -s)"; }

say "Phase 2: WezTerm"
install -d "$HOME/.config/wezterm"
cp "$REPO/config/wezterm-as1.lua" "$HOME/.config/wezterm/wezterm-as1.lua"
if [ -f "$HOME/.config/wezterm/wezterm.lua" ] && grep -q 'wezterm-as1' "$HOME/.config/wezterm/wezterm.lua"; then note "ok   wezterm.lua includes wezterm-as1"
else note 'ADD to ~/.config/wezterm/wezterm.lua before `return config`:  require("wezterm-as1").apply(config)'; fi

say "Phase 4: clipboard bridge (clip-client, as1 key, sshd tailnet-only)"
sudo install -m 755 "$REPO/bin/clip-client-mac.sh" /usr/local/bin/clip-client
touch "$HOME/.ssh/authorized_keys"; chmod 600 "$HOME/.ssh/authorized_keys"
AS1_PUB=$(ssh -o BatchMode=yes -o ConnectTimeout=5 as1 cat .ssh/id_ed25519.pub 2>/dev/null || cat "$REPO/config/as1.pub")
grep -qF "${AS1_PUB%% *} ${AS1_PUB#* }" "$HOME/.ssh/authorized_keys" || { echo "$AS1_PUB" >> "$HOME/.ssh/authorized_keys"; note "added as1 key to authorized_keys"; }
sudo install -d /etc/ssh/sshd_config.d
sudo tee /etc/ssh/sshd_config.d/100-tailnet.conf >/dev/null <<CONF
# as1 clipboard bridge: key-only, tailnet/LAN only. Installed by agentic-framework/install-mac.sh
PasswordAuthentication no
KbdInteractiveAuthentication no
AllowUsers $MACUSER@100.64.0.0/10 $MACUSER@192.168.10.0/24
CONF
sudo sshd -t && note "sshd config valid"
if sudo systemsetup -getremotelogin 2>/dev/null | grep -qi 'on'; then
  sudo launchctl kickstart -k system/com.openssh.sshd || true; note "Remote Login on; sshd restarted"
else
  note "Remote Login is OFF. Enable: System Settings > General > Sharing > Remote Login (only $MACUSER)"
  note "   or: sudo systemsetup -setremotelogin on"
fi

say "Done. Verify with docs/mac-client-setup.md"
