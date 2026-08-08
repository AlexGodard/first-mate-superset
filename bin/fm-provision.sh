#!/usr/bin/env bash
# fm-provision.sh <worktree> <workspace-id> <main-checkout> — supervised worktree
# provisioning for a dispatched crewmate. Runs the repo's setup script with one
# retry, logging to a DURABLE file under ~/.local/state/fm/provision/ (the
# worktree's .firstmate/provision.log is a symlink to it, so the evidence
# survives `superset ws delete` — the 2026-08-02 fleet failure was undiagnosable
# because every provision.log died with its worktree). On final failure it
# writes .firstmate/provision-failed, which fm-fleet.sh surfaces and the ship
# brief tells crews to report as BLOCKED instead of silently waiving UI
# evidence. Designed to be nohup'd by fm-spawn step 7.5.
set -u

WT="${1:?usage: fm-provision.sh <worktree> <workspace-id> <main-checkout>}"
WSID="${2:?workspace id}"
MAIN="${3:?main checkout path}"

STATE_DIR="$HOME/.local/state/fm/provision"
mkdir -p "$STATE_DIR" "$WT/.firstmate"
DLOG="$STATE_DIR/$(date +%Y%m%d-%H%M%S)-$(basename "$WT").log"
: > "$DLOG"
ln -sf "$DLOG" "$WT/.firstmate/provision.log"

cd "$WT" || { echo "fm-provision: cannot cd $WT" >> "$DLOG"; exit 1; }

log() { printf '%s %s\n' "$(date +%FT%T)" "$*" >> "$DLOG"; }

if [ -f "$WT/.superset/setup-complete" ]; then
  log "sentinel already present — nothing to do."
  rm -f "$WT/.firstmate/provision-failed"
  exit 0
fi

for attempt in 1 2; do
  log "provision attempt $attempt starting (worktree $WT)"
  if SUPERSET_WORKSPACE_PATH="$WT" SUPERSET_WORKSPACE_ID="$WSID" SUPERSET_ROOT_PATH="$MAIN" \
       bash scripts/superset/setup-worktree.sh >> "$DLOG" 2>&1; then
    log "provision OK on attempt $attempt"
    rm -f "$WT/.firstmate/provision-failed"
    exit 0
  fi
  log "provision attempt $attempt FAILED"
  [ "$attempt" = 1 ] && sleep 30
done

log "PROVISION FAILED after 2 attempts — dev servers will not boot in this worktree."
{
  echo "provisioning failed $(date +%FT%T); full log: $DLOG"
  tail -15 "$DLOG"
} > "$WT/.firstmate/provision-failed"
exit 1
