#!/usr/bin/env bash
# Send the captain's reply to a crewmate by injecting it into the LIVE desktop
# session -- the Superset port of Firstmate's `fm-send.sh` (which typed a line
# into the live crewmate tmux pane). Superset runs each crewmate inside an
# Electron-managed PTY; the fork CLI's `superset agents send <terminalId>
# --workspace <id>` (AlexGodard/superset PR #1 + #2) writes into that PTY, so
# the reply renders in the desktop pane and the crewmate resumes its SAME
# session with full context.
#
# THIS SCRIPT FAILS HARD. There are no fallback lanes: if any precondition of
# the live send is missing, it exits non-zero with an error naming exactly which
# precondition failed, sends nothing it can't verify, and appends nothing to
# .firstmate/status. (The old fork-resume / exec-resume / single-shot-unverified
# fallbacks silently degraded and masked real breakage for weeks — captain's
# order 2026-07-20: fail loudly so the underlying bug gets fixed.) If it errors,
# the manual last resorts are `superset ws open` (captain types in the pane) or
# `superset agents create` (context-losing) — a human decision, never automatic.
#
# The live send is VERIFIED: after injecting, we poll the crewmate's transcript
# (Claude Code transcript, or the Codex rollout for Codex crews — both dialects
# read by fm-send-verify.py) until the EXACT prompt appears. Only then do we
# append the "captain replied" line to .firstmate/status.
#
# Usage:
#   fm-send.sh <worktree-path|workspaceId> <message...>
#   fm-send.sh --raw <worktree|workspaceId> <message...>   # send verbatim (no wrapper)
#
#   <worktree-path>  a crewmate worktree dir (fm-fleet.sh --raw prints it in [..])
#   <workspaceId>    the Superset workspace id (matched against .firstmate/meta workspace=)
#   <message>        the captain's reply / steer (the remaining args, joined)
#
# Exit codes (each names the precondition that failed; fix it, don't work around):
#   2  usage error, or FM_LIVE_SEND=0 (the fork-resume escape hatch was removed)
#   3  workspace id resolves to no worktree under $SUPERSET_WORKTREES
#   4  no transcript to verify against (no Claude transcript dir for the cwd AND
#      no Codex rollout referencing it) -- nothing was sent
#   5  verifier saw DIFFERENT/TRUNCATED input (mismatch); refusing to retry or
#      duplicate -- inspect the pane before resending
#   6  no .firstmate/superset sidecar (or it lacks workspace=/terminalId=);
#      fm-capture-session.sh writes it at dispatch
#   7  resolved superset CLI has no `agents send` (need the fork build)
#   8  exact prompt not observed in the transcript after all attempts (send may
#      be landing nowhere: dead PTY? wrong terminalId? desktop restarted?)
#
# Env:
#   FM_CCS_PROJECTS_DIR   transcript base (default: $CLAUDE_CONFIG_DIR/projects,
#                         else ~/.claude/projects — the single merged config home)
#   FM_CODEX_HOME         Codex home for Codex crews (default: $CODEX_HOME or ~/.codex);
#                         rollouts live under $FM_CODEX_HOME/sessions
#   SUPERSET_WORKTREES    worktree root for workspaceId resolution (default: ~/.superset/worktrees)
#   FM_SUPERSET_BIN       superset CLI used for the send. Default: ~/.superset/bin/
#                         superset-fork if present, else `superset`. Must have `agents send`.
#   FM_LIVE_QUIET_S       seconds the transcript must stay unchanged before we treat
#                         the crewmate's turn as ENDED and send (default 4). Guards
#                         the readiness race (input during an active turn is dropped).
#   FM_LIVE_WAIT_S        max seconds to wait for that quiet window (default 45).
#   FM_LIVE_TRIES         send attempts before giving up with exit 8 (default 5).
#   FM_LIVE_POLL_S        verify polls (1/s) per attempt (default 6).
set -eu

BIN_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$BIN_SELF/fm-watch-guard.sh" >/dev/null || true

WRAP=1
if [ "${1:-}" = "--raw" ]; then WRAP=0; shift; fi
TARGET="${1:-}"; shift || true
MSG="$*"
[ -n "$TARGET" ] && [ -n "$MSG" ] || { echo "usage: fm-send.sh [--raw] <worktree|workspaceId> <message...>" >&2; exit 2; }

if [ "${FM_LIVE_SEND:-1}" = "0" ]; then
  echo "error: FM_LIVE_SEND=0 requested the fork-resume lane, but the fallback lanes were removed (2026-07-20, fail-hard rewrite). The live send is the only lane; unset FM_LIVE_SEND." >&2
  exit 2
fi

ROOT="${SUPERSET_WORKTREES:-$HOME/.superset/worktrees}"

# --- 1. resolve the crewmate worktree dir -------------------------------------
if [ -d "$TARGET" ] && [ -d "$TARGET/.firstmate" ]; then
  WT="$TARGET"
elif [ -d "$TARGET" ]; then
  WT="$TARGET"                       # a dir without .firstmate -- trust it anyway
else
  # Treat as a workspace id. The actual id is captured in the live-session
  # sidecar because the crewmate brief is generated before ws create and seeds
  # workspace=- in meta. Search sidecars first; retain meta as a legacy fallback.
  WT=""
  while IFS= read -r sidecar; do
    [ -n "$sidecar" ] || continue
    if grep -q "^workspace=$TARGET$" "$sidecar" 2>/dev/null; then
      WT=$(dirname "$(dirname "$sidecar")"); break
    fi
  done < <(find "$ROOT" -maxdepth 8 \( -name node_modules -o -name .git \) -prune -o \
           -type f -path '*/.firstmate/superset' -print 2>/dev/null | sort)

  # Backward compatibility for older/manual crews that recorded the concrete
  # workspace id directly in meta.
  if [ -z "$WT" ]; then
  while IFS= read -r meta; do
    [ -n "$meta" ] || continue
    if grep -q "^workspace=$TARGET$" "$meta" 2>/dev/null; then
      WT=$(dirname "$(dirname "$meta")"); break
    fi
  done < <(find "$ROOT" -maxdepth 8 \( -name node_modules -o -name .git \) -prune -o \
           -type f -path '*/.firstmate/meta' -print 2>/dev/null | sort)
  fi
  [ -n "$WT" ] || { echo "error: no worktree for workspace '$TARGET' under $ROOT (pass the worktree path instead)" >&2; exit 3; }
fi

# crewmate's Claude Code cwd is the worktree root (where Superset launched it)
CWD=$(cd "$WT" && pwd -P)

# --- 1a. transcript base ------------------------------------------------------
# All Claude crews share the single merged config home (~/.claude, or
# CLAUDE_CONFIG_DIR when set) since the claude-swap migration — the old per-repo
# wavo/personal CCS instance split is gone. FM_CCS_PROJECTS_DIR overrides.
PROJECTS_DIR="${FM_CCS_PROJECTS_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects}"

# --- 1b. Codex rollout lookup (Codex crews) -----------------------------------
# Codex crewmates don't write Claude transcripts, but Codex keeps
# its own append-only rollout at $CODEX_HOME/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl
# with the launch cwd in the first line (session_meta). That gives Codex crews the
# same resolve-by-worktree + verify-by-transcript contract as Claude crews.
CODEX_SESS="${FM_CODEX_HOME:-${CODEX_HOME:-$HOME/.codex}}/sessions"
codex_rollout_for_cwd() {
  # newest rollout whose session_meta cwd == $1 (rollout paths have no spaces)
  local f
  for f in $(ls -t "$CODEX_SESS"/*/*/*/rollout-*.jsonl 2>/dev/null); do
    if head -c 4096 "$f" 2>/dev/null | grep -Fq "\"cwd\":\"$1\""; then
      printf '%s\n' "$f"
      return 0
    fi
  done
  return 1
}

# --- 2. preconditions of the live send (each miss is a HARD error) ------------
SUP="${FM_SUPERSET_BIN:-}"
if [ -z "$SUP" ]; then
  if [ -x "$HOME/.superset/bin/superset-fork" ]; then SUP="$HOME/.superset/bin/superset-fork"; else SUP="superset"; fi
fi

SC="$WT/.firstmate/superset"
LWSID=""; LTID=""
if [ -f "$SC" ]; then
  LWSID=$(sed -n 's/^workspace=//p' "$SC" | head -1)
  LTID=$(sed -n 's/^terminalId=//p' "$SC" | head -1)
fi
if [ -z "$LTID" ] || [ -z "$LWSID" ]; then
  echo "error: no live-session sidecar: $SC missing or lacks workspace=/terminalId= lines. fm-capture-session.sh writes it at dispatch — re-run it against this worktree's desktop session, then retry." >&2
  exit 6
fi

if ! "$SUP" agents send --help >/dev/null 2>&1; then
  echo "error: '$SUP' has no 'agents send' subcommand — the live send needs the fork CLI (AlexGodard/superset, built at ~/.superset/bin/superset-fork). Rebuild it (packages/cli: bun run build:darwin-arm64) or point FM_SUPERSET_BIN at it." >&2
  exit 7
fi

# --- 3. resolve the transcript we will verify against (Claude, then Codex) ----
LSAN=$(printf '%s' "$CWD" | sed 's/[/.]/-/g')
LTDIR="$PROJECTS_DIR/$LSAN"
[ -d "$LTDIR" ] || LTDIR=$(ls -dt "$PROJECTS_DIR"/*-"$(basename "$CWD" | sed 's/[/.]/-/g')" 2>/dev/null | head -1 || true)
LTRANS=""; [ -n "$LTDIR" ] && LTRANS=$(ls -t "$LTDIR"/*.jsonl 2>/dev/null | head -1 || true)
if [ -z "$LTRANS" ]; then
  LTRANS=$(codex_rollout_for_cwd "$CWD" || true)
  [ -n "$LTRANS" ] && LTDIR=$(dirname "$LTRANS")
fi
if [ -z "$LTRANS" ]; then
  echo "error: nothing to verify against — no Claude Code transcript for $CWD (looked in $PROJECTS_DIR) and no Codex rollout under $CODEX_SESS references it. An unverifiable send is a blind send (that's what duplicated replies 5x on 2026-07-11), so nothing was sent. Check FM_CCS_PROJECTS_DIR routing, or whether the crewmate ever started." >&2
  exit 4
fi

# --- 4. compose the prompt ----------------------------------------------------
LIVEMSG=$(printf '%s' "$MSG" | tr '\n' ' ')
if [ "$WRAP" = 1 ]; then
  LIVEPROMPT="[CAPTAIN REPLY — relayed by the first mate] $LIVEMSG — Resume your task using this decision; keep reporting through .firstmate/status (append the next phase line, and \`done: …\` when finished)."
else
  LIVEPROMPT="$LIVEMSG"
fi
# NB: no CR appended here. `agents send` submits its argument first and a
# standalone \r second (fork PR #2). We wrap only the argument in bracketed-paste
# markers so multi-read PTY input stays one prompt:
#   1. SUBMIT BYTE: the TUI submits on CR (\r = Enter), NOT LF.
#   2. LONG INPUT: macOS PTY reads split larger input into chunks; without an
#      ESC[200~/ESC[201~ envelope Claude Code may retain only the final chunk.
#   3. READINESS RACE: a send just before the prompt is re-armed can be dropped.
LIVEINPUT=$(printf '\033[200~%s\033[201~' "$LIVEPROMPT")

# --- 5. wait for the crewmate's turn to END (readiness race, gotcha #3) -------
# The crewmate writes its needs-decision status line MID-TURN — its turn keeps
# going before it returns to the input prompt, and input sent during an active
# turn is DROPPED by the TUI (not even buffered). Wait for the transcript to go
# QUIET (no new lines for FM_LIVE_QUIET_S consecutive seconds), capped at
# FM_LIVE_WAIT_S; then the prompt is armed and a CR-terminated send submits.
QUIET_S="${FM_LIVE_QUIET_S:-4}"; WAIT_S="${FM_LIVE_WAIT_S:-45}"
waited=0; lastn=-1; quiet=0
while [ "$waited" -lt "$WAIT_S" ]; do
  curn=$(wc -l < "$LTRANS" 2>/dev/null || echo 0)
  if [ "$curn" = "$lastn" ]; then
    quiet=$((quiet + 1)); [ "$quiet" -ge "$QUIET_S" ] && break
  else
    quiet=0; lastn=$curn
  fi
  sleep 1; waited=$((waited + 1))
done

BEFORE=$(wc -c < "$LTRANS" 2>/dev/null || echo 0)

# --- 6. send, then verify the EXACT prompt landed -----------------------------
# Retry only when NO prompt-bearing record appeared (the drop case); transcript
# growth alone can be an away summary and is not proof this input landed. A
# DIFFERENT/truncated prompt aborts immediately — retrying a mismatch is how
# duplicates happen.
TRIES="${FM_LIVE_TRIES:-5}"; POLL_S="${FM_LIVE_POLL_S:-6}"
LIVE_OK=0
LIVE_MISMATCH=0
attempt=0
while [ "$attempt" -lt "$TRIES" ]; do
  attempt=$((attempt + 1))
  "$SUP" agents send "$LTID" --workspace "$LWSID" "$LIVEINPUT" >/dev/null 2>&1 || true
  poll=0
  while [ "$poll" -lt "$POLL_S" ]; do
    sleep 1; poll=$((poll + 1))
    if python3 "$BIN_SELF/fm-send-verify.py" "$LTRANS" "$BEFORE" "$LIVEPROMPT" >/dev/null 2>&1; then
      LIVE_OK=1
      break
    else
      VERIFY_STATUS=$?
      if [ "$VERIFY_STATUS" = 2 ]; then
        LIVE_MISMATCH=1
        break
      fi
    fi
  done
  [ "$LIVE_OK" = 1 ] && break
  [ "$LIVE_MISMATCH" = 1 ] && break
done

if [ "$LIVE_OK" = 1 ]; then
  # status append happens ONLY here, on verified success
  mkdir -p "$WT/.firstmate"
  printf 'working: captain replied (live send to terminal %s)\n' "$LTID" >> "$WT/.firstmate/status"
  echo "sent LIVE to crewmate terminal $LTID in workspace $LWSID (via $SUP agents send; exact prompt verified)"
  exit 0
fi
if [ "$LIVE_MISMATCH" = 1 ]; then
  echo "error: live crewmate received different or truncated input; refusing to retry or duplicate. Inspect the pane and the transcript ($LTRANS) before resending." >&2
  exit 5
fi
echo "error: exact prompt not observed in $LTRANS after $TRIES attempts (via $SUP agents send $LTID --workspace $LWSID). The send may be landing nowhere: dead PTY (desktop restarted? superset#5305), stale terminalId in $SC, or the crewmate is mid-turn longer than FM_LIVE_WAIT_S=${WAIT_S}s. Nothing was appended to status." >&2
exit 8
