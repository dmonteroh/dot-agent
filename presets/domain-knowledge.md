# Domain knowledge rules

Goal: organized, provenanced, retrievable knowledge, and outputs grounded in it. Be concise. Each sentence must carry operational weight. The domain itself goes in `purpose.md`. Adapt during bootstrap: fill Project guardrails with exact locations and commands; keep the Kernel intact.

## Kernel

1. Do not fabricate. If it is not in the accumulated material, say it is not known — a gap is a finding, not a problem to hide.
2. Do not restructure or rewrite stored knowledge when asked a question — answer first; change the store only on explicit direction.
3. Never record or output a fact without its source; provenance survives every rewrite.
4. Never silently overwrite on contradiction — keep both versions, dated, flag it, and let the human decide.
5. Never ingest material without adding its catalog entry in the same session.
6. Never present inference as established fact; mark which is which in every output.
7. Never delete knowledge — mark it superseded with a date, or move it to `archive/`.
8. Before finishing: append one session-log entry per its header template; update memory.md only if durable facts changed.
9. No narrative, transcripts, or command output in `.agent/` files.
10. Never write secrets, tokens, or customer/personal data into `.agent/`.

## Context loading

- Scale reads: quick lookup = entry point + the catalog's target doc; producing an output = purpose + memory + the docs the catalog routes to; restructuring or convention change = purpose + memory + all affected docs.
- Check `.agent/` context before asking about unknown terms, sources, or deliverables.

## Scope control

- Handle small clear requests directly.
- For work spanning several docs or outputs, give a 3–5 step plan before editing.
- For high-risk or ambiguous work, ask one focused question or propose a narrow first slice.
- Do not give task time estimates unless explicitly asked.
- Accuracy over agreement. Update views only on evidence; push back on flawed premises.

## Knowledge discipline

- Catalog format: source, date, type, one-line summary — one entry per ingested item, in the catalog file named in Project guardrails. Catalogs live in `.agent/docs/`, never in `memory.md`.
- Structure from chaos: convert casual input (notes, conversations, screenshots, quick thoughts) into the node's standard format before storing it.
- Surface connections: when new material relates to existing knowledge, note the connection where the knowledge lives.
- Every output names what it draws on and states what is missing.
- Knowledge levels: project-specific facts stay in the project node; cross-project patterns go to the root node (see manifest `children`).

## Verification contract

- Before completion: internal links resolve, catalogs and indexes are updated in the same change, no placeholders remain.
- Verify external citations against the primary source before they leave the node; a stored summary is not a substitute.
- When a doc is renamed or removed, find and update every reference in the same change.
- Re-read each edited region with surrounding context before completion.
- If a check fails, classify: caused-by-change, pre-existing, or unknown. Investigate unknown before reporting.

## Continuity contract

- Subagents: report continuity facts to the orchestrator; never edit `.agent/` unless explicitly assigned. The orchestrator is the single session-log writer.
- Before marking work complete, update `.agent/` per each file's header contract:
  - `memory.md`: durable working state, decisions, terminology, preferences, active blockers only. If nothing durable changed, leave it unchanged and say so in the log entry.
  - `session-log.md`: one index entry, ~25 words — date, tool (model-tagged when the harness states one, never guessed), task, area, outcome, verification status.
  - `docs/`: catalogs and structured knowledge update as part of the task, not after it. New docs open with a one-line `<!-- Read when: … -->` routing hint and get a catalog row.
- When an existing entry exceeds the ceiling, trim it to the template on sight, preserving task, outcome, and verification status.
- Record user corrections, durable preferences, and repeated patterns in memory with a trigger or confidence tag.
- Fix stale memory, outdated docs, and duplication when encountered.
- Act on GROOM:/REPAIR:/INDEX: flags from the bootstrap status check in the same session.

## Self-learning

- After a user correction or a failed verification that needed a non-obvious fix, record the lesson:

  `- [YYYY-MM-DD] <imperative rule>. Trigger: <cause, only if it adds information>.`

- Write the rule, not the story: imperative, ≤40 words, no incident retelling. Merge near-duplicates instead of appending.
- Route by scope: behavioral rules (scoping, verification, communication, workflow) stay in `rules/learned.md`. Source or format mechanics go to the matching `.agent/docs/` file under `## Gotchas`, same format; keep at most a one-line pointer here for cross-area hazards.

## Git and commits

- Before committing, inspect status and diff; include only intended files. Messages: technical, concise, what and why. Never add yourself as co-author. <!-- Delete this section at bootstrap if the node is not in a git repository. -->

## Project guardrails

<!-- Bootstrap MUST fill this section with exact locations and commands. "Keep an index" is not filled in; "catalog: docs/sources.md, one row per item" is. -->

- Catalog: <file path + entry format; the file's header carries the format contract>
- Docs layout: <areas, routing hints, where structured knowledge lives>
- Tooling: <exact index/audit/regeneration commands if any; generated files are never hand-edited>
- Output conventions: <formats, templates, citation style>
- Boundaries: <what this node does not cover; root/child node locations>
