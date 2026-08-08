# Away mode (AFK)

Reference for the away-mode branch of [`SKILL.md`](../SKILL.md). Enter when the captain
steps away (`/first-mate afk`, "going afk", "back in an hour"): keep delivering
autonomously but collapse what reaches the captain into rare, batched,
captain-critical escalations. (Ports upstream firstmate's `/afk` sub-supervisor,
[#30](https://github.com/kunchenguid/firstmate/pull/30) /
[#54](https://github.com/kunchenguid/firstmate/pull/54) — no separate daemon here,
because the watcher already does the bash-side triage.)

1. **Set the durable flag.** Run `"$SKILL_ROOT/bin/fm-afk.sh" start` (survives a
   restart; on a fresh session, re-enter afk if the flag is present). On return, run
   `fm-afk.sh stop` to clear the flag and drain any buffered watcher events.
2. **Arm the watcher as usual** (`fm-watch-bg.sh`). It reads `.afk` and widens
   batching: it counts only **AFK-critical** lines (`needs-decision|blocked|failed`)
   toward waking, and coalesces a burst of changes into **one** wake by waiting for the
   actionable signature to settle (`FM_AFK_SETTLE` quiet polls, ~60s) before exiting.
   Routine `done` deliveries no longer wake on sight — you pick them up on the next
   batched wake.
3. **Behavioral contract while away:**
   - **Deliver autonomously.** Carry out the per-mode delivery (relay direct-PR URLs,
     merge `local-only` under standing consent, file scout reports) without narrating
     each one.
   - **Batch what you tell the captain.** One digested "while you were out" summary per
     wake, not a message per event.
   - **Still escalate the calls that are theirs.** `needs-decision`/`ask-user`, and
     anything destructive/irreversible/security-sensitive, wait for the captain —
     batched, but never auto-decided. AFK is orthogonal to authority: "away" never
     means "approves more" (the existing yolo boundary — afk changes *cadence*, not
     *who decides*).
4. **Exit is automatic.** The first genuine captain message (not another `/afk`) means
   they're back: `rm -f "$SKILL_ROOT/state/.afk"`, flush one distilled catch-up, and
   resume full per-wake responsiveness. Bias ambiguous cases toward exit — a present
   captain beats token savings, and a false exit self-corrects (they re-run `/afk`).
