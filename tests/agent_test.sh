#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
t_setup

agent() { TMUX_SOCKET_OVERRIDE="$TMUX_SOCK" bash "$SCRIPTS/agent.sh" "$@"; }

# two agent-shaped sessions running plain shells (send/read work on any pane)
$TMUX_CMD new-session -d -s claude-alpha-api  -c "$T_TMP" 'bash --norc'
$TMUX_CMD new-session -d -s claude-beta-api   -c "$T_TMP" 'bash --norc'
$TMUX_CMD new-session -d -s claude-alpha-docs -c "$T_TMP" 'bash --norc'
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

t_teardown
