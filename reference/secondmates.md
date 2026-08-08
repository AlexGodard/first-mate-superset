# Secondmates (a supervision tier)

Reference for the secondmate branch of [`SKILL.md`](../SKILL.md). Reach for this when a
fleet outgrows one supervisor — many concurrent tasks across a few distinct
**domains** — and you delegate a domain to a **secondmate**: a persistent agent session
running this same skill, scoped to a set of projects, supervising its **own** crew.
Captain → main first mate → secondmate → crewmate. A handful of crewmates needs no
tier. (Ports upstream firstmate's persistent secondmates,
[#37](https://github.com/kunchenguid/firstmate/pull/37) /
[#42](https://github.com/kunchenguid/firstmate/pull/42).)

You route it scoped work and read its one-line status; it owns the per-crew
supervision underneath.

**Two-tier scoping is automatic via owner ids.** A secondmate's **home** (its
workspace) carries *your* owner id in `.firstmate/meta`, so your `fm-fleet.sh --mine`
shows the secondmate as one `kind=secondmate` line — but not its crew. The secondmate
exports `FM_OWNER=<secondmate-id>` (a stable slug) for everything it dispatches, so its
crew is disjoint from yours and findable by that id (retirement safety reads it).

A secondmate can run on its **own model/effort** — the supervisor-tier equivalent of
the crew's `--model`: pass `--model`/`--effort` to `spawn` and they pin the
secondmate's home session (e.g. a cheap sub-supervisor driving an Opus crew, or
vice-versa).

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

- **Idle-by-default.** The charter (`fm-brief.sh --kind secondmate`) tells the
  secondmate to reconcile only its own already-in-flight crew on startup, then go idle
  and wait. It acts only on (a) its in-flight crew and (b) tasks you `route` into its
  session.
- **Routing** rides `fm-send.sh` (the live lane) — `route` injects a `[ROUTED TASK]`
  message into the secondmate's running session, which dispatches/supervises/delivers
  per the project's mode and reports back through its `.firstmate/status`. Your watcher
  wakes on that status change like any crew line.
- **Escalation chains up.** A secondmate escalates every human/destructive/security
  call to *you* via `needs-decision`; you relay to the captain. It never self-approves,
  regardless of any project's yolo flag.
- **Retirement is safety-gated**: `retire` refuses while the secondmate has
  non-terminal crew (deliver/hand back first, or `--force`); on success it
  `superset ws delete`s the home and drops the registry row (`state/secondmates.md`).
- **Liveness is conservative** (`probe` → `alive|dead|unknown`); `recover` refuses
  unless both the workspace lookup and a missing worktree confirm death.
