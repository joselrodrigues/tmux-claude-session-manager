#!/usr/bin/env bash
# Shared helpers for tmux-claude-session-manager.

# get_tmux_option <option-name> <default>
# Echoes the global tmux option value, or the default when unset/empty.
get_tmux_option() {
  local value
  value="$(tmux show-option -gqv "$1" 2>/dev/null)"
  if [ -n "$value" ]; then
    printf '%s' "$value"
  else
    printf '%s' "$2"
  fi
}

# session_hash <string>
# Short, stable, portable 8-char hash for deriving a session name from a path.
# Prefers md5sum (Linux), falls back to md5 (macOS) then shasum. The trailing
# newline matches the conventional `echo "$path" | md5sum` scheme, so it stays
# compatible with sessions created that way.
session_hash() {
  local out
  if command -v md5sum >/dev/null 2>&1; then
    out="$(printf '%s\n' "$1" | md5sum)"
  elif command -v md5 >/dev/null 2>&1; then
    out="$(printf '%s\n' "$1" | md5 -q)"
  else
    out="$(printf '%s\n' "$1" | shasum)"
  fi
  printf '%s' "${out%% *}" | cut -c1-8
}

# file_mtime <path>
# Epoch seconds of a file's last modification. GNU stat (Linux) is tried first,
# then BSD (macOS); each rejects the other's flag, so the fallback is unambiguous.
file_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# claude_transcript_mtime <session-id>
# Epoch seconds of the last write to that Claude session's transcript — i.e. when
# the agent last did anything. `claude agents --json` reports only `startedAt`,
# never a last-activity time, so the transcript's mtime stands in for it.
#
# Found by glob so we never have to reproduce Claude's cwd -> project-slug
# encoding. The path is an internal Claude Code detail and may move; an empty
# result just renders the age column as '-'.
claude_transcript_mtime() {
  local base f
  base="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  for f in "$base"/projects/*/"$1".jsonl; do
    [ -f "$f" ] && {
      file_mtime "$f"
      return
    }
  done
}

# valid_agent_name <name>
# Charset for session names AND git branch names: rejects git-ref invalids
# and anything argv/tmux-unsafe. Dots are forbidden outright (not just the
# git-ref special cases like *.lock or *..*) — tmux parses `.` in a -t target
# as the window.pane separator, so a dotted session name becomes
# unaddressable (and a kill can land on the wrong pane).
valid_agent_name() {
  printf '%s' "$1" | grep -qE '^[A-Za-z0-9][A-Za-z0-9_-]*$'
}

# expand_tilde <path>
# tmux stores user options opaquely and bash never tilde-expands variable
# contents, so a leading ~ in @claude_worktree_dir must be expanded by hand.
expand_tilde() { printf '%s' "${1/#\~/$HOME}"; }

# open_agent <session-or-window-id> [client]
# Show an agent as a tab in the client's session, and focus it.
#
# The agent keeps living in its own session; link-window only makes its window
# appear in a second one, so closing the tab with unlink-window leaves it
# running. Without <client> the target is tmux's current session, which is
# ambiguous with more than one client attached — pass it whenever you have it.
# A @window-id argument is used as-is: once a window is linked into two
# sessions, resolving "which session does this pane belong to" is ambiguous,
# but the window id names the one shared window object unambiguously.
open_agent() {
  local session="$1" client="${2:-}" win target
  case "$session" in
  @*) win="$session" ;;
  *) win="$(tmux list-windows -t "=$session" -F '#{window_id}' | head -1)" ;;
  esac
  [ -z "$win" ] && return 1
  # #{client_session}, not #{session_name}: -c picks which client the message
  # goes to, but the format is still evaluated against tmux's current session,
  # which is whichever one was last created or used — not the one this client
  # is looking at. Spawning an agent makes the mismatch the common case.
  if [ -n "$client" ]; then
    target="$(tmux display-message -p -c "$client" '#{client_session}')"
  else
    target="$(tmux display-message -p '#{session_name}')"
  fi
  [ -z "$target" ] && return 1

  # link-window is not idempotent: linking a window that is already here
  # succeeds and leaves two tabs pointing at the same window.
  tmux list-windows -t "=$target" -F '#{window_id}' | grep -qx "$win" ||
    tmux link-window -s "$win" -t "=$target:"

  # Switch before selecting, and address the window through its session: a
  # linked window belongs to two sessions, so a bare `-t @id` is ambiguous
  # about whose current-window pointer moves, and a client left on the old
  # session would not follow the selection.
  [ -n "$client" ] && tmux switch-client -c "$client" -t "=$target"
  tmux select-window -t "=$target:$win"
}

# panes_with_option <option> [value]
# Pane ids whose OWN pane-scope option is set — and equals <value>, when given.
#
# Split agents are stamped on the pane rather than on a session of their own, so
# this is how they are found. Two steps on purpose: `#{@opt}` in a format
# inherits, so a pane merely sitting in a session that carries the option
# reports it as its own; the format only narrows the candidates and
# `show-option -p`, which does not inherit, decides.
panes_with_option() {
  local opt="$1" want="${2:-}" p v
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    v="$(tmux show-option -p -t "$p" -qv "$opt" 2>/dev/null)"
    [ -z "$v" ] && continue
    { [ -n "$want" ] && [ "$v" != "$want" ]; } && continue
    printf '%s\n' "$p"
  done <<EOF
$(tmux list-panes -a -F "#{pane_id}"$'\t'"#{$opt}" 2>/dev/null |
  awk -F'\t' '$2 != "" { print $1 }')
EOF
}

# name_window <session> <name>
# Label the agent's window for the status bar. automatic-rename would
# otherwise overwrite it with whatever command the pane is running.
name_window() {
  tmux rename-window -t "$1:" "$2"
  tmux set-window-option -t "$1:" automatic-rename off
}
