#!/usr/bin/env bash
# One-call crewmate dispatch: the whole sequence the first mate used to hand-run
# inline (registry resolve -> cloud-project -> branch -> brief -> ws create ->
# capture-session -> open-foreground), behind a single command, plus a
# zsh-safe BATCH mode (ported from upstream firstmate#33).
#
# Usage:
#   fm-spawn.sh [--scout] [--branch <slug>] [--mode <m>] [--host <id>] <project> <task...>
#   fm-spawn.sh --batch [--scout] [--host <id>]      # stdin: "<project>\t<task>" per line
#
#   --scout       dispatch a read-only investigator (report deliverable); default is ship.
#   --branch      override the auto-derived slug (the leaf; the fm/ or scout/ prefix is added).
#   --mode        override the registry delivery mode for a ship (direct-PR|local-only|no-mistakes).
#   --host <id>   dispatch to a remote host instead of --local.
#
# Batch mode loops IN BASH and re-execs the single path per line, so the caller
# never hand-writes a multi-task loop -- the tool shell is zsh, which does not
# word-split unquoted $vars and silently mangles ad-hoc `for x in $pairs` loops
# (the exact footgun upstream#33 fixes). One line = one crewmate; blank lines and
# lines starting with `#` are skipped; a shared --scout/--host applies to all.
# A failed line is reported and skipped; the rest still launch; exit is non-zero if
# any line failed.
#
# FM_DRY_RUN=1 resolves + prints the plan line(s) without touching superset or
# the filesystem -- for preview and tests.
#
# On success prints (single):
#   spawned <kind> <project> branch=<branch> mode=<mode> yolo=<yolo> workspace=<id> worktree=<path>
set -eu

SKILL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$SKILL_ROOT/bin"
WTROOT="${SUPERSET_WORKTREES:-$HOME/.superset/worktrees}"
CONFIG="${FM_CONFIG_OVERRIDE:-$SKILL_ROOT/config}"
. "$BIN/fm-gate-refuse-lib.sh"
fm_refuse_gate_agent spawn || exit $?
"$BIN/fm-watch-guard.sh" >/dev/null || true

KIND=ship BRANCH_OVERRIDE="" MODE_OVERRIDE="" HOST="" BATCH=0 FORK_OVERRIDE="" CREW_MODEL="${FM_CREW_MODEL:-}" CREW_EFFORT="${FM_CREW_EFFORT:-}"
POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --scout) KIND=scout; shift ;;
    --kind) KIND=$2; shift 2 ;;
    --branch) BRANCH_OVERRIDE=$2; shift 2 ;;
    --mode) MODE_OVERRIDE=$2; shift 2 ;;
    --model) CREW_MODEL=$2; shift 2 ;;
    --effort) CREW_EFFORT=$2; shift 2 ;;
    --fork) FORK_OVERRIDE=$2; shift 2 ;;
    --host) HOST=$2; shift 2 ;;
    --batch) BATCH=1; shift ;;
    --) shift; while [ $# -gt 0 ]; do POS+=("$1"); shift; done ;;
    -*) echo "error: unknown flag $1" >&2; exit 2 ;;
    *) POS+=("$1"); shift ;;
  esac
done
case "$KIND" in ship|scout) ;; *) echo "error: --kind must be ship|scout" >&2; exit 2 ;; esac
if [ -n "$CREW_EFFORT" ]; then
  case "$CREW_EFFORT" in
    low|medium|high|xhigh|max) ;;
    *) echo "error: --effort must be low|medium|high|xhigh|max" >&2; exit 2 ;;
  esac
fi

# Crewmates get the 1M-context variant of 1M-capable models: the bare ID
# (`claude-opus-4-8`) resolves to the 200k deployment, and long autonomous runs
# want the full window. Normalize here so the pin, dry-run preview, and summary
# all show what actually launches; superset-launch applies the same rewrite at
# launch (covering FM_CREW_MODEL fallbacks and manual reopens). An explicit
# bracket suffix is respected as-is; haiku has no 1M variant and passes through.
case "$CREW_MODEL" in
  *\[*) ;;
  claude-opus-4-8|claude-sonnet-5|claude-fable-5) CREW_MODEL="${CREW_MODEL}[1m]" ;;
esac

slugify() {  # lower, non-alnum -> '-', trim, cap; deterministic part of the branch
  printf '%s' "$1" | head -1 | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-28 | sed -E 's/-+$//'
}
rand4() { openssl rand -hex 2 2>/dev/null || printf '%04x' "$(( ${RANDOM:-0} % 65536 ))"; }

# ---- batch mode: loop in bash, re-exec the single path per stdin line ----------
if [ "$BATCH" = 1 ]; then
  [ "${#POS[@]}" -eq 0 ] || { echo "error: --batch takes no positional args; pipe '<project>\\t<task>' lines on stdin" >&2; exit 2; }
  passthru=()
  [ "$KIND" = scout ] && passthru+=(--scout)
  [ -n "$HOST" ] && passthru+=(--host "$HOST")
  [ -n "$CREW_MODEL" ] && passthru+=(--model "$CREW_MODEL")
  [ -n "$CREW_EFFORT" ] && passthru+=(--effort "$CREW_EFFORT")
  rc=0 n=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    proj=${line%%	*}                       # everything before the first TAB
    task=${line#*	}                        # everything after it
    if [ "$proj" = "$line" ] || [ -z "${task//[[:space:]]/}" ]; then
      echo "batch: SKIP malformed line (need '<project>\\t<task>'): $line" >&2; rc=1; continue
    fi
    n=$((n+1))
    if FM_SPAWN_BATCH_CHILD=1 "$BIN/fm-spawn.sh" "${passthru[@]}" "$proj" "$task"; then :; else
      echo "batch: FAILED to spawn into '$proj': $task" >&2; rc=1
    fi
  done
  [ "$n" -gt 0 ] || { echo "error: --batch read no task lines on stdin" >&2; exit 2; }
  exit "$rc"
fi

# ---- single task ---------------------------------------------------------------
PROJECT="${POS[0]:-}"
[ -n "$PROJECT" ] || { echo "usage: fm-spawn.sh [--scout] <project> <task...>" >&2; exit 2; }
TASK="${POS[*]:1}"
[ -n "${TASK//[[:space:]]/}" ] || { echo "error: a task description is required" >&2; exit 2; }

# 1. delivery config (mode/yolo/fork) from the registry; flags override for a ship.
# Resolved BEFORE the consultation backstop so a mode-specific model default (below)
# can satisfy it — the no-mistakes gate has a fixed harness, so it self-resolves.
eval "$("$BIN/fm-registry.sh" resolve "$PROJECT")"   # sets mode= yolo= projectId= fork=
MODE="$mode"; YOLO="$yolo"; FORK="${fork:--}"
if [ -n "$MODE_OVERRIDE" ]; then
  case "$MODE_OVERRIDE" in
    direct-PR|local-only|no-mistakes) MODE="$MODE_OVERRIDE" ;;
    *) echo "error: --mode must be direct-PR|local-only|no-mistakes" >&2; exit 2 ;;
  esac
fi
[ -n "$FORK_OVERRIDE" ] && FORK="$FORK_OVERRIDE"
[ "$KIND" = scout ] && MODE=scout

# 1b. no-mistakes default harness. The no-mistakes validation gate runs on the
# Codex harness — a ship left to the Claude default would drive the wrong
# gate. So when a no-mistakes ship carries no explicit --model, default the crew to
# gpt-5.6-terra at high effort (the /no-mistakes CLI's harness). An explicit
# --model/--effort always wins; other modes are untouched. This also satisfies the
# consultation backstop below without the supervisor hand-passing the flag.
if [ "$MODE" = no-mistakes ]; then
  [ -n "$CREW_MODEL" ]  || CREW_MODEL=gpt-5.6-terra
  [ -n "$CREW_EFFORT" ] || CREW_EFFORT=high
fi

# 2. consultation backstop. When a dispatch profile (config/crew-dispatch.json)
# is active, the FIRST MATE must resolve a model from its rules and pass --model
# explicitly — the scripts never parse the rules, so this guard is what keeps
# them from being silently skipped. FM_DRY_RUN is exempt: dry-run is exactly how
# the supervisor previews a resolution before committing to it. Ported from
# upstream firstmate (AGENTS.md "consultation backstop"). See SKILL.md "Crewmate
# model & the dispatch profile".
if [ -z "${FM_DRY_RUN:-}" ] && [ -z "$CREW_MODEL" ] && [ -f "$CONFIG/crew-dispatch.json" ]; then
  echo "error: config/crew-dispatch.json is active — pass an explicit --model resolved from the dispatch rules (the consultation backstop, so the profile is never silently skipped). Preview with FM_DRY_RUN=1." >&2
  exit 2
fi

# 2. branch
LEAF="${BRANCH_OVERRIDE:-$(slugify "$TASK")}"
[ -n "$LEAF" ] || LEAF=task
[ -n "$BRANCH_OVERRIDE" ] || LEAF="$LEAF-$(rand4)"
if [ "$KIND" = scout ]; then BRANCH="scout/$LEAF"; else BRANCH="fm/$LEAF"; fi

# 3. owner (scopes the crew to this supervisor for fm-fleet.sh --mine).
# A secondmate supplies its durable id through FM_OWNER; preserving it is what
# keeps that secondmate's child fleet stable across turns and process restarts.
# Ordinary first mates have no override and keep the session-derived owner id.
OWNER="${FM_OWNER:-$("$BIN/fm-lock.sh" id 2>/dev/null || echo -)}"

if [ -n "${FM_DRY_RUN:-}" ]; then
  # Dry-run validates model routing without creating a workspace. Claude ids
  # (or none) → the Claude agent; gpt-*/codex-* ids → the Codex agent.
  _h=claude
  case "$CREW_MODEL" in
    gpt-*|codex-*) _h=codex ;;
  esac
  echo "DRYRUN spawn $KIND $PROJECT branch=$BRANCH mode=$MODE yolo=$YOLO fork=${FORK:--} model=${CREW_MODEL:-default} effort=${CREW_EFFORT:-default} harness=$_h owner=$OWNER host=${HOST:-local}"
  exit 0
fi

# 4. live cloud project id (drift-proof)
PID=$("$BIN/fm-registry.sh" cloud-project "$PROJECT")

# 4b. resolve the CUSTOM AGENT instance UUID (the `claude` preset was removed;
# `ws create --agent` needs a HostAgentConfig id). Claude ids (or none) → the
# Claude agent; gpt-*/codex-* ids → the Codex agent. See bin/fm-agent.sh.
AGENT_ARGS=(resolve)
[ -n "$CREW_MODEL" ] && AGENT_ARGS+=(--model "$CREW_MODEL")
[ -n "$HOST" ] && AGENT_ARGS+=(--host "$HOST")
eval "$("$BIN/fm-agent.sh" "${AGENT_ARGS[@]}" "$PROJECT")"   # sets agent= agent_label= agent_ctx= agent_harness= agent_pin=

# 5. brief (harness-aware: Codex crews get the persistent-session dev-server recipe)
BRIEF=$("$BIN/fm-brief.sh" --kind "$KIND" --mode "$MODE" --project "$PROJECT" \
  --branch "$BRANCH" --owner "$OWNER" --fork "${FORK:--}" \
  --harness "${agent_harness:-claude}" --task "$TASK")

# 6. create the v2-visible worktree + spawn the crewmate in one CLI call.
# Stage the model pin FIRST (keyed by the deterministic worktree path): the agent
# launches DURING `ws create`, so superset-launch must find the pin already in place.
# Local dispatch only — a --host crewmate launches on the remote's agent Command,
# which can't see this host's pin file. See ~/.local/bin/superset-launch.
WT="$WTROOT/$PID/$BRANCH"
if [ -n "$CREW_MODEL" ] || [ -n "$CREW_EFFORT" ]; then
  if [ -n "$HOST" ]; then
    echo "warn: --model/--effort are local-only; ignored for --host dispatch (remote uses its instance default)" >&2
  else
    # The pin only takes effect when the agent's Command routes through
    # superset-launch (which `take`s it at launch). fm-agent.sh inspected the
    # Command and reported agent_pin: warn on `inert` (Command runs claude
    # directly) so a silently-defaulting model never goes unnoticed.
    if [ "${agent_pin:-unknown}" = inert ]; then
      echo "warn: agent '$agent_label' launches claude directly, so --model/--effort will NOT reach the crewmate — point its Command at ~/.local/bin/superset-launch (Superset → Settings → Agents)" >&2
    fi
    PIN_ARGS=()
    [ -n "$CREW_MODEL" ] && PIN_ARGS+=(--model "$CREW_MODEL")
    [ -n "$CREW_EFFORT" ] && PIN_ARGS+=(--effort "$CREW_EFFORT")
    "$HOME/.local/bin/superset-launch" pin set "$WT" "${PIN_ARGS[@]}" || true
  fi
fi
LOC=(--local); [ -n "$HOST" ] && LOC=(--host "$HOST")
WS=$(superset ws create "${LOC[@]}" --project "$PID" --branch "$BRANCH" \
  --name "$KIND-$LEAF" --agent "$agent" --prompt "$BRIEF" --json)
WSID=$(printf '%s' "$WS" | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["workspace"]["id"])
except Exception: print("")')
[ -n "$WSID" ] || { echo "error: ws create returned no workspace id:" >&2; printf '%s\n' "$WS" >&2; exit 1; }

# 7. capture the live terminal id (for fm-send live lane) + foreground the pane.
# fm-capture-session exits 4 when ws-create's agents[] carries {ok:false,error}:
# the CLI exits 0 and prints success even when the agent failed to launch
# (superset-sh/superset#5767), so the workspace would exist but no crewmate is
# running in it. Do NOT report "spawned" in that case.
CAPTURE_RC=0
printf '%s' "$WS" | "$BIN/fm-capture-session.sh" "$WT" >&2 || CAPTURE_RC=$?
if [ "$CAPTURE_RC" -eq 4 ]; then
  "$BIN/fm-open-foreground.sh" "$WSID" "$WT" >&2 || true
  echo "error: workspace $WSID was created but the AGENT FAILED TO LAUNCH (see error above)." >&2
  echo "error: no crewmate is running in $WT — fix the launch failure (e.g. Superset pty exhaustion: restart the desktop app), then retry with:" >&2
  echo "  superset agents create --workspace $WSID --agent $agent --prompt <brief>   # reuse the workspace" >&2
  echo "  # or tear down and re-dispatch: superset ws delete $WSID" >&2
  exit 1
fi
"$BIN/fm-open-foreground.sh" "$WSID" "$WT" >&2 || true

# Belt-and-suspenders: a terminal-agent dispatch with no captured terminalId
# means we can't prove the agent launched (older CLI payloads, parse drift).
# Warn — the crewmate may be fine, but verify before trusting the dispatch.
if ! grep -q '^terminalId=' "$WT/.firstmate/superset" 2>/dev/null; then
  echo "warning: no terminalId captured — agent launch unconfirmed; live-send lane unavailable." >&2
  echo "warning: verify the crewmate is alive (fm-crew-state.sh $WT, or the desktop pane) before relying on it." >&2
fi

echo "spawned $KIND $PROJECT branch=$BRANCH mode=$MODE yolo=$YOLO agent=$agent_label model=${CREW_MODEL:-default} effort=${CREW_EFFORT:-default} workspace=$WSID worktree=$WT"
