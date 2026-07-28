#!/usr/bin/env bash
# Resolve which Superset CUSTOM AGENT a dispatch should launch.
#
# Since the 2026-07-19 single-profile consolidation there are TWO dispatchable
# agents, both running the machine-level launcher ~/.local/bin/superset-launch:
#
#   Claude superset-launch claude --dangerously-skip-permissions   (Claude Code)
#   Codex  superset-launch codex --dangerously-bypass-approvals-and-sandbox  (Codex CLI)
#
# Older lane-specific agents are gone — scoping happens at the project level,
# not via agents.
#
# `ws create --agent` must receive the instance UUID (a preset id like `claude`
# does not resolve). The UUID is resolved LIVE from `superset agents list` by
# label (instance IDs are host-specific). When the CLI is unavailable, an
# optional per-harness environment fallback can supply the local instance ID.
# A --host dispatch must always resolve live.
#
# Model policy → harness selection:
#   claude-* or no model → Claude (pin: --model / CLAUDE_CODE_EFFORT_LEVEL)
#   gpt-* / codex-*      → Codex  (pin: -m / -c model_reasoning_effort; the
#                          gpt-5.6 family is sol / terra / luna)
#
# Usage:
#   fm-agent.sh resolve [--model <id>] [--host <hostId>] <project-name-or-pid>
# Prints (eval-able):
#   agent=<uuid> agent_label=… agent_ctx=personal agent_harness=<claude|codex> agent_pin=<live|inert|unknown>
#
# agent_pin says whether the agent's Command consumes the per-dispatch
# model/effort pin: `live` when it routes through superset-launch (or the old
# fm-launch.sh), `inert` when it runs claude/codex directly,
# `unknown` when the command couldn't be inspected (offline fallback /
# FM_AGENT_ID).
# Env:
#   FM_AGENT_ID          force the instance uuid (label/harness still reported)
#   FM_CLAUDE_AGENT_ID   offline fallback for the local Claude agent
#   FM_CODEX_AGENT_ID    offline fallback for the local Codex agent
set -eu

usage() { echo "usage: fm-agent.sh resolve [--model <id>] [--host <hostId>] <project-name-or-pid>" >&2; exit 2; }

[ "${1:-}" = resolve ] || usage
shift
MODEL="" HOST="" PROJ=""
while [ $# -gt 0 ]; do
  case "$1" in
    --model) MODEL=$2; shift 2 ;;
    --host) HOST=$2; shift 2 ;;
    -*) usage ;;
    *) PROJ=$1; shift ;;
  esac
done
[ -n "$PROJ" ] || usage

case "$MODEL" in
  gpt-*|codex-*)
    HARNESS=codex
    LABEL='Codex'
    FALLBACK=${FM_CODEX_AGENT_ID:-} ;;
  *)
    HARNESS=claude
    LABEL='Claude'
    FALLBACK=${FM_CLAUDE_AGENT_ID:-} ;;
esac
CTX=personal

ID="${FM_AGENT_ID:-}"
PIN=unknown
if [ -z "$ID" ] && command -v superset >/dev/null 2>&1; then
  LOC=(--local); [ -n "$HOST" ] && LOC=(--host "$HOST")
  hit=$(superset agents list "${LOC[@]}" --json 2>/dev/null | python3 -c '
import sys, json
lbl = sys.argv[1]
try:
    ags = json.load(sys.stdin)
except Exception:
    sys.exit()
for a in (ags if isinstance(ags, list) else []):
    if a.get("label") == lbl:
        print(a.get("id", ""))
        print(a.get("command", ""))
        break
' "$LABEL" 2>/dev/null || true)
  ID=$(printf '%s\n' "$hit" | sed -n 1p)
  CMD=$(printf '%s\n' "$hit" | sed -n 2p)
  if [ -n "$ID" ]; then
    case "$CMD" in
      *superset-launch*|*fm-launch.sh*|*fm-ccs-route.sh*) PIN=live ;;
      ?*) PIN=inert ;;
    esac
  fi
fi
if [ -z "$ID" ]; then
  if [ -n "$HOST" ]; then
    echo "error: cannot resolve custom agent '$LABEL' on host $HOST — instance IDs are host-specific (check: superset agents list --host $HOST)" >&2
    exit 1
  fi
  [ -n "$FALLBACK" ] || {
    fallback_var=FM_CLAUDE_AGENT_ID
    [ "$HARNESS" = codex ] && fallback_var=FM_CODEX_AGENT_ID
    echo "error: cannot resolve local custom agent '$LABEL' (run: superset agents list --local --json, or set $fallback_var)" >&2
    exit 1
  }
  ID="$FALLBACK"
fi

printf "agent=%s agent_label='%s' agent_ctx=%s agent_harness=%s agent_pin=%s\n" "$ID" "$LABEL" "$CTX" "$HARNESS" "$PIN"
