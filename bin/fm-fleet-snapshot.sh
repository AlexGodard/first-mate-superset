#!/usr/bin/env bash
# Stable bounded fleet JSON for automation and /bearings.
set -eu
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$BIN/fm-fleet-snapshot.py" "$@"
