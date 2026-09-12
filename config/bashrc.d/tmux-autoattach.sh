# Interactive SSH logins land in tmux session "main". Never triggers for
# `ssh as1 <command>` (non-interactive) or inside tmux. Escape hatch:
#   ssh -t as1 'NO_TMUX=1 bash -l'
# shellcheck shell=bash
if [[ $- == *i* && -n ${SSH_TTY:-} && -z ${TMUX:-} && -z ${NO_TMUX:-} ]] && command -v tmux >/dev/null 2>&1; then
  exec tmux new -As main
fi
