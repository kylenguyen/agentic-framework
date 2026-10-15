# shellcheck shell=bash
# Sourced by tests/sim-test.sh after tests/sim/harness.sh; see its header.
# shellcheck disable=SC2015,SC2016,SC2030,SC2031,SC2154
echo "# ports and names"
( lib
  check "android 1: console port" 5600 "$(sim_android_port 1)"
  check "android 3: serial" emulator-5604 "$(sim_android_serial 3)"
  check "android 2: own adb server" 5039 "$(sim_adb_port 2)"
  check "android 1: Metro" 8101 "$(sim_metro_port android 1)"
  check "web 2: dev server" 8202 "$(sim_metro_port web 2)"
  check "ios 1: Metro on the default port" 8081 "$(sim_metro_port ios 1)"
  check "ios 2: Metro" 8091 "$(sim_metro_port ios 2)"
  check "ios 2: simulator name" agent-ios-2 "$(sim_ios_name 2)"
  check "tree name: checkout" app "$(sim_tree_name "$T/ws/app")"
  check "tree name: worktree" app-feat "$(sim_tree_name "$T/ws/app.wt/feat")"
  check "root: from a subdirectory" "$T/ws/app.wt/feat" "$(sim_root "$T/ws/app.wt/feat/client")"
  check "app dir: top level" . "$(sim_app_rel "$T/ws/app")"
  check "app dir: a monorepo's client" client "$(sim_app_rel "$T/ws/app.wt/feat/client")"
  sim_slots tv 2>/dev/null && bad "slots: rejects an unknown platform" || ok "slots: rejects an unknown platform"
)
