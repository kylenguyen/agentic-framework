# shellcheck shell=bash
# Sourced by tests/sim-test.sh after tests/sim/harness.sh; see its header.
# shellcheck disable=SC2015,SC2016,SC2030,SC2031,SC2154
echo "# sim tunnel"
# tunnel_reap: every tunnel (the ssh shim with -R) and watcher this file started is killed; tunnel_up: one runs.
tunnel_reap() { pkill -f "$T/shims/ssh .* -R " 2>/dev/null; pkill -f "$REPO/bin/sim _tunnel_watch" 2>/dev/null; rm -f "$T/tunnel.up"; }
tunnel_up() { pgrep -f "$T/shims/ssh .* -R " >/dev/null; }
( cd "$T/ws/app" || exit 1; rm -rf "$T/log/"* "$T/state/ios" "$T/lsof.out" "$T/tunnel.fail"
  trap tunnel_reap EXIT
  out=$("$REPO/bin/sim" tunnel ios 22000 2>&1); rc=$?
  check "tunnel: rc 1 without a lease" 1 "$rc"
  has "tunnel: says how to get a slot" "sim enable" "$out"
  "$REPO/bin/sim" tunnel ios 2>/dev/null; check "tunnel: no ports is a usage error" 2 "$?"
  "$REPO/bin/sim" tunnel android 22000 2>/dev/null; check "tunnel: only ios" 2 "$?"
  out=$("$REPO/bin/sim" tunnel ios 22000,x 2>&1); rc=$?
  check "tunnel: a bad port list is a usage error" 2 "$rc"
  has "tunnel: ...saying what a list is" "a comma list of port numbers" "$out"
  "$REPO/bin/sim" tunnel ios 70000 2>/dev/null; check "tunnel: a port above 65535 is a usage error" 2 "$?"
  hold ios "$T/ws/app" 60; holder=$!
  wait_for "( lib; sim_held ios 1 )"

  # A port outside the slot's block (ios 1: 22000-22099).
  : > "$T/log/ssh"
  out=$("$REPO/bin/sim" tunnel ios 22000,8440 --background 2>&1); rc=$?
  check "tunnel: a port outside the block is rc 2" 2 "$rc"
  has "tunnel: ...naming the block and --any-port" "port 8440 is outside ios slot 1's block 22000-22099 (sim ports ios); --any-port" "$out"
  lacks "tunnel: ...and starts no tunnel" " -R " "$(cat "$T/log/ssh")"

  # --background: the forward, its options, the pidfile, a watcher.
  : > "$T/log/ssh"
  out=$("$REPO/bin/sim" tunnel ios 22000,22001 --background 2>&1); rc=$?
  check "tunnel --background: rc 0" 0 "$rc"
  has "tunnel --background: says it is up" "tunnel up: Mac 127.0.0.1:22000 -> host 127.0.0.1:22000" "$out"
  has "tunnel --background: one line per port" "tunnel up: Mac 127.0.0.1:22001 -> host 127.0.0.1:22001" "$out"
  line=$(grep -- ' -R ' "$T/log/ssh")
  has "tunnel: forwards 127.0.0.1 to 127.0.0.1" "-R 127.0.0.1:22000:127.0.0.1:22000 -R 127.0.0.1:22001:127.0.0.1:22001" "$line"
  has "tunnel: fails when a forward fails" "-N -o ExitOnForwardFailure=yes" "$line"
  has "tunnel: on a connection of its own" "-o ControlMaster=no -o ControlPath=none" "$line"
  has "tunnel: ...its options before the shared ones (ssh keeps the first)" "ControlPath=none -N -o ExitOnForwardFailure=yes -R 127.0.0.1:22000:127.0.0.1:22000 -R 127.0.0.1:22001:127.0.0.1:22001 -o BatchMode=yes" "$line"
  has "tunnel: the bound-port check goes first" "-nP \"-iTCP:\$p\" -sTCP:LISTEN -Fpc" "$(grep -B1 -- ' -R ' "$T/log/ssh" | head -1)"
  has "tunnel: lsof at its macOS path" "L=/usr/sbin/lsof" "$(grep -m1 lsof "$T/log/ssh")"
  has "tunnel: a connect probe through /bin/bash" "/bin/bash -c 'exec 3<>/dev/tcp/127.0.0.1/'\$p" "$(grep -m1 lsof "$T/log/ssh")"
  f=$T/state/ios/1.tunnel
  [ -e "$f" ] && ok "tunnel --background: pidfile" || bad "tunnel --background: pidfile"
  check "tunnel --background: pidfile has the ports" "ports=22000,22001" "$(grep '^ports=' "$f")"
  pid=$(sed -n 's/^pid=//p' "$f"); watcher=$(sed -n 's/^watcher=//p' "$f")
  kill -0 "$pid" 2>/dev/null && ok "tunnel --background: its ssh runs after sim returns" || bad "tunnel --background: its ssh runs after sim returns"
  kill -0 "$watcher" 2>/dev/null && ok "tunnel --background: and so does its watcher" || bad "tunnel --background: and so does its watcher"
  check "tunnel --background: the ssh is in a session of its own" "$pid" "$(ps -o sid= -p "$pid" | tr -d ' ')"
  has "status: shows the tunnel" "tunnel 22000,22001" "$("$REPO/bin/sim" status | awk '$1 == "ios" && $2 == 1')"

  # A second tunnel: one more background tunnel is refused; one on a port the first holds is a bound port.
  out=$("$REPO/bin/sim" tunnel ios 22002 --background 2>&1); rc=$?
  check "tunnel --background: a second one is rc 1" 1 "$rc"
  has "tunnel --background: ...saying there is one" "already has a background tunnel (ports 22000,22001)" "$out"
  printf '=22000\np%s\ncsshd\n' "$pid" > "$T/lsof.out"
  out=$("$REPO/bin/sim" tunnel ios 22000 2>&1); rc=$?
  check "tunnel: a bound port is rc 1" 1 "$rc"
  has "tunnel: ...naming its command and pid" "port 22000 already bound on the Mac by this slot's background tunnel (sim tunnel ios --stop)" "$out"
  rm -f "$T/lsof.out"

  # --stop
  out=$("$REPO/bin/sim" tunnel ios --stop 2>&1); rc=$?
  check "tunnel --stop: rc 0" 0 "$rc"
  has "tunnel --stop: says so" "stopped (ports 22000,22001)" "$out"
  kill -0 "$pid" 2>/dev/null && bad "tunnel --stop: the ssh is dead" || ok "tunnel --stop: the ssh is dead"
  wait_for "! kill -0 $watcher 2>/dev/null" && ok "tunnel --stop: and the watcher" || bad "tunnel --stop: and the watcher"
  [ -e "$f" ] && bad "tunnel --stop: pidfile removed" || ok "tunnel --stop: pidfile removed"
  lacks "status: no tunnel after --stop" "tunnel" "$("$REPO/bin/sim" status | awk '$1 == "ios" && $2 == 1')"
  has "tunnel --stop: without a tunnel, says so" "nothing to stop" "$("$REPO/bin/sim" tunnel ios --stop 2>&1)"

  # A port bound by someone else.
  printf '=22005\np4242\ncnode\nf12\n=22006\n' > "$T/lsof.out"; : > "$T/log/ssh"
  out=$("$REPO/bin/sim" tunnel ios 22005,22006 --background 2>&1); rc=$?
  check "tunnel: a port bound by another process is rc 1" 1 "$rc"
  check "tunnel: ...one line naming it" "sim: port 22005 already bound on the Mac by node (pid 4242)" "$out"
  lacks "tunnel: ...and starts no tunnel" " -R " "$(cat "$T/log/ssh")"
  printf '=22005\n+\n' > "$T/lsof.out"
  out=$("$REPO/bin/sim" tunnel ios 22005 --background 2>&1); rc=$?
  check "tunnel: a port that takes connections, holder unseen, is rc 1" 1 "$rc"
  has "tunnel: ...saying lsof cannot name it" "port 22005 already bound on the Mac, by a process lsof does not show" "$out"
  rm -f "$T/lsof.out"

  # --any-port: a warning, then the tunnel.
  out=$("$REPO/bin/sim" tunnel ios 8440 --any-port --background 2>&1); rc=$?
  check "tunnel --any-port: rc 0" 0 "$rc"
  has "tunnel --any-port: warns" "warning: port 8440 is outside ios slot 1's block 22000-22099: another slot may use it too" "$out"
  has "tunnel --any-port: forwards it" "-R 127.0.0.1:8440:127.0.0.1:8440" "$(grep -- ' -R ' "$T/log/ssh")"
  "$REPO/bin/sim" tunnel ios --stop >/dev/null

  # ssh cannot forward: rc 1 with its stderr, nothing left running.
  echo 'Error: remote port forwarding failed for listen port 22003' > "$T/tunnel.fail"
  out=$(SIM_TUNNEL_READY_TIMEOUT=2 "$REPO/bin/sim" tunnel ios 22003 --background 2>&1); rc=$?
  check "tunnel: a failed forward is rc 1" 1 "$rc"
  has "tunnel: ...with ssh's stderr" "did not come up within 2 s: Error: remote port forwarding failed for listen port 22003" "$out"
  [ -e "$f" ] && bad "tunnel: ...and no pidfile" || ok "tunnel: ...and no pidfile"
  rm -f "$T/tunnel.fail"

  # The foreground tunnel holds until a signal, then is gone.
  "$REPO/bin/sim" tunnel ios 22004 > "$T/log/fg.out" 2>&1 & fg=$!
  wait_for "grep -q 'tunnel up' '$T/log/fg.out'" && ok "tunnel: foreground says it is up" || bad "tunnel: foreground says it is up" "$(cat "$T/log/fg.out")"
  tunnel_up && ok "tunnel: foreground holds the ssh" || bad "tunnel: foreground holds the ssh"
  kill -TERM "$fg"; wait "$fg"; rc=$?
  check "tunnel: foreground exits 0 on a signal" 0 "$rc"
  wait_for "! tunnel_up" && ok "tunnel: ...and takes the ssh with it" || bad "tunnel: ...and takes the ssh with it"

  # The lease ends: the watcher closes the tunnel within its interval and removes the pidfile.
  SIM_TUNNEL_WATCH=1 "$REPO/bin/sim" tunnel ios 22000 --background >/dev/null 2>&1
  pid=$(sed -n 's/^pid=//p' "$f")
  kill "$holder" 2>/dev/null; pkill -P "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  wait_for "! kill -0 $pid 2>/dev/null" && ok "tunnel: closed once the lease ends" || bad "tunnel: closed once the lease ends"
  wait_for "[ ! -e '$f' ]" && ok "tunnel: ...and its pidfile removed" || bad "tunnel: ...and its pidfile removed"
)
( cd "$T/ws/app" || exit 1; rm -rf "$T/log/"* "$T/state/ios"
  trap tunnel_reap EXIT
  # sim reap: a pidfile whose ssh is gone goes; a tunnel whose lease has ended (its watcher gone too) is closed.
  hold ios "$T/ws/app" 60; holder=$!
  wait_for "( lib; sim_held ios 1 )"
  mkdir -p "$T/state/ios"; printf 'pid=999999\nports=22000\nroot=%s\n' "$T/ws/app" > "$T/state/ios/1.tunnel"
  AGENT_SIM_IDLE_MINUTES=0 "$REPO/bin/sim" reap >/dev/null 2>&1
  [ -e "$T/state/ios/1.tunnel" ] && bad "reap: drops a pidfile whose pid is gone" || ok "reap: drops a pidfile whose pid is gone"
  "$REPO/bin/sim" tunnel ios 22000 --background >/dev/null 2>&1
  pid=$(sed -n 's/^pid=//p' "$T/state/ios/1.tunnel"); kill "$(sed -n 's/^watcher=//p' "$T/state/ios/1.tunnel")"
  out=$(AGENT_SIM_IDLE_MINUTES=0 "$REPO/bin/sim" reap 2>&1)
  kill -0 "$pid" 2>/dev/null && ok "reap: leaves a tunnel whose lease holds" || bad "reap: leaves a tunnel whose lease holds"
  kill "$holder" 2>/dev/null; pkill -P "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  out=$(AGENT_SIM_IDLE_MINUTES=0 "$REPO/bin/sim" reap 2>&1)
  has "reap: closes a tunnel whose lease has ended" "ios 1: tunnel closed" "$out"
  kill -0 "$pid" 2>/dev/null && bad "reap: ...its ssh is dead" || ok "reap: ...its ssh is dead"
)
( cd "$T/ws/app.wt/feat/client" || exit 1; rm -rf "$T/log/"* "$T/state/ios" "$T/ssh.rc"
  trap tunnel_reap EXIT
  hold ios "$T/ws/app.wt/feat" 60; holder=$!
  wait_for "( lib; sim_held ios 1 )"
  "$REPO/bin/sim" maestro ios --forward 22000 test x >/dev/null 2>"$T/log/maestro.err"; rc=$?
  check "maestro --forward: rc 0" 0 "$rc"
  r=$(grep -n -m1 -- ' -R ' "$T/log/ssh" | cut -d: -f1); m=$(grep -n -m1 'sim-maestro 1 ' "$T/log/ssh" | cut -d: -f1)
  [ -n "$r" ] && [ -n "$m" ] && [ "$r" -lt "$m" ] && ok "maestro --forward: the tunnel ssh comes before sim-maestro" \
    || bad "maestro --forward: the tunnel ssh comes before sim-maestro" "$(cat "$T/log/ssh")"
  has "maestro --forward: forwards the port" "-R 127.0.0.1:22000:127.0.0.1:22000" "$(grep -- ' -R ' "$T/log/ssh")"
  run=$(grep 'sim-maestro 1 ' "$T/log/ssh")
  has "maestro --forward: Maestro gets the rest" "/output x" "$run"
  lacks "maestro --forward: ...and not --forward" "forward" "$run"
  has "maestro --forward: says the tunnel is up" "tunnel up: Mac 127.0.0.1:22000" "$(cat "$T/log/maestro.err")"
  wait_for "! tunnel_up" && ok "maestro --forward: the tunnel is gone after the run" || bad "maestro --forward: the tunnel is gone after the run"
  : > "$T/log/ssh"
  "$REPO/bin/sim" maestro ios test --forward=22001,22002 x >/dev/null 2>&1
  has "maestro --forward=: the = form" "-R 127.0.0.1:22001:127.0.0.1:22001 -R 127.0.0.1:22002:127.0.0.1:22002" "$(grep -- ' -R ' "$T/log/ssh")"
  run=$(grep 'sim-maestro 1 ' "$T/log/ssh")
  has "maestro --forward=: ...consumed too" "/output x" "$run"
  lacks "maestro --forward=: ...and not passed on" "forward" "$run"
  : > "$T/log/ssh"
  "$REPO/bin/sim" maestro ios --forward 8440 test x >/dev/null 2>&1; rc=$?
  check "maestro --forward: a port outside the block is rc 2" 2 "$rc"
  lacks "maestro --forward: ...and Maestro does not run" "sim-maestro 1 " "$(cat "$T/log/ssh")"
  printf '=22000\np7\ncpython3\n' > "$T/lsof.out"
  out=$("$REPO/bin/sim" maestro ios --forward 22000 test x 2>&1); rc=$?
  check "maestro --forward: a bound port is rc 1" 1 "$rc"
  has "maestro --forward: ...naming it" "port 22000 already bound on the Mac by python3 (pid 7)" "$out"
  rm -f "$T/lsof.out"
  "$REPO/bin/sim" maestro ios --forward 2>/dev/null; check "maestro --forward: without ports is a usage error" 2 "$?"
  "$REPO/bin/sim" maestro ios --forward 22000 2>/dev/null; check "maestro --forward: without Maestro args is a usage error" 2 "$?"
  ( cd "$T/ws/app" && "$REPO/bin/sim" maestro android --forward 22000 test x 2>/dev/null ); check "maestro android --forward: rc 2, iOS only" 2 "$?"
  kill "$holder" 2>/dev/null; pkill -P "$holder" 2>/dev/null; wait
)
