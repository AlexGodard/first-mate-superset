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
# A fixed Superset combo agent can be selected by label instead. Its command
# must carry both --pin-model and --pin-effort; the resolver reads those args
# live and derives the actual harness, so callers do not need per-dispatch
# model/effort overrides.
#
# Usage:
#   fm-agent.sh resolve [--model <id> | --preset <label>] [--host <hostId>] <project-name-or-pid>
# Prints (eval-able):
#   agent=<uuid> agent_label=… agent_ctx=personal agent_harness=<claude|codex> agent_pin=<live|inert|unknown> agent_model=… agent_effort=… agent_preset=<on|off>
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

usage() { echo "usage: fm-agent.sh resolve [--model <id> | --preset <label>] [--host <hostId>] <project-name-or-pid>" >&2; exit 2; }

[ "${1:-}" = resolve ] || usage
shift
MODEL="" PRESET="" HOST="" PROJ=""
while [ $# -gt 0 ]; do
  case "$1" in
    --model) MODEL=$2; shift 2 ;;
    --preset) PRESET=$2; shift 2 ;;
    --host) HOST=$2; shift 2 ;;
    -*) usage ;;
    *) PROJ=$1; shift ;;
  esac
done
[ -n "$PROJ" ] || usage
[ -z "$MODEL" ] || [ -z "$PRESET" ] || {
  echo "error: --model and --preset are mutually exclusive" >&2
  exit 2
}

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

ID=""
PIN=unknown
AGENT_MODEL=""
AGENT_EFFORT=""
IS_PRESET=off
if [ -n "$PRESET" ]; then
  LABEL="$PRESET"
  FALLBACK=""
  IS_PRESET=on
elif [ -n "${FM_AGENT_ID:-}" ]; then
  ID="$FM_AGENT_ID"
fi

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
        args = a.get("args") or []
        harness = ""
        command = str(a.get("command", ""))
        command_base = command.rsplit("/", 1)[-1]
        if command_base in ("codex", "claude"):
            harness = command_base
        elif "superset-launch" in command and args:
            if args[0] in ("codex", "claude"):
                harness = args[0]
        model = effort = ""
        for idx, arg in enumerate(args):
            if arg == "--pin-model" and idx + 1 < len(args):
                model = str(args[idx + 1])
            elif isinstance(arg, str) and arg.startswith("--pin-model="):
                model = arg.split("=", 1)[1]
            elif arg == "--pin-effort" and idx + 1 < len(args):
                effort = str(args[idx + 1])
            elif isinstance(arg, str) and arg.startswith("--pin-effort="):
                effort = arg.split("=", 1)[1]
        print(harness)
        print(model)
        print(effort)
        break
' "$LABEL" 2>/dev/null || true)
  ID=$(printf '%s\n' "$hit" | sed -n 1p)
  CMD=$(printf '%s\n' "$hit" | sed -n 2p)
  RESOLVED_HARNESS=$(printf '%s\n' "$hit" | sed -n 3p)
  AGENT_MODEL=$(printf '%s\n' "$hit" | sed -n 4p)
  AGENT_EFFORT=$(printf '%s\n' "$hit" | sed -n 5p)
  if [ -n "$ID" ]; then
    case "$CMD" in
      *superset-launch*|*fm-launch.sh*|*fm-ccs-route.sh*) PIN=live ;;
      ?*) PIN=inert ;;
    esac
    if [ -n "$PRESET" ]; then
      case "$RESOLVED_HARNESS" in
        claude|codex) HARNESS="$RESOLVED_HARNESS" ;;
        *)
          echo "error: agent preset '$LABEL' does not resolve to a Claude or Codex harness" >&2
          exit 1 ;;
      esac
      if [ -z "$AGENT_MODEL" ] || [ -z "$AGENT_EFFORT" ]; then
        echo "error: agent preset '$LABEL' must define both --pin-model and --pin-effort in its Superset args" >&2
        exit 1
      fi
    fi
  fi
fi
if [ -z "$ID" ]; then
  if [ -n "$PRESET" ]; then
    LOCATION=--local
    [ -n "$HOST" ] && LOCATION="--host $HOST"
    echo "error: cannot resolve fixed agent preset '$LABEL'${HOST:+ on host $HOST} (check: superset agents list $LOCATION --json)" >&2
    exit 1
  fi
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

printf "agent=%s agent_label='%s' agent_ctx=%s agent_harness=%s agent_pin=%s agent_model='%s' agent_effort='%s' agent_preset=%s\n" \
  "$ID" "$LABEL" "$CTX" "$HARNESS" "$PIN" "$AGENT_MODEL" "$AGENT_EFFORT" "$IS_PRESET"
