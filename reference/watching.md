# Watcher & crew-state internals

Reference for the supervision loop of [`SKILL.md`](../SKILL.md): what the watcher does
between your turns, and how `fm-crew-state.sh` derives ground truth. Reach for this
when the watcher misbehaves (double wakes, missed wakes, stale heartbeat) or when a
crew-state reading needs interpreting.

## Watcher internals

The watcher blocks until an **actionable** fleet change occurs, then **exits**. Claude
Code re-invokes you directly on that exit; Superset-hosted Codex needs
`fm-watch-superset.sh`, which runs the same watcher and then injects one verified
internal wake prompt into the originating terminal (upstream firstmate
[#27](https://github.com/kunchenguid/firstmate/issues/27)).

- **Singleton per owner** (mkdir-pid lock in `state/`, via `bin/fm-lib.sh`): a second
  `/first-mate watch` — or a stray re-arm before the prior watcher exited — sees the
  live lock and exits immediately (two watchers = two wake turns per fleet change). The
  lock releases on exit (trap) and reclaims a dead holder's lock, so a crashed watcher
  never wedges it. `FM_WATCH_NO_LOCK=1` bypasses (tests).
- **Local and bounded**: it reads local `.firstmate/status` files —
  never git/gh/network inside the loop, so a slow remote can't wedge it (an ad-hoc
  `git ls-remote` watcher silently froze on exactly that).
- **Durable queue**: before exiting on an actionable change, it appends a compact event
  to the per-owner queue (`state/.wake-queue.<owner>`), so the event survives a lost
  background-completion notification. `fm-wake-drain.sh` drains it atomically on wake;
  `fm-watch-guard.sh` reports a pending queue or stale watcher heartbeat while crew is
  in flight (`spawn` and `send` invoke it as a quiet backstop).
- **Heartbeat self-heal**: it exits after `FM_MAX_TICKS` even when nothing changed, so
  it always re-arms.
- **Arm-time catch-up**: it wakes at arm time on actionable crew no prior wake surfaced
  (`state/.last-surfaced.<owner>`), so a crew finishing between watcher runs is never
  baselined away.
- **Declared external waits**: a crew's `paused:` line resurfaces after
  `FM_PAUSE_RESURFACE_SECS` (default 1h).

**Benign churn is absorbed in bash — it never wakes you.** The watcher diffs the
*actionable signature* of the fleet — only crew in `done|blocked|needs-decision|failed`,
or whose last status line carries a captain-relevant phrase (`PR ready`, `checks
green`, `merged`, …) — not the full digest. A crewmate appending `working:` notes all
the way through a long pass changes the digest constantly but not the signature; those
updates are logged to `state/.watch-triage.log` and absorbed. The classifier lives in
`bin/fm-classify-lib.sh` (single source of truth: `fleet_line_is_actionable`,
`fleet_actionable_signature`, `fleet_afk_critical_signature`); `FM_CAPTAIN_RE`
overrides the verb set. (Local equivalent of upstream firstmate's away-mode daemon
triage, [#30](https://github.com/kunchenguid/firstmate/pull/30) /
[#107](https://github.com/kunchenguid/firstmate/pull/107), folded into the watcher.)

**Superset/Codex adapter requirements**: `fm-watch-superset.sh` needs
`SUPERSET_TERMINAL_ID`, `SUPERSET_WORKSPACE_ID`, and `CODEX_TUI_SESSION_LOG_PATH`, all
supplied to Superset Codex terminals. It never sends queue contents — only a bounded
owner+digest wake instruction — and the prompt must appear in the Codex rollout before
the adapter records it as injected. A failed or unverifiable send leaves the durable
queue pending for `fm-watch-guard.sh` and the next ordinary turn. Under Codex, run the
watcher in a persistent `exec_command` session and keep the terminal session alive.

## Crew-state semantics

`.firstmate/status` is an append-only **event log**: a crew deep in a multi-minute
implement/validate stretch writes nothing the whole time, so `tail -1` (the default
`fm-fleet.sh` view) reports the last *event*, not current progress.
`fm-crew-state.sh <worktree>` maps the most recent recognized state event onto a
stable, parseable state (`working|parked|paused|done|blocked|failed`), flags a
torn-down worktree as `unknown`, and ignores `resolved:` decision-history lines. It is
read-only and side-effect free. Source precedence:

- **`source: process`** — positive live-process evidence referencing the worktree
  corroborates a `working` log line (it never overrides an explicit
  needs-decision/blocked/done/failed event).
- **`source: status-log`** — otherwise, the log line is a report, not proof that the
  Superset pane is busy.

For the deeper "is it actually moving?" signals — live processes touching the worktree,
freshest artifacts, per-item progress lines — pair it with
`fm-progress.sh <worktree>`, and confirm delivery claims against ground truth
(`gh pr view`, the remote branch head, the Superset session UI). (Ported from upstream
firstmate [#104](https://github.com/kunchenguid/firstmate/pull/104), addressed by
worktree path rather than tmux window.)
