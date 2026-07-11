# Changelog

Design evolution of the `.agent/` operating model. Each version captures the reasoning, not just the diff.

---

## V6 — 2026-07-11 — Fork lineage + consistency pass

### Why

This fork (`dmonteroh/dot-agent`) diverges from upstream (`jlonardi/dot-agent`, through V5) based on five months of field data from four production instances. Before the larger V6 harvest changes land, the shipped files contradicted each other in small but costly ways: the spec's own session-log example failed the verify script's date check, the presets and the field named different archive locations, the housekeeping advice argued against the grooming the field proved necessary, and the enforcement claims oversold hooks the reference deployments don't run.

### What changed

- **Fork lineage** — the version line forks here: this is V6 of `dmonteroh/dot-agent`; upstream lineage is V1–V5 (`jlonardi/dot-agent`). Source references and the bootstrap prompt now point at this fork.
- **Dated log entries** — the session-log entry template is `- [YYYY-MM-DD] (tool) …` everywhere, matching what the verify script checks and what the field instances converged on. The model is appended to the tool tag only when the harness states one — `(claude/sonnet)` — never guessed.
- **One archive location** — `archive/session-log-archive.md`. A directory keeps future archives (memory snapshots, superseded docs) out of the node root. Presets previously said `.agent/session-log-archive.md`.
- **Grooming thresholds replace anti-grooming advice** — "a few hundred lines is negligible / reorganizing costs more tokens than reading a longer file" is deleted from the operating model and all three presets. It was wrong in the field: one instance lost its pre-June history to an unarchived 5,834-word log; another hit 15,303 words. Replaced with numbers: session-log over ~80 entries or ~5,000 words → archive entries older than 30 days; memory.md over ~800 words → compact; learned.md over ~25 rules → merge near-duplicates.
- **Honesty pass on compliance claims** — the comparison-table row "Can be enforced" is now "Has a compliance mechanism"; the enforcement-mechanisms section moved to an appendix labeled optional, Claude-Code-only, unused in the reference deployments. The trust contract is the primary compliance story — it is the one with months of field evidence.
- **Rules filename** — the human rules file keeps the preset name (e.g. `software-development.md`); that is what exists in every field instance. V5's `contract.md` rename never shipped in practice.

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
