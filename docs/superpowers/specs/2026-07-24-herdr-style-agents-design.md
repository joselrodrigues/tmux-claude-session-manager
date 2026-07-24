# Herdr-style multi-agent management — design

Turn the plugin into a herdr-like agent manager on top of tmux: spawn N named
Claude agents per repo, each isolated in its own git worktree, drive them from
outside (send/wait/read/kill), and manage everything from the existing picker.

Herdr's model was verified empirically against herdr 0.7.1 (worktree layout,
branch lifecycle, agent CLI). Where this design diverges, it does so
deliberately — noted inline.

## 1. Spawn — `prefix + Y` → `scripts/spawn.sh <name> [dir]`

- `tmux command-prompt -p 'agent name:'` collects the name; dir defaults to the
  invoking pane's current path.
- Fails with a `display-message` if dir is not inside a git repo, or the name
  is empty / contains characters unsafe for a session name (allowed:
  `[A-Za-z0-9._-]`).
- Worktree: `<@claude_worktree_dir>/<repo-name>/<name>` with a new branch
  `<name>` from the repo's current HEAD (herdr semantics). If the worktree
  path already exists, reuse it as-is. If only the branch exists, check it out
  into the new worktree.
- Session: `claude-<name>` (existing `@claude_session_prefix` honored), cwd set
  to the worktree, running `@claude_command` + `@claude_args` — same launch
  shape as `launch.sh`.
- Session options set at spawn: `@claude_origin` (like `launch.sh`) and
  `@claude_worktree <path>` so kill knows the session is worktree-backed.
- Opens the popup on the session, identical to `launch.sh`.
- New tmux option: `@claude_worktree_dir` (default `~/.claude-worktrees`).

## 2. Agent CLI — `scripts/agent.sh <subcommand> <target> ...`

Target resolution: bare name (`api` → session `claude-api`), full session
name, or tmux pane id (`%3`). For session targets the pane is the one running
Claude, resolved with the same pid→tty→pane join `agents.sh` already does.

- `send <target> <text...>` — `tmux send-keys` the text, then Enter.
  `--no-enter` sends the literal text only. (Divergence: herdr's `agent send`
  is literal-only and `pane run` adds Enter; here the prompt-sending case is
  the default.)
- `wait <target> --status <waiting|idle|busy> [--timeout SECONDS]` — poll
  `claude agents --json` (1s interval) until the target's status matches.
  Exit 0 on match, 1 on timeout. Default timeout 300s.
- `read <target> [--lines N]` — `tmux capture-pane -p` on the agent's pane
  (last N lines, default full visible pane).
- `kill <target>` — kill the Claude pid (same as the picker's ctrl-x), then:
  if the session has `@claude_worktree` and `git status --porcelain` in it is
  empty → `git worktree remove` (the branch always survives, herdr semantics)
  and kill the session. Dirty worktree → keep it, kill the session, and
  `display-message` the preserved path. (Divergence: herdr never auto-removes
  worktrees; auto-clean on kill keeps garbage from accumulating.)

Scripts are directly invocable (`~/.tmux/plugins/tmux-claude-session-manager/scripts/agent.sh`),
so one Claude can spawn and drive others — that is the orchestration story; no
extra daemon or socket, tmux is the server.

## 3. Dashboard — extend `agents.sh` + `picker.sh`

- Row gains a branch column with a dirty marker (`api*`), via
  `git -C <cwd> branch --show-current` and `git status --porcelain` per row.
  Agent counts are small; a couple of git calls per row is fine.
- New picker bindings:
  - `ctrl-n` — spawn a new agent: closes the picker and triggers the
    `command-prompt` name flow on the outer client (`@claude_parent`).
  - `ctrl-s` — prompt for text inside the picker terminal (fzf `execute`) and
    `agent.sh send` it to the selected agent without attaching.
  - `ctrl-x` (existing kill) — extended to run `agent.sh kill`, picking up the
    worktree cleanup.

## 4. Worktree lifecycle

- Clean check: `git status --porcelain` empty.
- Clean → worktree removed, branch kept. Dirty → worktree and branch kept,
  user notified with the path. Branches are never deleted by the plugin.

## 5. Error handling

- Every user-facing failure surfaces via `tmux display-message`; scripts exit
  0 after reporting (tmux run-shell swallows stderr).
- `agent.sh` run outside tmux or with an unknown target prints to stderr and
  exits non-zero (it is also a CLI).

## 6. Testing

- `bash -n` + shellcheck on every new/changed script.
- Manual smoke: spawn in a repo → row appears with branch → `send` a prompt →
  `read` shows it → `wait --status busy` then `idle` → `kill` on a clean
  worktree removes it, on a dirty one preserves it.
