#!/usr/bin/env bash
# Open the session picker in a popup.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

w="$(get_tmux_option @claude_popup_width '90%')"
h="$(get_tmux_option @claude_popup_height '90%')"

# The client that pressed the key. picker.sh opens agents into that client's
# session and reads the spawn directory from its current pane, so it has to
# outlive this popup — which is exactly why the picker asks for it by name
# instead of looking up "whichever client is around" at jump time.
me="${1:-}"
tmux set-option -g @claude_parent "$me"

if [ -n "$me" ]; then
  tmux display-popup -c "$me" -w "$w" -h "$h" -E "$DIR/picker.sh"
else
  tmux display-popup -w "$w" -h "$h" -E "$DIR/picker.sh"
fi
