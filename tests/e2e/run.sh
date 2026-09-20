#!/usr/bin/env bash
# tests/e2e/run.sh: two Docker containers on a private network, "box" (the host, real sshd, install-host.sh as alice
# with sudo) and "mac" (install-mac.sh as macuser, brew/osascript/pbpaste/pngpaste stubbed). The Mac script runs
# first through the password path (SSH_ASKPASS answers for the human), then once more for idempotency; the host
# script runs twice as well. Values are deliberately not the live ones (alias box, login alice), so a literal that
# slipped past tests/params-test.sh fails here. What a container cannot do (systemd, tailscale) is shimmed
# and logged; see tests/e2e/shims. The clipboard bridge is driven the way WezTerm drives it: the rendered module runs
# under Lua 5.4 (tests/e2e/wezterm-paste.lua) and its Cmd+V decision calls the real clip-push, which pushes over ssh
# to the real host and pastes back the path clip-put printed; the shell checks that file byte for byte. Driving the
# three harnesses with that pasted path needs their installers and is tests/e2e/harness-paste.sh. A second
# Mac (macuser2, same .env, own key) installs and pushes too, since the design is many Macs against one host.
# Needs docker without sudo; network only for the image builds. KEEP=1 leaves the containers running for a look
# around. Exit 0 when every check passes.
# Usage: bash tests/e2e/run.sh
# shellcheck disable=SC2015,SC2016
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
NET=af-e2e; BOX=af-e2e-box; MAC=af-e2e-mac
LOGIN=alice; PASSWORD=alice-pw; ALIAS=box
BOX_REPO=/home/$LOGIN/workspace/agentic-framework; MAC_REPO=/home/macuser/workspace/agentic-framework
T=$(mktemp -d); : > "$T/results"
ok()    { echo ok >> "$T/results"; printf 'ok   %s\n' "$1"; }
bad()   { echo FAIL >> "$T/results"; printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
has()   { case "$2" in *"$1"*) ok "$3";; *) bad "$3" "output lacks [$1]";; esac; }   # has <needle> <haystack> <name>
say()   { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
cleanup() {
  if [ "${KEEP:-0}" = 1 ]; then echo "KEEP=1: containers $BOX and $MAC left running on network $NET"; return; fi
  docker rm -f "$BOX" "$MAC" >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1; rm -rf "$T"
}
trap cleanup EXIT
box()  { docker exec -u "$LOGIN" -e "HOME=/home/$LOGIN" -w "$BOX_REPO" "$BOX" "$@"; }           # as the host login
root() { docker exec "$BOX" "$@"; }
mac()  { docker exec -u macuser -e HOME=/home/macuser -w "$MAC_REPO" "$MAC" "$@"; }
strip() { tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g'; }                                              # pty output -> plain
run() { RAW=$("$@" 2>&1); RC=$?; OUT=$(printf '%s\n' "$RAW" | strip); }                          # RC is the command's, not a filter's

say "images and containers"
command -v docker >/dev/null || { echo "docker is required" >&2; exit 2; }
docker rm -f "$BOX" "$MAC" >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1
docker build -q -f "$REPO/tests/e2e/Dockerfile.host" --build-arg "LOGIN=$LOGIN" --build-arg "PASSWORD=$PASSWORD" -t af-e2e-host "$REPO/tests/e2e" >/dev/null || { echo "host image build failed" >&2; exit 1; }
docker build -q -f "$REPO/tests/e2e/Dockerfile.mac" -t af-e2e-mac "$REPO/tests/e2e" >/dev/null || { echo "mac image build failed" >&2; exit 1; }
docker network create "$NET" >/dev/null
docker run -d --name "$BOX" --hostname "$ALIAS" --network "$NET" --network-alias "$ALIAS" af-e2e-host >/dev/null
docker run -d --name "$MAC" --hostname mac --network "$NET" af-e2e-mac >/dev/null
BOX_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$BOX")
SUBNET=$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$NET")
echo "    $ALIAS is $BOX_IP in $SUBNET"
# The working tree, not a commit, so uncommitted changes are what gets tested. No .git, no .env.
root install -d -o "$LOGIN" -g "$LOGIN" "$BOX_REPO" "/home/$LOGIN/workspace"
tar -C "$REPO" --exclude=.git --exclude=.env -cf - . | docker exec -i -u "$LOGIN" "$BOX" tar -C "$BOX_REPO" -xf -
docker exec -u macuser "$MAC" install -d "$MAC_REPO"
tar -C "$REPO" --exclude=.git --exclude=.env -cf - . | docker exec -i -u macuser "$MAC" tar -C "$MAC_REPO" -xf -
for _ in $(seq 1 30); do mac ssh-keyscan -T 2 "$ALIAS" 2>/dev/null | grep -q ssh-ed25519 && break; sleep 1; done
mac ssh-keyscan -T 2 "$ALIAS" 2>/dev/null | grep -q ssh-ed25519 && ok "sshd on $ALIAS answers" || { bad "sshd on $ALIAS answers"; exit 1; }

say "host: ./install-host.sh --no-tools (first run, phase 1 through sudo)"
run box ./install-host.sh --no-tools; out=$OUT
check "host: exit 0" 0 "$RC"
has "Parameters: host $ALIAS ($ALIAS), login $LOGIN, LAN $BOX_IP" "$out" "host: derived alias, address, login and LAN address"
has "wrote .env" "$out" "host: wrote .env on the first run"
check "host: .env content" "AGENT_HOST=$ALIAS AGENT_HOST_ADDRESS=$ALIAS AGENT_HOST_USER=$LOGIN AGENT_HOST_LAN_IP=$BOX_IP" \
  "$(box grep -v '^#' .env | tr '\n' ' ' | sed 's/ $//')"
root test -e /etc/ssh/sshd_config.d/10-hardening.conf && bad "host: sshd left as installed" "a drop-in was written" || ok "host: sshd left as installed (no drop-in)"
log=$(root cat /var/log/e2e-shims.log)
case "$log" in *"systemctl reload ssh"*|*ufw*) bad "host: no sshd reload, no ufw" "$log";; *) ok "host: no sshd reload, no ufw";; esac
has "loginctl enable-linger $LOGIN" "$log" "host: linger for the login"
check "host: login shell is zsh" /usr/bin/zsh "$(root getent passwd "$LOGIN" | cut -d: -f7)"
check "host: ~/.zshrc links into the repo" "$BOX_REPO/config/zshrc" "$(box readlink "/home/$LOGIN/.zshrc")"
check "host: secrets file mode" 600 "$(box stat -c %a "/home/$LOGIN/.config/agents/env")"
check "host: xclip shim linked" "$BOX_REPO/bin/xclip" "$(box readlink "/home/$LOGIN/.local/bin/xclip")"
has "Parameters for the Macs" "$out" "host: prints the .env block for the Macs"
has "tailscale not installed" "$out" "host: tailscale absence is a note, not a failure"

say "host: unit tests inside the container"
run box bash tests/params-test.sh; tail=$(printf '%s\n' "$OUT" | tail -1)
[ "$RC" = 0 ] && ok "host: tests/params-test.sh ($tail)" || bad "host: tests/params-test.sh ($tail)" "$(printf '%s\n' "$OUT" | grep -A1 '^FAIL')"

say "mac: .env, then ./install-mac.sh (first run, password path via SSH_ASKPASS)"
mac sh -c "printf 'AGENT_HOST=$ALIAS\nAGENT_HOST_ADDRESS=$ALIAS\nAGENT_HOST_USER=$LOGIN\nAGENT_HOST_LAN_IP=$BOX_IP\n' > .env"
run docker exec -t -u macuser -e HOME=/home/macuser -e SSH_ASKPASS=/usr/local/bin/askpass -e SSH_ASKPASS_REQUIRE=force \
         -e "E2E_PASSWORD=$PASSWORD" -w "$MAC_REPO" "$MAC" ./install-mac.sh; mout=$OUT
check "mac: exit 0" 0 "$RC"
has "Parameters: \`ssh $ALIAS\` is $LOGIN@$ALIAS, \`ssh $ALIAS-lan\` is $LOGIN@$BOX_IP" "$mout" "mac: parameters read from .env"
has "storing $ALIAS's host key" "$mout" "mac: host key stored on first contact"
has "Enter $LOGIN's password on $ALIAS" "$mout" "mac: took the password path"
has "ok   ssh $ALIAS logs in by key" "$mout" "mac: key login established"
has "created ~/.config/wezterm/wezterm.lua (minimal, includes wezterm-agent-host)" "$mout" "mac: minimal wezterm.lua created"
has "installed ~/.local/bin/clip-push (pushes to $ALIAS-clip)" "$mout" "mac: clip-push installed"
g() { mac ssh -G "$1" 2>/dev/null | awk -v k="$2" '$1==k {print $2}'; }
check "mac: ssh -G $ALIAS hostname" "$ALIAS" "$(g "$ALIAS" hostname)"
check "mac: ssh -G $ALIAS user" "$LOGIN" "$(g "$ALIAS" user)"
check "mac: ssh -G $ALIAS-lan hostname" "$BOX_IP" "$(g "$ALIAS-lan" hostname)"
check "mac: ssh -G $ALIAS-clip batchmode" yes "$(g "$ALIAS-clip" batchmode)"
check "mac: one agent-host block in ~/.ssh/config" 1 "$(mac grep -c 'agentic-framework:agent-host >>>' /home/macuser/.ssh/config)"
check "mac: wezterm module rendered" "local HOST = \"$ALIAS\"" "$(mac grep '^local HOST' /home/macuser/.config/wezterm/wezterm-agent-host.lua)"
check "mac: ssh $ALIAS true without a prompt" ok "$(mac ssh -o BatchMode=yes "$ALIAS" echo ok 2>/dev/null)"
# The LAN address has its own host key entry; first use accepts it, as on a real LAN.
check "mac: ssh $ALIAS-lan true (host key accepted on first use)" ok "$(mac ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$ALIAS-lan" echo ok 2>/dev/null)"
check "mac: ssh $ALIAS-clip true without a prompt" ok "$(mac ssh "$ALIAS-clip" echo ok 2>/dev/null)"
check "mac: non-interactive ssh does not land in tmux" "tmux=" "$(mac ssh -o BatchMode=yes "$ALIAS" 'echo tmux=$TMUX' 2>/dev/null)"
check "mac: remote shell is zsh with ~/.local/bin on PATH (zshenv)" "/home/$LOGIN/.local/bin/xclip" "$(mac ssh -o BatchMode=yes "$ALIAS" 'command -v xclip' 2>/dev/null)"
mac ssh -o BatchMode=yes "root@$ALIAS" true 2>/dev/null && bad "mac: root login refused" || ok "mac: root login refused"

say "mac: clipboard bridge"
mac sh -c "printf plain > /tmp/clipboard.txt; echo text > /tmp/clipboard.kind"
check "clip: text is reported" text/plain "$(mac /home/macuser/.local/bin/clip-push 2>&1)"
check "clip: text reached the spool" plain "$(box cat "/home/$LOGIN/.clip/latest")"
check "clip: xclip -o over ssh serves it" plain "$(mac ssh -o BatchMode=yes "$ALIAS" 'xclip -selection clipboard -o' 2>/dev/null)"
check "clip: --if-image with text pushes nothing" text/plain "$(mac sh -c 'printf other > /tmp/clipboard.txt; /home/macuser/.local/bin/clip-push --if-image' 2>&1)"
check "clip: spool unchanged by --if-image text" plain "$(box cat "/home/$LOGIN/.clip/latest")"
mac sh -c "echo iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg== | base64 -d > /tmp/clipboard.png; echo png > /tmp/clipboard.kind"
pushed=$(mac /home/macuser/.local/bin/clip-push --if-image 2>&1 | tr -d '\r')
check "clip: image is reported" image/png "$(printf '%s\n' "$pushed" | sed -n 1p)"
PNG1=$(printf '%s\n' "$pushed" | sed -n 2p)
case "$PNG1" in /home/$LOGIN/.clip/????????T??????Z-??????.png) ok "clip: the push prints the image's own path ($(basename "$PNG1"))";; *) bad "clip: the push prints the image's own path" "[$PNG1]";; esac
has "PNG image data, 1 x 1" "$(box file "$PNG1")" "clip: that file holds the PNG"
check "clip: latest points at it, so the xclip shim still serves the newest image" "$PNG1" "$(box readlink "/home/$LOGIN/.clip/latest")"
check "clip: xclip TARGETS over ssh" image/png "$(mac ssh -o BatchMode=yes "$ALIAS" 'xclip -selection clipboard -t TARGETS -o' 2>/dev/null)"
check "clip: image file mode 600" 600 "$(box stat -c %a "$PNG1")"
check "clip: directory mode 700" 700 "$(box stat -c %a "/home/$LOGIN/.clip")"
PNG2=$(mac /home/macuser/.local/bin/clip-push --if-image 2>&1 | tr -d '\r' | sed -n 2p)
[ -n "$PNG2" ] && [ "$PNG2" != "$PNG1" ] && ok "clip: a second push gets its own file, the first is untouched" || bad "clip: a second push gets its own file" "[$PNG1] [$PNG2]"
check "clip: both files present" 2 "$(box sh -c "ls /home/$LOGIN/.clip/*.png | wc -l")"
box touch -d '25 hours ago' "$PNG1"
mac /home/macuser/.local/bin/clip-push --if-image >/dev/null 2>&1
box test -e "$PNG1" && bad "clip: a push prunes images older than 24 h" "$(basename "$PNG1") still there" || ok "clip: a push prunes images older than 24 h"
box test -e "$PNG2" && ok "clip: and keeps the younger ones" || bad "clip: and keeps the younger ones" "$(basename "$PNG2") gone"
mac /home/macuser/.local/bin/clip-push --clear >/dev/null 2>&1
check "clip: --clear empties the spool dir" "" "$(box ls -A "/home/$LOGIN/.clip")"

say "mac: Cmd+V as WezTerm runs it (rendered module under Lua 5.4, real clip-push, real host)"
# wez <scenario> [proc]: run the module's Cmd+V handler in the mac container; PUSH_HOST reaches clip-push as CLIP_PUSH_HOST.
wez() { docker exec -u macuser -e HOME=/home/macuser -e "CLIP_PUSH_HOST=${PUSH_HOST:-}" -w "$MAC_REPO" "$MAC" lua5.4 tests/e2e/wezterm-paste.lua "$@" 2>&1; }
spool() { box cat "/home/$LOGIN/.clip/latest" 2>/dev/null; }
preset() { mac sh -c "printf before | ssh $ALIAS-clip '~/.local/bin/clip-put'"; }        # a known spool, so "unchanged" is provable
apply=$(wez apply)
has "domain $ALIAS $ALIAS $LOGIN None" "$apply" "wez: ssh domain named after the alias, login from .env, no multiplexing"
has "key CMD|SHIFT a SpawnCommandInNewTab $ALIAS" "$apply" "wez: Cmd+Shift+A opens a tab in the host domain"
has "key CMD v callback" "$apply" "wez: Cmd+V is the routing callback"
has "term xterm-256color" "$apply" "wez: term set for the host's terminfo"
has "scheme Preset" "$apply" "wez: a colour scheme set before the include is kept"
mac sh -c "printf typed-text > /tmp/clipboard.txt; echo text > /tmp/clipboard.kind"; preset
check "wez: text into a local pane -> plain paste" "action PasteFrom Clipboard" "$(wez local zsh)"
check "wez: text into the host domain -> plain paste, nothing pushed" "action PasteFrom Clipboard" "$(wez domain)"
check "wez: spool untouched by text pastes" before "$(spool)"
mac sh -c "echo png > /tmp/clipboard.kind"
check "wez: image into a local pane -> plain paste (never pushed)" "action PasteFrom Clipboard" "$(wez local zsh)"
check "wez: spool untouched by a local image paste" before "$(spool)"
png_sha=$(mac sha256sum /tmp/clipboard.png | cut -c1-64)
# pasted <scenario...>: run Cmd+V with an image on the Mac clipboard; the one line WezTerm would act on is
# "paste <path>", and the path must be a .png on the host holding the pushed bytes.
pasted() { local name=$1; shift; local out path
  out=$(wez "$@"); path=${out#paste }
  case "$out" in "paste /home/$LOGIN/.clip/"*.png) ok "wez: $name -> push, then paste the host path";; *) bad "wez: $name -> push, then paste the host path" "$out"; return;; esac
  check "wez: $name: the pasted path holds the PNG byte for byte" "$png_sha" "$(box sha256sum "$path" | cut -c1-64)"
  case "$path" in *" "*) bad "wez: $name: path has no spaces" "$path";; *) ok "wez: $name: path has no spaces (one paste, one path in every harness)";; esac
}
pasted "image into the host domain" domain
# Ctrl+V in Claude Code still works while the shim is there: latest follows the newest image.
check "claude: xclip TARGETS after the push" image/png "$(mac ssh -o BatchMode=yes "$ALIAS" 'xclip -selection clipboard -t TARGETS -o' 2>/dev/null)"
check "claude: xclip image/png returns the same bytes" "$png_sha" "$(mac ssh -o BatchMode=yes "$ALIAS" 'xclip -selection clipboard -t image/png -o | sha256sum' 2>/dev/null | cut -c1-64)"
mac ssh -o BatchMode=yes "$ALIAS" 'xclip -selection clipboard -t text/plain -o' >/dev/null 2>&1 && bad "claude: text request on a PNG spool exits 1" || ok "claude: text request on a PNG spool exits 1"
preset; pasted "local pane running ssh" local ssh
preset; pasted "local pane running mosh-client" local mosh-client
preset; out=$(PUSH_HOST=nowhere-clip wez domain)
has "toast $ALIAS clipboard: clip-push failed" "$out" "wez: push failure -> toast"
case "$out" in *action*|*paste*) bad "wez: push failure pastes nothing (no stale path)" "$out";; *) ok "wez: push failure pastes nothing (no stale path)";; esac
check "wez: spool untouched by the failed push" before "$(spool)"

say "host -> mac: copy inside the host reaches the Mac clipboard as OSC 52"
# xclip with stdin is what Claude Code and tmux run on copy; with a pty the shim emits OSC 52, which WezTerm turns into
# a Mac clipboard write. Over ssh -tt the escape sequence comes back in the pty stream.
osc=$(mac ssh -tt -o BatchMode=yes "$ALIAS" 'printf hello-osc52 | xclip -selection clipboard' 2>/dev/null | od -An -c | tr -d ' \n')
case "$osc" in *"033]52;c;$(printf hello-osc52 | base64)"*) ok "copy: xclip stdin -> OSC 52 with the base64 payload";; *) bad "copy: OSC 52" "$osc";; esac
check "copy: the copy is also spooled on the host" hello-osc52 "$(spool)"
osc2=$(mac ssh -o BatchMode=yes "$ALIAS" 'printf quiet | xclip -selection clipboard' 2>&1)
check "copy: no pty -> no escape sequence, exit 0" "" "$osc2"

say "second mac: macuser2, same .env, own key, against the same host"
MAC2_REPO=/home/macuser2/workspace/agentic-framework
mac2() { docker exec -u macuser2 -e HOME=/home/macuser2 -w "$MAC2_REPO" "$MAC" "$@"; }
docker exec -u macuser2 "$MAC" install -d "$MAC2_REPO"
tar -C "$REPO" --exclude=.git --exclude=.env -cf - . | docker exec -i -u macuser2 "$MAC" tar -C "$MAC2_REPO" -xf -
mac sh -c "cat .env" | docker exec -i -u macuser2 "$MAC" sh -c "cat > $MAC2_REPO/.env"                 # the lines the host printed
run docker exec -t -u macuser2 -e HOME=/home/macuser2 -e SSH_ASKPASS=/usr/local/bin/askpass -e SSH_ASKPASS_REQUIRE=force \
         -e "E2E_PASSWORD=$PASSWORD" -w "$MAC2_REPO" "$MAC" ./install-mac.sh; m2out=$OUT
check "mac2: exit 0" 0 "$RC"
has "Enter $LOGIN's password on $ALIAS" "$m2out" "mac2: took the password path for its own key"
has "ok   ssh $ALIAS logs in by key" "$m2out" "mac2: key login established"
check "host: two Mac keys trusted, nothing else changed per Mac" 2 "$(box grep -c . "/home/$LOGIN/.ssh/authorized_keys")"
check "mac2: ssh $ALIAS true without a prompt" ok "$(mac2 ssh -o BatchMode=yes "$ALIAS" echo ok 2>/dev/null)"
check "mac1: still logs in" ok "$(mac ssh -o BatchMode=yes "$ALIAS" echo ok 2>/dev/null)"
mac sh -c "printf from-mac2 > /tmp/clipboard.txt; echo text > /tmp/clipboard.kind"
check "mac2: pushes text" text/plain "$(mac2 /home/macuser2/.local/bin/clip-push 2>&1)"
check "host: last pusher wins, mac1 reads mac2's paste" from-mac2 "$(mac ssh -o BatchMode=yes "$ALIAS" 'xclip -selection clipboard -o' 2>/dev/null)"
mac sh -c "echo png > /tmp/clipboard.kind"
check "mac1: pushes an image over it" image/png "$(mac /home/macuser/.local/bin/clip-push --if-image 2>&1 | head -1)"
check "host: mac2 now sees the image" image/png "$(mac2 ssh -o BatchMode=yes "$ALIAS" 'xclip -selection clipboard -t TARGETS -o' 2>/dev/null)"
mac2 /home/macuser2/.local/bin/clip-push --clear >/dev/null 2>&1
check "mac2: --clear empties the spool for everyone" "" "$(box ls -A "/home/$LOGIN/.clip")"

say "sessions: the picker, and two devices on one harness session"
# Two Mac users are the two devices; each gets its own view of one base session, which is the whole point
# of the grouped-session design. The picker runs non-interactively through AGENT_PICK_FILTER, so the ssh
# commands need a pty (for tmux to attach to) but no human.
AGENTBIN=/home/$LOGIN/.local/bin/agent
bagent() { box "$AGENTBIN" "$@"; }
btmux()  { box tmux "$@"; }
# until_box <seconds> <shell test>: poll inside the box, because attaching happens in another container
until_box() { local n=$1 i=0; shift; while [ "$i" -lt $((n * 5)) ]; do box sh -c "$1" >/dev/null 2>&1 && return 0; sleep 0.2; i=$((i + 1)); done; return 1; }
MAC_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$MAC")

check "box: agent is linked into the repo" "$BOX_REPO/bin/agent" "$(box readlink "$AGENTBIN")"
check "box: fzf is installed" 0 "$(box sh -c 'command -v fzf >/dev/null; echo $?')"
check "box: no sessions before any are made" "" "$(bagent ls --porcelain)"
check "mac: non-interactive ssh still bypasses tmux and can call agent" "tmux= 0" \
  "$(mac ssh -o BatchMode=yes "$ALIAS" 'echo tmux=$TMUX; agent ls --porcelain | wc -l' 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"

# device 1 logs in and makes a shell session through the picker
timeout 180 docker exec -t -u macuser -e HOME=/home/macuser "$MAC" \
  ssh -tt -o BatchMode=yes "$ALIAS" 'AGENT_PICK_FILTER="new shell" agent pick' >"$T/mac1.ssh" 2>&1 &
MAC1=$!
if until_box 20 "tmux list-sessions -F '#{session_name}' | grep -qx 'scratch@1'"; then
  ok "mac1: the picker made a shell session and attached a view to it"
else
  bad "mac1: the picker made a shell session and attached a view to it" "$(bagent ls --porcelain; tr -d '\r' < "$T/mac1.ssh" | tail -3)"
fi
SESSION=scratch
check "box: one base session, listed as a shell" "$SESSION	shell	-	-" "$(bagent ls --porcelain | cut -f1-4)"
check "box: the view carries the Mac's address" "$MAC_IP" "$(bagent ls --porcelain | cut -f8)"
check "box: the base itself is not attached" 0 "$(btmux display-message -p -t "$SESSION" '#{session_attached}')"

# device 2 picks the same session: a second view, same windows, its own current window
timeout 180 docker exec -t -u macuser2 -e HOME=/home/macuser2 "$MAC" \
  ssh -tt -o BatchMode=yes "$ALIAS" "AGENT_PICK_FILTER=$SESSION agent pick" >"$T/mac2.ssh" 2>&1 &
MAC2=$!
if until_box 20 "tmux list-sessions -F '#{session_name}' | grep -qx '$SESSION@2'"; then
  ok "mac2: picking the same session gives it a second view"
else
  bad "mac2: picking the same session gives it a second view" "$(btmux list-sessions -F '#{session_name}'; tr -d '\r' < "$T/mac2.ssh" | tail -3)"
fi
check "box: base and two views are one group" 3 "$(btmux display-message -p -t "$SESSION" '#{session_group_size}')"
check "box: view 1 has its own client" 1 "$(btmux display-message -p -t "$SESSION@1" '#{session_attached}')"
check "box: view 2 has its own client" 1 "$(btmux display-message -p -t "$SESSION@2" '#{session_attached}')"
check "box: both devices are listed against the one base" 2 "$(bagent ls --porcelain | cut -f8 | tr ',' '\n' | grep -c "$MAC_IP")"
check "box: still one base session in ls" 1 "$(bagent ls --porcelain | wc -l)"
# Independent views: a window switch on one device must not move the other. Window indexes are whatever
# base-index says, so take them from tmux rather than assuming.
WIN_BEFORE=$(btmux display-message -p -t "$SESSION@2" '#{window_index}')
WIN_NEW=$(btmux new-window -t "$SESSION" -P -F '#{window_index}')
btmux select-window -t "$SESSION@1:$WIN_NEW"
check "box: view 1 moved to the new window" "$WIN_NEW" "$(btmux display-message -p -t "$SESSION@1" '#{window_index}')"
check "box: view 2 did not move with it" "$WIN_BEFORE" "$(btmux display-message -p -t "$SESSION@2" '#{window_index}')"

btmux detach-client -s "$SESSION@1"
until_box 20 "! tmux has-session -t '$SESSION@1' 2>/dev/null" \
  && ok "box: detaching device 1 destroys only its view" || bad "box: detaching device 1 destroys only its view" "$(btmux list-sessions -F '#{session_name}')"
check "box: the base survives the detach" 0 "$(btmux has-session -t "$SESSION" >/dev/null 2>&1; echo $?)"
check "box: view 2 survives the detach" 1 "$(btmux display-message -p -t "$SESSION@2" '#{session_attached}')"
wait "$MAC1"; check "mac1: the ssh session ended cleanly on detach" 0 "$?"

bagent kill "$SESSION" >/dev/null
check "box: kill removes the base and the remaining view" "" "$(btmux list-sessions -F '#{session_name}' 2>/dev/null | grep "$SESSION" || true)"
# A client whose session is killed under it does not exit 0; what matters is that it ends rather than hangs.
wait "$MAC2" 2>/dev/null; rc2=$?
[ "$rc2" -lt 124 ] && ok "mac2: its ssh session ended when the session was killed" \
  || bad "mac2: its ssh session ended when the session was killed" "exit $rc2, probably a timeout"
check "box: ls is empty again" "" "$(bagent ls --porcelain)"

say "sessions: log out from the prefix-g popup closes the connection"
# The one thing only a real login can show: the popup runs in the tmux server's process tree, so choosing
# "log out" there has to reach the ssh login shell sitting in its own picker. Everything here is real —
# ssh with a pty, a real display-popup on that client — apart from the two AGENT_PICK_FILTERs standing in
# for the keystrokes.
timeout 180 docker exec -t -u macuser -e HOME=/home/macuser "$MAC" \
  ssh -tt -o BatchMode=yes "$ALIAS" 'AGENT_PICK_FILTER="new shell" agent pick; echo picker-rc=$?' >"$T/mac3.ssh" 2>&1 &
MAC3=$!
if until_box 20 "tmux list-sessions -F '#{session_name}' | grep -qx 'scratch@1'"; then
  CLIENT=$(btmux list-clients -t 'scratch@1' -F '#{client_tty}' | head -1)
  box tmux display-popup -E -c "$CLIENT" "AGENT_PICK_FILTER='log out' $AGENTBIN pick --switch" >/dev/null 2>&1 || true
  wait "$MAC3" 2>/dev/null; rc3=$?
  [ "$rc3" -lt 124 ] && ok "mac: log out in the popup ends the ssh session" \
    || bad "mac: log out in the popup ends the ssh session" "exit $rc3, probably a timeout"
  has "picker-rc=3" "$(tr -d '\r' < "$T/mac3.ssh" | tail -5)" "mac: the login picker exited 3, which is what the landing fragment logs out on"
  until_box 20 "! tmux has-session -t 'scratch@1' 2>/dev/null" \
    && ok "box: the view went with the detached client" || bad "box: the view went with the detached client" "$(btmux list-sessions -F '#{session_name}')"
  check "box: the session it was attached to is still there" 0 "$(btmux has-session -t scratch >/dev/null 2>&1; echo $?)"
else
  bad "mac: log out in the popup ends the ssh session" "no view to log out of: $(bagent ls --porcelain; tr -d '\r' < "$T/mac3.ssh" | tail -3)"
  kill "$MAC3" 2>/dev/null || true
fi
bagent kill scratch >/dev/null 2>&1 || true

say "sessions: agent new runs a harness in the repo and keeps its last screen"
# A stand-in "claude" on the box PATH: it records where it started, then becomes a process tmux can name.
# It is a copy of /bin/sh rather than a link to sleep, because coreutils is one multi-call binary that
# refuses to run under another argv[0].
docker exec -i -u "$LOGIN" -e "HOME=/home/$LOGIN" "$BOX" sh -s <<'STUB'
set -e
cp "$(readlink -f /bin/sh)" "$HOME/.local/bin/claude-proc"
cat > "$HOME/.local/bin/claude" <<'EOS'
#!/bin/sh
pwd > "$HOME/stub.cwd"
exec claude-proc -c 'read line'
EOS
chmod +x "$HOME/.local/bin/claude"
mkdir -p "$HOME/workspace/standin"
git -C "$HOME/workspace/standin" init -q -b main
git -C "$HOME/workspace/standin" -c user.email=t@example -c user.name=t commit -q --allow-empty -m init
STUB
check "box: agent new --no-attach prints the session name" standin "$(bagent new standin --harness claude --no-attach)"
until_box 20 "test -f /home/$LOGIN/stub.cwd"
check "box: the harness started in the repo" "/home/$LOGIN/workspace/standin" "$(box cat "/home/$LOGIN/stub.cwd")"
check "box: ls says running, with the repo as cwd" "standin	claude	standin	main	/home/$LOGIN/workspace/standin	running" \
  "$(bagent ls --porcelain | cut -f1-6)"
check "box: nothing is attached to it" "-" "$(bagent ls --porcelain | cut -f8)"
box sh -c "kill \$(tmux display-message -p -t standin '#{pane_pid}')"
until_box 20 "tmux display-message -p -t standin '#{pane_dead}' | grep -qx 1" \
  && ok "box: the dead harness leaves its pane behind" || bad "box: the dead harness leaves its pane behind"
check "box: ls says exited" exited "$(bagent ls --porcelain | cut -f6)"
check "box: the last screen is still readable" 1 "$(box sh -c 'tmux capture-pane -p -t standin | grep -c .' || true)"
bagent kill standin >/dev/null
check "box: kill clears the exited session" "" "$(bagent ls --porcelain)"

say "second runs: idempotency"
run docker exec -t -u macuser -e HOME=/home/macuser -w "$MAC_REPO" "$MAC" ./install-mac.sh; mout2=$OUT
check "mac: second run exit 0" 0 "$RC"
has "ok   ssh $ALIAS logs in by key" "$mout2" "mac: second run finds key login"
has "wezterm.lua includes wezterm-agent-host" "$mout2" "mac: second run finds the include"
check "mac: still one agent-host block" 1 "$(mac grep -c 'agentic-framework:agent-host >>>' /home/macuser/.ssh/config)"
before=$(root sh -c 'wc -l < /var/log/e2e-shims.log')
run box ./install-host.sh --no-tools; out2=$OUT
check "host: second run exit 0" 0 "$RC"
has "ok   .env" "$out2" "host: second run keeps .env"
has "ok   Linger=yes" "$out2" "host: second run leaves linger alone"
has "ok   /usr/bin/zsh" "$out2" "host: second run leaves the shell alone"
after=$(root sh -c 'wc -l < /var/log/e2e-shims.log')
root sed -n "$((before + 1)),\$p" /var/log/e2e-shims.log | grep -qE 'reload|enable-linger' && bad "host: second run made no root changes" "$(root sed -n "$((before + 1)),\$p" /var/log/e2e-shims.log)" || ok "host: second run made no root changes ($((after - before)) read-only shim calls)"
# .env from a Mac with a different login must be refused on the host, before anything runs.
box sh -c "sed -i 's/^AGENT_HOST_USER=.*/AGENT_HOST_USER=someone/' .env"
run box ./install-host.sh --no-tools --no-root
check "host: .env with another login -> exit 1" 1 "$RC"; has "but this script runs as $LOGIN" "$OUT" "host: says why"
box sh -c "sed -i 's/^AGENT_HOST_USER=.*/AGENT_HOST_USER=$LOGIN/' .env"

pass=$(grep -c '^ok$' "$T/results"); fail=$(grep -c '^FAIL$' "$T/results")
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
