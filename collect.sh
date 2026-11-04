#!/usr/bin/env bash
# Hook entrypoint for the session orchestrator.
#
# Appends one TSV event line per hook invocation to state/<session_id>.tsv.
# Design constraints, in order of importance:
#   1. Never block a session: every path exits 0, stdout stays empty so no hook
#      decision is ever implied, and a missing jq/state dir degrades to a no-op.
#   2. Stay cheap: one jq per event, one append. No git, no reads of prior state.
#      Branch and labels are resolved by the dashboard, not here.
set -uo pipefail

STATE="${CLAUDE_ORCHESTRATOR_STATE:-$HOME/.claude/orchestrator/state}"
mkdir -p "$STATE" 2>/dev/null || exit 0

payload=$(cat)

line=$(printf '%s' "$payload" | jq -rc '
  [ (.session_id // "?"),
    (.hook_event_name // "?"),
    (.tool_name // ""),
    (.notification_type // ""),
    ((.prompt // .last_assistant_message // .message // "")
       | tostring | gsub("[\t\r\n]"; " ") | .[0:200]),
    (.cwd // ""),
    (.transcript_path // "")
  ] | @tsv' 2>/dev/null) || exit 0

[ -n "$line" ] || exit 0
sid=${line%%$'\t'*}
case "$sid" in ""|"?") exit 0 ;; esac

event=${line#*$'\t'}; event=${event%%$'\t'*}

# A finished session leaves the board rather than lingering as stale.
if [ "$event" = "SessionEnd" ]; then
  rm -f "$STATE/$sid.tsv" 2>/dev/null
  exit 0
fi

# Two ways to locate the session's tmux pane. TMUX_PANE is cheap but can be
# stale (it is inherited from whatever pane the process started in), so the pid
# is recorded too: the board walks it up to a live tmux pane_pid, which is exact.
printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$line" "${TMUX_PANE:-}" "$PPID" >> "$STATE/$sid.tsv" 2>/dev/null

# Opportunistic prune: only on SessionStart, so it costs nothing in the hot path.
if [ "$event" = "SessionStart" ]; then
  find "$STATE" -name '*.tsv' -mtime +2 -delete 2>/dev/null
  # a chat opened by `todo.sh start` inherits TODO_ID: record it as the item's chat
  [ -n "${TODO_ID:-}" ] && bash "$(dirname "${BASH_SOURCE[0]}")/todo.sh" link "$TODO_ID" "$sid" >/dev/null 2>&1
fi
exit 0
