#!/usr/bin/env bash
# Ghost sessions: tmux-continuum/resurrect bring back a `claude-*` session with
# the right name, a bare shell inside it and no Claude anywhere. The name alone
# used to block that agent from ever being spawned again.
#
# The two liveness signals are exercised separately, because either one alone
# would answer wrong in one direction: a published agent (a Claude that is
# there but says nothing about its pane) and the pane's own process being the
# configured @claude_command (a Claude too young to have published itself).
# The fake here runs `cat`: alive, holding the pane, and nothing to do with
# @claude_command — which in this suite is `sleep 300`, exactly as a restored
# login shell has nothing to do with the real `claude`.
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

pane_pid_of() { $TMUX_CMD list-panes -t "=$1" -F '#{pane_pid}' | head -1; }

# ------------------------------------------------------- a ghost is recycled

$TMUX_CMD new-session -d -s claude-alpha-ghosty -c "$T_TMP" 'cat'
ghost_pid="$(pane_pid_of claude-alpha-ghosty)"
assert_ok spawn ghosty "$repo"
assert_ok $TMUX_CMD has-session -t '=claude-alpha-ghosty'
assert_ok test -d "$wt_parent/ghosty"
[ "$(pane_pid_of claude-alpha-ghosty)" = "$ghost_pid" ] &&
  _fail 'the ghost session was kept instead of recycled'
command kill -0 "$ghost_pid" 2>/dev/null && _fail 'the ghost process outlived its session'
assert_eq "$($TMUX_CMD show-option -t claude-alpha-ghosty -qv @claude_agent_name)" \
  ghosty 'the recycled session is a real agent session'

# Stale stamps do not make a ghost live: resurrect restores what it restores,
# and an option is not a process.
$TMUX_CMD new-session -d -s claude-alpha-stamped -c "$T_TMP" 'cat'
$TMUX_CMD set-option -t claude-alpha-stamped @claude_worktree "$wt_parent/stamped"
$TMUX_CMD set-option -t claude-alpha-stamped @claude_agent_name stamped
assert_ok spawn stamped "$repo"
assert_ok test -d "$wt_parent/stamped"

# A pane whose process is already dead (remain-on-exit keeps the corpse on
# screen) is a ghost by the same rule.
$TMUX_CMD new-session -d -s claude-alpha-dead -c "$T_TMP" 'true'
$TMUX_CMD set-option -t claude-alpha-dead remain-on-exit on
sleep 1
assert_ok spawn dead "$repo"
assert_ok test -d "$wt_parent/dead"

# ------------------------------------------- a live agent is never recycled

# Signal one: Claude has published itself against that pane's tty. The pane
# runs `cat`, so the command check cannot save it — the session file is the
# only thing saying "there is an agent here", and it must be enough.
$TMUX_CMD new-session -d -s claude-alpha-livey -c "$T_TMP" 'cat'
live_pid="$(pane_pid_of claude-alpha-livey)"
t_session "$live_pid" busy "$wt_parent/livey"
assert_fail spawn livey "$repo"
assert_ok $TMUX_CMD has-session -t '=claude-alpha-livey'
assert_eq "$(pane_pid_of claude-alpha-livey)" "$live_pid" 'the live agent kept its process'
assert_ok test ! -d "$wt_parent/livey"

# Signal two: nothing published (a Claude that just started), but the pane is
# running the configured claude command. Spawned for real, then re-spawned.
assert_ok spawn young "$repo"
young_pid="$(pane_pid_of claude-alpha-young)"
err="$(spawn young "$repo" 2>&1 >/dev/null)"
case "$err" in
*'already running'*) : ;;
*) _fail "an unpublished but running agent must be refused, not recycled: $err" ;;
esac
assert_eq "$(pane_pid_of claude-alpha-young)" "$young_pid" 'the young agent kept its process'

t_teardown
