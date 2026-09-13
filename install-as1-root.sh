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

echo "==> packages: mosh gh zsh"
apt-get install -y -q mosh gh zsh

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
tailscale set --auto-update || true
systemctl is-enabled unattended-upgrades && systemctl is-active unattended-upgrades

echo "==> done. Optional: tailscale up --ssh (Tailscale SSH alongside OpenSSH)."
