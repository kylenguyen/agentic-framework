#!/usr/bin/env bash
# tests/e2e/run.sh: two Docker containers on a private network, "box" (the host, real sshd, install-host.sh as alice
# with sudo) and "mac" (install-mac.sh as macuser, brew/osascript/pbpaste/pngpaste stubbed). The Mac script runs
# first through the password path (SSH_ASKPASS answers for the human), then once more for idempotency; the host
# script runs twice as well. Values are deliberately not the live ones (alias box, login alice), so a literal that
# slipped past tests/params-test.sh fails here. What a container cannot do (systemd, tailscale) is shimmed
# and logged; see tests/e2e/shims. The clipboard bridge is driven the way WezTerm drives it: the rendered module runs
# under Lua 5.4 (tests/e2e/wezterm-paste.lua) and its Cmd+V decision calls the real clip-push, which pushes over ssh
# to the real host; the shell then makes the xclip calls Claude Code makes after Ctrl+V and compares bytes. A second
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
check "clip: image is reported and pushed" image/png "$(mac /home/macuser/.local/bin/clip-push --if-image 2>&1)"
has "PNG image data, 1 x 1" "$(box file "/home/$LOGIN/.clip/latest")" "clip: spool holds the PNG"
check "clip: xclip TARGETS over ssh" image/png "$(mac ssh -o BatchMode=yes "$ALIAS" 'xclip -selection clipboard -t TARGETS -o' 2>/dev/null)"
check "clip: spool mode 600" 600 "$(box stat -c %a "/home/$LOGIN/.clip/latest")"
mac /home/macuser/.local/bin/clip-push --clear >/dev/null 2>&1
check "clip: --clear empties the spool dir" "" "$(box ls "/home/$LOGIN/.clip")"

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
check "wez: image into the host domain -> push, then Ctrl+V" "action SendKey CTRL v" "$(wez domain)"
png_sha=$(mac sha256sum /tmp/clipboard.png | cut -c1-64)
check "wez: the PNG landed in the spool byte for byte" "$png_sha" "$(box sha256sum "/home/$LOGIN/.clip/latest" | cut -c1-64)"
# What Claude Code does when it receives that Ctrl+V: ask xclip for TARGETS, then for the PNG.
check "claude: xclip TARGETS after Ctrl+V" image/png "$(mac ssh -o BatchMode=yes "$ALIAS" 'xclip -selection clipboard -t TARGETS -o' 2>/dev/null)"
check "claude: xclip image/png returns the same bytes" "$png_sha" "$(mac ssh -o BatchMode=yes "$ALIAS" 'xclip -selection clipboard -t image/png -o | sha256sum' 2>/dev/null | cut -c1-64)"
mac ssh -o BatchMode=yes "$ALIAS" 'xclip -selection clipboard -t text/plain -o' >/dev/null 2>&1 && bad "claude: text request on a PNG spool exits 1" || ok "claude: text request on a PNG spool exits 1"
preset; check "wez: local pane running ssh -> push, then Ctrl+V" "action SendKey CTRL v" "$(wez local ssh)"
check "wez: spool holds the PNG after the ssh-pane push" "$png_sha" "$(box sha256sum "/home/$LOGIN/.clip/latest" | cut -c1-64)"
preset; check "wez: local pane running mosh-client -> push, then Ctrl+V" "action SendKey CTRL v" "$(wez local mosh-client)"
check "wez: spool holds the PNG after the mosh-pane push" "$png_sha" "$(box sha256sum "/home/$LOGIN/.clip/latest" | cut -c1-64)"
preset; out=$(PUSH_HOST=nowhere-clip wez domain)
has "toast $ALIAS clipboard: clip-push failed" "$out" "wez: push failure -> toast"
case "$out" in *action*) bad "wez: push failure sends no key (no stale paste)" "$out";; *) ok "wez: push failure sends no key (no stale paste)";; esac
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
check "mac1: pushes an image over it" image/png "$(mac /home/macuser/.local/bin/clip-push --if-image 2>&1)"
check "host: mac2 now sees the image" image/png "$(mac2 ssh -o BatchMode=yes "$ALIAS" 'xclip -selection clipboard -t TARGETS -o' 2>/dev/null)"
mac2 /home/macuser2/.local/bin/clip-push --clear >/dev/null 2>&1
check "mac2: --clear empties the spool for everyone" "" "$(box ls "/home/$LOGIN/.clip")"

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
