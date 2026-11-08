# absorb.sh — merging a worker's node back

An orchestrator that runs workers in their own checkouts, such as git worktrees each carrying a copy of `.agent/`, loses whatever a worker wrote into its copy when the checkout goes away. `absorb.sh` merges that copy back into the main node.

```
Usage: absorb.sh mark [root]
       absorb.sh records --from <worker-root> [root]
       absorb.sh docs --from <worker-root> [root]
```

`root` defaults to `.`, the project root holding `.agent/`. A worker in the same checkout as its orchestrator needs none of this: it writes the shared files through the node's writers, which serialize on the node's locks.

## The three steps

1. **`mark`**, in the worker's checkout, when the orchestrator dispatches it. It records the size and hash of every node Markdown file in `.agent/.state/absorb-base.tsv` of the worker's copy. That is the worker's base. Scripts, confs, `indexes/`, `archive/`, and `.state/` are not recorded and never travel.
2. **`records --from <worker>`**, in the main checkout, when each attempt ends. Failed and discarded attempts are included, because a failed attempt's lesson is often the most valuable one. It merges the worker's experience records:
   - entries appended to `session-log.md` and `memory.md`
   - new or superseded fact files under `memory/`
   - new or revised records under `rules/learned/`, or, on a node with no record directory, bullets appended to `rules/learned.md`.
3. **`docs --from <worker>`**, in the main checkout, when the worker's code is integrated. It merges code-coupled writes: `purpose.md`, `rules/*.md` other than `learned.md`, and everything under `docs/`. In `track-shared` and `track-all`, git already carries the tracked files on the worker's branch. `docs` matters most for files git does not carry.

## What gets applied

| Case | Result |
| --- | --- |
| Session log, memory index, manual learned rules: the worker only appended | Each appended line the main file does not already hold is appended |
| The worker rewrote an earlier part of one of those files | `conflict`, nothing applied for that file |
| A file new in the worker, absent in the main node | Copied |
| A new learned record whose rule `learn.sh lookup` reports as a duplicate | `duplicate`, not copied |
| A file the worker changed, unchanged in the main node since the base | Copied over |
| A doc whose `Checked:` stamp names a commit the main checkout's `HEAD` does not contain | Applied without the stamp line, with a reason |
| A file both sides changed, or the main node removed | `conflict`, the main node keeps its version |
| A file the worker removed | `not-applied`: retirement stays with the orchestrator, against a named enforcer (`learn.sh retire --enforced-by`) |

Near-duplicates that differ in wording pass, as they do through `learn.sh`. Grooming catches them later. A conflict is not merged line by line: the base records hashes, not content, so `absorb.sh` cannot tell which lines each side changed. Reconcile a conflict by hand from the worker's copy.

## Checked stamps

A doc's `Checked:` stamp names the commit at which its cited code was read (see `docs.md`). A worker stamps at its own `HEAD`. An orchestrator that integrates task commits by cherry-pick or rebase gives the main checkout copies of those commits, never the stamped commit itself. In the main checkout `links.sh` would then report every change since the branch point as `STALE:`, and once the task branch is gone it would report a stamp that names no commit.

So `docs` drops the stamp line from a doc it applies unless the main checkout's `HEAD` contains the stamped commit. The rest of the doc is copied byte for byte, and the doc arrives unchecked. The decision prints as a third field on its `applied` line:

```
applied	docs/client.md	dropped its Checked stamp 1a2b3c4, a commit the main checkout's HEAD does not contain. Re-read the code it cites, then restamp it with docs.sh check
```

A stamp at a commit the main checkout already holds is kept, for example a stamp written in a worker dispatched from the integrated `HEAD`. A main node that already holds the worker's file as the worker wrote it, because git carried it, is left as git left it.

When anything under `rules/` or `docs/` was applied on a node with `indexes: generated`, `absorb.sh` runs the node's `index.sh ensure` once at the end.

## Safety

- Both nodes must carry a manifest at the same `version`. A worker node from another version is refused.
- `--from` may not name the main node itself, and a worker without a base is refused.
- The main node is locked for the whole merge with the same locks `log.sh`, `memory.sh`, and `learn.sh` take, so no writer runs against it mid-merge, and a merge refuses while one does.
- Nothing is ever deleted from the main node.

## Output and exit status

One tab-separated line per decision: `applied`, `duplicate`, `conflict`, or `not-applied`, then the path, then a reason for the last two and for an `applied` doc whose stamp was dropped. Unchanged files print nothing, so a repeated run prints nothing.

| Code | Meaning |
| --- | --- |
| 0 | merged, no conflict |
| 3 | merged around one or more reported conflicts |
| 2 | refused: no manifest, no base, a version mismatch, `--from` naming the main node, or a lock held by a live writer |

`scripts/tests/absorb-v63.sh` covers every row above.
