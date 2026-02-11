# Claude Code enforcement hooks

Programmatic enforcement of the [dot-agent operating model](../../operating-model.md) for Claude Code.

Without these hooks, the operating model's trust contracts are convention — the agent follows them because the rules say to. With these hooks, they're enforced — the agent literally cannot skip them.

## What's enforced

| Hook | Events | What it does |
|------|--------|-------------|
| `pre-work.py` | PreToolUse | Blocks edits to project files until that project's `.agent/purpose.md` and `.agent/memory.md` have been read. Only triggers for projects with `.agent/`. |
| `correctness.py` | PreToolUse + Stop | Tracks file edits, re-reads, and test/build commands during the session. On Stop, blocks if edited files weren't re-read or if source files changed without tests being run. |
| `self-maintenance.py` | PreToolUse + Stop | Blocks session end until `session-log.md` is updated in ALL discovered `.agent/` dirs. Enforces dual-write (project + global). |
| `retro.py` | Stop | After substantial sessions (source files changed, hooks caught mistakes, or long session), prompts the agent to reflect on behavioral lessons and write rules to `rules/learned.md`. |

### Hook execution order

**PreToolUse:** pre-work → correctness → self-maintenance

**Stop:** correctness → self-maintenance → retro

Order matters for Stop: correctness checks your work, self-maintenance checks your documentation, retro reflects on the whole session. Retro reads correctness's checkpoint to know if the safety valve fired.

## Prerequisites

- **Python 3.10+** — hooks use modern type syntax (`Path | None`) that requires 3.10 or later. Check with `python3 --version`.

## Install

```bash
mkdir -p ~/.claude/hooks
cp hooks/*.py ~/.claude/hooks/

# Merge settings-example.json into your ~/.claude/settings.json
# (add the hooks and permissions sections)
```

Or symlink for auto-updates:

```bash
for hook in pre-work.py correctness.py self-maintenance.py retro.py; do
    ln -sf /path/to/dot-agent/tools/claude-code/hooks/$hook ~/.claude/hooks/$hook
done
```

## Safety valves

All Stop hooks follow the same pattern: block once, then let through on second attempt. This prevents infinite loops when the agent genuinely can't satisfy the contract (e.g. no tests exist in the project, or a read-only session that doesn't need documentation).

## Checkpoints

Each hook stores session state in `/tmp/`:

| Hook | Checkpoint dir |
|------|---------------|
| `pre-work.py` | `/tmp/claude-pre-work/` |
| `correctness.py` | `/tmp/claude-correctness/` |
| `self-maintenance.py` | `/tmp/claude-self-maintenance/` |
| `retro.py` | `/tmp/claude-retro/` |

Checkpoints are per-session (keyed by session ID) and auto-cleaned after 24 hours.

## Extending

These are **core** hooks — they enforce the operating model contract and nothing more.

To add custom behavior (daily bootstrap, inbox enforcement, maintenance prompts, diary nudges, etc.), copy the hooks and extend them. Extensions should be a strict superset: include all core behavior plus your additions. Installing extended hooks replaces the core ones.
