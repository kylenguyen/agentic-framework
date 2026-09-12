# Interactive shells only: mise activation (shims already cover non-interactive shells).
# shellcheck shell=bash
if command -v mise >/dev/null 2>&1; then
  eval "$(mise activate bash)"
fi
