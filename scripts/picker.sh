#!/usr/bin/env bash
# Interactive picker for running Claude agents.
#
#   picker.sh           fzf picker; on enter, jumps to the chosen agent.
#   picker.sh --list    print the rows only (used by fzf's ctrl-x reload).
#
# Rows come from agents.sh, which pairs each running Claude with the tmux pane it
# occupies. Two kinds of row jump differently:
#   dedicated  a Claude in a `claude-*` session this plugin launched — opened as
#              a tab in your own session.
#   split      a worktree agent spawned into a split of a window you already
#              have — focused in place, since it is already where it lives.
#   loose      a Claude running in any other pane — focused in place.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

[ "${1:-}" = '--list' ] && exec "$DIR/agents.sh"

for tool in fzf jq claude; do
  command -v "$tool" >/dev/null 2>&1 || {
    tmux display-message "tmux-claude-session-manager: $tool is required for the picker"
    exit 0
  }
done

self="$DIR/picker.sh"
export FZF_DEFAULT_OPTS=''
export CLAUDE_PICKER="$self"

# Arbitrary user fzf options (e.g. custom --bind or --preview-window)
extra_opts=()
fzf_options="$(get_tmux_option @claude_fzf_options '')"
[ -n "$fzf_options" ] && eval "extra_opts=($fzf_options)"

parent=$(tmux show-options -gqv @claude_parent 2>/dev/null)
spawn_dir="$(tmux display-message -p -t "${parent:-}" '#{pane_current_path}' 2>/dev/null || pwd)"

# ctrl-x routes through agent.sh kill (worktree cleanup) with the pane id;
# ctrl-s prompts on the picker's own tty and sends without attaching;
# ctrl-n swaps this popup's process for the spawn prompt, which opens the new
# agent as a tab on $parent once it's spawned.
sel=$("$DIR/agents.sh" | fzf --ansi --delimiter='\t' --with-nth=5.. \
  --reverse --cycle \
  --header='Claude agents · enter: jump · ctrl-n: new · ctrl-s: send · ctrl-x: kill' \
  --preview='tmux capture-pane -ept {2}' --preview-window='up,70%,follow' \
  --bind="ctrl-x:execute-silent($DIR/agent.sh kill {2} || kill {3})+reload(sleep 0.3; $self --list)" \
  --bind="ctrl-s:execute(printf 'send> '; IFS= read -r p; [ -n \"\$p\" ] && $DIR/agent.sh send {2} \"\$p\")+reload(sleep 0.3; $self --list)" \
  --bind="ctrl-n:become($DIR/spawn-prompt.sh $(printf '%q' "$spawn_dir") $(printf '%q' "$parent"))" \
  ${extra_opts[@]+"${extra_opts[@]}"})

[ -z "$sel" ] && exit 0

# The jump itself is jump_to_agent, shared with the jump key (jump.sh) so the
# two paths cannot drift. This popup closes on its own when the script exits.
jump_to_agent "$(printf '%s' "$sel" | cut -f2)" "$(printf '%s' "$sel" | cut -f4)" "$parent"
