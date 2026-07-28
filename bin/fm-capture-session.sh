#!/usr/bin/env bash
# Capture a crewmate's live Superset workspace id + terminal (agent PTY) id from
# the `superset ws create --json` payload into a sidecar the live-send path reads.
#
# Background: `superset agents send <terminalId> --workspace <id>` (the fork's new
# CLI command) injects input into the RUNNING desktop session -- but the terminalId
# is ONLY exposed at create time (agents[].sessionId for a kind:"terminal" agent);
# there is no "list running sessions" CLI. So dispatch must capture it now. We write
# a `.firstmate/superset` sidecar (NOT `.firstmate/meta`, which the crewmate seeds
# and would overwrite) holding `workspace=` + `terminalId=`. fm-send.sh's FM_LIVE_SEND
# path reads it to target the live session; absent ⇒ it falls back to fork-resume.
#
# Usage:
#   superset ws create … --json | fm-capture-session.sh <worktree-dir>
#   fm-capture-session.sh <worktree-dir> < ws-create.json
set -eu

WT="${1:-}"
[ -n "$WT" ] || { echo "usage: fm-capture-session.sh <worktree-dir> < ws-create.json" >&2; exit 2; }

JSON=$(cat)
# One value per line (empty line = empty field) — tab/space separators collapse
# empty fields under IFS whitespace splitting and misassign the rest.
PARSED=$(printf '%s' "$JSON" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print("\n\n"); sys.exit(0)
ws = (d.get("workspace") or {}).get("id", "")
tid = ""
err = ""
for a in (d.get("agents") or []):
    # Server maps a failed launch to {ok: false, error} instead of failing the
    # create (workspaces.ts dispatchSugarAgents) — surface it, do not infer
    # success from workspace creation alone.
    if a.get("ok") is False:
        err = (a.get("error") or "unknown agent launch error").replace("\n", " ")
        continue
    if a.get("kind") == "terminal" and a.get("sessionId"):
        tid = a["sessionId"]
print(ws); print(tid); print(err)
')
WSID=$(printf '%s\n' "$PARSED" | sed -n 1p)
TID=$(printf '%s\n' "$PARSED" | sed -n 2p)
LAUNCH_ERR=$(printf '%s\n' "$PARSED" | sed -n 3p)

[ -n "${WSID:-}" ] || { echo "fm-capture-session: no workspace.id in ws-create json (not captured)" >&2; exit 3; }

mkdir -p "$WT/.firstmate"
{
  printf 'workspace=%s\n' "$WSID"
  [ -n "${TID:-}" ] && printf 'terminalId=%s\n' "$TID"
} > "$WT/.firstmate/superset"

if [ -n "${LAUNCH_ERR:-}" ]; then
  echo "fm-capture-session: AGENT LAUNCH FAILED: $LAUNCH_ERR" >&2
  echo "captured workspace=$WSID terminalId=${TID:-<none>} -> $WT/.firstmate/superset"
  exit 4
fi

echo "captured workspace=$WSID terminalId=${TID:-<none>} -> $WT/.firstmate/superset"
