#!/usr/bin/env bash
# Passive notifier — herdr's two sounds: "done" when an agent goes busy -> idle,
# "request" when it goes busy -> waiting, fired only for agents you are NOT
# looking at.
#
# Why polling instead of the Claude Code hooks. This machine already has a
# Stop/Notification hook that plays these same mp3s, so reusing it looks like
# the lazier route. It isn't: that hook runs inside each Claude process, knows
# nothing about tmux, and cannot tell whether you are looking at that pane — so
# it beeps for the agent already on your screen, which is exactly the noise
# herdr's focus filter exists to remove. Focus is only knowable from the tmux
# server, so the notifier has to live here. tmux has no periodic hook, so the
# status line is the clock: a `#()` in status-right is re-run every
# status-interval. No daemon and no socket — this process starts, diffs one
# state file, and exits.
#
# Divergence from the brief, which said "sounds for agents whose session is not
# the attached one": an agent counts as focused only when it is the active pane
# of the active window of an attached session — its own session, or any session
# its window is linked into as a tab. A background window of the session you are
# attached to is not on your screen, so it still rings.
#
#   pulse.sh install   — append the poll to status-right (idempotent)
#   pulse.sh           — one poll; prints nothing, by design
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$DIR/$(basename "${BASH_SOURCE[0]}")"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

tm() {
  if [ -n "${TMUX_SOCKET_OVERRIDE:-}" ]; then
    command tmux -L "$TMUX_SOCKET_OVERRIDE" "$@"
  else
    command tmux "$@"
  fi
}
tmux() { tm "$@"; }

# Installed both at plugin load and from a client-attached hook: a config that
# sets status-right *after* tpm runs would otherwise wipe the load-time append,
# and the first attach is also the first moment the status line can poll at all.
if [ "${1:-}" = install ]; then
  cur="$(tm show-option -gqv status-right)"
  case "$cur" in
  *pulse.sh*) ;;
  *) tm set-option -g status-right "$cur#(\"$SELF\")" ;;
  esac
  exit 0
fi

[ "$(get_tmux_option @claude_sound_enabled 'on')" = on ] || exit 0

config="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
[ -f "$config/mute" ] && exit 0

sound_done="$(expand_tilde "$(get_tmux_option @claude_sound_done "$config/sounds/terminado.mp3")")"
sound_request="$(expand_tilde "$(get_tmux_option @claude_sound_request "$config/sounds/esperando.mp3")")"
prefix="$(get_tmux_option @claude_session_prefix 'claude-')"

state="${CLAUDE_PULSE_STATE:-${TMPDIR:-/tmp}/claude-pulse-$(id -u).state}"
lock="$state.lock"
# Every attached client redraws its own status line, so concurrent polls are
# normal, not an edge case — without the lock two of them read the same "busy"
# and both ring. ponytail: mkdir is the portable mutex; the age check is there
# because a lock leaked by a SIGKILLed poll would silence the feature forever.
find "$lock" -maxdepth 0 -mmin +1 -exec rmdir {} \; 2>/dev/null
mkdir "$lock" 2>/dev/null || exit 0
trap 'rmdir "$lock" 2>/dev/null' EXIT

agents="$(claude agents --json 2>/dev/null |
  jq -r '.[] | select(.kind == "interactive") | [.pid, .status] | @tsv' 2>/dev/null)"

# Nothing to diff, and leaving the state file untouched is what makes a single
# failed `claude agents --json` harmless: were it rewritten empty, every pending
# busy would be forgotten and the busy -> idle edge — the whole point of this
# script — would never be seen.
[ -n "$agents" ] || exit 0

# pid -> tty -> pane, the same identity join agents.sh uses (a pane reports its
# shell in pane_current_command, never the claude child). ps is asked about the
# agent pids only; unlike the picker, this runs every status-interval forever,
# so enumerating every process on the box is a cost it would pay all day.
current="$({
  ps -o pid=,tty= -p "$(printf '%s\n' "$agents" | cut -f1 | tr '\n' ',' | sed 's/,$//')" 2>/dev/null |
    awk '{ print "P\t" $1 "\t" $2 }'
  tm list-panes -a -F $'T\t#{pane_tty}\t#{session_name}\t#{session_attached}\t#{window_active}\t#{pane_active}' 2>/dev/null
  printf '%s\n' "$agents" | sed $'s/^/A\t/'
} | awk -F'\t' -v prefix="$prefix" '
  $1 == "P" { tty_of[$2] = $3; next }
  $1 == "T" {
    sub(/^\/dev\//, "", $2)
    # An agent opened as a tab lives in two sessions at once, so its pane comes
    # back from list-panes twice and neither row can be trusted alone.
    #
    # The dedicated session is the misleading one: that window is always the
    # only -- therefore active -- window there, and the session is never
    # attached (a client attaches to a session, not a window). Read by itself
    # it reports "not focused" even while you are looking straight at the tab.
    # So focus is an OR across every session holding the pane...
    if ($4 > 0 && $5 == 1 && $6 == 1) focused[$2] = 1
    # ...while the session recorded is deliberately the dedicated one, since
    # @claude_agent_name and @claude_sound_mute are set there and nowhere else.
    if (!($2 in sess) || index($3, prefix) == 1) sess[$2] = $3
    next
  }
  $1 == "A" {
    tty = tty_of[$2]
    if (tty == "" || !(tty in sess)) next   # this Claude is not running inside tmux
    printf "%s\t%s\t%s\t%s\n", $2, $3, sess[tty], focused[tty] + 0
  }
')"

announce() {
  local msg="$1" client
  while IFS= read -r client; do
    [ -n "$client" ] && tm display-message -c "$client" "$msg" 2>/dev/null
  done <<EOF
$(tm list-clients -F '#{client_name}' 2>/dev/null)
EOF
}

while IFS=$'\t' read -r pid status session focused; do
  [ -z "$pid" ] && continue
  [ "$(awk -F'\t' -v p="$pid" '$1 == p { print $2; exit }' "$state" 2>/dev/null)" = busy ] || continue
  case "$status" in
  idle) sound="$sound_done" verb='finished' ;;
  waiting) sound="$sound_request" verb='needs input' ;;
  *) continue ;;
  esac
  [ "$focused" = 1 ] && continue
  [ "$(tm show-option -t "$session" -qv @claude_sound_mute 2>/dev/null)" = on ] && continue

  name="$(tm show-option -t "$session" -qv @claude_agent_name 2>/dev/null)"
  announce "claude: ${name:-$session} $verb"
  [ -f "$sound" ] && afplay "$sound" >/dev/null 2>&1 </dev/null &
done <<EOF
$current
EOF

printf '%s\n' "$current" | cut -f1,2 >"$state"
exit 0
