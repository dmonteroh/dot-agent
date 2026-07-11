# Software development rules

Goal: correct, useful, auditable changes. Be concise. Each sentence must carry operational weight. Adapt during bootstrap: fill Project guardrails with exact commands; keep the Kernel intact.

## Kernel

1. Do not change code unrelated to the task.
2. Do not change product code when asked a question — answer first; edit only on explicit direction.
3. Never claim done, fixed, or passing without freshly running the exact commands in Project guardrails.
4. Do not ignore a failing command — fix it or report the exact failure.
5. Never hand-edit generated sources or lockfiles.
6. Check `git status --short` before editing; never revert or overwrite work you did not do.
7. Before finishing: append one session-log entry per its header template; update memory.md only if durable facts changed.
8. No narrative, logs, file lists, or SHAs in `.agent/` files.
9. Never write secrets, tokens, or customer/personal data into `.agent/`.
10. Do not fabricate; say when uncertain; push back on flawed premises.

## Context loading

- Scale reads: typo/single-file = entry point + target file; feature = purpose + memory + area doc; domain/behavior change = purpose + memory + relevant docs. If `.agent/docs/architecture.md` has a routing table, pick area docs there; otherwise use the entry point's doc index.
- Check `.agent/` context before asking about unknown files, concepts, or deliverables.
- Use matching local skills, minimal set.

## Scope control

- Implement small clear requests directly.
- For multi-file work, give a 3–5 step plan before editing.
- For investigation or unclear implementation permission, diagnose first; do not change product code until direction is explicit.
- For high-risk or ambiguous work, ask one focused question or propose a narrow first slice.
- Act on small rule-aligned decisions. Ask only when scope, risk, product behavior, or user intent changes.
- Do not ship knowingly partial fixes to stay small — surface the gap.
- Do not give task time estimates unless explicitly asked.
- Accuracy over agreement. Update views only on evidence.

## Implementation

- Follow existing style, structure, patterns, helper APIs, and ownership boundaries.
- Prefer clear names and structure over comments; comment only non-obvious logic.
- New or changed observable behavior requires test coverage. Pure refactors may rely on existing coverage.
- Update docs only when behavior, flows, dependencies, architecture, or practices change. Write docs as timeless descriptions, never change narration.
- Carry documented design decisions through all dependent briefs, contracts, docs, and implementation scope immediately.
- After major architecture changes: remove dead code, align layout and naming, update docs and references, remove unused dependencies, run the full quality bar.

## Verification contract

- Run the quality bar for changed scope: tests, lint, typecheck, build as applicable — exact commands in Project guardrails.
- If a required tool is unavailable, state the gap instead of silently skipping.
- If verification fails, classify: caused-by-change, pre-existing, environmental, or unknown. Investigate unknown before reporting.
- Fix failures within task scope. For unrelated baseline failures, report command, status, blocker, and residual risk.
- Report exact commands and pass/fail status. Quote error excerpts; never dump full logs.
- Before completion, re-read each edited region with surrounding context; re-read a file in full only after large-scale rewrites.
- Self-review: tests covered, docs synced, `.agent/` updated, no unrelated changes.

## Continuity contract

- Subagents: report continuity facts to the orchestrator; never edit `.agent/` unless explicitly assigned. The orchestrator is the single session-log writer.
- Before marking work complete, update `.agent/` per each file's header contract:
  - `memory.md`: durable state, decisions, terminology, preferences, active blockers only. If nothing durable changed, leave it unchanged and say so in the log entry.
  - `session-log.md`: one index entry, ~25 words — date, tool (model-tagged when the harness states one, never guessed), task, area, outcome, verification status. Reference task briefs by ID.
  - `docs/`: update when architecture, operations, behavior, dependencies, or workflows change. New area docs open with a one-line `<!-- Read when: … -->` routing hint and get a routing-table row.
- Bad (transcript): "Added page at /x. 5 new files: a.ts (loader), b.svelte…; reviewer pass; 6 tests; commit 47feccc." Good: "- [2026-06-23] (claude/sonnet) S197 invitation acceptance page (frontend). verify: pass."
- When an existing entry exceeds the ceiling, trim it to the template on sight, preserving task name, outcome, and verification status.
- Record user corrections, durable preferences, and repeated patterns in memory with a trigger or confidence tag.
- Fix stale memory, outdated docs, and duplication when encountered.
- Act on GROOM:/REPAIR:/INDEX: flags from the bootstrap status check in the same session.

## Self-learning

- After a user correction or a failed verification that needed a non-obvious fix, record the lesson:

  `- [YYYY-MM-DD] <imperative rule>. Trigger: <cause, only if it adds information>.`

- Write the rule, not the story: imperative, ≤40 words, no incident retelling. If the rule needs its history to make sense, it is not distilled yet.
- Ask "what check or behavior would have prevented this?" and record that. One-off outcomes belong in the session log, not here.
- Merge near-duplicates instead of appending.
- Route by scope: behavioral rules (scoping, verification, communication, workflow) stay in `rules/learned.md`. Area gotchas (library, API, SQL, CSS mechanics) go to the matching `.agent/docs/` file under `## Gotchas`, same format; keep at most a one-line pointer here for cross-area hazards.

## Git and commits

- Before committing, inspect status and diff; include only intended files.
- Commit messages: technical, concise, what and why.
- Never add yourself as a co-author to commits.

## Project guardrails

<!-- Bootstrap MUST fill this section with exact commands. "Run the tests" is not filled in; `dotnet test backend/X.sln --no-build` is. -->

- Areas and package managers: <e.g. frontend `app/` — pnpm only>
- Build: <exact command(s)>
- Test: <exact command(s), noting any serial-execution constraints>
- Lint / typecheck: <exact command(s)>
- Generated files: <paths + regeneration command; never hand-edit>
- Project constraints: <e.g. styling system, config file locations>
