#!/usr/bin/env bash
# tests/e2e/web/fixture.sh: the throwaway host inside the tests/e2e/web.sh container, run as the unprivileged
# test login (pwuser) with the environment web.sh gives the container (HOME=/work/home, AGENT_TMUX_SOCKET,
# AGENT_WEB_*, SHELL=/bin/sh). The repo is at /work/repo.
#
#   setup   HOME with bin/ (agent and clip-put linked from the repo, the claude/codex/omp/opencode stand-ins of
#           tests/agent-test.sh), ~/workspace/demo (git, branch main, one commit) and the session `demo`
#           (harness claude, the stand-in), which the list spec expects to find.
#   serve   the server under a supervisor loop: node web/server.mjs, its pid in /work/server.pid, its output in
#           /work/server.log. When the server exits it is started again, so a spec restarts it by signalling
#           that pid (helpers.mjs restartServer). /work/stop ends the loop. web.sh runs this detached.
#   wait    until /api/health answers, at most 15 s.
set -euo pipefail
REPO=/work/repo
W=/work
BASE="http://127.0.0.1:${AGENT_WEB_PORT:-7690}"

case "${1:-}" in
  setup)
    mkdir -p "$HOME/bin" "$HOME/workspace/demo" "$AGENT_WEB_STATE" "$AGENT_WEB_FILES" "$(dirname "$CLIP_BRIDGE_SPOOL")"
    ln -sf "$REPO/bin/agent" "$HOME/bin/agent"
    ln -sf "$REPO/bin/clip-put" "$HOME/bin/clip-put"
    # A copy of sh rather than a link to sleep: coreutils is one multi-call binary that refuses another argv[0].
    cp "$(readlink -f /bin/sh)" "$HOME/bin/claude-proc"
    cat > "$HOME/bin/claude" <<'STANDIN'
#!/bin/sh
pwd > "$HOME/standin.cwd"
exec claude-proc -c 'read line'
STANDIN
    chmod 755 "$HOME/bin/claude"
    for h in codex omp opencode; do cp "$HOME/bin/claude" "$HOME/bin/$h"; done
    git -C "$HOME/workspace/demo" init -q -b main
    git -C "$HOME/workspace/demo" -c user.email=t@example -c user.name=t commit -q --allow-empty -m init
    git config --global user.email t@example
    git config --global user.name t
    agent new demo --harness claude --no-attach
    ;;
  serve)
    rm -f "$W/stop"
    while [ ! -e "$W/stop" ]; do
      node "$REPO/web/server.mjs" >> "$W/server.log" 2>&1 &
      echo "$!" > "$W/server.pid"
      wait "$!" || true
      sleep 0.2
    done
    ;;
  wait)
    for _ in $(seq 60); do
      if node -e 'fetch(process.argv[1], {headers: {"Tailscale-User-Login": process.env.AGENT_WEB_ALLOW}})
                   .then((r) => process.exit(r.ok ? 0 : 1), () => process.exit(1))' "$BASE/api/health"; then
        exit 0
      fi
      sleep 0.25
    done
    echo "fixture: the server did not come up; /work/server.log:" >&2
    tail -20 "$W/server.log" >&2 || true
    exit 1
    ;;
  *) echo "usage: fixture.sh setup|serve|wait" >&2; exit 2 ;;
esac
