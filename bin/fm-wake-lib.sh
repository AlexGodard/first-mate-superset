#!/usr/bin/env bash
# Durable Superset watcher delivery, conceptually ported from firstmate#444/#490.
# The background-task completion remains the transport; this queue is the
# recovery record when that completion notification or a supervisor turn is lost.

fm_wake_state_dir() {
  printf '%s' "${FM_STATE_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/state}"
}

fm_wake_owner() {
  local owner=${FM_OWNER:-}
  if [ -z "$owner" ]; then
    owner=$("$(dirname "${BASH_SOURCE[0]}")/fm-lock.sh" id 2>/dev/null || true)
  fi
  printf '%s' "${owner:-global}" | tr -cd 'A-Za-z0-9_.-'
}

fm_wake_queue_path() { printf '%s/.wake-queue.%s' "$(fm_wake_state_dir)" "${1:-$(fm_wake_owner)}"; }
fm_wake_beat_path() { printf '%s/.watch-beat.%s' "$(fm_wake_state_dir)" "${1:-$(fm_wake_owner)}"; }

fm_wake_heartbeat() {
  local state owner
  state=$(fm_wake_state_dir); owner=${1:-$(fm_wake_owner)}
  mkdir -p "$state"
  date +%s > "$(fm_wake_beat_path "$owner")"
}

fm_wake_enqueue() { # <owner> <reason...>
  local owner=$1 state queue lock reason
  shift
  state=$(fm_wake_state_dir); queue=$(fm_wake_queue_path "$owner"); lock="$queue.lock"
  reason=$(printf '%s' "$*" | tr '\r\n\t' '   ' | cut -c1-4000)
  mkdir -p "$state"
  # mkdir is the portable append lock; recover a dead/stale lock conservatively.
  local n=0
  until mkdir "$lock" 2>/dev/null; do
    local held
    held=$(cat "$lock/pid" 2>/dev/null || true)
    if [ -n "$held" ] && ! kill -0 "$held" 2>/dev/null; then
      rm -f "$lock/pid"; rmdir "$lock" 2>/dev/null || true
      continue
    fi
    n=$((n + 1)); [ "$n" -lt 30 ] || { echo "warn: wake queue busy: $queue" >&2; return 1; }
    sleep 0.1
  done
  printf '%s\n' "$$" > "$lock/pid"
  trap 'rm -f "$lock/pid"; rmdir "$lock" 2>/dev/null || true' RETURN
  printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$reason" >> "$queue"
  rm -f "$lock/pid"; rmdir "$lock" 2>/dev/null || true
  trap - RETURN
}

fm_wake_has_pending() { [ -s "$(fm_wake_queue_path "${1:-$(fm_wake_owner)}")" ]; }
