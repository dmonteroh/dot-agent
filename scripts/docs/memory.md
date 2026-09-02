# memory.sh — the fact writer

Scaffolds a fact file and its `memory.md` index line as one operation. This is a two-place write that drifts when done by hand. The point of the script is to make that drift impossible, not just to detect it. (`status.sh`'s `REPAIR:` check does the detecting for facts written by hand.)

```
Usage: memory.sh new --slug <slug> --title <title> --hook <hook> --fact "…" \
         [--scope <project|package|root>] [--type <fact|reference>] [root]
```

`root` defaults to `.` and `scope` defaults to `project`, `type` to `fact`. Writes `<root>/.agent/memory/<slug>.md` and appends its index line to `<root>/.agent/memory.md` — both or neither: every check runs before any write happens.

No size gate. Writes are never refused for length. `status.sh` flags outliers on the load path for grooming.

## The fact file carries no header contract

It holds its frontmatter and the fact, and nothing else. Every other canonical file carries its own contract because there is one of it. `memory/` is the only tier with N files, where a header is paid once per fact and outweighs the fact itself. The contract lives once in `memory.md`'s header, which loads every session and is the tier's index.

`memory.sh` also states the contract in its own output, where it reaches the session doing the writing instead of every later read.

Before writing, search `purpose.md`, `rules/`, routed docs, relevant source, and existing facts. If one already states the knowledge, update that source or its routing and write no fact. Stable knowledge about how the system works belongs in `docs/`. `architecture.md` already routes it, so memory adds no pointer. A harness or tool defect fixed at its source creates no compensating fact.
