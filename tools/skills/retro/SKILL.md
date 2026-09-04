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

Or the session is closing and a lesson may be worth keeping.

## Do not use this skill when

- The outcome is a one-off: it goes in the session log, and no rule is written.
- The task is the session-log entry itself — that is `log.sh`'s job, not retro's.
- The lesson already has a `learned.md` entry and its failure mode is still unenforced — merge or broaden that entry in place (see below). Remove it when code or tooling now prevents the failure.
- No tool-native memory silo exists — don't go looking for one. The harvesting section states its own gate.

## Find the failing source before distilling

The preset's Self-learning section is part of `rules/contract.md`. A trigger starts this check. It does not guarantee a new rule.

Search the contract, routed docs, relevant source, tooling, and existing learned rules for the behavior and its cause. If one already owns it, fix that source and write no compensating rule. If this session made the behavior mechanically enforceable, remove any learned rule that only asked the agent to do the same thing. Version control keeps the incident history.

A doc that exists and was never opened is a failing source too. Check its `Read when:` hook and its `architecture.md` routing row against the words the task actually used. A hook that names the occasion — "shipping a release" — and never the thing asked about — "deploy" — is the defect: fix the routing line, and write no rule telling the agent to search harder.

Only after that source check, ask what check or behavior would have prevented the failure. For a plan deviation, ask what the plan missed.

If the answer generalizes past the source fix and this session, draft a rule. Otherwise the outcome belongs in the session log. A useful test: try to state the rule in one imperative sentence before writing anything down. If it only makes sense with a paragraph of backstory attached, keep asking until the generalizable version surfaces.

## The format

`rules/learned.md`'s own header contract defines the entry format:

`- [YYYY-MM-DD] <imperative rule>. Trigger: <cause, optional>.`

Draft the rule clause first. Add the trigger clause only if a future session would otherwise not know when the rule applies.

## Merge, don't append

Before adding a new entry, search `learned.md` for existing entries on the same subject or trigger. A quick `grep` on a keyword from the draft rule is enough. If a near-duplicate exists, edit it in place: broaden the imperative, or fold in the new trigger. Then drop the old line, rather than leaving both for the grooming threshold to reconcile later.

## Route by scope

Behavioral rules stay in `learned.md`. Some rules are really an area-specific mechanic: a library quirk, an API gotcha, a SQL or CSS behavior. Those belong in the matching `.agent/docs/<area>.md` file instead, under a `## Gotchas` heading and in the same entry format. Leave at most a one-line pointer in `learned.md` for cross-area hazards.

A comment-hygiene lesson first routes to `comments.sh`. If the gate already catches the shape, write nothing. Otherwise add a project-specific repeatable shape to `.agent/scripts/comments.conf`, so the next occurrence is mechanical: a citation format goes to `BLOCK_RE_EXTRA`, a house narration phrasing to `NARRATION_RE_EXTRA`, a generated path the gate should skip to `EXCLUDE_RE_EXTRA`. When the gate blocked something real, the fix is `CONSTRAINT_RE_EXTRA`, not an exception.

Write a `learned.md` rule for it only when no pattern can express what went wrong. This is the fix ladder in miniature. A rule that was already written and breached anyway needs a check, not a restatement.

## Harvesting a tool-native memory silo

This is a repair path, not a routine step. See operating-model.md's Native tool memory section for why. It applies only when retro finds a tool-collected silo. That happens when the native-memory setting wasn't applied to this node, or when another tool populated its own store.

Check the tool's native memory location for entries about this project. For Claude Code, that is wherever `autoMemoryEnabled` would have written. If any entries exist, fold their content into the right `.agent/` file: a fact into `memory/`, a behavioral rule into `learned.md`. Then delete the silo. A node with the setting correctly applied has nothing to harvest. Don't go looking for one.
