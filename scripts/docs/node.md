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

The skeleton, the manifest, the gitignore for the chosen mode, the preset as `rules/contract.md`, the seven shipped scripts, and the three starter confs.

The starter confs are seeded because the scripts are executed rather than read: without the file on disk, a knob is one nobody finds. They are configs from that moment on — the node edits or deletes them freely.

A `.gitignore` at `$HOME` is commonly git's global `core.excludesFile`, so a `.agent/` pattern there would ignore every project node in every repo. init skips writing one in that case and says so.

## What update does

A version migration is two phases: `update` does the mechanical part and leaves the node mid-migration on purpose; `finalize` closes it out once the mechanical part and the agent's own reconciliation are both done. `version` changes at `finalize` only — `update` never writes it.

`update` refreshes the shipped scripts from the source repo **by exactly their seven names** — `status.sh`, `log.sh`, `memory.sh`, `docs.sh`, `links.sh`, `comments.sh`, `finish.sh`. Anything else under `scripts/` is the node's own and is never overwritten. A missing starter conf is seeded — the one write that cannot clobber node content — and an existing one is never touched.

It also reaches the mechanical migration baseline: memory body moved verbatim to `memory/legacy.md`, the old per-fact header stripped, and `migration_target` written into the manifest frontmatter holding the version this update is moving the node toward. `version` itself is left untouched at its pre-migration value — recording the pending target instead of stamping `version` directly means a crash or an interrupted session mid-migration still shows, from the manifest alone, that the node hasn't finished. This write is the gate for every mutation below it: `update` verifies the manifest rewrite actually landed (the transform ran cleanly, the rewritten file is neither empty nor short a line, and it carries the value just written) before replacing the manifest with a same-directory rename, and it aborts before touching any node content if that verification fails — a crash cannot be mistaken for a completed step, and none of memory, session-log, or scripts is touched on a failed write. `update`'s closing lines name what the agent still owes: splitting `memory/legacy.md` into fact files, reconciling `rules/contract.md` and `docs/` against the current presets and operating model, then running `finalize`.

The memory split itself is resumable, not gated on `memory/` merely existing: that alone can't tell a node that was never split apart from one interrupted mid-split apart from one already fully split into real fact files, and the three call for different treatment. `update` instead reads `memory/.split-in-progress` (a marker it writes before the first content change below and removes only after the last one succeeds) alongside whether `memory/` already holds any `*.md` file. A crash between the marker being written and removed is what a retry resumes from — never a permanent skip. The two content writes inside the split are each independently safe to redo: moving the body into `memory/legacy.md` and rewriting `memory.md` into its index are gated on `memory.md`'s own header contract, so a retry never re-derives from a `memory.md` that a prior attempt already rewrote (which would fabricate an empty `legacy.md` and discard a real split); appending the index line pointing at `memory/legacy.md` is gated on that file existing with no line yet, so a crash between the two writes resumes by finishing only the missing half. A `memory/.split-in-progress` marker left behind by a crash outside of `update` itself (for example a hand-edited or externally interrupted node) is otherwise inert — the next `update` run consumes and clears it — and needs no manual reconciliation.

Every node with untracked memory (every mode but `track-all`) is backed up first, and the backup path depends on which case is running. A version migration writes `.agent.backup-v<old-version>`; a same-version shape refresh (see below) writes `.agent.backup-v<version>-shape`, so the two can never collide with each other. Within the version-migration case, a collision on `.agent.backup-v<old-version>` is not always a stop: if the manifest's `migration_target` already names the version this run is migrating toward, the backup is read as the snapshot from an interrupted prior run and the update resumes against it rather than re-copying over it — running `update` again after an interruption is exactly how a stalled migration continues. Any other collision on that path — no `migration_target` set, or one naming a different version — aborts with "backup path already exists", and nothing is touched. The same-version shape-refresh backup has no resume case: a collision there always aborts the same way.

A node already on the current version can still be shape-stale: version-current is not shape-current, so shape migrations run regardless, using the shape-refresh backup path above.

## What finalize does

`finalize` is the second phase: it closes out a migration `update` left pending, but only once the node checks clean.

If the manifest carries no `migration_target`, `finalize` reports the node already finalized and exits 0 — safe to run on a node that was never mid-migration or already closed one out.

Otherwise it runs the node's own `scripts/status.sh` (the copy `update` already refreshed, not this repo's), capturing its stdout and stderr separately — never folded together — and its exit code. Two checks gate the manifest write, and they are independent: did the inspection itself run cleanly, and are its findings acceptable. A nonzero exit, any stderr output, or empty stdout means the inspection did not complete, and `finalize` refuses (fail closed) without even reading stdout for findings. Only once the run is clean does `finalize` read `REPAIR:` lines from stdout, excluding the pending-migration line itself — that one is true by definition until this exact run clears it, so counting it would make every pending node unconditionally refuse. If any other `REPAIR:` finding remains, `finalize` refuses, lists the offending lines, and touches nothing — reconcile those and re-run `finalize`. `GROOM:` findings never gate finalize. Once the node checks clean, it stamps `version` to the pending `migration_target` and then removes `migration_target` from the manifest — in that order, so a crash between the two leaves the node still reading as pending rather than falsely finished. Each of those two writes carries the same verified-rewrite-then-rename contract `update` uses for `migration_target`. If stamping `version` fails verification, `finalize` aborts before touching `migration_target` at all, leaving both the marker and the old version exactly as they were. If stamping `version` succeeds but removing `migration_target` then fails, `finalize` still returns nonzero and prints the failure rather than the success line — the node is left with `version` already stamped but `migration_target` still present, which reads as pending (not falsely finished) and is detectable and safe to retry by running `finalize` again.
