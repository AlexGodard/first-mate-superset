#!/usr/bin/env bash
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/state"; mkdir -p "$STATE"
TRANSCRIPT="$TMP/rollout.jsonl"; : > "$TRANSCRIPT"
CALLS="$TMP/calls"; : > "$CALLS"

cat > "$TMP/watcher" <<'EOF'
#!/usr/bin/env bash
q="$FM_STATE_OVERRIDE/.wake-queue.$FM_OWNER"
[ -s "$q" ] || printf '2026-07-27T18:00:00Z\tactionable fleet change: done test\n' > "$q"
echo "stub watcher completed"
EOF

cat > "$TMP/superset" <<'EOF'
#!/usr/bin/env bash
if [ "$1 $2 $3" = "agents send --help" ]; then exit 0; fi
[ "$1 $2" = "agents send" ] || exit 2
printf 'send\n' >> "$WAKE_TEST_CALLS"
python3 - "$WAKE_TEST_TRANSCRIPT" "${@: -1}" <<'PY'
import json, sys
path, value = sys.argv[1], sys.argv[2]
value = value.removeprefix("\x1b[200~").removesuffix("\x1b[201~")
if __import__("os").environ.get("WAKE_TEST_DIALECT") == "tui":
    record = {
        "dir": "from_tui",
        "kind": "op",
        "payload": {
            "UserTurn": {
                "items": [{"type": "text", "text": value}],
            }
        },
    }
else:
    record = {"type": "event_msg", "payload": {"type": "user_message", "message": value}}
with open(path, "a") as stream:
    stream.write(json.dumps(record) + "\n")
PY
EOF
chmod +x "$TMP/watcher" "$TMP/superset"

run_adapter() {
  FM_OWNER=owner-test \
  FM_STATE_OVERRIDE="$STATE" \
  FM_WATCH_BIN="$TMP/watcher" \
  FM_SUPERSET_BIN="$TMP/superset" \
  FM_SUPERVISOR_TRANSCRIPT="$TRANSCRIPT" \
  FM_SUPERSET_WAKE_VERIFY_POLLS=2 \
  SUPERSET_TERMINAL_ID=term-test \
  SUPERSET_WORKSPACE_ID=ws-test \
  WAKE_TEST_TRANSCRIPT="$TRANSCRIPT" \
  WAKE_TEST_CALLS="$CALLS" \
  "$ROOT/bin/fm-watch-superset.sh"
}

run_adapter | grep -q "verified wake injection"
[ "$(wc -l < "$CALLS" | tr -d ' ')" = 1 ]
grep -q "\\[FIRST-MATE WAKE owner=owner-test event=" "$TRANSCRIPT"

# The same still-pending queue snapshot must not inject twice.
run_adapter | grep -q "already injected"
[ "$(wc -l < "$CALLS" | tr -d ' ')" = 1 ]

# New durable work changes the digest and earns exactly one new wake.
printf '2026-07-27T18:01:00Z\tactionable fleet change: blocked test\n' \
  >> "$STATE/.wake-queue.owner-test"
run_adapter | grep -q "verified wake injection"
[ "$(wc -l < "$CALLS" | tr -d ' ')" = 2 ]

# Draining and recreating an identical queue is a distinct event generation.
SAVED=$(cat "$STATE/.wake-queue.owner-test")
rm "$STATE/.wake-queue.owner-test"
printf '%s' "$SAVED" > "$STATE/.wake-queue.owner-test"
run_adapter | grep -q "verified wake injection"
[ "$(wc -l < "$CALLS" | tr -d ' ')" = 3 ]

# Preconditions fail before the watcher can run or a blind send can occur.
if FM_OWNER=owner-test FM_STATE_OVERRIDE="$STATE" FM_WATCH_BIN="$TMP/watcher" \
  FM_SUPERSET_BIN="$TMP/superset" FM_SUPERVISOR_TRANSCRIPT="$TRANSCRIPT" \
  SUPERSET_WORKSPACE_ID=ws-test "$ROOT/bin/fm-watch-superset.sh" >/dev/null 2>&1; then
  echo "missing terminal id unexpectedly succeeded" >&2
  exit 1
fi

# Real Superset Codex terminals expose CODEX_TUI_SESSION_LOG_PATH, whose input
# records use the op/UserTurn dialect rather than standard rollout event_msg rows.
TUI_STATE="$TMP/tui-state"; mkdir -p "$TUI_STATE"
TUI_TRANSCRIPT="$TMP/tui-session.jsonl"; : > "$TUI_TRANSCRIPT"
TUI_CALLS="$TMP/tui-calls"; : > "$TUI_CALLS"
FM_OWNER=owner-tui \
FM_STATE_OVERRIDE="$TUI_STATE" \
FM_WATCH_BIN="$TMP/watcher" \
FM_SUPERSET_BIN="$TMP/superset" \
CODEX_TUI_SESSION_LOG_PATH="$TUI_TRANSCRIPT" \
FM_SUPERSET_WAKE_VERIFY_POLLS=2 \
SUPERSET_TERMINAL_ID=term-tui \
SUPERSET_WORKSPACE_ID=ws-tui \
WAKE_TEST_DIALECT=tui \
WAKE_TEST_TRANSCRIPT="$TUI_TRANSCRIPT" \
WAKE_TEST_CALLS="$TUI_CALLS" \
  "$ROOT/bin/fm-watch-superset.sh" | grep -q "verified wake injection"
[ "$(wc -l < "$TUI_CALLS" | tr -d ' ')" = 1 ]
grep -q '"UserTurn"' "$TUI_TRANSCRIPT"

echo "fm-watch-superset tests passed"
