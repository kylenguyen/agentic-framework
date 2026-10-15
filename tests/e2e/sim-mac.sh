#!/usr/bin/env bash
# tests/e2e/sim-mac.sh: the iOS path of the device simulation service (bin/sim, bin/sim-mcp, lib/sim.sh) over real
# ssh and rsync, between two Docker containers on a private network: "host" (Debian, login `agent`, this working
# tree copied to ~/af and linked into ~/.local/bin, a test worktree /w/app.wt/feat with its app in client/) and
# "mac" (Debian with sshd, login `runner` whose shell is zsh, shims for xcrun, maestro, npx and sim-xcodebuildmcp
# from tests/e2e/shims/simmac, and the real sim-maestro launcher cut out of install-ios-runner.sh). No Mac, no KVM.
# Keys are made inside the host container; nothing from the real ~/.ssh is read. A dropped Mac is
# `docker network disconnect` (mac_drop) or `docker pause` (mac_pause). The host container runs with
# net.ipv4.tcp_retries2=3, so an ssh connection whose peer vanished fails within seconds of its next write instead
# of after TCP's 15 minutes: the e2e stands for a Mac that is gone, not for a slow one.
#
# Environment:
#   AF_SIM_PREFIX  names the network ($AF_SIM_PREFIX) and containers ($AF_SIM_PREFIX-host, $AF_SIM_PREFIX-mac);
#                  default af-sim. Give each concurrent run its own. Images are shared: af-sim-host:<hash> and
#                  af-sim-mac:<hash>, the hash taken from what builds them, so a change builds anew.
#   KEEP=1         leave the containers and network running for a look afterwards (docker rm -f to clean up).
#
# Helpers for the cases (later tasks add sections below; keep each in its own `say` block):
#   hx <cmd...>        as `agent` in the host container, in /w/app.wt/feat/client, with SIM_STATE, SIM_CACHE set
#   hxi <cmd...>       the same with stdin attached (for pipes into the container)
#   mx <cmd...>        as `runner` in the mac container, in ~runner; mxz '<zsh cmd>' runs it through zsh (PATH as ssh)
#   mac_drop / mac_restore   take the mac container off the network / put it back (and wait for its sshd)
#   mac_pause / mac_unpause  freeze / thaw the mac container
#   mcp_start <s> [platform]   start a long-lived `sim-mcp <platform>` (default ios) named <s> in the host
#                      container, fed through a fifo; mcp_init <s> sends initialize; mcp_call <s> <id> <tool>
#                      [json] sends a tools/call; mcp_wait <s> <regex> [secs] waits for it on stdout; mcp_out,
#                      mcp_err <s> print them; mcp_reply <s> <id> prints one response; mcp_stop <s> closes its
#                      stdin; mcp_rc <s> [secs] waits for it to exit and prints the exit code
#   status_of <platform> <N>   that slot's line of `sim status`
# Needs docker without sudo; network only for the image builds. Target: under 3 minutes after the first build.
# Usage: [AF_SIM_PREFIX=af-sim-me] [KEEP=1] bash tests/e2e/sim-mac.sh
# shellcheck disable=SC2015,SC2016
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
E2E=$REPO/tests/e2e
PFX=${AF_SIM_PREFIX:-af-sim}
NET=$PFX; HOSTC=$PFX-host; MACC=$PFX-mac
U=agent; UH=/home/agent; AF=/home/agent/af
WT=/w/app.wt/feat; APP=$WT/client
TREE=app-feat-$(printf %s "$WT" | sha256sum | cut -c1-6)                # its directory on the Mac, sims/$TREE
STATE=/tmp/sim-state; CACHE=/tmp/sim-cache
T=$(mktemp -d); : > "$T/results"
ok()    { echo ok >> "$T/results"; printf 'ok   %s\n' "$1"; }
bad()   { echo FAIL >> "$T/results"; printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
has()   { case "$2" in *"$1"*) ok "$3";; *) bad "$3" "output lacks [$1] in [$2]";; esac; }   # has <needle> <haystack> <name>
lacks() { case "$2" in *"$1"*) bad "$3" "unexpected [$1] in [$2]";; *) ok "$3";; esac; }
say()   { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
cleanup() {
  if [ "${KEEP:-0}" = 1 ]; then echo "KEEP=1: containers $HOSTC and $MACC left running on network $NET"; rm -rf "$T"; return; fi
  docker rm -f "$HOSTC" "$MACC" >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1; rm -rf "$T"
}
trap cleanup EXIT
HENV=(-e "HOME=$UH" -e "PATH=$UH/.local/bin:/usr/local/bin:/usr/bin:/bin" -e "SIM_STATE=$STATE" -e "SIM_CACHE=$CACHE"
      -e SIM_IOS_SETTLE=0)
hx()  { docker exec -u "$U" "${HENV[@]}" -w "$APP" "$HOSTC" "$@"; }
hxi() { docker exec -i -u "$U" "${HENV[@]}" -w "$APP" "$HOSTC" "$@"; }
hxh() { docker exec -u "$U" "${HENV[@]}" -w "$UH" "$HOSTC" "$@"; }                         # in ~agent, before $APP exists
mx()  { docker exec -u runner -e HOME=/home/runner -w /home/runner "$MACC" "$@"; }
mxz() { mx zsh -c "$1"; }
run() { OUT=$("$@" 2>&1); RC=$?; }                                                          # RC is the command's
mac_ssh_ok() { hx ssh -o BatchMode=yes -o ConnectTimeout=3 runner@mac true 2>/dev/null; }
mac_drop()    { docker network disconnect "$NET" "$MACC"; }
mac_restore() {
  docker network connect --alias mac "$NET" "$MACC" || return 1
  local _; for _ in $(seq 1 30); do mac_ssh_ok && return 0; sleep 0.5; done; return 1
}
mac_pause()   { docker pause "$MACC" >/dev/null; }
mac_unpause() { docker unpause "$MACC" >/dev/null; }
status_of() { hx sim status | awk -v p="$1" -v n="$2" '$1 == p && $2 == n'; }
# A long-lived MCP session in the host container: /tmp/mcp-<s>/{in,out,err,rc}. A sleeping writer holds the fifo
# open, so the server sees EOF only when mcp_stop kills it.
mcp_start() {
  hx bash -c 'd=/tmp/mcp-$1; rm -rf "$d"; mkdir -p "$d"; mkfifo "$d/in"
    setsid sleep 100000 > "$d/in" 2>/dev/null < /dev/null & echo $! > "$d/holder"
    setsid bash -c "cd \"\$0\"; sim-mcp $2 < $d/in > $d/out 2> $d/err; echo \$? > $d/rc" "$PWD" > /dev/null 2>&1 < /dev/null &' \
    _ "$1" "${2:-ios}"
}
mcp_send()  { hx bash -c 'printf "%s\n" "$2" > "/tmp/mcp-$1/in"' _ "$1" "$2"; }
mcp_init()  {
  mcp_send "$1" '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"sim-mac","version":"1"}}}'
  mcp_send "$1" '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  mcp_wait "$1" '"id": 0,'
}
mcp_call()  { mcp_send "$1" "{\"jsonrpc\":\"2.0\",\"id\":$2,\"method\":\"tools/call\",\"params\":{\"name\":\"$3\",\"arguments\":${4:-{\}}}}"; }
mcp_wait()  { hx timeout "${3:-20}" bash -c 'until grep -qE "$2" "/tmp/mcp-$1/out" 2>/dev/null; do sleep 0.1; done' _ "$1" "$2"; }
mcp_out()   { hx cat "/tmp/mcp-$1/out"; }
mcp_err()   { hx cat "/tmp/mcp-$1/err"; }
mcp_reply() { hx jq -c --argjson id "$2" 'select(.id == $id)' "/tmp/mcp-$1/out"; }
mcp_stop()  { hx bash -c 'kill "$(cat "/tmp/mcp-$1/holder")" 2>/dev/null' _ "$1"; }
mcp_rc()    {
  hx timeout "${2:-20}" bash -c 'until [ -s "/tmp/mcp-$1/rc" ]; do sleep 0.1; done; cat "/tmp/mcp-$1/rc"' _ "$1" || echo timeout
}
calltext()  { jq -r '.result.content[0].text | fromjson | '"$1"; }                                # calltext <jq filter>, stdin a reply

say "images and containers (prefix $PFX)"
command -v docker >/dev/null || { echo "docker is required" >&2; exit 2; }
SECONDS=0
HIMG=af-sim-host:$(cat "$E2E/Dockerfile.simhost" | sha256sum | cut -c1-12)
MIMG=af-sim-mac:$(cat "$E2E/Dockerfile.simmac" "$E2E"/shims/simmac/* | sha256sum | cut -c1-12)
docker image inspect "$HIMG" >/dev/null 2>&1 \
  || docker build -q -f "$E2E/Dockerfile.simhost" -t "$HIMG" "$E2E" >/dev/null || { echo "host image build failed" >&2; exit 1; }
docker image inspect "$MIMG" >/dev/null 2>&1 \
  || docker build -q -f "$E2E/Dockerfile.simmac" -t "$MIMG" "$E2E" >/dev/null || { echo "mac image build failed" >&2; exit 1; }
docker rm -f "$HOSTC" "$MACC" >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1
docker network create "$NET" >/dev/null || { echo "could not create network $NET" >&2; exit 1; }
docker run -d --name "$MACC" --hostname mac --network "$NET" --network-alias mac "$MIMG" >/dev/null
docker run -d --name "$HOSTC" --hostname host --network "$NET" --sysctl net.ipv4.tcp_retries2=3 \
  -v "$REPO:/src:ro" "$HIMG" >/dev/null
echo "    images $HIMG $MIMG, built or found in ${SECONDS}s"

# The working tree, not a commit, so uncommitted changes are what gets tested. No .git, no .env.
hxh bash -c "set -e; mkdir -p $AF $UH/.local/bin; tar -C /src --exclude=./.git --exclude=./.env -cf - . | tar -C $AF -xf -
  ln -sf $AF/bin/sim $AF/bin/sim-mcp $UH/.local/bin/
  printf 'AGENT_IOS_HOST=mac\\nAGENT_IOS_USER=runner\\nAGENT_SIM_IOS_SLOTS=2\\n' > $AF/.env"
# The test app: /w/app (checkout) and /w/app.wt/feat (worktree), the app in client/, two .env files that must stay home.
hxh bash -c "set -e; cd /w
  git init -q -b main app && cd app && mkdir -p client/flows
  echo 'export default 1' > client/app.js; printf 'appId: test\n---\n- launchApp\n' > client/flows/login.yaml
  git add -A && git -c user.email=t@t -c user.name=t commit -q -m init
  git worktree add -q $WT -b feat
  echo SECRET=1 > $WT/.env; echo SECRET=2 > $APP/.env"
# Keys made here, for this run only; the Mac's host key goes into known_hosts, so BatchMode needs no prompt.
hxh bash -c "set -e; mkdir -p -m 700 $UH/.ssh; ssh-keygen -q -t ed25519 -N '' -f $UH/.ssh/id_ed25519
  printf 'Host mac\n  HostName mac\n  User runner\n  IdentityFile ~/.ssh/id_ed25519\n' > $UH/.ssh/config"
hx cat "$UH/.ssh/id_ed25519.pub" | docker exec -i -u runner "$MACC" sh -c 'cat > ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'
for _ in $(seq 1 30); do hx sh -c "ssh-keyscan -T 2 mac 2>/dev/null | grep ssh-ed25519 > $UH/.ssh/known_hosts" && break; sleep 0.5; done
# The real Maestro launcher, as install-ios-runner.sh writes it.
sed -n "/^cat > \"\$HOME\/.local\/bin\/sim-maestro\" <<'EOF'$/,/^EOF$/p" "$REPO/install-ios-runner.sh" | sed '1d;$d' \
  | docker exec -i -u runner "$MACC" sh -c 'cat > ~/.local/bin/sim-maestro && chmod 755 ~/.local/bin/sim-maestro'

say "setup"
mac_ssh_ok && ok "host reaches runner@mac by key, BatchMode" || { bad "host reaches runner@mac by key, BatchMode"; exit 1; }
check "the Mac's login shell is zsh" /usr/bin/zsh "$(hx ssh mac 'echo $SHELL')"
check "ssh commands find the shims through ~/.zshenv" /home/runner/.local/bin/xcrun "$(hx ssh mac 'command -v xcrun')"
has "exec maestro --device" "$(mx cat .local/bin/sim-maestro)" "the real sim-maestro launcher is installed"
check "sim status lists both ios slots free and off" "ios 1 agent-ios-1 off unused free|ios 2 agent-ios-2 off unused free" \
  "$(hx sim status | awk '$1 == "ios"' | tr -s ' ' | paste -sd'|')"
has "sim contract 2; maestro " "$(hx sim version)" "sim version prints the contract and the pins"
check "sim status --json: both ios slots off, no lease, no tunnel" "ios 1 off null []|ios 2 off null []" \
  "$(hx sim status --json | jq -r '.[] | select(.platform == "ios") | "\(.platform) \(.slot) \(.state) \(.lease) \(.tunnel)"' | paste -sd'|')"

say "shims"
mxz 'nohup npx expo start --port 8095 > /dev/null 2>&1 < /dev/null &'
for _ in $(seq 1 30); do [ "$(mx curl -fsS localhost:8095/status 2>/dev/null)" = packager-status:running ] && break; sleep 0.2; done
check "npx expo start serves /status" packager-status:running "$(mx curl -fsS localhost:8095/status 2>/dev/null)"
mxz "pkill -f 'expo start.*--port 8095'" && ok "pkill -f 'expo start.*--port P' finds it" || bad "pkill -f 'expo start.*--port P' finds it"
check "pkill spares the ssh command's own shell, as on macOS" alive "$(hx ssh mac "pkill -f 'expo start.*--port 8099'; echo alive")"
check "xcrun: a simulator starts Shutdown" "    agent-ios-2 (00000002-AAAA-4BBB-8CCC-DDDDDDDDDDDD) (Shutdown) " \
  "$(mxz 'xcrun simctl list devices' | grep agent-ios-2)"

say "sim ios sync"
run hx sim ios sync
check "sync: exit 0" 0 "$RC"
has "synced to /home/runner/sims/$TREE/client on the Mac" "$OUT" "sync: prints the app's path on the Mac"
check "sync: the tree is ~runner/sims/$TREE" "app.js flows" "$(mx ls "sims/$TREE/client" | paste -sd' ')"
check "sync: no .env arrives, at the top or in the app" "" "$(mx find "sims/$TREE" -name '.env*')"
check "sync: no .git arrives" "" "$(mx find "sims/$TREE" -maxdepth 1 -name .git)"
hx sh -c 'echo "export default 2" > app.js'
hx sim ios sync >/dev/null 2>&1
check "sync: a second sync carries the edit" "export default 2" "$(mx cat "sims/$TREE/client/app.js")"

say "sim-mcp ios through tests/mcp-probe.mjs"
run hx node "$AF/tests/mcp-probe.mjs" --call screenshot '{}' -- sim-mcp ios
check "probe: exit 0" 0 "$RC"
check "probe: lists 2 tools" '{"tools":["screenshot","session_set_defaults"]}' "$(printf '%s\n' "$OUT" | grep '^{"tools"')"
call=$(printf '%s\n' "$OUT" | grep '^{"call"')
check "probe: the call returns the stub's echo" 'screenshot 1 1' \
  "$(printf '%s' "$call" | hxi jq -r '.text | fromjson | "\(.tool) \(.calls) \(.slot)"')"
has "ios slot 1 leased for $WT" "$OUT" "probe: sim-mcp says which slot it leased, for which worktree"
check "probe: the call booted agent-ios-1 first" Booted "$(mx cat simstate/agent-ios-1)"
has "start slot=1" "$(mx cat xcodebuildmcp.log)" "probe: the Mac launcher ran with the slot number"
check "probe: the lease is freed when the probe ends" free "$(status_of ios 1 | awk '{print $NF}')"

say "a long-lived sim-mcp ios session"
mcp_start s1 ios
mcp_init s1 && ok "session: initialize answered" || bad "session: initialize answered" "$(mcp_err s1)"
st=$(status_of ios 1)
has "leased" "$st" "session: sim status shows ios 1 leased while it runs"
has "$WT" "$st" "session: ...by this worktree"
mcp_call s1 1 screenshot; mcp_call s1 2 session_set_defaults '{"x":1}'
mcp_wait s1 '"id": 2,' || bad "session: two calls answered" "$(mcp_err s1)"
r1=$(mcp_reply s1 1 | hxi jq -r '.result.content[0].text | fromjson | "\(.calls) \(.pid)"')
r2=$(mcp_reply s1 2 | hxi jq -r '.result.content[0].text | fromjson | "\(.tool) \(.arguments.x) \(.calls) \(.pid)"')
check "session: the second call reaches the same server process" "session_set_defaults 1 2 ${r1#* }" "$r2"

say "sim maestro ios (session s1 holds the lease)"
mx sh -c 'echo 1 > maestro.rc'
run hx sim maestro ios test flows/
check "maestro: the flow's exit code comes back (1)" 1 "$RC"
RUN1=$(hx readlink "$CACHE/ios/maestro-1/latest"); RUN1=${RUN1#runs/}
has "maestro run $RUN1: $CACHE/ios/maestro-1/runs/$RUN1" "$OUT" "maestro: says where the run's directory is"
check "maestro: ran in the synced app directory" "/home/runner/sims/$TREE/client" "$(mx cat maestro.cwd)"
check "maestro: the device from the launcher, the output dirs from the host" \
  "--device 00000001-AAAA-4BBB-8CCC-DDDDDDDDDDDD test --debug-output /home/runner/.cache/agent-sim/maestro-1/runs/$RUN1/debug --test-output-dir /home/runner/.cache/agent-sim/maestro-1/runs/$RUN1/output flows/" \
  "$(mx tail -1 maestro.log)"
check "maestro: debug files arrived on the host" "debug/maestro.log debug/screenshot-failed.png output/maestro.log output/screenshot-failed.png" \
  "$(hx sh -c "cd $CACHE/ios/maestro-1/latest/ && find debug output -type f | sort" | paste -sd' ')"
mx sh -c 'echo 0 > maestro.rc'
run hx sim maestro ios test "$APP/flows/login.yaml"
check "maestro: a passing run exits 0" 0 "$RC"
check "maestro: an absolute path in the worktree is rewritten for the Mac" flows/login.yaml "$(mx tail -1 maestro.log | awk '{print $NF}')"

say "sim reap of an idle simulator"
hx touch -d '2 minutes ago' "$STATE/ios/1.active"
run hx env AGENT_SIM_IDLE_MINUTES=1 sim reap
has "ios 1: agent-ios-1 shut down, unused for 2 min" "$OUT" "reap: says it shut agent-ios-1 down"
check "reap: xcrun simctl shutdown ran on the Mac" "simctl shutdown agent-ios-1" "$(mx grep shutdown xcrun.log | tail -1)"
check "reap: agent-ios-1 is Shutdown" Shutdown "$(mx cat simstate/agent-ios-1)"
has " off " "$(status_of ios 1)" "reap: sim status shows ios 1 off"
run hx env AGENT_SIM_IDLE_MINUTES=1 sim reap
lacks "ios 1" "$OUT" "reap: a second round leaves the down simulator alone"
mcp_call s1 3 screenshot
mcp_wait s1 '"id": 3,' && ok "reap: the next tool call is answered" || bad "reap: the next tool call is answered" "$(mcp_err s1)"
check "reap: ...after booting agent-ios-1 again" Booted "$(mx cat simstate/agent-ios-1)"
has " booted " "$(status_of ios 1)" "reap: and sim status shows it booted"

say "the Mac drops off during sim-mcp ios: the session and its lease survive (T8)"
# Default reconnect schedule (5, 10, 30, then every 60 s). The Mac is cached as up, so the next call passes the wake
# and goes into the dead link: the write fails within seconds (tcp_retries2=3), ssh exits, the relay answers the call.
holder=$(status_of ios 1 | grep -o 'pid [0-9]*')
mac_drop && ok "drop: mac disconnected from $NET" || bad "drop: mac disconnected from $NET"
hx bash -c 'echo "up $(date +%s)" > "$1/ios/mac.state"' _ "$STATE"
mcp_call s1 4 screenshot
mcp_wait s1 '"id": ?4,' 60 || bad "drop: the call in flight is answered" "$(mcp_err s1)"
has "reconnecting" "$(mcp_reply s1 4)" "drop: the call in flight gets a tool error saying it is reconnecting"
check "drop: ...as isError" true "$(mcp_reply s1 4 | hxi jq -r .result.isError)"
mcp_call s1 5 screenshot
mcp_wait s1 '"id": ?5,' 10
has "mac unreachable (runner@mac), reconnecting, attempt" "$(mcp_reply s1 5)" "drop: a call during the outage gets the reconnecting error"
st=$(status_of ios 1)
has "leased" "$st" "drop: sim status still shows ios 1 leased"
check "drop: ...by the same sim-mcp" "$holder" "$(printf '%s' "$st" | grep -o 'pid [0-9]*')"
has "down" "$(hx cat "$STATE/ios/mac.state")" "drop: the Mac is cached as down"
mac_restore && ok "drop: the link comes back" || bad "drop: the link comes back"
SECONDS_AT=$SECONDS
hx timeout 70 bash -c 'until grep -q "reconnected to runner@mac after" /tmp/mcp-s1/err; do sleep 0.5; done' \
  && ok "drop: reconnected within 70 s of the link coming back ($((SECONDS - SECONDS_AT))s)" \
  || bad "drop: reconnected within 70 s of the link coming back" "$(mcp_err s1)"
mcp_call s1 6 screenshot
mcp_wait s1 '"id": ?6,' 40 || bad "drop: a call after the reconnect is answered" "$(mcp_err s1)"
r6=$(mcp_reply s1 6 | hxi jq -r '.result.content[0].text | fromjson | "\(.calls) \(.inits) \(.pid)"')
check "drop: the new server had initialize and session_set_defaults replayed (calls 2, inits 1)" "2 1" "${r6% *}"
[ -n "${r6##* }" ] && [ "${r6##* }" != "${r1#* }" ] && ok "drop: ...and is a new process (pid ${r1#* } -> ${r6##* })" \
  || bad "drop: ...and is a new process" "[$r6] vs [$r1]"
check "drop: the Mac's log shows initialize, the replay, then the call on the new server" \
  "initialize|call session_set_defaults|call screenshot" \
  "$(mx grep "pid=${r6##* }$" xcodebuildmcp.log | grep -v start | sed 's/ slot=.*//' | paste -sd'|')"
lacks "sim-replay" "$(mcp_out s1)" "drop: the harness never sees a sim-replay id"
check "drop: sim status still shows the same holder" "$holder" "$(status_of ios 1 | grep -o 'pid [0-9]*')"
mcp_stop s1
check "drop: the session ends cleanly" 0 "$(mcp_rc s1 20)"
check "drop: the lease is freed when it ends" free "$(status_of ios 1 | awk '{print $NF}')"

say "remote paths: a worktree with a space and a ' in its paths"
# /w/my app.wt/feat with its app in o'k app/: the tree name drops the space, the app directory keeps both.
WT2="/w/my app.wt/feat"; APP2="$WT2/o'k app"; TREE2=my_app-feat-$(printf %s "$WT2" | sha256sum | cut -c1-6)
hxh bash -c 'set -e; cd /w/app; git worktree add -q "$1" -b feat2; mkdir -p "$2/flows"
  printf "appId: test\n---\n- launchApp\n" > "$2/flows/login.yaml"; touch -d "10 days ago" "$1"' _ "$WT2" "$APP2"
h2() { docker exec -u "$U" "${HENV[@]}" -w "$APP2" "$HOSTC" "$@"; }
run h2 sim ios sync
check "paths: sync exits 0" 0 "$RC"
has "synced to /home/runner/sims/$TREE2/o'k app on the Mac" "$OUT" "paths: sync prints the hashed tree and the app"
check "paths: the app arrived" "flows" "$(mx ls "sims/$TREE2/o'k app")"
mx test -e "sims/$TREE2/.agent-sim-synced" && ok "paths: sync left its stamp" || bad "paths: sync left its stamp"
run h2 sim lease ios
has "leased for $WT2" "$OUT" "paths: sim lease ios for the worktree"
mx sh -c 'echo 0 > maestro.rc'
run h2 sim maestro ios test flows/
check "paths: maestro exits 0" 0 "$RC"
check "paths: maestro ran in the app directory, through zsh" "/home/runner/sims/$TREE2/o'k app" "$(mx cat maestro.cwd)"
run h2 sim maestro ios test "$APP2/flows/login.yaml"
check "paths: an absolute path in it is rewritten" flows/login.yaml "$(mx tail -1 maestro.log | awk '{print $NF}')"
run h2 sim release ios
say "sim ios gc goes by the sync stamp"
check "gc: the Mac's tree has the worktree's old mtime (rsync -a)" 1 "$(mx find sims -maxdepth 1 -name "$TREE2" -mtime +7 | wc -l)"
run hx sim ios gc 0
check "gc 0: exit 0" 0 "$RC"
mx test -d "sims/$TREE2" && ok "gc 0: keeps a tree synced just now" || bad "gc 0: keeps a tree synced just now" "$OUT"
run hx sim ios gc 7
mx test -d "sims/$TREE2" && ok "gc 7: keeps it though its mtime is 10 days old" || bad "gc 7: keeps it though its mtime is 10 days old" "$OUT"
mx touch -d '10 days ago' "sims/$TREE2/.agent-sim-synced"
run hx sim ios gc 7
mx test -d "sims/$TREE2" && bad "gc 7: removes it once its stamp is 10 days old" "$OUT" || ok "gc 7: removes it once its stamp is 10 days old"
has "sims/$TREE2" "$OUT" "gc 7: says which tree it removed"
mx test -d "sims/$TREE" && ok "gc 7: leaves the other worktree's tree" || bad "gc 7: leaves the other worktree's tree"

say "a frozen Mac: probe, status and exit 3"
# docker pause: the Mac's kernel still accepts connections, nothing answers on them. The shared ssh master from the
# commands above (ControlPersist) is still open and would hang a command for a minute; the probe never uses it.
masters() { hx bash -c 'n=0; for s in "$1"/ios/ssh-*; do [ -S "$s" ] && n=$((n + 1)); done; echo $n' _ "$STATE"; }
hx sim ios sync >/dev/null 2>&1
check "frozen: a shared ssh master is open before the freeze" 1 "$(masters)"
mac_pause
SECONDS_AT=$SECONDS; st=$(status_of ios 1); took=$((SECONDS - SECONDS_AT))
has " unreachable " "$st" "frozen: sim status shows ios unreachable"
[ "$took" -le 8 ] && ok "frozen: ...within 8 s (${took}s)" || bad "frozen: ...within 8 s" "took ${took}s"
check "frozen: the stale master is dropped" 0 "$(masters)"
SECONDS_AT=$SECONDS; run hx sim maestro ios test flows/; took=$((SECONDS - SECONDS_AT))
check "frozen: sim maestro ios exits 3" 3 "$RC"
has "mac unreachable" "$OUT" "frozen: ...saying the Mac is unreachable"
[ "$took" -le 10 ] && ok "frozen: ...within 10 s (${took}s)" || bad "frozen: ...within 10 s" "took ${took}s"
run hx sim ios sync
check "frozen: sim ios sync exits 3 too" 3 "$RC"
mac_unpause
st=$(status_of ios 1)
case $st in *" booted "*|*" off "*) ok "thawed: sim status shows ios booted or off again" ;;
  *) bad "thawed: sim status shows ios booted or off again" "$st" ;; esac
run hx sim ios sync
check "thawed: sim ios sync works again" 0 "$RC"

say "sim-mcp ios: a simulator that does not boot (relay)"
mx sh -c 'echo Shutdown > simstate/agent-ios-1; touch bootstatus.fail'
mcp_start s2 ios
mcp_init s2 && ok "no boot: initialize answered" || bad "no boot: initialize answered" "$(mcp_err s2)"
mcp_call s2 1 screenshot
mcp_wait s2 '"id":1,' 40 || bad "no boot: the call is answered" "$(mcp_err s2)"
r=$(mcp_reply s2 1)
check "no boot: the call gets a tool error" true "$(printf '%s' "$r" | hxi jq -r .result.isError)"
has "could not boot agent-ios-1" "$(printf '%s' "$r" | hxi jq -r '.result.content[0].text')" "no boot: its text says the simulator could not boot"
lacks "call screenshot" "$(mx cat xcodebuildmcp.log | tail -1)" "no boot: the call never reached XcodeBuildMCP"
mx rm -f bootstatus.fail
mcp_call s2 2 screenshot
mcp_wait s2 '"id": 2,' 40 && ok "no boot: the next call boots it and is answered" || bad "no boot: the next call boots it and is answered" "$(mcp_err s2)"
check "no boot: agent-ios-1 is Booted again" Booted "$(mx cat simstate/agent-ios-1)"
mcp_stop s2
check "no boot: the session ends cleanly" 0 "$(mcp_rc s2 20)"

say "sim maestro ios: run directories and reports brought home"
run hx sim lease ios
has "leased for $WT" "$OUT" "runs: sim lease ios for the worktree"
hx rm -rf "$APP/e2e"
mx sh -c 'echo 1 > maestro.rc'
run hx sim maestro ios test flows/ --output e2e/report.xml
check "runs: the first run's rc is Maestro's (1)" 1 "$RC"
R1=$(hx readlink "$CACHE/ios/maestro-1/latest"); R1=${R1#runs/}
check "runs: the report arrives in the host worktree" '<testsuites/>' "$(hx cat "$APP/e2e/report.xml" 2>/dev/null)"
has "--output /home/runner/.cache/agent-sim/maestro-1/runs/$R1/artifacts/client/e2e/report.xml" "$(mx tail -1 maestro.log)" \
  "runs: Maestro wrote it into the run's artifacts on the Mac"
mx sh -c 'echo 0 > maestro.rc'
hx rm -f "$APP/e2e/report.xml"
run hx sim maestro ios test flows/ --output e2e/report.xml
check "runs: the second run exits 0" 0 "$RC"
R2=$(hx readlink "$CACHE/ios/maestro-1/latest"); R2=${R2#runs/}
[ -n "$R1" ] && [ -n "$R2" ] && [ "$R1" != "$R2" ] && ok "runs: latest moved to the second run" || bad "runs: latest moved to the second run" "$R1 $R2"
hx test -d "$CACHE/ios/maestro-1/runs/$R1/debug" && hx test -d "$CACHE/ios/maestro-1/runs/$R2/debug" \
  && ok "runs: both run directories are on the host, with their debug output" || bad "runs: both run directories are on the host, with their debug output"
check "runs: cmd.txt records each rc" "rc: 1 rc: 0" \
  "$(hx sh -c "tail -qn1 $CACHE/ios/maestro-1/runs/$R1/cmd.txt $CACHE/ios/maestro-1/runs/$R2/cmd.txt" | paste -sd' ')"
check "runs: the report is in the host worktree again" '<testsuites/>' "$(hx cat "$APP/e2e/report.xml" 2>/dev/null)"
check "runs: the Mac keeps the last 3 runs" "3" "$(mx sh -c 'ls .cache/agent-sim/maestro-1/runs | wc -l' | tr -d ' ')"
mx test -d ".cache/agent-sim/maestro-1/runs/$R2" && ok "runs: ...the newest among them" || bad "runs: ...the newest among them"

say "sim metro start ios: environment and readiness (the lease above still held)"
Q="a b'c\"d \$HOME \\x"
run hx env EXPO_PUBLIC_API_URL=http://127.0.0.1:22000 sim metro start ios --env "E2E_Q=$Q"
check "metro: exit 0" 0 "$RC"
has "env: EXPO_PUBLIC_API_URL, E2E_Q" "$OUT" "metro: prints the names it passes"
has "Metro ready on port" "$OUT" "metro: returns once Metro answers"
check "metro: EXPO_PUBLIC_API_URL reached npx on the Mac" EXPO_PUBLIC_API_URL=http://127.0.0.1:22000 \
  "$(mx grep '^EXPO_PUBLIC_API_URL=' npx.env)"
check "metro: a value with a space, quotes, \$ and \\ survives env and zsh" "E2E_Q=$Q" "$(mx grep '^E2E_Q=' npx.env)"
run hx sim metro start ios --env 1X=y
check "metro: a bad --env name is rc 2" 2 "$RC"
SECONDS_AT=$SECONDS
run hx env SIM_METRO_READY_TIMEOUT=3 sim metro start ios --env E2E_NPX_NOSERVE=1
took=$((SECONDS - SECONDS_AT))
check "metro: no answer within SIM_METRO_READY_TIMEOUT is rc 1" 1 "$RC"
has "did not answer within 3 s" "$OUT" "metro: ...saying so"
has "metro stub: not serving" "$OUT" "metro: ...with the end of the Mac's Metro log"
[ "$took" -le 12 ] && ok "metro: ...within the timeout and a few seconds (${took}s)" || bad "metro: ...within the timeout and a few seconds" "took ${took}s"
run hx sim metro stop ios
run hx sim release ios

say "sim tunnel ios and sim maestro ios --forward: host services on the Mac"
# Two web servers on the host, on the first two ports of the slot's block; the Mac reaches them only through a tunnel.
# mac_listens <port>: "open" while the port takes connections on the Mac. Not lsof: as the runner it cannot see
# sshd's forward listeners (sshd is not dumpable), which is why sim tunnel probes by connecting too.
mac_listens() { mx bash -c 'exec 3<>"/dev/tcp/127.0.0.1/$1"' _ "$1" 2>/dev/null && echo open; }
run hx sim lease ios
has "leased for $WT" "$OUT" "tunnel: sim lease ios for the worktree"
P1=$(hx sim ports ios 1); P2=$((P1 + 1))
for p in "$P1" "$P2"; do docker exec -d -u "$U" -w /w "$HOSTC" python3 -m http.server --bind 127.0.0.1 "$p"; done
for _ in $(seq 1 30); do hx curl -fs "127.0.0.1:$P2" >/dev/null 2>&1 && break; sleep 0.2; done
check "tunnel: nothing listens on the Mac at $P1 before" "" "$(mac_listens "$P1")"
check "tunnel: ...nor at $P2" "" "$(mac_listens "$P2")"
SECONDS_AT=$SECONDS; run hx timeout 30 sim tunnel ios "$P1" --background; took=$((SECONDS - SECONDS_AT))
check "tunnel --background: exit 0" 0 "$RC"
has "tunnel up: Mac 127.0.0.1:$P1 -> host 127.0.0.1:$P1" "$OUT" "tunnel --background: says it is up"
[ "$took" -le 10 ] && ok "tunnel --background: returns at once, detached (${took}s)" || bad "tunnel --background: returns at once" "took ${took}s"
has "Directory listing" "$(mx curl -s "127.0.0.1:$P1")" "tunnel: the Mac reaches the host's server at 127.0.0.1:$P1"
check "tunnel: the Mac takes connections on $P1 (the probe the checks below use)" open "$(mac_listens "$P1")"
has "tunnel $P1" "$(status_of ios 1)$(status_of ios 2)" "tunnel: sim status shows it"
run hx sim tunnel ios "$P1"
check "tunnel: a second one on the port is rc 1" 1 "$RC"
has "port $P1 already bound on the Mac by" "$OUT" "tunnel: ...saying the port is already bound"
# The shared ssh master goes away (ControlPersist ends, or a drop kills it); the tunnel has a connection of its own.
hx bash -c 'for s in "$1"/ios/ssh-*; do [ -S "$s" ] && ssh -o ControlPath="$s" -O exit runner@mac; done' _ "$STATE" >/dev/null 2>&1
has "Directory listing" "$(mx curl -s "127.0.0.1:$P1")" "tunnel: outlives the shared ssh master"
mx sh -c "echo http://127.0.0.1:$P2/ > maestro.curl; echo 0 > maestro.rc; rm -f maestro.curl.rc maestro.curl.out"
run hx sim maestro ios --forward "$P2" test flows/
check "maestro --forward: exit 0" 0 "$RC"
has "tunnel up: Mac 127.0.0.1:$P2" "$OUT" "maestro --forward: says the tunnel is up"
check "maestro --forward: the flow's HTTP call reached the host" 0 "$(mx cat maestro.curl.rc 2>/dev/null)"
has "Directory listing" "$(mx cat maestro.curl.out 2>/dev/null)" "maestro --forward: ...and got the host's answer"
lacks "forward" "$(mx tail -1 maestro.log)" "maestro --forward: Maestro never sees --forward"
for _ in $(seq 1 20); do [ -z "$(mac_listens "$P2")" ] && break; sleep 0.25; done
check "maestro --forward: the tunnel is gone after the run" "" "$(mac_listens "$P2")"
# forward_ios in the worktree's .sim/config: the same run without --forward.
mx rm -f maestro.curl.rc maestro.curl.out
hx bash -c 'mkdir -p "$1/.sim" && printf "forward_ios = %s\n" "$2" > "$1/.sim/config"' _ "$WT" "$P2"
run hx sim maestro ios test flows/
check "maestro, forward_ios from .sim/config: exit 0" 0 "$RC"
has "tunnel up: Mac 127.0.0.1:$P2" "$OUT" "maestro, forward_ios from .sim/config: the tunnel is up"
check "maestro, forward_ios from .sim/config: the flow's HTTP call reached the host" 0 "$(mx cat maestro.curl.rc 2>/dev/null)"
hx rm -rf "$WT/.sim"
for _ in $(seq 1 20); do [ -z "$(mac_listens "$P2")" ] && break; sleep 0.25; done
mx rm -f maestro.curl maestro.curl.rc maestro.curl.out
run hx sim tunnel ios --stop
check "tunnel --stop: exit 0" 0 "$RC"
for _ in $(seq 1 20); do [ -z "$(mac_listens "$P1")" ] && break; sleep 0.25; done
check "tunnel --stop: the Mac no longer listens on $P1" "" "$(mac_listens "$P1")"
lacks "tunnel" "$(status_of ios 1)$(status_of ios 2)" "tunnel --stop: sim status shows none"
run hx env SIM_TUNNEL_WATCH=1 sim tunnel ios "$P1" --background
check "tunnel: a new one with a 1 s watcher" 0 "$RC"
run hx sim release ios
for _ in $(seq 1 40); do [ -z "$(mac_listens "$P1")" ] && break; sleep 0.25; done
check "tunnel: closed once the lease is released" "" "$(mac_listens "$P1")"
for _ in $(seq 1 20); do [ -z "$(hx bash -c 'ls "$1"/ios/*.tunnel 2>/dev/null' _ "$STATE")" ] && break; sleep 0.25; done
check "tunnel: ...and its pidfile removed" "" "$(hx bash -c 'ls "$1"/ios/*.tunnel 2>/dev/null' _ "$STATE")"
hx pkill -f 'http.server' >/dev/null 2>&1
say "sim doctor ios against the fake Mac"
run hx sim doctor ios 1
check "doctor: rc 0" 0 "$RC"
has "ok    ios     1  mac            mac up, answered in " "$OUT" "doctor: the probe and its round trip"
has "ok    ios     1  launcher       sim-maestro contract 2" "$OUT" "doctor: the real launcher's contract"
has "ok    ios     1  simulator      agent-ios-1 " "$OUT" "doctor: the simulator and its state"
has "ok    ios     1  xcodebuildmcp  2.7.0" "$OUT" "doctor: xcodebuildmcp at the pin"
has "ok    ios     1  maestro        2.11.0" "$OUT" "doctor: maestro at the pin"
has "ok    ios     1  runtime        iOS 26.0" "$OUT" "doctor: the runtime"
has "ios     1  disk" "$OUT" "doctor: the Mac's free disk"
run hx sim doctor ios 1 --json
check "doctor --json: rc 0" 0 "$RC"
check "doctor --json: the same checks as objects, all ok on slot 1" "ok ios 1 mac" \
  "$(jq -r '([.[] | "\(.level) \(.platform) \(.slot)"] | unique | join(",")) + " " + .[0].check' <<<"$OUT" 2>&1)"
before=$(mx cat xcrun.log | grep -cv '^list ')
mac_pause
SECONDS_AT=$SECONDS; run hx sim doctor ios 1; took=$((SECONDS - SECONDS_AT))
check "doctor frozen: rc 1" 1 "$RC"
has "fail  ios     1  mac            unreachable" "$OUT" "doctor frozen: fail ... unreachable"
[ "$took" -le 10 ] && ok "doctor frozen: within 10 s (${took}s)" || bad "doctor frozen: within 10 s" "took ${took}s"
mac_unpause
check "doctor: changed nothing on the Mac (only simctl list)" "$before" "$(mx cat xcrun.log | grep -cv '^list ')"

pass=$(grep -c '^ok$' "$T/results"); fail=$(grep -c '^FAIL$' "$T/results")
printf '\n%d passed, %d failed (%ds)\n' "$pass" "$fail" "$SECONDS"
[ "$fail" = 0 ]
