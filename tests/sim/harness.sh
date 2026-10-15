# shellcheck shell=bash
# tests/sim/harness.sh: setup shared by every tests/sim section file. Sourced first by tests/sim-test.sh.
# shellcheck disable=SC2015,SC2016,SC2030,SC2031,SC2034
set -u
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
: > "$T/results"
ok()    { echo ok >> "$T/results"; printf 'ok   %s\n' "$1"; }
bad()   { echo FAIL >> "$T/results"; printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
has()   { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "no [$2] in [$3]" ;; esac; }   # has <name> <needle> <haystack>
lacks() { case "$3" in *"$2"*) bad "$1" "unexpected [$2] in [$3]" ;; *) ok "$1" ;; esac; }

# The relay runs on the real node; the node shim below stands in for the MCP servers.
SIM_RELAY_NODE=$(command -v node) || { echo "sim-test: node is required (bin/sim-mcp-relay.mjs)" >&2; exit 1; }
export SIM_RELAY_NODE
# A repo copy with a test .env, and shims that log to $T/log.
REPO=$T/repo
mkdir -p "$REPO/bin" "$REPO/lib" "$REPO/config" "$T/shims" "$T/log"
cp "$SRC/lib/params.sh" "$SRC/lib/sim.sh" "$REPO/lib/"
cp "$SRC/bin/sim" "$SRC/bin/sim-mcp" "$SRC/bin/sim-mcp-relay.mjs" "$REPO/bin/"
cp "$SRC/install-ios-runner.sh" "$REPO/"
mkdir -p "$REPO/config/sim"; cp "$SRC/config/sim/"* "$REPO/config/sim/"
printf 'AGENT_HOST=box\nAGENT_IOS_HOST=mini.tail.ts.net\nAGENT_IOS_USER=bob\nAGENT_SIM_ANDROID_SLOTS=2\nAGENT_SIM_WEB_SLOTS=2\nAGENT_SIM_IOS_SLOTS=1\n' > "$REPO/.env"
for c in ssh rsync mise; do
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/log/%s"\nexit 0\n' "$T" "$c" > "$T/shims/$c"
done
# ssh running the Mac's MCP launcher serves until stdin closes, as the real one does.
# ssh running the Maestro launcher exits with the code in $T/ssh.rc; `sim-maestro --version` prints $T/sim-maestro.version (2). `simctl list devices` prints $T/simctl.list.
# The Metro readiness loop (its last argument) is run by sh here.
# While $T/ssh.down exists every call is logged, then fails as one to an unreachable host does (255).
# With $T/mcp.fake present, the MCP launcher is that script run on the real node (tests/sim/62-ios-reconnect.sh).
# A tunnel (-R) prints $T/tunnel.fail to stderr and exits 255 when that file exists; otherwise it marks $T/tunnel.up
# and holds until a signal. lsof on the Mac (sim tunnel) prints $T/lsof.out when it exists, else, while a tunnel is
# up, sshd listening on every port it was asked about.
cat > "$T/shims/ssh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$T/log/ssh"
[ -e "$T/ssh.down" ] && exit 255
case "\$*" in
  *" -R "*)
    [ -e "$T/tunnel.fail" ] && { cat "$T/tunnel.fail" >&2; exit 255; }
    touch "$T/tunnel.up"; trap 'rm -f "$T/tunnel.up"; exit 0' TERM INT HUP
    while :; do sleep 0.1; done ;;
  *lsof*)
    if [ -e "$T/lsof.out" ]; then cat "$T/lsof.out"
    elif [ -e "$T/tunnel.up" ]; then
      for p in \$(printf '%s\n' "\$*" | sed -n 's/.*for p in \([0-9 ]*\);.*/\1/p'); do printf '=%s\np99\ncsshd\n' "\$p"; done
    fi ;;
  *sim-xcodebuildmcp*) [ -e "$T/mcp.fake" ] && exec "$SIM_RELAY_NODE" "$T/mcp.fake"; cat > /dev/null ;;
  *"sim-maestro --version"*) cat "$T/sim-maestro.version" 2>/dev/null || echo 2 ;;
  *sim-maestro*) exit "\$(cat "$T/ssh.rc" 2>/dev/null || echo 0)" ;;
  *"simctl list devices"*) cat "$T/simctl.list" 2>/dev/null ;;
  *packager-status*) for a; do :; done; exec sh -c "\$a" ;;   # the Metro readiness loop runs here, against the curl shim
esac
exit 0
EOF
# systemctl: a unit is active while its name is a line of $T/active; start and stop edit that file. A start fails while
# $T/systemctl.fail exists, and first sleeps for the seconds in $T/wake.delay.
cat > "$T/shims/systemctl" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$T/log/systemctl"
[ "\$1" = --user ] && shift
for u; do :; done
case \$1 in
  is-active) grep -qx "\$u" "$T/active" 2>/dev/null && { [ "\$2" = -q ] || echo active; exit 0; }; [ "\$2" = -q ] || echo inactive; exit 3 ;;
  start) [ -e "$T/systemctl.fail" ] && exit 1; sleep "\$(cat "$T/wake.delay" 2>/dev/null || echo 0)"; echo "\$u" >> "$T/active" ;;
  stop) grep -vx "\$u" "$T/active" > "$T/active.new" 2>/dev/null; mv "$T/active.new" "$T/active" ;;
esac
exit 0
EOF
# adb: sys.boot_completed is the content of $T/boot (default 1); wait-for-device waits for it to be 1.
cat > "$T/shims/adb" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$T/log/adb"
case "\$*" in
  *wait-for-device*) while [ "\$(cat "$T/boot" 2>/dev/null || echo 1)" != 1 ]; do sleep 0.1; done ;;
  *"getprop sys.boot_completed"*) cat "$T/boot" 2>/dev/null || echo 1 ;;
esac
EOF
printf '#!/bin/sh\nprintf "%%s\\n" "$*" > "%s/log/emulator"\necho "$ANDROID_TMP" > "%s/log/emulator.tmp"\n' "$T" "$T" > "$T/shims/emulator"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/log/npx"\n' "$T" > "$T/shims/npx"
# curl: logs its arguments and prints $T/metro.status as Metro's /status body; without that file Metro is up
# (packager-status:running), so a test that starts Metro in passing does not wait out the readiness timeout.
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/log/curl"\ncat "%s/metro.status" 2>/dev/null || echo packager-status:running\n' "$T" "$T" > "$T/shims/curl"
# docker: logs every call. The image exists unless $T/docker.noimage does; `ps` prints $T/docker.ps; a run of the
# Maestro container exits with the code in $T/docker.rc.
cat > "$T/shims/docker" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$T/log/docker"
case "\$1 \$2" in
  "image inspect") [ ! -e "$T/docker.noimage" ] ;;
  ps*) cat "$T/docker.ps" 2>/dev/null; exit 0 ;;
  run*) case "\$*" in *" -d "*) exit 0 ;; esac; exit "\$(cat "$T/docker.rc" 2>/dev/null || echo 0)" ;;
esac
EOF
# The MCP server stand-in: records its arguments, environment and input, then serves until stdin closes.
printf '#!/bin/sh\nprintf "%%s\\n" "$*" > "%s/log/node.args"\nenv > "%s/log/node.env"\ncat > "%s/log/node.in"\n' "$T" "$T" "$T" > "$T/shims/node"
mkdir -p "$T/prefix/node_modules/.bin"; printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/log/mobilecli"\n' "$T" > "$T/prefix/node_modules/.bin/mobilecli"
chmod +x "$T/shims/"* "$T/prefix/node_modules/.bin/mobilecli"
export PATH="$T/shims:$PATH" SIM_STATE=$T/state SIM_PREFIX=$T/prefix SIM_NODE=$T/shims/node HOME=$T/home
mkdir -p "$HOME"
unset AGENT_HOST AGENT_HOST_ADDRESS AGENT_HOST_USER AGENT_HOST_LAN_IP AGENT_IOS_HOST AGENT_IOS_USER \
  AGENT_SIM_ANDROID_SLOTS AGENT_SIM_WEB_SLOTS AGENT_SIM_IOS_SLOTS AGENT_SIM_IDLE_MINUTES AGENT_SIM_KEEP_RUNS ANDROID_SERIAL ANDROID_ADB_SERVER_PORT \
  XDG_CACHE_HOME SIM_CACHE ANDROID_TMP
lib() { . "$REPO/lib/sim.sh" && sim_load_params; }
# a git worktree layout for the tests that need a root: $T/ws/app (checkout) and $T/ws/app.wt/feat (worktree)
mkdir -p "$T/ws/app/client" && git -C "$T/ws/app" init -q && git -C "$T/ws/app" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$T/ws/app" worktree add -q "$T/ws/app.wt/feat" 2>/dev/null; mkdir -p "$T/ws/app.wt/feat/client"
# hold <platform> <root> <seconds>: lease a slot in the background for a while, as an MCP server would
hold() { ( cd "$2" && . "$REPO/lib/sim.sh" && sim_load_params && sim_lease "$1" "$2" && sleep "$3" ) & }
wait_for() { local i; for i in $(seq 1 50); do eval "$1" && return 0; sleep 0.1; done; return 1; }
