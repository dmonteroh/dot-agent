# .agent/

[![CI](https://github.com/dmonteroh/dot-agent/actions/workflows/ci.yml/badge.svg)](https://github.com/dmonteroh/dot-agent/actions/workflows/ci.yml)

Agent memory that lives in the repo: portable across LLM providers, shareable across a team, and checked so it doesn't drift. An adaptation from [`jlonardi/dot-agent`](https://github.com/jlonardi/dot-agent).

## The problem

Agent memory is per-tool and stays there. Claude Code keeps its own store, Cursor keeps another, Copilot another again. None of them read each other, so what an agent learned on Monday in one tool is unavailable on Tuesday in a different one, and a developer running two tools runs two disconnected memories.

Teams get less than that. Those stores sit on one machine, outside the repo, so what your agent learned never reaches anyone else's. The options for fixing it are roughly nothing, or adopting a platform.

Two costs follow the knowledge that does get written down. It drifts, because a rule or a doc that no longer matches the code looks exactly like one that does. And it is paid for on every session, because whatever an agent loads at the start of a task it loads again on the next one.

## The idea

A `.agent/` directory of markdown at the project root. Any agent reads it, any agent writes it, and it travels with the code through git.

**Portable across providers.** The format is files, so Claude Code, Cursor, Copilot, and Codex all read the same context through a thin entry point in each tool's own filename. The operating model's wiring matrix records what is actually verified per tool, with dates, instead of asserting it. Native tool memory is switched off where the tool has a setting for it (Claude Code's is shipped and checked, and the matrix tracks the rest), leaving one store instead of several.

**Shareable without a platform.** A tracking mode, chosen once, decides what enters git. `track-shared` publishes purpose, rules, and docs for the team to review in a pull request, while memory and session logs stay personal to each developer.

**Checked, so it drifts less.** The agent writes context back as part of finishing work. A check on the load path reads the node's files rather than the agent's claims. It finds files past their grooming thresholds, a routing table that disagrees with the docs it routes, an index out of sync with its facts, bootstrap steps left half-done, and native memory still switched on.

**Bounded at load.** What every session reads is a small fixed set: the rules and the indexes. A memory fact opens when its hook matches the task, an area doc when the routing table sends the session there, and reference material only when a doc hands out the path.

```
Monday     Claude Code finishes a task and writes what it learned to .agent/
Tuesday    Cursor reads the same .agent/ and picks up where that left off
Thursday   A teammate pulls the repo; purpose, rules, and docs came with it
```

The design takes what native tool memory gets right: an index over one fact per file, with write-back at the end of a task. It adds what a shared repository needs: review, version history, and a format no vendor owns.

It stops there on purpose. Working agreements, team methodology, and how people decide things are not `.agent/`'s to hold. The goal is a harness that stays out of their way.

## What's inside

```
.agent/
├── rules/          # Behavior rules (adapted from a preset)
├── purpose.md      # What this project is, who it's for + the dot-agent manifest
├── memory.md       # Index of durable facts — one line per file in memory/
├── memory/         # Current state or user context absent from canonical artifacts
├── session-log.md  # Meeting notes (appended every session)
├── docs/           # Architecture, features, data flows; docs/<area>/references/
│                   # holds depth that is never routed or auto-loaded
├── archive/        # Groomed history — archived log entries, retired facts
├── scripts/        # status.sh + the typed writers (log.sh, memory.sh, docs.sh)
│                   # + links.sh, the on-demand orphan/broken-link audit
│                   # + comments.sh, the diff comment gate (node vocabulary
│                   # in comments.conf, never refreshed by update)
└── skills/         # Optional — installed skills, symlinked into tool dirs
```

Two contracts hold it together. The self-maintenance contract covers what gets written: before finishing any task, the agent writes a session-log entry, qualifying current state to memory, and stable system knowledge to docs. The load contract covers what gets read, and keeps the always-loaded set small enough that a session opening does not cost more than the task. The binding rules live in the preset, and each file's header carries its own format contract.

## Presets

Rule presets for different domains. Pick one during bootstrap or let the agent adapt:

- **[Software development](presets/software-development.md)**: load order, code quality, testing, git discipline
- **[Academic research](presets/academic-research.md)**: evidence-first writing, source traceability, no unsupported claims
- **[Domain knowledge](presets/domain-knowledge.md)**: accumulating and organizing information over time

Each preset is self-contained — bootstrap copies exactly one into `rules/contract.md`. Editing them? [`presets/_shared.md`](presets/_shared.md) lists the text that must stay word-for-word identical across all three (the rules describing the operating model rather than a domain). `scripts/test.sh` fails if any of it drifts.

## Get started

Two prompts, one per node type. Either works standalone: a project node is self-contained. Add the root when you want memory that follows you across projects.

### Your root node: `~/.agent/` documents you

Copy this into any capable agent:

```
Read the .agent/ operating model at https://github.com/dmonteroh/dot-agent. Then set up my root node at ~/.agent/. Its subject is me, not a codebase. Do the steps in order. Finish each one before starting the next.

1. Interview me first, before you clone anything or write any file. Ask one question at a time. Prioritize questions whose answers change what you'll write. Cover my role, my active projects, how I work and communicate, and preferences that should hold across every project. Ask for the tracking mode too: ignore-all, track-shared, or track-all (see Tracking modes in the operating model). Don't invent facts about me.
2. Clone the source repo. Choose the preset that matches my work: software-development, academic-research, or domain-knowledge, and no other name. Then run `bash scripts/node.sh init --preset <name> --mode <mode> ~` from the clone. It creates ~/.agent/, stamps its manifest, and copies the scripts and their starter confs. Read what it prints before going on. If it refuses because ~/.agent/ already exists, stop and tell me. An existing node takes the update prompt, not this one. Expect its note about skipping the gitignore at ~. Don't write one by hand.
3. Adapt the preset that node.sh copied into rules/contract.md. Keep its Kernel intact.
4. Move contract.md's `## Quality bar` section into rules/quality-bar.md. After the move, that section is gone from contract.md and the rubric loads on demand.
5. Write purpose.md from what I told you in step 1: what this node is for and what it holds. Leave the dot-agent frontmatter block at the top of the file untouched.
6. List any existing project nodes in the manifest's children.
7. Wire my tools at the root from the canonical entry-point template. The template is templates/entry-point.md in the clone. For Claude Code, the entry point is ~/.claude/CLAUDE.md. Fill every <…> placeholder. Delete the template's own header comment. Write every path absolute, since sessions run from project directories. That means ~/.agent/..., and `bash ~/.agent/scripts/status.sh ~` for the status step. Keep every entry point you write byte-identical to the others.
8. Disable Claude Code's native memory: set "autoMemoryEnabled": false in ~/.claude/settings.json.
9. Last, run `bash ~/.agent/scripts/status.sh ~`. Clear every REPAIR: line it prints. If clearing one needs a fact I haven't given you, ask me instead of inventing it.

Ask me anything you can't infer.
```

### A project node: `.agent/` documents a codebase

Run this inside the project:

```
Read the .agent/ operating model at https://github.com/dmonteroh/dot-agent. Then bootstrap .agent/ for this project. Do the steps in order. Finish each one before starting the next.

1. Explore the project: README, configs, source, and git history. Confirm your findings with me before writing anything. Include which preset fits, and what you could not infer.
2. Ask me the tracking mode once. The three modes are ignore-all (.agent/ fully gitignored), track-shared (purpose/rules/docs shared, memory.md/memory/ and logs ignored), and track-all (everything committed).
3. Clone the source repo. Then run `bash scripts/node.sh init --preset <name> --mode <mode> <this project's path>` from the clone. It creates .agent/, stamps its manifest, and writes the matching gitignore entries. <name> is the preset we settled in step 1: software-development, academic-research, or domain-knowledge, and no other name. Give an absolute path, since you are running from the clone. Read what it prints before going on. If it refuses because .agent/ already exists, stop and tell me. An existing node takes the update prompt, not this one.
4. Adapt the preset that node.sh copied into rules/contract.md. Keep its Kernel intact. Fill Project guardrails with exact commands ("run the tests" is not filled in — the real test command is).
5. Move contract.md's `## Quality bar` section into rules/quality-bar.md. After the move, that section is gone from contract.md and the rubric loads on demand.
6. Write purpose.md from what step 1 established. Cover what this project is, who it's for, its key constraints, and where to change what. Leave the dot-agent frontmatter block at the top of the file untouched.
7. Wire my tools from the canonical entry-point template into CLAUDE.md and AGENTS.md. The template is templates/entry-point.md in the clone. Add .github/copilot-instructions.md if I use Copilot Chat or code review. Fill every <…> placeholder: the project line and the doc routing. Delete the template's own header comment. Keep every entry point byte-identical.
8. Disable Claude Code's native memory: set "autoMemoryEnabled": false in .claude/settings.json.
9. If I have a root ~/.agent/, add this node to its manifest's children.
10. Last, run `bash .agent/scripts/status.sh` from this project's root. Clear every REPAIR: line it prints. If clearing one needs a fact I haven't given you, ask me instead of inventing it.

Ask me anything you can't infer. Don't guess.
```

The tracking mode in step 2 is the gitignore practice: it decides what enters git, once, at bootstrap, and `node.sh init` writes it. See [Tracking modes](operating-model.md#tracking-modes) for the exact gitignore each mode writes.

### Updating an existing node

When the operating model evolves, run this inside the node's project (or at the root):

```
Read the .agent/ operating model at https://github.com/dmonteroh/dot-agent. Then update this project's existing .agent/ node to match it.

1. Clone the source repo. Then run `bash scripts/node.sh update <this node's path>` from the clone. Give an absolute path, since you are running from the clone. The script reads the manifest and compares version. It backs up the node first, unless its mode is track-all. It then applies the mechanical migration baseline. Read its output before going on:
   - If it says the node is current, any recognized same-version shape refresh is complete. Go straight to step 4.
   - If it reports no manifest (a pre-V6 node), update the node by hand instead. Work through CHANGELOG.md from the V6 entry forward as the migration checklist. If you restore the manifest, stamp it with the node's real prior version before re-running the script.
   - If it stops for any other reason, stop and tell me. Those reasons include no .agent directory at that path, or a backup path already there. Never delete, move, or rename anything to get past it.
2. Reconcile. Apply what the operating model adds, while preserving accumulated content: memory, learned rules, and project-specific adaptations. That includes splitting `memory/legacy.md` into fact files per its GROOM flag. If existing content directly conflicts, flag it and let me decide. Never silently overwrite.
3. Refresh the entry points against the canonical template. The template is templates/entry-point.md in the clone. Carry this node's own filled-in values into the refreshed copy: the project line and the doc routing. Never leave the template's <…> placeholders. Keep every entry point byte-identical.
4. Repeat steps 1–3 for each child node listed in the manifest's children, one node at a time.
5. Run the node's status check: `bash .agent/scripts/status.sh` from its project root, or `bash ~/.agent/scripts/status.sh ~` for a root node. Clear the REPAIR: lines it prints.
6. Report what changed, what you preserved, anything you flagged for me, and any REPAIR: line still standing.
```

Each conversation opens with one status check: the entry point's first step runs `.agent/scripts/status.sh`. Later user messages continue the same session and do not reopen the entry point or reload its files; after a compaction or handoff the steps run again. The check prints recent session-log entries and `GROOM:` flags when files breach their grooming thresholds. `REPAIR:` flags cover missing stamps, index/file drift, and bootstrap steps left undone (unfilled guardrails, an unsplit quality bar, entry points that stopped matching, native memory still enabled). It also prints `INDEX:` flags for doc-routing drift, advisory `TOOLS:` notes, and an advisory `LOAD:` line measuring what the always-loaded set costs. The agent handles the flags as part of the session — inline, or by handing `GROOM:` work to one subagent (a small model is fine) scoped to the flagged files. There is no completion-time gate. Grooming rides the load path.

One check is deliberately not on that path: `.agent/scripts/links.sh` audits the node's own link graph on demand, reporting `ORPHAN:` (a file nothing cites) and `BROKEN:` (a cited node path that doesn't exist). Run it when grooming or after a restructuring pass. It matters most for `docs/<area>/references/`, which carries no routing entry by design, so an uncited reference file is unreachable and nothing on the load path can tell.

A third check runs at diff time: `.agent/scripts/comments.sh` gates the comments a diff adds, run against the change's true parent ref. It blocks five decidable kinds — citations a fresh clone cannot open (commit SHAs, git transcripts, ticket ids), code left commented out, narration of the change ("previously", "no longer", "now returns"), replies to whoever asked for it, and short narration of the structure below it ("build the rows", "gets the user name") — and lists every other added comment for the author to justify or delete, labeling any that merely restate the code below them. What no pattern settles stays in the review list: whether a reader would have been surprised, and whether the explanation already exists elsewhere in different words. Team-specific vocabulary (base ref, ticket and narration patterns, the constraint escape, the scanned extensions, path exclusions) lives in `comments.conf` beside it — plain `KEY=value`, parsed and never executed. Init seeds a starter, and update seeds it only when absent and never overwrites it. The status check's thresholds and probed-tools list tune the same way, in `status.conf`, and the log writer's options in `log.conf` (`LOG_INCLUDE_BRANCH=true` stamps each entry with the checked-out branch, read from git at write time). Starters listing every key ship at init, since a knob without its file on disk is a knob no one finds. Conf edits survive update, script edits don't. The operating model's "The comment gate" section documents the keys with a full example.

If you use **Claude Code**, optional [skills](tools/skills/) package the rare in-session procedures (grooming, retro) for on-demand loading. They are installed into `.agent/skills/` and read through a symlink. [`tools/claude-code/`](tools/claude-code/) ships the settings the bootstrap copies (`autoMemoryEnabled: false`, `.agent/**` permissions). The trust contract is the compliance story, and the reference deployments run without any of it.

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

Wire a tool to the root (Claude Code via `~/.claude/CLAUDE.md`) and it works across projects. It knows how they relate and how you think. Wire a tool only to a leaf (Cursor via `.cursorrules`) and it focuses deeply without distraction. Root agents coordinate. Leaf agents specialize.

The tree grows as needed. Start with one node. Add a root when you work on a second project. The topology is yours: solo dev with many repos, monorepo with package nodes, or a single project with no root at all.

See [operating-model.md](operating-model.md) for the full pattern, observation, setup, and team considerations.

## How it compares

| | AGENTS.md | Tool-specific files | .agent/ |
|---|---|---|---|
| Agent reads context | Yes | Yes | Yes |
| Agent-maintained memory lives in the repo | No | No | **Yes** |
| Survives tool switch | Partially | No | **Yes** |
| Memory across sessions | No | Partially | **Yes** |
| Shareable with a team through review | Yes | No | **Yes** |
| Loads only what the task needs | No | No | **Yes** |
| Has a compliance mechanism | No | No | **Yes** |

Use `AGENTS.md` for shared team instructions. Use `.agent/` for personal persistent context.

Read **[operating-model.md](operating-model.md)** for the full operating model: philosophy, directory structure, self-maintenance contract, tool wiring, and design decisions.

## Working on this repo

Rationale has one home per story. `CHANGELOG.md` states what a release changed in this repo, `operating-model.md` states the rule plus at most a one-line pointer, and a code comment states only the constraint it enforces. For a tunable, the comment states the provenance of its number. Field observations from private nodes are evidence for a decision, never content: a shipped number cites them anonymously where it lives, and nothing in the corpus retells them. Trim the other copies whenever a change touches them.

Every script is documented in [`scripts/docs/`](scripts/docs/) — one file each, covering what it reports and how a node tunes it. Those docs stay in this repo: a node receives the executables and their starter confs, never this repo's design notes.

Run `bash scripts/test.sh` after any change under `scripts/`: self-contained smoke tests for `node.sh`, `status.sh`, `log.sh`, `memory.sh`, `docs.sh`, `links.sh`, and `comments.sh`. It must pass before a change ships.

That suite checks the corpus as an artifact, and every check in it passes on a corpus no agent obeys. [`evals/`](evals/) covers the other half: paired runs that measure whether a session under this corpus behaves differently from one without it. It belongs to this repository and never to a node — nothing under `evals/` is installed by `node.sh` or copied into a project adopting `.agent/`. It is not in CI either, since a run costs model tokens and returns a distribution rather than a bit, but `test.sh` validates its spec, builds its fixtures and drives its grader, so the eval set cannot rot between runs.

## License

MIT
