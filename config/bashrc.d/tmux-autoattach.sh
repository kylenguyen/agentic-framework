# Interactive SSH logins land in the session picker (`agent pick`). Never triggers for `ssh <host> <command>` or
# inside tmux. Sourced from ~/.bashrc and ~/.zshrc; the test below is valid in both shells. Escape hatch:
#   ssh -t <host> 'NO_TMUX=1 zsh -l'      (or bash -l)
# Picker exit codes: 0 "plain shell here", so the login shell carries on outside tmux; 3 "log out", so the
# connection closes.
# shellcheck shell=bash
if [[ $- == *i* && -n ${SSH_TTY:-} && -z ${TMUX:-} && -z ${NO_TMUX:-} ]] && command -v agent >/dev/null 2>&1; then
  agent pick
  [[ $? -ne 3 ]] || exit
fi
