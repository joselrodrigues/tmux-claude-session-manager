# Herdr-style Multi-Agent Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Spawn N named Claude agents per repo in isolated git worktrees and drive them from outside (send/wait/read/signal/kill) via a bash CLI plus the existing fzf picker.

**Architecture:** All bash inside this tmux plugin. New `spawn.sh` (worktree + session), `spawn-prompt.sh` (popup name collector), `agent.sh` (driving CLI). Extensions to `helpers.sh`, `agents.sh`, `picker.sh`, `claude_session_manager.tmux`. No daemon — tmux is the server; agent status comes from `claude agents --json`; explicit completion comes from a sidecar signals file.

**Tech Stack:** bash, tmux ≥3.2 (display-popup), fzf, jq, git worktrees, Claude Code CLI.

**Spec:** `docs/superpowers/specs/2026-07-24-herdr-style-agents-design.md`. One deliberate deviation discovered while planning: the signals file lives NEXT TO the worktree (`<wt_parent>/.<name>.signals`), not inside it — an untracked file inside would make the clean-check read dirty and block `git worktree remove`. Task 5 updates the spec to match.

## Global Constraints

- Session naming: `claude-<repo>-<name>` (`@claude_session_prefix` honored, default `claude-`).
- Worktrees: `<@claude_worktree_dir>/<repo>-<hash8>/<name>`, default base `$HOME/.claude-worktrees`, `hash8` = `session_hash` of repo root.
- Agent names: `^[A-Za-z0-9][A-Za-z0-9._-]*$`, no `..`, no trailing `.`, no `.lock` suffix.
- Branches are never deleted by the plugin.
- User-facing errors: `tmux display-message` when inside tmux, stderr otherwise; CLI exits non-zero on failure, 1 on wait timeout.
- Every script passes `bash -n` and `shellcheck` before commit.
- Tests run against a scratch tmux server `tmux -L claude-test` and temp git repos under `$TMPDIR` — never the user's real server or repos.
- Commit format: conventional commits, no Claude attribution.

---

### Task 1: Test harness + name/path helpers

**Files:**
- Create: `tests/lib.sh`
- Create: `tests/helpers_test.sh`
- Modify: `scripts/helpers.sh` (append)

**Interfaces:**
- Produces: `valid_agent_name <name>` (exit 0/1), `expand_tilde <path>` (echoes), test helpers `t_setup`, `t_teardown`, `t_repo`, `assert_ok`, `assert_fail`, `assert_eq`, `TMUX_CMD` (array-free string `tmux -L claude-test`).

- [ ] **Step 1: Write the test harness**

```bash
# tests/lib.sh
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
```

```bash
# tests/helpers_test.sh
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
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/helpers_test.sh`
Expected: `not ok` lines (functions undefined) and `FAIL`.

- [ ] **Step 3: Implement in helpers.sh (append)**

```bash
# valid_agent_name <name>
# Charset for session names AND git branch names: rejects git-ref invalids
# (.., trailing dot, .lock suffix) and anything argv/tmux-unsafe.
valid_agent_name() {
  case "$1" in
  '' | *..* | *.lock | *.) return 1 ;;
  esac
  printf '%s' "$1" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]*$'
}

# expand_tilde <path>
# tmux stores user options opaquely and bash never tilde-expands variable
# contents, so a leading ~ in @claude_worktree_dir must be expanded by hand.
expand_tilde() { printf '%s' "${1/#\~/$HOME}"; }
```

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/helpers_test.sh`
Expected: `PASS`

- [ ] **Step 5: Lint and commit**

```bash
bash -n scripts/helpers.sh tests/lib.sh tests/helpers_test.sh
shellcheck scripts/helpers.sh tests/lib.sh tests/helpers_test.sh
git add scripts/helpers.sh tests/
git commit -m "feat: agent name validation, tilde expansion, test harness"
```

---

### Task 2: spawn.sh — worktree + session creation (CLI mode)

**Files:**
- Create: `scripts/spawn.sh`
- Create: `tests/spawn_test.sh`

**Interfaces:**
- Consumes: `get_tmux_option`, `session_hash`, `valid_agent_name`, `expand_tilde` from `helpers.sh`.
- Produces: `spawn.sh <name> [dir] [task] [--no-popup] [--window <id>]`. Creates worktree + session `claude-<repo>-<name>`, sets `@claude_worktree`, `@claude_task`, `@claude_origin`, pane title. Exit non-zero + message on failure. Tests always pass `--no-popup`.

- [ ] **Step 1: Write the failing test**

```bash
# tests/spawn_test.sh
#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
t_setup
export TMUX_TMPDIR=""  # keep tmux calls on our -L socket via wrapper below
WT_BASE="$T_TMP/wt"

# spawn.sh talks to tmux; route it to the scratch server and a fake agent cmd.
spawn() {
  TMUX='' tmux -L "$TMUX_SOCK" set-option -g @claude_worktree_dir "$WT_BASE"
  TMUX='' tmux -L "$TMUX_SOCK" set-option -g @claude_command 'sleep 300'
  TMUX_SOCKET_OVERRIDE="$TMUX_SOCK" bash "$SCRIPTS/spawn.sh" "$@" --no-popup
}

repo="$(t_repo alpha)"

# happy path: worktree, branch, session, options
assert_ok spawn api "$repo" 'fix the login bug'
hash8="$(. "$SCRIPTS/helpers.sh"; session_hash "$repo")"
wt="$WT_BASE/alpha-$hash8/api"
assert_ok test -d "$wt"
assert_eq "$(git -C "$wt" branch --show-current)" api branch-name
assert_ok $TMUX_CMD has-session -t '=claude-alpha-api'
assert_eq "$($TMUX_CMD show-option -t claude-alpha-api -qv @claude_worktree)" "$wt" wt-option
assert_eq "$($TMUX_CMD show-option -t claude-alpha-api -qv @claude_task)" 'fix the login bug' task-option

# collision: same name again is rejected, not re-attached
assert_fail spawn api "$repo"

# same agent name in a second repo gets its own session (repo segment disjoint)
repo2="$(t_repo beta)"
assert_ok spawn api "$repo2"
assert_ok $TMUX_CMD has-session -t '=claude-beta-api'

# invalid names rejected before any git/tmux action
assert_fail spawn 'foo.lock' "$repo"
assert_fail spawn 'a..b' "$repo"
assert_fail spawn -x "$repo"

# non-repo dir rejected
assert_fail spawn ok "$T_TMP"

# existing-branch reuse: branch survives a worktree removal, respawn reuses it
git -C "$repo" worktree remove --force "$wt"
$TMUX_CMD kill-session -t '=claude-alpha-api'
assert_ok spawn api "$repo"
assert_eq "$(git -C "$WT_BASE/alpha-$hash8/api" branch --show-current)" api branch-reused

t_teardown
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/spawn_test.sh`
Expected: FAIL — `spawn.sh` does not exist.

- [ ] **Step 3: Implement scripts/spawn.sh**

```bash
#!/usr/bin/env bash
# Spawn a named Claude agent: worktree + dedicated session (+ popup).
#   spawn.sh <name> [dir] [task] [--no-popup] [--window <window-id>]
# TMUX_SOCKET_OVERRIDE reroutes every tmux call (tests use a scratch server).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

tm() {
  if [ -n "${TMUX_SOCKET_OVERRIDE:-}" ]; then
    command tmux -L "$TMUX_SOCKET_OVERRIDE" "$@"
  else
    command tmux "$@"
  fi
}
# helpers.sh's get_tmux_option calls bare tmux; shadow it through tm.
tmux() { tm "$@"; }

die() {
  [ -n "${TMUX:-}" ] && tm display-message "claude-spawn: $*"
  echo "claude-spawn: $*" >&2
  exit 1
}

name='' path='' task='' popup=yes window=''
while [ $# -gt 0 ]; do
  case "$1" in
  --no-popup) popup=no ;;
  --window) window="${2:-}"; shift ;;
  *)
    if [ -z "$name" ]; then name="$1"
    elif [ -z "$path" ]; then path="$1"
    elif [ -z "$task" ]; then task="$1"
    fi
    ;;
  esac
  shift
done
path="${path:-$PWD}"

valid_agent_name "$name" || die "invalid agent name '${name:-<empty>}'"
repo_root="$(git -C "$path" rev-parse --show-toplevel 2>/dev/null)" ||
  die "$path is not inside a git repo"
repo="$(basename "$repo_root" | tr -cd 'A-Za-z0-9._-')"

prefix="$(get_tmux_option @claude_session_prefix 'claude-')"
session="${prefix}${repo}-${name}"
tm has-session -t "=$session" 2>/dev/null &&
  die "agent '$name' already running for $repo ($session)"

wt_base="$(expand_tilde "$(get_tmux_option @claude_worktree_dir "$HOME/.claude-worktrees")")"
wt_dir="$wt_base/${repo}-$(session_hash "$repo_root")/$name"

if [ ! -d "$wt_dir" ]; then
  mkdir -p "$(dirname "$wt_dir")"
  if git -C "$repo_root" show-ref --verify --quiet "refs/heads/$name"; then
    err="$(git -C "$repo_root" worktree add "$wt_dir" "$name" 2>&1)" || die "$err"
    [ -n "${TMUX:-}" ] && tm display-message "reusing existing branch '$name'"
  else
    err="$(git -C "$repo_root" worktree add -b "$name" "$wt_dir" 2>&1)" || die "$err"
  fi
  [ -f "$wt_dir/.gitmodules" ] &&
    git -C "$wt_dir" submodule update --init --recursive >/dev/null 2>&1
fi

cmd="$(get_tmux_option @claude_command 'claude')"
args="$(get_tmux_option @claude_args '')"
[ -n "$args" ] && cmd="$cmd $args"

tm new-session -d -s "$session" -c "$wt_dir" "$cmd" || die "new-session failed"
tm set-option -t "$session" @claude_worktree "$wt_dir"
[ -n "$task" ] && tm set-option -t "$session" @claude_task "$task"
[ -n "$window" ] && tm set-option -t "$session" @claude_origin "$window"
tm select-pane -t "$session:" -T "$name" 2>/dev/null

if [ "$popup" = yes ]; then
  w="$(get_tmux_option @claude_popup_width '90%')"
  h="$(get_tmux_option @claude_popup_height '90%')"
  tm display-popup -w "$w" -h "$h" -E "tmux attach-session -t $session"
fi
```

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/spawn_test.sh`
Expected: `PASS`

- [ ] **Step 5: Lint and commit**

```bash
bash -n scripts/spawn.sh && shellcheck scripts/spawn.sh tests/spawn_test.sh
git add scripts/spawn.sh tests/spawn_test.sh
git commit -m "feat: spawn named agents into per-repo git worktrees"
```

---

### Task 3: spawn-prompt.sh popup + key binding + options

**Files:**
- Create: `scripts/spawn-prompt.sh`
- Modify: `claude_session_manager.tmux`

**Interfaces:**
- Consumes: `spawn.sh <name> [dir] [task] --window <id>` (Task 2).
- Produces: `prefix + Y` (option `@claude_spawn_key`, default `Y`) opens a small popup that reads name + optional task with `read -r` and execs spawn. No test file — interactive; verified by the manual smoke in Task 11. Keep it dumb: all logic stays in spawn.sh.

- [ ] **Step 1: Implement scripts/spawn-prompt.sh**

```bash
#!/usr/bin/env bash
# Collect agent name + optional task inside a popup, then spawn.
#   spawn-prompt.sh <dir> [origin-window-id]
# read -r keeps the input pure data — tmux command-prompt substitution would
# re-parse quotes/;/$() through the shell before validation could run.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

path="${1:-$PWD}"
window="${2:-}"

printf 'agent name: '
IFS= read -r name
[ -z "$name" ] && exit 0
printf 'task (optional): '
IFS= read -r task

if ! "$DIR/spawn.sh" "$name" "$path" "$task" --window "$window"; then
  printf 'press enter to close '
  IFS= read -r _
fi
```

- [ ] **Step 2: Add the binding to claude_session_manager.tmux**

After the `list_key` binding block, append:

```bash
spawn_key="$(get_tmux_option @claude_spawn_key 'Y')"

# Spawn a named agent in its own git worktree for the current pane's repo.
# The popup collects the name with read -r; see spawn-prompt.sh.
tmux bind-key "$spawn_key" \
  display-popup -w 60% -h 25% \
  -E "$CURRENT_DIR/scripts/spawn-prompt.sh '#{q:pane_current_path}' '#{q:window_id}'"
```

- [ ] **Step 3: Lint, reload, manual check**

```bash
bash -n scripts/spawn-prompt.sh claude_session_manager.tmux
shellcheck scripts/spawn-prompt.sh claude_session_manager.tmux
tmux source-file ~/.tmux.conf && ./claude_session_manager.tmux
```

Press `prefix + Y` in a repo pane: popup asks name, spawns, agent popup opens.
Expected: session `claude-<repo>-<name>` exists (`tmux ls`).

- [ ] **Step 4: Commit**

```bash
git add scripts/spawn-prompt.sh claude_session_manager.tmux
git commit -m "feat: prefix+Y spawn popup with name and task prompt"
```

---

### Task 4: agent.sh — target resolution, send, read

**Files:**
- Create: `scripts/agent.sh`
- Create: `tests/agent_test.sh`

**Interfaces:**
- Consumes: `get_tmux_option` (helpers.sh); sessions created like Task 2's.
- Produces:
  - `agent.sh send <target> [--no-enter] [--json] <text...>`
  - `agent.sh read <target> [--lines N] [--source visible|recent] [--json]`
  - Internal: `resolve_sessions <target>` (bare name → unique `claude-*-<name>`; full session; pane id `%N`; groups come in Task 8), `pane_of <session>`, `die`, `tm`/`tmux` shim identical to spawn.sh.
  - `--json` emits `{"ok":true,"targets":[...]}` for send, `{"ok":true,"lines":"..."}` for read (jq -Rs).

- [ ] **Step 1: Write the failing test**

```bash
# tests/agent_test.sh
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

# unknown target
assert_fail agent read nosuchagent

# --json shapes
agent send docs --json 'true' | jq -e '.ok == true and (.targets | length) == 1' >/dev/null || _fail send-json
agent read claude-alpha-docs --json | jq -e '.ok == true and (.lines | type) == "string"' >/dev/null || _fail read-json

t_teardown
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/agent_test.sh`
Expected: FAIL — `agent.sh` does not exist.

- [ ] **Step 3: Implement scripts/agent.sh**

```bash
#!/usr/bin/env bash
# Drive named Claude agents from outside their sessions.
#   agent.sh send <target> [--no-enter] [--json] <text...>
#   agent.sh read <target> [--lines N] [--source visible|recent] [--json]
# Targets: bare name (api -> unique claude-*-api), full session name, or
# pane id (%3). Pane resolution is pure tmux — `claude agents --json` is
# stale for seconds after a spawn, and spawn-then-send must work.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

tm() {
  if [ -n "${TMUX_SOCKET_OVERRIDE:-}" ]; then
    command tmux -L "$TMUX_SOCKET_OVERRIDE" "$@"
  else
    command tmux "$@"
  fi
}
tmux() { tm "$@"; }

die() { echo "claude-agent: $*" >&2; exit 1; }

prefix="$(get_tmux_option @claude_session_prefix 'claude-')"

# resolve_sessions <target> — echo one session name per line, or die.
resolve_sessions() {
  local t="$1" matches
  case "$t" in
  %*)
    tm display-message -p -t "$t" '#{session_name}' 2>/dev/null || die "no pane $t"
    ;;
  "$prefix"*)
    tm has-session -t "=$t" 2>/dev/null || die "no session $t"
    printf '%s\n' "$t"
    ;;
  *)
    matches="$(tm list-sessions -F '#{session_name}' 2>/dev/null |
      grep -E "^${prefix}.+-${t}$")"
    [ -z "$matches" ] && die "no agent named '$t'"
    [ "$(printf '%s\n' "$matches" | wc -l)" -gt 1 ] &&
      die "ambiguous name '$t': $(printf '%s ' $matches)"
    printf '%s\n' "$matches"
    ;;
  esac
}

pane_of() { tm list-panes -t "=$1" -F '#{pane_id}' | head -1; }

cmd="${1:-}"; shift 2>/dev/null || die 'usage: agent.sh <send|read> <target> ...'
target="${1:-}"; shift 2>/dev/null || die 'missing target'

case "$cmd" in
send)
  enter=yes json=no text=''
  while [ $# -gt 0 ]; do
    case "$1" in
    --no-enter) enter=no ;;
    --json) json=yes ;;
    *) text="${text:+$text }$1" ;;
    esac
    shift
  done
  [ -z "$text" ] && die 'nothing to send'
  sent=''
  while IFS= read -r s; do
    pane="$(pane_of "$s")"
    tm send-keys -t "$pane" -l -- "$text"
    [ "$enter" = yes ] && tm send-keys -t "$pane" Enter
    sent="${sent:+$sent }$s"
  done <<EOF
$(resolve_sessions "$target")
EOF
  if [ "$json" = yes ]; then
    printf '%s\n' "$sent" | tr ' ' '\n' | jq -R . | jq -cs '{ok: true, targets: .}'
  else
    echo "sent to: $sent"
  fi
  ;;
read)
  lines='' source=visible json=no
  while [ $# -gt 0 ]; do
    case "$1" in
    --lines) lines="${2:-}"; shift ;;
    --source) source="${2:-visible}"; shift ;;
    --json) json=yes ;;
    esac
    shift
  done
  s="$(resolve_sessions "$target" | head -1)"
  pane="$(pane_of "$s")"
  cap=(tm capture-pane -p -t "$pane")
  [ "$source" = recent ] && cap+=(-S "-${lines:-1000}")
  out="$("${cap[@]}")"
  [ -n "$lines" ] && out="$(printf '%s\n' "$out" | tail -n "$lines")"
  if [ "$json" = yes ]; then
    printf '%s' "$out" | jq -Rs '{ok: true, lines: .}'
  else
    printf '%s\n' "$out"
  fi
  ;;
*)
  die "unknown subcommand '$cmd'"
  ;;
esac
```

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/agent_test.sh`
Expected: `PASS`

- [ ] **Step 5: Lint and commit**

```bash
bash -n scripts/agent.sh && shellcheck scripts/agent.sh tests/agent_test.sh
git add scripts/agent.sh tests/agent_test.sh
git commit -m "feat: agent CLI with send and read over tmux panes"
```

---

### Task 5: signal + wait --signal / --match

**Files:**
- Modify: `scripts/agent.sh`
- Create: `tests/wait_test.sh`
- Modify: `docs/superpowers/specs/2026-07-24-herdr-style-agents-design.md` (signals location note)

**Interfaces:**
- Consumes: `resolve_sessions`, `pane_of`, `tm` from Task 4; `@claude_worktree` option from Task 2.
- Produces:
  - `agent.sh signal <target> <done|blocked> [--body <text>] [--json]` — appends `<epoch>\t<type>\t<body>` to the sidecar `"$(dirname "$wt")/.$(basename "$wt").signals"`.
  - `agent.sh wait <target> --signal <done|blocked> [--timeout N] [--json]`
  - `agent.sh wait <target> --match <text> [--regex] [--timeout N] [--json]`
  - Internal: `signals_file <session>` (echoes path or fails if no `@claude_worktree`), `wait` exit 0 on hit / 1 on timeout; `--json` emits `{"ok":true,"matched":"<type-or-text>","body":"..."}` or `{"ok":false,"timeout":true}`.

- [ ] **Step 1: Write the failing test**

```bash
# tests/wait_test.sh
#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
t_setup

agent() { TMUX_SOCKET_OVERRIDE="$TMUX_SOCK" bash "$SCRIPTS/agent.sh" "$@"; }

wt="$T_TMP/base/repo-xxxxxxxx/worker"
mkdir -p "$wt"
$TMUX_CMD new-session -d -s claude-repo-worker -c "$wt" 'bash --norc'
$TMUX_CMD set-option -t claude-repo-worker @claude_worktree "$wt"
sigfile="$T_TMP/base/repo-xxxxxxxx/.worker.signals"

# signal writes the sidecar file (outside the worktree — keeps it clean)
assert_ok agent signal worker done --body 'all tests green'
assert_ok test -f "$sigfile"
assert_eq "$(cut -f2 "$sigfile")" done sig-type
assert_ok test ! -e "$wt/.claude-signals"

# wait --signal returns immediately when the signal already exists
assert_ok agent wait worker --signal done --timeout 3
# and times out (exit 1) for a type never sent
assert_fail agent wait worker --signal blocked --timeout 2

# wait --signal unblocks when the signal arrives mid-wait
rm "$sigfile"
( sleep 2; printf '%s\tdone\tlate\n' "$(date +%s)" >> "$sigfile" ) &
assert_ok agent wait worker --signal done --timeout 10

# wait --match on pane output
assert_ok agent send worker 'echo MAGIC-TOKEN-42'
assert_ok agent wait worker --match 'MAGIC-TOKEN-42' --timeout 10
assert_fail agent wait worker --match 'NEVER-PRINTED' --timeout 2
assert_ok agent send worker 'echo ABC-123'
assert_ok agent wait worker --match 'ABC-[0-9]+' --regex --timeout 10

# json shape on timeout
agent wait worker --signal blocked --timeout 1 --json |
  jq -e '.ok == false and .timeout == true' >/dev/null || _fail wait-json

t_teardown
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/wait_test.sh`
Expected: FAIL — unknown subcommands.

- [ ] **Step 3: Implement in agent.sh**

Add before the final `case`:

```bash
# signals_file <session> — sidecar path next to the worktree. Inside the
# worktree it would read as untracked -> dirty -> kill would never clean.
signals_file() {
  local wt
  wt="$(tm show-option -t "$1" -qv @claude_worktree)"
  [ -z "$wt" ] && die "$1 has no worktree (not a spawned agent)"
  printf '%s/.%s.signals' "$(dirname "$wt")" "$(basename "$wt")"
}
```

Add the two subcommands to the `case`:

```bash
signal)
  type='' body='' json=no
  while [ $# -gt 0 ]; do
    case "$1" in
    --body) body="${2:-}"; shift ;;
    --json) json=yes ;;
    done | blocked) type="$1" ;;
    esac
    shift
  done
  [ -z "$type" ] && die 'signal type must be done or blocked'
  s="$(resolve_sessions "$target" | head -1)"
  f="$(signals_file "$s")"
  printf '%s\t%s\t%s\n' "$(date +%s)" "$type" "$body" >>"$f"
  [ "$json" = yes ] && printf '{"ok":true,"signaled":"%s"}\n' "$type" || echo "signaled $type"
  ;;
wait)
  mode='' want='' timeout=300 use_regex=no json=no
  while [ $# -gt 0 ]; do
    case "$1" in
    --signal) mode=signal; want="${2:-}"; shift ;;
    --match) mode=match; want="${2:-}"; shift ;;
    --status) mode=status; want="${2:-}"; shift ;;
    --regex) use_regex=yes ;;
    --timeout) timeout="${2:-300}"; shift ;;
    --json) json=yes ;;
    esac
    shift
  done
  [ -z "$mode" ] && die 'wait needs --signal, --match, or --status'
  s="$(resolve_sessions "$target" | head -1)"
  deadline=$((SECONDS + timeout))
  while [ "$SECONDS" -lt "$deadline" ]; do
    case "$mode" in
    signal)
      f="$(signals_file "$s")"
      if [ -f "$f" ] && line="$(awk -F'\t' -v t="$want" '$2 == t { print; exit }' "$f")" && [ -n "$line" ]; then
        body="$(printf '%s' "$line" | cut -f3-)"
        [ "$json" = yes ] &&
          printf '%s' "$body" | jq -Rs --arg m "$want" '{ok: true, matched: $m, body: .}' ||
          echo "$want: $body"
        exit 0
      fi
      ;;
    match)
      out="$(tm capture-pane -p -t "$(pane_of "$s")")"
      if [ "$use_regex" = yes ]; then hit() { printf '%s' "$out" | grep -qE -- "$want"; }
      else hit() { printf '%s' "$out" | grep -qF -- "$want"; }; fi
      if hit; then
        [ "$json" = yes ] && printf '{"ok":true,"matched":%s}\n' "$(printf '%s' "$want" | jq -Rs .)" || echo "matched"
        exit 0
      fi
      ;;
    status)
      st="$(status_of "$s")"   # Task 6
      if [ "$st" = "$want" ]; then
        [ "$json" = yes ] && printf '{"ok":true,"matched":"%s"}\n' "$want" || echo "$want"
        exit 0
      fi
      ;;
    esac
    sleep 1
  done
  [ "$json" = yes ] && echo '{"ok":false,"timeout":true}' || echo 'timeout' >&2
  exit 1
  ;;
```

(`status_of` arrives in Task 6; until then `--status` dies with "status_of: command not found", which no test exercises yet.)

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/wait_test.sh` and re-run `bash tests/agent_test.sh`
Expected: both `PASS`

- [ ] **Step 5: Update spec, lint, commit**

In the spec, replace the sentence about `.claude-signals` inside the worktree
with the sidecar location (`<wt_parent>/.<name>.signals`) and the rationale
(untracked file would block clean removal).

```bash
bash -n scripts/agent.sh && shellcheck scripts/agent.sh tests/wait_test.sh
git add scripts/agent.sh tests/wait_test.sh docs/superpowers/specs/
git commit -m "feat: done/blocked signal contract and blocking waits"
```

---

### Task 6: wait --status via claude agents --json

**Files:**
- Modify: `scripts/agent.sh`
- Create: `tests/status_test.sh`
- Create: `tests/fixtures/claude` (mock)

**Interfaces:**
- Consumes: `pane_of`, wait loop from Task 5.
- Produces: `status_of <session>` — echoes `waiting|idle|busy` or nothing. Joins the session pane's tty against `claude agents --json` pids (same identity rule as `agents.sh`). The `claude` binary is found via `$PATH`, so tests prepend a mock.

- [ ] **Step 1: Write the mock and failing test**

```bash
# tests/fixtures/claude
#!/usr/bin/env bash
# Mock `claude agents --json`: emits one interactive agent whose pid/status
# come from env (CLAUDE_MOCK_PID / CLAUDE_MOCK_STATUS).
[ "$1 $2" = 'agents --json' ] || exit 1
printf '[{"kind":"interactive","pid":%s,"status":"%s","sessionId":"mock","cwd":"/tmp"}]\n' \
  "${CLAUDE_MOCK_PID:-0}" "${CLAUDE_MOCK_STATUS:-idle}"
```

```bash
# tests/status_test.sh
#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
t_setup
chmod +x "$TESTDIR/fixtures/claude"
export PATH="$TESTDIR/fixtures:$PATH"

agent() { TMUX_SOCKET_OVERRIDE="$TMUX_SOCK" bash "$SCRIPTS/agent.sh" "$@"; }

$TMUX_CMD new-session -d -s claude-repo-w -c "$T_TMP" 'bash --norc'
$TMUX_CMD set-option -t claude-repo-w @claude_worktree "$T_TMP"
sleep 1
# the pane's shell pid is what the mock reports as the agent pid
pid="$($TMUX_CMD list-panes -t claude-repo-w -F '#{pane_pid}')"
export CLAUDE_MOCK_PID="$pid"

export CLAUDE_MOCK_STATUS=idle
assert_ok agent wait w --status idle --timeout 5
export CLAUDE_MOCK_STATUS=busy
assert_fail agent wait w --status idle --timeout 2
assert_ok agent wait w --status busy --timeout 5

t_teardown
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/status_test.sh`
Expected: FAIL — `status_of` not defined.

- [ ] **Step 3: Implement status_of in agent.sh** (next to `signals_file`)

```bash
# status_of <session> — waiting|idle|busy from `claude agents --json`,
# joined by tty: the pane's tty must equal the agent pid's tty (agents.sh
# uses the same identity rule). Empty when the supervisor doesn't know the
# agent (yet) — callers treat that as "keep waiting".
status_of() {
  local tty pid st
  tty="$(tm display-message -p -t "$(pane_of "$1")" '#{pane_tty}')"
  tty="${tty#/dev/}"
  while IFS=$'\t' read -r pid st; do
    [ "$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')" = "$tty" ] &&
      { printf '%s' "$st"; return 0; }
  done <<EOF
$(claude agents --json 2>/dev/null |
  jq -r '.[] | select(.kind == "interactive") | [.pid, .status] | @tsv' 2>/dev/null)
EOF
  return 0
}
```

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/status_test.sh` and `bash tests/wait_test.sh`
Expected: both `PASS`

- [ ] **Step 5: Lint and commit**

```bash
bash -n scripts/agent.sh && shellcheck scripts/agent.sh tests/status_test.sh tests/fixtures/claude
git add scripts/agent.sh tests/status_test.sh tests/fixtures/claude
git commit -m "feat: wait --status joins claude agents json by pane tty"
```

---

### Task 7: kill with worktree cleanup

**Files:**
- Modify: `scripts/agent.sh`
- Create: `tests/kill_test.sh`

**Interfaces:**
- Consumes: `resolve_sessions`, `pane_of`, `signals_file`, `tm`.
- Produces: `agent.sh kill <target> [--json]` — kills the pane process (TERM, poll `kill -0` up to 10s, then KILL), then: clean worktree → `git worktree remove` + delete sidecar signals + kill session; dirty → keep worktree, kill session. Message always names what was removed/preserved. `--json`: `{"ok":true,"worktree":"removed"|"preserved"|"none","path":"..."}`.

- [ ] **Step 1: Write the failing test**

```bash
# tests/kill_test.sh
#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
t_setup

agent() { TMUX_SOCKET_OVERRIDE="$TMUX_SOCK" bash "$SCRIPTS/agent.sh" "$@"; }

repo="$(t_repo alpha)"
mk_agent() { # <name> — real worktree + session running sleep
  local wt="$T_TMP/wtbase/alpha-h/$1"
  mkdir -p "$T_TMP/wtbase/alpha-h"
  git -C "$repo" worktree add -q -b "$1" "$wt"
  $TMUX_CMD new-session -d -s "claude-alpha-$1" -c "$wt" 'sleep 300'
  $TMUX_CMD set-option -t "claude-alpha-$1" @claude_worktree "$wt"
}

# clean kill: worktree gone, branch survives, session gone
mk_agent clean1
assert_ok agent kill clean1
assert_ok test ! -d "$T_TMP/wtbase/alpha-h/clean1"
assert_ok git -C "$repo" show-ref --verify --quiet refs/heads/clean1
assert_fail $TMUX_CMD has-session -t '=claude-alpha-clean1'

# dirty kill: worktree preserved, session gone
mk_agent dirty1
echo change > "$T_TMP/wtbase/alpha-h/dirty1/f.txt"
out="$(agent kill dirty1 --json)"
printf '%s' "$out" | jq -e '.worktree == "preserved"' >/dev/null || _fail dirty-json
assert_ok test -d "$T_TMP/wtbase/alpha-h/dirty1"
assert_fail $TMUX_CMD has-session -t '=claude-alpha-dirty1'

# sidecar signals removed with a clean worktree
mk_agent sig1
agent signal sig1 done --body x >/dev/null
assert_ok test -f "$T_TMP/wtbase/alpha-h/.sig1.signals"
assert_ok agent kill sig1
assert_ok test ! -e "$T_TMP/wtbase/alpha-h/.sig1.signals"

t_teardown
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/kill_test.sh`
Expected: FAIL — unknown subcommand kill.

- [ ] **Step 3: Implement kill in agent.sh**

```bash
kill)
  json=no
  [ "${1:-}" = --json ] && json=yes
  s="$(resolve_sessions "$target" | head -1)"
  pane="$(pane_of "$s")"
  pid="$(tm display-message -p -t "$pane" '#{pane_pid}')"

  # TERM, then wait for real death before touching the worktree — a dying
  # Claude can still flush writes that would corrupt the clean-check.
  command kill -- "$pid" 2>/dev/null
  for _ in $(seq 1 100); do
    command kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  command kill -0 "$pid" 2>/dev/null && command kill -9 -- "$pid" 2>/dev/null

  wt="$(tm show-option -t "$s" -qv @claude_worktree)"
  state=none
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    if [ -z "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
      main="$(dirname "$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)")"
      git -C "$main" worktree remove -- "$wt" 2>/dev/null && state=removed || state=preserved
      rm -f "$(dirname "$wt")/.$(basename "$wt").signals"
    else
      state=preserved
    fi
  fi
  tm kill-session -t "=$s" 2>/dev/null

  msg="killed $s — worktree $state${wt:+: $wt}"
  [ -n "${TMUX:-}" ] && tm display-message "$msg"
  if [ "$json" = yes ]; then
    jq -cn --arg st "$state" --arg p "${wt:-}" '{ok: true, worktree: $st, path: $p}'
  else
    echo "$msg"
  fi
  ;;
```

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/kill_test.sh` and the full suite `for t in tests/*_test.sh; do bash "$t" || exit 1; done`
Expected: all `PASS`

- [ ] **Step 5: Lint and commit**

```bash
bash -n scripts/agent.sh && shellcheck scripts/agent.sh tests/kill_test.sh
git add scripts/agent.sh tests/kill_test.sh
git commit -m "feat: kill waits for process death then auto-cleans worktree"
```

---

### Task 8: group targets @all @idle @waiting @busy

**Files:**
- Modify: `scripts/agent.sh` (`resolve_sessions`)
- Create: `tests/group_test.sh`

**Interfaces:**
- Consumes: `status_of` (Task 6), mock `claude` fixture.
- Produces: `resolve_sessions` also accepts `@all` (every `claude-*` session that has `@claude_worktree`) and `@idle`/`@waiting`/`@busy` (those filtered by `status_of`). `send` already loops over all resolved sessions; `read`/`wait`/`kill`/`signal` keep using the first and die on group targets (`die "group target not supported for $cmd"`).

- [ ] **Step 1: Write the failing test**

```bash
# tests/group_test.sh
#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
t_setup
chmod +x "$TESTDIR/fixtures/claude"
export PATH="$TESTDIR/fixtures:$PATH"

agent() { TMUX_SOCKET_OVERRIDE="$TMUX_SOCK" bash "$SCRIPTS/agent.sh" "$@"; }

for n in a b; do
  $TMUX_CMD new-session -d -s "claude-r-$n" -c "$T_TMP" 'bash --norc'
  $TMUX_CMD set-option -t "claude-r-$n" @claude_worktree "$T_TMP"
done
$TMUX_CMD new-session -d -s claude-deadbeef -c "$T_TMP" 'bash --norc'  # hash session: no worktree option
sleep 1

# @all hits both agents, skips the hash session
out="$(agent send @all --json 'echo hi')"
printf '%s' "$out" | jq -e '.targets | length == 2' >/dev/null || _fail all-count

# @idle: mock reports pane pid of agent a only
export CLAUDE_MOCK_PID="$($TMUX_CMD list-panes -t claude-r-a -F '#{pane_pid}')"
export CLAUDE_MOCK_STATUS=idle
out="$(agent send @idle --json 'echo idle-only')"
printf '%s' "$out" | jq -e '.targets == ["claude-r-a"]' >/dev/null || _fail idle-filter

# groups rejected where they make no sense
assert_fail agent kill @all
assert_fail agent read @idle

t_teardown
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/group_test.sh`
Expected: FAIL — `@all` resolves to nothing / no error handling.

- [ ] **Step 3: Implement**

In `resolve_sessions`, add before the `%*)` case:

```bash
  @all | @idle | @waiting | @busy)
    local want="${t#@}" s2
    while IFS= read -r s2; do
      [ -z "$(tm show-option -t "$s2" -qv @claude_worktree)" ] && continue
      if [ "$want" = all ] || [ "$(status_of "$s2")" = "$want" ]; then
        printf '%s\n' "$s2"
      fi
    done <<EOF2
$(tm list-sessions -F '#{session_name}' 2>/dev/null | grep "^$prefix")
EOF2
    ;;
```

At the top of the `read`, `wait`, `signal`, and `kill` subcommand blocks:

```bash
  case "$target" in @*) die "group target not supported for $cmd" ;; esac
```

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/group_test.sh` and the full suite.
Expected: all `PASS`

- [ ] **Step 5: Lint and commit**

```bash
bash -n scripts/agent.sh && shellcheck scripts/agent.sh tests/group_test.sh
git add scripts/agent.sh tests/group_test.sh
git commit -m "feat: group send targets @all/@idle/@waiting/@busy"
```

---

### Task 9: dashboard columns — branch, dirty marker, task

**Files:**
- Modify: `scripts/agents.sh`
- Modify: `scripts/picker.sh` (`--with-nth` only)

**Interfaces:**
- Consumes: row format from `agents.sh` (`rank\tpane\tpid\tkind\ticon\tage\tloc\tpath`).
- Produces: rows gain two display columns: `branch` (with `*` when dirty, `-` when not a repo) and `task` (from the session's `@claude_task`, `-` when unset). New row: `rank\tpane\tpid\tkind\ticon\tage\tloc\tpath\tbranch\ttask`. `picker.sh` shows `--with-nth=5..`.

- [ ] **Step 1: Modify agents.sh**

The awk pipeline currently ends at the `sort`. Change awk's `printf` to also
emit the raw cwd as a trailing hidden field:

```awk
    printf "%s\t%s\t%s\t%s\t%s\t%5s\t%s\t%s\t%s\n",
      rank, pane[tty], $2, kind, icon, age, loc[tty], path, $5
```

Then append a post-processing loop after the existing `sort` (pipe into it):

```bash
' | sort -t$'\t' -k1,1n -k6,6n | while IFS=$'\t' read -r rank pane pid kind icon age loc path cwd; do
  branch="$(git -C "$cwd" branch --show-current 2>/dev/null)"
  if [ -n "$branch" ]; then
    [ -n "$(git -C "$cwd" status --porcelain --untracked-files=no 2>/dev/null | head -1)" ] &&
      branch="$branch*"
  else
    branch='-'
  fi
  sess="$(tmux display-message -p -t "$pane" '#{session_name}' 2>/dev/null)"
  task="$(tmux show-option -t "$sess" -qv @claude_task 2>/dev/null)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$rank" "$pane" "$pid" "$kind" "$icon" "$age" "$loc" "$path" "$branch" "${task:--}"
done
```

(The sort comment about `-k6,6n` stays where it is, above this pipeline.)

- [ ] **Step 2: Update picker.sh display slice**

Change `--with-nth=5,6,7,8` to `--with-nth=5..`.

- [ ] **Step 3: Verify by hand**

```bash
bash -n scripts/agents.sh scripts/picker.sh
shellcheck scripts/agents.sh scripts/picker.sh
./scripts/agents.sh   # with at least one Claude running in tmux
```

Expected: each row ends with a branch (or `-`) and a task (or `-`); a dirty
worktree shows `branch*`. Open `prefix + u`: columns render, jump still works.

- [ ] **Step 4: Commit**

```bash
git add scripts/agents.sh scripts/picker.sh
git commit -m "feat: branch, dirty marker, and task columns in picker rows"
```

---

### Task 10: picker bindings — ctrl-n spawn, ctrl-s send, ctrl-x via agent.sh

**Files:**
- Modify: `scripts/picker.sh`

**Interfaces:**
- Consumes: `spawn-prompt.sh` (Task 3), `agent.sh send`/`kill` (Tasks 4/7), `@claude_parent` option.
- Produces: inside the picker — `ctrl-n` replaces fzf with the spawn prompt in the same popup (spawning `--no-popup`; user reopens the picker to jump); `ctrl-s` prompts for text and sends to the highlighted agent; `ctrl-x` now routes through `agent.sh kill` so worktrees get cleaned.

- [ ] **Step 1: Modify picker.sh**

Replace the fzf invocation block with:

```bash
# ctrl-x routes through agent.sh kill (worktree cleanup) with the pane id;
# ctrl-s prompts on the picker's own tty and sends without attaching;
# ctrl-n swaps this popup's process for the spawn prompt (spawn uses
# --no-popup — opening a nested popup from inside one hangs; see list.sh).
spawn_dir="$(tmux display-message -p -t "${CLAUDE_PARENT_PANE:-}" '#{pane_current_path}' 2>/dev/null || pwd)"
sel=$("$DIR/agents.sh" | fzf --ansi --delimiter='\t' --with-nth=5.. \
  --reverse --cycle \
  --header='Claude agents · enter: jump · ctrl-n: new · ctrl-s: send · ctrl-x: kill' \
  --preview='tmux capture-pane -ept {2}' --preview-window='up,70%,follow' \
  --bind="ctrl-x:execute-silent($DIR/agent.sh kill {2} || kill {3})+reload(sleep 0.3; $self --list)" \
  --bind="ctrl-s:execute(printf 'send> '; IFS= read -r p; [ -n \"\$p\" ] && $DIR/agent.sh send {2} \"\$p\")+reload(sleep 0.3; $self --list)" \
  --bind="ctrl-n:become($DIR/spawn-prompt.sh $(printf '%q' "$spawn_dir") --no-popup)" \
  ${extra_opts[@]+"${extra_opts[@]}"})
```

And in `spawn-prompt.sh`, accept the pass-through flag (append to its arg
handling): when `$2` is `--no-popup`, call spawn with `--no-popup` and no
`--window`:

```bash
path="${1:-$PWD}"
window="${2:-}"
extra=()
if [ "$window" = --no-popup ]; then
  window=''
  extra=(--no-popup)
fi
```

and the spawn call becomes:

```bash
if ! "$DIR/spawn.sh" "$name" "$path" "$task" ${window:+--window "$window"} ${extra[0]:+"${extra[@]}"}; then
```

- [ ] **Step 2: Verify by hand**

```bash
bash -n scripts/picker.sh scripts/spawn-prompt.sh
shellcheck scripts/picker.sh scripts/spawn-prompt.sh
```

Open `prefix + u` with an agent running: `ctrl-s` sends text that appears in
the agent pane; `ctrl-n` shows the name prompt and spawns (session appears in
`tmux ls`); `ctrl-x` on a spawned clean agent removes its worktree.

- [ ] **Step 3: Commit**

```bash
git add scripts/picker.sh scripts/spawn-prompt.sh
git commit -m "feat: picker bindings for spawn, send, and cleanup kill"
```

---

### Task 11: orchestration doc + README + full verification

**Files:**
- Create: `docs/orchestration.md`
- Modify: `README.md` (new features section)

**Interfaces:**
- Consumes: everything above.
- Produces: user-facing docs; final adversarial smoke pass.

- [ ] **Step 1: Write docs/orchestration.md**

```markdown
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
```

- [ ] **Step 2: Add a README section**

Under the existing feature docs, add a "Named agents & worktrees" section
listing: `prefix + Y` spawn, `@claude_worktree_dir` / `@claude_spawn_key`
options, the `agent.sh` subcommands one line each, picker bindings, and a
link to `docs/orchestration.md`. Follow the README's existing table style.

- [ ] **Step 3: Full test suite + lint sweep**

```bash
for t in tests/*_test.sh; do echo "== $t"; bash "$t" || exit 1; done
shellcheck scripts/*.sh claude_session_manager.tmux
```

Expected: every suite `PASS`, shellcheck clean (SC1091 info ok).

- [ ] **Step 4: Adversarial smoke (manual, real tmux)**

- Spawn with name `x'; run-shell 'touch /tmp/pwned` → rejected, `/tmp/pwned` absent.
- Spawn `api` from two different repos → two sessions; third spawn `api` in repo 1 → rejected.
- Spawn then immediately `agent.sh send` (within 1s) → text arrives.
- Spawn in `~/.dotfiles` → `tools/lazygit` populated in the worktree.
- `agent.sh kill` on dirty agent → worktree preserved, message shows path.
- Re-spawn a killed name → "reusing existing branch" message.
- `prefix + u` → `ctrl-n` spawn → reopen picker → new agent listed with task.

- [ ] **Step 5: Commit and push**

```bash
git add docs/orchestration.md README.md
git commit -m "docs: orchestration guide and README for named agents"
git push origin main
```

---

## Deferred (phase 2, by design)

Passive notifications (`pulse.sh` on `status-interval`, done/request sounds,
unfocused-only) — spec §5. Not in this plan; the state-file format is already
reserved by the spec.
