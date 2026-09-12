#!/usr/bin/env bash
# Idempotent user-level setup for as1 (phases 1-4). Safe to re-run.
# Usage: MAC_USER=<macOS login> ./install-as1.sh [--no-tools]
#   --no-tools   skip network installs (mise toolchains, uv, harnesses)
# Root-level steps (sshd, ufw, apt, linger, tailscale) live in install-as1-root.sh.
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MAC_USER=${MAC_USER:-kyle}
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

say "Phase 2: tmux + shell"
link "$REPO/config/tmux.conf" "$HOME/.tmux.conf"
link "$REPO/config/bashrc.d" "$HOME/.bashrc.d"
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
link "$REPO/config/workspace/CLAUDE.md" "$HOME/workspace/CLAUDE.md"
link "$REPO/config/workspace/AGENTS.md" "$HOME/workspace/AGENTS.md"
install -d "$HOME/.claude"
link "$REPO/config/claude-settings.json" "$HOME/.claude/settings.json"

say "Phase 4: clipboard bridge"
install -d "$HOME/.local/bin"
link "$REPO/bin/xclip" "$HOME/.local/bin/xclip"
install -d -m 700 "$HOME/.ssh"; touch "$HOME/.ssh/config"; chmod 600 "$HOME/.ssh/config"
block "$HOME/.ssh/config" clip-bridge bottom "$(sed "s/__MACUSER__/$MAC_USER/" "$REPO/config/ssh_config.as1" | grep -v '^#')"
note "ssh config User for the Macs: $MAC_USER (override with MAC_USER=...)"

if [ "$TOOLS" = 1 ]; then
  say "Phase 3: toolchains"
  export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
  if ! command -v mise >/dev/null; then curl -fsSL https://mise.run | MISE_INSTALL_PATH="$HOME/.local/bin/mise" sh; fi
  mise use -g -y node@lts bun@latest python@3.12
  mise reshim
  command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh
  say "Phase 3: harnesses"
  if ! command -v opencode >/dev/null; then
    curl -fsSL https://opencode.ai/install | bash      # installs to ~/.opencode/bin and appends to ~/.bashrc
    ln -sfn "$HOME/.opencode/bin/opencode" "$HOME/.local/bin/opencode"
    sed -i '/^# opencode$/,/^export PATH=.*\.opencode\/bin/d' "$HOME/.bashrc"   # PATH handled by agents-env.sh
  fi
  command -v aider >/dev/null || uv tool install --force --python python3.12 --with pip aider-chat@latest
  command -v omp >/dev/null || npm install -g @oh-my-pi/pi-coding-agent
  mise reshim
  claude update || true
fi

say "Done. Root steps: sudo bash $REPO/install-as1-root.sh"
