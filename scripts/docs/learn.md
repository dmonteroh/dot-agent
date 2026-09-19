# learn.sh — the learned-record lookup and upsert helper

Finds the records under `<root>/.agent/rules/learned/` that already cover a discovery, writes a new one under a minted identity, and revises or retires an existing one only against the version it was read at. This is the mechanism alone: it enforces the record's own bullet grammar, refuses an exact duplicate, and stops a shared-term create for the agent's own judgment — it never decides whether two rules mean the same thing, whether a discovery is worth keeping, or which surface a discovery belongs to. Those decisions stay with the agent, guided by the preset's admission prose.

```
Usage: learn.sh lookup  --file <path|-> [root]
       learn.sh new     --file <path|-> [--distinct] [--surface learned|memory|docs|gotchas] [root]
       learn.sh revise  <id> --file <path|-> --expected <version> [root]
       learn.sh retire  <id> --expected <version> [root]
```

`root` defaults to `.` — the project root holding `.agent/`. A record lives at `<root>/.agent/rules/learned/<id>.md`; `<id>` is its filename without `.md`, a minted 12-character lowercase-hex identity — the same scheme `node.sh` mints during migration, so a record's identity never depends on where its text came from. `--file -` reads the candidate body from stdin, so a multi-line record never has to survive shell quoting as an argument string; omitting `--file` where a body is required is a usage error rather than a run that blocks on a terminal.

`<version>` is `git hash-object --no-filters -- <record>` of the record file — the same content digest `index.sh` already uses for every canonical source. Read it directly with `git hash-object --no-filters -- <root>/.agent/rules/learned/<id>.md`, or take it off a prior `lookup`, `new`, or `revise` result line. A record with no file on disk reads as the literal version `absent`. Passing `--expected absent` against an `<id>` nothing has written yet clears the ordinary stale check, since the current version is also the literal string `absent` — but `revise` and `retire` each then run a dedicated absent-record check and refuse at exit 2 rather than letting a create or a no-op through silently.

## Commands

- **`lookup`** — reports what already exists without writing anything. For every record byte-identical to the candidate, prints `duplicate\t<path>\t<version>`; for every record sharing nontrivial terms with it, prints `overlap\t<path>\t<version>`. Always exits 0, whether or not it found anything — it is a read, not a refusal.
- **`new`** — writes the candidate under a freshly minted identity. Refuses an exact duplicate of an existing record, and refuses a shared-term overlap unless `--distinct` is passed, naming every match either way. `--surface` defaults to `learned`; any other value is refused, naming the writer that actually owns that surface.
- **`revise`** — rewrites an existing record's body in place, keeping its filename (its identity) unchanged. Requires `--expected <version>`, checked against a fresh hash of the record on disk; a stale value refuses and prints the current one. A revise whose candidate is byte-identical to the record it targets — or to any other record — is the same duplicate refusal `new` gives, not a no-op success.
- **`retire`** — removes an existing record. Also requires `--expected <version>`, checked the same way.

## Exit status

| Code | Meaning |
| --- | --- |
| 0 | success — the result line is on stdout; `lookup` always returns this |
| 2 | usage error, or an operation that could not be carried out (a filesystem failure, or 100 consecutive identity collisions while minting) |
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
