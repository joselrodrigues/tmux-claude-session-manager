#!/usr/bin/env bash
# Shared harness: scratch tmux server + temp repos. Source from each test file.
set -u
TESTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$TESTDIR/../scripts"
TMUX_SOCK="claude-test-$$"
TMUX_CMD="tmux -L $TMUX_SOCK"
T_TMP=""
FAILS=0

t_setup() {
  T_TMP="$(mktemp -d "${TMPDIR:-/tmp}/claude-agents-test.XXXXXX")"
  # Agent state is read from $CLAUDE_CONFIG_DIR/sessions, so without this every
  # test would see the developer's own running Claudes. Left empty the glob
  # matches nothing and the scripts fall back to `claude agents --json` — which
  # is the mock in tests/fixtures; call t_session to exercise the file path.
  export CLAUDE_CONFIG_DIR="$T_TMP/claude-config"
  # claude_agents_tsv falls back to `claude agents --json` whenever no session
  # file matches, and a spawn's task-waiter polls it twice a second — pointed at
  # the developer's real claude that is their real agents, at node start-up
  # prices, on repeat. The mock answers instantly and knows only fixtures.
  chmod +x "$TESTDIR/fixtures/claude"
  export PATH="$TESTDIR/fixtures:$PATH"
  # Long enough to outlive the slowest file on a loaded machine: when the
  # keeper's sleep returns, the session goes with it and every later assertion
  # fails as "can't find session: t-keeper" rather than on its own merits.
  $TMUX_CMD new-session -d -s t-keeper -c "$T_TMP" 'sleep 3000'
}

t_teardown() {
  $TMUX_CMD kill-server 2>/dev/null
  rm -rf "$T_TMP"
  if [ "$FAILS" -gt 0 ]; then echo "FAIL ($FAILS)"; exit 1; else echo "PASS"; fi
}

# t_repo <name>  — create a git repo with one commit; echoes its path.
t_repo() {
  local r="$T_TMP/$1"
  mkdir -p "$r" && git -C "$r" init -q -b main
  git -C "$r" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  printf '%s' "$r"
}

# t_session <pid> <status> [cwd]  — write the session file a running Claude
# publishes, so the scripts read this agent the way they read a real one.
# statusUpdatedAt is "now" in ms, which is what the picker's age column reads.
t_session() {
  mkdir -p "$CLAUDE_CONFIG_DIR/sessions"
  printf '{"pid":%s,"sessionId":"sid-%s","cwd":"%s","kind":"interactive","status":"%s","statusUpdatedAt":%s000}\n' \
    "$1" "$1" "${3:-$T_TMP}" "$2" "$(date +%s)" >"$CLAUDE_CONFIG_DIR/sessions/$1.json"
}

# t_no_sessions — drop every session file, sending the scripts to the CLI fallback.
t_no_sessions() { rm -rf "$CLAUDE_CONFIG_DIR/sessions"; }

# in_pane <name> <command...> — run a command in a throwaway window of the
# scratch server, with the env the scripts need, and wait for it to finish.
# Its output is left in $T_TMP/<name>.out. Needs a `host` session to hang the
# throwaway windows on, so they never disturb the client under test.
in_pane() {
  local name="$1"; shift
  $TMUX_CMD new-window -d -t '=host:' -c "$T_TMP" \
    "env CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR PATH=$TESTDIR/fixtures:\$PATH \
     sh -c '$* >$T_TMP/$name.out 2>&1; echo done >$T_TMP/$name.flag'"
  local i=0
  while [ ! -f "$T_TMP/$name.flag" ] && [ "$i" -lt 60 ]; do
    sleep 1
    i=$((i + 1))
  done
  # Said out loud, because a command that never finished and a command that
  # printed nothing produce the same empty .out file — and every assertion
  # downstream would then blame the script under test.
  [ -f "$T_TMP/$name.flag" ] || _fail "in_pane '$name' never finished"
  rm -f "$T_TMP/$name.flag"
}

# The client's current window, read the way helpers.sh:91 explains you have to:
# display-message evaluates against tmux's current session, not the client's,
# so the session has to come from the client itself first. Both read $client.
client_window() {
  local s
  s="$($TMUX_CMD list-clients -F '#{client_name} #{client_session}' |
    awk -v c="$client" '$1 == c { print $2 }')"
  [ -z "$s" ] && return 1
  $TMUX_CMD display-message -p -t "=$s:" '#{window_id}'
}
client_pane() {
  local s
  s="$($TMUX_CMD list-clients -F '#{client_name} #{client_session}' |
    awk -v c="$client" '$1 == c { print $2 }')"
  [ -z "$s" ] && return 1
  $TMUX_CMD display-message -p -t "=$s:" '#{pane_id}'
}

# settle <pane> [seconds] — wait until a pane stops repainting.
#
# fzf paints its header before its list, and a key sent into that gap can be
# swallowed by its terminal set-up. Two identical captures in a row means the
# screen has stopped moving and the UI is listening.
settle() {
  local i=0 max=$(( ${2:-10} * 5 )) now prev=''
  while [ "$i" -lt "$max" ]; do
    now="$($TMUX_CMD capture-pane -p -t "$1" 2>/dev/null)"
    [ -n "$now" ] && [ "$now" = "$prev" ] && return 0
    prev="$now"
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}

# press_until <pane> <key> <seconds> <cmd...> — press <key>, wait up to
# <seconds> for <cmd> to succeed, and press it again if nothing moved.
#
# Driving a full-screen UI down a tty is not perfectly reliable: a key sent
# while the program is still taking over the terminal can be swallowed, and
# what a user does then is press it again. Three tries, then give up.
press_until() {
  local pane="$1" key="$2" secs="$3"; shift 3
  local try i
  for try in 1 2 3; do
    $TMUX_CMD send-keys -t "$pane" "$key"
    i=0
    while [ "$i" -lt $((secs * 2)) ]; do
      "$@" && return 0
      sleep 0.5
      i=$((i + 1))
    done
  done
  return 1
}

_fail() { echo "not ok: $*"; FAILS=$((FAILS + 1)); }
assert_ok()   { "$@" >/dev/null 2>&1 || _fail "expected success: $*"; }
assert_fail() { "$@" >/dev/null 2>&1 && _fail "expected failure: $*"; }
assert_eq()   { [ "$1" = "$2" ] || _fail "${3:-assert_eq}: '$1' != '$2'"; }
