#!/usr/bin/env bash
# tmux-claude-session-manager
#
# List, monitor status, and jump across nested Claude Code sessions from a
# single popup. tpm runs this file as an executable on tmux startup; it reads
# user options (with sensible defaults) and installs the key bindings.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/helpers.sh
. "$CURRENT_DIR/scripts/helpers.sh"

launch_key="$(get_tmux_option @claude_launch_key 'y')"
list_key="$(get_tmux_option @claude_list_key 'u')"

# Launch (or re-attach to) a Claude session for the current pane's directory.
# #{pane_current_path} / #{window_id} are expanded by run-shell before the args
# reach the script.
tmux bind-key "$launch_key" \
  run-shell "$CURRENT_DIR/scripts/launch.sh #{q:pane_current_path} #{q:window_id}"

# Open the session picker. When pressed from inside a session popup, list.sh
# closes that popup first so the picker opens full-size on the outer client.
tmux bind-key "$list_key" \
  run-shell "$CURRENT_DIR/scripts/list.sh #{q:client_name}"

spawn_key="$(get_tmux_option @claude_spawn_key 'Y')"
popup_w="$(get_tmux_option @claude_popup_width '90%')"
popup_h="$(get_tmux_option @claude_popup_height '90%')"

# Spawn a named agent in its own git worktree for the current pane's repo.
# The popup collects the name with read -r; see spawn-prompt.sh.
# display-popup itself does not format-expand -E's shell-command, so the
# #{q:...} formats must be expanded by run-shell first, same as launch_key
# above. Sized to match the follow-on session popup spawn.sh opens, since
# tmux "modifies" an already-open popup in place and ignores a new -w/-h.
tmux bind-key "$spawn_key" \
  run-shell "tmux display-popup -w $popup_w -h $popup_h -E \"$CURRENT_DIR/scripts/spawn-prompt.sh #{q:pane_current_path} #{q:window_id}\""
