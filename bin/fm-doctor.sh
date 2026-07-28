#!/usr/bin/env bash
# Superset-only first-mate diagnostics. No upstream backend selection/install.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin"; FAIL=0; WARN=0
ok(){ printf 'ok    %s\n' "$1"; }
warn(){ WARN=$((WARN+1)); printf 'warn  %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }

command -v superset >/dev/null 2>&1 && ok "Superset CLI: $(superset --version 2>/dev/null | head -1)" || bad "Superset CLI not found"
if command -v superset >/dev/null 2>&1; then
  superset status >/dev/null 2>&1 && ok "Superset host/auth reachable" || bad "Superset status failed (host stopped or CLI not authenticated)"
  AGENTS=$(superset agents list --local --json 2>/dev/null || true)
  for label in 'Claude' 'Codex'; do
    printf '%s' "$AGENTS" | grep -Fq "$label" && ok "custom agent: $label" || warn "custom agent not visible: $label"
  done
fi
for cmd in python3 git openssl; do command -v "$cmd" >/dev/null 2>&1 && ok "dependency: $cmd" || bad "missing dependency: $cmd"; done
command -v shellcheck >/dev/null 2>&1 && ok "optional lint: shellcheck" || warn "shellcheck unavailable (tests still run without lint)"
[ -f "$ROOT/registry.md" ] && ok "registry present" || bad "registry missing: $ROOT/registry.md"
"$BIN/fm-watch-guard.sh" >/dev/null 2>&1 && ok "watcher queue/liveness healthy" || warn "watcher needs attention; run fm-watch-guard.sh for details"
printf '\nsummary: %s failure(s), %s warning(s)\n' "$FAIL" "$WARN"
[ "$FAIL" -eq 0 ]
