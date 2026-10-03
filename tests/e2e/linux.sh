#!/usr/bin/env bash
# tests/e2e/linux.sh: install-linux.sh on several Linux distributions against one real host. "box" is the run.sh host
# image (real sshd, install-host.sh --no-tools as alice); each distro in DISTROS gets a client container from
# Dockerfile.linux that starts without the ssh client, mosh, wl-clipboard or xclip, so the script must install them
# through sudo with linuxuser's password (shims/linux/askpass answers sudo and ssh and logs every prompt). Per distro:
# first run (sudo once, ssh password once), key login, the rendered WezTerm module with the Linux keys, clip-push
# against a real X clipboard (Xvfb + xclip), the paste key through tests/e2e/wezterm-paste.lua with the bytes checked
# on the host, and a second run that must prompt for nothing. Distros in WAYLAND_DISTROS repeat the clipboard checks
# under a headless sway with wl-paste. The script's refusal to run on the host itself is checked on box.
# Needs docker without sudo, and network during the run as well as the builds: the clients install packages from
# their distro mirrors, which is the point. KEEP=1 leaves the containers running; LX_LOG_DIR=<dir> keeps each
# distro's first install-linux.sh output there.
# Usage: bash tests/e2e/linux.sh
#        DISTROS="fedora:41" bash tests/e2e/linux.sh      one or more base images, space separated
# shellcheck disable=SC2015,SC2016
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
NET=af-lx; BOX=af-lx-box
LOGIN=alice; PASSWORD=alice-pw; ALIAS=box; LUSER=linuxuser; SUDO_PW=linux-pw
DISTROS=${DISTROS:-ubuntu:24.04 debian:12 fedora:41 archlinux:latest opensuse/tumbleweed}
WAYLAND_DISTROS=${WAYLAND_DISTROS:-ubuntu:24.04}
BOX_REPO=/home/$LOGIN/workspace/agentic-framework; LX_HOME=/home/$LUSER; LX_REPO=$LX_HOME/workspace/agentic-framework
PNG_B64=iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==
T=$(mktemp -d); : > "$T/results"; CLIENTS=""
ok()    { echo ok >> "$T/results"; printf 'ok   %s\n' "$1"; }
bad()   { echo FAIL >> "$T/results"; printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
has()   { case "$2" in *"$1"*) ok "$3";; *) bad "$3" "output lacks [$1]";; esac; }   # has <needle> <haystack> <name>
say()   { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
cleanup() {
  if [ "${KEEP:-0}" = 1 ]; then echo "KEEP=1: containers $BOX$CLIENTS left running on network $NET"; return; fi
  # shellcheck disable=SC2086
  docker rm -f "$BOX" $CLIENTS >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1; rm -rf "$T"
}
trap cleanup EXIT
box()  { docker exec -u "$LOGIN" -e "HOME=/home/$LOGIN" -w "$BOX_REPO" "$BOX" "$@"; }
strip() { tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g'; }
run() { RAW=$("$@" 2>&1); RC=$?; OUT=$(printf '%s\n' "$RAW" | strip); }
slug() { printf '%s' "$1" | tr ':/.' '---'; }

say "host image and container"
command -v docker >/dev/null || { echo "docker is required" >&2; exit 2; }
docker rm -f "$BOX" >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1
docker build -q -f "$REPO/tests/e2e/Dockerfile.host" --build-arg "LOGIN=$LOGIN" --build-arg "PASSWORD=$PASSWORD" -t af-e2e-host "$REPO/tests/e2e" >/dev/null || { echo "host image build failed" >&2; exit 1; }
docker network create "$NET" >/dev/null
docker run -d --name "$BOX" --hostname "$ALIAS" --network "$NET" --network-alias "$ALIAS" af-e2e-host >/dev/null
BOX_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$BOX")
docker exec "$BOX" install -d -o "$LOGIN" -g "$LOGIN" "$BOX_REPO" "/home/$LOGIN/workspace"
tar -C "$REPO" --exclude=.git --exclude=.env -cf - . | docker exec -i -u "$LOGIN" "$BOX" tar -C "$BOX_REPO" -xf -
run box ./install-host.sh --no-tools
check "host: install-host.sh --no-tools exit 0" 0 "$RC"
has "Parameters for the clients" "$OUT" "host: prints the .env block for the clients"
run box ./install-linux.sh --no-packages
check "host: install-linux.sh refuses to run on the host -> exit 1" 1 "$RC"
has "looks like the agent host" "$OUT" "host: says why"

n_clients=0
for distro in $DISTROS; do
  s=$(slug "$distro"); C=af-lx-c-$s; IMG=af-lx-$s; CLIENTS="$CLIENTS $C"
  wl=0; case " $WAYLAND_DISTROS " in *" $distro "*) wl=1;; esac
  say "$distro: image and container"
  docker rm -f "$C" >/dev/null 2>&1
  if ! docker build -q --build-arg "BASE=$distro" --build-arg "WAYLAND=$wl" --build-arg "SUDO_PASSWORD=$SUDO_PW" \
       -f "$REPO/tests/e2e/Dockerfile.linux" -t "$IMG" "$REPO/tests/e2e" >"$T/build.log" 2>&1; then
    bad "$distro: image builds" "$(tail -5 "$T/build.log")"; continue
  fi
  docker run -d --name "$C" --hostname "lx-$s" --network "$NET" "$IMG" >/dev/null
  # lx: a command as linuxuser on an X11 desktop. lxe: the same with extra docker exec options first.
  lx()  { docker exec -u "$LUSER" -e "HOME=$LX_HOME" -e DISPLAY=:99 -w "$LX_REPO" "$C" "$@"; }
  lxe() { local opts=(); while [ "${1:-}" != -- ]; do opts+=("$1"); shift; done; shift
          docker exec -u "$LUSER" -e "HOME=$LX_HOME" -e DISPLAY=:99 "${opts[@]}" -w "$LX_REPO" "$C" "$@"; }
  docker exec -u "$LUSER" "$C" install -d "$LX_REPO"
  tar -C "$REPO" --exclude=.git --exclude=.env -cf - . | docker exec -i -u "$LUSER" "$C" tar -C "$LX_REPO" -xf -
  lx sh -c "printf 'AGENT_HOST=$ALIAS\nAGENT_HOST_ADDRESS=$ALIAS\nAGENT_HOST_USER=$LOGIN\nAGENT_HOST_LAN_IP=$BOX_IP\n' > .env"
  check "$distro: starts without the ssh client, mosh and the clipboard tools" "" \
    "$(lx sh -c 'for c in ssh mosh wl-paste xclip; do command -v $c; done')"

  say "$distro: ./install-linux.sh (first run: sudo password once, host password once)"
  ASK=(-e SSH_ASKPASS=/usr/local/bin/askpass -e SSH_ASKPASS_REQUIRE=force -e SUDO_ASKPASS=/usr/local/bin/askpass
       -e "E2E_PASSWORD=$PASSWORD" -e "E2E_SUDO_PASSWORD=$SUDO_PW" -e SHELL=/bin/bash)
  run lxe -t "${ASK[@]}" -- ./install-linux.sh; out=$OUT
  printf '%s\n' "$out" > "${LX_LOG_DIR:-$T}/install-$s.log"
  check "$distro: exit 0" 0 "$RC"
  [ "$RC" = 0 ] || printf '%s\n' "$out" | tail -15 | sed 's/^/     | /'
  has "sudo will ask for a password once" "$out" "$distro: says sudo will ask"
  check "$distro: sudo asked once" 1 "$(lx sh -c 'grep -c "\[sudo\]" /tmp/askpass.log' 2>/dev/null)"
  for c in ssh ssh-copy-id mosh wl-paste xclip; do
    lx sh -c "command -v $c" >/dev/null 2>&1 && ok "$distro: $c installed" || bad "$distro: $c installed"
  done
  has "Enter $LOGIN's password on $ALIAS" "$out" "$distro: took the ssh password path"
  has "ok   ssh $ALIAS logs in by key" "$out" "$distro: key login established"
  check "$distro: key comment falls back to uname -n where hostname is missing" "$LUSER@lx-$s" "$(lx sh -c 'cut -d" " -f3 ~/.ssh/id_ed25519.pub')"
  check "$distro: ssh $ALIAS true without a prompt" ok "$(lx ssh -o BatchMode=yes "$ALIAS" echo ok 2>/dev/null)"
  check "$distro: ssh -G $ALIAS-lan hostname" "$BOX_IP" "$(lx ssh -G "$ALIAS-lan" 2>/dev/null | awk '$1=="hostname" {print $2}')"
  check "$distro: PATH block in ~/.bashrc" 1 "$(lx grep -c 'agentic-framework:path >>>' "$LX_HOME/.bashrc")"
  check "$distro: the Linux clip-push installed" 1 "$(lx grep -c 'wl-paste --list-types' "$LX_HOME/.local/bin/clip-push")"
  n_clients=$((n_clients + 1))
  check "host: one trusted key per client so far" "$n_clients" "$(box grep -c . "/home/$LOGIN/.ssh/authorized_keys")"

  # clip_checks <label> <exec options...>: text and image through clip-push and the paste key, with the clipboard
  # set by the matching tool (xclip or wl-copy). The options select the session (DISPLAY or WAYLAND_DISPLAY).
  clip_checks() {
    local label=$1; shift; local setter=$1; shift
    local o=("$@") pushed path png_sha apply
    lx sh -c "echo $PNG_B64 | base64 -d > /tmp/clip.png"
    png_sha=$(lx sha256sum /tmp/clip.png | cut -c1-64)
    lxe "${o[@]}" -- sh -c "printf 'plain-$s' | $setter >/dev/null 2>&1"
    check "$distro $label: text is reported" text/plain "$(lxe "${o[@]}" -- "$LX_HOME/.local/bin/clip-push" 2>&1)"
    check "$distro $label: text reached the spool" "plain-$s" "$(box cat "/home/$LOGIN/.clip/latest")"
    lxe "${o[@]}" -- sh -c "$setter -t image/png < /tmp/clip.png >/dev/null 2>&1"     # xclip and wl-copy both take -t
    pushed=$(lxe "${o[@]}" -- "$LX_HOME/.local/bin/clip-push" --if-image 2>&1 | tr -d '\r')
    check "$distro $label: image is reported" image/png "$(printf '%s\n' "$pushed" | sed -n 1p)"
    path=$(printf '%s\n' "$pushed" | sed -n 2p)
    check "$distro $label: the pushed file holds the PNG byte for byte" "$png_sha" "$(box sha256sum "$path" 2>/dev/null | cut -c1-64)"
    # The paste key as WezTerm runs it on Linux: the module under Lua 5.4 with the Linux target triple.
    apply=$(lxe "${o[@]}" -e WEZ_TRIPLE=x86_64-unknown-linux-gnu -- lua5.4 tests/e2e/wezterm-paste.lua apply 2>&1)
    has "key CTRL|SHIFT v callback" "$apply" "$distro $label: Ctrl+Shift+V is the routing callback"
    has "key CTRL|SHIFT a SpawnCommandInNewTab $ALIAS" "$apply" "$distro $label: Ctrl+Shift+A opens a tab in the host domain"
    out=$(lxe "${o[@]}" -e WEZ_TRIPLE=x86_64-unknown-linux-gnu -- lua5.4 tests/e2e/wezterm-paste.lua domain 2>&1); path=${out#paste }
    case "$out" in "paste /home/$LOGIN/.clip/"*.png) ok "$distro $label: paste key -> push, then paste the host path";; *) bad "$distro $label: paste key -> push, then paste the host path" "$out";; esac
    check "$distro $label: the pasted path holds the PNG byte for byte" "$png_sha" "$(box sha256sum "$path" 2>/dev/null | cut -c1-64)"
    lxe "${o[@]}" -- sh -c "printf typed | $setter >/dev/null 2>&1"
    check "$distro $label: text into the host domain -> plain paste" "action PasteFrom Clipboard" \
      "$(lxe "${o[@]}" -e WEZ_TRIPLE=x86_64-unknown-linux-gnu -- lua5.4 tests/e2e/wezterm-paste.lua domain 2>&1)"
  }

  say "$distro: clipboard under X11 (Xvfb, xclip)"
  clip_checks x11 "xclip -selection clipboard -i" -e DISPLAY=:99

  if [ "$wl" = 1 ]; then
    say "$distro: clipboard under Wayland (headless sway, wl-paste)"
    WL=(-e XDG_RUNTIME_DIR=/tmp/xdg -e WAYLAND_DISPLAY=wayland-1)
    lx sh -c 'mkdir -p -m 700 /tmp/xdg; echo "xwayland disable" > /tmp/sway.cfg'
    docker exec -d -u "$LUSER" -e XDG_RUNTIME_DIR=/tmp/xdg -e WLR_BACKENDS=headless -e WLR_RENDERER=pixman \
      -e WLR_LIBINPUT_NO_DEVICES=1 "$C" sh -c 'sway -c /tmp/sway.cfg > /tmp/sway.log 2>&1'
    for _ in $(seq 1 50); do lx test -S /tmp/xdg/wayland-1 && break; sleep 0.2; done
    # DISPLAY stays set too, as under XWayland: clip-push must prefer Wayland when both are there.
    clip_checks wayland wl-copy "${WL[@]}"
  fi

  say "$distro: second run (idempotency, no prompts)"
  asked=$(lx sh -c 'wc -l < /tmp/askpass.log')
  run lxe -t "${ASK[@]}" -- ./install-linux.sh; out2=$OUT
  check "$distro: second run exit 0" 0 "$RC"
  has "ok   all installed" "$out2" "$distro: second run installs nothing"
  has "ok   ssh $ALIAS logs in by key" "$out2" "$distro: second run finds key login"
  check "$distro: second run prompted for nothing" "$asked" "$(lx sh -c 'wc -l < /tmp/askpass.log')"
  check "$distro: still one agent-host block" 1 "$(lx grep -c 'agentic-framework:agent-host >>>' "$LX_HOME/.ssh/config")"
  check "$distro: still one PATH block" 1 "$(lx grep -c 'agentic-framework:path >>>' "$LX_HOME/.bashrc")"
  # A second run with an edited .env rewrites the marker blocks in place (awk), where the first only appended.
  lx sh -c "sed -i 's/^AGENT_HOST_LAN_IP=.*/AGENT_HOST_LAN_IP=10.9.9.9/' .env"
  run lxe -t "${ASK[@]}" -- ./install-linux.sh; out3=$OUT
  check "$distro: third run with a new LAN address exit 0" 0 "$RC"
  has "upd  $LX_HOME/.ssh/config [agent-host]" "$out3" "$distro: the agent-host block is replaced, not appended"
  check "$distro: ssh -G $ALIAS-lan follows the new address" 10.9.9.9 "$(lx ssh -G "$ALIAS-lan" 2>/dev/null | awk '$1=="hostname" {print $2}')"
  check "$distro: still one agent-host block after the rewrite" 1 "$(lx grep -c 'agentic-framework:agent-host >>>' "$LX_HOME/.ssh/config")"
  [ "${KEEP:-0}" = 1 ] || docker rm -f "$C" >/dev/null 2>&1
done

pass=$(grep -c '^ok$' "$T/results"); fail=$(grep -c '^FAIL$' "$T/results")
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
