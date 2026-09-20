#!/usr/bin/env bash
# tests/e2e/tui.sh: the session picker as a human meets it. Two containers on a private network, "box" (the
# host: real sshd, real tmux, real fzf, install-host.sh) and "mac" (the client: install-mac.sh, its ssh config
# and key). The client holds a tmux server of its own whose one pane runs `ssh -tt box`, so the login lands in
# `agent pick` through the real config/bashrc.d/tmux-autoattach.sh fragment, on a real pty. From there
# send-keys IS typing and capture-pane IS the screen the operator would be looking at.
#
# This is deliberately not how tests/e2e/run.sh drives the picker. That one sets AGENT_PICK_FILTER, which
# replaces interactive fzf with `fzf --filter`, skips every free-text prompt and leaves the picker loop after
# one pass. Useful for the session plumbing, blind to the flow: three of the bugs this file covers (the popup
# redrawing its own list, `agent pick` inside tmux attaching nothing, a slug clash killing the picker) all sat
# under a green run.sh. So: no AGENT_PICK_FILTER here, ever.
#
# Cases are named for the flows in docs/session-picker-plan.md. L is the login picker (`agent pick`), P is the
# prefix-g popup (`agent pick --switch`); a flow that exists in both is tested in both, because they are two
# different code paths through the same menu.
# Needs docker without sudo; network only for the image builds. KEEP=1 leaves the containers up.
# Usage: bash tests/e2e/tui.sh
# A && ok || bad is the intended pattern here:
# shellcheck disable=SC2015,SC2016
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
NET=af-tui; BOX=af-tui-box; MAC=af-tui-mac
LOGIN=alice; PASSWORD=alice-pw; ALIAS=box
BOX_REPO=/home/$LOGIN/workspace/agentic-framework; MAC_REPO=/home/macuser/workspace/agentic-framework
T=$(mktemp -d); : > "$T/results"
ok()   { echo ok >> "$T/results"; printf 'ok   %s\n' "$1"; }
bad()  { echo FAIL >> "$T/results"; printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
say()  { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
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
porc()   { bagent ls --porcelain 2>/dev/null | tr -d '\r'; }
names()  { btmux list-sessions -F '#{session_name}' 2>/dev/null | tr -d '\r' | sort | tr '\n' ' ' | sed 's/ $//'; }

# --- the client's terminal ------------------------------------------------------------------------------
# One tmux server per Mac user, one pane, one ssh client in it. `ct` is Mac 1, `ct2` is Mac 2.
ct()  { docker exec -u macuser  -e HOME=/home/macuser  "$MAC" tmux -L tui "$@"; }
ct2() { docker exec -u macuser2 -e HOME=/home/macuser2 "$MAC" tmux -L tui "$@"; }
SSHCMD="ssh -tt -o BatchMode=yes -o StrictHostKeyChecking=accept-new $ALIAS"

login()  { ct  kill-session -t term  >/dev/null 2>&1; ct  new-session -d -x 180 -y 45 -s term  "$SSHCMD; echo SSH_DONE=\$?; sleep 3600"; }
login2() { ct2 kill-session -t term2 >/dev/null 2>&1; ct2 new-session -d -x 180 -y 45 -s term2 "$SSHCMD; echo SSH_DONE=\$?; sleep 3600"; }
keys()   { ct  send-keys -t term  "$@"; }
keys2()  { ct2 send-keys -t term2 "$@"; }
screen() { ct  capture-pane -p -t term  2>/dev/null | tr -d '\r' | sed 's/[[:space:]]*$//'; }
screen2(){ ct2 capture-pane -p -t term2 2>/dev/null | tr -d '\r' | sed 's/[[:space:]]*$//'; }

# await <needle> [secs] [screenfn]: poll the screen until the text shows up. Everything the picker does is
# asynchronous from here (ssh, tmux, fzf, a harness starting), so nothing is asserted without waiting first.
await()  { local n=$1 s=${2:-15} f=${3:-screen} i=0
           while [ "$i" -lt $((s * 4)) ]; do case "$($f)" in *"$n"*) return 0;; esac; sleep 0.25; i=$((i + 1)); done; return 1; }
# unaware <needle> [secs]: poll until the text is gone (a popup that closed, a session that went away).
unaware(){ local n=$1 s=${2:-15} i=0
           while [ "$i" -lt $((s * 4)) ]; do case "$(screen)" in *"$n"*) ;; *) return 0;; esac; sleep 0.25; i=$((i + 1)); done; return 1; }
# dump: both ends of the screen. fzf draws its prompt at the top and the shell's last output sits at the
# bottom, and which of the two is there is usually the whole answer, so a failure prints some of each.
dump()   { local f=${1:-screen} all; all=$($f | grep -v '^$'); printf '\n%s\n    ...\n%s' "$(printf '%s\n' "$all" | head -6)" "$(printf '%s\n' "$all" | tail -10)"; }
saw()    { if await "$1" "${3:-15}"; then ok "$2"; else bad "$2" "screen has no [$1]:$(dump)"; fi; }
saw2()   { if await "$1" "${3:-15}" screen2; then ok "$2"; else bad "$2" "screen2 has no [$1]:$(dump screen2)"; fi; }
went()   { if unaware "$1" "${3:-15}"; then ok "$2"; else bad "$2" "screen still has [$1]:$(dump)"; fi; }
# host_wait <shell test>: the same patience, for state on the box rather than pixels on the client.
host_wait(){ local i=0; while [ "$i" -lt 60 ]; do box sh -c "$1" >/dev/null 2>&1 && return 0; sleep 0.25; i=$((i + 1)); done; return 1; }
# pick <text>: narrow the menu the way a human does, then take the row. Not a filter: fzf is really running.
# C-u first is fzf's clear-query: what the last case typed is still in the box until that fzf exits.
clearq() { keys C-u; sleep 0.5; }
pick()   { clearq; keys "$1"; sleep 1; keys Enter; sleep 1; }
typ()    { clearq; keys "$1"; sleep 1; keys Enter; sleep 1; }  # a free-text prompt (name, slug)

# at_picker: put the client back at the login picker, whatever the last flow left behind. Cases here run in
# sequence against one long-lived login, so without this a single broken flow reports itself once and then
# again as every later case, and the real result is buried. Escape backs out of any menu, C-b d leaves a
# session, and a login that has ended is simply made again.
at_picker() {
  local i
  for i in 1 2 3; do
    await 'session>' 2 && { clearq; return 0; }
    keys Escape; sleep 1; await 'session>' 2 && { clearq; return 0; }
    keys C-b; keys d; sleep 1; await 'session>' 3 && { clearq; return 0; }
    login; await 'session>' 25 && { clearq; return 0; }
  done
  return 1
}

# in_session <name>: at the picker, then inside that session, with the client attached to a view of it. The
# popup flows all start from inside a session, since prefix-g is only reachable from a tmux client.
in_session() { at_picker; pick "$1"; await "[$1@" 25; }

# popup: open the prefix-g picker on whatever session the client is in.
popup() { keys C-b; keys g; sleep 2; await 'session>' 20; }

say "images and containers"
command -v docker >/dev/null || { echo "docker is required" >&2; exit 2; }
docker rm -f "$BOX" "$MAC" >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1
docker build -q -f "$REPO/tests/e2e/Dockerfile.host" --build-arg "LOGIN=$LOGIN" --build-arg "PASSWORD=$PASSWORD" -t af-e2e-host "$REPO/tests/e2e" >/dev/null || { echo "host image build failed" >&2; exit 1; }
docker build -q -f "$REPO/tests/e2e/Dockerfile.mac" -t af-e2e-mac "$REPO/tests/e2e" >/dev/null || { echo "mac image build failed" >&2; exit 1; }
docker network create "$NET" >/dev/null
docker run -d --name "$BOX" --hostname "$ALIAS" --network "$NET" --network-alias "$ALIAS" af-e2e-host >/dev/null
docker run -d --name "$MAC" --hostname mac --network "$NET" af-e2e-mac >/dev/null
BOX_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$BOX")
root install -d -o "$LOGIN" -g "$LOGIN" "$BOX_REPO" "/home/$LOGIN/workspace"
tar -C "$REPO" --exclude=.git --exclude=.env -cf - . | docker exec -i -u "$LOGIN" "$BOX" tar -C "$BOX_REPO" -xf -
docker exec -u macuser "$MAC" install -d "$MAC_REPO"
tar -C "$REPO" --exclude=.git --exclude=.env -cf - . | docker exec -i -u macuser "$MAC" tar -C "$MAC_REPO" -xf -
for _ in $(seq 1 30); do mac ssh-keyscan -T 2 "$ALIAS" 2>/dev/null | grep -q ssh-ed25519 && break; sleep 1; done

say "host and client install"
box ./install-host.sh --no-tools >"$T/install-host.log" 2>&1
check "host: install-host.sh exit 0" 0 "$?"
mac sh -c "printf 'AGENT_HOST=$ALIAS\nAGENT_HOST_ADDRESS=$ALIAS\nAGENT_HOST_USER=$LOGIN\nAGENT_HOST_LAN_IP=$BOX_IP\n' > .env"
docker exec -t -u macuser -e HOME=/home/macuser -e SSH_ASKPASS=/usr/local/bin/askpass -e SSH_ASKPASS_REQUIRE=force \
       -e "E2E_PASSWORD=$PASSWORD" -w "$MAC_REPO" "$MAC" ./install-mac.sh >"$T/install-mac.log" 2>&1
check "mac: install-mac.sh exit 0" 0 "$?"
# macuser2 gets the same treatment, for the two-device flows at the end.
MAC2_REPO=/home/macuser2/workspace/agentic-framework
docker exec -u macuser2 "$MAC" install -d "$MAC2_REPO"
tar -C "$REPO" --exclude=.git --exclude=.env -cf - . | docker exec -i -u macuser2 "$MAC" tar -C "$MAC2_REPO" -xf -
mac sh -c "cat .env" | docker exec -i -u macuser2 "$MAC" sh -c "cat > $MAC2_REPO/.env"
docker exec -t -u macuser2 -e HOME=/home/macuser2 -e SSH_ASKPASS=/usr/local/bin/askpass -e SSH_ASKPASS_REQUIRE=force \
       -e "E2E_PASSWORD=$PASSWORD" -w "$MAC2_REPO" "$MAC" ./install-mac.sh >"$T/install-mac2.log" 2>&1
check "mac2: install-mac.sh exit 0" 0 "$?"

# Two repos to choose between, and a stand-in harness: it records where it started, then becomes a process
# that sits still and can be killed, so "the harness is running" and "the harness exited" are both provable.
docker exec -i -u "$LOGIN" -e "HOME=/home/$LOGIN" "$BOX" sh -s <<'STUB'
set -e
cp "$(readlink -f /bin/sh)" "$HOME/.local/bin/claude-proc"
printf '#!/bin/sh\nprintf "standin harness\\nSTANDIN-CLAUDE-HERE\\nready\\n"\npwd > "$HOME/stub.cwd"\nexec claude-proc -c "read line"\n' > "$HOME/.local/bin/claude"
chmod +x "$HOME/.local/bin/claude"
for r in demo other; do
  mkdir -p "$HOME/workspace/$r"
  git -C "$HOME/workspace/$r" init -q -b main
  git -C "$HOME/workspace/$r" -c user.email=t@example -c user.name=t commit -q --allow-empty -m init
done
STUB

# =========================================================================================================
say "flow 1 (L): an interactive login lands in the picker"
check "non-interactive ssh runs the command and no picker" "hi" "$(mac ssh -o BatchMode=yes "$ALIAS" 'echo hi' 2>/dev/null | tr -d '\r')"
login
saw 'session>' "L1: the login lands in fzf" 30
saw '+ new session' "L1: the verb rows are on the screen"
saw 'x log out' "L1: the ways out are on the screen"

at_picker
say "flow 3 (L): + new shell asks for a name and puts you in it"
pick 'new shell'
saw 'empty: scratch' "L3: + new shell asks for a name"
typ 'notes'
saw '[notes@1]' "L3: the client is attached to a view of the named session" 20
check "L3: the base session is named after what was typed" "notes" "$(porc | cut -f1)"
check "L3: it is a shell session in ~/workspace" "shell	-" "$(porc | cut -f2,3)"
keys 'echo TYPED-IN-THE-SHELL' ; keys Enter
saw 'TYPED-IN-THE-SHELL' "L3: keystrokes reach the new shell"

say "flow 13/9 (L): the picker shows no preview, detach comes back to the picker"
in_session notes
keys 'echo PREVIEW-MARKER-42'; keys Enter; sleep 1
keys C-b; keys d
saw '+ new session' "L9: detaching from a session comes back to the picker" 20
host_wait "test \$(tmux list-sessions -F '#{session_name}' | grep -c '^notes@') -eq 0" \
  && ok "L9: the view went with the detached client" || bad "L9: the view went with the detached client" "$(names)"
check "L9: the base survived the detach" "notes" "$(porc | cut -f1)"
keys 'notes'; sleep 2
went 'PREVIEW-MARKER-42' "L13: highlighting a session does not preview its screen"

at_picker
say "flow 4 (L): choosing a session row attaches a view of it"
pick 'notes'
saw '[notes@' "L4: picking the row attaches a fresh view" 20
saw 'PREVIEW-MARKER-42' "L4: it is the same session, scrollback and all"
keys C-b; keys d; sleep 1
await '+ new session' 20

at_picker
say "flow 2 (L): + new session walks repo, harness and slug, then puts you in it"
pick 'new session'
saw 'repo>' "L2: the repo menu"
pick 'demo'
saw 'harness>' "L2: the harness menu"
pick 'shell'
saw 'slug' "L2: the slug prompt"
typ 'feature'
saw '[demo-feature@1]' "L2: the client lands in the new session" 25
check "L2: the session works in the worktree" "demo-feature	shell	demo	agent/feature" "$(porc | grep feature | cut -f1-4)"
check "L2: the worktree is on disk" ok "$(box sh -c "test -d /home/$LOGIN/workspace/demo.wt/feature && echo ok")"
check "L2: it is a worktree of the repo" ok "$(box sh -c "git -C /home/$LOGIN/workspace/demo worktree list | grep -q demo.wt/feature && echo ok")"
keys C-b; keys d; sleep 1
await '+ new session' 20

at_picker
say "flow 5 (L): kill asks a second time, takes the views and the worktree, keeps the branch"
pick 'kill session'
saw 'kills the harness' "L5: kill asks in a list of its own"
pick 'demo-feature'
saw '+ new session' "L5: the picker comes back after the kill" 20
host_wait "! tmux has-session -t demo-feature 2>/dev/null" \
  && ok "L5: the session is gone" || bad "L5: the session is gone" "$(names)"
check "L5: the worktree directory is gone" "" "$(box sh -c "test -d /home/$LOGIN/workspace/demo.wt/feature && echo still-there")"
check "L5: the branch is kept" "ok" "$(box sh -c "git -C /home/$LOGIN/workspace/demo rev-parse --verify -q agent/feature >/dev/null && echo ok")"

at_picker
say "flow 2b (L): the same slug again, now that agent/feature exists"
pick 'new session'; pick 'demo'; pick 'shell'
saw 'slug' "L2b: back at the slug prompt"
typ 'feature'
saw '[demo-feature@1]' "L2b: a slug whose branch already exists still lands in a session" 25
check "L2b: it is on the branch that was kept" "agent/feature" "$(porc | grep feature | cut -f4)"

say "flow 5b (L): a worktree with uncommitted changes asks once more"
login; await 'session>' 30
in_session demo-feature
keys 'echo dirty > scratch.txt'; keys Enter; sleep 1
keys C-b; keys d; sleep 1
await '+ new session' 20
pick 'kill session'; pick 'demo-feature'
saw 'Remove the worktree anyway?' "L5b: a dirty worktree asks before it goes"
keys 'n' Enter; sleep 2
check "L5b: answering no keeps the worktree" ok "$(box sh -c "test -f /home/$LOGIN/workspace/demo.wt/feature/scratch.txt && echo ok")"
saw 'worktree kept' "L5b: and says how to remove it by hand"
# Asked of the host, not of the screen, and alone in this file in that. `confirm_dirty` reads the answer
# from /dev/tty while fzf is not running, and the redraw that follows is the one thing capture-pane will not
# show through this container's ssh pty: fzf covers the screen with --height and, in this case only, what
# comes back is the state from before the question. The menu is a process on the box either way, so that is
# what is asserted; the same sequence driven against a local tmux does show the menu return.
host_wait "pgrep -f 'fzf --prompt=session' >/dev/null" \
  && ok "L5: the picker is back at its menu after a kept worktree" \
  || bad "L5: the picker is back at its menu after a kept worktree" \
         "$(box sh -c "ps -eo pid,stat,args | grep -E 'agent pick|fzf' | grep -v grep" 2>&1 | tr '\n' ';')"
box sh -c "git -C /home/$LOGIN/workspace/demo worktree remove --force /home/$LOGIN/workspace/demo.wt/feature" >/dev/null 2>&1

at_picker
say "flow 14 (L): agent pick from inside a tmux pane"
pick 'notes'
await '[notes@1]' 20
keys 'agent pick'; keys Enter
saw 'session>' "L14: the picker runs inside a pane" 20
pick 'new shell'
saw 'empty: scratch' "L14: it offers the same menus"
typ 'inner'
saw '[inner@1]' "L14: inside tmux it switches the client to the new session, rather than silently failing" 25
check "L14: no orphan was left behind" "1" "$(porc | grep -c '^inner	')"

say "flow P (popup): the same menus from prefix-g, which must end by leaving the popup"
in_session notes
keys C-b; keys g; sleep 2
saw 'session>' "P: prefix-g opens the picker in a popup" 20
pick 'new shell'
saw 'empty: scratch' "P3: + new shell asks for a name here too"
typ 'from-popup'
saw '[from-popup@1]' "P3: the popup switches the client to the new session" 25
went 'session>' "P3: and the popup closes instead of redrawing its list"
keys 'echo POPUP-SHELL-WORKS'; keys Enter
saw 'POPUP-SHELL-WORKS' "P3: keystrokes reach the session, not a stale popup"

popup
pick 'new session'; pick 'other'; pick 'shell'; typ ''
saw '[other@1]' "P2: + new session switches the client too" 25
went 'session>' "P2: and closes the popup"
check "P2: no slug means the main checkout" "other	shell	other	main" "$(porc | grep '^other	' | cut -f1-4)"

popup
pick 'notes'
saw '[notes@' "P4: picking a row switches to that session" 25
went 'session>' "P4: and closes the popup"

popup
pick 'plain shell here'
went 'session>' "P6: plain shell here just closes the popup"
saw '[notes@' "P6: and leaves the client where it was"

popup
pick 'kill session'
saw 'kills the harness' "P5: kill asks a second time in the popup too"
pick 'from-popup'
host_wait "! tmux has-session -t from-popup 2>/dev/null" \
  && ok "P5: the session is gone" || bad "P5: the session is gone" "$(names)"

say "flow 10 (L): a harness that exits leaves its last screen"
bagent new demo --harness claude --no-attach >/dev/null 2>&1
host_wait "test -f /home/$LOGIN/stub.cwd"
check "10: the harness started in the repo" "/home/$LOGIN/workspace/demo" "$(box cat "/home/$LOGIN/stub.cwd" | tr -d '\r')"
check "10: ls says running" "running" "$(porc | grep '^demo	' | cut -f6)"
box sh -c "kill \$(tmux display-message -p -t demo '#{pane_pid}')"
host_wait "tmux display-message -p -t demo '#{pane_dead}' | grep -qx 1"
check "10: ls says exited" "exited" "$(porc | grep '^demo	' | cut -f6)"
in_session notes
popup
pick 'demo'
saw 'STANDIN-CLAUDE-HERE' "10: the exited harness's last screen is still there to read" 25
in_session notes
popup
pick 'kill session'; pick 'demo'
host_wait "! tmux has-session -t demo 2>/dev/null" \
  && ok "10: an exited session can be killed from the picker" || bad "10: an exited session can be killed from the picker" "$(names)"

say "flow 11/12: a second Mac on the same session, and detaching only takes its own view"
in_session notes
login2
saw2 'session>' "11: the second Mac lands in the picker too" 30
keys2 'notes'; sleep 1; keys2 Enter; sleep 2
saw2 '[notes@' "11: it picks the same session and gets a view of its own" 25
check "11: one base, two views" 3 "$(btmux display-message -p -t notes '#{session_group_size}' | tr -d '\r')"
check "11: both devices are listed against the one base" 2 "$(porc | grep '^notes	' | cut -f8 | tr ',' '\n' | grep -c .)"
check "11: still one row in ls" 1 "$(porc | grep -c '^notes	')"
WIN=$(btmux new-window -t notes -P -F '#{window_index}' | tr -d '\r')
VIEWS=$(btmux list-sessions -F '#{session_name}' | tr -d '\r' | grep '^notes@' | sort)
V1=$(printf '%s\n' "$VIEWS" | head -1); V2=$(printf '%s\n' "$VIEWS" | tail -1)
check "12: the two Macs really are on two views" 2 "$(printf '%s\n' "$VIEWS" | grep -c .)"
B2=$(btmux display-message -p -t "$V2" '#{window_index}' | tr -d '\r')
btmux select-window -t "$V1:$WIN" >/dev/null
check "12: one device changed window" "$WIN" "$(btmux display-message -p -t "$V1" '#{window_index}' | tr -d '\r')"
check "12: the other did not move with it" "$B2" "$(btmux display-message -p -t "$V2" '#{window_index}' | tr -d '\r')"
ct2 kill-session -t term2 >/dev/null 2>&1
host_wait "test \$(tmux list-sessions -F '#{session_name}' | grep -c '^notes@') -eq 1" \
  && ok "12: the second Mac leaving destroys only its own view" || bad "12: the second Mac leaving destroys only its own view" "$(names)"
check "12: the base is still there" "notes" "$(porc | grep '^notes	' | cut -f1)"

at_picker
say "flow 6/7/8 (L): the three ways out"
pick 'plain shell here'
sleep 3
keys 'echo "tmux=[$TMUX] PLAIN-SHELL"'; keys Enter
saw 'tmux=[] PLAIN-SHELL' "L6: plain shell here leaves you in a login shell outside tmux" 20
keys 'exit'; keys Enter
saw 'SSH_DONE=0' "L6: and exiting that shell ends the connection" 20

login
await 'session>' 30
keys Escape; sleep 1
saw 'SSH_DONE' "L8: Escape at the login picker closes the connection" 20

login
await 'session>' 30
pick 'log out'
saw 'SSH_DONE' "L7: x log out closes the connection" 20

say "flow P7: log out from the popup ends the login it is standing in"
login
await 'session>' 30
pick 'notes'
await '[notes@' 25
popup
pick 'log out'
saw 'SSH_DONE' "P7: log out in the popup ends the ssh login, not just the popup" 25
check "P7: the session it was attached to survives" "notes" "$(porc | grep '^notes	' | cut -f1)"

pass=$(grep -c '^ok$' "$T/results"); fail=$(grep -c '^FAIL$' "$T/results")
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
