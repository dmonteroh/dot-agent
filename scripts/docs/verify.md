# verify.sh — execution receipts

`verify.sh` runs one named project check and records the result together with a fingerprint of the inputs it observed. It establishes execution evidence. It does not prove that a check provides adequate semantic coverage.

```
verify.sh run CHECK [--root ROOT] [--timeout SECONDS] [--output-share N]
verify.sh check RECEIPT [--root ROOT]
```

The project-owned `.agent/scripts/checks.sh` receives `CHECK` as its sole argument. Configuration is non-executable `KEY=value` data in `.agent/scripts/verify.conf`: `CHECK_DRIVER`, `POSITIVE_TEST_CHECKS`, `TEST_COUNT_FORMAT` (`tap` or `none`), `TIMEOUT_SECONDS`, and optionally `NON_GIT_INPUT_ROOTS`, `OUTPUT_MAX_BYTES`, and `OUTPUT_FAILURE_PATTERN`. Command strings are not supported.

Every invocation prints one tab-separated result record on stdout. `run` returns 0 only for a pass, 1 for a failed or inconclusive run, 2 for usage/infrastructure errors, and 124 for timeout. `check` returns 0 for a current, structurally valid receipt even when that receipt records failure. Missing, malformed, or stale receipts return 2.

The check's output prints on stderr. Output within `OUTPUT_MAX_BYTES` (default 29000) prints whole. A harness cuts a tool result past its own limit, about 30 KB on Claude Code, and that cut can fall on the one failing assertion. So longer output is trimmed here instead:

- A header states the output's size and where the full output is kept: `.agent/.state/output/<receipt-id>.log`.
- Every line matching `OUTPUT_FAILURE_PATTERN` prints first, with the five lines after it, up to half the limit.
- With `TEST_COUNT_FORMAT=tap`, every failing TAP result line (`not ok`, indented subtests included) is chosen before any other line in that half, so one failure's context cannot crowd out another failure's name. A `not ok` marked `# TODO` is an expected failure and is not chosen.
- As many of the last lines as fit fill the rest.
- Every printed line carries its line number in the full output.

If the selection itself fails, for example on an invalid pattern, the plain last bytes print instead. A run that exits before its receipt is written still prints its output.

`--output-share N` divides the limit by N for one run, so N runs printed into one tool result stay within one limit together. `checkpoint.sh --checks` passes the number of checks it runs. The limit never drops below 1 byte. A share smaller than the trimming header prints only the header and the section markers, and the full output is still kept.

TAP counts require one unindented `1..N` plan and exactly N sequentially numbered top-level results. Nested plans are ignored. Missing, malformed, or duplicate top-level plans produce an unknown count. Incomplete result sets also produce an unknown count. A zero or unknown count makes a check named by `POSITIVE_TEST_CHECKS` inconclusive. A source change during the check also makes the result inconclusive.

Receipts are read as data, never sourced, and live in the private worktree state directory under `receipts/`. `check` accepts only the opaque ID printed by `run`, not a path. Each receipt binds its physical worktree, fingerprint, configured driver invocation, and UTC execution timestamp. A nonzero run can therefore leave a valid receipt that honestly records `fail` or `inconclusive`.

Each receipt also records `fails_without_change`: `yes` when the check was seen failing at the base commit with only the change's test files applied, `no` when it passed there, and `unknown` when that was never run. Nothing runs it yet, so every receipt records `unknown`. The field is inside the receipt digest, and `check` refuses a receipt that lacks it or holds another value. It lives in the receipt file only: the stdout record keeps its five fields, so `checkpoint.sh` and an orchestrator parsing that record read it unchanged. Receipt schema 3 added the field. A schema 2 receipt fails `check` as an invalid version, and a fresh `run` replaces it.

In Git worktrees, fingerprints cover the physical worktree identity, HEAD, read-only index entries, tracked working files (including executable-bit changes and missing files), and untracked non-ignored inputs. Canonical `.agent/` content stays covered even when ignored. The configured driver and verification configuration also stay covered. Checked-out submodule inputs are fingerprinted recursively. Unsupported submodule boundaries and unresolved index stages are refused. Runtime state, generated indexes, the session log and its atomic checkpoint files, and generated-mode `rules/learned.md` aggregates are excluded. Manual `rules/learned.md` remains an input.

In a non-Git node the runtime helper defaults to `.agent`. A verification pass is refused unless `NON_GIT_INPUT_ROOTS` explicitly declares the space-separated project-relative input roots to fingerprint. The verification config and its declared driver remain inputs even if those roots omit `.agent`. Paths containing spaces are supported inside a declared root, but declared root names themselves cannot contain spaces. Runtime state always lives in self-ignored `.agent/.state`, including when the project later adopts Git.

Timeout handling uses an invocation-owned watchdog while the parent waits directly for the driver. Normal completion cancels that watchdog immediately. Timeout signals only the driver's owned process group, including attached descendants. A descendant can deliberately detach into another process group. A portable Bash wrapper cannot discover or clean it up without broad process enumeration. Such drivers must supervise their own detached work.

## Design: proving a test fails without the change

The quality bar asks for a test that fails without the change. Today that is prose, so a reviewer asks for the evidence and the session builds it by hand. A `verify.sh prove --base <ref> <check>` would run the check at `<ref>` with the change's test files applied, expect a failure, and record `fails_without_change` on the receipt of the normal run at the current tree. The change's test files are the paths in `git diff --name-only <ref>` that match `review.conf`'s `TEST_PATH_RE`, the same set `review.sh` already reads for `TEST_COVERAGE`. Two ways can produce that base tree.

**In place, by stash.** Stash every change except the test files, run the check, restore the stash.

- Cost: no second checkout and no cold build, because the build cache already holds the current tree and an incremental build reuses it.
- It moves the session's own working tree to the base for the whole run. An interrupt, a timeout, or a failed restore leaves the tree at the base with the work in the stash.
- The stash stack is shared by every worktree of the repository, so a concurrent session can pop the wrong entry.
- The run changes the tree it fingerprints, which `run` already reads as inconclusive. The proof would need its own exception to that rule.

**A temporary checkout.** `git worktree add --detach` at `<ref>` under the node's private state, copy the test files in, run the configured check there, and remove the checkout afterwards.

- Cost: a checkout's disk and its first build. A project whose build cache is large pays for that once per checkout, and a second copy of the cache when the checkout does not share it.
- The session's tree is never touched, so an interrupt costs a stray directory that `git worktree prune` and the next run clear, never work.
- The receipt's fingerprint rules hold unchanged, because the proof runs in a different physical worktree with its own state.
- Sharing the cache is project knowledge, not something `verify.sh` can know. The driver learns it is proving from an environment variable and points its own cache at the main checkout where the tool allows that: a shared package store, a target directory, a compiler cache.

**Choice: the temporary checkout.** The stash route is cheaper only while nothing goes wrong, and what it risks when something does is the session's uncommitted work, which no receipt can give back. The checkout's cost is disk and build time, which the driver can cut per project and the operator can see. One checkout per node, reused across runs by resetting it to the new base, bounds the disk to one copy. `prove` records `yes` only for a failing base run with a passing current run, `no` for a passing base run, and `unknown` for anything else: a setup failure, a timeout, an inconclusive count, or a change with no test files.

