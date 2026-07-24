#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
t_setup

agent() { TMUX_SOCKET_OVERRIDE="$TMUX_SOCK" bash "$SCRIPTS/agent.sh" "$@"; }

wt="$T_TMP/base/repo-xxxxxxxx/worker"
mkdir -p "$wt"
$TMUX_CMD new-session -d -s claude-repo-worker -c "$wt" 'bash --norc'
$TMUX_CMD set-option -t claude-repo-worker @claude_worktree "$wt"
sigfile="$T_TMP/base/repo-xxxxxxxx/.worker.signals"

# signal writes the sidecar file (outside the worktree — keeps it clean)
assert_ok agent signal worker 'done' --body 'all tests green'
assert_ok test -f "$sigfile"
assert_eq "$(cut -f2 "$sigfile")" 'done' sig-type
assert_ok test ! -e "$wt/.claude-signals"

# wait --signal returns immediately when the signal already exists
assert_ok agent wait worker --signal 'done' --timeout 3
# and times out (exit 1) for a type never sent
assert_fail agent wait worker --signal 'blocked' --timeout 2

# wait --signal unblocks when the signal arrives mid-wait
rm "$sigfile"
( sleep 2; printf '%s\tdone\tlate\n' "$(date +%s)" >> "$sigfile" ) &
assert_ok agent wait worker --signal 'done' --timeout 10

# wait --match on pane output
assert_ok agent send worker 'echo MAGIC-TOKEN-42'
assert_ok agent wait worker --match 'MAGIC-TOKEN-42' --timeout 10
assert_fail agent wait worker --match 'NEVER-PRINTED' --timeout 2
assert_ok agent send worker 'echo ABC-123'
assert_ok agent wait worker --match 'ABC-[0-9]+' --regex --timeout 10

# json shape on timeout
agent wait worker --signal blocked --timeout 1 --json |
  jq -e '.ok == false and .timeout == true' >/dev/null || _fail wait-json

t_teardown
