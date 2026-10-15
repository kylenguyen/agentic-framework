# shellcheck shell=bash
# Sourced by tests/sim-test.sh after tests/sim/harness.sh; see its header.
# shellcheck disable=SC2015,SC2016,SC2030,SC2031,SC2154
echo "# syntax"
# Globs, so new bash files are checked without editing this list. bin/sim* skips non-bash files (*.mjs).
for f in "$SRC"/lib/sim.sh "$SRC"/bin/sim* "$SRC"/install-ios-runner.sh "$SRC"/tests/sim-test.sh "$SRC"/tests/sim/*.sh "$SRC"/config/sim/*.sh; do
  case $f in *.mjs|*.js) continue ;; esac
  f=${f#"$SRC"/}; bash -n "$SRC/$f" && ok "bash -n $f" || bad "bash -n $f"
done
[ -x "$SRC/bin/sim" ] && [ -x "$SRC/bin/sim-mcp" ] && ok "bin/sim and bin/sim-mcp are executable" || bad "executable bits"
