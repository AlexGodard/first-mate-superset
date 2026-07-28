#!/usr/bin/env python3
"""Verify that an exact live-send prompt landed in new transcript rows.

Understands both transcript dialects:
- Claude Code project transcripts (queue-operation / attachment / user rows)
- Codex rollout files under ~/.codex/sessions (event_msg user_message and
  response_item role=user rows, nested under "payload")
- Superset's CODEX_TUI_SESSION_LOG_PATH (op/UserTurn rows)

A candidate counts as delivered when it equals the expected prompt OR contains
it intact as a substring — Codex merges input injected near a turn boundary
into the pending user message, so the prompt can land embedded in a larger
message without being truncated or corrupted.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any, Iterable


def prompt_candidates(record: dict[str, Any]) -> Iterable[str]:
    record_type = record.get("type")

    if record_type == "queue-operation":
        content = record.get("content")
        if isinstance(content, str):
            yield content

    if record_type == "attachment":
        attachment = record.get("attachment")
        if isinstance(attachment, dict):
            prompt = attachment.get("prompt")
            if isinstance(prompt, str):
                yield prompt

    if record_type == "user":
        message = record.get("message")
        if isinstance(message, dict):
            content = message.get("content")
            if isinstance(content, str):
                yield content

    # Codex rollout dialect (~/.codex/sessions/**/rollout-*.jsonl): user input is
    # recorded twice per turn — an event_msg/user_message and a response_item
    # message with role=user — both nested under "payload".
    payload = record.get("payload")
    if isinstance(payload, dict):
        # Superset Codex TUI session log dialect. The adapter records input sent
        # through terminal.writeInput as an op whose UserTurn contains text
        # items. This is the transcript fm-watch-superset.sh is given through
        # CODEX_TUI_SESSION_LOG_PATH, distinct from the standard Codex rollout.
        if record.get("kind") == "op":
            user_turn = payload.get("UserTurn")
            if isinstance(user_turn, dict):
                items = user_turn.get("items")
                if isinstance(items, list):
                    for item in items:
                        if (
                            isinstance(item, dict)
                            and item.get("type") == "text"
                            and isinstance(item.get("text"), str)
                        ):
                            yield item["text"]

        if record_type == "event_msg" and payload.get("type") == "user_message":
            message = payload.get("message")
            if isinstance(message, str):
                yield message
        if (
            record_type == "response_item"
            and payload.get("type") == "message"
            and payload.get("role") == "user"
        ):
            content = payload.get("content")
            if isinstance(content, list):
                parts = [
                    part.get("text")
                    for part in content
                    if isinstance(part, dict) and isinstance(part.get("text"), str)
                ]
                if parts:
                    yield "\n".join(parts)


def main() -> int:
    if len(sys.argv) != 4:
        print(
            "usage: fm-send-verify.py <transcript.jsonl> <bytes-before-send> <expected-prompt>",
            file=sys.stderr,
        )
        return 64

    transcript = Path(sys.argv[1])
    try:
        bytes_before = int(sys.argv[2])
    except ValueError:
        print("bytes-before-send must be an integer", file=sys.stderr)
        return 64
    expected = sys.argv[3]

    saw_prompt = False
    try:
        stream = transcript.open("rb")
        stream.seek(bytes_before)
    except OSError as error:
        print(f"cannot read transcript: {error}", file=sys.stderr)
        return 64

    with stream:
        for line in stream:
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(record, dict):
                continue
            for candidate in prompt_candidates(record):
                saw_prompt = True
                if candidate == expected or expected in candidate:
                    return 0

    # 1 means the send has not appeared yet; callers may continue polling/retry.
    # 2 means a different prompt appeared, including a truncated suffix. Retrying or
    # falling back would duplicate/conflict with input already queued in the live pane.
    return 2 if saw_prompt else 1


if __name__ == "__main__":
    raise SystemExit(main())
