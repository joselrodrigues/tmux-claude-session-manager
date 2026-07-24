#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
t_setup
chmod +x "$TESTDIR/fixtures/claude"
export PATH="$TESTDIR/fixtures:$PATH"

agent() { TMUX_SOCKET_OVERRIDE="$TMUX_SOCK" bash "$SCRIPTS/agent.sh" "$@"; }

$TMUX_CMD new-session -d -s claude-repo-w -c "$T_TMP" 'bash --norc'
$TMUX_CMD set-option -t claude-repo-w @claude_worktree "$T_TMP"
sleep 1
# the pane's shell pid is what the mock reports as the agent pid
pid="$($TMUX_CMD list-panes -t claude-repo-w -F '#{pane_pid}')"
export CLAUDE_MOCK_PID="$pid"

export CLAUDE_MOCK_STATUS=idle
assert_ok agent wait w --status idle --timeout 5
export CLAUDE_MOCK_STATUS=busy
assert_fail agent wait w --status idle --timeout 2
assert_ok agent wait w --status busy --timeout 5

t_teardown
