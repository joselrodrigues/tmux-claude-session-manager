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

printf 'agent name: '
IFS= read -r name
[ -z "$name" ] && exit 0
printf 'task (optional): '
IFS= read -r task

if ! "$DIR/spawn.sh" "$name" "$path" "$task" ${window:+--window "$window"} ${extra[0]:+"${extra[@]}"}; then
  printf 'press enter to close '
  IFS= read -r _
fi
