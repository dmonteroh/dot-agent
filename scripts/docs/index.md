# index.sh — the generated-mode index cache

Refreshes bounded Markdown indexes under `<root>/.agent/indexes/` before an agent reads them, and reuses a verified prior build when nothing that feeds it has changed. Not yet wired into bootstrap or `finish.sh` — that is F16's task. This is the mechanism alone: two operations, a fingerprint, and an atomic publish.

```
Usage: index.sh ensure [--root <path>] [--budget <bytes>]
       index.sh check  [--root <path>] [--budget <bytes>]
```

`root` defaults to `.`. `budget` defaults to 30000 and bounds every generated page and the entry file, in bytes (256..1000000).

`ensure` validates the cache against the canonical sources and republishes if anything changed, then prints one absolute path — `<root>/.agent/indexes/current.md` — to stdout. `check` runs the same validation but never writes: it prints `FRESH` or `STALE` to stdout and nothing else. Both put `HIT`/`BUILT`/`FRESH`/`STALE` and every diagnostic on stderr. Neither ever prints a rule body or a routing table to stdout — only the bounded status above. On a failed `ensure`, stderr names the canonical source directories to read instead, and the previous entry (if any) is left exactly as it was.

## Exit status

| | 0 | 1 | 2 |
|---|---|---|---|
| `ensure` | HIT or BUILT — the entry path is on stdout | refresh failed; canonical sources named on stderr, prior entry untouched | usage error: bad flags, a budget outside 256..1000000, or a root with no `.agent/` |
| `check` | FRESH | STALE | usage error, same as `ensure` |

`check` needs its own non-zero code for "not fresh" the same way `ensure` needs one for "could not publish": a caller must tell "read the canonical sources, this is stale" apart from "the arguments were wrong," or a broken invocation reads as a stale-but-otherwise-healthy cache.

## Canonical sources and the grammar F15 adapts records to

Every `*.md` file under `<root>/.agent/rules/` or `<root>/.agent/docs/` (recursively, sub-docs included) is a canonical source record, with one named exception: whenever `<root>/.agent/rules/learned/` exists and holds at least one `*.md` file, those files are the canonical source records and `<root>/.agent/rules/learned.md` is excluded from the source set instead — see "The learned-rules aggregate" below. Everything else in the project is out of scope — index.sh never reads it.

### The learned-rules aggregate

`status.sh` still reads a single `<root>/.agent/rules/learned.md` file for its REPAIR, GROOM, and payload checks; it does not yet know about `<root>/.agent/rules/learned/`. So that a node which moves its rules under `rules/learned/` does not look broken the moment it does, `ensure` regenerates `rules/learned.md` — whenever `rules/learned/` holds at least one record — as a lossless, path-sorted concatenation of those records' bodies behind the same fixed header `node.sh init` writes today, and publishes it with the same write-then-same-directory-rename mechanism the entry file uses: a reader never sees a half-written aggregate, a failed `ensure` leaves the previous aggregate exactly as it was, and the write is skipped entirely when the recomputed bytes already match. `rules/learned.md` is excluded from both the source-record set above and the fingerprint that decides whether a rebuild is needed — the aggregate is derived, never a source, and it is gitignored.

This is the only write `ensure` performs outside `<root>/.agent/indexes/`, and it is transitional: `check` never performs it (or any other write), and it exists only because `status.sh` cannot yet be taught the `rules/learned/` shape. It goes away once `status.sh` reads the record directory directly.

A record's directory decides how it renders:

- **`.agent/rules/**/*.md`** — a *rule record*. Its complete body is copied verbatim into a rule page behind one `Source: <absolute path>` line. Nothing here is ever truncated or summarized; a rule record too large to fit in one page fails the build (see Failure modes) rather than splitting a rule's meaning across a page boundary.
- **`.agent/docs/**/*.md`** — a *route record*. It contributes one line to a routes page: `- <title> | <hook> | READ: <absolute path>`, where title is the record's first `# ` heading (or its path, if it has none) and hook is the payload of its first `<!-- Read when: ... -->` comment (or `(no hook)`, if it has none) — the same header `docs.sh` already writes for every doc.

This is the whole grammar: one heading, one optional hook comment, and relative Markdown links inside rule bodies rewritten to their canonical location (below) — nothing else index.sh parses. F15 adapts the node's real `rules/` and `docs/` files to it; this task only proves the mechanism against disposable fixtures and pins the grammar with parser fixtures in `scripts/test.sh` (heading present/absent, hook present/absent, multi-line rule bodies) before the render tests build on it.

### Relative links inside a rule body

A rule page is a rule record's complete body copied behind its `Source:` line — but a generated page lives at `<root>/.agent/indexes/gen.XXXXXXXX/rules-N.md`, not at the record's own path under `.agent/rules/`, so a relative Markdown link (`[text](relative/path)`) copied unchanged would resolve against the wrong directory once read from there. Rendering rewrites every such link's target to an absolute path back to its original location — resolved against the record's own directory under `.agent/rules/`, with `.`/`..` segments collapsed the way a filesystem would. A `#fragment` on the link is preserved. Three kinds of link are left untouched: an already-absolute path (`/...`), a `#`-only anchor, and any URL with a scheme (`https:`, `mailto:`, ...). This is the only content transformation rendering ever performs on a rule body; everything else about it is copied verbatim.

Relative source names allow ASCII letters, digits, `_`, `.`, `/`, and `-` only, and a symlink anywhere under `.agent/rules/` or `.agent/docs/` is rejected outright. Both cause a failed `ensure` (a fallback naming the canonical directories) rather than a silently skipped record.

## The entry file and direct page links

`<root>/.agent/indexes/current.md` holds, in order:

1. the fingerprint (one hash),
2. the generation name (`gen.XXXXXXXX`),
3. a tree digest binding every published page's name to its bytes,
4. a blank line, then
5. one `READ: <absolute path>` line per generated page.

Every page link is direct — the entry itself is the index. There is no separate `index.md` inside the generation directory a reader has to open first to find the page names; the interface this task ships against asked for exactly one hop from "read the entry" to "read a page."

## Fingerprint and generation directories

The fingerprint is a single hash over: the generator's own bytes (`git hash-object` of `index.sh` itself), the render configuration (schema version and `--budget`), the absolute project root, the sorted list of every canonical source's project-relative path, and each one's content hash (`git hash-object`, not its mtime or size — a same-length edit that preserves the file's timestamp still changes this hash). Changing any of these — the generator, the budget, a source's bytes, or the source set itself (an add, a rename, or a delete) — changes the fingerprint and invalidates the cache. None of this writes a git object; hashing is a pure content digest run whether or not `<root>` is a git repository at all.

Each build renders into a fresh, uniquely named `<root>/.agent/indexes/gen.XXXXXXXX/` directory (from `mktemp -d`) and never touches an existing one. Generations are immutable once rendering finishes: nothing about them changes after that point, including under bounded cleanup (below). Publication is one same-filesystem `mv -f` of a temp file onto `current.md`, so a reader never observes a partially written entry, and a build that dies at any point before that rename leaves the previous entry (if any) exactly as it was — there is nothing to roll back because nothing visible was touched.

## Cache-hit verification

A hit is not "the fingerprint on line one matches." It is: the fingerprint matches, the referenced generation directory exists, its recomputed tree digest matches the recorded one (so a damaged or deleted page is caught), and reconstructing the entry's expected bytes for that generation today reproduces the file's actual bytes exactly (so tampering with `current.md` itself — not just a page — is caught too). Anything short of all four is a rebuild, never a partial or best-effort reuse.

## Concurrent refreshes and interrupted publication

No writer takes a lock. Each build's generation directory is unique by construction (`mktemp -d`), so concurrent writers never collide, and each publishes by the same atomic rename, so the last one to finish simply becomes current — no writer can see, let alone publish, a mix of another writer's pages. A writer killed mid-build (any signal, any point before its `mv -f`) leaves nothing published: the trap on exit removes its own unpublished generation directory, and the existing entry (if any) is exactly what it was before that writer started. The next `ensure`, from any process, rebuilds cleanly with no lock file to recover or break.

## Bounded retries on a moving target

Before publishing, a build re-fingerprints the sources it just rendered and compares that to the fingerprint it started from. A mismatch means something changed mid-render, so the render is discarded and retried — up to 5 attempts — rather than either publishing a page set that never matched any single point-in-time state, or failing on the first transient overlap with an unrelated writer. Exhausting the bound reports the count and falls back; the previous entry, if any, is untouched throughout.

## Bounded cleanup

After a successful publish, index.sh sweeps `<root>/.agent/indexes/` for other `gen.*` directories and removes the ones that are neither the generation it just published nor the one that entry replaced, and only once they are at least `INDEX_CLEANUP_AGE_SECONDS` old (default 300; override via that environment variable, mainly for tests). The two most recent generations are always exempt regardless of age, so a reader who has just read an entry and is about to open its pages is never racing a cleanup pass — cleanup only reaches generations at least one full publish cycle stale, and only well after any realistic concurrent build could still be relying on them. Immediately before removing each candidate, cleanup also re-reads `current.md`'s generation line rather than trusting the name recorded at publish time, so a generation some other writer has since published over `current.md` is never swept out from under it even if it is neither of the two names this build knew about. This still leaves a genuinely idle project's cache directory holding at most two live generations at a time; nothing here is a general-purpose garbage collector, and a crash-abandoned generation from an otherwise-idle project waits for the next `ensure` to be swept.

## Failure modes

Every failure prints one `ERROR:` line and one `FALLBACK:` line to stderr naming `<root>/.agent/rules/` and `<root>/.agent/docs/` as the canonical read path, then exits 1 (`ensure`) having touched nothing publishable. This covers: a source symlink or an unsupported filename, a rule or route record whose own content cannot fit in a single page even at the page budget (never truncated to fit), a rendered page index too large for the budget, an entry that would exceed the budget once every page link is included, sources that keep changing across every retry attempt, and any filesystem failure the surrounding commands did not already guard explicitly (a full disk, a permissions error, and so on) — the top-level `ERR` trap turns any of those into the same fallback rather than a silent partial write.

## Known limits

- Freshness means "matched the fingerprint checked immediately before this build," not a transactional filesystem snapshot; a change that lands between that check and publication is caught by the next `ensure`, not this one (the bounded-retry recheck narrows, but cannot close, that window).
- Bounded cleanup is not garbage collection: an idle project's cache can hold two full generations indefinitely, and nothing here reclaims disk if `ensure` is never run again.
- Bounded cleanup re-checks `current.md` right before each removal (above), so it cannot sweep whatever generation is published at that instant — but it still cannot protect a reader that already read an *older* entry and opened one of that entry's pages before a later publish's cleanup pass ran. That reader holds a path, not a lock; nothing in this mechanism tracks who is reading which generation, so an old generation can still be removed out from under a reader slow enough to still be consuming it two full publish cycles later.
- Hash validation catches accidental damage — a truncated page, a stray edit to `current.md` — not a writer that controls both the cache directory and the entry's own hashes.
- This mechanism does not install itself, migrate existing `rules/`/`docs/` records to the grammar above, or wire into bootstrap: F15 and F16, respectively.
- A link label containing a nested `[...]` (e.g. `[a [nested] label](weird.md)`) is not recognized as a link at all, so its still-relative target is left unrewritten and will not resolve once the page moves.
- [`index-benchmark.md`](index-benchmark.md) records measured median/p95 latency at 100 and 1,000 records and an honest comparison against the spike's numbers, including why that comparison is not apples-to-apples.
