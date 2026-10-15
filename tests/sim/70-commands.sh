# shellcheck shell=bash
# Sourced by tests/sim-test.sh after tests/sim/harness.sh; see its header.
# shellcheck disable=SC2015,SC2016,SC2030,SC2031,SC2154
echo "# sim commands"
( cd "$T/ws/app" || exit 1
  out=$("$REPO/bin/sim" env 2>&1); rc=$?
  [ "$rc" != 0 ] && ok "env: fails without a lease" || bad "env: fails without a lease"
  has "env: says how to get a slot" "sim enable" "$out"
  hold android "$T/ws/app" 30; holder=$!
  wait_for "( lib; sim_held android 1 )"
  env=$("$REPO/bin/sim" env); has "env: serial of my slot" "ANDROID_SERIAL=emulator-5600" "$env"
  has "env: adb server of my slot" "ANDROID_ADB_SERVER_PORT=5038" "$env"
  check "run: command sees the slot" emulator-5600 "$("$REPO/bin/sim" run sh -c 'echo $ANDROID_SERIAL')"
  st=$("$REPO/bin/sim" status)
  has "status: leased android slot" "leased  pid" "$(echo "$st" | grep '^android  1')"
  has "status: free web slot" free "$(echo "$st" | grep '^web      1')"
  check "status: one line per slot" 5 "$(echo "$st" | wc -l)"
  ( cd client && rm -f "$T/log/npx" && SIM_METRO_SETTLE=0 "$REPO/bin/sim" build --variant debug >/dev/null 2>&1 )
  has "build: starts the slot's Metro first" "expo start --port 8101" "$(head -1 "$T/log/npx" 2>/dev/null)"
  has "build: expo run:android for the slot's Metro port" "expo run:android --port 8101 --variant debug" "$(tail -1 "$T/log/npx" 2>/dev/null)"
  "$REPO/bin/sim" metro stop android 2>/dev/null
  kill "$holder" 2>/dev/null; pkill -P "$holder" 2>/dev/null; wait
)
( cd "$T/ws/app.wt/feat/client" || exit 1; rm -f "$T/log/"*
  "$REPO/bin/sim" ios sync >/dev/null 2>&1
  r=$(cat "$T/log/rsync")
  has "ios sync: whole worktree" "$T/ws/app.wt/feat/ bob@mini.tail.ts.net:sims/app-feat/" "$r"
  has "ios sync: no .env files" "--exclude=.env.*" "$r"
  has "ios sync: no node_modules" "--exclude=node_modules" "$r"
  has "ios sync: keeps the Mac's generated ios/" "--filter=P ios/" "$r"
  has "ios sync: deletes what the worktree dropped" "--delete" "$r"
)
