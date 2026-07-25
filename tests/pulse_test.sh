#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
t_setup
chmod +x "$TESTDIR/fixtures/claude"

# Fake afplay ahead of the real one on PATH: the log is the only evidence a
# sound fired, since pulse.sh is silent on stdout by design.
mkdir -p "$T_TMP/bin"
export AFPLAY_LOG="$T_TMP/afplay.log"
cat >"$T_TMP/bin/afplay" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"$AFPLAY_LOG"
EOF
chmod +x "$T_TMP/bin/afplay"
export PATH="$T_TMP/bin:$TESTDIR/fixtures:$PATH"

export CLAUDE_CONFIG_DIR="$T_TMP/claude-config"
mkdir -p "$CLAUDE_CONFIG_DIR/sounds"
: >"$CLAUDE_CONFIG_DIR/sounds/terminado.mp3"
: >"$CLAUDE_CONFIG_DIR/sounds/esperando.mp3"
export CLAUDE_PULSE_STATE="$T_TMP/pulse.state"

pulse() { TMUX_SOCKET_OVERRIDE="$TMUX_SOCK" bash "$SCRIPTS/pulse.sh" "$@"; }
# afplay is backgrounded; give it the same beat the rest of the suite uses.
poll() { pulse; sleep 1; }
sounds() { cat "$AFPLAY_LOG" 2>/dev/null; }
reset_sounds() { : >"$AFPLAY_LOG"; }

$TMUX_CMD new-session -d -s claude-repo-api -c "$T_TMP" 'bash --norc'
$TMUX_CMD set-option -t claude-repo-api @claude_agent_name api
sleep 1
# the pane's shell pid is what the mock reports as the agent pid
pid="$($TMUX_CMD list-panes -t claude-repo-api -F '#{pane_pid}')"
export CLAUDE_MOCK_PID="$pid"

# install is idempotent — tpm reloads and every client-attached run it again
pulse install
pulse install
assert_eq "$($TMUX_CMD show-option -gqv status-right | awk '{ print gsub(/pulse\.sh/, "") }')" \
  1 'install appended the poll exactly once'
# Undo it: the moment a client attaches below, tmux would start running the
# installed pulse.sh for real — with no socket override, i.e. against the
# developer's own tmux server and sounds.
$TMUX_CMD set-option -g status-right ''
# display-message defaults to 750ms; hold it long enough to capture.
$TMUX_CMD set-option -g display-time 5000

# first sighting has no previous status: nothing to announce
export CLAUDE_MOCK_STATUS=busy
poll
assert_eq "$(sounds)" '' 'first sighting is silent'

# busy -> idle: the "done" sound
export CLAUDE_MOCK_STATUS=idle
poll
case "$(sounds)" in *terminado.mp3*) : ;; *) _fail "busy->idle played no done sound: $(sounds)" ;; esac

# idle -> idle: no edge, no sound
reset_sounds
poll
assert_eq "$(sounds)" '' 'unchanged status is silent'

# busy -> waiting: the "request" sound, and only that one
export CLAUDE_MOCK_STATUS=busy
poll
export CLAUDE_MOCK_STATUS=waiting
poll
case "$(sounds)" in
*esperando.mp3*) : ;;
*) _fail "busy->waiting played no request sound: $(sounds)" ;;
esac
case "$(sounds)" in *terminado.mp3*) _fail "busy->waiting played the done sound too" ;; *) : ;; esac

# per-agent mute
reset_sounds
$TMUX_CMD set-option -t claude-repo-api @claude_sound_mute on
export CLAUDE_MOCK_STATUS=busy
poll
export CLAUDE_MOCK_STATUS=idle
poll
assert_eq "$(sounds)" '' 'muted agent is silent'
$TMUX_CMD set-option -t claude-repo-api @claude_sound_mute off

# global mute file (~/.claude/mute), the same switch cmute/cunmute flip
reset_sounds
: >"$CLAUDE_CONFIG_DIR/mute"
export CLAUDE_MOCK_STATUS=busy
poll
export CLAUDE_MOCK_STATUS=idle
poll
assert_eq "$(sounds)" '' 'global mute file is silent'
rm -f "$CLAUDE_CONFIG_DIR/mute"

# a dropped `claude agents --json` must not erase the remembered statuses
export CLAUDE_MOCK_STATUS=busy
poll
mv "$T_TMP/bin/afplay" "$T_TMP/afplay.bin" # keep the fake, hide claude instead
mv "$TESTDIR/fixtures/claude" "$T_TMP/claude.bin"
poll
mv "$T_TMP/claude.bin" "$TESTDIR/fixtures/claude"
mv "$T_TMP/afplay.bin" "$T_TMP/bin/afplay"
reset_sounds
export CLAUDE_MOCK_STATUS=idle
poll
case "$(sounds)" in
*terminado.mp3*) : ;;
*) _fail "a poll with no agent data lost the busy state: $(sounds)" ;;
esac

# Positive control, and the announcement itself. A client attached to another
# session gives display-message somewhere to land while the agent stays
# unfocused; the host pane renders that client's screen, status line included.
$TMUX_CMD new-session -d -s bystander -c "$T_TMP" "env -u TMUX $TMUX_CMD attach -t t-keeper"
sleep 2
reset_sounds
export CLAUDE_MOCK_STATUS=busy
poll
export CLAUDE_MOCK_STATUS=idle
poll
case "$(sounds)" in
*terminado.mp3*) : ;;
*) _fail "unfocused control failed, focus test would prove nothing: $(sounds)" ;;
esac
msg="$($TMUX_CMD capture-pane -p -t bystander | grep 'claude:')"
assert_eq "${msg%% *}" 'claude:' 'transition announced on the attached client'
# names the agent, not the session it happens to live in
case "$msg" in
'claude: api finished'*) : ;;
*) _fail "message should name the agent 'api': $msg" ;;
esac

$TMUX_CMD new-session -d -s attacher -c "$T_TMP" "env -u TMUX $TMUX_CMD attach -t claude-repo-api"
sleep 2
assert_eq "$($TMUX_CMD display-message -p -t claude-repo-api '#{session_attached}')" \
  1 'nested attach produced a client'

reset_sounds
export CLAUDE_MOCK_STATUS=busy
poll
export CLAUDE_MOCK_STATUS=idle
poll
assert_eq "$(sounds)" '' 'focused agent is silent'

t_teardown
