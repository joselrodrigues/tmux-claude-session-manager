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
  $TMUX_CMD new-session -d -s t-keeper -c "$T_TMP" 'sleep 300'
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

_fail() { echo "not ok: $*"; FAILS=$((FAILS + 1)); }
assert_ok()   { "$@" >/dev/null 2>&1 || _fail "expected success: $*"; }
assert_fail() { "$@" >/dev/null 2>&1 && _fail "expected failure: $*"; }
assert_eq()   { [ "$1" = "$2" ] || _fail "${3:-assert_eq}: '$1' != '$2'"; }
