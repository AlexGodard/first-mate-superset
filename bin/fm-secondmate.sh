#!/usr/bin/env bash
# Persistent secondmate lifecycle: spawn / list / route / retire a scoped
# sub-supervisor (kunchenguid/firstmate#37 + #42, ported to Superset).
#
# A SECONDMATE is a persistent Claude Code session (its own Superset workspace =
# its "home") that runs the SAME first-mate skill, scoped to a domain (one or more
# projects), supervising its OWN crew. It is idle-by-default: after reconciling its
# in-flight crew it waits for the main first mate to route it scoped tasks. Its crew
# is tagged with a STABLE owner (= the secondmate id), so the two supervision tiers
# stay disjoint AND the main first mate can find/retire its crew. The secondmate's
# HOME meta carries the MAIN first mate's owner, so the main's `fm-fleet.sh --mine`
# sees the secondmate as one line (kind=secondmate) without seeing its crew.
#
# Usage:
#   fm-secondmate.sh spawn <id> --scope <p1,p2> --project <home-project> [--branch <slug>] [--host <id>]
#   fm-secondmate.sh list
#   fm-secondmate.sh route <id> <task...>      # send a scoped task into the secondmate's session
#   fm-secondmate.sh retire <id> [--force]     # delete the home; refuses if crew is in flight
#
# Registry: state/secondmates.md (managed here; do not hand-edit while live).
# FM_DRY_RUN=1 resolves + prints the plan without touching superset/filesystem.
set -eu

SKILL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$SKILL_ROOT/bin"
STATE="${FM_STATE_OVERRIDE:-$SKILL_ROOT/state}"
REG="${FM_SECONDMATE_REGISTRY:-$STATE/secondmates.md}"
WTROOT="${SUPERSET_WORKTREES:-$HOME/.superset/worktrees}"
mkdir -p "$STATE"

# Registry format (pipe-delimited, between markers):
#   <id> | <workspaceId> | <home-project> | <scope csv> | <worktree> | <added-iso>
reg_ensure() {
  [ -f "$REG" ] && return 0
  {
    echo "# first-mate secondmate registry (managed by fm-secondmate.sh; do not hand-edit while live)"
    echo ""
    echo "<!-- secondmates:begin -->"
    echo "<!-- secondmates:end -->"
  } > "$REG"
}
reg_line() {  # print the registry line for <id>, or nothing
  local id=$1
  [ -f "$REG" ] || return 0
  awk -F'|' -v n="$id" '
    /<!-- secondmates:begin -->/{f=1;next} /<!-- secondmates:end -->/{f=0}
    f && NF { x=$1; gsub(/^[ \t-]+|[ \t]+$/,"",x); if (x==n) { print; exit } }' "$REG"
}
reg_field() {  # reg_field <id> <1-based-field>
  reg_line "$1" | awk -F'|' -v i="$2" '{gsub(/^[ \t-]+|[ \t]+$/,"",$i); print $i}'
}
reg_add() {  # reg_add <id> <wsid> <project> <scope> <wt> <iso>
  reg_ensure
  local tmp; tmp=$(mktemp)
  awk -v row="- $1 | $2 | $3 | $4 | $5 | $6" '
    { print }
    /<!-- secondmates:begin -->/ { print row }' "$REG" > "$tmp" && mv "$tmp" "$REG"
}
reg_remove() {  # reg_remove <id>
  [ -f "$REG" ] || return 0
  local tmp; tmp=$(mktemp)
  awk -F'|' -v n="$1" '
    /<!-- secondmates:begin -->/{f=1;print;next} /<!-- secondmates:end -->/{f=0;print;next}
    f && NF { x=$1; gsub(/^[ \t-]+|[ \t]+$/,"",x); if (x==n) next }
    { print }' "$REG" > "$tmp" && mv "$tmp" "$REG"
}

# In-flight crew owned by a secondmate (meta owner == <id>, status not terminal).
# Used by retire's safety gate. Prints one "<state> <project> <branch> [<wt>]" per crew.
inflight_crew() {
  local id=$1
  [ -d "$WTROOT" ] || return 0
  while IFS= read -r meta; do
    [ -n "$meta" ] || continue
    grep -q "^owner=$id$" "$meta" 2>/dev/null || continue
    local dir status last state project branch
    dir=$(dirname "$(dirname "$meta")")
    status="$dir/.firstmate/status"
    project=$(grep -m1 '^project=' "$meta" | cut -d= -f2-); branch=$(grep -m1 '^branch=' "$meta" | cut -d= -f2-)
    if [ -f "$status" ]; then last=$(grep -v '^[[:space:]]*$' "$status" | tail -1); else last=""; fi
    state=${last%%:*}; [ "$state" = "$last" ] && state="working"
    case "$state" in done|failed) continue ;; esac
    printf '%s %s %s [%s]\n' "$state" "${project:-?}" "${branch:--}" "$dir"
  done < <(find "$WTROOT" -maxdepth 8 \( -name node_modules -o -name .git \) -prune -o \
    -type f -path '*/.firstmate/meta' -print 2>/dev/null | sort)
}

valid_id() { case "$1" in ''|*[!a-zA-Z0-9_-]*) return 1 ;; *) return 0 ;; esac; }

cmd=${1:-}; shift || true
case "$cmd" in
  spawn)
    ID=${1:-}; shift || true
    SCOPE="" HOME_PROJ="" BRANCH_OVERRIDE="" HOST="" SM_MODEL="${FM_CREW_MODEL:-}" SM_EFFORT="${FM_CREW_EFFORT:-}"
    while [ $# -gt 0 ]; do
      case "$1" in
        --scope) SCOPE=$2; shift 2 ;;
        --project) HOME_PROJ=$2; shift 2 ;;
        --branch) BRANCH_OVERRIDE=$2; shift 2 ;;
        --model) SM_MODEL=$2; shift 2 ;;
        --effort) SM_EFFORT=$2; shift 2 ;;
        --host) HOST=$2; shift 2 ;;
        *) echo "error: unknown arg $1" >&2; exit 2 ;;
      esac
    done
    if [ -n "$SM_EFFORT" ]; then
      case "$SM_EFFORT" in low|medium|high|xhigh|max) ;;
        *) echo "error: --effort must be low|medium|high|xhigh|max" >&2; exit 2 ;; esac
    fi
    case "$SM_MODEL" in
      gpt-*|codex-*)
        echo "error: model '$SM_MODEL' is a GPT/Codex id; secondmates use the Claude agent only" >&2
        exit 2 ;;
    esac
    valid_id "$ID" || { echo "error: secondmate id must be a slug [A-Za-z0-9_-]: '$ID'" >&2; exit 2; }
    [ -n "$SCOPE" ] || { echo "error: --scope required (comma-separated project names)" >&2; exit 2; }
    [ -n "$HOME_PROJ" ] || { echo "error: --project required (the secondmate's home project)" >&2; exit 2; }
    [ -z "$(reg_line "$ID")" ] || { echo "error: secondmate '$ID' already registered (retire it first)" >&2; exit 2; }
    LEAF="${BRANCH_OVERRIDE:-$ID}"
    BRANCH="mate/$LEAF"
    MAIN_OWNER=$("$BIN/fm-lock.sh" id 2>/dev/null || echo -)

    if [ -n "${FM_DRY_RUN:-}" ]; then
      echo "DRYRUN secondmate spawn $ID scope=$SCOPE home=$HOME_PROJ branch=$BRANCH model=${SM_MODEL:-default} effort=${SM_EFFORT:-default} main-owner=$MAIN_OWNER host=${HOST:-local}"
      exit 0
    fi

    PID=$("$BIN/fm-registry.sh" cloud-project "$HOME_PROJ")
    BRIEF=$("$BIN/fm-brief.sh" --kind secondmate --id "$ID" --scope "$SCOPE" \
      --project "$HOME_PROJ" --owner "$MAIN_OWNER")
    # Pin the secondmate's own model/effort (the "supervisor tier on a different
    # model" axis, upstream's config/secondmate-harness) — staged before ws create
    # so superset-launch picks it up at launch. Local only (remote can't see the pin).
    WT="$WTROOT/$PID/$BRANCH"
    if [ -n "$SM_MODEL" ] || [ -n "$SM_EFFORT" ]; then
      if [ -n "$HOST" ]; then
        echo "warn: --model/--effort are local-only; ignored for --host secondmate" >&2
      else
        SM_PIN=()
        [ -n "$SM_MODEL" ] && SM_PIN+=(--model "$SM_MODEL")
        [ -n "$SM_EFFORT" ] && SM_PIN+=(--effort "$SM_EFFORT")
        "$HOME/.local/bin/superset-launch" pin set "$WT" "${SM_PIN[@]}" || true
      fi
    fi
    # Secondmates run this skill, so they are Claude-only: always the Claude custom
    # agent (the `claude` preset was removed; --agent needs the instance UUID).
    SM_AGENT_ARGS=(resolve); [ -n "$HOST" ] && SM_AGENT_ARGS+=(--host "$HOST")
    [ -n "$SM_MODEL" ] && SM_AGENT_ARGS+=(--model "$SM_MODEL")
    eval "$("$BIN/fm-agent.sh" "${SM_AGENT_ARGS[@]}" "$HOME_PROJ")"   # sets agent= agent_label= …
    LOC=(--local); [ -n "$HOST" ] && LOC=(--host "$HOST")
    WS=$(superset ws create "${LOC[@]}" --project "$PID" --branch "$BRANCH" \
      --name "mate-$ID" --agent "$agent" --prompt "$BRIEF" --json)
    WSID=$(printf '%s' "$WS" | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["workspace"]["id"])
except Exception: print("")')
    [ -n "$WSID" ] || { echo "error: ws create returned no workspace id:" >&2; printf '%s\n' "$WS" >&2; exit 1; }
    printf '%s' "$WS" | "$BIN/fm-capture-session.sh" "$WT" >&2 || true
    "$BIN/fm-open-foreground.sh" "$WSID" "$WT" >&2 || true
    reg_add "$ID" "$WSID" "$HOME_PROJ" "$SCOPE" "$WT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "spawned secondmate $ID scope=$SCOPE home=$HOME_PROJ branch=$BRANCH workspace=$WSID worktree=$WT"
    ;;

  list)
    reg_ensure
    any=0
    while IFS='|' read -r id wsid proj scope wt added; do
      [ -n "$id" ] || continue
      id=$(printf '%s' "$id" | sed -E 's/^[[:space:]-]+|[[:space:]]+$//g')
      [ -n "$id" ] || continue
      any=1
      wt=$(printf '%s' "$wt" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
      scope=$(printf '%s' "$scope" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
      proj=$(printf '%s' "$proj" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
      status="(no status)"; [ -n "$wt" ] && [ -f "$wt/.firstmate/status" ] && \
        status=$(grep -v '^[[:space:]]*$' "$wt/.firstmate/status" | tail -1)
      live=unknown
      wsid=$(printf '%s' "$wsid" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
      if [ -n "$wsid" ] && command -v superset >/dev/null 2>&1; then
        if superset ws get "$wsid" --json >/dev/null 2>&1; then live=alive
        elif [ -d "$wt" ]; then live=unknown
        else live=dead
        fi
      fi
      crew=$(inflight_crew "$id" | grep -c . || true)
      printf '%-16s home=%-20s scope=%-28s crew=%s live=%s :: %s\n' "$id" "$proj" "$scope" "${crew:-0}" "$live" "$status"
    done < <(awk '/<!-- secondmates:begin -->/{f=1;next} /<!-- secondmates:end -->/{f=0} f && NF' "$REG")
    [ "$any" = 1 ] || echo "(no secondmates registered)"
    ;;

  route)
    ID=${1:-}; shift || true
    valid_id "$ID" || { echo "error: bad secondmate id '$ID'" >&2; exit 2; }
    MSG="$*"
    [ -n "$MSG" ] || { echo "usage: fm-secondmate.sh route <id> <task...>" >&2; exit 2; }
    [ -n "$(reg_line "$ID")" ] || { echo "error: secondmate '$ID' not registered" >&2; exit 2; }
    WT=$(reg_field "$ID" 5); WSID=$(reg_field "$ID" 2)
    if [ -n "${FM_DRY_RUN:-}" ]; then echo "DRYRUN route -> $ID ($WSID): $MSG"; exit 0; fi
    PROMPT="[ROUTED TASK — from the main first mate] $MSG

Handle this per your charter: confirm it is within your scope, dispatch a crewmate (FM_OWNER=$ID …/bin/fm-spawn.sh), supervise and deliver per the project's mode, then report via .firstmate/status and return to idle. Escalate any human/destructive call up to the main first mate."
    TARGET="$WT"; [ -d "$TARGET" ] || TARGET="$WSID"
    "$BIN/fm-send.sh" --raw "$TARGET" "$PROMPT"
    echo "routed to secondmate $ID"
    ;;

  retire)
    ID=${1:-}; shift || true
    FORCE=0; [ "${1:-}" = "--force" ] && FORCE=1
    valid_id "$ID" || { echo "error: bad secondmate id '$ID'" >&2; exit 2; }
    [ -n "$(reg_line "$ID")" ] || { echo "error: secondmate '$ID' not registered" >&2; exit 2; }
    WSID=$(reg_field "$ID" 2)
    CREW=$(inflight_crew "$ID")
    if [ -n "$CREW" ] && [ "$FORCE" != 1 ]; then
      echo "error: secondmate $ID still has crew in flight (retire refused; deliver/hand back first, or --force):" >&2
      printf '%s\n' "$CREW" | sed 's/^/  /' >&2
      exit 1
    fi
    if [ -n "${FM_DRY_RUN:-}" ]; then echo "DRYRUN retire $ID (workspace $WSID; force=$FORCE; inflight=$(printf '%s' "$CREW" | grep -c . || true))"; exit 0; fi
    [ -n "$CREW" ] && echo "warn: --force retiring $ID with crew still in flight" >&2
    superset ws delete "$WSID" >&2 || echo "warn: 'superset ws delete $WSID' failed; remove the home manually" >&2
    reg_remove "$ID"
    echo "retired secondmate $ID (workspace $WSID deleted, registry row removed)"
    ;;

  probe)
    ID=${1:-}; valid_id "$ID" || { echo "error: bad secondmate id '$ID'" >&2; exit 2; }
    [ -n "$(reg_line "$ID")" ] || { echo "error: secondmate '$ID' not registered" >&2; exit 2; }
    WT=$(reg_field "$ID" 5); WSID=$(reg_field "$ID" 2)
    if superset ws get "$WSID" --json >/dev/null 2>&1; then
      echo "alive: workspace=$WSID worktree=$WT"; exit 0
    fi
    if [ ! -d "$WT" ]; then echo "dead: workspace missing and worktree gone"; exit 1; fi
    echo "unknown: workspace lookup failed but worktree still exists"; exit 2
    ;;

  recover)
    ID=${1:-}; valid_id "$ID" || { echo "error: bad secondmate id '$ID'" >&2; exit 2; }
    [ -n "$(reg_line "$ID")" ] || { echo "error: secondmate '$ID' not registered" >&2; exit 2; }
    set +e
    "$0" probe "$ID" >/dev/null 2>&1
    prc=$?
    set -e
    [ "$prc" != 0 ] || { echo "error: secondmate '$ID' is alive; recovery refused" >&2; exit 1; }
    [ "$prc" = 1 ] || { echo "error: secondmate liveness is unknown; recovery refused" >&2; exit 1; }
    PROJ=$(reg_field "$ID" 3); SCOPE=$(reg_field "$ID" 4); OLD_WS=$(reg_field "$ID" 2)
    superset ws delete "$OLD_WS" >/dev/null 2>&1 || true
    reg_remove "$ID"
    "$0" spawn "$ID" --scope "$SCOPE" --project "$PROJ" --branch "$ID-recovered-$(date +%s)"
    ;;

  *)
    echo "usage: fm-secondmate.sh {spawn <id> --scope <p,p> --project <home> [--branch <s>] [--host <id>]|list|probe <id>|recover <id>|route <id> <task...>|retire <id> [--force]}" >&2
    exit 2
    ;;
esac
