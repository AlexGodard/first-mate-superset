#!/usr/bin/env bash
# Resolve a worktree's existing project-memory file. Prints its path, or nothing
# if neither file exists. Read-only: never creates, moves, overwrites, or symlinks.
#   - AGENTS.md exists      -> "AGENTS.md"
#   - only CLAUDE.md exists -> "CLAUDE.md"
#   - neither exists        -> (no output)
# Usage: fm-ensure-memory.sh [worktree-dir]
set -eu

DIR=${1:-.}
[ -d "$DIR" ] || { echo "error: not a directory: $DIR" >&2; exit 1; }
cd "$DIR"

if [ -e AGENTS.md ]; then
  echo "AGENTS.md"
  exit 0
fi
if [ -e CLAUDE.md ]; then
  echo "CLAUDE.md"
  exit 0
fi
exit 0
