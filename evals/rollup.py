#!/usr/bin/env python3
"""evals/rollup.py — joins an iteration's two arms on assertion id, recomputes
every number from the grading records, and prints the four-bucket split.

Nothing here is transcribed. A rollup written by hand is where the
arithmetic error enters, and it then propagates into everything derived
from it, so the report is generated or it is not trusted.

This is operator ceremony, not a node script: it runs beside a model API.

Full documentation: evals/README.md.

Usage: rollup.py <iteration-dir>     # writes rollup.json, prints the table
"""

import collections
import json
import math
import os
import sys

USAGE = """Usage: rollup.py <iteration-dir>

Reads <iteration-dir>/arm-map.json, run-config.json, and every
eval-*/<run-id>/grading.json under it, joins the arms on assertion id, and
writes rollup.json beside them.

Exits 2 when the records cannot support a rollup: missing experiment
configuration, a grading record whose id set differs from its eval snapshot,
a cell with incomplete repeats, or an arm token found inside a grading
record. Each of those makes the delta wrong rather than absent, so none of
them is warned about and carried past.

Duration reporting (duration_s in rollup.json) is all-or-nothing: if any
run's run-meta.json carries a duration_s/duration_seconds/duration field,
every run in both arms for that iteration must carry one too, or the
rollup exits 2 naming the run that is missing it. If no run anywhere
carries the field, duration_s is omitted from rollup.json entirely.
"""


def die(msg):
    sys.stderr.write("rollup.py: %s\n" % msg)
    sys.exit(2)


def load(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError) as exc:
        die("cannot read %s: %s" % (path, exc))


def read_text(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except (OSError, ValueError) as exc:
        die("cannot read %s: %s" % (path, exc))


def majority(bits):
    return sum(bits) * 2 > len(bits)


def mean_and_stddev(values):
    m = sum(values) / len(values)
    variance = sum((value - m) ** 2 for value in values) / len(values)
    return m, variance ** 0.5


def rollup(iteration):
    """Join both arms of one iteration and return the report and its inputs."""
    arm_map = load(os.path.join(iteration, "arm-map.json"))
    if not isinstance(arm_map, dict):
        die("arm-map.json must be an object mapping run ids to arms")
    if not arm_map:
        die("arm-map.json is empty — nothing to join")
    if any(not isinstance(run_id, str) or not isinstance(arm, str)
           for run_id, arm in arm_map.items()):
        die("arm-map.json must map string run ids to string arms")
    arms = sorted(set(arm_map.values()))
    if len(arms) != 2:
        die("expected exactly 2 arms in arm-map.json, found %d: %s" % (len(arms), arms))

    config = load(os.path.join(iteration, "run-config.json"))
    if not isinstance(config, dict):
        die("run-config.json must be an object")
    treatment = config.get("treatment_arm")
    if not isinstance(treatment, str) or treatment not in arms:
        die("run-config.json treatment_arm %r is not an arm in arm-map.json" % treatment)
    repeats_per_cell = config.get("repeats_per_cell")
    if (isinstance(repeats_per_cell, bool) or
            not isinstance(repeats_per_cell, int) or repeats_per_cell < 1):
        die("run-config.json repeats_per_cell must be a positive integer")
    control = [arm for arm in arms if arm != treatment][0]

    # Blinding check. The condition must not have reached a grading record, its
    # filename, or its path: a grader that could see the arm is a threat to any
    # delta the run produces, and a leak voids the grading pass rather than
    # reducing confidence in it.
    tokens = [a.lower() for a in arms]

    # assertion id -> arm -> list of pass bits (one per repeat)
    cells = collections.defaultdict(lambda: collections.defaultdict(list))
    concepts, evidence, eval_of = {}, collections.defaultdict(dict), {}
    # Durations come from each run's retained metadata. Keep arms separate:
    # combining them makes an arm-specific cost difference invisible. Coverage
    # is tracked separately and enforced all-or-nothing below: a duration that
    # only some runs carry would silently under-report the other arm's cost.
    durations = collections.defaultdict(list)
    duration_runs = []
    all_runs = []

    for eval_dir in sorted(os.listdir(iteration)):
        if not eval_dir.startswith("eval-"):
            continue
        base = os.path.join(iteration, eval_dir)
        snapshot = load(os.path.join(base, "eval-snapshot.json"))
        want = set()
        for a in snapshot.get("assertions", []):
            want.add(a["id"])
            concepts[a["id"]] = a.get("concept", a["id"])
            eval_of[a["id"]] = snapshot.get("id", eval_dir)

        for run_id in sorted(os.listdir(base)):
            run = os.path.join(base, run_id)
            if not os.path.isdir(run) or run_id == "outputs":
                continue
            grading_path = os.path.join(run, "grading.json")
            if not os.path.exists(grading_path):
                continue
            for tok in tokens:
                if tok in run_id.lower() or tok in grading_path.lower():
                    die("arm token %r appears in %s — grading was not blind, "
                        "re-run the grading pass" % (tok, grading_path))
            raw = read_text(grading_path)
            for tok in tokens:
                if tok in raw.lower():
                    die("arm token %r appears inside %s — grading was not blind, "
                        "re-run the grading pass" % (tok, grading_path))
            try:
                grading = json.loads(raw)
            except ValueError as exc:
                die("cannot read %s: %s" % (grading_path, exc))

            arm = arm_map.get(run_id)
            if arm is None:
                die("run id %r is in %s but not in arm-map.json" % (run_id, base))
            all_runs.append((run_id, arm))

            results = grading.get("results", [])
            if not isinstance(results, list):
                die("%s results must be a list" % grading_path)
            try:
                got = set(r["id"] for r in results)
            except (KeyError, TypeError):
                die("%s has a result without an assertion id" % grading_path)
            if len(got) != len(results):
                die("%s records an assertion more than once" % grading_path)
            if got != want:
                die("%s grades %d ids, its snapshot lists %d; missing=%s extra=%s"
                    % (grading_path, len(got), len(want),
                       sorted(want - got), sorted(got - want)))

            for r in results:
                if "passed" not in r:
                    die("%s has no \"passed\" key for %s — a result missing the "
                        "field entirely cannot support a rollup" % (grading_path, r["id"]))
                passed = r.get("passed")
                if passed is None:
                    die("%s leaves %s ungraded. It is a manual assertion and a "
                        "human has to judge it, blind, before this iteration can "
                        "be rolled up" % (grading_path, r["id"]))
                cells[r["id"]][arm].append(bool(passed))
                if not r.get("evidence"):
                    die("%s has no evidence for %s — a pass bit without a "
                        "quotation cannot be re-derived" % (grading_path, r["id"]))
                evidence[r["id"]][arm] = r["evidence"]

            meta_path = os.path.join(run, "run-meta.json")
            if os.path.exists(meta_path):
                meta = load(meta_path)
                if not isinstance(meta, dict):
                    die("%s must be an object" % meta_path)
                for field in ("duration_s", "duration_seconds", "duration"):
                    if field in meta:
                        value = meta[field]
                        if (isinstance(value, bool) or
                                not isinstance(value, (int, float)) or
                                not math.isfinite(value) or value < 0):
                            die("%s %s must be a finite non-negative number" % (meta_path, field))
                        durations[arm].append(float(value))
                        duration_runs.append((run_id, arm))
                        break

    if not cells:
        die("no grading records found under %s" % iteration)

    # Duration reporting is all-or-nothing: a mean built from a subset of runs
    # would understate one arm's cost without saying so. Once any run in this
    # iteration carries a duration field, every run must.
    if duration_runs:
        have_duration = set(run_id for run_id, _arm in duration_runs)
        for run_id, arm in all_runs:
            if run_id not in have_duration:
                die("run %r (arm %s) has no duration field, but other runs in "
                    "this iteration do — duration reporting requires complete "
                    "coverage or none" % (run_id, arm))

    buckets = collections.defaultdict(list)
    rows, totals = [], collections.Counter()

    for aid in sorted(cells):
        per_arm = cells[aid]
        if set(per_arm) != set(arms):
            die("%s was graded in %s only — an unpaired assertion has no delta"
                % (aid, sorted(per_arm)))
        t_bits, c_bits = per_arm[treatment], per_arm[control]
        if len(t_bits) != repeats_per_cell or len(c_bits) != repeats_per_cell:
            die("%s has repeats treatment=%d control=%d; run-config.json requires %d per cell"
                % (aid, len(t_bits), len(c_bits), repeats_per_cell))
        t, c = majority(t_bits), majority(c_bits)
        unstable = len(set(t_bits)) > 1 or len(set(c_bits)) > 1

        if unstable:
            bucket = "unstable"
        elif t and not c:
            bucket = "discriminating"
        elif c and not t:
            bucket = "regression"
        else:
            bucket = "non-discriminating"

        buckets[bucket].append(aid)
        totals[treatment] += 1 if t else 0
        totals[control] += 1 if c else 0
        rows.append({
            "id": aid, "eval": eval_of.get(aid), "concept": concepts.get(aid),
            "bucket": bucket,
            treatment: {"passed": t, "repeats": t_bits, "evidence": evidence[aid].get(treatment)},
            control: {"passed": c, "repeats": c_bits, "evidence": evidence[aid].get(control)},
        })

    n = len(rows)
    if sum(len(v) for v in buckets.values()) != n:
        die("bucket counts do not sum to the checklist size — partition is broken")

    t_rate = 100.0 * totals[treatment] / n
    c_rate = 100.0 * totals[control] / n
    delta = t_rate - c_rate

    # Concentration: a delta that is one assertion in disguise is a different
    # finding from a broad lift, and the aggregate hides which it is.
    gain = len(buckets["discriminating"])
    per_point = 100.0 / n
    top1 = per_point / delta * 100 if delta > 0 else 0.0
    top2 = (2 * per_point) / delta * 100 if delta > 0 and gain >= 2 else top1

    report = {
        "iteration": os.path.basename(os.path.abspath(iteration)),
        "arms": {"treatment": treatment, "control": control},
        "weighting": "per-assertion",
        "checklist_size": n,
        "passed": {treatment: totals[treatment], control: totals[control]},
        "pass_rate_pct": {treatment: round(t_rate, 1), control: round(c_rate, 1)},
        "delta_pct_points": round(delta, 1),
        "buckets": {k: sorted(v) for k, v in buckets.items()},
        "concentration_pct_of_delta": {
            "top_assertion": round(top1, 1),
            "top_two_assertions": round(top2, 1),
        },
        "cost": {
            "input_tokens": "unavailable",
            "output_tokens": "unavailable",
            "usd": "unavailable",
        },
        "rows": rows,
    }
    if durations:
        report["duration_s"] = {}
        for arm in arms:
            values = durations[arm]
            if not values:
                continue
            duration_mean, duration_stddev = mean_and_stddev(values)
            report["duration_s"][arm] = {
                "mean": round(duration_mean, 3),
                "population_stddev": round(duration_stddev, 3),
                "sample_size": len(values),
            }
    return report, arms, durations


def print_report(report, arms, durations):
    treatment = report["arms"]["treatment"]
    control = report["arms"]["control"]
    n = report["checklist_size"]
    buckets = collections.defaultdict(list, report["buckets"])
    rows = report["rows"]

    print("arms:      %s (treatment) vs %s (control)" % (treatment, control))
    print("checklist: %d assertions, weighted per-assertion" % n)
    print("pass rate: %s %.1f%%   %s %.1f%%   delta %+.1f pp"
          % (treatment, 100.0 * report["passed"][treatment] / n,
             control, 100.0 * report["passed"][control] / n,
             report["delta_pct_points"]))
    if durations:
        for arm in arms:
            values = durations[arm]
            if not values:
                continue
            duration_mean, duration_stddev = mean_and_stddev(values)
            print("duration:  %s mean %.3fs   population stddev %.3fs   n=%d"
                  % (arm, duration_mean, duration_stddev, len(values)))
    print("cost:      unavailable (input tokens, output tokens, USD not recorded)")
    print("")
    for name in ("discriminating", "regression", "unstable", "non-discriminating"):
        ids = sorted(buckets[name])
        print("%-20s %2d" % (name, len(ids)))
        for aid in ids:
            print("                     %s" % aid)
    print("")
    if buckets["regression"]:
        print("REGRESSIONS — each needs its own named section with both arms' evidence:")
        for aid in sorted(buckets["regression"]):
            row = next(r for r in rows if r["id"] == aid)
            print("  %s" % aid)
            print("    %-10s %s" % (control, row[control]["evidence"]))
            print("    %-10s %s" % (treatment, row[treatment]["evidence"]))
        print("")


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        sys.stdout.write(USAGE)
        return 0
    iteration = argv[0]
    if not os.path.isdir(iteration):
        die("no such iteration directory: %s" % iteration)

    report, arms, durations = rollup(iteration)

    out = os.path.join(iteration, "rollup.json")
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=2, sort_keys=True)
        fh.write("\n")

    print_report(report, arms, durations)
    print("wrote %s" % out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
