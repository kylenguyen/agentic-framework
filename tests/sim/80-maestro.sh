# shellcheck shell=bash
# Sourced by tests/sim-test.sh after tests/sim/harness.sh; see its header.
# shellcheck disable=SC2015,SC2016,SC2030,SC2031,SC2154
echo "# sim maestro"
( cd "$T/ws/app.wt/feat/client" || exit 1; rm -f "$T/log/"* "$T/active"
  out=$("$REPO/bin/sim" maestro android test flows/ 2>&1); rc=$?
  [ "$rc" != 0 ] && ok "maestro: fails without a lease" || bad "maestro: fails without a lease"
  has "maestro: says how to get a slot" "sim enable" "$out"
  hold android "$T/ws/app.wt/feat" 30; holder=$!
  wait_for "( lib; sim_held android 1 )"
  touch "$T/docker.noimage"; echo 3 > "$T/docker.rc"
  MAESTRO_APP_ID=com.x "$REPO/bin/sim" maestro android test flows/ >/dev/null 2>"$T/log/maestro.err"; rc=$?
  check "maestro: Maestro's exit code" 3 "$rc"
  d=$(cat "$T/log/docker")
  has "maestro: starts the slot's emulator" "start agent-sim-android@1.service" "$(cat "$T/log/systemctl")"
  has "maestro: and waits for its boot" "getprop sys.boot_completed" "$(cat "$T/log/adb")"
  has "maestro: builds the pinned image when missing" "build -q -t agent-sim-maestro:2.11.0-" "$d"
  has "maestro: of the pinned version" "--build-arg MAESTRO_VERSION=2.11.0" "$d"
  has "maestro: with its checksum" "MAESTRO_SHA256=5384593c" "$d"
  relay=$(grep -- '--name agent-sim-maestro-1-adb' "$T/log/docker")
  has "maestro: relay on the host network" "--network host" "$relay"
  has "maestro: relay to the slot's adb server" "UNIX-LISTEN:/run/sim/adb.sock,fork,mode=600 TCP:127.0.0.1:5038" "$relay"
  run=$(grep -- '--name agent-sim-maestro-1 ' "$T/log/docker")
  lacks "maestro: Maestro on a network of its own" "--network" "$run"
  id=$(readlink "$HOME/.cache/agent-sim/android/maestro-1/latest"); id=${id#runs/}
  has "maestro: Maestro on the slot's serial" " emulator-5600 test --debug-output $HOME/.cache/agent-sim/android/maestro-1/runs/$id/debug " "$run"
  has "maestro: the caller's arguments follow" "/runs/$id/output flows/" "$run"
  has "maestro: worktree at its own path" "-v $T/ws/app.wt/feat:$T/ws/app.wt/feat -w $T/ws/app.wt/feat/client" "$run"
  has "maestro: as the host user" "--user $(id -u):$(id -g)" "$run"
  has "maestro: HOME at its host path, so printed paths are real" "-e HOME=$HOME/.cache/agent-sim/android/maestro-1" "$run"
  has "maestro: MAESTRO_ variables reach the flows" "-e MAESTRO_APP_ID" "$run"
  check "maestro: relay removed after the run" "rm -f agent-sim-maestro-1-adb" "$(tail -1 "$T/log/docker")"
  [ -e "$T/state/android/1.active" ] && ok "maestro: a run is use" || bad "maestro: a run is use"
  rm -f "$T/log/docker" "$T/docker.noimage" "$T/docker.rc"
  "$REPO/bin/sim" maestro android hierarchy >/dev/null 2>&1
  lacks "maestro: no build when the image exists" "build" "$(cat "$T/log/docker")"
  echo abc123 > "$T/docker.ps"
  out=$("$REPO/bin/sim" maestro android test flows/ 2>&1); rc=$?
  [ "$rc" != 0 ] && ok "maestro: one run per slot" || bad "maestro: one run per slot"
  has "maestro: says a run is going" "already going on android slot 1" "$out"
  rm -f "$T/docker.ps"
  "$REPO/bin/sim" maestro >/dev/null 2>&1; check "maestro: no arguments is a usage error" 2 "$?"
  "$REPO/bin/sim" maestro test flows/ >/dev/null 2>&1; check "maestro: no platform word is a usage error" 2 "$?"
  "$REPO/bin/sim" maestro tv test flows/ >/dev/null 2>&1; check "maestro: an unknown platform is a usage error" 2 "$?"
  "$REPO/bin/sim" maestro android >/dev/null 2>&1; check "maestro android: no arguments is a usage error" 2 "$?"
  kill "$holder" 2>/dev/null; pkill -P "$holder" 2>/dev/null; wait
)
( cd "$T/ws/app.wt/feat/client" || exit 1; rm -rf "$T/log/"* "$T/state/ios"
  out=$("$REPO/bin/sim" maestro ios test flows/ 2>&1); rc=$?
  [ "$rc" != 0 ] && ok "maestro ios: fails without a lease" || bad "maestro ios: fails without a lease"
  has "maestro ios: says how to get a slot" "sim enable" "$out"
  hold ios "$T/ws/app.wt/feat" 30; holder=$!
  wait_for "( lib; sim_held ios 1 )"
  touch "$T/state/ios/1.down"; echo 3 > "$T/ssh.rc"
  MAESTRO_APP_ID="com.x y" "$REPO/bin/sim" maestro ios test flows/ "$T/ws/app.wt/feat/e2e/login.yaml" \
    "--config=$T/ws/app.wt/feat/client/config.yaml" >/dev/null 2>"$T/log/maestro.err"; rc=$?
  check "maestro ios: Maestro's exit code" 3 "$rc"
  tree=app-feat-$(printf %s "$T/ws/app.wt/feat" | sha256sum | cut -c1-6)
  has "maestro ios: syncs the worktree first" "$T/ws/app.wt/feat/ bob@mini.tail.ts.net:sims/$tree/" "$(head -1 "$T/log/rsync")"
  has "maestro ios: boots the slot's simulator" "xcrun simctl bootstatus agent-ios-1 -b" "$(cat "$T/log/ssh")"
  run=$(grep 'sim-maestro [0-9]' "$T/log/ssh"); id=$(readlink "$HOME/.cache/agent-sim/ios/maestro-1/latest"); id=${id#runs/}
  has "maestro ios: in the synced app dir" "cd sims/$tree/client && " "$run"
  has "maestro ios: launcher for the slot" "sim-maestro 1 $id test --debug-output \"\$HOME\"/.cache/agent-sim/maestro-1/runs/$id/debug " "$run"
  has "maestro ios: checks the launcher's contract first" "sim-maestro --version" "$(grep -m1 sim-maestro "$T/log/ssh")"
  has "maestro ios: worktree paths become paths in the synced copy" " ../e2e/login.yaml" "$run"
  has "maestro ios: and so do --opt=path arguments" " --config=config.yaml" "$run"
  has "maestro ios: MAESTRO_ variables reach the flows" 'env MAESTRO_APP_ID=com.x\ y ' "$run"
  has "maestro ios: debug output pulled back" "bob@mini.tail.ts.net:.cache/agent-sim/maestro-1/runs/$id/ $HOME/.cache/agent-sim/ios/maestro-1/runs/$id/" "$(tail -1 "$T/log/rsync")"
  has "maestro ios: says where it is" "maestro run $id: $HOME/.cache/agent-sim/ios/maestro-1/runs/$id" "$(cat "$T/log/maestro.err")"
  [ -e "$T/state/ios/1.active" ] && ok "maestro ios: a run is use" || bad "maestro ios: a run is use"
  [ -e "$T/state/ios/1.down" ] && bad "maestro ios: clears the down mark" || ok "maestro ios: clears the down mark"
  rm -f "$T/ssh.rc"
  flock "$T/state/ios/1.maestro.lock" sleep 3 & locker=$!
  sleep 0.3
  out=$("$REPO/bin/sim" maestro ios test flows/ 2>&1); rc=$?
  [ "$rc" != 0 ] && ok "maestro ios: one run per slot" || bad "maestro ios: one run per slot"
  has "maestro ios: says a run is going" "already going on ios slot 1" "$out"
  kill "$locker" 2>/dev/null
  "$REPO/bin/sim" maestro ios >/dev/null 2>&1; check "maestro ios: no arguments is a usage error" 2 "$?"
  kill "$holder" 2>/dev/null; pkill -P "$holder" 2>/dev/null; wait
)
