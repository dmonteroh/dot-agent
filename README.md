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
├── purpose.md      # What this project is, who it's for + the dot-agent manifest
├── memory.md       # Current state, decisions (updated when durable facts change)
├── session-log.md  # Meeting notes (appended every session)
├── docs/           # Architecture, features, data flows
├── archive/        # Groomed history — archived session-log entries
└── scripts/        # status.sh — the status check the entry point runs first
```

The core mechanism is the **self-maintenance contract**: before finishing any task, the agent writes context back — a session-log entry every session, memory and docs when what they hold changed. This is what keeps context alive without manual effort. The binding rules live in the preset; each file's header carries its own format contract.

## Presets

Rule presets for different domains — pick one during bootstrap or let the agent adapt:

- **[Software development](presets/software-development.md)** — load order, code quality, testing, git discipline
- **[Academic research](presets/academic-research.md)** — evidence-first writing, source traceability, no unsupported claims
- **[Domain knowledge](presets/domain-knowledge.md)** — accumulating and organizing information over time

## Get started

Copy this into any capable agent:

```
Read the .agent/ operating model at https://github.com/dmonteroh/dot-agent.

Look at my current setup and do what makes sense:
- No ~/.agent/? Set up the system from scratch — ask me about myself first.
- ~/.agent/ exists but outdated? Read the dot-agent manifest on purpose.md
  and update.
- In a project without .agent/? Bootstrap it: explore the project, confirm
  your findings with me, adapt a preset (keep its Kernel intact; fill
  Project guardrails with exact commands), ask me the tracking mode once
  (ignore-all / track-shared / track-all), stamp the manifest, and wire my
  tools from the canonical entry-point template.

Ask me anything you need to know.
```

One prompt. The agent reads the operating model, figures out what state you're in, and does the right thing.

Every session opens with a status check: the entry point's first step runs `.agent/scripts/status.sh`, which prints recent session-log entries plus `GROOM:`/`REPAIR:`/`INDEX:` flags when files breach their grooming thresholds, and the agent handles the flags as part of the session. There is no completion-time gate — grooming rides the load path.

If you use **Claude Code**, optional hooks can add a mechanical compliance check for the load order and self-maintenance contract — the trust contract is the primary compliance story, and the reference deployments run without them. See [`tools/claude-code/`](tools/claude-code/).

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
