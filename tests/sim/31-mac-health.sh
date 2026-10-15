# shellcheck shell=bash
# Sourced by tests/sim-test.sh after tests/sim/harness.sh; see its header.
# shellcheck disable=SC2015,SC2016,SC2030,SC2031,SC2034,SC2154
echo "# mac health"
mac_reset() { rm -f "$T/ssh.down" "$T/simctl.list" "$T/state/ios/mac.state" "$T/log/"*; }
( lib; mac_reset
  sim_mac_probe; check "probe: up gives 0" 0 "$?"
  check "probe: caches up" up "$(cut -d' ' -f1 "$T/state/ios/mac.state")"
  log=$(cat "$T/log/ssh")
  has "probe: a connection of its own" "-o ControlMaster=no -o ControlPath=none -o ConnectTimeout=5" "$log"
  has "probe: runs true" "bob@mini.tail.ts.net true" "$log"
  sim_mac_probe; check "probe: a second probe within the TTL asks no one" 1 "$(wc -l < "$T/log/ssh")"
  sim_mac_probe --fresh; check "probe: --fresh asks again" 2 "$(wc -l < "$T/log/ssh")"
  touch "$T/ssh.down"
  sim_mac_probe; check "probe: the cached up stands within the TTL" 0 "$?"
  sim_mac_probe --fresh; check "probe: down gives 1" 1 "$?"
  check "probe: caches down" down "$(cut -d' ' -f1 "$T/state/ios/mac.state")"
  echo "up $(($(date +%s) - 31))" > "$T/state/ios/mac.state"
  sim_mac_probe; check "probe: an expired cache asks again" 1 "$?"
  ( AGENT_IOS_HOST=; sim_mac_probe ); check "probe: not configured gives 2" 2 "$?"
  ( AGENT_IOS_USER=; sim_mac_require ) 2>/dev/null; check "require: not configured exits 1" 1 "$?"
  err=$( (sim_mac_require) 2>&1); check "require: down exits 3" 3 "$?"
  has "require: says the Mac is unreachable" "sim: mac unreachable: bob@mini.tail.ts.net did not answer within 5 s (sim status)" "$err"
)
# a stale shared master is dropped when the probe finds the Mac down
if command -v python3 >/dev/null; then
  ( lib; mac_reset; mkdir -p "$T/state/ios"; touch "$T/ssh.down"
    python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$T/state/ios/ssh-feed"
    sim_mac_probe
    has "probe: down drops the shared master" "-o ControlPath=$T/state/ios/ssh-feed -O exit bob@mini.tail.ts.net" "$(cat "$T/log/ssh")"
    rm -f "$T/state/ios/ssh-feed" )
fi
( cd "$T/ws/app" || exit 1; mac_reset
  st=$("$REPO/bin/sim" status | grep '^ios ')
  has "status: ios off when the Mac answers" " off " "$st"
  check "status: one simctl list for all slots" 1 "$(grep -c 'simctl list devices' "$T/log/ssh")"
  printf '    agent-ios-1 (00000001-AAAA-4BBB-8CCC-DDDDDDDDDDDD) (Booted) \n' > "$T/simctl.list"
  has "status: ios booted" " booted " "$("$REPO/bin/sim" status | grep '^ios ')"
  touch "$T/ssh.down"
  st=$("$REPO/bin/sim" status | grep '^ios '); rc=$?
  has "status: ios unreachable while the Mac is down" " unreachable " "$st"
  lacks "status: never the old down word" " down " "$st"
  rm -f "$T/ssh.down" "$T/simctl.list" "$T/state/ios/mac.state"
  "$REPO/bin/sim" ios stop 1 >/dev/null
  has "status: off after sim ios stop 1" " off " "$("$REPO/bin/sim" status | grep '^ios ')"
  printf 'AGENT_HOST=box\nAGENT_SIM_IOS_SLOTS=1\n' > "$T/nomac.env"
  cp "$REPO/.env" "$T/env.keep"; cp "$T/nomac.env" "$REPO/.env"; rm -f "$T/log/ssh"
  st=$("$REPO/bin/sim" status | grep '^ios ')
  cp "$T/env.keep" "$REPO/.env"
  has "status: unconfigured without a Mac" " unconfigured " "$st"
  [ -e "$T/log/ssh" ] && bad "status: no ssh without a Mac" || ok "status: no ssh without a Mac"
)
( cd "$T/ws/app.wt/feat/client" || exit 1; mac_reset; touch "$T/ssh.down"
  hold ios "$T/ws/app.wt/feat" 10; holder=$!
  wait_for "( lib; sim_held ios 1 )"
  out=$("$REPO/bin/sim" maestro ios test x 2>&1); rc=$?
  check "maestro ios while down: rc 3" 3 "$rc"
  has "maestro ios while down: says so" "mac unreachable" "$out"
  [ -e "$T/log/rsync" ] && bad "maestro ios while down: nothing synced" || ok "maestro ios while down: nothing synced"
  "$REPO/bin/sim" metro start ios >/dev/null 2>&1; check "metro start ios while down: rc 3" 3 "$?"
  "$REPO/bin/sim" ios sync >/dev/null 2>&1; check "ios sync while down: rc 3" 3 "$?"
  "$REPO/bin/sim" ios gc >/dev/null 2>&1; check "ios gc while down: rc 3" 3 "$?"
  "$REPO/bin/sim" ios nope >/dev/null 2>&1; check "ios: an unknown action is still a usage error" 2 "$?"
  kill "$holder" 2>/dev/null; pkill -P "$holder" 2>/dev/null; wait
)
( mac_reset; mkdir -p "$T/state/ios"; rm -f "$T/state/ios/1.down"; touch "$T/ssh.down"
  touch -d '40 minutes ago' "$T/state/ios/1.active"
  "$REPO/bin/sim" reap > "$T/log/reap.out" 2> "$T/log/reap.err"
  check "reap while down: exactly one ssh call" 1 "$(wc -l < "$T/log/ssh")"
  check "reap while down: one line says so" 1 "$(grep -c 'ios: mini.tail.ts.net unreachable, next round tries again' "$T/log/reap.err")"
  [ -e "$T/state/ios/1.down" ] && bad "reap while down: the simulator is not marked off" || ok "reap while down: the simulator is not marked off"
  rm -f "$T/ssh.down" "$T/state/ios/mac.state"
  "$REPO/bin/sim" reap >/dev/null 2>&1
  [ -e "$T/state/ios/1.down" ] && ok "reap: the Mac back, the next round shuts it down" || bad "reap: the Mac back, the next round shuts it down"
)
( cd "$T/ws/app" || exit 1; mac_reset
  "$REPO/bin/sim" ios start 1 >/dev/null 2>&1
  log=$(grep bootstatus "$T/log/ssh")
  has "ssh: two missed keepalives end a dead link" "ServerAliveCountMax=2" "$log"
  has "ssh: short commands share a master" "ControlPath=$T/state/ios/ssh-%C" "$log"
  has "ssh: the master stays a minute" "ControlPersist=60" "$log"
  rm -f "$T/log/"*
  sleep 1 | "$REPO/bin/sim-mcp" ios 2>/dev/null; wait
  server=$(grep sim-xcodebuildmcp "$T/log/ssh")
  has "sim-mcp ios: the server's ssh is a connection of its own" "-o ControlMaster=no -o ControlPath=none -o BatchMode=yes" "$server"
  mac_reset; touch "$T/ssh.down"
  err=$(sleep 1 | "$REPO/bin/sim-mcp" ios 2>&1 >/dev/null); rc=$?
  check "sim-mcp ios while down: exit 1" 1 "$rc"
  has "sim-mcp ios while down: says mac unreachable" "mac unreachable" "$err"
  echo "up $(date +%s)" > "$T/state/ios/mac.state"
  sleep 1 | "$REPO/bin/sim-mcp" ios >/dev/null 2>&1; check "sim-mcp ios: probes fresh, never trusts the cache" 1 "$?"
  mac_reset
)
if [ -d "/run/user/$(id -u)" ] && [ -w "/run/user/$(id -u)" ]; then
  check "SIM_STATE default: /run/user/<uid>/agent-sim without XDG_RUNTIME_DIR" "/run/user/$(id -u)/agent-sim" \
    "$(env -u SIM_STATE -u XDG_RUNTIME_DIR bash -c '. "$1/lib/sim.sh"; echo "$SIM_STATE"' _ "$REPO")"
else
  echo "skip SIM_STATE default: /run/user/$(id -u) is absent"
fi
check "SIM_STATE default: XDG_RUNTIME_DIR first" "$T/xdg/agent-sim" \
  "$(env -u SIM_STATE XDG_RUNTIME_DIR="$T/xdg" bash -c '. "$1/lib/sim.sh"; echo "$SIM_STATE"' _ "$REPO")"
