#!/usr/bin/env bash
# Collect agent name + optional task inside a popup, then spawn.
#   spawn-prompt.sh <dir> [origin-window-id]
# read -r keeps the input pure data — tmux command-prompt substitution would
# re-parse quotes/;/$() through the shell before validation could run.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

path="${1:-$PWD}"
window="${2:-}"
extra=()
if [ "$window" = --no-popup ]; then
  window=''
  extra=(--no-popup)
fi

printf 'agent name (empty = auto): '
IFS= read -r name
printf 'task (optional): '
IFS= read -r task

# spawn.sh prints the session name on stdout; progress/errors go to stderr.
if session="$("$DIR/spawn.sh" "$name" "$path" "$task" ${window:+--window "$window"} ${extra[0]:+"${extra[@]}"})"; then
  if [ ${#extra[@]} -eq 0 ]; then
    # We ARE the popup — attach in place instead of nesting another popup.
    exec tmux attach-session -t "$session"
  fi
  echo "spawned: $session"
  sleep 1
else
  printf 'press enter to close '
  IFS= read -r _
fi
