# learn.sh — the learned-record lookup and upsert helper

Finds the records under `<root>/.agent/rules/learned/` that already cover a discovery, writes a new one under a minted identity, and revises or retires an existing one only against the version it was read at. This is the mechanism alone: it enforces the record's own bullet grammar, refuses an exact duplicate, and stops a shared-term create for the agent's own judgment — it never decides whether two rules mean the same thing, whether a discovery is worth keeping, or which surface a discovery belongs to. Those decisions stay with the agent, guided by the preset's admission prose. `pending` and `resolve` extend this the same way, over the one-time backlog `node.sh update`'s migration could not classify on its own — see [Reconciling the migration backlog](#reconciling-the-migration-backlog) below.

```
Usage: learn.sh lookup   --file <path|-> [root]
       learn.sh new      --file <path|-> [--distinct] [--surface learned|memory|docs|gotchas] [root]
       learn.sh revise   <id> --file <path|-> --expected <version> [root]
       learn.sh retire   <id> --expected <version> [root]
       learn.sh pending  [root]
       learn.sh resolve  --id <id> --disposition <value> [root]
```

`root` defaults to `.` — the project root holding `.agent/`. A record lives at `<root>/.agent/rules/learned/<id>.md`; `<id>` is its filename without `.md`, a minted 12-character lowercase-hex identity — the same scheme `node.sh` mints during migration, so a record's identity never depends on where its text came from. `--file -` reads the candidate body from stdin, so a multi-line record never has to survive shell quoting as an argument string; omitting `--file` where a body is required is a usage error rather than a run that blocks on a terminal.

`<version>` is `git hash-object --no-filters -- <record>` of the record file — the same content digest `index.sh` already uses for every canonical source. Read it directly with `git hash-object --no-filters -- <root>/.agent/rules/learned/<id>.md`, or take it off a prior `lookup`, `new`, or `revise` result line. A record with no file on disk reads as the literal version `absent`. Passing `--expected absent` against an `<id>` nothing has written yet clears the ordinary stale check, since the current version is also the literal string `absent` — but `revise` and `retire` each then run a dedicated absent-record check and refuse at exit 2 rather than letting a create or a no-op through silently.

## Commands

- **`lookup`** — reports what already exists without writing anything. For every record byte-identical to the candidate, prints `duplicate\t<path>\t<version>`; for every record sharing nontrivial terms with it, prints `overlap\t<path>\t<version>`. Always exits 0, whether or not it found anything — it is a read, not a refusal.
- **`new`** — writes the candidate under a freshly minted identity. Refuses an exact duplicate of an existing record, and refuses a shared-term overlap unless `--distinct` is passed, naming every match either way. `--surface` defaults to `learned`; any other value is refused, naming the writer that actually owns that surface.
- **`revise`** — rewrites an existing record's body in place, keeping its filename (its identity) unchanged. Requires `--expected <version>`, checked against a fresh hash of the record on disk; a stale value refuses and prints the current one. A revise whose candidate is byte-identical to the record it targets — or to any other record — is the same duplicate refusal `new` gives, not a no-op success.
- **`retire`** — removes an existing record. Also requires `--expected <version>`, checked the same way.
- **`pending`** — lists the migration's open `semantic-review-pending` and `hook-missing` items from `<root>/.agent/migration-inventory.md`. A read, never a write; always exits 0. See [Reconciling the migration backlog](#reconciling-the-migration-backlog).
- **`resolve`** — closes one pending item by rewriting its disposition field, after checking that the disposition is already true of the node on disk. Never repairs a record or a doc itself. See [Reconciling the migration backlog](#reconciling-the-migration-backlog).

## Exit status

| Code | Meaning |
| --- | --- |
| 0 | success — the result line is on stdout; `lookup` and `pending` always return this |
| 2 | usage error, or an operation that could not be carried out (a filesystem failure, 100 consecutive identity collisions while minting, or a `resolve` precondition refusal) |
| 3 | stale `--expected` on `revise` or `retire` — stderr names the current version |
| 4 | judgment required — `new` found a shared-term overlap without `--distinct` |
| 5 | exact duplicate — the candidate is byte-identical to a record that already holds it |
| 6 | malformed candidate — the body is not exactly one top-level `- [YYYY-MM-DD] ` bullet |
| 7 | surface refusal — the record directory does not exist yet, or the candidate names another surface |

1 is never returned. Among the shipped scripts it means "a finding"; this helper reports none of its own — every outcome above is either a write or a refusal, never a judgment call it renders on someone else's behalf.

## The record grammar it enforces

A candidate must be exactly one top-level `- [YYYY-MM-DD] <imperative rule>. Trigger: <cause, optional>.` bullet, plus whatever continuation lines (indented sub-bullets, a blank line and a further paragraph) belong to that same bullet — the format `node.sh init` writes into `rules/learned.md` and every preset mirrors. A second top-level bullet, a frontmatter block, or a Markdown heading anywhere in the body is refused before anything is written. The preset's "imperative, ≤40 words" line is a curation rule, not a parser rule: a candidate over that ceiling warns on stderr and is still written, since reconciling a pre-existing record that predates the ceiling must not become impossible.

A record file holds its bullet span verbatim and nothing else: no `id:` line, no heading, no header of any kind. `index.sh` concatenates every record's body behind one shared header to regenerate `rules/learned.md`, so anything a record carried beyond its rule text would render into that file and into every rule page built from it.

## Duplicate and overlap

Two candidates are compared byte for byte for the duplicate check, and by shared nontrivial terms for the overlap check: lowercase, strip everything but letters and digits, keep words over two characters that are not on a short stopword list — `trigger` among them, since the record format's own `Trigger:` label would otherwise overlap almost every pair regardless of subject, at the cost that a rule genuinely about a database trigger loses that word as a retrieval term too — and look for any term both texts share. The leading `- [YYYY-MM-DD] ` date is stripped before that scan runs, since every record carries one and it is provenance, not retrieval text. A word this scan cannot find because it never made it into the rule's own wording is why the curation guidance asks for retrieval terms to be written into the imperative itself, not left implicit.

## What it deliberately does not decide

Whether two candidates are synonymous, contradictory, or genuinely distinct once they overlap; whether a discovery is worth recording at all; and which surface — `rules/learned/`, a memory fact, a routed doc, or an area doc's own `## Gotchas` section — a discovery belongs to in the first place. `--surface` only lets the caller state that decision so `learn.sh` can refuse to act on it; it never makes the decision itself.

## After a write

When `<root>/.agent/purpose.md` says `indexes: generated`, a successful `new`, `revise`, or `retire` runs the node's own `.agent/scripts/index.sh ensure` so the regenerated `rules/learned.md` and any cached pages reflect the write immediately. An absent or failing indexer prints one warning naming `.agent/rules/` and `.agent/docs/` as the canonical read path and does not change `learn.sh`'s own exit status — a cache fault is not a defect, and a freshly cloned or gitignored worktree can have no indexer installed yet.

## Reconciling the migration backlog

`node.sh update`'s one-time migration marks a rule record `semantic-review-pending` when its span carried an indented sub-bullet or a second paragraph after a blank line — a shape a mechanical split cannot safely resolve on its own — and marks a doc `hook-missing` when it could not trust `architecture.md` enough to backfill the doc's own `<!-- Read when: … -->` header. Both classes are recorded, verbatim, as the last field of one line in `<root>/.agent/migration-inventory.md`. `pending` lists every open line from that file; `resolve` closes one, after the agent has done the actual work outside this script. Neither command judges: `pending` is a read, and `resolve` only checks that the fact it is about to record is already true of the node on disk.

### `pending`

`learn.sh pending [root]` prints one line per item still `semantic-review-pending` or `hook-missing`:

```
<label> | <disposition> | <path> | version=<value>
```

`<label>` and `<path>` are the inventory's own fields: `<label>` is everything on the item's line before its `id=` field, `<path>` is that field's value. A rule item's `<value>` is a fresh `git hash-object --no-filters --` of its own record, so a caller always resolves against the version actually on disk; a doc item — which has no record of its own — prints `version=-`. The listing ends with one line reading `<n> pending`. It exits 0 with no output at all, not even a `0 pending` line, when `migration-inventory.md` is absent or carries no pending item — printing nothing is how a caller tells "checked, nothing open" apart from a run that failed before it checked. `pending` never writes.

### `resolve`

`learn.sh resolve --id <id> --disposition <value> [root]` rewrites one item line's disposition field, matched by an exact comparison against that line's `id=<id>` field — never a whole-line pattern. Nothing else in the file changes: not that line's label or location, not any other line, not the title or the prose above the items.

Accepted `--disposition` values:

- **`migrated`** — the item is closed as-is. On a rule item this asserts its own record still exists under its original identity; on a doc item it asserts the doc's first five lines now carry a `<!-- Read when: … -->` header — the same predicate `backfill_doc_hook` used to mark it `hook-missing` in the first place.
- **`migrated (split into <id>[, <id>]…)`** — rule-only. Asserts a record exists at `rules/learned/<id>.md` for every identity named. The item's own original identity is never one of them: a split revises the original record in place and mints the other half under a new identity, so the original continuing to exist is exactly what a plain `migrated` on that same id already means.
- **`migrated (merged into <id>)`** — rule-only. Asserts a record exists at `rules/learned/<id>.md`, the surviving target. What becomes of the item's own record is the agent's call — usually retired once its content is folded in, sometimes left in place — and `resolve` does not check either way.
- **`retired`** — rule-only. Asserts the item's own record no longer exists at `rules/learned/<id>.md`.

Split, merge, and retired are refused on a doc item, named as the three rule-only forms: a doc has no record to split or merge, and nothing in the learning corpus deletes a doc, so `retired` would assert something no command performs.

`resolve` never creates, edits, splits, merges, or deletes a record or a doc — it only checks that the disposition it is about to write down is already true, then writes it down. The agent does the actual work first, with the ordinary write commands: `new` and `revise` for a split, `revise` and `retire` for a merge, `retire` alone for a retirement. Every refusal below names what it checked and writes nothing:

- `--id` or `--disposition` missing.
- `migration-inventory.md` absent.
- the id matches no line, or matches more than one line — the latter only reachable by hand-editing the inventory, since nothing else can put one id on two lines.
- the matched item's current disposition is neither `semantic-review-pending` nor `hook-missing` — it was already resolved, or was never pending.
- `--disposition` is not one of the four accepted forms, or names something that is not a 12-lowercase-hex identity.
- split, merge, or retired named against a doc item.
- the on-disk check for the accepted form and item type fails: a named identity has no record file, a `retired` rule item's record still exists, or a `migrated` doc's first five lines still carry no `<!-- Read when: … -->` header.

Every usage error and every refusal above exits at code 2, the same "usage error, or an operation that could not be carried out" class the rest of `learn.sh` already uses — see Exit status above.

### Repairing a `hook-missing` doc

`docs.sh rehook --name <file> --read-when "…"` cannot repair a `hook-missing` doc by itself: it refuses unless the doc's first five lines already carry `Read when:` text, and refuses unless `architecture.md` already carries a `### \`<file>\`` entry — both true of a doc a session simply failed to reach with the right hook text, neither true of a doc the migration left byte-identical. Widening `rehook` to accept a headerless doc would change a shipped command's contract for every other caller, and would still leave half of `architecture.md`'s possible faults — a duplicate entry, an entry with no `- **Read when:**` line — unfixed, since those live on the routing side a doc-only patch cannot reach.

The repair is three hand edits, done before `resolve` is ever called:

1. Fix `architecture.md`: delete a duplicate `### \`<file>\`` entry down to exactly one, add a `- **Read when:**` line under an entry that has none, or add a whole entry (heading and `- **Read when:**` line) for a doc with none at all.
2. Prepend the doc's own `<!-- Read when: … -->` line by hand — any placeholder text; `rehook` overwrites it next.
3. Run `docs.sh rehook --name <file> --read-when "…"` with the real hook text. It rewrites the doc's header and the entry's `- **Read when:**` line together from that one value — the point of running it last, so the two texts come from one value instead of two hand edits that could drift.

Only then does `resolve --id <file> --disposition migrated` close the line, checking the same header predicate the migration used to open it — never repairing anything itself.

### Why the shell refuses to judge, and why this is one-time

Whether a nested sub-bullet is really two separate rules, whether two rules mean the same thing and should merge, and what a doc's `Read when:` hook should actually say are calls only the agent can make — exactly why `classify_rule_span` and `backfill_doc_hook` stopped short and left the item pending rather than guessing. `pending` and `resolve` exist only to make that backlog visible and closeable, not to shrink it themselves. `migrate_learned_and_docs` is a no-op on any node whose `rules/learned/` already holds a record, so this backlog opens exactly once per node, at the update that first migrates it; a node with no pending items has nothing left for either command to do, and neither runs as part of any later bootstrap or update.
