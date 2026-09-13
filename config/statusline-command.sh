#!/usr/bin/env bash
# Claude Code status line on as1. ~/.claude/statusline-command.sh is a symlink to this file (install-as1.sh);
# config/claude-settings.json names that path. Claude Code pipes one JSON object on stdin per refresh; we show
# model, working directory and git branch. jq comes from install-as1-root.sh; without it only the directory is shown.
input=$(cat)
model= dir=
if command -v jq >/dev/null 2>&1; then
  model=$(jq -r '.model.display_name // empty' <<<"$input" 2>/dev/null)
  dir=$(jq -r '.workspace.current_dir // .cwd // empty' <<<"$input" 2>/dev/null)
fi
dir=${dir:-$PWD}
branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
printf '%s%s%s\n' "${model:+$model | }" "${dir/#$HOME/~}" "${branch:+ ($branch)}"
