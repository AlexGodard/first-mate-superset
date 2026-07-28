#!/usr/bin/env python3
"""Bounded, read-only Superset fleet snapshot (firstmate#475/#485 adaptation)."""
from __future__ import annotations

import json
import os
import subprocess
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(os.environ.get("SUPERSET_WORKTREES", Path.home() / ".superset/worktrees"))
SKILL = Path(__file__).resolve().parent.parent
STATE = Path(os.environ.get("FM_STATE_OVERRIDE", SKILL / "state"))
LIMIT = max(1, int(os.environ.get("FM_SNAPSHOT_LIMIT", "30")))
try:
    PS_COMMANDS = subprocess.run(
        ["ps", "-axo", "command="], text=True, capture_output=True, check=False
    ).stdout.splitlines()
except OSError:
    PS_COMMANDS = []


def meta(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    try:
        for line in path.read_text(errors="replace").splitlines():
            if "=" in line:
                key, value = line.split("=", 1)
                out[key] = value
    except OSError:
        pass
    return out


def current_state(worktree: Path) -> tuple[str, str, str]:
    if not worktree.is_dir():
        return "unknown", "none", "worktree gone"
    status = worktree / ".firstmate/status"
    recognized = {"working", "needs-decision", "paused", "blocked", "done", "failed"}
    line = ""
    try:
        for candidate in status.read_text(errors="replace").splitlines():
            verb = candidate.split(":", 1)[0].strip()
            if verb in recognized:
                line = candidate
    except OSError:
        pass
    if not line:
        return "unknown", "none", "no current-state source available"
    verb, _, note = line.partition(":")
    verb, note = verb.strip(), note.strip()
    if verb not in {"paused", "blocked"} and any(str(worktree) in cmd and "fm-fleet-snapshot" not in cmd for cmd in PS_COMMANDS):
        return "working", "process", "live process references worktree"
    mapped = {"needs-decision": "parked"}.get(verb, verb)
    return mapped, "status-log", note


def task_rows() -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    if not ROOT.exists():
        return rows
    meta_paths: list[Path] = []
    for current, dirs, files in os.walk(ROOT):
        rel_depth = len(Path(current).relative_to(ROOT).parts)
        dirs[:] = [d for d in dirs if d not in {"node_modules", ".git", ".next", "dist", "build"}]
        if rel_depth >= 8:
            dirs[:] = []
        if Path(current).name == ".firstmate" and "meta" in files:
            meta_paths.append(Path(current) / "meta")
            dirs[:] = []
    for mp in sorted(meta_paths):
        wt = mp.parent.parent
        values = meta(mp)
        state, source, detail = current_state(wt)
        status = wt / ".firstmate/status"
        age = None
        try:
            age = max(0, int(datetime.now().timestamp() - status.stat().st_mtime))
        except OSError:
            pass
        report = wt / ".firstmate/report.md"
        rows.append(
            {
                "id": values.get("branch", wt.name),
                "project": values.get("project", "?"),
                "kind": values.get("kind", "?"),
                "mode": values.get("mode", "?"),
                "branch": values.get("branch", "-"),
                "owner": values.get("owner", "-"),
                "task": values.get("task", ""),
                "state": state,
                "source": source,
                "doing": detail,
                "status_age_seconds": age,
                "workspace": values.get("workspace", ""),
                "worktree": str(wt),
                "report": str(report) if report.exists() else None,
            }
        )
    return rows


def landed_rows() -> list[dict[str, str]]:
    path = STATE / "landed.tsv"
    rows: list[dict[str, str]] = []
    try:
        for line in path.read_text(errors="replace").splitlines():
            parts = line.split("\t", 3)
            if len(parts) == 4:
                rows.append(dict(generated=parts[0], project=parts[1], what=parts[2], artifact=parts[3]))
    except OSError:
        pass
    return rows[-LIMIT:][::-1]


def secondmates() -> list[dict[str, str]]:
    path = Path(os.environ.get("FM_SECONDMATE_REGISTRY", STATE / "secondmates.md"))
    rows: list[dict[str, str]] = []
    active = False
    try:
        for line in path.read_text(errors="replace").splitlines():
            if "secondmates:begin" in line:
                active = True
                continue
            if "secondmates:end" in line:
                active = False
            if active and "|" in line:
                p = [x.strip(" -\t") for x in line.split("|")]
                if len(p) >= 5:
                    rows.append(dict(id=p[0], workspace=p[1], project=p[2], scope=p[3], worktree=p[4]))
    except OSError:
        pass
    return rows[:LIMIT]


tasks = task_rows()
captains_call = [t for t in tasks if t["state"] in {"parked", "blocked", "failed"} or (t["state"] == "done" and t["kind"] == "ship")]
recent = landed_rows() + [
    {"project": str(t["project"]), "what": str(t["doing"]), "artifact": str(t["report"] or "-")}
    for t in tasks if t["state"] == "done" and t["kind"] == "scout"
]
underway = [t for t in tasks if t["state"] in {"working", "paused", "unknown"}]
omitted = []
for name, rows in (("captains_call", captains_call), ("recently_landed", recent), ("underway", underway)):
    if len(rows) > LIMIT:
        omitted.append({"surface": name, "count": len(rows) - LIMIT})

payload = {
    "schema": "fm-superset-snapshot.v1",
    "generated": datetime.now(timezone.utc).isoformat(),
    "worktree_root": str(ROOT),
    "captains_call": captains_call[:LIMIT],
    "recently_landed": recent[:LIMIT],
    "underway": underway[:LIMIT],
    "charted_next": [],
    "secondmates": secondmates(),
    "pending_wakes": sum(1 for p in STATE.glob(".wake-queue.*") if p.is_file() and p.stat().st_size),
    "omitted": omitted,
}
print(json.dumps(payload, separators=(",", ":"), ensure_ascii=False))
