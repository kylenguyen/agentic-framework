#!/usr/bin/env bash
# Idempotent macOS client setup for the agent host, including key login to it. Run on the Mac from a clone of this
# repo. No sudo. Asks for the host password once, only when no local key is trusted there.
# Usage: ./install-mac.sh
# Parameters (lib/params.sh): .env in this checkout names the host (AGENT_HOST, the ssh alias), its address, the login
# and optionally its LAN address. With no .env and a terminal the script asks and writes .env; without a terminal it
# exits 2 before touching anything. The steps shared with install-linux.sh are in lib/client.sh.
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CLIENT_SCRIPT=install-mac.sh
CLIENT_RC=$HOME/.zshrc
KEY_PASTE=Cmd+V
KEY_RELOAD=Cmd+Shift+R
NET_HINT="check the Tailscale menu bar icon"
. "$REPO/lib/params.sh"
. "$REPO/lib/client.sh"

client_params

say "Phase 1: brew packages, ssh config"
command -v brew >/dev/null || { echo "Homebrew missing: https://brew.sh"; exit 1; }
brew list mosh >/dev/null 2>&1 || brew install mosh
brew list pngpaste >/dev/null 2>&1 || brew install pngpaste
brew list gh >/dev/null 2>&1 || note "optional: brew install gh"
# GUI apps are not installed here: a managed Mac may get them from the App Store or an MDM catalogue.
[ -d /Applications/WezTerm.app ] || command -v wezterm >/dev/null || note "WezTerm not found: brew install --cask wezterm"
[ -d /Applications/Tailscale.app ] || note "Tailscale app not found: https://tailscale.com/download/mac (sign in to the tailnet, start at login)"
client_ssh_config

say "Phase 2: WezTerm"
client_wezterm

say "Phase 4: clipboard push (clip-push, run by WezTerm on Cmd+V)"
client_clip_push bin/clip-push-mac.sh.in

client_login
client_finish
