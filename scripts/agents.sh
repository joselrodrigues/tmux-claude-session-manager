#!/usr/bin/env bash
# Emit one picker row per running Claude that lives in a tmux pane.
#
# Claude self-reports its status: each session writes its own state to disk, which
# claude_agents_tsv reads. So this needs no Claude Code hooks, and no
# `pane_current_command` scan — on macOS a pane reports its parent shell there,
# never the `claude` child running inside it.
#
# Identity is the Claude process, not the tmux session. Joining pid -> tty -> pane
# is what lets several Claudes in one project (same cwd, same session, different
# windows) each get a row of their own.
#
#   Row: rank \t pane_id \t pid \t kind \t icon \t age \t loc \t path \t branch \t task
#   rank/pane_id/pid/kind are hidden from the display via fzf's --with-nth.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

rows="$(claude_agents_tsv)"
[ -n "$rows" ] || exit 0

# The session files carry a last-activity time of their own, so only the CLI
# fallback — which does not — costs a stat per row. Resolved out here because
# only `stat`, outside awk, can read an mtime.
mtimes="$(printf '%s\n' "$rows" | awk -F'\t' '$5 == "" { print $3 }' |
  while IFS= read -r sid; do
    printf 'M\t%s\t%s\n' "$sid" "$(claude_transcript_mtime "$sid")"
  done)"

# Three tagged streams into one awk: pid->tty, tty->pane, session->last-activity.
# Total cost is 3 subprocesses regardless of how many sessions or panes exist.
{
  ps -Ao pid=,tty= 2>/dev/null | awk '{ print "P\t" $1 "\t" $2 }'
  tmux list-panes -a -F $'T\t#{pane_tty}\t#{pane_id}\t#{session_name}\t#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null
  printf '%s\n' "$mtimes"
  printf '%s\n' "$rows" | sed $'s/^/A\t/'
} | awk -F'\t' -v now="$(date +%s)" -v home="$HOME" \
  -v prefix="$(get_tmux_option @claude_session_prefix 'claude-')" '
  $1 == "P" { tty_of[$2] = $3; next }
  $1 == "T" {
    sub(/^\/dev\//, "", $2)
    pane[$2] = $3
    # An agent opened as a tab lives in two sessions at once, so list-panes -a
    # walks its pane twice and last-one-wins keeps whichever session sorts
    # later -- usually the one you linked it into, which read the agent as
    # loose and lost the task stamped on its own session. Same two-rows trap
    # pulse.sh documents; the dedicated session is the one describing the agent.
    # (No apostrophes in here: the awk program is single-quoted.)
    if (!($2 in sess) || index($4, prefix) == 1) { sess[$2] = $4; loc[$2] = $5 }
    next
  }
  $1 == "M" { seen_at[$2] = $3; next }
  $1 == "A" {
    tty = tty_of[$2]
    if (tty == "" || !(tty in pane)) next   # this Claude is not running inside tmux

    if      ($3 == "waiting") { icon = "\033[33m●\033[0m waiting"; rank = 0 }  # yellow - needs input
    else if ($3 == "idle")    { icon = "\033[32m●\033[0m idle   "; rank = 1 }  # green  - done, your turn
    else if ($3 == "busy")    { icon = "\033[31m●\033[0m working"; rank = 3 }  # red    - busy, leave it
    else                      { icon = "\033[90m●\033[0m   ?    "; rank = 2 }  # grey   - unrecognised status

    at = ($6 != "") ? $6 : seen_at[$4]
    age = (at != "") ? int((now - at) / 60) "m" : "-"
    kind = (index(sess[tty], prefix) == 1) ? "dedicated" : "loose"

    path = $5
    if (index(path, home) == 1) path = "~" substr(path, length(home) + 1)

    printf "%s\t%s\t%s\t%s\t%s\t%5s\t%s\t%s\t%s\t%s\n",
      rank, pane[tty], $2, kind, icon, age, loc[tty], path, $5, sess[tty]
  }
' | sort -t$'\t' -k1,1n -k6,6n | while IFS=$'\t' read -r rank pane pid kind icon age loc path cwd sess; do
  branch="$(git -C "$cwd" branch --show-current 2>/dev/null)"
  if [ -n "$branch" ]; then
    [ -n "$(git -C "$cwd" status --porcelain --untracked-files=no 2>/dev/null | head -1)" ] &&
      branch="$branch*"
  else
    branch='-'
  fi
  # $sess comes from awk, not from `display-message -t $pane`: a linked pane
  # belongs to two sessions, so asking tmux which one it is in answers with
  # whichever it likes — and for a tab agent that is the user's session, which
  # carries none of the agent's stamps.
  #
  # A split agent lives in an ordinary session and is stamped on its pane, so
  # the awk above — which knows only session names — can only have called it
  # loose. Pane options do not inherit, so this asks the pane itself.
  if [ -n "$(tmux show-option -p -t "$pane" -qv @claude_worktree 2>/dev/null)" ]; then
    kind='split'
    task="$(tmux show-option -p -t "$pane" -qv @claude_task 2>/dev/null)"
  else
    task="$(tmux show-option -t "$sess" -qv @claude_task 2>/dev/null)"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$rank" "$pane" "$pid" "$kind" "$icon" "$age" "$loc" "$path" "$branch" "${task:--}"
done
# rank asc (what needs you floats up), then age asc so whatever just went idle
# sits at the top of its group. -k6,6n reads the leading number of the age field
# ("5m" -> 5; "-" -> 0).
