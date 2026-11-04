#!/usr/bin/env bash
# Orchestrator board, intended for a dedicated tmux window: the todo list.
#
# Usage: dashboard.sh [--once] [--interval N]
set -uo pipefail

STATE="${CLAUDE_ORCHESTRATOR_STATE:-$HOME/.claude/orchestrator/state}"
CACHE="${CLAUDE_ORCH_CACHE:-$HOME/.claude/orchestrator/cache}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTERVAL=2; ONCE=0; HELP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --once) ONCE=1 ;;
    --help-page) HELP=1 ;;
    --interval) INTERVAL="${2:-2}"; shift ;;
  esac; shift
done
mkdir -p "$STATE" "$CACHE" 2>/dev/null
# config, a shell file in the data directory: CLAUDE_BIN, CLAUDE_ORCH_ISSUE_URL, EDITOR
[ -f "${CLAUDE_ORCH_DIR:-$HOME/.claude/orchestrator}/config" ] && . "${CLAUDE_ORCH_DIR:-$HOME/.claude/orchestrator}/config"
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude || echo claude)}"
# the tracker URL an issue key is appended to, such as https://example.atlassian.net/browse/; empty for no issue links
ISSUE_URL="${CLAUDE_ORCH_ISSUE_URL:-}"
EDITOR="${EDITOR:-vi}"

C_DIM=$'\033[2m'; C_RST=$'\033[0m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
C_RED=$'\033[31m'; C_BLU=$'\033[34m'; C_BLD=$'\033[1m'; C_MAG=$'\033[35m'

fmt_ago() {
  local s=$1
  if   [ "$s" -lt 3600 ]  ; then printf '%dm ago'  $((s/60))
  elif [ "$s" -lt 86400 ] ; then printf '%dh ago'  $((s/3600))
  else                           printf '%dd ago'  $((s/86400)); fi
}
cut_to()  { local s=$1 n=$2; [ "${#s}" -le "$n" ] && printf '%s' "$s" || printf '%s…' "${s:0:n-1}"; }

# tmux pane maps, rebuilt once per frame
declare -A PANE_LIVE PANE_BY_PID
load_panes() {
  PANE_LIVE=(); PANE_BY_PID=()
  local pid pane
  while read -r pid pane; do
    [ -n "${pane:-}" ] || continue
    PANE_BY_PID[$pid]=$pane; PANE_LIVE[$pane]=1
  done < <(tmux list-panes -a -F '#{pane_pid} #{pane_id}' 2>/dev/null)
}

# A recorded TMUX_PANE may name a pane that no longer exists, so it is trusted
# only when the server still lists it. Otherwise walk the process tree up from
# the session's pid until a live pane_pid matches - that mapping is exact.
resolve_pane() {
  local pane="${1:-}" pid="${2:-}" hop
  if [ -n "$pane" ] && [ -n "${PANE_LIVE[$pane]+x}" ]; then printf '%s' "$pane"; return; fi
  for hop in 1 2 3 4 5 6 7 8; do
    case "${pid:-}" in ''|0|1) break ;; esac
    if [ -n "${PANE_BY_PID[$pid]+x}" ]; then printf '%s' "${PANE_BY_PID[$pid]}"; return; fi
    pid=$(awk '/^PPid:/{print $2}' "/proc/$pid/status" 2>/dev/null)
  done
  printf ''
}

help_page() {
  local B=$C_BLD R=$C_RST D=$C_DIM
  cat <<EOF
${B}${C_BLU}THE BOARD${R}  ${D}— what is left to do${R}

${B}KEYS${R}
  ${B}o${R}    todos, listed by their AI-written title: pick one to read its full
       description, start, resume or jump to its chat, mark it [v] ◇ review
       (its PR waits for approval), [m] ◆ to merge (approved, not completed),
       [d] done or [n] canceled.
       ${B}Links${R}, listed under the picked item, numbered:
         - its tracker issue, for each category segment that is an issue key
         - every URL written in its description
         - the links you add with [l], such as its Azure DevOps PR
       [1-9] opens that link in the browser, [o] opens them all.
       ${D}[t] retitle or [e] edit the description (Enter saves, Esc
       cancels, Ctrl-X Ctrl-E opens the editor), or [c] file it under a category path
       such as 8677/CA-6, drawn as a tree, (no category) first to uncategorise it.
       [k] [j] move it up or down within its category, [p] to a position in it,
       1 the top. [w] sets the items it waits on: while one is open, the item
       shows ⊘ blocked and "after #12" in front of its title. The chat that
       adds an item through /todoa fills them in.
       [A] adds one, [C] creates a category, [X] deletes one, [R] renames one or
       moves it under another path, [O] orders one among its siblings with [k] [j],
       [H] shows done and canceled items,
       [/] keeps the items whose number, title, description, category or directory
       contains the text, ignoring case. Each item shows its place in its
       category, each category the open items under it in parentheses.
       [↑] [↓] [PgUp] [PgDn] or [K] [J] scroll the list; a picked item opens
       under it, so the list stays in view while you act on the item.
       Both menus show their frequent keys; [?] shows the others or hides them again.
       /todoa and /todos do the same from a chat${R}
  ${B}t${R}    past conversations to resume, ${D}[/] filters them on title, directory or branch${R}
  ${B}h${R}    this page          ${B}q${R}  quit

${B}FILES${R}
  ${D}$HERE/   scripts
  ~/.claude/orchestrator/          todos.tsv, categories, categories.order and config
  ~/.claude/orchestrator/state/   one file per live session, written by hooks, for todo chats
  ~/.claude/orchestrator/cache/   board caches
  Hooks live in ~/.claude/settings.json, written by install.sh.${R}

${D}Press any key to go back.${R}
EOF
  read -rsn1
}

windows_frame() {
  local w; w=$(tput cols 2>/dev/null || echo 100); [ "$w" -gt 40 ] || w=40
  local rule; rule=$(printf '─%.0s' $(seq 1 "$w"))
  printf '%s%sWINDOWS%s %s(every tmux window and what is in it)%s\n' \
    "$C_BLD" "$C_BLU" "$C_RST" "$C_DIM" "$C_RST"
  printf '%s%s%s\n' "$C_DIM" "$rule" "$C_RST"

  : > "$CACHE/window-keys.tsv"
  local letters=abcdefghijklmnopqrstuvwxyz i=0 empties=0
  local pane coords wname cmd path summary L col
  while IFS=$'\t' read -r pane coords wname cmd path summary; do
    [ -n "${pane:-}" ] || continue
    i=$((i+1)); [ "$i" -le 26 ] || break
    L=${letters:$((i-1)):1}
    printf '%s\t%s\n' "$L" "$pane" >> "$CACHE/window-keys.tsv"
    case "$summary" in
      'empty — never used') col=$C_MAG; empties=$((empties+1)) ;;
      shell)                col=$C_DIM ;;
      *)                    col=$C_GRN ;;
    esac
    printf ' %s[%s]%s %-8s %s%-9s%s %-30s %s%s%s\n' \
      "$C_BLU" "$L" "$C_RST" "$coords" "$C_DIM" "$(cut_to "$wname" 9)" "$C_RST" \
      "$(cut_to "$path" 30)" "$col" "$(cut_to "$summary" 40)" "$C_RST"
  done < <(bash "$HERE/windows.sh" 2>/dev/null)
  [ "$i" -gt 0 ] || printf '  %s(tmux not reachable)%s\n' "$C_DIM" "$C_RST"
  [ "$empties" -gt 0 ] && printf '\n  %s%s window(s) marked empty hold a Claude session that was never used.%s\n' \
    "$C_DIM" "$empties" "$C_RST"

  printf '\n%s  [a-z] go to window   [Esc] back   [Q] quit%s\n' "$C_DIM" "$C_RST"
}

goto_window() {
  goto_pane "$(awk -F'\t' -v l="$1" '$1==l{print $2; exit}' "$CACHE/window-keys.tsv" 2>/dev/null)"
}

# Keep the TSV rows whose columns $1 (comma-separated) contain FILTER, ignoring case.
filtered() {
  awk -F'\t' -v f="$FILTER" -v cols="$1" 'BEGIN { f = tolower(f); n = split(cols, c, ",") }
    { for (i = 1; i <= n; i++) if (index(tolower($c[i]), f)) { print; next } }'
}

history_frame() {
  local w; w=$(tput cols 2>/dev/null || echo 100); [ "$w" -gt 40 ] || w=40
  local rule; rule=$(printf '─%.0s' $(seq 1 "$w"))
  printf '%s%sHISTORY%s %s(past conversations — resume one in a new window%s)%s\n' \
    "$C_BLD" "$C_BLU" "$C_RST" "$C_DIM" "${FILTER:+ · filter: $FILTER}" "$C_RST"
  printf '%s%s%s\n' "$C_DIM" "$rule" "$C_RST"

  : > "$CACHE/history-keys.tsv"
  local now; now=$(date +%s)
  local letters=abcdefghijklmnopqrstuvwxyz i=0 mt sid cwd branch title repo
  while IFS=$'\t' read -r mt sid cwd branch title; do
    [ -n "${sid:-}" ] || continue
    i=$((i+1)); [ "$i" -le 20 ] || break
    local L=${letters:$((i-1)):1}
    printf '%s\t%s\t%s\t%s\n' "$L" "$sid" "${cwd:-$HOME}" "$title" >> "$CACHE/history-keys.tsv"
    repo=$(basename "${cwd:-?}")
    printf ' %s[%s]%s %-30s %s%-18s %-16s%s %s%9s%s\n' \
      "$C_BLU" "$L" "$C_RST" "$(cut_to "$title" 30)" \
      "$C_DIM" "$(cut_to "$repo" 18)" "$(cut_to "${branch:-–}" 16)" "$C_RST" \
      "$C_DIM" "$(fmt_ago $(( now - mt )))" "$C_RST"
  # every row, not the first 20: the filter must reach older conversations
  done < <(bash "$HERE/history.sh" 1000000 2>/dev/null | filtered 3,4,5)
  [ "$i" -gt 0 ] || printf '  %s(no conversation found)%s\n' "$C_DIM" "$C_RST"

  printf '\n%s  [a-t] resume in a new window   [/] filter   [Esc] back   [G] rescan   [Q] quit%s\n' \
    "$C_DIM" "$C_RST"
}

resume_session() {
  local L="$1" sid cwd title row
  row=$(awk -F'\t' -v l="$L" '$1==l{print; exit}' "$CACHE/history-keys.tsv" 2>/dev/null)
  [ -n "$row" ] || return 0
  IFS=$'\t' read -r _ sid cwd title <<< "$row"
  [ -n "${sid:-}" ] || return 0
  [ -d "${cwd:-}" ] || cwd="$HOME"
  [ -n "${TMUX:-}" ] || return 0
  # a fresh window in the conversation's own directory, resuming by session id
  tmux new-window -c "$cwd" -n "$(printf '%s' "${title:-claude}" | cut -c1-12)" \
    "'$CLAUDE_BIN' -r '$sid'" 2>/dev/null
}

# The live pane of a todo's chat, empty when the chat is not running.
todo_pane() {
  local sid="$1" rec
  [ -n "$sid" ] && [ -f "$STATE/$sid.tsv" ] || return 0
  rec=$(tail -1 "$STATE/$sid.tsv" | awk -F'\t' '{printf "%s %s", $9, $10}')
  resolve_pane ${rec}
}

# One row per item: key, its place in its category, mark, status, id, the open items it waits on, text,
# indented by its tree depth. Needs load_panes first.
todo_line() {
  local key="$1" id="$2" status="$3" sid="$4" text="$5" width="$6" depth="${7:-0}" pos="${8:-}" wait="${9:-}" mark st col
  case "$status" in
    done)  mark='✓'; st=done; col=$C_DIM ;;
    canceled) mark='✗'; st=canceled; col=$C_DIM ;;
    doing) if [ -n "$(todo_pane "$sid")" ]; then mark='●'; st='in chat'; col=$C_GRN
           else mark='◐'; st=paused; col=$C_YEL; fi ;;
    review) mark='◇'; st=review; col=$C_BLU ;;
    merge) mark='◆'; st='to merge'; col=$C_MAG ;;
    *)     if [ -n "$wait" ]; then mark='⊘'; st=blocked; col=$C_RED; else mark='○'; st=todo; col=$C_RST; fi ;;
  esac
  [ -z "$wait" ] || wait="after $wait "
  printf ' %s%-4s%s %*s%s%3s%s %s%s %-8s%s %s#%-3s%s %s%s%s%s\n' "$C_BLU" "$key" "$C_RST" $((depth*2)) '' \
    "$C_BLD" "${pos:+$pos.}" "$C_RST" "$col" "$mark" "$st" "$C_RST" \
    "$C_DIM" "$id" "$C_RST" "$C_RED" "$wait" "$C_RST" "$(cut_to "$text" $((width-depth*2-4-${#wait})))"
}

# A category, with the open items filed in it and its subcategories.
todo_header() { printf '      %*s%s%s▸ %s%s %s(%s)%s\n' $(($1*2)) '' "$C_BLD" "$C_MAG" "$2" "$C_RST" "$C_DIM" "$3" "$C_RST"; }

# Open items as a category tree, uncategorised first, \001-separated:
#   H depth name count                   opens one category level, count the open items under it
#   I depth id status session text pos wait   an item at that depth, pos its place in its category, 1 the top,
#                                            wait the open items it waits on, as "#12 #15"
# Every category also enters as a row with no id, so an empty one still gets its header.
todo_tree() {
  # pos and wait are taken before the filter, so pos stays the place todo.sh pos takes and a hidden blocker still counts
  # sort on the rank todo.sh cats gives each level of the path, so siblings keep the order catup and catdown set
  # and a branch stays whole; stable, so items keep the file order todo.sh up and down set
  # a filter drops the empty categories, which hold nothing to match
  { bash "$HERE/todo.sh" list | awk -F'\t' -v OFS='\t' '{ open[$1]; r[NR] = $0 }
      END { for (i = 1; i <= NR; i++) {
              $0 = r[i]; w = ""; n = split($10, d, ",")
              for (k = 1; k <= n; k++) if (d[k] in open) w = w (w == "" ? "" : " ") "#" d[k]
              $10 = w; $11 = ++p[$8]; print } }' | filtered 1,6,7,8,9
    [ -n "$FILTER" ] || bash "$HERE/todo.sh" cats | sed 's/^/\t\t\t\t\t\t\t/'; } \
    | awk -F'\t' 'FILENAME == ARGV[1] { rank[$0] = FNR; next }
        { n = split($8, p, "/"); c = ""; k = ""
          for (d = 1; d <= n; d++) { c = c (d > 1 ? "/" : "") p[d]; k = k sprintf("%06d\002", rank[c]) }
          print k "\t" $0 }' <(bash "$HERE/todo.sh" cats) - \
    | LC_ALL=C sort -s -t$'\t' -k1,1 | cut -f2- | awk -F'\t' -v OFS='\001' '
      # the counts are known only once every row is read, so the rows are printed at the end
      { r[NR] = $0; n = ($8 == "") ? 0 : split($8, p, "/")
        if ($1 != "") { c = ""; for (d = 1; d <= n; d++) cnt[c = c (d > 1 ? "/" : "") p[d]]++ } }
      END {
        for (j = 1; j <= NR; j++) {
          split(r[j], f, "\t"); n = (f[8] == "") ? 0 : split(f[8], p, "/")
          k = 1; while (k <= n && k <= m && p[k] == q[k]) k++
          c = ""; for (d = 1; d <= n; d++) { c = c (d > 1 ? "/" : "") p[d]; if (d >= k) print "H", d - 1, p[d], cnt[c] + 0 }
          if (f[1] != "") print "I", n, f[1], f[2], f[5], (f[9] != "" ? f[9] : f[7]), f[11], f[10]
          delete q; for (d = 1; d <= n; d++) q[d] = p[d]; m = n } }'
}

render_todos() {
  local n=0 shown=0 rows kind depth id status sid text pos wait
  # the frame around the list takes 5 lines: header, rule, the "more" line, blank, footer
  rows=$(( $(tput lines 2>/dev/null || echo 40) - 5 ))
  load_panes
  # \001, not tab: tab is IFS whitespace and would collapse an empty session
  while IFS=$'\001' read -r kind depth id status sid text pos wait; do
    if [ "$kind" = H ]; then
      # a header with no room for an item under it would leave the next item filed under the wrong one
      if [ "$rows" -gt 1 ]; then todo_header "$depth" "$id" "$status"; rows=$((rows-1)); else rows=0; fi; continue
    fi
    n=$((n+1)); [ "$rows" -gt 0 ] || continue
    todo_line '' "$id" "$status" "$sid" "$text" 80 "$depth" "$pos" "$wait"; rows=$((rows-1)); shown=$n
  done < <(todo_tree)
  [ "$n" -gt 0 ] || printf '  %s(nothing to do)%s\n' "$C_DIM" "$C_RST"
  [ "$n" -gt "$shown" ] && printf '  %s… %s more, [o] to see them all%s\n' "$C_DIM" $((n-shown)) "$C_RST"
}

# The rows of the todos screen: the open tree, or the done items flat, newest first, category in front.
todo_rows() {
  if [ "$TODO_HISTORY" = 1 ]; then
    bash "$HERE/todo.sh" list --all | awk -F'\t' '$2=="done" || $2=="canceled"' | filtered 1,6,7,8,9 | sort -t$'\t' -k4,4nr \
      | awk -F'\t' -v OFS='\001' '{ print "I", 0, $1, $2, $5, ($8 == "" ? "" : "[" $8 "] ") ($9 != "" ? $9 : $7), "" }'
  else todo_tree; fi
}

# The todo list in exactly HEIGHT lines: title, rule, then the rows from TODO_TOP on, keys a-z on the
# items in view. SEL, an item id, is marked; SNAP scrolls it into view. The board runs this in a
# subshell, so the top it settles on goes to $CACHE/todo-top for the caller to read back.
todo_list() {
  local height="$1" sel="${2:-}" snap="${3:-}" w; w=$(tput cols 2>/dev/null || echo 100); [ "$w" -gt 40 ] || w=40
  local -a rows=(); local r kind depth id status sid text pos wait idx=-1 top i n=0 shown=0 key body=''
  local letters=abcdefghijklmnopqrstuvwxyz
  while IFS= read -r r; do
    rows+=("$r")
    IFS=$'\001' read -r kind _ id _ <<< "$r"
    [ -n "$sel" ] && [ "$kind$id" = "I$sel" ] && idx=$(( ${#rows[@]} - 1 ))
  done < <(todo_rows)
  height=$((height - 2)); [ "$height" -gt 0 ] || height=1
  top=$TODO_TOP
  if [ -n "$snap" ] && [ "$idx" -ge 0 ] && { [ "$idx" -lt "$top" ] || [ "$idx" -ge $((top + height)) ]; }; then
    top=$((idx - height / 2))
  fi
  [ "$top" -le $(( ${#rows[@]} - height )) ] || top=$(( ${#rows[@]} - height ))
  [ "$top" -ge 0 ] || top=0
  printf '%s\n' "$top" > "$CACHE/todo-top"

  : > "$CACHE/todo-keys.tsv"
  load_panes
  for (( i = top; i < ${#rows[@]} && shown < height; i++, shown++ )); do
    IFS=$'\001' read -r kind depth id status sid text pos wait <<< "${rows[i]}"
    if [ "$kind" = H ]; then body+=$(todo_header "$depth" "$id" "$status")$'\n'; continue; fi
    [ "$n" -lt 26 ] || break
    key="[${letters:n:1}]"
    printf '%s\t%s\t%s\t%s\n' "${letters:n:1}" "$id" "$status" "$sid" >> "$CACHE/todo-keys.tsv"
    n=$((n+1))
    [ "$id" = "$sel" ] && key=' >>'
    body+=$(todo_line "$key" "$id" "$status" "$sid" "$text" $((w-22)) "$depth" "$pos" "$wait")$'\n'
  done

  local scope=open; [ "$TODO_HISTORY" = 1 ] && scope='done and canceled, newest first'
  printf '%s%sTODOS%s %s(%s · rows %s-%s of %s%s)%s\n' "$C_BLD" "$C_BLU" "$C_RST" "$C_DIM" "$scope" \
    $((top + 1)) "$i" "${#rows[@]}" "${FILTER:+ · filter: $FILTER}" "$C_RST"
  printf '%s%s%s\n' "$C_DIM" "$(printf '─%.0s' $(seq 1 "$w"))" "$C_RST"
  [ "${#rows[@]}" -gt 0 ] || { body="  ${C_DIM}(empty)${C_RST}"$'\n'; shown=1; }
  # padded to HEIGHT, so whatever comes below starts on the same line whatever the list holds
  printf '%s' "$body"
  for (( ; shown < height; shown++ )); do printf '\n'; done
}

todos_frame() {
  local h; h=$(tput lines 2>/dev/null || echo 40)
  local other=history; [ "$TODO_HISTORY" = 1 ] && other='open items'
  # the footer may wrap once, and the frame must stop short of the last line or the terminal scrolls
  todo_list $((h - 4 - (${#TODO_MSG} > 0)))
  if [ "$TODO_MORE" = 1 ]; then
    printf '%s  [a-z] pick an item   [A] add   [C] new category   [X] delete category   [/] filter   [R] rename category   [O] order categories   [H] %s   [↑↓ PgUp PgDn J K] scroll   [?] less   [Esc] back   [Q] quit%s\n' \
      "$C_DIM" "$other" "$C_RST"
  else
    printf '%s  [a-z] pick an item   [A] add   [C] new category   [X] delete category   [?] more   [Esc] back   [Q] quit%s\n' "$C_DIM" "$C_RST"
  fi
  [ -n "$TODO_MSG" ] && printf '  %s%s%s\n' "$C_YEL" "$TODO_MSG" "$C_RST"
}

# Scroll the todo list by STEP rows, or by half a screen for PGUP and PGDN. Fails on any other key.
todo_scroll() {
  local page=$(( $(tput lines 2>/dev/null || echo 40) / 2 ))
  case "$1" in
    UP|K)   TODO_TOP=$((TODO_TOP - 1)) ;;
    DOWN|J) TODO_TOP=$((TODO_TOP + 1)) ;;
    PGUP)   TODO_TOP=$((TODO_TOP - page)) ;;
    PGDN)   TODO_TOP=$((TODO_TOP + page)) ;;
    *) return 1 ;;
  esac
  [ "$TODO_TOP" -ge 0 ] || TODO_TOP=0
}

# One key into KEY: a character, Esc, or UP, DOWN, PGUP, PGDN for those keys. TIMEOUT in seconds, optional.
read_key() {
  local k rest
  KEY=''
  read -rsn1 ${1:+-t "$1"} k || return 0
  if [ "$k" = $'\e' ]; then
    read -rsn2 -t 0.05 rest
    case "$rest" in
      '[A') k=UP ;;
      '[B') k=DOWN ;;
      '[5') read -rsn1 -t 0.05 _; k=PGUP ;;
      '[6') read -rsn1 -t 0.05 _; k=PGDN ;;
    esac
  fi
  KEY=$k
}

# The URLs of an item, one per line, deduplicated: the tracker issue of every category segment that is an issue
# key, such as PROJ-12, when the config sets CLAUDE_ORCH_ISSUE_URL, then the URLs in its description, then the
# links added with todo.sh links.
item_links() {
  { [ -z "$ISSUE_URL" ] || printf '%s\n' "$1" | tr '/' '\n' | grep -E '^[A-Z][A-Z0-9_]*-[0-9]+$' | sed "s#^#$ISSUE_URL#"
    printf '%s\n' "$2" | grep -oE 'https?://[^ ]+'
    printf '%s\n' $3; } | awk 'NF && !seen[$0]++'
}

# Open a URL in the Windows browser from WSL, or with xdg-open elsewhere.
open_url() {
  if [ -x /mnt/c/Windows/explorer.exe ]; then /mnt/c/Windows/explorer.exe "$1" >/dev/null 2>&1
  else xdg-open "$1" >/dev/null 2>&1 & fi
}

# Show the picked item in full under the list, then act on it: start, resume or jump to its chat,
# close, reopen or delete it, edit its title or description. The list keeps the top part and scrolls.
todo_act() {
  local row id status sid pane act w h list desc opts more title text cat cwd after links urls waits v snap=1
  row=$(awk -F'\t' -v l="$1" '$1==l{print; exit}' "$CACHE/todo-keys.tsv")
  IFS=$'\001' read -r _ id status sid <<< "${row//$'\t'/$'\001'}"
  [ -n "${id:-}" ] || return 0
  IFS=$'\001' read -r _ _ _ _ _ cwd text cat title after links <<< "$(bash "$HERE/todo.sh" list --all \
    | awk -F'\t' -v id="$id" '$1==id{gsub("\t", "\001"); print; exit}')"
  waits=$(bash "$HERE/todo.sh" list --all | awk -F'\t' -v a=",$after," 'index(a, "," $1 ",") {
    printf "    #%s %-8s %s\n", $1, $2, ($9 != "" ? $9 : $7) }')
  urls=$(item_links "$cat" "$text" "$links")
  load_panes; pane=$(todo_pane "${sid:-}")
  # the frequent actions first, the rest behind [?] (TODO_MORE)
  if [ "$status" = done ] || [ "$status" = canceled ]; then
    opts='[r] reopen  [x] delete  '; more='[t] title  [e] description  [l] links  '
  else
    opts='[s] jump to its chat  [d] done  [e] description  [x] delete  '
    [ -n "$pane" ] || opts="[s] $([ -n "${sid:-}" ] && echo resume || echo start) in a new window  ${opts#*chat  }"
    more='[v] in review  [m] to merge  [n] canceled  [k] up  [j] down  [p] position  [c] category  [w] waits on  [t] title  [l] links  '
  fi
  while :; do
    w=$(tput cols 2>/dev/null || echo 100); [ "$w" -gt 40 ] || w=40
    h=$(tput lines 2>/dev/null || echo 40)
    desc=$(printf '%s\n' "$text" | fold -s -w $((w-4)) | sed 's/^/  /')
    [ -z "$waits" ] || desc+=$'\n\n  waits on:\n'$(printf '%s\n' "$waits" | cut -c1-$((w-2)))
    [ -z "$urls" ] || desc+=$'\n\n  links, [1-9] opens one, [o] all, [l] edits the added ones:\n'$(printf '%s\n' "$urls" \
      | head -9 | awk '{ printf "    %s[%d]%s %s\n", b, NR, z, $0 }' b="$C_BLU" z="$C_RST")
    # half the screen, less when the description needs it: 7 lines of detail around it, 3 for read_edit
    list=$((h / 2)); [ "$list" -le $((h - $(wc -l <<< "$desc") - 10)) ] || list=$((h - $(wc -l <<< "$desc") - 10))
    [ "$list" -ge 5 ] || list=5
    printf '\033[H\033[2J%s\n' "$(todo_list "$list" "$id" "$snap")"
    TODO_TOP=$(cat "$CACHE/todo-top" 2>/dev/null || echo 0); snap=''
    printf '%s%s%s\n' "$C_DIM" "$(printf '═%.0s' $(seq 1 "$w"))" "$C_RST"
    printf '%s%s#%s %s%s\n' "$C_BLD" "$C_BLU" "$id" "${title:-(no title yet)}" "$C_RST"
    printf '%s%s%s\n\n' "$C_DIM" "${cat:+[$cat]  }$cwd" "$C_RST"
    printf '%s\n' "$desc"
    if [ "$TODO_MORE" = 1 ]; then
      printf '\n  %s%s[?] less  [any] cancel  %s[↑↓ PgUp PgDn J K] scroll the list %s' "$opts" "$more" "$C_DIM" "$C_RST"
    else
      printf '\n  %s[?] more  [any] cancel ' "$opts"
    fi
    read_key; act=$KEY
    case "$act" in
      '?') TODO_MORE=$((1-TODO_MORE)); continue ;;
      [1-9]) v=$(sed -n "${act}p" <<< "$urls"); [ -n "$v" ] && open_url "$v"; continue ;;
      o) while IFS= read -r v; do [ -n "$v" ] && open_url "$v"; done <<< "$urls"; continue ;;
    esac
    todo_scroll "$act" || break
  done
  TODO_MSG=''
  case "$act" in
    s) if [ -n "$pane" ]; then goto_pane "$pane"
       else TODO_MSG=$(bash "$HERE/todo.sh" start "$id" 2>&1); fi ;;
    v) [ "$status" != done ] && [ "$status" != canceled ] && bash "$HERE/todo.sh" review "$id" ;;
    m) [ "$status" != done ] && [ "$status" != canceled ] && bash "$HERE/todo.sh" merge "$id" ;;
    d) bash "$HERE/todo.sh" done "$id" ;;
    n) bash "$HERE/todo.sh" cancel "$id" ;;
    r) bash "$HERE/todo.sh" reopen "$id" ;;
    k) [ "$status" != done ] && [ "$status" != canceled ] && bash "$HERE/todo.sh" up "$id" ;;
    j) [ "$status" != done ] && [ "$status" != canceled ] && bash "$HERE/todo.sh" down "$id" ;;
    p) [ "$status" != done ] && [ "$status" != canceled ] && v=$(read_edit 'position in its category, 1 the top' '') \
         && TODO_MSG=$(bash "$HERE/todo.sh" pos "$id" "$v" 2>&1) ;;
    x) bash "$HERE/todo.sh" rm "$id" ;;
    c) bash "$HERE/todo.sh" move "$id" "$(read_cat item)" ;;
    w) [ "$status" != done ] && [ "$status" != canceled ] && v=$(read_edit 'ids it waits on, such as 12,15, empty for none' "$after") \
         && TODO_MSG=$(bash "$HERE/todo.sh" after "$id" "$v" 2>&1) ;;
    t) v=$(read_edit title "$title") && TODO_MSG=$(bash "$HERE/todo.sh" title "$id" "$v" 2>&1) ;;
    e) v=$(read_edit description "$text") && TODO_MSG=$(bash "$HERE/todo.sh" edit "$id" "$v" 2>&1) ;;
    l) v=$(read_edit 'links, space-separated, such as a PR URL' "$links") && TODO_MSG=$(bash "$HERE/todo.sh" links "$id" "$v" 2>&1) ;;
  esac
}

# Ctrl-X Ctrl-E in read_edit: the line goes through $EDITOR and comes back joined on one line.
edit_in_editor() {
  local f; f=$(mktemp) || return
  printf '%s\n' "$READLINE_LINE" > "$f"
  "$EDITOR" "$f" </dev/tty >/dev/tty
  READLINE_LINE=$(paste -sd' ' "$f"); READLINE_POINT=${#READLINE_LINE}
  rm -f "$f"
}

# Prompt for a line, prefilled with its current value and editable with readline.
# Esc cancels: it prints the current value back and fails. Ctrl-X Ctrl-E opens the editor.
read_edit() {
  local v rc=0
  printf '\033[?25h\n  %sEnter saves, Esc cancels, Ctrl-X Ctrl-E opens the editor%s\n' "$C_DIM" "$C_RST" >&2
  # Esc empties the line then sends EOF, the only way to make read fail; the short
  # timeout keeps Esc snappy while still telling it apart from arrow-key sequences.
  bind 'set keyseq-timeout 50' 2>/dev/null
  bind '"\e": "\C-a\C-k\C-d"' 2>/dev/null
  bind -x '"\C-x\C-e": edit_in_editor' 2>/dev/null
  read -e -r -p "  $1: " -i "$2" v || { v=$2; rc=1; }
  printf '\033[?25l' >&2
  printf '%s' "$v"
  return $rc
}

# Pick a category path from the existing ones, or type a new one. Empty means none.
# Enter takes the highlighted match, or the typed path when nothing matches;
# Alt-Enter takes the typed path even when it matches an existing one.
# Filing an item ("item") lists (no category) first, which prints nothing.
read_cat() {
  local none='(no category)'
  printf '\033[?25h' >&2
  { [ "${1:-}" = item ] && echo "$none"; bash "$HERE/todo.sh" cats; } | fzf --height=~40% --reverse --prompt='  category> ' \
    --header='Enter: pick or create   Alt-Enter: create as typed   Esc: none' \
    --bind 'enter:accept-or-print-query,alt-enter:print-query' | grep -vxF "$none"
  printf '\033[?25l' >&2
}

# Pick a category, then move it among its siblings with k and j until any other key.
todo_order_cat() {
  local c k
  c=$(read_cat); [ -n "$c" ] || return 0
  while :; do
    printf '\033[H\033[2J%s\n' "$(todo_list $(( $(tput lines 2>/dev/null || echo 40) - 3 )))"
    printf '  %sordering%s %s%s%s   [k] up  [j] down  [any] done ' "$C_DIM" "$C_RST" "$C_BLD" "$c" "$C_RST"
    read_key; k=$KEY
    case "$k" in
      k) TODO_MSG=$(bash "$HERE/todo.sh" catup "$c" 2>&1) ;;
      j) TODO_MSG=$(bash "$HERE/todo.sh" catdown "$c" 2>&1) ;;
      *) break ;;
    esac
    # an unknown category, typed rather than picked, ends the loop with the error in the footer
    [ -z "$TODO_MSG" ] || break
  done
}

todo_add() {
  local text
  text=$(read_edit 'new todo' '')
  [ -n "$text" ] && TODO_MSG=$(bash "$HERE/todo.sh" add --cat "$(read_cat item)" "$text" 2>&1)
}

frame() {
  local w; w=$(tput cols 2>/dev/null || echo 100); [ "$w" -gt 40 ] || w=40
  # tr is byte-oriented and mangles the multibyte rule character; repeat it instead
  local rule; rule=$(printf '─%.0s' $(seq 1 "$w"))
  printf '%s%sTODOS%s %s%s  (open · [o] manage)%s\n' "$C_BLD" "$C_BLU" "$C_RST" "$C_DIM" "$(date +%H:%M:%S)" "$C_RST"
  printf '%s%s%s\n' "$C_DIM" "$rule" "$C_RST"
  render_todos
  printf '\n%s  [o] todos  [A] add  [w] windows  [t] history  [h] help  [q] quit%s\n' "$C_DIM" "$C_RST"
}

goto_pane() {
  local pane="$1" sess
  [ -n "$pane" ] || return 0
  # display-message -t needs an attached client to resolve, so read the session
  # name straight out of the pane list instead
  sess=$(tmux list-panes -a -F '#{pane_id} #{session_name}' 2>/dev/null \
         | awk -v p="$pane" '$1==p{print $2; exit}')
  [ -n "$sess" ] && tmux switch-client -t "$sess" 2>/dev/null
  tmux select-window -t "$pane" 2>/dev/null
  tmux select-pane   -t "$pane" 2>/dev/null
}

VIEW=todos; TODO_HISTORY=0; TODO_MSG=''; FILTER=''; TODO_TOP=0; TODO_MORE=0
if [ "$HELP" = 1 ]; then help_page; exit 0; fi
if [ "$ONCE" = 1 ]; then frame; exit 0; fi
trap 'printf "\033[?25h"; exit 0' INT TERM
printf '\033[?25l'                       # hide cursor; restored by the trap
while :; do
  case "$VIEW" in
    todos)   out=$(todos_frame); TODO_TOP=$(cat "$CACHE/todo-top" 2>/dev/null || echo 0) ;;
    history) out=$(history_frame) ;;
    windows) out=$(windows_frame) ;;
    *)       out=$(frame) ;;
  esac
  printf '\033[H\033[2J%s\n' "$out"      # repaint whole frame at once: no flicker
  # read doubles as the frame delay, so keys register without a busy loop.
  read_key "$INTERVAL"; key=$KEY
  if [ "$VIEW" = todos ]; then
    # same rule as history: lowercase picks a row, uppercase is a command
    todo_scroll "$key" && continue
    case "$key" in
      Q)        printf '\033[?25h'; exit 0 ;;
      B|$'\e') VIEW=board; TODO_HISTORY=0; TODO_MSG=''; FILTER=''; TODO_TOP=0 ;;
      /)        FILTER=$(read_edit filter "$FILTER"); TODO_TOP=0 ;;
      A)        todo_add ;;
      C)        c=$(read_cat); [ -n "$c" ] && TODO_MSG=$(bash "$HERE/todo.sh" mkcat "$c" 2>&1) ;;
      X)        c=$(read_cat); [ -n "$c" ] && TODO_MSG=$(bash "$HERE/todo.sh" rmcat "$c" 2>&1) ;;
      R)        c=$(read_cat); [ -n "$c" ] && v=$(read_edit "rename $c to" "$c") \
                  && TODO_MSG=$(bash "$HERE/todo.sh" mvcat "$c" "$v" 2>&1) ;;
      O)        TODO_MSG=''; todo_order_cat ;;
      H)        TODO_HISTORY=$((1-TODO_HISTORY)); TODO_TOP=0 ;;
      '?')      TODO_MORE=$((1-TODO_MORE)) ;;
      [a-z])    todo_act "$key" ;;
    esac
    continue
  fi
  if [ "$VIEW" = history ]; then
    # lowercase picks a row, uppercase is a command: otherwise rows b, g and q
    # would be unreachable behind back/rescan/quit.
    case "$key" in
      Q)        printf '\033[?25h'; exit 0 ;;
      B|$'\e') VIEW=board; FILTER='' ;;
      /)        FILTER=$(read_edit filter "$FILTER") ;;
      G)        rm -f "$CACHE/history.tsv" ;;
      [a-t])    resume_session "$key"; VIEW=board; FILTER='' ;;
    esac
    continue
  fi
  if [ "$VIEW" = windows ]; then
    case "$key" in
      Q)        printf '\033[?25h'; exit 0 ;;
      B|$'\e') VIEW=board ;;
    esac
    continue
  fi
  case "$key" in
    q|Q) printf '\033[?25h'; exit 0 ;;
    t|T) VIEW=history ;;
    w|W) VIEW=windows ;;
    o|O) VIEW=todos ;;
    A)   VIEW=todos; todo_add ;;
    h|H|'?') if [ -n "${TMUX:-}" ]; then
               tmux display-popup -E -w 84% -h 88% "bash '$HERE/dashboard.sh' --help-page" 2>/dev/null
             else
               printf '\033[?25h\033[H\033[2J'; help_page; printf '\033[?25l'
             fi ;;
  esac
done
