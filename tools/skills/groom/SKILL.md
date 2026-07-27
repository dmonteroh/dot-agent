---
name: groom
description: Use when .agent/scripts/status.sh prints a GROOM: line (session-log.md, a memory/*.md fact file, the memory.md index, rules/learned.md, or memory/legacy.md over its threshold) and you need the procedure for clearing it.
---

# Grooming `.agent/`

The binding rule, that `GROOM:` flags get handled as part of the current
session, lives in the node's `.agent/rules/contract.md` (from the preset's
Kernel and Continuity contract). The thresholds themselves live in one
place: the variables at the top of the node's own
`.agent/scripts/status.sh` (the operating model's design decisions
explain where each number came from). This skill is an optional
walkthrough of *how* to clear each flag; it adds no obligation beyond
what those two sources already state, and a node with no skills
installed grooms fine without it.

Start by running `.agent/scripts/status.sh` and reading the exact `GROOM:`
line: it names the file and the threshold it crossed. Handle each flag
below, then re-run `status.sh` to confirm it's clear.

## `session-log.md` over threshold

Entries are newest-last, one per line. Grooming is size-based, not
time-based: the dates inside entries are context for when something
happened, nothing else. Working from the top of the file (oldest first),
move the oldest entries, in original order, into
`.agent/archive/session-log-archive.md` (create it with a one-line
header comment if it doesn't exist yet), then delete those lines from
`session-log.md`. Keep roughly the newest half of the entry threshold in
place (the flag names the number) so the flag doesn't fire again next
session.

## A `memory/<slug>.md` fact file over the outlier threshold

The threshold is a review trigger, not a cap: a file this size likely
holds more than one fact. Re-read the file's own header contract first:
one fact per file. If it holds one fact that grew wordy, rewrite it
tighter in place: same filename, refreshed date. If it holds two facts
that would be superseded at different times, split it: run
`.agent/scripts/memory.sh new` for the second fact under a new slug, then
trim the original down to just the first fact. Both slugs end up indexed in
`memory.md`. If the fact cannot shrink without losing detail a future
session needs, move that detail to the matching `.agent/docs/` file and
cut the fact down to the decision plus a pointer.

## `memory.md` index over its review threshold

Read every index line. For facts that are stale, superseded, or no longer
true, drop the index line and move the fact file to `.agent/archive/`.
Groom by archiving, not deletion: in `ignore-all` and `track-shared` modes
`memory/` never enters git, so a deleted fact is gone for good, while an
archived one stays recoverable. Where two lines describe the same
underlying fact, consolidate into one `memory/<slug>.md`, then drop the
redundant line and archive its file. If every line is live and true,
nothing is wrong: raise the threshold at the top of the node's `status.sh`
instead of retiring good memory.

## `rules/learned.md` over its rule ceiling

The file's own header comment is the curation law; read it before editing.
Look for near-duplicate rules and fold them into one entry instead of
keeping both; grep for shared trigger words or subject matter across
entries as a starting point. For any entry that is really an area-specific
mechanic (a library, API, SQL, or CSS gotcha rather than a behavioral rule),
move it to the matching `.agent/docs/<area>.md` file under a `## Gotchas`
heading, in the same entry format, and leave at most a one-line pointer
behind if it's a cross-area hazard.

## A `docs/` area doc over its size threshold

The threshold is a review trigger: past it, the doc costs more to load
than most tasks need from it. Two moves, in order of preference:

1. Tighten in place: convert repeated invariant prose into tables or
   one-fact-per-line bullets, collapse near-duplicate sections, and keep
   every operational fact (names, values, commands, gotchas). The
   savings live in structure, not deletion.
2. Split by sub-area when one file genuinely covers several: create
   `docs/<area>/<sub-doc>.md` files via `.agent/scripts/docs.sh new
   --name <area>/<sub-doc> --read-when "…"` (each gets its own routing
   row), move each section's content to its sub-doc, then delete the
   original file and its routing row once every section has a home.
   Routing stays in the single `docs/architecture.md` table; a sub-doc
   loads only when its hook matches the task.

Re-run `status.sh` after either move.

## `memory/legacy.md` exists

This file is the mechanical output of `scripts/node.sh update`'s
memory-split migration: the node's pre-6.1 `memory.md` prose body, moved
verbatim. Read it, identify each distinct durable fact inside it, and run
`.agent/scripts/memory.sh new` once per fact (its own slug, title, hook;
keep each body as small as the fact allows; `status.sh` flags outliers
for review). Once every fact has a home, delete `memory/legacy.md` and
remove its index line from `memory.md` by hand: `memory.sh new` only
appends index lines, it doesn't remove this one.
