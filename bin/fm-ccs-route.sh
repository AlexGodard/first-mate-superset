#!/usr/bin/env bash
# Compat delegate — the old single-preset router. Since the claude-swap
# migration (2026-07-27) there is no per-repo wavo/personal instance split and
# no cliproxy pool: every Claude launch goes through the machine-level
# ~/.local/bin/superset-launch, which owns the pin-take, [1m] rewrite, effort
# env, and the gpt-*/codex-* → Codex CLI lane. This shim keeps any stale
# references working. Usage unchanged: fm-ccs-route.sh [flags…]
exec "$HOME/.local/bin/superset-launch" claude "$@"
