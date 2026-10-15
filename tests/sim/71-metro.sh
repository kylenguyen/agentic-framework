# shellcheck shell=bash
# Sourced by tests/sim-test.sh after tests/sim/harness.sh; see its header.
# shellcheck disable=SC2015,SC2016,SC2030,SC2031,SC2154
echo "# metro"
metro_reset() { rm -f "$T/log/"* "$T/metro.status" "$T/ssh.down" "$T/state/ios/mac.state"; }   # Metro answers (curl shim)
start_line() { grep nohup "$T/log/ssh" 2>/dev/null; }   # the ssh call that starts Metro on the Mac
# an npx for the host cases that records its environment and writes a line to Metro's log
mkdir -p "$T/npxenv"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/log/npx"\nenv > "%s/log/npx.env"\necho "metro: bundler log line"\n' "$T" "$T" > "$T/npxenv/npx"
chmod +x "$T/npxenv/npx"

( cd "$T/ws/app.wt/feat/client" || exit 1; metro_reset
  hold ios "$T/ws/app.wt/feat" 20; holder=$!
  wait_for "( lib; sim_held ios 1 )"
  out=$(EXPO_PUBLIC_API_URL=x "$REPO/bin/sim" metro start ios --env 'FOO=b c' 2>&1); rc=$?
  check "ios start: rc 0 once Metro answers" 0 "$rc"
  has "ios start: the variables go in an env prefix, quoted" 'env EXPO_PUBLIC_API_URL=x FOO=b\ c npx expo start --port 8081' "$(start_line)"
  has "ios start: in the app's directory on the Mac" "cd sims/app-feat-" "$(start_line)"
  has "ios start: prints the names passed" "env: EXPO_PUBLIC_API_URL, FOO" "$out"
  lacks "ios start: never the values" "b c" "$out"
  has "ios start: ready" "Metro ready on port 8081" "$out"
  has "ios start: the readiness loop asks /status on the Mac" "curl -fs --max-time 2 http://127.0.0.1:8081/status" "$(cat "$T/log/ssh")"
  check "ios start: one ssh for the whole wait" 1 "$(grep -c 'packager-status:running ] && exit 0' "$T/log/ssh")"

  metro_reset
  "$REPO/bin/sim" metro start ios --env "Q=a'b \$c\"d" --env=R=1=2 >/dev/null 2>&1
  has "ios start: quotes, \$ and spaces are quoted for the remote shell" "Q=a\\'b\\ \\\$c\\\"d" "$(start_line)"
  has "ios start: --env=K=V, a value with =" "R=1=2 npx" "$(start_line)"

  metro_reset
  out=$(EXPO_PUBLIC_A=1 EZ_X=2 SIM_METRO_ENV=EZ_X,EZ_UNSET "$REPO/bin/sim" metro start ios --env EXPO_PUBLIC_A=3 2>&1)
  has "ios start: SIM_METRO_ENV names, an --env replaces a variable of the same name" "env EXPO_PUBLIC_A=3 EZ_X=2 npx" "$(start_line)"
  has "ios start: each name printed once, unset ones left out" "env: EXPO_PUBLIC_A, EZ_X" "$out"
  lacks "ios start: an unset SIM_METRO_ENV name is not passed" "EZ_UNSET" "$(start_line)"

  metro_reset
  out=$("$REPO/bin/sim" metro start ios 2>&1)
  lacks "ios start: no env line without variables" "env:" "$out"
  has "ios start: still an env prefix, empty" "nohup env npx expo start --port 8081" "$(start_line)"

  metro_reset
  "$REPO/bin/sim" metro start ios --env 1X=y >/dev/null 2>&1; check "bad --env 1X=y: rc 2" 2 "$?"
  "$REPO/bin/sim" metro start ios --env FOO >/dev/null 2>&1; check "bad --env without =: rc 2" 2 "$?"
  "$REPO/bin/sim" metro start ios --env >/dev/null 2>&1; check "--env without a value: rc 2" 2 "$?"
  SIM_METRO_ENV='A-B' "$REPO/bin/sim" metro start ios >/dev/null 2>&1; check "bad SIM_METRO_ENV name: rc 2" 2 "$?"
  "$REPO/bin/sim" metro stop ios --env A=1 >/dev/null 2>&1; check "--env with stop: rc 2" 2 "$?"
  check "bad --env: Metro is never started" "" "$(start_line)"

  metro_reset; : > "$T/metro.status"
  start=$SECONDS
  err=$(SIM_METRO_READY_TIMEOUT=2 "$REPO/bin/sim" metro start ios 2>&1 >/dev/null); rc=$?
  check "ios start, no answer: rc 1" 1 "$rc"
  has "ios start, no answer: says so" "sim: Metro on port 8081 did not answer within 2 s" "$err"
  has "ios start, no answer: the tail of the Mac's Metro log" "tail -n 20 sims/app-feat-" "$(cat "$T/log/ssh")"
  [ $((SECONDS - start)) -le 5 ] && ok "ios start, no answer: gives up after the timeout" || bad "ios start, no answer: gives up after the timeout" "$((SECONDS - start)) s"
  kill "$holder" 2>/dev/null; pkill -P "$holder" 2>/dev/null; wait
)

( cd "$T/ws/app" || exit 1; metro_reset; export PATH="$T/npxenv:$PATH"
  hold web "$T/ws/app" 20; holder=$!
  wait_for "( lib; sim_held web 1 )"
  out=$(EXPO_PUBLIC_API_URL='http://h:1/a b' "$REPO/bin/sim" metro start web --env 'FOO=$x "y"' 2>&1); rc=$?
  check "web start: rc 0 once Metro answers" 0 "$rc"
  has "web start: ready" "Metro ready on port 8201" "$out"
  has "web start: Expo web on the slot's port" "expo start --port 8201 --web" "$(cat "$T/log/npx")"
  has "web start: polls the slot's /status" "http://127.0.0.1:8201/status" "$(cat "$T/log/curl")"
  check "web start: EXPO_PUBLIC_* reaches Metro as is" 'EXPO_PUBLIC_API_URL=http://h:1/a b' "$(grep '^EXPO_PUBLIC_API_URL=' "$T/log/npx.env")"
  check "web start: --env reaches Metro as is" 'FOO=$x "y"' "$(grep '^FOO=' "$T/log/npx.env")"
  has "web start: names printed" "env: EXPO_PUBLIC_API_URL, FOO" "$out"
  "$REPO/bin/sim" metro stop web 2>/dev/null

  metro_reset; : > "$T/metro.status"
  start=$SECONDS
  err=$(SIM_METRO_READY_TIMEOUT=2 "$REPO/bin/sim" metro start web 2>&1 >/dev/null); rc=$?
  check "web start, no answer: rc 1" 1 "$rc"
  has "web start, no answer: says so" "did not answer within 2 s" "$err"
  has "web start, no answer: the tail of Metro's log in stderr" "metro: bundler log line" "$err"
  [ $((SECONDS - start)) -le 5 ] && ok "web start, no answer: gives up after the timeout" || bad "web start, no answer: gives up after the timeout" "$((SECONDS - start)) s"
  "$REPO/bin/sim" metro stop web 2>/dev/null
  kill "$holder" 2>/dev/null; pkill -P "$holder" 2>/dev/null; wait
)

( cd "$T/ws/app" || exit 1; metro_reset
  hold android "$T/ws/app" 20; holder=$!
  wait_for "( lib; sim_held android 1 )"
  mkdir -p "$T/state/android"; sleep 30 & metro=$!; echo "$metro" > "$T/state/android/1.metro"
  t0=$(date +%s%N)
  ( cd client && "$REPO/bin/sim" build --variant debug >/dev/null 2>&1 ); rc=$?
  ms=$((($(date +%s%N) - t0) / 1000000))
  check "build, Metro running: rc 0" 0 "$rc"
  check "build, Metro running: no second Metro" "expo run:android --port 8101 --variant debug" "$(cat "$T/log/npx" 2>/dev/null)"
  has "build, Metro running: adb reverse all the same" "reverse tcp:8081 tcp:8101" "$(cat "$T/log/adb" 2>/dev/null)"
  [ "$ms" -lt 1000 ] && ok "build, Metro running: no settle sleep (${ms} ms)" || bad "build, Metro running: no settle sleep" "${ms} ms"
  mkdir -p "$T/badadb"
  printf '#!/bin/sh\ncase "$*" in *reverse*) exit 1 ;; esac\nexit 0\n' > "$T/badadb/adb"; chmod +x "$T/badadb/adb"
  rm -f "$T/log/npx"
  err=$(cd client && PATH="$T/badadb:$PATH" "$REPO/bin/sim" build 2>&1 >/dev/null); rc=$?
  check "build, adb reverse fails: rc 1" 1 "$rc"
  has "build, adb reverse fails: says so" "adb reverse tcp:8081 tcp:8101 failed" "$err"
  [ -e "$T/log/npx" ] && bad "build, adb reverse fails: no build" || ok "build, adb reverse fails: no build"
  kill "$metro" 2>/dev/null; rm -f "$T/state/android/1.metro"
  kill "$holder" 2>/dev/null; pkill -P "$holder" 2>/dev/null; wait
)
