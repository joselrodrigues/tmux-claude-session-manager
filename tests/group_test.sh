#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
t_setup
chmod +x "$TESTDIR/fixtures/claude"
export PATH="$TESTDIR/fixtures:$PATH"

agent() { TMUX_SOCKET_OVERRIDE="$TMUX_SOCK" bash "$SCRIPTS/agent.sh" "$@"; }

for n in a b; do
  $TMUX_CMD new-session -d -s "claude-r-$n" -c "$T_TMP" 'bash --norc'
  $TMUX_CMD set-option -t "claude-r-$n" @claude_worktree "$T_TMP"
done
$TMUX_CMD new-session -d -s claude-deadbeef -c "$T_TMP" 'bash --norc'  # hash session: no worktree option
sleep 1

# @all hits both agents, skips the hash session
out="$(agent send @all --json 'echo hi')"
printf '%s' "$out" | jq -e '.targets | length == 2' >/dev/null || _fail all-count

# @idle: mock reports pane pid of agent a only
pid="$($TMUX_CMD list-panes -t claude-r-a -F '#{pane_pid}')"
export CLAUDE_MOCK_PID="$pid"
export CLAUDE_MOCK_STATUS=idle
out="$(agent send @idle --json 'echo idle-only')"
printf '%s' "$out" | jq -e '.targets == ["claude-r-a"]' >/dev/null || _fail idle-filter

# groups rejected where they make no sense
assert_fail agent kill @all
assert_fail agent read @idle

# @idle with zero matches must fail loudly, not silently "send to nobody"
export CLAUDE_MOCK_STATUS=busy
assert_fail agent send @idle 'echo nobody-home'

t_teardown
