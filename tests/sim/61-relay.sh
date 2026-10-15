# shellcheck shell=bash
# Sourced by tests/sim-test.sh after tests/sim/harness.sh; see its header.
# shellcheck disable=SC2015,SC2016,SC2030,SC2031,SC2154
echo "# relay (bin/sim-mcp-relay.mjs, sim _wake)"
r_init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
r_call='{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"x","arguments":{}}}'
r_ping='{"jsonrpc":"2.0","id":3,"method":"ping"}'
r_unit=agent-sim-android@1.service
# line_of <text> <file>: the number of the first line of <file> that is exactly <text>, or 0
line_of() { grep -nxF -- "$1" "$2" 2>/dev/null | head -1 | cut -d: -f1 | grep . || echo 0; }

( cd "$T/ws/app" || exit 1; rm -f "$T/log/"* "$T/active"; touch "$T/systemctl.fail"
  { printf '%s\n' "$r_init" "$r_call"; sleep 1; } | "$REPO/bin/sim-mcp" android > "$T/log/out" 2> "$T/log/err"; wait
  rm -f "$T/systemctl.fail"
  reply=$(jq -c 'select(.id == 2)' "$T/log/out" 2>/dev/null)
  check "wake fails: the call gets a tool error" true "$(jq -r '.result.isError' <<< "$reply" 2>/dev/null)"
  has "wake fails: its text says why" "sim: could not start $r_unit" "$(jq -r '.result.content[0].text' <<< "$reply" 2>/dev/null)"
  check "wake fails: the call never reaches the server" "$r_init" "$(cat "$T/log/node.in")"
  has "wake fails: the reason is on stderr too" "could not start" "$(cat "$T/log/err")"
)
( cd "$T/ws/app" || exit 1; rm -f "$T/log/"* "$T/state/ios/mac.state"
  rm -f "$T/ios.in"; mkfifo "$T/ios.in"; sleep 3 > "$T/ios.in" &      # holds the fifo open: EOF after 3 s
  "$REPO/bin/sim-mcp" ios < "$T/ios.in" > "$T/log/out" 2>/dev/null &
  wait_for '[ -s "$T/log/ssh" ] && grep -q sim-xcodebuildmcp "$T/log/ssh"'
  touch "$T/ssh.down"; rm -f "$T/state/ios/mac.state"
  printf '%s\n' "$r_call" > "$T/ios.in"
  wait_for 'grep -q "\"id\":2" "$T/log/out"'
  rm -f "$T/ssh.down" "$T/state/ios/mac.state"
  reply=$(jq -c 'select(.id == 2)' "$T/log/out" 2>/dev/null)
  check "ios, Mac gone: the call gets a tool error" true "$(jq -r '.result.isError' <<< "$reply" 2>/dev/null)"
  has "ios, Mac gone: its text says so" "sim: mac unreachable: bob@mini.tail.ts.net" "$(jq -r '.result.content[0].text' <<< "$reply" 2>/dev/null)"
  wait; rm -f "$T/ios.in"
)
( cd "$T/ws/app" || exit 1; rm -f "$T/log/"* "$T/active"; echo 2 > "$T/wake.delay"
  { printf '%s\n' "$r_init" "$r_call"; sleep 0.5; printf '%s\n' "$r_ping"; sleep 3; } \
    | "$REPO/bin/sim-mcp" android > /dev/null 2>&1; wait
  rm -f "$T/wake.delay"
  p=$(line_of "$r_ping" "$T/log/node.in"); c=$(line_of "$r_call" "$T/log/node.in")
  [ "$p" -gt 0 ] && [ "$c" -gt "$p" ] && ok "slow wake: a ping overtakes the waiting call" \
    || bad "slow wake: a ping overtakes the waiting call" "$(cat "$T/log/node.in")"
)
( cd "$T/ws/app" || exit 1; rm -f "$T/log/"*; echo "$r_unit" > "$T/active"; echo 0 > "$T/boot"
  ( sleep 1.5; echo 1 > "$T/boot" ) &
  { printf '%s\n' "$r_init" "$r_call"; sleep 3; } | "$REPO/bin/sim-mcp" android > /dev/null 2>&1 &
  sleep 1
  check "restarted unit: the call waits while it is not booted" "$r_init" "$(cat "$T/log/node.in" 2>/dev/null)"
  wait
  rm -f "$T/boot" "$T/active"
  check "restarted unit: and is forwarded once it has booted" "$(printf '%s\n' "$r_init" "$r_call")" "$(cat "$T/log/node.in")"
  lacks "restarted unit: an active unit is not started again" "start $r_unit" "$(cat "$T/log/systemctl")"
)
( cd "$T/ws/app" || exit 1; rm -f "$T/log/"* "$T/active" "$T/state/android/1.active"
  m='{"jsonrpc":"2.0","id":4,"method":"resources/read","params":{"uri":"tools/call","x":"\"method\":\"tools/call\""}}'
  { printf '%s\n' "$r_init" "$m"; sleep 1; } | "$REPO/bin/sim-mcp" android > /dev/null 2>&1; wait
  lacks "\"tools/call\" in another method's arguments: no wake" "start" "$(cat "$T/log/systemctl" 2>/dev/null)"
  [ -e "$T/state/android/1.active" ] && bad "\"tools/call\" in another method's arguments: not use" \
    || ok "\"tools/call\" in another method's arguments: not use"
  check "\"tools/call\" in another method's arguments: forwarded at once" "$(printf '%s\n' "$r_init" "$m")" "$(cat "$T/log/node.in")"
)
( cd "$T/ws/app" || exit 1; rm -f "$T/log/"*
  big=$(head -c 786432 /dev/urandom | base64 -w0)
  { printf '{"jsonrpc":"2.0","method":"notifications/big","params":{"data":"%s"}}\n' "$big"
    printf '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"big","arguments":{"data":"%s"}}}\n' "$big"; } > "$T/big.in"
  { cat "$T/big.in"; sleep 1; } | "$REPO/bin/sim-mcp" web > /dev/null 2>&1; wait
  [ "$(stat -c %s "$T/big.in")" -gt 2000000 ] && ok "large message: two 1 MB lines sent" || bad "large message: two 1 MB lines sent"
  check "large message: reaches the server byte for byte" "$(sha256sum < "$T/big.in")" "$(sha256sum < "$T/log/node.in")"
  rm -f "$T/big.in"
)
# A server that leaves a grandchild behind (sleep 300 &), as an npx or adb helper would.
printf '#!/bin/sh\necho $$ > "%s/log/server.pid"\nsleep 300 &\necho $! > "%s/log/grandchild.pid"\ncat > /dev/null\n' "$T" "$T" > "$T/shims/leaky"
# A server that does not exit on EOF.
printf '#!/bin/sh\necho $$ > "%s/log/server.pid"\ntrap "" TERM\nwhile :; do sleep 0.2; done\n' "$T" > "$T/shims/stubborn"
chmod +x "$T/shims/leaky" "$T/shims/stubborn"
gone() { ! kill -0 "$(cat "$1" 2>/dev/null || echo 999999)" 2>/dev/null; }
( cd "$T/ws/app" || exit 1; rm -f "$T/log/"*; export SIM_NODE=$T/shims/leaky
  sleep 2 | "$REPO/bin/sim-mcp" web 2>/dev/null &
  wait_for '[ -s "$T/log/grandchild.pid" ]'
  check "process group: the pgid file holds the server's group while it runs" "$(cat "$T/log/server.pid")" \
    "$(cat "$T/state/web/1.pgid" 2>/dev/null)"
  wait
  [ -e "$T/state/web/1.pgid" ] && bad "process group: pgid file removed at the end" || ok "process group: pgid file removed at the end"
  gone "$T/log/grandchild.pid" && ok "process group: a grandchild dies with the session (EOF)" \
    || { bad "process group: a grandchild dies with the session (EOF)"; kill "$(cat "$T/log/grandchild.pid")"; }
)
( cd "$T/ws/app" || exit 1; rm -f "$T/log/"*; export SIM_NODE=$T/shims/leaky
  sleep 30 | "$REPO/bin/sim-mcp" web 2>/dev/null &
  mcp=$!
  wait_for '[ -s "$T/log/grandchild.pid" ]'
  kill -TERM "$mcp"
  wait_for '! kill -0 "$mcp" 2>/dev/null' && ok "process group: sim-mcp ends on TERM" || bad "process group: sim-mcp ends on TERM"
  gone "$T/log/grandchild.pid" && ok "process group: a grandchild dies when sim-mcp is TERMed" \
    || { bad "process group: a grandchild dies when sim-mcp is TERMed"; kill "$(cat "$T/log/grandchild.pid")"; }
  gone "$T/log/server.pid" && ok "process group: so does the server" || bad "process group: so does the server"
  ( lib; sim_held web 1 ) && bad "process group: the slot is free after TERM" || ok "process group: the slot is free after TERM"
  pkill -P "$BASHPID" -x sleep 2>/dev/null; wait
)
( cd "$T/ws/app" || exit 1; rm -f "$T/log/"*; export SIM_NODE=$T/shims/stubborn
  SECONDS=0
  : | "$REPO/bin/sim-mcp" web 2>/dev/null; wait
  gone "$T/log/server.pid" && ok "process group: a server deaf to EOF and TERM is killed" \
    || { bad "process group: a server deaf to EOF and TERM is killed"; kill -9 "$(cat "$T/log/server.pid")"; }
  [ "$SECONDS" -ge 5 ] && [ "$SECONDS" -le 14 ] && ok "process group: ...after the grace periods" \
    || bad "process group: ...after the grace periods" "${SECONDS}s"
)
( cd "$T/ws/app" || exit 1; rm -f "$T/log/"* "$T/state/ios/1.booted" "$T/state/ios/1.down"
  "$REPO/bin/sim" _wake ios 1 2>/dev/null; check "_wake ios: exit 0" 0 "$?"
  "$REPO/bin/sim" _wake ios 1 2>/dev/null
  check "_wake ios: boots once, then trusts the booted mark" 1 "$(grep -c 'simctl bootstatus agent-ios-1' "$T/log/ssh")"
  "$REPO/bin/sim" ios stop 1 >/dev/null 2>&1
  [ -e "$T/state/ios/1.booted" ] && bad "_wake ios: sim ios stop removes the booted mark" || ok "_wake ios: sim ios stop removes the booted mark"
  "$REPO/bin/sim" _wake ios 1 2>/dev/null
  check "_wake ios: boots again after a stop" 2 "$(grep -c 'simctl bootstatus agent-ios-1' "$T/log/ssh")"
  touch "$T/ssh.down"; rm -f "$T/state/ios/mac.state"
  err=$("$REPO/bin/sim" _wake ios 1 2>&1); rc=$?
  rm -f "$T/ssh.down" "$T/state/ios/mac.state"
  check "_wake ios: the Mac gone is exit 3" 3 "$rc"
  has "_wake ios: ...and says so" "sim: mac unreachable: bob@mini.tail.ts.net" "$err"
  "$REPO/bin/sim" _wake web 1; check "_wake web: exit 0" 0 "$?"
  "$REPO/bin/sim" _wake tv 1 2>/dev/null; check "_wake: unknown platform is a usage error" 2 "$?"
  lacks "_wake: not in the usage text" "_wake" "$("$REPO/bin/sim" 2>&1)"
  rm -f "$T/state/ios/1.down" "$T/state/ios/1.booted"
)
