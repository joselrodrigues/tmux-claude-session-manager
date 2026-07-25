#!/usr/bin/env bash
# Collect agent name + optional task inside a popup, then spawn.
#   spawn-prompt.sh <dir> [window]
# read -r keeps the input pure data — tmux command-prompt substitution would
# re-parse quotes/;/$() through the shell before validation could run.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

path="${1:-$PWD}"
window="${2:-}"

printf 'agent name (empty = auto): '
IFS= read -r name
printf 'task (optional): '
IFS= read -r task

# spawn.sh prints the session name on stdout; progress/errors go to stderr.
if session="$("$DIR/spawn.sh" "$name" "$path" "$task" ${window:+--window "$window"})"; then
  # We ARE the popup (prefix+Y's popup, or the picker popup ctrl-n became) —
  # attach in place instead of nesting another popup.
  exec tmux attach-session -t "$session"
else
  printf 'press enter to close '
  IFS= read -r _
fi
