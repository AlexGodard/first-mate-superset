#!/usr/bin/env bash
# Shared wake classifier for the first-mate watcher: the single source of truth
# for deciding whether a fleet change is captain-relevant (must wake firstmate's
# LLM) or benign (absorbed in bash, never woken on). Ported from upstream
# firstmate's bin/fm-classify-lib.sh (kunchenguid/firstmate), adapted to the
# Superset/filesystem model: the local fleet has no tmux panes, so classification
# reads the `.firstmate/status` last line (via fm-fleet.sh's digest) instead of
# pane signatures.
#
# Source it:  . "$(dirname "$0")/fm-classify-lib.sh"
#
# Every function is a pure, side-effect-free read: it takes what it needs as
# arguments and touches no globals beyond the optional FM_CAPTAIN_RE override.
# The watcher layers its own baseline/dedup state on top.

# Captain-relevant status verbs/phrases. A crew whose last status line carries any
# of these is work firstmate must see; everything else (working: churn, bare
# turn-end notes) is benign and absorbed in bash. The state column that fm-fleet
# derives covers the leading verbs (done/blocked/needs-decision/failed); the
# phrase alternatives below also catch a captain-relevant signal embedded in an
# otherwise `working:` line (e.g. "working: pushed, checks green"). FM_CAPTAIN_RE
# overrides the whole set when a home needs a custom vocabulary.
FM_CLASSIFY_CAPTAIN_RE_DEFAULT='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'

# Subset of the captain-relevant set that, in AFK (away) mode, still warrants an
# interrupt rather than batch handling: a human decision or a hard failure. Plain
# `done` deliveries are batch-coalesced while away (the agent auto-delivers them
# under standing consent); these are not. FM_AFK_CRITICAL_RE overrides.
FM_CLASSIFY_AFK_CRITICAL_RE_DEFAULT='needs-decision:|blocked:|failed:'

# A declared external wait is deliberately idle and is not a blocker. It is
# resurfaced by the watcher on a separate long cadence (firstmate#421).
status_is_declared_pause() {
  printf '%s' "$1" | grep -qiE '^paused:[[:space:]]'
}

# 0 if the given status line matches a captain-relevant verb/phrase.
status_is_captain_relevant() {  # <last-status-line>
  local line=$1
  [ -n "$line" ] || return 1
  printf '%s' "$line" | grep -qiE "${FM_CAPTAIN_RE:-$FM_CLASSIFY_CAPTAIN_RE_DEFAULT}"
}

# 0 if the line warrants a prompt interrupt even in AFK mode.
status_is_afk_critical() {  # <last-status-line>
  local line=$1
  [ -n "$line" ] || return 1
  printf '%s' "$line" | grep -qiE "${FM_AFK_CRITICAL_RE:-$FM_CLASSIFY_AFK_CRITICAL_RE_DEFAULT}"
}

# A fm-fleet.sh digest line is `<state> <project> <kind> <branch> :: <last line>`.
# Split off the part after the ` :: ` separator (the crewmate's last status line);
# print the whole line back if there is no separator.
fleet_line_status() {  # <fleet-line>
  case "$1" in
    *" :: "*) printf '%s' "${1#* :: }" ;;
    *)        printf '%s' "$1" ;;
  esac
}

# The leading state token fm-fleet prints (first whitespace-delimited field).
fleet_line_state() {  # <fleet-line>
  printf '%s' "${1%%[[:space:]]*}"
}

# 0 (actionable) if a fm-fleet digest line is captain-relevant: either its derived
# state column is one of the attention states, or the trailing status line matches
# the captain regex (catches a relevant phrase inside a `working:` line).
fleet_line_is_actionable() {  # <fleet-line>
  local line=$1 state
  [ -n "$line" ] || return 1
  case "$line" in '('*')'*) return 1 ;; esac   # "(no crew in flight)" etc.
  state=$(fleet_line_state "$line")
  case "$state" in
    done|blocked|needs-decision|failed) return 0 ;;
    paused) return 1 ;;
  esac
  status_is_captain_relevant "$(fleet_line_status "$line")"
}

# 0 if a fm-fleet digest line is AFK-critical (interrupt even while away).
fleet_line_is_afk_critical() {  # <fleet-line>
  local line=$1 state
  [ -n "$line" ] || return 1
  case "$line" in '('*')'*) return 1 ;; esac
  state=$(fleet_line_state "$line")
  case "$state" in
    needs-decision|blocked|failed) return 0 ;;
  esac
  status_is_afk_critical "$(fleet_line_status "$line")"
}

# Filter a fm-fleet digest (on stdin) to only its actionable lines. This is the
# "actionable signature" the watcher diffs against its baseline: benign churn
# (working: lines coming and going) never changes it, so it never wakes the LLM.
fleet_actionable_signature() {  # reads fleet digest on stdin
  local line
  while IFS= read -r line; do
    fleet_line_is_actionable "$line" && printf '%s\n' "$line"
  done
}

# Filter to only AFK-critical lines (used while state/.afk exists).
fleet_afk_critical_signature() {  # reads fleet digest on stdin
  local line
  while IFS= read -r line; do
    fleet_line_is_afk_critical "$line" && printf '%s\n' "$line"
  done
}
