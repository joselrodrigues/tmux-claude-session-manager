#!/usr/bin/env bash
# Spawn a named Claude agent: worktree + dedicated session.
#   spawn.sh <name> [dir] [task] [--no-popup]
#   spawn.sh <name> [dir] [task] --split h|v [--target <pane-id>]
# Prints the session name, or with --split the new pane id.
# TMUX_SOCKET_OVERRIDE reroutes every tmux call (tests use a scratch server).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

tm() {
  if [ -n "${TMUX_SOCKET_OVERRIDE:-}" ]; then
    command tmux -L "$TMUX_SOCKET_OVERRIDE" "$@"
  else
    command tmux "$@"
  fi
}
# helpers.sh's get_tmux_option calls bare tmux; shadow it through tm.
tmux() { tm "$@"; }

die() {
  [ -n "${TMUX:-}" ] && tm display-message "claude-spawn: $*"
  echo "claude-spawn: $*" >&2
  exit 1
}

name='' path='' task='' split='' target='' pos=0
while [ $# -gt 0 ]; do
  case "$1" in
  --no-popup) : ;;
  --split) split="${2:-}"; shift ;;
  # Which pane to split. Must be passed explicitly: the binding runs the prompt
  # in a display-popup, so by the time spawn.sh runs, tmux's own idea of the
  # current pane is the popup — the same class of bug open_agent hits with
  # #{client_session}. The binding expands #{q:pane_id} of the invoking pane.
  --target) target="${2:-}"; shift ;;
  # Accepted and ignored, like --no-popup: agents no longer record an origin
  # window. Without this arm the positional-by-index branch below would take
  # "--window" for the task text and drop the id that follows it, silently.
  --window) shift ;;
  *)
    # Positional by index, not by first-empty-slot: an empty name argument
    # (auto-name request) must not swallow the path into its slot.
    pos=$((pos + 1))
    case "$pos" in
    1) name="$1" ;;
    2) path="$1" ;;
    3) task="$1" ;;
    esac
    ;;
  esac
  shift
done
path="${path:-$PWD}"

case "$split" in
'') ;;
h) split_flag=-h ;;
v) split_flag=-v ;;
*) die "--split takes h or v, not '$split'" ;;
esac

repo_root="$(git -C "$path" rev-parse --show-toplevel 2>/dev/null)" ||
  die "$path is not inside a git repo"
# Dots deleted, not kept: tmux parses `.` in -t targets as window.pane, so a
# dotted session name (repo `.dotfiles` -> `claude-.dotfiles-x`) is unaddressable.
repo="$(basename "$repo_root" | tr -cd 'A-Za-z0-9_-')"
[ -z "$repo" ] && die "cannot derive a session name from $repo_root"

prefix="$(get_tmux_option @claude_session_prefix 'claude-')"

# Empty name -> auto-generate (herdr semantics: the branch name is optional):
# first agentN whose session and branch are both free.
if [ -z "$name" ]; then
  i=1
  while tm has-session -t "=${prefix}${repo}-agent$i" 2>/dev/null ||
    git -C "$repo_root" show-ref --verify --quiet "refs/heads/agent$i"; do
    i=$((i + 1))
  done
  name="agent$i"
fi
valid_agent_name "$name" || die "invalid agent name '$name'"
session="${prefix}${repo}-${name}"
# A restored session (tmux-resurrect/continuum) carries the name of an agent
# that is no longer there, and the name alone would block this spawn forever.
# Recycled only when nothing in it is alive — see agent_session_is_live.
if tm has-session -t "=$session" 2>/dev/null; then
  agent_session_is_live "$session" &&
    die "agent '$name' already running for $repo ($session)"
  tm kill-session -t "=$session" 2>/dev/null
  [ -n "${TMUX:-}" ] && tm display-message "recycled ghost session $session"
fi

wt_base="$(expand_tilde "$(get_tmux_option @claude_worktree_dir "$HOME/.claude-worktrees")")"
wt_dir="$wt_base/${repo}-$(session_hash "$repo_root")/$name"

# has-session above cannot see a split agent — it has no session of its own —
# and the worktree already existing is normal (it is reused). Without this, a
# second spawn of the same name would put two Claudes in one worktree.
busy="$(panes_with_option @claude_worktree "$wt_dir" | head -1)"
[ -n "$busy" ] && die "agent '$name' already running in pane $busy"

if [ ! -d "$wt_dir" ]; then
  mkdir -p "$(dirname "$wt_dir")"
  if git -C "$repo_root" show-ref --verify --quiet "refs/heads/$name"; then
    err="$(git -C "$repo_root" worktree add "$wt_dir" "$name" 2>&1)" || die "$err"
    [ -n "${TMUX:-}" ] && tm display-message "reusing existing branch '$name'"
  else
    err="$(git -C "$repo_root" worktree add -b "$name" "$wt_dir" 2>&1)" || die "$err"
  fi
  # Progress stays visible (on stderr — stdout is reserved for the session
  # name): a first init clones every submodule from scratch, which can take
  # minutes — silenced, the popup looks frozen mid-spawn.
  if [ -f "$wt_dir/.gitmodules" ]; then
    echo "initializing submodules (first time can take a while)..." >&2
    git -C "$wt_dir" submodule update --init --recursive 1>&2
  fi
fi

cmd="$(get_tmux_option @claude_command 'claude')"
args="$(get_tmux_option @claude_args '')"
[ -n "$args" ] && cmd="$cmd $args"

# Split mode: the agent is a plain pane in a window you already have, so it
# lives and dies with that pane and there is no session to link anywhere. The
# stamps go on the pane instead — pane options do not inherit, which is what
# lets agent.sh tell a split agent from whatever session it happens to sit in
# (including another agent's).
if [ -n "$split" ]; then
  split_cmd=(split-window "$split_flag" -P -F '#{pane_id}' -c "$wt_dir")
  [ -n "$target" ] && split_cmd+=(-t "$target")
  pane="$(tm "${split_cmd[@]}" "$cmd")" || die "split-window failed"
  tm set-option -p -t "$pane" @claude_worktree "$wt_dir"
  tm set-option -p -t "$pane" @claude_agent_name "$name"
  [ -n "$task" ] && tm set-option -p -t "$pane" @claude_task "$task"
  tm select-pane -t "$pane" -T "$name" 2>/dev/null
  # No name_window: the window is the user's, not the agent's.
  printf '%s\n' "$pane"
  exit 0
fi

tm new-session -d -s "$session" -c "$wt_dir" "$cmd" || die "new-session failed"
tm set-option -t "$session" @claude_worktree "$wt_dir"
tm set-option -t "$session" @claude_agent_name "$name"
[ -n "$task" ] && tm set-option -t "$session" @claude_task "$task"
tm select-pane -t "$session:" -T "$name" 2>/dev/null
name_window "$session" "$name"

# Nothing is opened here: the caller decides where the agent shows up, using
# the session name printed below (spawn-prompt.sh hands it to open_agent).
# --no-popup is still accepted for compatibility; behavior is identical.
printf '%s\n' "$session"
