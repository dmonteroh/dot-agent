# memory.sh — the fact writer

Scaffolds a fact file and its `memory.md` index line as one operation. This is a two-place write that drifts when done by hand. The point of the script is to make that drift impossible, not just to detect it. (`status.sh`'s `REPAIR:` check does the detecting for facts written by hand.)

```
Usage: memory.sh lookup --query <text> [--limit <n>] [root]
       memory.sh new --slug <slug> --title <title> --hook <hook> (--fact "…" | --file <path|->) \
         [--scope <project|package|root>] [--type <fact|reference>] [root]
       memory.sh supersede --slug <slug> (--fact "…" | --file <path|->) \
         [--expected <digest>] \
         [--scope <project|package|root>] [--type <fact|reference>] [root]
```

`root` defaults to `.` and `scope` defaults to `project`, `type` to `fact`. Writes `<root>/.agent/memory/<slug>.md` and appends its index line to `<root>/.agent/memory.md` — both or neither: every check runs before any write happens.

No size gate. Writes are never refused for length. `status.sh` flags outliers on the load path for grooming.

`--file -` reads a multi-line body from standard input. `--fact` remains available for compatibility. Exactly one body source is accepted. Writes are staged beside their targets and renamed into place.

## Canonical lookup

`lookup` searches the initialized node's purpose, rules, memory index, fact files, and explicitly routed docs. The rules include manual `rules/learned.md` or generated `rules/learned/*.md` records. `docs/architecture.md` identifies the routed docs. It never scans the project generally or the user's home. The default limit is 20 and the accepted range is 1–100. When more matches exist, stdout remains records only and one stderr notice reports shown/total counts plus the larger `--limit` to try.

Each result is `exact|overlap<TAB>.agent/path<TAB>version<TAB>excerpt`. Paths are project-relative, versions are Git object digests, and excerpts are single-line and capped at 240 characters. Case-insensitive phrase and identifier matches are emitted before shared-term overlaps. No output means no canonical match. It does not grant permission to write.

## Superseding

`memory.sh supersede --slug <slug> --fact "…"` rewrites an existing fact file's body and restamps its `date` frontmatter to today. The filename is kept, which is what makes it a supersede rather than a new fact, and the `memory.md` index line is left alone — a superseded fact usually keeps the same title and hook, and when it does not, that line is one hand edit. `scope` and `type` carry forward from the file unless `--scope` or `--type` overrides them.

`--expected <digest>` compares a fresh `git hash-object --no-filters --` digest during validation and rechecks it immediately before replacing the file. A stale value refuses at exit 3 and prints the current version. This is optimistic stale-write protection, not an atomic compare-and-swap against noncooperating writers: the final check and rename are still separate filesystem operations. Omitting it retains the legacy supersede behavior.

It refuses a fact file that does not exist (use `new`) and one `memory.md` does not index. The second refusal is the point: rewriting an unindexed file leaves the two-place write exactly as split as writing it by hand does. Add the index line, then supersede.

The rewrite goes to a temporary file beside the fact and is renamed over it, so a write that fails leaves the previous fact intact rather than half-gone.

## The fact file carries no header contract

It holds its frontmatter and the fact, and nothing else. Every other canonical file carries its own contract because there is one of it. `memory/` is the only tier with N files, where a header is paid once per fact and outweighs the fact itself. The contract lives once in `memory.md`'s header, which loads every session and is the tier's index.

`memory.sh` also states the contract in its own output, where it reaches the session doing the writing instead of every later read.

Before writing, search `purpose.md`, `rules/`, routed docs, relevant source, and existing facts. If one already states the knowledge, update that source or its routing and write no fact. Stable knowledge about how the system works belongs in `docs/`. `architecture.md` already routes it, so memory adds no pointer. A harness or tool defect fixed at its source creates no compensating fact.
