#!/usr/bin/env bash
# Idempotent host setup, phases 1 to 4 in one script. Safe to re-run. Run as the login the host is for, never with sudo.
# Usage: ./install-host.sh [--no-tools] [--no-root]
#   --no-tools   skip network installs (oh-my-zsh, mise toolchains, uv, harnesses)
#   --no-root    skip phase 1 (the steps that need sudo)
# Phase 1 (apt packages, zsh as login shell, linger, Tailscale auto-update, unattended-upgrades) runs one
# command at a time through the as_root helper, and only when the host is not already in the wanted state.
# sudo asks for your password the first time a root step is actually needed; a host that is already
# configured never prompts. Everything else runs as you. sshd and the firewall are left as the OS installed them.
# Parameters (lib/params.sh): the login is the one running the script; host name, address and LAN address come from
# the system, or from .env when set there. .env is written from the derived values on the first run and its
# contents printed at the end for the Macs. Password prompts aside, nothing is interactive.
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
params_load || exit 1
params_derive_host || exit 1
USER_NAME=$AGENT_HOST_USER
say "Parameters: host $AGENT_HOST ($AGENT_HOST_ADDRESS), login $USER_NAME, LAN ${AGENT_HOST_LAN_IP:-none}"
if [ -f "$REPO/.env" ]; then note "ok   .env"; else params_env_text > "$REPO/.env"; note "wrote .env from the values above (edit to override, then re-run)"; fi

# as_root <cmd...>: run one command with sudo. The first call explains the password prompt; sudo caches
# the credential for the rest of the run, so later calls are silent.
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

# block <file> <marker> <content>: insert/replace a marked block. mode top|bottom
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
  say "Phase 1: packages: tmux mosh gh zsh, plus git curl file jq unattended-upgrades"
  # tmux is the whole of phase 2; the rest are what the later phases, the shim tests and the status line call.
  MISSING=()
  for pkg in tmux mosh gh zsh git curl file jq unattended-upgrades; do
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
fi

say "Phase 2: tmux + shell"
link "$REPO/config/tmux.conf" "$HOME/.tmux.conf"
link "$REPO/config/bashrc.d" "$HOME/.bashrc.d"
# zsh is the login shell (chsh happens in phase 1). Both shells share bashrc.d; bash
# stays fully configured as the escape hatch and for scripts.
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

say "Phase 3: secrets file, shared agent context, Claude settings"
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
install -d "$HOME/.claude"
link "$REPO/config/claude-settings.json" "$HOME/.claude/settings.json"
link "$REPO/config/statusline-command.sh" "$HOME/.claude/statusline-command.sh"

say "Phase 4: clipboard bridge (clip-put writes the spool, the xclip shim serves it)"
install -d "$HOME/.local/bin"
link "$REPO/bin/xclip" "$HOME/.local/bin/xclip"
link "$REPO/bin/clip-put" "$HOME/.local/bin/clip-put"

if [ "$TOOLS" = 1 ]; then
  say "Phase 2: oh-my-zsh"
  # Plain clone instead of the upstream install.sh: no chsh, no generated ~/.zshrc (ours is a
  # symlink into the repo), nothing to undo on re-run. Updates: `omz update`.
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
  mise reshim
  # Native installer, not npm: it puts a self-updating binary in ~/.local/bin and needs no toolchain.
  command -v claude >/dev/null || curl -fsSL https://claude.ai/install.sh | bash
  claude update || true
  note "first-time logins are manual: claude (OAuth) or ANTHROPIC_API_KEY in ~/.config/agents/env; gh auth login"
fi

say "Parameters for the Macs: put these lines in .env in the agentic-framework checkout there (README.md, section 2)"
params_env_text | grep -v '^#'
say "Done. Next: log out and back in, then one-time logins (README.md, section 4)."
