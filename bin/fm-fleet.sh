#!/usr/bin/env bash
# Fleet status digest for the first mate's watcher. Scans every Superset worktree
# for a .firstmate/meta + .firstmate/status pair (written by crewmates) and prints
# one line per crew member with its latest reported state.
#
# Usage:
#   fm-fleet.sh            # one line per crew member: <state> <project> <kind> <branch> :: <last line>
#   fm-fleet.sh --raw      # also print the worktree path
#   fm-fleet.sh --attention  # only crew needing the first mate (done|blocked|needs-decision|failed)
#   fm-fleet.sh --mine     # only crew this session owns (meta owner == $FM_OWNER)
#
# --mine scopes the fleet so concurrent supervisors never act on each other's crew
# (there is no supervisor mutex -- many run in parallel; crew ownership is the only
# coordination). The owner id is this session's harness pid: resolved from
# $FM_OWNER, else derived via `fm-lock.sh id`
# (stable across the session, so no env export needed). Crew owned by others is
# hidden, with a stderr note of the count so nothing is silently dropped. Without
# --mine the view is global (every supervisor's crew) -- an overview, not for acting.
#
# Worktree root defaults to ~/.superset/worktrees; override with SUPERSET_WORKTREES.
# Output is the heartbeat the first mate reads each wake; states that demand action:
#   done            deliver per the project's mode (PR / local merge / report)
#   needs-decision  relay options to the captain
#   blocked         unblock the crewmate
#   failed          inspect and recover
#   paused          known external wait; watcher resurfaces it on a long cadence
set -eu

ROOT="${SUPERSET_WORKTREES:-$HOME/.superset/worktrees}"
RAW=0 ATTN=0 MINE=0
for a in "$@"; do
  case "$a" in
    --raw) RAW=1 ;;
    --attention) ATTN=1 ;;
    --mine) MINE=1 ;;
    *) echo "usage: fm-fleet.sh [--raw] [--attention] [--mine]" >&2; exit 2 ;;
  esac
done
OWNER="${FM_OWNER:-}"
if [ "$MINE" = 1 ] && [ -z "$OWNER" ]; then
  OWNER=$("$(dirname "$0")/fm-lock.sh" id 2>/dev/null) || true
  [ -n "$OWNER" ] || { echo "error: --mine: set FM_OWNER or run inside the supervisor session (fm-lock.sh id failed)" >&2; exit 2; }
fi

[ -d "$ROOT" ] || { echo "no worktree root at $ROOT" >&2; exit 0; }

found=0 hidden=0
# Crewmate marker is .firstmate/meta anywhere under the worktree root.
while IFS= read -r meta; do
  [ -n "$meta" ] || continue
  dir=$(dirname "$(dirname "$meta")")          # .../worktree
  status="$dir/.firstmate/status"
  get() { grep -m1 "^$1=" "$meta" 2>/dev/null | cut -d= -f2-; }
  if [ "$MINE" = 1 ] && [ "$(get owner)" != "$OWNER" ]; then
    hidden=$((hidden+1)); continue           # belongs to another supervisor
  fi
  project=$(get project); kind=$(get kind); branch=$(get branch)
  [ -n "$project" ] || project="?"
  [ -n "$kind" ] || kind="?"
  [ -n "$branch" ] || branch="-"
  if [ -f "$status" ]; then
    last=$(grep -v '^[[:space:]]*$' "$status" | tail -1)
  else
    last="(no status yet)"
  fi
  state=${last%%:*}
  [ "$state" = "$last" ] && state="working"   # no colon -> treat as working

  # Surface a failed provisioning run (fm-provision.sh marker): the crew may
  # still be working, but UI evidence is doomed until the first mate intervenes,
  # so it always counts as needing attention.
  if [ -f "$dir/.firstmate/provision-failed" ]; then
    last="$last  [PROVISION-FAILED: dev servers cannot boot — see .firstmate/provision.log]"
  fi

  if [ "$ATTN" = 1 ]; then
    case "$state" in
      done|blocked|needs-decision|failed) ;;
      *) [ -f "$dir/.firstmate/provision-failed" ] || continue ;;
    esac
  fi
  found=$((found+1))
  if [ "$RAW" = 1 ]; then
    printf '%-14s %-22s %-6s %-28s :: %s\t[%s]\n' "$state" "$project" "$kind" "$branch" "$last" "$dir"
  else
    printf '%-14s %-22s %-6s %-28s :: %s\n' "$state" "$project" "$kind" "$branch" "$last"
  fi
done < <(find "$ROOT" -maxdepth 8 \( -name node_modules -o -name .git \) -prune -o \
  -type f -path '*/.firstmate/meta' -print 2>/dev/null | sort)

[ "$found" = 0 ] && echo "(no crew in flight)"
[ "$hidden" -gt 0 ] && echo "($hidden crew owned by other supervisors hidden; drop --mine to see all)" >&2
exit 0
