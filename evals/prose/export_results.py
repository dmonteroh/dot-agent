#!/usr/bin/env python3
"""Export a validated comparison with every repeat's grades and configuration."""

import argparse
import collections
import hashlib
import json
from pathlib import Path
import statistics
import subprocess
import sys


def read_json(path):
    return json.loads(path.read_text())


def summarize(runs):
    result = {}
    for arm in sorted({run["arm"] for run in runs}):
        selected = [run for run in runs if run["arm"] == arm]
        grades = [grade for run in selected for grade in run["grading"]["results"]]
        if any(type(grade["passed"]) is not bool for grade in grades):
            raise ValueError("Every assertion needs a boolean grade before export")
        durations = [run["meta"]["duration_seconds"] for run in selected]
        passed = sum(grade["passed"] for grade in grades)
        by_eval = collections.defaultdict(lambda: {"passed": 0, "total": 0})
        for run in selected:
            row = by_eval[run["meta"]["eval"]]
            row["passed"] += sum(g["passed"] for g in run["grading"]["results"])
            row["total"] += len(run["grading"]["results"])
        result[arm] = {
            "sessions": len(selected),
            "passed_assertion_observations": passed,
            "assertion_observations": len(grades),
            "observation_pass_rate_pct": 100 * passed / len(grades),
            "tool_calls": sum(run["tool_calls"] for run in selected),
            "duration_seconds": {
                "mean": statistics.mean(durations),
                "population_stddev": statistics.pstdev(durations),
                "min": min(durations),
                "max": max(durations),
            },
            "per_eval": dict(by_eval),
        }
    return result


def validate_runs(iteration, excluded):
    diagnostics = []
    for meta_path in sorted(iteration.glob("eval-*/*/run-meta.json")):
        meta = read_json(meta_path)
        diagnostics.append({"run_id": meta_path.parent.name, "eval": meta["eval"],
                            "status": meta.get("status"), "void": meta.get("void", False)})
        if meta["eval"] in excluded:
            continue
        if meta.get("void") or meta.get("status") != "ok":
            raise ValueError("Unfinished or invalid run requires an explicit task exclusion: " + meta_path.parent.name)
        if not (meta_path.parent / "grading.json").exists():
            raise ValueError("Missing grading record: " + meta_path.parent.name)
    return diagnostics


def export(iteration, output, excluded=()):
    diagnostics = validate_runs(iteration, set(excluded))
    runner = Path(__file__).resolve().parents[1] / "rollup.py"
    command = [sys.executable, str(runner)]
    for eval_id in excluded:
        command.extend(["--exclude-eval", eval_id])
    subprocess.run(command + [str(iteration)], check=True, stdout=subprocess.DEVNULL)
    arm_map = read_json(iteration / "arm-map.json")
    config = read_json(iteration / "run-config.json")
    runs = []
    snapshots = {}
    for eval_dir in sorted(iteration.glob("eval-*")):
        if eval_dir.name.removeprefix("eval-") in excluded:
            continue
        snapshots[eval_dir.name] = read_json(eval_dir / "eval-snapshot.json")
        for grade_path in sorted(eval_dir.glob("*/grading.json")):
            run_dir = grade_path.parent
            meta = read_json(run_dir / "run-meta.json")
            if meta.get("void") or meta.get("status") != "ok":
                raise ValueError("Cannot export an unfinished or invalid run: " + run_dir.name)
            if meta.get("isolation", {}).get("unshipped_names_found"):
                raise ValueError("Isolation marker found: " + run_dir.name)
            trace = run_dir / "outputs" / "trace.jsonl"
            calls = sum(json.loads(line).get("event") == "call" for line in trace.read_text().splitlines())
            artifacts = {}
            for path in sorted((run_dir / "outputs").glob("*")):
                if path.is_file():
                    artifacts[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
            mapping = arm_map[run_dir.name]
            arm = mapping["arm"] if isinstance(mapping, dict) else mapping
            runs.append({"run_id": run_dir.name, "arm": arm, "meta": meta,
                         "grading": read_json(grade_path), "tool_calls": calls,
                         "artifact_sha256": artifacts})
    expected = len(snapshots) * len(config["arms"]) * config["repeats_per_cell"]
    if len(runs) != expected:
        raise ValueError("Expected %d runs, found %d" % (expected, len(runs)))
    report = {
        "format_version": 1,
        "source_workspace": str(iteration.resolve()),
        "run_config": config,
        "excluded_evals": list(excluded),
        "run_diagnostics": diagnostics,
        "eval_snapshots": snapshots,
        "rollup": read_json(iteration / "rollup.json"),
        "repeat_observations": summarize(runs),
        "runs": runs,
        "notes": [
            "Rollup scores use majority outcomes per assertion. Observation scores count every repeat.",
            "Repeated assertions within a task are correlated. Observation counts are not independent trials.",
            "CLI usage fields have provider-specific semantics. Compare within one provider and model.",
            "Artifact hashes identify raw outputs retained in the source workspace.",
        ],
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("iteration", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--exclude-eval", action="append", default=[])
    args = parser.parse_args()
    try:
        export(args.iteration, args.output, args.exclude_eval)
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as exc:
        parser.exit(2, "export_results: %s\n" % exc)
    print(args.output)


if __name__ == "__main__":
    main()
