# Sourced from the top of ~/.bashrc and from ~/.zshenv, so it applies to non-interactive SSH commands too
# (ssh <host> 'claude -p ...') in either shell. Must stay POSIX sh: it runs under bash and zsh.
# shellcheck shell=bash

# PATH: ~/.local/bin (uv, opencode, claude, agent, the shims) and mise shims (toolchains).
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac
if [ -d "$HOME/.local/share/mise/shims" ]; then
  case ":$PATH:" in *":$HOME/.local/share/mise/shims:"*) ;; *) PATH="$HOME/.local/share/mise/shims:$PATH" ;; esac
fi
export PATH

# Agent secrets (API keys, GH_TOKEN). Mode 600, never committed; template secrets.env.example.
if [ -r "$HOME/.config/agents/env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$HOME/.config/agents/env"
  set +a
fi
