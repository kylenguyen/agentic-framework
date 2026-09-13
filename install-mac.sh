#!/usr/bin/env bash
# Idempotent macOS client setup for as1 (phases 1, 2 and 4). Run on the Mac from a clone of this repo. No sudo.
# Usage: ./install-mac.sh
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MACUSER=$(id -un)
say()  { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }

# block <file> <marker> <content>: append or replace a marked block (same markers as install-as1.sh).
# The content goes through a file, not awk -v: BSD awk on macOS rejects a -v value that contains newlines.
block() {
  local file=$1 marker=$2 content=$3 begin end tmp ctmp
  begin="# >>> agentic-framework:$marker >>>"; end="# <<< agentic-framework:$marker <<<"
  tmp=$(mktemp); ctmp=$(mktemp); printf '%s\n' "$content" > "$ctmp"
  if grep -qF "$begin" "$file" 2>/dev/null; then
    awk -v b="$begin" -v e="$end" -v cf="$ctmp" '
      $0==b {print b; while ((getline l < cf) > 0) print l; close(cf); print e; skip=1; next}
      $0==e {skip=0; next} !skip' "$file" > "$tmp"
    note "upd  $file [$marker]"
  else
    { cat "$file"; printf '\n%s\n' "$begin"; cat "$ctmp"; printf '%s\n' "$end"; } > "$tmp"
    note "add  $file [$marker]"
  fi
  cat "$tmp" > "$file"; rm -f "$tmp" "$ctmp"
}

say "Phase 1: brew packages, ssh config"
command -v brew >/dev/null || { echo "Homebrew missing: https://brew.sh"; exit 1; }
brew list mosh >/dev/null 2>&1 || brew install mosh
brew list pngpaste >/dev/null 2>&1 || brew install pngpaste
brew list gh >/dev/null 2>&1 || note "optional: brew install gh"
# GUI apps are not installed here: a managed Mac may get them from the App Store or an MDM catalogue.
[ -d /Applications/WezTerm.app ] || command -v wezterm >/dev/null || note "WezTerm not found: brew install --cask wezterm"
[ -d /Applications/Tailscale.app ] || note "Tailscale app not found: https://tailscale.com/download/mac (sign in to the tailnet, start at login)"
install -d -m 700 "$HOME/.ssh"; touch "$HOME/.ssh/config"; chmod 600 "$HOME/.ssh/config"
block "$HOME/.ssh/config" as1 "$(grep -v '^#' "$REPO/config/ssh_config.mac")"
[ -f "$HOME/.ssh/id_ed25519" ] || { note "no ~/.ssh/id_ed25519; generating"; ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N '' -C "$MACUSER@$(hostname -s)"; }

say "Phase 2: WezTerm"
install -d "$HOME/.config/wezterm"
cp "$REPO/config/wezterm-as1.lua" "$HOME/.config/wezterm/wezterm-as1.lua"
WEZ="$HOME/.config/wezterm/wezterm.lua"
if [ ! -f "$WEZ" ]; then
  # No config yet: write the minimal one from docs/mac-client-setup.md 2.1. An existing file is the user's; never edit it.
  cat > "$WEZ" <<'EOF'
local wezterm = require("wezterm")
local config = wezterm.config_builder()
require("wezterm-as1").apply(config)
return config
EOF
  note "created $WEZ (minimal, includes wezterm-as1)"
elif grep -q 'wezterm-as1' "$WEZ"; then note "ok   wezterm.lua includes wezterm-as1"
else note 'ADD to ~/.config/wezterm/wezterm.lua before `return config`:  require("wezterm-as1").apply(config)'; fi
note "reload WezTerm (Cmd+Shift+R) so Cmd+V pushes images to as1"

say "Phase 4: clipboard push (clip-push, run by WezTerm on Cmd+V)"
install -d "$HOME/.local/bin"
install -m 755 "$REPO/bin/clip-push-mac.sh" "$HOME/.local/bin/clip-push"
note "installed ~/.local/bin/clip-push"
# A fresh Mac has no ~/.local/bin on PATH. WezTerm calls clip-push by absolute path, but the verify commands in the
# docs, and the phase 5 `agent` alias, are typed in a shell. Same marker mechanism as ~/.ssh/config.
touch "$HOME/.zshrc"
block "$HOME/.zshrc" path 'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac'
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) note "open a new shell so clip-push is on PATH" ;; esac
# The first design had as1 SSH into the Mac. Its leftovers need sudo to remove; point at the doc instead.
for f in /usr/local/bin/clip-client /etc/ssh/sshd_config.d/100-tailnet.conf; do
  if [ -e "$f" ]; then note "old pull-bridge file present: $f (remove per docs/mac-client-setup.md, Rollback)"; fi
done
if grep -qs '@as1$' "$HOME/.ssh/authorized_keys"; then
  note "as1's key is still in ~/.ssh/authorized_keys; it is no longer needed (docs/mac-client-setup.md, Rollback)"
fi

say "Check: does ssh as1 log in by key, with no prompt?"
# Report only; never touch authorized_keys or known_hosts. Prints the one command that fits the situation.
# probe <key>: can this key alone log in? Host key deliberately ignored and not recorded: this checks
# authentication only, so it also works before the first interactive `ssh as1` has stored the host key.
probe() {
  ssh -o BatchMode=yes -o ConnectTimeout=5 -o IdentitiesOnly=yes -i "$1" \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR as1 true 2>/dev/null
}
check_as1_login() {
  local k trusted= reply
  if ssh -o BatchMode=yes -o ConnectTimeout=5 as1 true 2>/dev/null; then
    note "ok   ssh as1 logs in by key"; return
  fi
  reply=$(ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
              -o PreferredAuthentications=none -o LogLevel=ERROR as1 true 2>&1 || true)
  case "$reply" in
    *"Permission denied"*) ;;   # reachable: sshd answered
    *) note "as1 is not reachable over ssh: $reply"; note "check the Tailscale menu bar icon and that as1 is online"; return ;;
  esac
  if probe "$HOME/.ssh/id_ed25519"; then
    note "as1 trusts the repo key; only its host key is missing from ~/.ssh/known_hosts."
    note "  run:  ssh as1      and answer yes once"
    return
  fi
  ssh-keygen -F as1 >/dev/null 2>&1 || note "the first ssh to as1 will ask you to confirm its host key: answer yes"
  # A key provisioned before this repo may already be trusted by as1. If so, install the repo key over it, without a
  # password. -f is required: ssh-copy-id first logs in with every explicit identity to skip keys it thinks are already
  # installed, and the -o IdentityFile option makes that probe succeed with the old key, so without -f it skips the new
  # one and reports "All keys were skipped".
  for k in "$HOME"/.ssh/id_*; do
    case "$k" in *.pub|*-cert*|"$HOME/.ssh/id_ed25519") continue ;; esac
    [ -f "$k" ] || continue
    if probe "$k"; then trusted=$k; break; fi
  done
  if [ -n "$trusted" ]; then
    note "as1 trusts ${trusted/#$HOME/~} but not the repo key ~/.ssh/id_ed25519. Install the repo key over the trusted one (no password):"
    note "  ssh-copy-id -f -i ~/.ssh/id_ed25519.pub -o IdentityFile=${trusted/#$HOME/~} as1"
  else
    note "no local key logs in to as1. Install the repo key with kyle's password (docs/setup-from-scratch.md, part C):"
    note "  ssh-copy-id -i ~/.ssh/id_ed25519.pub as1"
  fi
}
check_as1_login
say "Done. Verify with docs/mac-client-setup.md; first-time order of work in docs/setup-from-scratch.md"
