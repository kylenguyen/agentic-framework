#!/usr/bin/env bash
# Root-level as1 setup (phase 1, plus the phase 2 chsh to zsh). Run: sudo bash install-as1-root.sh
# Keep an existing SSH session open while this runs; it reloads sshd.
# sshd accepts key or password for $USER_NAME; the account must already have a password set.
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
USER_NAME=${SUDO_USER:-kyle}

echo "==> sshd hardening (key or password for $USER_NAME, no root, tailnet/LAN only via ufw)"
# Password login is only useful, and only safe, if the account has a real password. passwd -S prints
# P (set), NP (none) or L (locked) in field 2; refuse to continue on anything but P.
case "$(passwd -S "$USER_NAME" | awk '{print $2}')" in
  P) ;;
  *) echo "$USER_NAME has no usable password; run: passwd $USER_NAME, then re-run this script"; exit 1 ;;
esac
echo "--- current /etc/ssh/sshd_config.d/50-cloud-init.conf:"; cat /etc/ssh/sshd_config.d/50-cloud-init.conf || true
install -m 644 "$REPO/config/sshd/10-hardening.conf" /etc/ssh/sshd_config.d/10-hardening.conf
sshd -t && systemctl reload ssh
sshd -T | grep -iE '^(passwordauthentication|permitemptypasswords|maxauthtries|permitrootlogin|allowusers|kbdinteractiveauthentication|x11forwarding) '

echo "==> packages: tmux mosh gh zsh, plus git curl file jq unattended-upgrades"
# tmux is the whole of phase 2; the rest are what install-as1.sh, the shim tests and the status line call.
apt-get install -y -q tmux mosh gh zsh git curl file jq unattended-upgrades

echo "==> login shell for $USER_NAME: zsh (oh-my-zsh config comes from install-as1.sh)"
# Done here rather than in install-as1.sh because chsh asks the user for a password; root does not.
ZSH_BIN=$(command -v zsh)
if [ "$(getent passwd "$USER_NAME" | cut -d: -f7)" != "$ZSH_BIN" ]; then
  chsh -s "$ZSH_BIN" "$USER_NAME"
fi
getent passwd "$USER_NAME" | cut -d: -f7

echo "==> firewall"
bash "$REPO/config/ufw.sh"

echo "==> linger for $USER_NAME (user systemd units + tmux survive logout)"
loginctl enable-linger "$USER_NAME"
loginctl show-user "$USER_NAME" | grep Linger

echo "==> tailscale auto-update, unattended-upgrades"
if command -v tailscale >/dev/null; then tailscale set --auto-update || true
else echo "tailscale not installed: curl -fsSL https://tailscale.com/install.sh | sh && tailscale up  (docs/setup-from-scratch.md, part A)"; fi
systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
systemctl is-active unattended-upgrades || echo "unattended-upgrades is not active; check: systemctl status unattended-upgrades"

echo "==> done. Optional: tailscale up --ssh (Tailscale SSH alongside OpenSSH)."
