#!/usr/bin/env bash
# fm-crew-state.sh - deterministic read of a crew's CURRENT state.
#
# Why this exists: <worktree>/.firstmate/status is an append-only, best-effort
# EVENT LOG. Crewmates append wake-worthy transitions (done/needs-decision/blocked
# /failed) and a `working:` note when they resume, but a crew deep in a long
# implement/validate stretch writes NOTHING the whole time -- so `tail -1` of that
# log reports the last EVENT, not whether the crew is currently progressing or
# wedged ("silence is not a stall"). This helper reads the authoritative sources
# into one stable, parseable, token-tight line firstmate can read any time:
#
#   state: <working|parked|paused|done|blocked|failed|unknown> · source: <process|status-log|none> · <detail>
#
# Logic, in order (ported from upstream firstmate's bin/fm-crew-state.sh,
# kunchenguid/firstmate, adapted to the Superset/filesystem model: crews are
# addressed by WORKTREE PATH, meta lives in <worktree>/.firstmate/meta, and the
# pane busy-signature fallback becomes a process-evidence check):
#   1. Positive process evidence (a live process referencing the worktree)
#      corroborates a `working` status-log line.
#   2. Otherwise the status log's most recent recognized state event.
#
# For deeper "is it actually moving?" signals (live processes, freshest
# artifacts, per-item progress lines) use fm-progress.sh alongside this.
#
# Read-only and side-effect free. Exits 0 on any successful read; exit 2 only on a
# usage error (no worktree).
set -u

WT=${1:-}
[ -n "$WT" ] || { echo "usage: fm-crew-state.sh <worktree-path>" >&2; exit 2; }

LOG="$WT/.firstmate/status"
SEP=' · '

emit() {  # <state> <source> [detail]
  local line="state: $1${SEP}source: $2"
  [ -n "${3:-}" ] && line="$line${SEP}$3"
  printf '%s\n' "$line"
  exit 0
}

# A torn-down (or never-created) worktree has no current state to read.
[ -d "$WT" ] || emit unknown none "worktree gone (torn down?): $WT"

# --- status log ------------------------------------------------------------

log_verb_of() {  # <line>
  local v=${1%%:*}
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}
log_note_of() {  # <line>
  case "$1" in
    *:*) local n=${1#*:}; printf '%s' "${n#"${n%%[![:space:]]*}"}" ;;
    *)   printf '%s' "$1" ;;
  esac
}
map_log_state() {  # <verb>
  case "$1" in
    working)        echo working ;;
    needs-decision) echo parked ;;
    paused)         echo paused ;;
    blocked)        echo blocked ;;
    done)           echo "done" ;;
    failed)         echo failed ;;
    *)              echo unknown ;;
  esac
}

# `resolved:` closes a decision but is not itself a current state. Read the most
# recent recognized state event instead (firstmate#475/#485).
log_last_state_line() {
  [ -f "$LOG" ] || return 1
  grep -E '^[[:space:]]*(working|needs-decision|paused|blocked|done|failed):' "$LOG" 2>/dev/null | tail -1
}

LOG_LINE=$(log_last_state_line || true)
LOG_VERB=$(log_verb_of "$LOG_LINE")

if [ -n "$LOG_VERB" ]; then
  # A process whose argv mentions the worktree proves only that the harness
  # exists, not that the model is actively working. Unlike upstream's actual
  # pane-busy signal, process existence cannot safely supersede an explicit
  # needs-decision, pause, blocker, done, or failure event. Use it only to
  # corroborate an already-working status; absence remains no proof of idle.
  PS=$(ps -axo command= 2>/dev/null || true)
  if [ "$LOG_VERB" = working ] && printf '%s\n' "$PS" | grep -F "$WT" | grep -v -E 'fm-crew-state|grep -F' >/dev/null 2>&1; then
    emit working process "live process references worktree"
  fi
  emit "$(map_log_state "$LOG_VERB")" status-log "$(log_note_of "$LOG_LINE")"
fi

emit unknown none "no current-state source available"
