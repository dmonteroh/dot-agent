# verify.sh — execution receipts

`verify.sh` runs one named project check and records the result together with a fingerprint of the inputs it observed. It establishes execution evidence. It does not prove that a check provides adequate semantic coverage.

```
verify.sh run CHECK [--root ROOT] [--timeout SECONDS] [--output-share N]
verify.sh prove CHECK --test PATH... [--base REF] [--root ROOT] [--timeout SECONDS]
verify.sh prove CHECK --break PATH=FILE... [--test PATH...] [--root ROOT] [--timeout SECONDS]
verify.sh check RECEIPT [--root ROOT]
verify.sh why RECEIPT [--root ROOT]
```

The project-owned `.agent/scripts/checks.sh` receives `CHECK` as its sole argument. Configuration is non-executable `KEY=value` data in `.agent/scripts/verify.conf`: `CHECK_DRIVER`, `POSITIVE_TEST_CHECKS`, `TEST_COUNT_FORMAT` (`auto`, `tap`, or `none`), `TIMEOUT_SECONDS`, and optionally `NON_GIT_INPUT_ROOTS`, `OUTPUT_MAX_BYTES`, and `OUTPUT_FAILURE_PATTERN`. Command strings are not supported.

`run`, `prove`, and `check` print one tab-separated result record on stdout. `run` returns 0 only for a pass, 1 for a failed or inconclusive run, 2 for usage/infrastructure errors, and 124 for timeout. A check whose captured output is gone when it ends is inconclusive, whatever it exited with. `check` returns 0 for a current, structurally valid receipt even when that receipt records failure. Missing, malformed, or stale receipts return 2.

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

`why` prints one word for a current receipt, so a caller need not guess the cause from the record. The words are `pass`, `proved`, `unproved`, `failed`, `uncounted`, `format`, `empty`, and `changed`. `proved` and `unproved` are a pass whose proof ran and held or did not. `uncounted` is a positive check whose output carries no test count, and `format` is the same under `TEST_COUNT_FORMAT=tap` or `none`. `empty` is a positive check that ran 0 tests. `changed` is any other inconclusive run: project files changed, or its output was lost.

A positive check that lost its output reads as `uncounted`, because its count is unknown. `checkpoint.sh` picks its refusal from that word. `TEST_COUNT_FORMAT=tap` counts TAP alone, and `none` counts nothing.

The default counts summaries because counting TAP alone was measured to cost calls. The measurement ran on 2026-11-24 over the 19 corpus evals of `evals/spec.json`, 3 repeats, 57 sessions per agent. The fixtures run `node --test`, which prints the spec reporter when piped on Node.js 24. At `0056c13`, which counted TAP alone, 11 Claude sessions and 15 Codex sessions changed the project's test command to print TAP. At `530e0e9`, none did. Tool calls per session fell from 11.2 to 9.3 on Claude and from 9.8 to 8.7 on Codex, and the share of checks passed stayed within the noise of 3 repeats.

Receipts are read as data, never sourced, and live in the private worktree state directory under `receipts/`. `check` accepts only the opaque ID printed by `run`, not a path. Each receipt binds its physical worktree, fingerprint, configured driver invocation, and UTC execution timestamp. A nonzero run can therefore leave a valid receipt that honestly records `fail` or `inconclusive`.

Each receipt also records `proof` and `fails_without_change`. `run` writes `proof=none` and `fails_without_change=unknown`. `prove` writes `yes` when the check fails without the change and passes with it, `no` when it passes without the change, and `unknown` with `proof=none` when nothing could be proved. After a verdict, `proof` names what it rests on: `base:<commit>:<digest>` or `break:<digest>:<digest>`. The last digest covers the content of the `--test` files, and the first digest of `break` covers the broken copies. The fingerprint leaves Git-ignored files out, so this line is what keeps a scratch test's proof on record after the file is deleted.

Both fields are inside the receipt digest, and `check` refuses a receipt that lacks either or holds a pair that cannot occur. They live in the receipt file only: the stdout record keeps its five fields, so `checkpoint.sh` and an orchestrator parsing that record read it unchanged. Receipt schema 3 added both fields. A schema 2 receipt fails `check` as an invalid version, and a fresh `run` replaces it.

In Git worktrees, fingerprints cover the physical worktree identity, HEAD, read-only index entries, tracked working files (including executable-bit changes and missing files), and untracked non-ignored inputs. Canonical `.agent/` content stays covered even when ignored. The configured driver and verification configuration also stay covered. Checked-out submodule inputs are fingerprinted recursively. Unsupported submodule boundaries and unresolved index stages are refused. Runtime state, generated indexes, the session log and its atomic checkpoint files, and generated-mode `rules/learned.md` aggregates are excluded. Manual `rules/learned.md` remains an input.

In a non-Git node the runtime helper defaults to `.agent`. A verification pass is refused unless `NON_GIT_INPUT_ROOTS` explicitly declares the space-separated project-relative input roots to fingerprint. The verification config and its declared driver remain inputs even if those roots omit `.agent`. Paths containing spaces are supported inside a declared root, but declared root names themselves cannot contain spaces. Runtime state always lives in self-ignored `.agent/.state`, including when the project later adopts Git.

Timeout handling uses an invocation-owned watchdog while the parent waits directly for the driver. Normal completion cancels that watchdog immediately. Timeout signals only the driver's owned process group, including attached descendants. A descendant can deliberately detach into another process group. A portable Bash wrapper cannot discover or clean it up without broad process enumeration. Such drivers must supervise their own detached work.

## Proving a test fails without the change

A test that passes proves little until it has been seen to fail. `prove` produces that evidence without touching the session's tree.

```
verify.sh prove test --test tmp/scratch/retry.test.ts
verify.sh prove test --base <commit before the work> --test test/retry.test.ts
verify.sh prove test --break src/client.ts=tmp/scratch/client.broken.ts
```

1. It runs the check on the current tree, as `run` does. A check that does not pass now is recorded as a failed run, and nothing is proved.
2. It copies the `--test` and `--break` files aside, then runs and digests those copies, so an edit during the runs cannot change what the receipt names. It makes a throwaway clone of the repository in the temporary folder and copies the current changes into it. Those are every file that differs from `HEAD`, every untracked file Git does not ignore, and each `--test` file, ignored or not.
3. It runs the check there once as a control. A check that fails there cannot run in the checkout, so the verdict is `unknown` and the output of that run prints.
4. It runs the check without the change. With `--test`, the checkout goes to `--base` (default `HEAD`, and always an ancestor of it). The check runs there once with no test file copied in, as a second control: a check that already fails at the base would fail with any test, so the verdict is `unknown`. Then each test file is copied onto the base and run on its own. With `--break PATH=FILE`, the current files stay and `PATH` is replaced by `FILE`, a copy the session broke on purpose.
5. The verdict is `yes` when every one of those runs fails, and `no` when one passes. The message names a test file that passes at the base.

`prove` exits 0 only for `yes`. It prints the output of the runs without the change, so the session can confirm each failure is the one it means. `yes` says the check fails there, and a missing file or a syntax error fails too.

`--break` is for a test that guards a rule the old code already met. Such a test passes at every base, so only breaking the behavior can show that it notices. Copy the file into the scratch folder, break the behavior in the copy, and pass the pair.

Each test file gets its own run because a runner that stops at its first failure would let one failing test stand for the others. Inside one file the runner decides. The driver sees `DA_PROVE=1` in the checkout, and a driver that turns off fail-fast there prints every failing test.

The checkout holds tracked and unignored files only. Installed dependencies and local configuration are usually ignored, so the driver also gets `DA_PROVE_MAIN`, the path of the project, and reads or links what the checkout lacks from there. Link dependencies only. A build of the base commit would write into a build cache linked from the project. The driver must run relative to its working directory, because a driver that changes into the project's own path would run the current files every time and record `no`.

A check that runs one new test file finds nothing to run at the base, and so does a suite whose first test is the one being proved. The second control reads a nonzero exit there as a base that already fails. Make the driver exit 0 for that case in the checkout alone, so a plain run over a missing file still fails:

```bash
scratch-*)
  file="tmp/scratch/${1#scratch-}.sh"
  [ -z "${DA_PROVE:-}" ] || [ -f "$file" ] || exit 0
  exec bash "$file" ;;
```

A `--test` file that such a check does not run then passes at the base, and the verdict is `no`. Such a check has no control at the base, so read its failing line with care: a base that cannot load the test file at all also counts as a failure.

Limits:

- A repository with submodules gets `unknown`, because the clone does not populate them.
- A node outside Git cannot prove.
- A `--test` or `--break` path that is a symbolic link, or that passes through one in the checkout, is refused, because a write through it could reach the project.
- The caller's Git environment variables are dropped for the checkout, and `DA_PROVE` from the caller never reaches a run of the current tree.
- A check that already fails at the base gives `unknown`, whether a test was red there, the base needs other dependencies than the current tree, or the check found no test to run.
- `prove` runs the check at least four times with `--test` and three with `--break`, so prove a focused check and leave the whole suite to `run`.
- Only folders are made writable before the checkout is cleaned or removed. A file there can be a hard link to one of the project's own.
- `checkpoint.sh --prove` runs a `--test` proof in the closing call and refuses to log one that did not hold. A `--break` proof runs here, and its receipt goes to `checkpoint.sh --verification` like any other.

The clone uses `git clone --shared`, which copies no objects and registers nothing in the session's repository. A stash was rejected because an interrupt would leave the session's work in the stash stack, which every worktree shares. A linked worktree was rejected because it stays registered in the repository after an interrupt.
