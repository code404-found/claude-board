---
name: todoa
description: Add an item to the todo list shown on the tmux board. Use when the user invokes /todoa.
argument-hint: <what to do>
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/todo.sh:*), AskUserQuestion
---

# /todoa: add a todo

Item text: `$ARGUMENTS`

- With text: add it as one item. Pass the text on stdin through a quoted
  heredoc, so quotes and `$` in it survive, and record the directory the work
  belongs in (the repo the conversation is about, else the current one), and
  its category: a `/`-separated path the board draws as a tree, such as
  `8677` or `8677/CA-6`. Take it from the ticket the item serves, its
  number alone, reusing a path `todo.sh cats` already lists. Omit `--cat` when
  the item serves no ticket.
  Then read `todo.sh list` (TSV: id, status, created, updated, session, cwd,
  text, category, title, after) and pass `--after` with the ids of the open
  items that must be finished before this one can start: a fix it builds on, a
  PR it needs merged, a decision it needs taken. Items added in the same run
  can wait on each other, so add the earlier one first. Omit `--after` when
  nothing blocks it: a related item that does not block it is no dependency.

  ```
  ${CLAUDE_PLUGIN_ROOT}/scripts/todo.sh add --cwd <dir> --cat <path> --after <id,id> <<'TODO'
  <text>
  TODO
  ```

- Without text: list the work still left in this conversation and ask through
  `AskUserQuestion`, multiSelect, which items to add, then add each chosen one
  as above. Write each item so it stands alone in a new chat: name the repo,
  the file or the ticket it is about.

Answer with the `#id text` lines the script printed, nothing else.
