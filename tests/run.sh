#!/usr/bin/env bash
# first-mate skill tests. Bash-only; stubs `superset`/`open` so nothing touches the
# desktop, the cloud, or the real worktree root. Run: bash tests/run.sh
set -u
SKILL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$SKILL_ROOT/bin"
PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- stubs ---------------------------------------------------------------------
STUB="$TMP/stubbin"; mkdir -p "$STUB"
cat > "$STUB/superset" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "ws create") echo '{"workspace":{"id":"ws-test-1"},"agents":[{"kind":"terminal","sessionId":"term-test-1"}]}' ;;
  "ws delete") echo "deleted $3" ;;
  "projects list") echo '[]' ;;
  *) : ;;
esac
EOF
cat > "$STUB/open" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$STUB/superset" "$STUB/open"
export PATH="$STUB:$PATH"

# test registry
REG="$TMP/registry.md"
cat > "$REG" <<'EOF'
<!-- registry:begin -->
testproj | direct-PR | off | testpid123
otherproj | direct-PR | off | otherpid456
forkproj | direct-PR | off | forkpid789 | git@github.com:me/upstream-fork.git
nmproj | no-mistakes | off | nmpid000
<!-- registry:end -->
EOF
export FIRST_MATE_REGISTRY="$REG"
export SUPERSET_WORKTREES="$TMP/worktrees"
export FM_STATE_OVERRIDE="$TMP/state"; mkdir -p "$FM_STATE_OVERRIDE"
export FM_SECONDMATE_REGISTRY="$TMP/secondmates.md"
export FM_CLAUDE_AGENT_ID=claude-test-agent
export FM_CODEX_AGENT_ID=codex-test-agent

echo "== fm-lib singleton lock =="
( . "$BIN/fm-lib.sh"
  L="$TMP/lk"
  fm_singleton_acquire "$L"; a=$?
  ( . "$BIN/fm-lib.sh"; fm_singleton_acquire "$L" ); b=$?
  fm_singleton_release "$L"
  [ "$a" = 0 ] && [ "$b" = 1 ] && [ ! -d "$L" ] ) \
  && ok "acquire / second-blocked / release" || bad "acquire / second-blocked / release"

( . "$BIN/fm-lib.sh"
  L="$TMP/lk2"; mkdir "$L"; echo 999999 > "$L/pid"   # dead pid
  FM_LOCK_STALE_AFTER=0 fm_singleton_acquire "$L" ) \
  && ok "reclaims a dead-pid lock" || bad "reclaims a dead-pid lock"

echo "== fm-spawn slug + dry single =="
out=$(FM_DRY_RUN=1 "$BIN/fm-spawn.sh" testproj "Add a CSV Export button!!" 2>/dev/null)
check "ship branch is fm/<slug>"     '[[ "$out" == *"branch=fm/add-a-csv-export-button"* ]]' "$out"
check "slug is sanitized (no caps/!)" '[[ "$out" != *"!"* && "$out" != *"CSV"* ]]' "$out"
out=$(FM_DRY_RUN=1 "$BIN/fm-spawn.sh" --scout testproj "look into X" 2>/dev/null)
check "scout branch is scout/<slug>"  '[[ "$out" == *" scout testproj branch=scout/look-into-x"* ]]' "$out"
out=$(FM_DRY_RUN=1 "$BIN/fm-spawn.sh" --branch fixed-slug testproj "whatever" 2>/dev/null)
check "--branch override has no rand suffix" '[[ "$out" == *"branch=fm/fixed-slug "* ]]' "$out"
out=$(FM_OWNER=stable-secondmate FM_DRY_RUN=1 "$BIN/fm-spawn.sh" testproj "owned task" 2>/dev/null)
check "explicit FM_OWNER is preserved for nested crew" '[[ "$out" == *"owner=stable-secondmate"* ]]' "$out"

echo "== fm-spawn batch (zsh-safe stdin loop) =="
out=$(FM_DRY_RUN=1 "$BIN/fm-spawn.sh" --batch <<'B' 2>/dev/null
testproj	first task
# comment skipped
otherproj	second task
B
)
n=$(printf '%s\n' "$out" | grep -c '^DRYRUN spawn')
check "batch spawns 2 (comment skipped)" '[ "$n" = 2 ]' "$out"
"$BIN/fm-spawn.sh" --batch <<'B' >/dev/null 2>&1
no_tab_here_so_malformed
B
check "batch with only a malformed line exits non-zero" '[ "$?" -ne 0 ]'

echo "== fm-agent custom-agent resolution (2026-07-19 two-agent model) =="
# Stubbed `superset agents list` returns nothing -> configured offline fallbacks:
out=$("$BIN/fm-agent.sh" resolve testproj 2>/dev/null)
check "default -> Claude (claude harness)"  '[[ "$out" == *"agent_label='"'"'Claude'"'"'"* && "$out" == *"agent_harness=claude"* ]]' "$out"
out=$("$BIN/fm-agent.sh" resolve --model claude-opus-4-8 testproj 2>/dev/null)
check "claude model -> Claude"        '[[ "$out" == *"agent_label='"'"'Claude'"'"'"* && "$out" == *"agent_harness=claude"* ]]' "$out"
out=$("$BIN/fm-agent.sh" resolve --model gpt-5.6-sol testproj 2>/dev/null)
check "gpt model -> Codex"            '[[ "$out" == *"agent_label='"'"'Codex'"'"'"* && "$out" == *"agent_harness=codex"* ]]' "$out"
out=$("$BIN/fm-agent.sh" resolve --model codex-mini testproj 2>/dev/null)
check "codex-* model -> Codex"        '[[ "$out" == *"agent_label='"'"'Codex'"'"'"* && "$out" == *"agent_harness=codex"* ]]' "$out"
out=$(FM_AGENT_ID=my-uuid "$BIN/fm-agent.sh" resolve testproj 2>/dev/null)
check "FM_AGENT_ID forces the uuid"  '[[ "$out" == *"agent=my-uuid "* ]]' "$out"
check "--host w/o live resolve errors" '! "$BIN/fm-agent.sh" resolve --host remote1 testproj >/dev/null 2>&1'

echo "== fm-launch harness launcher (pin restore) =="
LWT="$TMP/launch-wt"; mkdir -p "$LWT"
cat > "$STUB/claude" <<'EOF'
#!/usr/bin/env bash
echo "CLAUDE: $* EFF=${CLAUDE_CODE_EFFORT_LEVEL:-}"
EOF
chmod +x "$STUB/claude"
"$BIN/fm-model-pin.sh" set "$LWT" --model claude-opus-4-8 --effort high
r=$( cd "$LWT" && "$BIN/fm-launch.sh" claude --dangerously-skip-permissions 2>/dev/null )
check "claude lane injects pin + [1m] + env effort" '[[ "$r" == "CLAUDE: --model claude-opus-4-8[1m] --dangerously-skip-permissions EFF=high" ]]' "$r"
r=$( cd "$LWT" && "$BIN/fm-launch.sh" claude --dangerously-skip-permissions 2>/dev/null )
check "pin is read-once (2nd launch bare)"       '[[ "$r" == "CLAUDE: --dangerously-skip-permissions EFF=" ]]' "$r"
"$BIN/fm-model-pin.sh" set "$LWT" --model gpt-5.5
r=$( cd "$LWT" && "$BIN/fm-launch.sh" claude -x 2>/dev/null )
check "gpt pin on the Claude agent is dropped"   '[[ "$r" == "CLAUDE: -x EFF=" ]]' "$r"
# gpt-* pins are DROPPED on the claude harness (they belong on the Codex
# agent); effort still applies via env
"$BIN/fm-model-pin.sh" set "$LWT" --model gpt-5.6-sol --effort high
r=$( cd "$LWT" && "$BIN/fm-launch.sh" claude --dangerously-skip-permissions 2>/dev/null )
check "gpt-5.6 pin drops model, keeps effort" '[[ "$r" == "CLAUDE: --dangerously-skip-permissions EFF=high" ]]' "$r"
# legacy `ccs <profile>` spelling still routes (profile swallowed)
"$BIN/fm-model-pin.sh" set "$LWT" --model gpt-5.6-luna
r=$( cd "$LWT" && "$BIN/fm-launch.sh" ccs personal -x 2>/dev/null )
check "legacy ccs spelling still works, gpt pin dropped" '[[ "$r" == "CLAUDE: -x EFF=" ]]' "$r"
r=$( cd "$LWT" && FM_CREW_MODEL=claude-sonnet-5 FM_CREW_EFFORT=low "$BIN/fm-launch.sh" claude -z 2>/dev/null )
check "env fallback when no pin"                 '[[ "$r" == *"--model claude-sonnet-5[1m]"* && "$r" == *"EFF=low"* ]]' "$r"
check "removed CX harness rejected"              '! "$BIN/fm-launch.sh" cx personal >/dev/null 2>&1'
check "bad harness rejected"                     '! "$BIN/fm-launch.sh" tmux personal >/dev/null 2>&1'
rm -f "$STUB/claude"

echo "== fm-spawn full single path (stubbed superset) =="
out=$("$BIN/fm-spawn.sh" --branch e2e testproj "ship it" 2>/dev/null)
check "prints workspace + worktree" '[[ "$out" == *"workspace=ws-test-1"* && "$out" == *"worktree=$SUPERSET_WORKTREES/testpid123/fm/e2e"* ]]' "$out"
check "summary carries agent label" '[[ "$out" == *"agent=Claude"* ]]' "$out"
check "wrote the live-send sidecar"  '[ -f "$SUPERSET_WORKTREES/testpid123/fm/e2e/.firstmate/superset" ]'
check "sidecar has terminalId"       'grep -q "^terminalId=term-test-1$" "$SUPERSET_WORKTREES/testpid123/fm/e2e/.firstmate/superset"'

echo "== fork routing (#3) =="
out=$("$BIN/fm-registry.sh" resolve forkproj 2>/dev/null)
check "resolve emits fork url"        '[[ "$out" == *"fork=git@github.com:me/upstream-fork.git"* ]]' "$out"
out=$("$BIN/fm-registry.sh" resolve testproj 2>/dev/null)
check "resolve fork defaults to -"    '[[ "$out" == *"fork=-"* ]]' "$out"
b=$("$BIN/fm-brief.sh" --kind ship --mode direct-PR --project forkproj --branch fm/x \
     --fork "git@github.com:me/upstream-fork.git" --task "do it" 2>/dev/null)
check "direct-PR brief pushes to fork"       '[[ "$b" == *"git remote add fork git@github.com:me/upstream-fork.git"* && "$b" == *"gh pr create --repo"* && "$b" == *"upstream parent"* ]]'
b=$("$BIN/fm-brief.sh" --kind ship --mode direct-PR --project testproj --branch fm/x \
     --fork "-" --task "do it" 2>/dev/null)
check "no fork (-) leaves brief unforked"    '[[ "$b" != *"git remote add fork"* ]]'
out=$(FM_DRY_RUN=1 "$BIN/fm-spawn.sh" forkproj "ship upstream" 2>/dev/null)
check "fm-spawn threads fork from registry"  '[[ "$out" == *"fork=git@github.com:me/upstream-fork.git"* ]]' "$out"

echo "== crewmate model/effort pin + route injection =="
# dry-run surfaces the resolved model/effort
out=$(FM_DRY_RUN=1 "$BIN/fm-spawn.sh" --model claude-opus-4-8 --effort high testproj "hard task" 2>/dev/null)
check "dry-run echoes model+effort" '[[ "$out" == *"model=claude-opus-4-8"* && "$out" == *"effort=high"* ]]' "$out"
check "bad --effort rejected"       '! "$BIN/fm-spawn.sh" --effort turbo testproj "x" >/dev/null 2>&1'
# full path stages a pin the route script then consumes
out=$("$BIN/fm-spawn.sh" --branch pin1 --model claude-opus-4-8 --effort high testproj "go" 2>/dev/null)
check "spawn summary carries model+effort" '[[ "$out" == *"model=claude-opus-4-8"* && "$out" == *"effort=high"* ]]' "$out"
WTP="$SUPERSET_WORKTREES/testpid123/fm/pin1"
# stub claude so the route shim just echoes the resolved launch args; effort
# rides CLAUDE_CODE_EFFORT_LEVEL, never a flag
cat > "$STUB/claude" <<'EOF'
#!/usr/bin/env bash
echo "CLAUDE: $* EFF=${CLAUDE_CODE_EFFORT_LEVEL:-}"
EOF
chmod +x "$STUB/claude"
r=$( cd "$WTP" && "$BIN/fm-ccs-route.sh" --dangerously-skip-permissions 2>/dev/null )
check "route injects pinned model+effort" '[[ "$r" == *"--model claude-opus-4-8"* && "$r" == *"EFF=high"* && "$r" != *"--effort"* ]]' "$r"
r2=$( cd "$WTP" && "$BIN/fm-ccs-route.sh" --dangerously-skip-permissions 2>/dev/null )
check "pin is read-once (2nd launch bare)" '[[ "$r2" != *"--model"* ]]' "$r2"
# a staged pin is consumed at launch; explicit flags ride "$@" untouched
"$BIN/fm-model-pin.sh" set "$WTP" --model claude-haiku-4-5-20251001
r3=$( cd "$WTP" && "$BIN/fm-ccs-route.sh" --model claude-sonnet-5 2>/dev/null )
check "explicit --model also reaches launch" '[[ "$r3" == *"--model claude-sonnet-5"* ]]' "$r3"
"$BIN/fm-model-pin.sh" take "$WTP" >/dev/null 2>&1 || true
# FM_CREW_EFFORT env fallback when there is no pin
r4=$( cd "$WTP" && FM_CREW_EFFORT=low "$BIN/fm-ccs-route.sh" -x 2>/dev/null )
check "FM_CREW_EFFORT env fallback"      '[[ "$r4" == *"EFF=low"* ]]' "$r4"
rm -f "$STUB/claude"

echo "== codex harness lane (OpenAI models) =="
cat > "$STUB/codex" <<'EOF'
#!/usr/bin/env bash
echo "CODEX: $*"
EOF
cat > "$STUB/claude" <<'EOF'
#!/usr/bin/env bash
echo "CLAUDE: $* EFF=${CLAUDE_CODE_EFFORT_LEVEL:-}"
EOF
chmod +x "$STUB/codex" "$STUB/claude"
# the codex harness translates model/effort into codex flags
"$BIN/fm-model-pin.sh" set "$WTP" --model gpt-5.5 --effort max
r=$( cd "$WTP" && "$BIN/fm-launch.sh" codex --dangerously-bypass-approvals-and-sandbox 2>/dev/null )
check "codex harness execs codex"         '[[ "$r" == CODEX:* ]]' "$r"
check "codex lane keeps model via -m"     '[[ "$r" == *"-m gpt-5.5"* ]]' "$r"
check "effort -> model_reasoning_effort (max->xhigh)" '[[ "$r" == *"model_reasoning_effort=xhigh"* && "$r" != *"--effort"* ]]' "$r"
# a claude pin still routes to claude
"$BIN/fm-model-pin.sh" set "$WTP" --model claude-sonnet-5
r=$( cd "$WTP" && "$BIN/fm-ccs-route.sh" --dangerously-skip-permissions 2>/dev/null )
check "claude pin still routes to claude" '[[ "$r" == CLAUDE:* ]]' "$r"
# gpt-* dispatch routes to the Codex agent
out=$(FM_DRY_RUN=1 "$BIN/fm-spawn.sh" --model gpt-5.5 forkproj "ship it" 2>/dev/null)
check "gpt ship dry-runs on the codex harness" '[[ "$out" == *"model=gpt-5.5"* && "$out" == *"harness=codex"* ]]' "$out"
out=$(FM_DRY_RUN=1 "$BIN/fm-spawn.sh" --model gpt-5.6-sol testproj "ship it" 2>/dev/null)
check "gpt-5.6 ship dry-runs on the codex harness" '[[ "$out" == *"model=gpt-5.6-sol"* && "$out" == *"harness=codex"* ]]' "$out"
# a secondmate runs this skill and is claude-only: every gpt-*/codex-* id refuses
check "secondmate refuses gpt models (claude-only tier)" '! "$BIN/fm-secondmate.sh" spawn smgpt --scope testproj --project testproj --model gpt-5.5 >/dev/null 2>&1'
check "secondmate refuses gpt-5.6 too" '! "$BIN/fm-secondmate.sh" spawn smsol --scope testproj --project testproj --model gpt-5.6-sol >/dev/null 2>&1'
rm -f "$STUB/claude" "$STUB/codex"

echo "== consultation backstop (crew-dispatch.json) =="
CFG="$TMP/config"; mkdir -p "$CFG"
export FM_CONFIG_OVERRIDE="$CFG"
printf '{"default":{"model":"claude-opus-4-8"}}' > "$CFG/crew-dispatch.json"
check "active profile refuses spawn w/o --model" '! "$BIN/fm-spawn.sh" testproj "x" >/dev/null 2>&1'
out=$(FM_DRY_RUN=1 "$BIN/fm-spawn.sh" testproj "x" 2>/dev/null)
check "dry-run is exempt from backstop"          '[[ "$out" == *"DRYRUN spawn"* ]]' "$out"
out=$("$BIN/fm-spawn.sh" --branch bkstp --model claude-opus-4-8 testproj "x" 2>/dev/null)
check "explicit --model satisfies backstop"      '[[ "$out" == *"workspace=ws-test-1"* ]]' "$out"
rm -f "$CFG/crew-dispatch.json"; unset FM_CONFIG_OVERRIDE

echo "== fm-brief secondmate charter =="
b=$("$BIN/fm-brief.sh" --kind secondmate --id sm1 --scope "testproj,otherproj" --project testproj --owner 4242 2>/dev/null)
check "charter sets FM_OWNER=<id>"      '[[ "$b" == *"FM_OWNER=sm1"* ]]'
check "charter home meta owner=<main>"  '[[ "$b" == *"owner=4242"* ]]'
check "charter is idle-by-default"      '[[ "$b" == *"IDLE-BY-DEFAULT"* && "$b" == *"NEVER self-initiate"* ]]'
"$BIN/fm-brief.sh" --kind secondmate --id sm1 --project testproj >/dev/null 2>&1
check "secondmate requires --scope" '[ "$?" -ne 0 ]'

echo "== fm-secondmate lifecycle (stubbed superset) =="
out=$("$BIN/fm-secondmate.sh" spawn sm1 --scope "testproj,otherproj" --project testproj 2>/dev/null)
check "spawn registers + prints workspace" '[[ "$out" == *"workspace=ws-test-1"* ]]' "$out"
check "registry row added"                 '"$BIN/fm-secondmate.sh" list | grep -q "^sm1 "'
out=$("$BIN/fm-secondmate.sh" list)
check "list preserves leading t in project/scope" '[[ "$out" == *"home=testproj"* && "$out" == *"scope=testproj,otherproj"* ]]' "$out"
check "duplicate spawn refused"            '! "$BIN/fm-secondmate.sh" spawn sm1 --scope testproj --project testproj >/dev/null 2>&1'
out=$(FM_DRY_RUN=1 "$BIN/fm-secondmate.sh" route sm1 "do the thing" 2>/dev/null)
check "route resolves the home"            '[[ "$out" == *"DRYRUN route -> sm1 (ws-test-1)"* ]]' "$out"
out=$(FM_DRY_RUN=1 "$BIN/fm-secondmate.sh" spawn sm9 --scope testproj --project testproj --model claude-haiku-4-5-20251001 --effort medium 2>/dev/null)
check "secondmate spawn carries model+effort" '[[ "$out" == *"model=claude-haiku-4-5-20251001"* && "$out" == *"effort=medium"* ]]' "$out"
check "secondmate bad --effort rejected"      '! "$BIN/fm-secondmate.sh" spawn sm9 --scope testproj --project testproj --effort nope >/dev/null 2>&1'

# seed an in-flight crew owned by sm1 -> retire must refuse
CW="$SUPERSET_WORKTREES/testpid123/fm/crewjob/.firstmate"; mkdir -p "$CW"
printf 'project=testproj\nkind=ship\nbranch=fm/crewjob\nowner=sm1\n' > "$CW/meta"
printf 'working: building\n' > "$CW/status"
check "retire refuses while crew in flight" '! "$BIN/fm-secondmate.sh" retire sm1 >/dev/null 2>&1'
printf 'done: PR opened\n' >> "$CW/status"   # now terminal
out=$("$BIN/fm-secondmate.sh" retire sm1 2>/dev/null)
check "retire succeeds once crew is done"   '[[ "$out" == *"retired secondmate sm1"* ]]' "$out"
check "registry row removed"                '! "$BIN/fm-secondmate.sh" list | grep -q "^sm1 "'

echo "== fm-classify-lib wake classification =="
( . "$BIN/fm-classify-lib.sh"
  fleet_line_is_actionable "working  p ship fm/x :: working: building" && exit 1
  fleet_line_is_actionable "needs-decision p ship fm/x :: needs-decision: A or B" || exit 1
  fleet_line_is_actionable "working p ship fm/x :: working: pushed, checks green" || exit 1
  fleet_line_is_actionable "done p scout scout/x :: done: report" || exit 1
  fleet_line_is_actionable "(no crew in flight)" && exit 1
  exit 0 ) && ok "actionable vs benign fleet lines" || bad "actionable vs benign fleet lines"

( . "$BIN/fm-classify-lib.sh"
  d1=$'working p ship fm/a :: working: step 1\nworking p ship fm/b :: working: x'
  d2=$'working p ship fm/a :: working: step 2\nworking p ship fm/b :: working: x'
  s1=$(printf '%s\n' "$d1" | fleet_actionable_signature)
  s2=$(printf '%s\n' "$d2" | fleet_actionable_signature)
  [ "$s1" = "$s2" ] && [ -z "$s1" ] ) \
  && ok "working churn -> stable empty actionable sig (absorbed)" || bad "working churn -> stable empty actionable sig"

( . "$BIN/fm-classify-lib.sh"
  s1=$(printf 'working p ship fm/a :: working: step 1\n' | fleet_actionable_signature)
  s2=$(printf 'needs-decision p ship fm/a :: needs-decision: pick\n' | fleet_actionable_signature)
  [ "$s1" != "$s2" ] && [ -z "$s1" ] && [ -n "$s2" ] ) \
  && ok "needs-decision transition changes actionable sig (wakes)" || bad "needs-decision transition wakes"

( . "$BIN/fm-classify-lib.sh"
  fleet_line_is_afk_critical "done p ship fm/x :: done: PR opened" && exit 1
  fleet_line_is_afk_critical "needs-decision p ship fm/x :: needs-decision: A" || exit 1
  exit 0 ) && ok "afk-critical drops done, keeps needs-decision" || bad "afk-critical narrowing"

echo "== fm-crew-state reconciler =="
SC="$SUPERSET_WORKTREES/testpid123/scout/look/.firstmate"; mkdir -p "$SC"
printf 'project=testproj\nkind=scout\nbranch=scout/look\nowner=x\n' > "$SC/meta"
printf 'working: investigating\ndone: report ready\n' > "$SC/status"
out=$("$BIN/fm-crew-state.sh" "$(dirname "$SC")" 2>/dev/null)
check "scout falls back to status-log last line" '[[ "$out" == *"state: done"* && "$out" == *"source: status-log"* ]]' "$out"

out=$("$BIN/fm-crew-state.sh" "$TMP/gone-worktree" 2>/dev/null)
check "missing worktree -> unknown/none" '[[ "$out" == *"state: unknown"* && "$out" == *"source: none"* ]]' "$out"

SH="$SUPERSET_WORKTREES/testpid123/fm/recon/.firstmate"; mkdir -p "$SH"
printf 'project=testproj\nkind=ship\nbranch=fm/recon\nowner=x\n' > "$SH/meta"
printf 'working: building\nneeds-decision: should we X?\n' > "$SH/status"
out=$("$BIN/fm-crew-state.sh" "$(dirname "$SH")" 2>/dev/null)
check "ship needs-decision log -> parked" '[[ "$out" == *"state: parked"* && "$out" == *"source: status-log"* && "$out" == *"should we X?"* ]]' "$out"
tail -f "$SH/status" >/dev/null 2>&1 &
PROCESS_EVIDENCE_PID=$!
out=$("$BIN/fm-crew-state.sh" "$(dirname "$SH")" 2>/dev/null)
kill "$PROCESS_EVIDENCE_PID" 2>/dev/null || true
wait "$PROCESS_EVIDENCE_PID" 2>/dev/null || true
check "process existence does not override needs-decision" '[[ "$out" == *"state: parked"* && "$out" == *"source: status-log"* ]]' "$out"

printf 'resolved: captain chose X\npaused: waiting for upstream release\n' >> "$SH/status"
out=$("$BIN/fm-crew-state.sh" "$(dirname "$SH")" 2>/dev/null)
check "paused external wait is distinct" '[[ "$out" == *"state: paused"* && "$out" == *"waiting for upstream release"* ]]' "$out"

echo "== durable wake queue + paused resurfacing =="
PW="$SUPERSET_WORKTREES/testpid123/fm/paused/.firstmate"; mkdir -p "$PW"
printf 'project=testproj\nkind=ship\nbranch=fm/paused\nowner=wakeowner\n' > "$PW/meta"
printf 'paused: waiting for rate-limit reset\n' > "$PW/status"
# Mark the paused line as already surfaced so this exercises bounded resurfacing,
# not the separate arm-time race guard for newly actionable crew.
FM_OWNER=wakeowner "$BIN/fm-fleet.sh" --mine 2>/dev/null | grep '^paused' > "$FM_STATE_OVERRIDE/.last-surfaced.wakeowner"
out=$(FM_OWNER=wakeowner FM_WATCH_NO_LOCK=1 FM_POLL=1 FM_MAX_TICKS=1 FM_PAUSE_RESURFACE_SECS=1 \
  "$BIN/fm-watch-bg.sh" 2>/dev/null)
check "overdue paused wait wakes immediately" '[[ "$out" == *"bounded recheck cadence"* ]]' "$out"
check "watcher enqueues before exit" '[ -s "$FM_STATE_OVERRIDE/.wake-queue.wakeowner" ]'
out=$(FM_OWNER=wakeowner "$BIN/fm-wake-drain.sh")
check "drain returns queued event" '[[ "$out" == *"declared external wait recheck"* ]]' "$out"
check "drain atomically clears queue" '[ ! -s "$FM_STATE_OVERRIDE/.wake-queue.wakeowner" ]'

echo "== gate authority boundary =="
check "no-mistakes gate cannot spawn" '! NO_MISTAKES_GATE=1 FM_DRY_RUN=1 "$BIN/fm-spawn.sh" testproj "x" >/dev/null 2>&1'
check "ordinary dry-run remains allowed" 'FM_DRY_RUN=1 "$BIN/fm-spawn.sh" testproj "x" >/dev/null 2>&1'
b=$("$BIN/fm-brief.sh" --kind ship --mode direct-PR --project testproj --branch fm/gate --task x)
check "brief forbids gate fleet control" '[[ "$b" == *"observer only"* && "$b" == *"never invoke first-mate"* ]]'

echo "== no-mistakes delivery mode (ported back from kunchenguid/no-mistakes) =="
out=$("$BIN/fm-registry.sh" resolve nmproj 2>/dev/null)
check "registry accepts no-mistakes mode" '[[ "$out" == *"mode=no-mistakes"* ]]' "$out"
out=$(FM_DRY_RUN=1 "$BIN/fm-spawn.sh" nmproj "gate this" 2>/dev/null)
check "spawn resolves no-mistakes mode" '[[ "$out" == *"mode=no-mistakes"* ]]' "$out"
check "nm mode defaults crew to terra/high on codex" '[[ "$out" == *"model=gpt-5.6-terra"* && "$out" == *"effort=high"* && "$out" == *"harness=codex"* ]]' "$out"
out=$(FM_DRY_RUN=1 "$BIN/fm-spawn.sh" --model claude-opus-4-8 --effort medium nmproj "gate this" 2>/dev/null)
check "nm explicit --model overrides terra default" '[[ "$out" == *"model=claude-opus-4-8[1m]"* && "$out" == *"effort=medium"* && "$out" == *"harness=claude"* ]]' "$out"
out=$(FM_DRY_RUN=1 "$BIN/fm-spawn.sh" --scout nmproj "just look" 2>/dev/null)
check "nm scout keeps instance default (no terra)" '[[ "$out" == *"mode=scout"* && "$out" == *"model=default"* ]]' "$out"
check "spawn rejects a bogus --mode" '! FM_DRY_RUN=1 "$BIN/fm-spawn.sh" --mode yolo-mode testproj "x" >/dev/null 2>&1'
b=$("$BIN/fm-brief.sh" --kind ship --mode no-mistakes --project nmproj --branch fm/nm-x --task "gate this")
check "nm brief bakes gate DoD" '[[ "$b" == *"no-mistakes doctor"* && "$b" == *"checks green"* ]]'
check "nm brief escalates ask-user via needs-decision" '[[ "$b" == *"axi respond"* && "$b" == *"needs-decision"* ]]'
check "nm brief forbids --yes and daemon restarts" '[[ "$b" == *'"'"'Avoid `--yes`'"'"'* && "$b" == *"Never stop, restart, or update the shared"* ]]'
b=$("$BIN/fm-brief.sh" --kind ship --mode no-mistakes --project nmproj --branch fm/nm-x --fork git@github.com:me/f.git --task "x")
check "nm brief routes forks through init --fork-url" '[[ "$b" == *"--fork-url git@github.com:me/f.git"* ]]'

echo "== fm-crew-state no-mistakes run-step =="
NMWT="$SUPERSET_WORKTREES/nmpid000/fm/nm-cs"; mkdir -p "$NMWT/.firstmate"
( cd "$NMWT" && git init -q . && git commit -q --allow-empty -m x && git checkout -qb fm/nm-cs ) 2>/dev/null
printf 'project=nmproj\nkind=ship\nmode=no-mistakes\nbranch=fm/nm-cs\n' > "$NMWT/.firstmate/meta"
printf 'needs-decision: gate question\n' > "$NMWT/.firstmate/status"
cat > "$STUB/no-mistakes" <<'EOF'
#!/usr/bin/env bash
case "${NM_STUB_SCENARIO:-parked}" in
  parked)
    [ "$1 $2" = "axi status" ] && printf 'id: r1\nbranch: fm/nm-cs\nstatus: awaiting_approval\ngate: review\nfindings[2]{id,t}:\n  a,x\n  b,ask-user: y\n'
    ;;
  resumed)
    [ "$1 $2" = "axi status" ] && printf 'id: r1\nbranch: fm/nm-cs\nstatus: running\n'
    ;;
  green)
    [ "$1 $2" = "axi status" ] && printf 'id: r1\nbranch: fm/nm-cs\nstatus: ci\nsteps[5]{s,st,f}:\n  ci,running,0\n'
    [ "$1 $2" = "axi logs" ] && echo "all CI checks passed - still monitoring until merged or closed"
    ;;
  coarse)
    [ "$1 $2" = "axi status" ] && printf 'id: r2\nbranch: fm/other\nstatus: running\n'
    [ "$1" = runs ] && printf 'running    fm/nm-cs   abc123   2026-07-20\n'
    ;;
esac
exit 0
EOF
chmod +x "$STUB/no-mistakes"
out=$(NM_STUB_SCENARIO=parked "$BIN/fm-crew-state.sh" "$NMWT")
check "run-step parked at gate + findings + ask-user" '[[ "$out" == *"state: parked"* && "$out" == *"run-step"* && "$out" == *"2 finding(s)"* && "$out" == *"ask-user"* ]]' "$out"
out=$(NM_STUB_SCENARIO=resumed "$BIN/fm-crew-state.sh" "$NMWT")
check "resumed run supersedes stale needs-decision log" '[[ "$out" == *"state: working"* && "$out" == *"superseded"* ]]' "$out"
out=$(NM_STUB_SCENARIO=green "$BIN/fm-crew-state.sh" "$NMWT")
check "ci-log green overrides working -> done" '[[ "$out" == *"state: done"* && "$out" == *"checks green"* ]]' "$out"
out=$(NM_STUB_SCENARIO=coarse "$BIN/fm-crew-state.sh" "$NMWT")
check "coarse runs-list fallback attributes branch" '[[ "$out" == *"state: working"* && "$out" == *"background run"* ]]' "$out"
out=$(FM_CREW_STATE_NO_NM=1 "$BIN/fm-crew-state.sh" "$NMWT")
check "FM_CREW_STATE_NO_NM falls back to status log" '[[ "$out" == *"status-log"* ]]' "$out"
rm -f "$STUB/no-mistakes"

echo "== structured fleet snapshot =="
snap=$(FM_SNAPSHOT_LIMIT=5 "$BIN/fm-fleet-snapshot.sh")
check "snapshot schema is stable" 'printf "%s" "$snap" | python3 -c '\''import json,sys; assert json.load(sys.stdin)["schema"] == "fm-superset-snapshot.v1"'\''' "$snap"
check "snapshot exposes four bearings buckets" '[[ "$snap" == *'"'"'captains_call'"'"'* && "$snap" == *'"'"'recently_landed'"'"'* && "$snap" == *'"'"'underway'"'"'* && "$snap" == *'"'"'charted_next'"'"'* ]]' "$snap"

echo "== AFK lifecycle + Superset doctor =="
out=$("$BIN/fm-afk.sh" start); check "afk start writes durable flag" '[ -f "$FM_STATE_OVERRIDE/.afk" ]' "$out"
out=$("$BIN/fm-afk.sh" stop); check "afk stop clears flag" '[ ! -f "$FM_STATE_OVERRIDE/.afk" ]' "$out"
check "Superset doctor completes under stubs" '"$BIN/fm-doctor.sh" >/dev/null'

echo "== fm-send live delivery =="
if bash "$SKILL_ROOT/tests/fm-send-live.sh"; then
  ok "bracketed live send and exact transcript verification"
else
  bad "bracketed live send and exact transcript verification"
fi

echo "== Superset/Codex watcher turn injection =="
if bash "$SKILL_ROOT/tests/fm-watch-superset.sh"; then
  ok "durable, deduplicated, transcript-verified self wake"
else
  bad "Superset/Codex self wake"
fi

echo "== no-mistakes terminal completion watcher =="
if bash "$SKILL_ROOT/tests/fm-watch-no-mistakes.sh"; then
  ok "direct gate response reaches one durable terminal wake"
else
  bad "no-mistakes terminal completion wake"
fi

echo "== deterministic ShellCheck =="
"$SKILL_ROOT/tests/shellcheck.sh" >/dev/null && ok "ShellCheck 0.11.0 error parity" || bad "ShellCheck parity"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
