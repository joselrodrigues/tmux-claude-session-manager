#!/usr/bin/env bash
# Collect agent name + optional task inside a popup, then spawn.
#   spawn-prompt.sh <dir> [client] [--split <pane-id>]
# With --split the agent opens as a split of <pane-id>'s window instead of as a
# tab; the orientation — and whether it gets an isolated worktree at all — is
# asked for here. Declining the worktree gives a plain Claude in <dir>, the
# split twin of the prefix+y launcher (it shows up in the picker as loose).
# read -r keeps the input pure data — tmux command-prompt substitution would
# re-parse quotes/;/$() through the shell before validation could run.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

path="${1:-$PWD}"
[ $# -gt 0 ] && shift
client='' split_pane=''
while [ $# -gt 0 ]; do
  case "$1" in
  --split) split_pane="${2:-}"; shift ;;
  *) client="$1" ;;
  esac
  shift
done

fail() {
  printf 'press enter to close '
  IFS= read -r _
  exit 1
}

ask_name_task() {
  printf 'agent name (empty = auto): '
  IFS= read -r name
  printf 'task (optional): '
  IFS= read -r task
}

if [ -n "$split_pane" ]; then
  printf 'split — h: side by side, v: stacked [h]: '
  IFS= read -r orient
  case "$orient" in v | V) orient=v flag=-v ;; *) orient=h flag=-h ;; esac

  printf 'isolated worktree? [Y/n]: '
  IFS= read -r wt
  case "$wt" in
  n | N)
    # Plain split: Claude in the invoking directory, no worktree, no stamps —
    # the picker finds it as a loose agent by its process, like prefix+y's
    # sessions used to be found.
    cmd="$(get_tmux_option @claude_command 'claude')"
    args="$(get_tmux_option @claude_args '')"
    [ -n "$args" ] && cmd="$cmd $args"
    tmux split-window "$flag" -t "$split_pane" -c "$path" "$cmd" || fail
    exit 0
    ;;
  esac

  ask_name_task
  # Nothing to open: the split is already in the window that asked for it, so
  # this popup just exits. spawn.sh prints the new pane id; nobody needs it here.
  "$DIR/spawn.sh" "$name" "$path" "$task" --split "$orient" --target "$split_pane" >/dev/null ||
    fail
  exit 0
fi

ask_name_task
# spawn.sh prints the session name on stdout; progress/errors go to stderr.
if session="$("$DIR/spawn.sh" "$name" "$path" "$task")"; then
  # Open the agent as a tab on the client that asked for it — not on this
  # popup's own client, which is about to disappear when the script exits.
  open_agent "$session" "$client"
else
  fail
fi
