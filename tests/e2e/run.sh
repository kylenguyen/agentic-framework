#!/usr/bin/env bash
# tests/e2e/run.sh: two Docker containers on a private network, "box" (the host, real sshd, install-as1.sh as alice
# with sudo) and "mac" (install-mac.sh as macuser, brew/osascript/pbpaste/pngpaste stubbed). The Mac script runs
# first through the password path (SSH_ASKPASS answers for the human), then once more for idempotency; the host
# script runs twice as well. Values are deliberately not the live ones (alias box, login alice), so a literal that
# slipped past tests/params-test.sh fails here. What a container cannot do (systemd, ufw, tailscale) is shimmed
# and logged; see tests/e2e/shims. Needs docker without sudo; network only for the image builds. KEEP=1 leaves the
# containers running for a look around. Exit 0 when every check passes.
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

say "host: ./install-as1.sh --no-tools (first run, phase 1 through sudo)"
run box ./install-as1.sh --no-tools; out=$OUT
check "host: exit 0" 0 "$RC"
has "Parameters: host $ALIAS ($ALIAS), login $LOGIN, LAN $BOX_IP in $SUBNET" "$out" "host: derived alias, address, login, LAN address and range"
has "wrote .env" "$out" "host: wrote .env on the first run"
check "host: .env content" "AGENT_HOST=$ALIAS AGENT_HOST_ADDRESS=$ALIAS AGENT_HOST_USER=$LOGIN AGENT_HOST_LAN_IP=$BOX_IP AGENT_HOST_LAN_CIDR=$SUBNET" \
  "$(box grep -v '^#' .env | tr '\n' ' ' | sed 's/ $//')"
check "host: sshd drop-in allows the login" "AllowUsers $LOGIN" "$(root grep '^AllowUsers' /etc/ssh/sshd_config.d/10-hardening.conf)"
root grep -q '@' /etc/ssh/sshd_config.d/10-hardening.conf && bad "host: no placeholder in the installed drop-in" || ok "host: no placeholder in the installed drop-in"
check "host: sshd -T allowusers" "allowusers $LOGIN" "$(root sshd -T 2>/dev/null | grep '^allowusers')"
check "host: sshd -T passwordauthentication" "passwordauthentication yes" "$(root sshd -T 2>/dev/null | grep '^passwordauthentication')"
check "host: sshd -T permitrootlogin" "permitrootlogin no" "$(root sshd -T 2>/dev/null | grep '^permitrootlogin')"
log=$(root cat /var/log/e2e-shims.log)
has "systemctl reload ssh" "$log" "host: sshd reloaded after install"
has "ufw allow from $SUBNET to any port 22 proto tcp comment LAN ssh fallback" "$log" "host: ufw LAN rule carries the derived range"
has "ufw allow in on tailscale0" "$log" "host: ufw tailnet rule"
has "ufw --force enable" "$log" "host: ufw enabled"
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

say "second runs: idempotency"
run docker exec -t -u macuser -e HOME=/home/macuser -w "$MAC_REPO" "$MAC" ./install-mac.sh; mout2=$OUT
check "mac: second run exit 0" 0 "$RC"
has "ok   ssh $ALIAS logs in by key" "$mout2" "mac: second run finds key login"
has "wezterm.lua includes wezterm-agent-host" "$mout2" "mac: second run finds the include"
check "mac: still one agent-host block" 1 "$(mac grep -c 'agentic-framework:agent-host >>>' /home/macuser/.ssh/config)"
before=$(root sh -c 'wc -l < /var/log/e2e-shims.log')
run box ./install-as1.sh --no-tools; out2=$OUT
check "host: second run exit 0" 0 "$RC"
has "ok   .env" "$out2" "host: second run keeps .env"
has "ok   /etc/ssh/sshd_config.d/10-hardening.conf" "$out2" "host: second run leaves sshd alone"
has "ok   ufw enabled" "$out2" "host: second run leaves ufw alone"
has "ok   Linger=yes" "$out2" "host: second run leaves linger alone"
has "ok   /usr/bin/zsh" "$out2" "host: second run leaves the shell alone"
after=$(root sh -c 'wc -l < /var/log/e2e-shims.log')
root sed -n "$((before + 1)),\$p" /var/log/e2e-shims.log | grep -qE 'reload|ufw|enable-linger' && bad "host: second run made no root changes" "$(root sed -n "$((before + 1)),\$p" /var/log/e2e-shims.log)" || ok "host: second run made no root changes ($((after - before)) read-only shim calls)"
# .env from a Mac with a different login must be refused on the host, before anything runs.
box sh -c "sed -i 's/^AGENT_HOST_USER=.*/AGENT_HOST_USER=someone/' .env"
run box ./install-as1.sh --no-tools --no-root
check "host: .env with another login -> exit 1" 1 "$RC"; has "but this script runs as $LOGIN" "$OUT" "host: says why"
box sh -c "sed -i 's/^AGENT_HOST_USER=.*/AGENT_HOST_USER=$LOGIN/' .env"

pass=$(grep -c '^ok$' "$T/results"); fail=$(grep -c '^FAIL$' "$T/results")
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
