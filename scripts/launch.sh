#!/usr/bin/env bash
# Launch (or re-attach to) a Claude session for a directory, as a tab in the
# caller's session.
# Args: <dir> [client]   (both expanded by run-shell in the binding)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

path="${1:-$PWD}"
client="${2:-}"

prefix="$(get_tmux_option @claude_session_prefix 'claude-')"
cmd="$(get_tmux_option @claude_command 'claude')"
args="$(get_tmux_option @claude_args '')"
[ -n "$args" ] && cmd="$cmd $args"

session="${prefix}$(session_hash "$path")"

if ! tmux has-session -t "=$session" 2>/dev/null; then
  tmux new-session -d -s "$session" -c "$path" "$cmd" || exit 1
  # The session name is a hash of the path; the directory is what the tab has
  # to say for itself in the status bar.
  name_window "$session" "$(basename "$path")"
fi

open_agent "$session" "$client"
