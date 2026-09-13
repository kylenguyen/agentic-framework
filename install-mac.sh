#!/usr/bin/env bash
# Idempotent macOS client setup for the agent host (phases 1 to 4, including putting the Mac key on the host). Run on
# the Mac from a clone of this repo. No sudo. Asks for the host password once, only when no local key is trusted there.
# Usage: ./install-mac.sh
# Parameters (lib/params.sh): .env in this checkout names the host (AGENT_HOST, the ssh alias), its address, the login
# and, optionally, its LAN address. With no .env and a terminal, the script asks and writes .env; without a terminal
# it exits 2 before touching anything.
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MACUSER=$(id -un)
say()  { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
fail() { printf '\033[1;31m!!  %s\033[0m\n' "$*"; }

. "$REPO/lib/params.sh"
params_load || exit 1
if [ -z "${AGENT_HOST:-}" ] || [ -z "${AGENT_HOST_USER:-}" ]; then
  if [ -f "$REPO/.env" ] || [ ! -t 0 ]; then params_require AGENT_HOST AGENT_HOST_USER || exit 2; fi
  params_prompt || exit 2
  params_env_text install-mac.sh > "$REPO/.env"; note "wrote .env"
fi
: "${AGENT_HOST_ADDRESS:=$AGENT_HOST}"
params_validate || exit 1
H=$AGENT_HOST; ADDR=$AGENT_HOST_ADDRESS; RUSER=$AGENT_HOST_USER; LAN=${AGENT_HOST_LAN_IP:-}
say "Parameters: \`ssh $H\` is $RUSER@$ADDR${LAN:+, \`ssh $H-lan\` is $RUSER@$LAN}"

# block <file> <marker> <content>: append or replace a marked block (same markers as install-as1.sh).
# unblock <file> <marker>: remove a block an earlier version of this script left behind.
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
unblock() {
  local file=$1 marker=$2 begin end tmp
  begin="# >>> agentic-framework:$marker >>>"; end="# <<< agentic-framework:$marker <<<"
  grep -qF "$begin" "$file" 2>/dev/null || return 0
  tmp=$(mktemp)
  awk -v b="$begin" -v e="$end" '$0==b {skip=1; next} $0==e {skip=0; next} !skip' "$file" > "$tmp"
  cat "$tmp" > "$file"; rm -f "$tmp"; note "rm   $file [$marker]"
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
SSH_BLOCK=$(params_ssh_config_text) || { fail "config/ssh_config.mac.in did not render"; exit 1; }
unblock "$HOME/.ssh/config" as1                    # marker name before the block was parameterised
block "$HOME/.ssh/config" agent-host "$SSH_BLOCK"
[ -f "$HOME/.ssh/id_ed25519" ] || { note "no ~/.ssh/id_ed25519; generating"; ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N '' -C "$MACUSER@$(hostname -s)"; }

say "Phase 2: WezTerm"
install -d "$HOME/.config/wezterm"
WEZ_MOD=wezterm-agent-host                       # module name; the file is rendered from config/$WEZ_MOD.lua.in
params_render "$REPO/config/$WEZ_MOD.lua.in" "$HOME/.config/wezterm/$WEZ_MOD.lua" || { fail "config/$WEZ_MOD.lua.in did not render"; exit 1; }
# Before the rename the module was wezterm-as1; the copy is ours to remove and the require line is fixed in wez_include.
[ ! -e "$HOME/.config/wezterm/wezterm-as1.lua" ] || { rm -f "$HOME/.config/wezterm/wezterm-as1.lua"; note "rm   ~/.config/wezterm/wezterm-as1.lua (now $WEZ_MOD.lua)"; }
# The include line must be in the config WezTerm actually loads, or Cmd+V stays a plain paste and images never reach
# the host. WezTerm reads, in order: $WEZTERM_CONFIG_FILE, ~/.config/wezterm/wezterm.lua, ~/.wezterm.lua. Creating the
# second while only the third exists would shadow the user's config, so an existing file wins here too.
# ~/.config/wezterm is on WezTerm's package.path whichever file is loaded, so the require resolves from all three.
if [ -n "${WEZTERM_CONFIG_FILE:-}" ] && [ -f "$WEZTERM_CONFIG_FILE" ]; then WEZ=$WEZTERM_CONFIG_FILE
elif [ -f "$HOME/.config/wezterm/wezterm.lua" ] || [ ! -f "$HOME/.wezterm.lua" ]; then WEZ="$HOME/.config/wezterm/wezterm.lua"
else WEZ="$HOME/.wezterm.lua"; fi
WEZ_OK=1
# wez_include <file>: make sure the config includes $WEZ_MOD. A missing file gets the minimal config from
# README.md, section 2. An existing file is edited in place, once: the require line goes in just before the final
# `return <config>` line, whatever the variable is called, and the original is kept next to it as <file>.before-agent-host.
# A file that still requires the old module name has that one token rewritten, with the same backup.
# A config that ends some other way (returns a table literal, builds the config in another module) cannot be edited
# safely; the line to add is printed instead and the script exits 1 at the end so the gap is not missed.
wez_include() {
  local file=$1 var
  if [ ! -f "$file" ]; then
    cat > "$file" <<'EOF'
local wezterm = require("wezterm")
local config = wezterm.config_builder()
require("wezterm-agent-host").apply(config)
return config
EOF
    note "created ${file/#$HOME/~} (minimal, includes $WEZ_MOD)"; return 0
  fi
  if grep -q "$WEZ_MOD" "$file"; then note "ok   ${file/#$HOME/~} includes $WEZ_MOD"; return 0; fi
  if grep -q 'wezterm-as1' "$file"; then
    [ -e "$file.before-agent-host" ] || cp -p "$file" "$file.before-agent-host"
    local tmp; tmp=$(mktemp); sed 's/wezterm-as1/wezterm-agent-host/g' "$file" > "$tmp"; cat "$tmp" > "$file"; rm -f "$tmp"
    note "upd  ${file/#$HOME/~}: require(\"wezterm-as1\") is now require(\"$WEZ_MOD\") (original: ${file/#$HOME/~}.before-agent-host)"; return 0
  fi
  # Last `return <identifier>` line, ignoring trailing spaces and a trailing comment.
  var=$(awk '{ l=$0; sub(/--.*/, "", l) }
             l ~ /^[[:space:]]*return[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*$/ { v=l; sub(/^[[:space:]]*return[[:space:]]+/, "", v); sub(/[[:space:]]*$/, "", v) }
             END { if (v != "") print v }' "$file")
  if [ -z "$var" ]; then
    fail "${file/#$HOME/~} exists but does not end with \`return <config>\`, so it was left alone."
    note "ADD before the line that returns your config:  require(\"$WEZ_MOD\").apply(<your config variable>)"
    return 1
  fi
  [ -e "$file.before-agent-host" ] || cp -p "$file" "$file.before-agent-host"
  local tmp; tmp=$(mktemp)
  awk -v var="$var" -v mod="$WEZ_MOD" '
    { lines[NR]=$0; l=$0; sub(/--.*/, "", l)
      if (l ~ /^[[:space:]]*return[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*$/) last=NR }
    END { for (i=1; i<=NR; i++) {
            if (i==last) { ind=lines[i]; sub(/[^[:space:]].*$/, "", ind); print ind "require(\"" mod "\").apply(" var ")" }
            print lines[i] } }' "$file" > "$tmp"
  cat "$tmp" > "$file"; rm -f "$tmp"
  note "upd  ${file/#$HOME/~}: added require(\"$WEZ_MOD\").apply($var) before \`return $var\` (original: ${file/#$HOME/~}.before-agent-host)"
}
wez_include "$WEZ" || WEZ_OK=0
note "reload WezTerm (Cmd+Shift+R) so Cmd+V pushes images to $H"

say "Phase 4: clipboard push (clip-push, run by WezTerm on Cmd+V)"
install -d "$HOME/.local/bin"
CLIP_TMP=$(mktemp); params_render "$REPO/bin/clip-push-mac.sh.in" "$CLIP_TMP" || { fail "bin/clip-push-mac.sh.in did not render"; exit 1; }
install -m 755 "$CLIP_TMP" "$HOME/.local/bin/clip-push"; rm -f "$CLIP_TMP"
note "installed ~/.local/bin/clip-push (pushes to $H-clip)"
# A fresh Mac has no ~/.local/bin on PATH. WezTerm calls clip-push by absolute path, but the verify commands in the
# docs, and the phase 5 `agent` alias, are typed in a shell. Same marker mechanism as ~/.ssh/config.
touch "$HOME/.zshrc"
block "$HOME/.zshrc" path 'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac'
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) note "open a new shell so clip-push is on PATH" ;; esac
# The first design had the host SSH into the Mac. Its leftovers need sudo to remove; point at the doc instead.
for f in /usr/local/bin/clip-client /etc/ssh/sshd_config.d/100-tailnet.conf; do
  if [ -e "$f" ]; then note "old pull-bridge file present: $f (remove per README.md, Rollback)"; fi
done
if grep -qs "@$H\$" "$HOME/.ssh/authorized_keys"; then
  note "$H's key is still in ~/.ssh/authorized_keys; it is no longer needed (README.md, Rollback)"
fi

say "Phase 1, continued: key login to $H (asks for $RUSER's password on $H once, only if it has to)"
# Goal: `ssh $H true` runs with no prompt of any kind. mosh, the clipboard push and every `ssh $H <cmd>`
# depend on it. Never deletes anything: a stored host key that no longer matches is for a human to judge.
PUB="$HOME/.ssh/id_ed25519.pub"
key_ok() { ssh -o BatchMode=yes -o ConnectTimeout=5 "$H" true 2>/dev/null; }
# probe <key>: can this key alone log in? Host key deliberately ignored and not recorded: authentication only.
probe() {
  ssh -o BatchMode=yes -o ConnectTimeout=5 -o IdentitiesOnly=yes -i "$1" \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$H" true 2>/dev/null
}
# sshd's reply to a connection that offers no authentication: "Permission denied (publickey,password)" when
# reachable, and the list says whether password login is on. Anything else means the host did not answer.
auth_reply() {
  ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o PreferredAuthentications=none -o LogLevel=ERROR "$H" true 2>&1 || true
}

setup_host_login() {
  local k trusted='' auth reply
  if key_ok; then note "ok   ssh $H logs in by key"; return 0; fi

  auth=$(auth_reply)
  case "$auth" in
    *"Permission denied"*) ;;
    *) fail "$H ($ADDR) is not reachable over ssh: $auth"
       note "check the Tailscale menu bar icon and that $H is online, then re-run ./install-mac.sh"; return 1 ;;
  esac

  # Host key. BatchMode refuses an unknown host, so store it now (trust on first use, fingerprint shown for the
  # record). A stored key that no longer matches is never replaced here.
  reply=$(ssh -o BatchMode=yes -o ConnectTimeout=5 -o PreferredAuthentications=none -o LogLevel=ERROR "$H" true 2>&1 || true)
  if [[ $reply != *"Permission denied"* ]]; then
    if ssh-keygen -F "$ADDR" >/dev/null 2>&1; then
      fail "$H's host key does not match the one stored in ~/.ssh/known_hosts."
      note "if $H was reinstalled:  ssh-keygen -R $ADDR${LAN:+; ssh-keygen -R $LAN}   then re-run ./install-mac.sh"
      return 1
    fi
    note "first connection: storing $H's host key in ~/.ssh/known_hosts"
    ssh-keyscan -T 5 -t ed25519 "$ADDR" 2>/dev/null | ssh-keygen -lf - 2>/dev/null | sed 's/^/      /' || true
    ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o PreferredAuthentications=none \
        -o LogLevel=ERROR "$H" true 2>/dev/null || true
    if key_ok; then note "ok   ssh $H logs in by key ($H already trusted the repo key)"; return 0; fi
  fi

  # A key provisioned before this repo may already be trusted by the host. If so, install the repo key over it, without
  # a password. -f is required: ssh-copy-id first logs in with every explicit identity to skip keys it thinks are
  # already installed, and the -o IdentityFile option makes that probe succeed with the old key, so without -f it
  # skips the new one and reports "All keys were skipped".
  for k in "$HOME"/.ssh/id_*; do
    case "$k" in *.pub|*-cert*|"$HOME/.ssh/id_ed25519") continue ;; esac
    [ -f "$k" ] || continue
    if probe "$k"; then trusted=$k; break; fi
  done
  if [ -n "$trusted" ]; then
    note "$H trusts ${trusted/#$HOME/~} but not ~/.ssh/id_ed25519; installing the repo key over it (no password)"
    ssh-copy-id -f -i "$PUB" -o IdentityFile="$trusted" "$H" >/dev/null 2>&1 || fail "ssh-copy-id via ${trusted/#$HOME/~} failed"
  else
    case "$auth" in
      *password*) ;;
      *) fail "$H does not trust any local key and has password login off (a key was imported at install)."
         note "either run ./install-as1.sh on $H (README.md, section 3) and re-run this script, or"
         note "at the $H console:  mkdir -p -m 700 ~/.ssh && echo '$(cat "$PUB")' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
         return 1 ;;
    esac
    if [ ! -t 0 ]; then
      fail "$H does not trust ~/.ssh/id_ed25519 and there is no terminal to ask for a password."
      note "run in a terminal:  ssh-copy-id -i ~/.ssh/id_ed25519.pub $H"; return 1
    fi
    note "$H does not trust ~/.ssh/id_ed25519 yet. Enter $RUSER's password on $H when asked; it is needed once."
    ssh-copy-id -i "$PUB" "$H" || fail "ssh-copy-id failed (wrong password, or $H refused)"
  fi

  if key_ok; then note "ok   ssh $H logs in by key"; return 0; fi
  fail "ssh $H still prompts. Diagnose with:  ssh -v $H true"; return 1
}

LOGIN_OK=1; setup_host_login || LOGIN_OK=0
if [ "$LOGIN_OK" = 1 ] && [ "$WEZ_OK" = 1 ]; then
  say "Done. Open a new shell, reload WezTerm (Cmd+Shift+R), then verify with README.md, sections 2 and 6"
else
  [ "$LOGIN_OK" = 1 ] || say "Done, but ssh $H is not keyless yet (see above). Fix that, then re-run ./install-mac.sh"
  [ "$WEZ_OK" = 1 ] || say "Done, but ${WEZ/#$HOME/~} does not include $WEZ_MOD (see above): Cmd+V will not paste images into $H"
  exit 1
fi
