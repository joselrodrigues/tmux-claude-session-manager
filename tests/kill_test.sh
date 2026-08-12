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
out="$(agent kill plain --json 2>"$T_TMP/plain_stderr.txt")"
plain_err="$(cat "$T_TMP/plain_stderr.txt" 2>/dev/null || echo)"
printf '%s' "$out" | jq -e '.worktree == "none"' >/dev/null || _fail plain-json
[ -z "$plain_err" ] || _fail "plain-stderr: $plain_err"
assert_fail $TMUX_CMD has-session -t '=claude-alpha-plain'

# an agent opened as a tab elsewhere: killing it must take the tab with it,
# rather than leaving a dead window behind in someone else's session
mk_agent linked1
$TMUX_CMD new-session -d -s host -c "$T_TMP" 'sleep 300'
linked_win="$($TMUX_CMD list-windows -t '=claude-alpha-linked1' -F '#{window_id}')"
$TMUX_CMD link-window -s "$linked_win" -t '=host:'
assert_eq "$($TMUX_CMD list-windows -t '=host' -F '#{window_id}' | grep -cx "$linked_win")" \
  1 'agent opened as a tab in host'
assert_ok agent kill linked1
assert_eq "$($TMUX_CMD list-windows -t '=host' -F '#{window_id}' | grep -cx "$linked_win")" \
  0 'killing the agent closed its tab'
assert_fail $TMUX_CMD has-session -t '=claude-alpha-linked1'
$TMUX_CMD kill-session -t '=host' 2>/dev/null

# loose pane in a session without the claude- prefix: kill must refuse it
# rather than tearing down the whole session (and whatever else lives in it)
$TMUX_CMD new-session -d -s work -c "$T_TMP" 'sleep 300'
work_pid="$($TMUX_CMD list-panes -t work -F '#{pane_pid}')"
work_pane="$($TMUX_CMD list-panes -t work -F '#{pane_id}')"
assert_fail agent kill "$work_pane"
assert_ok $TMUX_CMD has-session -t '=work'
assert_ok command kill -0 "$work_pid"
$TMUX_CMD kill-session -t '=work' 2>/dev/null

# clean worktree WITH submodules: git refuses `worktree remove` outright, so
# kill falls back to rm -rf + prune — same outcome, and only for this exact
# refusal (the locked case above must stay preserved)
sub="$T_TMP/subrepo"
mkdir -p "$sub" && git -C "$sub" init -q -b main
git -C "$sub" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$repo" -c protocol.file.allow=always submodule add -q "$sub" themod 2>/dev/null
git -C "$repo" -c user.email=t@t -c user.name=t commit -q -m 'add submodule'
mk_agent submod1
git -C "$T_TMP/wtbase/alpha-h/submod1" -c protocol.file.allow=always \
  submodule update --init -q 2>/dev/null
out="$(agent kill submod1 --json)"
printf '%s' "$out" | jq -e '.worktree == "removed"' >/dev/null || _fail submod-json
assert_ok test ! -d "$T_TMP/wtbase/alpha-h/submod1"
assert_ok git -C "$repo" show-ref --verify --quiet refs/heads/submod1
assert_fail $TMUX_CMD has-session -t '=claude-alpha-submod1'

t_teardown
