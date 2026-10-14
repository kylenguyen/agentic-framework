#!/bin/bash
# install-ios-runner.sh: the iOS half of the device simulation service, on the Mac, as its dedicated runner login.
# Idempotent, no sudo, macOS /bin/bash 3.2. Normally piped over ssh by `sim ios bootstrap` on the host, which passes
# the versions below from lib/sim.sh; it can also be run on the Mac directly with the same variables.
# Installs into the runner's home only: mise, Node 22, Ruby 3.4 (precompiled), CocoaPods, XcodeBuildMCP, Java 17 and
# Maestro; simulators agent-ios-1..N; ~/sims for synced worktrees; the stdio launcher bin/sim-mcp runs over ssh, and
# the Maestro launcher `sim maestro ios` runs. Xcode itself, its
# licence and first-launch step, and the iOS runtime are the admin's job and are only checked here.
set -eu
: "${SIM_XCODEBUILDMCP_VERSION:?set by sim ios bootstrap}" "${SIM_IOS_SLOTS:=2}"
: "${SIM_MAESTRO_VERSION:?set by sim ios bootstrap}" "${SIM_MAESTRO_SHA256:?set by sim ios bootstrap}"
: "${SIM_IOS_DEVICE_TYPE:=com.apple.CoreSimulator.SimDeviceType.iPhone-17}"
: "${SIM_IOS_WORKFLOWS:=simulator,ui-automation,project-discovery,utilities}"
say()  { printf '==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
fail() { printf '!!  %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || fail "run this on the Mac"
[ "$(id -u)" != 0 ] || fail "run as the runner login, not root"
if id -Gn | tr ' ' '\n' | grep -qx admin; then note "warning: $(id -un) is an admin; a dedicated non-admin login is safer"; fi

say "Xcode"
xcode-select -p >/dev/null 2>&1 || fail "no Xcode selected: an admin runs sudo xcode-select -s /Applications/Xcode.app"
xcodebuild -checkFirstLaunchStatus || fail "Xcode first launch is pending: an admin runs sudo xcodebuild -runFirstLaunch"
xcodebuild -version | head -1 | sed 's/^/    /'
RUNTIME=$(xcrun simctl list runtimes available | awk '/^iOS /{id=$NF} END{print id}')
[ -n "$RUNTIME" ] || fail "no iOS simulator runtime: install one from Xcode > Settings > Components"
note "runtime $RUNTIME"

say "Disk"
FREE_GB=$(df -g "$HOME" | awk 'NR==2 {print $4}')
note "${FREE_GB} GB free"
[ "$FREE_GB" -ge 15 ] || fail "under 15 GB free; builds and simulators need room (sim ios gc, or free space as an admin)"

say "PATH for ssh commands (~/.zshenv block)"
BEGIN='# >>> agentic-framework:sim >>>'; END='# <<< agentic-framework:sim <<<'
touch "$HOME/.zshenv"
TMP=$(mktemp)
awk -v b="$BEGIN" -v e="$END" '$0==b {skip=1; next} $0==e {skip=0; next} !skip' "$HOME/.zshenv" > "$TMP"
{ cat "$TMP"; printf '%s\n%s\n%s\n' "$BEGIN" 'export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"' "$END"; } > "$HOME/.zshenv"
rm -f "$TMP"
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"

say "Toolchains: mise, Node 22, Ruby 3.4, Java 17, CocoaPods, XcodeBuildMCP $SIM_XCODEBUILDMCP_VERSION"
mkdir -p "$HOME/.local/bin"
command -v mise >/dev/null || curl -fsSL https://mise.run | MISE_INSTALL_PATH="$HOME/.local/bin/mise" sh
# Precompiled Ruby: compiling needs Homebrew's openssl, which a non-admin cannot install. Java is for Maestro.
MISE_RUBY_COMPILE=false mise use -g -y node@22 ruby@3.4 java@temurin-17
mise reshim
command -v pod >/dev/null || { gem install cocoapods --no-document; mise reshim; }
note "pod $(pod --version)"
if [ "$(xcodebuildmcp --version 2>/dev/null | tail -1)" != "$SIM_XCODEBUILDMCP_VERSION" ]; then
  npm install -g --no-audit --no-fund "xcodebuildmcp@$SIM_XCODEBUILDMCP_VERSION"; mise reshim
fi
note "xcodebuildmcp $(xcodebuildmcp --version | tail -1)"

say "Maestro $SIM_MAESTRO_VERSION"
MAESTRO_DIR=$HOME/.local/share/maestro/$SIM_MAESTRO_VERSION
if [ -x "$MAESTRO_DIR/bin/maestro" ]; then note "ok   $MAESTRO_DIR"
else
  TMP=$(mktemp -d)
  curl -fsSL -o "$TMP/maestro.zip" "https://github.com/mobile-dev-inc/maestro/releases/download/cli-$SIM_MAESTRO_VERSION/maestro.zip"
  echo "$SIM_MAESTRO_SHA256  $TMP/maestro.zip" | shasum -a 256 -c - >/dev/null || { rm -rf "$TMP"; fail "maestro.zip does not match SIM_MAESTRO_SHA256"; }
  unzip -q "$TMP/maestro.zip" -d "$TMP"
  mkdir -p "$(dirname "$MAESTRO_DIR")"; rm -rf "$MAESTRO_DIR"; mv "$TMP/maestro" "$MAESTRO_DIR"; rm -rf "$TMP"
  note "installed in $MAESTRO_DIR"
fi
ln -sfn "$MAESTRO_DIR/bin/maestro" "$HOME/.local/bin/maestro"

say "Simulators agent-ios-1..$SIM_IOS_SLOTS"
n=1
while [ "$n" -le "$SIM_IOS_SLOTS" ]; do
  if xcrun simctl list devices | grep -q "agent-ios-$n ("; then note "ok   agent-ios-$n"
  else xcrun simctl create "agent-ios-$n" "$SIM_IOS_DEVICE_TYPE" "$RUNTIME" >/dev/null; note "made agent-ios-$n"; fi
  n=$((n + 1))
done
mkdir -p "$HOME/sims"

say "Launcher ~/.local/bin/sim-xcodebuildmcp"
cat > "$HOME/.local/bin/sim-xcodebuildmcp" <<EOF
#!/bin/bash
# Written by install-ios-runner.sh (agentic-framework). sim-xcodebuildmcp <N>: XcodeBuildMCP on stdio, its session
# defaults pinned to simulator agent-ios-N, telemetry off. Started over ssh by bin/sim-mcp on the agent host.
case "\${1:-}" in [1-9]) ;; *) echo "usage: sim-xcodebuildmcp <slot 1-9>" >&2; exit 2 ;; esac
export PATH="\$HOME/.local/bin:\$HOME/.local/share/mise/shims:\$PATH"
# The UUID, not only the name: some tools (screenshot, UI automation) take nothing else from the session defaults.
udid=\$(xcrun simctl list devices | sed -n "s/^ *agent-ios-\$1 (\([0-9A-F-]*\)).*/\\1/p" | head -1)
if [ -n "\$udid" ]; then export XCODEBUILDMCP_SIMULATOR_ID="\$udid"; else export XCODEBUILDMCP_SIMULATOR_NAME="agent-ios-\$1"; fi
export XCODEBUILDMCP_ENABLED_WORKFLOWS="$SIM_IOS_WORKFLOWS"
export XCODEBUILDMCP_SENTRY_DISABLED=true
cd "\$HOME/sims"
exec xcodebuildmcp mcp
EOF
chmod 755 "$HOME/.local/bin/sim-xcodebuildmcp"
note "ok"

say "Launcher ~/.local/bin/sim-maestro"
cat > "$HOME/.local/bin/sim-maestro" <<'EOF'
#!/bin/bash
# Written by install-ios-runner.sh (agentic-framework). sim-maestro <N> <maestro args...>: Maestro on simulator
# agent-ios-N, analytics off. Run over ssh by `sim maestro ios` on the agent host, from the synced worktree. A run's
# debug output goes to ~/.cache/agent-sim/maestro-N, emptied first, which the host copies back afterwards.
case "${1:-}" in [1-9]) ;; *) echo "usage: sim-maestro <slot 1-9> <maestro args...>" >&2; exit 2 ;; esac
n=$1; shift
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
udid=$(xcrun simctl list devices | sed -n "s/^ *agent-ios-$n (\([0-9A-F-]*\)).*/\1/p" | head -1)
[ -n "$udid" ] || { echo "sim-maestro: no simulator agent-ios-$n on this Mac (sim ios bootstrap)" >&2; exit 1; }
export MAESTRO_CLI_NO_ANALYTICS=1 MAESTRO_CLI_ANALYSIS_NOTIFICATION_DISABLED=true
out=$HOME/.cache/agent-sim/maestro-$n
rm -rf "$out"; mkdir -p "$out"
if [ "${1:-}" = test ]; then shift; set -- test --debug-output "$out/debug" --test-output-dir "$out/output" "$@"; fi
exec maestro --device "$udid" "$@"
EOF
chmod 755 "$HOME/.local/bin/sim-maestro"
note "ok"
say "Done. From the host: sim status, then a harness session in a repo that ran sim enable."
