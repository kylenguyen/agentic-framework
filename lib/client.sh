# lib/client.sh: the client half of the setup, shared by install-mac.sh and install-linux.sh. Sourced, never executed.
# Must run under macOS /bin/bash 3.2 as well as Linux bash 5, and with BSD as well as GNU tools (see lib/params.sh).
# The caller sets REPO, sources lib/params.sh, then this file, and sets these before calling anything:
#   CLIENT_SCRIPT   its own name, for "re-run ./<script>" hints
#   CLIENT_RC       the shell rc file that gets the ~/.local/bin PATH block
#   KEY_PASTE       how the paste key is written on this platform (Cmd+V, Ctrl+Shift+V)
#   KEY_RELOAD      how WezTerm's reload-config key is written (Cmd+Shift+R, Ctrl+Shift+R)
#   NET_HINT        what to check when the host does not answer (the Tailscale app or daemon)
# The steps run in this order: client_params, the caller's packages, client_ssh_config, client_wezterm,
# client_clip_push <template>, client_login, client_finish.

say()  { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
fail() { printf '\033[1;31m!!  %s\033[0m\n' "$*"; }

# client_short_host: this machine's short name, for the key comment. Minimal Linux images ship without `hostname`.
client_short_host() { hostname -s 2>/dev/null || uname -n | cut -d. -f1; }

# client_params: settle the parameters before anything is touched. A missing .env is prompted for on a terminal and
# written; without a terminal the script exits 2. Sets H, ADDR, RUSER and LAN.
client_params() {
  params_load || exit 1
  if [ -z "${AGENT_HOST:-}" ] || [ -z "${AGENT_HOST_USER:-}" ]; then
    if [ -f "$REPO/.env" ] || [ ! -t 0 ]; then params_require AGENT_HOST AGENT_HOST_USER || exit 2; fi
    params_prompt || exit 2
    params_env_text "$CLIENT_SCRIPT" > "$REPO/.env"; note "wrote .env"
  fi
  : "${AGENT_HOST_ADDRESS:=$AGENT_HOST}"
  params_validate || exit 1
  H=$AGENT_HOST; ADDR=$AGENT_HOST_ADDRESS; RUSER=$AGENT_HOST_USER; LAN=${AGENT_HOST_LAN_IP:-}
  say "Parameters: \`ssh $H\` is $RUSER@$ADDR${LAN:+, \`ssh $H-lan\` is $RUSER@$LAN}"
}

# block <file> <marker> <content>: append or replace a marked block (same markers as install-host.sh).
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

# client_ssh_config: the agent-host block in ~/.ssh/config, and a key if there is none.
client_ssh_config() {
  local block_text
  install -d -m 700 "$HOME/.ssh"; touch "$HOME/.ssh/config"; chmod 600 "$HOME/.ssh/config"
  block_text=$(params_ssh_config_text) || { fail "config/ssh_config.client.in did not render"; exit 1; }
  block "$HOME/.ssh/config" agent-host "$block_text"
  [ -f "$HOME/.ssh/id_ed25519" ] || { note "no ~/.ssh/id_ed25519; generating"; ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N '' -C "$(id -un)@$(client_short_host)"; }
}

WEZ_MOD=wezterm-agent-host                       # module name; the file is rendered from config/$WEZ_MOD.lua.in
WEZ_OK=1

# client_wezterm: render the module and make sure the config WezTerm loads includes it. Sets WEZ and WEZ_OK.
client_wezterm() {
  install -d "$HOME/.config/wezterm"
  params_render "$REPO/config/$WEZ_MOD.lua.in" "$HOME/.config/wezterm/$WEZ_MOD.lua" || { fail "config/$WEZ_MOD.lua.in did not render"; exit 1; }
  # The include must go in the config WezTerm actually loads, or the paste key stays a plain paste. WezTerm reads, in
  # order: $WEZTERM_CONFIG_FILE, ~/.config/wezterm/wezterm.lua, ~/.wezterm.lua; creating the second while only the
  # third exists would shadow the user's config, so an existing file wins. ~/.config/wezterm is on package.path
  # whichever is loaded.
  if [ -n "${WEZTERM_CONFIG_FILE:-}" ] && [ -f "$WEZTERM_CONFIG_FILE" ]; then WEZ=$WEZTERM_CONFIG_FILE
  elif [ -f "$HOME/.config/wezterm/wezterm.lua" ] || [ ! -f "$HOME/.wezterm.lua" ]; then WEZ="$HOME/.config/wezterm/wezterm.lua"
  else WEZ="$HOME/.wezterm.lua"; fi
  wez_include "$WEZ" || WEZ_OK=0
  note "reload WezTerm ($KEY_RELOAD) so $KEY_PASTE pushes images to $H"
}

# wez_include <file>: make sure the config includes $WEZ_MOD. A missing file gets a minimal config. An existing file
# is edited once: the require line goes just before the final `return <config>` line, whatever the variable is
# called, with the original kept as <file>.before-agent-host. A config that ends some other way cannot be edited
# safely: the line to add is printed and the script exits 1 at the end so the gap is not missed.
wez_include() {
  local file=$1 var
  if [ ! -f "$file" ]; then
    cat > "$file" <<'EOF'
local wezterm = require("wezterm")
local config = wezterm.config_builder()
require("wezterm-agent-host").apply(config)
return config
EOF
    note "created ${file/#$HOME/\~} (minimal, includes $WEZ_MOD)"; return 0
  fi
  if grep -q "$WEZ_MOD" "$file"; then note "ok   ${file/#$HOME/\~} includes $WEZ_MOD"; return 0; fi
  # Last `return <identifier>` line, ignoring trailing spaces and a trailing comment.
  var=$(awk '{ l=$0; sub(/--.*/, "", l) }
             l ~ /^[[:space:]]*return[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*$/ { v=l; sub(/^[[:space:]]*return[[:space:]]+/, "", v); sub(/[[:space:]]*$/, "", v) }
             END { if (v != "") print v }' "$file")
  if [ -z "$var" ]; then
    fail "${file/#$HOME/\~} exists but does not end with \`return <config>\`, so it was left alone."
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
  note "upd  ${file/#$HOME/\~}: added require(\"$WEZ_MOD\").apply($var) before \`return $var\` (original: ${file/#$HOME/\~}.before-agent-host)"
}

# client_clip_push <template>: render this platform's clip-push into ~/.local/bin, and put ~/.local/bin on PATH.
client_clip_push() {
  local tmpl=$1 tmp
  install -d "$HOME/.local/bin"
  tmp=$(mktemp); params_render "$REPO/$tmpl" "$tmp" || { fail "$tmpl did not render"; exit 1; }
  install -m 755 "$tmp" "$HOME/.local/bin/clip-push"; rm -f "$tmp"
  note "installed ~/.local/bin/clip-push (pushes to $H-clip)"
  # WezTerm calls clip-push by absolute path, but the verify commands in the docs are typed in a shell, and a fresh
  # account may not have ~/.local/bin on PATH. Same marker mechanism as ~/.ssh/config.
  touch "$CLIENT_RC"
  # shellcheck disable=SC2016  # expanded by the shell that reads the rc file
  block "$CLIENT_RC" path 'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac'
  case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) note "open a new shell so clip-push is on PATH" ;; esac
}

# Key login. Goal: `ssh $H true` runs with no prompt of any kind; mosh, the clipboard push and every `ssh $H <cmd>`
# depend on it. Never deletes anything: a stored host key that does not match is for a human to judge.
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
  local k trusted='' auth reply pub="$HOME/.ssh/id_ed25519.pub"
  if key_ok; then note "ok   ssh $H logs in by key"; return 0; fi

  auth=$(auth_reply)
  case "$auth" in
    *"Permission denied"*) ;;
    *) fail "$H ($ADDR) is not reachable over ssh: $auth"
       note "$NET_HINT and that $H is online, then re-run ./$CLIENT_SCRIPT"; return 1 ;;
  esac

  # Host key: BatchMode refuses an unknown host, so store it on first use, fingerprint shown for the record. A stored
  # key that does not match is never replaced here.
  reply=$(ssh -o BatchMode=yes -o ConnectTimeout=5 -o PreferredAuthentications=none -o LogLevel=ERROR "$H" true 2>&1 || true)
  if [[ $reply != *"Permission denied"* ]]; then
    if ssh-keygen -F "$ADDR" >/dev/null 2>&1; then
      fail "$H's host key does not match the one stored in ~/.ssh/known_hosts."
      note "if $H was reinstalled:  ssh-keygen -R $ADDR${LAN:+; ssh-keygen -R $LAN}   then re-run ./$CLIENT_SCRIPT"
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
    note "$H trusts ${trusted/#$HOME/\~} but not ~/.ssh/id_ed25519; installing the repo key over it (no password)"
    ssh-copy-id -f -i "$pub" -o IdentityFile="$trusted" "$H" >/dev/null 2>&1 || fail "ssh-copy-id via ${trusted/#$HOME/\~} failed"
  else
    case "$auth" in
      *password*) ;;
      *) fail "$H does not trust any local key and has password login off (a key was imported at install)."
         note "either run ./install-host.sh on $H (README.md, section 3) and re-run this script, or"
         note "at the $H console:  mkdir -p -m 700 ~/.ssh && echo '$(cat "$pub")' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
         return 1 ;;
    esac
    if [ ! -t 0 ]; then
      fail "$H does not trust ~/.ssh/id_ed25519 and there is no terminal to ask for a password."
      note "run in a terminal:  ssh-copy-id -i ~/.ssh/id_ed25519.pub $H"; return 1
    fi
    note "$H does not trust ~/.ssh/id_ed25519 yet. Enter $RUSER's password on $H when asked; it is needed once."
    ssh-copy-id -i "$pub" "$H" || fail "ssh-copy-id failed (wrong password, or $H refused)"
  fi

  if key_ok; then note "ok   ssh $H logs in by key"; return 0; fi
  fail "ssh $H still prompts. Diagnose with:  ssh -v $H true"; return 1
}

LOGIN_OK=1
client_login() {
  say "Key login to $H (asks for $RUSER's password on $H once, only if it has to)"
  setup_host_login || LOGIN_OK=0
}

# client_finish [extra-failure-message]: the closing line, and exit 1 if anything above was left undone. The caller
# passes a message of its own (a missing package, say) to count as a failure too.
client_finish() {
  local extra=${1:-}
  if [ "$LOGIN_OK" = 1 ] && [ "$WEZ_OK" = 1 ] && [ -z "$extra" ]; then
    say "Done. Open a new shell, reload WezTerm ($KEY_RELOAD), then verify with README.md, sections 2 and 5"
    return 0
  fi
  [ "$LOGIN_OK" = 1 ] || say "Done, but ssh $H is not keyless yet (see above). Fix that, then re-run ./$CLIENT_SCRIPT"
  [ "$WEZ_OK" = 1 ] || say "Done, but ${WEZ/#$HOME/\~} does not include $WEZ_MOD (see above): $KEY_PASTE will not paste images into $H"
  [ -z "$extra" ] || say "Done, but $extra"
  exit 1
}
