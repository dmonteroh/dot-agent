# The `.agent/` convention

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

## The convention

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

### Context auditing

Accumulated context can go stale. When reading `.agent/` at session start, the agent should notice and fix:

- **Stale facts** in `memory.md` — decisions that were reversed, technologies that were replaced, states that changed
- **Outdated docs** — architecture or practices that no longer match the codebase
- **Redundancy** — the same information repeated across memory, docs, and session-log

This is not a separate step. It happens naturally during the load order: the agent reads context, notices something is wrong based on what it sees in the codebase, and corrects it as part of the current session's self-maintenance. The goal is that `.agent/` stays accurate, not just populated.

### Manual completion check (for agents without hooks)

For workflows where the agent cannot enforce completion hooks automatically,
use a lightweight manual verification step before "done":

- `scripts/verify-agent-context.sh`
- Fails if `.agent/memory.md` or `.agent/session-log.md` is missing/empty
- Can require a same-day `session-log.md` entry

If checks fail, an agent may run `scripts/verify-agent-context.sh --fix` to add
minimal scaffolding and a clearly marked placeholder entry for today. After
autofix, the agent must replace placeholders with real session details and
rerun verification before marking work complete.

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

### Privacy and sensitive data

`.agent/` often contains raw notes and working context. Treat it as sensitive.

- Never store secrets, tokens, passwords, private keys, or full credentials
- Avoid storing sensitive PII, legal identifiers, or medical data unless necessary
- Prefer summaries over raw dumps for confidential materials
- If sensitive details are needed, redact them and record only the minimum required context

---

## Getting started

### The bootstrap

Use the prompt that matches your project type.

#### Bootstrap prompt (code projects)

Copy this prompt into your first message to any agent. The agent reads the convention from GitHub, explores your project, and sets up `.agent/`.

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

I'll confirm, correct, and fill in what you can't infer. Then create .agent/
and add it to .gitignore (or .git/info/exclude for team repos).
```

#### Bootstrap prompt (non-code / knowledge projects)

```
Read the .agent/ convention at https://github.com/jlonardi/dot-agent —
start with convention.md, then read the presets/ folder.

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

1. **Agent reads this convention** and understands the structure, contract, and philosophy
2. **Agent reads the presets** and understands what good rules look like
3. **Agent explores the project** — package.json, README, source files, git history, existing configs
4. **Agent presents its findings** — "Here's what I think this project is, here's the tech stack, here's which preset I'd start from..."
5. **You confirm and correct** — fill in what the agent can't know (purpose, team context, preferences)
6. **Agent creates `.agent/`** — purpose.md, memory.md, session-log.md, rules adapted from the chosen preset
7. **Agent gitignores `.agent/`** — adds it to `.gitignore` (personal repos) or `.git/info/exclude` (team repos)
8. **Agent wires your tools** — creates the entry points for whichever tools you use

**For empty projects:** step 3 finds nothing, so step 5 becomes a conversation instead of confirmation.

**For migration:** the agent also reads existing `.cursor/`, `AGENTS.md`, etc. and incorporates them into `.agent/`.

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

**How to keep `.agent/` small over time?** Use lightweight retention: archive older `session-log.md` entries, prune stale items from `memory.md`, and move stable long-form knowledge to `docs/`.
