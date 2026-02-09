#!/usr/bin/env python3
"""Daily bootstrap enforcement hook for Claude Code.

Enforces the dot-agent operating model's load order: the agent must read
all required .agent/ files before doing any other work on the first
session of each day.

Required reads:
1. .agent/rules/*.md
2. .agent/purpose.md
3. .agent/memory.md
4. .agent/session-log.md

This is the CORE hook. It enforces only the operating model contract.
For personal assistant extensions (inbox, diary, maintenance prompt),
see dot-agent-assistant which provides an extended version.

Install: ~/.claude/hooks/daily-bootstrap.py
Configure: add to PreToolUse hooks in ~/.claude/settings.json
"""

import sys
import json
import os
from pathlib import Path
from datetime import date

MARKER_DIR = Path("/tmp/claude-bootstrap")
AGENT_DIR = str(Path.home() / ".agent")

REQUIRED_FILES = {
    "rules": "/rules/agent-and-quality.md",
    "purpose": "/purpose.md",
    "memory": "/memory.md",
    "session-log": "/session-log.md",
}


def main():
    data = json.load(sys.stdin)
    event = data.get("hook_event_name", "")

    if event != "PreToolUse":
        return

    MARKER_DIR.mkdir(parents=True, exist_ok=True)
    today = date.today().isoformat()
    marker = MARKER_DIR / f"{today}.json"

    # Load or initialize today's state
    if marker.exists():
        state = json.loads(marker.read_text())
        if state.get("completed"):
            return  # Already bootstrapped today
    else:
        for f in MARKER_DIR.iterdir():
            if f.suffix == ".json" and f.name != f"{today}.json":
                f.unlink(missing_ok=True)
        state = {"completed": False, "files_read": []}

    tool_name = data.get("tool_name", "")
    tool_input = data.get("tool_input", {})

    # Allow Read calls targeting .agent/ and track required file reads
    if tool_name == "Read":
        file_path = tool_input.get("file_path", "")
        if file_path.startswith(AGENT_DIR) or "/.agent/" in file_path:
            for key, suffix in REQUIRED_FILES.items():
                if file_path.endswith(suffix) and key not in state["files_read"]:
                    state["files_read"].append(key)

            if all(key in state["files_read"] for key in REQUIRED_FILES):
                state["completed"] = True

            marker.write_text(json.dumps(state))
            return

    # Allow Glob/Bash calls targeting .agent/
    if tool_name == "Glob":
        pattern = tool_input.get("pattern", "")
        path = tool_input.get("path", "")
        if AGENT_DIR in pattern or AGENT_DIR in path or "/.agent/" in pattern:
            return

    if tool_name == "Bash":
        command = tool_input.get("command", "")
        if "/.agent/" in command:
            return

    # Block until bootstrap complete
    missing = [key for key in REQUIRED_FILES if key not in state["files_read"]]
    missing_list = ", ".join(missing)

    json.dump(
        {
            "decision": "block",
            "reason": (
                f"Daily bootstrap required. Read .agent/ memory before doing anything else. "
                f"Still need to read: {missing_list}. "
                "Load order: (1) .agent/rules/, (2) .agent/purpose.md, "
                "(3) .agent/memory.md, (4) last 5-10 entries of .agent/session-log.md, "
                "(5) relevant .agent/docs/."
            ),
        },
        sys.stdout,
    )


if __name__ == "__main__":
    main()
