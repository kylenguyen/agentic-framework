# shellcheck shell=bash
# Sourced by tests/sim-test.sh after tests/sim/harness.sh; see its header.
# shellcheck disable=SC2015,SC2016,SC2030,SC2031,SC2034,SC2154
echo "# sim doctor and recovery"
# Canned answers: $T/doctor/{systemctl.show,ps,mac} (harness shims), /proc stand-ins for the host checks, df and
# playwright stubs. A healthy android slot 1 is active, booted, one Maestro driver, a live mobilecli daemon.
doc_reset() {
  rm -rf "$T/doctor" "$T/log/"* "${T:?}/boot" "$T/ssh.down" "$T/state/ios/mac.state" "$HOME/.cache/agent-sim/android/maestro-1"
  mkdir -p "$T/doctor/proc" "$T/state/android/1.mobilecli"
  printf 'MemTotal:       32000000 kB\nMemAvailable:   12000000 kB\n' > "$T/doctor/proc/meminfo"
  echo '0.50 0.40 0.30 1/200 999' > "$T/doctor/proc/loadavg"
  printf 'ActiveEnterTimestamp=%s\nNRestarts=0\n' "$(date -d '1 hour ago' '+%a %Y-%m-%d %H:%M:%S %Z')" > "$T/doctor/systemctl.show"
  printf 'NAME\ninit\ndev.mobile.maestro\nsystem_server\n' > "$T/doctor/ps"
  printf '{"pid":%s,"version":"1.0.16"}\n' "$$" > "$T/state/android/1.mobilecli/daemon.pid"
  printf 'launcher=2\nxcodebuildmcp=2.7.0\nmaestro=2.11.0\nruntime=iOS 26.0\ndisk=52428800\ndevice=agent-ios-1 Shutdown\n' > "$T/doctor/mac"
  echo agent-sim-android@1.service > "$T/active"
  rm -f "$T/state/android/1.active" "$T/state/ios/1.active"
}
printf '#!/bin/sh\necho "Filesystem 1024-blocks Used Available Capacity Mounted"\necho "/dev/x 100000000 50000000 52428800 50%% /"\n' > "$T/shims/df"
printf '#!/bin/sh\nprintf "  Install location:    %%s\\n" "%s/pw/chromium-1" "%s/pw/webkit-2"\n' "$T" "$T" > "$T/prefix/node_modules/.bin/playwright"
chmod +x "$T/shims/df" "$T/prefix/node_modules/.bin/playwright"
export SIM_PROC=$T/doctor/proc
run1() { # run1 <name> <runs-dir content>: a kept Maestro run on android slot 1 with a Maestro log line
  local d=$HOME/.cache/agent-sim/android/maestro-1/runs/$1
  mkdir -p "$d/debug"; printf '%s\n' "$2" > "$d/debug/maestro.log"; : > "$d/logcat.txt"
}

( cd "$T/ws/app.wt/feat/client" || exit 1; doc_reset
  out=$("$REPO/bin/sim" doctor 2>&1); rc=$?
  check "doctor: nothing leased is rc 1" 1 "$rc"
  has "doctor: says how to check every slot" "sim doctor all" "$out"
  "$REPO/bin/sim" doctor tv >/dev/null 2>&1; check "doctor: an unknown platform is a usage error" 2 "$?"
  "$REPO/bin/sim" doctor android 7 >/dev/null 2>&1; check "doctor: a slot out of range is a usage error" 2 "$?"
  "$REPO/bin/sim" doctor all 1 >/dev/null 2>&1; check "doctor: all takes no slot" 2 "$?"

  hold android "$T/ws/app.wt/feat" 30; holder=$!
  wait_for "( lib; sim_held android 1 )"
  run1 20261015-100000 'flow passed'
  out=$("$REPO/bin/sim" doctor 2>&1); rc=$?
  check "doctor healthy: rc 0" 0 "$rc"
  lacks "doctor healthy: no warn" "warn " "$out"
  lacks "doctor healthy: no fail" "fail " "$out"
  has "doctor healthy: unit and uptime" "ok    android 1  unit           active, up 1h" "$out"
  has "doctor healthy: no restarts" "android 1  restarts       0" "$out"
  has "doctor healthy: booted" "sys.boot_completed=1" "$out"
  has "doctor healthy: adb round trip" "android 1  adb            round trip " "$out"
  has "doctor healthy: one instrumentation client" "instrumentation dev.mobile.maestro" "$out"
  has "doctor healthy: mobilecli daemon alive" "mobilecli      daemon pid $$" "$out"
  has "doctor healthy: no driver deaths" "driver-deaths  none in the last 1 runs" "$out"
  has "doctor healthy: host memory" "ok    host    -  memory         11.4 GB available" "$out"
  has "doctor healthy: host load" "0.50 on $(nproc) cores" "$out"
  has "doctor healthy: host disk" "50.0 GB free for $HOME/.cache/agent-sim" "$out"
  lacks "doctor healthy: only this worktree's slots" "ios" "$out"
  lacks "doctor: read-only, no start or stop" "start" "$(grep -E ' (start|stop) ' "$T/log/systemctl")"
  [ -e "$T/state/android/1.active" ] && bad "doctor: a check is not use" || ok "doctor: a check is not use"
  has "doctor: asks the slot's adb server" "shell ps -A -o NAME" "$(cat "$T/log/adb")"

  doc_reset; sed -i 's/^NRestarts=0/NRestarts=2/' "$T/doctor/systemctl.show"
  out=$("$REPO/bin/sim" doctor android 2>&1); rc=$?
  has "doctor: NRestarts=2 warns" "warn  android 1  restarts       2" "$out"
  check "doctor: a warning alone is rc 0" 0 "$rc"

  doc_reset; echo 0 > "$T/boot"
  out=$("$REPO/bin/sim" doctor android 1 2>&1); rc=$?
  has "doctor: boot_completed 0 fails" "fail  android 1  boot           sys.boot_completed=0" "$out"
  check "doctor: a fail is rc 1" 1 "$rc"
  rm -f "$T/boot"

  doc_reset; printf 'NAME\ndev.mobile.maestro\r\nuiautomator\r\n' > "$T/doctor/ps"
  out=$("$REPO/bin/sim" doctor android 2>&1)
  has "doctor: two instrumentation clients warn" "warn  android 1  instrumentation 2 clients: dev.mobile.maestro uiautomator" "$out"

  doc_reset
  run1 20261015-090000 'flow passed'
  run1 20261015-100000 "$(printf 'DeviceServerDiedException: Device server died during viewHierarchy\nretry\nmaestro.DeviceServerDiedException')"
  echo '10-15 10:00:01 E AndroidRuntime: FATAL EXCEPTION: main' > "$HOME/.cache/agent-sim/android/maestro-1/runs/20261015-100000/logcat.txt"
  out=$("$REPO/bin/sim" doctor android 2>&1)
  has "doctor: driver deaths in a run's log warn with the count" "warn  android 1  driver-deaths  2 in 1 of the last 2 runs" "$out"
  has "doctor: crashes in logcat.txt warn" "warn  android 1  device-crashes 1 FATAL" "$out"
  run1 20261015-080000 'DeviceServerDiedException'
  out=$(AGENT_SIM_KEEP_RUNS=2 "$REPO/bin/sim" doctor android 2>&1)
  has "doctor: only the last AGENT_SIM_KEEP_RUNS runs count" "2 in 1 of the last 2 runs" "$out"

  doc_reset; : > "$T/active"
  out=$("$REPO/bin/sim" doctor android 2>&1); rc=$?
  has "doctor: an idle emulator is ok" "ok    android 1  unit           inactive" "$out"
  [ -e "$T/log/adb" ] && bad "doctor: no adb while the unit is down (it would start a server)" "$(cat "$T/log/adb")" \
    || ok "doctor: no adb while the unit is down (it would start a server)"
  check "doctor: idle is rc 0" 0 "$rc"

  doc_reset; echo '{"pid":999999999}' > "$T/state/android/1.mobilecli/daemon.pid"
  has "doctor: a dead mobilecli daemon warns" "warn  android 1  mobilecli      daemon pid 999999999 is gone" "$("$REPO/bin/sim" doctor android 2>&1)"

  doc_reset; printf 'MemAvailable:   500000 kB\n' > "$T/doctor/proc/meminfo"; echo '40.00 1 1 1/1 1' > "$T/doctor/proc/loadavg"
  out=$("$REPO/bin/sim" doctor android 2>&1); rc=$?
  has "doctor: low memory fails" "fail  host    -  memory         0.5 GB available" "$out"
  has "doctor: load above the cores warns" "warn  host    -  load           40.00 on" "$out"
  check "doctor: low memory is rc 1" 1 "$rc"
  kill "$holder" 2>/dev/null; pkill -P "$holder" 2>/dev/null; wait
)

( cd "$T/ws/app" || exit 1; doc_reset; mkdir -p "$T/pw/chromium-1" "$T/pw/webkit-2"
  out=$("$REPO/bin/sim" doctor web all 2>&1); rc=$?
  has "doctor web: browsers installed" "ok    web     1  browsers       chromium-1, webkit-2" "$out"
  has "doctor web: every slot" "web     2  browsers" "$out"
  check "doctor web: rc 0" 0 "$rc"
  rmdir "$T/pw/webkit-2"
  out=$("$REPO/bin/sim" doctor web 1 2>&1); rc=$?
  has "doctor web: a missing browser fails" "fail  web     1  browsers       missing webkit-2 (install-host.sh)" "$out"
  check "doctor web: rc 1" 1 "$rc"
)

( cd "$T/ws/app" || exit 1; doc_reset
  out=$("$REPO/bin/sim" doctor ios 1 2>&1); rc=$?
  check "doctor ios healthy: rc 0" 0 "$rc"
  has "doctor ios: probe and round trip" "ok    ios     1  mac            mini.tail.ts.net up, answered in " "$out"
  has "doctor ios: launcher contract" "ok    ios     1  launcher       sim-maestro contract 2" "$out"
  has "doctor ios: xcodebuildmcp pin" "ok    ios     1  xcodebuildmcp  2.7.0" "$out"
  has "doctor ios: maestro pin" "ok    ios     1  maestro        2.11.0" "$out"
  has "doctor ios: runtime" "ok    ios     1  runtime        iOS 26.0" "$out"
  has "doctor ios: simulator and state" "ok    ios     1  simulator      agent-ios-1 Shutdown" "$out"
  has "doctor ios: disk" "ok    ios     1  disk           50.0 GB free" "$out"
  lacks "doctor ios: no tunnel line without a pidfile" "tunnel" "$out"
  lacks "doctor ios: no host lines for ios alone" "host" "$out"
  lacks "doctor ios: read-only, never boots" "bootstatus" "$(cat "$T/log/ssh")"
  sleep 300 & tp=$!
  printf 'pid=%s\nports=22001,22002\nroot=%s\n' "$tp" "$T/ws/app" > "$T/state/ios/1.tunnel"
  has "doctor ios: a live tunnel" "ok    ios     1  tunnel         ports 22001,22002, pid $tp" "$("$REPO/bin/sim" doctor ios 1 2>&1)"
  kill "$tp"; wait "$tp" 2>/dev/null
  has "doctor ios: a stale tunnel pidfile warns" "warn  ios     1  tunnel" "$("$REPO/bin/sim" doctor ios 1 2>&1)"
  rm -f "$T/state/ios/1.tunnel"
  sed -i 's/^launcher=2/launcher=1/; s/^maestro=.*/maestro=2.10.0/; s/^disk=.*/disk=1048576/' "$T/doctor/mac"
  out=$("$REPO/bin/sim" doctor ios 1 2>&1); rc=$?
  has "doctor ios: an old launcher fails with the bootstrap hint" "fail  ios     1  launcher       sim-maestro contract 1, sim needs 2: sim ios bootstrap" "$out"
  has "doctor ios: a maestro off the pin warns" "warn  ios     1  maestro        2.10.0, pinned 2.11.0: sim ios bootstrap" "$out"
  has "doctor ios: under 15 GB free warns" "warn  ios     1  disk           1.0 GB free, under 15 GB" "$out"
  check "doctor ios: old launcher is rc 1" 1 "$rc"
  doc_reset; sed -i '/^device=/d' "$T/doctor/mac"
  has "doctor ios: a missing simulator fails" "fail  ios     1  simulator      no agent-ios-1 on the Mac: sim ios bootstrap" "$("$REPO/bin/sim" doctor ios 1 2>&1)"
  doc_reset; touch "$T/ssh.down"
  out=$("$REPO/bin/sim" doctor ios 1 2>&1); rc=$?
  has "doctor ios: Mac down fails unreachable" "fail  ios     1  mac            unreachable: bob@mini.tail.ts.net" "$out"
  check "doctor ios: Mac down is rc 1" 1 "$rc"
  check "doctor ios: Mac down, one line only" 1 "$(grep -c ios <<<"$out")"
  doc_reset
)

( cd "$T/ws/app" || exit 1; doc_reset
  out=$("$REPO/bin/sim" doctor all 2>&1)
  check "doctor all: host lines once" 3 "$(awk '$2 == "host"' <<<"$out" | wc -l)"
  check "doctor all: every slot" "android 1|android 2|ios 1|web 1|web 2" "$(awk '$2 != "host" {print $2, $3}' <<<"$out" | sort -u | paste -sd'|')"
)

# Recovery: sim android restart, sim maestro --fresh and --cold
( cd "$T/ws/app" || exit 1; doc_reset
  out=$("$REPO/bin/sim" android restart 1 2>&1); rc=$?
  check "restart: rc 0" 0 "$rc"
  check "restart: stop then start" "stop agent-sim-android@1.service|start agent-sim-android@1.service" \
    "$(grep -E ' (start|stop) ' "$T/log/systemctl" | sed 's/^--user //' | paste -sd'|')"
  has "restart: stops the slot's mobilecli daemon" "daemon stop" "$(cat "$T/log/mobilecli")"
  has "restart: waits for the boot" "wait-for-device" "$(cat "$T/log/adb")"
  has "restart: says the app is gone" "emulator-5600 restarted cold; the app is gone, run sim build" "$out"
  "$REPO/bin/sim" android restart >/dev/null 2>&1; check "restart: no slot is a usage error" 2 "$?"
  doc_reset; rm -f "$T/active"
  out=$("$REPO/bin/sim" android restart all 2>&1)
  check "restart all: every slot" 2 "$(grep -c 'restarted cold' <<<"$out")"
)
( cd "$T/ws/app.wt/feat/client" || exit 1; doc_reset
  hold android "$T/ws/app.wt/feat" 30; holder=$!
  wait_for "( lib; sim_held android 1 )"
  "$REPO/bin/sim" maestro android test --fresh flows/ >/dev/null 2>&1
  has "--fresh: force-stops Maestro's driver" "am force-stop dev.mobile.maestro; am force-stop dev.mobile.maestro.test; pkill uiautomator" "$(cat "$T/log/adb")"
  run=$(grep -- '--name agent-sim-maestro-1 ' "$T/log/docker")
  lacks "--fresh: not passed to Maestro" "--fresh" "$run"
  has "--fresh: the rest is" "/output flows/" "$run"
  lacks "--fresh: no restart" "stop" "$(cat "$T/log/systemctl")"
  doc_reset
  "$REPO/bin/sim" maestro android --cold test flows/ >/dev/null 2>"$T/log/cold.err"
  check "--cold android: restart (stop, start) before the run" "stop agent-sim-android@1.service|start agent-sim-android@1.service" \
    "$(grep -E ' (start|stop) ' "$T/log/systemctl" | sed 's/^--user //' | paste -sd'|')"
  check "--cold android: says so before the run" "restarted cold|maestro run" \
    "$(grep -oE 'restarted cold|maestro run' "$T/log/cold.err" | paste -sd'|')"
  lacks "--cold: not passed to Maestro" "--cold" "$(grep -- '--name agent-sim-maestro-1 ' "$T/log/docker")"
  kill "$holder" 2>/dev/null; pkill -P "$holder" 2>/dev/null; wait
)
( cd "$T/ws/app.wt/feat/client" || exit 1; doc_reset; rm -rf "$T/state/ios/1.down"
  hold ios "$T/ws/app.wt/feat" 30; holder=$!
  wait_for "( lib; sim_held ios 1 )"
  "$REPO/bin/sim" maestro ios --cold --fresh test flows/ >/dev/null 2>"$T/log/ios.err"
  log=$(grep -nE 'simctl shutdown agent-ios-1|bootstatus agent-ios-1|simctl terminate agent-ios-1 dev.mobile.maestro-driver-iosUITests.xctrunner|sim-maestro 1 ' "$T/log/ssh" \
    | sed -E 's/^[0-9]+://; s/.*(shutdown|bootstatus|terminate|sim-maestro 1).*/\1/' | paste -sd'|')
  check "--cold --fresh ios: shutdown, boot, terminate the driver, then the run" "shutdown|bootstatus|terminate|sim-maestro 1" "$log"
  run=$(grep 'sim-maestro 1 ' "$T/log/ssh")
  lacks "--fresh ios: not passed to Maestro" "--fresh" "$run"
  lacks "--cold ios: not passed to Maestro" "--cold" "$run"
  has "--cold ios: says the app stays" "the app stays installed" "$(cat "$T/log/ios.err")"
  kill "$holder" 2>/dev/null; pkill -P "$holder" 2>/dev/null; wait
)
rm -f "$T/shims/df" "$T/prefix/node_modules/.bin/playwright"; unset SIM_PROC
