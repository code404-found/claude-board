#!/usr/bin/env bash
# Install the board on this machine: the prerequisites, the Claude Code CLI, the
# plugin, a launcher with its tmux binding, and the todo rule in ~/.claude/CLAUDE.md.
# Every step is skipped when already in place, so the script can run again.
#
# Usage: curl -fsSL https://raw.githubusercontent.com/code404-found/claude-board/main/install.sh | bash
#    or: ./install.sh  from a checkout
set -euo pipefail

MARKETPLACE=code404-found/claude-board
PLUGIN=board@claude-board
LAUNCHER="$HOME/.local/bin/claude-board"

have() { command -v "$1" >/dev/null 2>&1; }
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }
ok()   { printf '  ok    %s\n' "$*"; }
todo() { printf '  add   %s\n' "$*"; }

# 1. Prerequisites, installed in one go through the package manager found.
missing=""
need() { todo "$1"; missing="$missing $2"; }
if have bash && ver_ge "$(bash -c 'echo ${BASH_VERSINFO[0]}')" 5; then ok "bash $(bash -c 'echo ${BASH_VERSION}')"; else need "bash 5" bash; fi
if have tmux && ver_ge "$(tmux -V | grep -oE '[0-9]+\.[0-9]+' | head -1)" 3.2; then ok "$(tmux -V)"; else need "tmux 3.2" tmux; fi
if have jq; then ok jq; else need jq jq; fi
if have fzf; then ok fzf; else need fzf fzf; fi
if have flock; then ok flock; elif have brew; then need flock flock; else need flock util-linux; fi
if [ -n "$missing" ]; then
  sudo=""; [ "$(id -u)" = 0 ] || sudo=sudo
  # shellcheck disable=SC2086  # $missing is a word list on purpose
  if   have apt-get; then $sudo apt-get update -qq && $sudo apt-get install -y $missing
  elif have dnf;     then $sudo dnf install -y $missing
  elif have pacman;  then $sudo pacman -S --noconfirm --needed $missing
  elif have brew;    then brew install $missing
  else printf 'no apt, dnf, pacman or brew: install by hand:%s\n' "$missing" >&2; exit 1
  fi
fi

# 2. The Claude Code CLI, through its own installer.
if have claude; then ok "claude $(claude --version 2>/dev/null | head -1)"
else
  todo "claude"
  curl -fsSL https://claude.ai/install.sh | bash
  export PATH="$HOME/.local/bin:$PATH"
  have claude || { printf 'claude is not on the PATH after its install: open a new shell and run this script again\n' >&2; exit 1; }
fi

# 3. The plugin: six hooks and the two skills.
if claude plugin list 2>/dev/null | grep -q "$PLUGIN"; then ok "plugin $PLUGIN"
else
  todo "plugin $PLUGIN"
  claude plugin marketplace list 2>/dev/null | grep -q "$MARKETPLACE" || claude plugin marketplace add "$MARKETPLACE"
  claude plugin install "$PLUGIN"
fi

# 4. A launcher that finds the installed plugin, whatever its version, and its tmux binding.
if [ -x "$LAUNCHER" ]; then ok "$LAUNCHER"
else
  todo "$LAUNCHER"
  mkdir -p "$(dirname "$LAUNCHER")"
  cat >"$LAUNCHER" <<'EOF'
#!/usr/bin/env bash
# Open the Claude Code board: the newest installed version of the board plugin.
exec bash "$(ls -d "$HOME"/.claude/plugins/cache/claude-board/board/*/scripts/board.sh | sort -V | tail -1)" "$@"
EOF
  chmod +x "$LAUNCHER"
fi
conf="$HOME/.tmux.conf"; [ -f "$conf" ] || [ ! -f "$HOME/.config/tmux/tmux.conf" ] || conf="$HOME/.config/tmux/tmux.conf"
if [ -f "$conf" ] && grep -qE '^bind(-key)? +b ' "$conf"; then ok "tmux prefix b, in $conf"
else
  todo "tmux prefix b, in $conf"
  printf 'bind b run-shell "%s"\n' "$LAUNCHER" >>"$conf"
  tmux source-file "$conf" 2>/dev/null || true
fi

# 5. The rule that makes every chat feed the list.
claude_md="$HOME/.claude/CLAUDE.md"
if [ -f "$claude_md" ] && grep -q '^# Todo list' "$claude_md"; then ok "todo rule in $claude_md"
else
  todo "todo rule in $claude_md"
  mkdir -p "$(dirname "$claude_md")"
  [ ! -s "$claude_md" ] || printf '\n' >>"$claude_md"
  cat >>"$claude_md" <<'EOF'
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
EOF
fi

printf '\nThe board is installed. Restart the Claude sessions already open so they get the hooks.\n'
printf 'Optional settings go in ~/.claude/orchestrator/config, see the README.\n'
