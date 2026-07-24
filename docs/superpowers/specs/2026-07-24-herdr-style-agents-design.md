# Herdr-style multi-agent management — design

Turn the plugin into a herdr-like agent manager on top of tmux: spawn N named
Claude agents per repo, each isolated in its own git worktree, drive them from
outside (send/wait/read/kill), and manage everything from the existing picker.

Herdr's model was verified empirically against herdr 0.7.1 (worktree layout,
branch lifecycle, agent CLI), and the design was reviewed against herdr, orca,
and an adversarial feasibility pass. Where this design diverges from herdr it
does so deliberately — noted inline.

## 1. Spawn — `prefix + Y` → `scripts/spawn.sh`

- Name collection: a small `display-popup -E` helper reads the name with
  `read -r` (stdin → shell var → argv is pure data). tmux `command-prompt`
  substitution is literal and re-parsed by the shell, so a name containing
  `'`, `;` or `$()` would break out before any validation ran — the popup
  avoids that interpolation entirely.
- Validation: name must match `^[A-Za-z0-9][A-Za-z0-9._-]*$` and not contain
  `..`, end in `.`, or end in `.lock` (git ref rules). User-supplied values are
  always passed after `--` to git/tmux.
- Dir defaults to the invoking pane's current path; fails with
  `display-message` if it is not inside a git repo.
- Worktree: `<@claude_worktree_dir>/<repo>-<hash8>/<name>` where `hash8` is
  `session_hash` of the repo root — two repos with the same basename cannot
  collide. A new branch `<name>` is created from the repo's current HEAD (our
  convention; herdr's `worktree create` also accepts `--base`/custom branch
  names, which we skip). If the worktree path already exists, reuse it. If
  only the branch exists, check it out into the new worktree and warn that
  existing commits are being reused. Branch-already-checked-out-elsewhere and
  other `git worktree add` failures surface git's error via `display-message`.
- Submodule repos: after `worktree add`, run `git submodule update --init`
  in the worktree so agents don't start on empty submodule dirs.
- Session: `claude-<repo>-<name>` (existing `@claude_session_prefix` honored),
  cwd set to the worktree, running `@claude_command` + `@claude_args` — same
  launch shape as `launch.sh`. If the session already exists, spawn rejects
  with a message (no silent re-attach to an agent from another repo).
  The repo segment keeps named sessions disjoint from `launch.sh`'s
  `claude-<8hex>` hash sessions.
- Session options set at spawn: `@claude_origin`, `@claude_worktree <path>`,
  and optional `@claude_task <text>` (a one-line task description, third
  argument of the popup helper) shown as a picker column.
- Pane identity: `select-pane -T <name>` so `pane-border-status` setups show
  which agent lives where.
- Opens the popup on the session, identical to `launch.sh`.
- New tmux option: `@claude_worktree_dir` (default `$HOME/.claude-worktrees`;
  a leading `~` in user-set values is expanded explicitly — tmux stores the
  option opaquely and bash never tilde-expands variable contents).

## 2. Agent CLI — `scripts/agent.sh <subcommand> <target> ...`

Target resolution: bare name (`api` → unique session `claude-*-api`, ambiguous
→ error listing candidates), full session name, or tmux pane id (`%3`).
`send`/`read`/`kill` resolve the pane directly from tmux
(`list-panes -t <session>`), NOT from `claude agents --json` — the supervisor
registry is stale for several seconds after spawn, and spawn-then-send is the
core orchestration flow. Only `wait --status` reads the JSON, where staleness
is benign (the poll just keeps waiting).

All subcommands accept `--json` and emit a machine-readable result object, so
other Claude instances can orchestrate without parsing human text.

- `send <target> <text...>` — `tmux send-keys` the text, then Enter.
  `--no-enter` sends the literal text only. (Divergence: herdr's `agent send`
  is literal-only and `pane run` adds Enter; here the prompt-sending case is
  the default.)
- `wait <target> --status <waiting|idle|busy> [--timeout SECONDS]` — poll
  `claude agents --json` (1s interval) until the target's status matches.
  Note: `wait --status busy` immediately after `send` can race a stale
  `idle`; orchestrators should wait for the terminal state they care about.
- `wait <target> --match <text> [--regex] [--timeout SECONDS]` — poll
  `capture-pane` until the text/pattern appears (herdr's `wait output`).
  Waiting for "PASS", a question, or a banner is often more useful than a
  status transition.
- `read <target> [--lines N] [--source visible|recent]` — `capture-pane -p`;
  `recent` adds `-S -<N>` to include scrollback instead of silently
  truncating to the visible screen.
- `kill <target>` — kill the Claude pid, poll `kill -0` until the process is
  actually gone (bounded, then SIGKILL) so late writes can't corrupt the
  clean-check. Then: session has `@claude_worktree` and
  `git status --porcelain` is empty → `git worktree remove` and kill the
  session; dirty → keep the worktree, kill the session. Either way
  `display-message` names exactly what was removed or preserved. The branch
  always survives (herdr semantics). (Divergence: herdr never auto-removes
  worktrees; auto-clean on kill keeps garbage from accumulating.)

Exit 0 on success/match, 1 on timeout/failure. Default wait timeout 300s.
Scripts are directly invocable, so one Claude can spawn and drive others —
that is the orchestration story; no extra daemon or socket, tmux is the
server. A short `docs/orchestration.md` documents the coordinator loop
(spawn → send → wait → read → decide), which covers what orca implements as
a structured message bus.

## 3. Dashboard — extend `agents.sh` + `picker.sh`

- Row gains: branch column with dirty marker (`api*`) via
  `git -C <cwd> branch --show-current` + `git status --porcelain
  --untracked-files=no` (cheap even when a loose Claude sits in a monorepo),
  and the `@claude_task` description when set.
- New picker bindings:
  - `ctrl-n` — spawn a new agent. Aborts fzf, then reuses `list.sh`'s
    teardown pattern (wait for the popup client to leave, validate
    `@claude_parent` liveness) before opening the spawn popup on the outer
    client — anything opened mid-teardown hangs.
  - `ctrl-s` — prompt for text inside the picker terminal (fzf `execute`) and
    `agent.sh send` it to the selected agent without attaching.
  - `ctrl-x` (existing kill) — extended to run `agent.sh kill`, picking up the
    worktree cleanup.

## 4. Worktree lifecycle

- Clean check: `git status --porcelain` empty (after confirmed process death).
- Clean → worktree removed, branch kept. Dirty → worktree and branch kept,
  user notified with the path. Branches are never deleted by the plugin.
- Re-spawning a previously killed name reuses the surviving branch — spawn
  warns when it does.

## 5. Notifications (phase 2, optional)

The passive "an agent finished / needs you" signal — herdr's highest-value
UX (two sounds: `done` on busy→idle, `request` on busy→waiting, fired only
for agents you are not currently focused on). No daemon: a `pulse.sh` run by
tmux's `status-interval` diffs current statuses against a state file in
`/tmp` and fires the user's `notify.sh`-style hook on transitions. Ships
after the core; the design just reserves the state-file format.

## 6. Error handling

- Every user-facing failure surfaces via `tmux display-message`; scripts exit
  0 after reporting (tmux run-shell swallows stderr).
- `agent.sh` run outside tmux or with an unknown/ambiguous target prints to
  stderr and exits non-zero (it is also a CLI).

## 7. Testing

- `bash -n` + shellcheck on every new/changed script.
- Happy path: spawn in a repo → row appears with branch+task → `send` →
  `read` shows it → `wait --status busy` then `idle` → `wait --match` on a
  known string → kill clean removes worktree, kill dirty preserves it.
- Adversarial (each an explicit test): injection payload as a name
  (`x'; run-shell ...`), same agent name from two repos (second spawn must
  be rejected, not cross-attached), spawn → immediate `send` (must work
  before the supervisor registers the agent), kill while the agent is
  mid-write (clean-check must wait for death), spawn in `~/.dotfiles`
  (submodules populated), invalid ref names (`foo.lock`, `a..b`, `-x`),
  `ctrl-n` teardown timing, re-spawn of a killed name (branch-reuse warning).
