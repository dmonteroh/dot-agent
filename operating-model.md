# The `.agent/` operating model

> **Version 6.1 (2026-07-27).** Fork lineage: `dmonteroh/dot-agent`; upstream V1–V5: `jlonardi/dot-agent`

You explain your project once in a conversation. The agent writes it down. From that point on, any agent — Cursor, Claude Code, Copilot, whatever — picks up where the last one left off. You never have that conversation again.

---

## The idea

One directory. Markdown files. The agent reads them at the start of every session and writes to them at the end.

```
Session 1:  You explain the project → agent writes purpose.md, memory.md, memory/
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
│   ├── rules/              # contract.md (adapted from a preset) + learned.md + quality-bar.md (loads on demand)
│   ├── purpose.md
│   ├── memory.md           # Index: one line per file in memory/
│   ├── memory/             # One durable fact per file
│   ├── session-log.md
│   ├── docs/
│   ├── archive/            # Groomed history — archived log entries, retired facts
│   ├── scripts/            # status.sh (the load-path check) + log.sh,
│   │                       # memory.sh, docs.sh — the typed writers
│   └── skills/             # Optional — installed skill payloads; tools
│                           # read them via symlink (.claude/skills → here)
```

### File purposes

| File | What it is | Who writes it |
|------|------------|---------------|
| `rules/contract.md` | How the agent should behave: load order, self-maintenance contract, verification, autonomy. Adapted from a preset during bootstrap; the manifest's `preset` field records which one. | Agent (from preset, with your input) |
| `rules/learned.md` | Behavioral rules accumulated from session retros. Imperative, durable, agent-discovered. | Agent (from retro process) |
| `rules/quality-bar.md` | The verifier's rubric: judgement criteria, split from the preset's Quality bar section at bootstrap. Loads on demand, not every session — see [Subagents and parallel sessions](#subagents-and-parallel-sessions). | Agent (from preset, at bootstrap) |
| `purpose.md` | Why this project exists, who it's for, key constraints. Where to change what. | Agent (from conversation with you) |
| `memory.md` | Index of durable facts: one line per file in `memory/`, no facts inline. | Agent (when a fact file is added, superseded, or removed) |
| `memory/*.md` | One durable fact per file — a decision, preference, or constraint, not a running summary. | Agent (when durable facts change) |
| `session-log.md` | Meeting notes. One index entry per session; format in the file's header contract. | Agent (mandatory, every session) |
| `docs/*.md` | Architecture, features, data flows — cites the code/test path that pins each behavior rather than paraphrasing it; a path is checkable, prose isn't. Expensive-to-infer context the agent produces from scanning the codebase. An area that outgrows one file splits into `docs/<area>/` sub-docs, routed from the same `architecture.md` table. | Agent (from codebase scan + your input) |

The distinction between rules and memory: **rules tell the agent how to behave. Memory tells the agent what to know.** Rules are imperative ("always re-read files after editing"). Memory is declarative ("project uses PostgreSQL, user prefers simple solutions").

Between the state files: if something is true right now, it belongs in a `memory/` fact file, indexed from `memory.md`. If it happened today, it goes in `session-log.md`. If it's stable knowledge about how the system works, it goes in `docs/`.

### File header contracts

Every canonical file opens with a short comment that is its own format contract, written at bootstrap. The rules for writing a file sit at the top of the file itself: in context at the exact moment of writing, for every tool, including ones that never read the preset.

`session-log.md`:

```markdown
# Session log
<!-- One entry per session, newest last.
Format: - [YYYY-MM-DD] (tool) <task, area, outcome — ≤25 words>. verify: pass|fail|n/a.
Append the model to the tag when the harness states one — (claude/sonnet) —
never guess it. No file lists, SHAs, test counts, reviewer verdicts, or
narrative. Preferred writer: .agent/scripts/log.sh (stamps date, enforces
the ceiling). -->
```

`memory.md` — the index, not a fact store:

```markdown
# Memory
<!-- Index only, one line per fact file, newest last; reorder by
relevance only when grooming.
Format: - [Title](memory/slug.md) — hook. No prose, no facts inline: a
fact that lives only as a line here and not as its own file under
memory/ is not recorded. Delete the line when its file is deleted.
Preferred writer: .agent/scripts/memory.sh new (scaffolds the fact file
and its index line together). -->
```

`memory/<slug>.md` — one fact file:

```markdown
---
date: YYYY-MM-DD
scope: <project | package | root>
---
<!-- One durable fact per file: one decision, one preference, one
constraint — non-obvious operating facts. If two halves of this file
would be superseded at different times, they are two files. Supersede in
place: rewrite the fact and the date, keep the filename; no dated
narratives, no command output, no history. As small as the fact allows;
expansive detail goes to docs/ with a pointer fact here. -->
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
  version: "6.1"
  preset: software-development
  mode: track-shared        # ignore-all | track-shared | track-all
  children: []              # repo-relative paths to child .agent/ nodes
---
```

`version` is always a quoted string. Bare YAML `6.1` parses as a float, and once there's a tenth minor, `6.10` and `6.1` become ambiguous as numbers.

**Never remove or rewrite the `dot-agent` frontmatter on `purpose.md`; update passes may change only `version`.** The comment inside the block restates the constraint at the point of writing (the header-contract pattern applied to the manifest), and `scripts/status.sh` prints a `REPAIR:` flag when it is missing. This replaces the V5-era `<!-- Source: URL | Version: N -->` comment convention, which survived only as long as an updating agent deemed it important.

### The self-maintenance contract

This is the core of the system. The agent writes context back as part of finishing work: a session-log entry every session, a `memory/` fact file plus its `memory.md` index line when durable facts changed, `docs/` when architecture, dependencies, or practices changed. The next session reads what was written.

The binding rules (what to update, when a file may be left untouched, and the exact entry formats with good/bad examples) live in one place: the preset's **Continuity contract**, plus each file's own [header contract](#file-header-contracts). The operating model does not restate them. One rule, one home: the operating model describes the mechanism and files, presets carry the only copy of behavioral rules, entry points carry only wiring.

Auditing is part of the same contract, not a separate step: while loading context, the agent notices stale facts, outdated docs, and redundancy against what it sees in the codebase, and fixes them as part of the current session. The goal is that `.agent/` stays accurate, not just populated.

### Behavioral enforcement

The self-maintenance contract covers one phase: completion. A well-run session has more phases, and each is a trust contract.

#### The trust contract

Agents follow these on trust. That is the system's primary compliance story, and how the reference deployments run.

| Phase | Trust contract | The rules live in |
|-------|---------------|-------------------|
| **Bootstrap** | Load context before working | The entry point's numbered steps |
| **Pre-work** | Load project context before editing project files | Preset: Context loading |
| **Correctness** | Verify before claiming | Preset: Verification contract, judged against the Quality bar rubric |
| **Completion** | Update `.agent/` before finishing | Preset: Continuity contract + file header contracts |
| **Retro** | Distill durable behavioral rules | Preset: Self-learning |

The operating model names the phases; the preset carries each phase's rules. Optional tool-specific packaging for the rare procedures exists; see the [appendix](#appendix-optional-tooling).

#### Self-learning

The retro phase produces behavioral rules, `rules/learned.md` stores them, the next bootstrap loads them alongside the other rules: session produces experience, retro distills rules, next session operates under improved rules.

- `rules/learned.md` exists at **every level of the knowledge tree**: project nodes learn project-specific rules, the root learns cross-project rules.
- Distinct from human-authored rules (the preset): human rules define the framework, learned rules capture what the agent discovered working within it.
- Versioned via git, so bad rules can be reverted; in `track-shared` mode they pass PR review before binding anyone else's sessions (see [Tracking modes](#tracking-modes)).
- The entry format, curation law, and routing rule (behavioral rules stay here; area gotchas go to their area doc) live in the file's own header and the preset's **Self-learning** section.
- Unlike `memory.md`, `learned.md` stays a single file: it is the artifact that passes PR review in `track-shared`, and a rule set reviewed as one diff is reviewable in a way that many small files are not.

### The load order

A session loads context before doing anything else. The load order is executable, not prose: it is the numbered steps of the [canonical entry point](#the-canonical-entry-point) — status check, learned rules, preset, purpose, memory, routed docs. How far to scale the reads for a given task is the preset's **Context loading** section.

### Tracking modes

How much of `.agent/` enters git is a per-node choice, made once at bootstrap and recorded in the manifest (`mode`):

| Mode | Git behavior | When |
|---|---|---|
| `ignore-all` | `.agent/` fully ignored, including `memory.md` and `memory/` (`.gitignore` or `.git/info/exclude`) | Public repos; teams where the tree is personal |
| `track-shared` | Track `purpose.md`, `rules/` (incl. `learned.md`), `docs/`; ignore `memory.md`, `memory/`, `session-log.md`, `archive/`, everything else | Multi-dev teams sharing knowledge, keeping personal state private |
| `track-all` | Everything committed, including `memory.md` and `memory/` | Solo private repos: full history, free backup |

The `track-shared` gitignore the bootstrap writes:

```gitignore
.agent/*
!.agent/purpose.md
!.agent/rules/
!.agent/docs/
```

This is an allowlist: `.agent/*` ignores everything, and only the negated lines are un-ignored. `memory/` needs no negation of its own — a directory nobody negates is ignored by default, the same way `memory.md` already is. The design fails safe: a new file or directory stays private until someone explicitly tracks it.

In `track-shared`, a PR that touches `learned.md` gets human review: every rule the agent taught itself passes an accept/edit/reject gate before it binds anyone else's sessions.

### Native tool memory

`.agent/` is the sole durable memory. Disable tool-native memory via the tool's *setting*, not via instructions. Four reasons, all architectural: `~` is ephemeral in devcontainers, so home-directory memory dies with the container; repo knowledge has to travel through git with the repo, not sit beside it in a tool's private store; solo projects still want their memory versioned; and agents should not write outside the project directory, whatever the tool's default. Claude Code: `"autoMemoryEnabled": false` in `.claude/settings.json`, committed in `track-shared`/`track-all` modes so it holds for every developer.

This is a blast-radius stance, not a claim that native memory is unreliable. The harvest step is a repair path, not a routine one: if a node reaches retro with a tool-collected silo — because the setting wasn't applied to that node, or another tool populated one of its own — fold what's there into `.agent/` and delete the silo. A node with the setting applied has no silo to harvest.

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
5. **You confirm and correct**: fill in what the agent can't know (purpose, team context, preferences), and choose the tracking mode (`ignore-all`, `track-shared`, or `track-all`)
6. **Agent runs `scripts/node.sh init --preset <name> --mode <mode>`**: creates the skeleton, stamps the manifest, writes the matching gitignore entries (see [Tracking modes](#tracking-modes)), copies `status.sh`, `log.sh`, `memory.sh`, and `docs.sh`, and writes each canonical file with its header contract (see [File header contracts](#file-header-contracts))
7. **Agent adapts the preset** that `node.sh` copied into `rules/contract.md`: keep `## Kernel` intact, fill `## Project guardrails` with **exact commands** per the section's own template comment; split the `## Quality bar` section out into `rules/quality-bar.md` per its own comment
8. **Agent wires your tools**: writes the canonical entry-point template (see [Wiring your tools](#wiring-your-tools)) into each tool's filename, filling the placeholders: project line, doc routing. All entry points stay identical. When wiring Claude Code, also disable native memory: `"autoMemoryEnabled": false` in `.claude/settings.json`

**For empty projects:** step 3 finds nothing, so step 5 becomes a conversation instead of confirmation.

**For migration:** the agent also reads existing `.cursor/`, `AGENTS.md`, etc. and incorporates them into `.agent/`.

### Updating existing nodes

The operating model evolves. Existing `.agent/` setups don't automatically update. When new concepts are added (like observation, or a restructured tree), tell the agent "update this node to match the operating model." Run `scripts/node.sh update`: it reads the `dot-agent` frontmatter on `purpose.md`, compares `version` against the script's target by version-sort (`sort -V` semantics), backs up any node whose memory is untracked (every mode but `track-all`) before touching it, refreshes `status.sh`, `log.sh`, `memory.sh`, and `docs.sh` from the source repo, applies the mechanical migrations for the version gap (e.g. the memory-split baseline: `memory/` created, `memory.md`'s prior body moved verbatim to `memory/legacy.md`, a fresh index written), and bumps `version` — nothing else in the frontmatter changes. A node whose version already matches or exceeds the script's target is left untouched. A node missing its manifest entirely (bootstrapped pre-V6, or the stamp was lost) is not something the script restores mechanically: read `CHANGELOG.md`, the pre-V6 migration checklist, and update the node by hand.

After the script runs, the agent reconciles what mechanics can't: splitting `memory/legacy.md` into fact files (flagged by `status.sh`'s `GROOM:` line), adding new rules, updating terminology, preserving project-specific content.

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

The template is a file, not prose: [`templates/entry-point.md`](templates/entry-point.md) — one canonical copy in the source repo. At bootstrap, copy it into each tool's filename and fill the `<…>` placeholders (project line, doc routing); its own header comment carries the copying instructions, the header-contract pattern applied to the template itself.

Template mechanics: a root node wired through a user-level file (`~/.claude/CLAUDE.md`) writes every path absolute — `bash ~/.agent/scripts/status.sh ~`, `~/.agent/rules/…` — because the session's working directory is the project, not `~`, and the relative paths would resolve against the project's node or nothing. The `~` argument matters: status.sh checks the node it is handed (default `.`), not the one it lives in. The status check runs first because step-skipping concentrates at the tail of numbered lists. Step 3 reads the full contract, every session, for every model — there is no floor to opt up from and no list to keep current. The Kernel that opens `contract.md` keeps a job of its own: a priority-ordering device, the rules that matter most stated first, and the section update-propagation diffs against when a node's shared slots move. When a new tool arrives, put the same template in its filename and add it to the mirror set.

### Subagents and parallel sessions

**Subagents.** When an orchestrator dispatches workers, the exception is write authority, not reads: workers read context like any session (skipping only the status check; flags are the orchestrator's to handle) and never write `.agent/` unless explicitly assigned. Workers report continuity facts back to the orchestrator, which is the single session-log writer. Grooming is the standing example of explicit assignment: a session may hand its `GROOM:` flags to one worker whose write scope is the flagged files, so a session bootstrapped for a large task doesn't spend its own context on housekeeping. The scripts and the groom skill make the procedure mechanical enough that a small, cheap model handles it; the dispatching session re-runs `status.sh` afterward — the cleared flag is the artifact, not the worker's claim. `REPAIR:` flags are not delegable: repair is a conversation, not a job to hand off. An orchestrator may also dispatch a verifier armed with `.agent/rules/quality-bar.md`: it reads context plus the rubric, judges the result against it, and reports — writing nothing, the same write ban as any other worker. `workflows/` and `agents/` directories hold role prompts and process definitions; they never load by default. Directories the node's files don't reference (`others/`, `tmp/`, installed skill payloads under `skills/`) are outside the model: never loaded by the load order, never groomed, never negated by `track-shared`'s allowlist (`track-all`, which commits everything, is the exception).

**Parallel sessions.** If independent sessions touch `.agent/` at the same time: append to `session-log.md` first (it is append-only by timestamp). The memory split makes the rest simpler than one shared file: two sessions writing different facts write different files under `memory/` and never collide. `CONFLICT` marking narrows to the case where two sessions write the *same* fact file (or both edit the same `memory.md` index line) in the same window — keep both statements, tag them `CONFLICT`, and resolve in the next human-guided pass. Never silently overwrite.

---

## The knowledge tree

A single `.agent/` gives memory within one project, but nodes can nest. Each is a hub for what's below and a spoke to what's above: a tree where context flows down and knowledge accumulates up.

```
~/.agent/                              # Root — documents the person
├── memory.md                          # Index: cross-project state, preferences, how you work
├── memory/                            # One fact per file
├── session-log.md                     # Cross-project history
├── docs/                              # Your principles, tools, patterns
└── rules/                             # Global behavior rules

~/projects/app/.agent/                 # Branch — documents this project
├── purpose.md, memory.md, memory/, docs/

~/projects/platform/.agent/            # Branch — documents the platform
├── purpose.md, memory.md, memory/, docs/
│
└── packages/auth/.agent/              # Leaf — documents this package
    ├── purpose.md, memory.md, memory/, docs/
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

A second kind of knowledge doesn't come from code; it comes from watching how the operator works. When you correct an agent, express a preference, or reveal a working pattern, that's a signal: agents record it as a fact file in the appropriate node's `memory/`, indexed from `memory.md`. Not every interaction, but patterns and clear preferences; the recording rule (trigger or confidence tag) is the preset's Continuity contract.

Scope follows the tree: the root learns "prefers simple solutions over configurable ones" and carries it everywhere; a project node learns "always writes tests before implementation here" and keeps it scoped. This builds across sessions and tools — the tree remembers what conversations forget.

### What this enables

An agent wired to the root works across projects in one session: it can rename something in one repo and update references in another. An agent wired only to a leaf works deeply on one area without distraction. The asymmetry emerges from the wiring, not configuration: root agents coordinate, leaf agents specialize.

### How to set it up

The root goes wherever makes sense for your workflow, typically your home directory — bootstrap it with the README's root-node prompt (`node.sh init` creates the skeleton). Wire your tools to read the root alongside project-level nodes. The agent reads context top-down: root first, then project, then package (if it exists). Each level adds specificity. Once any node exists, adding another is zero-cost: point the agent at a folder and say "set it up". The agent reads the codebase, creates `.agent/`, wires your tools, and adds the node to the parent manifest's `children` so the parent knows about it next time.

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
| Agent-maintained memory lives in the repo | No | No | **Yes** |
| Survives tool switch | Partially | No | **Yes** |
| Memory across sessions | No | Partially | **Yes** |
| Has a compliance mechanism | No | No | **Yes** |

`AGENTS.md` and `.agent/` are complementary: shared team instructions vs personal persistent context.

---

## Design decisions

**Why tracking modes instead of always-gitignored?** Early versions gitignored `.agent/` unconditionally; the field split three ways: `ignore-all` for public repos and personal trees, `track-shared` for teams (knowledge flows through PR review, personal state stays private), `track-all` for solo private repos.

**Why markdown?** Every agent can read it (no parser, no schema, no dependencies), and humans can edit it too.

**Why is self-maintenance mandatory?** Without it, the system is just documentation that goes stale. It works because AI agents are more reliable at "update docs before done" than humans are.

**Why presets over templates?** Presets are seeds, not rigid templates: they show what good rules look like (expected depth, format, topics), and the agent adapts them for the specific project.

**Why not `.cursor/` or `.claude/`?** Tool-specific directories create silos. `.agent/` is neutral: any tool, same context.

**Why disable tool-native memory?** Four architectural reasons, not a claim that it's unreliable: home-directory memory is ephemeral in devcontainers, repo knowledge needs to travel through git with the repo, solo projects still want memory versioned, and agents should not write outside the project directory. `.agent/` stays the sole durable store either way.

**Why does the agent write the docs, not the user?** The user explains the project in conversation; the agent converts it into documentation. The user's job is to think and direct, not to format.

**Provenance over rationalization.** Every constant in the system — grooming thresholds, ceilings, defaults — states its provenance where it lives: field data from the instances, a real incident, or an explicit chosen-default note. A number that turns out to have none is replaced with a sourced one, not defended because it ships. V6.1 replaced its own implementation-time limits this way after they flagged the field's healthiest artifacts.

**How does `.agent/` stay small, and why is the check on the load path?** Groom by thresholds, not judgment: ungroomed files are the dominant per-session token cost, and past a point they degrade recall of everything else in context. The field also demoted completion-time verification: routine end-of-task checks breed fatigue, and agent-claimed compliance can be phantom. So `scripts/status.sh` rides the load path. The entry point runs it first; it prints the recent session-log entries, checks artifacts rather than claims, and emits one `GROOM:`/`REPAIR:`/`INDEX:` line per breach plus advisory `TOOLS:` notes (nothing on pass, always exit 0); the binding instruction ("handle flags as part of this session") lives in the entry point, which also names the delegation path: `GROOM:` work may go to one subagent scoped to the flagged files (see Subagents). Thresholds (session-log over ~120 entries or ~5,000 words → archive the oldest entries; a memory fact file over ~300 body words → likely two facts, split or route detail to docs/; memory index ~100 entries → review for stale lines; learned ~60 rules → merge; an area doc over ~2,000 body words → tighten in place or split into routed `docs/<area>/` sub-docs, the check walking one sublevel) are variables at the top of the script; projects tune them. Every threshold is a review trigger, not a cap — no write is ever refused for size — and each is calibrated against the field instances, so a healthy node rarely sees a flag. There is no `--fix` scaffolding: placeholder scaffolds are phantom-compliance bait, and repair is a bootstrap-time conversation, not a sed job.

---

## Appendix: optional tooling

Optional, and unused in the reference deployments. Compliance rests on the trust contract plus the load-path status check; there is no mechanical enforcement layer. The V4/V5-era Claude Code compliance hooks were removed in V6.1 — a Stop-time file-diff check cannot tell whether durable facts changed this session, and the field demoted completion-time gates in favor of the status check; see `CHANGELOG.md` for the removal rationale.

**Claude Code settings:** [`tools/claude-code/`](tools/claude-code/) ships `settings-example.json` — `"autoMemoryEnabled": false` (see [Native tool memory](#native-tool-memory)) plus a permissions allowlist for `.agent/**` writes.

**Claude Code skills:** [`tools/skills/`](tools/skills/) packages the rare-but-detailed in-session procedures — grooming and retro — as Claude Code skills: optional, tool-specific, additive. Installed skills live in the node at `.agent/skills/`, and each tool reads them through a symlink (`.claude/skills` → `.agent/skills`): one reviewable, tool-neutral location. Bootstrap and update have no skill: they are operator ceremonies driven by the README prompts, which run with the operating model already in context. `rules/contract.md` (from the preset) keeps every binding rule; a skill only expands the *how* for a tool that reads skills (decision 5). A node with none installed works exactly the same.

**Cursor:** add the self-maintenance check to your project's save or lint pipeline, or include it in `.cursor/rules/` so the agent sees it on every interaction.

Without tooling, compliance depends on the agent following the rules, which works most of the time, but not all of the time. The trust contract carries the reference deployments.
