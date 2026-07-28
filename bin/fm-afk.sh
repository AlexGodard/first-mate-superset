#!/usr/bin/env bash
# Superset AFK lifecycle helper adapted from firstmate#490.
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="${FM_STATE_OVERRIDE:-$ROOT/state}"
FLAG="$STATE/.afk"
case "${1:-status}" in
  start)
    mkdir -p "$STATE"; date +%s > "$FLAG"
    echo "afk: active; arm $ROOT/bin/fm-watch-bg.sh"
    ;;
  stop)
    rm -f "$FLAG"
    "$ROOT/bin/fm-wake-drain.sh" || true
    echo "afk: inactive"
    ;;
  status)
    if [ -f "$FLAG" ]; then echo "afk: active since $(cat "$FLAG")"; else echo "afk: inactive"; fi
    ;;
  *) echo "usage: fm-afk.sh {start|stop|status}" >&2; exit 2 ;;
esac
