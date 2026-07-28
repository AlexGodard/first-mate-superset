#!/usr/bin/env bash
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPECTED=${FM_SHELLCHECK_VERSION:-0.11.0}
command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck not installed; skipping"; exit 0; }
ACTUAL=$(shellcheck --version | awk '/^version:/ {print $2}')
[ "$ACTUAL" = "$EXPECTED" ] || { echo "shellcheck version mismatch: expected $EXPECTED, got $ACTUAL" >&2; exit 1; }
shellcheck --severity=error -x "$ROOT"/bin/*.sh
