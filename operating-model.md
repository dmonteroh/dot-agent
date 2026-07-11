# The `.agent/` operating model

> **Version 6 — 2026-07-11** — fork lineage (`dmonteroh/dot-agent`); upstream V1–V5: `jlonardi/dot-agent`

You explain your project once in a conversation. The agent writes it down. From that point on, any agent — Cursor, Claude Code, Copilot, whatever — picks up where the last one left off. You never have that conversation again.

---

## The problem

Every AI coding session starts with amnesia. The agent doesn't know what your project is for, what you decided last week, or why things are the way they are. You re-explain. Every time.

The standard answer is a static file — `AGENTS.md`, `.cursorrules`, `CLAUDE.md`. You write instructions, the agent reads them. Better than nothing. But the information flows one way: you write, the agent reads. When the agent discovers something, makes a decision, or finishes work — none of that is captured. Chat history disappears. You switch tools and start from zero.

You are the memory. That doesn't scale.

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
│   ├── rules/              # Behavior rules (adapted from a preset or custom)
│   │   ├── *.md            # Human-authored rules (adapted from preset)
│   │   └── learned.md      # Agent-authored behavioral rules (from retro)
│   ├── purpose.md          # What the project is, who it's for, constraints
│   ├── memory.md           # Current state, key decisions (updated every session)
│   ├── session-log.md      # Meeting notes (appended every session)
│   └── docs/               # (Optional) Architecture, features, data flows
│       └── *.md
```

### File purposes

| File | What it is | Who writes it |
|------|------------|---------------|
| `rules/*.md` (except learned) | How the agent should behave: load order, self-maintenance contract, quality bar, autonomy. Adapted from a preset during bootstrap. | Agent (from preset, with your input) |
| `rules/learned.md` | Behavioral rules accumulated from session retros. Imperative, durable, agent-discovered. | Agent (from retro process) |
| `purpose.md` | Why this project exists, who it's for, key constraints. Where to change what. | Agent (from conversation with you) |
| `memory.md` | Current project state, decisions, domain knowledge. A running summary — not history. | Agent (mandatory, every session) |
| `session-log.md` | Meeting notes. What was discussed, decided, implemented. 2–5 lines per entry. | Agent (mandatory, every session) |
| `docs/*.md` | Architecture, features, data flows. Expensive-to-infer context the agent produces from scanning the codebase. | Agent (from codebase scan + your input) |

The distinction between rules and memory: **rules tell the agent how to behave. Memory tells the agent what to know.** Rules are imperative ("always re-read files after editing"). Memory is declarative ("project uses PostgreSQL, user prefers simple solutions").

### The node manifest

Every node carries its identity as YAML frontmatter on `purpose.md` — the least-rewritten file in the node:

```yaml
---
dot-agent:
  source: https://github.com/dmonteroh/dot-agent
  version: 6
  preset: software-development
  mode: track-shared        # ignore-all | track-shared | track-all
  children: []              # repo-relative paths to child .agent/ nodes
---
```

**Never remove or rewrite the `dot-agent` frontmatter on `purpose.md`; update passes may change only `version`.** This replaces the V5-era `<!-- Source: URL | Version: N -->` comment in the rules file, which survived only as long as an updating agent deemed it important — both mature field instances lost theirs.

### The self-maintenance contract

This is the core of the system. Before marking any task complete, the agent **must**:

1. **Update `memory.md`** with new domain knowledge, decisions, or state changes
2. **Append to `session-log.md`** — what was discussed, decided, implemented
3. **Update `docs/`** when the project's technology, patterns, or dependencies change — capture project-specific practices for working with them, not just what changed. Prune or update docs for removed technologies.

This is what makes the system self-maintaining. The agent writes context as part of finishing work. The next session reads what was written. Knowledge accumulates without manual effort. Without this contract, it's just documentation that goes stale.

### What good updates look like

The contract says "update memory" — but a superficial update is worse than none, because it creates false confidence that context is being maintained.

**`memory.md` — capture decisions and state, not activity:**

> Good: "Migrated from SQLite to PostgreSQL. Connection pooling via pg-pool, migrations in `db/migrations/`. Decision: no ORM, raw SQL only."
>
> Bad: "Updated database stuff."

**`session-log.md` — capture what was discussed, decided, and why:**

> Good: "- [2026-02-10] (claude) Implemented user auth with JWT. Chose bcrypt for hashing (argon2 considered, rejected for deployment simplicity). Login/register endpoints added, tests passing."
>
> Bad: "Worked on authentication."

**`session-log.md` — date and tag every entry:**

Every entry starts with the date and the tool that wrote it. When a root-level `.agent/` collects entries from different tools and projects, they land in the same log — add the project so the log stays scannable:

> `- [2026-02-10] (claude / my-app) Added auth: JWT with bcrypt. Argon2 rejected for deployment simplicity.`
> `- [2026-02-10] (cursor / infra) Fixed deploy: k8s readiness probe was hitting wrong port.`
> `- [2026-02-10] (codex / my-app) Refactored API routes: split monolithic router into per-resource modules.`

Format: `- [YYYY-MM-DD] (tool / project) details`. Append the model to the tool tag when the harness states one — `(claude/sonnet / my-app)` — never guess it. For project-local `.agent/` logs the project tag is optional since it's implied by the directory.

**Session log routing:** When working across multiple projects in one session, write to the project you actually worked on, not the directory you were opened in. If a root node exists, its `session-log.md` always gets an entry (it's the master log). If the project you worked on has its own `.agent/`, also write to that project's `session-log.md` and update its `memory.md` with project-specific knowledge. This keeps project-local context current for tools that only see the project level.

**What goes where:**

| | `memory.md` | `session-log.md` | `docs/` |
|---|---|---|---|
| **Purpose** | Current truth | Chronological history | Stable reference |
| **Content** | Active decisions, project state, domain knowledge | What happened each session, 2–5 lines | Architecture, data flows, technology practices |
| **Lifespan** | Rewritten as state changes | Append-only, archived when long | Updated when structure changes |
| **Analogy** | A wiki page | Meeting minutes | A technical spec |

If something is true right now, it belongs in `memory.md`. If it happened today, it goes in `session-log.md`. If it's stable knowledge about how the system works, it goes in `docs/`.

### Context auditing

Accumulated context can go stale. When reading `.agent/` at session start, the agent should notice and fix:

- **Stale facts** in `memory.md` — decisions that were reversed, technologies that were replaced, states that changed
- **Outdated docs** — architecture or practices that no longer match the codebase
- **Redundancy** — the same information repeated across memory, docs, and session-log

This is not a separate step. It happens naturally during the load order: the agent reads context, notices something is wrong based on what it sees in the codebase, and corrects it as part of the current session's self-maintenance. The goal is that `.agent/` stays accurate, not just populated.

### Behavioral enforcement

The self-maintenance contract covers one phase: completion. But a well-run session has more phases than that, and agents can be held to all of them.

#### The trust contract

Each lifecycle phase is a trust contract. Agents follow these on trust — that is the system's primary compliance story, and how the reference deployments run.

| Phase | Trust contract |
|-------|---------------|
| **Bootstrap** | Load context before working |
| **Pre-work** | Load project context before editing project files |
| **Correctness** | Re-read files you edited. Run tests after changing source files. Run build after changing config. |
| **Completion** | Update session-log and memory before finishing |
| **Retro** | After substantial sessions, reflect on behavioral lessons and record durable rules |

The operating model describes WHAT should happen. Optional tooling that adds a mechanical compliance check on top exists for some tools — see the [appendix](#appendix-compliance-tooling).

#### Self-learning

Agents accumulate behavioral rules across sessions. The retro phase produces them, `rules/learned.md` stores them.

- `rules/learned.md` exists at **every level of the knowledge tree**. Project agents learn project-specific behavioral rules, root agents learn cross-project rules. Same gradient as memory and observation.
- Distinct from human-authored rules (the contract/operating rules). Human rules define the framework. Learned rules capture what the agent discovered about working effectively within it.
- Each entry: date, imperative rule, trigger (what caused the learning).
- Loaded during bootstrap alongside other rules.
- Versioned via git. Bad rules can be reverted.

The self-learning loop: session produces experience, retro distills rules, next session operates under improved rules, cycle continues. Rules should be universal (not session-specific), abstracted, and high-impact.

Format: `- [YYYY-MM-DD] <imperative rule>. Trigger: <what caused this learning>.`

Example:
```
- [2026-02-10] Always check all consuming packages when modifying shared schemas. Trigger: changed a Zod schema in a shared package, broke 3 downstream test files that used the old shape.
```

### The load order

When an agent starts a session, it reads context before doing anything:

1. **Project entry point** (`.cursorrules`, `CLAUDE.md`, etc.) — points to `.agent/`
2. **`.agent/rules/`** — behavior rules (including `learned.md` if it exists)
3. **`.agent/purpose.md`** — what the project is and why
4. **`.agent/memory.md`** — current state and decisions
5. **Last 5–10 entries of `.agent/session-log.md`** — recent meeting notes
6. **Relevant `.agent/docs/`** — area-specific documentation

Scale to the task: a typo fix needs only the entry point and the one file. A new feature needs purpose + memory + area doc.

### Tracking modes

How much of `.agent/` enters git is a per-node choice — made once at bootstrap, recorded in the manifest (`mode`):

| Mode | Git behavior | When |
|---|---|---|
| `ignore-all` | `.agent/` fully ignored (`.gitignore` or `.git/info/exclude`) | Public repos; teams where the tree is personal |
| `track-shared` | Track `purpose.md`, `rules/` (incl. `learned.md`), `docs/`; ignore `memory.md`, `session-log.md`, `archive/`, everything else | Multi-dev teams sharing knowledge, keeping personal state private |
| `track-all` | Everything committed | Solo private repos — full history, free backup |

The `track-shared` gitignore the bootstrap writes:

```gitignore
.agent/*
!.agent/purpose.md
!.agent/rules/
!.agent/docs/
```

In `track-shared`, a PR that touches `learned.md` gets human review — every rule the agent taught itself passes an accept/edit/reject gate before it binds anyone else's sessions.

### Native tool memory

`.agent/` is the sole durable memory. Disable tool-native memory via the tool's *setting*, not via instructions — prose overrides of built-in memory features are documented-unreliable. Claude Code: `"autoMemoryEnabled": false` in `.claude/settings.json` — committed in `track-shared`/`track-all` modes so it holds for every developer. During retro, harvest anything a tool auto-collected into `.agent/` and delete the silo.

### Security

`.agent/` accumulates working context from every session. Treat it as potentially sensitive — write as if it could leak.

**The rule:** Never write into `.agent/` anything that is not already in the repo or is environment-sensitive: real secrets, production tokens, customer or personal data, unredacted incident details. Dev-only values already hardcoded in the repo may be cached — that's a feature. In `track-shared`/`track-all` modes, tracked files are published to everyone with repo access; review them like code.

- Sanitize URLs: strip tokens, keys, and auth parameters before recording
- Prefer summaries over raw dumps for confidential materials; if sensitive details are needed, redact to the minimum required context
- If you notice sensitive data in `.agent/`, remove it immediately
- Terminal pastes, debug output, and copied error messages are common sources — review periodically

Even in `ignore-all` mode the gitignore is a safety net, not a security boundary: `.agent/` can still be synced by backup tools, read by other processes, or included in archives.

---

## Getting started

### The bootstrap

The [README](README.md) has a single prompt that covers install, bootstrap, and updates. A human copies it, pastes it into any agent, and the agent reads this operating model to understand what to do.

### What happens during bootstrap

1. **Agent reads this operating model** and understands the structure, contract, and philosophy
2. **Agent reads the presets** and understands what good rules look like
3. **Agent explores the project** — package.json, README, source files, git history, existing configs
4. **Agent presents its findings** — "Here's what I think this project is, here's the tech stack, here's which preset I'd start from..."
5. **You confirm and correct** — fill in what the agent can't know (purpose, team context, preferences)
6. **Agent creates `.agent/`** — purpose.md, memory.md, session-log.md, rules adapted from the chosen preset
7. **Agent asks the tracking mode once** — `ignore-all`, `track-shared`, or `track-all` — and writes the matching gitignore entries (see [Tracking modes](#tracking-modes))
8. **Agent stamps the manifest** — `dot-agent` frontmatter on `purpose.md` (source, version, preset, mode, children) so the node can be identified and updated later
9. **Agent wires your tools** — creates the entry points for whichever tools you use. When wiring Claude Code, also disable native memory: `"autoMemoryEnabled": false` in `.claude/settings.json`

**For empty projects:** step 3 finds nothing, so step 5 becomes a conversation instead of confirmation.

**For migration:** the agent also reads existing `.cursor/`, `AGENTS.md`, etc. and incorporates them into `.agent/`.

### Updating existing nodes

The operating model evolves. Existing `.agent/` setups don't automatically update. When new concepts are added (like observation, or a restructured tree), tell the agent "update this node to match the operating model." The agent reads the `dot-agent` frontmatter on `purpose.md`, fetches the current operating model from `source`, compares `version`, and reconciles — adding new rules, updating terminology, preserving project-specific content. If the versions match, the node is already current.

An update pass changes only `version` in the manifest — it never removes or rewrites the frontmatter itself. A node missing its manifest (bootstrapped pre-V6, or the stamp was lost) gets it restored as part of the update.

This works at any level. Update a root to get new cross-project rules. Update a project node to get new self-maintenance practices. The agent already understands the operating model's structure, so reconciliation is natural — it's just a diff between what exists and what the operating model now says.

**Propagation:** When a node updates itself, it should also update the child nodes it knows about (listed in the manifest's `children`). An operating model change at the root that adds a new rule to the self-maintenance contract needs to reach every project node, not just the root. The agent walks the tree — updates the current node first, then each child node in turn.

**Conflict resolution during propagation:** When reconciling a child node, the agent may encounter project-specific customizations that differ from the operating model defaults. The rule: operating model additions are always applied (new concepts, new rules), but existing project-specific content is preserved unless it directly contradicts the operating model. If in doubt, the agent should flag the conflict and let the operator decide rather than silently overwriting.

---

## Wiring your tools

Each AI tool gets a thin entry point — a short file that says "read `.agent/`". The context lives in `.agent/`, the wiring is just a pointer.

### Cursor

`.cursorrules` at project root references `.agent/`:

```markdown
For agent behaviour and quality rules, see `.agent/rules/`.

## Documentation index
- `.agent/purpose.md` – what the project is
- `.agent/memory.md` – current state and decisions
- `.agent/session-log.md` – recent history
- `.agent/docs/` – architecture and features
```

Auto-load rules via symlink:

```bash
mkdir -p .cursor/rules
ln -sf ../../.agent/rules/your-rules.md .cursor/rules/your-rules.md
```

### Claude Code

`CLAUDE.md` at project root (or `~/.claude/CLAUDE.md` globally):

```markdown
When working on a project:
1. Read `.agent/rules/`, then `.agent/purpose.md`, `.agent/memory.md`,
   and last 5–10 entries of `.agent/session-log.md`
2. Follow the rules in `.agent/rules/`
3. Update `.agent/memory.md` and `.agent/session-log.md` when done
```

### Copilot

`.github/copilot-instructions.md`:

```markdown
This project uses .agent/ for persistent context. Read .agent/rules/ for
behavior rules, .agent/purpose.md for project context, .agent/memory.md
for current state. Update memory.md and session-log.md when finishing work.
```

### Codex / AGENTS.md

`AGENTS.md` at project root:

```markdown
This project uses `.agent/` as the source of truth for agent context.

At the start of work, read:
1. `.agent/rules/`
2. `.agent/purpose.md`
3. `.agent/memory.md`
4. last 5–10 entries in `.agent/session-log.md`
5. relevant `.agent/docs/`

Before marking work complete, update `.agent/memory.md` and append
to `.agent/session-log.md`.
```

### The pattern

Any tool that reads a config file can point to `.agent/`. The wiring is always a thin entry point that says "read `.agent/`". When a new tool arrives, create its entry point following the same pattern. The agent should be able to wire new tools by understanding this pattern, not just the examples above.

### Parallel sessions and conflict handling

If multiple agents/sessions touch `.agent/` at the same time:

1. Append to `session-log.md` first (append-only by timestamp)
2. Re-open `memory.md` before writing final updates
3. If two summaries conflict, keep both statements and mark as `CONFLICT`
4. Resolve conflicts in the next human-guided pass; do not silently overwrite

---

## The knowledge tree

A single `.agent/` gives an agent memory within one project. But `.agent/` directories can nest. Each node is both a hub for what's below it and a spoke to what's above it. The result is a tree where context flows down and knowledge accumulates up.

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

The tree has a natural gradient. Higher nodes document broader, more stable context. Lower nodes document narrower, more technical context.

| Level | Typically documents |
|---|---|
| **Root** (`~/.agent/`) | The operator — preferences, working patterns, cross-project decisions, principles |
| **Project** (`project/.agent/`) | The codebase — architecture, domain, technology choices, project state |
| **Package / subtree** (`pkg/.agent/`) | A specific area — its API, patterns, gotchas, local decisions |

The root is special because its subject is the person, not a codebase. Agents reading the root learn how you think, communicate, and decide — not just what your projects contain. This is what makes the same agent effective across different projects: it knows the operator, not just the code.

### Observation

The self-maintenance contract says agents must update memory and session-log. But there's a second kind of knowledge that doesn't come from code — it comes from watching how the operator works.

When you correct an agent, express a preference, explain your reasoning, or reveal a working pattern — that's a signal. Agents should notice these signals and record them in the appropriate node's `memory.md`. Not every interaction, but patterns and clear preferences.

Every new observation should include either a concrete trigger (the quote/behavior that caused it) or a confidence tag (`high`/`medium`/`low`) when the trigger is implicit.

This applies at every level of the tree:

| Level | What agents observe |
|---|---|
| **Root** | How you think, communicate, and decide. Preferences that apply everywhere. |
| **Project** | How you work in this codebase. Project-specific conventions and judgments. |
| **Package** | How you handle this specific area. Local patterns and gotchas. |

An agent at the root learns "prefers simple solutions over configurable ones" — that carries across all projects. An agent at a project node learns "always writes tests before implementation here" — that's scoped to this codebase. Both are observation; the scope differs.

This builds across sessions and tools. Knowledge about the operator lives in the tree, not in any single conversation. The tree remembers what conversations forget.

### What this enables

**Cross-project agents.** An agent wired to the root can work across multiple projects in one session. It knows project A uses data that project B generates. It can rename something in one repo and update references in another.

**Focused agents.** An agent wired only to a leaf works deeply on one area without distraction. This is usually what you want for focused coding sessions.

**Natural asymmetry.** Root agents coordinate. Leaf agents specialize. You don't configure this — it emerges from the wiring. The root accumulates knowledge from every session with every tool. The leaves stay focused.

### How to set it up

The root goes wherever makes sense for your workflow — typically your home directory:

```bash
mkdir -p ~/.agent/rules ~/.agent/docs
```

Wire your tools to read the root alongside project-level nodes. The agent reads context top-down: root first, then project, then package (if it exists). Each level adds specificity.

Project and package nodes are created through bootstrap — point the agent at a folder and say "set it up." Once the root exists, the agent already knows the pattern and can create new nodes without a bootstrap prompt.

### Topology is yours

The operating model prescribes the node structure (purpose, memory, session-log, rules, docs) and the contract (read at start, write at end). It does not prescribe the tree shape. Examples:

- **Solo developer, multiple repos:** root in `~/`, one node per project
- **Monorepo:** root at repo root, nodes in packages that need their own context
- **Work + personal separation:** two roots (`~/work/.agent/`, `~/personal/.agent/`), or one root with project nodes that carry their own constraints
- **Single project:** no root needed — just one `.agent/` in the project

The tree grows as needed. Start with one node. Add a root when you work on a second project. Add package nodes when a subtree gets complex enough to need its own memory. Don't create structure you don't need yet.

### Zero-cost bootstrap

The bootstrap prompts in "Getting started" exist for the cold start — a fresh agent that has never seen this operating model. Once any node exists, the agent already carries the pattern.

Adding a new node becomes: point the agent at a folder and say "set it up." The agent reads the codebase, creates `.agent/`, wires it into your tools, and adds the new node to the parent manifest's `children` so the parent knows about it next time.

This is where the system compounds. Each node the agent sets up makes the tree richer. Each session in any node adds to the accumulated knowledge. The agent's understanding of your work grows with every interaction. You never re-explain.

### Solo vs. team

For solo developers, the tree is personal — rooted on your machine, accumulating everything. For teams, each person has their own tree, and each repo node picks a tracking mode: `ignore-all` keeps the node personal (team documentation lives elsewhere — `AGENTS.md`, wiki, etc.); `track-shared` publishes `purpose.md`, `rules/`, and `docs/` as shared, reviewable team knowledge while memory and logs stay private.

---

## Beyond code

The `.agent/` mechanism is domain-agnostic. The directory structure, the self-maintenance contract, and the load order work the same way whether you're writing code, conducting research, managing an organization, or tracking a complex topic.

The `presets/` folder demonstrates this: `software-development.md` is for code projects, `academic-research.md` is for evidence-based writing, `domain-knowledge.md` is for accumulating and organizing information in any field.

What changes between domains is the **rules** — what the agent should prioritize, what quality means, what the agent must never do. The mechanism stays the same.

---

## How it compares

| | AGENTS.md | Tool-specific files | .agent/ |
|---|---|---|---|
| Agent reads context | Yes | Yes | Yes |
| Agent writes back | No | No | **Yes** |
| Survives tool switch | Partially | No | **Yes** |
| Memory across sessions | No | No | **Yes** |
| Has a compliance mechanism | No | No | **Yes** |
| Dependencies | None | None | None |

`AGENTS.md` and `.agent/` are complementary. Use `AGENTS.md` for shared team instructions. Use `.agent/` for personal persistent context that grows over time.

---

## Design decisions

**Why tracking modes instead of always-gitignored?** Early versions gitignored `.agent/` unconditionally. The field split three ways: public repos and personal trees want `ignore-all`, multi-dev teams get real value from `track-shared` (accumulated knowledge flows through PR review, personal state stays private), and solo private repos from `track-all` (full history, free backup). The mode is a one-time bootstrap choice recorded in the manifest, not a per-session judgment.

**Why markdown?** Every agent can read it. No parser, no schema, no dependencies. Humans can read and edit it too.

**Why self-maintenance is mandatory?** Without it, the system is just documentation that goes stale. The contract turns docs into a living thing: the agent writes context as part of finishing work, the next session reads it. This works because AI agents are more reliable at "update docs before done" than humans are.

**Why presets over templates?** Presets are seeds, not rigid templates. They show what good rules look like — expected depth, format, topics covered — so the agent knows what to produce. The agent reads them, understands the pattern, and adapts for the specific project.

**Why not `.cursor/` or `.claude/`?** Tool-specific directories create silos. `.agent/` is neutral — any tool, same context.

**Why the agent writes docs from conversations, not the user?** The user explains the project in conversation — that's natural. Asking them to also write structured markdown is busywork. The agent converts conversation into documentation. The user's job is to think and direct, not to format.

**How to keep `.agent/` small over time?** Groom by thresholds, not judgment: when `session-log.md` exceeds ~80 entries or ~5,000 words, move entries older than 30 days to `archive/session-log-archive.md`; when `memory.md` exceeds ~800 words, compact it to durable state only; when `rules/learned.md` exceeds ~25 rules, merge near-duplicates. Move stable long-form knowledge to `docs/`. Ungroomed files are the dominant per-session token cost, and past a point they degrade recall of everything else in context.

---

## Appendix: compliance tooling

Optional, and unused in the reference deployments — compliance there rests on the trust contract. Install these only if you want a mechanical check on top of it. The hooks are Claude-Code-only.

**Claude Code** — hooks that block the agent when contracts are violated. Ready-to-install hooks are in [`tools/claude-code/`](tools/claude-code/):

```bash
# Install hooks
cp tools/claude-code/hooks/*.py ~/.claude/hooks/
# Merge tools/claude-code/settings-example.json into ~/.claude/settings.json
```

**Cursor** — add the self-maintenance check to your project's save or lint pipeline, or include it in `.cursor/rules/` so the agent sees it on every interaction.

**Any tool without hooks** — use the verification script as a manual completion check:

```bash
./scripts/verify-agent-context.sh
# Fails if memory.md or session-log.md is missing, empty, or has no same-day entry.
# Run with --fix to add scaffolding, then replace placeholders with real content.
```

Without tooling, compliance depends on the agent following the rules — which works most of the time, but not all of the time. The trust contract carries the reference deployments.
