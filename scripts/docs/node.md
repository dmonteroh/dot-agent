# node.sh — bootstrap and update

The mechanical parts of standing a node up and moving it forward. Judgement — exploring the project, filling Project guardrails, reconciling content during an update — stays with the agent. This script never does either.

Run from the source repo. It is not copied into a node.

```
Usage:
  node.sh init --preset <name> --mode <mode> [--indexes <manual|generated>] [root]
  node.sh update [--indexes <manual|generated>] [root]
  node.sh finalize [root]
```

- `<name>` matches a file in `presets/` (currently `software-development`, `academic-research`, `domain-knowledge`).
- `<mode>` is one of `ignore-all`, `track-shared`, `track-all`.
- `--indexes` is `manual` or `generated`. `init` defaults it to `manual`. `update` preserves the manifest value when the flag is omitted, adopts generated mode when requested, and refuses generated-to-manual conversion outside the procedure below.
- `root` defaults to `.` and the script reads and writes `<root>/.agents`.

Header contracts in `operating-model.md` remain the format authority: this script writes files that carry their own header contracts, and produces nothing a header contract does not already describe.

## What init writes

The skeleton, the manifest, the gitignore for the chosen mode and index setting, the preset as `rules/contract.md`, the thirteen managed helpers listed by `SHIPPED_SCRIPTS`, six starter configurations, and the project-owned `checks.sh` driver.

The manifest's `indexes` field records `manual` or `generated`, next to `mode`. It defaults to `manual` when `--indexes` is omitted. A manifest with no `indexes` line at all — every node created before this field existed — reads as `manual` too, the same value an absent field already means. Nothing about such a node's behavior changes until it is turned on by hand. `generated` decides which lines `init` and `update` add to the gitignore and, at `update`, whether the learned-rules migration below runs. It also changes what a session reads: `status.sh` and `checkpoint.sh` read the manifest's `indexes` field themselves (each greps `purpose.md` for the `indexes:` line) and switch their own behavior on it, and `learn.sh` reads it to decide whether a write should also refresh the generated cache. The read-path wiring an agent installs is `templates/entry-point-generated.md`, the generated-mode counterpart to `templates/entry-point.md` (`scripts/docs/index.md`).

The starter confs are seeded because the scripts are executed rather than read: without the file on disk, a knob is one nobody finds. They are configs from that moment on — the node edits or deletes them freely.

A `.gitignore` at `$HOME` is commonly git's global `core.excludesFile`, so a `.agents/` pattern there would ignore every project node in every repo. init skips writing one in that case and says so.

`.agents/` may already exist before init, because other tools install skills there. init treats a node as present only when `.agents/purpose.md` exists. It refuses when any node-owned path (`rules/`, `memory/`, `docs/`, `archive/`, `scripts/`, `indexes/`, `memory.md`, `session-log.md`) is already there, and it never touches anything else under `.agents/`. It also refuses when a node from before 6.3 lives at `.agent/`. `update` moves that one.

## Storage contract

What a node shares through git and what it keeps private is set by tracking mode. Whether it keeps a generated index cache and a derived learned-rules file is set by `indexes`, independently. The two combine into six cases:

No mode ignores `.agents/` as a whole, because the directory is shared with other tools: `skills/` and anything else `node.sh` does not create belong to the project. Each mode names node-owned paths instead. The lists live in `node.sh` as `NODE_SHARED_PATHS` (`purpose.md`, `rules/`, `docs/`) and `NODE_PERSONAL_PATHS` (`memory.md`, `memory/`, `session-log.md`, `archive/`, `scripts/`, `indexes/`, `migration-inventory.md`, and the node's dot and temp files).

- **`ignore-all`** (either `indexes` value): the gitignore lists every shared and personal path, so nothing the node owns is shared through git. Each clone runs its own `init`.
- **`track-shared`, `indexes: manual`**: the gitignore lists the personal paths. `purpose.md`, `rules/`, and `docs/` are shared.
- **`track-shared`, `indexes: generated`**: the same, plus `.agents/rules/learned.md`. Every rule record under `rules/learned/` is shared. Only the cache directory, already a personal path, and the derived aggregate are held back.
- **`track-all`, `indexes: manual`**: no gitignore lines at all. Every file under `.agents/`, `memory.md` and `memory/` included, is shared.
- **`track-all`, `indexes: generated`**: the same as `track-all, manual`, minus `.agents/indexes/` and `.agents/rules/learned.md`.

`init` and `update` append any missing line of the mode's list and never remove one, so a path added to the lists reaches existing nodes on their next `update`. The generated cache is excluded from git in all six cases.

A node bootstrapped straight at `--indexes generated` has no `rules/learned/` directory yet — only the version migration below creates it — so it is not blocked waiting on that migration: `learn.sh new` creates the directory itself on a fresh generated node's first record and regenerates the gitignored aggregate from it (commit `0508934`, `scripts/docs/learn.md`).

`docs/` is unaffected by `indexes`: every `.agents/docs/**/*.md` file is a canonical source `index.sh` renders into a routes page, cache or no cache, in every tracking mode. `rules/learned/` holds one record per learned rule once the migration below has run. `index.sh ensure` regenerates `rules/learned.md` from those records as a read-only compatibility view for `status.sh` — hand edits to that file are overwritten on the next `ensure` (`scripts/docs/index.md`). `memory.md` and `memory/` are never a canonical source in any combination: `index.sh` reads only `.agents/rules/` and `.agents/docs/`. A fact recorded in memory never reaches a generated page or routes line, whether or not memory itself happens to be shared through git in that node's tracking mode.

## Installing the indexer into a fresh clone or worktree

`.agents/scripts/` is excluded from git under both `ignore-all` and `track-shared` (under `ignore-all` no node-owned path is tracked). A fresh clone or a `git worktree add` checkout of a `track-shared` node therefore carries the manifest and `rules/` but no scripts, `index.sh` included, even when that node's `indexes` is `generated`.

Run `node.sh update <root>` from this source checkout. Version-current nodes also receive every managed runtime helper. Each helper is replaced atomically. Existing check drivers, configuration, rules, docs, memory, and logs remain project-owned.

A session that finds no `.agents/scripts/index.sh` to run, or that runs `index.sh ensure` and gets a failed build, reads `.agents/rules/` and `.agents/docs/` directly — the same canonical sources `ensure` itself names on stderr when a build fails (`scripts/docs/index.md`). A missing or failing indexer never blocks a session. It only means the generated cache is unavailable until `index.sh` exists and builds one.

## Moving a node from `.agent/` to `.agents/`

Before 6.3 a node lived at `<root>/.agent/`. `update` moves it first, before any version or shape step, whenever `.agent/purpose.md` exists and `.agents/purpose.md` does not:

1. It refuses when a name exists in both directories, listing the clashes, so a skills directory another tool created is never overwritten.
2. Outside `track-all` it copies the old node to `<root>/.agent.backup-v<version>-relocate` once.
3. It moves each entry with `git mv` when git tracks any file in it, and with `mv` otherwise. `purpose.md` moves last, so an interrupted move is still detected and a re-run resumes it.
4. It rewrites `.agent` path tokens to `.agents` in the node's own Markdown and confs, except `session-log.md`, `archive/`, `skills/`, and `indexes/`. It does the same in the entry points it finds (`CLAUDE.md`, `AGENTS.md`, `GEMINI.md`, `.github/copilot-instructions.md`, `.claude/CLAUDE.md`, `.codex/AGENTS.md`), in `.claude/settings.json` and `.claude/settings.local.json`, and in `.git/info/exclude`. It prints every file it rewrote.
5. It repoints a `.claude/skills` symlink that targeted `.agent/skills`, and removes a `.codex/skills` symlink that did, since Codex reads `.agents/skills/` itself.
6. It removes the pre-6.3 node lines from `.gitignore` and writes the mode's new list.

`finalize` refuses a node still at `.agent/` and points to `update`.

## What update does

A version migration is two phases: `update` does the mechanical part and leaves the node mid-migration on purpose; `finalize` closes it out once the mechanical part and the agent's own reconciliation are both done. `version` changes at `finalize` only — `update` never writes it.

`update` refreshes the managed helpers named by `SHIPPED_SCRIPTS`. It seeds missing configuration and `checks.sh`, while preserving existing copies. Other project scripts remain untouched. Script replacement uses a temporary sibling and rename, so a running shell retains its original file.

A manifest with no `indexes` line is backfilled as `manual` unless `update --indexes generated` selects generated mode. Omitting the flag preserves an existing value.

It also reaches the mechanical migration baseline: memory body moved verbatim to `memory/legacy.md`, the old per-fact header stripped, and `migration_target` written into the manifest frontmatter holding the version this update is moving the node toward. `version` itself is left untouched at its pre-migration value — recording the pending target instead of stamping `version` directly means a crash or an interrupted session mid-migration still shows, from the manifest alone, that the node hasn't finished. This write is the gate for every mutation below it: `update` verifies the manifest rewrite actually landed (the transform ran cleanly, the rewritten file is neither empty nor short a line, and it carries the value just written) before replacing the manifest with a same-directory rename, and it aborts before touching any node content if that verification fails — a crash cannot be mistaken for a completed step, and none of memory, session-log, or scripts is touched on a failed write. `update`'s closing lines name what the agent still owes: splitting `memory/legacy.md` into fact files, reconciling `rules/contract.md` and `docs/` against the current presets and operating model, then running `finalize`.

The memory split itself is resumable, not gated on `memory/` merely existing: that alone can't tell a node that was never split apart from one interrupted mid-split apart from one already fully split into real fact files, and the three call for different treatment. `update` instead reads `memory/.split-in-progress` (a marker it writes before the first content change below and removes only after the last one succeeds) alongside whether `memory/` already holds any `*.md` file. A crash between the marker being written and removed is what a retry resumes from — never a permanent skip. The two content writes inside the split are each independently safe to redo: moving the body into `memory/legacy.md` and rewriting `memory.md` into its index are gated on `memory.md`'s own header contract, so a retry never re-derives from a `memory.md` that a prior attempt already rewrote (which would fabricate an empty `legacy.md` and discard a real split); appending the index line pointing at `memory/legacy.md` is gated on that file existing with no line yet, so a crash between the two writes resumes by finishing only the missing half. A `memory/.split-in-progress` marker left behind by a crash outside of `update` itself (for example a hand-edited or externally interrupted node) is otherwise inert — the next `update` run consumes and clears it — and needs no manual reconciliation.

Every node with untracked memory is backed up first. Version migration uses `.agents.backup-v<old-version>`, shape refresh uses `.agents.backup-v<version>-shape`, and generated adoption uses `.agents.backup-v<version>-indexes-generated`.

A matching `migration_target` makes the version-migration backup resumable. Any other backup collision aborts without touching the node.

A node already on the current version can still be shape-stale: version-current is not shape-current, so shape migrations run regardless, using the shape-refresh backup path above. This branch also refreshes managed helpers and backfills a missing `indexes` line. A version-current node has nothing to migrate, so it is the only path a fresh clone or worktree of such a node ever reaches — the one that closes the gap left by `.agents/scripts/` being untracked.

### Generated mode's migration step

A node actually migrating (its manifest version is older than this script's) and reading `indexes: generated` runs one extra step, behind the same backup as the rest of the migration. Every top-level bullet in `rules/learned.md` becomes its own record under `rules/learned/`, named by a minted identity rather than derived from the rule's text, so a reworded rule keeps its filename. A bullet with a nested sub-bullet or a second paragraph is still copied verbatim into one record, but flagged `semantic-review-pending` rather than `migrated` in the `migration-inventory.md` this step writes. The mechanical split makes no judgement about which rules read as two subjects — it only records where one might. Every doc under `docs/` missing a `<!-- Read when: ... -->` hook is backfilled from its `architecture.md` entry in the same pass, flagged `migrated` or `hook-missing` in the same inventory.

Once every record exists, `update` adds `.agents/indexes/` and `.agents/rules/learned.md` to the gitignore (in `track-shared` and `track-all`), runs `index.sh ensure` to regenerate `rules/learned.md` from the new records, and checks the regenerated file's bullets against the ones the migration started from. Only on an exact match — nothing added, dropped, or reworded — does it run `git rm --cached` on `rules/learned.md` to untrack it. A mismatch aborts before that untrack, so a file is never dropped from git on the strength of an aggregate that has not been proven to reproduce every original bullet. In `ignore-all`, outside a git work tree, or when `rules/learned.md` was never tracked to begin with, the untrack step is skipped and reported rather than treated as a failure. At `<root>` = `$HOME`, update still builds and verifies the aggregate. It skips the gitignore and untrack steps, and tells the operator to reconcile them by hand if the home directory is version-controlled.

### Adopting generated mode after reaching the current version

Run `node.sh update --indexes generated <root>`. In modes with untracked memory, the command first writes `.agents.backup-v<version>-indexes-generated`. It then records the mode, installs the two required scripts, and extracts learned-rule records. Finally, it backfills doc hooks, writes the inventory and ignore rules, builds the index, verifies the aggregate, and untracks the derived file.

The command is safe to repeat. Once the manifest says `generated`, another explicit run completes any interrupted adoption without creating a second backup or reminting existing records. Omitting `--indexes` keeps the current mode. Passing `--indexes manual` for a generated node is refused because reverting has a different data-shape procedure.

## Reverting to manual mode

Generated mode has no `revert` subcommand. Going back to manual is a short procedure, safe because `rules/learned.md` is a lossless, path-sorted concatenation of every record under `rules/learned/` (`scripts/docs/index.md`) — nothing a rule ever said is discarded by any of these steps. If a record under `rules/learned/` changed more recently than the last `index.sh ensure`, run `ensure` once before starting, so `rules/learned.md` reflects every record before it stops being regenerated.

1. In `.agents/purpose.md`, change `indexes: generated` to `indexes: manual`.
2. Delete `.agents/indexes/` — the generated cache is disposable. The next `indexes: generated` period, if any, rebuilds it from scratch.
3. Remove the two generated-mode lines, `.agents/indexes/` and `.agents/rules/learned.md`, from `.gitignore`.
4. `git add .agents/rules/learned.md` to re-track it.
5. Delete or archive `.agents/rules/learned/`.

What this loses: each rule's own record — its minted identity and the file-level merge behavior that identity buys across branches or clones. It collapses back into flat bullets in one shared file, merged and reconciled by hand the way a manual-mode node always has been. The rule text itself is not lost. Only the per-record structure is.

## What finalize does

`finalize` is the second phase: it closes out a migration `update` left pending, but only once the node checks clean.

If the manifest carries no `migration_target`, `finalize` reports the node already finalized and exits 0 — safe to run on a node that was never mid-migration or already closed one out.

Otherwise it runs the node's own `scripts/status.sh` (the copy `update` already refreshed, not this repo's), capturing its stdout and stderr separately — never folded together — and its exit code. Two checks gate the manifest write, and they are independent: did the inspection itself run cleanly, and are its findings acceptable. A nonzero exit, any stderr output, or empty stdout means the inspection did not complete, and `finalize` refuses (fail closed) without even reading stdout for findings. Only once the run is clean does `finalize` read `REPAIR:` lines from stdout, excluding the pending-migration line itself — that one is true by definition until this exact run clears it, so counting it would make every pending node unconditionally refuse. If any other `REPAIR:` finding remains, `finalize` refuses, lists the offending lines, and touches nothing — reconcile those and re-run `finalize`. `GROOM:` findings never gate finalize. Once the node checks clean, it stamps `version` to the pending `migration_target` and then removes `migration_target` from the manifest — in that order, so a crash between the two leaves the node still reading as pending rather than falsely finished. Each of those two writes carries the same verified-rewrite-then-rename contract `update` uses for `migration_target`. If stamping `version` fails verification, `finalize` aborts before touching `migration_target` at all, leaving both the marker and the old version exactly as they were. If stamping `version` succeeds but removing `migration_target` then fails, `finalize` still returns nonzero and prints the failure rather than the success line — the node is left with `version` already stamped but `migration_target` still present, which reads as pending (not falsely finished) and is detectable and safe to retry by running `finalize` again.
