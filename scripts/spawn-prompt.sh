#!/usr/bin/env bash
# Collect agent name + optional task inside a popup, then spawn.
#   spawn-prompt.sh <dir> [client]
# read -r keeps the input pure data — tmux command-prompt substitution would
# re-parse quotes/;/$() through the shell before validation could run.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

path="${1:-$PWD}"
client="${2:-}"

printf 'agent name (empty = auto): '
IFS= read -r name
printf 'task (optional): '
IFS= read -r task

# spawn.sh prints the session name on stdout; progress/errors go to stderr.
if session="$("$DIR/spawn.sh" "$name" "$path" "$task")"; then
  # Open the agent as a tab on the client that asked for it — not on this
  # popup's own client, which is about to disappear when the script exits.
  open_agent "$session" "$client"
else
  printf 'press enter to close '
  IFS= read -r _
fi
