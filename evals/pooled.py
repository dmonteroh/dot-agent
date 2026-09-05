#!/usr/bin/env python3
"""evals/pooled.py — one candidate corpus against a pooled baseline of runs.

rollup.py joins exactly two arms inside one iteration at one repeat count.
That is the right shape for a paired verdict, and the wrong shape for the
question this tool answers: when the same baseline corpus has already run
several times (across workspaces, days, and repeat counts), every one of
those runs is evidence about what the baseline does, and a candidate is
better judged against all of them than against one fresh control.

Pools every run of the named baseline arms and every run of the named
candidate arms, joins on assertion id, and reports per assertion:

  stable-pass   both sides pass every run
  both-fail     both sides pass at most half their runs
  unique-fail   candidate passes at most half, baseline at least three quarters
                (a regression candidate — read the evidence before believing it)
  unique-win    candidate at least three quarters, baseline at most half
  noise         everything else — the two sides differ inside the flake band

Pass rates are reported overall and per assertion kind (assertion-kinds.json),
and cost per eval — tool-call steps, USD, seconds — is reported as baseline
mean ± sd against candidate mean, because steps are what the corpus can change
and USD is what the operator pays.

This reads arm-map.json: it is an after-grading analysis, never a grading
step. A manual record still ungraded (passed: null) is listed and excluded,
and the exclusion count is printed, so a partial pool cannot read as a full one.

Usage: pooled.py --baseline <ws>[:<arm>] [--baseline ...]
                 --candidate <ws>[:<arm>] [--candidate ...]
                 [--kinds <assertion-kinds.json>] [--json <out.json>]
                 [--evals <id,id,...>]

<ws> is a workspace holding iteration-1/. With no :<arm>, every arm in that
workspace's arm-map.json is taken, so a single-arm workspace needs no suffix.
"""

import collections
import io
import json
import os
import sys

SELF = os.path.dirname(os.path.abspath(__file__))


def die(msg):
    sys.stderr.write("pooled.py: %s\n" % msg)
    sys.exit(2)


def load(path):
    with io.open(path, encoding="utf-8") as fh:
        return json.load(fh)


def runs_of(spec, only_evals):
    """Yield (label, eval_id, run_dir, grading, meta, steps) for each graded run."""
    ws, _, arm = spec.partition(":")
    it = os.path.join(os.path.expanduser(ws), "iteration-1")
    if not os.path.isdir(it):
        die("no iteration-1 under %s" % ws)
    arm_map = load(os.path.join(it, "arm-map.json"))
    for ev in sorted(os.listdir(it)):
        if not ev.startswith("eval-"):
            continue
        eval_id = ev[len("eval-"):]
        if only_evals and eval_id not in only_evals:
            continue
        for run in sorted(os.listdir(os.path.join(it, ev))):
            rd = os.path.join(it, ev, run)
            g = os.path.join(rd, "grading.json")
            if not os.path.isfile(g):
                continue
            run_arm = arm_map.get(run)
            if isinstance(run_arm, dict):
                run_arm = run_arm.get("arm")
            if arm and run_arm != arm:
                continue
            meta = load(os.path.join(rd, "run-meta.json")) if os.path.isfile(os.path.join(rd, "run-meta.json")) else {}
            steps = 0
            tr = os.path.join(rd, "outputs", "trace.jsonl")
            if os.path.isfile(tr):
                with io.open(tr, encoding="utf-8") as fh:
                    for line in fh:
                        try:
                            e = json.loads(line)
                        except ValueError:
                            continue
                        if e.get("event", "call") == "call":
                            steps += 1
            yield "%s:%s" % (os.path.basename(os.path.normpath(ws)), run_arm), eval_id, rd, load(g), meta, steps


def collect(specs, only_evals):
    bits = collections.defaultdict(list)       # assertion id -> [bool]
    pending = []                                # (run_dir, assertion id)
    per_eval = collections.defaultdict(lambda: {"steps": [], "usd": [], "dur": []})
    labels = collections.Counter()
    for spec in specs:
        for label, eval_id, rd, grading, meta, steps in runs_of(spec, only_evals):
            labels[label] += 1
            recs = grading["results"] if isinstance(grading, dict) and "results" in grading else grading
            for r in recs:
                if r.get("passed") is None:
                    pending.append((rd, r["id"]))
                    continue
                bits[r["id"]].append(bool(r["passed"]))
            u = meta.get("usage") or {}
            per_eval[eval_id]["steps"].append(steps)
            per_eval[eval_id]["usd"].append(u.get("usd") or 0.0)
            per_eval[eval_id]["dur"].append(meta.get("duration_seconds") or meta.get("duration_s") or 0)
    return bits, pending, per_eval, labels


def rate(xs):
    return sum(xs) / len(xs) if xs else None


def msd(xs):
    if not xs:
        return (None, None)
    m = sum(xs) / len(xs)
    v = sum((x - m) ** 2 for x in xs) / len(xs)
    return m, v ** 0.5


def bucket(b, c):
    if b is None or c is None:
        return "missing"
    if b == 1.0 and c == 1.0:
        return "stable-pass"
    if b <= 0.5 and c <= 0.5:
        return "both-fail"
    if c <= 0.5 and b >= 0.75:
        return "unique-fail"
    if c >= 0.75 and b <= 0.5:
        return "unique-win"
    if b == c:
        return "same"
    return "noise"


def main(argv):
    baseline, candidate, only = [], [], set()
    kinds_path = os.path.join(SELF, "assertion-kinds.json")
    out_json = None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--baseline":
            baseline.append(argv[i + 1]); i += 2
        elif a == "--candidate":
            candidate.append(argv[i + 1]); i += 2
        elif a == "--kinds":
            kinds_path = argv[i + 1]; i += 2
        elif a == "--json":
            out_json = argv[i + 1]; i += 2
        elif a == "--evals":
            only = set(argv[i + 1].split(",")); i += 2
        elif a in ("-h", "--help"):
            print(__doc__); return 0
        else:
            die("unknown argument: %s" % a)
    if not baseline or not candidate:
        die("--baseline and --candidate are both required")
    kinds = load(kinds_path)["kinds"]

    b_bits, b_pending, b_cost, b_labels = collect(baseline, only)
    c_bits, c_pending, c_cost, c_labels = collect(candidate, only)
    ids = sorted(set(b_bits) | set(c_bits))

    rows, buckets = [], collections.defaultdict(list)
    for aid in ids:
        b, c = rate(b_bits.get(aid, [])), rate(c_bits.get(aid, []))
        k = bucket(b, c)
        buckets[k].append(aid)
        rows.append({"id": aid, "kind": kinds.get(aid, "?"),
                     "baseline": [b, len(b_bits.get(aid, []))],
                     "candidate": [c, len(c_bits.get(aid, []))], "bucket": k})

    def kind_rates(bits):
        per = collections.defaultdict(lambda: [0, 0])
        for aid, xs in bits.items():
            k = kinds.get(aid, "?")
            per[k][0] += sum(xs); per[k][1] += len(xs)
        return {k: (v[0] / v[1] if v[1] else None, v[1]) for k, v in per.items()}

    def overall(bits):
        n = sum(len(x) for x in bits.values()); p = sum(sum(x) for x in bits.values())
        return (p / n if n else None, n)

    print("baseline runs:  %s" % dict(b_labels))
    print("candidate runs: %s" % dict(c_labels))
    if b_pending or c_pending:
        print("UNGRADED (excluded): baseline %d, candidate %d" % (len(b_pending), len(c_pending)))
        for rd, aid in (b_pending + c_pending)[:20]:
            print("   %s %s" % (rd, aid))
    bo, co = overall(b_bits), overall(c_bits)
    print()
    print("%-14s %10s %10s %8s" % ("pass rate", "baseline", "candidate", "delta"))
    print("%-14s %9.1f%% %9.1f%% %+7.1f  (n=%d / %d assertion-runs)"
          % ("overall", 100 * bo[0], 100 * co[0], 100 * (co[0] - bo[0]), bo[1], co[1]))
    bk, ck = kind_rates(b_bits), kind_rates(c_bits)
    for k in ("behavior", "conformance", "information"):
        if k in bk and k in ck and bk[k][0] is not None and ck[k][0] is not None:
            print("%-14s %9.1f%% %9.1f%% %+7.1f" % (k, 100 * bk[k][0], 100 * ck[k][0], 100 * (ck[k][0] - bk[k][0])))
    print()
    for k in ("unique-fail", "unique-win", "both-fail", "noise", "same", "missing"):
        if buckets.get(k):
            print("%-12s %d" % (k, len(buckets[k])))
            for aid in buckets[k]:
                r = next(x for x in rows if x["id"] == aid)
                print("   %-48s %-12s base %s/%d  cand %s/%d" % (
                    aid, r["kind"],
                    "%.2f" % r["baseline"][0] if r["baseline"][0] is not None else "-", r["baseline"][1],
                    "%.2f" % r["candidate"][0] if r["candidate"][0] is not None else "-", r["candidate"][1]))
    print("%-12s %d" % ("stable-pass", len(buckets.get("stable-pass", []))))

    print()
    print("%-28s %18s %12s %16s %10s %12s %8s" % ("cost per eval", "base steps", "cand steps", "base usd", "cand usd", "base s", "cand s"))
    tb = {"steps": 0.0, "usd": 0.0, "dur": 0.0}; tc = {"steps": 0.0, "usd": 0.0, "dur": 0.0}
    cost_rows = []
    for eval_id in sorted(set(b_cost) | set(c_cost)):
        b, c = b_cost.get(eval_id), c_cost.get(eval_id)
        bs, bsd = msd(b["steps"]) if b else (None, None)
        cs, _ = msd(c["steps"]) if c else (None, None)
        bu, _ = msd(b["usd"]) if b else (None, None)
        cu, _ = msd(c["usd"]) if c else (None, None)
        bd, _ = msd(b["dur"]) if b else (None, None)
        cd, _ = msd(c["dur"]) if c else (None, None)
        cost_rows.append({"eval": eval_id, "base_steps": bs, "base_steps_sd": bsd, "cand_steps": cs,
                          "base_usd": bu, "cand_usd": cu, "base_s": bd, "cand_s": cd})
        if bs is not None and cs is not None:
            tb["steps"] += bs; tc["steps"] += cs; tb["usd"] += bu; tc["usd"] += cu; tb["dur"] += bd; tc["dur"] += cd
        print("%-28s %10s ± %-5s %12s %16s %10s %12s %8s" % (
            eval_id, "%.1f" % bs if bs is not None else "-", "%.1f" % bsd if bsd is not None else "-",
            "%.1f" % cs if cs is not None else "-",
            "%.3f" % bu if bu is not None else "-", "%.3f" % cu if cu is not None else "-",
            "%.0f" % bd if bd is not None else "-", "%.0f" % cd if cd is not None else "-"))
    if tb["steps"]:
        print("%-28s %18.1f %12.1f %16.3f %10.3f %12.0f %8.0f" % ("TOTAL (evals in both)", tb["steps"], tc["steps"], tb["usd"], tc["usd"], tb["dur"], tc["dur"]))
        print("candidate / baseline: steps %.2f  usd %.2f  seconds %.2f" % (
            tc["steps"] / tb["steps"], tc["usd"] / tb["usd"] if tb["usd"] else 0, tc["dur"] / tb["dur"] if tb["dur"] else 0))
    if out_json:
        with io.open(out_json, "w", encoding="utf-8") as fh:
            json.dump({"baseline": baseline, "candidate": candidate, "overall": {"baseline": bo, "candidate": co},
                       "by_kind": {"baseline": bk, "candidate": ck}, "rows": rows,
                       "buckets": {k: v for k, v in buckets.items()}, "cost": cost_rows,
                       "cost_total": {"baseline": tb, "candidate": tc},
                       "ungraded": {"baseline": len(b_pending), "candidate": len(c_pending)}},
                      fh, indent=2)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
