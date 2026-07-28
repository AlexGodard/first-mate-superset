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

## Sync policy

Upstream changes are reviewed conceptually, then ported only when they preserve:

1. owner isolation between concurrent supervisors;
2. durable delivery before any wake notification;
3. fail-hard, transcript-verified live sends;
4. local and bounded watcher polling;
5. Superset-visible workspace creation through the CLI.

When porting an upstream idea, link its issue or pull request in the relevant code or
documentation. Do not copy local runtime state, registries, agent UUIDs, or credentials.
