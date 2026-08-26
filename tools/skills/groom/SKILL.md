---
name: groom
description: "Clears the GROOM: flags .agent/scripts/status.sh prints — one procedure per flagged file (session-log.md, a memory/*.md fact, the memory.md index, rules/learned.md, an oversized docs/ file, memory/legacy.md) — and runs the on-demand orphan/broken-link audit. Use when a status check prints a GROOM: line, or when auditing a node's links."
---

# Grooming `.agent/`

The binding rule — that `GROOM:` flags get handled as part of the current session — lives in the node's `.agent/rules/contract.md`. It comes from the preset's Kernel and Continuity contract. The threshold defaults live at the top of the node's own `.agent/scripts/status.sh`. The operating model's design decisions explain where each number came from. A project tunes them in `.agent/scripts/status.conf`, which survives `node.sh update`. Script edits don't.

This skill is an optional walkthrough of *how* to clear each flag. It adds no obligation beyond what those two sources already state. A node with no skills installed grooms fine without it.

## Use this skill when

`.agent/scripts/status.sh` printed a `GROOM:` line, or the operator asked for a link audit (`links.sh`).

## Do not use this skill when

- The flag is `REPAIR:` or `INDEX:` — each names its own fix in the flag text. Neither is grooming, and `REPAIR:` stays in the main session.
- No flag stands and nobody asked for an audit. Thresholds are review triggers, and grooming ahead of them trades signal for churn.
- A threshold itself seems wrong — that is a `status.conf` tuning decision for the operator, not a grooming step.

This skill also works as a subagent brief. Per the contract's subagent rule, a session may delegate its `GROOM:` flags to one dispatched worker. Assign that worker explicitly to write only the flagged files. A small model such as Haiku is fine. The scripts do the exacting parts. Pass the worker the `GROOM:` lines and this file. Then re-run `status.sh` yourself. The cleared flag is the confirmation, not the worker's report.

Start by running `.agent/scripts/status.sh`. Read the exact `GROOM:` line: it names the file and the threshold it crossed. Handle each flag below. Then re-run `status.sh` to confirm it's clear.

## `session-log.md` over threshold

Entries are newest-last, one per line. Grooming is size-based, not time-based. The dates inside entries are context for when something happened, nothing else.

Work from the top of the file, oldest first. Move the oldest entries, in original order, into `.agent/archive/session-log-archive.md`. Create that file with a one-line header comment if it doesn't exist yet. Then delete those moved lines from `session-log.md`. Keep roughly the newest half of the entry threshold in place, so the flag doesn't fire again next session. The flag names the number.

The entry-shape flag (`entries over N words`) is a different fix. The flagged entries breached the header format's per-entry ceiling — usually hand-written narratives that bypassed `log.sh`. Rewrite each to the header template: task, area, outcome, ≤25 words, `verify:` field. Route any durable detail the narrative carried to `memory/`, if it passes the retention test, or to the matching `docs/` file. Most of it is transcript, and transcript is dropped, not moved.

This flag is a per-session cost, not cosmetics. Oversized entries ride the status check's printed tail into every session's context.

## A `memory/<slug>.md` fact file over the outlier threshold

The threshold is a review trigger, not a cap. A file this size likely holds more than one fact. Re-read the contract in `memory.md`'s header, which covers every file in `memory/`. It requires one fact per file, kept only while work in this node changes when it is true.

If the file holds one fact that grew wordy, rewrite it tighter in place: same filename, refreshed date. If it holds two facts that would be superseded at different times, split it. Run `.agent/scripts/memory.sh new` for the second fact under a new slug. Then trim the original down to just the first fact. Both slugs end up indexed in `memory.md`.

If the fact cannot shrink without losing detail a future session needs, move that detail to the matching `.agent/docs/` file. Cut the fact down to the decision plus a pointer.

## `memory.md` index over its review threshold

Read every index line. For facts that are stale, superseded, or no longer true, drop the index line. Move the fact file to `.agent/archive/`. Groom by archiving, not deletion. In `ignore-all` and `track-shared` modes `memory/` never enters git. A deleted fact is gone for good, while an archived one stays recoverable.

Where two lines describe the same underlying fact, consolidate into one `memory/<slug>.md`. Then drop the redundant line and archive its file. If every line is live and true, nothing is wrong. Raise the threshold at the top of the node's `status.sh` instead of retiring good memory.

## `rules/learned.md` over its rule ceiling or word trigger

The file's own header comment is the curation law. Read it before editing. Look for near-duplicate rules and fold them into one entry instead of keeping both. Grep for shared trigger words or subject matter across entries as a starting point.

Some entries are really an area-specific mechanic: a library, API, SQL, or CSS gotcha rather than a behavioral rule. Move each of those to the matching `.agent/docs/<area>.md` file, under a `## Gotchas` heading and in the same entry format. Leave at most a one-line pointer behind if it's a cross-area hazard.

The word trigger fires under the rule ceiling and means something different. The entries themselves are over the file's ~40-word target. Compress them in place rather than retiring rules. An entry that needs its incident retold is not distilled yet. Domain detail past the target belongs in the matching `.agent/docs/` file, with a pointer left here. This file is always-loaded with no tier below it. So every word here is paid in every session on the project.

## A `docs/` area doc over its size threshold

The threshold is a review trigger. Past it, the doc costs more to load than most tasks need from it. This is the one grooming flag whose fix is lossy by default. So the doc's own header contract states the invariant: **restructuring changes shape, never content.** The savings come from structure — no operational fact is dropped to hit a word count. Read the file in full before editing it. Work the two moves in this order:

1. Tighten in place. Convert repeated "X is/does/lives-in Y" invariant prose into a table (`Concern | Rule | Where`) or one-fact-per-line bullets. Collapse a multi-sentence paragraph that states one fact into one terse bullet. Group near-duplicate mini-sections under one heading. Telegraphic style is right here — fragments, colons, arrows. Prose survives only where it carries the *why*.
2. Split by sub-area when one file genuinely covers several. Create `docs/<area>/<sub-doc>.md` files via `.agent/scripts/docs.sh new --name <area>/<sub-doc> --read-when "…"`. Each gets its own routing entry. Move each section's content to its sub-doc. Then delete the original file and its routing entry, once every section has a home. Routing stays in the single `docs/architecture.md` table. A sub-doc loads only when its hook matches the task.

3. Move irreducible depth out of the routed layer. Some material has its value in being complete rather than in being read. Examples include a full schema, an exhaustive option or error-code table, and a worked example. That material goes to `docs/<area>/references/<name>.md`, cited by path from the area doc in the same edit. Reference files carry no `Read when:` header, get no routing entry, and have no size trigger. `status.sh` skips them. Use this move when tightening would cost facts and splitting would only spread the same bulk across more routed docs.

Split only what covers several *areas*. A doc covering one area in many facets stays whole where its sections share invariants and get read together. Tighten it instead. Splitting it fragments the invariants and costs more routing entries than it saves.

Either move changes the doc's headings. So finish by refreshing its `architecture.md` entry: the `Sections:` list, and the hook if the doc's scope moved. `status.sh` flags both, so re-running it is the check.

## Proving a doc restructuring dropped nothing

A word count falling is not evidence the pass was lossless — it is equally consistent with having deleted content. Prove it instead of asserting it.

Before editing, copy the doc aside with `cp` to a scratch path outside the node. List its anchors: every identifier, numeric value, command, config key, path, route, and code fence in it. Grep the rewritten file for each anchor and confirm it survives. A `## Gotchas` bullet that vanished is a failure, not a saving. Report the before/after body-word counts *and* the anchor check together. The counts show the gain, and the anchor check is what makes the gain safe. Delete the scratch copy once the check passes.

When this flag is delegated, the worker owes the orchestrator both numbers and the anchor result. The orchestrator then re-runs `status.sh`. A doc whose facts genuinely no longer fit under the threshold splits (move 2). It does not get trimmed to fit.

Re-run `status.sh` after either move.

## The link audit, when you have the node open anyway

`status.sh` never reports orphans: an uncited file costs nothing to load, so it has no place on the load path. Grooming is when it is worth knowing. Run `.agent/scripts/links.sh` and read the two findings it prints:

- `ORPHAN:` — nothing in the node cites this file. For a `docs/<area>/references/` file this is the failure the tier is exposed to. It carries no routing entry, so uncited means unreachable. Cite it from its area doc, or retire it to `archive/` if the area no longer needs it. Elsewhere, an orphan is a question rather than a defect — decide, don't reflexively delete.
- `BROKEN:` — this file cites a node path that does not exist. Usually a rename that missed a reference, or a doc split whose old path survived in a sibling. Fix the citation. If the target is genuinely gone, remove the sentence that points at it rather than leaving a dead path.

It is advisory and always exits 0. Paths outside `.agent/` are out of scope. The session log, `archive/`, and `rules/` are not read as citation sources. So what it prints is the node's own graph.

## `memory/legacy.md` exists

This file is the mechanical output of `scripts/node.sh update`'s memory-split migration. It holds the node's pre-6.1 `memory.md` prose body, moved verbatim.

Read it and identify each distinct durable fact inside it. Run `.agent/scripts/memory.sh new` once per fact, with its own slug, title, and hook. Keep each body as small as the fact allows. `status.sh` flags outliers for review.

A split is not a shape migration. Each fact faces the retention test on the way through. A fact that no longer changes any work here is dropped rather than carried into a new file. A tool this project stopped using and another repo's configuration are both examples. The first field split kept a fact about a skill the repo does not use. It survived two rounds of review before anyone asked what it was for.

Once every fact has a home, delete `memory/legacy.md`. Remove its index line from `memory.md` by hand. `memory.sh new` only appends index lines, and it doesn't remove this one.
