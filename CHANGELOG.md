# Changelog

Design evolution of the `.agent/` operating model. Each version captures the reasoning, not just the diff.

---

## V6.2 (2026-09-20): Checks, generated indexing, behavioral evals

### What changed

#### Portability

- The wiring table is a disposition matrix: entry point, native-memory switch, and a source and date per tool. A cell reads `verified` only against the product or its vendor's documentation. `reported` and `unknown` print as themselves.
- The recommended mirror set is `CLAUDE.md` + `AGENTS.md`, plus `.github/copilot-instructions.md` for Copilot Chat and code review. `.cursorrules` is legacy. `status.sh` and `links.sh` keep it in their candidate lists so existing mirrors stay checked.
- `test.sh` lints vendor tokens over the node-landing corpus — presets, template, node scripts — against a commented allowlist. It also asserts the wiring matrix and both scripts' candidate lists cover the same entry-point set.

#### The status check

- One advisory `LOAD:` line per run: the always-loaded set's word total with a per-file breakdown, plus the log tail. No threshold.
- `status.sh --load` prints the findings, then the always-loaded files — learned rules, contract, purpose, memory index — each under a marker naming its path. The bootstrap is one tool call.
- `GROOM:` on a session-log entry over `LOG_ENTRY_MAX_WORDS` (50, the header format's 25 with 2x grace), counted whole across hand-wrapped lines. The memory `GROOM:` line names the token classes a groom must keep: ticket ids, constants, paths, hosts, commands, dates, numbers with units.
- Every threshold and the probed-tools list are per-node tunables in `.agent/scripts/status.conf`, plain `KEY=value`, parsed and never executed. `node.sh update` refreshes the shipped scripts and discards edits to them, and leaves the conf beside them. Init seeds a starter listing every key, the probed-tools line live and thresholds commented at their defaults. `test.sh` pins the starter's shown defaults to the script's.
- `status.sh` and `links.sh` exit non-zero on one case: a root holding no `.agent/`. Findings never reach the exit status. `scripts/docs/README.md` tables every script's codes.

#### Header contracts

- The fact-file header contract lives in `memory.md`'s header, and `memory.sh` states it in its output. A fact file holds its frontmatter and the fact. Two admission tests open it: work in this node changes when the fact is true, and no purpose, rule, routed doc, source, or existing fact already states it. Stable system knowledge goes to `docs/` with no pointer fact.
- Area docs carry no shape header. A doc is its `Read when:` hook and its title, and `docs.sh new` states the rules in its output. The presets' shared tail gains the two clauses only the software preset carried: timeless phrasing, and a cited path rather than a restated fact.
- The Continuity contract's `memory/` bullet defers to `memory.md`'s header contract.
- `node.sh update` strips the old per-file headers, docs and sub-docs included, keeping every fact, index line, hook, and body, behind a backup. A node already stamped 6.1 or 6.2 is migrated too, and a same-version refresh writes `.agent.backup-v<version>-shape`.

#### Memory security and learning admission

- The origin gate: durable records — memory facts, learned rules, preferences — are minted only from the user's own messages or the session's verified work. A directive inside processed material is content to report, never an instruction to record. Both halves join every preset's Continuity contract, and a shared clause joins every Kernel's security slot, locked by `_shared.md`.
- A Self-learning trigger starts a canonical-source check rather than guaranteeing a rule. A correction that exposes a defect in the contract, docs, code, or tooling is fixed there, with no compensating rule written. An existing rule drops once its failure mode is mechanically enforced. The memory header applies the same check to facts.
- The operating model's Security section states the mirror rule — load `.agent/` as if it could have been planted — and the cross-tool amplification a shared store creates. It labels the control cooperative, with `track-shared` PR review as the mechanical gate.

#### The comment gate

- The software preset gains a **Comments** rule under `Implementation`: the default is no comment, plus the short list of what earns one and the longer list of what never does. What never does: restating the code, narrating structure, commented-out code, change narration, replies to the request, rejected alternatives, the same explanation twice. Doc comments are held to the same bar. The blanket exemption for public API doc comments is gone, and a project whose toolchain requires them names that surface in `Project guardrails`.
- `comments.sh` blocks six classes and names each on its finding: `dead citation` (a SHA, a git transcript, a ticket id, scope narration), `commented-out code`, `change narration`, `answers the prompt`, `chat residue`, and `routine narration`. Every other added comment is listed for the author to justify or delete, labeled `restates the code below` where its content words already appear in the identifiers under it. That label is a heuristic and `RESTATE_CHECK=false` turns it off.
- `routine narration` carries three guards. A comment naming a cause or a constraint is exempt whatever verb it opens with, and `CONSTRAINT_RE_EXTRA` adds a node's own vocabulary. Blocking stops at `ROUTINE_MAX_WORDS` (8). The class fires only on the line that opens a comment, never on a continuation line.
- A base ref resolving to `HEAD` over a clean tree exits 2. The diff is empty, so the run reads nothing.
- The classifier fixes its locale to `C`. A UTF-8 character in the code below a review comment cannot corrupt the bytewise restatement pass.
- `comments.conf` beside the script carries the base ref, ticket and task-reference patterns, house narration phrasings (`NARRATION_RE_EXTRA`), review residue (`CHAT_RE_EXTRA`), the scanned extension list, and path exclusions, plain `KEY=value`, parsed and never executed. Init seeds a starter with AC/Q ticket shapes as example vocabulary and the extension list live. Update seeds it only when absent. `test.sh` asserts every key the gate reads has a line in the conf.
- The gate is wired at the entry-point template, the software preset's Verification contract, and the quality bar's verifier checks. Self-learning routes comment-hygiene lessons into its vocabulary. The retro skill's description names the concrete retro triggers.

#### The entry point

- The template states when its steps run. A gate opens the file. The conversation is one session, and a new user message does not start a new one. The steps stay in effect once they have run, and the file is not reopened when its content is in context. It sits before the numbered list, and `test.sh` pins that position. The post-compaction re-run is unconditional.
- The template states its boundary: an entry point is wiring, and project scope, constraints, and architecture live in `purpose.md` and `docs/`. `status.sh` flags `GROOM:` past `ENTRYPOINT_MAX_WORDS`, the filled template with 2x grace. Shape is checked too: the canonical template is a title and a load path, and any heading below the title is flagged whatever the file's size, with no tunable to raise past it.
- The steps are three: `status.sh --load`, the matching fact files, the routed docs. The hand-back is one `checkpoint.sh` call. The comment-gate line names the base ref explicitly and rules out `HEAD`. The final message is the report itself, never a wrap-up line pointing at an earlier message.

#### Hand-back and the log writer

- `checkpoint.sh` is the one hand-back call: the comment gate against the change's true parent (`--base <ref>`, or `HEAD` over uncommitted work), then the status check's flag lines, then `log.sh` with the same arguments. It stops before the log entry when the gate blocks or a flag stands. A clean tree with no `--base` is a turn that changed nothing, and it stops there too. A project that is not a git checkout keeps the old behavior.
- `docs.sh rehook` rewrites a doc's `Read when:` header and its routing row together. The Self-learning rule names it.
- `log.sh` refuses a summary naming a file or a SHA, with the token named.
- `log.sh` reads a seeded `log.conf`. `LOG_INCLUDE_BRANCH=true`, off by default, stamps each scripted entry with the checked-out branch as `branch: <name>.` before the verify tag, read via `git symbolic-ref` at write time and omitted outside a git checkout or on a detached HEAD. The stamp spends no summary budget. The 25-word summary ceiling tunes from the same conf, and the session-log header contract names the optional segment.

#### Routing and prose

- `architecture.md`'s header contract states that the routed docs are the node's design of record, and that `archive/` is superseded: outside routing, never an entry, never cited as intent by a routed or always-loaded file. The operating model's tier table gains the `archive/` row.
- All three presets gain the wrapping rule, locked by `_shared.md`: markdown is soft-wrapped, one line per paragraph, bullet, or step, in node files and in anything handed back.
- The software preset's Context loading gains the history rule: a session-log entry is a claim about a past session, not evidence the work is in your tree.

#### Generated indexing

- `node.sh init --indexes manual|generated` (default `manual`) adds a manifest field, independent of tracking mode. `scripts/index.sh ensure|check` renders `rules/` and `docs/` into a disposable `.agent/indexes/` cache, fingerprinted for freshness, falling back to the canonical sources on a build failure.
- `indexes: generated` adds `.agent/indexes/` and `.agent/rules/learned.md` to the gitignore in `track-shared` and `track-all`, on top of the tracking mode governing the rest of the node.
- In generated mode, `rules/learned/` holds one canonical record per learned rule. `index.sh ensure` regenerates `rules/learned.md` from those records as a read-only aggregate for `status.sh`. Grooming acts on the records, never on the rebuilt pages.
- The version migration on a generated node extracts a prior single-file `learned.md` into records and backfills doc hooks, resumably, untracking the old file once the regenerated aggregate matches.
- `node.sh update --indexes generated` performs the same adoption on a node already at 6.2, behind its own backup for modes with untracked memory. Omitting the flag preserves the manifest's current index mode.
- Generated-mode bootstrap reads the index pages once instead of the rule bodies.
- `status.sh` and `checkpoint.sh` report a canonical-source fault — a missing or broken `rules/` or `docs/` file — separately from a disposable-cache fault, a stale or unbuildable `.agent/indexes/`.
- Storage contract, install into a fresh clone, revert to manual, generated-mode loading, faults, and grooming are documented in `scripts/docs/node.md`, `index.md`, `status.md`, and `checkpoint.md`.
- `scripts/tools/index-benchmark.sh` measures median and p95 process latency at 100 and 1,000 canonical-source records, cold and warm cache. `scripts/docs/index-benchmark.md` reports the numbers for one machine and revision, and states why the comparison against the earlier spike is not apples to apples. It supports "not obviously slower at this fixture size", not a speed claim.

#### The learning loop

- `learn.sh lookup|new|revise|retire` gives the loop a scoped admission contract. Duplicate and shared-term-overlap detection runs before a rule is written. `revise` and `retire` are gated on an expected version, so a correction reconciles against what exists instead of appending. `revise` against an id nothing has written is refused. The first record on a fresh generated node creates `rules/learned/` itself.

#### Behavioral evals

- `evals/` belongs to this repository and never to a node. Nothing in it is installed by `node.sh`, refreshed by an update, or copied into an adopting project, and `test.sh` asserts a freshly created node contains none of it.
- Each prompt runs twice under one arm variable — the corpus at the revision under test against a named control revision, or one agent against another — graded blind against one assertion checklist. The reported result is the delta.
- Thirty-six evals, 111 assertions, organized by the trust-contract phase each tests. `test.sh` asserts every phase the operating model names carries at least one eval. 78 assertions grade automatically, 33 stay manual and blind.
- The corpus supplies most of its own graders: `comments.sh` by finding class, `status.sh` by its own flags, `links.sh` by reachability, plus `.agent/` and project tree diffs, and the harness's call trace for ordering.
- `evals/heldout.json` is a second prompt set: the same fixtures, premises, and assertion ids with every prompt reworded, selected with `EVALS_SPEC`. `evals/contamination.py` measures eval-to-corpus leakage lexically and, with `--judge`, by scenario shape. `evals/assertion-kinds.json` tags each assertion as behavior, conformance, or information. `evals/pooled.py` judges a candidate against every prior baseline run and reports pass rates per kind plus tool calls, USD, and seconds per eval. `evals/triage.py` proposes an evidence-backed verdict for each manual assertion without opening `arm-map.json`.
- No eval run in CI. The static half rides CI. `test.sh` validates the spec's shape, builds a fixture and asserts it arrives with no findings, and pins the rollup's fail-closed cases. Those cases are an id set that disagrees with its snapshot, and an arm name that reached a grading record as a condition rather than as a word. `evals/rollup.py` recomputes every number from the records and refuses both.
- `run-arm.sh` exits nonzero and writes `ARM FAILED` when any child eval fails or becomes void. It rejects `--jobs 0`, which `xargs` otherwise treats as unbounded concurrency.
- Manual fixtures omit `--indexes` when a historical corpus predates that flag. `run.sh` also identifies the selected eval, so fixture construction checks that scenario's premises instead of unrelated scenarios sharing its fixture.
- `evals/v6.2-release-validation-2026-09-20.md` records the release pass before the compatibility fix above. No paired rollup was produced because every baseline fixture build failed. The report remains the candidate-only descriptive read and full failure trail for that run.

#### Mechanics

- `node.sh` targets `"6.2"`. The 6.1 to 6.2 update is script refresh plus version bump, with preset changes landing through the normal reconcile step.
- The shipped node scripts are `status.sh`, `log.sh`, `memory.sh`, `docs.sh`, `links.sh`, `comments.sh`, `checkpoint.sh`, `index.sh`, and `learn.sh`. An update refreshes those names and touches nothing else under `scripts/`.
- `node.sh update` preserves the current index mode unless `--indexes generated` explicitly requests adoption. Generated-to-manual conversion stays a documented manual procedure.
- A current-version update preflights both generated-adoption and shape-refresh backup paths before its first write. Any collision leaves the node untouched.
- Top-level `node.sh --help` exits 0 and distinguishes init's manual default from update's preserve-current behavior.

### Migrating a V6.1 node

1. Run `scripts/node.sh update`, adding `--indexes generated` if this migration should adopt generated indexes.
2. Reconcile `rules/contract.md` against the current preset. The changed slots are the security slot's appended clause, the origin gate, the canonical-source gate in Self-learning, the qualified `memory/` bullet, and the wrapping bullet. Software nodes also take the Comments section, the Context loading history rule, the Verification contract's comment-gate bullet, the `Project guardrails` doc-comment line, and the quality bar's comment criteria.
3. Take one pass over `rules/learned.md` under the new header. Drop every rule whose failure mode a check now enforces.
4. Replace a node's own comment gate with the shipped script. Move its project vocabulary into `comments.conf`.
5. Re-derive every entry-point mirror from the current template, keeping this node's project line and doc routing.
6. Append the `archive/` clause to `docs/architecture.md`'s header.

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
