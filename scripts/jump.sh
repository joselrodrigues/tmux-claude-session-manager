#!/usr/bin/env bash
# Jump straight to the agent that most wants you, without opening the picker.
#   jump.sh [client]
#
# agents.sh already sorts by how much attention a row deserves — waiting first,
# then idle oldest-first, then working — so "the most attention-worthy agent" is
# just its first row. The jump itself is the picker's, shared through
# jump_to_agent.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

row="$("$DIR/agents.sh" | head -1)"
[ -z "$row" ] && {
  tmux display-message 'no agents'
  exit 0
}

jump_to_agent "$(printf '%s' "$row" | cut -f2)" "$(printf '%s' "$row" | cut -f4)" "${1:-}"
