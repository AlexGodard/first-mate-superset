---
name: first-mate
description: Act as a "first mate" supervisor — dispatch and monitor a crew of autonomous Superset agent sessions across isolated git worktrees. Use when the user wants parallel work across projects/worktrees, says "dispatch/spawn a crewmate to ship X", "scout/investigate X", asks for fleet/crew status, wants the current/real state of a quiet crewmate, enters away-mode ("/afk", "going afk", "back in an hour"), or invokes /first-mate.
user-invocable: true
---

# first-mate

You (this agent) become the **first mate**: a single supervisor the **captain** (the
user) talks to, who dispatches autonomous **crewmates** into isolated Superset
worktrees, watches their progress, and delivers their work. It ports
[Firstmate](https://github.com/kunchenguid/firstmate)'s orchestration model onto the
**`superset` CLI** (`ws create --agent`, `ws open`, `ws delete`, `projects list`), which
already supplies the worktree isolation, review, and editor that Firstmate built by hand.

> **Why the CLI, not the MCP.** The Superset MCP `create_workspace` writes only the v1
> local store; the v2 desktop UI reads a separate cloud-synced collection, so
> MCP-created worktrees are **invisible in the sidebar/overview** (Superset
> [#4186](https://github.com/superset-sh/superset/issues/4186)) — even ⌘R can't surface
> a row that was never written to the v2 store. The `superset` CLI writes the v2 cloud
> collection (verified: CLI-created workspaces appear in `ws list`/UI and yield a
> `superset://v2-workspace/…` deep link; MCP-created ones do not). So dispatch goes
> through the CLI. The MCP is still fine for read-only inspection (`list_workspaces`).

## The model

| Firstmate | Here (Superset) |
| --- | --- |
| first mate (supervisor) | **you**, this agent |
| crewmate (worker) | a `superset ws create --agent <custom-agent-uuid> --prompt <brief>` session (`bin/fm-agent.sh` picks among the configured Claude Code agents) |
| secondmate (scoped sub-supervisor) | a persistent `ws create` session running this skill, scoped via a charter (`bin/fm-secondmate.sh`, `bin/fm-brief.sh --kind secondmate`) |
| `fm-spawn.sh` (dispatch + batch) | `bin/fm-spawn.sh` — one-call dispatch; `--batch` for zsh-safe fan-out |
| treehouse worktree | `superset ws create` (a git worktree, v2-visible) |
| `fm-brief.sh` brief | the `--prompt` you pass to `ws create` (`bin/fm-brief.sh`) |
| `fm-watch.sh` tmux watcher | `bin/fm-watch-bg.sh` for native background-completion harnesses; `bin/fm-watch-superset.sh` injects verified wake turns into Superset-hosted Codex |
| `fm-send.sh` (type into the live tmux pane) | `bin/fm-send.sh` — injects the reply into the crewmate's live desktop PTY via the fork CLI's `agents send`, verified against the crew's transcript; fails hard if any precondition is missing |
| status files / turn-end hooks | crewmate's local `.firstmate/status` file, plus bounded no-mistakes run-state reconciliation for no-mistakes ship crews |
| `data/projects.md` registry | `registry.md` (`bin/fm-registry.sh`), cross-project |
| committed `AGENTS.md` memory | `bin/fm-ensure-memory.sh` (non-clobbering) |
| local merge gate | `bin/fm-merge-local.sh` |

`SKILL_ROOT` below means this skill's directory (where `bin/` and `registry.md` live).
The CLI needs auth (`superset auth login` or `SUPERSET_API_KEY`); if a CLI call returns
"Not logged in", ask the captain to run `superset auth login` (it has its own credential
store, separate from the desktop app).

## Invocation

The user invokes `/first-mate <verb> <task>` or just describes the intent:

- `/first-mate ship <task>` — dispatch a crewmate to make a PR-ready change.
- `/first-mate scout <task>` — dispatch a read-only investigator that returns a report.
- `/first-mate status` — print the fleet digest and act on anyone needing attention.
- `/first-mate watch` — start/refresh the harness-appropriate watcher.
- `/first-mate afk` (or "going afk", "back in an hour") — enter away-mode supervision: the
  watcher widens its batching and you surface only batched, captain-critical escalations
  until the captain returns (see [Away mode (AFK)](#away-mode-afk)).
- `/first-mate <task>` (no verb) — infer ship vs scout: investigations/questions → scout, changes → ship. If genuinely ambiguous, ask.

The target **project** comes from the task ("scout the payroll repo for…"), else default
to the project of the current worktree. Resolve every project name through the registry.

## Dispatch a crewmate

**Fast path — use `fm-spawn.sh`.** It runs the whole sequence below (registry resolve →
cloud-project → branch/slug → brief → `ws create` → capture-session →
open-foreground) in one call and prints a summary line:

```sh
"$SKILL_ROOT/bin/fm-spawn.sh" <project> "<full task + acceptance criteria + context>"
"$SKILL_ROOT/bin/fm-spawn.sh" --scout <project> "<investigation>"   # read-only investigator
# -> spawned ship <project> branch=fm/<slug> mode=<m> yolo=<y> agent=<label> workspace=<id> worktree=<path>
```

It derives the branch slug from the task, picks the delivery mode from the registry
(override with `--mode`), resolves the right **custom agent** for the project/model (see
"Custom agents" below), tags the crew with your owner id, and always foreground-opens the
workspace. `--branch <leaf>` overrides the slug, `--host <id>` dispatches remotely, and
`FM_DRY_RUN=1` prints the resolved plan without creating anything (preview before a big
fan-out).

**Batch fan-out (zsh-safe).** To dispatch many crewmates at once, pipe one `<project><TAB><task>`
line per crewmate to `--batch` — the loop runs **in bash**, so you never hand-write a
multi-task loop in the tool shell (zsh doesn't word-split unquoted `$vars` and silently
mangles ad-hoc `for` loops — upstream firstmate#33):

```sh
"$SKILL_ROOT/bin/fm-spawn.sh" --batch <<'EOF'
condo-scraper	add a CSV export button to the feed toolbar
payroll	fix the T4 rounding discrepancy
EOF
```

A shared `--scout`/`--host` applies to every line; a failed line is reported and skipped
while the rest still launch.

The manual sequence `fm-spawn.sh` automates, for reference / one-offs:

Dispatch is **one CLI call** that creates the v2-visible worktree *and* spawns the
crewmate with its brief, then a second to surface it.

1. **Resolve the project's config + cloud id:**
   ```sh
   "$SKILL_ROOT/bin/fm-registry.sh" resolve <project-name>        # -> mode=… yolo=…
   PID=$("$SKILL_ROOT/bin/fm-registry.sh" cloud-project <project-name>)   # live CLI id
   ```
   If the project isn't in the registry, `resolve` defaults it to `direct-PR off` and
   warns — tell the captain it's using the safe default and offer to add a registry row.
   If `cloud-project` errors with "Not logged in", have the captain run
   `superset auth login`. If it errors "not set up on this host", the project isn't
   cloned on this host — surface that.
2. **Pick a branch**: `fm/<short-slug>` for ship, `scout/<short-slug>` for scout (the CLI
   requires a branch for both).
3. **Build the brief** (the crewmate's prompt). The workspace id isn't known until after
   create, and the fleet digest doesn't need it, so omit `--workspace`:
   ```sh
   BRIEF=$("$SKILL_ROOT/bin/fm-brief.sh" --kind ship --mode <mode> --project <name> \
     --branch fm/<slug> --owner "$("$SKILL_ROOT/bin/fm-lock.sh" id)" \
     --task "<full task + acceptance criteria + context>")
   ```
   `--owner` tags the crew as yours so `--mine` can scope it to you.
   Use `--kind scout --branch scout/<slug>` for investigations. Put everything the
   crewmate needs in `--task`: goal, acceptance criteria, context/file pointers — it works
   alone and cannot ask you mid-stream except via `needs-decision`.
4. **Resolve the custom agent, create the worktree + spawn the crewmate in one call**,
   then surface it:
   ```sh
   eval "$("$SKILL_ROOT/bin/fm-agent.sh" resolve <project-name>)"   # sets agent=<uuid> agent_label=…
   WS=$(superset ws create --local --project "$PID" \
        --branch fm/<slug> --name "<kind>-<slug>" \
        --agent "$agent" --prompt "$BRIEF" --json)
   WSID=$(printf '%s' "$WS" | python3 -c 'import sys,json;print(json.load(sys.stdin)["workspace"]["id"])')
   WT="$HOME/.superset/worktrees/$PID/fm/<slug>"        # worktree path (== $ROOT/$projectId/$branch)
   printf '%s' "$WS" | "$SKILL_ROOT/bin/fm-capture-session.sh" "$WT" || true   # capture terminalId for live-send + foreground open
   "$SKILL_ROOT/bin/fm-open-foreground.sh" "$WSID" "$WT"   # ALWAYS open: agent foregrounded, window NOT raised
   ```
   **Always open the workspace on dispatch** — never suppress it. A CLI-created
   workspace the captain can't see reads as "you didn't create it" (it lands in the
   cloud collection but isn't auto-pinned to the sidebar), so opening it is the only
   visual signal that dispatch worked.
   Use `--host <hostId>` instead of `--local` for a remote host. Keep `$WSID` — it's how
   you `ws open`/`ws delete` later. (`--agent` takes the **custom agent instance UUID**
   `fm-agent.sh` resolved — the old `claude` preset was removed; see "Custom agents"
   below.) The `fm-capture-session.sh` line writes a
   `.firstmate/superset` sidecar (`workspace=`/`terminalId=`) from the create payload —
   the **only** moment the live agent's `terminalId` is exposed (no "list running
   sessions" CLI) — so `fm-send.sh` can later inject into the
   running desktop session (without the sidecar it fails hard, exit 6), and
   `fm-open-foreground.sh` reuses the same `terminalId` to
   foreground the live agent pane.

   > **A created workspace is NOT proof the crewmate launched.** `ws create` exits 0 and
   > prints success even when the agent fails to spawn — the server catches launch errors
   > and returns them as `agents:[{ok:false,error}]` in the JSON only
   > ([superset#5767](https://github.com/superset-sh/superset/issues/5767)).
   > `fm-capture-session.sh` detects that shape and exits 4 (`AGENT LAUNCH FAILED: …`);
   > `fm-spawn.sh` then aborts with retry instructions instead of reporting "spawned".
   > A missing `terminalId=` in the sidecar without an explicit error is a softer version
   > of the same smell — `fm-spawn` warns; verify with `fm-crew-state.sh` before trusting
   > the dispatch. Known cause of `posix_spawnp failed`: the desktop app leaking pty
   > masters until `kern.tty.ptmx_max` is exhausted (`lsof /dev/ptmx | grep -c Superset`).
   > superset#5305's 1.13 fix did NOT fully cure it — recurrence confirmed on
   > 1.15.1-canary (the standalone pty-daemon process still leaks; see the reopen
   > comment on #5305). Recovery: restart the Superset desktop app (kills live
   > sessions — check the fleet first).

   **Open without dragging the captain away.** `fm-open-foreground.sh` background-opens
   the workspace (`open -g` + the `background=1` deep-link flag): the desktop foregrounds
   the agent pane (setup stays a single background session) **without raising the
   window**, so dispatch surfaces every crewmate yet never yanks the captain out of their
   current work. This relies on the desktop honoring `background=1`
   (`apps/desktop/src/main/index.ts` skips `focusMainWindow` when set). Use
   `FM_OPEN_FOCUS=1` only if the captain explicitly wants each dispatch raised to the
   front. Do **not** skip the open — there is no "don't open" mode in the dispatch flow.
5. **Confirm to the captain**: project, kind, mode, branch, workspace id. Then start/
   refresh the watcher or tell them to run `/first-mate status` later.

The crewmate's first action seeds `.firstmate/meta` and writes `working: started`, so it
shows up in the fleet digest immediately. Because dispatch went through the CLI, it also
appears in the Superset Workspaces overview and is openable.

> **Residual UI nuance.** CLI-created workspaces land in the v2 cloud collection (so they
> show in the overview and `ws open` focuses them), but Superset may not *auto-pin* them
> to the sidebar tree ([#4919](https://github.com/superset-sh/superset/issues/4919),
> [#5083](https://github.com/superset-sh/superset/issues/5083)) — use `superset ws open`
> or the Workspaces page "Add to sidebar". This is cosmetic; supervision is filesystem-
> driven (`fm-fleet.sh`) and unaffected. Do **not** fall back to the MCP `create_workspace`
> — that path is invisible in the UI entirely
> ([#4186](https://github.com/superset-sh/superset/issues/4186)).

## Custom agents (context × model profile)

Since the 2026-07-19 single-profile consolidation there are **two** dispatchable custom
agents, both running the machine-level launcher `~/.local/bin/superset-launch`
(deliberately NOT part of this skill):

| Label | Command | When |
| --- | --- | --- |
| **Claude** | `superset-launch claude --dangerously-skip-permissions` (stdin) | Claude models / default |
| **Codex** | `superset-launch codex --dangerously-bypass-approvals-and-sandbox` (argv) | `gpt-*`/`codex-*` models (gpt-5.6 family: sol / terra / luna) |

Older lane-specific agents are gone — scoping happens at the **project level**
(per-repo `.mcp.json` / `CLAUDE.md`), not via agents. `ws create --agent` must
receive the **instance UUID** (`superset agents list --local --json`); the bare
word `claude` does not resolve.

`superset-launch` consumes the per-dispatch model/effort pin (see the next section) and
execs `claude …` or `codex …`. If an agent's Command is reset to bare
`claude`/`codex`, per-dispatch `--model`/`--effort` goes dead and `fm-spawn` warns via
`agent_pin=inert`.

`bin/fm-agent.sh resolve [--model <id>] [--host <id>] <project>` resolves the agent and
prints an eval-able `agent=<uuid> agent_label=… agent_ctx=personal
agent_harness=<claude|codex> agent_pin=…` line. `fm-spawn.sh` and `fm-secondmate.sh` call it
automatically: Claude models (or no model) → **Claude**; `gpt-*`/`codex-*` → **Codex**.
The UUID is resolved **live by label** from `superset agents list`; optional
`FM_CLAUDE_AGENT_ID` / `FM_CODEX_AGENT_ID` values provide an offline local fallback,
while a `--host` dispatch must resolve live. Renaming an agent in
**Superset → Settings → Agents** breaks the label match, so update `fm-agent.sh` if a
label changes. `FM_AGENT_ID=<uuid>` forces the exact agent.

`bin/fm-ccs-route.sh` (the old single-preset router) is out of the launch path — replaced
by `fm-agent.sh` (dispatch-time resolution) + `superset-launch` (launch-time pin
consumption). Kept only for reference.

## Crewmate model & the dispatch profile

Crewmates default to the model configured by the selected Claude Code agent. Override
the model **and reasoning effort** per dispatch:

```sh
"$SKILL_ROOT/bin/fm-spawn.sh" --model claude-opus-4-8 --effort high <project> "<task>"
"$SKILL_ROOT/bin/fm-spawn.sh" --model gpt-5.6-terra --effort high <project> "<task>"   # → Codex agent
"$SKILL_ROOT/bin/fm-spawn.sh" --batch --model claude-fable-5 <<'EOF'   # applies to every line
…
EOF
```

`--effort` is `low|medium|high|xhigh|max`. `FM_CREW_MODEL` / `FM_CREW_EFFORT` are the env
equivalents (a default for a whole session's dispatches; the flags override them). The
**supervisor's own** model is orthogonal — it's just whatever model *this* session runs on
(set it with `/model`), since the skill is pure orchestration. So "captain on Fable, crew on
Opus" = run `/first-mate` in a Fable session and dispatch with `--model claude-opus-4-8`.

`--model` also selects the agent: Claude ids (or none) → **Claude**; `gpt-*`/`codex-*` ids
→ **Codex** (both harnesses bill through the cliproxy pool).

**no-mistakes mode has a fixed default.** The `/no-mistakes` validation gate runs on the
Codex harness, so a no-mistakes ship dispatched with no `--model` defaults the crew
to **`gpt-5.6-terra` at `high` effort** — a Claude default would drive the wrong gate. An
explicit `--model`/`--effort` (or `FM_CREW_MODEL`/`FM_CREW_EFFORT`) still wins, and this
default only applies to `mode=no-mistakes` (registry `terminal`, or any project forced with
`--mode no-mistakes`); other modes and scouts are untouched. `fm-spawn.sh` sets it after
resolving the mode, so it also satisfies the consultation backstop without a hand-passed flag.

`fm-spawn` stages the pin and `superset-launch` injects it per harness. On **claude**,
effort rides `CLAUDE_CODE_EFFORT_LEVEL` and bare
1M-capable ids (`claude-opus-4-8`, `claude-sonnet-5`, `claude-fable-5`) are rewritten to
their `[1m]` variants; the cliproxy maps the thinking budget onto upstream reasoning
effort. On **codex**, the model rides `-m` and effort rides
`-c model_reasoning_effort=<e>` (`max` is mapped to codex's `xhigh`).

### The dispatch profile (judgment-driven, right-cost routing)

Passing `--model` on every dispatch is the manual lever. The **automatic** layer — ported
from upstream firstmate — is a **dispatch profile** at `config/crew-dispatch.json`
(gitignored; copy `config/crew-dispatch.example.json` to activate). It's a list of
natural-language `when → use {model, effort}` rules plus a `default`. **You (the first mate)
read those rules and pick the best-fit profile with judgment**, then pass the concrete
`--model`/`--effort` flags — the shell scripts never parse the rules. Typical shape:

- trivial rename / typo / format sweep → `claude-sonnet-5`, effort `low`
- focused single-file fix → `claude-sonnet-5`, effort `medium`
- big/ambiguous multi-file feature or risky refactor → `claude-opus-4-8`, effort `high`
- read-only scout → cheap model, it only reads and reports

**Resolution precedence** when a profile is active:
1. An explicit captain override for this task ("use haiku for this one") — always wins.
2. The best-fit `rules[]` entry you match by judgment.
3. The profile's `default`.
An omitted model/effort means the instance default (no flag emitted).

**Consultation backstop.** When `config/crew-dispatch.json` exists, `fm-spawn.sh` **refuses a
real ship/scout dispatch that has no `--model`** — this is what stops the profile from being
silently skipped (the scripts can't match the rules, so they enforce that *you* did).
`FM_DRY_RUN=1` is exempt, because dry-run is exactly how you preview a resolution before
committing. With no profile file present, nothing changes — `--model` stays purely optional.

> **How it threads through.** Env exported by `fm-spawn` never reaches the crewmate — the
> Superset desktop daemon spawns the agent pty with its own environment, and the agent
> launches *during* `ws create`. So `fm-spawn` stages a one-shot **launch pin** (model +
> effort, one flag per line) keyed by the deterministic worktree path *before* `ws create`
> (`superset-launch pin set`), and `superset-launch` — the Claude agent's Command, a
> machine-level script at `~/.local/bin/superset-launch`, state in
> `~/.local/state/superset-launch/` — **takes** it at launch (read-once, then deleted)
> and injects the harness-appropriate flags.
> Read-once is deliberate: a later manual *reopen* of the same worktree finds no pin and
> falls back to the instance default — the pin governs the initial launch only.
> **Local dispatch only:** a `--host` crewmate launches on the remote's agent Command,
> which can't see this host's pin file, so `--model`/`--effort` warn and are ignored there.
> This only works while the agents' Commands route through `superset-launch` —
> `fm-agent.sh` inspects the Command and reports `agent_pin=inert` if one was reset to
> bare `claude`/`codex`, and `fm-spawn` warns on it.

## Delivery modes

Resolved per-project from the registry; the brief already bakes the right
definition-of-done into the crewmate. Your job is the *delivery* half once a crewmate
reports `done`:

- **direct-PR** (default): the crewmate already pushed and opened the PR — relay the URL.
  If you instead see only an earlier `working`/`done: …committed (<sha>)` line and no PR,
  **silence is not a stall**: an implement-and-ship pass can run for many minutes without
  writing a status line. Before acting, confirm against ground truth — the Superset session
  UI (is it still working?), the remote branch head, and `gh pr view`. Re-engage with
  `fm-send.sh <worktree|workspaceId> "finish the pass: push and open the PR"` (injects
  into the crewmate's own live session with full context) **only** if the session is
  genuinely idle. (If `fm-send.sh` fails hard, fix the named precondition first;
  `superset agents create --workspace <id> --prompt …` is a manual, context-losing
  last resort.)
- **local-only**: review the crewmate's branch diff, get the captain's approval (or
  auto-approve only if `yolo=on`), then merge:
  ```sh
  "$SKILL_ROOT/bin/fm-merge-local.sh" <project-main-repo-path> fm/<slug>
  ```
  It fast-forwards the project's default branch; it refuses a diverged or dirty tree
  (have the crewmate rebase and retry).
- **no-mistakes**: the crewmate ships through the [no-mistakes](https://github.com/kunchenguid/no-mistakes)
  validation gate (pipeline → PR → captain merge, highest assurance). The brief tells it to
  implement, then drive `/no-mistakes` itself: the *pipeline* applies fixes, the crewmate only
  responds to gates, and `ask-user` findings come back to you as `needs-decision` — relay the
  captain's answer with `fm-send.sh` and the crewmate feeds it to `no-mistakes axi respond`.
  Completion convention: `done: PR <url> checks green` at the **CI-ready return point** (checks
  green), *not* after merge — the captain reviews and merges. Requirements: the `no-mistakes`
  binary on PATH and the repo initialized (`no-mistakes init`, checked by `no-mistakes doctor`
  in the brief's setup step). Opt-in per project via the registry `mode` column — unlike
  upstream (where it's the default), an unregistered project still falls back to `direct-PR`.
  **Never stop/restart/update the shared no-mistakes daemon** while any crew validates — one
  instance serves every worktree; a restart kills other crews' in-flight runs.

**Fork routing (upstream contributions).** A project whose registry row carries a `fork`
URL (5th column) is contributing to an **upstream parent** you can't push to: `origin` is
the parent, and the crewmate pushes its branch to your fork and opens the PR **against the
parent**. It's an attribute *orthogonal* to the mode, layered onto the push path —
`direct-PR` (push to the fork remote + `gh pr create --head <fork-owner>:…`);
`no-mistakes` (init the gate with `no-mistakes init --fork-url <url>`, which pushes to the
fork and opens the PR against the parent); `local-only` has no remote so it's ignored. `fm-spawn.sh`/`fm-brief.sh` read it from the
registry automatically; override per-dispatch with `fm-spawn.sh --fork <url>`. Delivery is
otherwise unchanged — you still relay the (now upstream) PR URL to the captain to merge.

**yolo** (per-project): when `on`, you may make routine approval calls yourself (PR
merges, `local-only` merges, `ask-user` findings). When `off`, bring those to the
captain. **Always escalate** destructive, irreversible, or security-sensitive actions
regardless of yolo.

## Fleet watcher

Read the fleet on demand with `fm-fleet.sh`. Use `--mine` to see only your own crew
(it self-derives your owner id) — required when other supervisors may be live:

```sh
"$SKILL_ROOT/bin/fm-fleet.sh" --mine              # your crew, one line each
"$SKILL_ROOT/bin/fm-fleet.sh" --mine --attention  # only yours needing you (done|blocked|needs-decision|failed)
"$SKILL_ROOT/bin/fm-fleet.sh" --mine --reconciled # replace stale no-mistakes events with authoritative local run state
"$SKILL_ROOT/bin/fm-fleet.sh" --raw               # global view + worktree paths (overview only)
```

For hands-off supervision, **don't hand-roll a poll loop**. Choose the watcher
entrypoint by the supervisor harness:

```sh
# Claude Code: its harness starts a new turn when the background task exits.
"$SKILL_ROOT/bin/fm-watch-bg.sh"

# Superset-hosted Codex: stock Codex observes the exit but does not start a turn.
# This wrapper runs the same watcher, then injects one verified internal prompt
# into this exact terminal using the inherited Superset IDs.
"$SKILL_ROOT/bin/fm-watch-superset.sh"
```

Run either command as a harness-tracked persistent/background task. Under Codex,
that means a persistent `exec_command` session; do not end the terminal session.
`fm-watch-superset.sh` requires `SUPERSET_TERMINAL_ID`,
`SUPERSET_WORKSPACE_ID`, and `CODEX_TUI_SESSION_LOG_PATH`, all supplied to
Superset Codex terminals. It never sends queue contents: only a bounded
owner+digest wake instruction. The prompt must appear in the Codex rollout before
the adapter records it as injected. A failed or unverifiable send leaves the
durable queue pending for `fm-watch-guard.sh` and the next ordinary turn.

It is a **singleton per owner** (mkdir-pid lock in `state/`, `bin/fm-lib.sh`): a second
`/first-mate watch` — or a stray re-arm before the prior watcher exited — sees the live
lock and exits immediately instead of running a second watcher (two watchers = two wake
turns per fleet change). The lock releases on exit (trap) and reclaims a dead holder's
lock, so a crashed watcher never wedges it. `FM_WATCH_NO_LOCK=1` bypasses (tests).

It blocks until an **actionable** fleet change occurs, then **exits**. Claude Code
re-invokes you directly on that exit (flavor 1); Superset/Codex uses
`fm-watch-superset.sh` to submit a verified internal wake prompt to the originating
terminal (the harness-specific injection described in upstream
[issue #27](https://github.com/kunchenguid/firstmate/issues/27)). It reads
local `.firstmate/status` files and, for no-mistakes ship crews, reconciles them
against the bounded local `no-mistakes axi status` view — never git/gh/network inside
the loop, so a slow remote can't wedge it (an ad-hoc `git ls-remote` watcher silently
froze on exactly that). This catches the direct-response path where the captain runs
`axi respond`, the pipeline finishes, and no new status event is appended. On wake: do
any network checks (`gh pr view`, CI) *then*, run
`fm-fleet.sh --mine --attention --reconciled`, act, and **re-arm
`fm-watch-bg.sh`** while any crew is still in flight. It self-heals with a heartbeat
exit (`FM_MAX_TICKS`) so it always re-arms even when nothing changed. Stop re-arming
once the fleet is idle.

Before exiting on an actionable change, the watcher appends a compact event to the
per-owner durable queue (`state/.wake-queue.<owner>`). On every supervisor wake, run
`fm-wake-drain.sh` before acting. This preserves the event if the harness loses a
background-completion notification. `fm-watch-guard.sh` reports a pending queue or stale
watcher heartbeat while crew is in flight; `spawn` and `send` invoke it as a quiet backstop.

> **Benign churn is absorbed in bash (it never wakes you).** The watcher diffs the
> *actionable signature* of the fleet — only crew in `done|blocked|needs-decision|failed`,
> or whose last status line carries a captain-relevant phrase (`PR ready`, `checks green`,
> `merged`, …) — not the full digest. A crewmate appending `working:` notes the whole way
> through a long pass changes the digest constantly but **not** the actionable
> signature, so those churn updates are logged to `state/.watch-triage.log` and silently
> absorbed instead of burning a supervisor turn each. This is the local equivalent of
> upstream firstmate's away-mode daemon triage ([#30](https://github.com/kunchenguid/firstmate/pull/30),
> [#107](https://github.com/kunchenguid/firstmate/pull/107)) — folded into the watcher,
> since locally the watcher already interposes bash before the LLM (no separate daemon).
> The policy lives in `bin/fm-classify-lib.sh` (shared, single source of truth);
> `FM_CAPTAIN_RE` overrides the verb set.

### Silence is not a stall — get ground truth with `fm-crew-state.sh`

`.firstmate/status` is an append-only **event log**: a crew deep in a multi-minute
implement/validate stretch writes *nothing* the whole time, so `tail -1` (what the
default `fm-fleet.sh` view shows) reports the last *event*, not whether the crew is
currently progressing or wedged. `fm-fleet.sh --reconciled` upgrades positively
attributed no-mistakes ship runs to their current run-step state.
Before you re-engage a crew that has gone quiet, read its state in one stable line:

```sh
"$SKILL_ROOT/bin/fm-crew-state.sh" <worktree-path>   # worktree is in fm-fleet.sh --raw's [...]
# -> state: working · source: status-log · building the export flow
# -> state: parked  · source: status-log · should we X or Y?
# -> state: done    · source: status-log · PR <url>
```

It maps the most recent recognized state event onto a stable, parseable state
(`working|parked|paused|done|blocked|failed`) and flags a torn-down worktree as `unknown`.
`resolved:` decision-history lines are ignored as current state.
For a **ship crew on a branch with a matching no-mistakes run**, the run-step is
**authoritative** (`source: run-step`): `running`/`fixing`/`ci` → `working`,
`awaiting_approval`/`fix_review` → `parked` (with the gate name, finding count, and an
`ask-user` marker), terminal `passed`/`checks-passed` → `done`, `failed`/`cancelled` →
`failed`. While the ci step runs, a ci-log check upgrades `working` → `done` the moment
checks read green, so a green PR is never read as still-validating; a stale
`needs-decision`/`blocked` log line the run has moved past is flagged `superseded`.
(`FM_CREW_STATE_NO_NM=1` skips the lookup; calls are bounded by
`FM_CREW_STATE_NM_TIMEOUT`, default 10s.)
With no run attributed, positive live-process
evidence that references the worktree may override stale history as `source: process`;
otherwise `source: status-log` remains a report, not proof that the Superset pane is busy.
For the deeper "is it actually moving?" signals — live processes touching the worktree,
freshest artifacts, per-item progress lines — pair it with `fm-progress.sh`, and confirm
delivery claims against ground truth (`gh pr view`, the remote branch head, the Superset
session UI). Read-only and side-effect free.
(Ported from upstream firstmate [#104](https://github.com/kunchenguid/firstmate/pull/104),
adapted to address crews by worktree path rather than tmux window.)

## Away mode (AFK)

When the captain steps away (`/first-mate afk`, "going afk", "back in an hour"), enter
**away-mode supervision**: keep delivering autonomously but collapse what reaches the
captain into rare, batched, captain-critical escalations. This ports upstream firstmate's
`/afk` sub-supervisor ([#30](https://github.com/kunchenguid/firstmate/pull/30),
[#54](https://github.com/kunchenguid/firstmate/pull/54)) onto the local model — there is no
separate daemon, because the watcher already does the bash-side triage.

1. **Set the durable flag.** Run `"$SKILL_ROOT/bin/fm-afk.sh" start` (survives a restart;
   on a fresh session, re-enter afk if the flag is present). On return, run `fm-afk.sh stop`
   to clear the flag and drain any buffered watcher events.
2. **Arm the watcher as usual** (`fm-watch-bg.sh`). It reads `.afk` and widens batching: it
   counts only **AFK-critical** lines (`needs-decision|blocked|failed`) toward waking, and
   coalesces a burst of changes into **one** wake by waiting for the actionable signature to
   settle (`FM_AFK_SETTLE` quiet polls, ~60s) before exiting. Routine `done` deliveries no
   longer wake on sight — you pick them up on the next batched wake.
3. **Behavioral contract while away:**
   - **Deliver autonomously.** Carry out the per-mode delivery (relay direct-PR URLs, merge
     `local-only` under standing consent, file scout reports) without narrating each one.
   - **Batch what you tell the captain.** Surface one digested "while you were out" summary
     per wake, not a message per event.
   - **Still escalate the calls that are theirs.** `needs-decision`/`ask-user`,
     and anything destructive/irreversible/security-sensitive, still wait for the captain —
     batched, but never auto-decided. **AFK is orthogonal to authority: "away" never means
     "approves more"** (this is exactly the existing yolo boundary — afk changes *cadence*,
     not *who decides*).
4. **Exit is automatic.** The first genuine captain message (not another `/afk`) means
   they're back: `rm -f "$SKILL_ROOT/state/.afk"`, flush one distilled catch-up, and resume
   full per-wake responsiveness. Bias ambiguous cases toward exit — a present captain beats
   token savings, and a false exit self-corrects (they re-run `/afk`).

Each line is `<state> <project> <kind> <branch> :: <last status line>`. Act on states:

- **done** → run the delivery step for that project's mode (above). For a **scout**,
  read `.firstmate/report.md` and relay it; for a **ship**, drive delivery. Once the
  captain has the result, offer to tear the worktree down (scout worktrees are
  throwaway): `superset ws delete <workspaceId>` (removes the v2 row *and* the worktree;
  do this before any git cleanup to avoid the resurrect bug
  [#5226](https://github.com/superset-sh/superset/issues/5226)), then prune/branch-delete
  if anything remains. Never tear down a ship worktree before its PR/merge has landed —
  and verify that via the PR's `MERGED` state (`gh pr view`), not `git merge-base
  --is-ancestor`: a squash merge rewrites the commit SHA, so the branch never becomes an
  ancestor of the default branch and ancestry always reads "unmerged".

  > **Merging a ship PR — never `gh pr merge --delete-branch`.** A ship branch is
  > checked out in its Superset worktree, so `--delete-branch` (which deletes the remote
  > **and** the local branch) always fails the local half with `cannot delete branch …
  > used by worktree at …`. The remote merge still lands, so it's a benign error — but
  > don't rely on it. Correct order: `gh pr merge <n> --squash` (NO `--delete-branch`) →
  > then teardown via `superset ws delete <workspaceId>`, which removes the worktree and
  > thereby frees the branch → only then is a local branch delete possible (usually
  > unnecessary, since `ws delete` already took the worktree). Deleting the **remote**
  > branch is fine anytime; it's only the *local* delete that the worktree blocks.
- **needs-decision** → relay the options to the captain verbatim, then send the captain's
  answer back **into the crewmate's own session with its full context intact**:
  ```sh
  "$SKILL_ROOT/bin/fm-send.sh" <worktree-path|workspaceId> "<the captain's decision>"
  ```
  `fm-send.sh` injects the reply **into the crewmate's live desktop session** (its only
  lane), so it renders in the running pane and the crewmate resumes its SAME
  conversation — full context, no fork. This works and is **verified** for BOTH
  harnesses: Claude crews verify against the Claude Code transcript, Codex
  crews against their `~/.codex/sessions` rollout (whose `session_meta` cwd identifies
  the worktree; `fm-send-verify.py` reads both dialects). The crewmate keeps reporting
  through `.firstmate/status` (the watcher wakes on the new lines) and the call is
  chainable, so captain↔crewmate dialogue accumulates context across turns. The
  worktree path is in `fm-fleet.sh --raw`'s `[…]`.

  **Fail-hard contract (no silent fallbacks).** If any precondition of the live send is
  missing, `fm-send.sh` exits non-zero naming exactly which one, sends nothing it can't
  verify, and appends nothing to status. Exit codes: `2` usage / `FM_LIVE_SEND=0`
  (retired escape hatch), `3` workspace id resolves to no worktree, `4` no transcript
  to verify against (nothing sent), `5` different/truncated input observed (refuses to
  retry — inspect the pane), `6` no `.firstmate/superset` sidecar (re-run
  `fm-capture-session.sh`), `7` CLI lacks `agents send` (rebuild the fork), `8` exact
  prompt never observed (dead PTY? stale terminalId? desktop restarted —
  superset#5305?). **Fix the named precondition; do not paper over it.** Manual last
  resorts (a human decision, never automatic): `superset ws open <workspaceId>` and
  have the captain type into the live desktop session, or `superset agents create
  --workspace <id> --prompt …` (a fresh agent — **context-losing**, only what's on
  disk).

  > **no-mistakes gates: answer the gate directly, don't relay.** When the
  > `needs-decision` comes from a parked no-mistakes `ask-user` gate (mode
  > `no-mistakes`; `fm-crew-state.sh` shows `parked` / `axi status` shows
  > `awaiting_approval`), the decision consumer is the **pipeline daemon**, not the
  > crewmate — so skip `fm-send.sh` and answer it yourself from the crew's worktree:
  > `cd <worktree> && no-mistakes axi respond --action approve|fix --findings <ids>
  > --instructions "<decision>"` (background it; it blocks until the next gate/outcome).
  > Rationale: relaying via the crewmate adds a hop that can silently drop — the
  > historical failure mode (2026-07-11, Codex crews) was the pane showing the text,
  > the status file saying "captain replied", and the run parked forever because the
  > crewmate never ran `axi respond`. (`fm-send.sh` to Codex crews is verified now —
  > it checks the exact prompt landed in the crew's `~/.codex/sessions` rollout — but
  > delivery-verified ≠ acted-on, so the direct lane remains the rule for parked
  > gates on every harness.) After responding, verify the run moved with
  > `no-mistakes axi status` before trusting any "replied" status line.

  > **The LIVE lane (the only lane).** The reply lands **in the running desktop
  > session**: `fm-send.sh` calls the fork's `superset agents send <terminalId>
  > --workspace <id>` → `terminal.writeInput` → the same PTY the desktop paints, so the
  > crewmate resumes the SAME pane the captain is watching. It requires the
  > `.firstmate/superset` sidecar (written at dispatch by `fm-capture-session.sh`) and
  > a CLI with `agents send` (`FM_SUPERSET_BIN`, or `~/.superset/bin/superset-fork`,
  > the built `AlexGodard/superset` fork — PR #1 + #2) — missing either is a hard
  > error, not a downgrade. Submit gotchas handled by First Mate: the TUI submits on
  > `\r` (not `\n`), so `agents send` writes its argument and then a standalone `\r`.
  > macOS PTY reads can split long input, so fm-send wraps the argument in a
  > bracketed-paste envelope without modifying Superset. It waits for the crewmate's
  > turn to END (transcript quiet), then verifies the exact unwrapped prompt in newly
  > appended transcript records — the Claude Code project transcript for Claude crews, or
  > the Codex rollout (`~/.codex/sessions/**/rollout-*.jsonl`, matched by
  > `session_meta` cwd) for Codex crews. A Codex TUI accepts the same bracketed-paste
  > + CR injection, queues input sent mid-turn, and records it as a `user_message` — a
  > reply injected near a turn boundary may be merged into a larger pending message,
  > so the verifier accepts the prompt embedded intact, not only as an exact row. If
  > no prompt appears it retries the send (drop case), then exits 8; if different or
  > truncated input appears it aborts immediately (exit 5) rather than duplicating it.
  > The status file gets its "captain replied" line **only on verified success**.
- **blocked** → read the worktree (`--raw` gives the path) and help, or escalate.
- **failed** → inspect the session and report; retry or explain what blocks it.

**Pacing:** the harness-appropriate watcher is the supervision loop — it pushes you a
turn the moment a crew finishes or needs you, so you don't poll on a timer. The
watcher wakes on any actionable digest change; on wake, drain `fm-wake-drain.sh`, filter with
`fm-fleet.sh --mine --attention --reconciled` and act only on
`done|blocked|needs-decision|failed`.

## Crew memory

Durable, project-intrinsic knowledge lives in the project's committed memory file
(`AGENTS.md`, or an existing `CLAUDE.md`). Crewmates may read it, but first-mate never
writes it automatically: the brief gives no memory directive and `bin/fm-ensure-memory.sh`
only resolves an existing file (read-only). A crewmate edits it solely when a task is
explicitly about doing so.

## Secondmates (a supervision tier)

When a fleet outgrows one supervisor — many concurrent tasks across a few distinct
**domains** — delegate a domain to a **secondmate**: a persistent agent session that runs
this **same skill**, scoped to a set of projects, supervising its **own** crew. You (the
main first mate) route it scoped work and read its one-line status; it owns the per-crew
supervision underneath. Captain → main first mate → secondmate → crewmate. This ports
upstream firstmate's persistent secondmates ([#37](https://github.com/kunchenguid/firstmate/pull/37),
[#42](https://github.com/kunchenguid/firstmate/pull/42)) onto Superset. Only reach for it
when the crew is genuinely large; a handful of crewmates needs no tier.

**Two-tier scoping is automatic via owner ids.** A secondmate's **home** (its workspace)
carries *your* owner id in `.firstmate/meta`, so your `fm-fleet.sh --mine` shows the
secondmate as one `kind=secondmate` line — but **not** its crew. The secondmate exports
`FM_OWNER=<secondmate-id>` (a stable slug) for everything it dispatches, so its crew is
disjoint from yours and findable by that id (retirement safety reads it). No fm-fleet
changes — the existing scan handles both tiers.

A secondmate can run on its **own model/effort** — the supervisor-tier equivalent of the
crew's `--model` (upstream's `config/secondmate-harness`): pass `--model`/`--effort` to
`spawn` and they pin the secondmate's home session (e.g. a cheap Haiku sub-supervisor driving
an Opus crew, or vice-versa).

```sh
# spin up a scoped secondmate (its home lives in <home-project>)
"$SKILL_ROOT/bin/fm-secondmate.sh" spawn payroll-domain \
   --scope "payroll,openrouter-stats-v2" --project payroll --model claude-sonnet-5
"$SKILL_ROOT/bin/fm-secondmate.sh" list                       # id, scope, home, in-flight crew, status
"$SKILL_ROOT/bin/fm-secondmate.sh" probe payroll-domain       # alive|dead|unknown, conservative
"$SKILL_ROOT/bin/fm-secondmate.sh" recover payroll-domain     # only confirmed-dead homes
"$SKILL_ROOT/bin/fm-secondmate.sh" route payroll-domain "fix the T4 rounding discrepancy"
"$SKILL_ROOT/bin/fm-secondmate.sh" retire payroll-domain      # refuses if its crew is in flight (--force overrides)
```

- **Idle-by-default.** The charter (`fm-brief.sh --kind secondmate`) tells the secondmate
  to reconcile only its own already-in-flight crew on startup, then **go idle and wait** —
  it never self-initiates surveys, audits, or new work. It acts only on (a) its in-flight
  crew and (b) tasks you `route` into its session.
- **Routing** rides `fm-send.sh` (the live lane) — `route` injects a `[ROUTED TASK]`
  message into the secondmate's running session, which dispatches/supervises/delivers per
  the project's mode and reports back through its `.firstmate/status`. Your watcher wakes on
  that status change like any crew line.
- **Escalation chains up.** A secondmate escalates every human/destructive/security call to
  *you* via `needs-decision`; you relay to the captain. It never self-approves, regardless
  of any project's yolo flag.
- **Retirement is safety-gated**: `retire` refuses while the secondmate has non-terminal
  crew (deliver/hand back first, or `--force`); on success it `superset ws delete`s the home
  and drops the registry row (`state/secondmates.md`).

## Safety rules (hard)

1. **Read-only over project checkouts** except the sanctioned `local-only` merge via
   `fm-merge-local.sh` and approved PR merges. Never run state-changing git in a project
   main checkout otherwise — crewmates work in their own worktrees.
2. **Crewmates stay in their worktree.** The brief enforces this; don't override it.
3. **Escalate human calls.** `needs-decision` / `ask-user` findings, and anything
   destructive/irreversible/security-sensitive, go to the captain — unless `yolo=on`
   covers the routine ones (never the destructive ones).
4. **Unregistered project → safe default** (`direct-PR off`). Never silently grant extra autonomy.
5. **Act only on your own crew.** With other supervisors possibly live, supervise and
   deliver through `--mine` (needs `FM_OWNER`); never deliver/tear down crew you don't own.
6. **Report faithfully.** If a crewmate failed or you skipped a delivery step, say so.
7. **Gate agents never drive the fleet.** No-mistakes validation agents are read-only
   observers; `spawn`, `send`, secondmate mutation, and recovery refuse their environment.

## Helper reference

| Script | Purpose |
| --- | --- |
| `bin/fm-spawn.sh [--scout] [--branch <s>] [--mode <m>] [--model <m>] [--effort <e>] [--host <id>] <project> <task…>` | **one-call dispatch**: the whole sequence (resolve→cloud-project→agent→branch→brief→`ws create`→capture→open) + summary line. `--model`/`--effort` pin the crewmate's launch; Claude ids → Claude agent, `gpt-*`/`codex-*` ids → Codex agent. Refuses a real dispatch w/o `--model` when `config/crew-dispatch.json` is active; `--batch` reads `<project>\t<task>` lines on stdin. |
| `bin/fm-agent.sh resolve [--model <id>] [--host <id>] <project>` | resolve **Claude** (Claude ids / no model) or **Codex** (`gpt-*`/`codex-*`), then print eval-able `agent=<uuid> agent_label=… agent_ctx=personal agent_harness=claude\|codex agent_pin=live\|inert\|unknown`. Resolves the UUID live by label from `superset agents list`; `FM_CLAUDE_AGENT_ID` / `FM_CODEX_AGENT_ID` provide optional offline local fallbacks (`--host` must resolve live), and `FM_AGENT_ID` forces. |
| `~/.local/bin/superset-launch claude\|codex [flags…]` \| `… pin set\|take <worktree> [args…]` | **machine-level launcher, not part of this skill** — both agents' launch Command AND the pin store (state: `~/.local/state/superset-launch/pending-model/`). Launch takes the pin (read-once; `SUPERSET_LAUNCH_MODEL`/`_EFFORT` or `FM_CREW_MODEL`/`FM_CREW_EFFORT` env fallbacks) and executes `claude [--model …]` (effort via `CLAUDE_CODE_EFFORT_LEVEL`, `[1m]` rewrite, gpt/codex pins dropped) or `codex [-m …] [-c model_reasoning_effort=…]` (`max`→`xhigh`, claude pins dropped). `bin/fm-launch.sh`/`bin/fm-model-pin.sh` remain as thin compat delegates. |
| `bin/fm-secondmate.sh spawn <id> --scope <p,p> --project <home> \| list \| probe <id> \| recover <id> \| route <id> <task…> \| retire <id> [--force]` | persistent **secondmate** lifecycle. Liveness is conservative (`alive\|dead\|unknown`); recovery refuses unless both the workspace lookup and missing worktree confirm death |
| `bin/fm-lib.sh` (sourced) | shared helpers — portable mkdir-pid **singleton lock** (`fm_singleton_acquire`/`fm_singleton_release`) used by the watcher |
| `bin/fm-lock.sh id` | this session's stable owner id (the harness PID, walked from the shell's ancestry) — keeps concurrent supervisors' crews disjoint. Never a mutex; never blocks |
| `bin/fm-registry.sh resolve\|cloud-project\|list\|device` | `resolve`→mode/yolo; `cloud-project`→live CLI project id; `device`→host id |
| `bin/fm-ccs-route.sh [claude-args…]` | **legacy — no longer in the launch path** (served the removed `claude` preset; superseded by `fm-agent.sh` + `superset-launch`). Kept for reference |
| `bin/fm-model-pin.sh set\|take <worktree> [args…]` | **compat delegate** → `superset-launch pin` (the one-shot per-worktree launch-flag handoff moved to the machine-level script; env can't reach the daemon-spawned agent, so `set` stages before `ws create` and `take` reads-once + deletes at launch) |
| `bin/fm-brief.sh … --owner <id> [--harness claude\|codex]` | emit the crewmate prompt (ship/scout × delivery mode); `--owner` tags crew for `--mine` scoping. `--harness codex` (passed automatically by `fm-spawn.sh` from `fm-agent.sh`'s resolution) appends the Codex-only long-running-process recipe: Codex exec shells reap `nohup`/`&`/`disown` children, so dev servers must run in a persistent `exec_command({tty:true, yield_time_ms:…})` session, verified by polling the app URL from a separate session. Claude crews don't get the block (their Bash tool has `run_in_background`) |
| `bin/fm-fleet.sh [--mine\|--attention\|--raw\|--reconciled]` | fleet status digest; `--mine` (needs `FM_OWNER`) scopes to your own crew; `--reconciled` replaces stale no-mistakes ship events only when a matching bounded local run-step is authoritative |
| `bin/fm-send.sh <worktree\|workspaceId> <msg>` | reply to a crewmate **with full context** — the LIVE lane only (`superset agents send` → running desktop session, crewmate resumes its SAME pane; needs the `.firstmate/superset` sidecar + fork CLI), verified against the crew's transcript on BOTH harnesses (Claude project transcript, or the Codex rollout matched by cwd). **Fails hard** on any missing precondition — exit 3 no worktree, 4 no transcript, 5 mismatch (never retried), 6 no sidecar, 7 CLI lacks `agents send`, 8 prompt never observed — sends nothing unverifiable, appends to status only on verified success. Chainable; reports back via `.firstmate/status`. `FM_SUPERSET_BIN` overrides the fork binary; `FM_CODEX_HOME` overrides `~/.codex`; `FM_LIVE_QUIET_S`/`FM_LIVE_WAIT_S`/`FM_LIVE_TRIES`/`FM_LIVE_POLL_S` tune the quiet-wait/verify loop |
| `bin/fm-capture-session.sh <worktree> < ws-create.json` | at dispatch, persist `workspace=`/`terminalId=` from the `ws create --json` payload to `.firstmate/superset` — the only point the live agent's `terminalId` is exposed; powers `fm-send.sh`'s live send (without it fm-send fails hard, exit 6) + `fm-open-foreground.sh`. Also detects a failed agent launch (`agents:[{ok:false,error}]`, superset#5767) and exits 4 so `fm-spawn` aborts loudly instead of reporting a dead crewmate as "spawned" |
| `bin/fm-open-foreground.sh <workspaceId> <worktree\|--terminal <id>>` | background-open a crewmate workspace with the AGENT terminal foregrounded (setup stays a single background session) via the `?terminalId=…&focusRequestId=…&background=1` deep link — avoids the "2 background processes running" pill a plain `ws open` leaves on a CLI-created workspace, and **doesn't raise the window** (`open -g` + `background=1`, which the desktop honors by skipping `focusMainWindow`). Dispatch ALWAYS opens — there is no "don't open" mode. `FM_OPEN_FOCUS=1` = old raise-and-focus; `FM_SUPERSET_BIN` overrides the binary |
| `bin/fm-watch-bg.sh` | local-only background watcher; durably enqueues before exiting, reconciles no-mistakes ship completion after direct `axi respond`, absorbs benign churn, heartbeats its owner chain, honors AFK batching, resurfaces declared `paused:` external waits on `FM_PAUSE_RESURFACE_SECS` (default 1h), and wakes at arm time on actionable crew no prior wake surfaced (`state/.last-surfaced.<owner>`) so a crew finishing between watcher runs is never baselined away |
| `bin/fm-watch-superset.sh` | Superset/Codex adapter around `fm-watch-bg.sh`: after an actionable queue write, injects one bounded internal wake into the originating terminal via `agents send`, verifies the exact prompt in the Codex rollout, and deduplicates the queue snapshot; heartbeats never inject and failed verification leaves the durable queue untouched |
| `bin/fm-classify-lib.sh` (sourced) | shared wake classifier — `fleet_line_is_actionable` / `fleet_actionable_signature` / `fleet_afk_critical_signature`; the single source of truth for captain-relevant vs benign, used by the watcher. `FM_CAPTAIN_RE` overrides the verb set |
| `bin/fm-wake-drain.sh` / `bin/fm-watch-guard.sh` | atomically drain durable per-owner wake events / diagnose pending events or a stale watcher heartbeat |
| `bin/fm-afk.sh start\|stop\|status` | durable Superset away-mode lifecycle; `stop` performs the final wake drain |
| `bin/fm-crew-state.sh <worktree>` | conservative **current-state** (`working\|parked\|paused\|done\|blocked\|failed\|unknown`) with `source: run-step\|process\|status-log\|none`; a matching no-mistakes run is authoritative; never equates workspace existence with active progress |
| `bin/fm-progress.sh <worktree> [extra-dir ...]` | granular read-only **progress peek** for one crew: status tail + `.firstmate/progress` tail (opt-in convention baked into the brief: long loops tee per-item lines there) + live processes touching the worktree + freshest artifacts. For crews where the agent is inside one long command and can't append status lines |
| `bin/fm-fleet-snapshot.sh` | bounded `fm-superset-snapshot.v1` JSON for `/bearings`: Captain's Call, Recently Landed, Underway, Charted Next, secondmates, pending wakes, and explicit omissions |
| `bin/fm-record-landed.sh <project> <summary> [artifact]` | append durable delivery evidence before teardown removes the worktree; use after a PR/local change is actually landed |
| `bin/fm-doctor.sh` | Superset-only diagnostics: CLI/auth/host, the Claude and Codex custom-agent labels, dependencies, registry, and watcher health. It never installs or selects upstream backends |
| `bin/fm-ensure-memory.sh [dir]` | resolve/create the project memory file (non-clobbering) |
| `bin/fm-merge-local.sh <proj> <branch>` | fast-forward local merge for `local-only` delivery |

Edit `registry.md` to onboard a project or change its delivery mode.
