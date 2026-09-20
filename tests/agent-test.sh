#!/usr/bin/env bash
# tests/agent-test.sh: checks for bin/agent and the login fragment that runs it. No sudo, no network, no
# Docker. Everything happens in a throwaway HOME with a fake ~/workspace/demo git repo, a stand-in harness
# on PATH and its own tmux socket (AGENT_TMUX_SOCKET), so the live tmux server, the real harnesses and the
# operator's sessions are never touched. Exit 0 when all pass.
# Usage: bash tests/agent-test.sh
# A && ok || bad is the intended pattern and cases run in subshells on purpose:
# shellcheck disable=SC2015,SC2016
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
AGENT=$REPO/bin/agent
T=$(mktemp -d)
export AGENT_TMUX_SOCKET=af-test-$$
cleanup() { tmux -L "$AGENT_TMUX_SOCKET" kill-server >/dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT
: > "$T/results"                                   # one line per case; cases may run in subshells
ok()    { echo ok >> "$T/results"; printf 'ok   %s\n' "$1"; }
bad()   { echo FAIL >> "$T/results"; printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }
skip()  { printf 'skip %s\n     %s\n' "$1" "${2:-}"; }        # neither pass nor fail: reported on its own
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
has()   { case "$2" in *"$1"*) ok "$3";; *) bad "$3" "output lacks [$1]";; esac; }
tm()    { tmux -L "$AGENT_TMUX_SOCKET" "$@"; }
sid()   { tm list-sessions -F '#{session_id}' -f "#{==:#{session_name},$1}" 2>/dev/null | head -1; }
opt()   { tm display-message -p -t "$(sid "$1")" "#{$2}" 2>/dev/null; }
names() { tm list-sessions -F '#{session_name}' 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//'; }
# wait_until <seconds> <cmd...>: poll, because attaching and exiting happen in other processes. The
# condition must be a command, never a "$(...)" the caller's shell would expand once and for all.
wait_until() { local n=$1 i=0; shift; while [ "$i" -lt $((n * 10)) ]; do "$@" >/dev/null 2>&1 && return 0; sleep 0.1; i=$((i + 1)); done; return 1; }
have_session() { [ -n "$(sid "$1")" ]; }
no_session()   { [ -z "$(sid "$1")" ]; }
opt_is()       { [ "$(opt "$1" "$2")" = "$3" ]; }

# --- a host of our own --------------------------------------------------------------------------------
# fzf has to be resolved to a real binary before HOME moves: `fzf` on this host is usually a mise shim,
# and a shim looks its version up against $HOME, which the throwaway HOME does not have.
FZF=$(command -v fzf 2>/dev/null || true)
case $FZF in */shims/*) FZF=$(mise which fzf 2>/dev/null || true) ;; esac
[ -z "$FZF" ] || FZF=$(readlink -f "$FZF")
export HOME=$T/home
mkdir -p "$HOME/bin" "$HOME/workspace/demo"
SYSPATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v '/mise/shims$' | paste -sd: -)   # shims resolve against $HOME
export PATH="$HOME/bin:$SYSPATH"
git -C "$HOME/workspace/demo" init -q -b main
git -C "$HOME/workspace/demo" -c user.email=t@example -c user.name=t commit -q --allow-empty -m init
# A second repo for the picker flows: names are <repo>[-<slug>], so a picker-made session in demo would be
# demo-2 or demo-3 depending on what ran before it; in picked it is always "picked".
mkdir -p "$HOME/workspace/picked"; git -C "$HOME/workspace/picked" init -q -b main
# The stand-in harness: records where it was started, then execs a process tmux can name, so
# pane_current_command proves the session command ran rather than a login shell. claude-proc is a copy of
# /bin/sh and not a symlink to sleep, because coreutils ships as one multi-call binary that refuses to run
# under another argv[0]; blocking on read keeps it a single quiet process until the test kills it.
cp "$(readlink -f /bin/sh)" "$HOME/bin/claude-proc"
cat > "$HOME/bin/claude" <<'STANDIN'
#!/bin/sh
pwd > "$HOME/standin.cwd"
exec claude-proc -c 'read line'
STANDIN
chmod +x "$HOME/bin/claude"
[ -z "$FZF" ] || ln -sf "$FZF" "$HOME/bin/fzf"
# Prove it actually runs here, rather than trusting the path: a picker case that silently gets no fzf
# would otherwise "pass" by falling through to the log-out branch.
HAVE_FZF=0
printf 'one\ntwo\n' | fzf --filter=two >/dev/null 2>&1 && HAVE_FZF=1
HAVE_PTY=0; command -v script >/dev/null 2>&1 && HAVE_PTY=1
# Every pty case runs `env -u TMUX`: a real login has no TMUX (the landing fragment only fires when it is
# empty), and leaving the developer's own TMUX in place makes tmux refuse the attach as a nested session.

echo "# syntax and shellcheck"
for f in bin/agent tests/agent-test.sh config/bashrc.d/tmux-autoattach.sh; do
  bash -n "$REPO/$f" && ok "bash -n $f" || bad "bash -n $f"
done
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x "$REPO/bin/agent" && ok "shellcheck bin/agent" || bad "shellcheck bin/agent"
  shellcheck -x "$REPO/tests/agent-test.sh" && ok "shellcheck tests/agent-test.sh" || bad "shellcheck tests/agent-test.sh"
  shellcheck "$REPO/config/bashrc.d/tmux-autoattach.sh" && ok "shellcheck tmux-autoattach.sh" || bad "shellcheck tmux-autoattach.sh"
else
  skip "shellcheck" "not installed: mise use -g shellcheck@latest"
fi

echo "# ls with no server"
check "ls: no server prints nothing" "" "$("$AGENT" ls 2>&1)"
check "ls: no server exits 0" 0 "$("$AGENT" ls >/dev/null 2>&1; echo $?)"

echo "# new: the base session carries the facts the picker shows"
check "new --no-attach prints the name" demo "$("$AGENT" new demo --no-attach)"
check "new: @harness" claude "$(opt demo @harness)"
check "new: @repo" demo "$(opt demo @repo)"
check "new: @cwd" "$HOME/workspace/demo" "$(opt demo @cwd)"
check "new: @branch" main "$(opt demo @branch)"
check "new: @hwin is a window id" 1 "$(case $(opt demo @hwin) in @[0-9]*) echo 1;; *) echo 0;; esac)"
check "new: remain-on-exit on the harness window" on "$(opt demo remain-on-exit)"
wait_until 10 test -f "$HOME/standin.cwd"
check "new: the harness ran in the repo" "$HOME/workspace/demo" "$(cat "$HOME/standin.cwd" 2>/dev/null)"
wait_until 10 opt_is demo pane_current_command claude-proc
check "new: window 1 runs the stand-in" claude-proc "$(opt demo pane_current_command)"
check "new: the harness is alive" 0 "$(opt demo pane_dead)"
check "new: unknown repo exits 2" 2 "$("$AGENT" new nosuch --no-attach >/dev/null 2>&1; echo $?)"
check "new: unknown harness exits 2" 2 "$("$AGENT" new demo --harness nope --no-attach >/dev/null 2>&1; echo $?)"

echo "# naming"
mkdir -p "$HOME/workspace/a.b:c"; git -C "$HOME/workspace/a.b:c" init -q -b main
check "name: . and : become _" a_b_c "$("$AGENT" new 'a.b:c' --no-attach)"
check "name: a second session for the same repo gets -2" demo-2 "$("$AGENT" new demo --no-attach)"
check "name: --name is used as given" mine "$("$AGENT" new demo --name mine --no-attach)"

echo "# worktrees"
out=$("$AGENT" new demo --slug feat --no-attach 2>&1)
has demo-feat "$out" "new --slug: session named after the slug"
check "new --slug: worktree exists" 1 "$([ -d "$HOME/workspace/demo.wt/feat" ] && echo 1 || echo 0)"
check "new --slug: on branch agent/feat" agent/feat "$(git -C "$HOME/workspace/demo.wt/feat" rev-parse --abbrev-ref HEAD)"
check "new --slug: @branch recorded" agent/feat "$(opt demo-feat @branch)"
out2=$("$AGENT" new demo --slug feat --no-attach 2>&1)
has "reusing worktree" "$out2" "new --slug again: reuses the worktree instead of failing"
has demo-feat-2 "$out2" "new --slug again: new session, same worktree"

echo "# ls"
tm new-session -d -s main                                    # a pre-existing plain session, as on the host today
porc=$("$AGENT" ls --porcelain)
check "ls --porcelain: eight tab-separated columns" 8 "$(printf '%s\n' "$porc" | head -1 | awk -F'\t' '{print NF}')"
check "ls --porcelain: a plain session is a shell with no repo" "main	shell	-	-" \
  "$(printf '%s\n' "$porc" | awk -F'\t' '$1=="main"{print $1"\t"$2"\t"$3"\t"$4}')"
check "ls --porcelain: a harness row" "demo	claude	demo	main	$HOME/workspace/demo	running	-" \
  "$(printf '%s\n' "$porc" | awk -F'\t' '$1=="demo"{print $1"\t"$2"\t"$3"\t"$4"\t"$5"\t"$6"\t"$8}')"
check "ls --porcelain: the worktree row" "demo-feat	claude	demo	agent/feat	$HOME/workspace/demo.wt/feat" \
  "$(printf '%s\n' "$porc" | awk -F'\t' '$1=="demo-feat"{print $1"\t"$2"\t"$3"\t"$4"\t"$5}')"
check "ls --porcelain: created is an epoch" 1 "$(printf '%s\n' "$porc" | awk -F'\t' '{if ($7 !~ /^[0-9]+$/) bad=1} END {print (bad?0:1)}')"
check "ls --porcelain: ordered by created then name" "$porc" "$(printf '%s\n' "$porc" | sort -t'	' -k7,7n -k1,1)"
check "ls: human output has a header" 1 "$("$AGENT" ls | head -1 | grep -c '^NAME .*HARNESS .*DEVICES$')"
check "ls: one human row per porcelain row" "$(printf '%s\n' "$porc" | wc -l)" "$("$AGENT" ls | tail -n +2 | wc -l)"
check "ls: a worktree row is marked wt" 1 "$("$AGENT" ls | awk '$1=="demo-feat" && $5=="wt"' | wc -l)"

echo "# attach: each device gets its own view"
if [ "$HAVE_PTY" = 0 ]; then
  skip "attach" "script(1) is not available, so no pty for a tmux client"
else
  env -u TMUX SSH_CLIENT="10.9.9.9 51000 22" timeout 60 script -qfc "$AGENT attach demo" /dev/null >/dev/null 2>&1 &
  attach_pid=$!
  if ! wait_until 15 have_session 'demo@1'; then
    bad "attach: a view is created" "demo@1 never appeared; sessions: $(names)"
  else
    ok "attach: the view demo@1 exists"
    check "attach: the view is grouped with the base" 1 "$(opt 'demo@1' session_grouped)"
    check "attach: the view has the client" 1 "$(opt 'demo@1' session_attached)"
    check "attach: the base keeps none" 0 "$(opt demo session_attached)"
    check "attach: @device is the ssh client address" 10.9.9.9 "$(opt 'demo@1' @device)"
    check "attach: destroy-unattached armed on the view" on "$(opt 'demo@1' destroy-unattached)"
    check "attach: the base is not armed" off "$(opt demo destroy-unattached)"
    check "ls: views are not listed" "" "$("$AGENT" ls --porcelain | cut -f1 | grep '@' || true)"
    check "ls: the device shows against the base" 10.9.9.9 "$("$AGENT" ls --porcelain | awk -F'\t' '$1=="demo"{print $8}')"
    check "attach: a view cannot itself be attached" 2 "$("$AGENT" attach 'demo@1' >/dev/null 2>&1; echo $?)"
    tm detach-client -s 'demo@1'
    wait_until 15 no_session 'demo@1' \
      && ok "attach: detaching destroys the view" || bad "attach: detaching destroys the view" "$(names)"
    check "attach: the base survives the detach" 1 "$([ -n "$(sid demo)" ] && echo 1 || echo 0)"
    wait "$attach_pid"; check "attach: exits 0 on detach" 0 "$?"
    check "ls: the device is gone with the view" "-" "$("$AGENT" ls --porcelain | awk -F'\t' '$1=="demo"{print $8}')"
  fi
fi
check "attach: unknown name exits 2" 2 "$("$AGENT" attach nosuch >/dev/null 2>&1; echo $?)"

echo "# a harness that exits leaves its last screen"
kill "$(opt demo pane_pid)" 2>/dev/null
wait_until 10 opt_is demo pane_dead 1 \
  && ok "exit: the pane is dead, not gone" || bad "exit: the pane is dead, not gone" "$(opt demo pane_dead)"
check "exit: the base session remains" 1 "$([ -n "$(sid demo)" ] && echo 1 || echo 0)"
check "exit: ls says exited" exited "$("$AGENT" ls --porcelain | awk -F'\t' '$1=="demo"{print $6}')"
check "exit: the last screen is still readable" 1 "$(tm capture-pane -p -t "$(sid demo)" | grep -c . || true)"

echo "# kill"
# demo-feat-2 is the second session in the same worktree; --keep-worktree is how the one that goes
# first leaves the checkout for it.
keepout=$("$AGENT" kill demo-feat --keep-worktree)
has "worktree kept" "$keepout" "kill --keep-worktree: says the worktree stays"
has "git -C $HOME/workspace/demo worktree remove $HOME/workspace/demo.wt/feat" "$keepout" "kill --keep-worktree: the exact command"
check "kill --keep-worktree: the worktree is still on disk" 1 "$([ -d "$HOME/workspace/demo.wt/feat" ] && echo 1 || echo 0)"
check "kill: the session is gone" "" "$(sid demo-feat)"
# Dirty and nobody to ask: setsid drops the controlling terminal, which is what a script or a cron run looks
# like, and the answer nobody gave has to be "keep".
echo dirt > "$HOME/workspace/demo.wt/feat/dirt"
if command -v setsid >/dev/null 2>&1; then
  dirtyout=$(setsid "$AGENT" kill demo-feat-2 </dev/null 2>/dev/null)
  has "worktree kept" "$dirtyout" "kill: a dirty worktree with no terminal to ask is kept"
  has "worktree remove --force $HOME/workspace/demo.wt/feat" "$dirtyout" "kill: the kept command carries --force"
  check "kill: the dirty worktree is still on disk" 1 "$([ -d "$HOME/workspace/demo.wt/feat" ] && echo 1 || echo 0)"
  check "kill: the session went anyway" "" "$(sid demo-feat-2)"
else
  skip "kill: a dirty worktree with no terminal to ask is kept" "setsid is not available"
  "$AGENT" kill demo-feat-2 --keep-worktree >/dev/null 2>&1 || true
fi
# --force is the operator answering yes up front: the uncommitted file goes with the worktree.
"$AGENT" new demo --slug feat --harness shell --name forcekill --no-attach >/dev/null 2>&1
forceout=$("$AGENT" kill forcekill --force)
has "worktree removed" "$forceout" "kill --force: removes a dirty worktree"
check "kill --force: the worktree is gone" 0 "$([ -d "$HOME/workspace/demo.wt/feat" ] && echo 1 || echo 0)"
check "kill --force: the branch is kept" agent/feat "$(git -C "$HOME/workspace/demo" branch --list agent/feat --format '%(refname:short)')"
# The ordinary case: a clean worktree goes with the session, no flags and no questions.
"$AGENT" new demo --slug clean --harness shell --name cleankill --no-attach >/dev/null 2>&1
cleanout=$("$AGENT" kill cleankill)
has "worktree removed: $HOME/workspace/demo.wt/clean" "$cleanout" "kill: a clean worktree is removed with the session"
check "kill: the clean worktree is gone from disk" 0 "$([ -d "$HOME/workspace/demo.wt/clean" ] && echo 1 || echo 0)"
check "kill: git no longer lists it" 0 "$(git -C "$HOME/workspace/demo" worktree list | grep -c 'demo.wt/clean' || true)"
check "kill: the branch is kept" agent/clean "$(git -C "$HOME/workspace/demo" branch --list agent/clean --format '%(refname:short)')"
# A session in the main checkout has no worktree to take away and says nothing about one.
"$AGENT" new demo --harness shell --name mainkill --no-attach >/dev/null 2>&1
check "kill: a session in the main checkout mentions no worktree" "" "$("$AGENT" kill mainkill)"
check "kill: the main checkout is untouched" 1 "$([ -d "$HOME/workspace/demo" ] && echo 1 || echo 0)"
check "kill: unknown name exits 2" 2 "$("$AGENT" kill nosuch >/dev/null 2>&1; echo $?)"
check "kill: an unknown flag exits 2" 2 "$("$AGENT" kill demo --nope >/dev/null 2>&1; echo $?)"
if [ "$HAVE_PTY" = 1 ]; then
  env -u TMUX SSH_CLIENT="10.8.8.8 51000 22" timeout 60 script -qfc "$AGENT attach demo-2" /dev/null >/dev/null 2>&1 &
  kill_pid=$!
  if wait_until 15 have_session 'demo-2@1'; then
    "$AGENT" kill demo-2 >/dev/null
    wait_until 15 no_session 'demo-2@1' \
      && ok "kill: the views go with the base" || bad "kill: the views go with the base" "$(names)"
  else
    skip "kill: the views go with the base" "no pty client"
  fi
  # the client dies with its session; tear down anyway so a failed case cannot block the run
  "$AGENT" kill demo-2 >/dev/null 2>&1 || true
  wait "$kill_pid" 2>/dev/null || true
fi

echo "# naming: what the picker can hand to tmux"
"$AGENT" new demo --harness shell --name 'my notes' --no-attach >/dev/null
check "name: whitespace becomes _, so the row's first word is the whole name" "my_notes" \
  "$("$AGENT" ls --porcelain | awk -F'\t' '$1=="my_notes"{print $1}')"
"$AGENT" kill my_notes >/dev/null 2>&1
"$AGENT" new demo --harness shell --name 'a.b:c|d,e' --no-attach >/dev/null
check "name: the tmux and field separators go too" "a_b_c_d_e" \
  "$("$AGENT" ls --porcelain | awk -F'\t' '$1=="a_b_c_d_e"{print $1}')"
"$AGENT" kill 'a_b_c_d_e' >/dev/null 2>&1

echo "# new --slug: a branch that outlived its worktree"
# `agent kill` takes the worktree directory and keeps the branch, so the second `new --slug reuse` meets an
# agent/reuse that already exists. It used to die there, and dying inside the picker ends the login shell.
"$AGENT" new demo --slug reuse --name wt1 --no-attach >/dev/null
check "new --slug: the worktree is made" ok "$([ -d "$HOME/workspace/demo.wt/reuse" ] && echo ok)"
check "new --slug: on the agent/ branch" "agent/reuse" "$(git -C "$HOME/workspace/demo.wt/reuse" rev-parse --abbrev-ref HEAD)"
"$AGENT" kill wt1 >/dev/null 2>&1
check "kill: the worktree directory is gone" "" "$([ -d "$HOME/workspace/demo.wt/reuse" ] && echo still-there)"
check "kill: the branch is kept" ok "$(git -C "$HOME/workspace/demo" rev-parse --verify -q refs/heads/agent/reuse >/dev/null && echo ok)"
out=$("$AGENT" new demo --slug reuse --name wt2 --no-attach 2>&1)
check "new --slug: the same slug again succeeds on the kept branch" 0 "$?"
has "reusing branch agent/reuse" "$out" "new --slug: and says it is reusing the branch"
check "new --slug: the session is on that branch" "agent/reuse" "$("$AGENT" ls --porcelain | awk -F'\t' '$1=="wt2"{print $4}')"
"$AGENT" kill wt2 >/dev/null 2>&1

echo "# pick"
if [ "$HAVE_FZF" = 0 ]; then
  skip "pick" "fzf is not installed (install-host.sh phase 1 installs it)"
else
  # env -u TMUX on every one of these: they are the *login* picker, and $TMUX is what tells the picker it has
  # a client to switch instead of a client to attach. Left in, the developer's own tmux would change the
  # answers (log out would mark and detach rather than exit 3), which is right for a pane and wrong here.
  check "pick: log out exits 3" 3 "$(env -u TMUX AGENT_PICK_FILTER='log out' "$AGENT" pick >/dev/null 2>&1; echo $?)"
  check "pick: plain shell here exits 0" 0 "$(env -u TMUX AGENT_PICK_FILTER='plain shell here' "$AGENT" pick >/dev/null 2>&1; echo $?)"
  check "pick: --switch outside tmux exits 2" 2 "$(env -u TMUX "$AGENT" pick --switch >/dev/null 2>&1; echo $?)"
  # A flow that cannot finish returns to the menu. It must never exit: this process is the login shell.
  before=$(names)
  check "pick: a repo that matches nothing leaves the picker alive, exit 0" 0 \
    "$(env -u TMUX AGENT_PICK_FILTER='new session;nosuchrepo' "$AGENT" pick >/dev/null 2>&1; echo $?)"
  check "pick: and creates nothing" "$before" "$(names)"
  # The kill row asks a second time, so the filter is a queue: verb, then the session to kill.
  "$AGENT" new demo --harness shell --name killme --no-attach >/dev/null
  before=$(names)
  AGENT_PICK_FILTER='kill session;nosuchsession' "$AGENT" pick >/dev/null 2>&1
  check "pick: kill with nothing matching leaves every session alone" "$before" "$(names)"
  AGENT_PICK_FILTER='kill session;killme' "$AGENT" pick >/dev/null 2>&1
  check "pick: kill session removes the chosen session" "" "$(sid killme)"
  check "pick: it kills only that one" 1 "$([ -n "$(sid demo)" ] && echo 1 || echo 0)"
  "$AGENT" new demo --harness shell --name killview --no-attach >/dev/null
  if [ "$HAVE_PTY" = 0 ]; then
    skip "pick: kill takes the views with it" "script(1) is not available, so no pty for a tmux client"
  else
    env -u TMUX SSH_CLIENT="10.5.5.5 51000 22" timeout 60 script -qfc "$AGENT attach killview" /dev/null >/dev/null 2>&1 &
    kv_pid=$!
    if wait_until 15 have_session 'killview@1'; then
      AGENT_PICK_FILTER='kill session;killview' "$AGENT" pick >/dev/null 2>&1
      wait_until 15 no_session 'killview@1' \
        && ok "pick: kill takes the views with it" || bad "pick: kill takes the views with it" "$(names)"
      check "pick: the killed base is gone too" "" "$(sid killview)"
    else
      skip "pick: kill takes the views with it" "no pty client"
    fi
    "$AGENT" kill killview >/dev/null 2>&1 || true
    kill "$kv_pid" 2>/dev/null || true
    wait "$kv_pid" 2>/dev/null || true
  fi
  if [ "$HAVE_PTY" = 0 ]; then
    skip "pick: attaching" "script(1) is not available, so no pty for a tmux client"
  else
    # "mine" and not one of the worktree sessions: the kill cases above take those, and their worktrees, away.
    env -u TMUX SSH_CLIENT="10.7.7.7 51000 22" timeout 60 script -qfc "env AGENT_PICK_FILTER=mine $AGENT pick" "$T/pick1.pty" >/dev/null 2>&1 &
    pick_pid=$!
    if wait_until 15 have_session 'mine@1'; then
      ok "pick: choosing a session row creates a view of it"
      check "pick: the view carries the device" 10.7.7.7 "$("$AGENT" ls --porcelain | awk -F'\t' '$1=="mine"{print $8}')"
      tm detach-client -s 'mine@1'
    else
      bad "pick: choosing a session row creates a view of it" "sessions: $(names); pty: $(tr -d '\r' < "$T/pick1.pty" | tr -s '\n' ' ' | tail -c 300)"
    fi
    kill "$pick_pid" 2>/dev/null || true
    wait "$pick_pid" 2>/dev/null || true
    env -u TMUX SSH_CLIENT="10.6.6.6 51000 22" timeout 60 script -qfc "env AGENT_PICK_FILTER='new shell' $AGENT pick" "$T/pick2.pty" >/dev/null 2>&1 &
    pick_pid=$!
    if wait_until 15 have_session 'scratch@1'; then
      ok "pick: new shell creates a shell session and attaches to it"
      check "pick: the new shell is a shell harness" shell "$(opt scratch @harness)"
      check "pick: ls lists it as a shell in ~/workspace" "shell	-	-	$HOME/workspace" \
        "$("$AGENT" ls --porcelain | awk -F'\t' '$1=="scratch"{print $2"\t"$3"\t"$4"\t"$5}')"
      tm detach-client -s 'scratch@1'
    else
      bad "pick: new shell creates a shell session and attaches to it" "sessions: $(names); pty: $(tr -d '\r' < "$T/pick2.pty" | tr -s '\n' ' ' | tail -c 300)"
    fi
    kill "$pick_pid" 2>/dev/null || true
    wait "$pick_pid" 2>/dev/null || true
    # new session: repo and harness are the second and third filters of the flow. The slug prompt is
    # skipped under AGENT_PICK_FILTER, so this is the main checkout.
    env -u TMUX SSH_CLIENT="10.8.8.8 51000 22" timeout 60 \
      script -qfc "env AGENT_PICK_FILTER='new session;picked;shell' $AGENT pick" "$T/pick3.pty" >/dev/null 2>&1 &
    pick_pid=$!
    if wait_until 15 have_session 'picked@1'; then
      ok "pick: new session creates the session and attaches to it"
      check "pick: the new session runs in the repo, not in a worktree" "$HOME/workspace/picked" "$(opt picked @cwd)"
      tm detach-client -s 'picked@1'
    else
      bad "pick: new session creates the session and attaches to it" \
        "sessions: $(names); pty: $(tr -d '\r' < "$T/pick3.pty" | tr -s '\n' ' ' | tail -c 300)"
    fi
    kill "$pick_pid" 2>/dev/null || true
    wait "$pick_pid" 2>/dev/null || true
    "$AGENT" kill picked >/dev/null 2>&1 || true
  fi
fi
# The picker is the login landing, so a host without fzf has to say so rather than drop the operator nowhere.
nofzf=$(printf '%s' "$PATH" | tr ':' '\n' | while read -r d; do [ -x "$d/fzf" ] || printf '%s:' "$d"; done)
check "pick: without fzf on PATH, exit 2 and say so" 2 "$(PATH=$nofzf "$AGENT" pick >/dev/null 2>&1; echo $?)"
has "fzf is not installed" "$(PATH=$nofzf "$AGENT" pick 2>&1 || true)" "pick: without fzf, the message names fzf"

echo "# switch: the prefix-g popup moves a client between sessions"
if [ "$HAVE_FZF" = 0 ] || [ "$HAVE_PTY" = 0 ]; then
  skip "switch" "needs both fzf and a pty"
else
  # Inside tmux the view cannot be created attached, so `pick --switch` creates it detached, switches the
  # client to it and arms destroy-unattached, which then reaps the view the client came from. Driving it
  # through send-keys in an attached pane is the only way to exercise that from a script.
  "$AGENT" new demo --harness shell --name switchsrc --no-attach >/dev/null
  env -u TMUX SSH_CLIENT="10.4.4.4 51000 22" timeout 60 script -qfc "$AGENT attach switchsrc" /dev/null >/dev/null 2>&1 &
  sw_pid=$!
  if wait_until 15 have_session 'switchsrc@1'; then
    tm send-keys -t 'switchsrc@1' \
      "export PATH='$PATH' AGENT_TMUX_SOCKET='$AGENT_TMUX_SOCKET'; AGENT_PICK_FILTER=mine '$AGENT' pick --switch" Enter
    if wait_until 15 have_session 'mine@1'; then
      ok "switch: the client lands on a view of the chosen session"
      check "switch: that view holds the client" 1 "$(opt 'mine@1' session_attached)"
      # @device is only as good as SSH_CLIENT in the environment the picker runs in. `display-popup -E`
      # inherits the attached client's, which is the real path; send-keys types into a pane that kept the
      # environment it was created with, so only assert that a device was recorded.
      check "switch: a device is recorded on it" 1 "$([ -n "$(opt 'mine@1' @device)" ] && echo 1 || echo 0)"
      wait_until 15 no_session 'switchsrc@1' \
        && ok "switch: the view it came from is destroyed" || bad "switch: the view it came from is destroyed" "$(names)"
      check "switch: the session it came from survives" 1 "$([ -n "$(sid switchsrc)" ] && echo 1 || echo 0)"
      tm detach-client -s 'mine@1' 2>/dev/null || true
    else
      bad "switch: the client lands on a view of the chosen session" \
        "sessions: $(names); pane: $(tm capture-pane -p -t switchsrc 2>/dev/null | grep -v '^$' | tail -4 | tr '\n' '|')"
    fi
  else
    skip "switch" "no pty client"
  fi
  "$AGENT" kill switchsrc >/dev/null 2>&1 || true
  kill "$sw_pid" 2>/dev/null || true
  wait "$sw_pid" 2>/dev/null || true
fi

echo "# log out from the popup ends the login, not just the popup"
if [ "$HAVE_FZF" = 0 ] || [ "$HAVE_PTY" = 0 ]; then
  skip "popup log out" "needs both fzf and a pty"
else
  # The whole point of the case is the two process trees: a login shell sitting in `agent pick` (here a pty
  # running with a filter, so it attaches once and then blocks in the attach), and a picker started inside
  # tmux the way the prefix-g popup starts it. The second one detaches the first, and the first has to come
  # out of its loop with 3 (log out) instead of drawing the menu again.
  "$AGENT" new demo --harness shell --name outsrc --no-attach >/dev/null
  env -u TMUX SSH_CLIENT="10.9.9.9 51000 22" timeout 60 \
    script -qfc "env AGENT_PICK_FILTER=outsrc '$AGENT' pick; echo \$? > '$T/logout.rc'" "$T/logout.pty" >/dev/null 2>&1 &
  out_pid=$!
  if wait_until 15 have_session 'outsrc@1'; then
    tm send-keys -t 'outsrc@1' \
      "export PATH='$PATH' AGENT_TMUX_SOCKET='$AGENT_TMUX_SOCKET'; AGENT_PICK_FILTER='log out' '$AGENT' pick --switch" Enter
    wait_until 20 test -s "$T/logout.rc" \
      && check "popup log out: the login picker exits 3" 3 "$(tr -d ' \n' < "$T/logout.rc")" \
      || bad "popup log out: the login picker exits 3" \
             "picker still running; sessions: $(names); pane: $(tm capture-pane -p -t outsrc 2>/dev/null | grep -v '^$' | tail -4 | tr '\n' '|')"
    wait_until 15 no_session 'outsrc@1' \
      && ok "popup log out: the view is gone with the client" || bad "popup log out: the view is gone with the client" "$(names)"
    check "popup log out: the session it was attached to survives" 1 "$([ -n "$(sid outsrc)" ] && echo 1 || echo 0)"
    # Claimed, not left behind: a mark still in the server environment would log the next picker on that
    # tty straight out again.
    check "popup log out: the mark is claimed, not left in the environment" 0 \
      "$(tm show-environment -g 2>/dev/null | grep -c '^AGENT_LOGOUT_' || true)"
  else
    skip "popup log out" "no pty client"
  fi
  "$AGENT" kill outsrc >/dev/null 2>&1 || true
  kill "$out_pid" 2>/dev/null || true
  wait "$out_pid" 2>/dev/null || true
fi

echo "# switch: a session made from the popup runs behind it, not inside it"
if [ "$HAVE_FZF" = 0 ] || [ "$HAVE_PTY" = 0 ]; then
  skip "popup new session" "needs both fzf and a pty"
else
  # The real prefix-g binding, not send-keys: `display-popup -E` on the attached client, which is the only
  # way to catch a picker that attaches the new harness in the popup instead of switching the client behind
  # it. The popup closes when its command returns, so the marker file is how a script sees it close.
  "$AGENT" kill picked >/dev/null 2>&1 || true
  cat > "$T/popup-new.sh" <<POPUP
#!/bin/sh
export PATH='$PATH' AGENT_TMUX_SOCKET='$AGENT_TMUX_SOCKET'
AGENT_PICK_FILTER='new session;picked;shell' '$AGENT' pick --switch
echo closed > '$T/popup.closed'
POPUP
  chmod +x "$T/popup-new.sh"
  "$AGENT" new demo --harness shell --name popsrc --no-attach >/dev/null
  env -u TMUX SSH_CLIENT="10.3.3.3 51000 22" timeout 60 script -qfc "$AGENT attach popsrc" /dev/null >/dev/null 2>&1 &
  pop_pid=$!
  if wait_until 15 have_session 'popsrc@1'; then
    popup_client=$(tm list-clients -F '#{client_name}' -t 'popsrc@1' 2>/dev/null | head -1)
    tm display-popup -c "$popup_client" -E "$T/popup-new.sh" 2>/dev/null || true
    if wait_until 20 have_session 'picked@1'; then
      ok "popup: new session lands in the client behind the popup"
      check "popup: that view holds the client" 1 "$(opt 'picked@1' session_attached)"
      wait_until 20 test -e "$T/popup.closed" \
        && ok "popup: the picker returns, so the popup closes" \
        || bad "popup: the picker returns, so the popup closes" "no marker; sessions: $(names)"
      wait_until 15 no_session 'popsrc@1' \
        && ok "popup: the view it came from is destroyed" || bad "popup: the view it came from is destroyed" "$(names)"
      tm detach-client -s 'picked@1' 2>/dev/null || true
    else
      bad "popup: new session lands in the client behind the popup" \
        "sessions: $(names); pane: $(tm capture-pane -p -t popsrc 2>/dev/null | grep -v '^$' | tail -4 | tr '\n' '|')"
    fi
  else
    skip "popup new session" "no pty client"
  fi
  "$AGENT" kill picked >/dev/null 2>&1 || true
  "$AGENT" kill popsrc >/dev/null 2>&1 || true
  kill "$pop_pid" 2>/dev/null || true
  wait "$pop_pid" 2>/dev/null || true
fi

echo "# the login fragment runs the picker, and only for interactive ssh logins"
FRAG=$REPO/config/bashrc.d/tmux-autoattach.sh
cat > "$HOME/bin/agent" <<'STUB'
#!/bin/sh
echo "$@" >> "$HOME/agent.argv"
STUB
chmod +x "$HOME/bin/agent"
# land <shell> <interactive 0|1> <env...>: source the fragment and report what the stub agent was called with
land() {
  local sh=$1 i=$2; shift 2
  : > "$HOME/agent.argv"
  if [ "$i" = 1 ]; then env "$@" "$sh" -ic ". $FRAG" </dev/null >/dev/null 2>&1
  else env "$@" "$sh" -c ". $FRAG" </dev/null >/dev/null 2>&1; fi
  tr -d '\n' < "$HOME/agent.argv"
}
for sh in bash zsh; do
  if ! command -v "$sh" >/dev/null 2>&1; then skip "landing: $sh" "not installed"; continue; fi
  check "landing: $sh interactive ssh login runs the picker" pick \
    "$(land "$sh" 1 -u TMUX -u NO_TMUX SSH_TTY=/dev/pts/9)"
  check "landing: $sh non-interactive ssh command does not" "" \
    "$(land "$sh" 0 -u TMUX -u NO_TMUX SSH_TTY=/dev/pts/9)"
  check "landing: $sh interactive local shell does not" "" \
    "$(land "$sh" 1 -u TMUX -u NO_TMUX -u SSH_TTY)"
  check "landing: $sh inside tmux does not" "" \
    "$(land "$sh" 1 -u NO_TMUX SSH_TTY=/dev/pts/9 TMUX=/tmp/x,1,0)"
  check "landing: $sh NO_TMUX=1 does not" "" \
    "$(land "$sh" 1 -u TMUX SSH_TTY=/dev/pts/9 NO_TMUX=1)"
done
rm -f "$HOME/bin/agent"

pass=$(grep -c '^ok$' "$T/results"); fail=$(grep -c '^FAIL$' "$T/results")
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
