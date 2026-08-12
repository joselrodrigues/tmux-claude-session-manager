# tmux-claude-session-manager

[![screenshot](./docs/screenshot.jpg)](https://youtu.be/NnTV6r4l5D0)

Run many [Claude Code](https://claude.com/claude-code) sessions across your
projects, each in its own tmux session — then **list them, see which are done
vs. still working, and open one as a tab** in the session you already work in.

If you launch Claude per-directory (one nested session per project), you quickly
end up with a dozen of them and no way to tell which are finished without opening
each one. This plugin gives you:

- 🔢 **A central picker** (`prefix` + `u`) listing every running Claude agent —
  several in one project, and any running loose in an ordinary pane.
- 🟢 **Live status** per agent — `working` / `waiting` / `idle` — read straight
  from what each Claude publishes about itself, so you instantly see which need
  you. No setup.
- 👁️ **A live preview** of each agent's screen right in the picker.
- 🎯 **Smart jump** — selecting an agent opens it as a window (tab) of your own
  session. Close the tab and the agent keeps running.
- ⚡ **One key to whoever needs you** (`prefix` + `J`) — straight to the agent
  waiting on you, no picker in between.
- 🚀 **A launcher** (`prefix` + `y`) that opens/attaches a Claude session for the
  current directory.
- ❌ **Quick kill** (`ctrl-x`) of a finished agent from the picker.

Status needs no configuration. Claude Code publishes each agent's own state and
the picker reads it — there are no hooks to install.

## Prerequisites

- **tmux ≥ 3.2** (for `display-popup`)
- **[fzf](https://github.com/junegunn/fzf)** — the picker UI
- **[jq](https://jqlang.org/)** — parses the agent state files
- **[Claude Code](https://claude.com/claude-code)** ≥ 2.1.139 — for published
  agent status (`claude --version` to check)
- bash; macOS or Linux

## Install (tpm)

Add to `~/.tmux.conf` (or `~/.config/tmux/tmux.conf`):

```tmux
set -g @plugin 'craftzdog/tmux-claude-session-manager'
```

Then hit `prefix` + <kbd>I</kbd> to install.

> **Keybinding note:** by default the plugin binds `prefix` + `y` (launch),
> `prefix` + `u` (list), `prefix` + `J` (jump to the agent that needs you),
> `prefix` + `Y` (spawn), `prefix` + `S` (spawn into a
> split) and `prefix` + `b` (close an agent tab). If your config binds those
> elsewhere, either change the options
> below, or make sure the plugin loads **after** your own bindings (put
> `run '~/.tmux/plugins/tpm/tpm'` _after_ them) so the one you want wins.

### Manual install

```sh
git clone https://github.com/craftzdog/tmux-claude-session-manager ~/clone/path
```

Add to `~/.tmux.conf`, then reload (`prefix` + <kbd>r</kbd> or `tmux source ~/.tmux.conf`):

```tmux
run-shell ~/clone/path/claude_session_manager.tmux
```

## Usage

| Key            | Action                                                                        |
| -------------- | ----------------------------------------------------------------------------- |
| `prefix` + `y` | Launch (or re-open) a Claude session for the current directory, as a tab      |
| `prefix` + `u` | Open the agent picker                                                         |
| `prefix` + `J` | Jump straight to the agent that most needs you, without the picker            |
| `prefix` + `Y` | Spawn a named agent in its own git worktree                                   |
| `prefix` + `S` | Spawn one the same way, but as a split of this window                        |
| `prefix` + `b` | Close the agent tab you are on, leaving the agent running                     |

> ⚠️ **`prefix` + `&` kills the agent.** An agent tab is a real tmux window, so
> tmux's own kill-window destroys the Claude process running in it and takes the
> agent's session with it — the worktree and branch survive on disk, but nothing
> cleans them up and the agent disappears from the picker. Use `prefix` + `b`
> (`unlink-window`) to close a tab, or `ctrl-x` in the picker for a real kill
> with worktree cleanup.

Inside the picker:

| Key                       | Action                                                |
| ------------------------- | ----------------------------------------------------- |
| `enter`                   | Jump to the agent (see [How it works](#how-it-works)) |
| `ctrl-x`                  | Kill the highlighted agent                            |
| `↑` / `↓`, type to filter | fzf navigation                                        |

Agents needing your attention (`waiting`, `idle`) sort to the top.

Every running Claude gets its own row — the picker identifies each by its process,
not by its tmux session. So several agents in one project all show up separately,
as does a Claude you started by hand in an ordinary pane.

## Options

Set any of these before the plugin loads (defaults shown):

```tmux
set -g @claude_launch_key     'y'                    # prefix key: launch/open for current dir
set -g @claude_list_key       'u'                    # prefix key: open the picker
set -g @claude_jump_key       'J'                    # prefix key: jump to the agent that needs you
set -g @claude_spawn_key      'Y'                    # prefix key: spawn named agent
set -g @claude_split_key      'S'                    # prefix key: spawn one into a split of this window
set -g @claude_command        'claude'               # command run in new sessions
set -g @claude_args           ''                     # extra args appended to the command
set -g @claude_session_prefix 'claude-'              # tmux session name prefix
set -g @claude_worktree_dir   '~/.claude-worktrees'  # where to store worktrees
set -g @claude_unlink_key     'b'                    # prefix key: close an agent tab, keep the agent
set -g @claude_popup_width    '90%'                  # picker/prompt popup width
set -g @claude_popup_height   '90%'                  # picker/prompt popup height
set -g @claude_fzf_options    ''                     # extra options passed to the fzf picker
set -g @claude_sound_enabled  'on'                   # background-agent notification sounds
set -g @claude_sound_done     '~/.claude/sounds/terminado.mp3'  # played on busy -> idle
set -g @claude_sound_request  '~/.claude/sounds/esperando.mp3'  # played on busy -> waiting
```

For example, to skip permission prompts in launched sessions:

```tmux
set -g @claude_args '--dangerously-skip-permissions'
```

### Customizing the fzf picker

`@claude_fzf_options` is passed straight to `fzf`, so you can add your own bindings.

Here is a vim keybinding example:

```tmux
set -g @claude_fzf_options "\
  --prompt 'nav> ' \
  --bind 'j:down' \
  --bind 'k:up' \
  --bind 'q:abort' \
  --bind 'x:execute-silent(kill {3})+reload(sleep 0.3; \$CLAUDE_PICKER --list)' \
  --bind 'i:unbind(j,k,q,i,a,x)+change-prompt(filter> )' \
  --bind 'a:unbind(j,k,q,i,a,x)+change-prompt(filter> )' \
  --bind 'esc:rebind(j,k,q,i,a,x)+change-prompt(nav> )'"
```

The picker opens in **nav** mode:

| Key       | Action                                                  |
| --------- | ------------------------------------------------------- |
| `j` / `k` | move down / up                                          |
| `i` / `a` | switch to **filter** mode — type to fuzzy-match         |
| `x`       | kill the highlighted agent (like the built-in `ctrl-x`) |
| `q`       | close the picker                                        |
| `enter`   | jump to the agent (both modes)                          |
| `esc`     | filter mode → back to nav                               |

Only the bound keys are special in nav mode; any other key still filters as you
type. `x` reloads the list through `$CLAUDE_PICKER`, a path the picker exports for
exactly this — write it as `\$CLAUDE_PICKER` inside the double-quoted value above
so tmux stores a literal `$` (in a single-quoted value, use a bare
`$CLAUDE_PICKER`).

## How it works

- The **launcher** creates a detached `claude-<hash-of-dir>` tmux session running
  `claude`, names its window after the directory, and links that window into your
  own session as a tab.
- **Agents live in their own sessions and only visit yours.** `link-window` makes
  one window appear in two sessions at once — it is the same window, not a copy —
  so an agent tab keeps running when you close it with `unlink-window`, and
  survives your session being destroyed entirely. Opening the same agent twice
  focuses the tab you already have rather than adding a second one.
- **A split agent is the opposite trade.** `prefix` + `S` spawns the same
  worktree agent, but as a plain split of the window you are in — no session of
  its own, nothing linked anywhere. It lives exactly as long as its pane: close
  the pane and Claude dies with it (the worktree and branch stay on disk, and
  nothing cleans them up). To keep one around without a tab of your own screen,
  `break-pane` moves it into a window of its own; the agent does not notice, and
  `ctrl-x` in the picker still kills it with the usual worktree cleanup.
  Everything that identifies a tab agent — its worktree, name and task — is
  stamped on the pane instead of on a session.
- **The task is typed in for you.** A spawn that collected a task waits — in the
  background, so the popup closes immediately — until that agent publishes
  itself, then sends the text. The wait is on the agent registering, never on
  what the pane prints: the shell and node write plenty before Claude's input
  box exists, and anything typed into that gap is lost. If the agent never
  registers within 20s nothing is sent, and the task is still on the picker row.
- **The base branch is asked for, not assumed.** `prefix` + `Y` / `prefix` + `S`
  offer a list of local branches for the new worktree to be cut from, with the
  repo's default under the cursor. That default is
  `git config claude.baseBranch` when you set one, otherwise the branch
  `origin/HEAD` points at, otherwise the branch you are on — the same chain
  `spawn.sh` follows when nobody passes `--base`.
- **The jump key** (`prefix` + `J`) takes the picker's top row — waiting first,
  then idle oldest-first — and jumps to it directly, through the same code path
  `enter` in the picker uses.
- **Restored sessions do not block a name forever.** tmux-continuum brings back
  a `claude-*` session with its name, a bare shell and no Claude in it; spawning
  that name again recycles the empty shell instead of refusing. A session is
  only treated as empty when nothing published itself against its pane's tty
  _and_ the pane is not running the configured `@claude_command` — a live agent
  is never killed to make room.
- **Each Claude's own state file** is the source of truth for what is running
  and how it is doing. A running session writes `~/.claude/sessions/<pid>.json`
  (honouring `CLAUDE_CONFIG_DIR`) with its state — `busy` / `waiting` / `idle` —
  and the scripts read those files with one `jq`. Nothing here scans processes
  for a `claude` command name — on macOS a pane reports its parent shell, never
  the `claude` child running inside it.
- **`claude agents --json` is the fallback**, used only when no state files
  exist, so status still needs no setup on machines that do not write them. It
  publishes the same data, but starting the CLI costs a quarter-second idle and
  seconds on a loaded machine — paid on every picker render, every
  `agent.sh wait` tick and every notification poll. Reading the files is ~10ms,
  which is the difference between a picker that opens and one that looks dead.
- **`agents.sh`** pairs each running Claude with the tmux pane it occupies by
  joining `pid` → `tty` → pane. That join is why identity is the Claude _process_
  rather than the tmux session, and therefore why several agents in one project
  each get their own row. It costs three subprocesses per render, whatever the
  number of sessions or panes.
- The **age column** is how long ago the agent last changed state, from the
  `statusUpdatedAt` in its state file. On the `claude agents --json` fallback —
  which reports only `startedAt`, never a last-activity time — it falls back to
  the mtime of the agent's transcript. Either way a brand-new agent that has yet
  to take a turn shows `-`.
- The **picker** renders those rows with a live `capture-pane` preview. It is
  itself a popup — a chooser you pass through, not somewhere you live. On `enter`
  a **dedicated** agent (in a `claude-*` session) opens as a tab in your session,
  while a **split** one (a stamped pane) or a **loose** one (any other pane) is
  focused in place — both already live somewhere. `ctrl-x` kills the Claude
  process itself: a dedicated session dies with its last window, a split agent
  takes its pane with it, and a loose pane keeps the shell that hosted it.

## Named agents & worktrees

Named agents let a coordinator Claude (or any script) orchestrate the fleet
without attaching. Launch with `prefix` + `Y` from any directory, then send
tasks and wait for completion via CLI.

### Spawn and control

| Command | Action |
| ------- | ------ |
| `spawn.sh [name] [repo] ["task"]` | Launch a named agent for `<repo>` with the given task; prints the session name on stdout. `name` is optional — empty auto-generates `agentN` (names cannot contain dots). Reuses worktree if name exists in that repo. The task is typed into the agent as soon as it comes up. `--no-popup` is accepted for CLI compatibility but is a no-op. |
| `spawn.sh [name] [repo] ["task"] --base <ref>` | The same, cutting the agent's branch from `<ref>` instead of the default. Ignored (with a warning) when the agent's branch already exists — that branch is where its work is. |
| `spawn.sh [name] [repo] ["task"] --split <h\|v> [--target <pane>]` | The same, as a split of `<pane>`'s window (`h` side by side, `v` stacked) instead of a session; prints the new pane id on stdout. `--target` defaults to whatever tmux calls the current pane, which is why the keybinding always passes it. |
| `agent.sh send <name\|@target> '<message>'` | Send text to an agent or group target. |
| `agent.sh read <name> [--lines N]` | Print agent's pane output. |
| `agent.sh wait <name> [--status <waiting\|idle\|busy>] [--match <text> [--regex]] [--signal <done\|blocked>] [--timeout SEC] [--json]` | Block until status matches, text appears, or signal is sent. |
| `agent.sh signal <name> <done\|blocked> [--body "<summary>"]` | Send a completion signal. |
| `agent.sh kill <name>` | Kill the agent; clean worktree removed, dirty preserved; branch always survives. |

### Group targets

Send to multiple agents with `@all`, `@idle`, `@waiting`, or `@busy`:

```bash
agent.sh send @idle 'pick up the next task from TODO.md'
```

### Picker bindings

When inside the picker (opened with `prefix` + `u`), these bindings work for named agents:

| Key      | Action                     |
| -------- | -------------------------- |
| `ctrl-n` | Spawn a new agent and open it as a tab |
| `ctrl-s` | Send text to agent         |
| `ctrl-x` | Kill agent + cleanup       |

### Notifications

Agents you are not looking at ring when they change state, so you can leave them
running and go back to your own window:

| Transition       | Sound                     | Message                       |
| ---------------- | ------------------------- | ----------------------------- |
| `busy` → `idle`  | `@claude_sound_done`      | `claude: <name> finished`     |
| `busy` → `waiting` | `@claude_sound_request` | `claude: <name> needs input`  |

An agent is considered **focused** — and therefore silent — only when its window
is the active window of an *attached* session. That can be its own session or,
more usually, the session you opened it into as a tab: an agent tab you are
looking at is silent, and the same tab sitting in the background still rings. It
is the window rather than the pane because a split agent shares a window with
you — it is on your screen while you type in your own pane next to it.
tmux cannot see whether the terminal emulator itself is in the foreground, so an
attached client behind another app still counts as focused.

Mute one agent without silencing the rest:

```bash
tmux set-option -t claude-myrepo-api @claude_sound_mute on   # tab agent
tmux set-option -p -t %7 @claude_sound_mute on               # split agent (its pane)
```

`~/.claude/mute` (the file `cmute`/`cunmute` toggle) silences everything, and
`set -g @claude_sound_enabled off` disables the feature at the next poll — no
tmux restart needed.

The poll rides the tmux status line: `pulse.sh` appends a `#()` to
`status-right` at load and on every `client-attached`, which means the status
line must be on (`set -g status on`) and `status-interval` decides the latency —
with the default `15` a notification can lag up to 15 seconds. Each poll is one
short-lived process; there is no daemon.

The default sound paths point at `~/.claude/sounds/*.mp3`, the same files the
Claude Code notification hook uses. Nothing plays if they are missing — point
the options at your own files if you keep them elsewhere.

### Full workflow

See [docs/orchestration.md](docs/orchestration.md) for a complete example,
including how to handle all three terminal states (`done`, `blocked`, `waiting`).

## License

[MIT](LICENSE) © Takuya Matsuyama
