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
  @all | @idle | @waiting | @busy)
    local want="${t#@}" s2
    while IFS= read -r s2; do
      [ -z "$(tm show-option -t "$s2" -qv @claude_worktree)" ] && continue
      if [ "$want" = all ] || [ "$(status_of "$s2")" = "$want" ]; then
        printf '%s\n' "$s2"
      fi
    done <<EOF2
$(tm list-sessions -F '#{session_name}' 2>/dev/null | grep "^$prefix")
EOF2
    ;;
  *)
    # Prefer the exact @claude_agent_name spawn.sh stamped on the session;
    # only fall back to the "prefix + repo + name" regex for sessions
    # created before that option existed (or made by hand, e.g. tests).
    # If ANY session carries a stamp, trust only exact matches — regex
    # fallback is unsafe when stamped agents coexist with regex-matchable names.
    local by_name='' s2 has_any_stamp=no agent_name matches='' p
    while IFS= read -r s2; do
      [ -z "$s2" ] && continue
      agent_name="$(tm show-option -t "$s2" -qv @claude_agent_name 2>/dev/null)"
      [ -n "$agent_name" ] && has_any_stamp=yes
      [ "$agent_name" = "$t" ] &&
        by_name="${by_name:+$by_name
}$s2"
    done <<EOF3
$(tm list-sessions -F '#{session_name}' 2>/dev/null | grep "^$prefix")
EOF3
    # A split agent has no session of its own: it answers to its bare name
    # through the stamp on its pane, and the pane id is what gets returned —
    # the session it sits in belongs to the user and may hold anything else.
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      has_any_stamp=yes
      [ "$(tm show-option -p -t "$p" -qv @claude_agent_name 2>/dev/null)" = "$t" ] &&
        by_name="${by_name:+$by_name
}$p"
    done <<EOF4
$(panes_with_option @claude_agent_name)
EOF4
    if [ -n "$by_name" ]; then
      matches="$by_name"
    elif [ "$has_any_stamp" = no ]; then
      # Only try regex if no stamped sessions exist (legacy behavior)
      matches="$(tm list-sessions -F '#{session_name}' 2>/dev/null |
        grep -E "^${prefix}.+-${t}$")"
    fi
    [ -z "$matches" ] && die "no agent named '$t'"
    # shellcheck disable=SC2086
    [ "$(printf '%s\n' "$matches" | wc -l)" -gt 1 ] &&
      die "ambiguous name '$t': $(printf '%s ' $matches)"
    printf '%s\n' "$matches"
    ;;
  esac
}

# pane_of <session-or-pane> — a split agent resolves to a pane id rather than a
# session name, since it has no session of its own; pass it straight through.
pane_of() {
  case "$1" in
  %*) printf '%s\n' "$1" ;;
  *) tm list-panes -t "=$1" -F '#{pane_id}' | head -1 ;;
  esac
}

# pane_for_target <target> <session> — the exact pane to act on. A %-pane-id
# target addresses that pane directly; any other target uses the session's
# first pane (resolve_sessions already validated a %-target's pane exists).
pane_for_target() {
  case "$1" in
  %*) printf '%s\n' "$1" ;;
  *) pane_of "$2" ;;
  esac
}

# worktree_of <pane> <session> — the agent's worktree, or empty.
#
# Pane first, always: a split agent stamps its pane, and the session it sits in
# is the user's — which, when you split an agent tab, is another agent whose
# @claude_worktree points at a different tree entirely.
worktree_of() {
  local wt
  wt="$(tm show-option -p -t "$1" -qv @claude_worktree 2>/dev/null)"
  [ -z "$wt" ] && wt="$(tm show-option -t "$2" -qv @claude_worktree 2>/dev/null)"
  printf '%s' "$wt"
}

# signals_file <pane> <session> — sidecar path next to the worktree. Inside the
# worktree it would read as untracked -> dirty -> kill would never clean.
signals_file() {
  local wt
  wt="$(worktree_of "$1" "$2")"
  [ -z "$wt" ] && die "$2 has no worktree (not a spawned agent)"
  printf '%s/.%s.signals' "$(dirname "$wt")" "$(basename "$wt")"
}

# status_of <session> — waiting|idle|busy from claude_agents_tsv, joined by
# tty: the pane's tty must equal the agent pid's tty (agents.sh uses the same
# identity rule). Empty when Claude has not published the agent (yet) —
# callers treat that as "keep waiting". `wait --status` calls this once a
# second, which is why it must not pay the `claude` CLI's start-up.
status_of() {
  local tty pid st pane
  pane="$(pane_of "$1")"
  [ -z "$pane" ] && return 0
  tty="$(tm display-message -p -t "$pane" '#{pane_tty}')"
  tty="${tty#/dev/}"
  while IFS=$'\t' read -r pid st; do
    [ "$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')" = "$tty" ] &&
      { printf '%s' "$st"; return 0; }
  done <<EOF
$(claude_agents_tsv | cut -f1,2)
EOF
  return 0
}

cmd="${1:-}"; shift 2>/dev/null || die 'usage: agent.sh <send|read|signal|wait> <target> ...'
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
  [ -z "$sessions" ] && die "no agents match $target"
  sent=''
  while IFS= read -r s; do
    pane="$(pane_for_target "$target" "$s")"
    [ -z "$pane" ] && die "cannot resolve pane for $s"
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
  case "$target" in @*) die "group target not supported for $cmd" ;; esac
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
  [ -z "$pane" ] && die "cannot resolve pane for $s"
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
signal)
  case "$target" in @*) die "group target not supported for $cmd" ;; esac
  type='' body='' json=no
  while [ $# -gt 0 ]; do
    case "$1" in
    --body) body="${2:-}"; shift ;;
    --json) json=yes ;;
    done | blocked) type="$1" ;;
    esac
    shift
  done
  [ -z "$type" ] && die 'signal type must be done or blocked'
  s="$(resolve_sessions "$target" | head -1)" || exit $?
  pane="$(pane_for_target "$target" "$s")"
  [ -z "$pane" ] && die "cannot resolve pane for $s"
  f="$(signals_file "$pane" "$s")"
  printf '%s\t%s\t%s\n' "$(date +%s)" "$type" "$body" >>"$f"
  [ "$json" = yes ] && printf '{"ok":true,"signaled":"%s"}\n' "$type" || echo "signaled $type"
  ;;
wait)
  case "$target" in @*) die "group target not supported for $cmd" ;; esac
  mode='' want='' timeout=300 use_regex=no json=no
  while [ $# -gt 0 ]; do
    case "$1" in
    --signal) mode=signal; want="${2:-}"; shift ;;
    --match) mode=match; want="${2:-}"; shift ;;
    --status) mode=status; want="${2:-}"; shift ;;
    --regex) use_regex=yes ;;
    --timeout) timeout="${2:-300}"; shift ;;
    --json) json=yes ;;
    esac
    shift
  done
  [ -z "$mode" ] && die 'wait needs --signal, --match, or --status'
  s="$(resolve_sessions "$target" | head -1)" || exit $?
  deadline=$((SECONDS + timeout))
  while [ "$SECONDS" -lt "$deadline" ]; do
    case "$mode" in
    signal)
      f="$(signals_file "$(pane_for_target "$target" "$s")" "$s")"
      if [ -f "$f" ] && line="$(awk -F'\t' -v t="$want" '$2 == t { print; exit }' "$f")" && [ -n "$line" ]; then
        body="$(printf '%s' "$line" | cut -f3-)"
        [ "$json" = yes ] &&
          printf '%s' "$body" | jq -Rs --arg m "$want" '{ok: true, matched: $m, body: .}' ||
          echo "$want: $body"
        exit 0
      fi
      ;;
    match)
      pane="$(pane_for_target "$target" "$s")"
      [ -z "$pane" ] && die "cannot resolve pane for $s"
      out="$(tm capture-pane -p -t "$pane")"
      if [ "$use_regex" = yes ]; then hit() { printf '%s' "$out" | grep -qE -- "$want"; }
      else hit() { printf '%s' "$out" | grep -qF -- "$want"; }; fi
      if hit; then
        [ "$json" = yes ] && printf '{"ok":true,"matched":%s}\n' "$(printf '%s' "$want" | jq -Rs .)" || echo "matched"
        exit 0
      fi
      ;;
    status)
      st="$(status_of "$s")"   # Task 6
      if [ "$st" = "$want" ]; then
        [ "$json" = yes ] && printf '{"ok":true,"matched":"%s"}\n' "$want" || echo "$want"
        exit 0
      fi
      ;;
    esac
    sleep 1
  done
  [ "$json" = yes ] && echo '{"ok":false,"timeout":true}' || echo 'timeout' >&2
  exit 1
  ;;
kill)
  case "$target" in @*) die "group target not supported for $cmd" ;; esac
  json=no
  [ "${1:-}" = --json ] && json=yes
  s="$(resolve_sessions "$target" | head -1)" || exit $?
  pane="$(pane_for_target "$target" "$s")"
  # An empty pane or pid MUST abort: `-t ""` falls back to tmux's notion of
  # the current pane, and the kill below would land on an innocent process.
  [ -z "$pane" ] && die "cannot resolve pane for $s"

  # Split agent or not, decided by the pane stamp — never by the session name,
  # which for a split is the user's own and says nothing.
  split=yes label=''
  wt="$(tm show-option -p -t "$pane" -qv @claude_worktree)"
  if [ -z "$wt" ]; then
    split=no
    wt="$(tm show-option -t "$s" -qv @claude_worktree)"
    # The prefix check is what protects an innocent pane from being killed as
    # if it were an agent. A stamped pane has already identified itself, so it
    # does not need to live in a claude- session to qualify.
    case "$s" in "$prefix"*) ;; *) die "not an agent session: $s" ;; esac
  else
    label="$(tm show-option -p -t "$pane" -qv @claude_agent_name)"
  fi
  label="${label:-$s}"
  sigfile=''
  [ -n "$wt" ] && sigfile="$(signals_file "$pane" "$s")"
  pid="$(tm display-message -p -t "$pane" '#{pane_pid}')"
  [ -z "$pid" ] && die "cannot resolve pid for $s"

  # TERM, then wait for real death before touching the worktree — a dying
  # Claude can still flush writes that would corrupt the clean-check.
  command kill -- "$pid" 2>/dev/null
  for _ in $(seq 1 100); do
    command kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  command kill -0 "$pid" 2>/dev/null && command kill -9 -- "$pid" 2>/dev/null

  state=none
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    if [ -z "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
      main="$(dirname "$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)")"
      if err="$(git -C "$main" worktree remove -- "$wt" 2>&1)"; then
        state=removed
      else
        case "$err" in
        # git refuses to remove ANY worktree containing submodules, even a
        # clean one. The tree was just verified clean, so rm + prune is the
        # same outcome by hand. Only this exact refusal — a locked worktree
        # (or anything else) stays preserved, that's the user talking.
        *'containing submodules'*)
          rm -rf "$wt" && git -C "$main" worktree prune && state=removed || state=preserved
          ;;
        *) state=preserved ;;
        esac
      fi
      [ "$state" = removed ] && rm -f "$sigfile"
    else
      state=preserved
    fi
  fi
  if [ "$split" = yes ]; then
    # Only the pane goes: the session around it is the user's. Killing the pid
    # already closes it in the normal case, but not under remain-on-exit.
    tm kill-pane -t "$pane" 2>/dev/null
  else
    tm kill-session -t "=$s" 2>/dev/null
  fi

  msg="killed $label — worktree $state${wt:+: $wt}"
  [ -n "${TMUX:-}" ] && tm display-message "$msg"
  if [ "$json" = yes ]; then
    jq -cn --arg st "$state" --arg p "${wt:-}" '{ok: true, worktree: $st, path: $p}'
  else
    echo "$msg"
  fi
  ;;
*)
  die "unknown subcommand '$cmd'"
  ;;
esac
