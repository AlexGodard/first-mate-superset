#!/usr/bin/env bash
# Hardened, local-only fleet watcher for the first mate (flavor-1 turn injection).
#
# Blocks until a CAPTAIN-RELEVANT fleet change occurs, then EXITS printing what
# changed. The first mate launches this as a harness-tracked BACKGROUND task; its
# exit re-invokes the first mate with no captain message -- Claude Code's "wake on
# background-process completion" capability (firstmate issue #27, flavor 1). This
# is the faithful port of upstream fm-watch.sh's status-signal scan, minus tmux.
# It reads local .firstmate/status files. It NEVER
# calls git/gh/network inside the loop -- a slow remote can't wedge it (the bug
# that silently froze an ad-hoc `git ls-remote` watcher). Do network checks
# (gh pr view, etc.) on wake, not here.
#
# Bash-side wake classification (ported from upstream fm-classify-lib.sh): the
# watcher diffs the ACTIONABLE signature -- only crew in done|blocked|needs-decision
# |failed, or whose last status line carries a captain-relevant phrase -- not the
# full digest. Benign churn (working: notes appearing/changing) is absorbed in
# bash and logged to state/.watch-triage.log; it never burns a firstmate turn. This
# is the local equivalent of upstream's away-mode daemon triage, folded into the
# watcher (locally the watcher already interposes bash before the LLM, so no
# separate daemon is needed).
#
# Arm-time race guard: a crew that turns actionable in the GAP between two watcher
# runs (e.g. `done` lands one second before re-arm) must not be baselined away --
# that once cost a silent, never-surfaced PR. At arm time the watcher compares the
# current actionable signature against state/.last-surfaced.<owner> (what the last
# wake already showed the supervisor) and wakes IMMEDIATELY on anything new. The
# last-surfaced file is what prevents the opposite failure, an arm->wake->re-arm
# loop on a line the supervisor has already seen and is deliberately sitting on
# (a needs-decision waiting on the captain): already-surfaced lines baseline
# normally.
#
# AFK mode (state/.afk present): widens batching. The watcher (a) coalesces a burst
# of actionable changes into ONE wake by waiting for the signature to settle
# (FM_AFK_SETTLE quiet polls) before exiting, and (b) only counts AFK-CRITICAL lines
# (needs-decision|blocked|failed) toward waking -- plain `done` deliveries are
# batch-coalesced and surfaced on the next wake, so a walk-away stretch produces
# few, digested wakes instead of one per event. AFK never grants more authority;
# the agent still escalates human/destructive calls to the captain (see
# reference/afk.md).
#
# Usage (the first mate runs this with run_in_background):
#   fm-watch-bg.sh        # block until an actionable fleet change -> print diff, exit 0
#                         # or exit 0 with "[heartbeat]" after FM_MAX_TICKS (self-heal)
# On wake: run `fm-fleet.sh --mine --attention`, act on
# done/blocked/needs-decision/failed, then RE-ARM this watcher while any crew is
# still in flight.
#
# Env:
#   FM_POLL             seconds between polls         (default 15; file reads, cheap)
#   FM_MAX_TICKS        polls before a heartbeat exit (default 80  ~= 20m at 15s)
#   FM_AFK_SETTLE       quiet polls before an AFK batch flushes (default 4 ~= 60s)
#   FM_OWNER            this session's owner id; defaults to `fm-lock.sh id`. The
#                       watcher scopes to your own crew (--mine) so a concurrent
#                       supervisor's fleet changes don't wake you.
#   FM_ALL              set to watch the GLOBAL fleet (every supervisor's crew)
#   FM_WATCH_NO_LOCK    bypass the singleton lock (tests / deliberate manual runs)
#   SUPERSET_WORKTREES  worktree root (passed through to fm-fleet.sh)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET="$SCRIPT_DIR/fm-fleet.sh"
# shellcheck source=bin/fm-lib.sh
. "$SCRIPT_DIR/fm-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
POLL=${FM_POLL:-15}
MAX_TICKS=${FM_MAX_TICKS:-80}
AFK_SETTLE=${FM_AFK_SETTLE:-4}
PAUSE_RESURFACE=${FM_PAUSE_RESURFACE_SECS:-3600}
case "$AFK_SETTLE" in ''|*[!0-9]*) AFK_SETTLE=4 ;; esac

# Scope to this session's crew by default. Resolve the owner id ONCE now, while
# ancestry detection is reliable (the harness launched us), and pin it via the
# env so per-poll fleet calls don't re-walk -- a detached background task can lose
# its harness ancestry mid-run. FM_ALL forces the global view; if the id can't be
# resolved and FM_ALL is unset, degrade to global rather than watch blind.
MINE="--mine"
if [ -n "${FM_ALL:-}" ]; then
  MINE=""
elif [ -z "${FM_OWNER:-}" ]; then
  FM_OWNER=$("$SCRIPT_DIR/fm-lock.sh" id 2>/dev/null) || true
  [ -n "$FM_OWNER" ] && export FM_OWNER || MINE=""
fi

STATE="${FM_STATE_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)/state}"
AFK_FLAG="$STATE/.afk"
TRIAGE_LOG="$STATE/.watch-triage.log"
WAKE_OWNER=${FM_OWNER:-$(fm_wake_owner)}
PAUSE_CHECK="$STATE/.paused-last-check.$WAKE_OWNER"
# Actionable lines the supervisor has already been shown (arm-time race guard).
SURFACED="$STATE/.last-surfaced.$WAKE_OWNER"

# Local-only fleet signature: each crew's state. No git/gh/network.
digest() { "$FLEET" $MINE 2>/dev/null; }
# The captain-relevant subset of the digest: the only thing a wake keys on. While
# away (state/.afk), narrow further to the AFK-critical subset so routine `done`
# deliveries batch instead of waking on sight.
actionable() {
  local selected last now
  if [ -f "$AFK_FLAG" ]; then
    selected=$(printf '%s\n' "$1" | fleet_afk_critical_signature)
  else
    selected=$(printf '%s\n' "$1" | fleet_actionable_signature)
  fi
  last=$(cat "$PAUSE_CHECK" 2>/dev/null || echo 0); case "$last" in ''|*[!0-9]*) last=0 ;; esac
  now=$(date +%s)
  if [ $((now - last)) -ge "$PAUSE_RESURFACE" ]; then
    selected=$(printf '%s\n%s\n' "$selected" "$(printf '%s\n' "$1" | awk '$1 == "paused"')" | awk 'NF && !seen[$0]++')
  fi
  printf '%s\n' "$selected" | sed '/^[[:space:]]*$/d'
}

# Persist the actionable lines a wake surfaced, so the next arm doesn't re-wake
# on them (and DOES wake on anything that appeared in an arm gap). Every exit
# path that prints actionable lines records them -- including the heartbeat,
# whose exit also re-invokes the supervisor (it runs --attention on any wake).
record_surfaced() {  # <actionable-signature>
  mkdir -p "$STATE" 2>/dev/null || true
  printf '%s\n' "$1" | sed '/^[[:space:]]*$/d' > "$SURFACED" 2>/dev/null || true
}

# Lines in the current actionable signature NOT yet shown to the supervisor.
# Same temp-file diff idiom as emit_diff_and_exit (no process substitution).
unsurfaced() {  # <cur-actionable>
  local ts out
  ts=$(mktemp)
  { cat "$SURFACED" 2>/dev/null || true; } >"$ts"
  out=$(printf '%s\n' "$1" | sed '/^[[:space:]]*$/d' | grep -vxF -f "$ts" || true)
  rm -f "$ts"
  printf '%s\n' "$out" | sed '/^[[:space:]]*$/d'
}

# Append-only triage log so absorbed benign churn is auditable (never silent).
log_benign() {  # <full-digest>
  mkdir -p "$STATE" 2>/dev/null || true
  { printf '[%s] benign churn absorbed (no actionable change):\n' "$(date '+%Y-%m-%dT%H:%M:%S')"
    printf '%s\n' "$1" | sed 's/^/  /'
  } >> "$TRIAGE_LOG" 2>/dev/null || true
}

[ -n "$MINE" ] && SCOPE="mine (owner=$FM_OWNER)" || SCOPE="global"

# Singleton guard: only ONE background watcher per supervisor (keyed on owner, so
# concurrent supervisors each get their own). A second `/first-mate watch` -- or a
# stray re-arm before the prior watcher exited -- would otherwise run two watchers,
# each waking the supervisor on the same fleet change (double turns). Keyed per
# owner; FM_WATCH_NO_LOCK=1 bypasses (tests / deliberate manual runs).
LOCKDIR="$STATE/.watch.${FM_OWNER:-global}.lock"
if [ -z "${FM_WATCH_NO_LOCK:-}" ]; then
  mkdir -p "$STATE"
  if ! fm_singleton_acquire "$LOCKDIR"; then
    echo "[fm-watch-bg] a watcher is already running for ${FM_OWNER:-global} (pid ${FM_LOCK_HELD_PID:-?}); not double-arming. Exiting."
    exit 0
  fi
  trap 'fm_singleton_release "$LOCKDIR"' EXIT INT TERM
fi

BASE_FULL="$(digest)"
BASE_ACT="$(actionable "$BASE_FULL")"
[ -f "$AFK_FLAG" ] && AFKLABEL=" [afk]" || AFKLABEL=""
echo "[fm-watch-bg] armed scope=$SCOPE${AFKLABEL}; $(printf '%s' "$BASE_FULL" | grep -c '::') crew in flight, $(printf '%s' "$BASE_ACT" | grep -c '::') actionable; poll=${POLL}s, cap=$((MAX_TICKS*POLL))s"
fm_wake_heartbeat "$WAKE_OWNER"

# Arm-time race guard (see header): anything actionable RIGHT NOW that no prior
# wake surfaced turned actionable in an arm gap -- wake immediately, don't
# baseline it away. In AFK mode BASE_ACT is already the narrowed critical subset,
# so routine `done` lines still batch rather than firing here.
ARM_NEW=$(unsurfaced "$BASE_ACT")
if [ -n "$ARM_NEW" ]; then
  echo "[fm-watch-bg] WAKE at arm -- actionable crew appeared between watcher runs:"
  printf '%s\n' "$ARM_NEW" | sed 's/^/  /'
  fm_wake_enqueue "$WAKE_OWNER" "actionable at arm (missed in watcher gap): $ARM_NEW" || true
  record_surfaced "$BASE_ACT"
  exit 0
fi

if printf '%s\n' "$BASE_ACT" | grep -q '^paused'; then
  echo "[fm-watch-bg] WAKE -- declared external wait reached its bounded recheck cadence:"
  printf '%s\n' "$BASE_ACT" | awk '$1 == "paused"' | sed 's/^/  /'
  fm_wake_enqueue "$WAKE_OWNER" "declared external wait recheck: $(printf '%s\n' "$BASE_ACT" | awk '$1 == "paused"')" || true
  record_surfaced "$BASE_ACT"
  exit 0
fi

# Emit the actionable lines now present that weren't in the baseline, then exit.
# No process substitution (`<()`): /dev/fd is unavailable when this runs as a
# harness background task -> "Bad file descriptor". Use temp files + grep -vxF.
emit_diff_and_exit() {  # <base-actionable> <cur-actionable> <elapsed-secs>
  echo "[fm-watch-bg] WAKE after ${3}s -- actionable fleet change:"
  local tb tc diff
  tb=$(mktemp) && tc=$(mktemp) && {
    printf '%s\n' "$1" >"$tb"; printf '%s\n' "$2" >"$tc"
    diff=$(grep -vxF -f "$tb" "$tc" || true)
    printf '%s\n' "$diff" | sed '/^$/d; s/^/  /'
    [ -n "$diff" ] && fm_wake_enqueue "$WAKE_OWNER" "actionable fleet change: $diff" || true
    rm -f "$tb" "$tc"
  }
  record_surfaced "$2"
  exit 0
}

i=0
afk_pending=0        # >0 while an AFK batch is settling: polls since last change
while [ "$i" -lt "$MAX_TICKS" ]; do
  sleep "$POLL"
  i=$((i + 1))
  fm_wake_heartbeat "$WAKE_OWNER"
  CUR_FULL="$(digest)"
  CUR_ACT="$(actionable "$CUR_FULL")"

  if [ "$CUR_ACT" != "$BASE_ACT" ]; then
    if [ -f "$AFK_FLAG" ]; then
      # AFK: don't wake on the first change; let the burst settle so multiple
      # events coalesce into one digested wake. Re-baseline to the latest each
      # time it changes and reset the quiet counter.
      BASE_ACT="$CUR_ACT"
      afk_pending=1
      continue
    fi
    emit_diff_and_exit "$BASE_ACT" "$CUR_ACT" "$((i * POLL))"
  fi

  # AFK batch settle: actionable signature held steady for AFK_SETTLE polls after
  # a change -> flush the accumulated batch as one wake.
  if [ "$afk_pending" -gt 0 ]; then
    if [ -f "$AFK_FLAG" ]; then
      afk_pending=$((afk_pending + 1))
      if [ "$afk_pending" -gt "$AFK_SETTLE" ]; then
        echo "[fm-watch-bg] WAKE after $((i * POLL))s -- AFK batch settled ($AFK_SETTLE quiet polls):"
        printf '%s\n' "$CUR_ACT" | sed 's/^/  /'
        fm_wake_enqueue "$WAKE_OWNER" "AFK batch settled: $CUR_ACT" || true
        record_surfaced "$CUR_ACT"
        exit 0
      fi
    else
      # Captain returned mid-batch (cleared .afk): flush immediately.
      echo "[fm-watch-bg] WAKE after $((i * POLL))s -- afk cleared, flushing batch:"
      printf '%s\n' "$CUR_ACT" | sed 's/^/  /'
      fm_wake_enqueue "$WAKE_OWNER" "AFK cleared; batch: $CUR_ACT" || true
      record_surfaced "$CUR_ACT"
      exit 0
    fi
  fi

  # Full digest moved but the actionable subset did not: benign churn. Absorb it
  # in bash -- log it, advance the full baseline, keep waiting. No LLM turn spent.
  if [ "$CUR_FULL" != "$BASE_FULL" ]; then
    log_benign "$CUR_FULL"
    BASE_FULL="$CUR_FULL"
  fi
done

echo "[fm-watch-bg] heartbeat: no actionable change after $((MAX_TICKS * POLL))s -- re-arm to keep watching"
printf '%s\n' "$CUR_ACT"
record_surfaced "$CUR_ACT"
exit 0
