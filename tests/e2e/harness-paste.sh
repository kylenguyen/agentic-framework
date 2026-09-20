#!/usr/bin/env bash
# tests/e2e/harness-paste.sh: the last step of the clipboard bridge. run.sh proves Cmd+V pushes the image and
# hands WezTerm a host path; this file pastes that path into Claude Code, Oh My Pi and OpenCode and checks each
# attaches it as an image. That shared behaviour is the only reason one key serves every harness, and nothing
# else in the suite notices when one of them loses it.
#
# Two containers on a private network: "box" (tests/e2e/Dockerfile.harness: the run.sh host image plus the
# three harnesses, versions pinned; login alice) and "mac" (the run.sh Mac image, as macuser). The Mac holds a
# tmux server whose one pane runs `ssh -tt box 'agent attach ...'`, standing in for the WezTerm pane. Pastes go
# in with `tmux paste-buffer -p`, which adds the bracketed-paste markers pane:paste sends, so the bytes cross
# ssh and the host tmux the way a real client delivers them; injecting the paste on the box would skip the
# step that has to work live. A command on the ssh line bypasses tmux-autoattach.sh, so the picker never draws.
#
# No real credentials: ANTHROPIC_API_KEY is a placeholder in a throwaway container, nothing is sent to
# Anthropic. It keeps the `sk-ant-` prefix because Claude Code 2.1.278 only offers its "use this API key?"
# dialog for a value shaped that way, and without that dialog it stops at a login menu no script can answer.
#
# The prompt and indicator strings are version-specific, so the run prints the three versions it saw next to
# its result. Run this when a harness is upgraded on the host, and move the pin in Dockerfile.harness once it
# passes.
# Needs docker without sudo; the first build pulls several hundred MB. KEEP=1 leaves the containers up.
# Usage: bash tests/e2e/harness-paste.sh
# A && ok || bad is the intended pattern here:
# shellcheck disable=SC2015,SC2016
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
NET=af-hp; BOX=af-hp-box; MAC=af-hp-mac
LOGIN=alice; PASSWORD=alice-pw; ALIAS=box
BOX_REPO=/home/$LOGIN/workspace/agentic-framework; MAC_REPO=/home/macuser/workspace/agentic-framework
T=$(mktemp -d); : > "$T/results"
ok()    { echo ok >> "$T/results"; printf 'ok   %s\n' "$1"; }
bad()   { echo FAIL >> "$T/results"; printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
say()   { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
cleanup() {
  if [ "${KEEP:-0}" = 1 ]; then echo "KEEP=1: containers $BOX and $MAC left on network $NET"; return; fi
  docker rm -f "$BOX" "$MAC" >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1; rm -rf "$T"
}
trap cleanup EXIT

box()    { docker exec -u "$LOGIN" -e "HOME=/home/$LOGIN" -w "$BOX_REPO" "$BOX" "$@"; }
root()   { docker exec "$BOX" "$@"; }
mac()    { docker exec -u macuser -e HOME=/home/macuser -w "$MAC_REPO" "$MAC" "$@"; }
bagent() { box "/home/$LOGIN/.local/bin/agent" "$@"; }
btmux()  { box tmux "$@"; }
bscreen(){ btmux capture-pane -p -t "$1" 2>/dev/null | tr -d '\r' | sed 's/[[:space:]]*$//'; }

# --- the client's terminal ----------------------------------------------------------------------------
# One tmux server on the Mac, one pane, one ssh client in it: the stand-in for a WezTerm pane connected to the
# host. `paste` delivers there and `screen` reads there, both across a real ssh connection.
ct()     { docker exec -u macuser -e HOME=/home/macuser "$MAC" tmux -L hp "$@"; }
keys()   { ct send-keys -t term "$@"; }
screen() { ct capture-pane -p -t term 2>/dev/null | tr -d '\r' | sed 's/[[:space:]]*$//'; }
dump()   { local all; all=$(screen | grep -v '^$'); printf '\n%s\n    ...\n%s' "$(printf '%s\n' "$all" | head -4)" "$(printf '%s\n' "$all" | tail -12)"; }
connect(){ ct kill-session -t term >/dev/null 2>&1
           ct new-session -d -x 120 -y 40 -s term \
              "ssh -tt -o BatchMode=yes -o StrictHostKeyChecking=accept-new $ALIAS 'agent attach $1'; echo SSH_DONE=\$?; sleep 3600"; }
# await <needle> [secs]: poll the Mac's screen until the text appears. Everything here is asynchronous, so
# nothing is asserted without waiting first.
await()  { local n=$1 s=${2:-20} i=0
           while [ "$i" -lt $((s * 4)) ]; do case "$(screen)" in *"$n"*) return 0;; esac; sleep 0.25; i=$((i + 1)); done; return 1; }
saw()    { if await "$1" "${3:-20}"; then ok "$2"; else bad "$2" "screen has no [$1]:$(dump)"; fi; }
# missing <needle> <name> [secs]: the text must be absent after the wait; something that did not happen has to
# be given time to happen first.
missing(){ if await "$1" "${3:-8}"; then bad "$2" "screen has [$1]:$(dump)"; else ok "$2"; fi; }
# paste <text>: one bracketed paste, as WezTerm's pane:paste delivers it. Without -p the harness sees
# keystrokes and runs its key handling, not the paste handler that turns a path into an attachment.
paste()  { ct set-buffer -- "$1"; ct paste-buffer -p -t term; }

say "images and containers"
command -v docker >/dev/null || { echo "docker is required" >&2; exit 2; }
docker rm -f "$BOX" "$MAC" >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1
docker build -q -f "$REPO/tests/e2e/Dockerfile.host" --build-arg "LOGIN=$LOGIN" --build-arg "PASSWORD=$PASSWORD" -t af-e2e-host "$REPO/tests/e2e" >/dev/null || { echo "host image build failed" >&2; exit 1; }
echo "    af-e2e-harness: the three harnesses, minutes and a few hundred MB on a cold cache"
docker build -q -f "$REPO/tests/e2e/Dockerfile.harness" --build-arg BASE=af-e2e-host --build-arg "LOGIN=$LOGIN" -t af-e2e-harness "$REPO/tests/e2e" >/dev/null || { echo "harness image build failed" >&2; exit 1; }
docker build -q -f "$REPO/tests/e2e/Dockerfile.mac" -t af-e2e-mac "$REPO/tests/e2e" >/dev/null || { echo "mac image build failed" >&2; exit 1; }
docker network create "$NET" >/dev/null
docker run -d --name "$BOX" --hostname "$ALIAS" --network "$NET" --network-alias "$ALIAS" af-e2e-harness >/dev/null
docker run -d --name "$MAC" --hostname mac --network "$NET" af-e2e-mac >/dev/null
BOX_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$BOX")
# The working tree, not a commit, so uncommitted changes are what gets tested. No .git, no .env.
root install -d -o "$LOGIN" -g "$LOGIN" "$BOX_REPO" "/home/$LOGIN/workspace"
tar -C "$REPO" --exclude=.git --exclude=.env -cf - . | docker exec -i -u "$LOGIN" "$BOX" tar -C "$BOX_REPO" -xf -
docker exec -u macuser "$MAC" install -d "$MAC_REPO"
tar -C "$REPO" --exclude=.git --exclude=.env -cf - . | docker exec -i -u macuser "$MAC" tar -C "$MAC_REPO" -xf -
for _ in $(seq 1 30); do mac ssh-keyscan -T 2 "$ALIAS" 2>/dev/null | grep -q ssh-ed25519 && break; sleep 1; done
mac ssh-keyscan -T 2 "$ALIAS" 2>/dev/null | grep -q ssh-ed25519 && ok "sshd on $ALIAS answers" || { bad "sshd on $ALIAS answers"; exit 1; }

say "host and client install"
box ./install-host.sh --no-tools >"$T/install-host.log" 2>&1
check "host: install-host.sh exit 0" 0 "$?"
mac sh -c "printf 'AGENT_HOST=$ALIAS\nAGENT_HOST_ADDRESS=$ALIAS\nAGENT_HOST_USER=$LOGIN\nAGENT_HOST_LAN_IP=$BOX_IP\n' > .env"
docker exec -t -u macuser -e HOME=/home/macuser -e SSH_ASKPASS=/usr/local/bin/askpass -e SSH_ASKPASS_REQUIRE=force \
       -e "E2E_PASSWORD=$PASSWORD" -w "$MAC_REPO" "$MAC" ./install-mac.sh >"$T/install-mac.log" 2>&1
check "mac: install-mac.sh exit 0" 0 "$?"

say "host: what the three harnesses need to reach a prompt with nobody logged in"
# ~/.config/agents/env is sourced by config/zshenv, so the harness `agent new` starts under zsh sees this;
# neither the tmux server's environment nor an export here would reach it.
box sh -c "printf 'ANTHROPIC_API_KEY=%s\n' 'sk-ant-e2e-placeholder-not-a-real-key' >> /home/$LOGIN/.config/agents/env"
# Oh My Pi's provider wizard is skipped by a config that says setup has already been done.
box sh -c "mkdir -p /home/$LOGIN/.omp/agent && printf 'setupVersion: 2\n' > /home/$LOGIN/.omp/agent/config.yml"
# OpenCode needs nothing: with no provider it goes straight to its prompt, and still attaches a pasted path.
box sh -c "mkdir -p /home/$LOGIN/workspace/standin && cd /home/$LOGIN/workspace/standin && git init -q -b main \
           && git -c user.email=t@example -c user.name=t commit -q --allow-empty -m init"
CLAUDE_V=$(box claude --version 2>&1 | tr -d '\r' | head -1)
OMP_V=$(box omp --version 2>&1 | tr -d '\r' | head -1)
OPENCODE_V=$(box opencode --version 2>&1 | tr -d '\r' | head -1)
echo "    claude [$CLAUDE_V]  omp [$OMP_V]  opencode [$OPENCODE_V]"
[ -n "$CLAUDE_V" ] && [ -n "$OMP_V" ] && [ -n "$OPENCODE_V" ] && ok "box: all three harnesses run" \
  || { bad "box: all three harnesses run" "claude [$CLAUDE_V] omp [$OMP_V] opencode [$OPENCODE_V]"; exit 1; }

# The PNG a Cmd+V would push: 16x16 rather than run.sh's 1x1, in case a harness declines a degenerate image.
FIXTURE=iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAJElEQVR42mMQsTkBR/8DNOAIlzjDINRAjCJk8cGoYTQeBoUGAK3rR5BXQzlQAAAAAElFTkSuQmCC
mac sh -c "echo $FIXTURE | base64 -d > /tmp/clipboard.png; echo png > /tmp/clipboard.kind"
PNG_SHA=$(mac sha256sum /tmp/clipboard.png | cut -c1-64)

# answer <session> <key...>: press the keys the dialog needs, then wait for the screen to change. Without the
# wait the next poll answers the same dialog again, and the extra Enter takes the default of whatever comes
# next, which for two of Claude Code's three dialogs is the answer that quits.
answer() {
  local name=$1 before k i=0; shift
  before=$(bscreen "$name")
  for k in "$@"; do btmux send-keys -t "$name" "$k"; sleep 0.4; done
  while [ "$i" -lt 40 ]; do [ "$(bscreen "$name")" != "$before" ] && return 0; sleep 0.25; i=$((i + 1)); done
}
# ready <session> <prompt needle>: clear the first-run dialogs on the base session until the harness's own
# prompt is on screen. Driven by what is there, not a fixed key sequence: wording and order change between
# releases, and a scripted key into the wrong dialog hangs the run. Verified against the pinned versions;
# Claude Code preselects "No"/"No, exit" in two of them.
ready() {
  local name=$1 needle=$2 s end=$((SECONDS + 150))
  while [ "$SECONDS" -lt "$end" ]; do
    s=$(bscreen "$name")
    case "$s" in
      *"$needle"*)                        return 0 ;;
      *"Choose the text style"*)          answer "$name" Enter ;;       # theme chooser
      *"use this API key"*)               answer "$name" Up Enter ;;    # "No (recommended)" is preselected
      *"Press Enter to continue"*)        answer "$name" Enter ;;       # security notes
      *"Is this a project you created"*)  answer "$name" Down Enter ;;  # "No, exit" is preselected
      *"esc skip"*)                       answer "$name" Escape ;;      # Oh My Pi's provider wizard
      *)                                  sleep 1 ;;
    esac
  done
  return 1
}

# harness <name> <prompt needle> <image indicator>: the whole flow for one harness, from `agent new` to a
# pasted path shown as an attachment. The three differ only in those strings.
harness() {
  local h=$1 prompt=$2 indicator=$3 second=${3/1/2} out path
  local name=$h-standin
  say "$h: a pasted image path becomes an attachment"
  check "$h: agent new prints the session name" "$name" "$(bagent new standin --harness "$h" --name "$name" --no-attach | tr -d '\r')"
  ready "$name" "$prompt" && ok "$h: the harness reached its prompt on the host" \
    || { bad "$h: the harness reached its prompt on the host" "$(bscreen "$name" | grep -v '^$' | tail -12)"
         bagent kill "$name" --force >/dev/null 2>&1; return; }

  connect "$name"
  if await "$prompt" 40; then ok "$h: the Mac's ssh pane is in the session, at the harness prompt"
  else bad "$h: the Mac's ssh pane is in the session, at the harness prompt" "$(dump)"; bagent kill "$name" --force >/dev/null 2>&1; return; fi

  # Text first: if a plain bracketed paste does not survive ssh and the host tmux, nothing below means anything.
  paste " hello-from-mac"
  saw "hello-from-mac" "$h: text pasted on the Mac arrives in the editor"

  # Cmd+V with an image on the Mac clipboard, decided by the rendered WezTerm module; the path it chose to paste
  # is then delivered as pane:paste would deliver it.
  out=$(docker exec -u macuser -e HOME=/home/macuser -w "$MAC_REPO" "$MAC" lua5.4 tests/e2e/wezterm-paste.lua domain 2>&1 | tr -d '\r')
  path=${out#paste }
  case "$out" in "paste /home/$LOGIN/.clip/"*.png) ok "$h: Cmd+V pushed the image and got a host path back" ;;
                 *) bad "$h: Cmd+V pushed the image and got a host path back" "$out"
                    bagent kill "$name" --force >/dev/null 2>&1; return ;; esac
  check "$h: the pasted path holds the pushed PNG byte for byte" "$PNG_SHA" "$(box sha256sum "$path" | cut -c1-64)"
  paste "$path"
  saw "$indicator" "$h: the pasted path is attached as an image ($indicator)"

  # A path to no file must attach nothing, or the check above would pass on any paste. What the three do with
  # the text differs (Oh My Pi drops it, the other two leave it in the editor), so only "no second attachment"
  # is asserted.
  paste "/home/$LOGIN/.clip/00000000T000000Z-absent.png"
  missing "$second" "$h: a path to no file attaches nothing (no $second)" 8

  keys C-b; keys d                      # leave the session, so the next harness connects into a clean pane
  bagent kill "$name" >/dev/null 2>&1
  check "$h: the session is gone again" "" "$(bagent ls --porcelain | tr -d '\r')"
}

# Each needle is the empty editor's placeholder, not the footer: for Claude Code the footer is the status line
# from config/claude-settings.json, and it wraps away at a narrow width.
harness claude   'Try "'        '[Image #1]'
harness omp      'π >'          '🖼 #1'
harness opencode 'Ask anything' '[Image 1]'

pass=$(grep -c '^ok$' "$T/results"); fail=$(grep -c '^FAIL$' "$T/results")
printf '\nclaude %s | omp %s | opencode %s\n' "$CLAUDE_V" "$OMP_V" "$OPENCODE_V"
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
