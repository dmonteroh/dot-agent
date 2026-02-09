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

### System install (one time)

Copy this prompt into any capable agent. It reads the operating model, sets up your global `~/.agent/`, and wires your tools.

```
Read the .agent/ operating model at https://github.com/jlonardi/dot-agent —
start with operating-model.md, then read the presets/ folder.

Set up my system:
1. Create ~/.agent/ with the standard structure
   (rules/, docs/, purpose.md, memory.md, session-log.md)
2. Ask me about myself — what I do, how I work, my preferences
3. Adapt rules from the preset that fits best
4. Wire the tools I use (create the entry points described in the operating model)
5. Gitignore .agent/ globally

When done, tell me what was set up and how to verify it works.
```

If you use **Claude Code**, you can also install enforcement hooks that programmatically enforce the load order and self-maintenance contract. See [`tools/claude-code/`](tools/claude-code/) for hooks and setup instructions.

### Add .agent/ to a project

Once the system is installed, use this to add persistent memory to any project:

```
Read the .agent/ operating model at https://github.com/jlonardi/dot-agent —
start with operating-model.md, then read the presets/ folder.

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

For non-code / knowledge projects, replace the project exploration step:

```
Read the .agent/ operating model at https://github.com/jlonardi/dot-agent —
start with operating-model.md, then read the presets/ folder.

Now look at this workspace/domain:
- Read existing notes/docs/folders and any current agent configs
- Infer the topic, goals, constraints, and current state

Tell me:
1. What you think this workspace/domain is
2. Which preset fits best (or if none fit)
3. What you'd put in .agent/

I'll confirm, correct, and fill in what you can't infer. Then create .agent/.
```

### Update existing .agent/

When the operating model evolves, update your project's rules to match:

```
Read the latest .agent/ operating model at https://github.com/jlonardi/dot-agent —
start with operating-model.md, then read the presets/ folder.

Now read my current .agent/rules/ and compare against the operating model.
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

## The knowledge tree

`.agent/` directories can nest. Each node is both a hub for what's below it and a spoke to what's above it — a tree where context flows down and knowledge accumulates up.

```
~/.agent/                              # Root — documents the person
├── memory.md, rules/, docs/

~/projects/app/.agent/                 # Branch — documents this project
├── purpose.md, memory.md, docs/

~/projects/platform/.agent/            # Branch — documents the platform
└── packages/auth/.agent/              # Leaf — documents this package
```

The root documents the operator — preferences, working patterns, cross-project decisions. Branches document codebases. Leaves document specific areas. Agents observe how you work at every level and record patterns in the appropriate node.

Wire a tool to the root (Claude Code via `~/.claude/CLAUDE.md`) and it works across projects — it knows how they relate and how you think. Wire a tool only to a leaf (Cursor via `.cursorrules`) and it focuses deeply without distraction. Root agents coordinate. Leaf agents specialize.

The tree grows as needed. Start with one node. Add a root when you work on a second project. The topology is yours — solo dev with many repos, monorepo with package nodes, or a single project with no root at all.

See [operating-model.md](operating-model.md) for the full pattern, observation, setup, and team considerations.

## How it compares

| | AGENTS.md | Tool-specific files | .agent/ |
|---|---|---|---|
| Agent reads context | Yes | Yes | Yes |
| Agent writes back | No | No | **Yes** |
| Survives tool switch | Partially | No | **Yes** |
| Memory across sessions | No | No | **Yes** |

Use `AGENTS.md` for shared team instructions. Use `.agent/` for personal persistent context.

Read **[operating-model.md](operating-model.md)** for the full operating model — philosophy, directory structure, self-maintenance contract, tool wiring, and design decisions.

## License

MIT
