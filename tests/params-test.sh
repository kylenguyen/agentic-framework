#!/usr/bin/env bash
# tests/params-test.sh: checks for lib/params.sh and every rendered template. No network, no sudo, nothing written
# outside a temp dir, so it is safe on the live host, in a container and on a Mac (bash 3.2). Exit 0 when all pass.
# Usage: bash tests/params-test.sh
# A && ok || bad is the intended pattern and cases run in subshells on purpose:
# shellcheck disable=SC2015,SC2016,SC2030,SC2031
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
: > "$T/results"                                   # one line per case; cases run in subshells, so no counters
ok()    { echo ok >> "$T/results"; printf 'ok   %s\n' "$1"; }
bad()   { echo FAIL >> "$T/results"; printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }   # check <name> <expected> <actual>
# fresh: start a case with no parameters set and the library loaded. Run inside ( ) so cases do not leak.
fresh() { unset AGENT_HOST AGENT_HOST_ADDRESS AGENT_HOST_USER AGENT_HOST_LAN_IP AGENT_HOST_LAN_CIDR; . "$REPO/lib/params.sh"; }
# expect_fail <name> <cmd...>: the command must return non-zero and print something on stderr
expect_fail() { local n=$1; shift; local err; if err=$("$@" 2>&1 >/dev/null); then bad "$n" "succeeded, expected failure"; else
  if [ -n "$err" ]; then ok "$n"; else bad "$n" "failed silently"; fi; fi; }

echo "# syntax"
for f in lib/params.sh tests/params-test.sh; do bash -n "$REPO/$f" && ok "bash -n $f" || bad "bash -n $f"; done

echo "# params_load"
( fresh
  printf 'AGENT_HOST=box\nAGENT_HOST_USER="alice"\n\n# c\nAGENT_HOST_LAN_CIDR=10.1.0.0/16\n' > "$T/env1"
  params_load "$T/env1" || bad "load env1" "returned $?"
  check "load: plain value" box "$AGENT_HOST"
  check "load: quoted value" alice "$AGENT_HOST_USER"
  check "load: cidr" 10.1.0.0/16 "$AGENT_HOST_LAN_CIDR"
  check "load: unset stays empty" "" "${AGENT_HOST_LAN_IP:-}"
)
( fresh; AGENT_HOST=pre; printf 'AGENT_HOST=file\n' > "$T/env2"; params_load "$T/env2"; check "load: environment beats file" pre "$AGENT_HOST" )
( fresh; params_load "$T/does-not-exist" && ok "load: missing file is fine" || bad "load: missing file" )
( fresh; printf 'AGENT_HOST=a b\n' > "$T/bad1"; expect_fail "load: rejects space in value" params_load "$T/bad1" )
( fresh; printf 'OTHER=1\n' > "$T/bad2"; expect_fail "load: rejects foreign key" params_load "$T/bad2" )
( fresh; printf 'AGENT_HOST_NOPE=1\n' > "$T/bad3"; expect_fail "load: rejects unknown AGENT_ key" params_load "$T/bad3" )
( fresh; printf 'AGENT_HOST=$(id)\n' > "$T/bad4"; expect_fail "load: rejects shell syntax" params_load "$T/bad4" )
( fresh; printf 'x\nAGENT_HOST=a;b\n' > "$T/bad5"; err=$(params_load "$T/bad5" 2>&1); case "$err" in *bad5:1:*) ok "load: names the line";; *) bad "load: names the line" "$err";; esac )

echo "# validators"
( fresh
  params_is_user kyle && ok "user: kyle" || bad "user: kyle"
  params_is_user "kyle smith" && bad "user: rejects space" || ok "user: rejects space"
  params_is_user "a@b" && bad "user: rejects @" || ok "user: rejects @"
  params_is_name as1 && ok "name: as1" || bad "name: as1"
  params_is_name "a/b" && bad "name: rejects /" || ok "name: rejects /"
  params_is_addr as1.tail.ts.net && ok "addr: fqdn" || bad "addr: fqdn"
  params_is_ipv4 192.168.10.2 && ok "ipv4: ok" || bad "ipv4: ok"
  params_is_ipv4 256.1.1.1 && bad "ipv4: rejects 256" || ok "ipv4: rejects 256"
  params_is_cidr 192.168.10.0/24 && ok "cidr: ok" || bad "cidr: ok"
  params_is_cidr 192.168.10.0/33 && bad "cidr: rejects /33" || ok "cidr: rejects /33"
  params_is_cidr 192.168.10.0 && bad "cidr: rejects no prefix" || ok "cidr: rejects no prefix"
  params_is_private_cidr 10.0.0.0/8 && ok "private: 10/8" || bad "private: 10/8"
  params_is_private_cidr 172.31.0.0/16 && ok "private: 172.31" || bad "private: 172.31"
  params_is_private_cidr 172.32.0.0/16 && bad "private: rejects 172.32" || ok "private: rejects 172.32"
  params_is_private_cidr 8.8.8.0/24 && bad "private: rejects 8.8.8.0" || ok "private: rejects 8.8.8.0"
  AGENT_HOST_USER="two words"; expect_fail "validate: names the bad parameter" params_validate
  AGENT_HOST_USER=alice; AGENT_HOST=box; params_validate && ok "validate: good set" || bad "validate: good set"
  AGENT_HOST_USER=; expect_fail "require: unset parameter" params_require AGENT_HOST AGENT_HOST_USER
  params_require AGENT_HOST && ok "require: set parameter" || bad "require: set parameter"
)

echo "# params_render"
( fresh; AGENT_HOST=box; AGENT_HOST_ADDRESS=box.tail.ts.net; AGENT_HOST_USER=alice; AGENT_HOST_LAN_IP=10.0.0.5; AGENT_HOST_LAN_CIDR=10.0.0.0/24
  printf 'Host @AGENT_HOST@ @AGENT_HOST@-clip\n  HostName @AGENT_HOST_ADDRESS@\n  User @AGENT_HOST_USER@\n  ControlPath ~/.ssh/cm-%%r@%%h:%%p\n  # @AGENT_HOST_LAN_IP@ @AGENT_HOST_LAN_CIDR@\n' > "$T/t.in"
  params_render "$T/t.in" "$T/t.out" || bad "render: returns 0" "$?"
  check "render: repeated placeholder" "Host box box-clip" "$(sed -n 1p "$T/t.out")"
  check "render: address" "  HostName box.tail.ts.net" "$(sed -n 2p "$T/t.out")"
  check "render: user" "  User alice" "$(sed -n 3p "$T/t.out")"
  check "render: ssh tokens untouched" '  ControlPath ~/.ssh/cm-%r@%h:%p' "$(sed -n 4p "$T/t.out")"
  check "render: ip and cidr" "  # 10.0.0.5 10.0.0.0/24" "$(sed -n 5p "$T/t.out")"
  check "render: to stdout" "Host box box-clip" "$(params_render "$T/t.in" - | head -1)"
  printf 'x @AGENT_HOST_NOPE@\n' > "$T/u.in"; expect_fail "render: unknown placeholder fails" params_render "$T/u.in" "$T/u.out"
  [ -e "$T/u.out" ] && bad "render: nothing written on failure" || ok "render: nothing written on failure"
  AGENT_HOST_LAN_IP=; expect_fail "render: empty value fails" params_render "$T/t.in" "$T/v.out"
  expect_fail "render: missing template fails" params_render "$T/none.in" "$T/w.out"
)

echo "# params_derive_host"
( fresh; AGENT_HOST_USER=someone-else; expect_fail "derive: refuses a different login in .env" params_derive_host )
( fresh; params_derive_host >/dev/null 2>&1 || bad "derive: returns 0" "$?"
  check "derive: user is the caller" "$(id -un)" "$AGENT_HOST_USER"
  check "derive: alias is hostname -s" "$(hostname -s)" "$AGENT_HOST"
  [ -n "$AGENT_HOST_ADDRESS" ] && ok "derive: address set ($AGENT_HOST_ADDRESS)" || bad "derive: address set"
  if command -v ip >/dev/null && ip -o -4 route show default 2>/dev/null | grep -q .; then
    params_is_cidr "$AGENT_HOST_LAN_CIDR" && ok "derive: lan cidr ($AGENT_HOST_LAN_CIDR)" || bad "derive: lan cidr" "$AGENT_HOST_LAN_CIDR"
    dev=$(ip -o -4 route show default | awk '{for (i=1;i<NF;i++) if ($i=="dev") {print $(i+1); exit}}')
    ip -o -4 addr show dev "$dev" | grep -q " inet $AGENT_HOST_LAN_IP/" && ok "derive: lan ip is on the default-route interface ($AGENT_HOST_LAN_IP)" \
      || bad "derive: lan ip" "$AGENT_HOST_LAN_IP not on $dev"
  else
    echo "skip derive: lan route (no ip route here)"
  fi
  params_env_text > "$T/env.txt"
  check "env_text: five parameters" 5 "$(grep -c '^AGENT_HOST' "$T/env.txt")"
  ( fresh; params_load "$T/env.txt" && params_validate && ok "env_text: loads back cleanly" || bad "env_text: loads back" )
)
( fresh; AGENT_HOST_LAN_CIDR=10.9.0.0/16; AGENT_HOST=custom; params_derive_host >/dev/null 2>&1
  check "derive: .env cidr override wins" 10.9.0.0/16 "$AGENT_HOST_LAN_CIDR"; check "derive: .env alias wins" custom "$AGENT_HOST" )

pass=$(grep -c '^ok$' "$T/results"); fail=$(grep -c '^FAIL$' "$T/results")
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
