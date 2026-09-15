#!/usr/bin/env bash
# Host firewall: tailnet-only inbound, LAN fallback for SSH. Run as root, by install-host.sh (phase 1) or by hand to
# re-apply rules. The LAN range is an argument, never a literal here: install-host.sh derives it from the default
# route or takes AGENT_HOST_LAN_CIDR from .env (lib/params.sh).
# Usage: ufw.sh [--dry-run] <lan-cidr>        e.g. sudo bash config/ufw.sh 192.168.1.0/24 (the range install-host.sh printed)
#   --dry-run   print the ufw commands instead of running them (no root needed)
# Docker publishes ports around ufw; do not rely on ufw for containers.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/params.sh"
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
LAN=${1:-}
[ $# -eq 1 ] && params_is_cidr "$LAN" || { echo "usage: $0 [--dry-run] <lan-cidr>   (e.g. 10.0.0.0/24)" >&2; exit 2; }
run() { if [ "$DRY" = 1 ]; then echo "ufw $*"; else ufw "$@"; fi; }
run default deny incoming
run default allow outgoing
run allow in on tailscale0 comment 'tailnet (ssh, mosh 60000-61000)'
run allow from "$LAN" to any port 22 proto tcp comment 'LAN ssh fallback'
run --force enable
run status verbose
