#!/usr/bin/env bash
# Idempotent macOS client setup for as1 (phases 1 to 4, including putting the Mac key on as1). Run on the Mac from a
# clone of this repo. No sudo. Asks for kyle's password on as1 once, only when no local key is trusted there.
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

say "Phase 1, continued: key login to as1 (asks for kyle's password on as1 once, only if it has to)"
# Goal: `ssh as1 true` runs with no prompt of any kind. mosh, the clipboard push and every `ssh as1 <cmd>`
# depend on it. Never deletes anything: a stored host key that no longer matches is for a human to judge.
PUB="$HOME/.ssh/id_ed25519.pub"
fail() { printf '\033[1;31m!!  %s\033[0m\n' "$*"; }
key_ok() { ssh -o BatchMode=yes -o ConnectTimeout=5 as1 true 2>/dev/null; }
# probe <key>: can this key alone log in? Host key deliberately ignored and not recorded: authentication only.
probe() {
  ssh -o BatchMode=yes -o ConnectTimeout=5 -o IdentitiesOnly=yes -i "$1" \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR as1 true 2>/dev/null
}
# sshd's reply to a connection that offers no authentication: "Permission denied (publickey,password)" when
# reachable, and the list says whether password login is on. Anything else means as1 did not answer.
auth_reply() {
  ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o PreferredAuthentications=none -o LogLevel=ERROR as1 true 2>&1 || true
}

setup_as1_login() {
  local k trusted= auth reply
  if key_ok; then note "ok   ssh as1 logs in by key"; return 0; fi

  auth=$(auth_reply)
  case "$auth" in
    *"Permission denied"*) ;;
    *) fail "as1 is not reachable over ssh: $auth"
       note "check the Tailscale menu bar icon and that as1 is online, then re-run ./install-mac.sh"; return 1 ;;
  esac

  # Host key. BatchMode refuses an unknown host, so store it now (trust on first use, fingerprint shown for the
  # record). A stored key that no longer matches is never replaced here.
  reply=$(ssh -o BatchMode=yes -o ConnectTimeout=5 -o PreferredAuthentications=none -o LogLevel=ERROR as1 true 2>&1 || true)
  if [[ $reply != *"Permission denied"* ]]; then
    if ssh-keygen -F as1 >/dev/null 2>&1; then
      fail "as1's host key does not match the one stored in ~/.ssh/known_hosts."
      note "if as1 was reinstalled:  ssh-keygen -R as1; ssh-keygen -R 192.168.10.2   then re-run ./install-mac.sh"
      return 1
    fi
    note "first connection: storing as1's host key in ~/.ssh/known_hosts"
    ssh-keyscan -T 5 -t ed25519 as1 2>/dev/null | ssh-keygen -lf - 2>/dev/null | sed 's/^/      /' || true
    ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o PreferredAuthentications=none \
        -o LogLevel=ERROR as1 true 2>/dev/null || true
    if key_ok; then note "ok   ssh as1 logs in by key (as1 already trusted the repo key)"; return 0; fi
  fi

  # A key provisioned before this repo may already be trusted by as1. If so, install the repo key over it, without
  # a password. -f is required: ssh-copy-id first logs in with every explicit identity to skip keys it thinks are
  # already installed, and the -o IdentityFile option makes that probe succeed with the old key, so without -f it
  # skips the new one and reports "All keys were skipped".
  for k in "$HOME"/.ssh/id_*; do
    case "$k" in *.pub|*-cert*|"$HOME/.ssh/id_ed25519") continue ;; esac
    [ -f "$k" ] || continue
    if probe "$k"; then trusted=$k; break; fi
  done
  if [ -n "$trusted" ]; then
    note "as1 trusts ${trusted/#$HOME/~} but not ~/.ssh/id_ed25519; installing the repo key over it (no password)"
    ssh-copy-id -f -i "$PUB" -o IdentityFile="$trusted" as1 >/dev/null 2>&1 || fail "ssh-copy-id via ${trusted/#$HOME/~} failed"
  else
    case "$auth" in
      *password*) ;;
      *) fail "as1 does not trust any local key and has password login off (a key was imported at install)."
         note "either run the root script on as1 (docs/setup-from-scratch.md, part D) and re-run this script, or"
         note "at the as1 console:  mkdir -p -m 700 ~/.ssh && echo '$(cat "$PUB")' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
         return 1 ;;
    esac
    if [ ! -t 0 ]; then
      fail "as1 does not trust ~/.ssh/id_ed25519 and there is no terminal to ask for a password."
      note "run in a terminal:  ssh-copy-id -i ~/.ssh/id_ed25519.pub as1"; return 1
    fi
    note "as1 does not trust ~/.ssh/id_ed25519 yet. Enter kyle's password on as1 when asked; it is needed once."
    ssh-copy-id -i "$PUB" as1 || fail "ssh-copy-id failed (wrong password, or as1 refused)"
  fi

  if key_ok; then note "ok   ssh as1 logs in by key"; return 0; fi
  fail "ssh as1 still prompts. Diagnose with:  ssh -v as1 true"; return 1
}

if setup_as1_login; then
  say "Done. Open a new shell, reload WezTerm (Cmd+Shift+R), then verify with docs/mac-client-setup.md"
else
  say "Done, but ssh as1 is not keyless yet (see above). Fix that, then re-run ./install-mac.sh"
  exit 1
fi
