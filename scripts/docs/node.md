# node.sh — bootstrap and update

The mechanical parts of standing a node up and moving it forward. Judgement — exploring the project, filling Project guardrails, reconciling content during an update — stays with the agent. This script never does either.

Run from the source repo. It is not copied into a node.

```
Usage:
  node.sh init --preset <name> --mode <mode> [root]
  node.sh update [root]
  node.sh finalize [root]
```

- `<name>` matches a file in `presets/` (currently `software-development`, `academic-research`, `domain-knowledge`).
- `<mode>` is one of `ignore-all`, `track-shared`, `track-all`.
- `root` defaults to `.` and the script reads and writes `<root>/.agent`.

Header contracts in `operating-model.md` remain the format authority: this script writes files that carry their own header contracts, and produces nothing a header contract does not already describe.

## What init writes

The skeleton, the manifest, the gitignore for the chosen mode, the preset as `rules/contract.md`, the six shipped scripts, and the three starter confs.

The starter confs are seeded because the scripts are executed rather than read: without the file on disk, a knob is one nobody finds. They are configs from that moment on — the node edits or deletes them freely.

A `.gitignore` at `$HOME` is commonly git's global `core.excludesFile`, so a `.agent/` pattern there would ignore every project node in every repo. init skips writing one in that case and says so.

## What update does

A version migration is two phases: `update` does the mechanical part and leaves the node mid-migration on purpose; `finalize` closes it out once the mechanical part and the agent's own reconciliation are both done. `version` changes at `finalize` only — `update` never writes it.

`update` refreshes the shipped scripts from the source repo **by exactly their seven names** — `status.sh`, `log.sh`, `memory.sh`, `docs.sh`, `links.sh`, `comments.sh`, `finish.sh`. Anything else under `scripts/` is the node's own and is never overwritten. A missing starter conf is seeded — the one write that cannot clobber node content — and an existing one is never touched.

It also reaches the mechanical migration baseline: memory body moved verbatim to `memory/legacy.md` (skipped if `memory/` already exists), the old per-fact header stripped, and `migration_target` written into the manifest frontmatter holding the version this update is moving the node toward. `version` itself is left untouched at its pre-migration value — recording the pending target instead of stamping `version` directly means a crash or an interrupted session mid-migration still shows, from the manifest alone, that the node hasn't finished. `update`'s closing lines name what the agent still owes: splitting `memory/legacy.md` into fact files, reconciling `rules/contract.md` and `docs/` against the current presets and operating model, then running `finalize`.

Every node with untracked memory (every mode but `track-all`) is backed up first, and the backup path depends on which case is running. A version migration writes `.agent.backup-v<old-version>`; a same-version shape refresh (see below) writes `.agent.backup-v<version>-shape`, so the two can never collide with each other. Within the version-migration case, a collision on `.agent.backup-v<old-version>` is not always a stop: if the manifest's `migration_target` already names the version this run is migrating toward, the backup is read as the snapshot from an interrupted prior run and the update resumes against it rather than re-copying over it — running `update` again after an interruption is exactly how a stalled migration continues. Any other collision on that path — no `migration_target` set, or one naming a different version — aborts with "backup path already exists", and nothing is touched. The same-version shape-refresh backup has no resume case: a collision there always aborts the same way.

A node already on the current version can still be shape-stale: version-current is not shape-current, so shape migrations run regardless, using the shape-refresh backup path above.

## What finalize does

`finalize` is the second phase: it closes out a migration `update` left pending, but only once the node checks clean.

If the manifest carries no `migration_target`, `finalize` reports the node already finalized and exits 0 — safe to run on a node that was never mid-migration or already closed one out.

Otherwise it runs the node's own `scripts/status.sh` (the copy `update` already refreshed, not this repo's) and reads its `REPAIR:` lines, excluding the pending-migration line itself — that one is true by definition until this exact run clears it, so counting it would make every pending node unconditionally refuse. A run that produces no output at all is also treated as a refusal (fail closed) rather than a pass. If any other `REPAIR:` finding remains, `finalize` refuses, lists the offending lines, and touches nothing — reconcile those and re-run `finalize`. Once the node checks clean, it stamps `version` to the pending `migration_target` and then removes `migration_target` from the manifest — in that order, so a crash between the two leaves the node still reading as pending rather than falsely finished.
