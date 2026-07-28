#!/usr/bin/env bash
# fm-progress.sh - granular, read-only progress peek for ONE crew.
#
# fm-crew-state.sh answers "stalled or just silent?" from the status log -- but
# an agent that is INSIDE one long bash call (a 4K render loop, a training
# epoch) physically cannot append .firstmate/status lines mid-call. This helper
# reads every passive progress signal instead, never touching the crew:
#
#   1. status log tail        (.firstmate/status, last 3 events)
#   2. progress file tail     (.firstmate/progress -- opt-in convention: the
#                              crew's long-running loops `tee -a` per-item lines
#                              here, e.g. "tick 3068 rendered (14/26)")
#   3. live processes         (anything whose command references the worktree,
#                              plus ffmpeg/python children -- what is EXECUTING)
#   4. freshest artifacts     (newest non-.git files in the worktree, with age
#                              -- renders/JSONs appearing == real progress)
#
# Usage: fm-progress.sh <worktree-path> [extra-artifact-dir ...]
#        (extra dirs: /tmp scratch dirs the brief points the crew at)
#
# Read-only, no network, bounded; safe to run any time, any crew.

set -uo pipefail
# no -e: tail/find/head SIGPIPE-race harmlessly; every section is best-effort

WT="${1:?usage: fm-progress.sh <worktree-path> [extra-artifact-dir ...]}"
shift || true
[ -d "$WT" ] || { echo "no such worktree: $WT" >&2; exit 1; }

echo "== crew: $WT"

echo "-- status (last 3):"
tail -3 "$WT/.firstmate/status" 2>/dev/null || echo "(no status file)"

if [ -f "$WT/.firstmate/progress" ]; then
  n=$(wc -l < "$WT/.firstmate/progress" | tr -d ' ')
  echo "-- progress file ($n lines, last 5):"
  tail -5 "$WT/.firstmate/progress"
else
  echo "-- progress file: (none -- crew hasn't adopted the convention)"
fi

echo "-- live processes touching the worktree:"
# command lines referencing the worktree path; also long-running ffmpeg/python
# spawned from it (their argv usually carries a path inside it)
PS=$(ps -axo pid,etime,%cpu,command)   # snapshot first so our own pipeline isn't in it
printf '%s\n' "$PS" | grep -F "$WT" | grep -vE "grep|fm-progress|sed s\|" \
  | sed "s|$WT|<wt>|g" | cut -c1-160
[ -z "$(printf '%s\n' "$PS" | grep -F "$WT" | grep -vE "grep|fm-progress|sed s\|")" ] && echo "(none)"
echo "-- freshest artifacts (top 6, non-.git):"
for d in "$WT" "$@"; do
  [ -d "$d" ] || continue
  find "$d" -type f -not -path '*/.git/*' -not -name '.DS_Store' -mmin -180 \
    -exec stat -f '%m %Sm %N' -t '%H:%M:%S' {} + 2>/dev/null
done | sort -rn | head -6 | sed "s|$WT|<wt>|g" | cut -d' ' -f2-

exit 0
