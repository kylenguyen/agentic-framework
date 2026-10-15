# shellcheck shell=bash
# Sourced by tests/sim-test.sh after tests/sim/harness.sh; see its header.
# shellcheck disable=SC2015,SC2016,SC2030,SC2031,SC2154
echo "# .sim/config and the stack seam"
# A repo of its own ($T/ws/cfg, app in client/), so no .sim/config leaks into the other sections' worktrees.
CFG=$T/ws/cfg
mkdir -p "$CFG/client" && git -C "$CFG" init -q && git -C "$CFG" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
cfg() { mkdir -p "$CFG/.sim" && printf '%s\n' "$@" > "$CFG/.sim/config"; }   # cfg <line...>: write .sim/config
cfg_reap() { pkill -f "$T/shims/ssh .* -R " 2>/dev/null; pkill -f "$REPO/bin/sim _tunnel_watch" 2>/dev/null; rm -f "$T/tunnel.up"; }
cfg_tunnel_up() { pgrep -f "$T/shims/ssh .* -R " >/dev/null; }

( lib
  cfg '# a comment' '' 'stack = expo' '  app_dir=client/  ' 'metro_env = FOO, BAR_2' 'forward_ios = 22000,22001' 'ports = 7' 'keep_runs = 03'
  err=$(sim_repo_config "$CFG" 2>&1); rc=$?
  check "config: a valid file is rc 0" 0 "$rc"
  check "config: ...quietly" "" "$err"
  sim_repo_config "$CFG" 2>/dev/null
  check "config: the values, trimmed" "expo|client|FOO,BAR_2|22000,22001|7|3" \
    "$SIM_CFG_STACK|$SIM_CFG_APP_DIR|$SIM_CFG_METRO_ENV|$SIM_CFG_FORWARD_IOS|$SIM_CFG_PORTS|$SIM_CFG_KEEP_RUNS"
  check "config: stack expo" expo "$(sim_stack)"

  cfg 'ports = 4' 'colour = blue'
  err=$(sim_repo_config "$CFG" 2>&1); rc=$?
  check "config: an unknown key is rc 0" 0 "$rc"
  has "config: ...with a warning naming its line" ".sim/config:2: unknown key colour" "$err"
  sim_repo_config "$CFG" 2>/dev/null
  check "config: ...the known keys still set" 4 "${SIM_CFG_PORTS:-}"
  check "config: a key the file leaves out is unset" unset "${SIM_CFG_KEEP_RUNS-unset}"

  cfg '# ports' 'ports = 200'
  err=$(sim_repo_config "$CFG" 2>&1); rc=$?
  check "config: ports = 200 is rc 2" 2 "$rc"
  has "config: ...naming .sim/config:2" ".sim/config:2: ports = 200" "$err"
  cfg 'stack = expo' 'foo'
  err=$(sim_repo_config "$CFG" 2>&1); rc=$?
  check "config: a line without = is rc 2" 2 "$rc"
  has "config: ...naming its line" ".sim/config:2: expected key = value" "$err"
  for bad in 'stack = flutter' 'app_dir = /abs' 'app_dir = ../up' 'app_dir = a/../../b' 'metro_env = 1X' 'forward_ios = 70000' \
    'forward_ios = 22000;22001' 'keep_runs = 0' 'keep_runs = 51' 'ports = 0' 'ports = x' 'Stack = expo'; do
    cfg "$bad"
    sim_repo_config "$CFG" 2>/dev/null; check "config: $bad is rc 2" 2 "$?"
  done

  # Never sourced: a command substitution in a value, in any key, is only text.
  rm -f "$T/cfg-pwned"
  for key in app_dir metro_env forward_ios stack ports colour; do
    cfg "$key = \$(touch $T/cfg-pwned)" "$key = \`touch $T/cfg-pwned\`"
    sim_repo_config "$CFG" >/dev/null 2>&1
  done
  [ -e "$T/cfg-pwned" ] && bad "config: \$(touch ...) as a value is never executed" || ok "config: \$(touch ...) as a value is never executed"

  rm -rf "$CFG/.sim"
  sim_repo_config "$CFG"; check "config: no file is rc 0" 0 "$?"
  check "config: ...and sets nothing" "unset unset" "${SIM_CFG_PORTS-unset} ${SIM_CFG_STACK-unset}"
  check "config: ...stack expo by default" expo "$(sim_stack)"
)

echo "# .sim/config precedence"
# keep_runs: the environment, then .sim/config, then the host .env, then 5. A repo copy whose .env says 5.
( mkdir -p "$T/kr/lib"; cp "$REPO/lib/"*.sh "$T/kr/lib/"; printf 'AGENT_SIM_KEEP_RUNS=5\n' > "$T/kr/.env"
  REPO=$T/kr
  cfg 'keep_runs = 2'
  ( lib; sim_repo_apply "$CFG"; check "precedence: keep_runs in .sim/config (2) beats .env (5)" 2 "$AGENT_SIM_KEEP_RUNS" )
  ( export AGENT_SIM_KEEP_RUNS=9; lib; sim_repo_apply "$CFG"; check "precedence: AGENT_SIM_KEEP_RUNS in the environment beats .sim/config" 9 "$AGENT_SIM_KEEP_RUNS" )
  rm -rf "$CFG/.sim"
  ( lib; sim_repo_apply "$CFG"; check "precedence: .env without .sim/config" 5 "$AGENT_SIM_KEEP_RUNS" )
  ( REPO=$T/kr; rm -f "$T/kr/.env"; lib; sim_repo_apply "$CFG"; check "precedence: the default" 5 "$AGENT_SIM_KEEP_RUNS" )
)
# ...and a Maestro run keeps that many.
( cd "$CFG" || exit 1; rm -rf "$T/log/"* "$T/cache-kr"; export SIM_CACHE=$T/cache-kr
  hold android "$CFG" 30; holder=$!
  wait_for "( lib; sim_held android 1 )"
  cfg 'keep_runs = 2'
  for i in 1 2 3; do mkdir -p "$SIM_CACHE/android/maestro-1/runs/20260101-00000$i"; done
  "$REPO/bin/sim" maestro android test x >/dev/null 2>&1
  check "precedence: sim maestro keeps keep_runs runs" 2 "$(find "$SIM_CACHE/android/maestro-1/runs" -mindepth 1 -maxdepth 1 | wc -l)"
  AGENT_SIM_KEEP_RUNS=3 "$REPO/bin/sim" maestro android test x >/dev/null 2>&1
  check "precedence: ...the environment's count over it" 3 "$(find "$SIM_CACHE/android/maestro-1/runs" -mindepth 1 -maxdepth 1 | wc -l)"
  rm -rf "$CFG/.sim"
  kill "$holder" 2>/dev/null; pkill -P "$holder" 2>/dev/null; wait
)

echo "# .sim/config in the commands"
( cd "$CFG" || exit 1; rm -rf "$T/log/"* "$T/state/ios" "$T/ssh.rc" "$T/lsof.out" "$T/tunnel.fail"
  trap 'cfg_reap; rm -rf "$CFG/.sim"' EXIT
  hold ios "$CFG" 60; holder=$!
  wait_for "( lib; sim_held ios 1 )"
  cfg 'forward_ios = 22000'
  "$REPO/bin/sim" maestro ios test x >/dev/null 2>"$T/log/maestro.err"; rc=$?
  check "forward_ios: sim maestro ios rc 0" 0 "$rc"
  has "forward_ios: sim maestro ios test x forwards 22000" "-R 127.0.0.1:22000:127.0.0.1:22000" "$(grep -- ' -R ' "$T/log/ssh")"
  wait_for "! cfg_tunnel_up" && ok "forward_ios: ...closed after the run" || bad "forward_ios: ...closed after the run"
  : > "$T/log/ssh"
  "$REPO/bin/sim" maestro ios --forward none test x >/dev/null 2>&1; rc=$?
  check "forward_ios: --forward none, rc 0" 0 "$rc"
  lacks "forward_ios: ...starts no tunnel" " -R " "$(cat "$T/log/ssh")"
  lacks "forward_ios: ...and Maestro never sees it" "none" "$(grep 'sim-maestro 1 ' "$T/log/ssh")"
  : > "$T/log/ssh"
  "$REPO/bin/sim" maestro ios --forward 22005 test x >/dev/null 2>&1
  check "forward_ios: --forward replaces it" "-R 127.0.0.1:22005:127.0.0.1:22005" "$(grep -- ' -R ' "$T/log/ssh" | grep -o -- '-R [^ ]*' | tr '\n' ' ' | sed 's/ $//')"
  cfg 'forward_ios = 8440'
  "$REPO/bin/sim" maestro ios test x >/dev/null 2>&1; check "forward_ios: a port outside the block is rc 2" 2 "$?"

  # sim tunnel ios with no ports: forward_ios.
  cfg 'forward_ios = 22001,22002'
  : > "$T/log/ssh"
  out=$("$REPO/bin/sim" tunnel ios --background 2>&1); rc=$?
  check "forward_ios: sim tunnel ios with no ports, rc 0" 0 "$rc"
  has "forward_ios: ...forwards forward_ios" "-R 127.0.0.1:22001:127.0.0.1:22001 -R 127.0.0.1:22002:127.0.0.1:22002" "$(grep -- ' -R ' "$T/log/ssh")"
  "$REPO/bin/sim" tunnel ios --stop >/dev/null 2>&1
  rm -rf "$CFG/.sim"
  "$REPO/bin/sim" tunnel ios 2>/dev/null; check "forward_ios: without it, no ports is still a usage error" 2 "$?"

  # metro_env: names passed to Metro on the Mac; SIM_METRO_ENV beats it.
  cfg 'metro_env = FOO'
  rm -f "$T/state/ios/mac.state" "$T/metro.status"; : > "$T/log/ssh"
  FOO=bar "$REPO/bin/sim" metro start ios >/dev/null 2>&1; rc=$?
  check "metro_env: rc 0" 0 "$rc"
  has "metro_env = FOO: the remote Metro command carries FOO" "env FOO=bar npx expo start --port 8081" "$(grep nohup "$T/log/ssh")"
  : > "$T/log/ssh"
  FOO=bar BAZ=q SIM_METRO_ENV=BAZ "$REPO/bin/sim" metro start ios >/dev/null 2>&1
  has "metro_env: SIM_METRO_ENV beats it" "env BAZ=q npx expo" "$(grep nohup "$T/log/ssh")"
  : > "$T/log/ssh"
  FOO=bar SIM_METRO_ENV='' "$REPO/bin/sim" metro start ios >/dev/null 2>&1
  has "metro_env: an empty SIM_METRO_ENV turns it off" "nohup env npx expo" "$(grep nohup "$T/log/ssh")"

  # app_dir: at the root, the app is client/; from elsewhere, where sim runs.
  cfg 'app_dir = client'
  : > "$T/log/ssh"
  "$REPO/bin/sim" metro start ios >/dev/null 2>&1
  has "app_dir: metro start ios at the root runs in client/ on the Mac" "/client && (pkill" "$(grep nohup "$T/log/ssh")"
  : > "$T/log/ssh"
  "$REPO/bin/sim" ios prepare >/dev/null 2>&1
  has "app_dir: ios prepare in client/ with the stack's command" "/client && npm ci --no-audit --no-fund && CI=1 npx expo prebuild -p ios --no-install && cd ios && pod install" "$(cat "$T/log/ssh")"
  mkdir -p "$CFG/other"; : > "$T/log/ssh"
  ( cd other && "$REPO/bin/sim" metro start ios >/dev/null 2>&1 )
  has "app_dir: only at the root" "/other && (pkill" "$(grep nohup "$T/log/ssh")"
  cfg 'app_dir = nowhere'
  "$REPO/bin/sim" metro start ios >/dev/null 2>&1; check "app_dir: a missing directory is rc 2" 2 "$?"

  # A bad file stops the commands that read it with rc 2, naming the line.
  cfg 'ports = 200'
  out=$("$REPO/bin/sim" metro start ios 2>&1); rc=$?
  check "bad config: sim metro is rc 2" 2 "$rc"
  has "bad config: ...naming the line" ".sim/config:1:" "$out"
  "$REPO/bin/sim" status >/dev/null 2>&1; check "bad config: sim status does not read it" 0 "$?"
  kill "$holder" 2>/dev/null; pkill -P "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
)

( cd "$CFG" || exit 1; rm -rf "$T/log/"*
  trap 'rm -rf "$CFG/.sim"' EXIT
  hold web "$CFG" 30; holder=$!
  wait_for "( lib; sim_held web 1 )"
  cfg 'ports = 3'
  check "ports = 3: eval gives 3 ports" "21000 3 21000 21001 21002" \
    "$(eval "$("$REPO/bin/sim" ports web)"; echo "$SIM_PORT_BASE $SIM_PORT_COUNT $SIM_PORTS")"
  check "ports = 3: a count still wins" 5 "$("$REPO/bin/sim" ports web 5 | wc -w)"
  rm -rf "$CFG/.sim"
  check "ports: without it, the whole block and no SIM_PORTS" "21000 100 unset" \
    "$(unset SIM_PORTS; eval "$("$REPO/bin/sim" ports web)"; echo "$SIM_PORT_BASE $SIM_PORT_COUNT ${SIM_PORTS-unset}")"
  kill "$holder" 2>/dev/null; pkill -P "$holder" 2>/dev/null; wait
)

# Host Metro and the build run in app_dir when sim runs at the root.
mkdir -p "$T/npxpwd"
printf '#!/bin/sh\nprintf "%%s %%s\\n" "$PWD" "$*" >> "%s/log/npx"\n' "$T" > "$T/npxpwd/npx"; chmod +x "$T/npxpwd/npx"
( cd "$CFG" || exit 1; rm -rf "$T/log/"* "$T/metro.status"; export PATH="$T/npxpwd:$PATH"
  trap 'rm -rf "$CFG/.sim"' EXIT
  hold android "$CFG" 30; holder=$!
  wait_for "( lib; sim_held android 1 )"
  cfg 'app_dir = client'
  "$REPO/bin/sim" build --variant debug >/dev/null 2>&1; rc=$?
  check "app_dir: build rc 0" 0 "$rc"
  wait_for "[ \$(wc -l < '$T/log/npx' 2>/dev/null || echo 0) -ge 2 ]"
  has "app_dir: Metro on the host runs in client/" "$CFG/client expo start --port 8101" "$(cat "$T/log/npx")"
  has "app_dir: the build runs in client/" "$CFG/client expo run:android --port 8101 --variant debug" "$(cat "$T/log/npx")"
  "$REPO/bin/sim" metro stop android >/dev/null 2>&1
  kill "$holder" 2>/dev/null; pkill -P "$holder" 2>/dev/null; wait
)

echo "# sim enable and .sim/config"
( cd "$CFG" || exit 1; rm -rf .sim
  out=$("$REPO/bin/sim" enable 2>&1)
  has "enable: wrote .sim/config" "wrote .sim/config" "$out"
  [ -f .sim/config ] && ok "enable: the template exists" || bad "enable: the template exists"
  check "enable: every key commented out" 0 "$(grep -cv '^#\|^$' .sim/config)"
  for k in stack app_dir metro_env forward_ios ports keep_runs; do
    has "enable: the template names $k" "# $k =" "$(cat .sim/config)"
  done
  ( lib; err=$(sim_repo_config "$CFG" 2>&1); check "enable: the template parses, quietly" "0 " "$? $err" )
  ( lib; sed 's/^# \([a-z_]* =\)/\1/' .sim/config > "$T/cfg.on"; cp "$T/cfg.on" .sim/config
    err=$(sim_repo_config "$CFG" 2>&1); check "enable: the defaults uncommented parse" "0 " "$? $err"
    sim_repo_config "$CFG" 2>/dev/null
    check "enable: ...and are the defaults" "expo|.|100|5" "$SIM_CFG_STACK|$SIM_CFG_APP_DIR|$SIM_CFG_PORTS|$SIM_CFG_KEEP_RUNS" )
  echo 'ports = 9' > .sim/config
  out=$("$REPO/bin/sim" enable 2>&1)
  has "enable: kept .sim/config" "kept .sim/config" "$out"
  check "enable: ...unchanged" "ports = 9" "$(cat .sim/config)"
  rm -rf .sim .mcp.json opencode.json .codex
)

echo "# the stack seam"
check "seam: bin/sim has no npx expo" "" "$(grep -n 'npx expo' "$SRC/bin/sim")"
( lib
  sim_stack_metro_cmd 8201 --web; check "seam: metro command, web" "npx expo start --port 8201 --web" "${SIM_STACK_CMD[*]}"
  sim_stack_build_android 8101 --variant debug; check "seam: android build" "npx expo run:android --port 8101 --variant debug" "${SIM_STACK_CMD[*]}"
  has "seam: rsync rules keep the Mac's ios/" "--filter=P ios/" "$(sim_stack_rsync_rules)"
  SIM_CFG_STACK=other; sim_stack_metro_cmd 1 2>/dev/null; check "seam: an unknown stack is rc 2" 2 "$?"
)
