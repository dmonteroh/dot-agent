# Prose contract experiments

Start with the [contract recommendations](recommendations-2026-09-27.md) and [follow-up results](followup-results-2026-09-27.md). The [650-word compact draft](continuity-core.md) preserves explicit behavior tests, catalog updates, and continuity admission. It is an experimental candidate.

The [tooling recommendations](tooling-recommendations-2026-09-27.md) identify which contract duties can move into fast Bash commands. Their [script audit](results/tooling-script-audit.json) records current timings and checkpoint reproductions.

This suite varies the installed `.agent/rules/contract.md` while keeping the node scripts, entry point, fixture, corpus revision, and model fixed. It evaluates the software-development preset only. Candidate files in this directory are experimental inputs, not installable presets.

The baseline is the contract that `node.sh` installs from the pinned corpus revision. The runner splits out `Quality bar` and fills the fixture's Project guardrails before the comparison. `--contract-file` replaces the prose above Project guardrails, preserves those guardrails, commits the replacement as the fixture base, and records the candidate's SHA-256 digest. An agent's diff therefore contains its work, not the experimental condition.

## Comparisons

| Question | Control | Candidate | Main moving factor |
| --- | --- | --- | --- |
| Does a short operating contract preserve outcomes? | current corpus contract | `short-protocol.md` | length and content together |
| How much operating detail helps? | `short-protocol.md` | `medium-operating.md` | additional behavioral detail |
| Does explanatory repetition change behavior? | `short-protocol-report.md` | `expanded-protocol.md` | length, with the same obligations |
| Does phrasing change behavior? | `short-protocol-report.md` | `short-natural.md` | imperative bullets versus natural paragraphs |
| Which guidance deserves the short budget? | `short-protocol-report.md` | `short-engineering-report.md` | continuity detail versus engineering detail |

The length and content comparisons are hypotheses, not claims that two drafts are semantically identical. Inspect the text before interpreting a difference. Keep a separate workspace for every pair and every model. A paired workspace contains one arm variable, one pinned corpus revision, one model, one prompt set, and one repeat budget.

`spec.json` has nine tasks and thirty assertions. Seven tasks reuse frozen scenarios from the main suite. Two add terse, ordinary requests. The set covers a brief question, a terse code edit, routing, verification honesty, session logging, memory supersession, source-instruction handling, and scope control. `assertion-kinds.json` separates behavior, conformance, and information checks. Use behavior rows to judge whether prose changes ordinary outcomes. Read conformance and information rows to find continuity regressions.

`heldout.json` rewords all nine prompts while keeping fixture premises and assertion IDs. Run it with `--spec evals/prose/heldout.json` in a separate workspace after a candidate passes the canonical set.

## Run a pair

Set `REPEATS` in a copy of `evals/agents.conf` before the first run. Three repeats can reveal a split within one arm. One repeat is a smoke test, not a stable estimate. Use `--list-arms` and `--probe-agent` to check the selected CLI first.

```sh
export EVALS_AGENTS_CONF=/absolute/path/to/agents-prose.conf
W=/absolute/path/outside/dot-agent/terra-short-pair
REF=<pinned-dot-agent-commit>

evals/run-arm.sh --agent codex --spec evals/prose/spec.json \
  --treatment-arm short "$W" current "$REF"
evals/run-arm.sh --agent codex --spec evals/prose/spec.json \
  --contract-file evals/prose/short-protocol.md --treatment-arm short \
  "$W" short "$REF"

evals/triage.py "$W/iteration-1"
evals/triage.py "$W/iteration-1" --apply
evals/rollup.py "$W/iteration-1"
```

Read the evidence quotations before accepting proposed manual grades. For an early automated preview, run `evals/rollup.py --auto-only "$W/iteration-1"`. A preview excludes manual assertions and must carry that label.

For the phrasing pair, give both arms `--contract-file` and point them at `short-protocol-report.md` and `short-natural.md`. Name the candidate as the treatment on both calls. For another model, copy `agents.conf`, change only `CLAUDE_MODEL` or `CODEX_MODEL` and its effort, probe the CLI, and run the same pair in a fresh workspace. Use `--agent claude` for Sonnet, Opus, or Fable. Use `--agent codex` for Terra, Sol, or Astra. Record the actual model identifier printed by `--list-arms`. Do not compare two models in one contract-variable workspace.

Check each run's `run-meta.json` for a clean isolation block. Keep the source and spec hashes with the results. Report pass rates by assertion kind, tool calls, elapsed time, and model usage when available. Name every regression and show both arms' evidence. The same model on another day is a new round because the hosted model or CLI may have changed.

## Run Sonnet explicitly

Use the same configuration and paired design with the Claude adapter:

```sh
W=/absolute/path/outside/dot-agent/sonnet-short-pair
evals/run.sh --probe-agent claude
evals/run-arm.sh --agent claude --spec evals/prose/spec.json \
  --treatment-arm short "$W" current "$REF"
evals/run-arm.sh --agent claude --spec evals/prose/spec.json \
  --contract-file evals/prose/short-protocol-report.md --treatment-arm short \
  "$W" short "$REF"
```

On macOS, a sandbox may hide an existing Keychain login. Check `claude auth status` in a normal terminal before concluding that login is missing. The adapter keeps each evaluation's session state in a disposable configuration directory.

The Codex adapter disables app connectors, plugins, and remote plugin loading for evaluation sessions. A disposable home alone did not stop account-synced plugin downloads. Both new and resumed turns receive the isolation overrides.

## Additional coverage

| Spec | Tasks | Assertions | Purpose |
| --- | ---: | ---: | --- |
| `spec.json` | 9 | 30 | Ordinary work, routing, continuity, verification, and source-origin handling |
| `continuity-spec.json` | 6 | 17 | Learning admission, scoped constraints, preference supersession, and session restart |
| `quality-spec.json` | 2 | 12 | Actual behavior and test coverage alongside harness compliance |

The continuity extension holds manual-index mode constant. Its handoff case starts a fresh session in the same CLI. It does not switch vendors or force provider-side compaction.

The quality spec was added after inspecting the canonical results. Its task prompts are familiar, so it is not a held-out evaluation. Capture independent behavior evidence after the agent finishes:

```sh
node --permission --allow-fs-read="$fixture" --allow-fs-read="$PWD/evals/prose" \
  evals/prose/quality_oracle.mjs "$fixture" retry
```

Use absolute, resolved paths for filesystem permissions. Use `refund` for the refund task. Save stdout as `outputs/quality-oracle.json` before manual grading. The retry check covers early success, third-attempt success, and exhaustion. It does not check delay magnitude or HTTP error policy.

## Export evidence

Review manual assertions before exporting:

```sh
python3 evals/prose/export_results.py "$W/iteration-1" /absolute/path/results.json
python3 -m unittest discover -s evals/prose -p 'test_*.py'
```

The export includes configuration, snapshots, every repeat's grades, artifact hashes, tool calls, and duration statistics. It rejects incomplete runs and missing grades. An explicit `--exclude-eval <id>` excludes the entire paired task and records its diagnostic statuses.

The follow-up corrected a catalog-grading weakness. A new exported helper can need a catalog entry even inside an existing module. `triage.py` now leaves that decision pending for review instead of proposing a vacuous pass.
