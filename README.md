# .agent/

Persistent, self-maintaining AI context that works across tools and sessions.

## The problem

Every AI coding session starts with amnesia. The agent doesn't know what your project is for, what you decided last week, or why things are the way they are. You re-explain. Every time. Switch tools and you start from zero.

## The idea

A `.agent/` directory at the project root. Any agent reads from it, any agent writes to it.

You explain the project once. The agent writes it down. Before finishing any task, the agent updates what it learned — decisions go into `memory.md`, session notes into `session-log.md`. The next session reads what the previous one wrote.

```
Session 1:  You explain → agent writes purpose.md, memory.md
Session 2:  Agent reads → works → updates memory + session log
Session 3:  Different tool → reads same .agent/ → full continuity
```

## What's inside

```
.agent/
├── rules/          # Behavior rules (adapted from a preset)
├── purpose.md      # What this project is, who it's for
├── memory.md       # Current state, decisions (updated every session)
├── session-log.md  # Meeting notes (appended every session)
└── docs/           # Architecture, features, data flows
```

The core mechanism is the **self-maintenance contract**: the agent *must* update `memory.md`, `session-log.md`, and relevant `docs/` before finishing any task. This is what keeps context alive without manual effort.

## Presets

Rule presets for different domains — pick one during bootstrap or let the agent adapt:

- **[Software development](presets/software-development.md)** — load order, code quality, testing, git discipline
- **[Academic research](presets/academic-research.md)** — evidence-first writing, source traceability, no unsupported claims
- **[Domain knowledge](presets/domain-knowledge.md)** — accumulating and organizing information over time

## Get started

Copy the matching bootstrap prompt from `convention.md` into your first message:

```
Read the .agent/ convention at https://github.com/jlonardi/dot-agent —
start with convention.md, then read the presets/ folder.

Now look at this project:
- Read package.json, README, source files, folder structure, git history
- Check for existing agent configs (.cursorrules, CLAUDE.md, AGENTS.md, .cursor/)

Tell me:
1. What you think this project is
2. Which preset fits best (or if none fit)
3. What you'd put in .agent/

I'll confirm, correct, and fill in what you can't infer. Then create .agent/.
```

15 minutes. One conversation. Your project has persistent memory.

## Update existing .agent/

When the convention evolves, update your project's rules to match:

```
Read the latest .agent/ convention at https://github.com/jlonardi/dot-agent —
start with convention.md, then read the presets/ folder.

Now read my current .agent/rules/ and compare against the convention.
Show me what's changed and update my rules to match.
Keep everything else in .agent/ as-is.
```

## Manual completion check (for agents without hooks)

If your agent cannot enforce completion hooks automatically, run:

```bash
./scripts/verify-agent-context.sh
```

The script verifies that:

- `.agent/memory.md` exists and is non-empty
- `.agent/session-log.md` exists and is non-empty
- `session-log.md` has an entry for today's date (`YYYY-MM-DD`)

If checks fail and you want minimal scaffolding automatically, run:

```bash
./scripts/verify-agent-context.sh --fix
```

`--fix` creates clearly marked placeholders only. The agent must replace
placeholder content with real session details, then rerun verification before
marking work complete.

## How it compares

| | AGENTS.md | Tool-specific files | .agent/ |
|---|---|---|---|
| Agent reads context | Yes | Yes | Yes |
| Agent writes back | No | No | **Yes** |
| Survives tool switch | Partially | No | **Yes** |
| Memory across sessions | No | No | **Yes** |

Use `AGENTS.md` for shared team instructions. Use `.agent/` for personal persistent context.

Read **[convention.md](convention.md)** for the full convention — philosophy, directory structure, self-maintenance contract, tool wiring, and design decisions.

## License

MIT
