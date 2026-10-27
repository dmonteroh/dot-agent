# Script documentation

These docs remain in the source repository. Nodes receive managed helpers, starter configuration, and a project-owned check driver. `node.sh` defines the installed set in `SHIPPED_SCRIPTS` and `SHIPPED_CONFIGS`.

| Script | Role | Documentation |
| --- | --- | --- |
| `status.sh` | Node findings and context loading | [status.md](status.md) |
| `log.sh` | Entry formatting and direct writing | [log.md](log.md) |
| `memory.sh` | Canonical lookup and fact writing | [memory.md](memory.md) |
| `docs.sh` | Doc routing and catalog updates | [docs.md](docs.md) |
| `links.sh` | On-demand link audit | [links.md](links.md) |
| `comments.sh` | Diff comment gate | [comments.md](comments.md) |
| `review.sh` | Comment gate plus catalog and coverage candidates | [review.md](review.md) |
| `verify.sh` | Project check execution and receipts | [verify.md](verify.md) |
| `capture.sh` | Optional lifecycle snapshot prototype | [capture.md](capture.md) |
| `runtime.sh` | Internal state, fingerprint, and lock functions | [runtime.md](runtime.md) |
| `checkpoint.sh` | Completion orchestration and retry-safe logging | [checkpoint.md](checkpoint.md) |
| `index.sh` | Generated context cache | [index.md](index.md) |
| `learn.sh` | Learned-record lookup and versioned writing | [learn.md](learn.md) |
| `absorb.sh` | Merging a worker checkout's node back into the main node | [absorb.md](absorb.md) |
| `session-start.sh` | The session-start hook body: the load, before the first turn | [session-start.md](session-start.md) |
| `checks.sh` | Project-owned check driver | [v6.3-trial.md](v6.3-trial.md) |
| `node.sh` | Source-repository installer and updater | [node.md](node.md) |
| `test.sh` | Source-repository regression suite | [test.md](test.md) |

The fifteen managed helpers are replaced atomically on update. Existing configurations and `checks.sh` are preserved. `node.sh`, `test.sh`, this documentation, and evaluation files are not installed into nodes.

## Arguments and output

Read each helper's `--help`. Writers generally accept a trailing root. `index.sh`, `verify.sh`, and `review.sh` use `--root`. `comments.sh` accepts a Git base and runs inside the project. `runtime.sh` is a sourced library.

Verification emits a receipt record on stdout and bounded check output on stderr. Status defaults to human text. `--format tsv` emits actionable findings with stable codes and severity. Configurations are plain data and are never executed.

## Exit meanings

| Helper | Result |
| --- | --- |
| `status.sh`, `links.sh` | 0 means inspection ran, even when it found issues |
| `comments.sh`, `review.sh` | 0 means completed without a blocking comment, 1 blocks, 2 means inspection failed |
| `verify.sh run` | 0 passes, 1 fails or is inconclusive, 2 is an invocation error, 124 times out |
| `verify.sh check` | 0 means the receipt is valid, even when it records failure |
| `checkpoint.sh` | 0 means recorded or already recorded, 1 means no entry was written |
| `index.sh` | 0 succeeds, 1 reports stale/fallback, 2 rejects invocation |
| `absorb.sh` | 0 merged without conflict, 3 merged around reported conflicts, 2 refused |

Writers have their own refusal codes. Their linked docs define version conflicts, duplicate records, and other cases. A passing command exit alone does not establish that a behavior was tested.
