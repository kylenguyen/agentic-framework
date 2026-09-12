#!/usr/bin/env bash
# Root-level as1 setup (phase 1). Run: sudo bash install-as1-root.sh
# Keep an existing SSH session open while this runs; it reloads sshd.
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
USER_NAME=${SUDO_USER:-kyle}

echo "==> sshd hardening"
echo "--- current /etc/ssh/sshd_config.d/50-cloud-init.conf:"; cat /etc/ssh/sshd_config.d/50-cloud-init.conf || true
install -m 644 "$REPO/config/sshd/10-hardening.conf" /etc/ssh/sshd_config.d/10-hardening.conf
sshd -t && systemctl reload ssh
sshd -T | grep -iE '^(passwordauthentication|permitrootlogin|allowusers|kbdinteractiveauthentication|x11forwarding) '

echo "==> packages: mosh gh"
apt-get install -y -q mosh gh

echo "==> firewall"
bash "$REPO/config/ufw.sh"

echo "==> linger for $USER_NAME (user systemd units + tmux survive logout)"
loginctl enable-linger "$USER_NAME"
loginctl show-user "$USER_NAME" | grep Linger

echo "==> tailscale auto-update, unattended-upgrades"
tailscale set --auto-update || true
systemctl is-enabled unattended-upgrades && systemctl is-active unattended-upgrades

echo "==> done. Optional: tailscale up --ssh (Tailscale SSH alongside OpenSSH)."
