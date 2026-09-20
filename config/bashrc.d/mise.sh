# Interactive shells only: mise activation (shims cover non-interactive shells). Sourced from both ~/.bashrc and
# ~/.zshrc, so the activation script matches the running shell.
# shellcheck shell=bash
if command -v mise >/dev/null 2>&1; then
  if [ -n "${ZSH_VERSION:-}" ]; then
    eval "$(mise activate zsh)"
  else
    eval "$(mise activate bash)"
  fi
fi
