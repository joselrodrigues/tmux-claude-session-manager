#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$SCRIPTS/helpers.sh"
t_setup

assert_ok   valid_agent_name api
assert_ok   valid_agent_name a1._x-2
assert_fail valid_agent_name ''
assert_fail valid_agent_name -x
assert_fail valid_agent_name .hidden
assert_fail valid_agent_name 'a..b'
assert_fail valid_agent_name 'foo.lock'
assert_fail valid_agent_name 'foo.'
assert_fail valid_agent_name 'a b'
assert_fail valid_agent_name "x'; run-shell 'touch /tmp/pwned'"

assert_eq "$(expand_tilde '~/x')" "$HOME/x" tilde-expanded
assert_eq "$(expand_tilde '/abs/x')" '/abs/x' abs-untouched

t_teardown
