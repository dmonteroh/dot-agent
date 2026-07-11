# Changelog

Design evolution of the `.agent/` operating model. Each version captures the reasoning, not just the diff.

---

## V6 — 2026-07-11 — Fork lineage + harvest

### Why

This fork (`dmonteroh/dot-agent`) diverges from upstream (`jlonardi/dot-agent`, through V5) based on five months of field data from four production instances. Before the larger V6 harvest changes land, the shipped files contradicted each other in small but costly ways: the spec's own session-log example failed the verify script's date check, the presets and the field named different archive locations, the housekeeping advice argued against the grooming the field proved necessary, and the enforcement claims oversold hooks the reference deployments don't run.

On top of the consistency pass, the harvest ships what use already built: node identity that survives rewrites, tracking modes matching how the four instances actually use git, a mechanical answer to tool-native memory, the canonical executable bootstrap the instances converged on, and — the largest piece — the evolved instance rules as the new preset seeds.

### What changed

- **Fork lineage** — the version line forks here: this is V6 of `dmonteroh/dot-agent`; upstream lineage is V1–V5 (`jlonardi/dot-agent`). Source references and the bootstrap prompt now point at this fork.
- **Dated log entries** — the session-log entry template is `- [YYYY-MM-DD] (tool) …` everywhere, matching what the verify script checks and what the field instances converged on. The model is appended to the tool tag only when the harness states one — `(claude/sonnet)` — never guessed.
- **One archive location** — `archive/session-log-archive.md`. A directory keeps future archives (memory snapshots, superseded docs) out of the node root. Presets previously said `.agent/session-log-archive.md`.
- **Grooming thresholds replace anti-grooming advice** — "a few hundred lines is negligible / reorganizing costs more tokens than reading a longer file" is deleted from the operating model and all three presets. It was wrong in the field: one instance lost its pre-June history to an unarchived 5,834-word log; another hit 15,303 words. Replaced with numbers: session-log over ~80 entries or ~5,000 words → archive entries older than 30 days; memory.md over ~800 words → compact; learned.md over ~25 rules → merge near-duplicates.
- **Honesty pass on compliance claims** — the comparison-table row "Can be enforced" is now "Has a compliance mechanism"; the enforcement-mechanisms section moved to an appendix labeled optional, Claude-Code-only, unused in the reference deployments. The trust contract is the primary compliance story — it is the one with months of field evidence.
- **Rules filename** — the human rules file keeps the preset name (e.g. `software-development.md`); that is what exists in every field instance. V5's `contract.md` rename never shipped in practice.
- **Node manifest** — node identity moves to `dot-agent` YAML frontmatter on `purpose.md` (source, version, preset, mode, children). Root cause of the lost version stamps: an HTML comment in a rules file survives only as long as an updating agent deems it important — both mature instances lost theirs. Frontmatter on the least-rewritten file, protected by an explicit negative constraint (update passes may change only `version`), doesn't depend on that judgment. Retires the `<!-- Source: URL | Version: N -->` comment convention; child nodes are listed in the manifest's `children`, not `memory.md`.
- **Tracking modes** — `ignore-all` / `track-shared` / `track-all` replace "always gitignored". The four observed usages collapse onto three gitignore configurations; the mode is asked once at bootstrap and recorded in the manifest. In `track-shared`, a PR that touches `learned.md` gets human review — an accept/edit/reject gate on every rule the agent taught itself. Security rule rewritten to match real practice: dev-only values already hardcoded in the repo may be cached; tracked files are published to everyone with repo access and reviewed like code.
- **Native tool memory disabled by setting** — `.agent/` is the sole durable memory. Tool-native memory is turned off via the tool's setting (Claude Code: `"autoMemoryEnabled": false` in `.claude/settings.json`, committed in tracked modes), not via instructions — prose overrides of built-in memory features are documented-unreliable. At retro, anything a tool auto-collected is harvested into `.agent/` and the silo deleted.
- **Evolved presets become the seeds** — `software-development.md` is replaced by a generalization of the two mature field instances, which independently converged on ~80% shared text; `domain-knowledge.md` and `academic-research.md` are rebuilt on the same skeleton: Kernel / Context loading / Scope control / domain section / Verification contract / Continuity contract / Self-learning / Git and commits / Project guardrails. Kernel slots 8–10 (session-log and memory contract, no narrative in `.agent/`, no secrets) are identical across all three presets so update-propagation diffs stay mechanical. `domain-knowledge.md` is a real harvest (both knowledge instances kept the five discipline rules nearly verbatim); `academic-research.md` has no field instance and ships at Medium confidence — its first bootstrapped node is the experiment.
- **The Kernel** — every preset opens with a contiguous section of ≤10 rules phrased as negative constraints, the rules that matter most. Per-instruction compliance decays multiplicatively with rule count and weaker models degrade linearly, so the always-loaded rule count decides whether a small model can run the system at all. A small-model entry point reads Kernel + Project guardrails only; frontier setups read the full preset, and the Kernel costs them nothing because it replaces scattered restatements. No model-tier machinery: one preset, one marked section, entry-point choice of how much to read.
- **Bootstrap-filled Project guardrails** — every preset ends with a `## Project guardrails` template the bootstrap must fill with exact commands: build, test, lint per area; package managers; generated-file regeneration; serial-execution constraints. "Run the tests" is not filled in; `dotnet test backend/X.sln --no-build` is. Small models fail judgment calls and pass mechanical ones — judgment stays with the human at bootstrap time, the session-time artifact is mechanical.
- **Catalogs routed out of memory.md** — both knowledge presets previously routed the source catalog into `memory.md` by instruction; followed as written, that marches memory.md through its own ~800-word grooming threshold by spec. Catalogs now live in `.agent/docs/`, always; memory.md holds durable working state only. The knowledge-tree levels rule (project facts in the project node, cross-project patterns to the root) survives the deleted Observation paragraphs in domain-knowledge's Knowledge discipline section.
- **First field-learned rule promoted to seed** — verify citations against the primary source before they leave the node; a stored summary is not a substitute. Learned by a field instance on 2026-05-17 after a report was mis-cited from a stale stored summary; now in both knowledge presets' verification contracts.
- **Canonical entry point replaces per-tool wiring examples** — the four slightly-different "read X then Y" examples (Cursor/Claude Code/Copilot/Codex) collapse into one tool-executed numbered bootstrap all entry points share; per-tool wiring is "put the template in the tool's filename", and entry points stay mirrored. The status check runs first, not last — step-skipping concentrates at the tail of numbered lists. The preset-read step is an inverted-default conditional: the safe floor is Kernel + Project guardrails, and only models on a per-project strong-model list opt up to the full preset, by matching the harness-stated model name against family substrings — a model that cannot resolve its name lands on the floor. Subagents dispatched with a task brief load rules, purpose, and their routed docs — memory stays with the orchestrator, which distills it into the brief — and never edit `.agent/` unless assigned. The update pass refreshes the strong-model list; the README prompt now names the bootstrap obligations (Kernel intact, guardrails filled, tracking mode asked, manifest stamped, canonical wiring).
- **File header contracts** — every canonical file opens with a 2–4-line comment that is its own format contract, written at bootstrap: the session-log entry template, memory.md's rewrite-in-place constraints, and learned.md's curation law (the proven field header, plus the routing rule). The write-time contract sits in the file being written instead of a preset read thousands of tokens earlier — for every tool, including ones that never read the preset. The session-log model tag is opt-up: appended only when the harness states the model, never guessed — a wrong tag silently corrupts measurement where a missing tag is visible and countable.

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
