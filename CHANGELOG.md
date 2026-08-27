# Changelog

Design evolution of the `.agent/` operating model. Each version captures the reasoning, not just the diff.

---

## V6.2 (2026-08-23): Claims become checks

### Why

V6.1's standing claims got instruments. Portability was asserted for four tools and never tested, and one asserted value had already rotted. The always-loaded set was bounded per file but never summed. `.agent/` was treated as a leak surface but not as the injection surface a store every future session auto-loads also is. And the session-log entry format lived only in prose and in a writer any hand edit bypasses, with no check on the entries themselves.

### What changed

#### Portability

- The wiring table is a disposition matrix: entry point, native-memory switch, and a verified-against source and date per tool. A cell reads `verified` only against the product or its vendor's own documentation. `reported` and `unknown` print as themselves, and prose never outruns the cells.
- Verified 2026-08-23: Cursor reads `AGENTS.md` at the project root, and `.cursorrules` is legacy — deprecated, reported ignored by agent mode. Copilot's coding agent reads `AGENTS.md` and `CLAUDE.md`. Chat and code review read `.github/copilot-instructions.md`. `AGENTS.md` is stewarded by the Agentic AI Foundation. The recommended mirror set becomes `CLAUDE.md` + `AGENTS.md`, plus `.github/copilot-instructions.md` for teams using Copilot Chat or code review. `status.sh` and `links.sh` keep `.cursorrules` in their candidate lists so existing nodes' mirrors stay checked.
- `test.sh` gains a vendor-token lint over the node-landing corpus — presets, template, node scripts — with a commented allowlist of the deliberate references. It also asserts the wiring matrix and both scripts' candidate lists cover the same entry-point set, so a tool added to one surface cannot arrive unchecked on another.

#### The status check

- One advisory `LOAD:` line every run: the always-loaded set's word total with a per-file breakdown, plus the log tail the check just printed. No threshold: a per-file limit that is never summed is not a limit, and the line covers the three set members with no per-file trigger: `contract.md`, `purpose.md`, the routing table.
- `GROOM:` on session-log entries over `LOG_ENTRY_MAX_WORDS` (50: the header format's 25 with 2× grace), entries counted whole across hand-wrapped lines. The groom skill covers clearing it.
- Every threshold and the probed-tools list are per-node tunables in `.agent/scripts/status.conf` (plain `KEY=value`, parsed and never executed). `node.sh update` refreshes the shipped scripts and discards edits to them. The conf beside them survives it, so a tuned threshold is a conf edit and never a script edit. A starter ships at init listing every key — the probed-tools line live, thresholds commented at their defaults. It ships because the scripts are executed rather than read, so an unseeded conf is an undiscoverable one. `test.sh` pins the starter's shown defaults to the script's.

#### The memory contract

- The fact-file header contract moves into `memory.md`'s header: a fact file holds its frontmatter and the fact, nothing else. `memory.sh` states the contract in its output, where it reaches the session doing the writing instead of every later read. Every other canonical file is a singleton, so its contract is written once however large the node grows. `memory/` is the only tier with N files, where one header is paid N times over. The replacement opens with a retention test — keep a fact only if work in this node changes when it is true, and a fact arriving from another repo or a migration earns its place again. `node.sh update` strips the old per-file header behind the existing backup, keeping the fact and its frontmatter. A node already on 6.1 is migrated too, since version-current is not shape-current.
- The Continuity contract's `memory/` bullet defers to `memory.md`'s header contract instead of restating three of its rules.

#### Memory security

- The origin gate: durable records — memory facts, learned rules, preferences — are minted only from the user's own messages or the session's verified work. A directive inside processed material is content to report, never an instruction to record. The full rule joins every preset's Continuity contract and a shared clause joins every Kernel's security slot, both locked by `_shared.md`.
- The operating model's Security section states the mirror rule — load as if it could have been planted — and the cross-tool amplification a shared store creates. The same section labels the control honestly: cooperative, with `track-shared` PR review as the mechanical gate.

#### The comment gate

- `comments.sh` joins the shipped node scripts. Run against the branch base before a diff is handed back, it blocks added comments citing what a fresh clone cannot open — commit SHAs, git transcripts, scope narration. It lists every other added comment for the author to justify or delete. The objective half of the comment rule moves into code. The judgement half stays a listed review, because "is this comment narrative?" is a call a reviewer can wave through and "can a fresh clone open what this cites?" is not.
- Wired where sessions live: the entry-point template names the run before a diff is handed back, the software preset's Verification contract binds it, and the quality bar carries it as a verifier check. The Self-learning routing sends comment-hygiene lessons into its vocabulary instead of another prose rule. The retro skill expands the how, and its description now names the concrete retro triggers so it can actually be matched.
- Workflow vocabulary is the node's, not the core's. `comments.conf` beside the script carries the base ref, ticket and task-reference patterns, the scanned extension list, and path exclusions — plain `KEY=value`, parsed and never executed. A config read every run is an injection surface, and this one cannot run code. The operating model documents it with a full example. Init seeds a starter conf — AC/Q ticket shapes as example vocabulary and the extension list live, so trimming to a project's stack is a conf edit. Update seeds the file only when absent and never overwrites it. Otherwise it refreshes the shipped scripts by exactly their six names, touching nothing else under `scripts/`.

#### The log writer

- `log.sh` reads a seeded `log.conf`. `LOG_INCLUDE_BRANCH=true` stamps each scripted entry with the checked-out branch as `branch: <name>.` before the verify tag — read via `git symbolic-ref` at write time, mechanical rather than agent-supplied, and silently omitted outside a git checkout or on a detached HEAD. The stamp spends no summary budget (the ceiling is enforced on `--summary` alone) and a stamped max-length entry stays well under the entry-shape flag — both test-pinned. The 25-word summary ceiling tunes from the same conf. Off by default. The session-log header contract names the optional segment.

#### Mechanics

- `node.sh` targets `"6.2"`. The 6.1→6.2 update is script refresh plus version bump, with preset changes landing through the normal reconcile step. The update message now names `links.sh` and `comments.sh` among the refreshed scripts.
- `status.sh` and `links.sh` exit non-zero on one case: a root holding no `.agent/`. Findings still never reach the exit status. Printing a node's worth of `REPAIR:` lines for a directory nobody addressed would send an agent to repair a node that does not exist, so the two are told apart. `scripts/docs/README.md` states every script's codes in one table.

### Migrating a V6.1 node

Run `scripts/node.sh update`, then reconcile `rules/contract.md` against the current preset: the security slot's appended clause, the origin-gate bullet, the shortened `memory/` bullet, and (software nodes) the Verification contract's comment-gate bullet plus the quality bar's gate check. Add the template's comment-gate paragraph to every entry-point mirror. A node that grew its own comment gate replaces it with the shipped script and moves its project vocabulary into `comments.conf`. Re-derive entry points only if adopting the new mirror set. Existing mirrors keep being checked either way.

---

## V6.1 (2026-07-27): Tiered context and scripted writes

### Why

A node's context loads in tiers. A small always-loaded set carries the rules and the indexes; everything else waits behind a hook, a routing entry, or a path a doc hands out. Scripts own every write that has to land in two places at once, and `status.sh` checks the node's shape on the load path rather than at the end of a session.

The direction follows Anthropic's *The new rules of context engineering for Claude 5 generation models*, with three workflow patterns from *A field guide to Claude Fable: Finding your unknowns*. Native tool memory stays off: `.agent/` is the only durable store, disabled by setting rather than instruction.

### What changed

#### Memory

- `memory.md` is an index, one line per fact file, newest last, reordered only when grooming. Each durable fact lives in `memory/<slug>.md` under `date`, `scope`, and `type` frontmatter. Two halves that would be superseded at different times are two files.
- `type` is `fact` or `reference`. A fact is something the node knows and supersedes as the project changes. A reference points outward at a URL, dashboard, ticket, or spec the node does not own.
- The index loads every session. A fact file opens when its hook matches the task, and that match is re-checked whenever the work moves to a new area.

#### Rules

- Every preset opens with a retention test: keep a rule only if a competent engineer would not already follow it, or if it is specific to this project, this operating model, or a mistake this project made. The Kernel holds at most ten negative constraints.
- The verification rubric lives in `rules/quality-bar.md`, split out of the preset at bootstrap. Verifier subagents always load it; the main session loads it for substantial work. `contract.md` keeps the rules that bind every session.
- `rules/learned.md` stays one file, the artifact that passes PR review in `track-shared`. Its grooming triggers are 60 rules or 2,400 words, whichever comes first.
- `presets/_shared.md` lists the text that must appear word for word in all three presets. `test.sh` fails when any of it drifts.
- Retro fires on a user correction, a failed verification that needed a non-obvious fix, or a mid-task deviation from an agreed plan. The rule it produces is imperative and under 40 words, and it merges with a near-duplicate rather than joining it.

#### Docs

- `docs/architecture.md` carries a per-doc entry with two fields. `Read when:` decides whether to open the doc. `Sections:` lists its `## ` headings, and finds a doc whose hook never names the topic. An entry may say more than a heading, never less.
- A catalog is an area's index of what already exists plus the recipes for adding more. Its hook is unconditional, so it loads for any task in its area that creates something. `software-development` gains the reuse rule, the same-change catalog-entry obligation, a quality-bar criterion, and a `Catalogs:` guardrail slot.
- An area that outgrows one file splits into `docs/<area>/` sub-docs, routed from the same table.
- `docs/<area>/references/` is the third tier: no routing entry, no size trigger, no auto-load. An area doc hands out the path. Full schemas, exhaustive tables, and worked examples live here.
- Area docs carry a header contract written by `docs.sh new`: facts as tables or one-fact-per-line bullets, prose only for the *why*, cited code paths, timeless phrasing, `## Gotchas` for area traps. Restructuring a doc changes its shape and never its content, and no tightening or splitting pass drops a name, value, command, path, or gotcha.

#### Scripts

- `node.sh init` builds the skeleton, manifest, gitignore, and script copies. `node.sh update` reaches the mechanical baseline: memory body moved verbatim to `memory/legacy.md`, scripts refreshed, `version` bumped, and every node with untracked memory backed up first.
- `memory.sh new` and `docs.sh new` each make a two-place write one operation. `log.sh` stamps the date and holds the summary to 25 words.
- `links.sh` audits the node's link graph on demand, reporting `ORPHAN:` for a file nothing cites and `BROKEN:` for a cited node path that does not exist. Paths outside `.agent/` are out of scope, and the session log, `archive/`, and `rules/` are read as records and instructions rather than citations.
- `test.sh` smoke-tests all of it and runs on Ubuntu and macOS in CI alongside ShellCheck.

#### The status check

`status.sh` runs as the entry point's first step. It prints the recent session-log entries, then one line per finding, and always exits 0.

- `GROOM:` at the grooming triggers: 120 log entries or 5,000 words, a 300-word memory fact, a 100-entry index, `learned.md` past 60 rules or 2,400 words, a 2,000-word area doc. Grooming is size-based, so the dates inside log entries are context for when something happened and nothing else. Each threshold is a review trigger rather than a cap, tunable at the top of the script, and each states its source where it lives.
- `REPAIR:` for a missing canonical file or manifest, index and fact files that disagree, guardrails still holding template placeholders, `## Quality bar` still inside `contract.md`, entry points that stopped matching, and `autoMemoryEnabled` set true or set nowhere.
- `INDEX:` for a doc missing from the routing table, a hook that drifted on one side, or a `## ` heading absent from `Sections:`.
- `TOOLS:` for environment availability.

#### Entry points and sessions

- The canonical template ships as `templates/entry-point.md`. Bootstrap copies it into each tool's filename and fills the placeholders. Root nodes write absolute paths, since sessions run from project directories.
- The README ships three prompts: root-node bootstrap, project-node bootstrap, and node update. The root prompt interviews one question at a time, taking the questions whose answers change what gets written first. The project prompt confirms its findings before writing, including what it could not infer.
- After a context compaction or handoff, steps 1 through 5 run again.
- `GROOM:` flags may go to one subagent assigned to write only the flagged files, and the dispatching session re-runs `status.sh` to confirm they cleared. `REPAIR:` stays in the main session.

#### Tooling

- `tools/skills/` ships `groom/` and `retro/` as optional Claude Code skills, installed at `.agent/skills/` and symlinked into each tool's skills directory. A skill expands the *how* of a procedure the contract already names.
- `tools/claude-code/` ships `settings-example.json`. The V4/V5 compliance hooks and `verify-agent-context.sh` are gone. Compliance is the trust contract plus the status check.

#### Manifest

The manifest's `version` is a quoted string, since bare 6.1 parses as a YAML float and collides with 6.10, and comparison uses `sort -V` semantics. Comparison-table rows updated: "Agent-maintained memory lives in the repo", and "Memory across sessions" is Partially for tool-specific files.

### Migrating a V6 node

Run `scripts/node.sh update`. Then, in a normal session: split `memory/legacy.md` into fact files when `GROOM:` flags it, re-derive the entry points from the canonical template, extract the preset's `## Quality bar` into `rules/quality-bar.md`, and reconcile `rules/contract.md` against the current preset, dropping any `verify-agent-context.sh` reference and the node's local copy. Flag conflicts for the operator instead of overwriting.

---

## V6 (2026-07-11): Fork lineage + harvest

### Why

This fork (`dmonteroh/dot-agent`) diverges from upstream (`jlonardi/dot-agent`, through V5) on five months of field data from four production instances. The shipped files contradicted each other in small but costly ways, and the mature instances had independently evolved a better contract than the one that seeded them. V6 fixes the contradictions and ships what the field already built.

On top of the consistency pass comes the harvest: node identity that survives rewrites, tracking modes matching how the four instances actually use git, a mechanical answer to tool-native memory, the canonical executable bootstrap the instances converged on, and (the largest piece) the evolved instance rules as the new preset seeds.

### What changed

- **Fork lineage:** the version line forks here. V6 is `dmonteroh/dot-agent`; upstream lineage is V1–V5. Source references and the bootstrap prompts point at this fork.
- **Dated log entries:** the session-log template is `- [YYYY-MM-DD] (tool) …` everywhere, matching the field format. The model is appended to the tag only when the harness states one, `(claude/sonnet)`, never guessed: a wrong tag silently corrupts measurement; a missing one is visible and countable.
- **One archive location:** `archive/session-log-archive.md`; a directory keeps future archives out of the node root.
- **Grooming thresholds replace anti-grooming advice:** "reorganizing costs more tokens than reading a longer file" was wrong in the field (one instance lost its pre-June history to an unarchived 5,834-word log). Replaced with numbers: session-log over ~80 entries or ~5,000 words → archive entries older than 30 days; memory.md over ~800 words → compact; learned.md over ~25 rules → merge near-duplicates.
- **Honesty pass on compliance claims:** "Can be enforced" becomes "Has a compliance mechanism"; the hooks move to an appendix labeled optional, Claude-Code-only, unused in the reference deployments. The trust contract is the primary compliance story.
- **Rules file renamed to `contract.md`:** V5 declared this rename but shipped no update mechanism, so pre-V5 nodes never picked it up; that was a missing update path, not evidence against the name. V6 supplies what the rename lacked: the manifest's `preset` field keeps the domain provenance the filename used to carry, the update pass lands the rename on old nodes (changelog as the pre-V6 migration checklist), and a fixed name removes the `<preset>` placeholder from the canonical entry point. Preset seeds in this repo keep their domain names; the node's adapted copy is `contract.md`.
- **Node manifest:** node identity moves to `dot-agent` YAML frontmatter on `purpose.md` (source, version, preset, mode, children), protected by a negative constraint (update passes change only `version`) restated as a comment inside the block itself. The V5 rules-file comment survived only as long as an updating agent deemed it important; both mature instances lost theirs. Child nodes are listed here, not in `memory.md`.
- **Tracking modes:** `ignore-all` / `track-shared` / `track-all` replace "always gitignored"; asked once at bootstrap, recorded in the manifest. In `track-shared`, every rule the agent taught itself passes PR review before binding anyone else. Security rule rewritten to match practice: dev-only values already hardcoded in the repo may be cached; tracked files are reviewed like code.
- **Native tool memory disabled by setting:** for Claude Code, `"autoMemoryEnabled": false` in `.claude/settings.json`, committed in tracked modes; prose overrides of built-in memory are unreliable. Retro harvests any tool-collected silo into `.agent/` and deletes it.
- **Evolved presets become the seeds:** `software-development.md` generalizes the two mature field instances (~80% converged text); the other two presets rebuild on the same skeleton. Kernel slots 8–10 are identical across all three so update-propagation diffs stay mechanical. `domain-knowledge.md` is a real harvest; `academic-research.md` has no field instance and ships at Medium confidence; its first bootstrapped node is the experiment.
- **The Kernel:** each preset opens with ≤10 negative constraints, the rules that matter most. Per-instruction compliance decays multiplicatively with rule count, so the always-loaded count decides whether a small model can run the system at all. Small-model load = Kernel + Project guardrails; no model-tier machinery beyond that entry-point choice.
- **Bootstrap-filled Project guardrails:** every preset ends with a template the bootstrap fills with exact commands. Small models fail judgment calls and pass mechanical ones; judgment stays with the human at bootstrap time.
- **Catalogs routed out of memory.md:** both knowledge presets marched memory.md through its own grooming threshold by spec. Catalogs live in `.agent/docs/`, always; memory.md holds working state only. The knowledge-levels rule survives in domain-knowledge's Knowledge discipline section.
- **First field-learned rule promoted to seed:** verify citations against the primary source; a stored summary is not a substitute (field instance, 2026-05-17). Now in both knowledge presets' verification contracts.
- **Canonical entry point replaces per-tool wiring examples:** one tool-executed numbered bootstrap, mirrored identically across every entry-point file. The status check runs first (step-skipping concentrates at the tail of numbered lists); the preset-read step is an inverted-default conditional: Kernel + guardrails floor, full preset only for models on a per-project strong-model list matched on family substrings, refreshed by update passes. The README ships three prompts (root-node bootstrap, project-node bootstrap, and node update) naming the bootstrap obligations and the update safeguards (preserve accumulated content, back up untracked nodes, changelog as the pre-V6 migration checklist).
- **File header contracts:** every canonical file opens with a 2–4-line comment that is its own format contract, in context at the exact moment of writing, for every tool, including ones that never read the preset.
- **Status check on the load path:** `scripts/status.sh` replaces `verify-agent-context.sh`'s routine role: run first by the entry point, it prints recent session-log entries and checks artifacts rather than claims, emitting `GROOM:`/`REPAIR:`/`INDEX:` flags plus advisory `TOOLS:` notes, silent on pass, always exit 0. Completion-time gates are what the field demoted; `--fix` placeholder generation is gone (phantom-compliance bait). The old script keeps a deprecation header because instance rule files reference its path.
- **Subagent contract named in the operating model:** the exception is write authority, not reads. Workers read context like any session (skipping only the status check), never write `.agent/` unless explicitly assigned; the orchestrator is the single session-log writer, which ends the field's duplicate orchestrator/implementer log pairs. `workflows/`, `agents/`, and unreferenced directories never load by default. The proposal drafted a narrower subagent load (rules + brief only); it shipped as read-everything, because conditional loads don't survive at rule scale, and the write ban is the rule that was actually load-bearing.
- **One rule, one home:** behavioral rule text deduplicated out of the operating model (which still said 2–5-line log entries while the field's presets say ~25 words): the spec describes mechanism and files, presets carry the only copy of behavioral rules, entry points carry only wiring. A future edit has no second copy to contradict.

---

## V5 — 2026-02-10 — Behavioral architecture + self-learning

### Why

V4 added enforcement hooks as optional tooling for the self-maintenance contract. But hooks can enforce more than documentation updates. A comparison with aashari's framework revealed two gaps: (1) hooks can enforce correctness (re-read files, run tests), not just session-log compliance, and (2) the system doesn't self-learn. Memory captures facts, but behavioral rules stay static and human-authored.

### What changed

- **Behavioral enforcement** — new section in operating model. Elevated hooks from optional tooling to first-class architectural concept. Described a trust contract: five lifecycle phases (bootstrap, pre-work, correctness, completion, retro) that agents should follow regardless of enforcement. Hooks are the reference implementation, not the concept.
- **Self-learning loop** — new `rules/learned.md` file at every level of the knowledge tree. Agent-authored behavioral rules accumulated from session retros. Distinct from human-authored rules: rules tell the agent how to behave, memory tells it what to know.
- **Three new core hooks** — `pre-work.py` (blocks edits until project `.agent/` context is loaded), `correctness.py` (tracks file edits, re-reads, and test execution; blocks Stop if skipped), `retro.py` (prompts behavioral reflection after substantial sessions).
- **Presets updated** — self-learning section added to all three presets. Correctness section added to software-development preset.
- **Renamed `agent-and-quality.md` to `contract.md`** — the old name didn't describe the content. "Contract" matches operating model terminology. Existing nodes keep their current filename until manually updated.

### Breaking changes

- Preset rules file renamed from `agent-and-quality.md` to `contract.md`. Nodes bootstrapped before V5 still have the old name. The daily-bootstrap hook's `REQUIRED_FILES` needs updating when you rename your local copy.

---

## V4 — 2026-02-09 — Enforcement hooks + one-prompt install

### Why

The self-maintenance contract is the system's core mechanism, but compliance depended entirely on the agent following instructions. Hooks turn convention into enforcement. Separately, the bootstrap process had too many prompts for different scenarios.

### What changed

- **Claude Code enforcement hooks** — `self-maintenance.py` in `tools/claude-code/`. Blocks session end until `session-log.md` is updated in ALL discovered `.agent/` directories. Enforces dual-write (project + global).
- **One-prompt install** — single bootstrap prompt in README that handles fresh install, updates, and project bootstrap. Agent determines the right action from current state.
- **Clean spec/README split** — operating model is the spec agents read, README is the human entry point with prompts. No duplication.
- **Removed core daily-bootstrap** — the assistant version is a strict superset and degrades gracefully. Core hook was redundant.
- **Ambiguity resolution** — added to all presets: "check memory before asking for clarification."

---

## V3 — 2026-02-08 — Operating model + observation

### Why

"Manifesto" sounded too grandiose. The document describes how things work, not what we believe. Also, the observation rule needed tightening: vague observations without triggers or confidence are noise.

### What changed

- **Renamed `manifesto.md` to `operating-model.md`** — updated all references, source refs, README links.
- **Observation tightened** — every new observation must include a concrete trigger (quote/behavior) or confidence tag (`high`/`medium`/`low`). Prevents accumulation of untraceable vague notes.
- **Session log routing** — explicit rule that entries go to the project you worked on, not the directory you were opened in. Root always gets an entry.

---

## V2 — 2026-02-08 — Knowledge tree + propagation

### Why

A single `.agent/` per project works, but real usage creates a natural hierarchy: a root node documenting the person, project nodes documenting codebases, package nodes documenting specific areas. The pattern needed to be formalized, and nodes needed a way to stay in sync with an evolving operating model.

### What changed

- **Knowledge tree** — replaced hub-and-spoke with recursive tree model. Every node follows the same structure (purpose, memory, session-log, rules, docs). Root documents the person, branches document projects.
- **Source references** — agents leave a `<!-- Source: URL | Version: N -->` comment in rules files so nodes can compare versions and update themselves.
- **Propagation** — when a node updates itself, it walks the tree and updates child nodes. "Update yourself" at root cascades to all projects.
- **Conflict resolution** — operating model additions always apply, project-specific content preserved, ambiguity flagged for human decision.
- **Versioning** — version tags in operating model and source references so nodes can detect when they're behind.

---

## V1 — 2026-02-07 — Initial convention

### Why

Every AI coding session starts with amnesia. Static instruction files (AGENTS.md, .cursorrules) flow one way: you write, the agent reads. Nothing is captured when the agent discovers something or finishes work. You are the memory. That doesn't scale.

### What changed

- **The `.agent/` directory** — markdown files at a known location. Agent reads at session start, writes at session end.
- **Self-maintenance contract** — the core mechanism. Agent must update `memory.md`, append to `session-log.md`, and update `docs/` before finishing any task.
- **File purposes** — `rules/` (behavior), `purpose.md` (what/why), `memory.md` (current state), `session-log.md` (chronological history), `docs/` (stable reference).
- **Three presets** — software development, academic research, domain knowledge. Seeds for different domains.
- **Tool wiring** — thin entry points for Cursor, Claude Code, Copilot, Codex that point to `.agent/`.
- **Context auditing** — agents notice and fix stale facts during session start.
- **Verification script** — `verify-agent-context.sh` for agents without hook support.
- **Security rules** — never store secrets, sanitize URLs, treat `.agent/` as potentially leakable.
