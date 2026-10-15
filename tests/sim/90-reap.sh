# shellcheck shell=bash
# Sourced by tests/sim-test.sh after tests/sim/harness.sh; see its header.
# shellcheck disable=SC2015,SC2016,SC2030,SC2031,SC2154
echo "# reap"
( lib; rm -rf "$T/state/android" "$T/state/web" "$T/state/ios" "$T/log/"*; mkdir -p "$T/state/android" "$T/state/web" "$T/state/ios"
  printf 'agent-sim-android@1.service\nagent-sim-android@2.service\n' > "$T/active"
  out=$("$REPO/bin/sim" reap)
  check "reap: slots never used start their clock, nothing stopped" "" "$out"
  [ -e "$T/state/android/2.active" ] && [ -e "$T/state/ios/1.active" ] && ok "reap: clock files made" || bad "reap: clock files made"
  touch -d '40 minutes ago' "$T/state/android/1.active" "$T/state/ios/1.active" "$T/state/web/1.active"
  touch -d '10 minutes ago' "$T/state/android/2.active"
  setsid sleep 60 & metro=$!; echo "$metro" > "$T/state/web/1.metro"
  out=$("$REPO/bin/sim" reap)
  has "reap: idle emulator stopped" "android 1: emulator stopped, unused for 40 min" "$out"
  lacks "reap: emulator in use kept" "android 2" "$out"
  check "reap: only that unit" "agent-sim-android@2.service" "$(cat "$T/active")"
  has "reap: idle iOS simulator shut down" "xcrun simctl shutdown agent-ios-1" "$(cat "$T/log/ssh")"
  has "reap: with its Metro on the Mac" "pkill -f 'expo start.*--port 8081'" "$(cat "$T/log/ssh")"
  [ -e "$T/state/ios/1.down" ] && ok "reap: iOS marked down" || bad "reap: iOS marked down"
  has "reap: idle web Metro stopped" "web 1: Metro stopped" "$out"
  wait_for "! kill -0 $metro 2>/dev/null" && ok "reap: that Metro is gone" || bad "reap: that Metro is gone"
  rm -f "$T/log/ssh"; out=$("$REPO/bin/sim" reap)
  check "reap: second round has nothing to do" "" "$out"
  [ -e "$T/log/ssh" ] && bad "reap: the Mac is asked once per idle spell" || ok "reap: the Mac is asked once per idle spell"
  st=$("$REPO/bin/sim" status)
  has "status: minutes since use" "used 40m ago" "$(echo "$st" | grep '^android  1')"
  has "status: iOS down" "down" "$(echo "$st" | grep '^ios      1')"
  touch -d '2 hours ago' "$T/state/android/2.active"
  out=$(AGENT_SIM_IDLE_MINUTES=0 "$REPO/bin/sim" reap)
  check "reap: idle minutes 0 never stops" "agent-sim-android@2.service" "$(cat "$T/active")"
)
( rm -f "$T/log/"*
  out=$("$REPO/bin/sim" ios start 1)
  has "ios start: boots and waits" "xcrun simctl bootstatus agent-ios-1 -b" "$(cat "$T/log/ssh")"
  [ -e "$T/state/ios/1.down" ] && bad "ios start: clears the down mark" || ok "ios start: clears the down mark"
  "$REPO/bin/sim" ios stop all >/dev/null
  has "ios stop all: shuts down" "xcrun simctl shutdown agent-ios-1" "$(cat "$T/log/ssh")"
  [ -e "$T/state/ios/1.down" ] && ok "ios stop: marks it down" || bad "ios stop: marks it down"
  "$REPO/bin/sim" ios stop 2 2>/dev/null; check "ios stop: no such slot is a usage error" 2 "$?"
  "$REPO/bin/sim" android start 3 2>/dev/null; check "android start: no such slot is a usage error" 2 "$?"
  rm -f "$T/log/"*; "$REPO/bin/sim" ios bootstrap >/dev/null 2>&1
  has "ios bootstrap: passes the Maestro version" "SIM_MAESTRO_VERSION=2.11.0 SIM_MAESTRO_SHA256=5384593c" "$(cat "$T/log/ssh")"
  rm -f "$T/log/"*; "$REPO/bin/sim" ios gc >/dev/null 2>&1
  has "ios gc: prunes Maestro's debug output too" ".cache/agent-sim" "$(cat "$T/log/ssh")"
)
( "$REPO/bin/sim" nope 2>/dev/null; check "sim: unknown command is a usage error" 2 "$?" )
