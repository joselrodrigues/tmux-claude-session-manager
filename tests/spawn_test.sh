#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
t_setup
export TMUX_TMPDIR=""  # keep tmux calls on our -L socket via wrapper below
WT_BASE="$T_TMP/wt"

# spawn.sh talks to tmux; route it to the scratch server and a fake agent cmd.
spawn() {
  TMUX='' tmux -L "$TMUX_SOCK" set-option -g @claude_worktree_dir "$WT_BASE"
  TMUX='' tmux -L "$TMUX_SOCK" set-option -g @claude_command 'sleep 300'
  TMUX_SOCKET_OVERRIDE="$TMUX_SOCK" bash "$SCRIPTS/spawn.sh" "$@" --no-popup
}

repo="$(t_repo alpha)"

assert_ok test -x "$SCRIPTS/spawn.sh"

# happy path: worktree, branch, session, options
assert_ok spawn api "$repo" 'fix the login bug'
hash8="$(. "$SCRIPTS/helpers.sh"; session_hash "$(git -C "$repo" rev-parse --show-toplevel)")"
wt="$WT_BASE/alpha-$hash8/api"
assert_ok test -d "$wt"
assert_eq "$(git -C "$wt" branch --show-current)" api branch-name
assert_ok $TMUX_CMD has-session -t '=claude-alpha-api'
assert_eq "$($TMUX_CMD show-option -t claude-alpha-api -qv @claude_worktree)" "$wt" wt-option
assert_eq "$($TMUX_CMD show-option -t claude-alpha-api -qv @claude_task)" 'fix the login bug' task-option
assert_eq "$($TMUX_CMD show-option -t claude-alpha-api -qv @claude_agent_name)" api agent-name-option

# collision: same name again is rejected, not re-attached
assert_fail spawn api "$repo"

# same agent name in a second repo gets its own session (repo segment disjoint)
repo2="$(t_repo beta)"
assert_ok spawn api "$repo2"
assert_ok $TMUX_CMD has-session -t '=claude-beta-api'

# invalid names rejected before any git/tmux action
assert_fail spawn 'foo.lock' "$repo"
assert_fail spawn 'a..b' "$repo"
assert_fail spawn -x "$repo"

# non-repo dir rejected
assert_fail spawn ok "$T_TMP"

# existing-branch reuse: branch survives a worktree removal, respawn reuses it
git -C "$repo" worktree remove --force "$wt"
$TMUX_CMD kill-session -t '=claude-alpha-api'
assert_ok spawn api "$repo"
assert_eq "$(git -C "$WT_BASE/alpha-$hash8/api" branch --show-current)" api branch-reused

# dotted repo name: dots are deleted from the session name — tmux parses `.`
# in -t targets as window.pane, so `claude-.dotrepo-x` would be unaddressable
dotrepo="$(t_repo .dotrepo)"
assert_ok spawn dotty "$dotrepo"
assert_ok $TMUX_CMD has-session -t '=claude-dotrepo-dotty'

# empty name auto-generates agentN (herdr semantics), skipping taken slots
assert_ok spawn '' "$dotrepo"
assert_ok $TMUX_CMD has-session -t '=claude-dotrepo-agent1'
assert_ok spawn '' "$dotrepo"
assert_ok $TMUX_CMD has-session -t '=claude-dotrepo-agent2'

# stdout contract: spawn.sh prints only the session name (callers like
# spawn-prompt.sh hand exactly this to open_agent)
assert_eq "$(spawn foo2 "$repo")" claude-alpha-foo2 stdout-session-name

# the agent's window is labelled for the status bar, and stays labelled
assert_eq "$($TMUX_CMD list-windows -t '=claude-alpha-foo2' -F '#{window_name}')" \
  foo2 window-named-after-agent
assert_eq "$($TMUX_CMD list-windows -t '=claude-alpha-foo2' -F '#{automatic-rename}')" \
  0 automatic-rename-off

# open_agent shows an agent as a tab in the caller's session. helpers.sh calls
# bare `tmux`; shadow it onto the scratch socket inside a subshell so $TMUX_CMD
# out here keeps working.
open_agent_t() (
  # shellcheck disable=SC2329  # called indirectly, from inside helpers.sh
  tmux() { command tmux -L "$TMUX_SOCK" "$@"; }
  . "$SCRIPTS/helpers.sh"
  open_agent "$@"
)
tabs_for() { $TMUX_CMD list-windows -t '=host' -F '#{window_id}' | grep -cx "$1"; }

$TMUX_CMD new-session -d -s host -c "$T_TMP" 'sleep 300'
$TMUX_CMD new-session -d -s hostclient -c "$T_TMP" "env -u TMUX $TMUX_CMD attach -t host"
sleep 2
client="$($TMUX_CMD list-clients -t host -F '#{client_name}' | head -1)"
[ -n "$client" ] || _fail 'no client attached to host, open_agent test would prove nothing'
agent_win="$($TMUX_CMD list-windows -t '=claude-alpha-foo2' -F '#{window_id}')"
agent_pid="$($TMUX_CMD list-panes -t '=claude-alpha-foo2' -F '#{pane_pid}')"

assert_ok open_agent_t claude-alpha-foo2 "$client"
assert_eq "$(tabs_for "$agent_win")" 1 'agent opened as a tab'
assert_eq "$($TMUX_CMD display-message -p -c "$client" '#{client_session}')" \
  host 'client still on its own session'
assert_eq "$($TMUX_CMD list-windows -t '=host' -F '#{window_id}' -f '#{window_active}')" \
  "$agent_win" 'agent tab is the active window'

# link-window is not idempotent on its own — opening twice must not double the tab
assert_ok open_agent_t claude-alpha-foo2 "$client"
assert_eq "$(tabs_for "$agent_win")" 1 'reopening does not duplicate the tab'

# closing the tab is not killing the agent
$TMUX_CMD unlink-window -t "=host:$agent_win"
assert_eq "$(tabs_for "$agent_win")" 0 'unlinked tab is gone'
assert_ok $TMUX_CMD has-session -t '=claude-alpha-foo2'
assert_ok command kill -0 "$agent_pid"

t_teardown
