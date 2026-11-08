---
name: retro
description: Triages session corrections and failures against their canonical source before retaining durable lessons. Use after a user correction, non-obvious verification fix, agreed-plan deviation, or comment-hygiene breach, and at session close. Routes surviving lessons to rules/learned.md, a docs Gotchas entry, or comments.conf vocabulary. Also harvests a tool-native memory silo into .agent/.
---

# Retro

The binding rule — that retro happens, and what it produces — lives in the preset's Self-learning section, part of `rules/contract.md`. It also lives in `rules/learned.md`'s own header, which is the curation law itself.

This skill is an optional walkthrough of _how_ to run retro well. It adds no obligation beyond what those two sources already state.

## Use this skill when

A retro trigger from the Self-learning section fires:

- a user correction
- a failed verification that needed a non-obvious fix
- a mid-task deviation from an agreed plan
- a comment-hygiene breach reaching review

Or the session is closing and a lesson may be worth keeping. A worker under an orchestrator runs retro too, at the end of its attempt: a check that failed, or a review finding fixed in a later round, is a failed verification. The worker writes into its own copy of the node, and the orchestrator merges it back (`.agent/scripts/absorb.sh`).

## Do not use this skill when

- The outcome is a one-off: it goes in the session log, and no rule is written.
- The task is the session-log entry itself — that is `log.sh`'s job, not retro's.
- The lesson already has a `learned.md` entry and its failure mode is still unenforced — merge or broaden that entry in place (see below). Remove it when code or tooling now prevents the failure.
- No tool-native memory silo exists — don't go looking for one. The harvesting section states its own gate.

## Draft from the evidence before reading the records

Write your own account first, from this session alone. Name the trigger, the evidence it left (the correction, the failed check, or the review finding), and the lesson in one sentence, or write that there is none. Do this before you open `rules/learned.md`, the learned records, memory facts, or earlier retro output. Keep the draft in your working notes, never in the node.

Existing records anchor a retro that reads them first. It tends to see the session in their terms: it reinforces a rule that only looks related, or files a near-duplicate, and it misses the lesson the records do not already hold.

Then run the source check below and the duplicate check under "Merge, don't append", and reconcile your draft with what they turn up. If a record already states the draft, the draft revises or reinforces that record and adds nothing new. If the draft differs from a record it resembles, say how before you change either.

## Find the failing source before distilling

The preset's Self-learning section is part of `rules/contract.md`. A trigger starts this check. It does not guarantee a new rule.

Search the contract, routed docs, relevant source, tooling, and existing learned rules for the behavior and its cause. If one already owns it, fix that source and write no compensating rule. If this session made the behavior mechanically enforceable, remove any learned rule that only asked the agent to do the same thing. Version control keeps the incident history.

A doc that exists and was never opened is a failing source too. Check its `Read when:` hook and its `architecture.md` routing row against the words the task actually used. A hook that names the occasion — "shipping a release" — and never the thing asked about — "deploy" — is the defect: fix the routing line, and write no rule telling the agent to search harder.

Only after that source check, ask what check or behavior would have prevented the failure. For a plan deviation, ask what the plan missed.

## Pick the cheapest fix that holds

Match the failure to the first rung that fixes it:

1. A check or script that already exists and was skipped needs routing or wiring, not a rule.
2. A mechanical step that repeats becomes a script: the project's own, or a node helper.
3. A narrow procedure becomes a doc section with a `Read when:` hook, or a skill.
4. An area mechanic becomes a `## Gotchas` entry in the owning doc.
5. A general behavioral lesson becomes a learned rule.

A one-off mistake gets no script and no rule: it goes in the session log. A rule moves up to a check only after it was written and breached anyway. Every learned rule loads in every session, so each one a script replaces is a recurring cost removed.

## Record only what the evidence shows

Writing nothing is the default outcome of a retro, not a failure of one. A lesson needs evidence it can cite: the correction, the failed check, or the review finding. Record what that evidence shows, not a cause you presume. When two changes landed together and you cannot tell which one fixed the failure, the lesson is confounded. Say so in the trigger clause, or keep it in the session log until a later session separates them. An invented attribution misleads every later session that loads it.

If the answer generalizes past the source fix and this session, draft a rule. Otherwise the outcome belongs in the session log. A useful test: try to state the rule in one imperative sentence before writing anything down. If it only makes sense with a paragraph of backstory attached, keep asking until the generalizable version surfaces.

## The format

`rules/learned.md`'s own header contract defines the entry format:

`- [YYYY-MM-DD] <imperative rule>. Trigger: <cause, optional>.`

Draft the rule clause first. Add the trigger clause only if a future session would otherwise not know when the rule applies.

## Merge, don't append

On a node running `indexes: generated`, run `.agent/scripts/learn.sh lookup` against the draft rule before adding a new entry. If it names a duplicate or an overlapping record, revise the record it names with `.agent/scripts/learn.sh revise` — broaden the imperative, or fold in the new trigger — rather than leaving both for the grooming threshold to reconcile later. Pass `--distinct` only after reading the records the refusal names and confirming the draft is genuinely a separate rule.

On a manual-mode node, `rules/learned/` does not exist and `learn.sh` refuses there, so merge near-duplicates by hand in `rules/learned.md` instead: read the file first, and edit the existing entry rather than adding a new one that says the same thing.

## Route by scope

What you found becomes one of four kinds, each owned by one surface and one writer: a task requirement stays in the task's own artifacts and the session log, at its stated scope, with no durable record; a project fact goes to `.agent/scripts/memory.sh new`, or the owning doc when it is stable knowledge about how the system works; a durable preference the user states in their own turn updates the existing canonical record with `.agent/scripts/memory.sh supersede --slug <slug>`; a behavioral lesson that generalizes past this session is a learned record, written with `.agent/scripts/learn.sh`.

Behavioral rules stay in `learned.md`. Some rules are really an area-specific mechanic: a library quirk, an API gotcha, a SQL or CSS behavior. Those belong in the matching `.agent/docs/<area>.md` file instead, under a `## Gotchas` heading and in the same entry format. Leave at most a one-line pointer in `learned.md` for cross-area hazards.

A comment-hygiene lesson first routes to `comments.sh`. If the gate already catches the shape, write nothing. Otherwise add a project-specific repeatable shape to `.agent/scripts/comments.conf`, so the next occurrence is mechanical: a citation format goes to `BLOCK_RE_EXTRA`, a house narration phrasing to `NARRATION_RE_EXTRA`, a generated path the gate should skip to `EXCLUDE_RE_EXTRA`. When the gate blocked something real, the fix is `CONSTRAINT_RE_EXTRA`, not an exception.

Write a `learned.md` rule for it only when no pattern can express what went wrong. This is the fix ladder above, applied to comments. A rule that was already written and breached anyway needs a check, not a restatement.

A behavioral lesson has a second scope question: which node. A lesson that stops making sense in another project belongs to this project, as a learned rule or a `## Gotchas` entry. A lesson that would help just as much in an unrelated project belongs in the root node's learned rules. If it holds for every project of this preset, it is a candidate for the preset itself. A project session or a worker reports a root-level or preset-level lesson and never writes the root node unprompted.

Word the rule at the level it applies. "Be thorough" is too generic to change anything. "The fee rose to 250 on Jan 1" is too specific to fire again. The one-sentence test above catches both.

## Harvesting a tool-native memory silo

This is a repair path, not a routine step. See operating-model.md's Native tool memory section for why. It applies only when retro finds a tool-collected silo. That happens when the native-memory setting wasn't applied to this node, or when another tool populated its own store.

Check the tool's native memory location for entries about this project. For Claude Code, that is wherever `autoMemoryEnabled` would have written. If any entries exist, fold their content into the right `.agent/` file: a fact into `memory/`, a behavioral rule into `learned.md`. Then delete the silo. A node with the setting correctly applied has nothing to harvest. Don't go looking for one.
