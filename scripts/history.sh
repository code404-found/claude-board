#!/usr/bin/env bash
# Past conversations, newest first, from the Claude transcripts.
#
# Emits TSV: mtime \t session_id \t cwd \t branch \t title
#
# Scanning every transcript costs ~38MB of IO, so results are cached per file
# and only re-read when that file's mtime changes.
set -uo pipefail
PROJ="${CLAUDE_PROJECTS:-$HOME/.claude/projects}"
CACHE="${CLAUDE_ORCH_CACHE:-$HOME/.claude/orchestrator/cache}"
LIMIT="${1:-25}"
mkdir -p "$CACHE" 2>/dev/null
CF="$CACHE/history.tsv"
[ -f "$CF" ] || : > "$CF"

tmp=$(mktemp) || exit 0
trap 'rm -f "$tmp"' EXIT

while IFS= read -r f; do
  [ -s "$f" ] || continue
  mt=$(date -r "$f" +%s 2>/dev/null || echo 0)
  sid=$(basename "$f" .jsonl)

  # reuse the cached row unless the transcript changed since it was built
  cached=$(awk -F'\t' -v s="$sid" -v m="$mt" '$2==s && $1==m{print; exit}' "$CF" 2>/dev/null)
  if [ -n "$cached" ]; then printf '%s\n' "$cached" >> "$tmp"; continue; fi

  # one pass per file: keep the LAST title/cwd/branch seen. The title is
  # rewritten as a conversation develops, and the final line is often an
  # ai-title record carrying no cwd, so neither can be read from tail -1.
  meta=$(awk '
    { if (match($0, /"aiTitle":"[^"]*"/))   t = substr($0, RSTART+11, RLENGTH-12)
      if (match($0, /"cwd":"[^"]*"/))       c = substr($0, RSTART+7,  RLENGTH-8)
      if (match($0, /"gitBranch":"[^"]*"/)) b = substr($0, RSTART+13, RLENGTH-14) }
    END { gsub(/\t/, " ", t); s = sprintf("%c", 1)
          printf "%s%s%s%s%s", t, s, c, s, b }' "$f")
  # \001, not tab: tab is IFS whitespace, so an untitled session would collapse
  # its empty first field and shift cwd into the title.
  IFS=$'\001' read -r title cwd branch <<< "$meta"
  [ -n "${title:-}" ] || title="(untitled)"
  printf '%s\t%s\t%s\t%s\t%s\n' "$mt" "$sid" "${cwd:-}" "${branch:-}" "$title" >> "$tmp"
done < <(find "$PROJ" -name '*.jsonl' -type f 2>/dev/null)

sort -rn "$tmp" > "$CF"
head -n "$LIMIT" "$CF"
