#!/usr/bin/env bash
# Atomically print and clear this supervisor's durable watcher queue.
set -eu
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$BIN/fm-wake-lib.sh"
OWNER=${FM_OWNER:-$(fm_wake_owner)}
if [ "${1:-}" = "--owner" ]; then OWNER=${2:?missing owner}; fi
Q=$(fm_wake_queue_path "$OWNER")
[ -s "$Q" ] || { echo "(no pending watcher wakes)"; exit 0; }
TMP="$Q.drain.$$"
mv "$Q" "$TMP"
cat "$TMP"
rm -f "$TMP"
# A drain is also a bounded recheck of declared external waits.
date +%s > "$(fm_wake_state_dir)/.paused-last-check.$OWNER"
