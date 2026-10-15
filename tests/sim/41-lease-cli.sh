# shellcheck shell=bash
# Sourced by tests/sim-test.sh after tests/sim/harness.sh; see its header.
# shellcheck disable=SC2015,SC2016,SC2030,SC2031,SC2154
echo "# CLI leases, sticky slots, takeover, own session"
# Every process these cases leave running is in $T/41.pids or is a CLI holder in an owner file; the last block of
# this file kills them all, whatever failed before it. Leases use --ttl 5m, so a holder that escapes still ends.
mkdir -p "$T/ws/la" "$T/ws/lb" "$T/ws/lc" "$T/ws/ld" "$T/ws/le" "$T/ws/lf" "$T/ws/lg"
: > "$T/41.pids"
sim41() { "$REPO/bin/sim" "$@"; }

( cd "$T/ws/app" || exit 1; rm -rf "$T/state/web" "$T/state/android"; lib
  out=$(sim41 lease web --ttl 5m 2>&1); rc=$?
  check "lease cli: rc 0" 0 "$rc"
  has "lease cli: says slot, root and end" "web slot 1 leased for $T/ws/app until " "$out"
  has "lease cli: says how to free it" "(sim release web)" "$out"
  has "status: CLI lease with its end" "leased cli until " "$(sim41 status | grep '^web      1')"
  check "lease cli: my slot finds it" 1 "$(sim_my_slot web "$T/ws/app")"
  out=$(sim41 lease web --ttl 5m 2>&1); rc=$?
  check "lease cli again: rc 0" 0 "$rc"
  has "lease cli again: same slot" "web slot 1 already leased" "$out"
  sim_held web 2 && bad "lease cli again: one holder" "slot 2 held" || ok "lease cli again: one holder"
  out=$(sim41 release web 2>&1); rc=$?
  check "release: rc 0" 0 "$rc"
  has "release: says so" "web slot 1 released" "$out"
  sim_held web 1 && bad "release: slot free" || ok "release: slot free"
  out=$(sim41 release web 2>&1); rc=$?
  check "release with no lease: rc 0" 0 "$rc"
  has "release with no lease: says so" "nothing to release" "$out"
  sim41 lease android --ttl 5m >/dev/null 2>&1
  has "lease cli: sim env finds the slot" "ANDROID_SERIAL=emulator-5600" "$(sim41 env 2>&1)"
  sim41 release android >/dev/null 2>&1
  sim_held android 1 && bad "release android: slot free" || ok "release android: slot free"
  out=$(cd "$T/ws/lf" && sim41 env 2>&1)
  has "my slot message: names sim lease" "or sim lease android" "$out"
)

( cd "$T/ws/la" || exit 1
  for t in 0m 9d x 8 -1h; do
    sim41 lease web --ttl "$t" >/dev/null 2>&1; check "lease --ttl $t: usage error" 2 "$?"
  done
)

( rm -rf "$T/state/web"; lib
  sim41 lease web --ttl 5m "$T/ws/lb" >/dev/null 2>&1
  sim41 lease web --ttl 5m "$T/ws/la" >/dev/null 2>&1
  check "sticky: B got slot 1" 1 "$(sim_my_slot web "$T/ws/lb")"
  check "sticky: A got slot 2" 2 "$(sim_my_slot web "$T/ws/la")"
  out=$(sim41 lease web --ttl 5m "$T/ws/lc" 2>&1); rc=$?
  check "lease cli: all slots taken is rc 3" 3 "$rc"
  has "lease cli: all taken lists the holders" "$T/ws/la" "$out"
  sim41 release web "$T/ws/la" >/dev/null 2>&1; sim41 release web "$T/ws/lb" >/dev/null 2>&1
  sim41 lease web --ttl 5m "$T/ws/la" >/dev/null 2>&1
  check "sticky: A leasing first gets its slot 2 back" 2 "$(sim_my_slot web "$T/ws/la")"
  sim41 lease web --ttl 5m "$T/ws/lb" >/dev/null 2>&1
  check "sticky: then B gets its slot 1 back" 1 "$(sim_my_slot web "$T/ws/lb")"
  sim41 release web "$T/ws/la" >/dev/null 2>&1; sim41 release web "$T/ws/lb" >/dev/null 2>&1
  sim41 lease web --ttl 5m "$T/ws/lb" >/dev/null 2>&1; sim41 lease web --ttl 5m "$T/ws/la" >/dev/null 2>&1
  check "sticky: B then A keeps A on 2" 2 "$(sim_my_slot web "$T/ws/la")"
  sim41 release web "$T/ws/la" >/dev/null 2>&1; sim41 release web "$T/ws/lb" >/dev/null 2>&1
  [ -s "$T/state/web/last/$(sim_root_key "$T/ws/la")" ] && ok "sticky: last file per root" || bad "sticky: last file per root"
)

# Takeover: a server group left by the previous holder. setsid -f, so the stand-in is not this shell's child and is
# reaped as soon as it dies (a zombie would still answer kill -0).
( rm -rf "$T/state/web"; mkdir -p "$T/state/web"; lib
  setsid -f sh -c 'echo $$ > "$1"; exec sleep 300' sh "$T/41.left" </dev/null >/dev/null 2>&1
  wait_for '[ -s "$T/41.left" ]'; left=$(cat "$T/41.left"); echo "$left" >> "$T/41.pids"
  wait_for "kill -0 -- -$left 2>/dev/null" && ok "takeover: stand-in server group up" || bad "takeover: stand-in server group up"
  echo "$left" > "$T/state/web/1.pgid"
  err=$( (sim_lease web "$T/ws/lc") 2>&1 >/dev/null)
  has "takeover: says what it stopped" "sim: stopped a server left by the slot's previous holder (pgid $left)" "$err"
  wait_for "! kill -0 $left 2>/dev/null" && ok "takeover: old server gone" || bad "takeover: old server gone"
  [ -e "$T/state/web/1.pgid" ] && bad "takeover: pgid file removed" || ok "takeover: pgid file removed"
  echo "$$" > "$T/state/web/1.pgid"; err=$( (sim_lease web "$T/ws/lc") 2>&1 >/dev/null)
  check "takeover: never its own group" "" "$err"
)

# Own session: two stand-in harnesses in one worktree, each with a holder (its child) of a web slot. On a go file,
# each asks sim_my_slot from a child process of its own.
( rm -rf "$T/state/web"; lib
  harness41() { # harness41 <tag>
    bash -c '
      TAG=$1 ROOT=$2 REPO=$3 T=$4; export ROOT REPO
      ( echo "$BASHPID" >> "$T/41.pids"; . "$REPO/lib/sim.sh"; sim_load_params
        sim_lease web "$ROOT" && echo "$SIM_SLOT" > "$T/41.slot.$TAG" && exec sleep 300 ) &
      h=$!
      for i in $(seq 1 100); do [ -e "$T/41.go.$TAG" ] && break; sleep 0.1; done
      bash -c ". \"\$REPO/lib/sim.sh\"; sim_load_params; sim_my_slot web \"\$ROOT\"" > "$T/41.mine.$TAG.new"
      mv "$T/41.mine.$TAG.new" "$T/41.mine.$TAG"
      kill "$h"; wait' harness41 "$1" "$T/ws/ld" "$REPO" "$T" &
    echo "$!" >> "$T/41.pids"
  }
  harness41 1; wait_for '[ -s "$T/41.slot.1" ]'
  harness41 2; wait_for '[ -s "$T/41.slot.2" ]'
  check "own session: first holder on slot 1" 1 "$(cat "$T/41.slot.1" 2>/dev/null)"
  check "own session: second holder on slot 2" 2 "$(cat "$T/41.slot.2" 2>/dev/null)"
  check "own session: an outsider gets the lowest" 1 "$(sim_my_slot web "$T/ws/ld")"
  touch "$T/41.go.2" "$T/41.go.1"
  wait_for '[ -e "$T/41.mine.2" ] && [ -e "$T/41.mine.1" ]'
  check "own session: the second session's child gets slot 2" 2 "$(cat "$T/41.mine.2" 2>/dev/null)"
  check "own session: the first session's child gets slot 1" 1 "$(cat "$T/41.mine.1" 2>/dev/null)"
  wait
)

( rm -rf "$T/state/web"; lib
  ( sim_lease web "$T/ws/le" cli $(($(date +%s) - 10)) && exec sleep 300 ) & h=$!; echo "$h" >> "$T/41.pids"
  wait_for 'sim_held web 1'
  has "status: expired CLI lease still shown" "leased cli until" "$(sim41 status | grep '^web      1')"
  out=$(sim41 reap 2>&1)
  has "reap: expired CLI lease ended" "web 1: CLI lease expired" "$out"
  wait_for '! sim_held web 1' && ok "reap: expired slot free" || bad "reap: expired slot free"
  wait
  sim41 lease web --ttl 5m "$T/ws/le" >/dev/null 2>&1
  out=$(sim41 reap 2>&1)
  lacks "reap: a CLI lease with time left stays" "CLI lease expired" "$out"
  sim_held web 1 && ok "reap: that slot still held" || bad "reap: that slot still held"
  sim41 release web "$T/ws/le" >/dev/null 2>&1
)

( rm -rf "$T/state/web"; lib
  hold web "$T/ws/lf" 30; holder=$!; echo "$holder" >> "$T/41.pids"
  wait_for 'sim_held web 1'
  has "status: MCP lease with its pid" "leased mcp pid " "$(sim41 status | grep '^web      1')"
  out=$(cd "$T/ws/lf" && sim41 release web 2>&1); rc=$?
  check "release of an MCP lease: rc 1" 1 "$rc"
  has "release of an MCP lease: says who holds it" "held by the sim-web MCP server (pid" "$out"
  has "release of an MCP lease: says how to free it" "end that harness session to free it" "$out"
  sim_held web 1 && ok "release of an MCP lease: slot kept" || bad "release of an MCP lease: slot kept"
  kill "$holder" 2>/dev/null; pkill -P "$holder" 2>/dev/null; wait
)

# The owner file is replaced whole: read it 100 times while another process leases slot 1 over and over.
( rm -rf "$T/state/web" "$T/41.stop"; lib
  ( echo "$BASHPID" >> "$T/41.pids"
    while [ ! -e "$T/41.stop" ]; do sim_lease web "$T/ws/lg" cli 4000000000 2>/dev/null && exec {SIM_LOCK_FD}>&-; done ) & w=$!
  wait_for '[ -e "$T/state/web/1.owner" ]'
  torn=0
  for _ in $(seq 1 100); do
    c=$(cat "$T/state/web/1.owner")
    case $c in pid=*$'\n'ppid=*$'\n'root=*$'\n'since=*$'\n'kind=cli$'\n'until=4000000000) ;; *) torn=$((torn + 1)) ;; esac
  done
  kill -0 "$w" 2>/dev/null && ok "owner file: writer was leasing throughout" || bad "owner file: writer was leasing throughout"
  check "owner file: never torn in 100 reads" 0 "$torn"
  touch "$T/41.stop"; wait
  ls "$T/state/web"/.*.owner.* >/dev/null 2>&1 && bad "owner file: no temp files left" || ok "owner file: no temp files left"
)

# Cleanup, whatever happened above: every recorded process, every CLI holder still holding a slot.
( lib
  while read -r p; do [ -n "$p" ] && { kill "$p" 2>/dev/null; pkill -P "$p" 2>/dev/null; }; done < "$T/41.pids"
  for o in "$T"/state/*/[0-9].owner; do
    [ -e "$o" ] || continue
    pl=$(basename "$(dirname "$o")"); n=$(basename "$o" .owner)
    sim_held "$pl" "$n" && [ "$(sim_owner_field "$pl" "$n" kind)" = cli ] && kill "$(sim_owner_field "$pl" "$n" pid)" 2>/dev/null
  done
  rm -rf "$T"/41.* "$T/state/web" "$T/state/android"
  true
)
