#!/usr/bin/env bash
# Open (or jump to) the orchestrator window in the current tmux session.
set -uo pipefail
WIN="${CLAUDE_ORCH_WINDOW:-board}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -n "${TMUX:-}" ] || { exec bash "$HERE/dashboard.sh" "$@"; }

if tmux list-windows -F '#W' | grep -qx "$WIN"; then
  exec tmux select-window -t "$WIN"
fi
tmux new-window -d -n "$WIN" "bash '$HERE/dashboard.sh'"
exec tmux select-window -t "$WIN"
