# verify.sh — execution receipts

`verify.sh` runs one named project check and records the result together with a fingerprint of the inputs it observed. It establishes execution evidence. It does not prove that a check provides adequate semantic coverage.

```
verify.sh run CHECK [--root ROOT] [--timeout SECONDS]
verify.sh check RECEIPT [--root ROOT]
```

The project-owned `.agents/scripts/checks.sh` receives `CHECK` as its sole argument. Configuration is non-executable `KEY=value` data in `.agents/scripts/verify.conf`: `CHECK_DRIVER`, `POSITIVE_TEST_CHECKS`, `TEST_COUNT_FORMAT` (`tap` or `none`), `TIMEOUT_SECONDS`, and optionally `NON_GIT_INPUT_ROOTS`. Command strings are not supported.

Every invocation prints one tab-separated result record on stdout. `run` returns 0 only for a pass, 1 for a failed or inconclusive run, 2 for usage/infrastructure errors, and 124 for timeout. `check` returns 0 for a current, structurally valid receipt even when that receipt records failure. Missing, malformed, or stale receipts return 2.

TAP counts require one unindented `1..N` plan and exactly N sequentially numbered top-level results. Nested plans are ignored. Missing, malformed, or duplicate top-level plans produce an unknown count. Incomplete result sets also produce an unknown count. A zero or unknown count makes a check named by `POSITIVE_TEST_CHECKS` inconclusive. A source change during the check also makes the result inconclusive.

Receipts are read as data, never sourced, and live in the private worktree state directory under `receipts/`. `check` accepts only the opaque ID printed by `run`, not a path. Each receipt binds its physical worktree, fingerprint, configured driver invocation, and UTC execution timestamp. A nonzero run can therefore leave a valid receipt that honestly records `fail` or `inconclusive`.

In Git worktrees, fingerprints cover the physical worktree identity, HEAD, read-only index entries, tracked working files (including executable-bit changes and missing files), and untracked non-ignored inputs. Canonical `.agents/` content stays covered even when ignored. The configured driver and verification configuration also stay covered. Checked-out submodule inputs are fingerprinted recursively. Unsupported submodule boundaries and unresolved index stages are refused. Runtime state, generated indexes, the session log and its atomic checkpoint files, and generated-mode `rules/learned.md` aggregates are excluded. Manual `rules/learned.md` remains an input.

In a non-Git node the runtime helper defaults to `.agents`. A verification pass is refused unless `NON_GIT_INPUT_ROOTS` explicitly declares the space-separated project-relative input roots to fingerprint. The verification config and its declared driver remain inputs even if those roots omit `.agents`. Paths containing spaces are supported inside a declared root, but declared root names themselves cannot contain spaces. Runtime state always lives in self-ignored `.agents/.state`, including when the project later adopts Git.

Timeout handling uses an invocation-owned watchdog while the parent waits directly for the driver. Normal completion cancels that watchdog immediately. Timeout signals only the driver's owned process group, including attached descendants. A descendant can deliberately detach into another process group. A portable Bash wrapper cannot discover or clean it up without broad process enumeration. Such drivers must supervise their own detached work.
