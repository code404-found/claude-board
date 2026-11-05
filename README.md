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

One command, on Linux or macOS:

```
curl -fsSL https://raw.githubusercontent.com/code404-found/claude-board/main/install.sh | bash
```

It installs what is missing and skips what is there, so it can run again:

1. bash 5, tmux 3.2 or later, jq, fzf and flock, through apt, dnf, pacman or
   brew;
2. the Claude Code CLI, through its own installer;
3. the plugin, marketplace `code404-found/claude-board` and plugin
   `board@claude-board`: the six hooks (every lifecycle event runs
   `collect.sh`) and the `/board:todoa` and `/board:todos` skills;
4. `~/.local/bin/claude-board`, a launcher that opens the newest installed
   version of the plugin, bound to `prefix b` in your tmux config;
5. the `# Todo list` section of `~/.claude/CLAUDE.md`, which makes every chat
   feed the list. Its text is at the end of `install.sh`.

Sessions already open keep the hooks they started with: restart them. Titles
are written by a headless `claude -p --model haiku` run a few seconds after an
item is added.

Optional, `~/.claude/orchestrator/config`, a shell file the scripts source:

```sh
CLAUDE_ORCH_ISSUE_URL=https://example.atlassian.net/browse/  # issue links on category segments such as PROJ-12
CLAUDE_BIN=/path/to/claude                                    # when claude is not on the PATH tmux has
EDITOR=nvim                                                   # Ctrl-X Ctrl-E in a prompt
```

To work on the board itself, bind `prefix b` to `scripts/board.sh` of a
checkout instead of the launcher.

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
| `install.sh` | the one-command install, skipping every step already in place |
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
Then remove the tmux binding, `~/.local/bin/claude-board`, the CLAUDE.md
section, and `~/.claude/orchestrator` if the list is no longer wanted.

## License

MIT, see `LICENSE`.
