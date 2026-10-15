# shellcheck shell=bash
# Sourced by tests/sim-test.sh after tests/sim/harness.sh; see its header.
# shellcheck disable=SC2015,SC2016,SC2030,SC2031,SC2154
echo "# remote paths"
( lib
  h6() { printf %s "$1" | sha256sum | cut -c1-6; }
  a=$(sim_tree_name "$T/ws/app"); b=$(sim_tree_name "$T/ws/app.wt/feat")
  [ "${a##*-}" != "${b##*-}" ] && ok "tree name: a checkout and its worktree hash apart" \
    || bad "tree name: a checkout and its worktree hash apart" "$a $b"
  check "tree name: <base>-<first 6 of sha256(root)>" "app-$(h6 "$T/ws/app")" "$a"
  a=$(sim_tree_name /x/one/app); b=$(sim_tree_name /x/two/app)
  [ "$a" != "$b" ] && ok "tree name: two roots with one basename differ" || bad "tree name: two roots with one basename differ" "$a"
  a=$(sim_tree_name /w/foo.wt/bar); b=$(sim_tree_name /w/foo-bar)
  [ "$a" != "$b" ] && ok "tree name: foo.wt/bar and a repo foo-bar differ" || bad "tree name: foo.wt/bar and a repo foo-bar differ" "$a"
  check "tree name: anything outside [A-Za-z0-9._-] becomes _" "it_s_my_app-feat.2-$(h6 "/w/it's my app.wt/feat.2")" \
    "$(sim_tree_name "/w/it's my app.wt/feat.2")"
  check "mac path: the top of the worktree" "sims/app-$(h6 "$T/ws/app")" "$(sim_mac_path "$T/ws/app" .)"
  check "mac path: an app inside it" "sims/app-$(h6 "$T/ws/app")/o'k app" "$(sim_mac_path "$T/ws/app" "o'k app")"
  check "mac dir: quoted for a remote shell" "sims/app-$(h6 "$T/ws/app")/o\\'k\\ app" "$(sim_mac_dir "$T/ws/app" "o'k app")"
  check "mac dir: bash reads it back" "sims/app-$(h6 "$T/ws/app")/o'k app" "$(bash -c "printf %s $(sim_mac_dir "$T/ws/app" "o'k app")")"
  if command -v zsh >/dev/null; then
    check "mac dir: so does zsh, the Mac's login shell" "sims/x-$(h6 /r/x)/a b'c"$'\t'"d" \
      "$(zsh -c "printf %s $(sim_mac_dir /r/x "a b'c"$'\t'"d")")"
  else ok "mac dir: so does zsh (no zsh here; the e2e covers it)"; fi
)
# A worktree whose path and app directory have a space and a ': every remote command gets the quoted path.
mkdir -p "$T/ws/my app/o'k app" && git -C "$T/ws/my app" init -q
( cd "$T/ws/my app/o'k app" || exit 1; rm -f "$T/log/"*
  tree=sims/my_app-$(printf %s "$T/ws/my app" | sha256sum | cut -c1-6)
  "$REPO/bin/sim" ios sync >/dev/null 2>&1
  has "sync: makes the tree and touches its stamp first" "mkdir -p $tree && touch $tree/.agent-sim-synced" "$(head -1 "$T/log/ssh")"
  r=$(cat "$T/log/rsync")
  has "sync: the stamp survives --delete" "--filter=P .agent-sim-synced" "$r"
  has "sync: from the root with its space, to the hashed tree" "$T/ws/my app/ bob@mini.tail.ts.net:$tree/" "$r"
  hold ios "$T/ws/my app" 30; holder=$!
  wait_for "( lib; sim_held ios 1 )"
  rm -f "$T/log/"*
  "$REPO/bin/sim" maestro ios test flows/ >/dev/null 2>&1
  has "maestro ios: a quoted cd into the app" "cd $tree/o\\'k\\ app && " "$(grep sim-maestro "$T/log/ssh")"
  "$REPO/bin/sim" metro start ios >/dev/null 2>&1
  has "metro start ios: a quoted cd" "cd $tree/o\\'k\\ app && (pkill" "$(grep 'expo start' "$T/log/ssh")"
  "$REPO/bin/sim" metro log ios >/dev/null 2>&1
  has "metro log ios: a quoted path" "tail -n 100 $tree/o\\'k\\ app/.metro.log" "$(grep 'tail -n 100' "$T/log/ssh")"
  "$REPO/bin/sim" ios prepare >/dev/null 2>&1
  has "ios prepare: a quoted cd" "cd $tree/o\\'k\\ app && npm ci" "$(grep 'npm ci' "$T/log/ssh")"
  has "ios prepare: a quoted workspace lookup" "ls -d \$HOME/$tree/o\\'k\\ app/ios/*.xcworkspace" "$(grep 'ls -d' "$T/log/ssh")"
  kill "$holder" 2>/dev/null; pkill -P "$holder" 2>/dev/null; wait
)
# gc goes by the sync stamp. Its command, run here in a fake home under sh and zsh (the Mac's login shell).
( cd "$T/ws/app" || exit 1; rm -f "$T/log/"*
  "$REPO/bin/sim" ios gc 7 >/dev/null 2>&1
  cmd=$(cat "$T/log/ssh")
  has "ios gc: reads the sync stamp" ".agent-sim-synced" "$cmd"
  # The ssh shim logs its options and destination before the command.
  cmd=${cmd#*bob@mini.tail.ts.net }
  for sh in sh zsh; do
    command -v "$sh" >/dev/null || { ok "ios gc under $sh: (no $sh here)"; continue; }
    g=$T/gc-$sh; rm -rf "$g"; mkdir -p "$g/sims/fresh" "$g/sims/stale" "$g/sims/legacy" "$g/sims/legacy-new" "$g/sims/my app"
    touch "$g/sims/fresh/.agent-sim-synced"; touch -d '10 days ago' "$g/sims/fresh"
    touch -d '10 days ago' "$g/sims/stale/.agent-sim-synced"
    touch -d '10 days ago' "$g/sims/legacy" "$g/sims/my app"
    out=$(cd "$g" && HOME=$g "$sh" -c "$cmd" 2>&1)
    check "ios gc under $sh: keeps what was synced or made lately" "fresh legacy-new" "$(find "$g/sims" -mindepth 1 -maxdepth 1 -printf "%f\n" | sort | paste -sd' ')"
    has "ios gc under $sh: says what it removed" "sims/stale" "$out"
    rm -rf "$g/sims"; out=$(cd "$g" && HOME=$g "$sh" -c "$cmd" 2>&1); rc=$?
    check "ios gc under $sh: no sims directory is fine" 0 "$rc"
  done
)
