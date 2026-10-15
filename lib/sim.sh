# lib/sim.sh: the device simulation service shared by bin/sim, bin/sim-mcp, install-host.sh and tests/sim-test.sh.
# Sourced, never executed. Host only (bash 5, GNU tools, util-linux flock). The caller sets REPO.
#
# Model. A platform has numbered slots: android 1..AGENT_SIM_ANDROID_SLOTS (emulators on this host), web
# 1..AGENT_SIM_WEB_SLOTS (headless browsers on this host), ios 1..AGENT_SIM_IOS_SLOTS (simulators agent-ios-N on the
# Mac named by AGENT_IOS_HOST). A slot is leased by holding an flock on $SIM_STATE/<platform>/<N>.lock. bin/sim-mcp
# takes the lock and execs the MCP server with the descriptor still open, so the lease lives exactly as long as the
# MCP server, which lives as long as the harness session: a crash or exit frees it, nothing has to clean up.
# Next to each lock, <N>.owner records the holder's pid and worktree; bin/sim finds "my slot" by matching the worktree.
# `sim lease` holds a slot the same way from a detached `sim _hold` that sleeps until the lease ends (bin/sim).
#
# Uptime. Nothing runs until it is used, and nothing stays up unused. A lease starts no device: the first tool call
# through sim-mcp does (an emulator unit, or booting agent-ios-N), and the call waits for the boot. Every tool call and
# every device command of bin/sim touches <N>.active. `sim reap`, every 5 minutes from a user timer, stops the
# emulator, the iOS simulator and Metro of every slot whose <N>.active is older than AGENT_SIM_IDLE_MINUTES, leased
# or not: a harness session (and its lease) can stay open for days in tmux. After a stop the next tool call starts
# the device again. <N>.down marks an iOS simulator that sim shut down, so the reaper reaches the Mac once per idle
# spell, and the next call knows to boot it. <N>.booted is the other half: the relay's wake (`sim _wake`) has seen
# agent-ios-N booted since sim last shut it down, so later calls skip the boot check.
#
# Ports, all derived from the slot number so nothing has to be allocated:
#   android N  emulator console 5598+2N (serial emulator-5600, -5602, ...), its own adb server on 5037+N, Metro 8100+N
#   web N      Expo web dev server 8200+N
#   ios N      Metro on the Mac 8081 + 10(N-1). Simulators share the Mac's localhost, and a React Native debug build
#              asks Metro at the port it was built with (RCT_METRO_PORT, default 8081): slot 1 needs nothing, slot 2
#              builds with RCT_METRO_PORT=8091.
#   test stacks  a block of 100 per slot from 20000 + 1000*(android 0, web 1, ios 2) + 100(N-1): `sim ports`
# Each emulator registers only with its slot's adb server, so the default adb server (5037) sees none of them and
# an MCP server pointed at slot N's adb server cannot see, let alone drive, another agent's emulator. That needs the
# consoles above 5585: an adb server also scans 5555-5585 when it starts and adopts every emulator it finds there.

# shellcheck disable=SC2034   # the constants and SIM_SLOT/SIM_LOCK_FD are read by the scripts that source this file
# The contract between sim and the repos that use it: the commands and flags the AGENTS.md section of `sim enable`
# tells agents about. Bump it when that section changes in a way a repo must re-paste (`sim enable --check` says so).
SIM_CONTRACT_VERSION=2
# Pinned versions. The npm packages are installed into SIM_PREFIX by install-host.sh, so starting an MCP server
# needs no network and never picks up a release nobody has tried.
SIM_PLAYWRIGHT_MCP_VERSION=0.0.83
SIM_MOBILE_MCP_VERSION=1.0.6
SIM_XCODEBUILDMCP_VERSION=2.7.0
SIM_ANDROID_API=35
SIM_ANDROID_IMAGE="system-images;android-$SIM_ANDROID_API;google_apis;x86_64"
SIM_AVD=agent-sim-android
SIM_AVD_DEVICE=pixel_7
SIM_IOS_DEVICE_TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-17
SIM_IOS_WORKFLOWS=simulator,ui-automation,project-discovery,utilities
# Maestro: for Android it runs in a container built from config/sim/Dockerfile.maestro on first use (`sim maestro
# android`); for iOS install-ios-runner.sh installs the same release on the Mac (`sim ios bootstrap`), so one bump
# moves both. Its adb ports (5037, 5038) are hard-coded per release, so a new version needs the check in
# docs/simulators-plan.md, Maestro.
SIM_MAESTRO_VERSION=2.11.0
SIM_MAESTRO_SHA256=5384593cb4e7a106489e75a821d157dd43f4e438df6bc308b72e82c685e1283a
sim_maestro_image() { # the image tag: the version and a hash of what builds it, so a change to either builds anew
  echo "agent-sim-maestro:$SIM_MAESTRO_VERSION-$(cat "$REPO/config/sim/Dockerfile.maestro" "$REPO/config/sim/maestro-entry.sh" | sha256sum | cut -c1-8)"
}

# System libraries, Ubuntu 26.04 names. The emulator loads the X/xcb, PulseAudio and font libraries even with
# -no-window; the rest is Playwright's own list for chromium and webkit (playwright-core nativeDeps, ubuntu26.04).
SIM_APT_PACKAGES="libpulse0 libx11-xcb1 libxcb-cursor0 libxcb-icccm4 libxcb-image0 libxcb-keysyms1 libxcb-randr0
libxcb-render0 libxcb-render-util0 libxcb-shape0 libxcb-shm0 libxcb-sync1 libxcb-util1 libxcb-xfixes0 libxcb-xkb1
libxi6 libxkbcommon-x11-0 libxkbfile1 libfontconfig1 libice6 libsm6 libjpeg8 libpcre2-16-0 libnss3 libxcomposite1
libxcursor1 libxdamage1 libxtst6 libgl1 libegl1
fonts-noto-color-emoji fonts-unifont libfreetype6 xfonts-cyrillic xfonts-scalable fonts-liberation
fonts-ipafont-gothic fonts-wqy-zenhei fonts-tlwg-loma-otf fonts-freefont-ttf
libasound2t64 libatk-bridge2.0-0t64 libatk1.0-0t64 libatspi2.0-0t64 libcairo2 libcups2t64 libdbus-1-3 libdrm2
libgbm1 libglib2.0-0t64 libnspr4 libpango-1.0-0 libx11-6 libxcb1 libxext6 libxfixes3 libxkbcommon0 libxrandr2
gstreamer1.0-libav gstreamer1.0-plugins-bad gstreamer1.0-plugins-base gstreamer1.0-plugins-good libicu78 libatomic1
libcairo-gobject2 libenchant-2-2 libepoxy0 libevent-2.1-7t64 libflite1 libgdk-pixbuf-2.0-0 libgles2
libgstreamer-gl1.0-0 libgstreamer-plugins-bad1.0-0 libgstreamer-plugins-base1.0-0 libgstreamer1.0-0 libgtk-4-1
libharfbuzz-icu0 libharfbuzz0b libhyphen0 libjpeg-turbo8 liblcms2-2 libmanette-0.2-0 libopus0 libpangocairo-1.0-0
libpng16-16t64 libsecret-1-0 libvpx12 libwayland-client0 libwayland-egl1 libwayland-server0 libwebp7 libwebpdemux2
libwoff1 libxml2-16 libxslt1.1 libx264-165 libavif16"

SIM_PLATFORMS="android web ios"
# Paths. Every one can be overridden, which is how tests/sim-test.sh runs without touching the host.
: "${SIM_PREFIX:=$HOME/.local/share/agent-sim}"                         # npm prefix for the pinned MCP servers
sim_state_default() { # locks, owners, Metro logs, the Mac probe: in RAM, gone at reboot
  local run; run=/run/user/$(id -u)
  if [ -n "${XDG_RUNTIME_DIR:-}" ]; then echo "$XDG_RUNTIME_DIR/agent-sim"
  elif [ -d "$run" ] && [ -w "$run" ]; then echo "$run/agent-sim"     # a shell without a systemd session (cron, su)
  else echo "/tmp/agent-sim-$(id -u)"; fi
}
: "${SIM_STATE:=$(sim_state_default)}"
: "${SIM_CACHE:=${XDG_CACHE_HOME:-$HOME/.cache}/agent-sim}"             # emulator scratch disks: on disk, not in RAM
: "${ANDROID_HOME:=$HOME/Android/Sdk}"

sim_fail() { printf 'sim: %s\n' "$*" >&2; return 1; }

# sim_load_params: the AGENT_IOS_* and AGENT_SIM_* parameters from .env (lib/params.sh), with defaults.
sim_load_params() {
  # Whether the environment set it, for the precedence over .sim/config (sim_repo_apply).
  SIM_ENV_KEEP_RUNS=${AGENT_SIM_KEEP_RUNS:-}
  . "$REPO/lib/params.sh"
  params_load || return 1
  : "${AGENT_SIM_ANDROID_SLOTS:=3}" "${AGENT_SIM_WEB_SLOTS:=3}" "${AGENT_SIM_IOS_SLOTS:=2}" "${AGENT_SIM_IDLE_MINUTES:=30}" \
    "${AGENT_SIM_KEEP_RUNS:=5}"
  local n
  for n in AGENT_SIM_ANDROID_SLOTS AGENT_SIM_WEB_SLOTS AGENT_SIM_IOS_SLOTS; do
    [[ ${!n} =~ ^[0-9]$ ]] || { sim_fail "$n=${!n}: a slot count from 0 to 9"; return 1; }
  done
  [[ $AGENT_SIM_IDLE_MINUTES =~ ^[0-9]{1,4}$ ]] \
    || { sim_fail "AGENT_SIM_IDLE_MINUTES=$AGENT_SIM_IDLE_MINUTES: minutes from 0 (never stop) to 9999"; return 1; }
  [[ $AGENT_SIM_KEEP_RUNS =~ ^[1-9][0-9]?$ ]] && [ "$AGENT_SIM_KEEP_RUNS" -le 50 ] \
    || { sim_fail "AGENT_SIM_KEEP_RUNS=$AGENT_SIM_KEEP_RUNS: Maestro runs to keep per slot, 1 to 50"; return 1; }
}

sim_slots() { # sim_slots <platform>: the configured slot count
  case $1 in
    android) echo "$AGENT_SIM_ANDROID_SLOTS" ;;
    web)     echo "$AGENT_SIM_WEB_SLOTS" ;;
    ios)     echo "$AGENT_SIM_IOS_SLOTS" ;;
    *) sim_fail "unknown platform: $1 (one of: $SIM_PLATFORMS)" ;;
  esac
}

sim_android_port() { echo $((5598 + 2 * $1)); }        # emulator console (at most 5682); adbd on this + 1
sim_android_serial() { echo "emulator-$(sim_android_port "$1")"; }
sim_adb_port() { echo $((5037 + $1)); }
sim_metro_port() { # sim_metro_port <platform> <N>
  case $1 in android) echo $((8100 + $2)) ;; web) echo $((8200 + $2)) ;; ios) echo $((8081 + 10 * ($2 - 1))) ;; esac
}
sim_ios_name() { echo "agent-ios-$1"; }

# Port blocks for test stacks: slot N of a platform owns SIM_PORT_BLOCK ports from sim_port_base, which no other slot
# and no sim service uses (android 20000-20899, web 21000-21899, ios 22000-22899 for slots 1-9; below the ephemeral
# range 32768 and up). `sim ports` hands them out; sim_android_env exports them for android.
SIM_PORT_BLOCK=100
sim_port_base() { # sim_port_base <platform> <N>
  local idx
  case $1 in android) idx=0 ;; web) idx=1 ;; ios) idx=2 ;; *) sim_fail "unknown platform: $1 (one of: $SIM_PLATFORMS)"; return 1 ;; esac
  echo $((20000 + 1000 * idx + SIM_PORT_BLOCK * ($2 - 1)))
}
sim_port_block() { # sim_port_block <platform> <N>: "<base> <count>", for `read -r base count`
  local base; base=$(sim_port_base "$1" "$2") || return 1
  echo "$base $SIM_PORT_BLOCK"
}
# sim_port_env <platform> <N> [count]: the exports SIM_PORT_BASE and SIM_PORT_COUNT (the whole block); with a count
# (.sim/config ports), SIM_PORT_COUNT is that and SIM_PORTS lists those ports.
sim_port_env() {
  local base; base=$(sim_port_base "$1" "$2") || return 1
  printf 'export SIM_PORT_BASE=%s\nexport SIM_PORT_COUNT=%s\n' "$base" "${3:-$SIM_PORT_BLOCK}"
  [ -z "${3:-}" ] || printf "export SIM_PORTS='%s'\n" "$(seq -s ' ' "$base" $((base + $3 - 1)))"
}

# sim_root [dir]: the worktree a command or an MCP server belongs to: the git top level, else the directory itself.
sim_root() {
  local d=${1:-$PWD}
  git -C "$d" rev-parse --show-toplevel 2>/dev/null || (cd "$d" && pwd -P)
}

# sim_app_rel [dir] [root]: where the app sits inside its worktree ("." at the top), for a monorepo's client/.
sim_app_rel() {
  local d root
  d=$(cd "${1:-$PWD}" && pwd -P); root=${2:-$(sim_root "$d")}
  realpath --relative-to="$root" "$d"
}

# sim_tree_name <root>: a stable directory name for a worktree on the Mac, <base>-<h6>. <base> is the agent session
# naming (bin/agent): <repo> for a checkout, <repo>-<slug> for ~/workspace/<repo>.wt/<slug>, with anything outside
# [A-Za-z0-9._-] made `_`. <h6> is the start of sha256(root), so two roots never share a tree on the Mac: not two
# checkouts with one basename, not foo.wt/bar and a repo called foo-bar.
sim_tree_name() {
  local root=$1 parent base h
  parent=$(basename "$(dirname "$root")")
  case $parent in
    *.wt) base="${parent%.wt}-$(basename "$root")" ;;
    *)    base=$(basename "$root") ;;
  esac
  h=$(printf %s "$root" | sha256sum); h=${h:0:6}
  printf '%s-%s\n' "${base//[^A-Za-z0-9._-]/_}" "$h"
}

# sim_mac_path <root> [app]: where a worktree (and its app, a path relative to the root as sim_app_rel gives it) sits
# on the Mac, relative to the runner's home: sims/<tree>[/<app>]. For messages; remote commands use sim_mac_dir.
sim_mac_path() {
  local p; p=sims/$(sim_tree_name "$1")
  case ${2:-.} in .) ;; *) p=$p/$2 ;; esac
  printf '%s\n' "$p"
}

# sim_mac_dir <root> [app]: sim_mac_path quoted with printf %q, the form every remote command takes. The runner's login
# shell (zsh on macOS) reads \-escapes and $'...' as bash writes them, so an app directory with a space or a ' survives.
# The tree name itself never needs quoting, so sims/<tree> is also safe as an rsync destination (see cmd_ios sync).
sim_mac_dir() {
  local p; p=$(sim_mac_path "$@") || return 1
  printf '%q\n' "$p"
}

# The stamp `sim ios sync` touches in a tree on the Mac before each rsync; `sim ios gc` goes by its age, because rsync -a
# gives the tree the mtime of the worktree on the host, however old that is.
SIM_SYNC_STAMP=.agent-sim-synced

# sim_lease <platform> [root] [kind] [until]: take a slot, the one this worktree had last if it is free, else the
# first free one. kind is mcp (bin/sim-mcp, the default) or cli (`sim lease`, which also passes the epoch its lease
# ends at). Sets SIM_SLOT to its number and SIM_LOCK_FD to the open lock, which the caller keeps open (an exec'd
# server inherits it) for as long as it wants the slot. Must run in the caller's shell, never in $(...): a subshell
# would take the lock with it when it exits. Returns 1, having printed who holds what, when every slot is taken.
sim_lease() {
  local platform=$1 root=${2:-$(sim_root)} kind=${3:-mcp} until=${4:-} count n last order fd dir key me=$BASHPID
  count=$(sim_slots "$platform") || return 1
  dir=$SIM_STATE/$platform; key=$(sim_root_key "$root")
  mkdir -p "$dir/last" || return 1
  last=$(cat "$dir/last/$key" 2>/dev/null || true)
  [[ $last =~ ^[1-9]$ ]] && [ "$last" -le "$count" ] || last=
  order=$last
  for ((n = 1; n <= count; n++)); do [ "$n" = "$last" ] || order+=" $n"; done
  for n in $order; do
    exec {fd}>>"$dir/$n.lock"
    # -w 0.2, not -n: sim_held probes by taking the lock for an instant, and a lease must not skip a free slot
    # because `sim status` happened to look at it at the same moment.
    if flock -w 0.2 "$fd"; then
      # Written whole, then renamed: a reader (sim status, my_slot) never sees half an owner file.
      # ppid: the harness that started bin/sim-mcp, which sim_my_slot looks for among its caller's ancestors.
      { printf 'pid=%s\nppid=%s\nroot=%s\nsince=%s\nkind=%s\n' "$me" "$(sim_ppid "$me")" "$root" "$(date +%FT%T)" "$kind"
        [ -z "$until" ] || printf 'until=%s\n' "$until"; } > "$dir/.$n.owner.$me" && mv -f "$dir/.$n.owner.$me" "$dir/$n.owner"
      echo "$n" > "$dir/last/$key.$me" && mv -f "$dir/last/$key.$me" "$dir/last/$key"
      sim_takeover "$platform" "$n" {fd}>&-
      SIM_SLOT=$n; SIM_LOCK_FD=$fd
      return 0
    fi
    exec {fd}>&-
  done
  sim_fail "all $count $platform slots are leased:"
  sim_holders "$platform" >&2
  return 1
}

sim_root_key() { printf %s "$1" | sha256sum | cut -c1-12; }   # sim_root_key <root>: its file name under last/

sim_ppid() { sim_stat_field "$1" 4; }                            # sim_ppid <pid>: its parent's pid

# sim_takeover <platform> <N>: stop the process group in <N>.pgid (the MCP server of the slot's previous holder,
# written by bin/sim-mcp) if it outlived that holder, so a new lease never shares the device with it.
sim_takeover() {
  local f=$SIM_STATE/$1/$2.pgid pg own i me=$BASHPID
  [ -e "$f" ] || return 0
  pg=$(cat "$f" 2>/dev/null || true); rm -f "$f"
  own=$(sim_stat_field "$me" 5)
  # Never group 0 or 1 (kill would take every process) nor our own.
  [[ $pg =~ ^[0-9]+$ ]] && [ "$pg" -gt 1 ] && [ "$pg" != "$own" ] && kill -0 -- "-$pg" 2>/dev/null || return 0
  kill -TERM -- "-$pg" 2>/dev/null || true
  for ((i = 0; i < 30; i++)); do kill -0 -- "-$pg" 2>/dev/null || break; sleep 0.1; done
  ! kill -0 -- "-$pg" 2>/dev/null || kill -KILL -- "-$pg" 2>/dev/null || true
  printf "sim: stopped a server left by the slot's previous holder (pgid %s)\n" "$pg" >&2
}

sim_stat_field() { # sim_stat_field <pid> <n>: field n (3 and up) of /proc/<pid>/stat; the name in 2 may hold spaces
  local s fields
  s=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
  read -r -a fields <<< "${s##*) }"
  echo "${fields[$2 - 3]}"
}

sim_held() { # sim_held <platform> <N>: true while someone holds the slot (probes by taking the lock for an instant)
  local f=$SIM_STATE/$1/$2.lock
  [ -e "$f" ] || return 1
  ! flock -n "$f" true
}

sim_owner_field() { # sim_owner_field <platform> <N> <key>
  sed -n "s/^$3=//p" "$SIM_STATE/$1/$2.owner" 2>/dev/null
}

sim_holders() { # sim_holders <platform>: one line per leased slot
  local platform=$1 n count
  count=$(sim_slots "$platform") || return 1
  for ((n = 1; n <= count; n++)); do
    sim_held "$platform" "$n" && printf '  %s %s  pid %s  %s\n' "$platform" "$n" \
      "$(sim_owner_field "$platform" "$n" pid)" "$(sim_owner_field "$platform" "$n" root)"
  done
  return 0
}

# sim_my_slot <platform> [root]: the slot leased for this worktree (by an MCP server or `sim lease`); returns 1 when
# there is none. When two harness sessions in one worktree each hold one, the caller's own session wins: the slot
# whose holder's parent (the harness) is an ancestor of this process. Otherwise the lowest.
sim_my_slot() {
  local platform=$1 root=${2:-$(sim_root)} n count mine=() up p
  count=$(sim_slots "$platform") || return 1
  for ((n = 1; n <= count; n++)); do
    sim_held "$platform" "$n" && [ "$(sim_owner_field "$platform" "$n" root)" = "$root" ] && mine+=("$n")
  done
  [ ${#mine[@]} -gt 0 ] || return 1
  if [ ${#mine[@]} -gt 1 ]; then
    up=' '; p=$BASHPID
    while [[ $p =~ ^[0-9]+$ ]] && [ "$p" -gt 1 ]; do up+="$p "; p=$(sim_ppid "$p") || break; done
    for n in "${mine[@]}"; do
      p=$(sim_owner_field "$platform" "$n" ppid)
      [ -n "$p" ] && [[ $up == *" $p "* ]] && { echo "$n"; return 0; }
    done
  fi
  echo "${mine[0]}"
}

# sim_android_env <N>: the environment that points Android tools at slot N and nothing else.
sim_android_env() {
  local java
  java=$(mise where java@temurin-17 2>/dev/null || true)
  printf 'export ANDROID_HOME=%q\n' "$ANDROID_HOME"
  printf 'export ANDROID_SDK_ROOT=%q\n' "$ANDROID_HOME"
  [ -z "$java" ] || printf 'export JAVA_HOME=%q\n' "$java"
  printf 'export ANDROID_ADB_SERVER_PORT=%s\n' "$(sim_adb_port "$1")"
  printf 'export ANDROID_SERIAL=%s\n' "$(sim_android_serial "$1")"
  sim_port_env android "$1"
  printf 'export PATH=%q:$PATH\n' "${java:+$java/bin:}$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator"
}

# --- uptime ----------------------------------------------------------------------------------------------------

sim_touch() { mkdir -p "$SIM_STATE/$1" && touch "$SIM_STATE/$1/$2.active"; }   # sim_touch <platform> <N>: in use now

sim_idle_secs() { # sim_idle_secs <platform> <N>: seconds since the slot was last used; returns 1 when it never was
  local f=$SIM_STATE/$1/$2.active
  [ -e "$f" ] || return 1
  echo $(($(date +%s) - $(stat -c %Y "$f")))
}

sim_android_unit() { echo "agent-sim-android@$1.service"; }

# sim_android_wait <N> <secs>: block until slot N's emulator has booted. Quiet; returns 1 on timeout.
sim_android_wait() {
  ( eval "$(sim_android_env "$1")"
    timeout "$2" adb wait-for-device shell 'while [ "$(getprop sys.boot_completed)" != 1 ]; do sleep 2; done' ) >/dev/null 2>&1
}

# sim_ios_boot <N>: boot agent-ios-N on the Mac (nothing if it is up) and wait until it shows its home screen.
# bootstatus returns about a second before SpringBoard draws (14 Oct 2026: a screenshot then shows the boot spinner),
# hence the settle after a cold boot.
sim_ios_boot() {
  local d; d=$(sim_ios_name "$1")
  sim_ios_ssh "xcrun simctl list devices | grep -F '$d (' | grep -q '(Booted)' && exit 0; xcrun simctl bootstatus $d -b && sleep ${SIM_IOS_SETTLE:-4}" \
    </dev/null >/dev/null 2>&1
}

# sim_ios_shutdown <N>: shut agent-ios-N down and stop the slot's Metro on the Mac; true when the Mac answered.
sim_ios_shutdown() {
  sim_ios_ssh "xcrun simctl shutdown $(sim_ios_name "$1") 2>/dev/null; pkill -f 'expo start.*--port $(sim_metro_port ios "$1")'; true" \
    </dev/null >/dev/null 2>&1
}

# sim_ios_ssh [-tt] <cmd...>: run on the Mac as the iOS runner account. BatchMode: an agent can never answer a
# prompt. -tt gives the command a terminal, so Ctrl-C on the host reaches it. Short commands share one connection
# (ControlMaster, kept 60 s after the last one ends); a dead link is noticed after 2 unanswered keepalives (60 s).
# With SIM_SSH_TIMEOUT set, a command (never one with -tt) is killed after that many seconds.
# ssh takes the first value it is given for an option, so extra options go before SIM_SSH_OPTS, never after.
SIM_SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=2
  -o ControlMaster=auto -o "ControlPath=$SIM_STATE/ios/ssh-%C" -o ControlPersist=60)
# Long sessions (the MCP server, tunnels) take a connection of their own, so a dropped master never takes them down.
SIM_SSH_SOLO_OPTS=(-o ControlMaster=no -o ControlPath=none)
sim_ios_ssh() {
  local tty=() pre=()
  [ "${1:-}" = -tt ] && { tty=(-tt); shift; }
  [ -n "${AGENT_IOS_HOST:-}" ] && [ -n "${AGENT_IOS_USER:-}" ] \
    || { sim_fail "AGENT_IOS_HOST and AGENT_IOS_USER must be set in .env (docs/simulators-plan.md)"; return 1; }
  mkdir -p "$SIM_STATE/ios" || return 1
  [ -z "${SIM_SSH_TIMEOUT:-}" ] || [ ${#tty[@]} -gt 0 ] || pre=(timeout "$SIM_SSH_TIMEOUT")
  "${pre[@]}" ssh "${SIM_SSH_OPTS[@]}" "${tty[@]}" "$AGENT_IOS_USER@$AGENT_IOS_HOST" "$@"
}

# --- Mac health ------------------------------------------------------------------------------------------------
# One probe decides whether the Mac answers: a fresh connection (never the shared master, which a frozen Mac can
# keep hanging for a minute) running `true` within SIM_MAC_PROBE_TIMEOUT seconds (5). The result is cached as
# "up|down <epoch>" in $SIM_STATE/ios/mac.state for SIM_MAC_PROBE_TTL seconds (30), so a burst of commands asks once.

sim_mac_configured() { [ -n "${AGENT_IOS_HOST:-}" ] && [ -n "${AGENT_IOS_USER:-}" ]; }

sim_mac_record() { # sim_mac_record up|down: cache a result; down also drops the shared master, which may be stale
  local s
  mkdir -p "$SIM_STATE/ios" && echo "$1 $(date +%s)" > "$SIM_STATE/ios/mac.state"
  [ "$1" = down ] || return 0
  for s in "$SIM_STATE"/ios/ssh-*; do
    [ -S "$s" ] || continue
    timeout 5 ssh -o "ControlPath=$s" -O exit "$AGENT_IOS_USER@$AGENT_IOS_HOST" </dev/null >/dev/null 2>&1 || rm -f "$s"
  done
  return 0
}

# sim_mac_probe [--fresh]: 0 when the Mac answers, 1 when it does not, 2 when no Mac is configured. --fresh skips the
# cache. Quiet.
sim_mac_probe() {
  local to=${SIM_MAC_PROBE_TIMEOUT:-5} st at now
  sim_mac_configured || return 2
  if [ "${1:-}" != --fresh ] && read -r st at 2>/dev/null < "$SIM_STATE/ios/mac.state"; then
    now=$(date +%s)
    if [[ $at =~ ^[0-9]+$ ]] && [ $((now - at)) -lt "${SIM_MAC_PROBE_TTL:-30}" ]; then
      case $st in up) return 0 ;; down) return 1 ;; esac
    fi
  fi
  mkdir -p "$SIM_STATE/ios" || return 1
  # timeout as well as ConnectTimeout: a frozen Mac whose kernel still accepts the connection never sends its banner.
  if timeout $((to + 1)) ssh "${SIM_SSH_SOLO_OPTS[@]}" -o "ConnectTimeout=$to" "${SIM_SSH_OPTS[@]}" \
       "$AGENT_IOS_USER@$AGENT_IOS_HOST" true </dev/null >/dev/null 2>&1; then
    sim_mac_record up; return 0
  fi
  sim_mac_record down; return 1
}

# sim_mac_require: return when the Mac answers; otherwise print why and exit, 3 (unavailable, retry later) when it
# does not answer, 1 when none is configured. For commands that cannot do anything without the Mac.
sim_mac_require() {
  local rc=0
  sim_mac_probe || rc=$?
  case $rc in
    0) return 0 ;;
    2) sim_fail "AGENT_IOS_HOST and AGENT_IOS_USER must be set in .env (docs/simulators-plan.md)" || exit 1 ;;
    *) sim_fail "mac unreachable: $AGENT_IOS_USER@$AGENT_IOS_HOST did not answer within ${SIM_MAC_PROBE_TIMEOUT:-5} s (sim status)" || exit 3 ;;
  esac
}

# What rsync leaves out when a worktree goes to the Mac: VCS data, dependencies and build output (rebuilt there),
# and .env files, which may hold secrets that have no business on another machine. Excluded paths are also kept
# safe from --delete on the Mac, so its node_modules and Pods survive every sync. The stack's own rules
# (sim_stack_rsync_rules) come after these.
SIM_RSYNC_EXCLUDES=(.git node_modules dist/ '.env' '.env.*' '*.keystore' '*.jks' '*.p12' '*.mobileprovision')

sim_rsync_args() { # sim_rsync_args: the rsync options for a sync of a worktree
  local e
  printf '%s\n' -az --delete
  for e in "${SIM_RSYNC_EXCLUDES[@]}"; do printf '%s\n' "--exclude=$e"; done
  sim_stack_rsync_rules || return
  # The sync stamp is the Mac's own (sim ios gc reads it), so --delete must leave it too.
  printf '%s\n' "--filter=P $SIM_SYNC_STAMP"
}

# --- per-repo needs (.sim/config) and the stack seam -----------------------------------------------------------
# A repo states what it needs from sim in a committed .sim/config: `key = value` lines, `#` comment lines, blank
# lines. It is read by sim_repo_config, never sourced, so a value is only ever data. Precedence for every key: a CLI
# flag, then an environment variable, then .sim/config, then the host's .env, then the default.
SIM_CFG_KEYS="stack app_dir metro_env forward_ios ports keep_runs"

# sim_repo_config <root>: read <root>/.sim/config into SIM_CFG_STACK, SIM_CFG_APP_DIR, SIM_CFG_METRO_ENV,
# SIM_CFG_FORWARD_IOS, SIM_CFG_PORTS and SIM_CFG_KEEP_RUNS (each unset when the file does not give it; no file is
# rc 0). An unknown key warns on stderr. A malformed line or a bad value is rc 2, naming .sim/config:<line>. No other
# side effects: sim enable --check calls it to see that the file parses.
sim_repo_config() {
  local file=$1/.sim/config line key val n=0 k
  for k in $SIM_CFG_KEYS; do unset "SIM_CFG_${k^^}"; done
  [ -e "$file" ] || return 0
  [ -f "$file" ] && [ -r "$file" ] || { printf 'sim: .sim/config: not a readable file\n' >&2; return 2; }
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    [[ $line =~ ^[[:space:]]*(#.*)?$ ]] && continue
    if ! [[ $line =~ ^[[:space:]]*([a-z_]+)[[:space:]]*=[[:space:]]*(.*[^[:space:]])?[[:space:]]*$ ]]; then
      printf 'sim: .sim/config:%s: expected key = value, got: %s\n' "$n" "$line" >&2; return 2
    fi
    key=${BASH_REMATCH[1]} val=${BASH_REMATCH[2]}
    case $key in
      stack)
        [ "$val" = expo ] || { sim_cfg_bad "$n" "stack = $val: the only stack is expo"; return 2; } ;;
      app_dir)   # a directory inside the worktree, relative to its top
        val=${val%/}
        if ! [[ $val =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] || [[ /$val/ == */../* ]]; then
          sim_cfg_bad "$n" "app_dir = $val: a relative path inside the worktree (letters, digits, . _ - and /, no ..)"; return 2
        fi ;;
      metro_env) # names, as SIM_METRO_ENV takes them
        val=${val//[[:space:]]/}
        [[ $val =~ ^([A-Za-z_][A-Za-z0-9_]*(,[A-Za-z_][A-Za-z0-9_]*)*)?$ ]] \
          || { sim_cfg_bad "$n" "metro_env = $val: a comma list of variable names"; return 2; } ;;
      forward_ios)
        val=${val//[[:space:]]/}
        sim_cfg_ports_ok "$val" || { sim_cfg_bad "$n" "forward_ios = $val: a comma list of ports from 1 to 65535"; return 2; } ;;
      ports)
        [[ $val =~ ^[0-9]{1,3}$ ]] && [ "$((10#$val))" -ge 1 ] && [ "$((10#$val))" -le "$SIM_PORT_BLOCK" ] \
          || { sim_cfg_bad "$n" "ports = $val: from 1 to $SIM_PORT_BLOCK, the size of a slot's port block"; return 2; }
        val=$((10#$val)) ;;
      keep_runs)
        [[ $val =~ ^[0-9]{1,2}$ ]] && [ "$((10#$val))" -ge 1 ] && [ "$((10#$val))" -le 50 ] \
          || { sim_cfg_bad "$n" "keep_runs = $val: Maestro runs to keep per slot, 1 to 50"; return 2; }
        val=$((10#$val)) ;;
      *) printf 'sim: .sim/config:%s: unknown key %s, ignored (keys: %s)\n' "$n" "$key" "$SIM_CFG_KEYS" >&2; continue ;;
    esac
    printf -v "SIM_CFG_${key^^}" '%s' "$val"
  done < "$file"
  return 0
}

# sim_repo_apply <root>: sim_repo_config, then the keys that override a host parameter: keep_runs replaces
# AGENT_SIM_KEEP_RUNS from .env or the default, never one set in the environment. rc 2 on a bad file.
sim_repo_apply() {
  sim_repo_config "$1" || return
  [ -n "${SIM_ENV_KEEP_RUNS:-}" ] || [ -z "${SIM_CFG_KEEP_RUNS:-}" ] || AGENT_SIM_KEEP_RUNS=$SIM_CFG_KEEP_RUNS
  return 0
}

sim_cfg_bad() { printf 'sim: .sim/config:%s: %s\n' "$1" "$2" >&2; }

sim_cfg_ports_ok() { # sim_cfg_ports_ok <list>: empty, or comma-separated ports 1-65535
  local p
  [ -z "$1" ] && return 0
  [[ $1 =~ ^[0-9]{1,5}(,[0-9]{1,5})*$ ]] || return 1
  for p in ${1//,/ }; do [ "$((10#$p))" -ge 1 ] && [ "$((10#$p))" -le 65535 ] || return 1; done
}

# sim_repo_config_template: what sim enable writes to a repo without a .sim/config.
sim_repo_config_template() {
  cat <<EOF
# .sim/config: what this repo needs from sim (the device simulation service). Commit it.
# Lines are key = value, or a comment starting with #. Every key is optional: the values below are the defaults.
# A command-line flag or an environment variable beats this file; this file beats the host's settings.

# The app's toolchain. expo is the only one so far.
# stack = expo

# The app's directory, relative to the repo's top, for sim commands run at the top (a monorepo's client/).
# Run from anywhere else, sim uses the directory it runs in.
# app_dir = .

# Variables sim metro start passes to Metro, besides EXPO_PUBLIC_* (comma list; SIM_METRO_ENV beats it).
# metro_env =

# Host ports that sim maestro ios makes reachable on the Mac when --forward is absent (--forward none: none), and
# that sim tunnel ios forwards when given no ports. From sim ports ios.
# forward_ios =

# How many ports of the slot's block of $SIM_PORT_BLOCK the test stack uses: eval "\$(sim ports <platform>)" sets
# SIM_PORT_COUNT to it and lists them in SIM_PORTS. 1 to $SIM_PORT_BLOCK.
# ports = $SIM_PORT_BLOCK

# Maestro run directories kept per slot (1 to 50; AGENT_SIM_KEEP_RUNS beats it; default: the host's, 5).
# keep_runs = 5
EOF
}

sim_stack() { echo "${SIM_CFG_STACK:-expo}"; }   # the stack of the repo whose .sim/config was read last

sim_stack_unknown() { sim_fail "unknown stack $(sim_stack) (.sim/config)"; return 2; }

# sim_stack_build_android <port> [args]: the command that builds, installs and opens the dev build on the slot's
# emulator, served by the slot's Metro on <port>, into SIM_STACK_CMD. Expo: --port bakes the port into the build and
# finds Metro already running there, so Expo starts no Metro of its own. Without it, Expo falls back to 8081: a Metro
# shared by every agent, or none. (--port and --no-bundler cannot go together.)
sim_stack_build_android() {
  local port=$1; shift
  case $(sim_stack) in
    expo) SIM_STACK_CMD=(npx expo run:android --port "$port" "$@") ;;
    *) sim_stack_unknown ;;
  esac
}

# sim_stack_metro_cmd <port> [--web]: the command that starts the slot's bundler on <port>, into SIM_STACK_CMD.
sim_stack_metro_cmd() {
  case $(sim_stack) in
    expo) SIM_STACK_CMD=(npx expo start --port "$1"); [ "${2:-}" != --web ] || SIM_STACK_CMD+=(--web) ;;
    *) sim_stack_unknown ;;
  esac
}

# sim_stack_ios_prepare_cmd: the shell command (for the runner's shell on the Mac, run in the app's directory there)
# that installs the dependencies and generates the Xcode workspace.
sim_stack_ios_prepare_cmd() {
  case $(sim_stack) in
    expo) echo 'npm ci --no-audit --no-fund && CI=1 npx expo prebuild -p ios --no-install && cd ios && pod install' ;;
    *) sim_stack_unknown ;;
  esac
}

# sim_stack_rsync_rules: the stack's rsync rules for a sync, one per line: its build output and generated projects.
sim_stack_rsync_rules() {
  case $(sim_stack) in
    expo)
      printf '%s\n' --exclude=ios/Pods/ --exclude=ios/build/ --exclude=android/ --exclude=.expo/ --exclude=web-build/
      # Expo generates ios/ on the Mac with prebuild; the host has none, and --delete must not take the Mac's away.
      printf '%s\n' '--filter=P ios/' ;;
    *) sim_stack_unknown ;;
  esac
}

# --- per-repo MCP registration (sim enable) -------------------------------------------------------------------
# Every entry is only `sim-mcp <platform>`: no path, host or login, so the files can be committed to the repo.

sim_server_name() { echo "sim-$1"; }

# sim_write_mcp_json <file> <platform...>: Claude Code and Oh My Pi read a project's .mcp.json.
sim_write_mcp_json() {
  local file=$1 p tmp; shift
  tmp=$(mktemp)
  [ -s "$file" ] && cat "$file" > "$tmp" || echo '{}' > "$tmp"
  for p in "$@"; do
    jq --arg n "$(sim_server_name "$p")" --arg p "$p" \
      '.mcpServers[$n] = {command: "sim-mcp", args: [$p]}' "$tmp" > "$tmp.new" || { rm -f "$tmp" "$tmp.new"; sim_fail "$file is not valid JSON"; return 1; }
    mv "$tmp.new" "$tmp"
  done
  cat "$tmp" > "$file"; rm -f "$tmp"
}

# sim_write_opencode_json <file> <platform...>: OpenCode reads a project's opencode.json.
sim_write_opencode_json() {
  local file=$1 p tmp; shift
  tmp=$(mktemp)
  [ -s "$file" ] && cat "$file" > "$tmp" || echo '{"$schema": "https://opencode.ai/config.json"}' > "$tmp"
  for p in "$@"; do
    jq --arg n "$(sim_server_name "$p")" --arg p "$p" \
      '.mcp[$n] = {type: "local", command: ["sim-mcp", $p], enabled: true}' "$tmp" > "$tmp.new" || { rm -f "$tmp" "$tmp.new"; sim_fail "$file is not valid JSON (comments are not supported)"; return 1; }
    mv "$tmp.new" "$tmp"
  done
  cat "$tmp" > "$file"; rm -f "$tmp"
}

# sim_write_codex_toml <file> <platform...>: Codex reads a project's .codex/config.toml once the project is trusted
# (trusting the main checkout covers its worktrees). The servers live in one marker block, replaced on every run.
sim_write_codex_toml() {
  local file=$1 p body='' begin='# >>> agentic-framework:sim >>>' end='# <<< agentic-framework:sim <<<' tmp; shift
  for p in "$@"; do
    # tool_timeout_sec: a call to a device that is down waits for its boot (sim-mcp), Codex's default is 60 s.
    body+="[mcp_servers.$(sim_server_name "$p")]"$'\n'"command = \"sim-mcp\""$'\n'"args = [\"$p\"]"$'\n'"startup_timeout_sec = 30"$'\n'"tool_timeout_sec = 300"$'\n'
  done
  mkdir -p "$(dirname "$file")"; touch "$file"
  tmp=$(mktemp)
  awk -v b="$begin" -v e="$end" '$0==b {skip=1; next} $0==e {skip=0; next} !skip' "$file" > "$tmp"
  # A table runs to the next header, so the block goes at the end, after a blank line.
  sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$tmp" > "$tmp.trim"
  { cat "$tmp.trim"; [ -s "$tmp.trim" ] && echo; printf '%s\n%s%s\n' "$begin" "$body" "$end"; } > "$file"
  rm -f "$tmp" "$tmp.trim"
}
