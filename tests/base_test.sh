#!/usr/bin/env bash
# Where an agent's branch is cut from: --base on the CLI, the default chain
# (claude.baseBranch -> origin/HEAD -> current branch), and the fzf selector the
# spawn popup shows.
#
# The proof is always the same: the new branch's tip is the base's tip, so the
# agent starts on that history and no other.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
t_setup
export TMUX_TMPDIR=""
WT_BASE="$T_TMP/wt"

$TMUX_CMD set-option -g @claude_worktree_dir "$WT_BASE"
$TMUX_CMD set-option -g @claude_command 'sleep 300'

spawn() { TMUX_SOCKET_OVERRIDE="$TMUX_SOCK" bash "$SCRIPTS/spawn.sh" "$@"; }
git_t() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }

# t_branched <name> — a repo whose `feat-x` branch is one commit ahead of main,
# so "which branch did this come from" has a single, checkable answer.
t_branched() {
  local r
  r="$(t_repo "$1")"
  git_t "$r" checkout -q -b feat-x
  git_t "$r" commit -q --allow-empty -m 'on feat-x'
  git_t "$r" checkout -q main
  printf '%s' "$r"
}
wt_of() { # <repo> <agent>
  printf '%s/%s-%s/%s' "$WT_BASE" "$(basename "$1")" \
    "$(. "$SCRIPTS/helpers.sh"; session_hash "$(git -C "$1" rev-parse --show-toplevel)")" "$2"
}
assert_cut_from() { # <wt> <repo> <ref> <label>
  assert_eq "$(git -C "$1" rev-parse HEAD 2>/dev/null)" \
    "$(git -C "$2" rev-parse "$3" 2>/dev/null)" "$4"
}

# ------------------------------------------------------------ --base on the CLI

repo="$(t_branched alpha)"
assert_ok spawn api "$repo" '' --base feat-x
assert_cut_from "$(wt_of "$repo" api)" "$repo" feat-x 'cli --base'
assert_ok git -C "$repo" merge-base --is-ancestor feat-x api

# Without --base, this repo has no config and no origin/HEAD: the current branch
# (main) is the last link of the chain.
assert_ok spawn plain "$repo" ''
assert_cut_from "$(wt_of "$repo" plain)" "$repo" main 'default chain: current branch'

# ------------------------------------------------------ default chain: config

conf="$(t_branched beta)"
git -C "$conf" config claude.baseBranch feat-x
assert_ok spawn api "$conf" ''
assert_cut_from "$(wt_of "$conf" api)" "$conf" feat-x 'default chain: claude.baseBranch'

# --------------------------------------------------- default chain: origin/HEAD

# No network needed: origin/HEAD is a symbolic ref like any other, and what the
# chain reads is the ref, not the remote.
orig="$(t_branched gamma)"
git -C "$orig" update-ref refs/remotes/origin/feat-x refs/heads/feat-x
git -C "$orig" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/feat-x
assert_ok spawn api "$orig" ''
assert_cut_from "$(wt_of "$orig" api)" "$orig" feat-x 'default chain: origin/HEAD'
# The local twin is what gets used — the selector lists local branches, and the
# base has to be one of the things it can offer.
assert_eq "$(. "$SCRIPTS/helpers.sh"; default_base "$orig")" feat-x default-base-local-twin

# config still outranks origin/HEAD
git -C "$orig" config claude.baseBranch main
assert_eq "$(. "$SCRIPTS/helpers.sh"; default_base "$orig")" main default-base-config-wins

# --------------------------------------------- an existing branch ignores --base

# The agent's branch already carries work; re-basing it silently would throw
# that away, so --base is refused, not applied.
reuse="$(t_branched delta)"
git_t "$reuse" branch old-work main
assert_ok spawn old-work "$reuse" '' --base feat-x
assert_cut_from "$(wt_of "$reuse" old-work)" "$reuse" main 'existing branch keeps its history'

# ------------------------------------------------------------- the fzf selector

# spawn-prompt.sh drives fzf on its own tty; in a pane it behaves exactly as it
# does in the popup, and send-keys is how a user types.
$TMUX_CMD new-session -d -s host -x 200 -y 50 -c "$T_TMP" 'sleep 300'
sel_repo="$(t_branched epsilon)"

prompt_pane() {
  $TMUX_CMD new-window -d -P -F '#{pane_id}' -t '=host:' -c "$T_TMP" \
    "env CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR PATH=$TESTDIR/fixtures:\$PATH \
     $SCRIPTS/spawn-prompt.sh $1"
}
see() { # <pane> <text> — poll, the prompt paints when it paints
  local i=0
  while [ "$i" -lt 30 ]; do
    case "$($TMUX_CMD capture-pane -p -t "$1" 2>/dev/null)" in
    *"$2"*) return 0 ;;
    esac
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

pane="$(prompt_pane "$sel_repo")"
if see "$pane" 'agent name'; then
  $TMUX_CMD send-keys -t "$pane" -l 'picked'
  $TMUX_CMD send-keys -t "$pane" Enter
  sleep 1
  $TMUX_CMD send-keys -t "$pane" Enter # no task
  see "$pane" 'base branch' || _fail "no base selector: [$($TMUX_CMD capture-pane -p -t "$pane")]"
  # main is the default and sits under the cursor; typing filters to the other
  # one, which is the whole point of the selector existing.
  settle "$pane"
  $TMUX_CMD send-keys -t "$pane" -l 'feat-x'
  settle "$pane"
  picked_wt() { test -d "$(wt_of "$sel_repo" picked)"; }
  press_until "$pane" Enter 10 picked_wt ||
    _fail "the selector never spawned: [$($TMUX_CMD capture-pane -p -t "$pane")]"
  assert_cut_from "$(wt_of "$sel_repo" picked)" "$sel_repo" feat-x 'selector picked a non-default base'
else
  _fail "the spawn prompt never appeared: [$($TMUX_CMD capture-pane -p -t "$pane")]"
fi

# escape out of the selector: nothing is created, the name stays free
pane="$(prompt_pane "$sel_repo")"
if see "$pane" 'agent name'; then
  $TMUX_CMD send-keys -t "$pane" -l 'aborted'
  $TMUX_CMD send-keys -t "$pane" Enter
  sleep 1
  $TMUX_CMD send-keys -t "$pane" Enter
  see "$pane" 'base branch' || _fail 'no base selector on the abort run'
  settle "$pane"
  prompt_gone() { ! $TMUX_CMD list-panes -a -F '#{pane_id}' | grep -qx "$pane"; }
  press_until "$pane" Escape 10 prompt_gone ||
    _fail "escape did not abort the prompt: [$($TMUX_CMD capture-pane -p -t "$pane")]"
  assert_ok test ! -d "$(wt_of "$sel_repo" aborted)"
  assert_fail git -C "$sel_repo" show-ref --verify --quiet refs/heads/aborted
  assert_fail $TMUX_CMD has-session -t '=claude-epsilon-aborted'
fi

t_teardown
