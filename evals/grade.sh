#!/usr/bin/env bash
# evals/grade.sh — evaluates one run's auto-graded assertions against the
# artifacts it captured, and writes grading.json with an evidence line per
# assertion.
#
# It reads only the captured outputs, never the repository the run acted on,
# so a grading pass is reproducible from the run directory alone and can be
# re-run months later against artifacts whose source tree has moved.
#
# Manual assertions are written out with passed:null for a human to fill in,
# blind. rollup.sh refuses a record that still holds one.
#
# Requires python3. Full documentation: evals/README.md.
#
# Usage: grade.sh <run-dir> <eval-snapshot.json>

set -u

case "${1:-}" in
-h | --help | "")
  cat <<'EOF'
Usage: grade.sh <run-dir> <eval-snapshot.json>

Reads <run-dir>/outputs/ and writes <run-dir>/grading.json.

Expected under outputs/, all written by run.sh:
  diff.patch              project tree diff, fixture base -> run end
  node-diff.patch         .agent/ diff, fixture base -> run end
  session-transcript.txt  the agent's own reply text
  trace.jsonl             one JSON object per tool-call event (see spec.json)
  status-after.txt        status.sh output after the session
  gate.txt                comments.sh output over diff.patch
  node-tree.txt           every path under .agent/ with its content, for
                          tree-wide absence checks

A missing artifact fails every assertion that needs it, with the reason
named. It never passes one by default: a grader that scores an artifact it
could not read is the fail-open shape this whole suite exists to refuse.
EOF
  exit 0 ;;
esac

rundir="$1"
snapshot="${2:-}"
[ -d "$rundir" ] || { echo "grade.sh: no such run directory: $rundir" >&2; exit 2; }
[ -f "$snapshot" ] || { echo "grade.sh: no such snapshot: $snapshot" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "grade.sh: python3 not found" >&2; exit 2; }

RUNDIR="$rundir" SNAPSHOT="$snapshot" python3 <<'PY'
import json, os, re, sys

rundir = os.environ["RUNDIR"]
out = os.path.join(rundir, "outputs")
snapshot = json.load(open(os.environ["SNAPSHOT"], encoding="utf-8"))

def art(name):
    p = os.path.join(out, name)
    if not os.path.exists(p):
        return None
    return open(p, encoding="utf-8", errors="replace").read()

CACHE = {}
def a(name):
    if name not in CACHE:
        CACHE[name] = art(name)
    return CACHE[name]

class Missing(Exception):
    def __init__(self, name):
        self.name = name

def need(name):
    v = a(name)
    if v is None:
        raise Missing(name)
    return v

# ---- diff readers -------------------------------------------------------
# A patch is parsed rather than grepped so "added" means a + line and not a
# context line that happens to contain the string. The distinction decides
# several assertions outright.

def diff_files(patch):
    # A file is new when git says so, on the --- line. Inferring it from
    # "no removed lines" reads an append to an existing file as a creation,
    # which is the difference between extending the catalogued block and
    # building a second one — the whole point of one of these evals.
    files = {}
    cur = None
    prev_from_devnull = False
    for line in patch.splitlines():
        if line.startswith("--- "):
            prev_from_devnull = line.strip() == "--- /dev/null"
            continue
        m = re.match(r"^\+\+\+ b/(.*)$", line)
        if m:
            cur = m.group(1)
            files.setdefault(cur, {"added": [], "removed": [], "new": prev_from_devnull})
            files[cur]["new"] = files[cur]["new"] or prev_from_devnull
            continue
        if cur is None:
            continue
        if line.startswith("+") and not line.startswith("+++"):
            files[cur]["added"].append(line[1:])
        elif line.startswith("-") and not line.startswith("---"):
            files[cur]["removed"].append(line[1:])
    return files

def node_files():
    return diff_files(need("node-diff.patch"))

def product_files():
    return diff_files(need("diff.patch"))

def added_text(patch):
    return "\n".join(l for l in patch.splitlines()
                     if l.startswith("+") and not l.startswith("+++"))

# ---- trace --------------------------------------------------------------

class InvalidTrace(Exception):
    def __init__(self, detail):
        self.detail = detail

def trace():
    """Return gradeable call events, rejecting malformed trace input.

    The runner owns the current trace contract.  Older captured runs used
    only integer seq and string text; accept exactly that shape as a call so
    historical artifacts remain gradeable without letting partial records
    masquerade as calls.
    """
    raw = need("trace.jsonl")
    events = []
    for line_no, line in enumerate(raw.splitlines(), 1):
        if not line.strip():
            raise InvalidTrace("trace.jsonl line %d is blank, not a JSON object" % line_no)
        try:
            ev = json.loads(line)
        except (TypeError, ValueError) as exc:
            raise InvalidTrace("trace.jsonl line %d is malformed JSON: %s" % (line_no, exc))
        if not isinstance(ev, dict):
            raise InvalidTrace("trace.jsonl line %d is not a JSON object" % line_no)

        legacy = set(ev) == set(("seq", "text"))
        if legacy:
            if isinstance(ev["seq"], bool) or not isinstance(ev["seq"], int):
                raise InvalidTrace("trace.jsonl line %d has non-integer legacy seq" % line_no)
            if not isinstance(ev["text"], str):
                raise InvalidTrace("trace.jsonl line %d has non-string legacy text" % line_no)
            events.append((ev["seq"], ev["text"]))
            continue

        required = ("seq", "event", "tool", "action", "text")
        absent = [field for field in required if field not in ev]
        if absent:
            raise InvalidTrace("trace.jsonl line %d is missing required field(s): %s" %
                               (line_no, ", ".join(absent)))
        if isinstance(ev["seq"], bool) or not isinstance(ev["seq"], int):
            raise InvalidTrace("trace.jsonl line %d has non-integer seq" % line_no)
        for field in ("event", "tool", "action", "text"):
            if not isinstance(ev[field], str):
                raise InvalidTrace("trace.jsonl line %d has non-string %s" % (line_no, field))
        if ev["action"] not in ("read", "write", "execute", "search", "other"):
            raise InvalidTrace("trace.jsonl line %d has invalid action %r" %
                               (line_no, ev["action"]))
        if ev["event"] == "call":
            events.append((ev["seq"], ev["text"]))
    return events

# ---- primitives ---------------------------------------------------------
# Each returns (bool, evidence). Evidence quotes what settled it; on a
# failure it quotes what the agent did instead, which is what turns a red
# cell into a next-revision edit rather than a restated assertion.

def p_gate_block_count(op, n):
    g = need("gate.txt")
    block = g.split("BLOCK:", 1)[1] if "BLOCK:" in g else ""
    count = len(re.findall(r"^\s{2}\S.*\[", block, re.M)) if block else 0
    return cmp_num(count, op, int(n)), "gate reported %d BLOCK finding(s)" % count

def p_gate_class_count(cls, op, n):
    g = need("gate.txt")
    count = g.count("[%s]" % cls)
    return cmp_num(count, op, int(n)), "gate reported %d finding(s) of class %r" % (count, cls)

def p_status_flags_absent(pattern):
    s = need("status-after.txt")
    hits = [l for l in s.splitlines()
            if re.match(r"^(GROOM|REPAIR|INDEX):", l) and re.search(pattern, l)]
    return (not hits), ("no status flag matches %r" % pattern) if not hits else ("status still reports: " + hits[0][:160])

def p_log_entries_added(op, n):
    f = node_files().get("session-log.md", {"added": []})
    entries = [l for l in f["added"] if l.startswith("- [")]
    return cmp_num(len(entries), op, int(n)), "%d log entr(y/ies) appended: %s" % (
        len(entries), (entries[0][:140] if entries else "none"))

def p_log_entry_words(op, n):
    f = node_files().get("session-log.md", {"added": []})
    entries = [l for l in f["added"] if l.startswith("- [")]
    if not entries:
        return False, "no log entry was appended, so its length cannot be judged"
    worst = max(entries, key=lambda e: len(e.split()))
    # The header format counts the summary, not the tags it is wrapped in.
    body = re.sub(r"^- \[[^\]]*\] \([^)]*\)\s*", "", worst)
    body = re.sub(r"(branch|verify):\s*\S+\.?", "", body)
    w = len(body.split())
    return cmp_num(w, op, int(n)), "longest entry's summary is %d words: %s" % (w, worst[:140])

def p_log_entry_absent(pattern):
    f = node_files().get("session-log.md", {"added": []})
    entries = [l for l in f["added"] if l.startswith("- [")]
    hits = [e for e in entries if re.search(pattern, e)]
    return (not hits), ("no appended entry matches %r" % pattern) if not hits else ("entry carries it: " + hits[0][:160])

def p_memory_files_added(op, n):
    fs = node_files()
    new = [k for k in fs if k.startswith("memory/") and fs[k]["new"]]
    return cmp_num(len(new), op, int(n)), "%d memory file(s) written: %s" % (
        len(new), ", ".join(new) if new else "none")

def p_memory_files_modified(op, n):
    fs = node_files()
    mod = [k for k in fs if k.startswith("memory/") and not fs[k]["new"]]
    return cmp_num(len(mod), op, int(n)), "%d memory file(s) modified in place: %s" % (
        len(mod), ", ".join(mod) if mod else "none")

def _learned_delta():
    f = node_files().get("rules/learned.md", {"added": [], "removed": []})
    add = [l for l in f["added"] if l.startswith("- [")]
    rem = [l for l in f["removed"] if l.startswith("- [")]
    return add, rem

def p_learned_rules_added(op, n):
    add, _ = _learned_delta()
    return cmp_num(len(add), op, int(n)), "%d learned rule(s) added: %s" % (
        len(add), add[0][:140] if add else "none")

def p_learned_rules_removed(op, n):
    _, rem = _learned_delta()
    return cmp_num(len(rem), op, int(n)), "%d learned rule(s) removed: %s" % (
        len(rem), rem[0][:140] if rem else "none")

def p_node_file_changed(path):
    fs = node_files()
    return (path in fs), ("%s was edited" % path) if path in fs else (
        "%s untouched; node changes were: %s" % (path, ", ".join(sorted(fs)) or "none"))

def p_node_file_matches(path, pattern):
    f = node_files().get(path)
    if f is None:
        return False, "%s was not edited at all" % path
    hits = [l for l in f["added"] if re.search(pattern, l)]
    return bool(hits), (hits[0][:160] if hits else "%s changed but no added line matches %r" % (path, pattern))

def p_node_file_absent(path, pattern):
    f = node_files().get(path)
    if f is None:
        return True, "%s was not edited, so nothing matching %r was added" % (path, pattern)
    hits = [l for l in f["added"] if re.search(pattern, l)]
    return (not hits), ("no added line in %s matches %r" % (path, pattern)) if not hits else hits[0][:160]

def p_node_tree_absent(pattern):
    t = need("node-tree.txt")
    hits = [l for l in t.splitlines() if re.search(pattern, l)]
    return (not hits), ("nothing under .agent/ matches %r" % pattern) if not hits else ("found under .agent/: " + hits[0][:160])

def p_product_files_changed(op, n):
    fs = product_files()
    return cmp_num(len(fs), op, int(n)), "%d project file(s) changed: %s" % (
        len(fs), ", ".join(sorted(fs)) if fs else "none")

def p_product_files_added(op, n):
    fs = product_files()
    new = [k for k in fs if fs[k]["new"]]
    return cmp_num(len(new), op, int(n)), "%d project file(s) created: %s" % (
        len(new), ", ".join(sorted(new)) if new else "none")

def p_diff_absent(s):
    txt = added_text(need("diff.patch"))
    hits = [l for l in txt.splitlines() if s in l]
    return (not hits), ("no added line contains %r" % s) if not hits else hits[0][:160]

def p_diff_contains(s):
    txt = added_text(need("diff.patch"))
    hits = [l for l in txt.splitlines() if s in l]
    return bool(hits), (hits[0][:160] if hits else "no added line contains %r" % s)

def p_entrypoint_words_delta(op, n):
    fs = node_files()
    d = 0
    for k, v in diff_files(need("diff.patch")).items():
        if os.path.basename(k) in ("CLAUDE.md", "AGENTS.md", "copilot-instructions.md"):
            d += sum(len(l.split()) for l in v["added"]) - sum(len(l.split()) for l in v["removed"])
    return cmp_num(d, op, int(n)), "entry points changed by %+d words" % d

def p_trace_count(needle, op, n):
    ev = trace()
    hits = [t for _, t in ev if needle in t]
    return cmp_num(len(hits), op, int(n)), "%d trace event(s) mention %r%s" % (
        len(hits), needle, (": " + hits[0][:120]) if hits else "")

def p_trace_contains(needle):
    ev = trace()
    hits = [t for _, t in ev if needle in t]
    return bool(hits), (hits[0][:160] if hits else "no trace event mentions %r" % needle)

def p_trace_matches(pattern):
    ev = trace()
    hits = [t for _, t in ev if re.search(pattern, t)]
    return bool(hits), (hits[0][:160] if hits else "no trace event matches %r" % pattern)

def p_trace_order(first, _kw, second):
    ev = trace()
    fi = next((s for s, t in ev if first in t), None)
    si = next((s for s, t in ev if second in t), None)
    if fi is None:
        return False, "%r never appears in the trace" % first
    if si is None:
        return False, "%r appears at seq %d but %r never appears in the trace" % (first, fi, second)
    return (fi < si), "%r at seq %d, %r at seq %d" % (first, fi, second, si)

def p_output_matches(s):
    t = need("session-transcript.txt")
    hits = [l for l in t.splitlines() if s.lower() in l.lower()]
    return bool(hits), (hits[0][:160] if hits else "the reply never says %r" % s)

def p_output_absent(s):
    t = need("session-transcript.txt")
    hits = [l for l in t.splitlines() if s.lower() in l.lower()]
    return (not hits), ("the reply never says %r" % s) if not hits else hits[0][:160]

def cmp_num(got, op, want):
    return {"==": got == want, "<=": got <= want, ">=": got >= want,
            "<": got < want, ">": got > want, "!=": got != want}[op]

PRIMS = {k[2:]: v for k, v in list(globals().items()) if k.startswith("p_")}

# ---- the tiny check language -------------------------------------------
# Deliberately tiny: named primitive, quoted string arguments, a numeric
# comparison, `!` negation, and && / || between terms. Anything a check
# wants to say beyond that is a judgement, and judgements are graded manual.

TOKEN = re.compile(r"'([^']*)'|\"([^\"]*)\"|(\S+)")

def eval_term(term):
    term = term.strip()
    neg = term.startswith("!")
    if neg:
        term = term[1:].strip()
    parts = [m.group(1) if m.group(1) is not None else
             m.group(2) if m.group(2) is not None else m.group(3)
             for m in TOKEN.finditer(term)]
    if not parts:
        raise ValueError("empty check term")
    name, args = parts[0], parts[1:]
    if name not in PRIMS:
        raise ValueError("unknown check primitive %r" % name)
    ok, ev = PRIMS[name](*args)
    return (not ok if neg else ok), ev

def eval_check(expr):
    # || binds loosest, then &&. No parentheses: a check needing them is a
    # check doing too much.
    for sep, combine in (("||", any), ("&&", all)):
        if sep in expr:
            results = [eval_check(p) for p in expr.split(sep)]
            ok = combine(r[0] for r in results)
            joiner = " OR " if sep == "||" else " AND "
            return ok, joiner.join(r[1] for r in results)
    return eval_term(expr)

results = []
for assertion in snapshot.get("assertions", []):
    entry = {"id": assertion["id"], "concept": assertion.get("concept")}
    if assertion.get("grade") != "auto":
        entry.update({"passed": None, "evidence": None, "grade": "manual"})
        results.append(entry)
        continue
    try:
        ok, ev = eval_check(assertion["check"])
        entry.update({"passed": bool(ok), "evidence": ev, "grade": "auto"})
    except Missing as m:
        entry.update({"passed": False, "grade": "auto",
                      "evidence": "artifact %s was not captured, so this could not be judged" % m.name})
    except Exception as exc:
        entry.update({"passed": False, "grade": "auto",
                      "evidence": "check could not be evaluated: %s" % exc})
    results.append(entry)

path = os.path.join(rundir, "grading.json")
with open(path, "w", encoding="utf-8") as fh:
    json.dump({"results": results}, fh, indent=2, sort_keys=True)
    fh.write("\n")

auto = [r for r in results if r["grade"] == "auto"]
manual = [r for r in results if r["grade"] == "manual"]
print("graded %d auto (%d passed), %d awaiting manual judgement -> %s"
      % (len(auto), sum(1 for r in auto if r["passed"]), len(manual), path))
for r in manual:
    print("  MANUAL  %s" % r["id"])
PY
