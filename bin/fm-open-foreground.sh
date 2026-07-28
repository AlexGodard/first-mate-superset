#!/usr/bin/env bash
# Surface a crewmate's workspace with the AGENT terminal foregrounded, WITHOUT
# stealing focus from the captain's current work.
#
# Background on the pane layout: a CLI-created workspace (`superset ws create`)
# has no pane layout written by the renderer, so a plain `superset ws open <id>`
# lands on it with NEITHER terminal attached to a pane -- the desktop shows both
# the setup terminal and the live agent terminal as "N background terminal
# sessions" (the "2 background processes running" pill), burying the live pane.
# The v2-workspace deep link `?terminalId=<id>&focusRequestId=<uuid>` (apps/desktop
# .../$workspaceId/hooks/useConsumeAutomationRunLink -> focusOrAddTerminalPane)
# focus-or-adds that terminal's pane and makes it the active tab. Pointing it at
# the AGENT terminal foregrounds the live session; the setup terminal stays a
# single background session. The agent terminalId is captured at dispatch into
# `.firstmate/superset` by fm-capture-session.sh (`terminalId=`).
#
# The focus problem: the desktop's processDeepLink() calls focusMainWindow()
# (show()+focus()) on EVERY non-auth deep link, so `open -g` can't keep it in the
# background -- the app raises itself. The proper fix is the `background=1` deep-
# link flag (apps/desktop/src/main/index.ts: skip focusMainWindow when set), which
# navigates+builds the layout without raising the window. That only takes effect
# once a desktop release carrying the change is installed.
#
# Default: background-open (`open -g` + &background=1) -- foregrounds the agent
# pane WITHOUT raising the window, so dispatch never drags the captain away. This
# requires a desktop build that honors `background=1` (shipped in
# apps/desktop/src/main/index.ts). On an older build the param is ignored and the
# app still force-focuses -- annoying, but dispatch still surfaces the workspace.
# There is deliberately no "don't open" mode: a crewmate the captain can't see
# reads as a failed dispatch, so dispatch always opens.
#
# Modes (env):
#   (default)        background-open: agent foregrounded, window NOT raised
#   FM_OPEN_FOCUS=1  open and raise/focus the desktop (old behavior)
#
# Usage:
#   fm-open-foreground.sh <workspaceId> <worktree-dir>
#   fm-open-foreground.sh <workspaceId> --terminal <terminalId>
set -eu

SUPERSET_BIN="${FM_SUPERSET_BIN:-superset}"

WSID="${1:-}"
[ -n "$WSID" ] || { echo "usage: fm-open-foreground.sh <workspaceId> <worktree-dir|--terminal <id>>" >&2; exit 2; }
shift

TID=""
if [ "${1:-}" = "--terminal" ]; then
  TID="${2:-}"
elif [ -n "${1:-}" ] && [ -f "${1%/}/.firstmate/superset" ]; then
  TID=$(sed -n 's/^terminalId=//p' "${1%/}/.firstmate/superset" | head -n1)
fi

if [ -z "$TID" ]; then
  echo "fm-open-foreground: no agent terminalId -> plain open of $WSID" >&2
  exec "$SUPERSET_BIN" ws open "$WSID"
fi

# focusRequestId is a nonce so re-opening re-focuses the same pane (de-dupe key).
# background=1 tells a capable desktop build to navigate without raising the window.
NONCE=$(uuidgen 2>/dev/null || python3 -c 'import uuid;print(uuid.uuid4())')
URL="superset://v2-workspace/${WSID}?terminalId=${TID}&focusRequestId=${NONCE}&background=1"

case "$(uname -s)" in
  Darwin)
    if [ "${FM_OPEN_FOCUS:-0}" = "1" ]; then open "$URL"; else open -g "$URL"; fi ;;
  *)      xdg-open "$URL" >/dev/null 2>&1 || exec "$SUPERSET_BIN" ws open "$WSID" ;;
esac
echo "opened $WSID foregrounding agent terminal ${TID:-<none>} (${FM_OPEN_FOCUS:+focus}${FM_OPEN_FOCUS:-background})"
