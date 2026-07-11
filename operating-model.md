# The `.agent/` operating model

> **Version 6 (2026-07-11).** Fork lineage: `dmonteroh/dot-agent`; upstream V1–V5: `jlonardi/dot-agent`

You explain your project once in a conversation. The agent writes it down. From that point on, any agent — Cursor, Claude Code, Copilot, whatever — picks up where the last one left off. You never have that conversation again.

---

## The idea

One directory. Markdown files. The agent reads them at the start of every session and writes to them at the end.

```
Session 1:  You explain the project → agent writes purpose.md, memory.md
Session 2:  Agent reads context → works → updates memory, appends session log
Session 3:  Different tool → reads same .agent/ → full continuity
...
Session N:  Reads memory + recent log → knows what session 1 decided and why
```

Knowledge becomes **cumulative** (grows over sessions), **self-producing** (the agent writes it, not you), and **omnipresent** (any tool can read markdown in a known location).

---

## The operating model

### Directory structure

```
project-root/
├── .agent/
│   ├── rules/              # contract.md (adapted from a preset) + learned.md
│   ├── purpose.md
│   ├── memory.md
│   ├── session-log.md
│   ├── docs/
│   ├── archive/            # Groomed history — archived session-log entries
│   └── scripts/
│       └── status.sh       # Status check the entry point runs first
```

### File purposes

| File | What it is | Who writes it |
|------|------------|---------------|
| `rules/contract.md` | How the agent should behave: load order, self-maintenance contract, quality bar, autonomy. Adapted from a preset during bootstrap; the manifest's `preset` field records which one. | Agent (from preset, with your input) |
| `rules/learned.md` | Behavioral rules accumulated from session retros. Imperative, durable, agent-discovered. | Agent (from retro process) |
| `purpose.md` | Why this project exists, who it's for, key constraints. Where to change what. | Agent (from conversation with you) |
| `memory.md` | Current project state, decisions, domain knowledge. A running summary, not history. | Agent (when durable facts change) |
| `session-log.md` | Meeting notes. One index entry per session; format in the file's header contract. | Agent (mandatory, every session) |
| `docs/*.md` | Architecture, features, data flows. Expensive-to-infer context the agent produces from scanning the codebase. | Agent (from codebase scan + your input) |

The distinction between rules and memory: **rules tell the agent how to behave. Memory tells the agent what to know.** Rules are imperative ("always re-read files after editing"). Memory is declarative ("project uses PostgreSQL, user prefers simple solutions").

Between the state files: if something is true right now, it belongs in `memory.md`. If it happened today, it goes in `session-log.md`. If it's stable knowledge about how the system works, it goes in `docs/`.

### File header contracts

Every canonical file opens with a short comment that is its own format contract, written at bootstrap. The rules for writing a file sit at the top of the file itself: in context at the exact moment of writing, for every tool, including ones that never read the preset.

`session-log.md`:

```markdown
# Session log
<!-- One entry per session, newest last:
- [YYYY-MM-DD] (tool) <task, area, outcome — ≤25 words>. verify: pass|fail|n/a.
Append the model to the tag when the harness states one — (claude/sonnet) —
never guess it. No file lists, SHAs, test counts, reviewer verdicts, or
narrative. -->
```

`memory.md`:

```markdown
# Memory
<!-- Durable current state only: decisions, terminology, preferences, active
blockers, non-obvious operating facts. Rewrite in place; supersede, don't
append. No dated narratives, no command output. Target ≤800 words. -->
```

`rules/learned.md`, whose header is the curation law itself:

```markdown
# Learned rules

Binding rules distilled from operator corrections and failed verifications
on this project. Append new rules; when updating you may merge or compress
entries, but never drop operational content. Keep each entry to roughly 40
words: imperative rule first, cause/trigger only where it adds information.
Write the rule, not the story — no incident retelling or justification
narrative; merge near-duplicates instead of appending; move domain detail
beyond ~40 words into the matching `.agent/docs/` file and keep a pointer
here (authoring rules: `contract.md`, Self-learning). Behavioral rules stay
here; area gotchas go to the matching `.agent/docs/` file under `## Gotchas`.

<!-- Format: - [YYYY-MM-DD] <imperative rule>. Trigger: <cause, optional>. -->
```

### The node manifest

Every node carries its identity as YAML frontmatter on `purpose.md`, the least-rewritten file in the node:

```yaml
---
# Do not remove or rewrite this block; update passes may change only `version`.
dot-agent:
  source: https://github.com/dmonteroh/dot-agent
  version: 6
  preset: software-development
  mode: track-shared        # ignore-all | track-shared | track-all
  children: []              # repo-relative paths to child .agent/ nodes
---
```

**Never remove or rewrite the `dot-agent` frontmatter on `purpose.md`; update passes may change only `version`.** The comment inside the block restates the constraint at the point of writing (the header-contract pattern applied to the manifest), and `scripts/status.sh` prints a `REPAIR:` flag when it is missing. This replaces the V5-era `<!-- Source: URL | Version: N -->` comment convention, which survived only as long as an updating agent deemed it important.

### The self-maintenance contract

This is the core of the system. The agent writes context back as part of finishing work: a session-log entry every session, `memory.md` when durable facts changed, `docs/` when architecture, dependencies, or practices changed. The next session reads what was written.

The binding rules (what to update, when a file may be left untouched, and the exact entry formats with good/bad examples) live in one place: the preset's **Continuity contract**, plus each file's own [header contract](#file-header-contracts). The operating model deliberately does not restate them. One rule, one home: the operating model describes the mechanism and files, presets carry the only copy of behavioral rules, entry points carry only wiring.

Auditing is part of the same contract, not a separate step: while loading context, the agent notices stale facts, outdated docs, and redundancy against what it sees in the codebase, and fixes them as part of the current session. The goal is that `.agent/` stays accurate, not just populated.

### Behavioral enforcement

The self-maintenance contract covers one phase: completion. A well-run session has more phases, and each is a trust contract.

#### The trust contract

Agents follow these on trust. That is the system's primary compliance story, and how the reference deployments run.

| Phase | Trust contract | The rules live in |
|-------|---------------|-------------------|
| **Bootstrap** | Load context before working | The entry point's numbered steps |
| **Pre-work** | Load project context before editing project files | Preset: Context loading |
| **Correctness** | Verify before claiming | Preset: Verification contract |
| **Completion** | Update `.agent/` before finishing | Preset: Continuity contract + file header contracts |
| **Retro** | Distill durable behavioral rules | Preset: Self-learning |

The operating model names the phases; the preset carries each phase's rules. Optional tooling that adds a mechanical compliance check on top exists for some tools; see the [appendix](#appendix-compliance-tooling).

#### Self-learning

The retro phase produces behavioral rules, `rules/learned.md` stores them, the next bootstrap loads them alongside the other rules: session produces experience, retro distills rules, next session operates under improved rules.

- `rules/learned.md` exists at **every level of the knowledge tree**: project nodes learn project-specific rules, the root learns cross-project rules.
- Distinct from human-authored rules (the preset): human rules define the framework, learned rules capture what the agent discovered working within it.
- Versioned via git, so bad rules can be reverted; in `track-shared` mode they pass PR review before binding anyone else's sessions (see [Tracking modes](#tracking-modes)).
- The entry format, curation law, and routing rule (behavioral rules stay here; area gotchas go to their area doc) live in the file's own header and the preset's **Self-learning** section.

### The load order

A session loads context before doing anything else. The load order is executable, not prose: it is the numbered steps of the [canonical entry point](#the-canonical-entry-point) — status check, learned rules, preset, purpose, memory, routed docs. How far to scale the reads for a given task is the preset's **Context loading** section.

### Tracking modes

How much of `.agent/` enters git is a per-node choice, made once at bootstrap and recorded in the manifest (`mode`):

| Mode | Git behavior | When |
|---|---|---|
| `ignore-all` | `.agent/` fully ignored (`.gitignore` or `.git/info/exclude`) | Public repos; teams where the tree is personal |
| `track-shared` | Track `purpose.md`, `rules/` (incl. `learned.md`), `docs/`; ignore `memory.md`, `session-log.md`, `archive/`, everything else | Multi-dev teams sharing knowledge, keeping personal state private |
| `track-all` | Everything committed | Solo private repos: full history, free backup |

The `track-shared` gitignore the bootstrap writes:

```gitignore
.agent/*
!.agent/purpose.md
!.agent/rules/
!.agent/docs/
```

In `track-shared`, a PR that touches `learned.md` gets human review: every rule the agent taught itself passes an accept/edit/reject gate before it binds anyone else's sessions.

### Native tool memory

`.agent/` is the sole durable memory. Disable tool-native memory via the tool's *setting*, not via instructions: prose overrides of built-in memory features are unreliable. Claude Code: `"autoMemoryEnabled": false` in `.claude/settings.json`, committed in `track-shared`/`track-all` modes so it holds for every developer. During retro, harvest anything a tool auto-collected into `.agent/` and delete the silo.

### Security

`.agent/` accumulates working context from every session. Treat it as potentially sensitive: write as if it could leak.

**The rule:** Never write into `.agent/` anything that is not already in the repo or is environment-sensitive: real secrets, production tokens, customer or personal data, unredacted incident details. Dev-only values already hardcoded in the repo may be cached; that's a feature. In `track-shared`/`track-all` modes, tracked files are published to everyone with repo access; review them like code.

- Sanitize URLs: strip tokens, keys, and auth parameters before recording
- Prefer summaries over raw dumps for confidential materials; redact to the minimum required context
- If you notice sensitive data in `.agent/`, remove it immediately
- Terminal pastes, debug output, and copied error messages are common sources; review periodically

Even in `ignore-all` mode the gitignore is a safety net, not a security boundary: `.agent/` can still be synced by backup tools, read by other processes, or included in archives.

---

## Getting started

### The bootstrap

The [README](README.md) ships three prompts (root-node bootstrap, project-node bootstrap, node update); a human pastes one into any agent, and the agent reads this operating model to understand what to do.

### What happens during bootstrap

1. **Agent reads this operating model** and understands the structure, contract, and philosophy
2. **Agent reads the presets** and understands what good rules look like
3. **Agent explores the project**: package.json, README, source files, git history, existing configs
4. **Agent presents its findings**: what the project is, the tech stack, which preset it would start from
5. **You confirm and correct**: fill in what the agent can't know (purpose, team context, preferences)
6. **Agent creates `.agent/`**: purpose.md, memory.md, session-log.md, the chosen preset adapted into `rules/contract.md`, and `scripts/status.sh` copied from the source repo; each canonical file opens with its header contract (see [File header contracts](#file-header-contracts)). Keep the preset's `## Kernel` intact, and fill `## Project guardrails` with **exact commands** per the section's own template comment.
7. **Agent asks the tracking mode once** (`ignore-all`, `track-shared`, or `track-all`) and writes the matching gitignore entries (see [Tracking modes](#tracking-modes))
8. **Agent stamps the manifest**: `dot-agent` frontmatter on `purpose.md` (source, version, preset, mode, children) so the node can be identified and updated later
9. **Agent wires your tools**: writes the canonical entry-point template (see [Wiring your tools](#wiring-your-tools)) into each tool's filename, filling the placeholders: project line, strong-model list, doc routing. All entry points stay identical. When wiring Claude Code, also disable native memory: `"autoMemoryEnabled": false` in `.claude/settings.json`

**For empty projects:** step 3 finds nothing, so step 5 becomes a conversation instead of confirmation.

**For migration:** the agent also reads existing `.cursor/`, `AGENTS.md`, etc. and incorporates them into `.agent/`.

### Updating existing nodes

The operating model evolves. Existing `.agent/` setups don't automatically update. When new concepts are added (like observation, or a restructured tree), tell the agent "update this node to match the operating model." The agent reads the `dot-agent` frontmatter on `purpose.md`, fetches the current operating model from `source`, compares `version`, and reconciles: adding new rules, updating terminology, preserving project-specific content. If the versions match, the node is already current.

An update pass changes only `version` in the manifest, never the frontmatter itself. If the node is not tracked in git (`ignore-all`), copy `.agent/` aside first: an update rewrites accumulated context, and untracked context has no undo. A node missing its manifest (bootstrapped pre-V6, or the stamp was lost) gets it restored as part of the update. The pass also refreshes the entry point's strong-model list; a stale list degrades safely, since a model not on it reads the Kernel + guardrails floor.

This works at any level, root or project node. Reconciliation is a diff between what exists and what the operating model now says.

**Propagation:** When a node updates itself, it also updates the child nodes listed in the manifest's `children`: the agent walks the tree, current node first, then each child in turn.

**Conflict resolution during propagation:** operating model additions are always applied; existing project-specific content is preserved unless it directly contradicts the operating model. If in doubt, flag the conflict and let the operator decide rather than silently overwriting.

---

## Wiring your tools

Each AI tool gets a thin entry point: a short file the tool loads automatically; the context lives in `.agent/`. One canonical template serves every tool, and per-tool wiring is "put this template in the tool's filename":

| Tool | Entry point file |
|---|---|
| Codex, and anything AGENTS.md-aware | `AGENTS.md` |
| Claude Code | `CLAUDE.md` (project root, or `~/.claude/CLAUDE.md` for a root node) |
| Cursor | `.cursorrules` |
| Copilot | `.github/copilot-instructions.md` |

### The canonical entry point

Written at bootstrap; placeholders in `<…>` filled per project:

```markdown
# <Project> — Session Bootstrap

<One line: stack, key dirs, package managers.> Binding rules and state load
in the steps below — do not answer, plan, or edit before completing them.

Execute with tools, in order:

1. Run `bash .agent/scripts/status.sh` — prints recent session-log entries
   plus any GROOM:/REPAIR:/INDEX: flags and TOOLS: notes; handle flags as
   part of this session, treat TOOLS: notes as advisory.
2. Read `.agent/rules/learned.md` — accumulated corrections; binding.
3. Read the `## Kernel` and `## Project guardrails` sections of
   `.agent/rules/contract.md` — binding. If you are one of: <Opus, Sonnet,
   GPT-5.5 — the project's strong-model list>, read the full file instead.
4. Read `.agent/purpose.md` — scope and boundaries.
5. Read `.agent/memory.md` — durable state.
6. <Routing: pick area docs via the table in `.agent/docs/architecture.md`;
   read only what the task needs.>

Exception — subagents: skip step 1 (flags are the orchestrator's to
handle); read everything else. Never edit `.agent/` unless explicitly
assigned — the orchestrator is the single session-log writer.

Keep this file and AGENTS.md identical; when editing one, mirror the other.
```

Template mechanics: the status check runs first because step-skipping concentrates at the tail of numbered lists. Step 3's default load is the safe floor (Kernel + Project guardrails); only models on the project's strong-model list opt *up* to the full preset; a model that cannot resolve the harness-stated name reads the floor. Fill the list with family substrings (`claude`, `gpt-5`), not versioned names: it stales slower, and stales floor-ward. When a new tool arrives, put the same template in its filename and add it to the mirror set.

### Subagents and parallel sessions

**Subagents.** When an orchestrator dispatches workers, the exception is write authority, not reads: workers read context like any session (skipping only the status check; flags are the orchestrator's to handle) and never write `.agent/` unless explicitly assigned. Workers report continuity facts back to the orchestrator, which is the single session-log writer. `workflows/` and `agents/` directories hold role prompts and process definitions; they never load by default. Directories the node's files don't reference (`others/`, `tmp/`, skill payloads) are outside the model: never loaded, never groomed, ignored in every tracking mode.

**Parallel sessions.** If independent sessions touch `.agent/` at the same time: append to `session-log.md` first (it is append-only by timestamp); re-open `memory.md` before writing final updates; if two summaries conflict, keep both statements marked `CONFLICT` and resolve them in the next human-guided pass. Never silently overwrite.

---

## The knowledge tree

A single `.agent/` gives memory within one project, but nodes can nest. Each is a hub for what's below and a spoke to what's above: a tree where context flows down and knowledge accumulates up.

```
~/.agent/                              # Root — documents the person
├── memory.md                          # Cross-project state, preferences, how you work
├── session-log.md                     # Cross-project history
├── docs/                              # Your principles, tools, patterns
└── rules/                             # Global behavior rules

~/projects/app/.agent/                 # Branch — documents this project
├── purpose.md, memory.md, docs/

~/projects/platform/.agent/            # Branch — documents the platform
├── purpose.md, memory.md, docs/
│
└── packages/auth/.agent/              # Leaf — documents this package
    ├── purpose.md, memory.md, docs/
```

Every node follows the same structure: purpose, memory, session-log, rules, docs. A node inherits context from its parent and adds its own specialization. The root knows everything broadly; the leaves know one thing deeply.

### What each level documents

The tree has a natural gradient: higher nodes document broader, more stable context; lower nodes narrower, more technical.

| Level | Typically documents |
|---|---|
| **Root** (`~/.agent/`) | The operator: preferences, working patterns, cross-project decisions, principles |
| **Project** (`project/.agent/`) | The codebase: architecture, domain, technology choices, project state |
| **Package / subtree** (`pkg/.agent/`) | A specific area: its API, patterns, gotchas, local decisions |

The root is special because its subject is the person, not a codebase: agents reading it learn how you think, communicate, and decide, which is what makes the same agent effective across different projects.

Continuity follows the work, not the directory the session was opened in. A session that spans projects logs to the node of the project it actually touched; if a root node exists, the root's `session-log.md` always gets an entry; it is the master log. Root-level entries add the project to the tag, `(tool / project)`, so a log fed by many tools and projects stays scannable.

### Observation

A second kind of knowledge doesn't come from code; it comes from watching how the operator works. When you correct an agent, express a preference, or reveal a working pattern, that's a signal: agents record it in the appropriate node's `memory.md`. Not every interaction, but patterns and clear preferences; the recording rule (trigger or confidence tag) is the preset's Continuity contract.

Scope follows the tree: the root learns "prefers simple solutions over configurable ones" and carries it everywhere; a project node learns "always writes tests before implementation here" and keeps it scoped. This builds across sessions and tools — the tree remembers what conversations forget.

### What this enables

An agent wired to the root works across projects in one session: it can rename something in one repo and update references in another. An agent wired only to a leaf works deeply on one area without distraction. The asymmetry emerges from the wiring, not configuration: root agents coordinate, leaf agents specialize.

### How to set it up

The root goes wherever makes sense for your workflow, typically your home directory (`mkdir -p ~/.agent/rules ~/.agent/docs`). Wire your tools to read the root alongside project-level nodes. The agent reads context top-down: root first, then project, then package (if it exists). Each level adds specificity. Once any node exists, adding another is zero-cost: point the agent at a folder and say "set it up". The agent reads the codebase, creates `.agent/`, wires your tools, and adds the node to the parent manifest's `children` so the parent knows about it next time.

### Topology is yours

The operating model prescribes the node structure (purpose, memory, session-log, rules, docs) and the contract (read at start, write at end). It does not prescribe the tree shape. Examples:

- **Solo developer, multiple repos:** root in `~/`, one node per project
- **Monorepo:** root at repo root, nodes in packages that need their own context
- **Work + personal separation:** two roots (`~/work/.agent/`, `~/personal/.agent/`), or one root with project nodes that carry their own constraints
- **Single project:** no root needed, just one `.agent/` in the project

The tree grows as needed: start with one node, add structure only when the work needs it.

### Solo vs. team

For solo developers, the tree is personal: rooted on your machine, accumulating everything. For teams, each person has their own tree, and each repo node picks a [tracking mode](#tracking-modes): `ignore-all` keeps the node personal, `track-shared` publishes purpose, rules, and docs as reviewable team knowledge while memory and logs stay private.

---

## Beyond code

The `.agent/` mechanism is domain-agnostic: the structure, contracts, and load order work the same whether you're writing code, conducting research, or tracking a complex topic.

The `presets/` folder demonstrates this with seeds for software development, academic research, and domain knowledge. What changes between domains is the **rules**: what the agent should prioritize, what quality means, what the agent must never do. The mechanism stays the same.

---

## How it compares

| | AGENTS.md | Tool-specific files | .agent/ |
|---|---|---|---|
| Agent reads context | Yes | Yes | Yes |
| Agent writes back | No | No | **Yes** |
| Survives tool switch | Partially | No | **Yes** |
| Memory across sessions | No | No | **Yes** |
| Has a compliance mechanism | No | No | **Yes** |

`AGENTS.md` and `.agent/` are complementary: shared team instructions vs personal persistent context.

---

## Design decisions

**Why tracking modes instead of always-gitignored?** Early versions gitignored `.agent/` unconditionally; the field split three ways: `ignore-all` for public repos and personal trees, `track-shared` for teams (knowledge flows through PR review, personal state stays private), `track-all` for solo private repos.

**Why markdown?** Every agent can read it (no parser, no schema, no dependencies), and humans can edit it too.

**Why is self-maintenance mandatory?** Without it, the system is just documentation that goes stale. It works because AI agents are more reliable at "update docs before done" than humans are.

**Why presets over templates?** Presets are seeds, not rigid templates: they show what good rules look like (expected depth, format, topics), and the agent adapts them for the specific project.

**Why not `.cursor/` or `.claude/`?** Tool-specific directories create silos. `.agent/` is neutral: any tool, same context.

**Why does the agent write the docs, not the user?** The user explains the project in conversation; the agent converts it into documentation. The user's job is to think and direct, not to format.

**How does `.agent/` stay small, and why is the check on the load path?** Groom by thresholds, not judgment: ungroomed files are the dominant per-session token cost, and past a point they degrade recall of everything else in context. The field also demoted completion-time verification: routine end-of-task checks breed fatigue, and agent-claimed compliance can be phantom. So `scripts/status.sh` rides the load path. The entry point runs it first; it prints the recent session-log entries, checks artifacts rather than claims, and emits one `GROOM:`/`REPAIR:`/`INDEX:` line per breach plus advisory `TOOLS:` notes (nothing on pass, always exit 0); the binding instruction ("handle flags as part of this session") lives in the entry point. Thresholds (session-log ~80 entries or ~5,000 words → archive entries older than 30 days; memory ~800 words → compact; learned ~25 rules → merge) are variables at the top of the script; projects tune them. There is no `--fix` scaffolding: placeholder scaffolds are phantom-compliance bait, and repair is a bootstrap-time conversation, not a sed job.

---

## Appendix: compliance tooling

Optional, and unused in the reference deployments; compliance there rests on the trust contract. Install these only if you want a mechanical check on top of it. The hooks are Claude-Code-only.

**Claude Code:** V5-era hooks that block the agent when contracts are violated. Ready-to-install hooks and instructions are in [`tools/claude-code/`](tools/claude-code/). Two of their checks predate V6 contracts; align them before relying on them: `self-maintenance.py` blocks until `memory.md` is updated in every discovered node, but V6 makes the memory update conditional (only if durable facts changed) and the orchestrator the single session-log writer; `correctness.py` enforces full-file re-reads, but the presets calibrate to re-reading edited regions with context.

**Cursor:** add the self-maintenance check to your project's save or lint pipeline, or include it in `.cursor/rules/` so the agent sees it on every interaction.

**`verify-agent-context.sh` (deprecated):** the V5-era manual completion check, retired from routine use now that the status check rides the load path. The file is kept only because existing instance rule files reference its path; do not wire it into new nodes.

Without tooling, compliance depends on the agent following the rules, which works most of the time, but not all of the time. The trust contract carries the reference deployments.
