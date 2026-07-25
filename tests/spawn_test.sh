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

t_teardown
