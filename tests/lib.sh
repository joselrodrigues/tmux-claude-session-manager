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

_fail() { echo "not ok: $*"; FAILS=$((FAILS + 1)); }
assert_ok()   { "$@" >/dev/null 2>&1 || _fail "expected success: $*"; }
assert_fail() { "$@" >/dev/null 2>&1 && _fail "expected failure: $*"; }
assert_eq()   { [ "$1" = "$2" ] || _fail "${3:-assert_eq}: '$1' != '$2'"; }
