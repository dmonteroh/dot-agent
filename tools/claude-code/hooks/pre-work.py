#!/usr/bin/env python3
"""Pre-work enforcement hook for Claude Code.

Enforces the dot-agent operating model's pre-work contract:
the agent cannot edit project files until that project's .agent/
context (purpose.md and memory.md) has been read.

Only triggers for projects that have a .agent/ directory. Once a
project's context is loaded, it's not checked again for that session.

These hooks are designed to be extended. To add custom behavior,
copy this file and modify it. The extension should be a strict
superset — include all core behavior plus your additions.

Install: ~/.claude/hooks/pre-work.py
Configure: add to PreToolUse hooks in ~/.claude/settings.json
"""

import sys
import json
import os
from pathlib import Path

CHECKPOINT_DIR = Path("/tmp/claude-pre-work")


def find_project_agent_dir(filepath: str) -> Path | None:
    """Find the .agent/ directory for the project containing filepath.
    Uses abspath (not resolve) to avoid following symlinks."""
    d = Path(os.path.abspath(filepath))
    if d.is_file():
        d = d.parent
    while d != d.parent:
        candidate = d / ".agent"
        if candidate.is_dir():
            return Path(os.path.abspath(str(candidate)))
        d = d.parent
    return None


def load_state(session_id: str) -> dict:
    CHECKPOINT_DIR.mkdir(parents=True, exist_ok=True)
    checkpoint = CHECKPOINT_DIR / f"{session_id}.json"
    if checkpoint.exists():
        return json.loads(checkpoint.read_text())
    return {"loaded_projects": []}


def save_state(session_id: str, state: dict):
    checkpoint = CHECKPOINT_DIR / f"{session_id}.json"
    checkpoint.write_text(json.dumps(state))


def main():
    data = json.load(sys.stdin)
    event = data.get("hook_event_name", "")

    if event != "PreToolUse":
        return

    # Skip when running under the runner (non-interactive, blocking has no benefit)
    import os
    if os.environ.get("AGENT_RUNNER"):
        return

    tool_name = data.get("tool_name", "")
    tool_input = data.get("tool_input", {})
    session_id = data.get("session_id", "unknown")

    # Track Read calls to .agent/ files
    if tool_name == "Read":
        file_path = tool_input.get("file_path", "")
        if not file_path or ("/.agent/" not in file_path):
            return

        agent_dir = find_project_agent_dir(file_path)
        if not agent_dir:
            return

        # Skip global ~/.agent/ — handled by bootstrap
        global_agent = (Path.home() / ".agent").resolve()
        if agent_dir == global_agent:
            return

        state = load_state(session_id)
        agent_key = str(agent_dir)
        if agent_key in state["loaded_projects"]:
            return

        project_state = state.get(agent_key, {"purpose_read": False, "memory_read": False})

        if file_path.endswith("purpose.md"):
            project_state["purpose_read"] = True
        elif file_path.endswith("memory.md"):
            project_state["memory_read"] = True

        state[agent_key] = project_state

        if project_state.get("purpose_read") and project_state.get("memory_read"):
            if agent_key not in state["loaded_projects"]:
                state["loaded_projects"].append(agent_key)

        save_state(session_id, state)
        return

    # Block Write/Edit if project context not loaded
    if tool_name not in ("Write", "Edit"):
        return

    file_path = tool_input.get("file_path", "")
    if not file_path:
        return

    # Find the project .agent/ for this file
    agent_dir = find_project_agent_dir(file_path)
    if not agent_dir:
        return  # No .agent/ in this project

    # Skip if editing .agent/ itself (always allowed)
    try:
        resolved = Path(file_path).resolve()
        if str(resolved).startswith(str(agent_dir)):
            return
    except (OSError, ValueError):
        pass

    # Skip global ~/.agent/
    global_agent = (Path.home() / ".agent").resolve()
    if agent_dir == global_agent:
        return

    state = load_state(session_id)
    agent_key = str(agent_dir)

    # Already loaded this project's context
    if agent_key in state["loaded_projects"]:
        return

    project_state = state.get(agent_key, {"purpose_read": False, "memory_read": False})
    missing = []
    if not project_state.get("purpose_read"):
        missing.append("purpose.md")
    if not project_state.get("memory_read"):
        missing.append("memory.md")

    if not missing:
        # Both read but not yet in loaded list
        state["loaded_projects"].append(agent_key)
        save_state(session_id, state)
        return

    json.dump(
        {
            "decision": "block",
            "reason": (
                f"Pre-work contract: read project context before editing project files. "
                f"This file belongs to a project with .agent/ at {agent_dir}. "
                f"Still need to read: {', '.join(missing)}. "
                f"Read {agent_dir}/purpose.md and {agent_dir}/memory.md first."
            ),
        },
        sys.stdout,
    )


if __name__ == "__main__":
    main()
