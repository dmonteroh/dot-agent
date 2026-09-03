# `evals/` — measuring what the corpus does to an agent

> **This directory belongs to the dot-agent repository, not to the harness.**
> Nothing here is installed into a node, copied into a project adopting
> `.agent/`, or refreshed by `node.sh update`. It is this project's own test
> bench, exactly as `scripts/test.sh` is. What a node receives is the list
> under **Directory structure** in the operating model, and `test.sh` pins
> that a freshly created node contains none of this.
>
> If you are adopting `.agent/` in a project: you want `README.md` at the
> repository root. You will never need this file.

`scripts/test.sh` checks the corpus as an artifact: the text is present, the scripts behave, the shared blocks match. Every one of those checks passes on a corpus that no agent obeys. This directory covers the other half — whether a session under this corpus behaves differently from a session without it — and it is the only place in the repo where the answer comes from running an agent rather than from reading one.

It is deliberately **not** in CI. `.github/workflows/ci.yml` runs `test.sh` and `shellcheck`, both deterministic and free. An eval run costs model tokens and returns a distribution rather than a bit. It is an operator ceremony, run when the corpus changes in a way that is supposed to change behavior — and the run is worth its cost only when something is genuinely in doubt.

**No provider API, SDK, or API key is used anywhere in this directory.** `run.sh` drives the `claude` and `codex` CLIs directly, through whatever session you already have logged in on this machine. `--list-arms` and `--probe-agent` only ever call those same CLIs — never a provider endpoint.

The one part that does ride CI is static: `test.sh` validates `spec.json`'s shape, builds fixtures, drives `grade.sh` against hand-written artifacts to pin its check language, and asserts `run.sh` refuses an unconfigured agent. That keeps the eval set and its tooling from rotting between runs without ever invoking a model.

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

## What is wired, and what is not

| Piece | State |
| --- | --- |
| `spec.json` — 20 evals, 58 assertions | complete |
| `fixtures.sh` — 9 fixtures at a pinned corpus revision | complete |
| `run.sh` — drives Claude Code and Codex directly, captures the artifact set, grades | complete |
| `grade.sh` — executes the check language, writes evidence per assertion | complete |
| `rollup.sh` — joins arms, buckets, reports the delta | complete |

Both reference agents are wired in: `run.sh` resolves the `claude` and `codex` CLIs on this machine, drives each through argument-safe, multi-turn adapters, and normalizes their tool calls into the shared trace contract. **Nothing here calls a provider API or reads an API key** — both adapters drive the operator's own logged-in CLI session, the same one you already use interactively.

Both adapters require subscription-backed login, never an API key: Claude needs a claude.ai account (`~/.claude/.credentials.json`, or `CLAUDE_CONFIG_DIR` if set, carrying an active `subscriptionType`) and Codex needs a ChatGPT account (`auth_mode` `chatgpt` in `~/.codex/auth.json`, or `CODEX_HOME` if set). A run refuses to start rather than fall back to a provider key, and `run.sh` strips every provider-credential and alternate-provider environment variable from its own process before either adapter's subprocess ever launches.

## Configuring an agent

Open `evals/agents.conf`. `claude` and `codex` need no command line — `run.sh` builds their invocation itself — only the executable to resolve, the model, and the effort:

```
CLAUDE_BIN=claude                 # a PATH name, an absolute path, or "auto"
CLAUDE_MODEL=claude-sonnet-5
CLAUDE_EFFORT=medium

CODEX_BIN=auto                    # PATH first; feature-probes the CLI and
                                  # falls back to CODEX_APP_BIN if set
CODEX_MODEL=gpt-5.6-terra
CODEX_EFFORT=medium
```

These ship uncommented with the reference model and effort, because nothing about resolving a binary or driving it through a fixed, argument-safe adapter can silently aim at the wrong target the way a hand-written command-line template could. Check `evals/run.sh --list-arms` against your own install before a real run — it resolves both binaries and prints their versions without placing a model call. Codex resolution also checks the candidate's global, `exec`, and `exec resume` help surfaces for every flag the adapter uses. That feature probe decides compatibility rather than a guessed version boundary.

For Codex, the first turn starts with `-C <fixture-root>`, so Codex loads that fixture's `AGENTS.md` as the project instruction source. Later turns use `codex exec resume` on the same thread: they retain both that thread and the project instructions established from the initial `-C` root. The adapter ignores user configuration and gives Codex a fresh, mode-`0700` temporary home containing only the copied login state; that home is outside the retained run directory and is removed after the call or an interrupt.

Trace format is fixed, not configurable: `run.sh` normalizes each adapter's own event shape into the shared trace contract itself, for both `claude` and `codex`. That is what makes **11 of the 58 assertions** — trace assertions — measurable at all: was the catalog read *before* the build, did the bootstrap run once, was the gate invoked against a real base ref.

```
evals/run.sh --list-arms                 # resolved binaries and versions, no model call
evals/run.sh --probe-agent claude        # one live call: is claude ready and logged in?
evals/run.sh --probe-agent codex         # same, for codex
```

`--probe-agent` drives the resolved CLI once with a trivial single-turn prompt and reports the binary, its version, and whether the call succeeded — including an authentication failure, surfaced from that same invocation. Like every other call this script makes, it goes through your logged-in CLI session and never touches a provider API directly.

## Running one eval, both arms

```
W=~/eval-runs/v6.2

# readiness, once, before spending anything on a real run
evals/run.sh --list-arms
evals/run.sh --probe-agent claude
evals/run.sh --probe-agent codex

# dry run — every turn, the resolved adapter, nothing driven
evals/run.sh --eval bootstrap-once --arm merged --treatment-arm merged \
  --agent claude --corpus-ref feature/v6.2 --workspace "$W" --dry-run

# a bounded live smoke run — one iteration, one eval, before committing to REPEATS
evals/run.sh --eval scope-question-no-edit --arm merged --treatment-arm merged \
  --agent claude --corpus-ref feature/v6.2 --workspace "$W" --iteration 1

# treatment: the corpus under test. --treatment-arm names it once; every
# later run against this workspace is checked against what it recorded.
evals/run.sh --eval routing-catalog-first --arm merged --treatment-arm merged \
  --agent claude --corpus-ref feature/v6.2 --workspace "$W"

# control: the corpus the field ran
evals/run.sh --eval routing-catalog-first --arm prerelease \
  --agent claude --corpus-ref 2f779b7 --workspace "$W"

evals/rollup.sh "$W/iteration-1"
```

Each invocation builds its own fixture from the corpus revision named, drives the agent through every turn of the eval's prompt in one session, captures the artifacts, and grades the auto assertions. `--iteration <n>` selects which single `iteration-<n>` directory this invocation targets (default `1`); it never selects a repeat. Within that one iteration, `run.sh` loops `REPEATS` times itself — each repeat is a cell, with its own fixture and run id, under `iteration-<n>/eval-<id>/`. `--dry-run` does everything except drive the agent, always runs exactly one repeat, and prints every turn verbatim — the way to run an eval by hand in a session you are watching.

`--treatment-arm` names the treatment arm once per workspace; it is required on the first run into a fresh `iteration-<n>` and recorded in `run-config.json`, never guessed from which arm happened to run first. Every later run into that same iteration is checked against what got recorded — treatment arm, arm variable, repeat budget, each arm's agent and corpus ref, and each participating agent's resolved binary identity, CLI version, model, and effort. Binary identity includes the resolved path, canonical path, and SHA-256 digest; the complete first line of `--version` is retained beside the parsed version. A corpus-variable comparison also holds the agent and model constant; an agent-variable comparison holds the corpus ref constant. `run.sh` refuses a drift before touching a fixture.

Nothing about the arm reaches a path or a grading record. The run id is a hash; the mapping lives in `arm-map.json` and the comparison design in `run-config.json`, neither of which the grader opens, and `rollup.sh` greps every record for arm tokens and voids the pass if it finds one.

## What a run leaves behind

```
<workspace>/iteration-<n>/
  arm-map.json               # run id -> arm. The only other place the condition lives
  run-config.json            # treatment arm, arm variable, per-arm inputs, locked
                              # comparison fields, resolved binary identity,
                              # CLI version/model/effort per agent
  eval-<id>/
    eval-snapshot.json       # prompt + assertions, frozen at run time
    <run-id>/
      fixture/               # the tree the session actually worked in
      run-meta.json          # model, effort, corpus ref, fixture base, resolved
                              # binary path/digest and version output, turn count,
                              # timings, exit status
      outputs/
        diff.patch           # project tree, fixture base -> end
        node-diff.patch      # .agent/ tree, fixture base -> end
        node-tree.txt        # every .agent/ file with content, for absence checks
        session-transcript.txt   # `## Turn N` sections containing final text;
                                 # multiline text is preserved and an empty final
                                 # response is recorded as [empty final response]
        trace.jsonl          # one {"seq","event","tool","action","text"} object per
                              # tool call, action in read|write|execute|search|other
        status-after.txt     # status.sh over the node afterwards
        gate.txt             # comments.sh over the diff
      grading.json           # one record per assertion, with evidence — absent
                              # entirely if the agent process failed or timed out
  rollup.json                # pass rate, delta, buckets, concentration, and
                              # per-arm duration stats — recomputed from the
                              # records above, never transcribed
```

`rollup.sh` cross-validates `run-config.json` against `arm-map.json` before it joins anything: `treatment_arm` must name one of the two arms found there, and `repeats_per_cell` must be a positive integer that every assertion's per-arm repeat count matches exactly. A cell with too few or too many repeats fails the rollup rather than averaging over a shortfall.

Where a run's `run-meta.json` records a duration (`duration_s`, `duration_seconds`, or `duration` — the first present), `rollup.sh` keeps the two arms' timings separate and reports each arm's mean, population standard deviation, and sample size in `rollup.json`'s `duration_s` block and in the printed table. Arms are never pooled: a cost difference that shows up in one arm and not the other is exactly what pooling would hide. Coverage is all-or-nothing: once any run in the iteration records a duration, every run in both arms must, or the rollup fails closed naming the run that is missing it — a mean built from a subset of runs would understate one arm's cost without saying so. `rollup.json` also always carries a `cost` block (`input_tokens`, `output_tokens`, `usd`), each `"unavailable"` today — token and dollar cost are not yet captured per run, and the placeholder says so in the report itself rather than omitting the field silently.

`grade.sh` reads `outputs/` and nothing else, so a grading pass is reproducible from the run directory alone, months later, against a source tree that has since moved. A run that was cancelled, timed out, exited nonzero, or dropped session continuation partway through its turns is void: `run-meta.json` records `"void": true`, its status, and its exit status, and no `outputs/` capture or `grading.json` is retained for it at all.

## Filling in the manual assertions

10 of 58 need a human. `grade.sh` writes them with `passed: null`, and `rollup.sh` refuses an iteration that still holds one — an ungraded assertion silently dropped from a rollup is a smaller checklist reported as the same one.

Grade them from `outputs/` without opening `arm-map.json`. Each needs a pass bit and a quotation: on a pass, the passage that satisfies it; on a failure, **what the agent did instead**, which is what turns a red cell into a next-revision edit. "Assertion not met" is not evidence and cannot be re-derived.

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
