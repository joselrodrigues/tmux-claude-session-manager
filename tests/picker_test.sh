#!/usr/bin/env bash
# The picker, driven as a user drives it: fzf running in a real pane, keys sent
# to it, and the result read off the client it was supposed to move.
#
# Everything here runs on the scratch server. picker.sh and agents.sh call bare
# `tmux` (they have no TMUX_SOCKET_OVERRIDE), so they are launched from inside a
# pane of that server — tmux exports $TMUX there, which is what a bare `tmux`
# follows. Same reason the env each pane needs is passed on its command line:
# an export in this shell does not cross into a pane.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
t_setup
export TMUX_TMPDIR=""
WT_BASE="$T_TMP/wt"

$TMUX_CMD set-option -g @claude_worktree_dir "$WT_BASE"
# Never let a real claude start here: it would talk to the network, and its own
# session file would appear in CLAUDE_CONFIG_DIR alongside the fixtures.
$TMUX_CMD set-option -g @claude_command 'sleep 300'
chmod +x "$TESTDIR/fixtures/claude"

spawn() { TMUX_SOCKET_OVERRIDE="$TMUX_SOCK" bash "$SCRIPTS/spawn.sh" "$@"; }

# open_agent is a helpers.sh function calling bare tmux, so it needs the same
# shim spawn.sh installs. This is the call spawn-prompt.sh makes after a spawn.
open_as_tab() {
  TMUX_SOCKET_OVERRIDE="$TMUX_SOCK" bash -c '
    tmux() { command tmux -L "$TMUX_SOCKET_OVERRIDE" "$@"; }
    . "$1/helpers.sh"
    open_agent "$2" "$3"' _ "$SCRIPTS" "$1" "$2"
}

# in_pane / client_window / client_pane live in lib.sh — jump_test.sh drives the
# same scratch-server-with-a-real-client setup.

# ---------------------------------------------------------------- fixtures

repo="$(t_repo alpha)"
hash8="$(. "$SCRIPTS/helpers.sh"; session_hash "$(git -C "$repo" rev-parse --show-toplevel)")"
wt_parent="$WT_BASE/alpha-$hash8"

# The user's own session: two windows, so landing on the wrong one is visible.
$TMUX_CMD new-session -d -s user -c "$T_TMP" 'sleep 300'
$TMUX_CMD rename-window -t 'user:' home
home_win="$($TMUX_CMD list-windows -t '=user' -F '#{window_id}' | head -1)"
$TMUX_CMD new-window -d -t '=user:' -c "$T_TMP" 'sleep 300'
host_pane="$($TMUX_CMD list-panes -t "=user:$home_win" -F '#{pane_id}')"

# A session for the throwaway windows in_pane opens, so they never disturb the
# client under test. Wide on purpose: a detached session defaults to 80 columns,
# which truncates the picker's own rows past the path column — the branch and
# task would be missing from the screen for reasons that have nothing to do
# with the picker.
$TMUX_CMD new-session -d -s host -x 250 -y 50 -c "$T_TMP" 'sleep 300'

# A real attached client on `user` — without one there is nothing for the jump
# to move, and every assertion below would prove nothing. Wide for the same
# reason `host` is: with the default `window-size latest` every window created
# from here on follows this client, and at 80 columns fzf truncates the picker
# rows before the branch and task columns are on screen.
$TMUX_CMD new-session -d -s userhost -x 250 -y 50 -c "$T_TMP" "env -u TMUX $TMUX_CMD attach -t user"
sleep 2
client="$($TMUX_CMD list-clients -t user -F '#{client_name}' | head -1)"
[ -n "$client" ] || { _fail 'no client attached to the user session'; t_teardown; }
# What list.sh stamps before opening the popup; the picker jumps on this client.
$TMUX_CMD set-option -g @claude_parent "$client"

# 1. tab agent — its own claude-* session, linked into `user` as a tab
tab_sess="$(spawn tabby "$repo" 'fix the login flow')"
tab_win="$($TMUX_CMD list-windows -t "=$tab_sess" -F '#{window_id}')"
open_as_tab "$tab_sess" "$client"
tab_pid="$($TMUX_CMD list-panes -t "=$tab_sess" -F '#{pane_pid}')"

# 2. split agent — a stamped pane in the user's own window
split_pane="$(spawn splitty "$repo" 'chase the flaky test' --split h --target "$host_pane")"
split_pid="$($TMUX_CMD display-message -p -t "$split_pane" '#{pane_pid}')"

# 3. loose agent — a Claude someone started by hand, no stamps, no claude- session
loose_pane="$($TMUX_CMD split-window -d -P -F '#{pane_id}' -t "$host_pane" -c "$repo" 'sleep 300')"
loose_pid="$($TMUX_CMD display-message -p -t "$loose_pane" '#{pane_pid}')"

sleep 1
t_session "$tab_pid" idle "$wt_parent/tabby"
t_session "$split_pid" waiting "$wt_parent/splitty"
t_session "$loose_pid" busy "$repo"

# ------------------------------------------------------------- rows render

in_pane rows "$SCRIPTS/agents.sh"
rows="$(cat "$T_TMP/rows.out")"
[ -n "$rows" ] || _fail "agents.sh produced no rows: $(cat "$T_TMP/rows.out")"

row_for() { printf '%s\n' "$rows" | awk -F'\t' -v p="$1" '$2 == p { print; exit }'; }
field() { printf '%s\n' "$1" | cut -f"$2"; }

for probe in "$tab_pid:dedicated:tabby:fix the login flow" \
  "$split_pid:split:splitty:chase the flaky test" \
  "$loose_pid:loose:main:-"; do
  pid="${probe%%:*}"; rest="${probe#*:}"
  want_kind="${rest%%:*}"; rest="${rest#*:}"
  want_branch="${rest%%:*}"; want_task="${rest#*:}"
  # Rows are keyed by pane, and the pane is what the pid -> tty -> pane join
  # resolved to; find it the same way the picker's preview would. head -1
  # because a tab agent's window is linked into two sessions, so list-panes -a
  # walks its pane twice.
  pane="$($TMUX_CMD list-panes -a -F '#{pane_pid} #{pane_id}' |
    awk -v p="$pid" '$1 == p { print $2; exit }')"
  row="$(row_for "$pane")"
  [ -n "$row" ] || { _fail "no picker row for $want_kind agent (pane $pane)"; continue; }
  assert_eq "$(field "$row" 4)" "$want_kind" "kind column for $want_kind"
  assert_eq "$(field "$row" 9)" "$want_branch" "branch column for $want_kind"
  assert_eq "$(field "$row" 10)" "$want_task" "task column for $want_kind"
  # statusUpdatedAt was written as "now", so every row must show a real age.
  case "$(field "$row" 6)" in
  *m) : ;;
  *) _fail "age column for $want_kind is not minutes: '$(field "$row" 6)'" ;;
  esac
done

# waiting sorts above idle, which sorts above busy — what needs you floats up
assert_eq "$(printf '%s\n' "$rows" | cut -f3 | head -1)" "$split_pid" 'waiting agent sorts first'

# ------------------------------------------------------------ render speed

in_pane timing "/usr/bin/time -p $SCRIPTS/picker.sh --list"
secs="$(awk '/^real/ { print $2 }' "$T_TMP/timing.out")"
awk -v s="${secs:-99}" 'BEGIN { exit !(s < 1.0) }' ||
  _fail "picker rows took ${secs}s to build; the popup looks dead over ~1s"

# ------------------------------------------------------ the picker UI itself

# picker.sh runs where the popup would: its own pane, with a tty, on the same
# server. Keys go in with send-keys and the screen comes back with capture-pane.
picker_pane=''
picker_secs=''
open_picker() {
  local started i=0 now prev=''
  started="$(date +%s)"
  picker_pane="$($TMUX_CMD new-window -d -P -F '#{pane_id}' -t '=host:' -c "$T_TMP" \
    "env CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR PATH=$TESTDIR/fixtures:\$PATH \
     $SCRIPTS/picker.sh")"
  # Polled at 200ms because this doubles as the clock for "does the popup show
  # up before the user decides it is dead", and a coarser tick cannot tell 0.3s
  # from 0.9s — which is the whole gap the session-file swap closes.
  #
  # Settled, not merely started: fzf paints its header before the rows, so a
  # capture taken the instant "Claude agents" appears can be missing half the
  # list. Two identical captures in a row means the screen has stopped moving.
  while [ "$i" -lt 50 ]; do
    now="$($TMUX_CMD capture-pane -p -t "$picker_pane" 2>/dev/null)"
    case "$now" in
    *'Claude agents'*)
      if [ "$now" = "$prev" ]; then
        picker_secs=$(($(date +%s) - started))
        return 0
      fi
      ;;
    esac
    prev="$now"
    sleep 0.2
    i=$((i + 1))
  done
  _fail "picker never rendered: $($TMUX_CMD capture-pane -p -t "$picker_pane")"
  return 1
}
# pick <filter> — type a filter that isolates one row, then press enter.
pick() {
  $TMUX_CMD send-keys -t "$picker_pane" -l -- "$1"
  sleep 1
  $TMUX_CMD send-keys -t "$picker_pane" Enter
  sleep 2
}

if open_picker; then
  # Wall clock from launching picker.sh to its rows being on screen — the
  # blank-popup complaint the session-file swap exists to fix.
  [ "${picker_secs:-99}" -le 1 ] ||
    _fail "picker took ${picker_secs}s to appear on screen"
  screen="$($TMUX_CMD capture-pane -p -t "$picker_pane")"
  printf '%s\n' "$screen" >"$T_TMP/picker-screen.txt"
  for want in tabby splitty 'fix the login flow' 'chase the flaky test'; do
    case "$screen" in
    *"$want"*) : ;;
    *) _fail "picker screen is missing '$want' (screen in $T_TMP/picker-screen.txt)" ;;
    esac
  done

  # The regression bb96be7 fixed. The agent's window is linked into `user`, so
  # its pane belongs to two sessions and resolving "which session is this" is
  # ambiguous — the jump has to name the window id. Start the client on its own
  # window so a jump that does nothing is not mistaken for a jump that worked.
  $TMUX_CMD select-window -t "=user:$home_win"
  sleep 1
  assert_eq "$(client_window)" "$home_win" 'client parked on its own window first'
  pick tabby
  assert_eq "$(client_window)" "$tab_win" 'enter on a tab agent lands on the agent window'
fi

# A split agent is already in a window of the user's session, so enter focuses
# its pane in place rather than linking anything.
$TMUX_CMD select-window -t "=user:$home_win"
$TMUX_CMD select-pane -t "$host_pane"
sleep 1
if open_picker; then
  pick splitty
  assert_eq "$(client_pane)" "$split_pane" 'enter on a split agent focuses its pane'
fi

# ------------------------------------------------------------------ ctrl-x

# A clean spawned agent: ctrl-x kills it and takes the worktree with it. The
# binding falls back to a bare `kill` when agent.sh fails, which makes the row
# vanish either way — so the worktree, not the row, is what proves the cleanup.
doomed="$(spawn doomed "$repo" 'about to be killed' --split v --target "$host_pane")"
doomed_pid="$($TMUX_CMD display-message -p -t "$doomed" '#{pane_pid}')"
sleep 1
t_session "$doomed_pid" idle "$wt_parent/doomed"
assert_ok test -d "$wt_parent/doomed"

if open_picker; then
  $TMUX_CMD send-keys -t "$picker_pane" -l -- doomed
  sleep 1
  $TMUX_CMD send-keys -t "$picker_pane" C-x
  sleep 3
  assert_ok test ! -d "$wt_parent/doomed"
  $TMUX_CMD list-panes -a -F '#{pane_id}' | grep -qx "$doomed" &&
    _fail 'ctrl-x left the killed agent pane alive'
  # the branch survives a kill, always
  assert_ok git -C "$repo" show-ref --verify --quiet refs/heads/doomed
  $TMUX_CMD send-keys -t "$picker_pane" Escape 2>/dev/null
fi

# the user's session is still theirs, and the other agents are untouched
assert_ok $TMUX_CMD has-session -t '=user'
assert_ok $TMUX_CMD has-session -t "=$tab_sess"
$TMUX_CMD list-panes -a -F '#{pane_id}' | grep -qx "$split_pane" ||
  _fail 'the split agent did not survive the ctrl-x on its neighbour'

t_teardown
