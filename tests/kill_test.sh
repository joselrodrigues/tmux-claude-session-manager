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

# signals preserved when worktree removal fails (locked worktree)
mk_agent locked1
agent signal locked1 "done" --body x >/dev/null
wt_path="$T_TMP/wtbase/alpha-h/locked1"
signals_path="$T_TMP/wtbase/alpha-h/.locked1.signals"
assert_ok test -f "$signals_path"
# Lock the worktree to force removal to fail
assert_ok git -C "$repo" worktree lock "$wt_path"
out="$(agent kill locked1 --json)"
printf '%s' "$out" | jq -e '.worktree == "preserved"' >/dev/null || _fail locked-json
assert_ok test -d "$wt_path"
assert_ok test -f "$signals_path"

# plain session without worktree: no stderr, worktree:none
$TMUX_CMD new-session -d -s claude-alpha-plain -c "$repo" 'sleep 300'
out="$(agent kill plain --json 2>/tmp/plain_stderr.txt)"
plain_err="$(cat /tmp/plain_stderr.txt 2>/dev/null || echo)"
printf '%s' "$out" | jq -e '.worktree == "none"' >/dev/null || _fail plain-json
[ -z "$plain_err" ] || _fail "plain-stderr: $plain_err"
assert_fail $TMUX_CMD has-session -t '=claude-alpha-plain'

t_teardown
