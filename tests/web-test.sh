#!/usr/bin/env bash
# tests/web-test.sh: unit and integration tests for the web dashboard (web/), run with node:test. No sudo or
# Docker; network only for the first `npm ci`. Each tests/web/*.test.mjs file runs in its own process with a
# throwaway HOME and its own tmux socket (tests/web/helpers.mjs), so the live server, tmux and ~/workspace are never
# touched. Exit 0 when all pass.
# Usage: bash tests/web-test.sh [pattern...]   (run only the test files whose name contains one of the patterns)
#
# web/node_modules is (re)installed from the lockfile when it is missing or older than web/package-lock.json, the
# same `npm ci --ignore-scripts` the host install runs. Add cases as new tests/web/<topic>.test.mjs files.
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WEB=$REPO/web

stamp=$WEB/node_modules/.package-lock.json            # npm rewrites it on every install
if [ ! -f "$stamp" ] || [ "$WEB/package-lock.json" -nt "$stamp" ]; then
  echo "# npm ci --ignore-scripts --prefix web"
  npm ci --ignore-scripts --no-audit --no-fund --prefix "$WEB" >/dev/null
fi

files=()
for f in "$REPO"/tests/web/*.test.mjs; do
  [ -e "$f" ] || continue
  if [ "$#" -eq 0 ]; then files+=("$f"); continue; fi
  for p in "$@"; do
    case ${f##*/} in *"$p"*) files+=("$f"); break ;; esac
  done
done
[ "${#files[@]}" -gt 0 ] || { echo "web-test: no tests/web file matches [$*]" >&2; exit 2; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
# spec for the reader, tap into a file for the counts.
status=0
node --test --test-reporter=spec --test-reporter-destination=stdout \
  --test-reporter=tap --test-reporter-destination="$T/tap" "${files[@]}" || status=$?

pass=$(sed -n 's/^# pass \([0-9]*\)$/\1/p' "$T/tap" | tail -1)
fail=$(sed -n 's/^# fail \([0-9]*\)$/\1/p' "$T/tap" | tail -1)
printf '\n%d passed, %d failed\n' "${pass:-0}" "${fail:-0}"
[ "$status" = 0 ] && [ "${fail:-0}" = 0 ] && [ -n "$pass" ]
