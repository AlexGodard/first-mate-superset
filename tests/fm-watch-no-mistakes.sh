#!/usr/bin/env bash
# Regression: after the captain answers a no-mistakes gate directly, the run can
# finish without the crewmate appending another .firstmate/status event. The
# watcher must reconcile authoritative run state and surface terminal completion.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export SUPERSET_WORKTREES="$TMP/worktrees"
export FM_STATE_OVERRIDE="$TMP/state"
export NM_SCENARIO_FILE="$TMP/no-mistakes-state"
export PATH="$TMP/stubbin:$PATH"

WT="$SUPERSET_WORKTREES/test-project/fm/axi-completion"
mkdir -p "$WT/.firstmate" "$FM_STATE_OVERRIDE" "$TMP/stubbin"
git -C "$WT" init -q
git -C "$WT" checkout -qb fm/axi-completion

printf '%s\n' \
  'project=test-project' \
  'kind=ship' \
  'mode=no-mistakes' \
  'branch=fm/axi-completion' \
  'owner=completion-owner' > "$WT/.firstmate/meta"
printf '%s\n' 'needs-decision: approve review finding?' > "$WT/.firstmate/status"
printf '%s\n' 'running' > "$NM_SCENARIO_FILE"

cat > "$TMP/stubbin/no-mistakes" <<'EOF'
#!/usr/bin/env bash
state=$(cat "$NM_SCENARIO_FILE")
if [ "$1 $2" = "axi status" ]; then
  if [ "$state" = running ]; then
    printf '%s\n' \
      'run:' \
      '  branch: fm/axi-completion' \
      '  status: running'
  else
    printf '%s\n' \
      'run:' \
      '  branch: fm/axi-completion' \
      '  status: completed' \
      'outcome: checks-passed'
  fi
fi
EOF
chmod +x "$TMP/stubbin/no-mistakes"

# The gate event was already shown to the captain. A raw status-log watcher must
# not wake on it again; only the later authoritative terminal transition counts.
FM_OWNER=completion-owner "$BIN/fm-fleet.sh" --mine \
  > "$FM_STATE_OVERRIDE/.last-surfaced.completion-owner"

WATCH_OUT="$TMP/watcher.out"
FM_OWNER=completion-owner \
FM_WATCH_NO_LOCK=1 \
FM_POLL=1 \
FM_MAX_TICKS=2 \
  "$BIN/fm-watch-bg.sh" > "$WATCH_OUT" 2>&1 &
WATCH_PID=$!

for _ in 1 2 3 4 5 6 7 8 9 10; do
  grep -q 'armed scope=' "$WATCH_OUT" 2>/dev/null && break
  sleep 0.1
done
grep -q 'armed scope=' "$WATCH_OUT"

# This is the state change produced while `axi respond` drives the remaining
# pipeline. Deliberately do not touch .firstmate/status.
printf '%s\n' 'completed' > "$NM_SCENARIO_FILE"
wait "$WATCH_PID"

CREW_STATE=$("$BIN/fm-crew-state.sh" "$WT")
printf '%s\n' "$CREW_STATE"
cat "$WATCH_OUT"

printf '%s\n' "$CREW_STATE" | grep -q 'state: done'
grep -q '0 actionable' "$WATCH_OUT"
grep -q 'WAKE' "$WATCH_OUT"
grep -q 'done' "$WATCH_OUT"
grep -q 'actionable fleet change' "$FM_STATE_OVERRIDE/.wake-queue.completion-owner"
[ "$(grep -c 'WAKE' "$WATCH_OUT")" -eq 1 ]
[ "$(grep -c 'actionable fleet change' "$FM_STATE_OVERRIDE/.wake-queue.completion-owner")" -eq 1 ]

echo "fm-watch no-mistakes completion regression: PASS"
