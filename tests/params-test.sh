#!/usr/bin/env bash
# tests/params-test.sh: checks for lib/params.sh and every rendered template. No network, no sudo, nothing written
# outside a temp dir, so it is safe on the live host, in a container and on a Mac (bash 3.2). Exit 0 when all pass.
# Usage: bash tests/params-test.sh
# A && ok || bad is the intended pattern and cases run in subshells on purpose:
# shellcheck disable=SC2015,SC2016,SC2030,SC2031
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
: > "$T/results"                                   # one line per case; cases run in subshells, so no counters
ok()    { echo ok >> "$T/results"; printf 'ok   %s\n' "$1"; }
bad()   { echo FAIL >> "$T/results"; printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }   # check <name> <expected> <actual>
# fresh: start a case with no parameters set and the library loaded. Run inside ( ) so cases do not leak.
fresh() { unset AGENT_HOST AGENT_HOST_ADDRESS AGENT_HOST_USER AGENT_HOST_LAN_IP AGENT_HOST_LAN_CIDR; . "$REPO/lib/params.sh"; }
# expect_fail <name> <cmd...>: the command must return non-zero and print something on stderr
expect_fail() { local n=$1; shift; local err; if err=$("$@" 2>&1 >/dev/null); then bad "$n" "succeeded, expected failure"; else
  if [ -n "$err" ]; then ok "$n"; else bad "$n" "failed silently"; fi; fi; }

echo "# syntax"
for f in lib/params.sh tests/params-test.sh; do bash -n "$REPO/$f" && ok "bash -n $f" || bad "bash -n $f"; done

echo "# params_load"
( fresh
  printf 'AGENT_HOST=box\nAGENT_HOST_USER="alice"\n\n# c\nAGENT_HOST_LAN_CIDR=10.1.0.0/16\n' > "$T/env1"
  params_load "$T/env1" || bad "load env1" "returned $?"
  check "load: plain value" box "$AGENT_HOST"
  check "load: quoted value" alice "$AGENT_HOST_USER"
  check "load: cidr" 10.1.0.0/16 "$AGENT_HOST_LAN_CIDR"
  check "load: unset stays empty" "" "${AGENT_HOST_LAN_IP:-}"
)
( fresh; AGENT_HOST=pre; printf 'AGENT_HOST=file\n' > "$T/env2"; params_load "$T/env2"; check "load: environment beats file" pre "$AGENT_HOST" )
( fresh; params_load "$T/does-not-exist" && ok "load: missing file is fine" || bad "load: missing file" )
( fresh; printf 'AGENT_HOST=a b\n' > "$T/bad1"; expect_fail "load: rejects space in value" params_load "$T/bad1" )
( fresh; printf 'OTHER=1\n' > "$T/bad2"; expect_fail "load: rejects foreign key" params_load "$T/bad2" )
( fresh; printf 'AGENT_HOST_NOPE=1\n' > "$T/bad3"; expect_fail "load: rejects unknown AGENT_ key" params_load "$T/bad3" )
( fresh; printf 'AGENT_HOST=$(id)\n' > "$T/bad4"; expect_fail "load: rejects shell syntax" params_load "$T/bad4" )
( fresh; printf 'x\nAGENT_HOST=a;b\n' > "$T/bad5"; err=$(params_load "$T/bad5" 2>&1); case "$err" in *bad5:1:*) ok "load: names the line";; *) bad "load: names the line" "$err";; esac )

echo "# validators"
( fresh
  params_is_user alice && ok "user: alice" || bad "user: alice"
  params_is_user "alice smith" && bad "user: rejects space" || ok "user: rejects space"
  params_is_user "a@b" && bad "user: rejects @" || ok "user: rejects @"
  params_is_name box && ok "name: box" || bad "name: box"
  params_is_name "a/b" && bad "name: rejects /" || ok "name: rejects /"
  params_is_addr box.tail.ts.net && ok "addr: fqdn" || bad "addr: fqdn"
  params_is_ipv4 192.168.1.2 && ok "ipv4: ok" || bad "ipv4: ok"
  params_is_ipv4 256.1.1.1 && bad "ipv4: rejects 256" || ok "ipv4: rejects 256"
  params_is_cidr 192.168.1.0/24 && ok "cidr: ok" || bad "cidr: ok"
  params_is_cidr 192.168.1.0/33 && bad "cidr: rejects /33" || ok "cidr: rejects /33"
  params_is_cidr 192.168.1.0 && bad "cidr: rejects no prefix" || ok "cidr: rejects no prefix"
  params_is_private_cidr 10.0.0.0/8 && ok "private: 10/8" || bad "private: 10/8"
  params_is_private_cidr 172.31.0.0/16 && ok "private: 172.31" || bad "private: 172.31"
  params_is_private_cidr 172.32.0.0/16 && bad "private: rejects 172.32" || ok "private: rejects 172.32"
  params_is_private_cidr 8.8.8.0/24 && bad "private: rejects 8.8.8.0" || ok "private: rejects 8.8.8.0"
  AGENT_HOST_USER="two words"; expect_fail "validate: names the bad parameter" params_validate
  AGENT_HOST_USER=alice; AGENT_HOST=box; params_validate && ok "validate: good set" || bad "validate: good set"
  AGENT_HOST_USER=; expect_fail "require: unset parameter" params_require AGENT_HOST AGENT_HOST_USER
  params_require AGENT_HOST && ok "require: set parameter" || bad "require: set parameter"
)

echo "# params_render"
( fresh; AGENT_HOST=box; AGENT_HOST_ADDRESS=box.tail.ts.net; AGENT_HOST_USER=alice; AGENT_HOST_LAN_IP=10.0.0.5; AGENT_HOST_LAN_CIDR=10.0.0.0/24
  printf 'Host @AGENT_HOST@ @AGENT_HOST@-clip\n  HostName @AGENT_HOST_ADDRESS@\n  User @AGENT_HOST_USER@\n  ControlPath ~/.ssh/cm-%%r@%%h:%%p\n  # @AGENT_HOST_LAN_IP@ @AGENT_HOST_LAN_CIDR@\n' > "$T/t.in"
  params_render "$T/t.in" "$T/t.out" || bad "render: returns 0" "$?"
  check "render: repeated placeholder" "Host box box-clip" "$(sed -n 1p "$T/t.out")"
  check "render: address" "  HostName box.tail.ts.net" "$(sed -n 2p "$T/t.out")"
  check "render: user" "  User alice" "$(sed -n 3p "$T/t.out")"
  check "render: ssh tokens untouched" '  ControlPath ~/.ssh/cm-%r@%h:%p' "$(sed -n 4p "$T/t.out")"
  check "render: ip and cidr" "  # 10.0.0.5 10.0.0.0/24" "$(sed -n 5p "$T/t.out")"
  check "render: to stdout" "Host box box-clip" "$(params_render "$T/t.in" - | head -1)"
  printf 'x @AGENT_HOST_NOPE@\n' > "$T/u.in"; expect_fail "render: unknown placeholder fails" params_render "$T/u.in" "$T/u.out"
  [ -e "$T/u.out" ] && bad "render: nothing written on failure" || ok "render: nothing written on failure"
  AGENT_HOST_LAN_IP=; expect_fail "render: empty value fails" params_render "$T/t.in" "$T/v.out"
  expect_fail "render: missing template fails" params_render "$T/none.in" "$T/w.out"
)

echo "# params_derive_host"
( fresh; AGENT_HOST_USER=someone-else; expect_fail "derive: refuses a different login in .env" params_derive_host )
( fresh; params_derive_host >/dev/null 2>&1 || bad "derive: returns 0" "$?"
  check "derive: user is the caller" "$(id -un)" "$AGENT_HOST_USER"
  check "derive: alias is hostname -s" "$(hostname -s)" "$AGENT_HOST"
  [ -n "$AGENT_HOST_ADDRESS" ] && ok "derive: address set ($AGENT_HOST_ADDRESS)" || bad "derive: address set"
  if command -v ip >/dev/null && ip -o -4 route show default 2>/dev/null | grep -q .; then
    params_is_cidr "$AGENT_HOST_LAN_CIDR" && ok "derive: lan cidr ($AGENT_HOST_LAN_CIDR)" || bad "derive: lan cidr" "$AGENT_HOST_LAN_CIDR"
    dev=$(ip -o -4 route show default | awk '{for (i=1;i<NF;i++) if ($i=="dev") {print $(i+1); exit}}')
    ip -o -4 addr show dev "$dev" | grep -q " inet $AGENT_HOST_LAN_IP/" && ok "derive: lan ip is on the default-route interface ($AGENT_HOST_LAN_IP)" \
      || bad "derive: lan ip" "$AGENT_HOST_LAN_IP not on $dev"
  else
    echo "skip derive: lan route (no ip route here)"
  fi
  params_env_text > "$T/env.txt"
  check "env_text: five parameters" 5 "$(grep -c '^AGENT_HOST' "$T/env.txt")"
  ( fresh; params_load "$T/env.txt" && params_validate && ok "env_text: loads back cleanly" || bad "env_text: loads back" )
)
( fresh; AGENT_HOST_LAN_CIDR=10.9.0.0/16; AGENT_HOST=custom; params_derive_host >/dev/null 2>&1
  check "derive: .env cidr override wins" 10.9.0.0/16 "$AGENT_HOST_LAN_CIDR"; check "derive: .env alias wins" custom "$AGENT_HOST" )

echo "# host templates: sshd, ufw"
( fresh; AGENT_HOST_USER=alice
  params_render "$REPO/config/sshd/10-hardening.conf.in" "$T/sshd" || bad "sshd: renders" "$?"
  check "sshd: exactly one AllowUsers line" 1 "$(grep -c '^AllowUsers ' "$T/sshd")"
  check "sshd: AllowUsers is the given login" "AllowUsers alice" "$(grep '^AllowUsers ' "$T/sshd")"
  grep -q '@' "$T/sshd" && bad "sshd: no @ left (sshd reads user@host in AllowUsers)" || ok "sshd: no @ left in the rendered file"
  installed=/etc/ssh/sshd_config.d/10-hardening.conf
  if [ -r "$installed" ]; then   # on a configured host the template must reproduce what is installed, directives only
    ( fresh; params_derive_host >/dev/null 2>&1; params_render "$REPO/config/sshd/10-hardening.conf.in" "$T/sshd2"
      d() { grep -v '^[[:space:]]*#' "$1" | sed '/^[[:space:]]*$/d'; }
      check "sshd: rendered for $(id -un) matches the installed drop-in" "$(d "$installed")" "$(d "$T/sshd2")" )
  else echo "skip sshd: no installed drop-in to compare with"; fi
)
( fresh
  out=$(bash "$REPO/config/ufw.sh" 2>&1); rc=$?
  check "ufw: no argument exits 2 before touching ufw" 2 "$rc"; case "$out" in usage:*) ok "ufw: prints usage";; *) bad "ufw: prints usage" "$out";; esac
  out=$(bash "$REPO/config/ufw.sh" --dry-run 10.0.0.0 2>&1); check "ufw: rejects a bare address" 2 "$?"
  out=$(bash "$REPO/config/ufw.sh" --dry-run 10.1.2.0/24 2>&1) || bad "ufw: dry run exits 0" "$out"
  check "ufw: dry run prints six commands" 6 "$(printf '%s\n' "$out" | grep -c '^ufw ')"
  check "ufw: LAN rule carries the given range" 1 "$(printf '%s\n' "$out" | grep -c "^ufw allow from 10.1.2.0/24 to any port 22 proto tcp")"
  printf '%s\n' "$out" | grep -q '^ufw --force enable$' && ok "ufw: enables" || bad "ufw: enables" "$out"
)

echo "# Mac templates: ssh config, clip-push, install-mac.sh entry"
( fresh; AGENT_HOST=box; AGENT_HOST_ADDRESS=box.tail.ts.net; AGENT_HOST_USER=alice; AGENT_HOST_LAN_IP=10.0.0.5
  params_ssh_config_text > "$T/sshcfg" || bad "sshcfg: renders" "$?"
  grep -q '^#' "$T/sshcfg" && bad "sshcfg: comments stripped" || ok "sshcfg: comments stripped"
  g() { ssh -G -F "$T/sshcfg" "$1" 2>/dev/null | grep -E "^$2 " | cut -d' ' -f2-; }
  check "sshcfg: ssh box -> hostname" box.tail.ts.net "$(g box hostname)"
  check "sshcfg: ssh box -> user" alice "$(g box user)"
  check "sshcfg: ssh box -> forwardagent off" no "$(g box forwardagent)"
  check "sshcfg: box-lan -> hostname is the LAN address" 10.0.0.5 "$(g box-lan hostname)"
  check "sshcfg: box-lan -> user" alice "$(g box-lan user)"
  check "sshcfg: box-clip -> hostname" box.tail.ts.net "$(g box-clip hostname)"
  check "sshcfg: box-clip -> batchmode" yes "$(g box-clip batchmode)"
  check "sshcfg: box-clip -> controlmaster" auto "$(g box-clip controlmaster)"
  check "sshcfg: box-clip -> connecttimeout" 3 "$(g box-clip connecttimeout)"
  # shellcheck disable=SC2088
  check "sshcfg: box-clip -> controlpath keeps ssh tokens" '~/.ssh/cm-%r@%h:%p' "$(grep ControlPath "$T/sshcfg" | awk '{print $2}')"
  check "sshcfg: three Host paragraphs" 3 "$(grep -c '^Host ' "$T/sshcfg")"
  AGENT_HOST_LAN_IP=; params_ssh_config_text > "$T/sshcfg2" || bad "sshcfg: renders without LAN" "$?"
  check "sshcfg: no LAN address -> two Host paragraphs" 2 "$(grep -c '^Host ' "$T/sshcfg2")"
  grep -q 'box-lan' "$T/sshcfg2" && bad "sshcfg: no LAN -> -lan paragraph gone" || ok "sshcfg: no LAN -> -lan paragraph gone"
  check "sshcfg: no LAN -> box still resolves" box.tail.ts.net "$(ssh -G -F "$T/sshcfg2" box 2>/dev/null | awk '/^hostname /{print $2}')"
)
( fresh; AGENT_HOST=box
  params_render "$REPO/bin/clip-push-mac.sh.in" "$T/clip-push" || bad "clip-push: renders" "$?"
  bash -n "$T/clip-push" && ok "clip-push: bash -n on the rendered script" || bad "clip-push: bash -n"
  grep -q 'host=${CLIP_PUSH_HOST:-box-clip}' "$T/clip-push" && ok "clip-push: default destination is <alias>-clip" || bad "clip-push: default destination" "$(grep 'host=' "$T/clip-push")"
)
( # install-mac.sh must settle its parameters before it touches anything, so its entry is testable anywhere.
  mkdir -p "$T/repo" "$T/home"; cp -R "$REPO/install-mac.sh" "$REPO/lib" "$REPO/config" "$REPO/bin" "$T/repo/"; rm -f "$T/repo/.env"
  out=$(HOME=$T/home bash "$T/repo/install-mac.sh" </dev/null 2>&1); rc=$?
  check "install-mac: no .env and no terminal -> exit 2" 2 "$rc"
  case "$out" in *"AGENT_HOST is not set"*) ok "install-mac: says what is missing";; *) bad "install-mac: says what is missing" "$out";; esac
  check "install-mac: wrote nothing to HOME" "" "$(ls -A "$T/home")"
  [ -e "$T/repo/.env" ] && bad "install-mac: did not write .env" || ok "install-mac: did not write .env"
  printf 'AGENT_HOST=box\nAGENT_HOST_USER=alice\n' > "$T/repo/.env"
  out=$(HOME=$T/home PATH=/usr/bin:/bin bash "$T/repo/install-mac.sh" </dev/null 2>&1 || true)
  case "$out" in *'Parameters: `ssh box` is alice@box'*) ok "install-mac: .env read, address defaults to the alias";; *) bad "install-mac: .env read" "$out";; esac
  case "$out" in *"box-lan"*) bad "install-mac: no -lan alias without a LAN address" "$out";; *) ok "install-mac: no -lan alias without a LAN address";; esac
  printf 'AGENT_HOST_USER=bad user\n' > "$T/repo/.env"
  HOME=$T/home bash "$T/repo/install-mac.sh" </dev/null >/dev/null 2>&1; check "install-mac: malformed .env -> exit 1" 1 "$?"
)

echo "# WezTerm module and a Linux dry run of install-mac.sh"
( fresh; AGENT_HOST=box; AGENT_HOST_ADDRESS=box.tail.ts.net; AGENT_HOST_USER=alice
  params_render "$REPO/config/wezterm-agent-host.lua.in" "$T/wez.lua" || bad "wezterm: renders" "$?"
  check "wezterm: HOST constant" 'local HOST = "box"' "$(grep '^local HOST' "$T/wez.lua")"
  check "wezterm: remote_address" 1 "$(grep -c 'remote_address = "box.tail.ts.net"' "$T/wez.lua")"
  check "wezterm: username" 1 "$(grep -c 'username = "alice"' "$T/wez.lua")"
  grep -q '"agent-host"\|example.ts.net' "$T/wez.lua" && bad "wezterm: no .env.example values" "$(grep -n '"agent-host"\|example.ts.net' "$T/wez.lua")" || ok "wezterm: no .env.example values"
  check "wezterm: balanced function/end" "$(grep -c '^end$' "$T/wez.lua")" "$(grep -c '^\(local \)\?function ' "$T/wez.lua")"
)
( # Everything in install-mac.sh up to the ssh probes runs on Linux against a throwaway HOME once brew is stubbed;
  # the probes then fail (box does not resolve) and the script exits 1. HOME starts with a user's own ssh config and a
  # wezterm.lua without the include, so the block-append and insert-before-return paths are exercised.
  mkdir -p "$T/mac/repo" "$T/mac/home/.ssh" "$T/mac/home/.config/wezterm" "$T/mac/bin"
  cp -R "$REPO/install-mac.sh" "$REPO/lib" "$REPO/config" "$REPO/bin" "$T/mac/repo/"
  printf 'AGENT_HOST=aftest.invalid\nAGENT_HOST_ADDRESS=box.invalid\nAGENT_HOST_USER=alice\nAGENT_HOST_LAN_IP=10.0.0.5\n' > "$T/mac/repo/.env"
  printf '#!/bin/sh\nexit 0\n' > "$T/mac/bin/brew"; chmod +x "$T/mac/bin/brew"
  printf 'Host other\n  User me\n' > "$T/mac/home/.ssh/config"
  printf 'local wezterm = require("wezterm")\nlocal cfg = wezterm.config_builder()\nreturn cfg\n' > "$T/mac/home/.config/wezterm/wezterm.lua"
  out=$(HOME=$T/mac/home PATH="$T/mac/bin:$PATH" bash "$T/mac/repo/install-mac.sh" </dev/null 2>&1); rc=$?
  check "dry run: exits 1 at the unreachable host, not earlier" 1 "$rc"
  case "$out" in *"aftest.invalid (box.invalid) is not reachable"*) ok "dry run: reached the login phase";; *) bad "dry run: reached the login phase" "$out";; esac
  cfg=$T/mac/home/.ssh/config
  check "dry run: one agent-host block" 1 "$(grep -c '^# >>> agentic-framework:agent-host >>>$' "$cfg")"
  check "dry run: user's own Host kept" 1 "$(grep -c '^Host other$' "$cfg")"
  check "dry run: ssh -G aftest.invalid -> alice@box.invalid" "box.invalid alice" "$(ssh -G -F "$cfg" aftest.invalid 2>/dev/null | awk '/^hostname /{h=$2} /^user /{u=$2} END{print h, u}')"
  check "dry run: ssh -G aftest.invalid-lan -> LAN address" 10.0.0.5 "$(ssh -G -F "$cfg" aftest.invalid-lan 2>/dev/null | awk '/^hostname /{print $2}')"
  wez=$T/mac/home/.config/wezterm
  check "dry run: module rendered with the alias" 'local HOST = "aftest.invalid"' "$(grep '^local HOST' "$wez/wezterm-agent-host.lua")"
  check "dry run: require line inserted before return" 'require("wezterm-agent-host").apply(cfg)' "$(grep require\(\"wezterm- "$wez/wezterm.lua")"
  check "dry run: require line sits right before the return" 'return cfg' "$(grep -A1 require\(\"wezterm- "$wez/wezterm.lua" | tail -1)"
  [ -e "$wez/wezterm.lua.before-agent-host" ] && ok "dry run: backup kept" || bad "dry run: backup kept"
  grep -q 'host=${CLIP_PUSH_HOST:-aftest.invalid-clip}' "$T/mac/home/.local/bin/clip-push" && ok "dry run: clip-push installed and rendered" || bad "dry run: clip-push" "$(ls -la "$T/mac/home/.local/bin" 2>&1)"
  [ -x "$T/mac/home/.local/bin/clip-push" ] && ok "dry run: clip-push executable" || bad "dry run: clip-push executable"
  [ -f "$T/mac/home/.ssh/id_ed25519" ] && ok "dry run: key generated" || bad "dry run: key generated"
  out2=$(HOME=$T/mac/home PATH="$T/mac/bin:$PATH" bash "$T/mac/repo/install-mac.sh" </dev/null 2>&1 || true)
  check "dry run: second run leaves one agent-host block" 1 "$(grep -c 'agentic-framework:agent-host >>>' "$cfg")"
  case "$out2" in *"wezterm.lua includes wezterm-agent-host"*) ok "dry run: second run sees the include";; *) bad "dry run: second run sees the include" "$out2";; esac
)

echo "# no deployment literals anywhere in the repo"
( # The repo describes a framework, not one deployment: no file, comment or doc may name a real host, login, LAN or
  # tailnet. Placeholders in the docs are <host>, <user>, <lan-ip>, <lan-cidr>; the tests use box, alice and 10.x.
  # Add a word here when a deployment value slips in and gets fixed, so it cannot come back. This file is skipped
  # because it carries the list; .env is the one place the real values belong.
  cd "$REPO" || exit 1
  words='as1|kyle|kylepc|macbook|manee-goby|192\.168\.10\.'
  hits=$(grep -rnwE --exclude-dir=.git --exclude=.env --exclude=params-test.sh "$words" . || true)
  [ -z "$hits" ] && ok "scan: no deployment literals in scripts, templates, configs or docs" || bad "scan: deployment literals found" "$hits"
  # .env.example values are examples too: they may appear only there.
  ex=$(grep -rnw --exclude-dir=.git --exclude=.env --exclude=.env.example --exclude=params-test.sh 'agent-host\.example\.ts\.net\|192\.168\.1\.10' . || true)
  [ -z "$ex" ] && ok "scan: .env.example values appear only in .env.example" || bad "scan: .env.example values leaked" "$ex"
  left=$(grep -rln '@AGENT_[A-Z_]*@' bin config lib install-host.sh install-mac.sh | grep -v -e '\.in$' -e '^lib/' || true)   # two -e: BSD grep misreads $\|
  [ -z "$left" ] && ok "scan: placeholders only in .in templates and lib" || bad "scan: placeholders outside templates" "$left"
)

pass=$(grep -c '^ok$' "$T/results"); fail=$(grep -c '^FAIL$' "$T/results")
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
