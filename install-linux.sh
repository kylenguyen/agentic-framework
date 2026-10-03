#!/usr/bin/env bash
# Idempotent Linux desktop client setup for the agent host, including key login to it: the Linux counterpart of
# install-mac.sh. Run as yourself (not root) from a clone of this repo, on the machine you sit at, not on the host.
# Usage: ./install-linux.sh [--no-packages]
#   --no-packages   skip the package step (the only one that needs sudo); report what is missing instead
# Packages: the ssh client, mosh, both clipboard readers (wl-clipboard for Wayland, xclip for X11) and gawk where
# there is no awk, through apt, dnf, pacman or zypper. The script calls sudo itself, one command at a time, only when
# one of them is missing, so sudo asks for a password at most once and a configured machine never prompts. With
# SUDO_ASKPASS set it runs sudo -A, so a graphical helper (or the e2e tests) can answer.
# Parameters (lib/params.sh): .env in this checkout, as for install-mac.sh. With no .env and a terminal the script
# asks and writes .env; without a terminal it exits 2 before touching anything. The steps shared with
# install-mac.sh are in lib/client.sh.
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PACKAGES=1
for arg in "$@"; do
  case "$arg" in
    --no-packages) PACKAGES=0 ;;
    *) echo "usage: $0 [--no-packages]" >&2; exit 2 ;;
  esac
done
[ "$(uname -s)" = Linux ] || { echo "install-linux.sh is for Linux clients; on a Mac run ./install-mac.sh" >&2; exit 1; }
[ "$(id -u)" != 0 ] || { echo "run as your own user, not root or sudo: the script calls sudo itself when a package is missing" >&2; exit 1; }
# The host has clip-put and the xclip shim in ~/.local/bin; a real xclip there would shadow nothing but would break
# the rule that the host never gets one (AGENTS.md), and a host does not need a client setup towards itself.
if [ -e "$HOME/.local/bin/clip-put" ]; then
  echo "$HOME/.local/bin/clip-put exists: this looks like the agent host itself. Run install-linux.sh on the machine you connect from." >&2
  exit 1
fi

CLIENT_SCRIPT=install-linux.sh
LOGIN_SHELL=${SHELL:-$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f7)}
case "${LOGIN_SHELL##*/}" in
  zsh)  CLIENT_RC=$HOME/.zshrc ;;
  bash) CLIENT_RC=$HOME/.bashrc ;;
  *)    CLIENT_RC=$HOME/.profile ;;
esac
KEY_PASTE=Ctrl+Shift+V
KEY_RELOAD=Ctrl+Shift+R
NET_HINT="check \`tailscale status\`"
. "$REPO/lib/params.sh"
. "$REPO/lib/client.sh"

client_params

# pm_detect: the package manager, from /etc/os-release (ID, then ID_LIKE), else whichever is installed.
pm_detect() {
  local ids id
  ids=$( [ -r /etc/os-release ] && . /etc/os-release && echo "${ID:-} ${ID_LIKE:-}" ) || ids=
  for id in $ids; do
    case "$id" in
      debian|ubuntu) echo apt; return ;;
      fedora|rhel|centos) echo dnf; return ;;
      arch) echo pacman; return ;;
      suse|opensuse*) echo zypper; return ;;
    esac
  done
  for id in apt-get:apt dnf:dnf pacman:pacman zypper:zypper; do
    command -v "${id%%:*}" >/dev/null && { echo "${id#*:}"; return; }
  done
  echo unknown
}

# pkg_for <command>: the package that provides it under $PM.
pkg_for() {
  case "$1:$PM" in
    ssh*:apt) echo openssh-client ;;
    ssh*:pacman) echo openssh ;;
    ssh*:*) echo openssh-clients ;;
    wl-paste:*) echo wl-clipboard ;;
    awk:*) echo gawk ;;
    *) echo "$1" ;;
  esac
}

# pm_install <pkg...>: one install command for $PM. apt refreshes its lists first: a fresh system has none.
pm_install() {
  case "$PM" in
    apt)    as_root apt-get update -q && as_root apt-get install -y -q "$@" ;;
    dnf)    as_root dnf install -y -q "$@" ;;
    pacman) as_root pacman -S --needed --noconfirm "$@" ;;
    zypper) as_root zypper --non-interactive install "$@" ;;
    *)      return 1 ;;
  esac
}

# pm_command <pkg...>: the same command as text, for when it has to be run by hand.
pm_command() {
  case "$PM" in
    apt)    echo "sudo apt-get update && sudo apt-get install -y $*" ;;
    dnf)    echo "sudo dnf install -y $*" ;;
    pacman) echo "sudo pacman -S --needed $*" ;;
    zypper) echo "sudo zypper install $*" ;;
    *)      echo "install with your package manager: $*" ;;
  esac
}

# as_root <cmd...>: one command under sudo. The first call says why; sudo caches the credential after it.
SUDO=(sudo); [ -z "${SUDO_ASKPASS:-}" ] || SUDO=(sudo -A)
SUDO_PRIMED=0
as_root() {
  if [ "$SUDO_PRIMED" = 0 ]; then
    command -v sudo >/dev/null || { fail "sudo is not installed"; return 1; }
    note "root needed for: $*"
    # Usually your own password; root's where sudo is set up that way (openSUSE's default, Defaults targetpw).
    "${SUDO[@]}" -n true 2>/dev/null || note "sudo will ask for a password once"
    "${SUDO[@]}" -v || return 1
    SUDO_PRIMED=1
  fi
  "${SUDO[@]}" "$@"
}

# missing_pkgs: the packages for the commands not on PATH, each named once.
# awk: the marker blocks are rewritten with it; minimal images (openSUSE's container) ship without one.
NEEDED="awk ssh ssh-keygen ssh-keyscan ssh-copy-id mosh wl-paste xclip"
missing_pkgs() {
  local c p out=''
  for c in $NEEDED; do
    command -v "$c" >/dev/null && continue
    p=$(pkg_for "$c")
    case " $out " in *" $p "*) ;; *) out="$out $p" ;; esac
  done
  echo "${out# }"
}

PM=$(pm_detect)
say "Phase 1: packages ($PM): ssh client, mosh, wl-clipboard, xclip; ssh config"
PKG_GAP=''
MISSING=$(missing_pkgs)
if [ -z "$MISSING" ]; then
  note "ok   all installed"
elif [ "$PACKAGES" = 0 ]; then
  note "--no-packages: not installing $MISSING"
elif [ "$PM" = unknown ]; then
  fail "no apt, dnf, pacman or zypper here; install these yourself: $MISSING"
else
  # shellcheck disable=SC2086  # one word per package
  pm_install $MISSING || fail "the package install failed (see above)"
fi
MISSING=$(missing_pkgs)
if [ -n "$MISSING" ]; then
  note "missing: $MISSING. Install with:  $(pm_command "$MISSING")"
  case " $MISSING " in
    *" $(pkg_for ssh) "*) fail "the ssh client is required for everything that follows"; exit 1 ;;
  esac
  PKG_GAP="packages are missing ($MISSING): $(pm_command "$MISSING"), then re-run ./install-linux.sh"
fi
# GUI apps and Tailscale are not installed here: they come from the desktop's own store or the vendor's repository.
if command -v wezterm >/dev/null; then :
elif command -v flatpak >/dev/null && flatpak info org.wezfurlong.wezterm >/dev/null 2>&1; then
  note "WezTerm is the Flatpak: it runs clip-push inside its sandbox, which may lack ssh and the clipboard tools;"
  note "the native package from https://wezterm.org/install/linux.html is what this setup is tested with"
else
  note "WezTerm not found: https://wezterm.org/install/linux.html"
fi
command -v tailscale >/dev/null || note "Tailscale not found: https://tailscale.com/download/linux (then sudo tailscale up)"
case "${XDG_SESSION_TYPE:-}" in
  wayland|x11) note "desktop session: $XDG_SESSION_TYPE (clip-push reads the clipboard with $( [ "$XDG_SESSION_TYPE" = wayland ] && echo wl-paste || echo xclip ))" ;;
esac
client_ssh_config

say "Phase 2: WezTerm"
client_wezterm

say "Phase 4: clipboard push (clip-push, run by WezTerm on $KEY_PASTE)"
client_clip_push bin/clip-push-linux.sh.in

client_login
client_finish "$PKG_GAP"
