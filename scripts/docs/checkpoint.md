# checkpoint.sh — verify, review, and record

Checkpoint coordinates verification evidence, diff review, node health, and the session log. It records unchanged completed content once. It does not infer user-turn boundaries or decide whether a task succeeded semantically.

```sh
checkpoint.sh --tool NAME --area NAME --summary TEXT \
  [--checks CHECK[,CHECK...]] [--verification ID[,ID...]] \
  [--verify fail|n/a] [--base REF] [--node-only] \
  [--policy strict|completion] [ROOT]
```

`ROOT` defaults to the project root at `.`. Use `--help` or `--version` for the installed interface.

## Verification

`--checks` runs named checks through `verify.sh`. `--verification` consumes existing receipts for unchanged inputs. Given both, checkpoint uses the receipts while every one is current, and runs the checks when one is missing or stale. `--checks n/a` is read as `--verify n/a`, because `n/a` is no check name. Each of the two prints a line saying what was done.

Each check's output prints on stderr. The checks share one `OUTPUT_MAX_BYTES` limit equally, so their combined output fits one tool result. See [verify.md](verify.md) for how long output is trimmed.

A valid receipt determines the recorded verification status. Known failures and inconclusive checks stop automatic publication, and the refusal names which of four things happened. For a failed check, fix and retry, or add `--verification <id> --verify fail` to the same call to record a final failed outcome. For a check that exited 0 with no test count `verify.sh` reads, fix the check driver, and leave the project's own test command as it is. For a check that ran 0 tests, add or select a test, or pass `--verify n/a` without `--checks` when nothing can be tested. For a check that ran while project files changed, run the call again. A bare `--verify pass` is refused. `--verify fail` and `--verify n/a` remain explicit reports for failed or manual-only work.

Logging failed work is allowed. A successful checkpoint means the record was written, not that project tests passed. The output names the recorded verification status.

Checkpoint validates receipts again before publishing the log. A source edit between verification and completion requires fresh evidence. See [verify.md](verify.md) for the fingerprint boundary and count limitations.

## Review and health

Review and status run before verification. A finding that blocks stops checkpoint before any check runs, so a fix costs one check run rather than two. A check that changes the inputs they read records an inconclusive result, and receipts are validated again before logging.

For Git work, `review.sh` invokes the comment gate and reports catalog and coverage candidates. Its blocking or execution errors stop checkpoint. Advisory review candidates still need agent judgment.

`status.sh --format tsv` supplies stable finding codes. The default `POLICY=strict` in `checkpoint.conf` blocks every actionable finding. `--policy completion` defers advisory maintenance while structural defects remain blocking. Informational tool notes do not block either policy.

A status block ends with a line that names the next step: do what each finding's line says, then run the call again. When only advisory findings blocked under the strict policy, the line says that they block too and that the session handles them now, without asking first. The node's contract already assigns that maintenance to the current session, so the line saves a question and keeps a session from relaxing the policy to get past the block.

A failed status command, unexpected stderr, or malformed finding is an inspection failure. Checkpoint writes no entry in that case.

Generated-index nodes refresh their cache before logging. A missing or failed indexer remains advisory because canonical rules and docs remain available.

## Bases and ignored nodes

An uncommitted Git change is compared with `HEAD`. Aliases resolving to the same comparison base share the same checkpoint identity.

Each recorded entry also records the worktree's commit, and a digest of its content, in `.agent/.state/checkpoint.head.<id>`. The id stands for the worktree's path, so worktrees that share one node keep separate marks. The digest covers the tracked files and the untracked files Git does not ignore, under the project root, with no commit and no index in it. It leaves out the session log and the generated indexes. Both values are taken before the review, so a file written while the checkpoint runs is still reviewed when a later call covers its commit. A call with neither `--base` nor `--node-only` is read against that mark, in this order:

| Check | Meaning | Result |
| --- | --- | --- |
| The content digest is the marked one, or `HEAD` is the marked commit and nothing is uncommitted | The last checkpoint covers this tree | Prints `nothing to record since the last checkpoint` and exits 0, unless ignored node files changed. That is refused, and the message names `--node-only` |
| No mark, or the marked commit is not an ancestor of `HEAD` | A first checkpoint, a rewritten history, or another branch | Uncommitted work is compared with `HEAD`. A clean tree is refused, and the message names `--base <the commit before your work>` |
| `HEAD` is the marked commit | Only uncommitted work is new | Compares with `HEAD` |
| `HEAD` moved | Commits landed since the last checkpoint | Uses the marked commit as the base, uncommitted work included, and prints `using --base <sha>` with the number of commits |

Work recorded before its commit counts as recorded afterwards, because its content is the same. Only the base is applied. `--node-only` writes an entry for content Git cannot show, so it stays explicit. It reviews no commit, so it leaves the mark in place, and its entry answers only another `--node-only` call. Ignored node files are compared through a digest in `.agent/.state/checkpoint.node`, which belongs to the node, so a worktree is not asked to record what another worktree sharing the node recorded.

Five limits follow from this:

- A checkpoint over uncommitted work with no usable mark starts the mark at `HEAD`, so earlier commits count as recorded. Pass `--base` when they are part of the work.
- A base inferred after a pull covers the pulled commits. When the review blocks on them, pass the commit before your own work with `--base`. The mark then moves to `HEAD`.
- Work recorded and then committed is reviewed again with the next change, because the base is the marked commit. It is logged once. Deleting a leftover file that was recorded with it counts as a change.
- A worktree holds one mark, so after a switch to another branch and a checkpoint there, a call back on the first branch can review and log its recorded work again.
- A file Git is told not to compare, with `assume-unchanged` or `skip-worktree`, cannot be reviewed, so a change to it alone records nothing.

`--base <ref>` overrides the inference. `--node-only` refuses product changes the last checkpoint did not record. Non-Git and node-only work report that no product diff was inspected.

An inherited dirty tree does not establish that the current turn changed anything. Call checkpoint only after changed work. Exact per-turn attribution still requires a runtime turn identifier or an explicit start snapshot.

## Retry and recovery

A private worktree lock serializes cooperating checkpoint and direct log writers. Checkpoint waits for a held lock as the record writers do, for up to `DA_LOCK_WAIT_SECONDS`. The checkpoint identity covers current inputs and the comparison base. Log output and runtime bookkeeping do not change that identity.

Repeating a successful checkpoint for unchanged content returns `unchanged`, without another test run or log entry. Use `verify.sh run` directly when an unchanged project needs a new check.

Log publication uses a sibling temporary file and atomic replacement. A private recovery record holds the intended log and its before/after digests. If publication was interrupted, the next invocation finishes that record once. Unexpected concurrent log edits stop recovery for inspection.

Private state lives in the worktree's self-ignored `.agent/.state` directory, including non-Git nodes. It is never loaded as memory. See [runtime.md](runtime.md).

## Exit status

| Status | Meaning |
| --- | --- |
| 0 | Entry recorded, content already recorded, or nothing to record since the last checkpoint |
| 1 | Refused, blocked, invalid input, or failed inspection. The last line says what was refused and the next step |

The session that owns the work owns checkpoint. Delegated workers write a lesson when they have one, through `learn.sh` or `memory.sh`, and never run checkpoint. The session-log entry is the owner's, one per integrated task. A worker in its own checkout writes its copy of the node, and the orchestrator merges it back with `absorb.sh` (`scripts/docs/absorb.md`).
