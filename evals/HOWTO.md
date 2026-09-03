# Evaluating a software-development installation

Every fixture in this set is built with `--preset software-development` (`fixtures.sh:144`). Running the eval suite described here is the software-development check — there is no separate mode to select. This walks through running it once, end to end, to answer one question: does the corpus at the revision you are about to ship behave the way the field release did, or better?

This is not a tool for auditing an already-adopted project's `.agent/` install. It rebuilds its own fixtures from a pinned corpus revision and never touches your project tree. If you adopted `.agent/` somewhere and want to know whether that install is current, that is `node.sh update`'s question, not this one — see the repository root `README.md`.

## What you need

- `python3` on PATH.
- `claude` and/or `codex`, logged in with a subscription — Claude through a `claude.ai` account, Codex through a ChatGPT account. Neither adapter accepts an API key: `run.sh` strips provider-credential environment variables from its own process before either subprocess launches.
- `git`, with the revision you want to validate reachable by name — a branch, a tag, or a commit both `--corpus-ref` values below can resolve.
- A repeat-count decision and a time budget, made before the first run. The full set is 20 evals. One eval, one arm, one repeat is one full agent session. `README.md`'s "Constraints on what a run may claim" covers the tradeoff — decide before you see a result, not after.

## 1. Configure an arm

Open `evals/agents.conf`. Confirm `CLAUDE_BIN`/`CLAUDE_MODEL`/`CLAUDE_EFFORT` (or the `CODEX_*` equivalents) match what you actually run, then check them against the real binary — flags and defaults move between CLI versions:

```
evals/run.sh --list-arms                 # resolves both binaries, prints versions, no model call
evals/run.sh --probe-agent claude        # one live call: is claude ready and logged in?
evals/run.sh --probe-agent codex         # same, for codex
```

Both must succeed before you spend anything on a real run. A rejected probe names the reason — usually a missing or non-subscription login.

## 2. Smoke-test one eval

```
W=~/eval-runs/software-development-$(date +%Y%m%d)
REF=<the branch, tag, or commit you are validating>

evals/run.sh --eval scope-question-no-edit --arm merged --treatment-arm merged \
  --agent claude --corpus-ref "$REF" --workspace "$W" --dry-run
```

`--dry-run` builds the fixture and prints every turn without driving the agent. Read it. A wrong prompt or fixture is cheaper to catch here than after a live run.

## 3. Set the repeat count, then run every eval, both arms

`REPEATS` in `agents.conf` sets how many repeat cells `run.sh` builds per eval per arm. One repeat shows whether an assertion passed, never whether that result is stable — at `REPEATS=1` every assertion buckets as stable whether it is or not. Three is the smallest count that can show a split.

Loop every eval id in `spec.json` against both arms, into one workspace:

```
for id in $(python3 -c "import json; [print(e['id']) for e in json.load(open('evals/spec.json'))['evals']]"); do
  evals/run.sh --eval "$id" --arm merged --treatment-arm merged \
    --agent claude --corpus-ref "$REF" --workspace "$W"
  evals/run.sh --eval "$id" --arm prerelease \
    --agent claude --corpus-ref 2f779b7 --workspace "$W"
done
```

`--treatment-arm merged` only has to be named once per workspace: the first call records it in `run-config.json`, and every later call is checked against what got recorded. `2f779b7` is the fixed control — the exact tree the operator was running in the field when the failures this eval set encodes were reported. Do not point the control at a different revision: a moving control answers a different question than "did this revision regress the field baseline."

`bootstrap-once` needs the agent, not the corpus, as its variable — its reported failure was never seen on Claude Code, so a corpus-only comparison on Claude Code measures nothing for it. Run it a second time with `--agent codex` at the same treatment `$REF`. See `README.md`'s "The eval set" for why.

## 4. Roll it up

```
evals/rollup.sh "$W/iteration-1"
```

This refuses to run while any manual assertion under that iteration is still ungraded. `grade.sh` writes those `passed: null`. For each one, open `$W/iteration-1/eval-<id>/<run-id>/outputs/`, read the artifacts, and fill in `passed` and a quoted `evidence` string by hand — blind to which run is which arm. `arm-map.json` holds that mapping, and `rollup.sh` voids the pass if a grading record leaks it.

## 5. Read the result

Every assertion lands in one bucket. Each bucket names a different fact about the two arms' pass bits:

- Discriminating (arms differ, treatment ahead): the corpus produced the behavior it claims to on this assertion.
- Non-discriminating (identical in both arms): the model does this regardless of the corpus. Not a failure — expected for some share of a first checklist.
- Regression (control passed, treatment failed): this revision failed an assertion the field baseline passed. Open a fix before shipping it.
- Unstable (repeats disagree within an arm): no verdict at this repeat count. Raise `REPEATS` and re-run before concluding anything about that assertion.

Zero regressions is the bar, not a rising aggregate pass rate. Check `rollup.json`'s `concentration_pct_of_delta` (`top_assertion`, `top_two_assertions`) so one loud assertion is not standing in for the whole set. Check `duration_s` too, if one arm visibly took a different number of turns to get there.

## When something fails and the cause isn't obvious

Run `agent-architecture-audit` rather than editing prose by hand. It triages layer by layer — standing instructions, memory admission, routing, tooling, harness — and orders fixes so enforcement moves into code before any prompt is reworded.

## What this does not tell you

One pass, one revision, against one pinned control. It does not tell you the corpus works on a harness this set has no adapter for, on prompts the eval set has not encoded, or that this result holds at a different repeat count. `README.md`'s "Constraints on what a run may claim" covers the full list — read it before reporting a result to anyone else.
