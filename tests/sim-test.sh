#!/usr/bin/env bash
# tests/sim-test.sh: unit tests for lib/sim.sh, bin/sim and bin/sim-mcp. No network, sudo, emulator, browser or Mac:
# the scripts run from a copy of the repo in a temp dir (so the checkout's .env cannot leak in), with shims for
# systemctl, ssh and node that record what they were asked to do. Safe on the live host. Exit 0 when all pass.
# Usage: bash tests/sim-test.sh
# A && ok || bad is the intended pattern and cases run in subshells on purpose:
# shellcheck disable=SC2015,SC2016,SC2030,SC2031
set -u
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
: > "$T/results"
ok()    { echo ok >> "$T/results"; printf 'ok   %s\n' "$1"; }
bad()   { echo FAIL >> "$T/results"; printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
has()   { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "no [$2] in [$3]" ;; esac; }   # has <name> <needle> <haystack>
lacks() { case "$3" in *"$2"*) bad "$1" "unexpected [$2] in [$3]" ;; *) ok "$1" ;; esac; }

# A repo copy with a test .env, and shims that log to $T/log.
REPO=$T/repo
mkdir -p "$REPO/bin" "$REPO/lib" "$REPO/config" "$T/shims" "$T/log"
cp "$SRC/lib/params.sh" "$SRC/lib/sim.sh" "$REPO/lib/"
cp "$SRC/bin/sim" "$SRC/bin/sim-mcp" "$REPO/bin/"
cp "$SRC/install-ios-runner.sh" "$REPO/"
printf 'AGENT_HOST=box\nAGENT_IOS_HOST=mini.tail.ts.net\nAGENT_IOS_USER=bob\nAGENT_SIM_ANDROID_SLOTS=2\nAGENT_SIM_WEB_SLOTS=2\nAGENT_SIM_IOS_SLOTS=1\n' > "$REPO/.env"
for c in systemctl ssh rsync mise; do
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/log/%s"\n[ "$1" = is-active ] && echo inactive\nexit 0\n' "$T" "$c" > "$T/shims/$c"
done
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/log/adb"\n' "$T" > "$T/shims/adb"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" > "%s/log/emulator"\necho "$ANDROID_TMP" > "%s/log/emulator.tmp"\n' "$T" "$T" > "$T/shims/emulator"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/log/npx"\n' "$T" > "$T/shims/npx"
# The MCP server stand-in: records its arguments and environment, then serves until stdin closes.
printf '#!/bin/sh\nprintf "%%s\\n" "$*" > "%s/log/node.args"\nenv > "%s/log/node.env"\ncat > /dev/null\n' "$T" "$T" > "$T/shims/node"
mkdir -p "$T/prefix/node_modules/.bin"; printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/log/mobilecli"\n' "$T" > "$T/prefix/node_modules/.bin/mobilecli"
chmod +x "$T/shims/"* "$T/prefix/node_modules/.bin/mobilecli"
export PATH="$T/shims:$PATH" SIM_STATE=$T/state SIM_PREFIX=$T/prefix SIM_NODE=$T/shims/node HOME=$T/home
mkdir -p "$HOME"
unset AGENT_HOST AGENT_HOST_ADDRESS AGENT_HOST_USER AGENT_HOST_LAN_IP AGENT_IOS_HOST AGENT_IOS_USER \
  AGENT_SIM_ANDROID_SLOTS AGENT_SIM_WEB_SLOTS AGENT_SIM_IOS_SLOTS ANDROID_SERIAL ANDROID_ADB_SERVER_PORT \
  XDG_CACHE_HOME SIM_CACHE ANDROID_TMP
lib() { . "$REPO/lib/sim.sh" && sim_load_params; }
# a git worktree layout for the tests that need a root: $T/ws/app (checkout) and $T/ws/app.wt/feat (worktree)
mkdir -p "$T/ws/app/client" && git -C "$T/ws/app" init -q && git -C "$T/ws/app" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$T/ws/app" worktree add -q "$T/ws/app.wt/feat" 2>/dev/null; mkdir -p "$T/ws/app.wt/feat/client"
# hold <platform> <root> <seconds>: lease a slot in the background for a while, as an MCP server would
hold() { ( cd "$2" && . "$REPO/lib/sim.sh" && sim_load_params && sim_lease "$1" "$2" && sleep "$3" ) & }
wait_for() { local i; for i in $(seq 1 50); do eval "$1" && return 0; sleep 0.1; done; return 1; }

echo "# syntax"
for f in lib/sim.sh bin/sim bin/sim-mcp install-ios-runner.sh tests/sim-test.sh; do bash -n "$SRC/$f" && ok "bash -n $f" || bad "bash -n $f"; done
[ -x "$SRC/bin/sim" ] && [ -x "$SRC/bin/sim-mcp" ] && ok "bin/sim and bin/sim-mcp are executable" || bad "executable bits"

echo "# parameters"
( lib; check "params: android slots from .env" 2 "$AGENT_SIM_ANDROID_SLOTS"; check "params: iOS login from .env" bob "$AGENT_IOS_USER" )
( AGENT_SIM_WEB_SLOTS=12; lib 2>/dev/null && bad "params: rejects a two-digit slot count" || ok "params: rejects a two-digit slot count" )
( sed -i 's/^AGENT_SIM_WEB_SLOTS=2$//' "$REPO/.env"; lib; check "params: web slots default to 3" 3 "$AGENT_SIM_WEB_SLOTS"
  printf 'AGENT_SIM_WEB_SLOTS=2\n' >> "$REPO/.env" )
( . "$REPO/lib/params.sh"; AGENT_IOS_USER="a b"; params_validate 2>/dev/null && bad "params: rejects a bad iOS login" || ok "params: rejects a bad iOS login" )

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

echo "# leases"
( lib
  hold web "$T/ws/app" 3
  wait_for 'sim_held web 1' && ok "lease: first holder gets slot 1" || bad "lease: first holder gets slot 1"
  sim_lease web "$T/ws/app.wt/feat"; check "lease: second holder gets slot 2" 2 "$SIM_SLOT"
  check "lease: owner records the worktree" "$T/ws/app.wt/feat" "$(sim_owner_field web 2 root)"
  check "my slot: found by worktree" 1 "$(sim_my_slot web "$T/ws/app")"
  err=$( (sim_lease web "$T/ws/other") 2>&1 >/dev/null); rc=$?
  [ "$rc" != 0 ] && ok "lease: exhausted pool refuses" || bad "lease: exhausted pool refuses"
  has "lease: refusal names the holders" "$T/ws/app" "$err"
  wait
  wait_for '! sim_held web 1' && ok "lease: freed when the holder exits" || bad "lease: freed when the holder exits"
  sim_my_slot web "$T/ws/app" >/dev/null && bad "my slot: none after release" || ok "my slot: none after release"
)

echo "# sim enable"
( cd "$T/ws/app.wt/feat" || exit 1
  printf '{"mcpServers": {"other": {"command": "x"}}}\n' > .mcp.json
  printf 'model = "m"\n\n[projects.x]\ntrust_level = "trusted"\n' > "$T/codex-before"; mkdir -p .codex; cp "$T/codex-before" .codex/config.toml
  out=$("$REPO/bin/sim" enable 2>&1) || bad "enable: exits 0" "$out"
  check "enable: .mcp.json keeps other servers" x "$(jq -r '.mcpServers.other.command' .mcp.json)"
  check "enable: .mcp.json sim-ios" '["ios"]' "$(jq -c '.mcpServers["sim-ios"].args' .mcp.json)"
  check "enable: .mcp.json command is the bare name" sim-mcp "$(jq -r '.mcpServers["sim-web"].command' .mcp.json)"
  check "enable: opencode.json sim-android" '["sim-mcp","android"]' "$(jq -c '.mcp["sim-android"].command' opencode.json)"
  check "enable: codex servers" 3 "$(grep -c '^\[mcp_servers\.sim-' .codex/config.toml)"
  has "enable: codex keeps the rest" 'trust_level = "trusted"' "$(cat .codex/config.toml)"
  has "enable: prints the AGENTS.md section" "## Simulators" "$out"
  cp .mcp.json "$T/m1"; cp .codex/config.toml "$T/c1"
  "$REPO/bin/sim" enable >/dev/null 2>&1
  cmp -s .mcp.json "$T/m1" && cmp -s .codex/config.toml "$T/c1" && ok "enable: second run changes nothing" || bad "enable: second run changes nothing" "$(diff "$T/c1" .codex/config.toml)"
  "$REPO/bin/sim" enable --only web >/dev/null 2>&1
  check "enable --only web: one codex server" 1 "$(grep -c '^\[mcp_servers\.sim-' .codex/config.toml)"
  lacks "enable: no host or login in the files" "mini.tail" "$(cat .mcp.json opencode.json .codex/config.toml)"
  echo '{bad' > opencode.json
  "$REPO/bin/sim" enable >/dev/null 2>&1 && bad "enable: refuses invalid JSON" || ok "enable: refuses invalid JSON"
  "$REPO/bin/sim" enable --only tv >/dev/null 2>&1; check "enable: unknown platform is a usage error" 2 "$?"
)

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
( cd "$T/ws/app" || exit 1; rm -f "$T/log/"*
  sleep 1 | "$REPO/bin/sim-mcp" android 2>/dev/null; wait
  has "android: starts the slot's emulator unit" "--user start agent-sim-android@1.service" "$(cat "$T/log/systemctl")"
  has "android: mobile-mcp" "@mobilenext/mobile-mcp/lib/index.js" "$(cat "$T/log/node.args")"
  has "android: the slot's own adb server" "ANDROID_ADB_SERVER_PORT=5038" "$(cat "$T/log/node.env")"
  has "android: telemetry off" "MOBILEMCP_DISABLE_TELEMETRY=1" "$(cat "$T/log/node.env")"
  has "android: a mobilecli daemon of the slot's own" "MOBILECLI_HOME=$T/state/android/1.mobilecli" "$(cat "$T/log/node.env")"
  check "android: that daemon stopped with the session" "daemon stop" "$(cat "$T/log/mobilecli" 2>/dev/null)"
)
( cd "$T/ws/app" || exit 1; rm -f "$T/log/"*
  sleep 1 | "$REPO/bin/sim-mcp" ios 2>/dev/null; wait
  has "ios: launcher for slot 1 over ssh" "-T bob@mini.tail.ts.net .local/bin/sim-xcodebuildmcp 1" "$(cat "$T/log/ssh")"
  has "ios: BatchMode, never a prompt" "BatchMode=yes" "$(cat "$T/log/ssh")"
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
( "$REPO/bin/sim" nope 2>/dev/null; check "sim: unknown command is a usage error" 2 "$?" )

pass=$(grep -c '^ok$' "$T/results"); fail=$(grep -c '^FAIL$' "$T/results")
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
