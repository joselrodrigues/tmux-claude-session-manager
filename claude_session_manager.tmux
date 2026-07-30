#!/usr/bin/env bash
# tmux-claude-session-manager
#
# List, monitor status, and jump across Claude Code agents, each opened as a tab
# in your own session. tpm runs this file as an executable on tmux startup; it
# reads user options (with sensible defaults) and installs the key bindings.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/helpers.sh
. "$CURRENT_DIR/scripts/helpers.sh"

launch_key="$(get_tmux_option @claude_launch_key 'y')"
list_key="$(get_tmux_option @claude_list_key 'u')"

# Launch (or re-attach to) a Claude session for the current pane's directory.
# #{pane_current_path} / #{client_name} are expanded by run-shell before the
# args reach the script.
tmux bind-key "$launch_key" \
  run-shell "$CURRENT_DIR/scripts/launch.sh #{q:pane_current_path} #{q:client_name}"

# Open the agent picker.
tmux bind-key "$list_key" \
  run-shell "$CURRENT_DIR/scripts/list.sh #{q:client_name}"

spawn_key="$(get_tmux_option @claude_spawn_key 'Y')"
popup_w="$(get_tmux_option @claude_popup_width '90%')"
popup_h="$(get_tmux_option @claude_popup_height '90%')"

# Spawn a named agent in its own git worktree for the current pane's repo.
# The popup collects the name with read -r; see spawn-prompt.sh.
# display-popup itself does not format-expand -E's shell-command, so the
# #{q:...} formats must be expanded by run-shell first, same as launch_key
# above. #{q:client_name} is who the new agent's tab gets opened on — the
# popup's own client is gone by then.
tmux bind-key "$spawn_key" \
  run-shell "tmux display-popup -w $popup_w -h $popup_h -E \"$CURRENT_DIR/scripts/spawn-prompt.sh #{q:pane_current_path} #{q:client_name}\""

# Same spawn, opened as a split of this window instead of as a tab. The prompt
# asks for the orientation, so this costs one key rather than two.
# #{q:pane_id} is the pane that pressed the key: inside the popup, tmux's own
# "current pane" is the popup itself, so the target has to be carried in.
split_key="$(get_tmux_option @claude_split_key 'S')"
tmux bind-key "$split_key" \
  run-shell "tmux display-popup -w $popup_w -h $popup_h -E \"$CURRENT_DIR/scripts/spawn-prompt.sh #{q:pane_current_path} #{q:client_name} --split #{q:pane_id}\""

# Close an agent's tab and leave the agent running. This is the safe opposite
# of tmux's own kill-window (prefix + &), which would take the agent with it.
unlink_key="$(get_tmux_option @claude_unlink_key 'b')"
tmux bind-key "$unlink_key" unlink-window

# Notifications. tmux has no periodic hook, so pulse.sh rides status-interval as
# a `#()` in status-right (it prints nothing). Installed twice on purpose: once
# now, and once per client-attached, because a .tmux.conf that sets status-right
# after tpm's `run` would clobber the load-time append. The install itself is
# idempotent, and @claude_sound_enabled is read by pulse.sh at poll time, not
# here, so toggling it takes effect without a tmux restart.
"$CURRENT_DIR/scripts/pulse.sh" install
# -a appends unconditionally, so the guard is what keeps a tpm reload from
# stacking a second copy of the same hook.
tmux show-hooks -g 2>/dev/null | grep -q 'pulse.sh install' ||
  tmux set-hook -ag client-attached "run-shell -b \"$CURRENT_DIR/scripts/pulse.sh install\""
