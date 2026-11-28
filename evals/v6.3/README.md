# v6.3 smoke comparison

This set compares the complete v6.3 corpus with v6.2 at `390d30f213925392a61c736725316824704d117d`. It contains eight tasks and 30 assertions. Both arms use the same prompts and graders. Prose and tooling change together, so results cannot isolate their individual effects.

The tasks cover catalog reuse, behavior tests, continuity writes, supersession, source-origin handling, read-only scope, verification honesty, and memory admission. The preference task has two turns.

## Run

Use a committed candidate revision in a disposable checkout. Keep the source revision fixed throughout the comparison. Configure model IDs, effort, repeats, and timeout through `EVALS_AGENTS_CONF`. The smoke plan uses Sonnet 5 and Terra at medium effort, one repeat, and a 420-second session timeout.

Use the pinned smoke configuration, then probe each adapter:

```sh
export EVALS_AGENTS_CONF="$PWD/evals/v6.3/agents.conf"
bash evals/run.sh --probe-agent claude
bash evals/run.sh --probe-agent codex
```

Run both arms for each model with separate workspaces:

```sh
candidate=<frozen-candidate-commit>
control=390d30f213925392a61c736725316824704d117d
workspace=/absolute/path/to/sonnet-smoke
bash evals/run-arm.sh --agent claude --spec evals/v6.3/spec.json \
  --treatment-arm v63 "$workspace" v62 "$control"
bash evals/run-arm.sh --agent claude --spec evals/v6.3/spec.json \
  --treatment-arm v63 "$workspace" v63 "$candidate"
```

Repeat with `--agent codex` and another workspace for Terra. A later model comparison changes the configuration, leaving the task set and grading rules fixed.

## Grade

Inspect each run by opaque ID before opening the arm map. Grade every manual assertion against the produced artifacts. Review behavior tests and execute the independent oracle in `evals/prose/quality_oracle.mjs` for both product-quality tasks. Inspect the command trace and configured driver when verification runs through a receipt. A zero-test exit does not establish coverage.

Keep infrastructure failures visible. Do not turn an absent artifact or unfinished run into a passing grade. Use `evals/prose/export_results.py` after closing manual grades. It refuses invalid runs and incomplete grading unless the entire affected task is explicitly excluded.

One repeat provides no stability estimate. These familiar synthetic tasks support a local trial decision, not a general model ranking or release-quality claim.

[The results report](results-2026-09-27.md) includes the completed comparison and its remaining gaps. [The follow-up spec](followup-spec.json) adds continuity assertions identified during the artifact audit. It has not been run.
