#!/usr/bin/env bash
# Wire the board into Claude Code, then print what is left to do by hand.
#
# - the hooks in ~/.claude/settings.json: every lifecycle event runs collect.sh, replacing the
#   entries of an earlier install (the previous file is kept as settings.json.before-board)
# - the /todoa and /todos skills in ~/.claude/skills, pointing at this checkout's todo.sh
# A second run leaves the same result.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
DATA="${CLAUDE_ORCH_DIR:-$HOME/.claude/orchestrator}"
command -v jq >/dev/null || { echo "install: jq is required" >&2; exit 1; }

mkdir -p "$CLAUDE_DIR/skills"
[ -s "$SETTINGS" ] || printf '{}\n' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.before-board"
jq --arg cmd "bash $HERE/collect.sh" '
  .hooks = (.hooks // {})
  | reduce ("SessionStart", "UserPromptSubmit", "PreToolUse", "Notification", "Stop", "SessionEnd") as $e (.;
      .hooks[$e] = ((.hooks[$e] // [])
                    | map(select((.hooks // []) | any((.command // "") | endswith("/collect.sh")) | not)))
                   + [{hooks: [{type: "command", command: $cmd, timeout: 5}]}])' "$SETTINGS" > "$SETTINGS.tmp"
mv "$SETTINGS.tmp" "$SETTINGS"

for s in todoa todos; do
  mkdir -p "$CLAUDE_DIR/skills/$s"
  sed "s#__TODO_SH__#$HERE/todo.sh#g" "$HERE/skills/$s/SKILL.md" > "$CLAUDE_DIR/skills/$s/SKILL.md"
done

cat <<MSG
Hooks written to $SETTINGS, previous copy in $SETTINGS.before-board.
Skills /todoa and /todos written to $CLAUDE_DIR/skills.
A session already open keeps the hooks it started with: restart it.

Left to do by hand:

1. Bind the board in tmux, in ~/.tmux.conf or ~/.config/tmux/tmux.conf, then source that file:
     bind b run-shell "$HERE/board.sh"

2. Teach Claude the list in ~/.claude/CLAUDE.md: the snippet is in README.md.

3. Optional, $DATA/config, a shell file:
     CLAUDE_ORCH_ISSUE_URL=https://example.atlassian.net/browse/   # issue links on category segments such as PROJ-12
     CLAUDE_BIN=/path/to/claude                                     # when claude is not on the PATH tmux has
     EDITOR=nvim                                                    # Ctrl-X Ctrl-E in a prompt
MSG
