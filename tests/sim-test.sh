#!/usr/bin/env bash
# tests/sim-test.sh: unit tests for lib/sim.sh, bin/sim and bin/sim-mcp. No network, sudo, emulator, browser or Mac:
# the scripts run from a copy of the repo in a temp dir (so the checkout's .env cannot leak in), with shims for
# systemctl, ssh and node that record what they were asked to do. Safe on the live host. Exit 0 when all pass.
# Usage: bash tests/sim-test.sh [pattern]   (pattern: run only tests/sim/NN-*.sh files whose name contains it)
#
# Layout: this file is only the runner. tests/sim/harness.sh holds the setup (temp repo copy, shims, ok/bad/check/
# has/lacks, lib, hold, wait_for) and is always sourced first. Then each tests/sim/NN-<topic>.sh is sourced in name
# order into the same shell, so all share $T and $T/results. Cases run in subshells so state does not leak.
# To add cases, add a new NN-<topic>.sh (copy the three header lines of an existing one) rather than growing a
# shared file. Numbers: 10 syntax, 20 params, 30 ports, 40 leases, 50 enable, 60 sim-mcp, 70 commands,
# 80 maestro, 90 reap. Reserved by the sim-service plan: 31 mac-health, 32 remote-paths, 41 lease-cli, 42 ports,
# 43 tunnel, 51 repo-config, 52 json-check, 61 relay, 62 ios-reconnect, 71 metro, 81 maestro-runs, 91 doctor.
# Otherwise pick a free number next to the section the new file belongs with.
set -u
TESTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sim
compgen -G "$TESTS/[0-9]*.sh" | grep -q -- "${1:-}" \
  || { echo "sim-test: no tests/sim file matches [${1:-}]" >&2; exit 2; }
# shellcheck source=tests/sim/harness.sh
. "$TESTS/harness.sh"
for sim_test_file in "$TESTS"/[0-9]*.sh; do
  case ${sim_test_file##*/} in *"${1:-}"*) ;; *) continue ;; esac
  # shellcheck disable=SC1090
  . "$sim_test_file"
done

pass=$(grep -c '^ok$' "$T/results"); fail=$(grep -c '^FAIL$' "$T/results")
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
