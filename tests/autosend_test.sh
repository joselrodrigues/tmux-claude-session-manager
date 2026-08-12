#!/usr/bin/env bash
# The task a spawn collects is typed into the agent — but only once the agent
# is there to receive it, and never at the cost of the popup staying open.
#
# The agent panes run `sleep 300` (the test @claude_command), so anything
# send-keys types into them is echoed by the tty and shows up in capture-pane.
# That echo is the evidence throughout this file.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
t_setup
export TMUX_TMPDIR=""
WT_BASE="$T_TMP/wt"

$TMUX_CMD set-option -g @claude_worktree_dir "$WT_BASE"
$TMUX_CMD set-option -g @claude_command 'sleep 300'

spawn() { TMUX_SOCKET_OVERRIDE="$TMUX_SOCK" bash "$SCRIPTS/spawn.sh" "$@"; }

# wait_text <pane> <text> [seconds] — the send is asynchronous by design, so
# every assertion about it is a poll, not a look.
wait_text() {
  local i=0 max=$(( ${3:-10} * 2 ))
  while [ "$i" -lt "$max" ]; do
    case "$($TMUX_CMD capture-pane -p -t "$1" 2>/dev/null)" in
    *"$2"*) return 0 ;;
    esac
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}
has_text() {
  case "$($TMUX_CMD capture-pane -p -t "$1" 2>/dev/null)" in
  *"$2"*) return 0 ;;
  esac
  return 1
}

repo="$(t_repo alpha)"
hash8="$(. "$SCRIPTS/helpers.sh"; session_hash "$(git -C "$repo" rev-parse --show-toplevel)")"
wt_parent="$WT_BASE/alpha-$hash8"

$TMUX_CMD new-session -d -s host -x 200 -y 50 -c "$T_TMP" 'sleep 300'
host_pane="$($TMUX_CMD list-panes -t '=host' -F '#{pane_id}')"

# ------------------------------------------------- tab agent: after, not before

sess="$(spawn tabby "$repo" 'run the tests')"
tab_pane="$($TMUX_CMD list-panes -t "=$sess" -F '#{pane_id}')"
tab_pid="$($TMUX_CMD list-panes -t "=$sess" -F '#{pane_pid}')"

# The pane exists and is writable from the first instant; what is missing is the
# Claude that would read it. Sending here is the bug this feature must not have.
sleep 2
has_text "$tab_pane" 'run the tests' &&
  _fail 'the task was typed before the agent registered'

t_session "$tab_pid" idle "$wt_parent/tabby"
wait_text "$tab_pane" 'run the tests' ||
  _fail "task never reached the tab agent: [$($TMUX_CMD capture-pane -p -t "$tab_pane")]"

# ------------------------------------------------------------------ split agent

split_pane="$(spawn splitty "$repo" 'chase the flaky test' --split h --target "$host_pane")"
split_pid="$($TMUX_CMD display-message -p -t "$split_pane" '#{pane_pid}')"
t_session "$split_pid" waiting "$wt_parent/splitty"
wait_text "$split_pane" 'chase the flaky test' ||
  _fail "task never reached the split agent: [$($TMUX_CMD capture-pane -p -t "$split_pane")]"

# ------------------------------------------- an agent that never shows up

# No session file is ever written for this one: the waiter must give up in
# silence, and spawn.sh must not have waited for it in the first place.
t0="$(date +%s)"
lonely="$(spawn lonely "$repo" 'never sent' --split v --target "$host_pane")"
elapsed=$(($(date +%s) - t0))
[ "$elapsed" -lt 5 ] || _fail "spawn blocked ${elapsed}s on an agent that never registered"
sleep 4
has_text "$lonely" 'never sent' &&
  _fail 'text was sent to an agent that never registered'
# The task is not lost — it is still on the pane for the picker to show.
assert_eq "$($TMUX_CMD show-option -p -t "$lonely" -qv @claude_task)" 'never sent' task-stamp-kept

# ------------------------------------------------------- the popup path itself

# The waiter is detached (fds closed, HUP ignored) so the spawn popup can close
# while it is still polling. Nothing but a real popup proves that: keys go to
# the pane running the attach, which is the client's own tty, and what that pane
# shows is what the client's screen shows — popup included.
$TMUX_CMD new-session -d -s user -x 200 -y 50 -c "$T_TMP" 'sleep 300'
$TMUX_CMD new-session -d -s userhost -x 200 -y 50 -c "$T_TMP" \
  "env -u TMUX $TMUX_CMD attach -t user"
sleep 2
client="$($TMUX_CMD list-clients -t user -F '#{client_name}' | head -1)"
screen_pane="$($TMUX_CMD list-panes -t '=userhost' -F '#{pane_id}')"

if [ -z "$client" ]; then
  _fail 'no client attached to the user session; the popup case would prove nothing'
else
  $TMUX_CMD display-popup -c "$client" -w 90% -h 90% -E \
    "$SCRIPTS/spawn-prompt.sh $repo $client" &
  if wait_text "$screen_pane" 'agent name' 10; then
    $TMUX_CMD send-keys -t "$screen_pane" -l 'popupy'
    $TMUX_CMD send-keys -t "$screen_pane" Enter
    sleep 1
    $TMUX_CMD send-keys -t "$screen_pane" -l 'ship it'
    $TMUX_CMD send-keys -t "$screen_pane" Enter
    # The base-branch selector is part of this flow; enter takes the default,
    # once fzf has finished painting it (see settle).
    wait_text "$screen_pane" 'base branch' 10 ||
      _fail "the base selector never appeared: [$($TMUX_CMD capture-pane -p -t "$screen_pane")]"
    settle "$screen_pane"

    # Closed while the waiter is still polling — that is the whole point, and it
    # needs no stopwatch: nothing has published this agent yet and nothing will
    # until the session file below is written, so the waiter cannot be finished.
    # A popup that is gone here is a popup that did not wait for it.
    popup_closed() { ! has_text "$screen_pane" 'agent name'; }
    press_until "$screen_pane" Enter 10 popup_closed ||
      _fail "the popup never closed: [$($TMUX_CMD capture-pane -p -t "$screen_pane")]"

    if $TMUX_CMD has-session -t '=claude-alpha-popupy' 2>/dev/null; then
      pop_pane="$($TMUX_CMD list-panes -t '=claude-alpha-popupy' -F '#{pane_id}' | head -1)"
      pop_pid="$($TMUX_CMD list-panes -t '=claude-alpha-popupy' -F '#{pane_pid}' | head -1)"
      t_session "$pop_pid" idle "$wt_parent/popupy"
      # The popup is gone and its pty with it; the waiter it left behind still
      # has to deliver.
      wait_text "$pop_pane" 'ship it' ||
        _fail "the detached waiter died with the popup: [$($TMUX_CMD capture-pane -p -t "$pop_pane")]"
    else
      _fail 'the popup spawn produced no agent session'
    fi
  else
    _fail "the spawn popup never appeared: [$($TMUX_CMD capture-pane -p -t "$screen_pane")]"
  fi
fi

t_teardown
