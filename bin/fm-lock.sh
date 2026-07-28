#!/usr/bin/env bash
# Session identity for the first mate.
#
# `id` -> this session's stable owner id (the harness PID, walked from the
# shell's ancestry). Used by fm-fleet.sh --mine and the watcher to keep
# concurrent supervisors' crews disjoint -- the only cross-supervisor
# coordination first-mate needs. Never a mutex; never blocks: many supervisors
# and many crewmates run at once, and ownership (not locking) keeps their
# fleets disjoint.
#
# Usage: fm-lock.sh id
set -u

# Known harness command names; extend when a new adapter is verified.
HARNESS_RE='claude|codex|opencode|^pi$'

harness_pid() {
  local pid=$$ comm args
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if printf '%s' "$(basename "$comm")" | grep -qE "$HARNESS_RE"; then
      echo "$pid"; return 0
    fi
    # Bare interpreter (e.g. node): match the harness name in its script path.
    case "$comm" in
      *node*|*python*) printf '%s' "$args" | grep -qE "$HARNESS_RE" && { echo "$pid"; return 0; } ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

case "${1:-}" in
  id)
    me=$(harness_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
    echo "$me"; exit 0
    ;;
  *) echo "usage: fm-lock.sh id" >&2; exit 2 ;;
esac
