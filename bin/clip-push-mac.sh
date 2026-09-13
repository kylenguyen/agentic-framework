#!/bin/bash
# clip-push: send the Mac clipboard to as1 so Claude Code there can paste it.
# WezTerm runs `clip-push --if-image` on Cmd+V in a pane connected to as1 (config/wezterm-as1.lua): an image is
# pushed and WezTerm then sends Ctrl+V to Claude Code; text is reported only and WezTerm pastes it natively.
# Install: install -m 755 bin/clip-push-mac.sh ~/.local/bin/clip-push   (install-mac.sh; no sudo)
# Usage:   clip-push              push the clipboard (image or text); prints image/png or text/plain
#          clip-push --if-image   push only if the clipboard holds an image; prints the type either way
#          clip-push --clear      delete the copy held on as1
# The type is printed before the push so the caller can tell what failed.
# CLIP_PUSH_HOST overrides the ssh destination; default as1-clip (config/ssh_config.mac), use as1-lan off the tailnet.
# WezTerm starts child processes with a minimal environment, so PATH is spelled out (Homebrew for pngpaste).
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
set -euo pipefail
host=${CLIP_PUSH_HOST:-as1-clip}
remote() { ssh -o BatchMode=yes -o ConnectTimeout=3 "$host" "~/.local/bin/clip-put $*"; }

if_image=0
case "${1:-}" in
  --clear) remote --clear </dev/null; exit 0 ;;
  --if-image) if_image=1 ;;
  "") ;;
  *) echo 'usage: clip-push [--if-image|--clear]' >&2; exit 2 ;;
esac

# `clipboard info` lists classes such as «class PNGf», TIFF picture, «class utf8».
if osascript -e 'clipboard info' 2>/dev/null | grep -qE 'PNGf|TIFF'; then
  echo image/png
  command -v pngpaste >/dev/null || { echo 'clip-push: pngpaste missing (brew install pngpaste)' >&2; exit 1; }
  pngpaste - | remote
else
  echo text/plain
  [ "$if_image" = 1 ] || pbpaste | remote
fi
