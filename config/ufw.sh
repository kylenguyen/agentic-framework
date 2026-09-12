#!/usr/bin/env bash
# as1 firewall: tailnet-only inbound, LAN fallback for SSH. Run as root (called by install-as1-root.sh).
# Docker publishes ports around ufw; do not rely on ufw for containers.
set -euo pipefail
ufw default deny incoming
ufw default allow outgoing
ufw allow in on tailscale0 comment 'tailnet (ssh, mosh 60000-61000)'
ufw allow from 192.168.10.0/24 to any port 22 proto tcp comment 'LAN ssh fallback'
ufw --force enable
ufw status verbose
