# shellcheck shell=bash
# Sourced by tests/sim-test.sh after tests/sim/harness.sh; see its header.
# shellcheck disable=SC2015,SC2016,SC2030,SC2031,SC2154
echo "# sim enable"
( cd "$T/ws/app.wt/feat" || exit 1
  printf '{"mcpServers": {"other": {"command": "x"}}}\n' > .mcp.json
  printf 'model = "m"\n\n[projects.x]\ntrust_level = "trusted"\n' > "$T/codex-before"; mkdir -p .codex; cp "$T/codex-before" .codex/config.toml
  out=$("$REPO/bin/sim" enable 2>&1) || bad "enable: exits 0" "$out"
  check "enable: .mcp.json keeps other servers" x "$(jq -r '.mcpServers.other.command' .mcp.json)"
  check "enable: .mcp.json sim-ios" '["ios"]' "$(jq -c '.mcpServers["sim-ios"].args' .mcp.json)"
  check "enable: .mcp.json command is the bare name" sim-mcp "$(jq -r '.mcpServers["sim-web"].command' .mcp.json)"
  check "enable: opencode.json sim-android" '["sim-mcp","android"]' "$(jq -c '.mcp["sim-android"].command' opencode.json)"
  check "enable: codex servers" 3 "$(grep -c '^\[mcp_servers\.sim-' .codex/config.toml)"
  check "enable: codex waits long enough for a boot" 3 "$(grep -c '^tool_timeout_sec = 300$' .codex/config.toml)"
  has "enable: codex keeps the rest" 'trust_level = "trusted"' "$(cat .codex/config.toml)"
  has "enable: prints the AGENTS.md section" "## Simulators" "$out"
  cp .mcp.json "$T/m1"; cp .codex/config.toml "$T/c1"
  "$REPO/bin/sim" enable >/dev/null 2>&1
  cmp -s .mcp.json "$T/m1" && cmp -s .codex/config.toml "$T/c1" && ok "enable: second run changes nothing" || bad "enable: second run changes nothing" "$(diff "$T/c1" .codex/config.toml)"
  "$REPO/bin/sim" enable --only web >/dev/null 2>&1
  check "enable --only web: one codex server" 1 "$(grep -c '^\[mcp_servers\.sim-' .codex/config.toml)"
  lacks "enable: no host or login in the files" "mini.tail" "$(cat .mcp.json opencode.json .codex/config.toml)"
  echo '{bad' > opencode.json
  "$REPO/bin/sim" enable >/dev/null 2>&1 && bad "enable: refuses invalid JSON" || ok "enable: refuses invalid JSON"
  "$REPO/bin/sim" enable --only tv >/dev/null 2>&1; check "enable: unknown platform is a usage error" 2 "$?"
)
