#!/bin/bash
# Claude Code status line.
#   line 1: robbyrussell-style identity  -> dir, git branch, model, effort, fast mode
#   line 2: usage                        -> context tokens + bar + %, 5h and 7d rate limits
# Input: the status line JSON Claude Code writes to stdin (see its statusLine docs).

input=$(cat)

# Single jq pass. Separator is US (0x1f), not tab: tab is IFS whitespace, so bash
# would collapse runs of it and empty fields would shift every later value left.
IFS=$'\x1f' read -r cwd model in_tok win used effort fast exceeds l5 l5r l7 l7r <<EOF
$(printf '%s' "$input" | jq -r '[
  (.workspace.current_dir // .cwd // ""),
  (.model.display_name // ""),
  (.context_window.total_input_tokens // 0),
  (.context_window.context_window_size // 0),
  (.context_window.used_percentage // -1),
  (.effort.level // ""),
  (.fast_mode // false),
  (.exceeds_200k_tokens // false),
  (.rate_limits.five_hour.used_percentage // -1),
  (.rate_limits.five_hour.resets_at // 0),
  (.rate_limits.seven_day.used_percentage // -1),
  (.rate_limits.seven_day.resets_at // 0)
] | map(tostring) | join("\u001f")')
EOF

dir=$(basename "${cwd:-$PWD}")

# Reset clock (24h local) for whichever window is getting full.
fmt_reset() { # $1 = epoch seconds
  [ "${1:-0}" -gt 0 ] 2>/dev/null || return
  date -r "$1" +%H:%M 2>/dev/null || date -d "@$1" +%H:%M 2>/dev/null
}
l5_reset=""
l7_reset=""
awk "BEGIN{exit !(${l5:-0} >= 60)}" && l5_reset=$(fmt_reset "$l5r")
awk "BEGIN{exit !(${l7:-0} >= 60)}" && l7_reset=$(fmt_reset "$l7r")

# ---- line 1 -----------------------------------------------------------------
branch=""
if git_branch=$(GIT_OPTIONAL_LOCKS=0 git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null); then
  branch="$git_branch"
fi

line1="\033[1;32m➜\033[0m  \033[0;36m${dir}\033[0m"
[ -n "$branch" ] && line1="${line1} \033[1;34mgit:(\033[0;31m${branch}\033[1;34m)\033[0m"

if [ -n "$model" ]; then
  # Make the 1M window explicit when it is engaged but not already named.
  label="$model"
  if [ "$exceeds" = "true" ] && [ "${model#*1M}" = "$model" ]; then
    label="${model} 1M"
  fi
  line1="${line1} \033[0;35m[${label}]\033[0m"
fi
[ -n "$effort" ] && line1="${line1} \033[0;90m·${effort}\033[0m"
[ "$fast" = "true" ] && line1="${line1} \033[0;33m·fast\033[0m"

# ---- line 2 -----------------------------------------------------------------
line2=$(awk -v used="${used:-1}" -v tok="${in_tok:-0}" -v win="${win:-0}" \
            -v l5="${l5:--1}" -v l7="${l7:--1}" -v l5r="$l5_reset" -v l7r="$l7_reset" '
  function human(n) {
    if (n >= 1000000) return sprintf("%.1fM", n / 1000000)
    if (n >= 1000)    return sprintf("%dk", n / 1000 + 0.5)
    return sprintf("%d", n)
  }
  function col(pct, warn, crit) {           # green -> amber -> red, by percentage
    if (pct >= crit) return "\033[0;31m"
    if (pct >= warn) return "\033[0;33m"
    return "\033[0;32m"
  }
  function ctxcol(t) {                      # context: absolute token bands, not %
    if (t > 200000) return "\033[0;31m"     # red    above 200k
    if (t > 100000) return "\033[38;5;208m" # orange 100k-200k
    return "\033[0;32m"                     # green  up to 100k
  }
  function bar(pct,   cells, filled, i, s) {
    cells = 8; filled = int(pct / 100 * cells + 0.5)
    if (filled > cells) filled = cells
    if (filled < 1 && pct > 0) filled = 1
    s = ""
    for (i = 0; i < cells; i++) s = s (i < filled ? "▓" : "░")
    return s
  }
  BEGIN {
    R = "\033[0m"; D = "\033[0;90m"
    out = D "ctx " R
    if (used < 0) {
      out = out D "—" R                     # no API call yet this session
    } else {
      c = ctxcol(tok)
      out = out c human(tok) D "/" human(win) R "  " c bar(used) sprintf(" %d%%", used + 0.5) R
    }
    if (l5 >= 0) {
      c = col(l5, 60, 85)
      out = out "  " D "5h " R c sprintf("%d%%", l5 + 0.5) R
      if (l5r != "") out = out D "↻" l5r R
    }
    if (l7 >= 0) {
      c = col(l7, 60, 85)
      out = out "  " D "7d " R c sprintf("%d%%", l7 + 0.5) R
      if (l7r != "") out = out D "↻" l7r R
    }
    print "   " out
  }
')

printf "%b\n%b\n" "$line1" "$line2"
