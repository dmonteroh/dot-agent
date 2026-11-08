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

`--checks` runs named checks through `verify.sh`. `--verification` consumes existing receipts for unchanged inputs. The two options are mutually exclusive.

Each check's output prints on stderr. The checks share one `OUTPUT_MAX_BYTES` limit equally, so their combined output fits one tool result. See [verify.md](verify.md) for how long output is trimmed.

A valid receipt determines the recorded verification status. Known failures and inconclusive checks stop automatic publication. Fix and retry, or explicitly add `--verify fail` to record a final failed outcome. A bare `--verify pass` is refused. `--verify fail` and `--verify n/a` remain explicit reports for failed or manual-only work.

Logging failed work is allowed. A successful checkpoint means the record was written, not that project tests passed. The output names the recorded verification status.

Checkpoint validates receipts again before publishing the log. A source edit between verification and completion requires fresh evidence. See [verify.md](verify.md) for the fingerprint boundary and count limitations.

## Review and health

Review and status run before verification. A finding that blocks stops checkpoint before any check runs, so a fix costs one check run rather than two. A check that changes the inputs they read records an inconclusive result, and receipts are validated again before logging.

For Git work, `review.sh` invokes the comment gate and reports catalog and coverage candidates. Its blocking or execution errors stop checkpoint. Advisory review candidates still need agent judgment.

`status.sh --format tsv` supplies stable finding codes. The default `POLICY=strict` in `checkpoint.conf` blocks every actionable finding. `--policy completion` defers advisory maintenance while structural defects remain blocking. Informational tool notes do not block either policy.

A failed status command, unexpected stderr, or malformed finding is an inspection failure. Checkpoint writes no entry in that case.

Generated-index nodes refresh their cache before logging. A missing or failed indexer remains advisory because canonical rules and docs remain available.

## Bases and ignored nodes

An uncommitted Git change defaults to `HEAD`. Use `--base <ref>` for committed work. Aliases resolving to the same comparison base share the same checkpoint identity.

A clean tree without an explicit base normally writes no entry. Use `--node-only` for a known node write hidden by Git ignore rules. This mode refuses outstanding product changes. Non-Git and node-only work report that no product diff was inspected.

An inherited dirty tree does not establish that the current turn changed anything. Call checkpoint only after changed work. Exact per-turn attribution still requires a runtime turn identifier or an explicit start snapshot.

## Retry and recovery

A private worktree lock serializes cooperating checkpoint and direct log writers. The checkpoint identity covers current inputs and the comparison base. Log output and runtime bookkeeping do not change that identity.

Repeating a successful checkpoint for unchanged content returns `unchanged`, without another test run or log entry. Use `verify.sh run` directly when an unchanged project needs a new check.

Log publication uses a sibling temporary file and atomic replacement. A private recovery record holds the intended log and its before/after digests. If publication was interrupted, the next invocation finishes that record once. Unexpected concurrent log edits stop recovery for inspection.

Private state lives in the worktree's self-ignored `.agent/.state` directory, including non-Git nodes. It is never loaded as memory. See [runtime.md](runtime.md).

## Exit status

| Status | Meaning |
| --- | --- |
| 0 | Entry recorded, or unchanged content was already recorded |
| 1 | Refused, blocked, invalid input, failed inspection, or no changed work |

The session that owns the work owns checkpoint. Delegated workers write their experience records through the node's writers (`log.sh`, `memory.sh`, `learn.sh`) and never run checkpoint. A worker in its own checkout writes its copy of the node, and the orchestrator merges it back with `absorb.sh` (`scripts/docs/absorb.md`).
