# Dispatch internals

Reference for the dispatch branch of [`SKILL.md`](../SKILL.md): the manual sequence
`fm-spawn.sh` automates, launch verification, and Superset UI nuances. Reach for this
when a dispatch fails, when you need a non-standard one-off dispatch, or when a
workspace behaves oddly in the desktop UI.

## Why the CLI, not the MCP

The Superset MCP `create_workspace` writes only the v1 local store; the v2 desktop UI
reads a separate cloud-synced collection, so MCP-created worktrees are invisible in the
sidebar/overview ([superset#4186](https://github.com/superset-sh/superset/issues/4186)).
Dispatch through the `superset` CLI, which writes the v2 cloud collection (CLI-created
workspaces appear in `ws list`/UI and yield a `superset://v2-workspace/…` deep link).
The MCP remains fine for read-only inspection (`list_workspaces`).

CLI-created workspaces may still not *auto-pin* to the sidebar tree
([#4919](https://github.com/superset-sh/superset/issues/4919),
[#5083](https://github.com/superset-sh/superset/issues/5083)) — use `superset ws open`
or the Workspaces page "Add to sidebar". Cosmetic only; supervision is
filesystem-driven (`fm-fleet.sh`) and unaffected.

## The manual sequence

Dispatch is one CLI call that creates the v2-visible worktree *and* spawns the crewmate
with its brief, then a second call to surface it.

1. **Resolve the project's config + cloud id:**
   ```sh
   "$SKILL_ROOT/bin/fm-registry.sh" resolve <project-name>        # -> mode=… yolo=…
   PID=$("$SKILL_ROOT/bin/fm-registry.sh" cloud-project <project-name>)   # live CLI id
   ```
   An unregistered project resolves to `direct-PR off` with a warning — tell the captain
   it's using the safe default and offer to add a registry row. `cloud-project` errors:
   "Not logged in" → captain runs `superset auth login`; "not set up on this host" → the
   project isn't cloned here — surface that.
2. **Pick a branch**: `fm/<short-slug>` for ship, `scout/<short-slug>` for scout (the
   CLI requires a branch for both).
3. **Build the brief** (the crewmate's prompt). The workspace id isn't known until after
   create and the fleet digest doesn't need it, so omit `--workspace`:
   ```sh
   BRIEF=$("$SKILL_ROOT/bin/fm-brief.sh" --kind ship --mode <mode> --project <name> \
     --branch fm/<slug> --owner "$("$SKILL_ROOT/bin/fm-lock.sh" id)" \
     --task "<full task + acceptance criteria + context>")
   ```
   `--owner` tags the crew as yours so `--mine` can scope to you. Use
   `--kind scout --branch scout/<slug>` for investigations. Put everything the crewmate
   needs in `--task`: goal, acceptance criteria, context/file pointers — it works alone
   and can only reach you via `needs-decision`.
4. **Resolve the custom agent, create the worktree + spawn the crewmate in one call,
   then surface it:**
   ```sh
   eval "$("$SKILL_ROOT/bin/fm-agent.sh" resolve <project-name>)"   # sets agent=<uuid> agent_label=…
   WS=$(superset ws create --local --project "$PID" \
        --branch fm/<slug> --name "<kind>-<slug>" \
        --agent "$agent" --prompt "$BRIEF" --json)
   WSID=$(printf '%s' "$WS" | python3 -c 'import sys,json;print(json.load(sys.stdin)["workspace"]["id"])')
   WT="$HOME/.superset/worktrees/$PID/fm/<slug>"        # worktree path (== $ROOT/$projectId/$branch)
   printf '%s' "$WS" | "$SKILL_ROOT/bin/fm-capture-session.sh" "$WT" || true
   "$SKILL_ROOT/bin/fm-open-foreground.sh" "$WSID" "$WT"
   ```
   Use `--host <hostId>` instead of `--local` for a remote host. Keep `$WSID` — it's how
   you `ws open`/`ws delete` later. `--agent` takes the custom-agent **instance UUID**
   `fm-agent.sh` resolved (the bare word `claude` does not resolve).

   `fm-capture-session.sh` writes the `.firstmate/superset` sidecar
   (`workspace=`/`terminalId=`) from the create payload — the **only** moment the live
   agent's `terminalId` is exposed (no "list running sessions" CLI). The sidecar powers
   `fm-send.sh`'s live send and `fm-open-foreground.sh`'s pane focus.
5. **Confirm to the captain**: project, kind, mode, branch, workspace id. Then arm the
   watcher or tell them to run `/first-mate status` later.

The crewmate's first action seeds `.firstmate/meta` and writes `working: started`, so it
appears in the fleet digest immediately.

## Launch verification

A created workspace is NOT proof the crewmate launched. `ws create` exits 0 and prints
success even when the agent fails to spawn — the server returns launch errors only as
`agents:[{ok:false,error}]` in the JSON
([superset#5767](https://github.com/superset-sh/superset/issues/5767)).
`fm-capture-session.sh` detects that shape and exits 4 (`AGENT LAUNCH FAILED: …`);
`fm-spawn.sh` then aborts with retry instructions instead of reporting "spawned".

A missing `terminalId=` in the sidecar without an explicit error is a softer version of
the same smell — `fm-spawn` warns; verify with `fm-crew-state.sh` before trusting the
dispatch.

Known cause of `posix_spawnp failed`: the desktop app leaking pty masters until
`kern.tty.ptmx_max` is exhausted (`lsof /dev/ptmx | grep -c Superset`).
[superset#5305](https://github.com/superset-sh/superset/issues/5305)'s 1.13 fix did not
fully cure it — recurrence confirmed on 1.15.1-canary (the standalone pty-daemon process
still leaks; see the reopen comment). Recovery: restart the Superset desktop app — this
kills live sessions, so check the fleet first.

## Opening without dragging the captain away

Every dispatch opens its workspace — a workspace the captain can't see reads as "you
didn't create it", so the open is the visual signal that dispatch worked.
`fm-open-foreground.sh` background-opens it (`open -g` + the `background=1` deep-link
flag, which the desktop honors by skipping `focusMainWindow`): the agent pane is
foregrounded inside the workspace, the app window stays where it is, and the captain is
never yanked out of their current work. It reuses the sidecar's `terminalId` via the
`?terminalId=…&focusRequestId=…&background=1` deep link, which also avoids the
"2 background processes running" pill a plain `ws open` leaves on a CLI-created
workspace. `FM_OPEN_FOCUS=1` restores the old raise-and-focus behavior for a captain who
wants each dispatch brought to the front.
