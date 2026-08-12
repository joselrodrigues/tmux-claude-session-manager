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

# claude_agents_tsv
# One line per running interactive Claude:
#   pid \t status \t sessionId \t cwd \t last-activity-epoch
#
# Each Claude writes its own state to $CLAUDE_CONFIG_DIR/sessions/<pid>.json,
# and that is the same data `claude agents --json` publishes — minus the CLI's
# start-up cost, which on a loaded machine is seconds. The picker pays it per
# render, `wait` per poll tick and pulse.sh every status-interval forever, so
# reading the files directly is the difference between a picker that opens and
# one that looks dead. The CLI stays as the fallback for machines where the
# files are absent, which keeps status working with no setup.
#
# Status is normalised to the CLI's three-word vocabulary: the files also carry
# raw states like `shell`, which the CLI reports as busy and which callers here
# only understand as "working".
#
# The last field is empty on the fallback path — `claude agents --json` reports
# only `startedAt`, never a last-activity time.
#
# ponytail: a torn write while jq reads drops that agent for one tick. It
# self-corrects on the next one, except in pulse.sh, where the state file is
# rewritten from this output — so a pid missing for a tick forgets its pending
# `busy` and loses the busy -> idle edge. Narrow enough to live with; per-file
# jq invocations if it ever bites.
claude_agents_tsv() {
  local out
  out="$(jq -r '
    select(.kind == "interactive")
    | [ .pid,
        (if .status == "idle" or .status == "waiting" then .status else "busy" end),
        .sessionId,
        .cwd,
        (if .statusUpdatedAt then (.statusUpdatedAt / 1000 | floor) else "" end) ]
    | @tsv' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/sessions/*.json 2>/dev/null)"
  [ -n "$out" ] && {
    printf '%s\n' "$out"
    return 0
  }
  claude agents --json 2>/dev/null |
    jq -r '.[] | select(.kind == "interactive")
      | [.pid, .status, .sessionId, .cwd, ""] | @tsv' 2>/dev/null
}

# pane_agent_status <pane>
# waiting|idle|busy for the Claude running in that pane; empty when no Claude
# has published itself against the pane's tty — not yet, or not ever. Callers
# read empty as "no agent here (yet)", never as an error.
#
# Identity is the pid -> tty -> pane join agents.sh uses: a pane holds an agent
# because a Claude process sits on its tty, not because of what it is called.
pane_agent_status() {
  local tty pid st
  [ -z "${1:-}" ] && return 0
  tty="$(tmux display-message -p -t "$1" '#{pane_tty}' 2>/dev/null)"
  tty="${tty#/dev/}"
  [ -z "$tty" ] && return 0
  while IFS=$'\t' read -r pid st; do
    [ "$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')" = "$tty" ] &&
      { printf '%s' "$st"; return 0; }
  done <<EOF
$(claude_agents_tsv | cut -f1,2)
EOF
  return 0
}

# send_task <pane> <task>
# Type a spawn's task into the agent it was spawned for, once there is an agent
# to receive it.
#
# The wait is on the agent publishing itself, never on pane output: the shell
# and node print plenty before Claude's input box exists, and text typed into
# that gap is dropped on the floor. Gives up after ~20s in silence — the task
# stays stamped on the session/pane, so the picker still shows what it was for.
send_task() {
  local pane="$1" task="$2" deadline=$((SECONDS + 20))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ -n "$(pane_agent_status "$pane")" ]; then
      tmux send-keys -t "$pane" -l -- "$task"
      tmux send-keys -t "$pane" Enter
      return 0
    fi
    sleep 0.5
  done
  return 1
}

# agent_session_is_live <session>
# True when a claude-* session still has the agent its name promises.
# tmux-resurrect/continuum restore the session and a bare shell, never the
# Claude that was in it, so the name alone proves nothing.
#
# Two independent signals, OR'd: a Claude published against the pane's tty, or
# the pane's own process is the configured @claude_command (which covers a
# Claude that started seconds ago and has not published itself yet). The
# asymmetry is deliberate — a false "live" only reproduces today's refusal,
# while a false "ghost" would kill a working agent.
agent_session_is_live() {
  local pane pid want
  pane="$(tmux list-panes -t "=$1" -F '#{pane_id}' 2>/dev/null | head -1)"
  [ -z "$pane" ] && return 1
  [ -n "$(pane_agent_status "$pane")" ] && return 0
  pid="$(tmux display-message -p -t "$pane" '#{pane_pid}' 2>/dev/null)"
  [ -z "$pid" ] && return 1
  want="$(get_tmux_option @claude_command 'claude')"
  want="${want%% *}"
  # A dead pid prints nothing, which is a ghost by the same rule.
  case "$(ps -o command= -p "$pid" 2>/dev/null)" in
  *"${want##*/}"*) return 0 ;;
  esac
  return 1
}

# default_base <repo-root>
# The ref a new agent branch is cut from when nobody picks one: an explicit
# `git config claude.baseBranch` wins, then the remote's default branch (its
# local twin where there is one — local branches are what the selector lists),
# then whatever the repo is on right now.
default_base() {
  local b
  b="$(git -C "$1" config claude.baseBranch 2>/dev/null)"
  [ -n "$b" ] && { printf '%s' "$b"; return; }
  b="$(git -C "$1" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)"
  if [ -n "$b" ]; then
    git -C "$1" show-ref --verify --quiet "refs/heads/${b#origin/}" && b="${b#origin/}"
    printf '%s' "$b"
    return
  fi
  b="$(git -C "$1" branch --show-current 2>/dev/null)"
  printf '%s' "${b:-HEAD}"
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

# jump_to_agent <pane> <kind> [client]
# Put the client in front of that agent, given a picker row's pane and kind.
#
# A dedicated agent lives in its own claude-* session and is shown as a tab —
# addressed by window id, not session: once the window is linked, the pane's
# session name is ambiguous and can resolve to the user's side, selecting the
# wrong window entirely. A split or loose agent already sits in a window of
# somebody's session, so it is focused where it is.
jump_to_agent() {
  local pane="$1" kind="$2" client="${3:-}" session win
  session="$(tmux display-message -p -t "$pane" '#{session_name}' 2>/dev/null)"
  if [ "$kind" = dedicated ]; then
    win="$(tmux display-message -p -t "$pane" '#{window_id}' 2>/dev/null)"
    open_agent "${win:-$session}" "$client"
    return
  fi
  if [ -n "$client" ]; then
    tmux switch-client -c "$client" -t "$session" 2>/dev/null
  else
    tmux switch-client -t "$session" 2>/dev/null
  fi
  tmux select-window -t "$pane" 2>/dev/null
  tmux select-pane -t "$pane" 2>/dev/null
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
