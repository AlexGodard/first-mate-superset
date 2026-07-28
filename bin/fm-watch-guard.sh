#!/usr/bin/env bash
# Read-only watcher-chain health check. Ported conceptually from firstmate#444.
set -eu
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$BIN/fm-wake-lib.sh"
OWNER=${FM_OWNER:-$(fm_wake_owner)}
MAX=${FM_WATCH_STALE_SECS:-1800}
NOW=$(date +%s)
BEAT=$(cat "$(fm_wake_beat_path "$OWNER")" 2>/dev/null || echo 0)
case "$BEAT" in ''|*[!0-9]*) BEAT=0 ;; esac
FLEET=$(FM_OWNER="$OWNER" "$BIN/fm-fleet.sh" --mine 2>/dev/null || true)
if fm_wake_has_pending "$OWNER"; then
  echo "warning: pending first-mate watcher events exist; run: $BIN/fm-wake-drain.sh" >&2
  exit 1
fi
if printf '%s\n' "$FLEET" | grep -qv '^('; then
  if [ "$BEAT" -eq 0 ] || [ $((NOW - BEAT)) -gt "$MAX" ]; then
    echo "warning: crew is in flight but watcher heartbeat is missing/stale; re-arm fm-watch-bg.sh" >&2
    exit 1
  fi
fi
exit 0
