---
name: retro
description: Distills a session's lessons into durable records. Use after a user correction, a failed verification that needed a non-obvious fix, a mid-task deviation from an agreed plan, or a comment-hygiene breach reaching review — and at session close before the log entry — routing each lesson to rules/learned.md, a docs Gotchas entry, or comments.conf vocabulary. Also covers harvesting a tool-native memory silo into .agent/.
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

Or the session is closing and a lesson may be worth keeping.

## Do not use this skill when

- The outcome is a one-off: it goes in the session log, and no rule is written.
- The task is the session-log entry itself — that is `log.sh`'s job, not retro's.
- The lesson already has a `learned.md` entry — merge or broaden that entry in place (see below) rather than re-running the walkthrough.
- No tool-native memory silo exists — don't go looking for one. The harvesting section states its own gate.

## When to distill a rule

The preset's Self-learning section is part of `rules/contract.md`. When one of its retro triggers fires, ask what check or behavior would have prevented it. For a plan deviation, ask what the plan missed.

If the answer generalizes past this one session, draft a rule. If it doesn't, the outcome belongs in the session log, not `learned.md`. A useful test: try to state the rule in one imperative sentence before writing anything down. If it only makes sense with a paragraph of backstory attached, keep asking the question until the generalizable version surfaces.

## The format

`rules/learned.md`'s own header contract defines the entry format:

`- [YYYY-MM-DD] <imperative rule>. Trigger: <cause, optional>.`

Draft the rule clause first. Add the trigger clause only if a future session would otherwise not know when the rule applies.

## Merge, don't append

Before adding a new entry, search `learned.md` for existing entries on the same subject or trigger. A quick `grep` on a keyword from the draft rule is enough. If a near-duplicate exists, edit it in place: broaden the imperative, or fold in the new trigger. Then drop the old line, rather than leaving both for the grooming threshold to reconcile later.

## Route by scope

Behavioral rules stay in `learned.md`. Some rules are really an area-specific mechanic: a library quirk, an API gotcha, a SQL or CSS behavior. Those belong in the matching `.agent/docs/<area>.md` file instead, under a `## Gotchas` heading and in the same entry format. Leave at most a one-line pointer in `learned.md` for cross-area hazards.

A comment-hygiene lesson routes to vocabulary, not prose. That lesson is a narrative comment or dead citation that reached review. Add its shape to `.agent/scripts/comments.conf`, so `comments.sh` catches the next one mechanically: a citation format goes to `BLOCK_RE_EXTRA`, a house narration phrasing to `NARRATION_RE_EXTRA`, a generated path the gate should skip to `EXCLUDE_RE_EXTRA`.

Write a `learned.md` rule for it only when no pattern can express what went wrong. This is the fix ladder in miniature. A rule that was already written and breached anyway needs a check, not a restatement.

## Harvesting a tool-native memory silo

This is a repair path, not a routine step. See operating-model.md's Native tool memory section for why. It applies only when retro finds a tool-collected silo. That happens when the native-memory setting wasn't applied to this node, or when another tool populated its own store.

Check the tool's native memory location for entries about this project. For Claude Code, that is wherever `autoMemoryEnabled` would have written. If any entries exist, fold their content into the right `.agent/` file: a fact into `memory/`, a behavioral rule into `learned.md`. Then delete the silo. A node with the setting correctly applied has nothing to harvest. Don't go looking for one.
