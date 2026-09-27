# Follow-up evaluation results, 27 September 2026

Shorten the contract selectively. Preserve explicit behavior tests, catalog updates, source-origin reporting, and continuity admission. Neither the 317-word draft nor the new 650-word draft has earned promotion to the shipped preset.

Sonnet ran successfully after the authentication check received access to macOS Keychain. The earlier claim that this machine lacked a Claude login was incorrect. The [recommendations](recommendations-2026-09-27.md) explain the proposed contract changes.

## Canonical comparisons

Both CLIs requested medium effort: `claude-sonnet-5` through Claude CLI 2.1.280, and `gpt-5.6-terra` through Codex CLI 0.155.1. Both used corpus `390d30f213925392a61c736725316824704d117d`.

The control is the installed software-development contract. The treatment is `short-protocol-report.md`. Scripts, entry points, fixtures, and index mode stay fixed within each pair. Provider sampling defaults remain unpinned.

| Comparison | Tasks | Repeats per arm | Current checks passed | Short checks passed | Tool calls: current / short |
| --- | ---: | ---: | ---: | ---: | ---: |
| [Sonnet canonical](results/sonnet-full.json) | 9 | 3 | 88/90 | 87/90 | 219 / 208 |
| [Terra complete task pairs](results/terra-complete-pairs.json) | 6 | 3 | 53/54 | 51/54 | 129 / 104 |
| [Terra recovery pairs](results/terra-continuity-recovery.json) | 3 | 1 | 12/12 | 12/12 | 19 / 25 |

These counts include every repeat and weight each assertion equally. Repeated assertions within a task are correlated, so the denominators are not independent trials. Each linked export contains configuration, snapshots, every grade, and artifact hashes.

Sonnet's majority score is 29/30 for both contracts. Its catalog-update check is unstable: current passed once in three repeats, while short passed zero times. All other canonical assertions passed on all Sonnet repeats.

The first isolated Terra round completed 49 of 54 sessions. Four timed out and one exited unsuccessfully. Those failures affected continuity write-back, memory supersession, and source-origin handling. The six-task score excludes each affected task's entire pair. A separate one-repeat round completed all three missing pairs with a 600-second limit. Do not pool the two repeat budgets into one headline rate.

### Regression: routing-catalog-first/catalog-entry-added

Terra's current contract added the catalog entry in 3/3 repeats. The short contract added it in 0/3.

Current evidence: `+| submitRefund | src/client.ts | submit a payment refund through the vendor refunds endpoint |` in the node diff. Short evidence: the product diff adds `export async function submitRefund`, while the node diff contains no catalog change.

Keep an explicit catalog-update obligation. Add a checkpoint review for new exported helpers absent from the catalog. The pilot below shows that a prose instruction alone remains unreliable.

Terra's brief-answer test check was also unstable. Current avoided testing in 2/3 repeats, while short avoided testing in 3/3. This is a split observation, not a stable improvement.

## Product quality changed outside the original checklist

The original checklist emphasized harness compliance. It could pass a new implementation that had no behavior test or could not load in the fixture runtime. An independent [post-hoc audit](results/product-quality-audit.json) checked the completed implementations.

| Matched audit | Current | Short |
| --- | --- | --- |
| Sonnet backoff behavior | 3/3 passed the independent check | 3/3 passed the independent check |
| Sonnet backoff test files | Changed in 3/3 runs | Changed in 0/3 runs |
| Terra refund behavior | 3/3 passed the independent check | 0/3 passed the independent check |
| Terra refund test files | Changed in 3/3 runs | Changed in 0/3 runs |

All three short-contract Terra refund implementations imported `./http` without the `.ts` extension. Node 24.16.0 could not resolve that import. Their `npm test` commands succeeded while discovering zero tests. The current-contract implementations included request tests and passed the independent check.

This audit was added after seeing the outputs. It is diagnostic evidence, not a preregistered headline score. Changed test files do not establish adequate coverage by themselves. The oracle checks actual behavior separately.

The retry oracle checks first-call success, success after two transport failures, and exhaustion after three failures. It does not validate delay magnitude or HTTP error policy. The refund oracle checks route, method, payload, and returned response. Both run with filesystem permissions limited to the fixture and oracle directory.

## Length, language, and content

These Sonnet smoke comparisons each ran three tasks once per arm. The reference was `short-protocol-report.md`. Each treatment changed one named prose dimension, with semantic differences acknowledged in the experiment plan.

| Treatment | Reference checks passed | Treatment checks passed |
| --- | ---: | ---: |
| [Expanded wording](results/sonnet-length.json) | 11/11 | 11/11 |
| [Paragraph wording](results/sonnet-language.json) | 11/11 | 11/11 |
| [Engineering content](results/sonnet-content.json) | 11/11 | 11/11 |

These checks did not discriminate between the variants. They establish smoke coverage, not equivalence or a winning prose style. The first language attempt timed out on both security cells. Its [partial export](results/sonnet-language-partial.json) remains separate from the successful rerun.

The engineering-content variant added backoff tests in its one run. Its reference added none. Both implementations passed the independent behavior check. This supports retaining targeted test guidance, with a one-repeat limitation.

Terra's length, language, and content matrix remains prepared for execution. Its broader canonical comparison and the compact-core pilot ran live. Larger models remain untested.

## Learning and continuity extension

[Sonnet's six additional scenarios](results/sonnet-continuity.json) passed 15/17 checks in both arms, with one repeat per arm. Both handled scoped constraints, preference supersession, unremarkable work, and a fresh-session continuation.

Both missed the canonical-source response in `memory-admission/says-where-it-lives`. They asked what work to do instead of naming the source that already held the requested information. Neither wrote a duplicate memory fact.

Both failed the strict single-record discovery check. They described the generation boundary in both a doc and a guardrail. The useful discovery survived. Review the duplicate-record criterion before using it as a release gate, since guardrail pointers can be appropriate.

The handoff scenario restarts the same CLI over the same tree. It does not test a Claude-to-Codex handoff or actual provider compaction. That cross-vendor continuation remains a release-coverage gap.

## Compact-core pilot

The [650-word candidate](continuity-core.md) restores explicit tests and catalog updates. It retains the continuity admission distinctions while removing detailed comment examples and fixed planning steps. Its two-task [quality spec](quality-spec.json) adds behavior and coverage checks.

[Terra](results/terra-core-pilot.json) scored 11/12 on both current and core. The unchanged aggregate hides one gain and one regression. Core added the refund catalog entry, which current missed. Core omitted backoff tests, which current supplied. Both implementations passed the independent behavior oracle.

### Regression: quality-continuity-writes-back/behavior-covered

Current evidence: the added test asserts three calls, delays of `[100, 200]`, and rejection after exhaustion. Core evidence: the diff changes only `src/client.ts`, with no test file.

Retain this coverage check. Compare selective removals from the current contract before promoting the compact draft. Investigate recording verification evidence and zero-test outcomes in tooling. Stronger repeated prose is not supported by this pilot.

[Sonnet's completed refund pair](results/sonnet-core-pilot-partial.json) scored 4/5 in both arms. Both omitted the catalog entry. The core backoff implementation completed and passed the oracle, but its current-contract counterpart became stuck in tests. I cancelled that cell after it issued `pkill -f "node --test"`. The paired backoff score is excluded. That cancellation is not counted as an ordinary model failure or a candidate win.

The pilot used familiar prompts and one repeat. It is not a held-out evaluation. Keep the draft experimental.

## Cost and runtime limits

Sonnet's canonical mean duration was 57.0 seconds for current and 54.1 seconds for short. Population standard deviations were 30.7 and 33.1 seconds. Tool calls were 219 and 208. This does not establish a clear latency advantage.

Claude reported estimated usage costs of $3.47 and $2.55 for those arms. These are CLI usage estimates, not subscription charges. Each export preserves input, cache, and output fields separately. Terra did not report a dollar estimate. Token semantics differ by provider, so no cross-provider cost ranking is presented.

The [run manifest](results/run-manifest.json) accounts for 185 attempted evaluation sessions: 172 completed, seven timed out, five were cancelled, and one exited unsuccessfully. Completion means the runner captured the session, not that its assertions passed. Four cancellations belong to the interrupted first Terra round.

That first Terra round tried to synchronize remote plugins and start app connectors despite its disposable home. The adapter now disables those services for new and resumed evaluation turns. Later timeouts still occurred, so the fix does not explain every runtime failure.

I also changed the runner while four Sonnet shell invocations were still active. They reported trailing shell errors after artifact capture. All 54 canonical Sonnet records and output sets completed. These runner diagnostics remain recorded rather than being attributed to the model.

No fixed-list isolation markers appeared in accepted exports. That scan does not prove total isolation. Raw outputs remain in the workspaces named by each export. Interrupted sessions left four owned temporary Codex homes, which cleanup removed.

## What changed in the evaluation tools

- Claude authentication errors now distinguish absent credentials from inaccessible Keychain credentials.
- Codex evaluation sessions disable app connectors and plugin loading.
- Catalog triage leaves exported-helper decisions for review instead of proposing a vacuous pass.
- The exporter rejects unfinished runs and missing grades unless an entire paired task is explicitly excluded.
- Independent behavior checks cover retry exhaustion and refund calls.
- Configuration, repeated grades, diagnostics, and artifact hashes are retained with the results.

The repository suite passed 1,360/1,360 checks. Seven focused reporting and oracle tests passed. Shell syntax checks passed. The prose deliverables passed the writing linter's blocking checks.

Before release, run the candidate against held-out wording, learning cases on both vendors, comments, generated indexes, and stress scenarios. Keep every observed regression in that gate. The next update should remove duplication while moving observable enforcement into the scripts that already own completion.
