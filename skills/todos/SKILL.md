---
name: todos
description: List the board's todo items and start one in a new chat, or mark one done or canceled. Use when the user invokes /todos.
argument-hint: [id | done [id] | cancel [id] | review [id] | merge [id] | move id [path] | after id [ids]]
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/todo.sh:*), AskUserQuestion
---

# /todos: start or close a todo

Script: `${CLAUDE_PLUGIN_ROOT}/scripts/todo.sh`. Arguments: `$ARGUMENTS`

- `<id>`: run `todo.sh start <id>`. It opens a tmux window with a new chat on
  the item, or resumes the chat that already worked on it. Report the window
  name `todo-<id>`, or the script's error as printed.
- `done [id]`: run `todo.sh done <id>`. Without an id, use the item this chat
  works on, the `N` of the `[todo #N]` that opens its first prompt; with none,
  ask which.
- `cancel [id]`: run `todo.sh cancel <id>`, which closes the item as canceled
  rather than done. The id defaults as for `done`.
- `review [id]` or `merge [id]`: run `todo.sh review <id>` when the item's PR
  waits for approval, `todo.sh merge <id>` when it is approved and waits to be
  completed. The id defaults as for `done`.
- `move <id> [path]`: run `todo.sh move <id> <path>`, which files the item
  under that category path, or uncategorises it without one.
- `after <id> [ids]`: run `todo.sh after <id> <ids>`, which sets the items it
  waits on, such as `12,15`, or clears them without ids.
- Nothing: run `todo.sh list` (TSV: id, status, created, updated, session,
  cwd, text, category, title, after) and show the items as a table of id,
  status, category, title, the text when the title is empty, and the open ids
  of `after` it waits on, grouped by category. Then ask
  through `AskUserQuestion` which one to start, the four oldest `todo` items as
  options, and start the chosen one as above.
