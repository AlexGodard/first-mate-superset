#!/usr/bin/env bash
# Compat delegate — the pin store moved to the machine-level launcher
# ~/.local/bin/superset-launch (state: ~/.local/state/superset-launch/).
# Usage unchanged: fm-model-pin.sh set|take <worktree> [args…]
exec "$HOME/.local/bin/superset-launch" pin "$@"
