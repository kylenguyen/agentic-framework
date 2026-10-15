# shellcheck shell=bash
# Sourced by tests/sim-test.sh after tests/sim/harness.sh; see its header.
# shellcheck disable=SC2015,SC2016,SC2030,SC2031,SC2154
echo "# sim-mcp"
( cd "$T/ws/app" || exit 1; rm -f "$T/log/"*
  mkdir -p "$T/state/web/1.out"; touch "$T/state/web/1.out/old.png"
  sleep 2 | "$REPO/bin/sim-mcp" web 2> "$T/log/web.err" &
  wait_for '[ -s "$T/log/node.args" ]' || bad "web: server started" "$(cat "$T/log/web.err")"
  ( lib; sim_held web 1 ) && ok "web: slot held while the server runs" || bad "web: slot held while the server runs"
  has "web: Playwright MCP headless and isolated" "@playwright/mcp/cli.js --headless --isolated --browser chromium" "$(cat "$T/log/node.args")"
  has "web: lease banner on stderr" "web slot 1 leased" "$(cat "$T/log/web.err")"
  [ -e "$T/state/web/1.out/old.png" ] && bad "web: last lease's output cleared" || ok "web: last lease's output cleared"
  wait
  ( lib; sim_held web 1 ) && bad "web: slot freed when the server exits" || ok "web: slot freed when the server exits"
)
call='{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"x","arguments":{}}}'
init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
( cd "$T/ws/app" || exit 1; rm -f "$T/log/"* "$T/active" "$T/state/android/1.active"
  { printf '%s\n' "$init"; sleep 1; } | "$REPO/bin/sim-mcp" android 2>/dev/null; wait
  lacks "android: a lease alone starts no emulator" "start agent-sim-android" "$(cat "$T/log/systemctl" 2>/dev/null)"
  [ -e "$T/state/android/1.active" ] && bad "android: initialize is not use" || ok "android: initialize is not use"
  rm -f "$T/log/"*
  { printf '%s\n' "$init" "$call" "$call"; sleep 1; } | "$REPO/bin/sim-mcp" android 2> "$T/log/android.err"; wait
  check "android: the first tool call starts the emulator, once" 1 "$(grep -c 'start agent-sim-android@1.service' "$T/log/systemctl")"
  has "android: and waits for its boot" "getprop sys.boot_completed" "$(cat "$T/log/adb")"
  has "android: says why the call waits" "starting emulator-5600" "$(cat "$T/log/android.err")"
  check "android: messages reach the server unchanged" "$(printf '%s\n' "$init" "$call" "$call")" "$(cat "$T/log/node.in")"
  [ -e "$T/state/android/1.active" ] && ok "android: a tool call is use" || bad "android: a tool call is use"
  [ -e "$T/state/android/1.in" ] && bad "android: relay pipe removed" || ok "android: relay pipe removed"
  has "android: mobile-mcp" "@mobilenext/mobile-mcp/lib/index.js" "$(cat "$T/log/node.args")"
  has "android: the slot's own adb server" "ANDROID_ADB_SERVER_PORT=5038" "$(cat "$T/log/node.env")"
  has "android: telemetry off" "MOBILEMCP_DISABLE_TELEMETRY=1" "$(cat "$T/log/node.env")"
  has "android: a mobilecli daemon of the slot's own" "MOBILECLI_HOME=$T/state/android/1.mobilecli" "$(cat "$T/log/node.env")"
  check "android: that daemon stopped with the session" "daemon stop" "$(tail -1 "$T/log/mobilecli" 2>/dev/null)"
)
( cd "$T/ws/app" || exit 1; rm -f "$T/log/"*
  sleep 1 | "$REPO/bin/sim-mcp" ios 2>/dev/null; wait
  has "ios: launcher for slot 1 over ssh" "-T bob@mini.tail.ts.net .local/bin/sim-xcodebuildmcp 1" "$(cat "$T/log/ssh")"
  has "ios: BatchMode, never a prompt" "BatchMode=yes" "$(cat "$T/log/ssh")"
  lacks "ios: a lease alone boots nothing" "bootstatus" "$(cat "$T/log/ssh")"
  rm -f "$T/log/"*; touch "$T/state/ios/1.down"
  { printf '%s\n' "$init" "$call" "$call"; sleep 1; } | "$REPO/bin/sim-mcp" ios 2>/dev/null; wait
  check "ios: the first tool call boots the simulator, once" 1 "$(grep -c 'xcrun simctl bootstatus agent-ios-1 -b' "$T/log/ssh")"
  [ -e "$T/state/ios/1.down" ] && bad "ios: boot clears the down mark" || ok "ios: boot clears the down mark"
)
( "$REPO/bin/sim-mcp" tv 2>/dev/null; check "sim-mcp: unknown platform is a usage error" 2 "$?" )
( rm -f "$T/log/"*; c=$T/home/.cache/agent-sim/android/2
  mkdir -p "$c"; touch "$c/emulator-old.qcow2"
  "$REPO/bin/sim" android run 2 >/dev/null 2>&1
  has "android run: the slot's adb server first" "start-server" "$(cat "$T/log/adb")"
  has "android run: console above adb's scan range" "-read-only -port 5602" "$(cat "$T/log/emulator")"
  check "android run: scratch disks in the slot's cache dir" "$c" "$(cat "$T/log/emulator.tmp")"
  [ -e "$c/emulator-old.qcow2" ] && bad "android run: last run's scratch disks cleared" || ok "android run: last run's scratch disks cleared"
)
