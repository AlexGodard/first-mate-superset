# Custom agents & model routing

Reference for the model-selection branch of [`SKILL.md`](../SKILL.md): how the two
custom agents resolve, how per-dispatch model/effort pins thread through to the
crewmate, and the dispatch-profile format. Reach for this when a pin doesn't take
effect, an agent fails to resolve, or you're editing the profile.

## The two custom agents

Both run the machine-level launcher `~/.local/bin/superset-launch` (deliberately NOT
part of this skill):

| Label | Command | When |
| --- | --- | --- |
| **Claude** | `superset-launch claude --dangerously-skip-permissions` (stdin) | Claude models / default |
| **Codex** | `superset-launch codex --dangerously-bypass-approvals-and-sandbox` (argv) | `gpt-*`/`codex-*` models (gpt-5.6 family: sol / terra / luna) |

Scoping happens at the **project level** (per-repo `.mcp.json` / `CLAUDE.md`), not via
agents. `ws create --agent` must receive the **instance UUID**
(`superset agents list --local --json`).

`bin/fm-agent.sh resolve [--model <id>] [--host <id>] <project>` resolves the agent and
prints an eval-able `agent=<uuid> agent_label=… agent_ctx=personal
agent_harness=<claude|codex> agent_pin=live|inert|unknown` line. `fm-spawn.sh` and
`fm-secondmate.sh` call it automatically: Claude models (or no model) → **Claude**;
`gpt-*`/`codex-*` → **Codex**. The UUID resolves **live by label** from
`superset agents list`; `FM_CLAUDE_AGENT_ID` / `FM_CODEX_AGENT_ID` are optional offline
local fallbacks (a `--host` dispatch must resolve live), and `FM_AGENT_ID=<uuid>` forces
the exact agent. Renaming an agent in **Superset → Settings → Agents** breaks the label
match — update `fm-agent.sh` if a label changes.

## How the pin threads through

Env exported by `fm-spawn` never reaches the crewmate — the Superset desktop daemon
spawns the agent pty with its own environment, and the agent launches *during*
`ws create`. So `fm-spawn` stages a one-shot **launch pin** (model + effort, one flag
per line) keyed by the deterministic worktree path *before* `ws create`
(`superset-launch pin set`), and `superset-launch` (state in
`~/.local/state/superset-launch/`) **takes** it at launch — read-once, then deleted —
and injects the harness-appropriate flags:

- **claude**: model via `--model` (bare 1M-capable ids — `claude-opus-4-8`,
  `claude-sonnet-5`, `claude-fable-5` — are rewritten to their `[1m]` variants); effort
  rides `CLAUDE_CODE_EFFORT_LEVEL`; the cliproxy maps the thinking budget onto upstream
  reasoning effort.
- **codex**: model rides `-m`; effort rides `-c model_reasoning_effort=<e>` (`max` maps
  to codex's `xhigh`).

Read-once is deliberate: a later manual *reopen* of the same worktree finds no pin and
falls back to the instance default — the pin governs the initial launch only.

**Local dispatch only:** a `--host` crewmate launches on the remote's agent Command,
which can't see this host's pin file, so `--model`/`--effort` warn and are ignored
there.

This works only while the agents' Commands route through `superset-launch` —
`fm-agent.sh` inspects the Command and reports `agent_pin=inert` if one was reset to
bare `claude`/`codex`, and `fm-spawn` warns on it.

`bin/fm-launch.sh` / `bin/fm-model-pin.sh` are thin compat delegates to
`superset-launch`; `bin/fm-ccs-route.sh` is legacy, out of the launch path.

## The dispatch profile

`config/crew-dispatch.json` (gitignored; copy `config/crew-dispatch.example.json` to
activate) is a list of natural-language `when → use {model, effort}` rules plus a
`default`. **You read the rules and pick the best fit with judgment**, then pass the
concrete `--model`/`--effort` flags — the shell scripts never parse the rules. Typical
shape:

- trivial rename / typo / format sweep → `claude-sonnet-5`, effort `low`
- focused single-file fix → `claude-sonnet-5`, effort `medium`
- big/ambiguous multi-file feature or risky refactor → `claude-opus-4-8`, effort `high`
- read-only scout → cheap model, it only reads and reports

**Resolution precedence** when a profile is active:

1. An explicit captain override for this task ("use haiku for this one") — always wins.
2. The best-fit `rules[]` entry you match by judgment.
3. The profile's `default`.

An omitted model/effort means the instance default (no flag emitted).

**Consultation backstop.** When the profile file exists, `fm-spawn.sh` refuses a real
ship/scout dispatch that has no `--model` — this is what stops the profile from being
silently skipped (the scripts can't match the rules, so they enforce that *you* did).
`FM_DRY_RUN=1` is exempt: dry-run is how you preview a resolution before committing.
With no profile file, `--model` stays purely optional.
