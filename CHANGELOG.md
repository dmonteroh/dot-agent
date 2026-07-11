# Changelog

Design evolution of the `.agent/` operating model. Each version captures the reasoning, not just the diff.

---

## V6 (2026-07-11): Fork lineage + harvest

### Why

This fork (`dmonteroh/dot-agent`) diverges from upstream (`jlonardi/dot-agent`, through V5) on five months of field data from four production instances. The shipped files contradicted each other in small but costly ways, and the mature instances had independently evolved a better contract than the one that seeded them. V6 fixes the contradictions and ships what the field already built.

On top of the consistency pass, the harvest ships what use already built: node identity that survives rewrites, tracking modes matching how the four instances actually use git, a mechanical answer to tool-native memory, the canonical executable bootstrap the instances converged on, and — the largest piece — the evolved instance rules as the new preset seeds.

### What changed

- **Fork lineage:** the version line forks here. V6 is `dmonteroh/dot-agent`; upstream lineage is V1–V5. Source references and the bootstrap prompts point at this fork.
- **Dated log entries:** the session-log template is `- [YYYY-MM-DD] (tool) …` everywhere, matching the field format. The model is appended to the tag only when the harness states one, `(claude/sonnet)`, never guessed: a wrong tag silently corrupts measurement; a missing one is visible and countable.
- **One archive location:** `archive/session-log-archive.md`; a directory keeps future archives out of the node root.
- **Grooming thresholds replace anti-grooming advice:** "reorganizing costs more tokens than reading a longer file" was wrong in the field (one instance lost its pre-June history to an unarchived 5,834-word log). Replaced with numbers: session-log over ~80 entries or ~5,000 words → archive entries older than 30 days; memory.md over ~800 words → compact; learned.md over ~25 rules → merge near-duplicates.
- **Honesty pass on compliance claims:** "Can be enforced" becomes "Has a compliance mechanism"; the hooks move to an appendix labeled optional, Claude-Code-only, unused in the reference deployments. The trust contract is the primary compliance story.
- **Rules filename:** the rules file keeps the preset name (e.g. `software-development.md`); V5's `contract.md` rename never shipped in practice.
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
