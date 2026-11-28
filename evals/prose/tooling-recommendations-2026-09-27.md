# Tooling recommendations from the prose evaluations

Build verification evidence first, then a diff review inside checkpoint. Extend the existing writers for lookup and routing maintenance. Keep a short contract for decisions the scripts cannot make.

Here, Bash-only means Bash 3.2, Git, and standard Unix utilities. The harness needs no Python, JavaScript runtime, model call, database, or daemon. Project verification still invokes the project's own tools. A Bash wrapper cannot make a slow test suite fast.

These are proposed interfaces and changes. This investigation does not modify the shipped scripts.

## Priorities

| Order | Tool change | What moves out of prose | What remains an agent decision |
| --- | --- | --- | --- |
| 1 | Add `verify.sh`, consumed by `checkpoint.sh` | Command execution, exit capture, stale-result checks, known zero-test detection | Relevant checks, failure cause, and whether tests cover the requested behavior |
| 2 | Add `review.sh`, called by checkpoint | Changed-path collection, catalog candidates, missing-test signals, existing comment checks | Whether a helper is reusable and whether existing tests suffice |
| 3 | Make checkpoint retries idempotent | Repeated logging checks and manual duplicate avoidance | The summary and whether another task changed intent |
| 4 | Extend `memory.sh lookup` and batch `learn.sh lookup` | Finding canonical records, exact duplicates, current versions, and owning paths | Semantic equivalence, durable value, scope, and source trust |
| 5 | Extend `docs.sh` with `sync` and `catalog` operations | Routing metadata synchronization and catalog row syntax | Routing hooks, descriptions, and documentation content |
| 6 | Give `status.sh` stable finding codes and severity | Parsing diagnostic prose and repeatedly inspecting unrelated maintenance debt | Distillation, retirement, and corrections that require understanding |

The strongest evidence supports the first two. The [product audit](results/product-quality-audit.json) found three unimportable Terra refund implementations with zero discovered tests. Sonnet's short-contract backoff changes omitted tests in all three repeats. Catalog updates also failed under both long and short contracts.

## 1. Record verification through `verify.sh`

Proposed use:

```sh
bash .agent/scripts/verify.sh run test
bash .agent/scripts/checkpoint.sh --verification <receipt-id> \
  --tool <tool> --area payments --summary "Added refund submission"
```

`verify.sh` invokes a named check from a project-owned check driver. That driver contains the exact approved project commands. Plain configuration maps check names to the driver. Configuration is parsed as data and never sourced or passed to `eval`.

The driver should become the command authority. Project guardrails point to it, so commands cannot drift between prose and configuration. The wrapper executes argument arrays or a checked-in script, preserving quoting.

The receipt records the check identity, exact invocation, input fingerprint, exit status, completion state, and test count when known. Its fingerprint covers the worktree, relevant tracked and untracked inputs, and check configuration. Hash file content, not just `git status`. Detect input changes during execution.

Store receipts outside loaded context, under the worktree's private Git directory. Use an explicit local state directory for non-Git nodes. Receipts and temporary test output do not enter memory, learned rules, or the session log.

Checkpoint derives verification status from the selected receipt. Missing, stale, or interrupted evidence cannot become `verify: pass`. A failed receipt can still produce an honest failed-work log entry. Completion of logging and success of the task are different outcomes.

An optional `checkpoint.sh --checks test` can run the configured check and finish in one call. Keep direct `verify.sh` available for earlier development checks. This uses the tool call already needed for verification.

Distinguish three test-count states: positive, zero, and unknown. Parse a supported runner format or consume a declared project adapter. An unrecognized output format stays unknown. Never infer a positive count from exit zero alone.

Projects choose which checks require a positive test count. Documentation-only work can report `n/a` with a reason. Existing tests may cover a behavior change, so unchanged test files are not a universal blocker.

Use a tracked child process and bounded execution. Stop only a process or group owned by this invocation. Never use a broad `pkill` pattern. Full descendant cleanup needs explicit supervision tests on macOS and Linux. A Bash timeout alone does not guarantee containment of detached descendants.

This tool establishes what ran against which inputs. It cannot prove test adequacy or classify a failure's cause. It also cannot attest to unchanged external services or prevent an agent from forging local files.

## 2. Put diff review inside checkpoint

Proposed standalone interface:

```sh
bash .agent/scripts/review.sh --base <ref>
```

Checkpoint calls this automatically. The agent should not need another mandatory tool call. Run the existing comment gate once through this path.

Collect changed paths and diff content once. Cover committed changes, staged changes, unstaged changes, and untracked files. Use NUL-delimited paths internally. Reuse the declared base across verification, comments, catalog review, and logging.

The first review should surface only a few actionable findings:

```text
REVIEW catalog-entry src/client.ts submitRefund has no matching catalog row
REVIEW test-coverage src/client.ts changed without a test-file change
CHECK verification test exit=0 tests=0
```

Use project-configured source roots, test roots, catalogs, and narrow symbol patterns. Include helpers added inside existing modules. The old grader's new-file-only shortcut missed exactly that case.

A pattern match identifies a review candidate. It does not prove that every export deserves a catalog entry. Unsupported syntax should report an incomplete scan. It must not report a clean catalog by default.

Likewise, a test-file change does not prove behavior coverage. Keep that finding advisory until a project supplies a checkable stronger rule. Objective failures, such as a known zero-test result under a configured requirement, can block a passing verification claim.

Do not add a universal rule against extensionless imports. Their validity depends on the project's runtime. The refund defect belongs in a project test or import check run through `verify.sh`.

## 3. Make checkpoint retries safe

The [script reproduction](results/tooling-script-audit.json) ran two successful checkpoints over the same dirty tree. Both appended an entry. Neither invocation ran a test command, yet both accepted `--verify pass`.

[checkpoint.sh](../../scripts/checkpoint.sh) currently sequences comments, status, and logging. [log.sh](../../scripts/log.sh) validates the caller's verification label and appends unconditionally. Neither stores a completed-checkpoint identity.

Add a worktree-scoped lock and a persisted identity for the checkpointed content. Exclude the log and bookkeeping state from that identity. Repeating a successful checkpoint for unchanged content should return `unchanged` without appending.

Make log publication and identity recording recoverable across interruption. A failure between those writes must not duplicate the entry on retry. Use temporary files, atomic replacement, and a small recovery record. Test the interruption boundary explicitly.

This still cannot identify every user turn. A dirty tree can contain inherited work. Exact per-turn logging needs an explicit start snapshot or a runtime-provided turn identifier. Do not infer turn boundaries from timestamps or dirty status.

Keep that start marker optional until evaluations justify its extra interaction. The first improvement is reliable retries of the existing completion command.

## 4. Retrieve existing knowledge before admission

Proposed read-only interface:

```sh
bash .agent/scripts/memory.sh lookup --query "webhook generation"
```

Search purpose, rules, memory, and routed docs. Return matching paths, record versions, and short excerpts. Prefer exact phrase and identifier matches before broader term overlap. Report truncation when a configured result limit is reached.

This makes the canonical-source check one bounded operation. The agent can cite an existing owner instead of writing a duplicate fact. For code-level ownership, search only explicit source roots or paths relevant to the task.

[learn.sh](../../scripts/learn.sh) already performs exact-duplicate checks, lexical overlap checks, and versioned updates. Reuse those conventions. Its lookup currently launches comparison processes per record. Batch tokenization and matching into one `awk` pass where practical, then hash only returned records.

Compare record bodies separately from timestamps when checking exact content duplicates. Add file or stdin input to the memory writer, matching `learn.sh`, to reduce shell-quoting mistakes.

Support expected-version checks on `memory.sh supersede`, matching `learn.sh revise`. A stale session should detect a newer fact before replacing it.

Support retrieval from both manual `rules/learned.md` and generated learned records. Leave writes with their existing owners. Do not silently migrate storage modes to provide lookup.

No match is not permission to write. Bash cannot establish whether a lesson generalizes, whether two sentences are synonymous, or whether processed material represents a user instruction. Keep the admission decision table and source-origin rule in the contract.

## 5. Finish the mechanical doc writers

Proposed commands:

```sh
bash .agent/scripts/docs.sh sync --name webhooks
bash .agent/scripts/docs.sh catalog --catalog service-catalog.md \
  --name submitRefund --path src/client.ts --when "Submitting a vendor refund"
```

`sync` derives the routing section list from the doc's actual headings. It reconciles the route with an existing `Read when:` header. A missing hook requires supplied text because its meaning cannot be inferred mechanically. The command preserves the document body.

`catalog` validates the referenced path and creates or updates one entry. It handles escaping and duplicate identity checks. An ambiguous or malformed table causes a diagnostic, never silent rewriting.

[docs.sh](../../scripts/docs.sh) already has `new` and `rehook`. These additions complete its existing responsibility. They avoid asking agents to remember table syntax or manually synchronize multiple locations.

## 6. Separate repair from maintenance

Checkpoint currently blocks on every `GROOM:`, `REPAIR:`, and `INDEX:` line. Those prefixes combine different consequences. A log-size threshold can therefore hold up an otherwise finished change.

Add stable finding codes and an optional machine-readable format. Preserve existing human output and exit meanings for compatibility. Checkpoint should consume codes instead of grepping prose prefixes.

Classify each finding explicitly. Missing canonical files, broken fact references, and unusable load payloads remain blocking. Ordinary size-triggered grooming can become advisory under an opt-in completion policy. Do not downgrade the entire `GROOM:` category automatically.

Keep a full audit on demand and before release. Changing completion policy needs its own paired evaluation. A fast path must not silently omit checks required for the current write.

## Cost and implementation constraints

[Measured script costs](results/tooling-script-audit.json) on this Mac, using the pinned small fixture:

| Operation | Repetitions | Median | p95 |
| --- | ---: | ---: | ---: |
| `status.sh` | 20 | 171 ms | 231 ms |
| `status.sh --load` | 20 | 187 ms | 233 ms |
| `comments.sh HEAD` | 20 | 120 ms | 161 ms |
| `learn.sh lookup`, 10 short records | 10 | 78 ms | 282 ms |
| `learn.sh lookup`, 100 short records | 10 | 473 ms | 835 ms |

These are warm, single-machine measurements of current scripts. The lookup cases have no matching records. They do not predict large-repository latency or measure any proposed implementation. Status load emitted 21,569 bytes in this fixture, so output size also deserves attention.

Choose a p95 target below 500 ms for combined completion metadata checks on the small fixture. Exclude project tests and builds from that budget. Treat this as a development target, not a promised performance result.

Keep the implementation small:

- Use existing Git and Unix dependencies, including Bash 3.2-compatible constructs.
- Parse configuration as data.
- Keep successful output short and diagnostic output bounded.
- Provide stable codes, `--help`, and a version identifier for new commands.
- Use separate statuses for completed checks, findings, and execution errors.
- Scan selected files in batches instead of spawning a process for every rule.
- Put no extra report, receipt, or checklist into the always-loaded files.

Update the init and update copy lists in [node.sh](../../scripts/node.sh). Include starter configuration, update preservation, and non-Git behavior. New commands also need script-level failure tests. A file under this repository's `scripts/` is not automatically installed into a node.

## Acceptance tests before shortening the contract

Require the tooling to distinguish exit-zero with no tests from a positive test run. Check stale receipts after source edits and edits made during a check. Exercise staged, unstaged, untracked, and already-committed changes.

Require catalog review to catch a helper added inside an existing file. Test a valid existing-test case that should remain advisory. Verify that lookup finds canonical docs in both index modes without admitting records itself.

Require repeated checkpoints to append once. Interrupt log publication and retry it. Exercise inherited dirty work, concurrent writers, and a hung test without affecting unrelated processes.

Then run the paired agent evaluations with the reduced prose. Keep the current and candidate contracts fixed while changing only the tooling. Afterward, hold the tooling fixed and compare prose removal. This separates a better script from a weaker instruction.

Start with `verify.sh`, checkpoint integration, and catalog review. Keep logging, memory admission, source-origin handling, and learning scope explicit until those comparisons support removing more text.
