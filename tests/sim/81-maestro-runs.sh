# shellcheck shell=bash
# Sourced by tests/sim-test.sh after tests/sim/harness.sh; see its header.
# shellcheck disable=SC2015,SC2016,SC2030,SC2031,SC2154
echo "# sim maestro: run directories, output copy-back, logcat"
# Shims of this file only, ahead of the harness's on PATH inside each case:
# rsync pulling a run back from the Mac drops artifacts/client/e2e/report.xml and artifacts/client/out/a.txt into it
# (or fails as a dropped link does while $T/rsync.fail exists); docker running Maestro waits until the run's
# background `adb logcat -v threadtime` has started, as a real run that takes seconds would, then defers to the
# harness's shim.
mkdir -p "$T/shims81"
cat > "$T/shims81/rsync" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$T/log/rsync"
for d; do :; done
case "\$*" in
  *:.cache/agent-sim/maestro-*)
    [ -e "$T/rsync.fail" ] && { echo "rsync: connection unexpectedly closed (0 bytes received so far)" >&2; exit 12; }
    mkdir -p "\$d/artifacts/client/e2e" "\$d/artifacts/client/out" "\$d/debug"
    echo '<testsuites/>' > "\$d/artifacts/client/e2e/report.xml"; echo a > "\$d/artifacts/client/out/a.txt"
    echo log > "\$d/debug/maestro.log" ;;
esac
exit 0
EOF
cat > "$T/shims81/docker" <<EOF
#!/bin/sh
case "\$1 \$*" in
  "run "*" -d "*) ;;
  run*) i=0; until grep -q 'logcat -v threadtime' "$T/log/adb" 2>/dev/null || [ \$i -ge 50 ]; do sleep 0.1; i=\$((i + 1)); done ;;
esac
exec "$T/shims/docker" "\$@"
EOF
chmod +x "$T/shims81/"*
runs_of() { find "$1/runs" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort -V | paste -sd' '; }

( PATH=$T/shims81:$PATH; cd "$T/ws/app.wt/feat/client" || exit 1; rm -rf "$T/log/"* "$T/state/android" "$HOME/.cache/agent-sim/android"
  home=$HOME/.cache/agent-sim/android/maestro-1
  hold android "$T/ws/app.wt/feat" 30; holder=$!
  wait_for "( lib; sim_held android 1 )"
  echo 1 > "$T/docker.rc"
  "$REPO/bin/sim" maestro android test flows/ >/dev/null 2>"$T/log/err1"; rc=$?
  check "runs android: the rc is still Maestro's" 1 "$rc"
  echo 0 > "$T/docker.rc"
  "$REPO/bin/sim" maestro android test flows/ >/dev/null 2>"$T/log/err2"
  read -r r1 r2 rest <<< "$(runs_of "$home")"
  [ -n "$r1" ] && [ -n "$r2" ] && [ -z "$rest" ] && ok "runs: two runs make two directories" || bad "runs: two runs make two directories" "$(runs_of "$home")"
  [[ $r1 =~ ^[0-9]{8}-[0-9]{6}$ ]] && ok "runs: the id is YYYYmmdd-HHMMSS" || bad "runs: the id is YYYYmmdd-HHMMSS" "$r1"
  check "runs: latest points at the second" "runs/$r2" "$(readlink "$home/latest")"
  check "runs: each has debug, output, artifacts, cmd.txt and logcat.txt" "artifacts cmd.txt debug logcat.txt output" \
    "$(find "$home/runs/$r1" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | paste -sd' ')"
  check "runs: cmd.txt has the arguments and the rc" "args: sim maestro android test flows/|rc: 1" "$(paste -sd'|' "$home/runs/$r1/cmd.txt")"
  has "runs: says where the run is" "maestro run $r2: $home/runs/$r2" "$(cat "$T/log/err2")"
  has "runs: and where latest is" "latest: $home/latest" "$(cat "$T/log/err2")"
  AGENT_SIM_KEEP_RUNS=2 "$REPO/bin/sim" maestro android test flows/ >/dev/null 2>&1
  read -r k1 k2 rest <<< "$(runs_of "$home")"
  [ "$k1" = "$r2" ] && [ -n "$k2" ] && [ -z "$rest" ] && ok "runs: with AGENT_SIM_KEEP_RUNS=2 a third run prunes the first" \
    || bad "runs: with AGENT_SIM_KEEP_RUNS=2 a third run prunes the first" "$(runs_of "$home")"
  check "runs: latest follows the newest" "runs/$k2" "$(readlink "$home/latest")"

  rm -f "$T/log/docker" "$T/log/adb"
  "$REPO/bin/sim" maestro android test --output e2e/report.xml "--test-output-dir=$T/ws/app.wt/feat/out" flows/ >/dev/null 2>&1
  id=$(readlink "$home/latest"); id=${id#runs/}
  run=$(grep -- '--name agent-sim-maestro-1 ' "$T/log/docker")
  has "android: mounts unchanged" "-v $T/state/android/1.maestro:/run/sim -v $home:$home -v $T/ws/app.wt/feat:$T/ws/app.wt/feat -w $T/ws/app.wt/feat/client " "$run"
  has "android: the debug output goes to the run" "test --debug-output $home/runs/$id/debug " "$run"
  lacks "android: no default --test-output-dir when the caller gave one" "--test-output-dir $home" "$run"
  has "android: worktree output paths are written in place" "--output $T/ws/app.wt/feat/client/e2e/report.xml --test-output-dir=$T/ws/app.wt/feat/out flows/" "$run"
  has "android: the log is cleared first" "logcat -c" "$(cat "$T/log/adb")"
  has "android: then captured" "logcat -v threadtime" "$(cat "$T/log/adb")"
  [ -e "$home/runs/$id/logcat.txt" ] && ok "android: into the run's logcat.txt" || bad "android: into the run's logcat.txt"
  rm -f "$T/log/docker"
  "$REPO/bin/sim" maestro android hierarchy >/dev/null 2>&1
  has "android: nothing added to a command other than test" " emulator-5600 hierarchy" "$(grep -- '--name agent-sim-maestro-1 ' "$T/log/docker")"
  rm -f "$T/log/docker"
  out=$("$REPO/bin/sim" maestro android test --output /tmp/report.xml flows/ 2>&1); rc=$?
  check "android: an output path outside the worktree is rc 2" 2 "$rc"
  has "android: and says why" "output paths must lie inside the worktree" "$out"
  lacks "android: before Maestro runs" "--name agent-sim-maestro-1 " "$(cat "$T/log/docker" 2>/dev/null)"
  rm -f "$T/docker.rc"
  kill "$holder" 2>/dev/null; pkill -P "$holder" 2>/dev/null; wait
)

( PATH=$T/shims81:$PATH; cd "$T/ws/app.wt/feat/client" || exit 1; rm -rf "$T/log/"* "$T/state/ios" "$HOME/.cache/agent-sim/ios"
  root=$T/ws/app.wt/feat; base=$HOME/.cache/agent-sim/ios/maestro-1
  rm -rf "$root/client/e2e" "$root/client/out"
  hold ios "$root" 30; holder=$!
  wait_for "( lib; sim_held ios 1 )"
  echo 1 > "$T/ssh.rc"
  "$REPO/bin/sim" maestro ios test --output e2e/report.xml "--test-output-dir=$root/client/out" flows/ >/dev/null 2>"$T/log/err"; rc=$?
  check "ios: the rc is still Maestro's" 1 "$rc"
  id=$(readlink "$base/latest"); id=${id#runs/}
  run=$(grep 'sim-maestro [0-9]' "$T/log/ssh")
  has "ios: the launcher gets the slot and the run id" "sim-maestro 1 $id test " "$run"
  has "ios: --output goes to the run's artifacts, by its path in the worktree" \
    "--output \"\$HOME\"/.cache/agent-sim/maestro-1/runs/$id/artifacts/client/e2e/report.xml" "$run"
  has "ios: and so does --opt=path" "--test-output-dir=\"\$HOME\"/.cache/agent-sim/maestro-1/runs/$id/artifacts/client/out" "$run"
  has "ios: the debug output is added by the host" "test --debug-output \"\$HOME\"/.cache/agent-sim/maestro-1/runs/$id/debug " "$run"
  lacks "ios: no default --test-output-dir when the caller gave one" "--test-output-dir \"" "$run"
  check "ios: the report arrives at its path in the worktree" '<testsuites/>' "$(cat "$root/client/e2e/report.xml" 2>/dev/null)"
  check "ios: an output directory arrives whole" a "$(cat "$root/client/out/a.txt" 2>/dev/null)"
  check "ios: the run's debug output is in the run directory" log "$(cat "$base/runs/$id/debug/maestro.log" 2>/dev/null)"
  lacks "ios: the pull has no --delete" "--delete" "$(grep maestro-1/runs "$T/log/rsync")"
  check "ios: cmd.txt has the rc" "rc: 1" "$(tail -1 "$base/runs/$id/cmd.txt")"
  has "ios: says where the run is" "maestro run $id: $base/runs/$id" "$(cat "$T/log/err")"
  rm -f "$T/ssh.rc"
  "$REPO/bin/sim" maestro ios test flows/ >/dev/null 2>&1
  read -r i1 i2 rest <<< "$(runs_of "$base")"
  [ "$i1" = "$id" ] && [ -n "$i2" ] && [ -z "$rest" ] && ok "ios: two runs make two directories" || bad "ios: two runs make two directories" "$(runs_of "$base")"
  check "ios: latest points at the second" "runs/$i2" "$(readlink "$base/latest")"
  has "ios: with both default output dirs" "--test-output-dir \"\$HOME\"/.cache/agent-sim/maestro-1/runs/$i2/output" "$(grep "sim-maestro 1 $i2" "$T/log/ssh")"
  touch "$T/rsync.fail"; echo 4 > "$T/ssh.rc"
  out=$("$REPO/bin/sim" maestro ios test flows/ 2>&1); rc=$?
  check "ios: a failed pull keeps Maestro's rc" 4 "$rc"
  has "ios: and shows rsync's error" "connection unexpectedly closed" "$out"
  rm -f "$T/rsync.fail" "$T/ssh.rc" "$T/log/ssh"
  out=$("$REPO/bin/sim" maestro ios test --output ../../elsewhere.xml flows/ 2>&1); rc=$?
  check "ios: an output path outside the worktree is rc 2" 2 "$rc"
  has "ios: and says why" "output paths must lie inside the worktree" "$out"
  lacks "ios: before anything reaches the Mac" "sim-maestro" "$(cat "$T/log/ssh" 2>/dev/null)"
  "$REPO/bin/sim" maestro ios test --output >/dev/null 2>&1; check "ios: --output without a path is rc 2" 2 "$?"
  echo > "$T/sim-maestro.version"; rm -f "$T/log/ssh"
  out=$("$REPO/bin/sim" maestro ios test flows/ 2>&1); rc=$?
  check "ios: a launcher on contract 1 is rc 1" 1 "$rc"
  has "ios: with the bootstrap hint" "the Mac's sim-maestro is out of date: sim ios bootstrap" "$out"
  lacks "ios: and Maestro does not run" "sim-maestro 1 " "$(cat "$T/log/ssh")"
  rm -f "$T/sim-maestro.version"
  kill "$holder" 2>/dev/null; pkill -P "$holder" 2>/dev/null; wait
)

# The Mac launcher itself, cut out of install-ios-runner.sh as the e2e does, run against stand-ins for xcrun and maestro.
( L=$T/launcher; rm -rf "$L"; mkdir -p "$L/bin" "$L/home"
  sed -n "/^cat > \"\$HOME\/.local\/bin\/sim-maestro\" <<'EOF'$/,/^EOF$/p" "$REPO/install-ios-runner.sh" | sed '1d;$d' > "$L/sim-maestro"
  lacks "launcher: never empties a directory with rm -rf \"\$out\"" 'rm -rf "$out"' "$(cat "$L/sim-maestro")"
  printf '#!/bin/sh\necho "    agent-ios-1 (00000001-AAAA-4BBB-8CCC-DDDDDDDDDDDD) (Booted) "\n' > "$L/bin/xcrun"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/maestro.log"\nexit 5\n' "$L" > "$L/bin/maestro"
  chmod +x "$L/bin/"* "$L/sim-maestro"
  lx() { HOME=$L/home PATH=$L/bin:$PATH bash "$L/sim-maestro" "$@"; }
  check "launcher: --version prints 2" 2 "$(lx --version)"
  lx 1 >/dev/null 2>&1; check "launcher: no run id is rc 2" 2 "$?"
  lx 1 test flows/ >/dev/null 2>&1; check "launcher: a contract-1 call (no run id) is rc 2" 2 "$?"
  lx 1 ../x test >/dev/null 2>&1; check "launcher: a run id with a path in it is rc 2" 2 "$?"
  for id in 20261015-100000 20261015-100001 20261015-100002 20261015-100003 20261015-100003-2; do lx 1 "$id" test --debug-output x flows/; rc=$?; done
  check "launcher: Maestro's rc" 5 "$rc"
  check "launcher: no flags of its own" "--device 00000001-AAAA-4BBB-8CCC-DDDDDDDDDDDD test --debug-output x flows/" "$(tail -1 "$L/maestro.log")"
  check "launcher: keeps the last 3 runs" "20261015-100002 20261015-100003 20261015-100003-2" \
    "$(find "$L/home/.cache/agent-sim/maestro-1/runs" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | paste -sd' ')"
)

( AGENT_SIM_KEEP_RUNS=0; lib 2>/dev/null && bad "params: rejects AGENT_SIM_KEEP_RUNS=0" || ok "params: rejects AGENT_SIM_KEEP_RUNS=0" )
( AGENT_SIM_KEEP_RUNS=99; lib 2>/dev/null && bad "params: rejects AGENT_SIM_KEEP_RUNS=99" || ok "params: rejects AGENT_SIM_KEEP_RUNS=99" )
( AGENT_SIM_KEEP_RUNS=50; lib && check "params: AGENT_SIM_KEEP_RUNS=50 is fine" 50 "$AGENT_SIM_KEEP_RUNS" )
( lib; check "params: AGENT_SIM_KEEP_RUNS defaults to 5" 5 "$AGENT_SIM_KEEP_RUNS" )
( echo AGENT_SIM_KEEP_RUNS=7 >> "$REPO/.env"; lib; check "params: AGENT_SIM_KEEP_RUNS from .env" 7 "$AGENT_SIM_KEEP_RUNS"
  sed -i '/^AGENT_SIM_KEEP_RUNS=/d' "$REPO/.env" )
