#!/bin/bash
# clip-client: serve the Mac clipboard to as1 over SSH.
# Install: sudo install -m 755 bin/clip-client-mac.sh /usr/local/bin/clip-client
# Non-interactive SSH sessions get a minimal PATH, so spell out Homebrew and /usr/local.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

case "${1:-}" in
  targets)
    # `clipboard info` lists classes such as «class PNGf», TIFF picture, «class utf8».
    if osascript -e 'clipboard info' 2>/dev/null | grep -qE 'PNGf|TIFF'; then
      echo image/png
    else
      echo 'text/plain UTF8_STRING'
    fi ;;
  image) command -v pngpaste >/dev/null || { echo 'clip-client: pngpaste missing (brew install pngpaste)' >&2; exit 1; }
         exec pngpaste - ;;
  text)  exec pbpaste ;;
  copy)  exec pbcopy ;;
  *) echo 'usage: clip-client targets|image|text|copy' >&2; exit 2 ;;
esac
