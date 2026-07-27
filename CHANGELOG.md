# Changelog

Design evolution of the `.agent/` operating model. Each version captures the reasoning, not just the diff.

---

## V6.1 (2026-07-27): Context-engineering alignment

### Why

Anthropic's *The new rules of context engineering for Claude 5 generation models* (`tmp/new_context.md`) argues six shifts against the V6 operating model. Five are adopted: rules → judgement (scoped — cut generic rules, keep project-specific knowledge, no model tiers); examples → interfaces (`node.sh`, `log.sh`, `memory.sh`, `docs.sh`, enum-typed flags replace prose procedure); upfront → progressive disclosure (memory becomes an index + files, rare procedures move to skills); repeat-yourself → simple descriptions (already true under V6's "one rule, one home" — no work needed); simple specs → rich references (docs cite code paths, the quality bar becomes a rubric). The through-line: cut generic behavioral rules, keep project-specific knowledge, replace prose contracts with typed interfaces.

The sixth shift — manual memory → auto-memory — is rejected. The prior rationale ("prose overrides of built-in memory are unreliable") is replaced with four architectural reasons, stated as a blast-radius stance, not a claim that the vendor feature doesn't work: `~` is ephemeral in devcontainers, so home-directory memory dies with the container; repo knowledge has to travel through git with the repo, not sit beside it in a tool's private store; solo projects still want their memory versioned; and agents should not write outside the project directory, whatever a tool's default. `.agent/` stays the sole durable store either way; the harvest step (fold a tool-collected silo into `.agent/`) is now explicitly a repair path for a node where the setting wasn't applied, not a routine part of retro.

### What changed

- **Retention test, written into every preset's preamble:** "would a competent engineer joining this project already do this? Cut it. Is it specific to this project, this operating model, or a mistake this project actually made? Keep it at full strength." Applied to all three presets' Kernel and body; the Kernel is subject to it too (a ceiling, not a quota).
- **Cut list — the restoration path if a trim regresses in the field:**
  - `software-development.md`: Kernel item 10's `; push back on flawed premises` clause (item now reads "Do not fabricate; say when uncertain."); Scope control's `Do not give task time estimates unless explicitly asked.`; Scope control's `Accuracy over agreement. Update views only on evidence.`; Implementation's `Follow existing style, structure, patterns, helper APIs, and ownership boundaries.`; Implementation's `Prefer clear names and structure over comments; comment only non-obvious logic.`; Git and commits' `Commit messages: technical, concise, what and why.`
  - `academic-research.md` (trimmed conservatively — no field instance, Medium confidence): Scope control's `Do not give task time estimates unless explicitly asked.`; Scope control's `Accuracy over agreement. Update views only on evidence; push back on flawed premises.`
  - `domain-knowledge.md` (trimmed most conservatively — a real field harvest): the same two Scope control lines as `academic-research.md`.
  - Note for an agent restoring one of these: V6's premise that Kernel slots 8–10 are identical across presets did not literally hold in the shipped files (floors already differed, software-dev 7–10 vs the other two 8–10, with wording drift in the no-narrative/no-secrets lines); the trim did not restructure to fix that, it just removed "push back on flawed premises" everywhere it appeared — Kernel-10 in software-development, Scope control in the other two — so no preset states that clause anywhere post-6.1.
- **Strong-model list deleted (a deliberate narrowing, not an oversight):** the canonical entry point's step 3 (read `contract.md`) is now unconditional — no per-project list of strong-model families to match against, none to refresh at update time. The cut line is generic-vs-project-specific, not strong-vs-weak model; the same (trimmed) rules apply to every model. This narrows the target to strong models: V6 explicitly served both tiers, and a small model now reads the full contract every session with no reduced floor. Deleting the list also removes the Kernel's original job (the small-model floor); the Kernel keeps a different one — a priority-ordering device, the rules that matter most stated first, and the section update-propagation diffs against when a node's shared slots move.
- **Memory split into an index plus one-fact-per-file:** `memory.md` becomes an index (`- [Title](memory/slug.md) — hook`, no facts inline); `memory/<slug>.md` holds one durable fact with `date`/`scope` frontmatter. New header contracts for both; the fact-file contract states a granularity test, not just a word ceiling: one decision, one preference, one constraint — if two halves would be superseded at different times, they're two files. `status.sh` gained a per-fact-file `MEMORY_MAX_WORDS` (was the whole-file ceiling), a new `MEMORY_MAX_ENTRIES` index-line ceiling, and `REPAIR:` drift checks in both directions (an index line whose file is missing; a file with no index line). `track-shared` inherits the split's privacy for free — the existing allowlist gitignore already leaves any new, un-negated directory ignored by default, so `memory/` stays private the same way `memory.md` always did; this is now stated explicitly rather than left to be re-derived from gitignore semantics.
- **Header "Format:" prefix, an implementation-time fix:** the `memory.md` and `session-log.md` header contracts' example lines gained a literal `Format:` prefix. Both examples had sat at column 0 inside the header comment, which `status.sh`'s line-anchored entry-counting and drift checks were matching against as if they were real entries; the prefix moves the example text off that pattern.
- **Scripted interfaces, with decision 6 governing all of them:** `scripts/node.sh init --preset <name> --mode <mode>` creates the skeleton, adapts the preset into `rules/contract.md`, stamps the manifest, writes the tracking-mode's gitignore, and copies `status.sh`/`log.sh`/`memory.sh`/`docs.sh` into the node. `scripts/log.sh` stamps the date and enforces the summary word ceiling. `scripts/memory.sh new` and `scripts/docs.sh new` scaffold a fact file + index line, or an area doc + routing row, as one write each — making the two-place drift impossible rather than only detecting it. `scripts/test.sh` smoke-tests all of the above (init × 3 presets × 3 modes, an update run against a V6 fixture, idempotency). None of this makes bash a hard dependency: decision 6 keeps header contracts the format authority, so an agent that cannot run a script follows the header contract by hand and produces the same artifact; no file format exists only inside a script.
- **`node.sh update`'s mechanical boundary is precise, on purpose:** splitting an 800-word memory blob into discrete facts is judgement, not mechanics, so the script only reaches a drift-clean baseline — it creates `memory/`, moves the prior `memory.md` body verbatim to `memory/legacy.md`, and writes an index with one line pointing at it — then bumps `version` (nothing else in the frontmatter changes) and refreshes the four copied scripts. `status.sh` flags `memory/legacy.md` with a `GROOM:` line so the fact split is prompted by the load path in a normal session, not remembered. Re-running `update` on an already-current node is a no-op.
- **README prompts shrink:** the three bootstrap/update prompts drop every step `node.sh init`/`update` now executes (skeleton, gitignore, manifest stamp, script copies, version comparison, backup); what remains is judgement — explore and confirm findings, choose the preset, fill Project guardrails with exact commands, reconcile conflicts, report.
- **Docs cite code, not paraphrase:** the preset Implementation/Continuity sections and the operating model's `docs/` file-purpose row now say an area doc cites the code or test path that pins a behavior instead of restating it in prose; prose stays for the *why*. A path is checkable in a way prose isn't (a follow-up `status.sh` check for a missing cited path is noted as a future mechanism, not built here).
- **Quality bar becomes a loadable rubric:** the Verification contract's checklist was extracted into each preset's `## Quality bar` section, split at bootstrap into `rules/quality-bar.md`. The load boundary is deliberate: `contract.md` keeps the always-loaded behavioral rules of verification (run the commands, classify failures, report honestly — every session, for every model); `quality-bar.md` holds the judgement criteria and loads on demand (verifier subagents always, the main session only for substantial work). An orchestrator may dispatch a read-only verifier armed with the rubric, consistent with the existing subagent write ban. Implementation-time renaming: "quality bar" now names only this rubric file; where the presets meant the check commands (build/test/lint/typecheck), the text now says "verification suite," freeing "quality bar" to name the new file unambiguously.
- **Skills package added; Claude Code hooks realigned or marked unsupported:** `tools/skills/` ships `groom/`, `bootstrap/`, `update/`, `retro/` as optional, additive Claude Code skills — the preset keeps each binding one-liner, the skill only expands the *how*, per decision 5. `pre-work.py` and `retro.py` hold up unchanged. `self-maintenance.py` is now marked **unsupported** and unwired in `settings-example.json`: it blocked Stop on a `memory.md` checksum change, already wrong under V6 (conditional memory writes, single orchestrator log writer) and wronger now that `memory.md` is an index, not a fact store — no mechanical replacement exists because "did durable facts change this session" is a judgement call a file diff can't make. `correctness.py` needed no code change, only a docs correction: its re-read check only ever required *a* re-read of an edited path, full or partial; it never enforced full-file re-reads, though the README and appendix previously described it that way.
- **Version scheme supports a minor:** the manifest's `version` is now a quoted string (`version: "6.1"`) instead of a bare number — unquoted `6.1` parses as a YAML float, and `6.10` vs `6.1` would become ambiguous at the tenth minor. `status.sh` and `node.sh` compare versions with `sort -V` semantics. The operating model's own header version line is bumped to match.
- **Comparison table:** the "Agent writes back" row is gone (Claude Code's own auto-memory made it false for tool-specific files). A candidate replacement, "reviewable by the team," was rejected — memory is gitignored by default even in `track-shared`, so it isn't true. The rows that shipped instead: "Agent-maintained memory lives in the repo" (No / No / **Yes**), and "Memory across sessions" downgraded to Partially for tool-specific files rather than No. `README.md` and `operating-model.md` carry the identical table.
- **Six decisions carried over from the proposal, recorded so they aren't re-litigated:** (1) `autoMemoryEnabled: false` stays, on the four architectural grounds above. (2) No "Lite" `contract.md` — a second file is a second home for the same rule and would drift; the one file gets shorter for every model instead. (3) No strong-model list — the cut line is generic-vs-project-specific, not strong-vs-weak model. (4) `learned.md` stays a single file — it's the artifact that passes PR review in `track-shared`; many small files aren't reviewable the same way. (5) Skills are additive, not primary — they ship in `tools/`, optional, the same status as the hooks; tool-neutrality is the product premise. (6) Scripts are the preferred interface, not the required one — header contracts remain the format authority, and no file format may exist only inside a script.
- **Migration checklist for an existing V6 node:** run `scripts/node.sh update` (backs up untracked nodes first, reaches the `memory/` + `legacy.md` + index baseline, refreshes the four copied scripts, bumps `version`); then, in a normal session, split `memory/legacy.md` into fact files (the `GROOM:` flag is the reminder); re-derive the entry points from the canonical template — there is no strong-model list to check for or refresh, step 3 is unconditional; extract the preset's `## Quality bar` section into `rules/quality-bar.md` by hand, since `node.sh update` does not touch `rules/contract.md`; and reconcile `rules/contract.md` itself against the current preset, because the B-series trim changed all three presets' text — the update script leaves that reconciliation, and the cut list above is what to check the node's existing contract against.

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
