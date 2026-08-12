#!/usr/bin/env bash
# The jump key: no picker, no choosing — straight to the agent that most wants
# you. Same scratch-server-with-a-real-client setup the picker test uses, since
# the only honest proof is where the client ends up.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
t_setup
export TMUX_TMPDIR=""
WT_BASE="$T_TMP/wt"

$TMUX_CMD set-option -g @claude_worktree_dir "$WT_BASE"
$TMUX_CMD set-option -g @claude_command 'sleep 300'

spawn() { TMUX_SOCKET_OVERRIDE="$TMUX_SOCK" bash "$SCRIPTS/spawn.sh" "$@"; }

repo="$(t_repo alpha)"
hash8="$(. "$SCRIPTS/helpers.sh"; session_hash "$(git -C "$repo" rev-parse --show-toplevel)")"
wt_parent="$WT_BASE/alpha-$hash8"

# The user's session, two windows: landing on the wrong one has to be visible.
$TMUX_CMD new-session -d -s user -x 200 -y 50 -c "$T_TMP" 'sleep 300'
$TMUX_CMD rename-window -t 'user:' home
home_win="$($TMUX_CMD list-windows -t '=user' -F '#{window_id}' | head -1)"
$TMUX_CMD new-window -d -t '=user:' -c "$T_TMP" 'sleep 300'
host_pane="$($TMUX_CMD list-panes -t "=user:$home_win" -F '#{pane_id}')"

$TMUX_CMD new-session -d -s host -x 200 -y 50 -c "$T_TMP" 'sleep 300'
$TMUX_CMD new-session -d -s userhost -x 200 -y 50 -c "$T_TMP" \
  "env -u TMUX $TMUX_CMD attach -t user"
sleep 2
client="$($TMUX_CMD list-clients -t user -F '#{client_name}' | head -1)"
[ -n "$client" ] || { _fail 'no client attached to the user session'; t_teardown; }

# Three agents, three shapes. No tasks: a task would type itself into these
# panes, which proves nothing here and only makes the captures noisier.
tab_sess="$(spawn tabby "$repo")"
tab_win="$($TMUX_CMD list-windows -t "=$tab_sess" -F '#{window_id}')"
tab_pid="$($TMUX_CMD list-panes -t "=$tab_sess" -F '#{pane_pid}')"
split_pane="$(spawn splitty "$repo" '' --split h --target "$host_pane")"
split_pid="$($TMUX_CMD display-message -p -t "$split_pane" '#{pane_pid}')"
loose_pane="$($TMUX_CMD split-window -d -P -F '#{pane_id}' -t "$host_pane" -c "$repo" 'sleep 300')"
loose_pid="$($TMUX_CMD display-message -p -t "$loose_pane" '#{pane_pid}')"

park() {
  $TMUX_CMD select-window -t "=user:$home_win"
  $TMUX_CMD select-pane -t "$host_pane"
  sleep 1
  assert_eq "$(client_window)" "$home_win" "$1: client parked on its own window first"
}

# ------------------------------------------- waiting wins, wherever it lives

# The dedicated agent is the one asking for input; it is not even open as a tab
# yet, so the jump has to link it in and land the client on it.
t_session "$tab_pid" waiting "$wt_parent/tabby"
t_session "$split_pid" idle "$wt_parent/splitty"
t_session "$loose_pid" busy "$repo"

park 'dedicated'
in_pane jump1 "$SCRIPTS/jump.sh $client"
assert_eq "$(client_window)" "$tab_win" 'jump lands on the waiting dedicated agent'

# Now the split agent is the one waiting: same key, other shape — focused in
# place, in the window it already lives in.
t_session "$tab_pid" busy "$wt_parent/tabby"
t_session "$split_pid" waiting "$wt_parent/splitty"

park 'split'
in_pane jump2 "$SCRIPTS/jump.sh $client"
assert_eq "$(client_pane)" "$split_pane" 'jump lands on the waiting split agent'

# Nobody waiting: idle outranks working, so the jump goes to the idle one.
t_session "$tab_pid" busy "$wt_parent/tabby"
t_session "$split_pid" busy "$wt_parent/splitty"
t_session "$loose_pid" idle "$repo"

park 'idle'
in_pane jump3 "$SCRIPTS/jump.sh $client"
assert_eq "$(client_pane)" "$loose_pane" 'with nobody waiting, the jump goes to the idle agent'

# ------------------------------------------------------------- no agents

t_no_sessions
park 'empty'
in_pane jump4 "$SCRIPTS/jump.sh $client"
assert_eq "$(client_window)" "$home_win" 'with no agents the client is left alone'
grep -q . "$T_TMP/jump4.out" && _fail "jump.sh wrote to stdout: $(cat "$T_TMP/jump4.out")"

t_teardown
