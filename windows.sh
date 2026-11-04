#!/usr/bin/env bash
# Inventory of every tmux window, with a one-line summary of what is in it.
#
# Emits TSV: pane_id \t coords \t window_name \t command \t short_path \t summary
#
# A claude window's summary comes from the board's own record of that session
# when there is one (the prompt that started it). Otherwise the pane is read
# directly: a session still showing the welcome placeholder has never been used.
set -uo pipefail
STATE="${CLAUDE_ORCHESTRATOR_STATE:-$HOME/.claude/orchestrator/state}"

# pane_pid -> pane_id, for mapping a session's process back to its window
declare -A BY_PID
while read -r pp pi; do [ -n "${pi:-}" ] && BY_PID[$pp]=$pi; done \
  < <(tmux list-panes -a -F '#{pane_pid} #{pane_id}' 2>/dev/null)

# pane_id -> the prompt that opened that session, from the board's state files
declare -A LABEL
shopt -s nullglob
for f in "$STATE"/*.tsv; do
  rec=$(awk 'BEGIN{FS="\t"; s=sprintf("%c",1); l=""}
             $3=="UserPromptSubmit" && $6!="" && l==""{l=$6}
             {pn=$9; pd=$10}
             END{if(NR)printf "%s%s%s%s%s", l, s, pn, s, pd}' "$f")
  IFS=$'\001' read -r lbl pane pid <<< "$rec"
  # the recorded pane may be stale, so fall back to walking the pid upward
  if [ -z "${pane:-}" ] || ! tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qx "$pane"; then
    for _ in 1 2 3 4 5 6 7 8; do
      case "${pid:-}" in ''|0|1) break ;; esac
      [ -n "${BY_PID[$pid]+x}" ] && { pane=${BY_PID[$pid]}; break; }
      pid=$(awk '/^PPid:/{print $2}' "/proc/$pid/status" 2>/dev/null)
    done
  fi
  [ -n "${pane:-}" ] && [ -n "${lbl:-}" ] && LABEL[$pane]=$lbl
done
shopt -u nullglob

while IFS='|' read -r pane coords wname cmd path; do
  [ -n "${pane:-}" ] || continue
  short=${path/#$HOME/\~}
  summary=""
  if [ "$cmd" = "claude" ]; then
    if [ -n "${LABEL[$pane]+x}" ]; then
      summary=$(printf "%s" "${LABEL[$pane]}" | cut -c1-120)
    elif tmux capture-pane -p -t "$pane" 2>/dev/null | grep -q 'Try "'; then
      # the welcome placeholder is still on screen: nothing was ever typed here
      summary="empty — never used"
    else
      summary=$(tmux capture-pane -p -t "$pane" 2>/dev/null \
                | grep -vE '^\s*$' | tail -1 | sed 's/^[[:space:]]*//' | cut -c1-60)
      [ -n "$summary" ] || summary="(active)"
    fi
  else
    summary="shell"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$pane" "$coords" "$wname" "$cmd" "$short" "${summary//	/ }"
done < <(tmux list-windows -a -F '#{pane_id}|#{session_name}:#{window_index}|#{window_name}|#{pane_current_command}|#{pane_current_path}' 2>/dev/null)
