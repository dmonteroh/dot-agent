---
name: retro
description: Distills a session's lessons into durable records. Use after a user correction, a failed verification that needed a non-obvious fix, a mid-task deviation from an agreed plan, or a comment-hygiene breach reaching review — and at session close before the log entry — routing each lesson to rules/learned.md, a docs Gotchas entry, or comments.conf vocabulary. Also covers harvesting a tool-native memory silo into .agent/.
---

# Retro

The binding rule, that retro happens and what it produces, lives in the
preset's Self-learning section (part of `rules/contract.md`) and in
`rules/learned.md`'s own header, which is the curation law itself. This
skill is an optional walkthrough of *how* to run retro well; it adds no
obligation beyond what those two sources already state.

## Use this skill when

A retro trigger from the Self-learning section fires — a user correction,
a failed verification that needed a non-obvious fix, a mid-task deviation
from an agreed plan, a comment-hygiene breach reaching review — or the
session is closing and a lesson may be worth keeping.

## Do not use this skill when

- The outcome is a one-off: it goes in the session log, and no rule is
  written.
- What's being written is the session-log entry itself — that is `log.sh`'s
  job, not retro's.
- The lesson already has a `learned.md` entry — merge or broaden that
  entry in place (see below) rather than re-running the walkthrough.
- No tool-native memory silo exists — don't go looking for one; the
  harvesting section states its own gate.

## When to distill a rule

When one of the retro triggers named in the preset's Self-learning section
(part of `rules/contract.md`) fires, ask what check or behavior would have
prevented it (for a plan deviation: what the plan missed). If the answer
generalizes past this one session, draft a rule; if it doesn't, the outcome
belongs in the session log, not `learned.md`. A useful test: try to state
the rule in one imperative sentence before writing anything down. If it
only makes sense with a paragraph of backstory attached, keep asking the
question until the generalizable version surfaces.

## The format

`rules/learned.md`'s own header contract defines the entry format:

`- [YYYY-MM-DD] <imperative rule>. Trigger: <cause, optional>.`

Draft the rule clause first; add the trigger clause only if a future
session would otherwise not know when the rule applies.

## Merge, don't append

Before adding a new entry, search `learned.md` for existing entries on the
same subject or trigger; a quick `grep` on a keyword from the draft rule
is enough. If a near-duplicate exists, edit it in place (broaden the
imperative or fold in the new trigger) and drop the old line, rather than
leaving both to be reconciled later at the grooming threshold.

## Route by scope

Behavioral rules stay in `learned.md`. A rule that's really an
area-specific mechanic (a library quirk, an API gotcha, a SQL or CSS
behavior) belongs in the matching `.agent/docs/<area>.md` file under a
`## Gotchas` heading instead, same entry format, with at most a one-line
pointer left in `learned.md` for cross-area hazards.

A comment-hygiene lesson — a narrative comment or dead citation that
reached review — routes to vocabulary, not prose: add the citation's shape
(a ticket-number format, a generated path the gate should skip) to
`.agent/scripts/comments.conf` so `comments.sh` catches the next one
mechanically. Write a `learned.md` rule for it only when no pattern can
express what went wrong. This is the fix ladder in miniature: a rule that
was already written and breached anyway needs a check, not a restatement.

## Harvesting a tool-native memory silo

This is a repair path, not a routine step; see operating-model.md's Native
tool memory section for why. It applies only when retro finds a
tool-collected silo, because the native-memory setting wasn't applied to
this node or another tool populated its own store. Concretely: check the
tool's native memory location (for Claude Code, wherever
`autoMemoryEnabled` would have written) for entries about this project; if
any exist, fold their content into the right `.agent/` file (a fact into
`memory/`, a behavioral rule into `learned.md`) and delete the silo. A
node with the setting correctly applied has nothing to harvest; don't go
looking for one.
