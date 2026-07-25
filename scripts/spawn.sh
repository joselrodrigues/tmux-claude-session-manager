#!/usr/bin/env bash
# Spawn a named Claude agent: worktree + dedicated session (+ popup).
#   spawn.sh <name> [dir] [task] [--no-popup] [--window <window-id>]
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

name='' path='' task='' window=''
while [ $# -gt 0 ]; do
  case "$1" in
  --no-popup) : ;;
  --window) window="${2:-}"; shift ;;
  *)
    if [ -z "$name" ]; then name="$1"
    elif [ -z "$path" ]; then path="$1"
    elif [ -z "$task" ]; then task="$1"
    fi
    ;;
  esac
  shift
done
path="${path:-$PWD}"

valid_agent_name "$name" || die "invalid agent name '${name:-<empty>}'"
repo_root="$(git -C "$path" rev-parse --show-toplevel 2>/dev/null)" ||
  die "$path is not inside a git repo"
# Dots deleted, not kept: tmux parses `.` in -t targets as window.pane, so a
# dotted session name (repo `.dotfiles` -> `claude-.dotfiles-x`) is unaddressable.
repo="$(basename "$repo_root" | tr -cd 'A-Za-z0-9_-')"
[ -z "$repo" ] && die "cannot derive a session name from $repo_root"

prefix="$(get_tmux_option @claude_session_prefix 'claude-')"
session="${prefix}${repo}-${name}"
tm has-session -t "=$session" 2>/dev/null &&
  die "agent '$name' already running for $repo ($session)"

wt_base="$(expand_tilde "$(get_tmux_option @claude_worktree_dir "$HOME/.claude-worktrees")")"
wt_dir="$wt_base/${repo}-$(session_hash "$repo_root")/$name"

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

tm new-session -d -s "$session" -c "$wt_dir" "$cmd" || die "new-session failed"
tm set-option -t "$session" @claude_worktree "$wt_dir"
tm set-option -t "$session" @claude_agent_name "$name"
[ -n "$task" ] && tm set-option -t "$session" @claude_task "$task"
[ -n "$window" ] && tm set-option -t "$session" @claude_origin "$window"
tm select-pane -t "$session:" -T "$name" 2>/dev/null

# No display-popup here: nesting a popup from inside the spawn-prompt popup
# does not work in practice. The caller owns the popup — spawn-prompt.sh
# attaches in place using the session name printed below. --no-popup is
# still accepted for compatibility; behavior is identical.
printf '%s\n' "$session"
