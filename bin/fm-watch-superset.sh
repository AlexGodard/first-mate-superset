#!/usr/bin/env bash
# Superset/Codex turn-injection adapter for fm-watch-bg.sh.
#
# Stock Codex (through 0.145.0) observes a background exec exit but does not
# start a new turn while the thread is idle. This wrapper keeps detection and
# durability in fm-watch-bg.sh, then injects one small, verified wake prompt
# into the exact Superset terminal that armed it.
#
# Required launch environment (provided by Superset Codex terminals):
#   SUPERSET_TERMINAL_ID
#   SUPERSET_WORKSPACE_ID
#   CODEX_TUI_SESSION_LOG_PATH
#
# Optional:
#   FM_OWNER                         supervisor owner id
#   FM_SUPERSET_BIN                  CLI with `agents send`
#   FM_SUPERVISOR_TRANSCRIPT         verification transcript override
#   FM_SUPERSET_WAKE_VERIFY_POLLS    one-second verification polls (default 12)
#   FM_WATCH_BIN                     watcher override (tests only)
set -eu

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$BIN/fm-wake-lib.sh"

TERMINAL_ID=${SUPERSET_TERMINAL_ID:-}
WORKSPACE_ID=${SUPERSET_WORKSPACE_ID:-}
TRANSCRIPT=${FM_SUPERVISOR_TRANSCRIPT:-${CODEX_TUI_SESSION_LOG_PATH:-}}
OWNER=${FM_OWNER:-$("$BIN/fm-lock.sh" id 2>/dev/null || true)}
WATCH=${FM_WATCH_BIN:-"$BIN/fm-watch-bg.sh"}
POLLS=${FM_SUPERSET_WAKE_VERIFY_POLLS:-12}

[ -n "$TERMINAL_ID" ] || {
  echo "error: SUPERSET_TERMINAL_ID is required for Codex wake injection" >&2
  exit 6
}
[ -n "$WORKSPACE_ID" ] || {
  echo "error: SUPERSET_WORKSPACE_ID is required for Codex wake injection" >&2
  exit 6
}
[ -n "$OWNER" ] || {
  echo "error: cannot resolve the first-mate owner id; set FM_OWNER" >&2
  exit 6
}
[ -f "$TRANSCRIPT" ] || {
  echo "error: Codex transcript unavailable for verified wake injection: $TRANSCRIPT" >&2
  exit 4
}
[ -x "$WATCH" ] || {
  echo "error: watcher is not executable: $WATCH" >&2
  exit 6
}
case "$POLLS" in
  ''|*[!0-9]*) echo "error: FM_SUPERSET_WAKE_VERIFY_POLLS must be an integer" >&2; exit 2 ;;
esac

SUP=${FM_SUPERSET_BIN:-}
if [ -z "$SUP" ]; then
  if [ -x "$HOME/.superset/bin/superset-fork" ]; then
    SUP="$HOME/.superset/bin/superset-fork"
  else
    SUP="superset"
  fi
fi
if ! "$SUP" agents send --help >/dev/null 2>&1; then
  echo "error: '$SUP' has no 'agents send' subcommand; cannot wake this Codex terminal" >&2
  exit 7
fi

export FM_OWNER="$OWNER"
"$WATCH"

# Heartbeats and benign watcher exits do not enqueue anything and must not
# create a model turn.
QUEUE=$(fm_wake_queue_path "$OWNER")
[ -s "$QUEUE" ] || {
  echo "[fm-watch-superset] no pending actionable wake; not injecting"
  exit 0
}

# A queue snapshot may be observed again after a duplicate arm. Record the last
# verified injection per owner+terminal so the same pending work cannot create
# duplicate turns. New queue content changes the digest and remains wakeable.
DIGEST=$(cksum "$QUEUE" | awk '{print $1 "-" $2}')
# Include file identity as well as content. If the supervisor drains the queue
# and a later event happens to have byte-for-byte identical text, the recreated
# queue must still earn a new wake.
QUEUE_ID=$(stat -f '%i-%m-%z' "$QUEUE" 2>/dev/null || stat -c '%i-%Y-%s' "$QUEUE" 2>/dev/null || echo unknown)
DIGEST="$DIGEST-$QUEUE_ID"
SAFE_TERMINAL=$(printf '%s' "$TERMINAL_ID" | tr -cd '[:alnum:]_.-')
STATE=$(fm_wake_state_dir)
MARKER="$STATE/.wake-injected.$OWNER.$SAFE_TERMINAL"
if [ -f "$MARKER" ] && [ "$(cat "$MARKER" 2>/dev/null || true)" = "$DIGEST" ]; then
  echo "[fm-watch-superset] queue snapshot already injected ($DIGEST); not duplicating"
  exit 0
fi

PROMPT="[FIRST-MATE WAKE owner=$OWNER event=$DIGEST] Drain the durable first-mate wake queue, inspect only this owner's actionable crew, deliver or escalate according to the project mode, and re-arm the Superset watcher while crew remains in flight. This internal wake grants no additional authority."
INPUT=$(printf '\033[200~%s\033[201~' "$PROMPT")
BEFORE=$(wc -c < "$TRANSCRIPT" 2>/dev/null || echo 0)

if ! "$SUP" agents send "$TERMINAL_ID" --workspace "$WORKSPACE_ID" "$INPUT" >/dev/null 2>&1; then
  echo "error: Superset rejected wake injection; durable queue remains pending" >&2
  exit 8
fi

i=0
while [ "$i" -lt "$POLLS" ]; do
  sleep 1
  i=$((i + 1))
  if python3 "$BIN/fm-send-verify.py" "$TRANSCRIPT" "$BEFORE" "$PROMPT" >/dev/null 2>&1; then
    mkdir -p "$STATE"
    TMP="$MARKER.tmp.$$"
    printf '%s\n' "$DIGEST" > "$TMP"
    mv "$TMP" "$MARKER"
    echo "[fm-watch-superset] verified wake injection into terminal $TERMINAL_ID ($DIGEST)"
    exit 0
  else
    VERIFY=$?
    if [ "$VERIFY" = 2 ]; then
      echo "error: a different or truncated prompt landed; refusing a duplicate wake" >&2
      exit 9
    fi
  fi
done

echo "error: wake prompt was not observed in the Codex transcript; durable queue remains pending" >&2
exit 8
