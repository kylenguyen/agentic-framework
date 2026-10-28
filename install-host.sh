#!/usr/bin/env bash
# Idempotent host setup, phases 1 to 4, the device simulation service and the web dashboard. Safe to re-run. Run as the host login, never with sudo.
# Usage: ./install-host.sh [--no-tools] [--no-root]
#   --no-tools   skip network installs (oh-my-zsh, mise toolchains, uv, the four harnesses); web/ packages come
#                from the npm cache only
#   --no-root    skip phase 1 (the steps that need sudo)
# Phase 1 (apt packages, zsh as login shell, linger, Tailscale auto-update, unattended-upgrades) runs one command at
# a time through as_root, only when the host is not already in the wanted state, so a configured host never prompts.
# sshd and the firewall are left as the OS installed them. Parameters (lib/params.sh): the login is the one running
# the script; host name, address and LAN address come from .env or the system. .env is written on the first run and
# printed at the end for the Macs. Password prompts aside, nothing is interactive.
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TOOLS=1; ROOT=1
for arg in "$@"; do
  case "$arg" in
    --no-tools) TOOLS=0 ;;
    --no-root)  ROOT=0 ;;
    *) echo "usage: $0 [--no-tools] [--no-root]" >&2; exit 2 ;;
  esac
done
[ "$(id -u)" != 0 ] || { echo "run as your own user, not root or sudo: the script calls sudo itself for phase 1" >&2; exit 1; }

say()  { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
fail() { printf '\033[1;31m!!  %s\033[0m\n' "$*" >&2; exit 1; }

. "$REPO/lib/params.sh"
. "$REPO/lib/sim.sh"
params_load || exit 1
params_derive_host || exit 1
USER_NAME=$AGENT_HOST_USER
say "Parameters: host $AGENT_HOST ($AGENT_HOST_ADDRESS), login $USER_NAME, LAN ${AGENT_HOST_LAN_IP:-none}"
if [ -f "$REPO/.env" ]; then note "ok   .env"; else params_env_text > "$REPO/.env"; note "wrote .env from the values above (edit to override, then re-run)"; fi

# as_root <cmd...>: one command under sudo. The first call explains the prompt; sudo caches the credential after it.
SUDO_PRIMED=0
as_root() {
  if [ "$SUDO_PRIMED" = 0 ]; then
    note "root needed for: $*"
    note "sudo will ask for your password once"
    sudo -v; SUDO_PRIMED=1
  fi
  sudo "$@"
}

link() { # link <target> <linkpath>: symlink, backing up a real file that is in the way
  local target=$1 linkpath=$2
  if [ -L "$linkpath" ] && [ "$(readlink -f "$linkpath")" = "$(readlink -f "$target")" ]; then
    note "ok   $linkpath"; return
  fi
  if [ -e "$linkpath" ] && [ ! -L "$linkpath" ]; then
    mv -v "$linkpath" "$linkpath.bak.$(date +%Y%m%d%H%M%S)"
  fi
  ln -sfn "$target" "$linkpath"; note "link $linkpath -> $target"
}

# block <file> <marker> <top|bottom> <content>: insert or replace a marked block.
block() {
  local file=$1 marker=$2 mode=$3 content=$4 begin end tmp
  begin="# >>> agentic-framework:$marker >>>"; end="# <<< agentic-framework:$marker <<<"
  tmp=$(mktemp)
  if grep -qF "$begin" "$file" 2>/dev/null; then
    awk -v b="$begin" -v e="$end" -v c="$content" '
      $0==b {print b; print c; print e; skip=1; next} $0==e {skip=0; next} !skip' "$file" > "$tmp"
    note "upd  $file [$marker]"
  elif [ "$mode" = top ]; then
    { printf '%s\n%s\n%s\n\n' "$begin" "$content" "$end"; cat "$file"; } > "$tmp"
    note "add  $file [$marker] (top)"
  else
    { cat "$file"; printf '\n%s\n%s\n%s\n' "$begin" "$content" "$end"; } > "$tmp"
    note "add  $file [$marker] (bottom)"
  fi
  cat "$tmp" > "$file"; rm -f "$tmp"
}

if [ "$ROOT" = 1 ]; then
  say "Phase 1: packages: tmux mosh gh zsh fzf, plus git curl file jq unattended-upgrades"
  # tmux and fzf serve phase 2 (sessions and the picker); the rest serve later phases, the shim tests and the status line.
  MISSING=()
  for pkg in tmux mosh gh zsh fzf git curl file jq unattended-upgrades; do
    [ "$(dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null)" = installed ] || MISSING+=("$pkg")
  done
  if [ "${#MISSING[@]}" = 0 ]; then note "ok   all installed"
  else as_root apt-get install -y -q "${MISSING[@]}"; fi

  say "Phase 1: login shell for $USER_NAME: zsh (oh-my-zsh config comes in phase 2)"
  # chsh run by the user asks for the password again; through sudo it reuses the cached credential.
  ZSH_BIN=$(command -v zsh)
  if [ "$(getent passwd "$USER_NAME" | cut -d: -f7)" = "$ZSH_BIN" ]; then
    note "ok   $ZSH_BIN"
  else
    as_root chsh -s "$ZSH_BIN" "$USER_NAME"
    getent passwd "$USER_NAME" | cut -d: -f7
  fi

  say "Phase 1: linger for $USER_NAME (user systemd units + tmux survive logout)"
  if [ -e "/var/lib/systemd/linger/$USER_NAME" ]; then
    note "ok   Linger=yes"
  else
    as_root loginctl enable-linger "$USER_NAME"
    loginctl show-user "$USER_NAME" | grep Linger
  fi

  say "Phase 1: tailscale auto-update, unattended-upgrades"
  if ! command -v tailscale >/dev/null; then
    note "tailscale not installed: curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up  (README.md, section 1)"
  elif tailscale debug prefs 2>/dev/null | grep -A2 '"AutoUpdate"' | grep -qE '"Apply": *true'; then
    note "ok   tailscale auto-update on"
  else
    as_root tailscale set --auto-update || true
  fi
  if [ "$(systemctl is-enabled unattended-upgrades 2>/dev/null)" = enabled ] && systemctl is-active --quiet unattended-upgrades; then
    note "ok   unattended-upgrades enabled and active"
  else
    as_root systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
    systemctl is-active unattended-upgrades || echo "unattended-upgrades is not active; check: systemctl status unattended-upgrades"
  fi
  note "optional: sudo tailscale up --ssh (Tailscale SSH alongside OpenSSH)"

  say "Phase 1: libraries for the Android emulator and the Playwright browsers (simulators, lib/sim.sh)"
  MISSING=()
  for pkg in $SIM_APT_PACKAGES; do
    [ "$(dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null)" = installed ] || MISSING+=("$pkg")
  done
  if [ "${#MISSING[@]}" = 0 ]; then note "ok   all installed"
  else as_root apt-get install -y -q --no-install-recommends "${MISSING[@]}"; fi
fi

say "Phase 2: tmux + shell"
link "$REPO/config/tmux.conf" "$HOME/.tmux.conf"
link "$REPO/config/bashrc.d" "$HOME/.bashrc.d"
# Both shells share bashrc.d; bash stays fully configured as the escape hatch and for scripts.
link "$REPO/config/zshenv" "$HOME/.zshenv"
link "$REPO/config/zshrc" "$HOME/.zshrc"
if [ "$(getent passwd "$USER_NAME" | cut -d: -f7)" != "$(command -v zsh || true)" ]; then
  note "login shell is not zsh yet: re-run without --no-root, or: chsh -s $(command -v zsh || echo /usr/bin/zsh)"
fi
touch "$HOME/.bashrc"
block "$HOME/.bashrc" env top \
'# All shells, incl. non-interactive ssh commands: PATH, mise shims, ~/.config/agents/env
[ -r "$HOME/.bashrc.d/agents-env.sh" ] && . "$HOME/.bashrc.d/agents-env.sh"'
block "$HOME/.bashrc" interactive bottom \
'[ -r "$HOME/.bashrc.d/mise.sh" ] && . "$HOME/.bashrc.d/mise.sh"
[ -r "$HOME/.bashrc.d/tmux-autoattach.sh" ] && . "$HOME/.bashrc.d/tmux-autoattach.sh"'

say "Phase 3: secrets file, shared agent context, Claude and Codex settings"
install -d -m 700 "$HOME/.config/agents"
if [ ! -f "$HOME/.config/agents/env" ]; then
  install -m 600 "$REPO/secrets.env.example" "$HOME/.config/agents/env"; note "created ~/.config/agents/env (fill in keys)"
else
  chmod 600 "$HOME/.config/agents/env"; note "ok   ~/.config/agents/env"
fi
# One file, two names: Claude Code reads CLAUDE.md, the other harnesses read AGENTS.md.
install -d "$HOME/workspace"
link "$REPO/config/workspace/CLAUDE.md" "$HOME/workspace/CLAUDE.md"
link "$REPO/config/workspace/CLAUDE.md" "$HOME/workspace/AGENTS.md"
# Codex reads instructions from the git root down, never ~/workspace, so the house rules reach it through its global
# ~/.codex/AGENTS.md. Its config.toml is not a symlink (Codex writes trusted projects and model choice into it), so
# the repo owns one marker block at the top, where a top-level key stays out of any table. project_doc_max_bytes:
# Codex truncates combined instructions at 32 KiB by default; the house rules plus a repo AGENTS.md are larger.
install -d "$HOME/.codex"
link "$REPO/config/workspace/CLAUDE.md" "$HOME/.codex/AGENTS.md"
touch "$HOME/.codex/config.toml"
block "$HOME/.codex/config.toml" codex top \
'# Installed by agentic-framework: the house rules and repo AGENTS.md files exceed the 32 KiB default.
project_doc_max_bytes = 131072'
install -d "$HOME/.claude"
link "$REPO/config/claude-settings.json" "$HOME/.claude/settings.json"
link "$REPO/config/statusline-command.sh" "$HOME/.claude/statusline-command.sh"

say "Phase 4: clipboard bridge (clip-put writes the spool, the xclip shim serves it), session picker"
install -d "$HOME/.local/bin"
link "$REPO/bin/xclip" "$HOME/.local/bin/xclip"
link "$REPO/bin/clip-put" "$HOME/.local/bin/clip-put"
# Every interactive login lands in the picker (config/bashrc.d/tmux-autoattach.sh), so it must be on PATH.
link "$REPO/bin/agent" "$HOME/.local/bin/agent"

say "Simulators: sim and sim-mcp, the emulator unit (docs/simulators-plan.md)"
link "$REPO/bin/sim" "$HOME/.local/bin/sim"
link "$REPO/bin/sim-mcp" "$HOME/.local/bin/sim-mcp"
install -d "$HOME/.config/systemd/user"
link "$REPO/config/systemd/agent-sim-android@.service" "$HOME/.config/systemd/user/agent-sim-android@.service"
link "$REPO/config/systemd/agent-sim-reap.service" "$HOME/.config/systemd/user/agent-sim-reap.service"
link "$REPO/config/systemd/agent-sim-reap.timer" "$HOME/.config/systemd/user/agent-sim-reap.timer"
if systemctl --user daemon-reload 2>/dev/null; then
  # Idle devices are stopped every 5 minutes (lib/sim.sh, Uptime); AGENT_SIM_IDLE_MINUTES=0 in .env keeps them up.
  systemctl --user enable --now agent-sim-reap.timer 2>/dev/null && note "ok   agent-sim-reap.timer" \
    || note "could not enable agent-sim-reap.timer; run: systemctl --user enable --now agent-sim-reap.timer"
else
  note "systemctl --user unavailable here; run: systemctl --user daemon-reload && systemctl --user enable --now agent-sim-reap.timer"
fi

if [ "$TOOLS" = 1 ]; then
  say "Phase 2: oh-my-zsh"
  # Plain clone instead of the upstream install.sh: no chsh, no generated ~/.zshrc (ours is a symlink into the
  # repo), nothing to undo on re-run. Updates: `omz update`.
  if [ ! -d "$HOME/.oh-my-zsh" ]; then
    git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git "$HOME/.oh-my-zsh"
  else
    note "ok   ~/.oh-my-zsh"
  fi
  say "Phase 3: toolchains"
  export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
  if ! command -v mise >/dev/null; then curl -fsSL https://mise.run | MISE_INSTALL_PATH="$HOME/.local/bin/mise" sh; fi
  mise use -g -y node@lts bun@latest python@3.12
  mise reshim
  command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh
  say "Phase 3: harnesses"
  if ! command -v opencode >/dev/null; then
    # --no-modify-path: the installer would otherwise append to the rc file of $SHELL, which for
    # zsh is our repo-owned ~/.zshrc symlink. PATH is handled by agents-env.sh.
    curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path      # installs to ~/.opencode/bin
    ln -sfn "$HOME/.opencode/bin/opencode" "$HOME/.local/bin/opencode"
  fi
  command -v omp >/dev/null || npm install -g @oh-my-pi/pi-coding-agent
  command -v codex >/dev/null || npm install -g @openai/codex
  mise reshim
  # pi-web-access swaps omp's built-in web_search for its keyless Exa search and adds fetch_content. `omp install` is
  # user-scoped (~/.omp/plugins), so the npm install above does not carry it; it needs no config (optional file:
  # ~/.pi/agent/web-search.json). After the reshim so `omp` resolves on a first run.
  [ -d "$HOME/.omp/plugins/node_modules/pi-web-access" ] || omp install pi-web-access
  # Native installer, not npm: it puts a self-updating binary in ~/.local/bin and needs no toolchain.
  command -v claude >/dev/null || curl -fsSL https://claude.ai/install.sh | bash
  claude update || true
  say "Simulators: JDK 17, Android SDK packages, the shared AVD, pinned MCP servers, Playwright browsers"
  mise install -y java@temurin-17
  SDKM=$ANDROID_HOME/cmdline-tools/latest/bin
  if [ -x "$SDKM/sdkmanager" ]; then
    export JAVA_HOME; JAVA_HOME=$(mise where java@temurin-17)
    yes | "$SDKM/sdkmanager" --licenses >/dev/null 2>&1 || true
    "$SDKM/sdkmanager" --install emulator platform-tools "platforms;android-$SIM_ANDROID_API" "$SIM_ANDROID_IMAGE" | tail -1
    if [ -d "$HOME/.android/avd/$SIM_AVD.avd" ]; then note "ok   AVD $SIM_AVD"
    else echo no | "$SDKM/avdmanager" create avd -n "$SIM_AVD" -k "$SIM_ANDROID_IMAGE" -d "$SIM_AVD_DEVICE" >/dev/null; note "made AVD $SIM_AVD"; fi
  else
    note "no Android command-line tools: unpack them to $ANDROID_HOME/cmdline-tools/latest (developer.android.com/studio, Command line tools only), then re-run"
  fi
  install -d "$SIM_PREFIX"
  npm install --prefix "$SIM_PREFIX" --no-audit --no-fund --save-exact \
    "@playwright/mcp@$SIM_PLAYWRIGHT_MCP_VERSION" "@mobilenext/mobile-mcp@$SIM_MOBILE_MCP_VERSION" | tail -1
  # The browsers Playwright MCP's own playwright build expects, not whatever a global playwright would fetch.
  "$SIM_PREFIX/node_modules/.bin/playwright" install chromium webkit
  if [ -n "${AGENT_IOS_HOST:-}" ]; then note "iOS: run \`sim ios bootstrap\` to install or update the runner on $AGENT_IOS_HOST"
  else note "iOS: set AGENT_IOS_HOST and AGENT_IOS_USER in .env, then run \`sim ios bootstrap\`"; fi
  note "first-time logins are manual: claude (OAuth) or ANTHROPIC_API_KEY in ~/.config/agents/env; codex login --device-auth or OPENAI_API_KEY piped to codex login --with-api-key; gh auth login"
fi

say "Web dashboard: agent-web, its npm packages and user unit (docs/web-dashboard-plan.md, README.md section 7)"
link "$REPO/web/server.mjs" "$HOME/.local/bin/agent-web"
link "$REPO/config/systemd/agent-web.service" "$HOME/.config/systemd/user/agent-web.service"
install -d -m 700 "$HOME/.config/agent-web"; chmod 700 "$HOME/.config/agent-web"
# Exactly the lockfile's packages. The stamp holds the lockfile's hash and lives inside node_modules, which npm ci
# empties first, so a failed install leaves no stamp. --no-tools keeps off the network: npm ci --offline installs
# from npm's cache (filled by any earlier install of the same lockfile, tests/web-test.sh included) or not at all.
WEB_STAMP=$REPO/web/node_modules/.agentic-framework-lock
WEB_LOCK=$(sha256sum "$REPO/web/package-lock.json" | cut -d' ' -f1)
NPM_PATH=$HOME/.local/share/mise/shims:$PATH
NPM_CI=(npm ci --ignore-scripts --no-audit --no-fund --prefix "$REPO/web")
if [ "$(cat "$WEB_STAMP" 2>/dev/null)" = "$WEB_LOCK" ]; then
  note "ok   web/node_modules"
elif ! PATH=$NPM_PATH command -v npm >/dev/null; then
  note "no npm for web/node_modules: re-run without --no-tools (mise installs node)"
elif [ "$TOOLS" = 1 ]; then
  PATH=$NPM_PATH "${NPM_CI[@]}" | tail -1
  echo "$WEB_LOCK" > "$WEB_STAMP"; note "npm  web/node_modules"
elif PATH=$NPM_PATH "${NPM_CI[@]}" --offline >/dev/null 2>&1; then
  echo "$WEB_LOCK" > "$WEB_STAMP"; note "npm  web/node_modules (offline, from the npm cache)"
else
  note "web/node_modules is not in the npm cache; re-run without --no-tools"
fi
if systemctl --user daemon-reload 2>/dev/null; then
  # Skipped, not failed, until ~/.config/agent-web/env exists (ConditionPathExists in the unit).
  if systemctl --user enable --now agent-web.service 2>/dev/null; then note "ok   agent-web.service"
  else note "could not enable agent-web.service; run: systemctl --user enable --now agent-web.service"; fi
else
  note "systemctl --user unavailable here; run: systemctl --user daemon-reload && systemctl --user enable --now agent-web.service"
fi
if [ -f "$HOME/.config/agent-web/env" ]; then
  note "ok   ~/.config/agent-web/env"
else
  note "add this line to ~/.config/agent-web/env, with the login \`tailscale status\` shows for you:"
  note "  AGENT_WEB_ALLOW=<your tailnet login>"
  note "then: systemctl --user restart agent-web.service, and the tailscale serve steps in README.md section 7"
fi
note "after a pull that changes web/: systemctl --user restart agent-web.service"

say "Parameters for the clients: put these lines in .env in the agentic-framework checkout on each Mac or Linux client (README.md, section 2)"
params_env_text | grep -v '^#'
say "Done. Next: log out and back in, then one-time logins (README.md, section 4)."
