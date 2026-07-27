# .agent/

Persistent, self-maintaining AI context that works across tools and sessions. An adaptation from [`jlonardi/dot-agent`](https://github.com/jlonardi/dot-agent).

## The problem

Every AI coding session starts with amnesia. The agent doesn't know what your project is for, what you decided last week, or why things are the way they are. You re-explain. Every time. Switch tools and you start from zero.

## The idea

A `.agent/` directory at the project root. Any agent reads from it, any agent writes to it.

You explain the project once. The agent writes it down. Before finishing any task, the agent updates what it learned: decisions go into `memory/` as one fact file each, indexed from `memory.md`; session notes into `session-log.md`. The next session reads what the previous one wrote.

```
Session 1:  You explain → agent writes purpose.md, memory.md, memory/
Session 2:  Agent reads → works → updates memory + session log
Session 3:  Different tool → reads same .agent/ → full continuity
```

## What's inside

```
.agent/
├── rules/          # Behavior rules (adapted from a preset)
├── purpose.md      # What this project is, who it's for + the dot-agent manifest
├── memory.md       # Index of durable facts — one line per file in memory/
├── memory/         # One durable fact per file (decision, preference, constraint)
├── session-log.md  # Meeting notes (appended every session)
├── docs/           # Architecture, features, data flows
├── archive/        # Groomed history — archived session-log entries
├── scripts/        # status.sh + the typed writers (log.sh, memory.sh, docs.sh)
└── skills/         # Optional — installed skills, symlinked into tool dirs
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

1. Interview me first, one question at a time, prioritizing questions
   whose answers change what you'll write: role, active projects, how I
   work and communicate, preferences that should hold across every
   project, and the tracking mode — ignore-all, track-shared, or
   track-all (see Tracking modes in the operating model). Don't invent
   facts about me.
2. Clone the source repo. Choose the preset that matches my work, then
   from the clone run `bash scripts/node.sh init --preset <name> --mode
   <mode> ~` to create ~/.agent/, stamp its manifest, and copy the
   scripts.
3. Adapt the preset copied into rules/contract.md; keep its Kernel
   intact.
4. List any existing project nodes in the manifest's children.
5. Wire my tools at the root from the canonical entry-point template
   (Claude Code: ~/.claude/CLAUDE.md), with every path absolute
   (~/.agent/...) since sessions run from project directories, and
   disable Claude Code's native memory in .claude/settings.json.

Ask me anything you can't infer.
```

### A project node: `.agent/` documents a codebase

Run this inside the project:

```
Read the .agent/ operating model at https://github.com/dmonteroh/dot-agent,
then bootstrap .agent/ for this project.

1. Explore the project (README, configs, source, git history) and confirm
   your findings with me — including which preset fits, and what you
   could not infer — before writing anything.
2. Ask me the tracking mode once — ignore-all (.agent/ fully gitignored),
   track-shared (purpose/rules/docs shared, memory.md/memory/ and logs
   ignored), or track-all (everything committed).
3. Clone the source repo, then from the clone run `bash scripts/node.sh
   init --preset <name> --mode <mode> <this project's path>` to create
   .agent/, stamp its manifest, and write the matching gitignore
   entries.
4. Adapt the preset copied into rules/contract.md: keep its Kernel
   intact and fill Project guardrails with exact commands ("run the
   tests" is not filled in; the real test command is).
5. Wire my tools from the canonical entry-point template (CLAUDE.md,
   AGENTS.md, …), keep every entry point identical, and disable Claude
   Code's native memory in .claude/settings.json.
6. If I have a root ~/.agent/, add this node to its manifest's children.

Ask me anything you can't infer; don't guess.
```

The tracking mode in step 2 is the gitignore practice: it decides what enters git, once, at bootstrap — `node.sh init` writes it. See [Tracking modes](operating-model.md#tracking-modes) for the exact gitignore each mode writes.

### Updating an existing node

When the operating model evolves, run this inside the node's project (or at the root):

```
Read the .agent/ operating model at https://github.com/dmonteroh/dot-agent,
then update this project's existing .agent/ node to match it.

1. Clone the source repo, then from the clone run `bash scripts/node.sh
   update <this node's path>` — it reads the manifest, compares version,
   backs up the node first if its mode is ignore-all, and applies the
   mechanical migration baseline. Read its output: if it says the node
   is current, stop here. If it reports no manifest (a pre-V6 node),
   read the newest CHANGELOG.md entry as the migration checklist,
   restore the manifest by hand, then re-run the script.
2. Reconcile: apply what the operating model adds — including splitting
   `memory/legacy.md` into fact files per its GROOM flag — while
   preserving accumulated content: memory, learned rules,
   project-specific adaptations. If existing content directly conflicts,
   flag it and let me decide; never silently overwrite.
3. Refresh the entry points against the canonical template, and keep
   them identical.
4. Repeat this process for each child node listed in the manifest's
   children.
5. Report what changed, what was preserved, and anything flagged.
```

Every session opens with a status check: the entry point's first step runs `.agent/scripts/status.sh`, which prints recent session-log entries plus `GROOM:`/`REPAIR:`/`INDEX:` flags when files breach their grooming thresholds, and the agent handles the flags as part of the session. There is no completion-time gate; grooming rides the load path.

If you use **Claude Code**, optional [skills](tools/skills/) package the rare in-session procedures (grooming, retro) for on-demand loading — installed into `.agent/skills/` and read through a symlink — and [`tools/claude-code/`](tools/claude-code/) ships the settings the bootstrap copies (`autoMemoryEnabled: false`, `.agent/**` permissions). The trust contract is the compliance story, and the reference deployments run without any of it.

## The knowledge tree

`.agent/` directories can nest. Each node is both a hub for what's below it and a spoke to what's above it: a tree where context flows down and knowledge accumulates up.

```
~/.agent/                              # Root — documents the person
├── memory.md, memory/, rules/, docs/

~/projects/app/.agent/                 # Branch — documents this project
├── purpose.md, memory.md, memory/, docs/

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
| Agent-maintained memory lives in the repo | No | No | **Yes** |
| Survives tool switch | Partially | No | **Yes** |
| Memory across sessions | No | Partially | **Yes** |
| Has a compliance mechanism | No | No | **Yes** |

Use `AGENTS.md` for shared team instructions. Use `.agent/` for personal persistent context.

Read **[operating-model.md](operating-model.md)** for the full operating model: philosophy, directory structure, self-maintenance contract, tool wiring, and design decisions.

## License

MIT
