# Claude Code enforcement hooks

Programmatic enforcement of the [dot-agent operating model](../../operating-model.md) for Claude Code.

Without these hooks, the operating model's load order and self-maintenance contract are convention — the agent follows them because the rules say to. With these hooks, they're enforced — the agent literally cannot skip them.

## What's enforced

| Hook | Event | What it does |
|------|-------|-------------|
| `self-maintenance.py` | PreToolUse + Stop | Blocks session end until `session-log.md` is updated in ALL discovered `.agent/` dirs. Enforces dual-write. |

## Install

```bash
mkdir -p ~/.claude/hooks
cp hooks/self-maintenance.py ~/.claude/hooks/

# Merge settings-example.json into your ~/.claude/settings.json
# (add the hooks and permissions sections)
```

Or symlink for auto-updates:

```bash
ln -sf /path/to/dot-agent/tools/claude-code/hooks/self-maintenance.py ~/.claude/hooks/
```

## Extending

These are **core** hooks — they enforce the operating model contract and nothing more.

To add custom behavior (daily bootstrap, inbox enforcement, maintenance prompts, diary nudges, etc.), copy the hooks and extend them. Extensions should be a strict superset: include all core behavior plus your additions. Installing extended hooks replaces the core ones.
