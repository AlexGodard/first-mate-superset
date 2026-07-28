#!/usr/bin/env bash
# Compat delegate — the agents' launch Command is now the machine-level
# ~/.local/bin/superset-launch (not part of this skill). The Superset "Claude"
# agent points there directly; this shim keeps any stale references working.
# Usage: fm-launch.sh claude|codex [flags…]  (legacy `ccs <profile>`/`ccsxp`
# spellings still accepted by superset-launch)
exec "$HOME/.local/bin/superset-launch" "$@"
