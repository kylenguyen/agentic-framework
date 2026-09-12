# Sourced from ~/.bashrc BEFORE the interactive guard, so it applies to
# non-interactive SSH commands too (ssh as1 'claude -p ...', systemd, automation).
# shellcheck shell=bash

# PATH: user bins, mise shims (toolchains), uv/opencode/omp installers put binaries here too.
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac
if [ -d "$HOME/.local/share/mise/shims" ]; then
  case ":$PATH:" in *":$HOME/.local/share/mise/shims:"*) ;; *) PATH="$HOME/.local/share/mise/shims:$PATH" ;; esac
fi
export PATH

# Agent secrets (API keys, GH_TOKEN). File is mode 600, never committed; see env.example.
if [ -r "$HOME/.config/agents/env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$HOME/.config/agents/env"
  set +a
fi
