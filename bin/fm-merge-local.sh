#!/usr/bin/env bash
# Local-only delivery: fast-forward a project's default branch to a crewmate's
# branch. This is the first mate's merge authority applied locally instead of via
# a GitHub PR -- the one sanctioned state-changing git op over a project checkout.
# It is narrow: clean fast-forward only, refuses a diverged or dirty tree.
#
# Usage: fm-merge-local.sh <project-main-repo-path> <branch>
#   e.g. fm-merge-local.sh "$HOME/.superset/projects/payroll" fm/add-foo
#
# Superset worktrees share the project's .git, so the branch the crewmate committed
# is already visible from the main checkout -- no fetch needed.
set -eu

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ=${1:?usage: fm-merge-local.sh <project-main-repo-path> <branch>}
BRANCH=${2:?usage: fm-merge-local.sh <project-main-repo-path> <branch>}
[ -d "$PROJ/.git" ] || git -C "$PROJ" rev-parse --git-dir >/dev/null 2>&1 || {
  echo "error: $PROJ is not a git repo" >&2; exit 1; }

default_branch() {
  local ref
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then echo "${ref#origin/}"; return 0; fi
  for b in main master; do
    git -C "$PROJ" show-ref --verify --quiet "refs/heads/$b" && { echo "$b"; return 0; }
  done
  return 1
}

git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null \
  || { echo "error: branch $BRANCH does not exist in $PROJ" >&2; exit 1; }

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ" >&2; exit 1; }

cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
[ "$cur" = "$DEFAULT" ] || { echo "error: $PROJ is on '$cur', expected default branch '$DEFAULT'; cannot merge safely" >&2; exit 1; }
[ -z "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ] \
  || { echo "error: $PROJ has a dirty working tree; refusing to merge" >&2; exit 1; }

git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$BRANCH" || {
  echo "REFUSED: $BRANCH is not a fast-forward of $DEFAULT (it has diverged)." >&2
  echo "Have the crewmate rebase $BRANCH onto $DEFAULT, then retry." >&2
  exit 1; }

before=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
git -C "$PROJ" merge --ff-only "$BRANCH" >/dev/null
after=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
"$BIN/fm-record-landed.sh" "$(basename "$PROJ")" "merged $BRANCH into local $DEFAULT" "$after" || true
echo "merged $BRANCH into local $DEFAULT ($before -> $after) in $PROJ"
