# Upstream lineage

The conceptual upstream is [kunchenguid/firstmate](https://github.com/kunchenguid/firstmate).
This repository preserves its MIT notice and cites the upstream issues and pull requests
that informed specific supervision behavior in `SKILL.md` and script comments.

## Why this is a standalone adaptation

Upstream Firstmate is organized around tmux and treehouse. This implementation uses:

- Superset CLI-created workspaces and native git worktrees
- Superset custom agents for Claude and Codex
- Filesystem event logs plus conservative current-state reconciliation
- Per-owner durable wake queues
- Native background completion for Claude-style harnesses
- Verified prompt injection for Superset-hosted Codex sessions

Those differences affect the orchestration boundary rather than a small backend adapter,
so a standalone repository makes the divergence explicit and keeps machine-specific
integration work out of upstream's core.

## Upstream → local mapping

| Firstmate | Here (Superset) |
| --- | --- |
| first mate (supervisor) | the agent running `SKILL.md` |
| crewmate (worker) | a `superset ws create --agent <custom-agent-uuid> --prompt <brief>` session (`bin/fm-agent.sh` picks the agent) |
| secondmate (scoped sub-supervisor) | a persistent `ws create` session running this skill, scoped via a charter (`bin/fm-secondmate.sh`, `bin/fm-brief.sh --kind secondmate`) |
| `fm-spawn.sh` (dispatch + batch) | `bin/fm-spawn.sh` — one-call dispatch; `--batch` for zsh-safe fan-out |
| treehouse worktree | `superset ws create` (a git worktree, v2-visible) |
| `fm-brief.sh` brief | the `--prompt` passed to `ws create` (`bin/fm-brief.sh`) |
| `fm-watch.sh` tmux watcher | `bin/fm-watch-bg.sh` (native background completion) / `bin/fm-watch-superset.sh` (verified wake injection into Superset-hosted Codex) |
| `fm-send.sh` (type into the live tmux pane) | `bin/fm-send.sh` — verified injection into the crewmate's live desktop PTY via the fork CLI's `agents send` |
| status files / turn-end hooks | crewmate-local `.firstmate/status`, plus bounded no-mistakes run-state reconciliation |
| `data/projects.md` registry | `registry.md` (`bin/fm-registry.sh`), cross-project |
| committed `AGENTS.md` memory | `bin/fm-ensure-memory.sh` (non-clobbering) |
| local merge gate | `bin/fm-merge-local.sh` |

## Sync policy

Upstream changes are reviewed conceptually, then ported only when they preserve:

1. owner isolation between concurrent supervisors;
2. durable delivery before any wake notification;
3. fail-hard, transcript-verified live sends;
4. local and bounded watcher polling;
5. Superset-visible workspace creation through the CLI.

When porting an upstream idea, link its issue or pull request in the relevant code or
documentation. Do not copy local runtime state, registries, agent UUIDs, or credentials.
