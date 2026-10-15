# shellcheck shell=bash
# Sourced by tests/sim-test.sh after tests/sim/harness.sh; see its header.
# shellcheck disable=SC2015,SC2016,SC2030,SC2031,SC2154
echo "# JSON output, contract version, sim enable --check"
sim52() { "$REPO/bin/sim" "$@"; }
mkdir -p "$T/ws/j52" "$T/ws/j52b"
: > "$T/52.pids"

( lib
  out=$(sim52 version); rc=$?
  check "version: rc 0" 0 "$rc"
  check "version: the contract and the pins" "sim contract $SIM_CONTRACT_VERSION; maestro $SIM_MAESTRO_VERSION; mobile-mcp $SIM_MOBILE_MCP_VERSION; xcodebuildmcp $SIM_XCODEBUILDMCP_VERSION; playwright-mcp $SIM_PLAYWRIGHT_MCP_VERSION" "$out"
  sim52 version --json | jq -e --argjson c "$SIM_CONTRACT_VERSION" '.contract == $c and ($c == 2)' >/dev/null \
    && ok "version --json: .contract == 2" || bad "version --json: .contract == 2" "$(sim52 version --json 2>&1)"
  sim52 version --json | jq -e --arg m "$SIM_MAESTRO_VERSION" --arg mm "$SIM_MOBILE_MCP_VERSION" --arg x "$SIM_XCODEBUILDMCP_VERSION" --arg pw "$SIM_PLAYWRIGHT_MCP_VERSION" \
    '.maestro == $m and .["mobile-mcp"] == $mm and .xcodebuildmcp == $x and .["playwright-mcp"] == $pw' >/dev/null \
    && ok "version --json: the pins" || bad "version --json: the pins" "$(sim52 version --json 2>&1)"
  sim52 version --yaml >/dev/null 2>&1; check "version: an unknown flag is a usage error" 2 "$?"
)

# A slot's object from sim status --json: every key, of its type.
status_shape='type == "array" and length == 5 and all(.[];
  (keys == ["device", "idle_secs", "lease", "platform", "slot", "state", "tunnel"])
  and (.platform | type == "string") and (.slot | type == "number")
  and (.device | type == "string" or type == "null") and (.state | type == "string" or type == "null")
  and (.idle_secs | type == "number" or type == "null") and (.tunnel | type == "array" and all(.[]; type == "number"))
  and (.lease == null or (.lease | (keys == ["kind", "pid", "root", "since", "until"]) and (.kind | IN("mcp", "cli"))
       and (.pid | type == "number") and (.root | type == "string") and (.since | type == "string")
       and (.until | type == "number" or type == "null"))))'

( cd "$T/ws/j52" || exit 1; rm -rf "$T/state/web" "$T/state/android"; rm -f "$T/state/ios/1.tunnel"; lib
  out=$(sim52 status --json); rc=$?
  check "status --json: rc 0" 0 "$rc"
  jq -e "$status_shape" <<<"$out" >/dev/null && ok "status --json: shape" || bad "status --json: shape" "$out"
  check "status --json: nothing leased, every lease null" 0 "$(jq '[.[] | select(.lease != null)] | length' <<<"$out")"
  check "status --json: web has no device or state" "null null" "$(jq -r '[.[] | select(.platform == "web")][0] | "\(.device) \(.state)"' <<<"$out")"
  check "status --json: android device and unit state" "emulator-5600 $(systemctl --user is-active agent-sim-android@1.service)" "$(jq -r '.[0] | "\(.device) \(.state)"' <<<"$out")"
  sim52 status --yaml >/dev/null 2>&1; check "status: an unknown flag is a usage error" 2 "$?"

  hold web "$T/ws/j52" 30; holder=$!; echo "$holder" >> "$T/52.pids"
  wait_for "sim_held web 1"
  sim52 lease android --ttl 5m >/dev/null 2>&1
  sim_touch web 1
  printf 'pid=%s\nports=22000,22001\nroot=%s\n' "$$" "$T/ws/j52" > "$T/state/ios/1.tunnel"
  out=$(sim52 status --json)
  jq -e "$status_shape" <<<"$out" >/dev/null && ok "status --json with leases: shape" || bad "status --json with leases: shape" "$out"
  check "status --json: mcp lease, no end" "mcp $T/ws/j52 null" "$(jq -r '.[] | select(.platform == "web" and .slot == 1) | .lease | "\(.kind) \(.root) \(.until)"' <<<"$out")"
  check "status --json: mcp lease pid" "$(sim_owner_field web 1 pid)" "$(jq -r '.[] | select(.platform == "web" and .slot == 1) | .lease.pid' <<<"$out")"
  check "status --json: cli lease ends" "cli number" "$(jq -r '.[] | select(.platform == "android" and .slot == 1) | .lease | "\(.kind) \(.until | type)"' <<<"$out")"
  check "status --json: idle seconds of a used slot" number "$(jq -r '.[] | select(.platform == "web" and .slot == 1) | .idle_secs | type' <<<"$out")"
  check "status --json: ios tunnel ports" "[22000,22001]" "$(jq -c '.[] | select(.platform == "ios") | .tunnel' <<<"$out")"
  has "status: text unchanged" "leased mcp pid $(sim_owner_field web 1 pid) $T/ws/j52" "$(sim52 status | grep '^web      1')"
  has "status: text tunnel" "tunnel 22000,22001" "$(sim52 status | grep '^ios      1')"
  rm -f "$T/state/ios/1.tunnel"

  out=$(sim52 ports web --json); rc=$?
  check "ports --json: rc 0" 0 "$rc"
  check "ports --json: base and count" "{\"base\":$(sim_port_base web 1),\"count\":$SIM_PORT_BLOCK}" "$(jq -c . <<<"$out")"
  mkdir -p .sim; echo 'ports = 3' > .sim/config
  check "ports --json: count from .sim/config" 3 "$(sim52 ports web --json | jq .count)"
  rm -rf .sim
  sim52 ports web --json 3 >/dev/null 2>&1; check "ports --json: one argument" 2 "$?"
  out=$(cd "$T/ws/j52b" && sim52 ports web --json 2>&1); rc=$?
  check "ports --json without a lease: rc 1 as before" 1 "$rc"

  sim52 release android >/dev/null 2>&1
  out=$(sim52 lease android --ttl 5m --json); rc=$?
  check "lease --json: rc 0" 0 "$rc"
  jq -e --arg r "$T/ws/j52" '(keys == ["platform", "root", "slot", "until"]) and .platform == "android" and .slot == 1
    and .root == $r and (.until | type == "number") and .until > now' <<<"$out" >/dev/null \
    && ok "lease --json: shape" || bad "lease --json: shape" "$out"
  check "lease --json again: the same lease" "$out" "$(sim52 lease android --json)"
  check "lease --json of an mcp lease: no end" "web 1 null" "$(sim52 lease web --json | jq -r '"\(.platform) \(.slot) \(.until)"')"
  sim52 lease android --ttl 0m --json >/dev/null 2>&1; check "lease --json: bad --ttl still rc 2" 2 "$?"
  sim52 release android >/dev/null 2>&1
  kill "$holder" 2>/dev/null; pkill -P "$holder" 2>/dev/null; wait
)

# sim doctor --json: the host lines and the web browser check, with stand-ins of their own.
( cd "$T/ws/j52" || exit 1; lib
  mkdir -p "$T/52/proc" "$T/52/bin" "$T/52/prefix/node_modules/.bin"
  printf 'MemAvailable:   12000000 kB\n' > "$T/52/proc/meminfo"; echo '0.50 0.40 0.30 1/200 999' > "$T/52/proc/loadavg"
  printf '#!/bin/sh\necho "Filesystem 1024-blocks Used Available Capacity Mounted"\necho "/dev/x 1 1 52428800 50%% /"\n' > "$T/52/bin/df"
  printf '#!/bin/sh\nprintf "  Install location:    %%s\\n" "%s/52/pw/chromium-1"\n' "$T" > "$T/52/prefix/node_modules/.bin/playwright"
  chmod +x "$T/52/bin/df" "$T/52/prefix/node_modules/.bin/playwright"
  export SIM_PROC=$T/52/proc SIM_PREFIX=$T/52/prefix PATH="$T/52/bin:$PATH"
  shape='type == "array" and length > 0 and all(.[]; (keys == ["check", "detail", "level", "platform", "slot"])
    and (.level | IN("ok", "warn", "fail")) and (.check | type == "string") and (.detail | type == "string")
    and (if .platform == "host" then .slot == null else (.slot | type == "number") end))'
  out=$(sim52 doctor web all --json); rc=$?
  check "doctor --json: a fail is still rc 1" 1 "$rc"
  jq -e "$shape" <<<"$out" >/dev/null && ok "doctor --json: shape" || bad "doctor --json: shape" "$out"
  check "doctor --json: host lines have slot null" "host null" "$(jq -r '.[] | select(.check == "memory") | "\(.platform) \(.slot)"' <<<"$out")"
  check "doctor --json: the browsers line per slot" "fail web 1,fail web 2" "$(jq -r '[.[] | select(.check == "browsers") | "\(.level) \(.platform) \(.slot)"] | join(",")' <<<"$out")"
  lacks "doctor --json: no text lines" "ok    host" "$out"
  mkdir -p "$T/52/pw/chromium-1"
  out=$(sim52 doctor --json web all); rc=$?
  check "doctor --json: healthy is rc 0, flag anywhere" 0 "$rc"
  jq -e "$shape" <<<"$out" >/dev/null && ok "doctor --json healthy: shape" || bad "doctor --json healthy: shape" "$out"
  has "doctor: text unchanged" "ok    web     1  browsers       chromium-1" "$(sim52 doctor web all)"
  sim52 doctor web all extra --json >/dev/null 2>&1; check "doctor --json: still a usage error with three arguments" 2 "$?"
)

( out=$(sim52 enable --print-agents); rc=$?
  lib
  check "print-agents: rc 0" 0 "$rc"
  check "print-agents: opens with the contract marker" "<!-- sim-contract: $SIM_CONTRACT_VERSION -->" "$(head -1 <<<"$out")"
  check "print-agents: closes with the end marker" "<!-- /sim-contract -->" "$(tail -1 <<<"$out")"
  for w in "## Simulators" "sim lease <android|web|ios>" "sim release" "sim ports <platform>" "sim tunnel ios" "--forward" \
           "sim metro start" "--env K=V" "latest" "sim doctor" "--fresh" "--cold" "Exit code 3" "retry later" \
           'never run `maestro` or `expo run:*` directly'; do
    has "print-agents: $w" "$w" "$out"
  done
  lacks "print-agents: no npx expo" "npx expo" "$out"
  has "enable: prints the section with markers" "$out" "$(cd "$T/ws/j52b" && sim52 enable 2>/dev/null)"
  rm -rf "$T/ws/j52b/.mcp.json" "$T/ws/j52b/opencode.json" "$T/ws/j52b/.codex" "$T/ws/j52b/.sim"
  sim52 enable --print-agents "$T/ws/j52" >/dev/null 2>&1; check "print-agents: takes no directory" 2 "$?"
  sim52 enable --print-agents --check >/dev/null 2>&1; check "print-agents and --check: usage error" 2 "$?"
  sim52 enable --check "$T/ws/none" >/dev/null 2>&1; check "check: no such directory is a usage error" 2 "$?"
  sim52 enable --check --only tv "$T/ws/j52" >/dev/null 2>&1; check "check: unknown platform is a usage error" 2 "$?"
)

# --check on a fresh repo: enable, paste the section, then each kind of staleness. Nothing is ever written.
c52=$T/ws/c52
mkdir -p "$c52" && git -C "$c52" init -q
snap() { find "$c52" -path "$c52/.git" -prune -o -printf '%p %s %T@\n' | sort; }
( cd "$c52" || exit 1; lib
  sim52 enable >/dev/null 2>&1
  { printf '# Repo\n\nSome rules.\n\n'; sim52 enable --print-agents; printf '\n## Other\n\nMore.\n'; } > AGENTS.md
  # Old mtimes, so a write within this second would still show.
  find "$c52" -path "$c52/.git" -prune -o -exec touch -h -d '2026-01-01 00:00' {} +
  before=$(snap)
  out=$(sim52 enable --check 2>&1); rc=$?
  check "check fresh: rc 0" 0 "$rc"
  has "check fresh: says so" "up to date" "$out"
  check "check fresh: from a subdirectory with a dir argument" 0 "$(cd /; sim52 enable --check "$c52" >/dev/null 2>&1; echo $?)"
  jq -c . .mcp.json > "$T/52.m" && cp "$T/52.m" .mcp.json && touch -d '2026-01-01 00:00' .mcp.json
  before=$(snap)
  check "check: other JSON formatting is no difference" 0 "$(sim52 enable --check >/dev/null 2>&1; echo $?)"

  cp AGENTS.md "$T/52.agents"
  sed -i "s/^<!-- sim-contract: $SIM_CONTRACT_VERSION -->\$/<!-- sim-contract: 1 -->/" AGENTS.md; touch -d '2026-01-01 00:00' AGENTS.md
  before2=$(snap)
  out=$(sim52 enable --check 2>&1); rc=$?
  check "check contract 1: rc 1" 1 "$rc"
  has "check contract 1: says so" "contract 1, current $SIM_CONTRACT_VERSION" "$out"
  check "check contract 1: wrote nothing" "$before2" "$(snap)"

  sed -n '/^<!-- sim-contract/,/^<!-- \/sim-contract/p' "$T/52.agents" | sed '1d;$d' > AGENTS.md; touch -d '2026-01-01 00:00' AGENTS.md
  out=$(sim52 enable --check 2>&1); rc=$?
  check "check unmarked section: rc 1" 1 "$rc"
  has "check unmarked section: contract 1" "contract 1, current $SIM_CONTRACT_VERSION" "$out"

  sed 's/^- Web: `sim metro start web` serves the app/- Web: serve it yourself/' "$T/52.agents" > AGENTS.md; touch -d '2026-01-01 00:00' AGENTS.md
  out=$(sim52 enable --check 2>&1); rc=$?
  check "check edited body: rc 1" 1 "$rc"
  has "check edited body: a diff" "+- Web: \`sim metro start web\` serves the app" "$out"
  has "check edited body: the removed line" "-- Web: serve it yourself" "$out"
  has "check edited body: diff headers" "+++ sim enable --print-agents" "$out"

  printf '# Repo\n' > AGENTS.md; touch -d '2026-01-01 00:00' AGENTS.md
  out=$(sim52 enable --check 2>&1); rc=$?
  check "check no section: rc 1" 1 "$rc"
  has "check no section: says so" "no sim-contract section" "$out"
  cp "$T/52.agents" AGENTS.md; touch -d '2026-01-01 00:00' AGENTS.md

  jq 'del(.mcpServers["sim-ios"])' "$T/52.m" > .mcp.json; touch -d '2026-01-01 00:00' .mcp.json
  before2=$(snap)
  out=$(sim52 enable --check 2>&1); rc=$?
  check "check .mcp.json missing sim-ios: rc 1" 1 "$rc"
  has "check .mcp.json missing sim-ios: names the file" ".mcp.json: not the entries" "$out"
  has "check .mcp.json missing sim-ios: the diff adds it" '+    "sim-ios": {' "$out"
  has "check .mcp.json missing sim-ios: sim-ios in the diff" '"sim-ios"' "$out"
  check "check .mcp.json missing sim-ios: wrote nothing" "$before2" "$(snap)"
  cp "$T/52.m" .mcp.json; touch -d '2026-01-01 00:00' .mcp.json

  cp .codex/config.toml "$T/52.codex"; sed -i 's/^tool_timeout_sec = 300$/tool_timeout_sec = 60/' .codex/config.toml
  out=$(sim52 enable --check 2>&1); rc=$?
  check "check stale codex block: rc 1" 1 "$rc"
  has "check stale codex block: the diff" "+tool_timeout_sec = 300" "$out"
  cp "$T/52.codex" .codex/config.toml; touch -d '2026-01-01 00:00' .codex/config.toml

  rm opencode.json
  out=$(sim52 enable --check 2>&1); rc=$?
  check "check missing opencode.json: rc 1" 1 "$rc"
  has "check missing opencode.json: says so" "opencode.json: missing" "$out"
  sim52 enable >/dev/null 2>&1; touch -d '2026-01-01 00:00' opencode.json .mcp.json .codex/config.toml

  cp .sim/config "$T/52.cfg"; echo 'ports = 500' >> .sim/config
  out=$(sim52 enable --check 2>&1); rc=$?
  check "check bad .sim/config: rc 1" 1 "$rc"
  has "check bad .sim/config: names the line" ".sim/config:" "$out"
  cp "$T/52.cfg" .sim/config; touch -d '2026-01-01 00:00' .sim/config

  before=$(snap)
  check "check restored: rc 0" 0 "$(sim52 enable --check >/dev/null 2>&1; echo $?)"
  check "check: never writes, mtimes unchanged" "$before" "$(snap)"
)

( mkdir -p "$T/ws/c52b" && cd "$T/ws/c52b" || exit 1
  sim52 enable --only android,web >/dev/null 2>&1; sim52 enable --print-agents > AGENTS.md
  check "check --only android,web: as enabled, rc 0" 0 "$(sim52 enable --check --only android,web >/dev/null 2>&1; echo $?)"
  out=$(sim52 enable --check 2>&1); rc=$?
  check "check without --only: sim-ios missing, rc 1" 1 "$rc"
  has "check without --only: names .mcp.json" ".mcp.json: not the entries" "$out"
)

while read -r p; do [ -n "$p" ] && { kill "$p" 2>/dev/null; pkill -P "$p" 2>/dev/null; }; done < "$T/52.pids"
( lib
  for pl in android web; do for n in 1 2; do
    sim_held "$pl" "$n" && [ "$(sim_owner_field "$pl" "$n" kind)" = cli ] && kill "$(sim_owner_field "$pl" "$n" pid)" 2>/dev/null
  done; done; true )
