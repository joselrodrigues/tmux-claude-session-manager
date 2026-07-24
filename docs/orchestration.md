# Orchestrating agents from another Claude

Every script is a plain CLI — a coordinator Claude (or you) can drive the
whole fleet without attaching. `S=~/.tmux/plugins/tmux-claude-session-manager/scripts`.

## The coordinator loop

    "$S/spawn.sh" api ~/work/repo "implement the /login endpoint" --no-popup
    "$S/agent.sh" send api 'Implement /login per the spec in docs/auth.md.
    When you finish, run: '"$S"'/agent.sh signal api done --body "<one-line summary>".
    If you get stuck, signal blocked instead.'
    "$S/agent.sh" wait api --signal done --timeout 1800 --json
    "$S/agent.sh" read api --lines 40
    "$S/agent.sh" kill api          # clean worktree -> removed; branch survives

## Three terminal states — handle all three

- `wait --signal done` succeeds → finished; summary is in the signal body.
- `wait --signal blocked` succeeds → agent is stuck; `read` the pane, decide.
- neither fires but `wait --status waiting` hits → the agent is asking a
  question; `read` the pane, `send` an answer, keep waiting.

Idle alone is ambiguous (done? question?) — that is why workers are told to
signal explicitly. `--status`/`--match` are fallbacks for agents that never
got the contract.

## Fan-out

    for n in try-a try-b try-c; do "$S/spawn.sh" "$n" ~/work/repo "same task" --no-popup; done
    "$S/agent.sh" send @all 'Task: ... signal done when finished.'
    # wait on each, then compare in the picker (branch column shows dirty state),
    # keep the winner's branch, kill the rest. Comparing/merging stays manual —
    # disagreement between attempts is signal, not noise.

## Group targets

`send` accepts `@all`, `@idle`, `@waiting`, `@busy` — e.g.
`agent.sh send @idle 'pick up the next task from TODO.md'`.
