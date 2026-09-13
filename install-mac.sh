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
install -d -m 700 "$HOME/.ssh"; touch "$HOME/.ssh/config"; chmod 600 "$HOME/.ssh/config"
block "$HOME/.ssh/config" as1 "$(grep -v '^#' "$REPO/config/ssh_config.mac")"
[ -f "$HOME/.ssh/id_ed25519" ] || { note "no ~/.ssh/id_ed25519; generating"; ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N '' -C "$MACUSER@$(hostname -s)"; }

say "Phase 2: WezTerm"
install -d "$HOME/.config/wezterm"
cp "$REPO/config/wezterm-as1.lua" "$HOME/.config/wezterm/wezterm-as1.lua"
if [ -f "$HOME/.config/wezterm/wezterm.lua" ] && grep -q 'wezterm-as1' "$HOME/.config/wezterm/wezterm.lua"; then note "ok   wezterm.lua includes wezterm-as1"
else note 'ADD to ~/.config/wezterm/wezterm.lua before `return config`:  require("wezterm-as1").apply(config)'; fi
note "reload WezTerm (Cmd+Shift+R) so Cmd+V pushes images to as1"

say "Phase 4: clipboard push (clip-push, run by WezTerm on Cmd+V)"
install -d "$HOME/.local/bin"
install -m 755 "$REPO/bin/clip-push-mac.sh" "$HOME/.local/bin/clip-push"
note "installed ~/.local/bin/clip-push"
# The first design had as1 SSH into the Mac. Its leftovers need sudo to remove; point at the doc instead.
for f in /usr/local/bin/clip-client /etc/ssh/sshd_config.d/100-tailnet.conf; do
  if [ -e "$f" ]; then note "old pull-bridge file present: $f (remove per docs/mac-client-setup.md, Rollback)"; fi
done
if grep -qs '@as1$' "$HOME/.ssh/authorized_keys"; then
  note "as1's key is still in ~/.ssh/authorized_keys; it is no longer needed (docs/mac-client-setup.md, Rollback)"
fi

say "Done. Verify with docs/mac-client-setup.md"
