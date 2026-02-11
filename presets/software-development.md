# Software development preset

Behavior rules for AI agents working on code projects. Adapt to your project during bootstrap — add project-specific conventions, test commands, and language rules.

---

## Context first (load order)

At the start of any new conversation or task, read context before writing code or giving advice. Read in order:

1. `.agent/purpose.md` (purpose, audience, constraints)
2. `.agent/memory.md` (current state, decisions)
3. Last 5–10 entries of `.agent/session-log.md` (recent meeting notes)
4. The doc for the area you are changing (see project entry point for doc index)

Do not skip this when the task touches design, behaviour, or multiple areas. This is your memory; without it you lack purpose and continuity.

**Scale to the task:**

- **Typo / single-file fix:** project entry point + the one file only.
- **New feature / layout change:** purpose + memory + entry point + area doc.
- **Domain or behaviour change:** purpose + memory + relevant docs.

## Self-maintenance (MANDATORY)

Before marking any task or step complete:

1. **Update `.agent/memory.md`** — new domain knowledge, decisions, terminology, or state changes from this session.
2. **Append to `.agent/session-log.md`** — what was discussed, decided, implemented. Short and factual (2–5 lines).
3. **Update `.agent/docs/`** when the project's technology, patterns, or dependencies change — capture project-specific practices, not just facts. Prune or update docs for removed technologies.

Do not skip. This is what gives the next session continuity.

**Observation:** When the user corrects you, expresses a preference, explains how they think, or reveals a working pattern — note it in the appropriate `.agent/memory.md`. Not every interaction, but patterns and clear preferences. Every new observation should include either a concrete trigger (quote/behavior) or a confidence tag (`high`/`medium`/`low`) when the trigger is implicit. This applies at every level of the knowledge tree: project-specific observations stay in the project's memory, cross-project patterns go to the root.

**Housekeeping:**
- When `session-log.md` gets long, archive older entries to `.agent/session-log-archive.md`. Don't archive too eagerly — a few hundred lines is negligible context for most LLMs, and the agent work to reorganize costs more tokens than just reading a longer file.
- Periodically compact `memory.md`: keep current truths/decisions, move stable long-form context to `.agent/docs/`, and remove stale superseded notes.

**Context auditing:** When reading `.agent/` at session start, notice and fix stale facts in `memory.md`, outdated `docs/`, and redundancy across files. Keep `.agent/` accurate, not just populated.

**Hookless agent check:** If this project uses `scripts/verify-agent-context.sh`
as a manual completion check, run it before done. On failure, run with
`--fix`, replace any placeholders with real session details, then rerun the
check and only mark done after it passes.

## Ambiguity resolution

When the user references something you don't immediately recognize (a file, project, concept, deliverable), consult your memory files and session log before asking for clarification. The answer is often already in your context.

## Code quality

- **Comments:** Only when the code is not self-explanatory. Prefer clear names and structure.
- **Documentation:** When adding or changing features, behaviour, or structure, update relevant `.agent/` docs in the same work. Keep docs in sync with the code.
- Follow the language and style conventions of the project.
- Update docs only when behaviour, flows, dependencies, or concepts change. Not for typo fixes or refactors that don't change behaviour.

## Regression and verification

- **Definition of done.** Do not mark a task complete until the project's quality bar passes (tests, lint, typecheck). If they fail, fix them in the same work.
- **Tests for new/changed behaviour.** Any new feature or changed behaviour must be covered by new or updated tests.

## Git and commits

- Clean commit messages. Focus on the technical change — what and why.

## Autonomy and reliability

- **Task chunking:** For multi-file tasks, propose a short plan (3–5 steps) before coding. After each step: run tests, update docs, then proceed.
- **Scope control:** If ambiguous or large, ask 1–2 clarifying questions or propose a narrow first slice.
- **Self-review before done:** Re-read changed files. Confirm tests added/updated, docs updated, memory and session-log updated, no unrelated changes.
- **Incremental delivery:** Small, working increments rather than one large change.
- **Agent runs the bar:** Run the project's test/lint commands; do not only suggest that the user run them.
- **Act vs ask:** Act autonomously on small decisions that match project rules. Ask when scope or direction is unclear.

## Correctness

- **Re-read files after editing.** Before marking done, re-read every file you wrote or edited. Catch mistakes, inconsistencies, and leftover artifacts before the user has to.
- **Run tests after changing source files.** If you changed `.ts`, `.tsx`, `.js`, `.jsx`, `.py`, `.rs`, `.go`, `.java`, or similar source files, run the project's test suite before finishing.
- **Verify build after config changes.** If you changed `package.json`, `tsconfig.json`, `*.config.*`, `.env`, or similar config files, run the build to verify nothing broke.

These are separate from the quality bar in "Regression and verification" — that section defines the bar, this section says you must actually check your own work against it.

## Self-learning

After substantial sessions (source files changed, user corrections received, or process patterns discovered), evaluate whether behavioral lessons emerged. If so, append a rule to `.agent/rules/learned.md`:

```
- [YYYY-MM-DD] <rule in imperative form>. Trigger: <what caused this learning>.
```

Rules should be universal (not session-specific), abstracted from the specific case, and high-impact. Examples of good rules: "Always check all consuming packages when modifying shared schemas." "Run the linter before committing, not after." "When the user says 'fix those', they mean all items listed, not just the first."

If nothing worth recording: proceed without updating. Most sessions won't produce a rule. That's fine.

## After big architectural changes

Perform a deep code review in the same work:

1. Remove dead code, unused modules, orphan tests.
2. Align folder layout and naming to the new design.
3. Update all docs and references.
4. Remove unused dependencies.
5. Run the full quality bar — tests, lint, typecheck.
