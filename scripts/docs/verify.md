# verify.sh — execution receipts

`verify.sh` runs one named project check and records the result together with a fingerprint of the inputs it observed. It establishes execution evidence. It does not prove that a check provides adequate semantic coverage.

```
verify.sh run CHECK [--root ROOT] [--timeout SECONDS] [--output-share N]
verify.sh check RECEIPT [--root ROOT]
verify.sh why RECEIPT [--root ROOT]
```

The project-owned `.agent/scripts/checks.sh` receives `CHECK` as its sole argument. Configuration is non-executable `KEY=value` data in `.agent/scripts/verify.conf`: `CHECK_DRIVER`, `POSITIVE_TEST_CHECKS`, `TEST_COUNT_FORMAT` (`auto`, `tap`, or `none`), `TIMEOUT_SECONDS`, and optionally `NON_GIT_INPUT_ROOTS`, `OUTPUT_MAX_BYTES`, and `OUTPUT_FAILURE_PATTERN`. Command strings are not supported.

`run` and `check` print one tab-separated result record on stdout. `run` returns 0 only for a pass, 1 for a failed or inconclusive run, 2 for usage/infrastructure errors, and 124 for timeout. A check whose captured output is gone when it ends is inconclusive, whatever it exited with. `check` returns 0 for a current, structurally valid receipt even when that receipt records failure. Missing, malformed, or stale receipts return 2.

The check's output prints on stderr. Output within `OUTPUT_MAX_BYTES` (default 29000) prints whole. A harness cuts a tool result past its own limit, about 30 KB on Claude Code, and that cut can fall on the one failing assertion. So longer output is trimmed here instead:

- A header states the output's size and where the full output is kept: `.agent/.state/output/<receipt-id>.log`.
- Every line matching `OUTPUT_FAILURE_PATTERN` prints first, with the five lines after it, up to half the limit.
- With TAP output, every failing TAP result line (`not ok`, indented subtests included) is chosen before any other line in that half, so one failure's context cannot crowd out another failure's name. A `not ok` marked `# TODO` is an expected failure and is not chosen.
- As many of the last lines as fit fill the rest.
- Every printed line carries its line number in the full output.

If the selection itself fails, for example on an invalid pattern, the plain last bytes print instead. A run that exits before its receipt is written still prints its output.

`--output-share N` divides the limit by N for one run, so N runs printed into one tool result stay within one limit together. `checkpoint.sh --checks` passes the number of checks it runs. The limit never drops below 1 byte. A share smaller than the trimming header prints only the header and the section markers, and the full output is still kept.

TAP counts require one unindented `1..N` plan and exactly N sequentially numbered top-level results. Nested plans are ignored. Missing, malformed, or duplicate top-level plans produce an unknown count. Incomplete result sets also produce an unknown count. A zero or unknown count makes a check named by `POSITIVE_TEST_CHECKS` inconclusive. A source change during the check also makes the result inconclusive. For both, `run` prints one more line on stderr that says why and names the next step.

`TEST_COUNT_FORMAT=auto`, the default, counts TAP by those rules. Output is TAP when it has a `TAP version` line or a top-level plan, and a summary line never stands in for a TAP stream that was cut short. For any other output, `auto` reads the runner's own closing summary and counts the tests that passed or failed:

| Runner | Line read | Count | Source |
|---|---|---|---|
| `node --test`, spec reporter | `ℹ pass 2`, `ℹ fail 0` | pass + fail | Node.js 24.16.0, observed |
| pytest | `==== 1 failed, 2 passed in 0.02s ====`, bare under `-q` | passed + failed + xfailed + xpassed | pytest 9.1.1, observed |
| Python unittest | `Ran 3 tests in 0.000s`, then `OK (skipped=1)` | tests run less skipped, never below 0 | Python 3.14.7, observed |
| Jest | `Tests:       1 failed, 2 passed, 3 total` | passed + failed | Jest 30.5.1, the template in its `SummaryReporter` source |
| Vitest | `Tests  1 failed \| 2 passed (3)` | passed + failed | Vitest 4.1.7, observed |
| `cargo test` | `test result: ok. 2 passed; 0 failed; …`, one per test binary | passed + failed, added up | cargo 1.99.1, observed |
| `go test -v` | `--- PASS: TestA (0.00s)`, unindented | top-level tests | Go 1.27.1, observed |
| minitest | `2 runs, 1 assertions, 0 failures, 0 errors, 1 skips` | runs less skips | minitest 5.11.3, observed |
| `bun test` | ` 2 pass`, ` 0 fail` | pass + fail | Bun 1.3.9, observed |

Skipped and filtered tests are left out, so a run whose every test was skipped or filtered away counts 0 and is inconclusive. A line of one of these shapes counts wherever it appears in the output. TAP counting does not leave skips out: `ok 1 # SKIP` counts as a result. `go test` without `-v` prints no count, so its driver line needs `-v`. A runner outside the table needs its TAP reporter in the check driver, or its own row here once its summary line has been observed.

`why` prints one word for a current receipt, so a caller need not guess the cause from the record. The words are `pass`, `failed`, `uncounted`, `format`, `empty`, and `changed`. `uncounted` is a positive check whose output carries no test count, and `format` is the same under `TEST_COUNT_FORMAT=tap` or `none`. `empty` is a positive check that ran 0 tests. `changed` is any other inconclusive run: project files changed, or its output was lost.

A positive check that lost its output reads as `uncounted`, because its count is unknown. `checkpoint.sh` picks its refusal from that word. `TEST_COUNT_FORMAT=tap` counts TAP alone, and `none` counts nothing.

The default counts summaries because counting TAP alone was measured to cost calls. The measurement ran on 2026-11-24 over the 19 corpus evals of `evals/spec.json`, 3 repeats, 57 sessions per agent. The fixtures run `node --test`, which prints the spec reporter when piped on Node.js 24. At `0056c13`, which counted TAP alone, 11 Claude sessions and 15 Codex sessions changed the project's test command to print TAP. At `530e0e9`, none did. Tool calls per session fell from 11.2 to 9.3 on Claude and from 9.8 to 8.7 on Codex, and the share of checks passed stayed within the noise of 3 repeats.

Receipts are read as data, never sourced, and live in the private worktree state directory under `receipts/`. `check` accepts only the opaque ID printed by `run`, not a path. Each receipt binds its physical worktree, fingerprint, configured driver invocation, and UTC execution timestamp. A nonzero run can therefore leave a valid receipt that honestly records `fail` or `inconclusive`.

Each receipt also records `fails_without_change`. No command sets it, so every receipt records `unknown`. The field is inside the receipt digest, and `check` refuses a receipt that lacks it or holds a value other than `yes`, `no`, or `unknown`. It lives in the receipt file only: the stdout record keeps its five fields, so `checkpoint.sh` and an orchestrator parsing that record read it unchanged. Receipt schema 3 added the field. A schema 2 receipt fails `check` as an invalid version, and a fresh `run` replaces it.

In Git worktrees, fingerprints cover the physical worktree identity, HEAD, read-only index entries, tracked working files (including executable-bit changes and missing files), and untracked non-ignored inputs. Canonical `.agent/` content stays covered even when ignored. The configured driver and verification configuration also stay covered. Checked-out submodule inputs are fingerprinted recursively. Unsupported submodule boundaries and unresolved index stages are refused. Runtime state, generated indexes, the session log and its atomic checkpoint files, and generated-mode `rules/learned.md` aggregates are excluded. Manual `rules/learned.md` remains an input.

In a non-Git node the runtime helper defaults to `.agent`. A verification pass is refused unless `NON_GIT_INPUT_ROOTS` explicitly declares the space-separated project-relative input roots to fingerprint. The verification config and its declared driver remain inputs even if those roots omit `.agent`. Paths containing spaces are supported inside a declared root, but declared root names themselves cannot contain spaces. Runtime state always lives in self-ignored `.agent/.state`, including when the project later adopts Git.

Timeout handling uses an invocation-owned watchdog while the parent waits directly for the driver. Normal completion cancels that watchdog immediately. Timeout signals only the driver's owned process group, including attached descendants. A descendant can deliberately detach into another process group. A portable Bash wrapper cannot discover or clean it up without broad process enumeration. Such drivers must supervise their own detached work.
