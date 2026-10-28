#!/usr/bin/env bash
# tests/e2e/web.sh: the web dashboard in real browsers. One container from Dockerfile.web (the pinned Playwright
# image, tmux, git, python3, jq, zsh) holds everything: the working tree copied to /work/repo, a throwaway HOME
# for the unprivileged login pwuser with the demo repo, the stand-in harnesses and the session `demo`
# (tests/e2e/web/fixture.sh setup), the server on 127.0.0.1:7690 under a supervisor the specs can restart
# (fixture.sh serve), and Playwright running tests/e2e/web/*.spec.mjs against it as the same login, so a spec
# can run `agent` on the very host the page shows (tests/e2e/web/helpers.mjs). The Tailscale-User-Login header
# that tailscale serve would add comes from Playwright's extraHTTPHeaders.
#
# Needs docker without sudo; network only for the image build. KEEP=1 leaves the container up ($E2E_NAME,
# default af-web-e2e; /work/server.log, /work/results). Set E2E_NAME to run two suites at once.
# SHOTS=<dir> also runs the screenshot pass and copies the PNGs there.
# Usage: bash tests/e2e/web.sh [filter...]   (passed to `playwright test`: a spec file name such as `paste`)
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
IMG=af-e2e-web; C=${E2E_NAME:-af-web-e2e}
T=$(mktemp -d)
say() { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
cleanup() {
  if [ "${KEEP:-0}" = 1 ]; then echo "KEEP=1: container $C left running"; else docker rm -f "$C" >/dev/null 2>&1 || true; fi
  rm -rf "$T"
}
trap cleanup EXIT

# The build context is the two npm files alone: the image changes with the pins, not with every edit.
say "image $IMG"
mkdir "$T/ctx"
cp "$REPO/web/package.json" "$REPO/web/package-lock.json" "$T/ctx/"
docker build -q -f "$REPO/tests/e2e/Dockerfile.web" -t "$IMG" "$T/ctx" >/dev/null || { echo "web image build failed" >&2; exit 1; }

say "container $C"
docker rm -f "$C" >/dev/null 2>&1 || true
# SHELL=/bin/sh is tmux's default-shell for `shell` sessions: zsh in an empty HOME opens its new-user menu.
docker run -d --name "$C" --init --ipc=host \
  -e HOME=/work/home -e SHELL=/bin/sh -e AGENT_TMUX_SOCKET=aw-e2e \
  -e AGENT_WEB_ALLOW=tester@example.test -e AGENT_WEB_PORT=7690 \
  -e AGENT_WEB_STATE=/work/state -e AGENT_WEB_FILES=/work/files -e CLIP_BRIDGE_SPOOL=/work/clip/latest \
  -e SHOTS="${SHOTS:+1}" \
  "$IMG" sleep infinity >/dev/null
docker exec "$C" sh -c 'mkdir -p /work/repo && chown -R pwuser:pwuser /work'
tar -C "$REPO" --exclude=.git --exclude=.env --exclude=./web/node_modules -cf - . \
  | docker exec -i -u pwuser "$C" tar -C /work/repo -xf -
docker exec -u pwuser "$C" sh -c 'ln -s /opt/web/node_modules /work/repo/web/node_modules && ln -s /opt/web/node_modules /work/repo/node_modules'

pw() { docker exec -u pwuser -w /work/repo "$C" "$@"; }
pw bash tests/e2e/web/fixture.sh setup >/dev/null
docker exec -d -u pwuser -w /work/repo "$C" bash tests/e2e/web/fixture.sh serve
pw bash tests/e2e/web/fixture.sh wait

say "playwright test $*"
status=0
pw node_modules/.bin/playwright test -c tests/e2e/web/playwright.config.mjs "$@" || status=$?

if [ -n "${SHOTS:-}" ]; then
  mkdir -p "$SHOTS"
  docker cp "$C:/work/shots/." "$SHOTS/" >/dev/null 2>&1 && say "screenshots in $SHOTS" || echo "no screenshots were taken" >&2
fi

counts=$(pw jq -r '.stats | "\(.expected) \(.unexpected + .flaky)"' /work/results/results.json 2>/dev/null || echo "0 1")
read -r pass fail <<< "$counts"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$status" = 0 ] && [ "$fail" = 0 ] && [ "$pass" -gt 0 ]
