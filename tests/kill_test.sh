#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
t_setup

agent() { TMUX_SOCKET_OVERRIDE="$TMUX_SOCK" bash "$SCRIPTS/agent.sh" "$@"; }

repo="$(t_repo alpha)"
mk_agent() { # <name> — real worktree + session running sleep
  local wt="$T_TMP/wtbase/alpha-h/$1"
  mkdir -p "$T_TMP/wtbase/alpha-h"
  git -C "$repo" worktree add -q -b "$1" "$wt"
  $TMUX_CMD new-session -d -s "claude-alpha-$1" -c "$wt" 'sleep 300'
  $TMUX_CMD set-option -t "claude-alpha-$1" @claude_worktree "$wt"
}

# clean kill: worktree gone, branch survives, session gone
mk_agent clean1
assert_ok agent kill clean1
assert_ok test ! -d "$T_TMP/wtbase/alpha-h/clean1"
assert_ok git -C "$repo" show-ref --verify --quiet refs/heads/clean1
assert_fail $TMUX_CMD has-session -t '=claude-alpha-clean1'

# dirty kill: worktree preserved, session gone
mk_agent dirty1
echo change > "$T_TMP/wtbase/alpha-h/dirty1/f.txt"
out="$(agent kill dirty1 --json)"
printf '%s' "$out" | jq -e '.worktree == "preserved"' >/dev/null || _fail dirty-json
assert_ok test -d "$T_TMP/wtbase/alpha-h/dirty1"
assert_fail $TMUX_CMD has-session -t '=claude-alpha-dirty1'

# sidecar signals removed with a clean worktree
mk_agent sig1
agent signal sig1 "done" --body x >/dev/null
assert_ok test -f "$T_TMP/wtbase/alpha-h/.sig1.signals"
assert_ok agent kill sig1
assert_ok test ! -e "$T_TMP/wtbase/alpha-h/.sig1.signals"

t_teardown
