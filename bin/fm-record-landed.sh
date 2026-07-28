#!/usr/bin/env bash
# Append a durable delivery record for /bearings after work is actually landed.
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="${FM_STATE_OVERRIDE:-$ROOT/state}"
[ $# -ge 2 ] || { echo "usage: fm-record-landed.sh <project> <summary> [artifact-url-or-path]" >&2; exit 2; }
mkdir -p "$STATE"
printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "${3:--}" >> "$STATE/landed.tsv"
