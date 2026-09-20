# node.sh — bootstrap and update

The mechanical parts of standing a node up and moving it forward. Judgement — exploring the project, filling Project guardrails, reconciling content during an update — stays with the agent. This script never does either.

Run from the source repo. It is not copied into a node.

```
Usage:
  node.sh init --preset <name> --mode <mode> [--indexes <manual|generated>] [root]
  node.sh update [root]
  node.sh finalize [root]
```

- `<name>` matches a file in `presets/` (currently `software-development`, `academic-research`, `domain-knowledge`).
- `<mode>` is one of `ignore-all`, `track-shared`, `track-all`.
- `--indexes` is `manual` or `generated`, default `manual`. `update` takes no `--indexes` flag: it reads the value already in the manifest and carries it forward unchanged.
- `root` defaults to `.` and the script reads and writes `<root>/.agent`.

Header contracts in `operating-model.md` remain the format authority: this script writes files that carry their own header contracts, and produces nothing a header contract does not already describe.

## What init writes

The skeleton, the manifest, the gitignore for the chosen mode and index setting, the preset as `rules/contract.md`, the ten shipped scripts (`status.sh`, `log.sh`, `memory.sh`, `docs.sh`, `links.sh`, `comments.sh`, `checkpoint.sh`, `index.sh`, `finish.sh`, `learn.sh`), and the three starter confs.

The manifest's `indexes` field records `manual` or `generated`, next to `mode`. It defaults to `manual` when `--indexes` is omitted. A manifest with no `indexes` line at all — every node created before this field existed — reads as `manual` too, the same value an absent field already means. Nothing about such a node's behavior changes until it is turned on by hand. `generated` wires nothing into a session by itself. It only decides which lines `init` and `update` add to the gitignore and, at `update`, whether the learned-rules migration below runs. Loading the generated index into a session's own read path is a separate, not-yet-shipped step (`scripts/docs/index.md`).

The starter confs are seeded because the scripts are executed rather than read: without the file on disk, a knob is one nobody finds. They are configs from that moment on — the node edits or deletes them freely.

A `.gitignore` at `$HOME` is commonly git's global `core.excludesFile`, so a `.agent/` pattern there would ignore every project node in every repo. init skips writing one in that case and says so.

## Storage contract

What a node shares through git and what it keeps private is set by tracking mode. Whether it keeps a generated index cache and a derived learned-rules file is set by `indexes`, independently. The two combine into six cases:

- **`ignore-all`** (either `indexes` value): the gitignore holds one line, `.agent/`, so nothing under the node — `purpose.md`, `rules/` (including `rules/learned/` records and the `rules/learned.md` aggregate, once generated mode creates them), `docs/`, `memory.md`, `memory/`, `session-log.md`, `scripts/`, and `indexes/` if built — is ever shared through git. Each clone runs its own `init`.
- **`track-shared`, `indexes: manual`**: the gitignore un-ignores `purpose.md`, `rules/`, and `docs/`. Everything else (`memory.md`, `memory/`, `session-log.md`, `scripts/`, `archive/`) stays private. No `indexes/` directory exists, since nothing in manual mode builds one.
- **`track-shared`, `indexes: generated`**: the same sharing as above, plus two more ignored lines, `.agent/indexes/` and `.agent/rules/learned.md`. Because `rules/` is already shared, every ordinary rule record under it — each file under `rules/learned/` included — is shared. Only the cache directory and the derived aggregate are held back.
- **`track-all`, `indexes: manual`**: no gitignore lines at all — every file under `.agent/`, `memory.md` and `memory/` included, is shared.
- **`track-all`, `indexes: generated`**: the same as `track-all, manual`, minus the same two lines `.agent/indexes/` and `.agent/rules/learned.md`.

The generated cache is excluded from git in all six. It's excluded wholly under `ignore-all`'s blanket rule, explicitly under the two added lines in the two `generated` rows above, and vacuously in the two `manual` rows, where `indexes/` is never created in the first place.

`docs/` is unaffected by `indexes`: every `.agent/docs/**/*.md` file is a canonical source `index.sh` renders into a routes page, cache or no cache, in every tracking mode. `rules/learned/` holds one record per learned rule once the migration below has run. `index.sh ensure` regenerates `rules/learned.md` from those records as a read-only compatibility view for `status.sh` — hand edits to that file are overwritten on the next `ensure` (`scripts/docs/index.md`). `memory.md` and `memory/` are never a canonical source in any combination: `index.sh` reads only `.agent/rules/` and `.agent/docs/`. A fact recorded in memory never reaches a generated page or routes line, whether or not memory itself happens to be shared through git in that node's tracking mode.

## Installing the indexer into a fresh clone or worktree

`.agent/scripts/` is excluded from git under both `ignore-all` and `track-shared` (under `ignore-all` nothing at all under `.agent/` is tracked). A fresh clone or a `git worktree add` checkout of a `track-shared` node therefore carries the manifest and `rules/` but no scripts, `index.sh` included, even when that node's `indexes` is `generated`.

The fix is the same command that carries any node forward: run `node.sh update <root>` from the source repo, pointing `<root>` at the clone or worktree. On a node already at this script's current version — the ordinary fresh-clone case — `update` does not re-copy all ten shipped scripts. It copies `index.sh` alone, since that is the one script a version-current node can still be missing, and installs it without touching `rules/`, `docs/`, `memory/`, or anything else the node already holds. A node whose manifest predates the current version instead takes the full migration path below, which refreshes all ten scripts by name as part of that migration.

A session that finds no `.agent/scripts/index.sh` to run, or that runs `index.sh ensure` and gets a failed build, reads `.agent/rules/` and `.agent/docs/` directly — the same canonical sources `ensure` itself names on stderr when a build fails (`scripts/docs/index.md`). A missing or failing indexer never blocks a session. It only means the generated cache is unavailable until `index.sh` exists and builds one.

## What update does

A version migration is two phases: `update` does the mechanical part and leaves the node mid-migration on purpose; `finalize` closes it out once the mechanical part and the agent's own reconciliation are both done. `version` changes at `finalize` only — `update` never writes it.

`update` refreshes the shipped scripts from the source repo **by exactly their ten names** — `status.sh`, `log.sh`, `memory.sh`, `docs.sh`, `links.sh`, `comments.sh`, `checkpoint.sh`, `index.sh`, `finish.sh`, `learn.sh`. Anything else under `scripts/` is the node's own and is never overwritten. A missing starter conf is seeded — the one write that cannot clobber node content — and an existing one is never touched.

A manifest with no `indexes` line at all is backfilled as `manual` — the value an absent field already means, so nothing about the node's behavior changes — both here and on a version-current node (below).

It also reaches the mechanical migration baseline: memory body moved verbatim to `memory/legacy.md`, the old per-fact header stripped, and `migration_target` written into the manifest frontmatter holding the version this update is moving the node toward. `version` itself is left untouched at its pre-migration value — recording the pending target instead of stamping `version` directly means a crash or an interrupted session mid-migration still shows, from the manifest alone, that the node hasn't finished. This write is the gate for every mutation below it: `update` verifies the manifest rewrite actually landed (the transform ran cleanly, the rewritten file is neither empty nor short a line, and it carries the value just written) before replacing the manifest with a same-directory rename, and it aborts before touching any node content if that verification fails — a crash cannot be mistaken for a completed step, and none of memory, session-log, or scripts is touched on a failed write. `update`'s closing lines name what the agent still owes: splitting `memory/legacy.md` into fact files, reconciling `rules/contract.md` and `docs/` against the current presets and operating model, then running `finalize`.

The memory split itself is resumable, not gated on `memory/` merely existing: that alone can't tell a node that was never split apart from one interrupted mid-split apart from one already fully split into real fact files, and the three call for different treatment. `update` instead reads `memory/.split-in-progress` (a marker it writes before the first content change below and removes only after the last one succeeds) alongside whether `memory/` already holds any `*.md` file. A crash between the marker being written and removed is what a retry resumes from — never a permanent skip. The two content writes inside the split are each independently safe to redo: moving the body into `memory/legacy.md` and rewriting `memory.md` into its index are gated on `memory.md`'s own header contract, so a retry never re-derives from a `memory.md` that a prior attempt already rewrote (which would fabricate an empty `legacy.md` and discard a real split); appending the index line pointing at `memory/legacy.md` is gated on that file existing with no line yet, so a crash between the two writes resumes by finishing only the missing half. A `memory/.split-in-progress` marker left behind by a crash outside of `update` itself (for example a hand-edited or externally interrupted node) is otherwise inert — the next `update` run consumes and clears it — and needs no manual reconciliation.

Every node with untracked memory (every mode but `track-all`) is backed up first, and the backup path depends on which case is running. A version migration writes `.agent.backup-v<old-version>`; a same-version shape refresh (see below) writes `.agent.backup-v<version>-shape`, so the two can never collide with each other. Within the version-migration case, a collision on `.agent.backup-v<old-version>` is not always a stop: if the manifest's `migration_target` already names the version this run is migrating toward, the backup is read as the snapshot from an interrupted prior run and the update resumes against it rather than re-copying over it — running `update` again after an interruption is exactly how a stalled migration continues. Any other collision on that path — no `migration_target` set, or one naming a different version — aborts with "backup path already exists", and nothing is touched. The same-version shape-refresh backup has no resume case: a collision there always aborts the same way.

A node already on the current version can still be shape-stale: version-current is not shape-current, so shape migrations run regardless, using the shape-refresh backup path above. This is also the branch that installs `index.sh` and backfills a missing `indexes` line (above). A version-current node has nothing to migrate, so it is the only path a fresh clone or worktree of such a node ever reaches — the one that closes the gap left by `.agent/scripts/` being untracked.

### Generated mode's migration step

A node actually migrating (its manifest version is older than this script's) and reading `indexes: generated` runs one extra step, behind the same backup as the rest of the migration. Every top-level bullet in `rules/learned.md` becomes its own record under `rules/learned/`, named by a minted identity rather than derived from the rule's text, so a reworded rule keeps its filename. A bullet with a nested sub-bullet or a second paragraph is still copied verbatim into one record, but flagged `semantic-review-pending` rather than `migrated` in the `migration-inventory.md` this step writes. The mechanical split makes no judgement about which rules read as two subjects — it only records where one might. Every doc under `docs/` missing a `<!-- Read when: ... -->` hook is backfilled from its `architecture.md` entry in the same pass, flagged `migrated` or `hook-missing` in the same inventory.

Once every record exists, `update` adds `.agent/indexes/` and `.agent/rules/learned.md` to the gitignore (in `track-shared` and `track-all`), runs `index.sh ensure` to regenerate `rules/learned.md` from the new records, and checks the regenerated file's bullets against the ones the migration started from. Only on an exact match — nothing added, dropped, or reworded — does it run `git rm --cached` on `rules/learned.md` to untrack it. A mismatch aborts before that untrack, so a file is never dropped from git on the strength of an aggregate that has not been proven to reproduce every original bullet. In `ignore-all`, outside a git work tree, or when `rules/learned.md` was never tracked to begin with, the untrack step is skipped and reported rather than treated as a failure. At `<root>` = `$HOME`, none of this — gitignore lines, the `ensure` regeneration, or the untrack — runs at all. `update` prints the same warning `init` does and leaves the gitignore and the aggregate for the node to reconcile by hand.

### Adopting generated mode after reaching the current version

Changing `indexes: manual` to `indexes: generated` on a version-current node does not make `update` extract learned records or add generated-mode ignore rules. This also applies to nodes upgraded in manual mode. Select generated mode before the version migration, or wait for a later version migration to adopt it. Fresh nodes can select generated mode at `init`.

Running `index.sh ensure` after that manifest edit can build a cache from existing sources, but does not perform adoption. Under `track-shared`, `.agent/*` already ignores the cache. Under `track-all`, the cache can remain unignored without a matching ignore rule.

## Reverting to manual mode

Generated mode has no `revert` subcommand. Going back to manual is a short procedure, safe because `rules/learned.md` is a lossless, path-sorted concatenation of every record under `rules/learned/` (`scripts/docs/index.md`) — nothing a rule ever said is discarded by any of these steps. If a record under `rules/learned/` changed more recently than the last `index.sh ensure`, run `ensure` once before starting, so `rules/learned.md` reflects every record before it stops being regenerated.

1. In `.agent/purpose.md`, change `indexes: generated` to `indexes: manual`.
2. Delete `.agent/indexes/` — the generated cache is disposable. The next `indexes: generated` period, if any, rebuilds it from scratch.
3. Remove the two generated-mode lines, `.agent/indexes/` and `.agent/rules/learned.md`, from `.gitignore`.
4. `git add .agent/rules/learned.md` to re-track it.
5. Delete or archive `.agent/rules/learned/`.

What this loses: each rule's own record — its minted identity and the file-level merge behavior that identity buys across branches or clones. It collapses back into flat bullets in one shared file, merged and reconciled by hand the way a manual-mode node always has been. The rule text itself is not lost. Only the per-record structure is.

## What finalize does

`finalize` is the second phase: it closes out a migration `update` left pending, but only once the node checks clean.

If the manifest carries no `migration_target`, `finalize` reports the node already finalized and exits 0 — safe to run on a node that was never mid-migration or already closed one out.

Otherwise it runs the node's own `scripts/status.sh` (the copy `update` already refreshed, not this repo's), capturing its stdout and stderr separately — never folded together — and its exit code. Two checks gate the manifest write, and they are independent: did the inspection itself run cleanly, and are its findings acceptable. A nonzero exit, any stderr output, or empty stdout means the inspection did not complete, and `finalize` refuses (fail closed) without even reading stdout for findings. Only once the run is clean does `finalize` read `REPAIR:` lines from stdout, excluding the pending-migration line itself — that one is true by definition until this exact run clears it, so counting it would make every pending node unconditionally refuse. If any other `REPAIR:` finding remains, `finalize` refuses, lists the offending lines, and touches nothing — reconcile those and re-run `finalize`. `GROOM:` findings never gate finalize. Once the node checks clean, it stamps `version` to the pending `migration_target` and then removes `migration_target` from the manifest — in that order, so a crash between the two leaves the node still reading as pending rather than falsely finished. Each of those two writes carries the same verified-rewrite-then-rename contract `update` uses for `migration_target`. If stamping `version` fails verification, `finalize` aborts before touching `migration_target` at all, leaving both the marker and the old version exactly as they were. If stamping `version` succeeds but removing `migration_target` then fails, `finalize` still returns nonzero and prints the failure rather than the success line — the node is left with `version` already stamped but `migration_target` still present, which reads as pending (not falsely finished) and is detectable and safe to retry by running `finalize` again.
