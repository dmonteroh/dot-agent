#!/usr/bin/env python3
"""evals/load_first.py — how often a session's first trace event is the node load.

The bench reports a load-first share beside the pass rates: of all graded
sessions, how many began with `status.sh --load`, either as the agent's first
tool call or as a load a session-start hook delivered before the first turn.
Only the first session of a run counts; a handoff's second session is graded
by its own assertions, not this share.

Reads arm-map.json, so it is an after-grading analysis like pooled.py. Runs
without a grading.json are void and skipped.

Usage: load_first.py <ws>[:<arm>] [<ws>[:<arm>] ...] [--evals <id,id,...>]

<ws> is a workspace holding iteration-1/. With no :<arm>, every arm in that
workspace's arm-map.json is taken. Each line reports one workspace and arm:

  <ws>:<arm>  load-first <n>/<total> (<pct>%)  by hook <h>, by call <c>
"""

import collections
import io
import json
import os
import sys


def die(msg):
    sys.stderr.write("load_first.py: %s\n" % msg)
    sys.exit(2)


def first_event(trace_path):
    """The first call or hook event in a trace, or None."""
    with io.open(trace_path, encoding="utf-8") as fh:
        for line in fh:
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            if ev.get("event", "call") in ("call", "hook"):
                return ev
    return None


def is_load(ev):
    return ev is not None and "status.sh --load" in (ev.get("text") or "")


def main(argv):
    specs = []
    only = set()
    i = 0
    while i < len(argv):
        if argv[i] == "--evals":
            if i + 1 >= len(argv):
                die("--evals needs a list")
            only = set(x for x in argv[i + 1].split(",") if x)
            i += 2
        elif argv[i] in ("-h", "--help"):
            sys.stdout.write(__doc__)
            return 0
        else:
            specs.append(argv[i])
            i += 1
    if not specs:
        die("name at least one workspace")

    counts = collections.OrderedDict()
    for spec in specs:
        ws, _, arm = spec.partition(":")
        it = os.path.join(ws, "iteration-1")
        map_path = os.path.join(it, "arm-map.json")
        if not os.path.isfile(map_path):
            die("no arm-map.json under %s" % it)
        with io.open(map_path, encoding="utf-8") as fh:
            arm_map = json.load(fh)
        for ev_dir in sorted(os.listdir(it)):
            if not ev_dir.startswith("eval-"):
                continue
            eval_id = ev_dir[len("eval-"):]
            if only and eval_id not in only:
                continue
            for run in sorted(os.listdir(os.path.join(it, ev_dir))):
                rd = os.path.join(it, ev_dir, run)
                if not os.path.isfile(os.path.join(rd, "grading.json")):
                    continue
                run_arm = arm_map.get(run)
                if isinstance(run_arm, dict):
                    run_arm = run_arm.get("arm")
                if run_arm is None or (arm and run_arm != arm):
                    continue
                trace = os.path.join(rd, "outputs", "trace.jsonl")
                ev = first_event(trace) if os.path.isfile(trace) else None
                key = "%s:%s" % (os.path.basename(os.path.normpath(ws)), run_arm)
                c = counts.setdefault(key, {"total": 0, "hook": 0, "call": 0})
                c["total"] += 1
                if is_load(ev):
                    c["hook" if ev.get("event") == "hook" else "call"] += 1

    if not counts:
        die("no graded runs found")
    for key, c in counts.items():
        n = c["hook"] + c["call"]
        print("%s  load-first %d/%d (%.0f%%)  by hook %d, by call %d" % (
            key, n, c["total"], 100.0 * n / c["total"], c["hook"], c["call"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
