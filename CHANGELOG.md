# Changelog

Design evolution of the `.agent/` operating model. Each version captures the reasoning, not just the diff.

---

## V6.1 (2026-07-27): Context-engineering alignment

### Why

Several changes apply the findings of Anthropic's *The new rules of context engineering for Claude 5 generation models*: trim generic rules, keep project-specific knowledge, replace prose procedure with typed script interfaces, move rare detail behind progressive disclosure. Its auto-memory recommendation is rejected on architectural grounds: home-directory memory dies with a devcontainer, repo knowledge travels through git, solo projects want memory versioned, and agents should not write outside the project directory. A post-review pass adapts three workflow patterns from *A field guide to Claude Fable: Finding your unknowns* and recalibrates every threshold against the archived field instances.

### What changed

- **Presets trimmed:** every preset now opens with a retention test (keep only what a competent engineer wouldn't already do, or what is specific to this project, this operating model, or a real past mistake); generic lines are cut from all three, pre-trim text in git history. The strong-model list is deleted: the cut line is generic versus project-specific, not strong versus weak model, so the contract-read step is unconditional and the Kernel stays as a priority-ordering device.
- **Memory split:** `memory.md` is an index, one line per fact file, appended newest-last (reorder only when grooming); each durable fact lives in `memory/<slug>.md` with `date`/`scope` frontmatter and a granularity test: facts superseded at different times are separate files. The index loads every session; fact files open when their hook matches the task. `status.sh` flags a fact file over ~300 body words (the largest field fact is ~130), an index past ~100 entries, and index/file drift: review triggers only, no write refused for size. Index grooming archives retired fact files rather than deleting them, since outside `track-all` git holds no copy of `memory/`; `track-shared` keeps it private via the existing allowlist.
- **Scripted interfaces:** `node.sh init` builds the skeleton, manifest, gitignore, and script copies; `node.sh update` reaches the mechanical baseline (memory body moved verbatim to `memory/legacy.md`, scripts refreshed, `version` bumped, every node with untracked memory backed up first, untouched if the backup fails) and leaves the fact split to a normal session via `GROOM:`. `memory.sh new` and `docs.sh new` make each two-place write one operation; `log.sh` stamps and validates the one-line entry; `test.sh` smoke-tests all of it. Header contracts stay the format authority, and the README prompts drop every step the scripts execute.
- **Quality bar extracted:** each preset's verification checklist became a `## Quality bar` rubric, split into `rules/quality-bar.md` at bootstrap and loaded on demand (verifier subagents always, the main session for substantial work); `contract.md` keeps the always-loaded rules. Area docs cite the code or test path that pins a behavior; prose stays for the why.
- **Skills added, hooks removed:** `tools/skills/` ships `groom/` and `retro/` as optional Claude Code skills, installed at `.agent/skills/` and symlinked into each tool's skills directory; a skill only expands the *how* of a procedure the contract already names, and only in-session procedures qualify (bootstrap and update are README-prompt ceremonies that run with the operating model in context). The V4/V5 compliance hooks are deleted: whether durable facts changed in a session is a judgement a file diff cannot make, and the field had demoted completion-time gates. Compliance is the trust contract plus `status.sh`; `tools/claude-code/` keeps only `settings-example.json`. The V5-era `verify-agent-context.sh` goes too: nothing distributes it (`node.sh` never copies it into nodes), and its `--fix` wrote the placeholder entries V6 already called phantom-compliance bait.
- **Unknowns pass (from the field guide):** the root prompt interviews one question at a time, prioritizing questions whose answers change what gets written; the project prompt's findings summary states what could not be inferred; a mid-task deviation from an agreed plan joins the retro triggers in all three presets. Quizzes, pitch docs, and prototype passes stay operator workflow. Root entry points write absolute `~/.agent/` paths, since sessions run from project directories.
- **Thresholds recalibrated; grooming is size-based, not time-based:** V6's 80-entry/30-day pair could never clear at the field's real pace (up to 23 entries a day, 141 per 30 days). The trigger is now ~120 entries (a heavy week) or the ~5,000-word incident ceiling, and grooming archives the oldest entries down to about half the threshold; dates inside entries are context, not grooming keys. The bootstrap tail widens to 25 lines to cover the busiest observed day, and `learned.md`'s review point rises from 25 to 60 rules (the two healthiest instances run 31 and 44, both over the old number). Area docs gain a trigger of their own, ~2,000 body words: set just under the smaller of the two field docs (2,200 and 3,200 words) whose density forced a manual restructuring pass, and consistent with the 2,000–8,000-token per-load band ICM publishes (arXiv 2603.16021). The fix is structural: tighten in place, or split into `docs/<area>/` sub-docs behind the same single routing table (`status.sh` and `docs.sh` walk one sublevel).
- **Routing entries carry a section list, and both halves are checked.** `architecture.md` moves from one table row per doc to a per-doc entry with two fields. `Read when:` is precision — skip the doc when the hook doesn't match. `Sections:` is recall — find the doc holding a topic its hook never names, the case a hook cannot cover because it is written when the doc is new and rarely revisited. In the field instance one doc's hook named 6 topics for 13 sections, hiding seven; the same instance maintained hand-written section lists across 12 docs for a month with every heading still listed, so the convention is affordable. `status.sh` now flags all three ways a doc and its entry disagree: doc missing from the index, hook drifted on one side, or a `## ` heading absent from `Sections:`. The section check is one-directional — an entry may say more than its heading, never less — because a hand-written gloss routes better than a bare title.
- **Catalogs: docs that load for a whole class of work.** `domain-knowledge` and `academic-research` already treated a catalog as first-class (Kernel rule, guardrail slot, quality-bar criterion); `software-development` had no equivalent, and duplication is most expensive there. It now carries the reuse rule (check the area catalog before adding an endpoint, component, service, module, migration, or worker; extend rather than build a second), the same-change catalog-entry obligation, a quality-bar criterion, and a `Catalogs:` guardrail slot. Routing gains an axis with it: reads scale by task *size*, but a catalog routes by task *kind* — anything that creates something new reads it first, however small. Files split along load-condition boundaries, not topic boundaries, which is why the catalog is its own doc rather than a section of the area doc: merged, one of the two gets the wrong load condition. The failure this prevents — a second copy of an existing building block — passes tests, passes lint, and survives review.
- **Area docs get the header contract every other canonical file already had,** written by `docs.sh new`: agent-facing shape (facts as tables or one-fact-per-line bullets, prose only for the *why*), cited code paths, timeless phrasing, `## Gotchas` for area traps. Docs were the largest, fastest-growing file type and the only one whose writing rules reached the agent solely as a repair instruction behind a size flag, so they were born prose-shaped and restructured by hand later. The contract carries the invariant the repair path was missing — restructuring changes shape, never content; no tightening or splitting pass may drop a name, value, command, path, or gotcha — and the presets, the quality-bar rubric, the `GROOM:` line, and the groom skill's anchor check each state it at their own layer, so a size trigger can never be cleared by deletion.
- **Version scheme:** the manifest's `version` is a quoted string (bare 6.1 parses as a YAML float and collides with 6.10), compared with `sort -V` semantics. Comparison-table rows updated: "Agent-maintained memory lives in the repo"; "Memory across sessions" is Partially for tool-specific files.
- **Decisions recorded so they aren't re-litigated:** auto-memory stays disabled; no "Lite" contract (a second file is a second home that drifts); no strong-model list; `learned.md` stays one file (the artifact that passes PR review in `track-shared`); skills are additive, not primary; scripts are preferred, not required; and provenance over rationalization: every constant states its source where it lives, and an unjustified one found later is replaced, not defended. The last rule is now in all three presets; this release's own invented limits are the mistake it distills.
- **Grooming is delegable:** `GROOM:` flags may be handed to one subagent explicitly assigned to write only the flagged files — the scripts and groom skill make the procedure mechanical enough for a small model — and the dispatching session re-runs `status.sh` to confirm the flags cleared. `REPAIR:` stays a main-session conversation. A session bootstrapped for a large task no longer spends its own context on housekeeping.
- **Entry-point template extracted:** the canonical template ships as `templates/entry-point.md`; the operating model and README prompts point at the one copy instead of embedding a second.
- **Migration for a V6 node:** run `scripts/node.sh update`; then, in a normal session, split `memory/legacy.md` into fact files when `GROOM:` flags it, re-derive the entry points from the canonical template, extract the preset's `## Quality bar` into `rules/quality-bar.md` by hand, and reconcile `rules/contract.md` against the current preset, removing any `verify-agent-context.sh` reference and the node's local copy. Flag conflicts for the operator instead of overwriting.

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
