# .agent/

Persistent, self-maintaining AI context that works across tools and sessions. An adaptation from `jlonardi/dot-agent`.

## The problem

Every AI coding session starts with amnesia. The agent doesn't know what your project is for, what you decided last week, or why things are the way they are. You re-explain. Every time. Switch tools and you start from zero.

## The idea

A `.agent/` directory at the project root. Any agent reads from it, any agent writes to it.

You explain the project once. The agent writes it down. Before finishing any task, the agent updates what it learned: decisions go into `memory.md`, session notes into `session-log.md`. The next session reads what the previous one wrote.

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

The core mechanism is the **self-maintenance contract**: before finishing any task, the agent writes context back (a session-log entry every session; memory and docs when what they hold changed). This is what keeps context alive without manual effort. The binding rules live in the preset; each file's header carries its own format contract.

## Presets

Rule presets for different domains. Pick one during bootstrap or let the agent adapt:

- **[Software development](presets/software-development.md)**: load order, code quality, testing, git discipline
- **[Academic research](presets/academic-research.md)**: evidence-first writing, source traceability, no unsupported claims
- **[Domain knowledge](presets/domain-knowledge.md)**: accumulating and organizing information over time

## Get started

Two prompts, one per node type. Either works standalone: a project node is self-contained; add the root when you want memory that follows you across projects.

### Your root node: `~/.agent/` documents you

Copy this into any capable agent:

```
Read the .agent/ operating model at https://github.com/dmonteroh/dot-agent,
then set up my root node at ~/.agent/. Its subject is me, not a codebase.

1. Interview me first: role, active projects, how I work and communicate,
   preferences that should hold across every project. Don't invent facts
   about me.
2. Create ~/.agent/ — purpose, memory, session-log, rules, docs, and
   scripts/status.sh copied from the source repo. Each canonical file
   opens with its header contract from the operating model.
3. Adapt the preset that matches my work into rules/; keep its Kernel
   intact.
4. Stamp the dot-agent manifest on purpose.md, listing any existing
   project nodes in children.
5. Wire my tools at the root from the canonical entry-point template
   (Claude Code: ~/.claude/CLAUDE.md) and disable Claude Code's native
   memory in .claude/settings.json.

Ask me anything you can't infer.
```

### A project node: `.agent/` documents a codebase

Run this inside the project:

```
Read the .agent/ operating model at https://github.com/dmonteroh/dot-agent,
then bootstrap .agent/ for this project.

1. Explore the project (README, configs, source, git history) and confirm
   your findings with me — including which preset fits — before writing
   anything.
2. Create .agent/ — purpose, memory, session-log, docs, and
   scripts/status.sh copied from the source repo. Each canonical file
   opens with its header contract from the operating model.
3. Adapt the chosen preset into rules/: keep its Kernel intact and fill
   Project guardrails with exact commands ("run the tests" is not filled
   in; the real test command is).
4. Ask me the tracking mode once — ignore-all (.agent/ fully gitignored),
   track-shared (purpose/rules/docs shared, memory and logs ignored), or
   track-all (everything committed) — and write the matching gitignore
   entries before anything is committed.
5. Stamp the dot-agent manifest on purpose.md (source, version, preset,
   mode, children).
6. Wire my tools from the canonical entry-point template (CLAUDE.md,
   AGENTS.md, …), keep every entry point identical, and disable Claude
   Code's native memory in .claude/settings.json.
7. If I have a root ~/.agent/, add this node to its manifest's children.

Ask me anything you can't infer; don't guess.
```

The tracking mode in step 4 is the gitignore practice: it decides what enters git, once, at bootstrap. See [Tracking modes](operating-model.md#tracking-modes) for the exact gitignore each mode writes.

### Updating an existing node

When the operating model evolves, run this inside the node's project (or at the root):

```
Read the .agent/ operating model at https://github.com/dmonteroh/dot-agent,
then update this project's existing .agent/ node to match it.

1. Read .agent/purpose.md. If it has a dot-agent manifest, compare its
   version against the operating model — if they match, stop; the node is
   current. If the manifest is missing, this is a pre-V6 node: use the
   newest CHANGELOG.md entry as the migration checklist and restore the
   manifest.
2. If .agent/ is not tracked by git, copy it aside before changing
   anything.
3. Reconcile: apply what the operating model adds; preserve accumulated
   content — memory, learned rules, project-specific adaptations. If
   existing content directly conflicts, flag it and let me decide; never
   silently overwrite.
4. Refresh the entry points against the canonical template, including the
   strong-model list, and keep them identical.
5. Update version in the manifest — change nothing else in the
   frontmatter — then update each child node listed in children the same
   way.
6. Report what changed, what was preserved, and anything flagged.
```

Every session opens with a status check: the entry point's first step runs `.agent/scripts/status.sh`, which prints recent session-log entries plus `GROOM:`/`REPAIR:`/`INDEX:` flags when files breach their grooming thresholds, and the agent handles the flags as part of the session. There is no completion-time gate; grooming rides the load path.

If you use **Claude Code**, optional hooks can add a mechanical compliance check for the load order and self-maintenance contract. The trust contract is the primary compliance story, and the reference deployments run without them. See [`tools/claude-code/`](tools/claude-code/).

## The knowledge tree

`.agent/` directories can nest. Each node is both a hub for what's below it and a spoke to what's above it: a tree where context flows down and knowledge accumulates up.

```
~/.agent/                              # Root — documents the person
├── memory.md, rules/, docs/

~/projects/app/.agent/                 # Branch — documents this project
├── purpose.md, memory.md, docs/

~/projects/platform/.agent/            # Branch — documents the platform
└── packages/auth/.agent/              # Leaf — documents this package
```

The root documents the operator: preferences, working patterns, cross-project decisions. Branches document codebases. Leaves document specific areas. Agents observe how you work at every level and record patterns in the appropriate node.

Wire a tool to the root (Claude Code via `~/.claude/CLAUDE.md`) and it works across projects; it knows how they relate and how you think. Wire a tool only to a leaf (Cursor via `.cursorrules`) and it focuses deeply without distraction. Root agents coordinate. Leaf agents specialize.

The tree grows as needed. Start with one node. Add a root when you work on a second project. The topology is yours: solo dev with many repos, monorepo with package nodes, or a single project with no root at all.

See [operating-model.md](operating-model.md) for the full pattern, observation, setup, and team considerations.

## How it compares

| | AGENTS.md | Tool-specific files | .agent/ |
|---|---|---|---|
| Agent reads context | Yes | Yes | Yes |
| Agent writes back | No | No | **Yes** |
| Survives tool switch | Partially | No | **Yes** |
| Memory across sessions | No | No | **Yes** |
| Has a compliance mechanism | No | No | **Yes** |

Use `AGENTS.md` for shared team instructions. Use `.agent/` for personal persistent context.

Read **[operating-model.md](operating-model.md)** for the full operating model: philosophy, directory structure, self-maintenance contract, tool wiring, and design decisions.

## License

MIT
