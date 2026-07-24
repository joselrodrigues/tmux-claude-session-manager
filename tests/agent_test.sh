#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
t_setup

agent() { TMUX_SOCKET_OVERRIDE="$TMUX_SOCK" bash "$SCRIPTS/agent.sh" "$@"; }

# three agent-shaped sessions running plain shells (send/read work on any pane)
$TMUX_CMD new-session -d -s claude-alpha-api  -c "$T_TMP" 'bash --norc'
$TMUX_CMD new-session -d -s claude-beta-api   -c "$T_TMP" 'bash --norc'
$TMUX_CMD new-session -d -s claude-alpha-docs -c "$T_TMP" 'bash --norc'
# resolve_sessions' bare-name lookup now keys off this option (spawn.sh sets
# it); set it by hand since these sessions are built manually, not spawned.
$TMUX_CMD set-option -t claude-alpha-api  @claude_agent_name api
$TMUX_CMD set-option -t claude-beta-api   @claude_agent_name api
$TMUX_CMD set-option -t claude-alpha-docs @claude_agent_name docs

# Test case: stamped session with name that would regex-match bogus target.
# claude-my-api-v2 is stamped as v2; a request for api-v2 should fail,
# not fall back to regex and accidentally match v2.
$TMUX_CMD new-session -d -s claude-my-api-v2 -c "$T_TMP" 'bash --norc'
$TMUX_CMD set-option -t claude-my-api-v2 @claude_agent_name v2

# Legacy test: unstamped session should still match via regex when no
# stamped sessions are checked. This session is made after all the stamped
# ones, so resolve_sessions will see has_any_stamp=yes and NOT try regex
# for other lookups. We'll test it specifically via full session name.
$TMUX_CMD new-session -d -s claude-legacy-query -c "$T_TMP" 'bash --norc'

sleep 1

# bare unique name resolves; ambiguous bare name fails; full session works
assert_ok   agent send docs 'echo docs-was-here'
assert_fail agent send api  'echo ambiguous'
assert_ok   agent send claude-beta-api 'echo beta-got-it'
sleep 1

out="$(agent read claude-beta-api --lines 5)"
case "$out" in *beta-got-it*) : ;; *) _fail "read missed sent text: $out" ;; esac

# --no-enter leaves the text on the input line, not executed
assert_ok agent send docs --no-enter 'echo NOT-RUN'
sleep 1
out="$(agent read claude-alpha-docs)"
case "$out" in *'$ echo NOT-RUN'*) : ;; *) _fail "--no-enter executed: $out" ;; esac

# pane-id target
pane="$($TMUX_CMD list-panes -t claude-alpha-docs -F '#{pane_id}' | head -1)"
assert_ok agent read "$pane"

# pane-id target on a multi-pane session must hit that exact pane, not the
# session's first pane
$TMUX_CMD split-window -t claude-alpha-docs -d -c "$T_TMP" 'bash --norc'
sleep 1
first_pane="$($TMUX_CMD list-panes -t claude-alpha-docs -F '#{pane_id}' | sed -n 1p)"
second_pane="$($TMUX_CMD list-panes -t claude-alpha-docs -F '#{pane_id}' | sed -n 2p)"
assert_ok agent send "$second_pane" 'echo second-pane-only'
sleep 1
out="$(agent read "$second_pane")"
case "$out" in *second-pane-only*) : ;; *) _fail "second pane missed sent text: $out" ;; esac
out="$(agent read "$first_pane")"
case "$out" in *second-pane-only*) _fail "text leaked into first pane: $out" ;; *) : ;; esac

# unknown target
assert_fail agent read nosuchagent

# --json shapes
agent send docs --json 'true' | jq -e '.ok == true and (.targets | length) == 1' >/dev/null || _fail send-json
agent read claude-alpha-docs --json | jq -e '.ok == true and (.lines | type) == "string"' >/dev/null || _fail read-json

# stamped-sessions-only test: regex fallback must be disabled
# claude-my-api-v2 is stamped as v2; api-v2 is NOT a stamp and would regex-match
# (claude-my-<api>-<v2>), but with stamped sessions present, regex is forbidden.
assert_fail agent send api-v2 'echo should-fail'

# but exact stamp match on v2 must work
assert_ok agent send v2 'echo v2-got-it'
sleep 1
out="$(agent read claude-my-api-v2 --lines 5)"
case "$out" in *v2-got-it*) : ;; *) _fail "stamped v2 lookup failed: $out" ;; esac

# legacy/unstamped session still works via full session name
# (It can't be tested via bare name because stamped sessions exist)
assert_ok agent send claude-legacy-query 'echo legacy-ok'
sleep 1
out="$(agent read claude-legacy-query --lines 5)"
case "$out" in *legacy-ok*) : ;; *) _fail "legacy session failed: $out" ;; esac

t_teardown
