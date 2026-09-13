#!/usr/bin/env bash
# Idempotent user-level setup for as1 (phases 2-4). Safe to re-run.
# Usage: ./install-as1.sh [--no-tools]
#   --no-tools   skip network installs (oh-my-zsh, mise toolchains, uv, harnesses)
# Root-level steps (sshd, ufw, apt, chsh to zsh, linger, tailscale) live in install-as1-root.sh.
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TOOLS=1; [ "${1:-}" = "--no-tools" ] && TOOLS=0

say()  { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }

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

# unblock <file> <marker>: remove a marked block left by an earlier version of this script, if present.
unblock() {
  local file=$1 marker=$2 begin end tmp
  begin="# >>> agentic-framework:$marker >>>"; end="# <<< agentic-framework:$marker <<<"
  grep -qF "$begin" "$file" 2>/dev/null || return 0
  tmp=$(mktemp)
  awk -v b="$begin" -v e="$end" '$0==b {skip=1; next} $0==e {skip=0; next} !skip' "$file" > "$tmp"
  cat "$tmp" > "$file"; rm -f "$tmp"; note "rm   $file [$marker]"
}

say "Phase 2: tmux + shell"
link "$REPO/config/tmux.conf" "$HOME/.tmux.conf"
link "$REPO/config/bashrc.d" "$HOME/.bashrc.d"
# zsh is the login shell (chsh happens in the root script). Both shells share bashrc.d; bash
# stays fully configured as the escape hatch and for scripts.
link "$REPO/config/zshenv" "$HOME/.zshenv"
link "$REPO/config/zshrc" "$HOME/.zshrc"
if [ "$(getent passwd "$USER" | cut -d: -f7)" != "$(command -v zsh || true)" ]; then
  note "login shell is not zsh yet: run the root script, or: chsh -s $(command -v zsh || echo /usr/bin/zsh)"
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
  install -m 600 "$REPO/env.example" "$HOME/.config/agents/env"; note "created ~/.config/agents/env (fill in keys)"
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
# The first design had as1 SSH into the Macs; drop the ~/.ssh/config block it left behind.
if [ -f "$HOME/.ssh/config" ]; then unblock "$HOME/.ssh/config" clip-bridge; fi

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
  command -v aider >/dev/null || uv tool install --force --python python3.12 --with pip aider-chat@latest
  command -v omp >/dev/null || npm install -g @oh-my-pi/pi-coding-agent
  mise reshim
  # Native installer, not npm: it puts a self-updating binary in ~/.local/bin and needs no toolchain.
  command -v claude >/dev/null || curl -fsSL https://claude.ai/install.sh | bash
  claude update || true
  note "first-time logins are manual: claude (OAuth) or ANTHROPIC_API_KEY in ~/.config/agents/env; gh auth login"
fi

say "Done. Root steps: sudo bash $REPO/install-as1-root.sh. Full order of work: docs/setup-from-scratch.md"
