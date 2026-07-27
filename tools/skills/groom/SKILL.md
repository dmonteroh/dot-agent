---
name: groom
description: Use when .agent/scripts/status.sh prints a GROOM: line (session-log.md, a memory/*.md fact file, the memory.md index, rules/learned.md, or memory/legacy.md over its threshold) and you need the procedure for clearing it.
---

# Grooming `.agent/`

The binding rule — that `GROOM:` flags get handled as part of the current
session — lives in the node's `.agent/rules/contract.md` (from the preset's
Kernel and Continuity contract). The thresholds themselves live in
`operating-model.md`'s "How does `.agent/` stay small" design decision and
at the top of `scripts/status.sh`. This skill is an optional walkthrough of
*how* to clear each flag; it adds no obligation beyond what those two
sources already state, and a node with no skills installed grooms fine
without it.

Start by running `.agent/scripts/status.sh` and reading the exact `GROOM:`
line — it names the file and the threshold it crossed. Handle each flag
below, then re-run `status.sh` to confirm it's clear.

## `session-log.md` over threshold

Entries are newest-last, one per line. Compute the cutoff (today minus 30
days). Working from the top of the file (oldest first), move every entry
older than the cutoff, in original order, into
`.agent/archive/session-log-archive.md` — create it with a one-line header
comment if it doesn't exist yet — then delete those lines from
`session-log.md`. Leave entries inside the 30-day window alone even if the
file is still over the entry-count threshold; the cutoff is time-based, not
count-based.

## A `memory/<slug>.md` fact file over its word ceiling

Re-read the file's own header contract first: one fact per file. If it
genuinely holds one fact that grew wordy, rewrite it tighter in place — same
filename, refreshed date, under the ceiling. If it holds two facts that
would be superseded at different times, split it: run
`.agent/scripts/memory.sh new` for the second fact under a new slug, then
trim the original down to just the first fact. Both slugs end up indexed in
`memory.md`.

## `memory.md` index over its entry ceiling

Read every index line. For facts that are stale, superseded, or no longer
true, delete the line and its fact file — groom by deletion, not by
rewriting. Where two lines describe the same underlying fact, consolidate
into one `memory/<slug>.md`, then delete the redundant line and file.

## `rules/learned.md` over its rule ceiling

The file's own header comment is the curation law; read it before editing.
Look for near-duplicate rules and fold them into one entry instead of
keeping both — grep for shared trigger words or subject matter across
entries as a starting point. For any entry that is really an area-specific
mechanic (a library, API, SQL, or CSS gotcha rather than a behavioral rule),
move it to the matching `.agent/docs/<area>.md` file under a `## Gotchas`
heading, in the same entry format, and leave at most a one-line pointer
behind if it's a cross-area hazard.

## `memory/legacy.md` exists

This file is the mechanical output of `scripts/node.sh update`'s
memory-split migration: the node's pre-6.1 `memory.md` prose body, moved
verbatim. Read it, identify each distinct durable fact inside it, and run
`.agent/scripts/memory.sh new` once per fact (its own slug, title, hook,
and body under the word ceiling). Once every fact has a home, delete
`memory/legacy.md` and remove its index line from `memory.md` by hand —
`memory.sh new` only appends index lines, it doesn't remove this one.
