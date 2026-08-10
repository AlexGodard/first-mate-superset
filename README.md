# First Mate for Superset

A Superset-native adaptation of [kunchenguid/firstmate](https://github.com/kunchenguid/firstmate):
talk to one captain-facing agent while it dispatches, supervises, and delivers work
from a crew of isolated Superset agent workspaces.

This is an independent adaptation, not a drop-in fork. It keeps Firstmate's nautical
model and several upstream supervision ideas, but replaces tmux/treehouse orchestration
with the Superset CLI, native worktrees, durable wake queues, and harness-specific
Claude/Codex wake behavior.

## What it includes

- One-call ship and scout dispatch through `superset ws create`
- Per-project delivery modes: `direct-PR` and `local-only`
- Claude and Codex custom-agent routing
- Owner-scoped fleets, so concurrent supervisors cannot act on one another's crew
- Live, transcript-verified captain-to-crewmate replies
- Durable watcher wakes with benign-churn filtering and AFK batching
- Superset/Codex turn injection with transcript verification
- Conservative current-state and progress inspection helpers
- Persistent scoped secondmates for larger fleets

The behavioral contract lives in [SKILL.md](SKILL.md); branch-specific detail
(dispatch internals, model routing, live send, watcher internals,
AFK, secondmates) lives in [`reference/`](reference/).

## Requirements

- Bash, Python 3, Git, and GitHub CLI
- macOS for the current Superset deep-link/open integration
- A Superset CLI build supporting:
  - `projects list`
  - `ws create`, `ws open`, and `ws delete`
  - `agents list`
  - `agents send` for live reply and Codex wake injection
- Superset custom agents named `Claude` and/or `Codex`
- Optional: ShellCheck 0.11.0 for deterministic lint parity

This repository expects a machine-level `superset-launch` command for per-dispatch
model pins. The compatibility helpers in `bin/` document that contract.

## Install

```sh
git clone git@github.com:AlexGodard/first-mate-superset.git \
  "$HOME/.agents/skills/first-mate"
cd "$HOME/.agents/skills/first-mate"
cp registry.example.md registry.md
```

If another agent installation needs the same skill, point it at this checkout rather
than maintaining a second copy:

```sh
ln -s "$HOME/.agents/skills/first-mate" "$HOME/.claude/skills/first-mate"
```

Do not replace an existing directory or symlink without backing it up first.

## Configure

Authenticate the Superset CLI:

```sh
superset auth login
superset projects list --json
superset agents list --local --json
```

Edit `registry.md` with your project names and delivery modes. It is intentionally
gitignored because it contains machine/account-specific project IDs.

Agent IDs are resolved live by label. For offline local resolution, set:

```sh
export FM_CLAUDE_AGENT_ID="<local Claude custom-agent UUID>"
export FM_CODEX_AGENT_ID="<local Codex custom-agent UUID>"
```

Remote-host dispatches always resolve agent IDs live because the IDs are host-specific.
`FIRST_MATE_DEVICE` can provide a legacy default device ID when needed.

To activate judgment-driven model routing:

```sh
cp config/crew-dispatch.example.json config/crew-dispatch.json
```

The live profile is also gitignored.

## Test

```sh
bash tests/run.sh
```

The suite stubs Superset and desktop calls. It exercises dispatch, ownership,
delivery-mode briefs, current-state reads, live-send verification, durable
wakes, Claude-style background completion, and the Superset/Codex injection adapter.

## Runtime state

Watcher heartbeats, wake queues, surfaced signatures, reports, secondmate records,
and other live state are stored under `state/`. The directory is ignored wholesale;
never commit it. Python caches and the local project registry are ignored as well.

## Lineage

This project is derived from and inspired by
[kunchenguid/firstmate](https://github.com/kunchenguid/firstmate), created by Kun Chen.
The upstream project is MIT licensed. See [UPSTREAM.md](UPSTREAM.md) for the adaptation
boundary and sync policy.

## License

MIT. See [LICENSE](LICENSE).
