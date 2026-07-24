#!/usr/bin/env bash
# Drive named Claude agents from outside their sessions.
#   agent.sh send <target> [--no-enter] [--json] <text...>
#   agent.sh read <target> [--lines N] [--source visible|recent] [--json]
# Targets: bare name (api -> unique claude-*-api), full session name, or
# pane id (%3). Pane resolution is pure tmux — `claude agents --json` is
# stale for seconds after a spawn, and spawn-then-send must work.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

die() { echo "claude-agent: $*" >&2; exit 1; }

prefix="$(get_tmux_option @claude_session_prefix 'claude-')"

# resolve_sessions <target> — echo one session name per line, or die.
resolve_sessions() {
  local t="$1" matches
  case "$t" in
  %*)
    tm display-message -p -t "$t" '#{session_name}' 2>/dev/null || die "no pane $t"
    ;;
  "$prefix"*)
    tm has-session -t "=$t" 2>/dev/null || die "no session $t"
    printf '%s\n' "$t"
    ;;
  *)
    matches="$(tm list-sessions -F '#{session_name}' 2>/dev/null |
      grep -E "^${prefix}.+-${t}$")"
    [ -z "$matches" ] && die "no agent named '$t'"
    # shellcheck disable=SC2086
    [ "$(printf '%s\n' "$matches" | wc -l)" -gt 1 ] &&
      die "ambiguous name '$t': $(printf '%s ' $matches)"
    printf '%s\n' "$matches"
    ;;
  esac
}

pane_of() { tm list-panes -t "=$1" -F '#{pane_id}' | head -1; }

# pane_for_target <target> <session> — the exact pane to act on. A %-pane-id
# target addresses that pane directly; any other target uses the session's
# first pane (resolve_sessions already validated a %-target's pane exists).
pane_for_target() {
  case "$1" in
  %*) printf '%s\n' "$1" ;;
  *) pane_of "$2" ;;
  esac
}

cmd="${1:-}"; shift 2>/dev/null || die 'usage: agent.sh <send|read> <target> ...'
target="${1:-}"; shift 2>/dev/null || die 'missing target'

case "$cmd" in
send)
  enter=yes json=no text=''
  while [ $# -gt 0 ]; do
    case "$1" in
    --no-enter) enter=no ;;
    --json) json=yes ;;
    *) text="${text:+$text }$1" ;;
    esac
    shift
  done
  [ -z "$text" ] && die 'nothing to send'
  sessions="$(resolve_sessions "$target")" || exit $?
  sent=''
  while IFS= read -r s; do
    pane="$(pane_for_target "$target" "$s")"
    tm send-keys -t "$pane" -l -- "$text"
    [ "$enter" = yes ] && tm send-keys -t "$pane" Enter
    sent="${sent:+$sent }$s"
  done <<EOF
$sessions
EOF
  if [ "$json" = yes ]; then
    printf '%s\n' "$sent" | tr ' ' '\n' | jq -R . | jq -cs '{ok: true, targets: .}'
  else
    echo "sent to: $sent"
  fi
  ;;
read)
  lines='' source=visible json=no
  while [ $# -gt 0 ]; do
    case "$1" in
    --lines) lines="${2:-}"; shift ;;
    --source) source="${2:-visible}"; shift ;;
    --json) json=yes ;;
    esac
    shift
  done
  s="$(resolve_sessions "$target" | head -1)" || exit $?
  pane="$(pane_for_target "$target" "$s")"
  cap=(tm capture-pane -p -t "$pane")
  [ "$source" = recent ] && cap+=(-S "-${lines:-1000}")
  out="$("${cap[@]}")"
  [ -n "$lines" ] && out="$(printf '%s\n' "$out" | tail -n "$lines")"
  if [ "$json" = yes ]; then
    printf '%s' "$out" | jq -Rs '{ok: true, lines: .}'
  else
    printf '%s\n' "$out"
  fi
  ;;
*)
  die "unknown subcommand '$cmd'"
  ;;
esac
