# shellcheck shell=bash
# Sourced by tests/sim-test.sh after tests/sim/harness.sh; see its header.
# shellcheck disable=SC2015,SC2016,SC2030,SC2031,SC2154
echo "# port blocks"
( lib
  check "port block: android 1" 20000 "$(sim_port_base android 1)"
  check "port block: android 3" 20200 "$(sim_port_base android 3)"
  check "port block: web 2" 21100 "$(sim_port_base web 2)"
  check "port block: ios 2" 22100 "$(sim_port_base ios 2)"
  check "port block: base and count" "21100 100" "$(sim_port_block web 2)"
  sim_port_base tv 1 2>/dev/null && bad "port block: rejects an unknown platform" || ok "port block: rejects an unknown platform"
  # Every pair of blocks for slots 1-9 is disjoint, and each stays clear of the sim services and the ephemeral range.
  blocks=() clash=
  for p in android web ios; do for n in 1 2 3 4 5 6 7 8 9; do blocks+=("$p$n:$(sim_port_base "$p" "$n")"); done; done
  for a in "${blocks[@]}"; do
    lo=${a#*:}; hi=$((lo + SIM_PORT_BLOCK - 1))
    [ "$hi" -lt 32768 ] && { [ "$hi" -lt 5037 ] || [ "$lo" -gt 8209 ]; } || clash+=" ${a%%:*}/services"
    for b in "${blocks[@]}"; do
      [ "$a" = "$b" ] && continue
      blo=${b#*:}; bhi=$((blo + SIM_PORT_BLOCK - 1))
      [ "$hi" -lt "$blo" ] || [ "$bhi" -lt "$lo" ] || clash+=" ${a%%:*}/${b%%:*}"
    done
  done
  check "port block: no two slots overlap, none hits a service port" "" "$clash"
)
( cd "$T/ws/app" || exit 1
  out=$("$REPO/bin/sim" ports web 2>&1); rc=$?
  check "ports: rc 1 without a lease" 1 "$rc"
  has "ports: says how to get a slot" "sim enable" "$out"
  "$REPO/bin/sim" ports 2>/dev/null; check "ports: no platform is a usage error" 2 "$?"
  "$REPO/bin/sim" ports tv 2>/dev/null; check "ports: unknown platform is a usage error" 2 "$?"
  hold web "$T/ws/app" 30; holder=$!
  wait_for "( lib; sim_held web 1 )"
  check "ports: eval gives the block" "21000 100" "$(eval "$("$REPO/bin/sim" ports web)"; echo "$SIM_PORT_BASE $SIM_PORT_COUNT")"
  check "ports: the first k" "21000 21001 21002" "$("$REPO/bin/sim" ports web 3)"
  check "ports: all 100" 100 "$("$REPO/bin/sim" ports web 100 | wc -w)"
  "$REPO/bin/sim" ports web 101 2>/dev/null; check "ports: 101 is a usage error" 2 "$?"
  "$REPO/bin/sim" ports web 0 2>/dev/null; check "ports: 0 is a usage error" 2 "$?"
  "$REPO/bin/sim" ports web x 2>/dev/null; check "ports: a word is a usage error" 2 "$?"
  # --check against the real ss: a listener on a port of the block that nothing else on this host uses. Parallel
  # runs of this suite each use their own SIM_STATE but the same block, so take the first free port, not 21000.
  if command -v python3 >/dev/null && command -v ss >/dev/null; then
    port=
    for p in $(seq 21000 21099); do ss -Hltn "sport = :$p" | grep -q . || { port=$p; break; }; done
    if [ -n "$port" ]; then
      python3 -m http.server --bind 127.0.0.1 "$port" >/dev/null 2>&1 & srv=$!
      if wait_for "ss -Hltn 'sport = :$port' | grep -q ."; then
        out=$("$REPO/bin/sim" ports web --check); rc=$?
        check "ports --check: rc 1 when a port of the block listens" 1 "$rc"
        has "ports --check: names the port and its process" "python3" "$(echo "$out" | grep "^$port ")"
      else bad "ports --check: http.server did not listen on $port"; fi
      kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null
    else echo "skip ports --check: every port of 21000-21099 is in use on this host"; fi
  else echo "skip ports --check: python3 or ss is missing"; fi
  # --check with a stub ss: a process ss cannot show (another user's), IPv4 and IPv6 lines merged, ports outside
  # the block ignored, and rc 0 when nothing listens.
  mkdir -p "$T/ss-shim"
  printf '#!/bin/sh\ncat "%s/ss.out"\n' "$T" > "$T/ss-shim/ss"; chmod +x "$T/ss-shim/ss"
  printf '%s\n' 'LISTEN 0 5 127.0.0.1:21005 0.0.0.0:*' 'LISTEN 0 5 [::]:21005 [::]:* users:(("node",pid=42,fd=3))' \
    'LISTEN 0 5 0.0.0.0:21100 0.0.0.0:* users:(("x",pid=1,fd=3))' 'LISTEN 0 5 *:21099 *:*' > "$T/ss.out"
  out=$(PATH=$T/ss-shim:$PATH "$REPO/bin/sim" ports web --check); rc=$?
  check "ports --check: rc 1 with stub listeners" 1 "$rc"
  check "ports --check: one line per port, process where visible" \
    "$(printf '21005  users:(("node",pid=42,fd=3))\n21099  (process not visible)')" "$out"
  : > "$T/ss.out"
  out=$(PATH=$T/ss-shim:$PATH "$REPO/bin/sim" ports web --check); rc=$?
  check "ports --check: rc 0 when none listens" 0 "$rc"
  has "ports --check: says so" "none listening" "$out"
  kill "$holder" 2>/dev/null; pkill -P "$holder" 2>/dev/null; wait
)
( cd "$T/ws/app" || exit 1
  hold android "$T/ws/app" 30; holder=$!
  wait_for "( lib; sim_held android 1 )"
  has "env: exports the port block" "SIM_PORT_BASE=20000" "$("$REPO/bin/sim" env)"
  check "run: command sees the port block" "20000 100" "$("$REPO/bin/sim" run sh -c 'echo "$SIM_PORT_BASE $SIM_PORT_COUNT"')"
  kill "$holder" 2>/dev/null; pkill -P "$holder" 2>/dev/null; wait
)
