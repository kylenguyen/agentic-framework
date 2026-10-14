#!/bin/sh
# maestro-entry <serial> <maestro args...>: the entry point of the agent-sim-maestro image (config/sim/Dockerfile.maestro),
# run by `sim maestro` in a network namespace of its own. Maestro finds Android devices only through adb servers on
# 5037 and 5038 and a direct scan of emulator ports 5555-5683, and reads no ANDROID_ADB_SERVER_PORT (2.11.0, from its
# bytecode). Here both ports lead to one slot's adb server, through the socket bin/sim relays to it, and nothing
# listens in the scan range, so Maestro sees that slot's emulator and nothing else.
set -eu
serial=$1; shift
sock=/run/sim/adb.sock

i=0
until [ -S "$sock" ]; do
  i=$((i + 1)); [ "$i" -le 100 ] || { echo "sim maestro: no relay to the slot's adb server at $sock" >&2; exit 1; }
  sleep 0.1
done
for port in 5037 5038; do
  socat "TCP-LISTEN:$port,bind=127.0.0.1,fork,reuseaddr" "UNIX-CONNECT:$sock" &
done
# Both listening (/proc/net/tcp: local port in hex, state 0A) before Maestro looks.
i=0
until [ "$(grep -cE ':(13AD|13AE) 00000000:0000 0A' /proc/net/tcp)" = 2 ]; do
  i=$((i + 1)); [ "$i" -le 50 ] || { echo "sim maestro: socat did not listen on 5037 and 5038" >&2; exit 1; }
  sleep 0.1
done
# Java takes its home from the passwd entry, which the host's uid lacks here; Maestro keeps its state there.
JAVA_OPTS="-Duser.home=$HOME ${JAVA_OPTS:-}"; export JAVA_OPTS
exec /opt/maestro/bin/maestro --device "$serial" "$@"
