#!/usr/bin/env bash
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY="$ROOT/bin/fm-send-verify.py"
SEND="$ROOT/bin/fm-send.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "fm-send live regression failed: $*" >&2
  exit 1
}

payload=$(python3 - <<'PY'
print("BEGIN_0000 " + "é漢字-" * 700 + " END_9999", end="")
PY
)

# The verifier only considers prompt-bearing rows appended after the send.
transcript="$TMP/verify.jsonl"
printf '%s\n' '{"type":"assistant","message":{"content":"old"}}' > "$transcript"
before=$(wc -c < "$transcript" | tr -d ' ')
python3 - "$transcript" "$payload" <<'PY'
import json, sys
with open(sys.argv[1], "a", encoding="utf-8") as stream:
    stream.write(json.dumps({"type": "queue-operation", "content": sys.argv[2]}, ensure_ascii=False) + "\n")
PY
python3 "$VERIFY" "$transcript" "$before" "$payload" || fail "exact queue-operation content was not accepted"

printf '%s\n' '{"type":"assistant","message":{"content":"old"}}' > "$transcript"
before=$(wc -c < "$transcript" | tr -d ' ')
python3 - "$transcript" "$payload" <<'PY'
import json, sys
with open(sys.argv[1], "a", encoding="utf-8") as stream:
    stream.write(json.dumps({"type": "attachment", "attachment": {"prompt": sys.argv[2][-1022:]}}, ensure_ascii=False) + "\n")
PY
set +e
python3 "$VERIFY" "$transcript" "$before" "$payload"
status=$?
set -e
[ "$status" -eq 2 ] || fail "truncated prompt returned $status instead of mismatch status 2"

printf '%s\n' '{"type":"assistant","message":{"content":"old"}}' > "$transcript"
before=$(wc -c < "$transcript" | tr -d ' ')
printf '%s\n' '{"type":"assistant","message":{"content":"unrelated growth"}}' >> "$transcript"
set +e
python3 "$VERIFY" "$transcript" "$before" "$payload"
status=$?
set -e
[ "$status" -eq 1 ] || fail "unrelated growth returned $status instead of not-observed status 1"

# Codex rollout dialect: event_msg/user_message and response_item role=user rows,
# nested under payload. Codex can merge input injected near a turn boundary into a
# larger pending user message, so an embedded-intact prompt must verify too.
printf '%s\n' '{"type":"event_msg","payload":{"type":"agent_message","message":"old"}}' > "$transcript"
before=$(wc -c < "$transcript" | tr -d ' ')
python3 - "$transcript" "$payload" <<'PY'
import json, sys
with open(sys.argv[1], "a", encoding="utf-8") as stream:
    stream.write(json.dumps({"type": "event_msg", "payload": {"type": "user_message", "message": sys.argv[2]}}, ensure_ascii=False) + "\n")
PY
python3 "$VERIFY" "$transcript" "$before" "$payload" || fail "codex event_msg user_message was not accepted"

printf '%s\n' '{"type":"event_msg","payload":{"type":"agent_message","message":"old"}}' > "$transcript"
before=$(wc -c < "$transcript" | tr -d ' ')
python3 - "$transcript" "$payload" <<'PY'
import json, sys
row = {"type": "response_item", "payload": {"type": "message", "role": "user",
       "content": [{"type": "input_text", "text": "earlier turn text\n" + sys.argv[2]}]}}
with open(sys.argv[1], "a", encoding="utf-8") as stream:
    stream.write(json.dumps(row, ensure_ascii=False) + "\n")
PY
python3 "$VERIFY" "$transcript" "$before" "$payload" || fail "codex merged response_item prompt was not accepted"

printf '%s\n' '{"type":"event_msg","payload":{"type":"agent_message","message":"old"}}' > "$transcript"
before=$(wc -c < "$transcript" | tr -d ' ')
python3 - "$transcript" "$payload" <<'PY'
import json, sys
with open(sys.argv[1], "a", encoding="utf-8") as stream:
    stream.write(json.dumps({"type": "event_msg", "payload": {"type": "user_message", "message": sys.argv[2][-1022:]}}, ensure_ascii=False) + "\n")
PY
set +e
python3 "$VERIFY" "$transcript" "$before" "$payload"
status=$?
set -e
[ "$status" -eq 2 ] || fail "truncated codex prompt returned $status instead of mismatch status 2"

# Integration stub: assert fm-send supplies bracketed-paste markers to the unchanged
# Superset CLI, then record the body as Claude Code would after interpreting them.
stub="$TMP/superset-stub"
cat > "$stub" <<'STUB'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = agents ] && [ "${2:-}" = send ] && [ "${3:-}" = --help ]; then
  exit 0
fi
[ "${1:-}" = agents ] && [ "${2:-}" = send ] || exit 64
python3 - "$TEST_TRANSCRIPT" "$STUB_MODE" "$TEST_COUNT" "${!#}" <<'PY'
import json, pathlib, sys
transcript, mode, count_path, value = sys.argv[1:]
start, end = "\x1b[200~", "\x1b[201~"
if not value.startswith(start) or not value.endswith(end):
    raise SystemExit("missing bracketed-paste envelope")
body = value[len(start):-len(end)]
count_file = pathlib.Path(count_path)
count = int(count_file.read_text() or "0") if count_file.exists() else 0
count_file.write_text(str(count + 1))
if mode == "truncate":
    body = body[-1022:]
if mode == "swallow":
    raise SystemExit(0)
with open(transcript, "a", encoding="utf-8") as stream:
    stream.write(json.dumps({"type": "queue-operation", "content": body}, ensure_ascii=False) + "\n")
PY
STUB
chmod +x "$stub"

wt="$TMP/worktree"
mkdir -p "$wt/.firstmate"
printf '%s\n' 'workspace=test-workspace' 'terminalId=test-terminal' > "$wt/.firstmate/superset"
printf '%s\n' 'project=testproj' 'kind=scout' 'workspace=-' > "$wt/.firstmate/meta"
projects="$TMP/projects"
san=$(printf '%s' "$wt" | sed 's/[/.]/-/g')
mkdir -p "$projects/$san"
live_transcript="$projects/$san/session.jsonl"
printf '%s\n' '{"type":"assistant","message":{"content":"old"}}' > "$live_transcript"
count="$TMP/send-count"
printf '0' > "$count"

run_send() {
  STUB_MODE="$1" \
  TEST_TRANSCRIPT="$live_transcript" \
  TEST_COUNT="$count" \
  FM_CCS_PROJECTS_DIR="$projects" \
  FM_SUPERSET_BIN="$stub" \
  FM_LIVE_QUIET_S=1 \
  FM_LIVE_WAIT_S=2 \
    bash "$SEND" --raw "$wt" "$payload"
}

status_lines() { wc -l < "$wt/.firstmate/status" 2>/dev/null || echo 0; }

output=$(run_send exact 2>&1) || fail "exact live send failed: $output"
case "$output" in
  *"exact prompt verified"*) ;;
  *) fail "exact live send did not report exact verification: $output" ;;
esac
[ "$(cat "$count")" -eq 1 ] || fail "exact live send was attempted more than once"

# Workspace-id addressing resolves through the capture sidecar, because the brief
# seeds workspace=- in meta before the actual Superset workspace id is known.
printf '%s\n' '{"type":"assistant","message":{"content":"old"}}' > "$live_transcript"
printf '0' > "$count"
output=$(STUB_MODE=exact \
  TEST_TRANSCRIPT="$live_transcript" \
  TEST_COUNT="$count" \
  SUPERSET_WORKTREES="$TMP" \
  FM_CCS_PROJECTS_DIR="$projects" \
  FM_SUPERSET_BIN="$stub" \
  FM_LIVE_QUIET_S=1 \
  FM_LIVE_WAIT_S=2 \
  bash "$SEND" --raw test-workspace "$payload" 2>&1) \
  || fail "workspace-id live send failed: $output"
case "$output" in
  *"exact prompt verified"*) ;;
  *) fail "workspace-id live send was not transcript-verified: $output" ;;
esac
[ "$(cat "$count")" -eq 1 ] || fail "workspace-id live send was attempted more than once"

printf '%s\n' '{"type":"assistant","message":{"content":"old"}}' > "$live_transcript"
printf '0' > "$count"
before_status=$(status_lines)
set +e
output=$(run_send truncate 2>&1)
status=$?
set -e
[ "$status" -eq 5 ] || fail "truncated live send returned $status instead of 5: $output"
[ "$(cat "$count")" -eq 1 ] || fail "truncated live send was retried or duplicated"
case "$output" in
  *"refusing to retry or duplicate"*) ;;
  *) fail "truncated live send did not explain safe refusal: $output" ;;
esac
[ "$(status_lines)" -eq "$before_status" ] || fail "truncated live send appended to status despite failing"

# --- FAIL-HARD: verify timeout (send lands nowhere) exits 8, appends nothing ---
printf '%s\n' '{"type":"assistant","message":{"content":"old"}}' > "$live_transcript"
printf '0' > "$count"
before_status=$(status_lines)
set +e
output=$(FM_LIVE_TRIES=2 FM_LIVE_POLL_S=1 run_send swallow 2>&1)
status=$?
set -e
[ "$status" -eq 8 ] || fail "verify-timeout returned $status instead of 8: $output"
[ "$(cat "$count")" -eq 2 ] || fail "verify-timeout attempted $(cat "$count") sends instead of FM_LIVE_TRIES=2"
case "$output" in
  *"not observed"*) ;;
  *) fail "verify-timeout error did not name the failed precondition: $output" ;;
esac
[ "$(status_lines)" -eq "$before_status" ] || fail "verify-timeout appended to status despite failing"

# --- FAIL-HARD: missing sidecar exits 6, sends nothing, appends nothing --------
nosc="$TMP/no-sidecar-worktree"
mkdir -p "$nosc/.firstmate"
printf '0' > "$count"
set +e
output=$(STUB_MODE=exact TEST_TRANSCRIPT="$live_transcript" TEST_COUNT="$count" \
  FM_CCS_PROJECTS_DIR="$projects" FM_SUPERSET_BIN="$stub" \
  bash "$SEND" --raw "$nosc" "hello" 2>&1)
status=$?
set -e
[ "$status" -eq 6 ] || fail "missing sidecar returned $status instead of 6: $output"
[ "$(cat "$count")" -eq 0 ] || fail "missing sidecar still attempted a send"
case "$output" in
  *".firstmate/superset"*"fm-capture-session"*) ;;
  *) fail "missing-sidecar error did not name the sidecar and its writer: $output" ;;
esac
[ ! -s "$nosc/.firstmate/status" ] || fail "missing sidecar appended to status despite failing"

# --- FAIL-HARD: CLI without 'agents send' exits 7 ------------------------------
nocli="$TMP/no-agents-send"
printf '%s\n' '#!/usr/bin/env bash' 'exit 64' > "$nocli"
chmod +x "$nocli"
set +e
output=$(FM_CCS_PROJECTS_DIR="$projects" FM_SUPERSET_BIN="$nocli" \
  bash "$SEND" --raw "$wt" "hello" 2>&1)
status=$?
set -e
[ "$status" -eq 7 ] || fail "CLI without agents send returned $status instead of 7: $output"
case "$output" in
  *"agents send"*) ;;
  *) fail "no-agents-send error did not name the missing subcommand: $output" ;;
esac

# --- FAIL-HARD: no transcript to verify against exits 4, sends nothing ---------
nt="$TMP/no-transcript-worktree"
mkdir -p "$nt/.firstmate"
printf '%s\n' 'workspace=nt-ws' 'terminalId=nt-term' > "$nt/.firstmate/superset"
printf '0' > "$count"
set +e
output=$(STUB_MODE=exact TEST_TRANSCRIPT="$live_transcript" TEST_COUNT="$count" \
  FM_CCS_PROJECTS_DIR="$projects" FM_CODEX_HOME="$TMP/empty-codex-home" \
  FM_SUPERSET_BIN="$stub" \
  bash "$SEND" --raw "$nt" "hello" 2>&1)
status=$?
set -e
[ "$status" -eq 4 ] || fail "no-transcript returned $status instead of 4: $output"
[ "$(cat "$count")" -eq 0 ] || fail "no-transcript still attempted a blind send"
case "$output" in
  *"no Claude Code transcript"*"no Codex rollout"*) ;;
  *) fail "no-transcript error did not name both transcript sources: $output" ;;
esac
[ ! -s "$nt/.firstmate/status" ] || fail "no-transcript appended to status despite failing"

# --- FAIL-HARD: FM_LIVE_SEND=0 (retired fork-resume escape hatch) is an error --
set +e
output=$(FM_LIVE_SEND=0 FM_CCS_PROJECTS_DIR="$projects" FM_SUPERSET_BIN="$stub" \
  bash "$SEND" --raw "$wt" "hello" 2>&1)
status=$?
set -e
[ "$status" -eq 2 ] || fail "FM_LIVE_SEND=0 returned $status instead of 2: $output"
case "$output" in
  *"removed"*) ;;
  *) fail "FM_LIVE_SEND=0 error did not say the fallback lanes were removed: $output" ;;
esac

# --- Codex (ccsxp) crew: live send verified against the rollout ----------------
# No Claude transcript exists for this worktree; a Codex rollout under
# FM_CODEX_HOME/sessions carries its cwd, so the live lane resolves + verifies
# against it.
cwt="$TMP/codex-worktree"
mkdir -p "$cwt/.firstmate"
printf '%s\n' 'workspace=codex-ws' 'terminalId=codex-term' > "$cwt/.firstmate/superset"
codex_home="$TMP/codex-home"
mkdir -p "$codex_home/sessions/2026/07/20"
codex_rollout="$codex_home/sessions/2026/07/20/rollout-2026-07-20T00-00-00-11111111-2222-3333-4444-555555555555.jsonl"
# Codex records the RESOLVED cwd in compact JSON — mirror that (fm-send matches
# on `pwd -P` of the worktree against the literal `"cwd":"…"` bytes).
python3 - "$codex_rollout" "$(cd "$cwt" && pwd -P)" <<'PY'
import json, sys
row = {"type": "session_meta", "payload": {"id": "11111111-2222-3333-4444-555555555555", "cwd": sys.argv[2]}}
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    stream.write(json.dumps(row, separators=(",", ":")) + "\n")
PY

# stub records into the rollout using the Codex user_message shape
cat > "$TMP/codex-stub" <<'STUB'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = agents ] && [ "${2:-}" = send ] && [ "${3:-}" = --help ]; then
  exit 0
fi
[ "${1:-}" = agents ] && [ "${2:-}" = send ] || exit 64
python3 - "$TEST_TRANSCRIPT" "${!#}" <<'PY'
import json, sys
transcript, value = sys.argv[1:]
start, end = "\x1b[200~", "\x1b[201~"
if not value.startswith(start) or not value.endswith(end):
    raise SystemExit("missing bracketed-paste envelope")
body = value[len(start):-len(end)]
with open(transcript, "a", encoding="utf-8") as stream:
    stream.write(json.dumps({"type": "event_msg", "payload": {"type": "user_message", "message": body}}, ensure_ascii=False) + "\n")
PY
STUB
chmod +x "$TMP/codex-stub"

output=$(TEST_TRANSCRIPT="$codex_rollout" \
  FM_CCS_PROJECTS_DIR="$projects" \
  FM_CODEX_HOME="$codex_home" \
  FM_SUPERSET_BIN="$TMP/codex-stub" \
  FM_LIVE_QUIET_S=1 FM_LIVE_WAIT_S=2 \
  bash "$SEND" --raw "$cwt" "$payload" 2>&1) || fail "codex live send failed: $output"
case "$output" in
  *"exact prompt verified"*) ;;
  *) fail "codex live send was not transcript-verified: $output" ;;
esac
grep -q "captain replied (live send to terminal codex-term)$" "$cwt/.firstmate/status" \
  || fail "codex live send did not append a verified status line"

echo "fm-send live regression: PASS"
