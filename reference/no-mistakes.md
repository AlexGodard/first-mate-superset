# no-mistakes delivery mode

Reference for the `no-mistakes` branch of [`SKILL.md`](../SKILL.md)'s delivery modes:
how a crew ships through the [no-mistakes](https://github.com/kunchenguid/no-mistakes)
validation gate and how you supervise its parked gates. Reach for this when a
no-mistakes ship crew reports `needs-decision`, parks on a gate, or when you're
onboarding a project to the mode.

## The mode

The crewmate implements, then drives `/no-mistakes` itself: the *pipeline* applies
fixes, the crewmate only responds to gates, and `ask-user` findings come back to you as
`needs-decision`. Pipeline → PR → captain merge: highest assurance.

Gate mechanics run **vanilla**: the official /no-mistakes skill is the sole authority
for how the crewmate drives gates (approve/fix/skip on judgment, per the findings
table's `action` column). The brief layers only first-mate plumbing on top — ask-user
findings route to the captain via `needs-decision`, and approve/skip responses get a
one-line status note. The global config keeps `auto_fix.review: 0` (the official
default) so review findings *park* for that judgment instead of being silently
self-fixed — 2026-08-08: a `review: 3` override fixed every suggestion wholesale and
compounded into 70–120-commit piles that never converged. A two-fix-round-per-step cap
was briefly added the same day, then removed in favor of the official skill's untouched
guidance; reintroduce it in the brief only if vanilla runs start looping again.

- **Completion convention**: `done: PR <url> checks green` at the **CI-ready return
  point** (checks green), *not* after merge — the captain reviews and merges.
- **Requirements**: the `no-mistakes` binary on PATH and the repo initialized
  (`no-mistakes init`; the brief's setup step checks with `no-mistakes doctor`).
- **Opt-in per project** via the registry `mode` column — an unregistered project falls
  back to `direct-PR`.
- **Crew model default**: a no-mistakes ship dispatched with no `--model` defaults to
  `gpt-5.6-terra` at `high` effort — the gate runs on the Codex harness, so a Claude
  default would drive the wrong gate. An explicit `--model`/`--effort` (or
  `FM_CREW_MODEL`/`FM_CREW_EFFORT`) still wins; other modes and scouts are untouched.
  `fm-spawn.sh` sets it after resolving the mode, so it also satisfies the consultation
  backstop without a hand-passed flag.

**One shared daemon serves every worktree.** Stop, restart, or update it only when no
crew's run is validating — a restart kills other crews' in-flight runs.

## Parked `ask-user` gates: answer directly

When a `needs-decision` comes from a parked no-mistakes `ask-user` gate
(`fm-crew-state.sh` shows `parked` / `axi status` shows `awaiting_approval`), the
decision consumer is the **pipeline daemon**, not the crewmate — so skip `fm-send.sh`
and answer it yourself from the crew's worktree:

```sh
cd <worktree> && no-mistakes axi respond --action approve|fix|skip --findings <ids> \
  --instructions "<the captain's decision>"   # background it; blocks until the next gate/outcome
```

Relaying via the crewmate adds a hop that can silently drop — the historical failure
mode (2026-07-11, Codex crews) was the pane showing the text, the status file saying
"captain replied", and the run parked forever because the crewmate never ran
`axi respond`. Delivery-verified ≠ acted-on, so the direct lane is the rule for parked
gates on every harness. After responding, verify the run moved with
`no-mistakes axi status` before trusting any "replied" status line.
