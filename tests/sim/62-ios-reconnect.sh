# shellcheck shell=bash
# Sourced by tests/sim-test.sh after tests/sim/harness.sh; see its header.
# shellcheck disable=SC2015,SC2016,SC2030,SC2031,SC2154
echo "# ios reconnect (bin/sim-mcp-relay.mjs --reconnect, sim _mac)"
# The Mac's MCP server, faked in node behind the ssh shim ($T/mcp.fake): logs "<pid> <message>" to $T/log/fake.in,
# answers initialize, tools/list and tools/call (text: {"tool","calls","pid"}). It exits 255 on the message numbered
# by $T/die.after, without answering it, and removes that file, so a later spawn works. While $T/ssh.down exists the
# ssh shim fails every spawn with 255, as a Mac off the network does.
cat > "$T/mcp.fake" <<EOF
const fs = require('fs');
const T = '$T', pid = process.pid;
let n = 0, calls = 0, dieAfter = 0;
try { dieAfter = parseInt(fs.readFileSync(T + '/die.after', 'utf8'), 10) || 0; } catch {}
const send = (m) => process.stdout.write(JSON.stringify(m) + '\n');
require('readline').createInterface({ input: process.stdin }).on('line', (l) => {
  fs.appendFileSync(T + '/log/fake.in', pid + ' ' + l + '\n');
  let m; try { m = JSON.parse(l); } catch { return; }
  if (dieAfter && ++n >= dieAfter) { fs.rmSync(T + '/die.after', { force: true }); process.exit(255); }
  if (m.id === undefined) return;
  if (m.method === 'initialize') send({ jsonrpc: '2.0', id: m.id, result: { protocolVersion: '2025-06-18', capabilities: { tools: {} }, serverInfo: { name: 'fake', version: '0' } } });
  else if (m.method === 'tools/list') send({ jsonrpc: '2.0', id: m.id, result: { tools: [{ name: 'screenshot' }, { name: 'session_set_defaults' }] } });
  else if (m.method === 'tools/call') { calls++; send({ jsonrpc: '2.0', id: m.id, result: { content: [{ type: 'text', text: JSON.stringify({ tool: m.params.name, calls, pid }) }] } }); }
  else send({ jsonrpc: '2.0', id: m.id, error: { code: -32601, message: 'no ' + m.method } });
}).on('close', () => process.exit(0));
EOF
rc_init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}'
rc_inited='{"jsonrpc":"2.0","method":"notifications/initialized"}'
rc_call() { printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":%s}}' "$1" "$2" "${3:-{\}}"; }
rc_reply() { jq -c --argjson id "$1" 'select(.id == $id)' "$T/log/out" 2>/dev/null; }
rc_text() { rc_reply "$1" | jq -r '.result.content[0].text' 2>/dev/null; }
# rc_start: sim-mcp ios in the background reading $T/rc.in, written through fd 7; MCP is its pid
rc_start() {
  rm -f "$T/rc.in"; mkfifo "$T/rc.in"
  "$REPO/bin/sim-mcp" ios < "$T/rc.in" > "$T/log/out" 2> "$T/log/err" &
  MCP=$!
  exec 7> "$T/rc.in"
}
rc_send() { printf '%s\n' "$1" >&7; }
held() { ( lib; sim_held ios 1 ) && echo held || echo free; }

( cd "$T/ws/app" || exit 1; rm -f "$T/log/"* "$T/state/ios/mac.state" "$T/state/ios/1.booted" "$T/ssh.down"
  export SIM_RECONNECT_DELAYS=0.2,0.2,0.5
  echo 5 > "$T/die.after"                 # initialize, initialized, tools/list, session_set_defaults, then the 5th
  rc_start
  rc_send "$rc_init"; rc_send "$rc_inited"; rc_send '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
  rc_send "$(rc_call 3 session_set_defaults '{"x":1}')"
  wait_for '[ -n "$(rc_reply 3)" ]' || bad "reconnect: the first calls are answered" "$(cat "$T/log/err")"
  pid1=$(rc_text 3 | jq -r .pid)
  h=$(held)
  touch "$T/ssh.down"
  rc_send "$(rc_call 4 screenshot)"       # forwarded (the Mac is cached as up), and the server dies on it
  wait_for '[ -n "$(rc_reply 4)" ]'
  check "reconnect: a call in flight when the server dies is answered with a tool error" true \
    "$(rc_reply 4 | jq -r .result.isError)"
  has "reconnect: ...saying it is reconnecting" "sim: mac unreachable (bob@mini.tail.ts.net), reconnecting, attempt" "$(rc_text 4)"
  rc_send "$(rc_call 5 screenshot)"
  wait_for '[ -n "$(rc_reply 5)" ]'
  check "reconnect: a call during the outage gets isError" true "$(rc_reply 5 | jq -r .result.isError)"
  has "reconnect: ...containing reconnecting and the attempt" "reconnecting, attempt " "$(rc_text 5)"
  has "reconnect: ...and when to try again" "try again in about a minute (sim status)" "$(rc_text 5)"
  rc_send '{"jsonrpc":"2.0","id":6,"method":"tools/list"}'; rc_send '{"jsonrpc":"2.0","id":7,"method":"ping"}'
  rc_send '{"jsonrpc":"2.0","id":8,"method":"resources/list"}'
  wait_for '[ -n "$(rc_reply 8)" ]'
  check "reconnect: tools/list during the outage returns the cached tools" "screenshot session_set_defaults" \
    "$(rc_reply 6 | jq -r '[.result.tools[].name] | join(" ")')"
  check "reconnect: ping during the outage gets {}" '{}' "$(rc_reply 7 | jq -c .result)"
  check "reconnect: another request gets error -32000" -32000 "$(rc_reply 8 | jq -r .error.code)"
  has "reconnect: ...with the same text" "reconnecting, attempt" "$(rc_reply 8 | jq -r .error.message)"
  h="$h $(held)"
  check "reconnect: the Mac is cached as down after the drop (sim _mac down)" down \
    "$(cut -d' ' -f1 "$T/state/ios/mac.state" 2>/dev/null)"
  sleep 1; h="$h $(held)"
  [ "$(grep -c sim-xcodebuildmcp "$T/log/ssh")" -ge 3 ] && ok "reconnect: it keeps trying while the Mac is gone" \
    || bad "reconnect: it keeps trying while the Mac is gone" "$(cat "$T/log/ssh")"
  rm -f "$T/ssh.down"
  wait_for 'grep -q "reconnected to bob@mini.tail.ts.net after" "$T/log/err"' \
    && ok "reconnect: logs reconnected to <host> after Xs" || bad "reconnect: logs reconnected to <host> after Xs" "$(cat "$T/log/err")"
  h="$h $(held)"
  # The relay logs "reconnected" and then runs its --on-up hook, which finishes on its own time.
  wait_for '[ "$(cut -d" " -f1 "$T/state/ios/mac.state" 2>/dev/null)" = up ]'
  check "reconnect: the Mac is cached as up again (sim _mac up)" up "$(cut -d' ' -f1 "$T/state/ios/mac.state" 2>/dev/null)"
  boots=$(grep -c 'simctl bootstatus agent-ios-1' "$T/log/ssh")
  rc_send "$(rc_call 9 screenshot)"
  wait_for '[ -n "$(rc_reply 9)" ]'
  r=$(rc_text 9)
  pid2=$(jq -r .pid <<< "$r")
  [ -n "$pid2" ] && [ "$pid2" != "$pid1" ] && ok "reconnect: the next call reaches a new server" || bad "reconnect: the next call reaches a new server" "$r"
  check "reconnect: ...which had the session's defaults replayed first (call 2 there)" "screenshot 2" "$(jq -r '"\(.tool) \(.calls)"' <<< "$r")"
  check "reconnect: the new server saw initialize, initialized, session_set_defaults, then the call" \
    "initialize notifications/initialized session_set_defaults screenshot" \
    "$(awk -v p="$pid2" '$1 == p { sub(/^[0-9]+ /, ""); print }' "$T/log/fake.in" | jq -r '.params.name // .method' | paste -sd' ')"
  check "reconnect: the replayed call carries the arguments it had" '{"x":1}' \
    "$(awk -v p="$pid2" '$1 == p { sub(/^[0-9]+ /, ""); print }' "$T/log/fake.in" | jq -c 'select(.params.name == "session_set_defaults") | .params.arguments')"
  check "reconnect: the replayed initialize is the client's own" '"t"' \
    "$(awk -v p="$pid2" '$1 == p { sub(/^[0-9]+ /, ""); print }' "$T/log/fake.in" | jq -c 'select(.method == "initialize") | .params.clientInfo.name')"
  check "reconnect: the next wake checks the simulator again (booted mark removed)" $((boots + 1)) \
    "$(grep -c 'simctl bootstatus agent-ios-1' "$T/log/ssh")"
  lacks "reconnect: the harness never sees a sim-replay id" "sim-replay" "$(cat "$T/log/out")"
  check "reconnect: every request got exactly one answer" "1 2 3 4 5 6 7 8 9" "$(jq -r .id "$T/log/out" | sort -n | paste -sd' ')"
  h="$h $(held)"
  check "reconnect: sim_held ios 1 stays true the whole time" "held held held held held" "$h"
  exec 7>&-
  wait "$MCP"; check "reconnect: the session ends on EOF, exit 0" 0 "$?"
  check "reconnect: the slot is free afterwards" free "$(held)"
  rm -f "$T/rc.in" "$T/die.after"
)
# EOF and TERM while reconnecting: the relay stops at once, the attempt under way or due is called off.
for how in eof term; do
  ( cd "$T/ws/app" || exit 1; rm -f "$T/log/"* "$T/state/ios/mac.state"
    export SIM_RECONNECT_DELAYS=0.2,30
    echo 2 > "$T/die.after"
    rc_start
    rc_send "$rc_init"; wait_for 'grep -q initialize "$T/log/fake.in" 2>/dev/null'
    touch "$T/ssh.down"; rc_send "$rc_inited"
    wait_for 'grep -q "reconnecting" "$T/log/err"' || bad "$how while reconnecting: the drop is noticed" "$(cat "$T/log/err")"
    wait_for '[ "$(grep -c sim-xcodebuildmcp "$T/log/ssh")" -ge 2 ]'   # the 0.2 s attempt failed; the 30 s one waits
    SECONDS=0
    if [ "$how" = eof ]; then exec 7>&-; else kill -TERM "$MCP"; exec 7>&-; fi
    wait_for '! kill -0 "$MCP" 2>/dev/null' && [ "$SECONDS" -le 3 ] && ok "$how while reconnecting: sim-mcp exits at once" \
      || bad "$how while reconnecting: sim-mcp exits at once" "${SECONDS}s"
    wait "$MCP" 2>/dev/null
    check "$how while reconnecting: the slot is free" free "$(held)"
    [ -e "$T/state/ios/1.pgid" ] && bad "$how while reconnecting: pgid file removed" || ok "$how while reconnecting: pgid file removed"
    pgrep -f "$T/mcp.fake" > /dev/null && bad "$how while reconnecting: no server left running" || ok "$how while reconnecting: no server left running"
    rm -f "$T/ssh.down" "$T/rc.in" "$T/die.after" "$T/state/ios/mac.state"
  )
done
# Android and web are not given --reconnect: a server that fails ends the session, as before.
printf '#!/bin/sh\ncat > /dev/null &\nsleep 0.3\nexit 3\n' > "$T/shims/fails"; chmod +x "$T/shims/fails"
( cd "$T/ws/app" || exit 1; export SIM_NODE=$T/shims/fails
  SECONDS=0
  "$REPO/bin/sim-mcp" web < <(sleep 10) > /dev/null 2>&1; rc=$?
  check "web: a server that exits 3 ends sim-mcp with 3" 3 "$rc"
  [ "$SECONDS" -lt 10 ] && ok "web: ...without waiting for EOF" || bad "web: ...without waiting for EOF" "${SECONDS}s"
)
