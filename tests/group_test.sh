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

# Status filters, read from the session files. Two agents with two different
# statuses is what the single-agent CLI mock could never express: each filter
# has to pick one and leave the other.
pid_a="$($TMUX_CMD list-panes -t claude-r-a -F '#{pane_pid}')"
pid_b="$($TMUX_CMD list-panes -t claude-r-b -F '#{pane_pid}')"
t_session "$pid_a" idle
t_session "$pid_b" busy
out="$(agent send @idle --json 'echo idle-only')"
printf '%s' "$out" | jq -e '.targets == ["claude-r-a"]' >/dev/null || _fail idle-filter
out="$(agent send @busy --json 'echo busy-only')"
printf '%s' "$out" | jq -e '.targets == ["claude-r-b"]' >/dev/null || _fail busy-filter
t_session "$pid_b" waiting
out="$(agent send @waiting --json 'echo waiting-only')"
printf '%s' "$out" | jq -e '.targets == ["claude-r-b"]' >/dev/null || _fail waiting-filter

# groups rejected where they make no sense
assert_fail agent kill @all
assert_fail agent read @idle

# @idle with zero matches must fail loudly, not silently "send to nobody"
t_session "$pid_a" busy
assert_fail agent send @idle 'echo nobody-home'

# Same filter with no session files at all, through the `claude agents --json`
# fallback — which reports one agent, so agent b drops out.
t_no_sessions
export CLAUDE_MOCK_PID="$pid_a"
export CLAUDE_MOCK_STATUS=idle
out="$(agent send @idle --json 'echo fallback-idle')"
printf '%s' "$out" | jq -e '.targets == ["claude-r-a"]' >/dev/null || _fail idle-filter-fallback
export CLAUDE_MOCK_STATUS=busy
assert_fail agent send @idle 'echo nobody-home'

t_teardown
