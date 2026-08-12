#!/usr/bin/env bash
# Split mode: a worktree agent living in a pane of a window you already have,
# with no session of its own — so every lookup that used to key on the session
# has to key on the pane stamp instead.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
t_setup
export TMUX_TMPDIR=""
WT_BASE="$T_TMP/wt"

spawn() {
  TMUX='' tmux -L "$TMUX_SOCK" set-option -g @claude_worktree_dir "$WT_BASE"
  TMUX='' tmux -L "$TMUX_SOCK" set-option -g @claude_command 'sleep 300'
  TMUX_SOCKET_OVERRIDE="$TMUX_SOCK" bash "$SCRIPTS/spawn.sh" "$@"
}
agent() { TMUX_SOCKET_OVERRIDE="$TMUX_SOCK" bash "$SCRIPTS/agent.sh" "$@"; }
pane_opt() { $TMUX_CMD show-option -p -t "$1" -qv "$2"; }
alive() { $TMUX_CMD list-panes -a -F '#{pane_id}' | grep -qx "$1"; }

repo="$(t_repo alpha)"
hash8="$(. "$SCRIPTS/helpers.sh"; session_hash "$(git -C "$repo" rev-parse --show-toplevel)")"
wt_parent="$WT_BASE/alpha-$hash8"

# The user's session: two windows, so "the invoking window" means something.
$TMUX_CMD new-session -d -s work -c "$T_TMP" 'sleep 300'
$TMUX_CMD rename-window -t 'work:' mywin
spare_win="$($TMUX_CMD new-window -d -P -F '#{window_id}' -t 'work:' -c "$T_TMP" 'sleep 300')"
my_win="$($TMUX_CMD list-windows -t '=work' -F '#{window_id}' -f '#{==:#{window_name},mywin}')"
host_pane="$($TMUX_CMD list-panes -t "=work:$my_win" -F '#{pane_id}')"
# Created last, so it is what tmux calls "current" for an untargeted command —
# the stand-in for the spawn popup. A --target that is not honoured lands here.
$TMUX_CMD new-session -d -s decoy -c "$T_TMP" 'sleep 300'

# happy path: the pane goes to the invoking window, stamped, and its id is the
# whole of stdout
pane="$(spawn api "$repo" 'fix login' --split h --target "$host_pane")"
case "$pane" in %[0-9]*) : ;; *) _fail "stdout is not a pane id: '$pane'" ;; esac
assert_eq "$($TMUX_CMD display-message -p -t "$pane" '#{window_id}')" "$my_win" split-in-invoking-window
assert_eq "$($TMUX_CMD display-message -p -t "$pane" '#{session_name}')" work split-in-invoking-session
assert_eq "$(pane_opt "$pane" @claude_worktree)" "$wt_parent/api" wt-pane-option
assert_eq "$(pane_opt "$pane" @claude_agent_name)" api name-pane-option
assert_eq "$(pane_opt "$pane" @claude_task)" 'fix login' task-pane-option
assert_ok test -d "$wt_parent/api"
assert_eq "$(git -C "$wt_parent/api" branch --show-current)" api branch-name

# no session of its own, and the window stays the user's: renaming it after the
# agent would be renaming someone else's window
assert_fail $TMUX_CMD has-session -t '=claude-alpha-api'
assert_eq "$($TMUX_CMD display-message -p -t "$pane" '#{window_name}')" mywin window-not-renamed

# -h puts the panes side by side, -v stacks them; empty name still auto-names
agent1="$(spawn '' "$repo" '' --split v --target "$host_pane")"
assert_eq "$(pane_opt "$agent1" @claude_agent_name)" agent1 auto-name-in-split
assert_eq "$($TMUX_CMD display-message -p -t "$pane" '#{pane_top}')" \
  "$($TMUX_CMD display-message -p -t "$host_pane" '#{pane_top}')" h-split-is-side-by-side
[ "$($TMUX_CMD display-message -p -t "$agent1" '#{pane_top}')" != \
  "$($TMUX_CMD display-message -p -t "$host_pane" '#{pane_top}')" ] ||
  _fail 'v-split should be stacked, not side by side'

# has-session cannot see a split agent, so respawning the same name would put a
# second Claude in the same worktree
err="$(spawn api "$repo" '' --split h --target "$host_pane" 2>&1 >/dev/null)"
case "$err" in
*'already running'*) : ;;
*) _fail "a duplicate split must be refused by the stamp guard, not by luck: $err" ;;
esac
assert_fail spawn api "$repo" '' --split sideways --target "$host_pane"

# bare name resolves through the pane stamp, and the worktree with it: the
# sidecar lands next to the worktree, not next to the host session's anything
assert_ok agent signal api 'done' --body ok
assert_ok test -f "$wt_parent/.api.signals"
assert_ok agent wait api --signal 'done' --timeout 3

# ambiguity still dies — two panes answering to one name is not a pick
$TMUX_CMD set-option -p -t "$host_pane" @claude_agent_name api
assert_fail agent read api
$TMUX_CMD set-option -pu -t "$host_pane" @claude_agent_name

# clean worktree: removed, sidecar with it, pane gone, host session untouched
assert_ok agent kill "$agent1"
assert_ok test ! -d "$wt_parent/agent1"
assert_ok git -C "$repo" show-ref --verify --quiet refs/heads/agent1
assert_fail alive "$agent1"
assert_ok $TMUX_CMD has-session -t '=work'
assert_ok alive "$host_pane"

# dirty worktree: preserved, and the sidecar preserved with it
echo change >"$wt_parent/api/f.txt"
out="$(agent kill api --json)"
printf '%s' "$out" | jq -e '.worktree == "preserved"' >/dev/null || _fail dirty-json
assert_ok test -d "$wt_parent/api"
assert_ok test -f "$wt_parent/.api.signals"
assert_fail alive "$pane"
assert_ok $TMUX_CMD has-session -t '=work'

# break-pane is the documented way to stash a split agent in its own window.
# The stamps ride along with the pane, so the kill still finds the worktree.
broken="$(spawn stash "$repo" '' --split h --target "$host_pane")"
$TMUX_CMD break-pane -d -s "$broken"
[ "$($TMUX_CMD display-message -p -t "$broken" '#{window_id}')" != "$my_win" ] ||
  _fail 'break-pane left the agent in the original window'
assert_ok agent kill "$broken"
assert_ok test ! -d "$wt_parent/stash"
assert_ok $TMUX_CMD has-session -t '=work'
assert_ok $TMUX_CMD has-session -t "=work:$spare_win"

# an unstamped pane is still not an agent, whatever session it sits in
assert_fail agent kill "$host_pane"
assert_ok alive "$host_pane"

t_teardown
