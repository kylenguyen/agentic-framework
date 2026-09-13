# lib/params.sh: host parameters shared by install-as1.sh and install-mac.sh. Sourced, never executed.
# Must run under macOS /bin/bash 3.2 as well as Linux bash 5: no associative arrays, mapfile or ${var,,}.
# The caller sets REPO (checkout root) before sourcing.
#
# Parameters, read from $REPO/.env (gitignored; template .env.example). Names, addresses and a login only,
# never secrets: those stay in ~/.config/agents/env, which agents are denied.
#   AGENT_HOST           ssh alias and WezTerm domain name                 host: default `hostname -s`
#   AGENT_HOST_ADDRESS   what the Mac connects to (MagicDNS name, FQDN, IP)  host: Tailscale DNS name, else AGENT_HOST
#   AGENT_HOST_USER      login on the host                                 host: always `id -un`; .env must agree
#   AGENT_HOST_LAN_IP    host address on the LAN; empty drops <alias>-lan   host: `src` of the default route
#   AGENT_HOST_LAN_CIDR  LAN range ufw lets ssh in from; host only          host: connected route of that interface
# Templates carry the same names as @AGENT_HOST@ style placeholders; params_render fills them in and fails on any
# placeholder left over, so a half-rendered file (an sshd AllowUsers line, say) can never be installed.

PARAMS_NAMES="AGENT_HOST AGENT_HOST_ADDRESS AGENT_HOST_USER AGENT_HOST_LAN_IP AGENT_HOST_LAN_CIDR"

params_fail() { printf '\033[1;31m!!  %s\033[0m\n' "$*" >&2; return 1; }

# params_load [file]: read KEY=value lines from .env. Anything that is not a known key with a plain value is an
# error, so the file is never executed as shell. Values already set in the environment take precedence, which lets
# a test or a one-off run override the file: AGENT_HOST=other ./install-mac.sh
params_load() {
  local file=${1:-$REPO/.env} line key val n=0
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$line" in ''|'#'*) continue ;; esac
    if ! [[ $line =~ ^(AGENT_HOST[A-Z_]*)=\"?([A-Za-z0-9_.:/-]*)\"?[[:space:]]*$ ]]; then
      params_fail "$file:$n: expected AGENT_HOST...=value (letters, digits, . : / _ -), got: $line"; return 1
    fi
    key=${BASH_REMATCH[1]}
    # shellcheck disable=SC2034
    val=${BASH_REMATCH[2]}                                   # read through eval below
    case " $PARAMS_NAMES " in *" $key "*) ;; *) params_fail "$file:$n: unknown parameter $key"; return 1 ;; esac
    if [ -z "$(eval "printf %s \"\${$key:-}\"")" ]; then eval "$key=\$val"; fi
  done < "$file"
}

# Validators. Each prints nothing and returns 1 on a bad value; params_validate names the parameter.
params_is_name()  { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; }                 # ssh alias, hostname label(s)
params_is_addr()  { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9_.:-]*$ ]]; }                # hostname, FQDN, IPv4 or IPv6
params_is_user()  { [[ $1 =~ ^[A-Za-z_][A-Za-z0-9_.-]{0,31}$ ]]; }              # no space, no @ (sshd user@host), no ,
params_is_ipv4()  {
  local o
  [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1:4}"; do [ "$o" -le 255 ] || return 1; done
}
params_is_cidr()  {                                                            # a later =~ resets BASH_REMATCH, so copy first
  local net bits
  [[ $1 =~ ^(.*)/([0-9]{1,2})$ ]] || return 1
  net=${BASH_REMATCH[1]}; bits=${BASH_REMATCH[2]}
  params_is_ipv4 "$net" && [ "$bits" -le 32 ]
}
params_is_private_cidr() { # RFC 1918 only; anything else must be set explicitly in .env
  params_is_cidr "$1" || return 1
  case "$1" in 10.*) return 0 ;; 192.168.*) return 0 ;;
    172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;; esac
  return 1
}

params_validate() {
  local ok=1
  if [ -n "${AGENT_HOST:-}" ]         && ! params_is_name "$AGENT_HOST";         then params_fail "AGENT_HOST=$AGENT_HOST: use letters, digits, . _ -"; ok=0; fi
  if [ -n "${AGENT_HOST_ADDRESS:-}" ] && ! params_is_addr "$AGENT_HOST_ADDRESS"; then params_fail "AGENT_HOST_ADDRESS=$AGENT_HOST_ADDRESS: hostname, FQDN or IP"; ok=0; fi
  if [ -n "${AGENT_HOST_USER:-}" ]    && ! params_is_user "$AGENT_HOST_USER";    then params_fail "AGENT_HOST_USER=$AGENT_HOST_USER: one login name, no spaces or @"; ok=0; fi
  if [ -n "${AGENT_HOST_LAN_IP:-}" ]  && ! params_is_ipv4 "$AGENT_HOST_LAN_IP";  then params_fail "AGENT_HOST_LAN_IP=$AGENT_HOST_LAN_IP: dotted IPv4"; ok=0; fi
  if [ -n "${AGENT_HOST_LAN_CIDR:-}" ] && ! params_is_cidr "$AGENT_HOST_LAN_CIDR"; then params_fail "AGENT_HOST_LAN_CIDR=$AGENT_HOST_LAN_CIDR: IPv4/prefix"; ok=0; fi
  [ "$ok" = 1 ]
}

# params_require NAME...: the Mac cannot derive anything; these must come from .env or the prompt.
params_require() {
  local n
  for n in "$@"; do
    [ -n "$(eval "printf %s \"\${$n:-}\"")" ] || { params_fail "$n is not set: copy .env.example to .env and fill it in (README.md, section 2)"; return 1; }
  done
}

# params_derive_host: fill what the system knows (Linux host only). Runs after params_load, so .env overrides
# win, except the login: the script configures the account it runs as, and sshd AllowUsers must name that one.
params_derive_host() {
  local me dev route
  me=$(id -un)
  if [ -n "${AGENT_HOST_USER:-}" ] && [ "$AGENT_HOST_USER" != "$me" ]; then
    params_fail "AGENT_HOST_USER=$AGENT_HOST_USER but this script runs as $me; fix .env or run as $AGENT_HOST_USER"; return 1
  fi
  AGENT_HOST_USER=$me
  : "${AGENT_HOST:=$(hostname -s)}"
  if [ -z "${AGENT_HOST_ADDRESS:-}" ]; then
    AGENT_HOST_ADDRESS=$(params_tailscale_name || true)
    : "${AGENT_HOST_ADDRESS:=$AGENT_HOST}"
  fi
  if [ -z "${AGENT_HOST_LAN_IP:-}" ] || [ -z "${AGENT_HOST_LAN_CIDR:-}" ]; then
    route=$(params_lan_route || true)              # "cidr ip" of the default-route interface, or empty
    [ -n "${AGENT_HOST_LAN_CIDR:-}" ] || AGENT_HOST_LAN_CIDR=${route%% *}
    [ -n "${AGENT_HOST_LAN_IP:-}" ]   || AGENT_HOST_LAN_IP=${route##* }
  fi
  params_validate
}

# params_tailscale_name: MagicDNS name of this machine without the trailing dot, or nothing.
params_tailscale_name() {
  command -v tailscale >/dev/null && command -v jq >/dev/null || return 1
  local n
  n=$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' 2>/dev/null) || return 1
  n=${n%.}; [ -n "$n" ] || return 1
  printf '%s\n' "$n"
}

# params_lan_route: "<network/prefix> <address>" for the interface that carries the default route, from the kernel's
# connected route (`ip route` on Linux), so no CIDR arithmetic is needed. Returns 1 when there is none.
params_lan_route() {
  command -v ip >/dev/null || return 1
  local dev line cidr src
  dev=$(ip -o -4 route show default 2>/dev/null | awk '{for (i=1;i<NF;i++) if ($i=="dev") {print $(i+1); exit}}')
  [ -n "$dev" ] || return 1
  line=$(ip -o -4 route show dev "$dev" proto kernel scope link 2>/dev/null | head -1)
  cidr=${line%% *}
  src=$(printf '%s\n' "$line" | awk '{for (i=1;i<NF;i++) if ($i=="src") {print $(i+1); exit}}')
  params_is_cidr "$cidr" && params_is_ipv4 "$src" || return 1
  printf '%s %s\n' "$cidr" "$src"
}

# params_render <template> <out>: substitute every @AGENT_...@ placeholder; out may be - for stdout. Fails, and
# writes nothing to <out>, if a placeholder has no value or is not a parameter at all.
params_render() {
  local src=$1 out=$2 tmp n v left expr=''
  [ -f "$src" ] || { params_fail "template not found: $src"; return 1; }
  for n in $PARAMS_NAMES; do
    v=$(eval "printf %s \"\${$n:-}\"")
    [ -n "$v" ] && expr="${expr}s|@$n@|$v|g;"
  done
  tmp=$(mktemp)
  sed "$expr" "$src" > "$tmp"
  if left=$(grep -n '@AGENT_[A-Z_]*@' "$tmp"); then
    rm -f "$tmp"; params_fail "$src: unresolved placeholder(s):"; printf '%s\n' "$left" >&2; return 1
  fi
  if [ "$out" = - ]; then cat "$tmp"; rm -f "$tmp"; else cat "$tmp" > "$out"; rm -f "$tmp"; fi
}

# params_env_text: the .env file body for the current values. What install-as1.sh prints for the Macs.
params_env_text() {
  printf '# Host parameters (names and addresses, no secrets). Generated by install-as1.sh on %s, %s.\n' "$(hostname -s)" "$(date +%Y-%m-%d)"
  printf '# Copy to .env in the agentic-framework checkout on each Mac. AGENT_HOST_LAN_CIDR is used on the host only.\n'
  printf 'AGENT_HOST=%s\nAGENT_HOST_ADDRESS=%s\nAGENT_HOST_USER=%s\nAGENT_HOST_LAN_IP=%s\nAGENT_HOST_LAN_CIDR=%s\n' \
    "${AGENT_HOST:-}" "${AGENT_HOST_ADDRESS:-}" "${AGENT_HOST_USER:-}" "${AGENT_HOST_LAN_IP:-}" "${AGENT_HOST_LAN_CIDR:-}"
}

# params_prompt: interactive fallback for the Mac when .env is missing. Caller checks for a terminal.
params_prompt() {
  local v
  printf 'No .env in %s. Enter the host parameters (README.md, section 2); they are saved to .env.\n' "$REPO"
  read -r -p "  ssh alias / WezTerm domain name [as1]: " v; AGENT_HOST=${v:-as1}
  read -r -p "  address the Mac connects to [$AGENT_HOST]: " v; AGENT_HOST_ADDRESS=${v:-$AGENT_HOST}
  read -r -p "  login on the host: " v; AGENT_HOST_USER=$v
  read -r -p "  LAN address of the host, blank for none: " v; AGENT_HOST_LAN_IP=$v
  params_validate && params_require AGENT_HOST AGENT_HOST_USER
}
