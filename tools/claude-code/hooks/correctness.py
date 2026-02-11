#!/usr/bin/env python3
"""Correctness enforcement hook for Claude Code.

Enforces the dot-agent operating model's correctness contract:
- Files that were edited must be re-read before finishing
- Source files changed must be followed by test execution
- Config files changed must be followed by build execution

Runs on PreToolUse (tracking) and Stop (enforcement).
Safety valve: blocks once, then lets through on second attempt.

These hooks are designed to be extended. To add custom behavior,
copy this file and modify it. The extension should be a strict
superset — include all core behavior plus your additions.

Install: ~/.claude/hooks/correctness.py
Configure: add to PreToolUse and Stop hooks in ~/.claude/settings.json
"""

import sys
import json
import os
import time
from pathlib import Path

CHECKPOINT_DIR = Path("/tmp/claude-correctness")
MAX_CHECKPOINT_AGE = 86400  # 24 hours

# File extensions considered "source code" (changes should trigger tests)
SOURCE_EXTENSIONS = {
    ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs",
    ".py", ".pyw",
    ".rs",
    ".go",
    ".java", ".kt", ".kts",
    ".c", ".cpp", ".cc", ".h", ".hpp",
    ".rb",
    ".swift",
    ".cs",
    ".scala",
    ".clj", ".cljs",
    ".ex", ".exs",
    ".zig",
}

# File patterns considered "config" (changes should trigger build)
CONFIG_PATTERNS = {
    "package.json", "tsconfig.json", "tsconfig.build.json",
    "webpack.config", "vite.config", "rollup.config", "esbuild.config",
    "babel.config", ".babelrc",
    "jest.config", "vitest.config",
    "cargo.toml", "go.mod", "go.sum",
    "pyproject.toml", "setup.py", "setup.cfg",
    "gemfile", "requirements.txt",
    ".env", ".env.local", ".env.production",
}

# Commands that count as "running tests"
TEST_COMMANDS = [
    "vitest", "jest", "mocha", "pytest", "python -m pytest",
    "npm test", "npm run test", "yarn test", "pnpm test", "bun test",
    "cargo test", "go test", "dotnet test", "mix test",
    "ruby -e", "rspec", "minitest",
]

# Commands that count as "running build"
BUILD_COMMANDS = [
    "tsc", "npm run build", "yarn build", "pnpm build", "bun build",
    "cargo build", "go build", "dotnet build",
    "make", "cmake", "gradle build", "mvn compile",
]


def is_source_file(filepath: str) -> bool:
    """Check if a file is a source code file (not test, not doc, not config)."""
    p = Path(filepath)
    ext = p.suffix.lower()
    if ext not in SOURCE_EXTENSIONS:
        return False
    # Exclude test files
    name = p.stem.lower()
    if any(pattern in name for pattern in ["test", "spec", ".test", ".spec"]):
        return False
    # Exclude files in test directories
    parts = [part.lower() for part in p.parts]
    if any(part in ("test", "tests", "__tests__", "spec", "specs") for part in parts):
        return False
    return True


def is_config_file(filepath: str) -> bool:
    """Check if a file is a config file."""
    name = Path(filepath).name.lower()
    for pattern in CONFIG_PATTERNS:
        if pattern in name:
            return True
    if ".config." in name:
        return True
    return False


def is_test_command(command: str) -> bool:
    """Check if a bash command runs tests."""
    cmd_lower = command.lower()
    return any(tc in cmd_lower for tc in TEST_COMMANDS)


def is_build_command(command: str) -> bool:
    """Check if a bash command runs a build."""
    cmd_lower = command.lower()
    return any(bc in cmd_lower for bc in BUILD_COMMANDS)


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


def load_state(session_id: str) -> dict:
    CHECKPOINT_DIR.mkdir(parents=True, exist_ok=True)
    checkpoint = CHECKPOINT_DIR / f"{session_id}.json"
    if checkpoint.exists():
        return json.loads(checkpoint.read_text())
    cleanup_old_checkpoints()
    return {
        "files_edited": [],
        "files_reread": [],
        "source_files_changed": False,
        "config_changed": False,
        "tests_run": False,
        "build_run": False,
        "_block_count": 0,
        "_safety_valve_fired": False,
    }


def save_state(session_id: str, state: dict):
    checkpoint = CHECKPOINT_DIR / f"{session_id}.json"
    checkpoint.write_text(json.dumps(state))


def main():
    data = json.load(sys.stdin)
    event = data.get("hook_event_name", "")
    session_id = data.get("session_id", "unknown")
    tool_name = data.get("tool_name", "")
    tool_input = data.get("tool_input", {})

    if event == "PreToolUse":
        handle_pre_tool_use(session_id, tool_name, tool_input)
    elif event == "Stop":
        handle_stop(session_id)


def handle_pre_tool_use(session_id: str, tool_name: str, tool_input: dict):
    """Track file operations and test/build commands."""
    state = load_state(session_id)

    if tool_name in ("Write", "Edit"):
        file_path = tool_input.get("file_path", "")
        if file_path and file_path not in state["files_edited"]:
            # Skip .agent/ files from tracking
            if "/.agent/" not in file_path:
                state["files_edited"].append(file_path)
                if is_source_file(file_path):
                    state["source_files_changed"] = True
                if is_config_file(file_path):
                    state["config_changed"] = True

    elif tool_name == "Read":
        file_path = tool_input.get("file_path", "")
        if file_path and file_path in state["files_edited"]:
            if file_path not in state["files_reread"]:
                state["files_reread"].append(file_path)

    elif tool_name == "Bash":
        command = tool_input.get("command", "")
        if is_test_command(command):
            state["tests_run"] = True
        if is_build_command(command):
            state["build_run"] = True

    save_state(session_id, state)


def handle_stop(session_id: str):
    """Enforce correctness checks before session end."""
    state = load_state(session_id)

    # Nothing to enforce if no files were edited
    if not state["files_edited"]:
        return

    # Safety valve: block once, then let through
    if state["_block_count"] >= 1:
        state["_safety_valve_fired"] = True
        save_state(session_id, state)
        return

    issues = []

    # Check: files edited but not re-read
    not_reread = [f for f in state["files_edited"] if f not in state["files_reread"]]
    if not_reread:
        file_list = ", ".join(Path(f).name for f in not_reread[:5])
        remaining = len(not_reread) - 5
        suffix = f" (+{remaining} more)" if remaining > 0 else ""
        issues.append(f"Files edited but not re-read: {file_list}{suffix}")

    # Check: source files changed but no tests run
    if state["source_files_changed"] and not state["tests_run"]:
        issues.append("Source files changed but no tests detected. Run the project's test suite.")

    if not issues:
        return

    state["_block_count"] = state.get("_block_count", 0) + 1
    save_state(session_id, state)

    json.dump(
        {
            "decision": "block",
            "reason": (
                "Correctness check before finishing.\n\n"
                + "\n".join(f"- {issue}" for issue in issues)
                + "\n\nRe-read your edits and run tests before completing."
            ),
        },
        sys.stdout,
    )


if __name__ == "__main__":
    main()
