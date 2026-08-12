#!/usr/bin/env bash
# status_of, through both data sources: the session files a running Claude
# publishes (primary) and `claude agents --json` (fallback, mocked here).
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
t_setup
chmod +x "$TESTDIR/fixtures/claude"
export PATH="$TESTDIR/fixtures:$PATH"

agent() { TMUX_SOCKET_OVERRIDE="$TMUX_SOCK" bash "$SCRIPTS/agent.sh" "$@"; }

$TMUX_CMD new-session -d -s claude-repo-w -c "$T_TMP" 'bash --norc'
$TMUX_CMD set-option -t claude-repo-w @claude_worktree "$T_TMP"
sleep 1
# the pane's shell pid is the agent pid, whichever source reports it
pid="$($TMUX_CMD list-panes -t claude-repo-w -F '#{pane_pid}')"
export CLAUDE_MOCK_PID="$pid"

check_both_ways() {
  set_status idle
  assert_ok agent wait w --status idle --timeout 5
  set_status busy
  assert_fail agent wait w --status idle --timeout 2
  assert_ok agent wait w --status busy --timeout 5
  set_status waiting
  assert_ok agent wait w --status waiting --timeout 5
}

# shellcheck disable=SC2329  # called through check_both_ways
set_status() { t_session "$pid" "$1"; }
check_both_ways

# A raw state the files carry but callers do not know: the CLI reports it as
# busy, so this must too, or `wait --status busy` hangs on a working agent.
t_session "$pid" shell
assert_ok agent wait w --status busy --timeout 5

# No session files: the same answers come from `claude agents --json`.
t_no_sessions
# shellcheck disable=SC2329  # called through check_both_ways
set_status() { export CLAUDE_MOCK_STATUS="$1"; }
check_both_ways

t_teardown
