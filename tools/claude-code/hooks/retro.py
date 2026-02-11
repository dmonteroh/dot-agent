#!/usr/bin/env python3
"""Retro/self-learning enforcement hook for Claude Code.

Enforces the dot-agent operating model's retro contract:
after substantial sessions, prompts the agent to reflect on
behavioral lessons and record durable rules to rules/learned.md.

Runs on Stop (after self-maintenance passes). Fires only when
the session was substantial (source files edited, safety valve
fired in correctness, or session ran for a while).

Safety valve: prompts once, lets through on second attempt.

These hooks are designed to be extended. To add custom behavior
(e.g. diary observation prompts), copy this file and modify it.
The extension should be a strict superset.

Install: ~/.claude/hooks/retro.py
Configure: add to Stop hooks in ~/.claude/settings.json (after self-maintenance)
"""

import sys
import json
import os
import time
from pathlib import Path

CHECKPOINT_DIR = Path("/tmp/claude-retro")
CORRECTNESS_CHECKPOINT_DIR = Path("/tmp/claude-correctness")
MAX_CHECKPOINT_AGE = 86400  # 24 hours

# Session age threshold (seconds) for "ran for a while" heuristic
SESSION_AGE_THRESHOLD = 1800  # 30 minutes


def cleanup_old_checkpoints():
    if not CHECKPOINT_DIR.exists():
        return
    now = time.time()
    for f in CHECKPOINT_DIR.iterdir():
        try:
            if f.suffix == ".json" and (now - f.stat().st_mtime) > MAX_CHECKPOINT_AGE:
                f.unlink(missing_ok=True)
        except OSError:
            pass


def is_substantial_session(session_id: str) -> bool:
    """Determine if the session warrants a retro.

    Checks:
    1. Correctness checkpoint shows source files were edited
    2. Correctness safety valve fired (agent made a caught mistake)
    3. Session has been running for a while (checkpoint age)
    """
    correctness_checkpoint = CORRECTNESS_CHECKPOINT_DIR / f"{session_id}.json"

    if correctness_checkpoint.exists():
        try:
            correctness_state = json.loads(correctness_checkpoint.read_text())

            # Source files were changed
            if correctness_state.get("source_files_changed"):
                return True

            # Safety valve fired (agent skipped a step)
            if correctness_state.get("_safety_valve_fired"):
                return True

            # Check checkpoint age as proxy for session length
            age = time.time() - correctness_checkpoint.stat().st_mtime
            if age > SESSION_AGE_THRESHOLD and correctness_state.get("files_edited"):
                return True
        except (json.JSONDecodeError, OSError):
            pass

    return False


def main():
    data = json.load(sys.stdin)
    event = data.get("hook_event_name", "")
    session_id = data.get("session_id", "unknown")

    if event != "Stop":
        return

    # Load retro state
    CHECKPOINT_DIR.mkdir(parents=True, exist_ok=True)
    checkpoint = CHECKPOINT_DIR / f"{session_id}.json"

    if checkpoint.exists():
        state = json.loads(checkpoint.read_text())
        if state.get("retro_completed"):
            return
        # Safety valve: prompted once, let through on second attempt
        if state.get("_block_count", 0) >= 1:
            return
    else:
        cleanup_old_checkpoints()
        state = {"retro_completed": False, "_block_count": 0}

    # Check if session is substantial enough for retro
    if not is_substantial_session(session_id):
        return

    state["_block_count"] = state.get("_block_count", 0) + 1
    checkpoint.write_text(json.dumps(state))

    json.dump(
        {
            "decision": "block",
            "reason": (
                "Self-learning check before finishing.\n\n"
                "1. Did hooks catch you skipping a step this session?\n"
                "2. Did the user correct your approach or behavior?\n"
                "3. Did you discover a process pattern that would improve future sessions?\n\n"
                "If any yes: append a behavioral rule to .agent/rules/learned.md\n"
                "Format: \"- [YYYY-MM-DD] <rule in imperative form>. "
                "Trigger: <what caused this learning>.\"\n"
                "Rules should be universal (not session-specific), abstracted, and high-impact.\n\n"
                "If nothing worth recording: proceed without updating."
            ),
        },
        sys.stdout,
    )


if __name__ == "__main__":
    main()
