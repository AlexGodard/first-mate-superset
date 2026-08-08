# fm-send: the live lane

Reference for the reply branch of [`SKILL.md`](../SKILL.md): how
`fm-send.sh <worktree|workspaceId> "<message>"` reaches a crewmate, and what each
failure code means. Reach for this when a send fails or you need to understand the
verification mechanics.

Exception first: a parked no-mistakes `ask-user` gate is answered directly with
`axi respond`, never via fm-send — see [`no-mistakes.md`](no-mistakes.md).

## Mechanics

The reply lands **in the running desktop session**: `fm-send.sh` calls the fork CLI's
`superset agents send <terminalId> --workspace <id>` → `terminal.writeInput` → the same
PTY the desktop paints, so the crewmate resumes the SAME pane the captain is watching —
full context, no fork. It requires the `.firstmate/superset` sidecar (written at
dispatch by `fm-capture-session.sh`) and a CLI with `agents send` (`FM_SUPERSET_BIN`,
or `~/.superset/bin/superset-fork`, the built `AlexGodard/superset` fork — PR #1 + #2).

Submit gotchas fm-send handles for you: the TUI submits on `\r` (not `\n`), so it
writes the argument then a standalone `\r`; macOS PTY reads can split long input, so it
wraps the argument in a bracketed-paste envelope.

**Verification**: it waits for the crewmate's turn to END (transcript quiet), then
verifies the exact unwrapped prompt in newly appended transcript records — the Claude
Code project transcript for Claude crews, or the Codex rollout
(`~/.codex/sessions/**/rollout-*.jsonl`, matched by `session_meta` cwd) for Codex crews
(`fm-send-verify.py` reads both dialects). A Codex TUI queues input sent mid-turn and
may merge it into a larger pending message, so the verifier accepts the prompt embedded
intact, not only as an exact row. If no prompt appears it retries the send once (drop
case), then exits 8; if different or truncated input appears it aborts immediately
(exit 5) rather than duplicating it. The status file gets its "captain replied" line
**only on verified success**. The call is chainable, so captain↔crewmate dialogue
accumulates context across turns.

## Fail-hard contract

If any precondition is missing, `fm-send.sh` exits non-zero naming exactly which one,
sends nothing it can't verify, and appends nothing to status. **Fix the named
precondition**:

| Exit | Meaning | Fix |
| --- | --- | --- |
| 2 | usage / `FM_LIVE_SEND=0` (retired escape hatch) | correct the invocation |
| 3 | workspace id resolves to no worktree | check the id / fleet `--raw` |
| 4 | no transcript to verify against (nothing sent) | crew never started a session — inspect the pane |
| 5 | different/truncated input observed (never retried) | inspect the pane before resending |
| 6 | no `.firstmate/superset` sidecar | re-run `fm-capture-session.sh` |
| 7 | CLI lacks `agents send` | rebuild the fork |
| 8 | exact prompt never observed | dead PTY? stale terminalId? desktop restarted (superset#5305)? |

Manual last resorts (a human decision, never automatic):
`superset ws open <workspaceId>` and have the captain type into the live session, or
`superset agents create --workspace <id> --prompt …` — a fresh agent, **context-losing**
(only what's on disk).

Tuning: `FM_CODEX_HOME` overrides `~/.codex`;
`FM_LIVE_QUIET_S`/`FM_LIVE_WAIT_S`/`FM_LIVE_TRIES`/`FM_LIVE_POLL_S` tune the
quiet-wait/verify loop.
