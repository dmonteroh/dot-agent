# The `.agent/` operating model

> **Version 3 — 2026-02-08**

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
│   │   └── *.md
│   ├── purpose.md          # What the project is, who it's for, constraints
│   ├── memory.md           # Current state, key decisions (updated every session)
│   ├── session-log.md      # Meeting notes (appended every session)
│   └── docs/               # (Optional) Architecture, features, data flows
│       └── *.md
```

### File purposes

| File | What it is | Who writes it |
|------|------------|---------------|
| `rules/*.md` | How the agent should behave: load order, self-maintenance contract, quality bar, autonomy. Adapted from a preset during bootstrap. | Agent (from preset, with your input) |
| `purpose.md` | Why this project exists, who it's for, key constraints. Where to change what. | Agent (from conversation with you) |
| `memory.md` | Current project state, decisions, domain knowledge. A running summary — not history. | Agent (mandatory, every session) |
| `session-log.md` | Meeting notes. What was discussed, decided, implemented. 2–5 lines per entry. | Agent (mandatory, every session) |
| `docs/*.md` | Architecture, features, data flows. Expensive-to-infer context the agent produces from scanning the codebase. | Agent (from codebase scan + your input) |

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

> Good: "Implemented user auth with JWT. Chose bcrypt for hashing (argon2 considered, rejected for deployment simplicity). Login/register endpoints added, tests passing."
>
> Bad: "Worked on authentication."

**`session-log.md` — tag entries by tool and project:**

When a root-level `.agent/` collects entries from different tools and projects, they land in the same log. Tag each entry so the log stays scannable:

> `- (Claude Code / my-app) **Added auth**: JWT with bcrypt. Argon2 rejected for deployment simplicity.`
> `- (Cursor / infra) **Fixed deploy**: k8s readiness probe was hitting wrong port.`
> `- (Codex / my-app) **Refactored API routes**: split monolithic router into per-resource modules.`

Format: `(Tool / project) **Bold summary**: details`. For project-local `.agent/` logs the project tag is optional since it's implied by the directory.

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

### Enforcing the contract

The contract works because agents follow instructions reliably. For stronger guarantees, use your tool's native enforcement mechanism.

**Claude Code** — a stop hook that blocks session end until `.agent/` is updated:

```python
# ~/.claude/hooks/self-maintenance.py (hook type: stop)
# Checks that memory.md and session-log.md were modified this session.
# Claude Code will show the error message and block until the agent complies.
```

**Cursor** — add the self-maintenance check to your project's save or lint pipeline, or include it in `.cursor/rules/` so the agent sees it on every interaction.

**Any tool without hooks** — use the verification script as a manual completion check:

```bash
./scripts/verify-agent-context.sh
# Fails if memory.md or session-log.md is missing, empty, or has no same-day entry.
# Run with --fix to add scaffolding, then replace placeholders with real content.
```

Enforcement is optional but recommended. Without it, compliance depends entirely on the agent following the rules — which works most of the time, but not all of the time.

### The load order

When an agent starts a session, it reads context before doing anything:

1. **Project entry point** (`.cursorrules`, `CLAUDE.md`, etc.) — points to `.agent/`
2. **`.agent/rules/`** — behavior rules
3. **`.agent/purpose.md`** — what the project is and why
4. **`.agent/memory.md`** — current state and decisions
5. **Last 5–10 entries of `.agent/session-log.md`** — recent meeting notes
6. **Relevant `.agent/docs/`** — area-specific documentation

Scale to the task: a typo fix needs only the entry point and the one file. A new feature needs purpose + memory + area doc.

### Always gitignored

The entire `.agent/` directory is gitignored. It's personal context — your decisions, your session history, your way of working with AI. Not team documentation. Never committed. Different team members may use different agents or none at all.

```bash
# Personal repos — add to .gitignore:
.agent/

# Team repos — add to .git/info/exclude:
.agent/
```

### Security

`.agent/` accumulates working context from every session. Treat it as potentially sensitive — write as if it could leak.

**Hard rules:**

- Never store secrets, tokens, passwords, API keys, or private keys
- Never paste terminal output containing credentials or connection strings
- Sanitize URLs: strip tokens, keys, and auth parameters before recording
- No customer data, incident specifics, or internal system names unless explicitly needed and redacted
- If you notice sensitive data in `.agent/`, remove it immediately

**Why this matters:** The `.gitignore` protects against accidental commits, but `.agent/` can still be synced by backup tools, read by other processes, or accidentally included in archives. The gitignore is a safety net, not a security boundary.

- Prefer summaries over raw dumps for confidential materials
- If sensitive details are needed, redact them and record only the minimum required context
- Periodically review `.agent/` for accumulated sensitive data — terminal pastes, debug output, and copied error messages are common sources

---

## Getting started

### The bootstrap

Use the prompt that matches your project type.

#### Bootstrap prompt (code projects)

Copy this prompt into your first message to any agent. The agent reads the operating model from GitHub, explores your project, and sets up `.agent/`.

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

I'll confirm, correct, and fill in what you can't infer. Then create .agent/
and add it to .gitignore (or .git/info/exclude for team repos).
```

#### Bootstrap prompt (non-code / knowledge projects)

```
Read the .agent/ operating model at https://github.com/jlonardi/dot-agent —
start with operating-model.md, then read the presets/ folder.

Now look at this workspace/domain:
- Read existing notes/docs/folders and any current agent configs
  (.cursorrules, CLAUDE.md, AGENTS.md, .cursor/)
- Infer the topic, goals, constraints, and current state

Tell me:
1. What you think this workspace/domain is
2. Which preset fits best (or if none fit)
3. What you'd put in .agent/

I'll confirm, correct, and fill in what you can't infer. Then create .agent/
and add it to .gitignore (or .git/info/exclude for team repos).
```

### What happens during bootstrap

1. **Agent reads this operating model** and understands the structure, contract, and philosophy
2. **Agent reads the presets** and understands what good rules look like
3. **Agent explores the project** — package.json, README, source files, git history, existing configs
4. **Agent presents its findings** — "Here's what I think this project is, here's the tech stack, here's which preset I'd start from..."
5. **You confirm and correct** — fill in what the agent can't know (purpose, team context, preferences)
6. **Agent creates `.agent/`** — purpose.md, memory.md, session-log.md, rules adapted from the chosen preset
7. **Agent leaves a source reference** in the rules file so the node can be updated later:
   ```markdown
   <!-- Source: https://github.com/jlonardi/dot-agent/operating-model.md | Version: 3 -->
   ```
8. **Agent gitignores `.agent/`** — adds it to `.gitignore` (personal repos) or `.git/info/exclude` (team repos)
9. **Agent wires your tools** — creates the entry points for whichever tools you use

**For empty projects:** step 3 finds nothing, so step 5 becomes a conversation instead of confirmation.

**For migration:** the agent also reads existing `.cursor/`, `AGENTS.md`, etc. and incorporates them into `.agent/`.

### Updating existing nodes

The operating model evolves. Existing `.agent/` setups don't automatically update. When new concepts are added (like observation, or a restructured tree), tell the agent "update this node to match the operating model." The agent reads the source reference in the rules file, fetches the current operating model, compares the version number, and reconciles — adding new rules, updating terminology, preserving project-specific content. If the versions match, the node is already current.

This works at any level. Update a root to get new cross-project rules. Update a project node to get new self-maintenance practices. The agent already understands the operating model's structure, so reconciliation is natural — it's just a diff between what exists and what the operating model now says.

**Propagation:** When a node updates itself, it should also update the child nodes it knows about (listed in its `memory.md`). An operating model change at the root that adds a new rule to the self-maintenance contract needs to reach every project node, not just the root. The agent walks the tree — updates the current node first, then each child node in turn.

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

Adding a new node becomes: point the agent at a folder and say "set it up." The agent reads the codebase, creates `.agent/`, wires it into your tools, and updates the parent node so it knows about this child next time.

This is where the system compounds. Each node the agent sets up makes the tree richer. Each session in any node adds to the accumulated knowledge. The agent's understanding of your work grows with every interaction. You never re-explain.

### Solo vs. team

For solo developers, the tree is personal — rooted on your machine, accumulating everything. For teams, each person has their own tree. The nodes are personal and gitignored — team documentation lives elsewhere (`AGENTS.md`, wiki, etc.).

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
| Can be enforced | No | No | **Yes** |
| Dependencies | None | None | None |

`AGENTS.md` and `.agent/` are complementary. Use `AGENTS.md` for shared team instructions. Use `.agent/` for personal persistent context that grows over time.

---

## Design decisions

**Why gitignored?** `.agent/` is personal context — your decisions, your session history, your way of working with AI. Not team documentation. Never committed. Different team members may use different agents or none at all. If you need shared docs, those go elsewhere.

**Why markdown?** Every agent can read it. No parser, no schema, no dependencies. Humans can read and edit it too.

**Why self-maintenance is mandatory?** Without it, the system is just documentation that goes stale. The contract turns docs into a living thing: the agent writes context as part of finishing work, the next session reads it. This works because AI agents are more reliable at "update docs before done" than humans are.

**Why presets over templates?** Presets are seeds, not rigid templates. They show what good rules look like — expected depth, format, topics covered — so the agent knows what to produce. The agent reads them, understands the pattern, and adapts for the specific project.

**Why not `.cursor/` or `.claude/`?** Tool-specific directories create silos. `.agent/` is neutral — any tool, same context.

**Why the agent writes docs from conversations, not the user?** The user explains the project in conversation — that's natural. Asking them to also write structured markdown is busywork. The agent converts conversation into documentation. The user's job is to think and direct, not to format.

**How to keep `.agent/` small over time?** Use lightweight retention: archive older `session-log.md` entries when they get long, prune stale items from `memory.md`, and move stable long-form knowledge to `docs/`. Don't over-optimize — a few hundred lines of markdown is negligible context for most LLMs, and the agent work to reorganize files often costs more tokens than just reading a longer file.
