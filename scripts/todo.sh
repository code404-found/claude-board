#!/usr/bin/env bash
# Todo list shared by the board and every Claude session.
#
# Store: todos.tsv, one row per item:
#   id \t status \t created \t updated \t session_id \t cwd \t text \t category \t title \t after \t links
# status is todo, doing, review (its PR waits for approval), merge (its PR is approved, not
# completed), done or canceled, the last two closing the item. session_id is
# the chat working on the item, filled in by collect.sh at SessionStart from the TODO_ID
# the window inherits.
# category is a /-separated path, such as 8677/CA-6, the board draws as a tree;
# empty leaves the item uncategorised. Rows written before it have 7 fields.
# title is the few words the board shows, written by a headless Haiku run after add;
# text stays the full description, the prompt a started chat receives.
# after is the comma-separated ids of the items this one waits on, mostly set by the chat that
# adds it; the board shows it blocked while one of them is still open.
# links is the space-separated URLs added to the item, such as its pull request; the board
# opens them next to the issue links of its category segments and the URLs of its text.
# categories holds the paths made with mkcat, which stay until rmcat; a path only open items
# carry vanishes with its last one. categories.order ranks siblings the way the board draws
# them, written by catup and catdown; a path it misses comes after, made ones first, then
# the others alphabetically.
# trash.tsv is the recycle bin: rm moves a row there, status kept and updated set to the deletion
# time, restore puts it back at the end of the list and purge drops it for good.
#
# Usage:
#   todo.sh add [--cwd DIR] [--cat PATH] [--after IDS] TEXT...   (TEXT from stdin when omitted) -> prints the id
#   todo.sh after ID [IDS]            set the items ID waits on, such as "12,15", clear them without IDS
#   todo.sh links ID [URLS]           set the links added to ID, clear them without URLS
#   todo.sh list [--all | --bin]      open and in-progress items, --all adds done and canceled, --bin the recycle bin
#   todo.sh cats                      the categories of open items or created, one per line, in board order
#   todo.sh mkcat PATH                create a category, nested under its parents
#   todo.sh rmcat PATH                delete a category and its subcategories, refused while an open item is filed there
#   todo.sh mvcat PATH NEW            rename a category, or move it under another, with its subcategories and items
#   todo.sh catup PATH | catdown PATH swap the category with the sibling above or below it
#   todo.sh move ID [PATH]            file the item under PATH, uncategorise it without one
#   todo.sh up ID | down ID           swap the item with the open item above or below it in its category
#   todo.sh pos ID N                  move the item to the Nth place among the open items of its category, 1 the top
#   todo.sh title ID TEXT | edit ID TEXT   set the title, or the description and regenerate the title
#   todo.sh autotitle [ID...]         fill empty titles, by default for every open item without one
#   todo.sh start ID                  open a new tmux window with a chat on the item,
#                                     or resume the chat that already worked on it
#   todo.sh review ID | merge ID      its PR waits for approval, or is approved and waits to be completed
#   todo.sh done ID | cancel ID | reopen ID | rm ID   rm moves the item to the recycle bin
#   todo.sh restore ID | purge [ID]   put an item back from the recycle bin, or drop one or all of them for good
#   todo.sh link ID SESSION_ID
set -uo pipefail

DIR="${CLAUDE_ORCH_DIR:-$HOME/.claude/orchestrator}"
DB="$DIR/todos.tsv"
BIN="$DIR/trash.tsv"
CATS="$DIR/categories"
ORDER="$DIR/categories.order"
# config, a shell file in the data directory: CLAUDE_BIN, CLAUDE_ORCH_ISSUE_URL
[ -f "$DIR/config" ] && . "$DIR/config"
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude || echo claude)}"
mkdir -p "$DIR" && touch "$DB" "$BIN" "$CATS" "$ORDER"

die() { printf 'todo: %s\n' "$*" >&2; exit 1; }
row() { awk -F'\t' -v id="$1" '$1==id{print; exit}' "$DB"; }
# " a / b/ " -> "a/b": a stray slash or space would open an extra tree level
oneline() { printf '%s' "$1" | tr '\t\r\n' '   ' | sed 's/^ *//; s/ *$//'; }
clean_cat() { printf '%s' "$1" | tr '\t\r\n' '   ' | sed 's# */ *#/#g; s#//*#/#g; s#^[ /]*##; s#[ /]*$##'; }
# "#12, 15 12" -> "12,15", each an existing item other than SELF
clean_after() {
  local self="$1" out='' d; shift
  for d in $(printf '%s' "$*" | tr -c '0-9' ' '); do
    [ "$d" != "$self" ] || die "#$d cannot wait on itself"
    [ -n "$(row "$d")" ] || die "no item #$d"
    [[ ",$out," == *",$d,"* ]] || out+="${out:+,}$d"
  done
  printf '%s' "$out"
}

# Set column COL of one row to VALUE.
set_col() {
  local id="$1" col="$2" value="$3"
  [ -n "$(row "$id")" ] || die "no item #$id"
  (
    flock 9
    awk -F'\t' -v OFS='\t' -v id="$id" -v c="$col" -v v="$value" -v now="$(date +%s)" '
      $1==id { $c = v; $4 = now } { print }' "$DB" > "$DB.tmp" && mv "$DB.tmp" "$DB"
  ) 9> "$DB.lock"
}

# A 2 to 5 word title from the description. Hooks off and TODO_ID dropped, or this
# run would appear on the board and could link itself to the item a chat works on.
gen_title() {
  (cd / && printf '%s' "$1" | env -u TODO_ID "$CLAUDE_BIN" -p --model haiku --tools "" \
    --settings '{"disableAllHooks":true}' \
    --system-prompt "You write the title of a todo item: at most 5 words, saying what it does, in English unless the item itself is written in French. Name the component, never a config key, class or ticket key. Reply with the title only, no quotes, no trailing period." \
    "Title for this todo:") 2>/dev/null | head -1
}

# Move one row from file FROM to the end of file TO, dating it now. WHERE names FROM in the error.
move_row() {
  local from="$1" to="$2" id="$3" where="${4:-}"
  grep -q "^$id"$'\t' "$from" || die "no item #$id${where:+ $where}"
  (
    flock 9
    awk -F'\t' -v OFS='\t' -v id="$id" -v to="$to" -v now="$(date +%s)" '
      $1==id { $4 = now; print >> to; next } { print }' "$from" > "$from.tmp" && mv "$from.tmp" "$from"
  ) 9> "$DB.lock"
}

# Set the status and/or the session of one row. flock serialises the board and concurrent hooks.
set_fields() {
  local id="$1" status="$2" session="$3"
  [ -n "$(row "$id")" ] || die "no item #$id"
  (
    flock 9
    awk -F'\t' -v OFS='\t' -v id="$id" -v st="$status" -v s="$session" -v now="$(date +%s)" '
      $1==id { if (st != "") $2 = st; if (s != "") $5 = s; $4 = now } { print }' "$DB" > "$DB.tmp" \
      && mv "$DB.tmp" "$DB"
  ) 9> "$DB.lock"
}

# Swap one row with the nearest open row of its category, STEP -1 above, 1 below.
# File order is the order the board shows within a category.
reorder() {
  local id="$1" step="$2"
  [ -n "$(row "$id")" ] || die "no item #$id"
  (
    flock 9
    awk -F'\t' -v id="$id" -v s="$step" '
      { r[NR] = $0; st[NR] = $2; c[NR] = $8; if ($1 == id) i = NR }
      END {
        for (j = i + s; j >= 1 && j <= NR; j += s)
          if (st[j] != "done" && st[j] != "canceled" && c[j] == c[i]) { t = r[i]; r[i] = r[j]; r[j] = t; break }
        for (k = 1; k <= NR; k++) print r[k] }' "$DB" > "$DB.tmp" && mv "$DB.tmp" "$DB"
  ) 9> "$DB.lock"
}

# Move one row to the Nth place among the open rows of its category, past the last when N exceeds them.
place() {
  local id="$1" n="$2"
  [ -n "$(row "$id")" ] || die "no item #$id"
  [[ "$n" =~ ^[0-9]+$ ]] || die "position '$n' is not a number"
  (
    flock 9
    awk -F'\t' -v id="$id" -v n="$n" '
      { r[NR] = $0; st[NR] = $2; c[NR] = $8; if ($1 == id) i = NR }
      END {
        for (k = 1; k <= NR; k++) if (k != i && st[k] != "done" && st[k] != "canceled" && c[k] == c[i]) L[++m] = k
        if (n < 1) n = 1
        for (k = 1; k <= NR; k++) {
          if (k == i && m > 0) continue
          if (n <= m && k == L[n]) print r[i]
          print r[k]
          if (n > m && m > 0 && k == L[m]) print r[i] } }' "$DB" > "$DB.tmp" && mv "$DB.tmp" "$DB"
  ) 9> "$DB.lock"
}

# Every made or open item's category path and its parents, ranked by the order file first,
# then made ones in file order, then the ones only items carry.
ordered_cats() {
  { cat "$CATS"; awk -F'\t' '$2!="done" && $2!="canceled" && $8!=""{print $8}' "$DB" | sort -u; } | awk '
    { n = split($0, p, "/"); c = ""
      for (d = 1; d <= n; d++) { c = c (d > 1 ? "/" : "") p[d]; if (!(c in seen)) { seen[c]; print c } } }' \
    | awk 'FILENAME == ARGV[1] { o[++m] = $0; next }
        { live[$0]; l[++k] = $0 }
        END { for (i = 1; i <= m; i++) if ((o[i] in live) && !(o[i] in out)) { out[o[i]]; print o[i] }
              for (j = 1; j <= k; j++) if (!(l[j] in out)) print l[j] }' "$ORDER" -
}

# Swap one category with its nearest sibling, STEP -1 above, 1 below, writing the whole order to the order file;
# a category gone empty drops out of it, and comes back last if items return.
# A category's children are ranked among themselves, so they follow it without moving.
reorder_cat() {
  local c; c=$(clean_cat "$1")
  ordered_cats | grep -qxF "$c" || die "no category $c"
  (
    flock 9
    ordered_cats | awk -v c="$c" -v s="$2" '
      function parent(x) { return sub("/[^/]*$", "", x) ? x : "" }
      { r[NR] = $0; if ($0 == c) i = NR }
      END {
        for (j = i + s; j >= 1 && j <= NR; j += s) if (parent(r[j]) == parent(c)) { t = r[i]; r[i] = r[j]; r[j] = t; break }
        for (k = 1; k <= NR; k++) print r[k] }' > "$ORDER.tmp" && mv "$ORDER.tmp" "$ORDER"
  ) 9> "$DB.lock"
}

cmd="${1:-list}"; shift || true
case "$cmd" in
  add)
    cwd="$PWD"; cat=''; after=''
    while :; do
      case "${1:-}" in
        --cwd) cwd="$2"; shift 2 ;;
        --cat) cat=$(clean_cat "$2"); shift 2 ;;
        --after) after=$(clean_after '' "$2") || exit 1; shift 2 ;;
        *) break ;;
      esac
    done
    if [ $# -gt 0 ]; then text="$*"; else text=$(cat); fi
    text=$(oneline "$text")
    [ -n "$text" ] || die "empty item"
    (
      flock 9
      # the recycle bin counts too, or a restored item could share its id with a newer one
      id=$(awk -F'\t' '$1+0>m{m=$1+0} END{print m+1}' "$DB" "$BIN")
      now=$(date +%s)
      printf '%s\ttodo\t%s\t%s\t\t%s\t%s\t%s\t\t%s\n' "$id" "$now" "$now" "$cwd" "$text" "$cat" "$after" >> "$DB"
      printf '#%s %s%s%s\n' "$id" "${cat:+[$cat] }" "${after:+(after #${after//,/ #}) }" "$text"
      # detached: the title lands a few seconds later, add returns now
      setsid bash "${BASH_SOURCE[0]}" autotitle "$id" </dev/null >/dev/null 2>&1 9>&- &
    ) 9> "$DB.lock" ;;

  list)
    case "${1:-}" in
      --all) cat "$DB" ;;
      --bin) cat "$BIN" ;;
      *) awk -F'\t' '$2!="done" && $2!="canceled"' "$DB" ;;
    esac ;;
  cats) ordered_cats ;;
  mkcat)
    c=$(clean_cat "${1:-}"); [ -n "$c" ] || die "empty category"
    grep -qxF "$c" "$CATS" || printf '%s\n' "$c" >> "$CATS" ;;
  rmcat)
    c=$(clean_cat "${1:-}"); [ -n "$c" ] || die "empty category"
    under() { awk -v c="$c" '$0==c || index($0, c "/")==1'; }
    busy=$(awk -F'\t' '$2!="done" && $2!="canceled"{print $8}' "$DB" | under | sort -u | paste -sd' ')
    [ -z "$busy" ] || die "open items are still filed under $busy, move them first"
    (
      flock 9
      for f in "$CATS" "$ORDER"; do
        awk -v c="$c" '!($0==c || index($0, c "/")==1)' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
      done
    ) 9> "$DB.lock" ;;

  mvcat)
    from=$(clean_cat "${1:-}"); to=$(clean_cat "${2:-}")
    [ -n "$from" ] && [ -n "$to" ] || die "usage: mvcat PATH NEW"
    ordered_cats | grep -qxF "$from" || die "no category $from"
    [[ "$to/" != "$from/"* ]] || die "$to is $from or under it"
    # done and canceled items too, so the history keeps the name; a line merged into an existing one keeps the first place
    (
      flock 9
      awk -F'\t' -v OFS='\t' -v f="$from" -v t="$to" -v now="$(date +%s)" '
        $8 == f || index($8, f "/") == 1 { $8 = t substr($8, length(f) + 1); $4 = now } { print }' "$DB" > "$DB.tmp" \
        && mv "$DB.tmp" "$DB"
      for x in "$CATS" "$ORDER"; do
        awk -v f="$from" -v t="$to" '$0 == f || index($0, f "/") == 1 { $0 = t substr($0, length(f) + 1) } !seen[$0]++' "$x" \
          > "$x.tmp" && mv "$x.tmp" "$x"
      done
    ) 9> "$DB.lock" ;;
  catup)   reorder_cat "${1:?category}" -1 ;;
  catdown) reorder_cat "${1:?category}" 1 ;;

  start)
    id="${1:?id}"; r=$(row "$id"); [ -n "$r" ] || die "no item #$id"
    # \001, not tab: tab is IFS whitespace and would collapse an empty session
    IFS=$'\001' read -r _ status _ _ session cwd text _ <<< "${r//$'\t'/$'\001'}"
    [ "$status" != done ] && [ "$status" != canceled ] || die "#$id is $status, reopen it first"
    [ -n "${TMUX:-}" ] || die "not inside tmux"
    # the window, not state/<session>.tsv: a chat killed without SessionEnd leaves that file behind
    tmux list-windows -a -F '#{window_name}' | grep -qxF "todo-$id" && die "#$id is already open in a live chat"
    [ -d "$cwd" ] || cwd="$HOME"
    # a chat that already worked on the item is resumed, not restarted
    if [ -n "$session" ]; then run=$(printf '%q -r %q' "$CLAUDE_BIN" "$session")
    else run=$(printf '%q %q' "$CLAUDE_BIN" "[todo #$id] $text"); fi
    tmux new-window -c "$cwd" -n "todo-$id" -e "TODO_ID=$id" "$run" || die "tmux refused the window"
    # an item whose PR is in review or to merge keeps that status when its chat resumes
    [ "$status" != todo ] || set_fields "$id" doing "" ;;

  done)   set_fields "${1:?id}" done "" ;;
  cancel) set_fields "${1:?id}" canceled "" ;;
  reopen) set_fields "${1:?id}" todo "" ;;
  review) set_fields "${1:?id}" review "" ;;
  merge)  set_fields "${1:?id}" merge "" ;;
  link)   st=$(row "${1:?id}" | cut -f2); set_fields "$1" "$([ "$st" = todo ] && echo doing)" "${2:?session id}" ;;
  move)
    id="${1:?id}"; [ -n "$(row "$id")" ] || die "no item #$id"
    (
      flock 9
      awk -F'\t' -v OFS='\t' -v id="$id" -v c="$(clean_cat "${2:-}")" -v now="$(date +%s)" '
        $1==id { $8 = c; $4 = now } { print }' "$DB" > "$DB.tmp" && mv "$DB.tmp" "$DB"
    ) 9> "$DB.lock" ;;
  up)   reorder "${1:?id}" -1 ;;
  down) reorder "${1:?id}" 1 ;;
  pos)  place "${1:?id}" "${2:?position}" ;;
  title) id="${1:?id}"; shift; set_col "$id" 9 "$(oneline "$*")" ;;
  after) id="${1:?id}"; shift; v=$(clean_after "$id" "$*") || exit 1; set_col "$id" 10 "$v" ;;
  links) id="${1:?id}"; shift; set_col "$id" 11 "$(oneline "$*" | tr -s ' ')" ;;
  edit)
    id="${1:?id}"; shift; text=$(oneline "$*")
    [ -n "$text" ] || die "empty description"
    # the old title described the old text: clear it and let Haiku write the new one
    set_col "$id" 7 "$text"; set_col "$id" 9 ""
    setsid bash "${BASH_SOURCE[0]}" autotitle "$id" </dev/null >/dev/null 2>&1 & ;;
  autotitle)
    [ $# -gt 0 ] || set -- $(awk -F'\t' '$2!="done" && $2!="canceled" && $9==""{print $1}' "$DB")
    for id in "$@"; do
      t=$(oneline "$(gen_title "$(row "$id" | cut -f7)")")
      # a title typed while Haiku ran wins
      [ -n "$t" ] && [ -z "$(row "$id" | cut -f9)" ] && set_col "$id" 9 "$t"
    done ;;
  rm)      move_row "$DB" "$BIN" "${1:?id}" ;;
  restore) move_row "$BIN" "$DB" "${1:?id}" "in the recycle bin" ;;
  purge)
    (
      flock 9
      awk -F'\t' -v id="${1:-}" 'id != "" && $1 != id' "$BIN" > "$BIN.tmp" && mv "$BIN.tmp" "$BIN"
    ) 9> "$DB.lock" ;;

  *) die "unknown command '$cmd' (add, list, cats, mkcat, rmcat, mvcat, catup, catdown, start, review, merge, done, cancel, reopen, rm, restore, purge, link, links, move, up, down, pos, title, after, edit, autotitle)" ;;
esac
