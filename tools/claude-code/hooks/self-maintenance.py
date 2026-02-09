#!/usr/bin/env python3
"""Self-maintenance enforcement hook for Claude Code.

Enforces the dot-agent operating model's self-maintenance contract:
the agent cannot stop without updating session-log.md in ALL discovered
.agent/ directories (dual-write enforcement).

These hooks are designed to be extended. To add custom behavior (e.g.
additional file tracking, soft nudges), copy this file and modify it.
The extension should be a strict superset — include all core behavior
plus your additions.

Install: ~/.claude/hooks/self-maintenance.py
Configure: add to PreToolUse and Stop hooks in ~/.claude/settings.json
"""

import sys
import json
import os
import hashlib
import time
from pathlib import Path

CHECKPOINT_DIR = Path("/tmp/claude-self-maintenance")
MAX_CHECKPOINT_AGE = 86400  # 24 hours


def find_all_agent_dirs(cwd: str) -> list[Path]:
    """Find all relevant .agent directories (deduplicated)."""
    dirs: list[Path] = []
    d = Path(cwd)
    while d != d.parent:
        candidate = d / ".agent"
        if candidate.is_dir():
            dirs.append(candidate.resolve())
            break
        d = d.parent
    global_agent = Path.home() / ".agent"
    if global_agent.is_dir() and global_agent.resolve() not in dirs:
        dirs.append(global_agent.resolve())
    return dirs


def checksum(filepath: Path) -> str:
    if not filepath.exists():
        return "MISSING"
    return hashlib.sha256(filepath.read_bytes()).hexdigest()


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


def main():
    data = json.load(sys.stdin)
    event = data.get("hook_event_name", "")
    session_id = data.get("session_id", "unknown")
    cwd = data.get("cwd", os.getcwd())

    agent_dirs = find_all_agent_dirs(cwd)
    if not agent_dirs:
        return

    CHECKPOINT_DIR.mkdir(parents=True, exist_ok=True)
    checkpoint = CHECKPOINT_DIR / f"{session_id}.json"

    if event == "PreToolUse":
        if not checkpoint.exists():
            cleanup_old_checkpoints()
            snapshot: dict = {}
            for agent_dir in agent_dirs:
                key = str(agent_dir)
                snapshot[key] = {
                    "session_log": checksum(agent_dir / "session-log.md"),
                    "memory": checksum(agent_dir / "memory.md"),
                }
            checkpoint.write_text(json.dumps(snapshot))

    elif event == "Stop":
        if not checkpoint.exists():
            return

        saved = json.loads(checkpoint.read_text())

        if "session_log" in saved:
            checkpoint.unlink(missing_ok=True)
            return

        missing_dirs: list[str] = []
        for key, saved_checksums in saved.items():
            if key.startswith("_"):
                continue
            agent_dir = Path(key)
            if checksum(agent_dir / "session-log.md") == saved_checksums.get("session_log"):
                missing_dirs.append(key)

        if not missing_dirs:
            checkpoint.unlink(missing_ok=True)
            return

        block_count = saved.get("_block_count", 0)
        if block_count >= 1:
            return

        saved["_block_count"] = block_count + 1
        checkpoint.write_text(json.dumps(saved))

        missing_list = ", ".join(missing_dirs)
        json.dump(
            {
                "decision": "block",
                "reason": (
                    "Self-maintenance contract: update .agent/session-log.md and "
                    ".agent/memory.md before finishing. "
                    f"Session-log NOT updated in: {missing_list}. "
                    "Dual-write required: when a project has its own .agent/, "
                    "BOTH the project and global session-logs must be updated. "
                    "Append session notes to session-log.md and update memory.md "
                    "with any new knowledge from this session."
                ),
            },
            sys.stdout,
        )


if __name__ == "__main__":
    main()
