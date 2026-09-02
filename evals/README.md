# `evals/` — measuring what the corpus does to an agent

`scripts/test.sh` checks the corpus as an artifact: the text is present, the scripts behave, the shared blocks match. Every one of those checks passes on a corpus that no agent obeys. This directory covers the other half — whether a session under this corpus behaves differently from a session without it — and it is the only place in the repo where the answer comes from running an agent rather than from reading one.

It is deliberately **not** in CI. `.github/workflows/ci.yml` runs `test.sh` and `shellcheck`, both deterministic and free. An eval run costs model tokens, needs API access, and returns a distribution rather than a bit. It is an operator ceremony, run when the corpus changes in a way that is supposed to change behavior — and the run is worth its cost only when something is genuinely in doubt.

The one part that does ride CI is static: `test.sh` validates `spec.json`'s shape and builds every fixture. That keeps the eval set from rotting between runs without ever invoking a model.

## The method

Paired control, from the `skill-benchmark-harness` skill. Each eval prompt runs **twice** under a single arm variable, and the result is the delta between the arms. A treatment-arm pass rate alone is not a result: without the control there is no way to separate what the corpus contributed from what the model was doing anyway.

| Arm variable | Treatment | Control | Answers |
| --- | --- | --- | --- |
| `corpus` (default) | node bootstrapped from the revision under test | node bootstrapped from `2f779b7`, the V6.2 pre-release run in the field | did this change to the corpus change behavior? |
| `agent` | the candidate agent | the baseline agent, named in `run-config.json` | does this corpus work on that harness too? |

Vary one, never both. A delta from two moving variables is attributable to neither.

The `corpus` control is precise on purpose: `2f779b7` is the exact tree the operator was running when they reported the failures these evals encode. A regression against it is a regression against the field report.

## The eval set

`spec.json` is frozen data, not prose — hash it before the first run and after the last. Each entry carries an id, the phase whose contract it tests, the verbatim prompt, the fixture it needs, the fixed artifact set both arms must emit, and its assertions.

The set is organized by the **trust-contract phase** the operating model already names, not by the bug that prompted each eval. That ordering is deliberate: a set organized by bug report drifts toward whatever failed most recently, and the first version of this file did exactly that — four evals on the comment rule and none at all on write-back, which is the harness's central claim. `test.sh` now asserts every phase in that table carries at least one eval, so the set cannot narrow back silently.

| Phase | The claim under test | Evals |
| --- | --- | --- |
| Bootstrap | load context before working, once per session | `bootstrap-once` · `bootstrap-complete` · `entry-point-boundary` |
| Pre-work | load project context before editing, scaled to the task | `routing-catalog-first` · `routing-scales` · `routing-finds-doc` |
| Correctness | verify before claiming; comments state what code cannot | `verify-no-false-done` · `verify-baseline-failure` · `comments-feature` · `comments-docstrings` |
| Completion | write context back before finishing | `continuity-writes-back` · `continuity-supersede` · `continuity-docs-not-memory` · `memory-admission` |
| Retro | distill durable rules, and only those | `retro-source-gate` · `retro-rule-expiry` |
| Security | the origin gate, and the leak surface | `security-origin-gate` · `security-no-secrets` |
| Grooming | flags handled in the session that printed them | `groom-acts-on-flags` |
| Scope control | answer a question without editing | `scope-question-no-edit` |

Two carry a note on why they exist at all. `routing-catalog-first` tests the failure the operating model says "passes tests, passes lint, and survives review, so nothing else in the model catches it" — which makes it the eval with the least redundant coverage anywhere in the set. `security-origin-gate` tests the corpus's only security claim, which is cooperative by design; an untested cooperative control is an assumption wearing a control's clothes.

`bootstrap-once` is the one eval that must run with the **agent** as the variable. Its failure was agent-specific — reported on `gpt-5.6-*`, never observed on Claude Code — so a corpus arm on the agent that never had it measures nothing. Run it against both harnesses with the corpus held at the treatment revision, and use `cross-vendor-delegation` for the foreign arm: content-not-path handoff, an injection-delimited payload, a bounded run, and a fail-closed verdict gate.

## Fixtures

Nine, each seeding a state a real node reaches rather than a synthetic one. `evals/fixtures.sh --list` names them; `--help` describes each. Eight arrive with a clean status check, because a fixture that arrives flagged makes every session spend itself on repair and the delta then measures that. The ninth, `ts-service-flagged`, exists to be flagged — `test.sh` asserts it still crosses both thresholds its eval is supposed to clear.

## Assertions

Two classes. An **artifact assertion** names a checkable property of a named output document. A **trace assertion** names an event that should appear in the harness's record of the calls the agent made — that is what makes `bootstrap-once` measurable at all, since it produces no deliverable.

Each assertion carries a stable `id` (joins the two arms), a `concept` (groups assertions testing the same property across evals, so a rollup does not double-count), the claim text, its class, and its grading mode. Anything string- or count-checkable is graded `auto`. Everything else is `manual` — and graded blind.

The corpus supplies several of its own graders, which is what keeps the automated share high without a model in the loop. `comments.sh` settles the comment assertions by class count. `status.sh` settles node-health and flag-clearing assertions by reading its own flags. `links.sh` settles reachability after a restructure. Beyond those, a `.agent/` tree diff settles the continuity and memory-admission assertions, a project tree diff settles scope, and the harness's call trace settles ordering — whether the catalog was read *before* the build, whether the bootstrap ran once.

That leaves manual grading for what genuinely needs judgment: whether a constraint comment survived the rule that cuts valueless ones, whether a failure was honestly classified, whether a groom pass changed shape without dropping content. Those are graded blind, and there are few enough of them to grade carefully.

## Running one

```
bash evals/fixtures.sh <fixture> <destination> [--corpus-ref <ref>]
```

builds an eval's fixture node at a pinned corpus revision. Everything after that is the operator's harness: open a session in the destination, paste the eval's prompt verbatim, save the artifacts under the run layout, and grade.

```
<workspace>/
  spec.json                  # hashed, frozen for the run
  iteration-<n>/
    run-config.json          # models, versions, sampling, corpus refs, repeats, grader
    arm-map.json             # opaque run id -> arm; the grader never opens this
    eval-<id>/
      eval-snapshot.json     # prompt + assertions, copied from spec.json at run time
      <run-id>/              # opaque: no arm token in the path or the filename
        outputs/             # the artifact set named by the eval, same names both arms
        grading.json
    rollup.json
```

The condition must appear in no path, no filename, and no field of a grading record. Blinding is a requirement, not a nicety — an unblinded grader working toward an expected direction is a first-order threat to any delta it produces. It also cannot be total here: treatment-arm output carries the corpus's own vocabulary. Report that residual rather than claiming full blinding.

`bash evals/rollup.sh <iteration-dir>` joins the arms on assertion id, recomputes every number from the grading records, and prints the four-bucket split. Nothing in a report is transcribed by hand.

## Reading a result

Every assertion lands in exactly one bucket:

| Bucket | Condition | Action |
| --- | --- | --- |
| Discriminating | arms differ, treatment ahead | keep — it carries the signal |
| Non-discriminating | identical in both arms | prune or downweight next iteration |
| Regression | control passed, treatment failed | keep, and open a fix |
| Unstable | repeats disagree within an arm | report the split, no verdict |

Expect a first checklist to lose a large share to non-discriminating. That bucket is measuring base-model competence, not the corpus, and left in place it inflates every later score.

Report the delta's **concentration** — the share carried by the largest single assertion, and by the top two. A delta that is one assertion in disguise is a different finding from a broad lift, and the aggregate hides which.

Every regression gets its own named section with both arms' evidence quoted and a proposed next action. A regression named only inside a count is not reported.

## When an eval fails and the cause is unclear

Run `agent-architecture-audit` rather than editing prose. It triages layer by layer — standing instructions, memory admission, routing, tooling, harness — records each finding against exactly one layer with a resolvable evidence reference, and orders the fixes so enforcement moves into code before any prompt is rewritten. That ordering is the house rule anyway: the corpus's own Self-learning gate says fix the source, and a script that catches a shape beats a sentence asking an agent to avoid it.

## The other standing measurements

Not paired evals — recurring passes with their own procedures.

| Pass | Skill | Cadence | What it produces |
| --- | --- | --- | --- |
| Always-loaded cost | `context-budget` | after any change to the always-loaded set | per-component token prices, and removals ranked by tokens reclaimed. The `LOAD:` line is the in-node sample; this is the audit behind it |
| Per-harness disposition | `agent-harness-portability` | when a tool is added to the wiring matrix, or a cell's date goes stale | a disposition per axis per target, source-token leakage findings, and a defined repair for each failure. The matrix's `verified`/`reported`/`unknown` cells are its output |
| Corpus grooming | `skill-corpus-maintenance` | periodic, not per-change | keep/revise/retire per item, with evidence-bearing reasons and a dated record so the next run re-evaluates only what changed |
| Foreign-harness arm | `cross-vendor-delegation` | whenever a non-Claude arm runs | the handoff payload and the adjudication gate for what comes back |

Two skills on the operator's list have no job here, and saying so is cheaper than inventing one. `finetuning-method-selection` routes a training effort by the data shape in hand; nothing in this repo is trained. `tool-output-middleware` governs a layer that rewrites tool output before an agent sees it; this harness has no such layer — `status.sh` and `comments.sh` write to a session's context directly, and their output is the product.

## Constraints on what a run may claim

- **Sample size.** One run per cell yields no variance estimate. Record the repeat count and label it a chosen budget.
- **Plans are not behavior.** Name the tier graded. An eval whose artifact is a proposal measures planning; only an executed diff measures behavior. Four of the six here grade executed work.
- **Review surface.** Publish both arms' per-assertion evidence side by side, or the control and every rollup error stay hidden.
- **Held-back prompts.** Iterating against a fixed eval set tunes the corpus to that set. Keep prompts no iteration has seen and run them before declaring an improvement.
- **Stopping rule.** Fix it before the first run — a target, an iteration cap, or a cost ceiling — and label it a chosen budget.
