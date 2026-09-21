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

What the runs so far found is written up in [What the September 2026 evaluations found](v6.2-evals-september-2026.md), which stands on its own: what the tests do, the scores, what moved them, what did not work, and how much of it to believe.

## In plain terms

An eval is a small, realistic situation and a list of things a good session does in it. The bench builds a tiny project with a fresh `.agent/` node inside it, plants one trap (a doc the routing hook does not name, a memory fact due for an update, a file carrying an instruction aimed at the agent, a test that was already red), hands a real agent one prompt in that project, and records everything the session leaves behind: the diff, the `.agent/` diff, the reply, and the sequence of tool calls. Then it grades that record against the list.

The list is the point. Each item is a checkable claim about the session's actions, artifacts, or reply. Scripts settle most of them. A blind reviewer grades the thirty-three that need judgement.

A single score means nothing on its own, because most of what any session does well it would have done with no corpus at all. So every eval runs at least twice with one thing varied: the corpus revision, or the agent. The result is the difference between the arms, assertion by assertion, and the report says which assertions moved, which regressed, and which stayed the same in both arms. The last bucket is usually the largest, and that is expected.

Two prompt sets exist. `spec.json` is the canonical set: thirty-six evals, one hundred eleven assertions, frozen. The first twenty (sixty-three assertions) cover manual-mode routing, write-back, and the comment gate; the other sixteen (forty-eight assertions) add generated-index routing and its fault states, the eight learning-admission cases, the migration backlog, the exceptional-comment case, a twenty-turn stress session, and a handoff. `heldout.json` is the same thirty-six situations with every prompt reworded, written after the corpus changes it judges were frozen. A corpus that passes the first and fails the second was tuned to the wording, not to the rule.

## Keeping it honest

Every one of these exists because a run without it produced a wrong conclusion at least once. The report that found each one is in the summary above.

| Bias | What the bench does about it |
| --- | --- |
| **The corpus was written from the evals' failing transcripts, so it may have learned the test** | A held-out set with reworded prompts (`heldout.json`, selected with `EVALS_SPEC`). A contamination audit (`contamination.py`) that measures shared phrases and, with `--judge`, asks a model whether any corpus passage describes the same situation as an eval prompt whatever the vocabulary. One variant scored best on the canonical set and turned out to retell 11 of the 19 scenarios as worked examples; it was the only arm to score below the base on held-out. |
| **A score can lean on rows that only the mechanism can pass** | Every assertion is tagged in `assertion-kinds.json` as *behavior* (an outcome any instruction set could produce), *conformance* (a format, a script, a flag, a load order), or *information* (the answer exists only inside `.agent/`). Reports show all three strata, and a harness-free arm is judged on behavior rows only. |
| **One run per cell hides the noise** | The same corpus moved by ±2 assertions across four identical runs. Repeats are a recorded budget (`REPEATS` in `agents.conf`), and `pooled.py` judges a candidate against every prior run of the baseline, bucketing each assertion by pass rate rather than by one bit: a "unique failure" needs the candidate at or below half and the baseline at or above three quarters. |
| **The grader could know the arm** | Run ids are hashes; the arm mapping lives in `arm-map.json`, which no grader opens, and `rollup.py` voids a pass if an arm name reaches any grading record as the condition — a path or id component, a key or whole field value, or the name written beside the experiment's own vocabulary. It is not a bare substring match: arms are named for what they are, `node` is also the corpus's word for itself, and a guard that forces the operator to rename the thing being measured taxes the blind rather than protecting it. `triage.py` proposes manual verdicts from the record alone and never reads the mapping. Blindness is nominal for a harness-versus-none comparison — a transcript that runs `status.sh` reveals its arm — and is stated as such. |
| **Manual grading drifts between runs** | `triage.py` applies one fixed rule per manual assertion and quotes the evidence; it was calibrated against the previous human grades and agreed everywhere except one shape the human had scored both ways. The rule now applied is written down. |
| **The wrong cost is measured** | Cost was first compared in always-loaded words. USD per tool call turned out to be flat across every corpus size, and calls varied fourfold, so reports carry tool calls, USD, and seconds per eval, and the corpus change that shipped cut calls. |
| **An assertion measures the prompt, not the rule** | Every arm passed the vendor-comment row on the canonical wording and failed it on the paraphrase. That row was rewritten to accept a named constant, and any row that behaves that way is reported as a wording probe, not a result. |
| **The fixture measures itself** | A fixture guardrail named a linter the fixture did not have, and every session in every arm spent steps discovering it. Premises a prompt makes about the fixture are checked at build time; the fixture no longer names tools it lacks. |
| **The result depends on one model** | A cheap cross-model check on a second model (Haiku 4.5, the seven-eval subset) is run before a shape is adopted; direction has to hold. |
| **A flag is trusted instead of verified** | A feasibility pass found Codex loading a personal writing-style skill despite `--ignore-user-config`. `run.sh` now writes an isolation block into every cell's `run-meta.json` — the disposable config directory, the stripped provider variables, and any name from a fixed list that turned up in the trace anyway — so a run whose block is non-empty is reported as configuration-specific evidence rather than trusted as isolated. |

What the bench does not do: it does not vary the scenarios (a paraphrase is not a new situation; that needs a new fixture), it does not run on a real repository (the base fixture is ten lines of TypeScript; the learning fixture adds a dozen small files), and its manual grades are made by the same lineage that writes the corpus. Those limits are stated in every report.

## The method

Paired control. Each eval prompt runs under a single arm variable, and the result is the delta between the arms. A treatment-arm pass rate alone is not a result: without the control there is no way to separate what the corpus contributed from what the model was doing anyway.

| Arm variable | Treatment | Control | Answers |
| --- | --- | --- | --- |
| `corpus` (default) | node bootstrapped from the revision under test | node bootstrapped from a pinned baseline revision | did this change to the corpus change behavior? |
| `agent` | the candidate agent | the baseline agent, named in `run-config.json` | does this corpus work on that harness too? |
| `node-mode` | the node built `--indexes generated` | the same node, same corpus ref, same agent, built `--indexes manual` | does generated-file routing behave differently from the current file-based routing? |

Vary one, never both. A delta from two moving variables is attributable to neither. `node-mode` is the one exception that locks three things at once — agent, model, *and* corpus ref — rather than two, because neither pinned control revision (`2f779b7`, `5001189`) ships `index.sh` or `learn.sh`: a corpus arm against either would measure the absence of a file, not the behavior of a mechanism. Four evals whose fault state has no manual-mode counterpart at all (a corrupted cache, a missing indexer, a branch-switched cache, a migration backlog) run generated-only and are reported as feasibility evidence, never a delta.

Two shapes of control are in use. `spec.json` names the paired control, `2f779b7`, the tree the operator was running in the field when the failures these evals encode were reported; `run.sh` and `rollup.py` implement that two-arm shape inside one workspace. Once a baseline corpus has run several times, the better control is all of those runs pooled: `pooled.py` takes any number of baseline workspaces and any number of candidate workspaces and joins them on assertion id. Round two ran each candidate in a single-arm workspace against four pooled baseline runs, then reran the adopted corpus (commit `5001189`) at three repeats on both prompt sets so the next round's control is contemporaneous. A control is reproduced, not shared: `run-arm.sh --jobs 6 <workspace> base 5001189`, once per prompt set, and `pooled.py --baseline <workspace>` from there.

## The eval set

`spec.json` is frozen data, not prose — hash it before the first run and after the last. Each entry carries an id, the phase whose contract it tests, the verbatim prompt, the fixture it needs, the fixed artifact set both arms must emit, its premises about the fixture (enforced at build time), and its assertions. `heldout.json` carries the same entries with `prompt` rewritten and the original kept as `prompt_canonical`.

The set is organized by the **trust-contract phase** the operating model already names, not by the bug that prompted each eval. That ordering is deliberate: a set organized by bug report drifts toward whatever failed most recently, and the first version of this file did exactly that — four evals on the comment rule and none at all on write-back, which is the harness's central claim. `test.sh` now asserts every phase in that table carries at least one eval, so the set cannot narrow back silently.

| Phase | The claim under test | Evals |
| --- | --- | --- |
| Bootstrap | load context before working, once per session | `bootstrap-once` · `bootstrap-complete` · `entry-point-boundary` · `handoff-reload` |
| Pre-work | load project context before editing, scaled to the task | `routing-catalog-first` · `routing-scales` · `routing-finds-doc` · `index-routing-generated` · `index-cache-fault-fallback` · `index-missing-indexer` · `index-branch-switch` |
| Correctness | verify before claiming; comments state what code cannot | `verify-no-false-done` · `verify-baseline-failure` · `comments-feature` · `comments-docstrings` · `comments-rare-after-correction` |
| Completion | write context back before finishing | `continuity-writes-back` · `continuity-supersede` · `continuity-docs-not-memory` · `memory-admission` · `learning-admits-discovery` · `learning-refuses-order-rule` · `learning-scopes-constraint` · `learning-writes-nothing` · `migration-backlog-reconcile` · `stress-twenty-turn` |
| Retro | distill durable rules, and only those | `retro-source-gate` · `retro-rule-expiry` · `learning-reuses-synonym` · `learning-admits-after-correction` · `learning-supersedes-contradiction` · `learning-updates-preference` |
| Security | the origin gate, and the leak surface | `security-origin-gate` · `security-no-secrets` |
| Grooming | flags handled in the session that printed them | `groom-acts-on-flags` |
| Scope control | answer a question without editing | `scope-question-no-edit` |

Two carry a note on why they exist at all. `routing-catalog-first` tests the failure the operating model says "passes tests, passes lint, and survives review, so nothing else in the model catches it" — which makes it the eval with the least redundant coverage anywhere in the set. `security-origin-gate` tests the corpus's only security claim, which is cooperative by design; an untested cooperative control is an assumption wearing a control's clothes.

`bootstrap-once` is the one eval that must run with the **agent** as the variable. Its failure was agent-specific — reported on `gpt-5.6-*`, never observed on Claude Code — so a corpus arm on the agent that never had it measures nothing. Run it against both harnesses with the corpus held at the treatment revision. For the foreign arm, hand over content rather than paths, delimit the payload against injection, bound the run, and fail closed when no verdict comes back.

`handoff-reload` carries a turn separator, `|HANDOFF|`, instead of the ordinary `||`: the turn after it starts under a fresh session id over the same unchanged working tree, a genuine session discontinuity rather than a resumed one. This models a handoff, never a provider-side context compaction — neither CLI exposes a way to force the latter on demand — and the assertions measure whether the required context gets reloaded before the session edits anything further.

The eight `learning-*` evals correspond one-to-one with the eight admission cases (successful discovery, rediscovered synonym, a current-order correction, a feature-specific constraint, a durable discovery after a correction, no new learning, a contradiction to supersede, and a durable preference update); each is a single-prompt eval so one case's outcome can never leak into another's. Five of the eight use two turns in one session — never a `|HANDOFF|` restart — so the "existing record" a case assumes is real and written by the same session, on whichever surface that arm actually offers, rather than pre-seeded into the fixture.

## Fixtures

Fourteen, each seeding a state a real node reaches rather than a synthetic one. `evals/fixtures.sh --list` names them; `--help` describes each. Most arrive with a clean status check, because a fixture that arrives flagged makes every session spend itself on repair and the delta then measures that. `ts-service-flagged` exists to be flagged — `test.sh` asserts it still crosses both thresholds its eval is supposed to clear, and its oversized fact carries real names, values, a command, and a path, so fact loss is checkable token by token. `ts-service-partial-migration` is flagged too, deliberately: its whole point is an open migration backlog. Four more exist only on a generated node, each seeding a specific fault `--indexes generated` can reach: `ts-service-index-fault` (a truncated, non-verifying published entry), `ts-service-no-indexer` (the indexer itself removed after the cache warmed), `ts-service-branch-switched` (a cache built on a second branch, checkout left on this one — index.sh's own `.gitignore` of `.agent/indexes/` means a checkout never touches it), and `ts-service-partial-migration` (a migration-inventory.md carrying both an open `semantic-review-pending` rule and an open `hook-missing` doc). `ts-service-learning` carries the application code the eight learning-admission prompts talk about — a shared retry helper, webhook send and receive paths, an exchange-rate cache with no expiry, three paginated admin endpoints sharing one default, a generated webhook schema with its generator and YAML sources, a hand-run diagnostic script, and a rename checklist — and documents none of it in `.agent/`. The first calibration run (2026-09-20) built those eight evals on the bare `ts-service` tree; every session correctly refused to invent the missing code, and the positive half of seven cases graded 0/N for that reason alone. Each prompt's feature now has a build-time premise, so a prompt about code the fixture lacks refuses to run instead of grading a refusal.

`--indexes <manual|generated>` defaults to `manual`. The builder passes the flag when the pinned corpus advertises it and omits it for an older manual-only corpus. Generated fixtures require a corpus that supports the flag. After seeding, they run `.agent/scripts/index.sh ensure` and arrive with a warm cache. `run.sh` maps `--index-mode manual|generated` to this flag and records the value in `run-config.json`.

`run.sh` also passes `--eval <id>`, so fixture construction checks only that scenario's premises. A direct builder call without `--eval` retains the maintenance check over every scenario sharing the fixture.

Two modifier flags build harness-free control arms on the same fixtures: `--no-harness` moves the node aside and ships no entry point; `--generic-claude` replaces it with an ordinary hand-written instructions file. Both are restricted to the evals whose assertions never touch the `.agent/` tree, and two of those seven measure information availability rather than behavior, because their answer only exists inside `.agent/docs/`.

## Assertions

Two classes. An **artifact assertion** names a checkable property of a named output document. A **trace assertion** names an event that should appear in the harness's record of the calls the agent made — that is what makes `bootstrap-once` measurable at all, since it produces no deliverable. Sixteen of the one hundred eleven are trace assertions.

Each assertion carries a stable `id` (joins the arms), a `concept` (groups assertions testing the same property across evals, so a rollup does not double-count), the claim text, its class, and its grading mode. Anything string- or count-checkable is graded `auto`. Everything else is `manual` — and graded blind. A third file, `assertion-kinds.json`, tags each id as behavior, conformance, or information; it is kept beside the spec rather than inside it so the frozen spec stays frozen.

The corpus supplies several of its own graders, which is what keeps the automated share high without a model in the loop. `comments.sh` settles the comment assertions by class count. `status.sh` settles node-health and flag-clearing assertions by reading its own flags. Beyond those, a `.agent/` tree diff settles the continuity and memory-admission assertions, a project tree diff settles scope, and the harness's call trace settles ordering — whether the catalog was read *before* the build, whether the bootstrap ran once. The grading copies of `status.sh` and `comments.sh` are snapshotted from this repository, never taken from the node under test, so a corpus revision cannot grade itself.

That leaves manual grading for what genuinely needs judgement: whether a constraint survived the rule that cuts valueless comments, whether a failure was honestly classified, whether a groom pass changed shape without dropping content, whether a durable write is correctly scoped, deduplicated, or superseded. `triage.py` proposes a verdict and the quotation for each, and the grader reads the quotation. Thirty-three of the one hundred eleven are manual.

## What is wired

| Piece | State |
| --- | --- |
| `spec.json` — 36 evals, 111 assertions; `heldout.json` — the same, reworded | complete |
| `fixtures.sh` — 13 fixtures at a pinned corpus revision, plus the two harness-free modifiers | complete |
| `fixture_seed.py` — the contract and routing-table edits a fixture needs, and the premise check | complete |
| `run.sh` — drives Claude Code and Codex directly, captures the artifact set, grades; `EVALS_SPEC` selects the prompt set | complete |
| `grade.py` — executes the check language, writes evidence per assertion | complete |
| `rollup.py` — joins one workspace's two arms, buckets, reports the delta | complete |
| `pooled.py` — joins any baseline runs against any candidate runs; pass rates per kind; calls, USD, seconds per eval | complete |
| `triage.py` — evidence-backed proposals for the manual assertions, never opening the arm map | complete |
| `contamination.py` — lexical and scenario-shape leakage from the eval set into a corpus revision | complete |
| `assertion-kinds.json` — behavior / conformance / information per assertion | complete |
| `run-arm.sh` — every eval of one arm into one workspace, `--jobs N` at a time | complete |

Both reference agents are wired in: `run.sh` resolves the `claude` and `codex` CLIs on this machine, drives each through argument-safe, multi-turn adapters, and normalizes their tool calls into the shared trace contract. **Nothing here calls a provider API or reads an API key** — both adapters, and the contamination judge, drive the operator's own logged-in CLI session, the same one you already use interactively.

Both adapters require subscription-backed login, never an API key: Claude needs a claude.ai account (`~/.claude/.credentials.json`, or `CLAUDE_CONFIG_DIR` if set, carrying an active `subscriptionType`) and Codex needs a ChatGPT account (`auth_mode` `chatgpt` in `~/.codex/auth.json`, or `CODEX_HOME` if set). A run refuses to start rather than fall back to a provider key, and `run.sh` strips every provider-credential and alternate-provider environment variable from its own process before either adapter's subprocess ever launches.

Both drive the session the same way: one process per turn, the session carried by an id — `--session-id` then `--resume` for Claude, `thread.started` then `exec resume` for Codex — so each process closes exactly the turn it was given. Neither writes into the operator's own session history: each run gets a disposable config dir in temporary storage, seeded with a copy of the validated login and nothing else, removed on every normal or signalled exit. Claude's earlier shape queued every turn onto one process's stdin, and CLI 2.1.245 answers a queue as one prompt with one result, so every run of the set's only multi-turn eval voided and its Claude side had never been measured.

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

Trace format is fixed, not configurable: `run.sh` normalizes each adapter's own event shape into the shared trace contract itself, for both `claude` and `codex`.

```
evals/run.sh --list-arms                 # resolved binaries and versions, no model call
evals/run.sh --probe-agent claude        # one live call: is claude ready and logged in?
evals/run.sh --probe-agent codex         # same, for codex
```

`--probe-agent` drives the resolved CLI once with a trivial single-turn prompt and reports the binary, its version, and whether the call succeeded — including an authentication failure, surfaced from that same invocation.

## Running a round

```
W=/a/directory/outside/the/repository/round-x

# readiness, once, before spending anything on a real run
evals/run.sh --list-arms
evals/run.sh --probe-agent claude

# dry run — every turn, the resolved adapter, nothing driven
evals/run.sh --eval bootstrap-once --arm cand --treatment-arm cand \
  --agent claude --corpus-ref <sha> --workspace "$W" --dry-run

# one eval, one arm, live
evals/run.sh --eval routing-catalog-first --arm cand --treatment-arm cand \
  --agent claude --corpus-ref <sha> --workspace "$W"
```

Each invocation builds its own fixture from the corpus revision named, drives the agent through every turn of the eval's prompt in one session, captures the artifacts, and grades the auto assertions. `--iteration <n>` selects which single `iteration-<n>` directory this invocation targets (default `1`); it never selects a repeat. Within that one iteration, `run.sh` loops `REPEATS` times itself — each repeat is a cell, with its own fixture and run id, under `iteration-<n>/eval-<id>/`. `--dry-run` does everything except drive the agent, always runs exactly one repeat, and prints every turn verbatim.

`--treatment-arm` names the treatment arm once per workspace; it is required on the first run into a fresh `iteration-<n>` and recorded in `run-config.json`, never guessed from which arm happened to run first. Every later run into that same iteration is checked against what got recorded — treatment arm, arm variable, repeat budget, each arm's agent and corpus ref, and each participating agent's resolved binary identity, CLI version, model, and effort. `run.sh` refuses a drift before touching a fixture.

Three choices to make before the first live call, each recorded as a chosen budget:

- **Repeats.** `REPEATS` in `agents.conf`; to change it for one round, copy the conf, edit the line, and export `EVALS_AGENTS_CONF` pointing at the copy for every invocation. One repeat cannot show a split; two can show a regression candidate against a pooled control; three is the smallest count that can show a split on its own.
- **Prompt set.** Default `spec.json`; `EVALS_SPEC=evals/heldout.json` selects the held-out set. Run each set into its own workspace.
- **Control.** A two-arm workspace (name a control arm and its `--corpus-ref`, then `rollup.py`), or a single-arm workspace judged with `pooled.py` against the pooled baseline. Prefer pooled once the baseline has run more than once; it is cheaper and better powered.

`run-arm.sh [--jobs N] [--spec <spec>] [--evals <ids>] <workspace> <arm> <corpus-ref>` runs one arm's evals, slowest first. Per-eval logs land under `<workspace>/logs/<arm>/`. `N` must be positive because `xargs` interprets `-P 0` as unbounded concurrency.

Runs may share a workspace because `run.sh` locks its metadata writes. Pass the same `--treatment-arm` value to every arm. The first run records the design, and a later disagreement is refused.

Every child status is recorded in `run.log`. Any failed or void child makes the batch write `ARM FAILED` and exit nonzero. `ARM DONE` means every child invocation exited zero.

Concurrent sessions contend for the machine and account, which inflates duration without changing tool calls or USD. Re-run any void cell when complete counts matter. Never switch branches while a run is active because `run.sh` reads the checkout. Run `evals/contamination.py --judge <ref>` before believing a candidate's delta.

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
                              # timings, token usage and USD, exit status, and an
                              # isolation block: the disposable config directory,
                              # the provider variables stripped, and every skill or
                              # hook name from a fixed list that turned up in the
                              # trace anyway
      outputs/
        diff.patch           # project tree, fixture base -> end
        node-diff.patch      # .agent/ tree, fixture base -> end
        node-tree.txt        # every .agent/ file with content, for absence checks
        indexes-before.txt   # one "path digest" line per .agent/indexes/ file,
                              # taken right after the fixture build
        indexes-after.txt    # the same manifest, taken at capture time — the only
                              # way to see a hand-edit of a generated page, since
                              # node-diff.patch is staged and .gitignore hides that
                              # whole tree from it on a generated node
        session-transcript.txt   # `## Turn N` sections containing final text
        trace.jsonl          # one {"seq","event","tool","action","text"} object per
                              # tool call, action in read|write|execute|search|other
        status-after.txt     # status.sh over the node afterwards
        gate.txt             # comments.sh over the diff
      grading.json           # one record per assertion, with evidence — absent
                              # entirely if the agent process failed or timed out
  rollup.json                # two-arm rollup, recomputed from the records above
```

`grade.py` reads `outputs/` and nothing else, so a grading pass is reproducible from the run directory alone, months later, against a source tree that has since moved. A run that was cancelled, timed out, exited nonzero, or dropped session continuation partway through its turns is void: `run-meta.json` records `"void": true`, its status, and its exit status; its raw stream is kept for diagnosis and no `grading.json` is retained.

Note one thing the transcript cannot show: only each turn's final text is captured. A session that answers mid-turn and closes with a wrap-up line has answered the user and not the transcript; `triage.py` reads the raw stream for those.

## Filling in the manual assertions

Thirty-three of one hundred eleven need a human. `grade.py` writes them with `passed: null`, and `rollup.py` refuses an iteration that still holds one — an ungraded assertion silently dropped from a rollup is a smaller checklist reported as the same one.

Run `evals/triage.py <iteration-dir>`: it prints, per ungraded record, a proposed verdict and the quotation that produced it, applying one fixed rule per assertion. Read the quotations. `--apply` writes the PASS and FAIL proposals with their evidence; UNSURE ones, and any proposal you disagree with, are filled by hand with a pass bit and a quotation: on a pass, the passage that satisfies it; on a failure, **what the agent did instead**, which is what turns a red cell into a next-revision edit. Never open `arm-map.json` while grading.

## Reading a result

`rollup.py` (two arms, one workspace) lands every assertion in one bucket:

| Bucket | Condition | Action |
| --- | --- | --- |
| Discriminating | arms differ, treatment ahead | keep — it carries the signal |
| Non-discriminating | identical in both arms | prune or downweight next iteration |
| Regression | control passed, treatment failed | keep, and open a fix |
| Unstable | repeats disagree within an arm | report the split, no verdict |

`pooled.py` (any baseline runs against any candidate runs) buckets by pass rate instead: `unique-fail` (candidate ≤ 0.5, baseline ≥ 0.75), `unique-win` (the reverse), `both-fail`, `noise` (the two differ inside the flake band), `stable-pass`. It reports the overall rate and the behavior, conformance, and information strata, and per eval the mean tool calls (with the baseline's spread), USD, and seconds. Read the strata before the headline: a lift carried by conformance and information rows is adoption of the mechanism, not a change in behavior.

Expect a first checklist to lose a large share to non-discriminating. That bucket is measuring base-model competence, not the corpus, and left in place it inflates every later score. Report the delta's **concentration** — the share carried by the largest single assertion — and give every regression its own named section with both arms' evidence quoted. A regression named only inside a count is not reported.

## When an eval fails and the cause is unclear

Triage layer by layer rather than editing prose: standing instructions, memory admission, routing, tooling, harness. Record each finding against exactly one layer with a resolvable evidence reference, and order the fixes so enforcement moves into code before any prompt is rewritten. That ordering is the house rule, and the September runs bear it out: every fix that held was a script refusing a shape, and every fix that did not was a sentence.

## The other standing measurements

Not paired evals — recurring passes with their own procedures.

| Pass | Cadence | What it produces |
| --- | --- | --- |
| Always-loaded cost | after any change to the always-loaded set | per-component token prices, and removals ranked by tokens reclaimed. The `LOAD:` line is the in-node sample; this is the audit behind it. Read it with `pooled.py`'s call counts: calls, not words, moved cost in every run so far |
| Per-harness disposition | when a tool is added to the wiring matrix, or a cell's date goes stale | a disposition per axis per target, source-token leakage findings, and a defined repair for each failure |
| Corpus grooming | periodic, not per-change | keep/revise/retire per item, with evidence-bearing reasons and a dated record |
| Foreign-harness arm | whenever a non-Claude arm runs | the handoff payload and the adjudication gate for what comes back |
| Contamination audit (`contamination.py --judge`) | before any variant's delta is believed | shared phrases, and passages that describe an eval's situation in any vocabulary |

## Constraints on what a run may claim

- **Sample size.** One run per cell yields no variance estimate; four identical runs of one corpus moved by ±2 assertions. Record the repeat count and label it a chosen budget.
- **Plans are not behavior.** Name the tier graded. An eval whose artifact is a proposal measures planning; only an executed diff measures behavior.
- **Review surface.** Publish both arms' per-assertion evidence side by side, or the control and every rollup error stay hidden.
- **Held-out prompts.** Iterating against a fixed eval set tunes the corpus to that set. `heldout.json` is the held-out set; a paraphrase is still not a new scenario, and a new scenario needs a new fixture.
- **Contamination.** A corpus revision that retells an eval's situation is graded on the held-out set only, and the judge's finding is reported with the delta.
- **Wording-sensitive rows.** An assertion that passes in every arm on one wording and fails in every arm on another measures the prompt; report it as such and rewrite it.
- **Stopping rule.** Fix it before the first run — a target, an iteration cap, or a cost ceiling — and label it a chosen budget.
