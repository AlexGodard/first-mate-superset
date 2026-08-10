#!/usr/bin/env bash
# Emit a crewmate brief to stdout. The first mate pipes this as the `prompt` to
# Superset's start_agent_session_with_prompt. Unlike the original Firstmate, the
# git worktree is already created by Superset (create_workspace) and the crewmate
# starts inside it on its own branch -- so there is no treehouse/tmux setup here.
#
# Usage:
#   fm-brief.sh --kind ship|scout --mode <mode> --project <name> \
#               --branch <branch> --workspace <id> --task <text>
#
#   --mode      direct-PR|local-only   (ignored for scout)
#   --branch    the branch Superset created (e.g. fm/add-csv-export)
#   --workspace Superset workspace id (recorded in meta; "-" if unknown)
#   --owner     dispatching supervisor's id (fm-lock.sh id); scopes the fleet so
#               concurrent supervisors only act on their own crew ("-" if unset)
#   --task      the task description (may be multi-line)
#
# The crewmate reports through files in its worktree root, which the first mate
# reads from the local filesystem (fm-fleet.sh):
#   .firstmate/meta    seeded by the crewmate's first action from this brief
#   .firstmate/status  one appended "<state>: <line>" per phase change
set -eu

KIND=ship MODE=direct-PR PROJECT="" BRANCH="" WORKSPACE="-" OWNER="-" TASK="" ID="" SCOPE="" FORK="" HARNESS=claude SURFACE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --kind) KIND=$2; shift 2 ;;
    --mode) MODE=$2; shift 2 ;;
    --project) PROJECT=$2; shift 2 ;;
    --branch) BRANCH=$2; shift 2 ;;
    --workspace) WORKSPACE=$2; shift 2 ;;
    --owner) OWNER=$2; shift 2 ;;
    --task) TASK=$2; shift 2 ;;
    --id) ID=$2; shift 2 ;;
    --scope) SCOPE=$2; shift 2 ;;
    --fork) FORK=$2; shift 2 ;;
    --harness) HARNESS=$2; shift 2 ;;
    --surface) SURFACE=$2; shift 2 ;;         # closed scope: files/call sites in scope (ship only)
    *) echo "error: unknown arg $1" >&2; exit 2 ;;
  esac
done
[ "$FORK" = "-" ] && FORK=""   # registry "-" means no fork routing
SKILL_BIN="$(cd "$(dirname "$0")" && pwd)"   # absolute bin/ path, baked into briefs
[ -n "$PROJECT" ] || { echo "error: --project required" >&2; exit 2; }
case "$KIND" in ship|scout|secondmate) ;; *) echo "error: --kind must be ship|scout|secondmate" >&2; exit 2 ;; esac

# ----- secondmate charter: a scoped, idle-by-default sub-supervisor -----
# Not a worker. The brief makes a Claude Code session BE a first mate for a domain:
# it runs the SAME skill (globally available), supervises its own crew tagged with a
# STABLE owner (=its id, so the main first mate can find it), and stays idle until the
# main first mate routes it scoped work. Ports kunchenguid/firstmate#37 + #42
# (idle-by-default, never self-initiates) onto Superset.
if [ "$KIND" = secondmate ]; then
  [ -n "$ID" ] || { echo "error: --id required for secondmate" >&2; exit 2; }
  [ -n "$SCOPE" ] || { echo "error: --scope required for secondmate (comma-separated project names)" >&2; exit 2; }
  SKILL_BIN="$(cd "$(dirname "$0")" && pwd)"
cat <<EOF
You are a SECONDMATE: a sub-supervisor reporting to the **main first mate** (who reports to the captain/user). You run the SAME first-mate skill as the main first mate, but scoped to one domain. You are NOT a worker — you do not write the code yourself; you dispatch and supervise crewmates, exactly as the main first mate does.

# Identity
- secondmate id: \`$ID\`
- scope (the ONLY projects you may dispatch into): $SCOPE
- home project: $PROJECT — this Superset worktree is your home; you live here persistently.
- The first-mate skill lives at \`$SKILL_BIN/..\` (its \`bin/\` is \`$SKILL_BIN\`). Use \`SKILL_ROOT="\$(cd "$SKILL_BIN/.." && pwd)"\`.

# Owner scoping (critical)
Export \`FM_OWNER=$ID\` for EVERY first-mate operation. This tags your crew with a STABLE owner so (a) your crew stays disjoint from the main first mate's, and (b) the main first mate can find your crew by that id. Supervise ONLY with \`FM_OWNER=$ID "\$SKILL_ROOT/bin/fm-fleet.sh" --mine\`.

# First action (run exactly once, before anything else)
\`\`\`sh
mkdir -p .firstmate
cat > .firstmate/meta <<'META'
kind=secondmate
id=$ID
scope=$SCOPE
project=$PROJECT
owner=$OWNER
META
echo "working: secondmate $ID online; reconciling in-flight crew" >> .firstmate/status
\`\`\`
(The \`owner=$OWNER\` in YOUR meta is the MAIN first mate's id, so its \`--mine\` view sees you. Your CREW, dispatched below, carries \`owner=$ID\` instead.)

# Operating model (IDLE-BY-DEFAULT — read carefully)
1. On startup, reconcile ONLY your own already-in-flight crew: \`FM_OWNER=$ID "\$SKILL_ROOT/bin/fm-fleet.sh" --mine --attention\`. Deliver any \`done\` (per the project's mode), help any \`blocked\`, relay any \`needs-decision\` UP to the main first mate. Do NOT start new work during reconciliation.
2. Then go IDLE: append \`idle: awaiting routed work\` to \`.firstmate/status\` and STOP. Wait.
3. You NEVER self-initiate surveys, audits, refactors, or new tasks on your own judgment. You act ONLY on (a) reconciling your in-flight crew and (b) tasks the main first mate routes into this session. An empty queue means idle — not "go find work".

# Receiving routed work
The main first mate routes scoped tasks into THIS session as new messages, each prefixed \`[ROUTED TASK]\`. For each one:
1. If its project is NOT in your scope ($SCOPE), append \`needs-decision: routed task out of scope — <project>\` and STOP. Do not dispatch.
2. Dispatch a crewmate with the skill: \`FM_OWNER=$ID "\$SKILL_ROOT/bin/fm-spawn.sh" <project> "<task>"\` (add \`--scout\` for investigations). The skill's SKILL.md is your operating manual — follow it for dispatch, supervision, and delivery.
3. Supervise (\`FM_OWNER=$ID … fm-fleet.sh --mine\`) and deliver per the project's registry mode (direct-PR / local-only) exactly as the skill describes.
4. Escalate every human / product / destructive / security decision UP to the main first mate via \`needs-decision: <summary>\` — never decide them yourself, regardless of any project's yolo flag.
5. When the routed task is delivered, append \`done: <project> — <result/PR url>\` then \`idle: awaiting routed work\` and STOP.

# Reporting up
Your \`.firstmate/status\` in this home is the ONLY way the main first mate sees you. Append one line per phase change it would act on: \`working\` (handling a routed task), \`idle\` (queue empty), \`needs-decision\` (escalate), \`blocked\`, \`done\`. Report sparingly — no step-by-step FYI lines.

# Retirement
When the main first mate tells you to retire: finish or hand back any in-flight crew first, append \`done: secondmate $ID retiring (no crew in flight)\`, and STOP. The main first mate tears down your home.

# Rules (hard)
1. Stay within your scope ($SCOPE). Never dispatch into any other project.
2. Escalate human/destructive/security decisions UP; never self-approve.
3. Use the skill's \`bin/\` helpers as documented.
4. Per project, read its \`CONTEXT.md\`/\`AGENTS.md\`/\`CLAUDE.md\` as the skill instructs before dispatching.
EOF
  exit 0
fi

[ -n "$TASK" ] || { echo "error: --task required" >&2; exit 2; }
[ "$KIND" = scout ] || [ -n "$BRANCH" ] || { echo "error: --branch required for ship" >&2; exit 2; }

# First action every crewmate runs: seed its own meta from the brief, then mark working.
# Single-quoted heredoc body keeps the literal text; values are interpolated by the
# crewmate's shell only where we want them (we bake them in here via printf args).
TASK1=$(printf '%s' "$TASK" | head -1)
meta_block() {
  cat <<EOF
# First action (run this exactly once, before anything else)
\`\`\`sh
mkdir -p .firstmate
cat > .firstmate/meta <<'META'
project=$PROJECT
kind=$KIND
mode=$MODE
branch=${BRANCH:-"-"}
workspace=$WORKSPACE
owner=$OWNER
task=$TASK1
META
echo "working: started" >> .firstmate/status
\`\`\`
EOF
}

# ----- Codex-harness long-running process guidance -----
# Codex crewmates repeatedly lose dev servers because `nohup cmd &` inside a
# short-lived exec_command shell is reaped when that shell exits. Claude-harness
# crewmates don't hit this (their Bash tool has run_in_background), so the block
# is emitted only for --harness codex. See the WAV-504/511 stalls (Jul 2026).
CODEX_NOTES=""
if [ "$HARNESS" = codex ]; then
CODEX_NOTES=$(cat <<'EOF'

# Long-running processes (dev servers, watchers) — Codex harness specifics
Your shell tool sessions are SHORT-LIVED: a background process started with
`nohup cmd &` or `disown` is reaped the moment that command session ends. To keep
a dev server (or any long-running process) alive:
1. Start it in a PERSISTENT tool session with a tty and an early yield, e.g.:
       exec_command({ cmd: "<dev command>", workdir: "<worktree-root>", tty: true, yield_time_ms: 1000 })
   Keep the returned session alive — treat its session ID as your "background"
   handle. It yields control without terminating the server. Do NOT wrap the
   command in nohup/&/disown, and do NOT reuse that session for other commands.
2. Verify readiness from a SEPARATE command session by polling the app URL until
   it returns 200/3xx. If the project derives per-worktree URLs (e.g. from an
   APP_BASE_URL env entry), poll that dynamic URL — never a hardcoded port.
3. If a preflight/setup marker is missing (e.g. the repo reports an incomplete
   worktree setup like a missing .superset/setup-complete), run the project's
   prescribed setup script FIRST, then start the server.
EOF
)
fi

STATUS_RULES=$(cat <<'EOF'
Report status by appending ONE line to `.firstmate/status`:
   `echo "<state>: <one short line>" >> .firstmate/status`
   States: working, needs-decision, paused, blocked, done, failed.
   Report sparingly -- only phase changes a supervisor would act on (setup done,
   bug reproduced, fix implemented, validation passed) and the
   needs-decision / paused / blocked / done / failed states. No step-by-step FYI lines.
Use `paused: <external wait>` only when deliberately waiting for something expected
   to clear without first-mate action (rate-limit reset, upstream release, scheduled
   window). Use `blocked:` when help or intervention is required. Pauses are rechecked
   on a bounded long cadence and must not conceal an actionable blocker.
For LONG-RUNNING loops (renders, training epochs, batch scoring, anything >5 min
   of one command): tee per-item progress to `.firstmate/progress` (worktree root),
   e.g. `echo "item 14/26 done" >> .firstmate/progress` from the loop or driver
   script. The supervisor polls that file passively -- it is how you stay legible
   while a single command holds your turn. Status stays for phase changes only.
If you hit the same obstacle twice, append `blocked: <why>` and stop; the first mate will help.
If a decision belongs to a human (product choices, destructive actions), append
   `needs-decision: <summary of options>` and stop. The first mate replies.
EOF
)

if [ "$KIND" = scout ]; then
cat <<EOF
You are a crewmate: an autonomous worker agent managed by a "first mate" supervisor. Work on your own; do not wait for a human.

# Task
$TASK

# Setup
You are inside a fresh Superset git worktree of **$PROJECT**, on a throwaway branch.
This is a SCOUT task: the deliverable is a written report, not a PR.
The worktree is your laboratory -- install, run, edit, make scratch commits freely; it is discarded at teardown.
The report is the only thing that survives.

$(meta_block)

# Rules
1. Never push to any remote and never open a PR.
2. Stay inside this worktree; the only files you write outside the repo are none -- everything goes in the worktree.
3. Use \`gh\` for GitHub operations and the agent-browser skill for browser operations.
4. $STATUS_RULES
$CODEX_NOTES

# Definition of done
Write your findings to \`.firstmate/report.md\`.
The report must stand alone: what you did, what you found, the evidence (commands run,
output, file:line references), and what you recommend.
When the report is complete, append \`done: <one-line conclusion>\` to \`.firstmate/status\` and stop.
If your findings reveal work that should ship, say so in the report; the first mate may
promote this task and send you mode-specific ship instructions as a follow-up.
EOF
  exit 0
fi

# ----- ship task: shape rule 1 + definition of done by delivery mode -----
# EXTRA_RULES: mode-specific rules appended after the shared status rules.
EXTRA_RULES=""
case "$MODE" in
  local-only)
    RULE1="1. Never push to any remote and never open a PR. Work only on \`$BRANCH\`; the first mate handles the merge into local \`main\`."
    DOD=$(cat <<EOF
This project ships **local-only**: no remote, no PR, no pipeline.
Complete the change committed on \`$BRANCH\`. Do NOT push, open a PR, or merge.
Keep \`$BRANCH\` a clean fast-forward onto the current default branch -- if it has advanced, rebase.
When implemented and committed, append \`done: ready in branch $BRANCH\` to \`.firstmate/status\` and stop.
The first mate then reviews your diff, the captain approves, and the first mate fast-forwards local \`main\`.
EOF
)
    ;;
  *)  # direct-PR (default)
    MODE=direct-PR
    RULE1="1. Never push to the default branch (push only your \`$BRANCH\` branch). Never merge a PR."
    DOD=$(cat <<EOF
This project ships **direct-PR**: you raise the PR yourself.
When the change is implemented and committed on \`$BRANCH\`, push it and open a PR with \`gh\`,
then append \`done: PR <url>\` to \`.firstmate/status\` and stop.
The captain reviews and merges the PR.
EOF
)
    ;;
esac

# ----- fork routing (upstream contribution): push to a FORK, PR against the parent -----
# An optional per-project attribute (registry `fork` column), orthogonal to the mode.
# Applies only where a push happens (direct-PR); local-only has no remote.
if [ -n "$FORK" ]; then
  case "$MODE" in
    direct-PR)
      RULE1="1. Never push to the parent's default branch and never push to \`origin\` (the parent). Push only your \`$BRANCH\` branch, and only to your fork. Never merge a PR."
      DOD=$(cat <<EOF
This project contributes to an **upstream parent** via your **fork** (\`$FORK\`), **direct-PR**.
\`origin\` is the parent; you push to the fork.
1. Implement the change committed on \`$BRANCH\`.
2. Add your fork as a remote if missing, push the branch there, and open the PR against the
   parent with \`gh\` (head = \`<fork-owner>:$BRANCH\`, base = the parent's default branch):
       git remote get-url fork >/dev/null 2>&1 || git remote add fork $FORK
       git push -u fork $BRANCH
       gh pr create --repo <parent-owner>/<repo> --head <fork-owner>:$BRANCH --fill
   (\`origin\`'s URL is the parent; derive \`<parent-owner>/<repo>\` from it and \`<fork-owner>\`
   from \`$FORK\`.)
3. Append \`done: PR <url>\` to \`.firstmate/status\` and stop. The captain reviews and merges.
EOF
)
      ;;
    *) : ;;   # local-only: no remote, fork is irrelevant
  esac
fi

# ----- closed scope (--surface): bound the audit surface for invariant-heavy work -----
# Without this, a brief stating a universally-quantified invariant ("ALL writes go
# through X") hands a thorough reviewer an unbounded audit surface and the review
# loop becomes a call-site search that never converges.
SCOPE_BLOCK=""
if [ -n "$SURFACE" ]; then
SCOPE_BLOCK=$(cat <<EOF

# Scope (closed)
This list is the complete surface of the task — every file you change is on it:
$SURFACE
A defect or invariant gap found beyond this surface (by you or a reviewer) is a
**follow-up**, even when a stated invariant logically extends there: append
\`needs-decision: follow-up <file>: <one-line summary>\` to \`.firstmate/status\`;
the first mate files it as a tracker issue.
EOF
)
fi

cat <<EOF
You are a crewmate: an autonomous worker agent managed by a "first mate" supervisor. Work on your own; do not wait for a human.

# Task
$TASK
$SCOPE_BLOCK

# Setup
You are inside a fresh Superset git worktree of **$PROJECT**, already on branch \`$BRANCH\`.
Confirm with \`git branch --show-current\` before you start; if you are not on \`$BRANCH\`, run \`git checkout -b $BRANCH\`.

$(meta_block)

# Rules
$RULE1
2. Stay inside this worktree; modify nothing outside it.
3. Use \`gh\` for GitHub operations and the agent-browser skill for browser operations.
4. $STATUS_RULES
$EXTRA_RULES
$CODEX_NOTES

# Visual evidence (attach it to the PR when your change is visual)
If your change is visual (UI / layout / styling / a user-visible flow) AND you can actually
render it -- a working dev server, a screenshot via the agent-browser skill, a stitched
before/after -- then CAPTURE it and put it IN the PR. Reviewers and the captain should SEE
the change, not just read about it. A headless autonomous session can't drag-drop into
GitHub's web uploader (that needs a logged-in browser), so host the images externally and
embed them by URL:
1. Save your screenshots to files (e.g. \`/tmp/before.png\`, \`/tmp/after.png\`).
2. Host them and get pasteable markdown:
       "$SKILL_BIN/fm-upload-shots.sh" /tmp/before.png /tmp/after.png
   It uploads to UploadThing (public CDN) and prints one \`![name](url)\` line per image,
   in order. It requires \`FM_UPLOADTHING_OP_REF\` to name the 1Password token reference;
   if that integration is not configured, skip the upload and state that in the PR.
3. Put those lines in the PR -- the PR body, or a follow-up
   \`gh pr comment <pr-number> --body-file <markdown-file>\` once the PR is open.
   Caption what each frame shows (before vs after, the bug vs the fix).
Only attach REAL captures you actually rendered -- never fabricate or mock a screenshot.
If the repo's dev-server guard refuses to start because worktree provisioning is
incomplete (e.g. a missing \`.superset/setup-complete\` sentinel): dispatch already
backgrounded a supervised provisioning run -- check \`.firstmate/provision.log\` in
this worktree and WAIT for it to finish (it can take several minutes), then retry the
dev server. If \`.firstmate/provision-failed\` exists, provisioning failed after
retries: report yourself BLOCKED with that file's contents so the first mate can fix
the environment -- do NOT silently waive UI evidence. If neither file exists, run the
repo's prescribed setup script yourself before declaring screenshots impossible.
If the change isn't visual, or you genuinely can't render it here (no dev server, no keys),
skip this and describe the change in words instead.

# Definition of done
$DOD
EOF
