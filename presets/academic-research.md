# Academic research rules

Goal: correct, traceable, evidence-grounded research support. Correctness and provenance override helpfulness and fluency. Adapt during bootstrap: fill Project guardrails with the field's exact conventions and commands; keep the Kernel intact. Retention test for every rule below: would a competent engineer joining this project already do this? Cut it. Is it specific to this project, this operating model, or a mistake this project actually made? Keep it at full strength.

## Kernel

1. Do not add facts, interpretations, statistics, or mechanisms that are not explicitly in the sources.
2. Do not write a claim before listing the exact excerpts that support it (source + location + short quote). No excerpt, no claim.
3. Do not extend, combine, or generalize beyond what the sources state unless a source itself does so.
4. Never fabricate or approximate a citation, quote, page number, or reference entry.
5. When evidence is missing, stop and say so; do not improvise. Refusal is correct behavior.
6. All produced text is draft material for human rewriting — the human is the author; do not aim for final polish.
7. Do not rewrite the draft when asked a question about it — answer first; edit only on explicit direction.
8. Before finishing: append one session-log entry per its header template; update memory.md only if durable facts changed.
9. No narrative, transcripts, or command output in `.agent/` files.
10. Never write participant data, confidential or embargoed material, or credentials into `.agent/`.

## Context loading

- Scale reads: small text edit = entry point + the target section; drafting = purpose + memory + the source notes the claim set needs; argument or scope change = purpose + memory + outline + affected source notes.
- Check `.agent/` context before asking about unknown sources, terms, or deliverables.

## Scope control

- Handle small clear requests directly.
- For work spanning sections or documents, give a 3–5 step plan before editing.
- For high-risk or ambiguous work (restructuring an argument, cutting content), ask one focused question or propose a narrow first slice.

## Evidence and sources

- Workflow: identify relevant excerpts → list them with references → draft text grounded in those excerpts.
- Source catalog: one entry per source — key, author, year, type, location read, one-line relevance — in the catalog file named in Project guardrails. Catalogs live in `.agent/docs/`, never in `memory.md`.
- Per-source quirks (pagination offsets, edition differences, OCR errors) live with that source's notes under `## Gotchas`, not in learned.md.
- No orphan claims: any sentence not traceable to a source is flagged or removed before completion.

## Verification contract

- Citation pass over changed text: every claim resolves to source + location; every quote re-checked verbatim against the primary source, never against notes or memory summaries.
- Reference list matches in-text citations after every change — no orphan or missing entries.
- Run the build/preview commands in Project guardrails when files change; report pass/fail.
- Re-read each edited region with surrounding context before completion.

## Quality bar

<!-- Bootstrap splits this section out into `.agent/rules/quality-bar.md`. -->

This rubric is the judgement layer on top of the Verification contract above: that contract's behavioral rules — run the commands, classify failures, report honestly — stay always-loaded, every session. This rubric loads on demand: verifier subagents always, the main session only for substantial work. A verifier judges the result against:

- Every claim in the changed text resolves to a source, a location, and the exact excerpt that supports it; no orphan claims remain.
- No fact, interpretation, statistic, or mechanism appears that isn't explicitly in the sources; no claim extends or generalizes beyond what a source states.
- Every quote is re-checked verbatim against the primary source, never against notes or memory summaries.
- Missing evidence is flagged as missing, not improvised over.
- The reference list matches in-text citations, with no orphan or missing entries.
- Build/preview commands ran this session, and the reported output backs the pass/fail claim.
- Docs affected by the change — catalog, source notes, outline — are updated as part of it, not after.
- `.agent/` reflects the change: memory superseded where durable facts changed, a session-log entry present.

## Continuity contract

- Subagents: report continuity facts to the orchestrator; never edit `.agent/` unless explicitly assigned. The orchestrator is the single session-log writer.
- Before marking work complete, update `.agent/` per each file's header contract:
  - `memory/`: write the fact to `memory/<slug>.md` (prefer `.agent/scripts/memory.sh new`) — one fact per file, per its header contract: a decision, term, preference, or active blocker — then add or update its index line in `memory.md`. Supersede in place, don't append. If nothing durable changed, leave both unchanged and say so in the log entry.
  - `session-log.md`: append via `.agent/scripts/log.sh --tool <tool, model-tagged when the harness states one, never guessed> --area <area> --verify <pass|fail|n/a> --summary "<task, outcome, ≤25 words>"`. If the script cannot run, follow the file's header contract by hand.
  - `docs/`: source catalog, source notes, and outline update as part of the task, not after it. New docs open with a one-line `<!-- Read when: … -->` routing hint and get a routing-table row.
- Record user corrections, durable preferences, and repeated patterns in memory with a trigger or confidence tag.
- Fix stale memory, outdated docs, and duplication when encountered.
- Act on GROOM:/REPAIR:/INDEX: flags from the bootstrap status check in the same session.

## Self-learning

- After a user correction or a failed verification that needed a non-obvious fix, record the lesson:

  `- [YYYY-MM-DD] <imperative rule>. Trigger: <cause, only if it adds information>.`

- Write the rule, not the story: imperative, ≤40 words, no incident retelling. Merge near-duplicates instead of appending.
- Route by scope: behavioral rules stay in `rules/learned.md`; source mechanics go to that source's notes under `## Gotchas`.

## Git and commits

- Before committing, inspect status and diff; include only intended files. Messages: technical, concise, what and why. Never add yourself as co-author. <!-- Delete this section at bootstrap if the project is not in a git repository. -->

## Project guardrails

<!-- Bootstrap MUST fill this section with exact conventions and commands. "Follow the citation style" is not filled in; "APA 7, references.bib via Zotero export" is. -->

- Citation style + reference manager: <e.g. APA 7; Zotero → references.bib>
- Style guide and register: <file or rules; language conventions>
- Build / preview: <exact commands, e.g. `latexmk -pdf main.tex`>
- Sources: <where PDFs and notes live; catalog file path + entry format>
- Requirements: <institutional templates and constraints; details in purpose.md>
