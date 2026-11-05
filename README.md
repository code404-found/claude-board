# claude-board

A tmux board for Claude Code: one todo list shared by the board and every
Claude session. An item starts a chat in its own tmux window, a chat adds the
follow-ups it leaves behind, and hooks tell the board which chats are live.

Six bash scripts, two skills, six hooks, no daemon. Packaged as a Claude Code
plugin.

## What it shows

Open it with `prefix b` in tmux (or run `scripts/board.sh` outside tmux).

- `o` todos: the open items as a category tree, each with a status mark and a
  letter. Pick one to read it in full, then start or resume its chat, jump to
  the window where it runs, mark it in review, to merge, done or canceled,
  edit its title or description, file it under a category, move it in its
  category, set the items it waits on, or open its links. `A` adds an item,
  `/` filters, `H` shows the closed ones, `T` the recycle bin, `?` the other
  keys.
- `t` history: past conversations, newest first, with their directory and
  branch. A letter resumes one in a new window, `/` filters.
- `w` windows: every tmux window and what runs in it. A Claude window shows
  the prompt that opened it, or "never used" when nothing was typed.
- `h` help: the key reference.

Status marks: `○` todo, `⊘` blocked by an open item it waits on, `●` in a live
chat, `◐` paused (its chat is not running), `◇` in review, `◆` to merge,
`✓` done, `✗` canceled, `⌧` in the recycle bin.

## From a chat

- `/board:todoa <text>` adds an item, with the directory the work belongs in,
  its category and the open items it waits on. `/board:todoa` alone lists the
  work left in the conversation and asks which items to add.
- `/board:todos` lists the items and starts one. `/board:todos <id>`,
  `/board:todos done`, `cancel`, `review`, `merge`, `move`, `after` do what
  their names say; `done`, `cancel`, `review` and `merge` default to the item
  the chat works on.
- A chat started from the board receives `[todo #N] <text>` as its first
  prompt and is recorded as the item's chat. Starting the item again resumes
  that chat.

## Install

Needs bash 5, tmux 3.2 or later, jq, fzf, flock (util-linux) and the Claude
Code CLI on the PATH. Titles are written by a headless `claude -p --model
haiku` run a few seconds after an item is added.

```
claude plugin marketplace add code404-found/claude-board
claude plugin install board@claude-board
```

That installs the six hooks (every lifecycle event runs `collect.sh`) and the
`/board:todoa` and `/board:todos` skills. Sessions already open keep the hooks
they started with: restart them.

Then by hand:

1. Bind the board in your tmux config and source it. The plugin lives under
   `~/.claude/plugins/`; find its path with `claude plugin details board`, or
   point the binding at a checkout of this repository:

   ```
   bind b run-shell "~/claude-board/scripts/board.sh"
   ```

2. Teach Claude the list, in `~/.claude/CLAUDE.md`:

   ```markdown
   # Todo list

   The board plugin's `scripts/todo.sh` keeps the todo list shown on the tmux
   board (prefix b, then o). `/board:todoa` adds an item, `/board:todos`
   starts one.

   - A turn that ends with work left undone (a follow-up you reported, a step
     you skipped, a bug you noticed out of scope) ends with an
     `AskUserQuestion`, multiSelect, offering to add those items to the todo
     list. Add each chosen one as `/board:todoa` does. No question when
     nothing is left.
   - A chat whose first prompt opens with `[todo #N]` works on item N. When
     its work is finished, ask whether to mark it done, and on yes run
     `todo.sh done N`.
   ```

3. Optional, `~/.claude/orchestrator/config`, a shell file the scripts source:

   ```sh
   CLAUDE_ORCH_ISSUE_URL=https://example.atlassian.net/browse/  # issue links on category segments such as PROJ-12
   CLAUDE_BIN=/path/to/claude                                    # when claude is not on the PATH tmux has
   EDITOR=nvim                                                   # Ctrl-X Ctrl-E in a prompt
   ```

## Files

In the plugin:

| Path | Role |
|---|---|
| `scripts/board.sh` | opens or jumps to the board window; runs the dashboard directly outside tmux |
| `scripts/dashboard.sh` | the board itself: the todos, history, windows and help screens |
| `scripts/todo.sh` | the todo list CLI, the only writer of `todos.tsv`; its header comment documents every command |
| `scripts/collect.sh` | the hook entrypoint: one TSV event line per hook call, never blocking a session |
| `scripts/history.sh` | past conversations, from the Claude transcripts, cached per file |
| `scripts/windows.sh` | the tmux window inventory |
| `hooks/hooks.json` | the six lifecycle events that run `collect.sh` |
| `skills/todoa`, `skills/todos` | the two skills |

Data, in `~/.claude/orchestrator` (`CLAUDE_ORCH_DIR` to move it; the state
and cache directories can move on their own with `CLAUDE_ORCHESTRATOR_STATE`
and `CLAUDE_ORCH_CACHE`):

| File | Content |
|---|---|
| `todos.tsv` | one item per row: id, status, created, updated, session, cwd, text, category, title, after, links |
| `trash.tsv` | the recycle bin, same columns |
| `categories`, `categories.order` | the categories made by hand, and the order of siblings |
| `config` | the optional settings above |
| `state/<session>.tsv` | the hook events of one live session, deleted at its end |
| `cache/` | the board's caches, safe to delete |

`todo.sh` serialises every write with `flock`, so the board and concurrent
hooks never corrupt the list.

## How a chat is found

Every hook event records the session's `TMUX_PANE` and its parent pid. The
pane id can be stale, so the board walks the process tree up from the pid
until it meets a live tmux pane: that mapping is exact.

## Uninstall

`claude plugin uninstall board@claude-board` removes the hooks and skills.
Then remove the tmux binding, the CLAUDE.md section, and
`~/.claude/orchestrator` if the list is no longer wanted.

## License

MIT, see `LICENSE`.
