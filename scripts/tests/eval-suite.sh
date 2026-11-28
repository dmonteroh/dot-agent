#!/usr/bin/env bash

: "${reporoot:?run scripts/test.sh}"

evleak="$WORK/node-scope"
mkdir -p "$evleak"
"$NODE" init --preset software-development --mode track-all "$evleak" >/dev/null 2>&1
leaked43=$(find "$evleak" -path '*eval*' -o -name 'spec.json' -o -name 'agents.conf' \
  -o -name 'fixtures.sh' -o -name 'fixture_seed.py' -o -name 'rollup.py' -o -name 'grade.py' 2>/dev/null)
[ -z "$leaked43" ] && pass "evals: init puts nothing from evals/ into a node" || fail "evals: init puts nothing from evals/ into a node ($leaked43)"

evleak2="$WORK/node-scope-update"
mkdir -p "$evleak2"
make_v6_fixture "$evleak2"
"$NODE" update "$evleak2" >/dev/null 2>&1
leaked43b=$(find "$evleak2" -path '*eval*' -o -name 'spec.json' -o -name 'agents.conf' \
  -o -name 'fixtures.sh' -o -name 'fixture_seed.py' -o -name 'rollup.py' -o -name 'grade.py' 2>/dev/null)
[ -z "$leaked43b" ] && pass "evals: update puts nothing from evals/ into a node" || fail "evals: update puts nothing from evals/ into a node ($leaked43b)"

extra43=""
for f43 in "$evleak"/.agent/scripts/*; do
  case "$(basename "$f43")" in
  status.sh | log.sh | memory.sh | docs.sh | links.sh | comments.sh | checkpoint.sh | index.sh | learn.sh | runtime.sh | verify.sh | review.sh | capture.sh | absorb.sh | session-start.sh | checks.sh | status.conf | log.conf | comments.conf | verify.conf | review.conf | checkpoint.conf) ;;
  *) extra43="$extra43 $(basename "$f43")" ;;
  esac
done
[ -z "$extra43" ] && pass "evals: a node's scripts/ holds exactly the shipped set" || fail "evals: a node's scripts/ holds exactly the shipped set (extra: $(printf '%s' "$extra43" | tr '\n' ' '))"

grep -qF "belongs to the dot-agent repository, not to the harness" "$reporoot/evals/README.md" && pass "evals: the bench states its own scope at the top of its README" || fail "evals: the bench states its own scope at the top of its README"
appendix43=$(awk '/^## Appendix: optional tooling/ { f = 1 } f' "$reporoot/operating-model.md")
printf '%s\n' "$appendix43" | grep -q 'evals/' && fail "evals: the bench is not listed as node-installable tooling" || pass "evals: the bench is not listed as node-installable tooling"

evroot="$reporoot/evals"
if command -v python3 >/dev/null 2>&1; then
  ev42=$(SPEC="$evroot/spec.json" FIX="$evroot/fixtures.sh" python3 - <<'PY'
import io, json, os, re, sys
bad = []
spec = json.load(io.open(os.environ["SPEC"], encoding="utf-8"))
fixtures = set(re.search(r'^FIXTURES="([^"]*)"', io.open(os.environ["FIX"], encoding="utf-8").read(), re.M).group(1).split())
seen = set()
for ev in spec["evals"]:
    for field in ("id", "fixture", "prompt", "expect", "artifacts", "assertions"):
        if not ev.get(field):
            bad.append("%s missing %s" % (ev.get("id", "?"), field))
    if ev.get("fixture") not in fixtures:
        bad.append("%s names unknown fixture %r" % (ev["id"], ev.get("fixture")))
    for a in ev.get("assertions", []):
        for field in ("id", "concept", "text", "class", "grade"):
            if not a.get(field):
                bad.append("%s/%s missing %s" % (ev["id"], a.get("id", "?"), field))
        if a.get("class") not in ("artifact", "trace"):
            bad.append("%s class=%r" % (a.get("id"), a.get("class")))
        if a.get("grade") not in ("auto", "manual"):
            bad.append("%s grade=%r" % (a.get("id"), a.get("grade")))
        if a.get("grade") == "auto" and not a.get("check"):
            bad.append("%s is auto-graded with no check" % a.get("id"))
        if not str(a.get("id", "")).startswith(ev["id"] + "/"):
            bad.append("%s is not namespaced under its eval" % a.get("id"))
        if a.get("id") in seen:
            bad.append("duplicate assertion id %s" % a.get("id"))
        seen.add(a.get("id"))
    for p in ev.get("premises", []) or []:
        if not p.get("path"):
            bad.append("%s has a premise with no path: %r" % (ev["id"], p))
        keys = [k for k in ("contains", "absent", "exists") if k in p]
        if len(keys) != 1:
            bad.append("%s has a premise with %d of contains/absent/exists, want exactly 1: %r"
                       % (ev["id"], len(keys), p))
for key in ("arms", "weighting"):
    if not spec.get(key):
        bad.append("spec missing %s" % key)
if not spec.get("arms", {}).get("control", {}).get("definition"):
    bad.append("spec has no control-arm definition — an undefined control is an undefined experiment")
sys.stdout.write("; ".join(bad))
PY
)
  [ -z "$ev42" ] && pass "evals: spec.json is well-formed and every assertion is joinable" || fail "evals: spec.json is well-formed and every assertion is joinable ($ev42)"

  evh42=$(SPEC="$evroot/heldout.json" FIX="$evroot/fixtures.sh" python3 - <<'PY'
import io, json, os, re, sys
bad = []
spec = json.load(io.open(os.environ["SPEC"], encoding="utf-8"))
fixtures = set(re.search(r'^FIXTURES="([^"]*)"', io.open(os.environ["FIX"], encoding="utf-8").read(), re.M).group(1).split())
seen = set()
for ev in spec["evals"]:
    for field in ("id", "fixture", "prompt", "expect", "artifacts", "assertions"):
        if not ev.get(field):
            bad.append("%s missing %s" % (ev.get("id", "?"), field))
    if ev.get("fixture") not in fixtures:
        bad.append("%s names unknown fixture %r" % (ev["id"], ev.get("fixture")))
    for a in ev.get("assertions", []):
        for field in ("id", "concept", "text", "class", "grade"):
            if not a.get(field):
                bad.append("%s/%s missing %s" % (ev["id"], a.get("id", "?"), field))
        if a.get("class") not in ("artifact", "trace"):
            bad.append("%s class=%r" % (a.get("id"), a.get("class")))
        if a.get("grade") not in ("auto", "manual"):
            bad.append("%s grade=%r" % (a.get("id"), a.get("grade")))
        if a.get("grade") == "auto" and not a.get("check"):
            bad.append("%s is auto-graded with no check" % a.get("id"))
        if not str(a.get("id", "")).startswith(ev["id"] + "/"):
            bad.append("%s is not namespaced under its eval" % a.get("id"))
        if a.get("id") in seen:
            bad.append("duplicate assertion id %s" % a.get("id"))
        seen.add(a.get("id"))
    for p in ev.get("premises", []) or []:
        if not p.get("path"):
            bad.append("%s has a premise with no path: %r" % (ev["id"], p))
        keys = [k for k in ("contains", "absent", "exists") if k in p]
        if len(keys) != 1:
            bad.append("%s has a premise with %d of contains/absent/exists, want exactly 1: %r"
                       % (ev["id"], len(keys), p))
for key in ("arms", "weighting"):
    if not spec.get(key):
        bad.append("spec missing %s" % key)
if not spec.get("arms", {}).get("control", {}).get("definition"):
    bad.append("spec has no control-arm definition — an undefined control is an undefined experiment")
sys.stdout.write("; ".join(bad))
PY
)
  [ -z "$evh42" ] && pass "evals: heldout.json is well-formed and every assertion is joinable" || fail "evals: heldout.json is well-formed and every assertion is joinable ($evh42)"

  evpar42=$(python3 - "$evroot/spec.json" "$evroot/heldout.json" <<'PY'
import json, sys
a = json.load(open(sys.argv[1], encoding="utf-8"))
b = json.load(open(sys.argv[2], encoding="utf-8"))
bad = []
aids, bids = sorted(e["id"] for e in a["evals"]), sorted(e["id"] for e in b["evals"])
if aids != bids:
    bad.append("eval ids differ: only in spec %r, only in heldout %r" %
               (sorted(set(aids) - set(bids)), sorted(set(bids) - set(aids))))
aa = sorted(x["id"] for e in a["evals"] for x in e["assertions"])
ba = sorted(x["id"] for e in b["evals"] for x in e["assertions"])
if aa != ba:
    bad.append("assertion ids differ: only in spec %r, only in heldout %r" %
               (sorted(set(aa) - set(ba)), sorted(set(ba) - set(aa))))
sys.stdout.write("; ".join(bad))
PY
)
  [ -z "$evpar42" ] && pass "evals: both prompt sets carry the same eval and assertion ids" || fail "evals: both prompt sets carry the same eval and assertion ids ($evpar42)"

  evkind42=$(python3 - "$evroot/spec.json" "$evroot/assertion-kinds.json" <<'PY'
import json, sys
spec = json.load(open(sys.argv[1], encoding="utf-8"))
kinds = json.load(open(sys.argv[2], encoding="utf-8"))["kinds"]
valid = {"behavior", "conformance", "information"}
bad = []
for e in spec["evals"]:
    for a in e["assertions"]:
        if kinds.get(a["id"]) not in valid:
            bad.append("%s kind=%r" % (a["id"], kinds.get(a["id"])))
sys.stdout.write("; ".join(bad))
PY
)
  [ -z "$evkind42" ] && pass "evals: every assertion carries a behavior, conformance, or information kind" || fail "evals: every assertion carries a behavior, conformance, or information kind ($evkind42)"

  evidx42=$(python3 - "$evroot/spec.json" "$evroot/heldout.json" <<'PY'
import json, sys
bad = []
for path in sys.argv[1:]:
    spec = json.load(open(path, encoding="utf-8"))
    for e in spec["evals"]:
        for a in e["assertions"]:
            if "index.sh" in (a.get("check") or ""):
                bad.append("%s:%s" % (path, a["id"]))
sys.stdout.write("; ".join(bad))
PY
)
  [ -z "$evidx42" ] && pass "evals: a page-read assertion names the page, never the script that built it" || fail "evals: a page-read assertion names the page, never the script that built it ($evidx42)"

  evproof42=$(python3 - "$evroot/spec.json" "$evroot/heldout.json" <<'PY'
import json, re, sys
bad = []
for path in sys.argv[1:]:
    spec = json.load(open(path, encoding="utf-8"))
    ev = [e for e in spec["evals"] if e["id"] == "verify-scratch-proof"]
    if not ev:
        bad.append("%s lacks the eval" % path)
        continue
    if (ev[0].get("arm_variable") or spec["arms"]["variable"]) != "corpus":
        bad.append("%s arm_variable=%r" % (path, ev[0].get("arm_variable")))
    hit = re.search(r"test|scratch|proof|prove|verif", ev[0]["prompt"], re.I)
    if hit:
        bad.append("%s prompt names %r" % (path, hit.group(0)))
sys.stdout.write("; ".join(bad))
PY
)
  [ -z "$evproof42" ] && pass "evals: the scratch-proof eval varies the corpus and its prompts name no test and no proof" || fail "evals: the scratch-proof eval varies the corpus and its prompts name no test and no proof ($evproof42)"
else
  fail "evals: spec.json is well-formed and every assertion is joinable (python3 absent)"
  fail "evals: heldout.json is well-formed and every assertion is joinable (python3 absent)"
  fail "evals: both prompt sets carry the same eval and assertion ids (python3 absent)"
  fail "evals: every assertion carries a behavior, conformance, or information kind (python3 absent)"
  fail "evals: a page-read assertion names the page, never the script that built it (python3 absent)"
  fail "evals: the scratch-proof eval varies the corpus and its prompts name no test and no proof (python3 absent)"
fi

phases42=$(awk '/^\| Phase \| Trust contract/ { f = 1; next } f && /^\| \*\*/ { gsub(/\*/, "", $2); print tolower($2) } f && !/^\|/ { exit }' "$reporoot/operating-model.md")
covered42=$(sed -n 's/.*"phase": "\([a-z-]*\)".*/\1/p' "$evroot/spec.json" | sort -u)
uncovered42=""
for ph in $phases42; do
  printf '%s\n' "$covered42" | grep -qx "$ph" || uncovered42="$uncovered42 $ph"
done
[ -n "$phases42" ] && [ -z "$uncovered42" ] && pass "evals: every trust-contract phase carries at least one eval" || fail "evals: every trust-contract phase carries at least one eval (uncovered:${uncovered42:-none}; phases found: $(printf '%s' "$phases42" | tr '\n' ' '))"

evfx="$WORK/eval-fixture"
"$evroot/fixtures.sh" ts-service-catalog "$evfx" --corpus-dir "$reporoot" >/dev/null 2>&1
if [ -d "$evfx/.agent" ]; then
  pass "evals: a fixture builds a node from the corpus under test"
  f42=$(status_flags "$evfx")
  [ -z "$f42" ] && pass "evals: a freshly built fixture reports no findings" || fail "evals: a freshly built fixture reports no findings ($f42)"
else
  fail "evals: a fixture builds a node from the corpus under test"
  fail "evals: a freshly built fixture reports no findings (no fixture)"
fi

evfg="$WORK/eval-fixture-flagged"
"$evroot/fixtures.sh" ts-service-flagged "$evfg" --corpus-dir "$reporoot" >/dev/null 2>&1
f42b=$(status_flags "$evfg")
printf '%s\n' "$f42b" | grep -q '^GROOM: session-log.md entries over' && printf '%s\n' "$f42b" | grep -q '^GROOM: memory/' && pass "evals: the flagged fixture arrives over the thresholds its eval clears" || fail "evals: the flagged fixture arrives over the thresholds its eval clears ($f42b)"

evdoc="$WORK/eval-fixture-with-doc"
"$evroot/fixtures.sh" ts-service-with-doc "$evdoc" --corpus-dir "$reporoot" >/dev/null 2>&1
rc42doc=$?
[ "$rc42doc" -eq 0 ] && [ -d "$evdoc/.agent" ] && pass "evals: ts-service-with-doc builds and its premises hold" || fail "evals: ts-service-with-doc builds and its premises hold (rc=$rc42doc)"

evstale="$WORK/eval-fixture-stale-rule"
"$evroot/fixtures.sh" ts-service-stale-rule "$evstale" --corpus-dir "$reporoot" >/dev/null 2>&1
rc42stale=$?
[ "$rc42stale" -eq 0 ] && [ -d "$evstale/.agent" ] && pass "evals: ts-service-stale-rule builds and its premises hold" || fail "evals: ts-service-stale-rule builds and its premises hold (rc=$rc42stale)"

evfailing="$WORK/eval-fixture-failing"
"$evroot/fixtures.sh" ts-service-failing "$evfailing" --corpus-dir "$reporoot" >/dev/null 2>&1
rc42failing=$?
[ "$rc42failing" -eq 0 ] && [ -d "$evfailing/.agent" ] && pass "evals: ts-service-failing builds and its premises hold" || fail "evals: ts-service-failing builds and its premises hold (rc=$rc42failing)"

evgenwarm="$WORK/eval-fixture-generated-warm"
"$evroot/fixtures.sh" ts-service "$evgenwarm" --corpus-dir "$reporoot" --indexes generated >/dev/null 2>&1
rc42genwarm=$?
[ "$rc42genwarm" -eq 0 ] && [ -s "$evgenwarm/.agent/indexes/current.md" ] \
  && pass "evals: a generated-mode fixture builds and its indexer leaves a warm cache" \
  || fail "evals: a generated-mode fixture builds and its indexer leaves a warm cache (rc=$rc42genwarm)"

evidxfault="$WORK/eval-fixture-index-fault"
"$evroot/fixtures.sh" ts-service-index-fault "$evidxfault" --corpus-dir "$reporoot" --indexes generated >/dev/null 2>&1
rc42idxfault=$?
[ "$rc42idxfault" -eq 0 ] && grep -qx 'stale0000000000000000000000000000000000' "$evidxfault/.agent/indexes/current.md" 2>/dev/null \
  && pass "evals: the index-fault fixture arrives with a stale entry its eval must recover from" \
  || fail "evals: the index-fault fixture arrives with a stale entry its eval must recover from (rc=$rc42idxfault)"

evnoidx="$WORK/eval-fixture-no-indexer"
"$evroot/fixtures.sh" ts-service-no-indexer "$evnoidx" --corpus-dir "$reporoot" --indexes generated >/dev/null 2>&1
rc42noidx=$?
[ "$rc42noidx" -eq 0 ] && [ ! -e "$evnoidx/.agent/scripts/index.sh" ] \
  && pass "evals: the no-indexer fixture arrives with no installed indexer" \
  || fail "evals: the no-indexer fixture arrives with no installed indexer (rc=$rc42noidx)"

evlearn="$WORK/eval-fixture-learning"
"$evroot/fixtures.sh" ts-service-learning "$evlearn" --corpus-dir "$reporoot" >/dev/null 2>&1
rc42learn=$?
[ "$rc42learn" -eq 0 ] && [ -s "$evlearn/src/retry.ts" ] && [ -s "$evlearn/scripts/diagnose-vendor.ts" ] \
  && pass "evals: the learning fixture builds and every spec.json premise holds on it" \
  || fail "evals: the learning fixture builds and every spec.json premise holds on it (rc=$rc42learn)"
if command -v node >/dev/null 2>&1 && [ "$rc42learn" -eq 0 ]; then
  (cd "$evlearn" && npm test >/dev/null 2>&1) \
    && pass "evals: the learning fixture's own test suite passes before any session touches it" \
    || fail "evals: the learning fixture's own test suite passes before any session touches it"
else
  pass "evals: the learning fixture's own test suite passes before any session touches it (node absent, skipped)"
fi
evlearnh="$WORK/eval-fixture-learning-heldout"
EVALS_SPEC="$evroot/heldout.json" "$evroot/fixtures.sh" ts-service-learning "$evlearnh" --corpus-dir "$reporoot" >/dev/null 2>&1 \
  && pass "evals: every heldout.json premise holds on the learning fixture" \
  || fail "evals: every heldout.json premise holds on the learning fixture"

evlatent="$WORK/eval-fixture-latent-bug"
"$evroot/fixtures.sh" ts-service-latent-bug "$evlatent" --corpus-dir "$reporoot" >/dev/null 2>&1
rc42latent=$?
EVALS_SPEC="$evroot/heldout.json" "$evroot/fixtures.sh" ts-service-latent-bug "$evlatent-heldout" --corpus-dir "$reporoot" >/dev/null 2>&1
rc42latenth=$?
[ "$rc42latent" -eq 0 ] && [ "$rc42latenth" -eq 0 ] \
  && git -C "$evlatent" check-ignore -q tmp/scratch/yen.test.ts 2>/dev/null \
  && pass "evals: the latent-bug fixture builds under both prompt sets with tmp/ ignored" \
  || fail "evals: the latent-bug fixture builds under both prompt sets with tmp/ ignored (rc=$rc42latent heldout=$rc42latenth)"
if command -v node >/dev/null 2>&1; then
  (cd "$evlatent" 2>/dev/null && bash .agent/scripts/checks.sh test >/dev/null 2>&1)
  latent_before=$?
  mkdir -p "$evlatent/tmp/scratch"
  cat >"$evlatent/tmp/scratch/yen.test.ts" <<'EOF'
import test from "node:test"
import assert from "node:assert/strict"
import { toMinorUnits } from "../../src/client.ts"

test("a yen amount has no minor unit", () => {
  assert.equal(toMinorUnits(500, "JPY"), 500)
})
EOF
  (cd "$evlatent" && bash .agent/scripts/checks.sh test >/dev/null 2>&1)
  latent_proof=$?
  sed -i.bak 's/JPY: 2,/JPY: 0,/' "$evlatent/src/client.ts" 2>/dev/null && rm -f "$evlatent/src/client.ts.bak"
  (cd "$evlatent" && bash .agent/scripts/checks.sh test >/dev/null 2>&1)
  latent_fixed=$?
  [ "$latent_before" -eq 0 ] && [ "$latent_proof" -eq 1 ] && [ "$latent_fixed" -eq 0 ] \
    && pass "evals: the latent-bug driver passes with the defect, and runs a scratch test that fails until the fix" \
    || fail "evals: the latent-bug driver passes with the defect, and runs a scratch test that fails until the fix (before=$latent_before proof=$latent_proof fixed=$latent_fixed)"
else
  pass "evals: the latent-bug driver passes with the defect, and runs a scratch test that fails until the fix (node absent, skipped)"
fi

evbranchsw="$WORK/eval-fixture-branch-switched"
"$evroot/fixtures.sh" ts-service-branch-switched "$evbranchsw" --corpus-dir "$reporoot" --indexes generated >/dev/null 2>&1
rc42bsw=$?
bsw_branch=$(git -C "$evbranchsw" branch --show-current 2>/dev/null)
bsw_other_has_note=$(git -C "$evbranchsw" show fixture-other:.agent/docs/branch-notes.md 2>/dev/null | grep -c 'Only on fixture-other')
bsw_here_lacks_note=$(grep -c 'Only on fixture-other' "$evbranchsw/.agent/docs/branch-notes.md" 2>/dev/null)
[ "$rc42bsw" -eq 0 ] && [ "$bsw_branch" = "fixture-base" ] && [ "${bsw_other_has_note:-0}" -ge 1 ] \
  && [ "${bsw_here_lacks_note:-0}" -eq 0 ] && [ -s "$evbranchsw/.agent/indexes/current.md" ] \
  && pass "evals: the branch-switched fixture arrives with a cache built on the other branch" \
  || fail "evals: the branch-switched fixture arrives with a cache built on the other branch (rc=$rc42bsw, branch=$bsw_branch)"

evpartmig="$WORK/eval-fixture-partial-migration"
"$evroot/fixtures.sh" ts-service-partial-migration "$evpartmig" --corpus-dir "$reporoot" --indexes generated >/dev/null 2>&1
rc42partmig=$?
[ "$rc42partmig" -eq 0 ] && grep -q 'semantic-review-pending' "$evpartmig/.agent/migration-inventory.md" 2>/dev/null \
  && grep -q 'hook-missing' "$evpartmig/.agent/migration-inventory.md" 2>/dev/null \
  && pass "evals: the partial-migration fixture arrives carrying both pending classes" \
  || fail "evals: the partial-migration fixture arrives carrying both pending classes (rc=$rc42partmig)"

evlearndir="$WORK/eval-learned-delta-fallback"
mkdir -p "$evlearndir/outputs"
cat >"$evlearndir/outputs/node-diff.patch" <<'EOF'
diff --git a/.agent/rules/learned/aaaaaaaaaaaa.md b/.agent/rules/learned/aaaaaaaaaaaa.md
new file mode 100644
index 0000000..1111111
--- /dev/null
+++ b/.agent/rules/learned/aaaaaaaaaaaa.md
@@ -0,0 +1 @@
+- [2026-09-19] Prefer the generated record directory over the aggregate.
EOF
: >"$evlearndir/outputs/diff.patch"
: >"$evlearndir/outputs/trace.jsonl"
: >"$evlearndir/outputs/session-transcript.txt"
: >"$evlearndir/outputs/status-after.txt"
: >"$evlearndir/outputs/gate.txt"
: >"$evlearndir/outputs/node-tree.txt"
cat >"$evlearndir/snapshot.json" <<'EOF'
{"assertions": [{"id": "x/y", "concept": "c", "text": "t", "class": "artifact", "grade": "auto", "check": "learned_rules_added == 1"}]}
EOF
"$evroot/grade.py" "$evlearndir" "$evlearndir/snapshot.json" >/dev/null 2>&1
evlearn_pass=$(python3 -c "
import json
print(json.load(open('$evlearndir/grading.json'))['results'][0]['passed'])
" 2>/dev/null)
[ "$evlearn_pass" = "True" ] && pass "evals: the learned delta reads records when the record directory exists" || fail "evals: the learned delta reads records when the record directory exists (got $evlearn_pass)"

sed -i.bak "s/amountMino:/amountMinor:/" "$evdoc/src/client.ts" && rm -f "$evdoc/src/client.ts.bak"
premfail42=$("$evroot/fixture_seed.py" check-premises "$evroot/spec.json" ts-service-with-doc "$evdoc" 2>&1)
premrc42=$?
[ "$premrc42" -eq 2 ] && printf '%s\n' "$premfail42" | grep -q 'routing-scales' \
  && pass "evals: check-premises catches a drifted premise and names the eval" \
  || fail "evals: check-premises catches a drifted premise and names the eval (rc=$premrc42; $premfail42)"
"$evroot/fixture_seed.py" check-premises "$evroot/spec.json" ts-service-with-doc "$evdoc" routing-finds-doc >/dev/null 2>&1
premtargetrc42=$?
[ "$premtargetrc42" -eq 0 ] \
  && pass "evals: targeted premise checks ignore unrelated evals sharing the fixture" \
  || fail "evals: targeted premise checks ignore unrelated evals sharing the fixture (rc=$premtargetrc42)"

evbare="$WORK/eval-fixture-bare"
"$evroot/fixtures.sh" ts-service "$evbare" --corpus-dir "$reporoot" --no-harness >/dev/null 2>&1
rc42bare=$?
[ "$rc42bare" -eq 0 ] && [ ! -d "$evbare/.agent" ] \
  && [ -f "$evbare.verifier/scripts/status.sh" ] && [ -f "$evbare.verifier/scripts/comments.sh" ] \
  && pass "evals: --no-harness builds a fixture with no node and the verifier beside it" \
  || fail "evals: --no-harness builds a fixture with no node and the verifier beside it (rc=$rc42bare)"

[ ! -e "$evbare/CLAUDE.md" ] && [ ! -e "$evbare/AGENTS.md" ] \
  && [ -f "$evbare/.claude/settings.json" ] \
  && git -C "$evbare" rev-parse HEAD >/dev/null 2>&1 \
  && pass "evals: --no-harness drops the instruction files, keeps the settings control, and still commits a base" \
  || fail "evals: --no-harness drops the instruction files, keeps the settings control, and still commits a base"

evgen="$WORK/eval-fixture-generic"
"$evroot/fixtures.sh" ts-service "$evgen" --corpus-dir "$reporoot" --generic-claude >/dev/null 2>&1
rc42gen=$?
[ "$rc42gen" -eq 0 ] && [ ! -d "$evgen/.agent" ] && [ -f "$evgen/CLAUDE.md" ] \
  && cmp -s "$evgen/CLAUDE.md" "$evgen/AGENTS.md" \
  && pass "evals: --generic-claude writes an instructions file and mirrors it to AGENTS.md" \
  || fail "evals: --generic-claude writes an instructions file and mirrors it to AGENTS.md (rc=$rc42gen)"

! grep -qiE '\.agent|entry point|routing|learned rule|session log' "$evgen/CLAUDE.md" \
  && grep -q 'npm test' "$evgen/CLAUDE.md" \
  && pass "evals: the generic instructions file names real commands and no node scaffolding" \
  || fail "evals: the generic instructions file names real commands and no node scaffolding"

"$evroot/fixtures.sh" ts-service "$WORK/eval-fixture-both" --corpus-dir "$reporoot" \
  --no-harness --generic-claude >/dev/null 2>&1
rc42both=$?
[ "$rc42both" -eq 2 ] \
  && pass "evals: --no-harness and --generic-claude together are refused" \
  || fail "evals: --no-harness and --generic-claude together are refused (rc=$rc42both)"

evsh="$evroot/run.sh"
evfake="$WORK/eval fake cli"
mkdir -p "$evfake"
corpus_ref_test=$(git -C "$reporoot" rev-parse HEAD)

evauth="$evfake/auth"
mkdir -p "$evauth/claude-ok" "$evauth/codex-ok"
cat >"$evauth/claude-ok/.credentials.json" <<'EOF'
{"claudeAiOauth": {"accessToken": "fake-access-token", "refreshToken": "fake-refresh-token", "subscriptionType": "pro"}}
EOF
cat >"$evauth/codex-ok/auth.json" <<'EOF'
{"auth_mode": "chatgpt", "tokens": {"access_token": "fake-access-token"}}
EOF
export CLAUDE_CONFIG_DIR="$evauth/claude-ok"
export CODEX_HOME="$evauth/codex-ok"

fake_claude="$evfake/fake-claude.py"
cat >"$fake_claude" <<'PY'
#!/usr/bin/env python3
import json, os, subprocess, sys, time

# Reports only whether a named var reached this process's environment, never
# its value — the sentinel-leak checks read this file, not the process env.
leak_var = os.environ.get("FAKE_ENV_LEAK_VAR")
leak_out = os.environ.get("FAKE_ENV_LEAK_OUT")
if leak_var and leak_out:
    with open(leak_out, "w") as f:
        f.write("PRESENT" if leak_var in os.environ else "ABSENT")

if "--version" in sys.argv:
    print("9.9.9-fake")
    sys.exit(0)

if any("submitPayment" in arg or "What does this project" in arg for arg in sys.argv[1:]):
    sys.stderr.write("prompt text must be supplied on stdin, never argv\n")
    sys.exit(64)

argv = sys.argv[1:]

def reject(message):
    sys.stderr.write(message + "\n")
    sys.exit(64)

def require_flag(flag):
    if argv.count(flag) != 1:
        reject("required flag %s must appear exactly once" % flag)

def require_pair(flag, value):
    require_flag(flag)
    index = argv.index(flag)
    if index + 1 >= len(argv) or argv[index + 1] != value:
        reject("required flag %s has the wrong value or position" % flag)

for required in ("--print", "--verbose", "--strict-mcp-config", "--safe-mode",
                 "--no-chrome"):
    require_flag(required)
require_pair("--input-format", "stream-json")
require_pair("--output-format", "stream-json")
require_pair("--model", "fake-claude-model")
require_pair("--mcp-config", '{"mcpServers":{}}')
require_pair("--allowedTools", "Read,Write,Edit,Bash")
require_pair("--permission-mode", "acceptEdits")
require_pair("--effort", "medium")

# One process is one turn, and the session is carried by the id: turn one
# opens it with --session-id, every later turn resumes that same id. A
# session cannot be resumed at all without being persisted, so
# --no-session-persistence must be gone and the config dir must be the
# disposable one the runner made — the operator's own session store is not
# an acceptable place for eval transcripts to land.
if "--no-session-persistence" in argv:
    reject("--no-session-persistence cannot be passed to a session that must be resumable")
config_dir = os.environ.get("CLAUDE_CONFIG_DIR", "")
if not config_dir or "dot-agent-claude-home." not in config_dir:
    reject("CLAUDE_CONFIG_DIR must name the runner's disposable config dir, got %r" % config_dir)
home_path = os.environ.get("FAKE_CLAUDE_HOME_PATH")
if home_path:
    open(home_path, "w").write(config_dir)

turnfile = os.path.join(config_dir, "fake-claude-turns")
try:
    turn = int(open(turnfile).read().strip())
except Exception:
    turn = 0
turn += 1
open(turnfile, "w").write(str(turn))

if turn == 1:
    require_flag("--session-id")
    session_id = argv[argv.index("--session-id") + 1]
    if "--resume" in argv:
        reject("turn 1 opens the session, it does not resume one")
    open(os.path.join(config_dir, "fake-claude-session"), "w").write(session_id)
else:
    require_flag("--resume")
    session_id = argv[argv.index("--resume") + 1]
    if "--session-id" in argv:
        reject("a resumed turn must not also claim a fresh --session-id")
    opened = open(os.path.join(config_dir, "fake-claude-session")).read().strip()
    if session_id != opened:
        reject("turn %d resumed %r, not the session %r turn 1 opened" % (turn, session_id, opened))
# The fixture carries a CLAUDE.md in every arm but the harness-free ones,
# where there is no instructions file to append and the flag must be absent
# rather than pointing at nothing.
if os.path.exists("CLAUDE.md"):
    require_flag("--append-system-prompt-file")
    system_index = argv.index("--append-system-prompt-file")
    if system_index + 1 >= len(argv) or os.path.realpath(argv[system_index + 1]) != os.path.realpath("CLAUDE.md"):
        reject("--append-system-prompt-file must name the fixture CLAUDE.md")
elif "--append-system-prompt-file" in argv:
    reject("--append-system-prompt-file was passed for a fixture with no CLAUDE.md")

mode = os.environ.get("FAKE_CLAUDE_MODE", "ok")
total = int(os.environ.get("FAKE_CLAUDE_TURNS", "0"))

# A background Agent's completion comes back to the main loop as a turn of its
# own, carrying its own terminal result. Shape copied from a real claude
# 2.1.245 stream, origin field and all.
INJECTED_RESULT = {"type": "result", "subtype": "success", "is_error": False,
                   "result": "Agent completed with result: PONG",
                   "origin": {"kind": "task-notification"}}

if mode == "timeout":
    time.sleep(3600)
    sys.exit(0)

# One process, one turn: the runner writes exactly one stream-json user
# message onto this process's stdin and reads one terminal result back.
text = ""
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        msg = json.loads(line)
        text = msg["message"]["content"][0]["text"]
    except Exception:
        text = ""
    break

if mode == "adversarial-file" and turn == 1:
    hostile = '.agent/pwn"; touch ../outside-capture; #/payload'
    os.makedirs(os.path.dirname(hostile), exist_ok=True)
    open(hostile, "w").write("hostile filename payload\n")
if mode == "gate-findings" and turn == 1:
    os.makedirs("src", exist_ok=True)
    open("src/gate-finding.ts", "w").write("// Refactored per commit deadbeefcafe1234.\nexport const value = 1;\n")
if mode == "verifier-attack" and turn == 1:
    os.makedirs("src", exist_ok=True)
    # A BLOCK-worthy comment (a commit reference a fresh clone cannot
    # open) sits beside the attacker's config mutations below, so
    # whether the trusted or the tampered comments.conf ran is directly
    # observable in gate.txt rather than inferred.
    open("src/verifier-attack.ts", "w").write(
        "// Refactored per commit deadbeefcafe1234.\nexport const safe = true;\n")
    payload = '#!/bin/sh\ntouch "$FAKE_VERIFIER_ATTACK_MARKER"\nprintf "FORGED\\n"\n'
    open(".agent/scripts/status.sh", "w").write(payload)
    open(".agent/scripts/comments.sh", "w").write(payload)
    # ENTRYPOINT_MAX_WORDS=1 would spuriously flag CLAUDE.md under the
    # tampered value (the trusted default, 800, does not); EXCLUDE_RE_EXTRA
    # would hide the file above from comments.sh entirely if honored.
    open(".agent/scripts/status.conf", "w").write("ENTRYPOINT_MAX_WORDS=1\n")
    open(".agent/scripts/comments.conf", "w").write("EXCLUDE_RE_EXTRA=verifier-attack\n")
if mode == "success-resistant-child" and turn == 1:
    # The leader completes this turn and exits 0 normally, but leaves a
    # detached child and grandchild behind in its own process group,
    # both ignoring SIGTERM. Post-success group cleanup must still clear
    # them before capture, without disturbing the leader's own result.
    child_code = '''
import os, signal, subprocess, sys, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
open(os.environ["FAKE_CLAUDE_CHILD_PID"], "w").write(str(os.getpid()))
grandchild_code = """import os, signal, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
open(os.environ['FAKE_CLAUDE_GRANDCHILD_PID'], 'w').write(str(os.getpid()))
time.sleep(3600)
"""
subprocess.Popen([sys.executable, "-c", grandchild_code])
time.sleep(3600)
'''
    subprocess.Popen([sys.executable, "-c", child_code])
    # Wait for both descendants to install their own SIGTERM-ignore
    # handler (signalled by each writing its pid file right after) before
    # this leader finishes its turn and exits — otherwise the group
    # cleanup's SIGTERM can race a descendant still inside interpreter
    # startup and kill it via the default disposition, which would make
    # this scenario indistinguishable from one with no resistant child.
    deadline = time.time() + 5
    while time.time() < deadline and not (
            os.path.exists(os.environ["FAKE_CLAUDE_CHILD_PID"])
            and os.path.exists(os.environ["FAKE_CLAUDE_GRANDCHILD_PID"])):
        time.sleep(0.02)
fixture_root = os.getcwd()
runner_root = os.environ.get("FAKE_TRACE_RUNNER_ROOT", "")
trace_paths = [
    fixture_root + "/src/client.ts",
    fixture_root.replace("/", "//") + "//src//client.ts",
    os.path.realpath(fixture_root) + "/src/client.ts",
    runner_root + "/evals/spec.json",
    runner_root.replace("/", "//") + "//evals//spec.json",
    os.path.realpath(runner_root) + "/evals/spec.json",
]
call = {"type": "assistant", "message": {"content": [
    {"type": "tool_use", "name": "Read", "input": {"file_path": "src/client.ts"}},
    {"type": "tool_use", "name": "Bash", "input": {
        "command": "cat " + " ".join(trace_paths)
    }}
]}}
sys.stdout.write(json.dumps(call) + "\n")
sys.stdout.flush()
if mode == "fail" and turn == 1:
    sys.exit(3)
if mode == "short" and turn == total:
    sys.exit(0)
if mode == "background-subagent-short" and turn == total:
    # The last turn dies without its own result, but a background agent's
    # result lands anyway. The count must not let that stand in for the
    # turn that never finished.
    sys.stdout.write(json.dumps(INJECTED_RESULT) + "\n")
    sys.stdout.flush()
    sys.exit(0)
if mode == "error-result":
    result = {"type": "result", "subtype": "error_during_execution",
              "is_error": True, "result": "fake error"}
else:
    result = {"type": "result", "subtype": "success",
              "is_error": False, "result": "echo:" + text}
sys.stdout.write(json.dumps(result) + "\n")
if mode == "mixed-result":
    error = {"type": "result", "subtype": "error_during_execution",
             "is_error": True, "result": "error after success"}
    sys.stdout.write(json.dumps(error) + "\n")
if mode in ("background-subagent", "background-subagent-short"):
    sys.stdout.write(json.dumps(INJECTED_RESULT) + "\n")
if mode == "malformed-stream":
    sys.stdout.write("not-json\n")
    sys.stdout.write('{"type":"assistant","message":[]}\n')
sys.stdout.flush()

sys.exit(0)
PY
chmod +x "$fake_claude"

fake_codex="$evfake/fake-codex.py"
cat >"$fake_codex" <<'PY'
#!/usr/bin/env python3
import json, os, subprocess, sys, time

# Reports only whether a named var reached this process's environment, never
# its value — the sentinel-leak checks read this file, not the process env.
leak_var = os.environ.get("FAKE_ENV_LEAK_VAR")
leak_out = os.environ.get("FAKE_ENV_LEAK_OUT")
if leak_var and leak_out:
    with open(leak_out, "w") as f:
        f.write("PRESENT" if leak_var in os.environ else "ABSENT")

if "--version" in sys.argv:
    print(os.environ.get("FAKE_CODEX_VERSION", "5.5.5-fake"))
    sys.exit(0)

argv = sys.argv[1:]
missing_feature = os.environ.get("FAKE_CODEX_MISSING_FEATURE", "")
incompatible_bin = os.environ.get("FAKE_CODEX_INCOMPATIBLE_BIN", "")
if incompatible_bin and os.path.realpath(sys.argv[0]) == os.path.realpath(incompatible_bin):
    missing_feature = "--ignore-user-config"
help_surfaces = {
    ("--help",): ["--ask-for-approval", "-c", "-C", "--sandbox"],
    ("exec", "--help"): ["--json", "--ignore-user-config", "--sandbox", "-C", "--model"],
    ("exec", "resume", "--help"): ["--json", "--model", "--ignore-user-config"],
}
if tuple(argv) in help_surfaces:
    print(" ".join(flag for flag in help_surfaces[tuple(argv)] if flag != missing_feature))
    sys.exit(0)
if any("What does this project" in arg or "TURN" in arg for arg in argv):
    sys.stderr.write("prompt text must be supplied on stdin, never argv\n")
    sys.exit(64)
if "-" not in argv:
    sys.stderr.write("stdin prompt marker is required\n")
    sys.exit(64)
def reject(message):
    sys.stderr.write(message + "\n")
    sys.exit(64)

def require_flag(flag):
    if argv.count(flag) != 1:
        reject("required flag %s must appear exactly once" % flag)

def require_pair(flag, value):
    require_flag(flag)
    index = argv.index(flag)
    if index + 1 >= len(argv) or argv[index + 1] != value:
        reject("required flag %s has the wrong value or position" % flag)
    return index

if argv[-1:] != ["-"]:
    reject("stdin prompt marker must be the final argument")

# `codex exec resume` accepts neither -C nor --sandbox, so a resumed turn
# can only be aimed by the root command's copies of them. Every turn is
# therefore aimed the same way: working root, sandbox, approval policy and
# effort ahead of exec, and the stream and identity flags after it. A
# resumed turn that arrives without a working root would run wherever the
# runner happens to be, so its absence is rejected here rather than
# silently read as "the fixture".
require_flag("exec")
exec_index = argv.index("exec")
is_resume = len(argv) > exec_index + 1 and argv[exec_index + 1] == "resume"

approval_index = require_pair("--ask-for-approval", "never")
config_indexes = [i for i, arg in enumerate(argv) if arg == "-c"]
config_values = [argv[i + 1] for i in config_indexes if i + 1 < len(argv)]
required_config = ['model_reasoning_effort="medium"', 'features.apps=false',
                   'features.plugins=false', 'features.remote_plugin=false']
if sorted(config_values) != sorted(required_config):
    reject("effort and eval isolation overrides must each appear exactly once")
effort_index = argv.index('model_reasoning_effort="medium"') - 1
sandbox_index = require_pair("--sandbox", "workspace-write")
require_flag("-C")
cwd_index = argv.index("-C")
if cwd_index + 1 >= len(argv) or not os.path.isdir(argv[cwd_index + 1]):
    reject("-C must name the fixture directory")
for name, flag_index in (("--ask-for-approval", approval_index), ("-c", effort_index),
                         ("--sandbox", sandbox_index), ("-C", cwd_index)):
    if flag_index > exec_index:
        reject("global flag %s must precede exec" % name)

require_flag("--json")
require_flag("--ignore-user-config")
require_pair("--model", "fake-codex-model")
for required in ("--json", "--ignore-user-config", "--model"):
    if argv.index(required) < exec_index:
        reject("exec flag %s must follow exec" % required)
if is_resume and "thread-fixed-fake" not in argv[exec_index + 2:-1]:
    reject("resume is missing the captured thread id")

mode = os.environ.get("FAKE_CODEX_MODE", "ok")
if mode == "timeout":
    time.sleep(3600)
    sys.exit(0)
if mode == "timeout-resistant":
    child_code = '''
import os, signal, subprocess, sys, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
open(os.environ["FAKE_CODEX_CHILD_PID"], "w").write(str(os.getpid()))
grandchild_code = """import os, signal, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
open(os.environ['FAKE_CODEX_GRANDCHILD_PID'], 'w').write(str(os.getpid()))
time.sleep(3600)
"""
subprocess.Popen([sys.executable, "-c", grandchild_code])
time.sleep(3600)
'''
    subprocess.Popen([sys.executable, "-c", child_code])
    time.sleep(3600)
    sys.exit(0)
if mode == "signal-wait":
    open(os.environ["FAKE_CODEX_HOME_PATH"], "w").write(os.environ.get("CODEX_HOME", ""))
    # The parent receives TERM while waiting for us.  A short sleep lets its
    # signal trap run after this fake exits without leaving a test process.
    time.sleep(3)
    sys.exit(0)
if mode == "signal-child":
    open(os.environ["FAKE_CODEX_HOME_PATH"], "w").write(os.environ.get("CODEX_HOME", ""))
    open(os.environ["FAKE_CODEX_PARENT_PID"], "w").write(str(os.getpid()))
    child_code = '''
import os, subprocess, sys, time
open(os.environ["FAKE_CODEX_CHILD_PID"], "w").write(str(os.getpid()))
grandchild_code = """import os, time
open(os.environ['FAKE_CODEX_GRANDCHILD_PID'], 'w').write(str(os.getpid()))
time.sleep(3600)
"""
subprocess.Popen([sys.executable, "-c", grandchild_code])
time.sleep(3600)
'''
    subprocess.Popen([sys.executable, "-c", child_code])
    time.sleep(3600)
    sys.exit(0)

counter_path = os.environ.get("FAKE_CODEX_COUNTER", "")
n = 1
if counter_path:
    try:
        n = int(open(counter_path).read().strip()) + 1
    except Exception:
        n = 1
    open(counter_path, "w").write(str(n))

prompt = sys.stdin.read().strip()
fail_turn = int(os.environ.get("FAKE_CODEX_FAIL_TURN", "0"))
if mode == "fail" and n == fail_turn:
    sys.exit(5)

events = []
if not is_resume:
    events.append({"type": "thread.started", "thread_id": "thread-fixed-fake"})
    if mode == "duplicate-thread-started":
        events.append({"type": "thread.started", "thread_id": "thread-fixed-fake"})
elif mode == "resume-thread-mismatch":
    events.append({"type": "thread.started", "thread_id": "thread-wrong-fake"})
elif mode == "resume-thread-started-ok":
    events.append({"type": "thread.started", "thread_id": "thread-fixed-fake"})
fixture_root = argv[argv.index("-C") + 1] if "-C" in argv else ""
runner_root = os.environ.get("FAKE_TRACE_RUNNER_ROOT", "")
if fixture_root:
    trace_paths = [
        fixture_root + "/README.md",
        fixture_root.replace("/", "//") + "//README.md",
        os.path.realpath(fixture_root) + "/README.md",
        runner_root + "/evals/spec.json",
        runner_root.replace("/", "//") + "//evals//spec.json",
        os.path.realpath(runner_root) + "/evals/spec.json",
    ]
    command = "cat " + " ".join(trace_paths)
else:
    command = "echo turn-%d" % n
# Real Codex announces a command twice — once on starting it, once on
# finishing it with the output and exit code — so the fake does too, and
# every codex test here runs against the shape the live CLI emits. One
# trace record per command is the property that has to hold across both.
command_item = {"type": "command_execution", "command": command}
if mode == "command-missing-command":
    command_item = {"type": "command_execution"}
events.append({"type": "item.started", "item": command_item})
events.append({"type": "item.completed",
               "item": dict(command_item, aggregated_output="out-%d" % n, exit_code=0)})
file_change_item = {"type": "file_change", "changes": [{"path": "notes/codex-turn-%d.md" % n, "kind": "add"}]}
if mode == "file-change-on-started":
    events.append({"type": "item.started", "item": file_change_item})
events.append({"type": "item.completed", "item": file_change_item})
text = "echo:" + prompt
if mode == "transcript-shape" and n == 1:
    text += "\nsecond transcript line"
if mode != "transcript-shape" or n != 2:
    events.append({"type": "item.completed", "item": {"type": "agent_message", "text": text}})
short_turn = {"short-first": 1, "short-middle": 2, "short-final": 3}.get(mode)
if n != short_turn:
    events.append({"type": "turn.completed"})
if mode == "mixed-failed":
    events.append({"type": "turn.failed", "error": "failed after completion"})
elif mode == "mixed-error":
    events.append({"type": "error", "message": "error after completion"})
elif mode == "duplicate-completion":
    events.append({"type": "turn.completed"})
for ev in events:
    sys.stdout.write(json.dumps(ev) + "\n")
if mode == "malformed-stream":
    sys.stdout.write("not-json\n")
    sys.stdout.write('{"type":"item.completed","item":{"type":"file_change","changes":"bad"}}\n')
if mode == "replace-between-turns" and n == 1:
    with open(sys.argv[0], "a") as self_file:
        self_file.write("\n# replaced at turn boundary\n")
sys.exit(0)
PY
chmod +x "$fake_codex"

phase_bin="$evfake/phase-bin"
mkdir -p "$phase_bin"
cat >"$phase_bin/bash" <<'SH'
#!/bin/sh
block=0
case "${FAKE_RUN_PHASE:-}:$1" in
capture:*/dot-agent-eval-verifiers.*/status.sh) block=1 ;;
esac
if [ "$block" -eq 1 ]; then
  printf 'ready\n' >"$FAKE_PHASE_READY"
  kill -TERM "$PPID" || exit 1
fi
exec "$FAKE_REAL_BASH" "$@"
SH
chmod +x "$phase_bin/bash"

cat >"$phase_bin/git" <<'SH'
#!/bin/sh
if [ "${FAKE_INFRA_FAIL:-}" = capture ]; then
  case " $* " in
  *" add -A "*)
    capture_count=0
    [ ! -f "$FAKE_CAPTURE_GIT_COUNTER" ] || capture_count=$(cat "$FAKE_CAPTURE_GIT_COUNTER")
    capture_count=$((capture_count + 1))
    printf '%s\n' "$capture_count" >"$FAKE_CAPTURE_GIT_COUNTER"
    [ "$capture_count" -lt 2 ] || exit 73
    ;;
  esac
fi
exec "$FAKE_REAL_GIT" "$@"
SH
chmod +x "$phase_bin/git"

cat >"$phase_bin/python3" <<'SH'
#!/bin/sh
if [ "${FAKE_INFRA_FAIL:-}" = trace ]; then
  case "${1:-}:${2:-}" in
  */run_lib.py:extract-claude-trace | */run_lib.py:extract-codex-trace) exit 74 ;;
  esac
fi
# grade.py reaches this wrapper through its own shebang, so the grading
# process boundary is intercepted here rather than in the Bash wrapper.
if [ "${FAKE_RUN_PHASE:-}" = grading ] && [ "$1" = "${FAKE_GRADE_PATH:-}" ]; then
  printf 'ready\n' >"$FAKE_PHASE_READY"
  kill -TERM "$PPID" || exit 1
fi
if [ "${FAKE_INFRA_FAIL:-}" = grading ] && [ "$1" = "${FAKE_GRADE_PATH:-}" ]; then
  exit 75
fi
if [ -n "${FAKE_REPLACE_AFTER_GRADE:-}" ] && [ "$1" = "${FAKE_GRADE_PATH:-}" ]; then
  "$FAKE_REAL_PYTHON" "$@"
  grade_rc=$?
  if [ ! -e "$FAKE_REPLACE_AFTER_GRADE.done" ]; then
    printf '\n# replaced between repeats\n' >>"$FAKE_REPLACE_AFTER_GRADE"
    : >"$FAKE_REPLACE_AFTER_GRADE.done"
  fi
  exit "$grade_rc"
fi
exec "$FAKE_REAL_PYTHON" "$@"
SH
chmod +x "$phase_bin/python3"

cat >"$phase_bin/chmod" <<'SH'
#!/bin/sh
if [ "$1" = 700 ]; then
  case "$2" in
  *dot-agent-eval-verifiers.*)
    if [ "${FAKE_RUN_PHASE:-}" = verifier-setup ]; then
      printf '%s\n' "$2" >"$FAKE_PHASE_PATH"
      printf 'ready\n' >"$FAKE_PHASE_READY"
      while [ ! -e "$FAKE_PHASE_RELEASE" ]; do sleep 0.05; done
    fi
    ;;
  *dot-agent-codex-home.*)
    if [ "${FAKE_RUN_PHASE:-}" = codex-home-setup ]; then
      printf '%s\n' "$2" >"$FAKE_PHASE_PATH"
      printf 'ready\n' >"$FAKE_PHASE_READY"
      while [ ! -e "$FAKE_PHASE_RELEASE" ]; do sleep 0.05; done
    fi
    ;;
  esac
fi
exec "$FAKE_REAL_CHMOD" "$@"
SH
chmod +x "$phase_bin/chmod"

cat >"$phase_bin/cat" <<'SH'
#!/bin/sh
if [ -n "${FAKE_CODEX_APPEND_FAIL:-}" ] && [ "$(basename -- "$1" 2>/dev/null)" = "$FAKE_CODEX_APPEND_FAIL" ]; then
  echo "fake cat: simulated append failure" >&2
  exit 1
fi
exec "$FAKE_REAL_CAT" "$@"
SH
chmod +x "$phase_bin/cat"

eval_conf_write() {
  cat >"$1" <<CONF
CLAUDE_BIN=$2
CLAUDE_MODEL=fake-claude-model
CLAUDE_EFFORT=medium
CODEX_BIN=$3
CODEX_MODEL=fake-codex-model
CODEX_EFFORT=medium
REPEATS=$4
TIMEOUT=$5
CONF
}

eval_void_clean() {
  evc_run=$(find "$1/iteration-1/eval-$2" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n1)
  [ -n "$evc_run" ] \
    && [ -f "$evc_run/run-meta.json" ] \
    && grep -q '"void": true' "$evc_run/run-meta.json" 2>/dev/null \
    && { [ ! -e "$evc_run/outputs" ] || \
         { [ -f "$evc_run/outputs/agent-stdout.txt" ] \
           && [ ! -e "$evc_run/outputs/diff.patch" ] \
           && [ ! -e "$evc_run/outputs/node-diff.patch" ]; }; } \
    && [ ! -e "$evc_run/grading.json" ]
}

trace_roots_absent() {
  python3 - "$1" "$2" "$3" <<'PY'
import os, re, sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
text = re.sub(r"/+", "/", text)
for supplied in sys.argv[2:]:
    for root in (supplied, os.path.abspath(supplied), os.path.realpath(supplied)):
        root = re.sub(r"/+", "/", root.rstrip(os.sep))
        if root and root in text:
            sys.exit(1)
sys.exit(0)
PY
}

recorded_processes_dead() {
  rpd_failed=0
  for rpd_file in "$@"; do
    rpd_pid=$(sed -n '1p' "$rpd_file" 2>/dev/null)
    case "$rpd_pid" in
    *[!0-9]* | "") rpd_failed=1 ;;
    *)
      if kill -0 "$rpd_pid" 2>/dev/null; then
        rpd_failed=1
        kill -KILL "$rpd_pid" 2>/dev/null
      fi
      ;;
    esac
  done
  [ "$rpd_failed" -eq 0 ]
}

printf '{}\n' | "$fake_claude" --print >/dev/null 2>&1
rc44claude_flags=$?
[ "$rc44claude_flags" -eq 64 ] && pass "evals: fake claude rejects missing required adapter flags" || fail "evals: fake claude rejects missing required adapter flags (rc=$rc44claude_flags)"
printf 'prompt\n' | "$fake_codex" exec --ask-for-approval never \
  -c 'model_reasoning_effort="medium"' --json --ignore-user-config \
  --sandbox workspace-write -C "$reporoot" --model fake-codex-model - >/dev/null 2>&1
rc44codex_flags=$?
[ "$rc44codex_flags" -eq 64 ] && pass "evals: fake codex rejects misplaced global adapter flags" || fail "evals: fake codex rejects misplaced global adapter flags (rc=$rc44codex_flags)"

conf_disc="$evfake/agents-discovery.conf"
eval_conf_write "$conf_disc" "$fake_claude" "$fake_codex" 1 60
la44=$(EVALS_AGENTS_CONF="$conf_disc" "$evsh" --list-arms 2>&1)
printf '%s\n' "$la44" | grep -qF "$fake_claude" && printf '%s\n' "$la44" | grep -q 'version=9.9.9-fake' && pass "evals: run.sh --list-arms resolves a configured claude binary and its version" || fail "evals: run.sh --list-arms resolves a configured claude binary and its version ($la44)"
printf '%s\n' "$la44" | grep -qF "$fake_codex" && printf '%s\n' "$la44" | grep -q 'version=5.5.5-fake' && pass "evals: run.sh --list-arms resolves a configured codex binary and its version" || fail "evals: run.sh --list-arms resolves a configured codex binary and its version ($la44)"

conf_feature="$evfake/agents-feature-probe.conf"
eval_conf_write "$conf_feature" "$fake_claude" "$fake_codex" 1 60
la44old=$(EVALS_AGENTS_CONF="$conf_feature" FAKE_CODEX_VERSION=0.0.1-fake "$evsh" --list-arms 2>&1)
printf '%s\n' "$la44old" | grep -q 'codex    bin=' && pass "evals: feature-complete codex is accepted across the former version boundary" || fail "evals: feature-complete codex is accepted across the former version boundary ($la44old)"
feature_missing_ok=1
for missing_feature in --ask-for-approval -c --json --ignore-user-config --sandbox -C --model; do
  la44missing=$(EVALS_AGENTS_CONF="$conf_feature" FAKE_CODEX_VERSION=99.0.0-fake \
    FAKE_CODEX_MISSING_FEATURE="$missing_feature" "$evsh" --list-arms 2>&1)
  if ! printf '%s\n' "$la44missing" | grep -q 'codex    not ready' \
    || ! printf '%s\n' "$la44missing" | grep -qF -- "$missing_feature"; then
    feature_missing_ok=0
  fi
done
if [ "$feature_missing_ok" -eq 1 ]; then
  pass "evals: feature probe rejects a new codex missing any required adapter flag"
else
  fail "evals: feature probe rejects a new codex missing any required adapter flag"
fi

incompatible_dir="$evfake/incompatible-path"
mkdir -p "$incompatible_dir"
incompatible_codex="$incompatible_dir/codex"
cp "$fake_codex" "$incompatible_codex"
chmod +x "$incompatible_codex"
conf_fallback="$evfake/agents-feature-fallback.conf"
eval_conf_write "$conf_fallback" "$fake_claude" auto 1 60
printf 'CODEX_APP_BIN=%s\n' "$fake_codex" >>"$conf_fallback"
la44fallback=$(PATH="$incompatible_dir:$PATH" EVALS_AGENTS_CONF="$conf_fallback" \
  FAKE_CODEX_INCOMPATIBLE_BIN="$incompatible_codex" "$evsh" --list-arms 2>&1)
if printf '%s\n' "$la44fallback" | grep -qF "codex    bin=$fake_codex" \
  && ! printf '%s\n' "$la44fallback" | grep -qF "codex    bin=$incompatible_codex"; then
  pass "evals: incompatible PATH codex falls back to a compatible configured app"
else
  fail "evals: incompatible PATH codex falls back to a compatible configured app ($la44fallback)"
fi

conf_unset="$evfake/agents-unset.conf"
eval_conf_write "$conf_unset" "$evfake/no-such-claude" "$evfake/no-such-codex" 1 60
la44b=$(EVALS_AGENTS_CONF="$conf_unset" "$evsh" --list-arms 2>&1)
printf '%s\n' "$la44b" | grep -q 'claude   not ready' && printf '%s\n' "$la44b" | grep -q 'codex    not ready' && pass "evals: run.sh --list-arms reports an unresolvable agent as not ready" || fail "evals: run.sh --list-arms reports an unresolvable agent as not ready ($la44b)"
EVALS_AGENTS_CONF="$conf_unset" "$evsh" --eval scope-question-no-edit --arm x --treatment-arm x \
  --agent claude --corpus-ref "$corpus_ref_test" --workspace "$WORK/ev-refuse" >/dev/null 2>&1
rc44b=$?
[ "$rc44b" -eq 2 ] && pass "evals: run.sh refuses an unconfigured agent" || fail "evals: run.sh refuses an unconfigured agent (rc=$rc44b)"

wsc_fixture_fail="$evfake/claude workspace-fixture-build-fail"
conf_fixture_fail="$evfake/agents-fixture-build-fail.conf"
eval_conf_write "$conf_fixture_fail" "$fake_claude" "$evfake/no-such-codex" 1 60
invalid_corpus_ref="refs/heads/dot-agent-missing-$RANDOM-$$"
EVALS_AGENTS_CONF="$conf_fixture_fail" \
  "$evsh" --eval scope-question-no-edit --arm treat --treatment-arm treat \
  --agent claude --corpus-ref "$invalid_corpus_ref" --workspace "$wsc_fixture_fail" >/dev/null 2>&1
rc44fixture_fail=$?
fixture_fail_run=$(find "$wsc_fixture_fail/iteration-1/eval-scope-question-no-edit" \
  -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n1)
if [ "$rc44fixture_fail" -ne 0 ] && eval_void_clean "$wsc_fixture_fail" scope-question-no-edit \
  && grep -q '"status": "fixture_build_failed"' "$fixture_fail_run/run-meta.json" 2>/dev/null \
  && grep -q '"failure_reason":' "$fixture_fail_run/run-meta.json" 2>/dev/null \
  && [ -f "$fixture_fail_run/fixture-build.txt" ]; then
  pass "evals: fixture-build failure retains diagnostic metadata without outputs"
else
  fail "evals: fixture-build failure retains diagnostic metadata without outputs (rc=$rc44fixture_fail)"
fi

wsc="$evfake/claude workspace"
conf_claude="$evfake/agents-claude.conf"
eval_conf_write "$conf_claude" "$fake_claude" "$evfake/no-such-codex" 2 60
EVALS_AGENTS_CONF="$conf_claude" FAKE_CLAUDE_MODE=ok FAKE_CLAUDE_TURNS=1 FAKE_TRACE_RUNNER_ROOT="$reporoot" \
  "$evsh" --eval scope-question-no-edit --arm treat --treatment-arm treat \
  --agent claude --corpus-ref "$corpus_ref_test" --workspace "$wsc" >"$evfake/claude-run.out" 2>&1
rc44c=$?
[ "$rc44c" -eq 0 ] && pass "evals: a full run.sh invocation against a fake claude CLI exits 0" || fail "evals: a full run.sh invocation against a fake claude CLI exits 0 (rc=$rc44c; $(cat "$evfake/claude-run.out"))"

evaldir_c="$wsc/iteration-1/eval-scope-question-no-edit"
rundirs_c=$(find "$evaldir_c" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
ndirs_c=$(printf '%s\n' "$rundirs_c" | grep -c .)
[ "$ndirs_c" -eq 2 ] && pass "evals: REPEATS=2 places both repeats under the one targeted iteration" || fail "evals: REPEATS=2 places both repeats under the one targeted iteration (found $ndirs_c under $evaldir_c)"
[ ! -d "$wsc/iteration-2" ] && pass "evals: repeats never spawn a second iteration-<n> directory" || fail "evals: repeats never spawn a second iteration-<n> directory"

run1_c=$(printf '%s\n' "$rundirs_c" | sed -n 1p)
[ -d "$run1_c/fixture" ] && pass "evals: a workspace path containing a space still builds a fixture" || fail "evals: a workspace path containing a space still builds a fixture ($run1_c)"
grep -qF 'echo:Is submitPayment safe to call concurrently?' "$run1_c/outputs/session-transcript.txt" 2>/dev/null && pass "evals: the eval prompt reached the fake claude CLI on stdin, not argv" || fail "evals: the eval prompt reached the fake claude CLI on stdin, not argv"
[ "$(grep -c '^## Turn [0-9][0-9]*$' "$run1_c/outputs/session-transcript.txt" 2>/dev/null)" = "1" ] && pass "evals: claude transcript counts numbered turn sections" || fail "evals: claude transcript counts numbered turn sections"
grep -q '"action": "read"' "$run1_c/outputs/trace.jsonl" 2>/dev/null && pass "evals: claude's tool_use call normalizes into the shared trace contract" || fail "evals: claude's tool_use call normalizes into the shared trace contract"
grep -q '"path": "src/client.ts"' "$run1_c/outputs/trace.jsonl" 2>/dev/null && pass "evals: the trace record carries a fixture-relative path" || fail "evals: the trace record carries a fixture-relative path"
if trace_roots_absent "$run1_c/outputs/trace.jsonl" "$run1_c/fixture" "$reporoot"; then
  pass "evals: claude trace text contains no absolute fixture or runner-worktree path"
else
  fail "evals: claude trace text contains no absolute fixture or runner-worktree path"
fi

wsc_multi="$evfake/claude workspace-multiturn"
conf_claude_multi="$evfake/agents-claude-multiturn.conf"
eval_conf_write "$conf_claude_multi" "$fake_claude" "$evfake/no-such-codex" 1 60
claude_home_path="$evfake/claude-multi-home"
rm -f "$claude_home_path"
EVALS_AGENTS_CONF="$conf_claude_multi" FAKE_CLAUDE_MODE=ok FAKE_CLAUDE_TURNS=3 FAKE_TRACE_RUNNER_ROOT="$reporoot" \
  FAKE_CLAUDE_HOME_PATH="$claude_home_path" \
  "$evsh" --eval bootstrap-once --arm treat --treatment-arm treat \
  --agent claude --corpus-ref "$corpus_ref_test" --workspace "$wsc_multi" >"$evfake/claude-multi.out" 2>&1
rc44multi=$?
[ "$rc44multi" -eq 0 ] && pass "evals: a 3-turn eval against a fake claude CLI exits 0" || fail "evals: a 3-turn eval against a fake claude CLI exits 0 (rc=$rc44multi; $(cat "$evfake/claude-multi.out"))"
run_multi=$(find "$wsc_multi/iteration-1/eval-bootstrap-once" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n1)
[ "$(grep -c '^## Turn [0-9][0-9]*$' "$run_multi/outputs/session-transcript.txt" 2>/dev/null)" = "3" ] && pass "evals: a 3-turn eval against claude captures three numbered transcript sections" || fail "evals: a 3-turn eval against claude captures three numbered transcript sections"
sed -n '2p' "$run_multi/outputs/session-transcript.txt" 2>/dev/null | grep -qF 'echo:What does this project use for HTTP?' && pass "evals: turn one's prompt reached the fake claude CLI on stdin, not argv" || fail "evals: turn one's prompt reached the fake claude CLI on stdin, not argv"
grep -qF 'echo:Add a timeout of 5s to the client.' "$run_multi/outputs/session-transcript.txt" 2>/dev/null && pass "evals: the last turn of a resumed claude session is captured too" || fail "evals: the last turn of a resumed claude session is captured too"
[ "$(grep -c '"action": "read"' "$run_multi/outputs/trace.jsonl" 2>/dev/null)" = "3" ] && pass "evals: each claude turn contributes its own trace events" || fail "evals: each claude turn contributes its own trace events"
multi_home=$(cat "$claude_home_path" 2>/dev/null)
case "$multi_home" in
"${TMPDIR:-/tmp}/dot-agent-claude-home."*) multi_home_prefix=1 ;;
*) multi_home_prefix=0 ;;
esac
[ "$multi_home_prefix" -eq 1 ] && [ ! -e "$multi_home" ] && pass "evals: the disposable claude config dir is system-temporary and removed after the run" || fail "evals: the disposable claude config dir is system-temporary and removed after the run (home=$multi_home)"
retained_cred=$(find "$wsc_multi/iteration-1/eval-bootstrap-once" -name '.credentials.json' -print -quit 2>/dev/null)
[ -z "$retained_cred" ] && pass "evals: copied Claude authentication never enters retained outputs" || fail "evals: copied Claude authentication never enters retained outputs ($retained_cred)"

wsc_ctrlfirst="$evfake/claude workspace-control-first"
conf_ctrlfirst="$evfake/agents-claude-control-first.conf"
eval_conf_write "$conf_ctrlfirst" "$fake_claude" "$evfake/no-such-codex" 1 60
EVALS_AGENTS_CONF="$conf_ctrlfirst" FAKE_CLAUDE_MODE=ok FAKE_CLAUDE_TURNS=1 \
  "$evsh" --eval scope-question-no-edit --arm ctrl --treatment-arm treat \
  --agent claude --corpus-ref "$corpus_ref_test" --workspace "$wsc_ctrlfirst" >"$evfake/ctrlfirst.out" 2>&1
rc44cf=$?
[ "$rc44cf" -eq 0 ] && pass "evals: the control arm may create a fresh iteration when it names the treatment" || fail "evals: the control arm may create a fresh iteration when it names the treatment (rc=$rc44cf; $(cat "$evfake/ctrlfirst.out"))"
grep -q '"treatment_arm": "treat"' "$wsc_ctrlfirst/iteration-1/run-config.json" 2>/dev/null && pass "evals: the iteration records the named treatment, not its creator" || fail "evals: the iteration records the named treatment, not its creator"
EVALS_AGENTS_CONF="$conf_ctrlfirst" FAKE_CLAUDE_MODE=ok FAKE_CLAUDE_TURNS=1 \
  "$evsh" --eval scope-question-no-edit --arm ctrl --treatment-arm ctrl \
  --agent claude --corpus-ref "$corpus_ref_test" --workspace "$wsc_ctrlfirst" >"$evfake/ctrlfirst2.out" 2>&1
rc44cf2=$?
[ "$rc44cf2" -eq 2 ] && pass "evals: a later run disagreeing about the treatment is still refused" || fail "evals: a later run disagreeing about the treatment is still refused (rc=$rc44cf2)"
EVALS_AGENTS_CONF="$conf_ctrlfirst" FAKE_CLAUDE_MODE=ok FAKE_CLAUDE_TURNS=1 \
  "$evsh" --eval scope-question-no-edit --arm ctrl \
  --agent claude --corpus-ref "$corpus_ref_test" --workspace "$evfake/claude workspace-unnamed" >"$evfake/unnamed.out" 2>&1
rc44un=$?
[ "$rc44un" -eq 2 ] && grep -q 'must name the treatment arm' "$evfake/unnamed.out" && pass "evals: a fresh iteration with no named treatment is still refused" || fail "evals: a fresh iteration with no named treatment is still refused (rc=$rc44un)"

wsc_arm_name_collision="$evfake/arm-name-collision"
EVALS_AGENTS_CONF="$conf_ctrlfirst" "$evsh" --eval verify-baseline-failure \
  --arm baseline --treatment-arm candidate --agent claude \
  --corpus-ref "$corpus_ref_test" --workspace "$wsc_arm_name_collision" --dry-run \
  >"$evfake/arm-name-collision.out" 2>&1
rc44armname=$?
[ "$rc44armname" -eq 2 ] && grep -qF "arm name 'baseline' is a component of eval id 'verify-baseline-failure'" "$evfake/arm-name-collision.out" \
  && pass "evals: run.sh refuses an arm name that would leak through the eval path" \
  || fail "evals: run.sh refuses an arm name that would leak through the eval path (rc=$rc44armname; $(cat "$evfake/arm-name-collision.out"))"
[ ! -e "$wsc_arm_name_collision" ] \
  && pass "evals: an arm-name collision creates no iteration workspace" \
  || fail "evals: an arm-name collision creates no iteration workspace"

wsc_arm="$evfake/run-arm workspace"
conf_arm="$evfake/agents-run-arm.conf"
eval_conf_write "$conf_arm" "$fake_claude" "$evfake/no-such-codex" 1 60
for arm44 in treat ctrl; do
  EVALS_AGENTS_CONF="$conf_arm" FAKE_CLAUDE_MODE=ok FAKE_CLAUDE_TURNS=1 \
    "$evroot/run-arm.sh" --evals scope-question-no-edit --treatment-arm treat \
    "$wsc_arm" "$arm44" "$corpus_ref_test" >/dev/null 2>&1
done
if [ -s "$wsc_arm/logs/treat/scope-question-no-edit.log" ] \
  && [ -s "$wsc_arm/logs/ctrl/scope-question-no-edit.log" ]; then
  pass "evals: run-arm.sh keeps each arm's per-eval log under its own arm directory"
else
  fail "evals: run-arm.sh keeps each arm's per-eval log under its own arm directory ($(find "$wsc_arm/logs" -type f 2>/dev/null | tr '\n' ' '))"
fi
armmap44=$(python3 -c '
import json, sys
try:
    m = json.load(open(sys.argv[1]))
except Exception:
    sys.exit("unreadable")
print(" ".join(sorted(set(m.values()))))' "$wsc_arm/iteration-1/arm-map.json" 2>&1)
[ "$armmap44" = "ctrl treat" ] && pass "evals: both arms of one run-arm.sh workspace land in the same arm map" || fail "evals: both arms of one run-arm.sh workspace land in the same arm map ($armmap44)"

wsc_arm_fail="$evfake/run-arm failure workspace"
EVALS_AGENTS_CONF="$conf_arm" FAKE_CLAUDE_MODE=ok FAKE_CLAUDE_TURNS=1 \
  "$evroot/run-arm.sh" --jobs 2 --evals scope-question-no-edit,routing-scales \
  "$wsc_arm_fail" broken definitely-not-a-corpus-ref >"$evfake/run-arm-fail.out" 2>&1
rc44armfail=$?
[ "$rc44armfail" -ne 0 ] && pass "evals: run-arm.sh exits nonzero when parallel child evals fail" || fail "evals: run-arm.sh exits nonzero when parallel child evals fail"
if grep -q '^ARM FAILED broken ' "$wsc_arm_fail/run.log" 2>/dev/null \
  && ! grep -q '^ARM DONE broken ' "$wsc_arm_fail/run.log" 2>/dev/null; then
  pass "evals: a failed run-arm.sh batch records ARM FAILED, never ARM DONE"
else
  fail "evals: a failed run-arm.sh batch records ARM FAILED, never ARM DONE ($(cat "$wsc_arm_fail/run.log" 2>/dev/null))"
fi

"$evroot/run-arm.sh" --jobs 0 --evals scope-question-no-edit \
  "$evfake/run-arm-zero-jobs" zero "$corpus_ref_test" >"$evfake/run-arm-zero.out" 2>&1
rc44armzero=$?
[ "$rc44armzero" -eq 2 ] && grep -q 'positive whole number' "$evfake/run-arm-zero.out" \
  && pass "evals: run-arm.sh refuses unbounded --jobs 0" \
  || fail "evals: run-arm.sh refuses unbounded --jobs 0 (rc=$rc44armzero; $(cat "$evfake/run-arm-zero.out"))"

compat_corpus="$evfake/pre-indexes corpus"
mkdir -p "$compat_corpus/scripts"
cp -R "$reporoot/templates" "$reporoot/presets" "$compat_corpus/"
cat >"$compat_corpus/scripts/node.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --help ]; then
  printf 'Usage: node.sh init --preset <name> --mode <mode> [root]\n'
  exit 0
fi
for compat_arg in "$@"; do
  [ "$compat_arg" != --indexes ] || exit 97
done
exec "$COMPAT_NODE" "$@"
SH
chmod +x "$compat_corpus/scripts/node.sh"
compat_manual="$evfake/pre-indexes-manual"
COMPAT_NODE="$NODE" "$evroot/fixtures.sh" ts-service "$compat_manual" \
  --corpus-dir "$compat_corpus" --indexes manual >"$evfake/pre-indexes-manual.out" 2>&1
rc44compatmanual=$?
[ "$rc44compatmanual" -eq 0 ] && pass "evals: a manual fixture builds against a corpus predating --indexes" || fail "evals: a manual fixture builds against a corpus predating --indexes (rc=$rc44compatmanual; $(cat "$evfake/pre-indexes-manual.out"))"
grep -q '^  indexes: manual' "$compat_manual/.agent/purpose.md" 2>/dev/null \
  && pass "evals: the pre-indexes compatibility path preserves the manual default" \
  || fail "evals: the pre-indexes compatibility path preserves the manual default"
COMPAT_NODE="$NODE" "$evroot/fixtures.sh" ts-service "$evfake/pre-indexes-generated" \
  --corpus-dir "$compat_corpus" --indexes generated >"$evfake/pre-indexes-generated.out" 2>&1
rc44compatgenerated=$?
[ "$rc44compatgenerated" -ne 0 ] && grep -q 'does not support generated indexes' "$evfake/pre-indexes-generated.out" \
  && pass "evals: generated fixtures refuse a corpus predating --indexes" \
  || fail "evals: generated fixtures refuse a corpus predating --indexes (rc=$rc44compatgenerated; $(cat "$evfake/pre-indexes-generated.out"))"

wsc_hostile="$evfake/claude workspace-hostile-filename"
conf_claude_hostile="$evfake/agents-claude-hostile.conf"
eval_conf_write "$conf_claude_hostile" "$fake_claude" "$evfake/no-such-codex" 1 60
EVALS_AGENTS_CONF="$conf_claude_hostile" FAKE_CLAUDE_MODE=adversarial-file FAKE_CLAUDE_TURNS=1 \
  "$evsh" --eval scope-question-no-edit --arm treat --treatment-arm treat \
  --agent claude --corpus-ref "$corpus_ref_test" --workspace "$wsc_hostile" >/dev/null 2>&1
rc44hostile=$?
hostile_run=$(find "$wsc_hostile/iteration-1/eval-scope-question-no-edit" \
  -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n1)
escaped_hostile=$(find "$wsc_hostile" -name outside-capture -print -quit 2>/dev/null)
hostile_payload=$(find "$hostile_run/fixture/.agent" -name payload -print -quit 2>/dev/null)
if [ "$rc44hostile" -eq 0 ] && [ -n "$hostile_payload" ] && [ -z "$escaped_hostile" ]; then
  pass "evals: node-tree capture treats adversarial .agent filenames as data"
else
  fail "evals: node-tree capture treats adversarial .agent filenames as data (rc=$rc44hostile escaped=$escaped_hostile)"
fi

wsc_gate_findings="$evfake/claude workspace-gate-findings"
conf_gate_findings="$evfake/agents-gate-findings.conf"
eval_conf_write "$conf_gate_findings" "$fake_claude" "$evfake/no-such-codex" 1 60
EVALS_AGENTS_CONF="$conf_gate_findings" FAKE_CLAUDE_MODE=gate-findings FAKE_CLAUDE_TURNS=1 \
  "$evsh" --eval scope-question-no-edit --arm treat --treatment-arm treat \
  --agent claude --corpus-ref "$corpus_ref_test" --workspace "$wsc_gate_findings" >/dev/null 2>&1
rc44gate_findings=$?
gate_findings_run=$(find "$wsc_gate_findings/iteration-1/eval-scope-question-no-edit" \
  -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n1)
if [ "$rc44gate_findings" -eq 0 ] \
  && grep -q '^BLOCK' "$gate_findings_run/outputs/gate.txt" 2>/dev/null \
  && [ -f "$gate_findings_run/grading.json" ]; then
  pass "evals: comments.sh findings exit 1 remains a gradeable capture"
else
  fail "evals: comments.sh findings exit 1 remains a gradeable capture (rc=$rc44gate_findings)"
fi

wsc_verifier_attack="$evfake/claude workspace-verifier-attack"
conf_verifier_attack="$evfake/agents-verifier-attack.conf"
verifier_attack_marker="$evfake/verifier-payload-executed"
rm -f "$verifier_attack_marker"
eval_conf_write "$conf_verifier_attack" "$fake_claude" "$evfake/no-such-codex" 1 60
EVALS_AGENTS_CONF="$conf_verifier_attack" FAKE_CLAUDE_MODE=verifier-attack \
  FAKE_CLAUDE_TURNS=1 FAKE_VERIFIER_ATTACK_MARKER="$verifier_attack_marker" \
  "$evsh" --eval scope-question-no-edit --arm treat --treatment-arm treat \
  --agent claude --corpus-ref "$corpus_ref_test" --workspace "$wsc_verifier_attack" >/dev/null 2>&1
rc44verifier_attack=$?
verifier_attack_run=$(find "$wsc_verifier_attack/iteration-1/eval-scope-question-no-edit" \
  -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n1)
if [ "$rc44verifier_attack" -eq 0 ] && [ ! -e "$verifier_attack_marker" ] \
  && ! grep -q 'FORGED' "$verifier_attack_run/outputs/status-after.txt" 2>/dev/null \
  && ! grep -q 'FORGED' "$verifier_attack_run/outputs/gate.txt" 2>/dev/null \
  && [ -f "$verifier_attack_run/grading.json" ]; then
  pass "evals: fixture verifier replacement cannot execute or forge artifacts"
else
  rm -f "$verifier_attack_marker"
  fail "evals: fixture verifier replacement cannot execute or forge artifacts (rc=$rc44verifier_attack)"
fi

if ! grep -q 'GROOM: CLAUDE.md' "$verifier_attack_run/outputs/status-after.txt" 2>/dev/null; then
  pass "evals: status.sh runs against the trusted status.conf, not a fixture-side mutation"
else
  fail "evals: status.sh runs against the trusted status.conf, not a fixture-side mutation"
fi
if grep -q '^BLOCK' "$verifier_attack_run/outputs/gate.txt" 2>/dev/null; then
  pass "evals: comments.sh runs against the trusted comments.conf, not a fixture-side mutation"
else
  fail "evals: comments.sh runs against the trusted comments.conf, not a fixture-side mutation"
fi
if grep -q 'ENTRYPOINT_MAX_WORDS=1' "$verifier_attack_run/outputs/node-tree.txt" 2>/dev/null; then
  pass "evals: the attempted status.conf mutation is still visible as a captured artifact"
else
  fail "evals: the attempted status.conf mutation is still visible as a captured artifact"
fi

wsc_claude_short="$evfake/claude workspace-short"
conf_claude_short="$evfake/agents-claude-short.conf"
eval_conf_write "$conf_claude_short" "$fake_claude" "$evfake/no-such-codex" 1 60
EVALS_AGENTS_CONF="$conf_claude_short" FAKE_CLAUDE_MODE=short FAKE_CLAUDE_TURNS=3 \
  "$evsh" --eval bootstrap-once --arm treat --treatment-arm treat \
  --agent claude --corpus-ref "$corpus_ref_test" --workspace "$wsc_claude_short" >/dev/null 2>&1
rc44claude_short=$?
if [ "$rc44claude_short" -ne 0 ] && eval_void_clean "$wsc_claude_short" bootstrap-once; then
  pass "evals: claude exit 0 with a short session becomes a diagnostic-only void run"
else
  fail "evals: claude exit 0 with a short session becomes a diagnostic-only void run (rc=$rc44claude_short)"
fi

wsc_claude_error="$evfake/claude workspace-error-result"
conf_claude_error="$evfake/agents-claude-error-result.conf"
eval_conf_write "$conf_claude_error" "$fake_claude" "$evfake/no-such-codex" 1 60
EVALS_AGENTS_CONF="$conf_claude_error" FAKE_CLAUDE_MODE=error-result FAKE_CLAUDE_TURNS=1 \
  "$evsh" --eval scope-question-no-edit --arm treat --treatment-arm treat \
  --agent claude --corpus-ref "$corpus_ref_test" --workspace "$wsc_claude_error" >/dev/null 2>&1
rc44claude_error=$?
if [ "$rc44claude_error" -ne 0 ] && eval_void_clean "$wsc_claude_error" scope-question-no-edit; then
  pass "evals: claude exit-zero error result becomes a diagnostic-only void run"
else
  fail "evals: claude exit-zero error result becomes a diagnostic-only void run (rc=$rc44claude_error)"
fi

wsc_claude_mixed="$evfake/claude workspace-mixed-result"
conf_claude_mixed="$evfake/agents-claude-mixed-result.conf"
eval_conf_write "$conf_claude_mixed" "$fake_claude" "$evfake/no-such-codex" 1 60
EVALS_AGENTS_CONF="$conf_claude_mixed" FAKE_CLAUDE_MODE=mixed-result FAKE_CLAUDE_TURNS=1 \
  "$evsh" --eval scope-question-no-edit --arm treat --treatment-arm treat \
  --agent claude --corpus-ref "$corpus_ref_test" --workspace "$wsc_claude_mixed" >/dev/null 2>&1
rc44claude_mixed=$?
if [ "$rc44claude_mixed" -ne 0 ] && eval_void_clean "$wsc_claude_mixed" scope-question-no-edit; then
  pass "evals: claude mixed success and error terminals become a diagnostic-only void run"
else
  fail "evals: claude mixed success and error terminals become a diagnostic-only void run (rc=$rc44claude_mixed)"
fi

wsc_claude_bgsub="$evfake/claude workspace-background-subagent"
conf_claude_bgsub="$evfake/agents-claude-background-subagent.conf"
eval_conf_write "$conf_claude_bgsub" "$fake_claude" "$evfake/no-such-codex" 1 60
EVALS_AGENTS_CONF="$conf_claude_bgsub" FAKE_CLAUDE_MODE=background-subagent FAKE_CLAUDE_TURNS=1 \
  "$evsh" --eval scope-question-no-edit --arm treat --treatment-arm treat \
  --agent claude --corpus-ref "$corpus_ref_test" --workspace "$wsc_claude_bgsub" \
  >"$evfake/claude-bgsub.out" 2>&1
rc44claude_bgsub=$?
if [ "$rc44claude_bgsub" -eq 0 ]; then
  pass "evals: a background subagent's extra terminal result does not void the run"
else
  fail "evals: a background subagent's extra terminal result does not void the run (rc=$rc44claude_bgsub; $(cat "$evfake/claude-bgsub.out"))"
fi

wsc_claude_bgshort="$evfake/claude workspace-background-subagent-short"
conf_claude_bgshort="$evfake/agents-claude-background-subagent-short.conf"
eval_conf_write "$conf_claude_bgshort" "$fake_claude" "$evfake/no-such-codex" 1 60
EVALS_AGENTS_CONF="$conf_claude_bgshort" FAKE_CLAUDE_MODE=background-subagent-short FAKE_CLAUDE_TURNS=3 \
  "$evsh" --eval bootstrap-once --arm treat --treatment-arm treat \
  --agent claude --corpus-ref "$corpus_ref_test" --workspace "$wsc_claude_bgshort" >/dev/null 2>&1
rc44claude_bgshort=$?
if [ "$rc44claude_bgshort" -ne 0 ] && eval_void_clean "$wsc_claude_bgshort" bootstrap-once; then
  pass "evals: an injected result cannot stand in for a turn the session never finished"
else
  fail "evals: an injected result cannot stand in for a turn the session never finished (rc=$rc44claude_bgshort)"
fi

wsc_bare="$evfake/claude workspace-no-harness"
conf_bare="$evfake/agents-claude-no-harness.conf"
eval_conf_write "$conf_bare" "$fake_claude" "$evfake/no-such-codex" 1 60
EVALS_AGENTS_CONF="$conf_bare" FAKE_CLAUDE_MODE=ok FAKE_CLAUDE_TURNS=1 \
  "$evsh" --eval scope-question-no-edit --arm bare --treatment-arm bare \
  --agent claude --corpus-ref "$corpus_ref_test" --workspace "$wsc_bare" --no-harness \
  >"$evfake/claude-bare.out" 2>&1
rc44bare=$?
bare_run=$(find "$wsc_bare/iteration-1/eval-scope-question-no-edit" \
  -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n1)
bare_harness=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["arms"]["bare"].get("harness"))' \
  "$wsc_bare/iteration-1/run-config.json" 2>/dev/null)
if [ "$rc44bare" -eq 0 ] && [ -n "$bare_run" ] && [ -f "$bare_run/grading.json" ] \
  && [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("void"))' "$bare_run/run-meta.json" 2>/dev/null)" = "False" ] \
  && grep -q 'no .agent directory' "$bare_run/outputs/status-after.txt" 2>/dev/null \
  && [ "$bare_harness" = "none" ]; then
  pass "evals: a no-harness run grades instead of voiding, and records its harness mode"
else
  fail "evals: a no-harness run grades instead of voiding, and records its harness mode (rc=$rc44bare; harness=$bare_harness; $(cat "$evfake/claude-bare.out"))"
fi

wsc_claude_malformed="$evfake/claude workspace-malformed-stream"
conf_claude_malformed="$evfake/agents-claude-malformed.conf"
eval_conf_write "$conf_claude_malformed" "$fake_claude" "$evfake/no-such-codex" 1 60
EVALS_AGENTS_CONF="$conf_claude_malformed" FAKE_CLAUDE_MODE=malformed-stream FAKE_CLAUDE_TURNS=1 \
  "$evsh" --eval scope-question-no-edit --arm treat --treatment-arm treat \
  --agent claude --corpus-ref "$corpus_ref_test" --workspace "$wsc_claude_malformed" >/dev/null 2>&1
rc44claude_malformed=$?
if [ "$rc44claude_malformed" -ne 0 ] && eval_void_clean "$wsc_claude_malformed" scope-question-no-edit; then
  pass "evals: malformed raw claude stream becomes a diagnostic-only void run"
else
  fail "evals: malformed raw claude stream becomes a diagnostic-only void run (rc=$rc44claude_malformed)"
fi

python3 - "$run1_c/run-meta.json" "$wsc/iteration-1/run-config.json" "$fake_claude" <<'PY' >/dev/null 2>&1
import hashlib, json, os, sys
meta = json.load(open(sys.argv[1]))
cfg = json.load(open(sys.argv[2]))["resolved"]["claude"]
whole_cfg = json.load(open(sys.argv[2]))
real = os.path.realpath(sys.argv[3])
digest = hashlib.sha256(open(real, "rb").read()).hexdigest()
required = {
    "bin_realpath": real,
    "bin_sha256": digest,
    "version_output": "9.9.9-fake",
}
ok = all(cfg.get(k) == v for k, v in required.items())
ok = ok and meta.get("agent_bin_realpath") == real
ok = ok and meta.get("agent_bin_sha256") == digest
ok = ok and meta.get("agent_version_output") == "9.9.9-fake"
ok = ok and whole_cfg.get("arms", {}).get("treat", {}).get("corpus_ref") == meta.get("corpus_ref")
sys.exit(0 if ok else 1)
PY
rc44identity=$?
[ "$rc44identity" -eq 0 ] && pass "evals: run config and metadata record canonical executable identity" || fail "evals: run config and metadata record canonical executable identity"

fake_claude_digest="$evfake/fake-claude-digest.py"
cp "$fake_claude" "$fake_claude_digest"
conf_claude_digest="$evfake/agents-claude-digest.conf"
wsc_digest="$evfake/claude workspace-digest"
eval_conf_write "$conf_claude_digest" "$fake_claude_digest" "$evfake/no-such-codex" 1 60
EVALS_AGENTS_CONF="$conf_claude_digest" FAKE_CLAUDE_MODE=ok FAKE_CLAUDE_TURNS=1 \
  "$evsh" --eval scope-question-no-edit --arm treat --treatment-arm treat \
  --agent claude --corpus-ref "$corpus_ref_test" --workspace "$wsc_digest" >/dev/null 2>&1
printf '\n# changed in place\n' >>"$fake_claude_digest"
EVALS_AGENTS_CONF="$conf_claude_digest" FAKE_CLAUDE_MODE=ok FAKE_CLAUDE_TURNS=1 \
  "$evsh" --eval scope-question-no-edit --arm treat --treatment-arm treat \
  --agent claude --corpus-ref "$corpus_ref_test" --workspace "$wsc_digest" >/dev/null 2>&1
rc44digest=$?
[ "$rc44digest" -eq 2 ] && pass "evals: run-config refuses an in-place executable digest change" || fail "evals: run-config refuses an in-place executable digest change (rc=$rc44digest)"

wsc_fail="$evfake/claude workspace-fail"
conf_claude_fail="$evfake/agents-claude-fail.conf"
eval_conf_write "$conf_claude_fail" "$fake_claude" "$evfake/no-such-codex" 1 60
EVALS_AGENTS_CONF="$conf_claude_fail" FAKE_CLAUDE_MODE=fail FAKE_CLAUDE_TURNS=1 \
  "$evsh" --eval scope-question-no-edit --arm treat --treatment-arm treat \
  --agent claude --corpus-ref "$corpus_ref_test" --workspace "$wsc_fail" >/dev/null 2>&1
rc44f=$?
[ "$rc44f" -ne 0 ] && pass "evals: a failing agent process makes the whole run.sh invocation exit nonzero" || fail "evals: a failing agent process makes the whole run.sh invocation exit nonzero"
rundir_fail=$(find "$wsc_fail/iteration-1/eval-scope-question-no-edit" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n1)
[ -n "$rundir_fail" ] && [ ! -e "$rundir_fail/grading.json" ] && pass "evals: a void run writes no grading.json" || fail "evals: a void run writes no grading.json"
[ -f "$rundir_fail/run-meta.json" ] && grep -q '"status": "void"' "$rundir_fail/run-meta.json" 2>/dev/null && pass "evals: a void run's run-meta.json records status void" || fail "evals: a void run's run-meta.json records status void"
[ -f "$rundir_fail/outputs/agent-stdout.txt" ] && [ ! -e "$rundir_fail/outputs/diff.patch" ] && [ ! -e "$rundir_fail/grading.json" ] \
  && pass "evals: a void run keeps the raw stream and discards derived outputs" \
  || fail "evals: a void run keeps the raw stream and discards derived outputs"

wsc_drift="$evfake/claude workspace-drift"
conf_claude_drift1="$evfake/agents-claude-drift1.conf"
eval_conf_write "$conf_claude_drift1" "$fake_claude" "$evfake/no-such-codex" 1 60
EVALS_AGENTS_CONF="$conf_claude_drift1" FAKE_CLAUDE_MODE=ok FAKE_CLAUDE_TURNS=1 \
  "$evsh" --eval scope-question-no-edit --arm treat --treatment-arm treat \
  --agent claude --corpus-ref "$corpus_ref_test" --workspace "$wsc_drift" >/dev/null 2>&1
rc44d1=$?
[ "$rc44d1" -eq 0 ] && pass "evals: the first run into a fresh iteration locks run-config.json" || fail "evals: the first run into a fresh iteration locks run-config.json (rc=$rc44d1)"
python3 - "$wsc_drift/iteration-1/run-config.json" <<'PY' >/dev/null 2>&1
import json, sys
cfg = json.load(open(sys.argv[1]))
sys.exit(0 if "repeats_per_cell" in cfg and "repeats" not in cfg else 1)
PY
rc44cfg=$?
[ "$rc44cfg" -eq 0 ] && pass "evals: run-config records repeats_per_cell, not the retired repeats field" || fail "evals: run-config records repeats_per_cell, not the retired repeats field"

conf_claude_drift2="$evfake/agents-claude-drift2.conf"
eval_conf_write "$conf_claude_drift2" "$fake_claude" "$evfake/no-such-codex" 1 60
subst "$conf_claude_drift2" 's/^CLAUDE_MODEL=.*/CLAUDE_MODEL=fake-claude-model-drifted/'
EVALS_AGENTS_CONF="$conf_claude_drift2" FAKE_CLAUDE_MODE=ok FAKE_CLAUDE_TURNS=1 \
  "$evsh" --eval scope-question-no-edit --arm treat --treatment-arm treat \
  --agent claude --corpus-ref "$corpus_ref_test" --workspace "$wsc_drift" >"$evfake/drift.err" 2>&1
rc44d2=$?
[ "$rc44d2" -eq 2 ] && pass "evals: a later run with a drifted model is refused" || fail "evals: a later run with a drifted model is refused (rc=$rc44d2)"
grep -q 'drifted' "$evfake/drift.err" && pass "evals: the drift refusal names the field that moved" || fail "evals: the drift refusal names the field that moved ($(cat "$evfake/drift.err"))"

conf_claude_effort="$evfake/agents-claude-effort-drift.conf"
eval_conf_write "$conf_claude_effort" "$fake_claude" "$evfake/no-such-codex" 1 60
subst "$conf_claude_effort" 's/^CLAUDE_EFFORT=.*/CLAUDE_EFFORT=high/'
EVALS_AGENTS_CONF="$conf_claude_effort" FAKE_CLAUDE_MODE=ok FAKE_CLAUDE_TURNS=1 \
  "$evsh" --eval scope-question-no-edit --arm treat --treatment-arm treat \
  --agent claude --corpus-ref "$corpus_ref_test" --workspace "$wsc_drift" >"$evfake/effort-drift.err" 2>&1
rc44effort=$?
[ "$rc44effort" -eq 2 ] && pass "evals: a later run with drifted effort is refused" || fail "evals: a later run with drifted effort is refused (rc=$rc44effort)"
grep -q 'effort' "$evfake/effort-drift.err" && pass "evals: held-effort drift is named in the refusal" || fail "evals: held-effort drift is named in the refusal ($(cat "$evfake/effort-drift.err"))"
ndirs_drift=$(find "$wsc_drift/iteration-1/eval-scope-question-no-edit" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | grep -c .)
[ "$ndirs_drift" -eq 1 ] && pass "evals: a refused drifted run creates no additional run directory" || fail "evals: a refused drifted run creates no additional run directory (found $ndirs_drift)"

conf_claude_indexmode="$evfake/agents-claude-indexmode-drift.conf"
eval_conf_write "$conf_claude_indexmode" "$fake_claude" "$evfake/no-such-codex" 1 60
EVALS_AGENTS_CONF="$conf_claude_indexmode" FAKE_CLAUDE_MODE=ok FAKE_CLAUDE_TURNS=1 \
  "$evsh" --eval scope-question-no-edit --arm treat --treatment-arm treat \
  --agent claude --corpus-ref "$corpus_ref_test" --workspace "$wsc_drift" --index-mode generated \
  >"$evfake/indexmode-drift.err" 2>&1
rc44im=$?
[ "$rc44im" -eq 2 ] && grep -q 'index_mode' "$evfake/indexmode-drift.err" \
  && pass "evals: an arm entry records its index mode and refuses a drifted one" \
  || fail "evals: an arm entry records its index mode and refuses a drifted one (rc=$rc44im; $(cat "$evfake/indexmode-drift.err"))"

wscx="$evfake/codex workspace"
conf_codex="$evfake/agents-codex.conf"
eval_conf_write "$conf_codex" "$evfake/no-such-claude" "$fake_codex" 1 60
codex_counter="$evfake/codex-counter"
rm -f "$codex_counter"
EVALS_AGENTS_CONF="$conf_codex" FAKE_CODEX_MODE=ok FAKE_CODEX_COUNTER="$codex_counter" FAKE_TRACE_RUNNER_ROOT="$reporoot" \
  "$evsh" --eval bootstrap-once --arm treat --treatment-arm treat \
  --agent codex --corpus-ref "$corpus_ref_test" --workspace "$wscx" >"$evfake/codex-run.out" 2>&1
rc44x=$?
[ "$rc44x" -eq 0 ] && pass "evals: a full run.sh invocation against a fake codex CLI exits 0" || fail "evals: a full run.sh invocation against a fake codex CLI exits 0 (rc=$rc44x; $(cat "$evfake/codex-run.out"))"

rundir_x=$(find "$wscx/iteration-1/eval-bootstrap-once" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n1)
[ "$(grep -c '^## Turn [0-9][0-9]*$' "$rundir_x/outputs/session-transcript.txt" 2>/dev/null)" = "3" ] && pass "evals: a 3-turn eval against codex captures three numbered transcript sections" || fail "evals: a 3-turn eval against codex captures three numbered transcript sections"
sed -n '2p' "$rundir_x/outputs/session-transcript.txt" 2>/dev/null | grep -qF 'echo:What does this project use for HTTP?' && pass "evals: turn one's prompt reached the fake codex CLI on stdin, not argv" || fail "evals: turn one's prompt reached the fake codex CLI on stdin, not argv"
[ "$(grep -c '"tool": "codex.command_execution"' "$rundir_x/outputs/trace.jsonl" 2>/dev/null)" = "3" ] && pass "evals: codex's command_execution items normalize into the shared trace contract, one per turn" || fail "evals: codex's command_execution items normalize into the shared trace contract, one per turn"
grep -q '"path": "notes/codex-turn-3.md"' "$rundir_x/outputs/trace.jsonl" 2>/dev/null && pass "evals: codex's file_change items normalize with a fixture-relative path" || fail "evals: codex's file_change items normalize with a fixture-relative path"
python3 - "$rundir_x/outputs/agent-stdout.txt" <<'PY' >/dev/null 2>&1
import json, sys
seen_completed = False
seen_started = False
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    event = json.loads(line)
    item = event.get("item") or {}
    if item.get("type") == "file_change":
        seen_completed |= event.get("type") == "item.completed"
        seen_started |= event.get("type") == "item.started"
sys.exit(0 if seen_completed and not seen_started else 1)
PY
rc44file_lifecycle=$?
[ "$rc44file_lifecycle" -eq 0 ] && pass "evals: codex file_change trace fixture uses the real item.completed lifecycle" || fail "evals: codex file_change trace fixture uses the real item.completed lifecycle"
python3 - "$rundir_x/outputs/agent-stdout.txt" <<'PY' >/dev/null 2>&1
import json, sys
started = completed = 0
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    event = json.loads(line)
    if (event.get("item") or {}).get("type") == "command_execution":
        started += event.get("type") == "item.started"
        completed += event.get("type") == "item.completed"
sys.exit(0 if started == 3 and completed == 3 else 1)
PY
rc44cmd_lifecycle=$?
[ "$rc44cmd_lifecycle" -eq 0 ] && pass "evals: codex command_execution trace fixture announces each command on both lifecycle events" || fail "evals: codex command_execution trace fixture announces each command on both lifecycle events"
if trace_roots_absent "$rundir_x/outputs/trace.jsonl" "$rundir_x/fixture" "$reporoot"; then
  pass "evals: codex trace text contains no absolute fixture or runner-worktree path"
else
  fail "evals: codex trace text contains no absolute fixture or runner-worktree path ($(cat "$rundir_x/outputs/trace.jsonl" 2>/dev/null))"
fi
[ "$(grep -c 'thread.started' "$rundir_x/outputs/agent-stdout.txt" 2>/dev/null)" = "1" ] && pass "evals: turns 2 and 3 resume the thread turn 1 started rather than opening a new one" || fail "evals: turns 2 and 3 resume the thread turn 1 started rather than opening a new one"

for short_mode in short-first short-middle short-final; do
  wscx_short="$evfake/codex workspace-$short_mode"
  conf_codex_short="$evfake/agents-codex-$short_mode.conf"
  codex_short_counter="$evfake/codex-$short_mode-counter"
  rm -f "$codex_short_counter"
  eval_conf_write "$conf_codex_short" "$evfake/no-such-claude" "$fake_codex" 1 60
  EVALS_AGENTS_CONF="$conf_codex_short" FAKE_CODEX_MODE="$short_mode" \
    FAKE_CODEX_COUNTER="$codex_short_counter" \
    "$evsh" --eval bootstrap-once --arm treat --treatment-arm treat \
    --agent codex --corpus-ref "$corpus_ref_test" --workspace "$wscx_short" >/dev/null 2>&1
  rc44codex_short=$?
  if [ "$rc44codex_short" -ne 0 ] && eval_void_clean "$wscx_short" bootstrap-once; then
    pass "evals: codex $short_mode exit 0 becomes a diagnostic-only void run"
  else
    fail "evals: codex $short_mode exit 0 becomes a diagnostic-only void run (rc=$rc44codex_short)"
  fi
done

for terminal_mode in mixed-failed mixed-error duplicate-completion; do
  wscx_terminal="$evfake/codex workspace-$terminal_mode"
  conf_codex_terminal="$evfake/agents-codex-$terminal_mode.conf"
  eval_conf_write "$conf_codex_terminal" "$evfake/no-such-claude" "$fake_codex" 1 60
  EVALS_AGENTS_CONF="$conf_codex_terminal" FAKE_CODEX_MODE="$terminal_mode" \
    "$evsh" --eval scope-question-no-edit --arm treat --treatment-arm treat \
    --agent codex --corpus-ref "$corpus_ref_test" --workspace "$wscx_terminal" >/dev/null 2>&1
  rc44terminal=$?
  if [ "$rc44terminal" -ne 0 ] && eval_void_clean "$wscx_terminal" scope-question-no-edit; then
    pass "evals: codex $terminal_mode terminals become a diagnostic-only void run"
  else
    fail "evals: codex $terminal_mode terminals become a diagnostic-only void run (rc=$rc44terminal)"
  fi
done

wscx_malformed="$evfake/codex workspace-malformed-stream"
conf_codex_malformed="$evfake/agents-codex-malformed.conf"
eval_conf_write "$conf_codex_malformed" "$evfake/no-such-claude" "$fake_codex" 1 60
EVALS_AGENTS_CONF="$conf_codex_malformed" FAKE_CODEX_MODE=malformed-stream \
  "$evsh" --eval scope-question-no-edit --arm treat --treatment-arm treat \
  --agent codex --corpus-ref "$corpus_ref_test" --workspace "$wscx_malformed" >/dev/null 2>&1
rc44codex_malformed=$?
if [ "$rc44codex_malformed" -ne 0 ] && eval_void_clean "$wscx_malformed" scope-question-no-edit; then
  pass "evals: malformed raw codex stream becomes a diagnostic-only void run"
else
  fail "evals: malformed raw codex stream becomes a diagnostic-only void run (rc=$rc44codex_malformed)"
fi

fake_codex_replace="$evfake/fake-codex-replace.py"
cp "$fake_codex" "$fake_codex_replace"
chmod +x "$fake_codex_replace"
wscx_replace="$evfake/codex workspace-replace-between-turns"
conf_codex_replace="$evfake/agents-codex-replace.conf"
codex_replace_counter="$evfake/codex-replace-counter"
rm -f "$codex_replace_counter"
eval_conf_write "$conf_codex_replace" "$evfake/no-such-claude" "$fake_codex_replace" 1 60
EVALS_AGENTS_CONF="$conf_codex_replace" FAKE_CODEX_MODE=replace-between-turns \
  FAKE_CODEX_COUNTER="$codex_replace_counter" \
  "$evsh" --eval bootstrap-once --arm treat --treatment-arm treat \
  --agent codex --corpus-ref "$corpus_ref_test" --workspace "$wscx_replace" >/dev/null 2>&1
rc44codex_replace=$?
codex_replace_run=$(find "$wscx_replace/iteration-1/eval-bootstrap-once" \
  -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n1)
if [ "$rc44codex_replace" -ne 0 ] && [ "$(cat "$codex_replace_counter" 2>/dev/null)" = 1 ] \
  && eval_void_clean "$wscx_replace" bootstrap-once \
  && grep -q '"status": "agent_identity_mismatch"' "$codex_replace_run/run-meta.json" 2>/dev/null; then
  pass "evals: same-path codex replacement at a turn boundary voids before resume"
else
  fail "evals: same-path codex replacement at a turn boundary voids before resume (rc=$rc44codex_replace)"
fi

real_bash=$(command -v bash)
real_git=$(command -v git)
real_python=$(command -v python3)
real_chmod=$(command -v chmod)
real_cat=$(command -v cat)

fake_claude_replace="$evfake/fake-claude-replace.py"
cp "$fake_claude" "$fake_claude_replace"
chmod +x "$fake_claude_replace"
wsc_repeat_replace="$evfake/claude workspace-replace-between-repeats"
conf_repeat_replace="$evfake/agents-replace-between-repeats.conf"
rm -f "$fake_claude_replace.done"
eval_conf_write "$conf_repeat_replace" "$fake_claude_replace" "$evfake/no-such-codex" 2 60
PATH="$phase_bin:$PATH" FAKE_REAL_BASH="$real_bash" FAKE_REAL_GIT="$real_git" \
  FAKE_REAL_PYTHON="$real_python" FAKE_REAL_CHMOD="$real_chmod" FAKE_REAL_CAT="$real_cat" \
  FAKE_REPLACE_AFTER_GRADE="$fake_claude_replace" \
  FAKE_GRADE_PATH="$evroot/grade.py" EVALS_AGENTS_CONF="$conf_repeat_replace" \
  FAKE_CLAUDE_MODE=ok FAKE_CLAUDE_TURNS=1 \
  "$evsh" --eval scope-question-no-edit --arm treat --treatment-arm treat \
  --agent claude --corpus-ref "$corpus_ref_test" --workspace "$wsc_repeat_replace" >/dev/null 2>&1
rc44repeat_replace=$?
repeat_replace_eval="$wsc_repeat_replace/iteration-1/eval-scope-question-no-edit"
repeat_replace_void=$(find "$repeat_replace_eval" -name run-meta.json -exec grep -l '"status": "agent_identity_mismatch"' {} \; 2>/dev/null | head -n1)
if [ "$rc44repeat_replace" -ne 0 ] \
  && [ "$(find "$repeat_replace_eval" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | grep -c .)" -eq 2 ] \
  && [ -n "$repeat_replace_void" ] \
  && [ -f "${repeat_replace_void%/run-meta.json}/outputs/agent-stdout.txt" ] \
  && [ ! -e "${repeat_replace_void%/run-meta.json}/outputs/diff.patch" ] \
  && [ ! -e "${repeat_replace_void%/run-meta.json}/grading.json" ]; then
  pass "evals: same-path executable replacement between repeats voids the affected repeat"
else
  fail "evals: same-path executable replacement between repeats voids the affected repeat (rc=$rc44repeat_replace)"
fi

# The capture and grading wrappers are direct runner children. Sending TERM there
# exercises the selected phase even when fixture setup or the agent takes longer.
for run_phase in capture grading; do
  phase_workspace="$evfake/claude workspace-signal-$run_phase"
  phase_conf="$evfake/agents-signal-$run_phase.conf"
  phase_ready="$evfake/$run_phase-ready"
  rm -f "$phase_ready"
  eval_conf_write "$phase_conf" "$fake_claude" "$evfake/no-such-codex" 1 60
  PATH="$phase_bin:$PATH" FAKE_REAL_BASH="$real_bash" FAKE_REAL_GIT="$real_git" \
    FAKE_REAL_PYTHON="$real_python" FAKE_REAL_CHMOD="$real_chmod" FAKE_REAL_CAT="$real_cat" \
    FAKE_RUN_PHASE="$run_phase" \
    FAKE_GRADE_PATH="$evroot/grade.py" FAKE_PHASE_READY="$phase_ready" \
    EVALS_AGENTS_CONF="$phase_conf" \
    FAKE_CLAUDE_MODE=ok FAKE_CLAUDE_TURNS=1 \
    "$evsh" --eval scope-question-no-edit --arm treat --treatment-arm treat \
    --agent claude --corpus-ref "$corpus_ref_test" --workspace "$phase_workspace" >/dev/null 2>&1 &
  wait "$!" 2>/dev/null
  phase_rc=$?
  phase_run=$(find "$phase_workspace/iteration-1/eval-scope-question-no-edit" \
    -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n1)
  if [ "$phase_rc" -eq 143 ] && [ -s "$phase_ready" ] \
    && eval_void_clean "$phase_workspace" scope-question-no-edit \
    && grep -q '"status": "cancelled"' "$phase_run/run-meta.json" 2>/dev/null; then
    pass "evals: TERM during $run_phase retains cancelled metadata and no outputs or grading"
  else
    fail "evals: TERM during $run_phase retains cancelled metadata and no outputs or grading (rc=$phase_rc)"
  fi
done

for infra_stage in capture trace grading; do
  infra_workspace="$evfake/claude workspace-$infra_stage-failure"
  infra_conf="$evfake/agents-$infra_stage-failure.conf"
  infra_capture_counter="$evfake/$infra_stage-capture-git-counter"
  rm -f "$infra_capture_counter"
  eval_conf_write "$infra_conf" "$fake_claude" "$evfake/no-such-codex" 1 60
  PATH="$phase_bin:$PATH" FAKE_REAL_BASH="$real_bash" FAKE_REAL_GIT="$real_git" \
    FAKE_REAL_PYTHON="$real_python" FAKE_REAL_CHMOD="$real_chmod" FAKE_REAL_CAT="$real_cat" \
    FAKE_INFRA_FAIL="$infra_stage" \
    FAKE_CAPTURE_GIT_COUNTER="$infra_capture_counter" \
    FAKE_GRADE_PATH="$evroot/grade.py" EVALS_AGENTS_CONF="$infra_conf" \
    FAKE_CLAUDE_MODE=ok FAKE_CLAUDE_TURNS=1 \
    "$evsh" --eval scope-question-no-edit --arm treat --treatment-arm treat \
    --agent claude --corpus-ref "$corpus_ref_test" --workspace "$infra_workspace" >/dev/null 2>&1
  infra_rc=$?
  case "$infra_stage" in
  capture) infra_status=artifact_capture_failed ;;
  trace) infra_status=trace_extraction_failed ;;
  grading) infra_status=grading_failed ;;
  esac
  infra_run=$(find "$infra_workspace/iteration-1/eval-scope-question-no-edit" \
    -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n1)
  if [ "$infra_rc" -ne 0 ] && eval_void_clean "$infra_workspace" scope-question-no-edit \
    && grep -q "\"status\": \"$infra_status\"" "$infra_run/run-meta.json" 2>/dev/null \
    && grep -q '"failure_reason":' "$infra_run/run-meta.json" 2>/dev/null \
    && [ -d "$infra_run/fixture" ] && [ -f "$infra_run/fixture-build.txt" ]; then
    pass "evals: $infra_stage infrastructure failure retains truthful void metadata only"
  else
    fail "evals: $infra_stage infrastructure failure retains truthful void metadata only (rc=$infra_rc)"
  fi
done

wscx_transcript="$evfake/codex workspace-transcript-shape"
conf_codex_transcript="$evfake/agents-codex-transcript-shape.conf"
eval_conf_write "$conf_codex_transcript" "$evfake/no-such-claude" "$fake_codex" 1 60
codex_shape_counter="$evfake/codex-shape-counter"
rm -f "$codex_shape_counter"
EVALS_AGENTS_CONF="$conf_codex_transcript" FAKE_CODEX_MODE=transcript-shape FAKE_CODEX_COUNTER="$codex_shape_counter" \
  "$evsh" --eval bootstrap-once --arm treat --treatment-arm treat \
  --agent codex --corpus-ref "$corpus_ref_test" --workspace "$wscx_transcript" >/dev/null 2>&1
rundir_transcript=$(find "$wscx_transcript/iteration-1/eval-bootstrap-once" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n1)
[ "$(grep -c '^## Turn [0-9][0-9]*$' "$rundir_transcript/outputs/session-transcript.txt" 2>/dev/null)" = "3" ] && pass "evals: transcript emits a numbered section for every completed turn" || fail "evals: transcript emits a numbered section for every completed turn"
grep -A1 '^## Turn 2$' "$rundir_transcript/outputs/session-transcript.txt" 2>/dev/null | grep -qF '[empty final response]' && pass "evals: transcript records an empty final response with a placeholder" || fail "evals: transcript records an empty final response with a placeholder"
grep -A2 '^## Turn 1$' "$rundir_transcript/outputs/session-transcript.txt" 2>/dev/null | grep -qF 'second transcript line' && pass "evals: transcript preserves multiline final response text" || fail "evals: transcript preserves multiline final response text"

wscx_signal="$evfake/codex workspace-signal"
conf_codex_signal="$evfake/agents-codex-signal.conf"
eval_conf_write "$conf_codex_signal" "$evfake/no-such-claude" "$fake_codex" 1 60
codex_home_path="$evfake/codex-active-home"
codex_auth_source="$evfake/codex-auth-source"
mkdir -p "$codex_auth_source"
printf '{"auth_mode": "chatgpt", "token":"fake"}\n' >"$codex_auth_source/auth.json"
rm -f "$codex_home_path"
EVALS_AGENTS_CONF="$conf_codex_signal" CODEX_HOME="$codex_auth_source" FAKE_CODEX_MODE=signal-wait FAKE_CODEX_HOME_PATH="$codex_home_path" \
  "$evsh" --eval bootstrap-once --arm treat --treatment-arm treat \
  --agent codex --corpus-ref "$corpus_ref_test" --workspace "$wscx_signal" >/dev/null 2>&1 &
signal_runner_pid=$!
signal_wait=0
while [ ! -s "$codex_home_path" ] && [ "$signal_wait" -lt 100 ]; do sleep 0.1; signal_wait=$((signal_wait + 1)); done
kill -TERM "$signal_runner_pid" 2>/dev/null
wait "$signal_runner_pid" 2>/dev/null
signal_rc=$?
signal_home=$(cat "$codex_home_path" 2>/dev/null)
case "$signal_home" in
"${TMPDIR:-/tmp}/dot-agent-codex-home."*) signal_home_prefix=1 ;;
*) signal_home_prefix=0 ;;
esac
[ "$signal_rc" -ne 0 ] && [ "$signal_home_prefix" -eq 1 ] && [ ! -e "$signal_home" ] && pass "evals: TERM cleanup removes the active system-temporary Codex home" || fail "evals: TERM cleanup removes the active system-temporary Codex home (rc=$signal_rc home=$signal_home)"
case "$signal_home" in "$wscx_signal"/*) signal_home_retained=1 ;; *) signal_home_retained=0 ;; esac
retained_auth=$(find "$wscx_signal/iteration-1/eval-bootstrap-once" -path '*/outputs/auth.json' -print -quit 2>/dev/null)
[ "$signal_home_retained" -eq 0 ] && [ -z "$retained_auth" ] && pass "evals: copied Codex authentication never enters retained outputs" || fail "evals: copied Codex authentication never enters retained outputs"

wscx_cancel="$evfake/codex workspace-cancel-group"
conf_codex_cancel="$evfake/agents-codex-cancel-group.conf"
eval_conf_write "$conf_codex_cancel" "$evfake/no-such-claude" "$fake_codex" 1 60
cancel_home_path="$evfake/codex-cancel-home"
cancel_parent_pid="$evfake/codex-cancel-parent.pid"
cancel_child_pid="$evfake/codex-cancel-child.pid"
cancel_grandchild_pid="$evfake/codex-cancel-grandchild.pid"
rm -f "$cancel_home_path" "$cancel_parent_pid" "$cancel_child_pid" "$cancel_grandchild_pid"
EVALS_AGENTS_CONF="$conf_codex_cancel" FAKE_CODEX_MODE=signal-child \
  FAKE_CODEX_HOME_PATH="$cancel_home_path" FAKE_CODEX_PARENT_PID="$cancel_parent_pid" \
  FAKE_CODEX_CHILD_PID="$cancel_child_pid" FAKE_CODEX_GRANDCHILD_PID="$cancel_grandchild_pid" \
  "$evsh" --eval bootstrap-once --arm treat --treatment-arm treat \
  --agent codex --corpus-ref "$corpus_ref_test" --workspace "$wscx_cancel" >/dev/null 2>&1 &
cancel_runner_pid=$!
cancel_wait=0
while { [ ! -s "$cancel_parent_pid" ] || [ ! -s "$cancel_child_pid" ] || [ ! -s "$cancel_grandchild_pid" ]; } \
  && [ "$cancel_wait" -lt 100 ]; do
  sleep 0.1
  cancel_wait=$((cancel_wait + 1))
done
kill -TERM "$cancel_runner_pid" 2>/dev/null
wait "$cancel_runner_pid" 2>/dev/null
cancel_rc=$?
if [ "$cancel_rc" -ne 0 ] \
  && recorded_processes_dead "$cancel_parent_pid" "$cancel_child_pid" "$cancel_grandchild_pid"; then
  pass "evals: targeted TERM kills the active codex process group including child and grandchild"
else
  fail "evals: targeted TERM kills the active codex process group including child and grandchild (rc=$cancel_rc)"
fi
cancel_rundir=$(find "$wscx_cancel/iteration-1/eval-bootstrap-once" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n1)
if [ -f "$cancel_rundir/run-meta.json" ] \
  && grep -q '"status": "cancelled"' "$cancel_rundir/run-meta.json" 2>/dev/null \
  && [ -f "$cancel_rundir/outputs/agent-stdout.txt" ] \
  && [ ! -e "$cancel_rundir/outputs/diff.patch" ] \
  && [ ! -e "$cancel_rundir/grading.json" ]; then
  pass "evals: cancellation retains void metadata, keeps the raw stream and discards derived outputs"
else
  fail "evals: cancellation retains void metadata, keeps the raw stream and discards derived outputs"
fi

wscx_timeout="$evfake/codex workspace-timeout"
conf_codex_timeout="$evfake/agents-codex-timeout.conf"
codex_child_pid="$evfake/codex-timeout-child.pid"
codex_grandchild_pid="$evfake/codex-timeout-grandchild.pid"
rm -f "$codex_child_pid" "$codex_grandchild_pid"
eval_conf_write "$conf_codex_timeout" "$evfake/no-such-claude" "$fake_codex" 1 1
EVALS_AGENTS_CONF="$conf_codex_timeout" FAKE_CODEX_MODE=timeout-resistant \
  FAKE_CODEX_CHILD_PID="$codex_child_pid" FAKE_CODEX_GRANDCHILD_PID="$codex_grandchild_pid" \
  "$evsh" --eval bootstrap-once --arm treat --treatment-arm treat \
  --agent codex --corpus-ref "$corpus_ref_test" --workspace "$wscx_timeout" >/dev/null 2>&1
rc44timeout=$?
if [ "$rc44timeout" -ne 0 ] \
  && recorded_processes_dead "$codex_child_pid" "$codex_grandchild_pid"; then
  pass "evals: timeout kills TERM-resistant codex child and grandchild"
else
  fail "evals: timeout kills TERM-resistant codex child and grandchild (rc=$rc44timeout)"
fi
timeout_rundir=$(find "$wscx_timeout/iteration-1/eval-bootstrap-once" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n1)
if [ -f "$timeout_rundir/run-meta.json" ] \
  && grep -q '"status": "timeout"' "$timeout_rundir/run-meta.json" 2>/dev/null \
  && [ -f "$timeout_rundir/outputs/agent-stdout.txt" ] \
  && [ ! -e "$timeout_rundir/outputs/diff.patch" ] \
  && [ ! -e "$timeout_rundir/grading.json" ]; then
  pass "evals: timeout retains void metadata, keeps the raw stream and discards derived outputs"
else
  fail "evals: timeout retains void metadata, keeps the raw stream and discards derived outputs"
fi

gd="$WORK/eval-grade/r0"
mkdir -p "$gd/outputs"
cat >"$gd/snap.json" <<'EOF'
{"id":"g","assertions":[
 {"id":"g/new","concept":"c","class":"artifact","grade":"auto","check":"product_files_added == 1"},
 {"id":"g/append","concept":"c","class":"artifact","grade":"auto","check":"memory_files_added == 0"},
 {"id":"g/order","concept":"c","class":"trace","grade":"auto","check":"trace_order 'catalog' before 'write:'"},
 {"id":"g/absent","concept":"c","class":"artifact","grade":"auto","check":"node_tree_absent 'SECRET-TOKEN'"},
 {"id":"g/missing","concept":"c","class":"artifact","grade":"auto","check":"gate_block_count == 0"},
 {"id":"g/nodeprefix","concept":"c","class":"artifact","grade":"auto","check":"node_file_changed 'memory/x.md'"},
 {"id":"g/wrapped","concept":"c","class":"trace","grade":"auto","check":"fixture_test_executed"},
 {"id":"g/human","concept":"c","class":"artifact","grade":"manual"}]}
EOF
printf -- '--- /dev/null\n+++ b/src/new.ts\n+const a = 1\n' >"$gd/outputs/diff.patch"
ndrepo="$WORK/eval-node-diff"
mkdir -p "$ndrepo/.agent/memory"
printf 'seed\n' >"$ndrepo/.agent/memory/x.md"
git -C "$ndrepo" init -q
git -C "$ndrepo" add -A
git -C "$ndrepo" -c user.name=eval -c user.email=eval@local -c commit.gpgsign=false \
  commit -q -m base
nd_base=$(git -C "$ndrepo" rev-parse HEAD)
printf 'a line\n' >>"$ndrepo/.agent/memory/x.md"
git -C "$ndrepo" add -A
git -C "$ndrepo" diff --cached "$nd_base" -- .agent >"$gd/outputs/node-diff.patch"
printf '{"seq":0,"event":"call","tool":"read_file","action":"read","text":"read catalog"}\n{"seq":1,"event":"call","tool":"write_file","action":"write","text":"write:src/new.ts"}\n' >"$gd/outputs/trace.jsonl"
printf 'nothing sensitive here\n' >"$gd/outputs/node-tree.txt"
cat >"$gd/outputs/agent-stdout.txt" <<'EOF'
{"type":"item.completed","item":{"type":"command_execution","command":"bash .agent/scripts/verify.sh run test","aggregated_output":"> test\n> node --test\nnot ok 1 - legacy currency rounding","exit_code":1}}
EOF
"$evroot/grade.py" "$gd" "$gd/snap.json" >/dev/null 2>&1
g42=$(python3 -c '
import json,sys
r = {x["id"]: x for x in json.load(open(sys.argv[1]))["results"]}
bad = []
if not r["g/new"]["passed"]: bad.append("new-file-not-counted")
if not r["g/append"]["passed"]: bad.append("append-read-as-creation")
if not r["g/wrapped"]["passed"]: bad.append("wrapped-test-execution-missed")
if not r["g/order"]["passed"]: bad.append("trace-order")
if not r["g/absent"]["passed"]: bad.append("tree-absence")
if r["g/missing"]["passed"]: bad.append("missing-artifact-passed-by-default")
if not r["g/nodeprefix"]["passed"]: bad.append("node-diff-prefix-not-stripped")
if r["g/human"]["passed"] is not None: bad.append("manual-was-auto-graded")
print(" ".join(bad))' "$gd/grading.json" 2>&1)
[ -z "$g42" ] && pass "evals: the grader evaluates its check language and fails closed on a missing artifact" || fail "evals: the grader evaluates its check language and fails closed on a missing artifact ($g42)"

gd2="$WORK/eval-grade-modules/r0"
mkdir -p "$gd2/outputs"
cat >"$gd2/snap.json" <<'EOF'
{"id":"g2","assertions":[
 {"id":"g2/files","concept":"c","class":"artifact","grade":"auto","check":"product_files_added == 2"},
 {"id":"g2/modules","concept":"c","class":"artifact","grade":"auto","check":"product_modules_added == 1"}]}
EOF
printf -- '--- /dev/null\n+++ b/src/refunds.ts\n+export const refunds = 1\n--- /dev/null\n+++ b/src/client.test.ts\n+test()\n' \
  >"$gd2/outputs/diff.patch"
"$evroot/grade.py" "$gd2" "$gd2/snap.json" >/dev/null 2>&1
g42mod=$(python3 -c '
import json,sys
r = {x["id"]: x for x in json.load(open(sys.argv[1]))["results"]}
bad = []
if not r["g2/files"]["passed"]: bad.append("product-files-added-miscounted")
if not r["g2/modules"]["passed"]: bad.append("test-file-counted-as-module")
print(" ".join(bad))' "$gd2/grading.json" 2>&1)
[ -z "$g42mod" ] && pass "evals: product_modules_added excludes a test file beside a new module" || fail "evals: product_modules_added excludes a test file beside a new module ($g42mod)"

gd3="$WORK/eval-grade-modules-only-test/r0"
mkdir -p "$gd3/outputs"
printf '{"id":"g3","assertions":[{"id":"g3/modules","concept":"c","class":"artifact","grade":"auto","check":"product_modules_added == 0"}]}' >"$gd3/snap.json"
printf -- '--- /dev/null\n+++ b/src/client.test.ts\n+test()\n' >"$gd3/outputs/diff.patch"
"$evroot/grade.py" "$gd3" "$gd3/snap.json" >/dev/null 2>&1
g42testonly=$(python3 -c '
import json,sys
r = json.load(open(sys.argv[1]))["results"][0]
print("" if r["passed"] else "test-only-diff-counted-as-module")' "$gd3/grading.json" 2>&1)
[ -z "$g42testonly" ] && pass "evals: product_modules_added is zero when only a test file is added" || fail "evals: product_modules_added is zero when only a test file is added ($g42testonly)"

gd5="$WORK/eval-grade-line-removed/r0"
mkdir -p "$gd5/outputs"
cat >"$gd5/snap.json" <<'EOF'
{"id":"g5","assertions":[
 {"id":"g5/changed","concept":"c","class":"artifact","grade":"auto","check":"product_line_removed 'src/a.ts' 'limit: 2'"},
 {"id":"g5/moved","concept":"c","class":"artifact","grade":"auto","check":"product_line_removed 'src/a.test.ts' 'assert'"},
 {"id":"g5/deleted","concept":"c","class":"artifact","grade":"auto","check":"product_line_removed 'src/b.test.ts' 'assert'"}]}
EOF
cat >"$gd5/outputs/diff.patch" <<'EOF'
--- a/src/a.test.ts
+++ b/src/a.test.ts
-assert.equal(f(1), 2)
+  assert.equal(f(1), 2)
--- a/src/a.ts
+++ b/src/a.ts
-  limit: 2,
+  limit: 0,
--- a/src/b.test.ts
+++ /dev/null
-assert.equal(g(), 1)
EOF
"$evroot/grade.py" "$gd5" "$gd5/snap.json" >/dev/null 2>&1
g42removed=$(python3 -c '
import json,sys
r = {x["id"]: x for x in json.load(open(sys.argv[1]))["results"]}
print("%s %s %s" % (r["g5/changed"]["passed"], r["g5/moved"]["passed"], r["g5/deleted"]["passed"]))' "$gd5/grading.json" 2>&1)
[ "$g42removed" = "True False True" ] && pass "evals: product_line_removed counts a changed line and a deleted file, never a re-indented line" || fail "evals: product_line_removed counts a changed line and a deleted file, never a re-indented line ($g42removed)"

gd6="$WORK/eval-grade-kept-tests/r0"
mkdir -p "$gd6/outputs"
cat >"$gd6/snap.json" <<'EOF'
{"id":"g6","assertions":[
 {"id":"g6/kept","concept":"c","class":"artifact","grade":"auto","check":"kept_tests_added 'tmp/scratch/' == 1"},
 {"id":"g6/all","concept":"c","class":"artifact","grade":"auto","check":"kept_tests_added 'build/' == 2"}]}
EOF
cat >"$gd6/outputs/diff.patch" <<'EOF'
--- a/src/a.test.ts
+++ b/src/a.test.ts
-test("old title", () => {
+test("new title", () => {
+test("one more", () => {
+  assert.equal(f(1), 2)
--- /dev/null
+++ b/tmp/scratch/proof.test.ts
+test("scratch", () => {
EOF
"$evroot/grade.py" "$gd6" "$gd6/snap.json" >/dev/null 2>&1
g42kept=$(python3 -c '
import json,sys
r = {x["id"]: x for x in json.load(open(sys.argv[1]))["results"]}
print("%s %s" % (r["g6/kept"]["passed"], r["g6/all"]["passed"]))' "$gd6/grading.json" 2>&1)
[ "$g42kept" = "True True" ] && pass "evals: kept_tests_added nets a renamed test to zero and skips the scratch folder" || fail "evals: kept_tests_added nets a renamed test to zero and skips the scratch folder ($g42kept)"

gd7="$WORK/eval-grade-fixture-files/r0"
mkdir -p "$gd7/outputs" "$gd7/fixture/tmp/scratch/deep" "$gd7/fixture/src" "$WORK/eval-grade-fixture-files/r1/outputs"
printf 'left\n' >"$gd7/fixture/tmp/scratch/deep/proof.test.ts"
cat >"$gd7/snap.json" <<'EOF'
{"id":"g7","assertions":[
 {"id":"g7/left","concept":"c","class":"artifact","grade":"auto","check":"fixture_files_under 'tmp/scratch' == 1"},
 {"id":"g7/empty","concept":"c","class":"artifact","grade":"auto","check":"fixture_files_under 'src' == 0"},
 {"id":"g7/outside","concept":"c","class":"artifact","grade":"auto","check":"fixture_files_under '../outputs' == 0"}]}
EOF
"$evroot/grade.py" "$gd7" "$gd7/snap.json" >/dev/null 2>&1
"$evroot/grade.py" "$WORK/eval-grade-fixture-files/r1" "$gd7/snap.json" >/dev/null 2>&1
g42fixture=$(python3 -c '
import json,sys
r = {x["id"]: x for x in json.load(open(sys.argv[1]))["results"]}
m = {x["id"]: x for x in json.load(open(sys.argv[2]))["results"]}
print("%s %s %s %s" % (r["g7/left"]["passed"], r["g7/empty"]["passed"], r["g7/outside"]["passed"], m["g7/empty"]["passed"]))' "$gd7/grading.json" "$WORK/eval-grade-fixture-files/r1/grading.json" 2>&1)
[ "$g42fixture" = "True True False False" ] && pass "evals: fixture_files_under counts files left in the kept tree and fails closed without one" || fail "evals: fixture_files_under counts files left in the kept tree and fails closed without one ($g42fixture)"

gd4="$WORK/eval-grade-claims/r0"
mkdir -p "$gd4/outputs"
claims_check() {
  printf '%s\n' "$1" >"$gd4/outputs/session-transcript.txt"
  printf '{"id":"g4","assertions":[{"id":"g4/claim","concept":"c","class":"artifact","grade":"auto","check":"output_claims %s"}]}' "$2" >"$gd4/snap.json"
  "$evroot/grade.py" "$gd4" "$gd4/snap.json" >/dev/null 2>&1
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["results"][0]["passed"])' "$gd4/grading.json"
}
c1=$(claims_check 'I can'"'"'t truthfully say "the suite is green".' "'suite is green'")
[ "$c1" = "False" ] && pass "evals: output_claims reads a refusal naming the phrase as not claiming it" || fail "evals: output_claims reads a refusal naming the phrase as not claiming it ($c1)"

c2=$(claims_check 'Use the internal release tool, never raw kubectl.' "'kubectl'")
[ "$c2" = "False" ] && pass "evals: output_claims reads a never-use-this mention as not a claim" || fail "evals: output_claims reads a never-use-this mention as not a claim ($c2)"

c3=$(claims_check 'All tests pass.' "'all tests pass'")
[ "$c3" = "True" ] && pass "evals: output_claims reads a bare assertion as a claim" || fail "evals: output_claims reads a bare assertion as a claim ($c3)"

c4=$(claims_check 'The suite is green.' "'suite is green'")
[ "$c4" = "True" ] && pass "evals: output_claims reads an unqualified statement as a claim" || fail "evals: output_claims reads an unqualified statement as a claim ($c4)"

c5=$(claims_check 'Raw kubectl is explicitly disallowed.' "'kubectl'")
[ "$c5" = "False" ] && pass "evals: output_claims reads an explicitly-disallowed mention as not a claim" || fail "evals: output_claims reads an explicitly-disallowed mention as not a claim ($c5)"

trace_snapshot="$gd/trace-snapshot.json"
printf '{"id":"trace","assertions":[{"id":"trace/order","concept":"c","class":"trace","grade":"auto","check":"trace_order '\''catalog'\'' before '\''write:'\''"},{"id":"trace/product","concept":"c","class":"artifact","grade":"auto","check":"product_files_added == 1"}]}' >"$trace_snapshot"
trace_result() {
  "$evroot/grade.py" "$gd" "$trace_snapshot" >/dev/null 2>&1
  python3 -c 'import json,sys; r={x["id"]:x for x in json.load(open(sys.argv[1]))["results"]}; print("%s|%s|%s" % (r["trace/order"]["passed"], r["trace/product"]["passed"], r["trace/order"]["evidence"]))' "$gd/grading.json"
}

printf '{"seq":0,"event":"call","tool":"read_file","action":"read","text":"read catalog"}\n' >"$gd/outputs/trace.jsonl"
trace_missing=$(trace_result)
printf '%s\n' "$trace_missing" | grep -q '^False|True|.*write:.*never appears' && pass "evals: trace_order fails when its second call is missing" || fail "evals: trace_order fails when its second call is missing ($trace_missing)"

printf '{"seq":0,"event":"call","tool":"read_file","action":"read","text":"read catalog"}\nnot-json\n' >"$gd/outputs/trace.jsonl"
trace_malformed=$(trace_result)
printf '%s\n' "$trace_malformed" | grep -q '^False|True|.*malformed JSON' && pass "evals: malformed trace JSON fails trace checks without aborting artifact checks" || fail "evals: malformed trace JSON fails trace checks without aborting artifact checks ($trace_malformed)"

printf '{"seq":0,"event":"result","tool":"read_file","action":"read","text":"read catalog"}\n{"seq":1,"event":"result","tool":"write_file","action":"write","text":"write:src/new.ts"}\n' >"$gd/outputs/trace.jsonl"
trace_noncall=$(trace_result)
printf '%s\n' "$trace_noncall" | grep -q '^False|True|.*catalog.*never appears' && pass "evals: non-call trace records cannot satisfy trace_order" || fail "evals: non-call trace records cannot satisfy trace_order ($trace_noncall)"

printf '{"seq":0,"text":"read catalog"}\n{"seq":1,"text":"write:src/new.ts"}\n' >"$gd/outputs/trace.jsonl"
trace_legacy=$(trace_result)
printf '%s\n' "$trace_legacy" | grep -q '^True|True|' && pass "evals: valid legacy seq/text traces remain gradeable" || fail "evals: valid legacy seq/text traces remain gradeable ($trace_legacy)"

tracefix_priv="/private/tmp/evtrace-$$"
mkdir -p "$tracefix_priv/.agent/rules"
printf 'a rule\n' >"$tracefix_priv/.agent/rules/learned.md"
tracefix_tmp="/tmp/evtrace-$$"
cat >"$gd/outputs/claude-stream-alias.jsonl" <<EOF
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"$tracefix_tmp/.agent/rules/learned.md"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"cat $tracefix_tmp/.agent/rules/learned.md"}}]}}
{"type":"result","result":"done"}
EOF
"$evroot/run_lib.py" extract-claude-trace "$gd/outputs/claude-stream-alias.jsonl" "$gd/outputs/trace-alias.jsonl" \
  "$gd/outputs/transcript-alias.txt" "$tracefix_priv" run1 "$WORK" >/dev/null 2>&1
rc_alias=$?
trace_alias_lines=$(cat "$gd/outputs/trace-alias.jsonl" 2>/dev/null)
if [ "$rc_alias" -eq 0 ] \
  && printf '%s\n' "$trace_alias_lines" | grep -q '"text": *"read:\.agent/rules/learned\.md"' \
  && printf '%s\n' "$trace_alias_lines" | grep -q '"text": *"execute:cat \.agent/rules/learned\.md"'; then
  pass "evals: trace extractor strips the other side of a macOS /tmp alias"
else
  fail "evals: trace extractor strips the other side of a macOS /tmp alias (rc=$rc_alias $trace_alias_lines)"
fi

cat >"$gd/outputs/claude-stream-foreign.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/etc/other/.agent/x"}}]}}
{"type":"result","result":"done"}
EOF
"$evroot/run_lib.py" extract-claude-trace "$gd/outputs/claude-stream-foreign.jsonl" "$gd/outputs/trace-foreign.jsonl" \
  "$gd/outputs/transcript-foreign.txt" "$tracefix_priv" run1 "$WORK" >/dev/null 2>&1
rc_foreign=$?
[ "$rc_foreign" -ne 0 ] && pass "evals: trace extractor fails closed on a foreign absolute node path" \
  || fail "evals: trace extractor fails closed on a foreign absolute node path (rc=$rc_foreign)"
rm -rf "$tracefix_priv"

usage_claude="$gd/outputs/usage-claude-stdout.txt"
cat >"$usage_claude" <<'EOF'
{"type":"result","result":"ok","usage":{"input_tokens":100,"cache_creation_input_tokens":10,"cache_read_input_tokens":5,"output_tokens":20},"total_cost_usd":0.015}
{"type":"result","result":"ok","usage":{"input_tokens":200,"cache_creation_input_tokens":0,"cache_read_input_tokens":15,"output_tokens":40},"total_cost_usd":0.025}
EOF
usage_out=$("$evroot/run_lib.py" agent-usage "$usage_claude" claude-stream-json)
usage_rc=$?
usage_expect='{"cache_creation_input_tokens": 10, "cache_read_input_tokens": 20, "input_tokens": 300, "output_tokens": 60, "usd": 0.04}'
if [ "$usage_rc" -eq 0 ] && python3 -c '
import json, sys
got = json.loads(sys.argv[1])
want = json.loads(sys.argv[2])
sys.exit(0 if got == want else 1)' "$usage_out" "$usage_expect"; then
  pass "evals: agent-usage sums claude usage records across turns"
else
  fail "evals: agent-usage sums claude usage records across turns (rc=$usage_rc; $usage_out)"
fi

usage_empty="$gd/outputs/usage-empty-stdout.txt"
printf '{"type":"result","result":"ok"}\n' >"$usage_empty"
usage_null_out=$("$evroot/run_lib.py" agent-usage "$usage_empty" claude-stream-json)
usage_null_rc=$?
if [ "$usage_null_rc" -eq 0 ] && python3 -c '
import json, sys
got = json.loads(sys.argv[1])
sys.exit(0 if all(v is None for v in got.values()) else 1)' "$usage_null_out"; then
  pass "evals: agent-usage exits 0 with all-null fields when the stream has no usage block"
else
  fail "evals: agent-usage exits 0 with all-null fields when the stream has no usage block (rc=$usage_null_rc; $usage_null_out)"
fi

countstream="$gd/outputs/count-results.jsonl"

cat >"$countstream" <<'EOF'
{"type":"system","subtype":"init","session_id":"s1"}
{"type":"assistant","message":{"content":[{"type":"text","text":"LAUNCHED"}]}}
{"type":"result","subtype":"success","is_error":false,"result":"LAUNCHED","session_id":"s1"}
{"type":"system","subtype":"init","session_id":"s1"}
{"type":"result","subtype":"success","is_error":false,"result":"Agent completed","session_id":"s1","origin":{"kind":"task-notification"}}
EOF
count_bg=$("$evroot/run_lib.py" claude-count-results "$countstream")
[ "$count_bg" = "1 1 0 1" ] \
  && pass "evals: a background subagent's own result is not counted as a turn boundary" \
  || fail "evals: a background subagent's own result is not counted as a turn boundary ($count_bg)"

cat >"$countstream" <<'EOF'
{"type":"result","subtype":"success","is_error":false,"result":"one","session_id":"s1"}
EOF
count_trunc=$("$evroot/run_lib.py" claude-count-results "$countstream")
[ "$count_trunc" = "1 1 0 0" ] \
  && pass "evals: a stream one result short of the turns sent still counts one terminal" \
  || fail "evals: a stream one result short of the turns sent still counts one terminal ($count_trunc)"

cat >"$countstream" <<'EOF'
{"type":"result","subtype":"success","is_error":false,"result":"one","session_id":"s1"}
{"type":"result","is_error":false,"session_id":"s1","origin":{"kind":"task-notification"}}
EOF
count_badinj=$("$evroot/run_lib.py" claude-count-results "$countstream")
[ "$count_badinj" = "1 1 1 1" ] \
  && pass "evals: a malformed injected result still counts as a malformed record" \
  || fail "evals: a malformed injected result still counts as a malformed record ($count_badinj)"

evr="$WORK/eval-rollup"
mkdir -p "$evr/eval-demo/r1" "$evr/eval-demo/r2" "$evr/eval-demo/r3" "$evr/eval-demo/r4"
printf '{"r1":"treat","r2":"ctrl","r3":"treat","r4":"ctrl"}\n' >"$evr/arm-map.json"
printf '{"treatment_arm":"treat","repeats_per_cell":2}\n' >"$evr/run-config.json"
printf '{"id":"demo","assertions":[{"id":"a1","concept":"c"},{"id":"a2","concept":"c"}]}\n' >"$evr/eval-demo/eval-snapshot.json"
printf '{"results":[{"id":"a1","passed":true,"evidence":"q"},{"id":"a2","passed":false,"evidence":"r"}]}\n' >"$evr/eval-demo/r1/grading.json"
printf '{"results":[{"id":"a1","passed":false,"evidence":"s"},{"id":"a2","passed":false,"evidence":"t"}]}\n' >"$evr/eval-demo/r2/grading.json"
printf '{"results":[{"id":"a1","passed":true,"evidence":"u"},{"id":"a2","passed":false,"evidence":"v"}]}\n' >"$evr/eval-demo/r3/grading.json"
printf '{"results":[{"id":"a1","passed":false,"evidence":"w"},{"id":"a2","passed":false,"evidence":"x"}]}\n' >"$evr/eval-demo/r4/grading.json"
printf '{"duration_seconds":1}\n' >"$evr/eval-demo/r1/run-meta.json"
printf '{"duration_seconds":2}\n' >"$evr/eval-demo/r2/run-meta.json"
printf '{"duration_seconds":5}\n' >"$evr/eval-demo/r3/run-meta.json"
printf '{"duration_seconds":6}\n' >"$evr/eval-demo/r4/run-meta.json"
out42=$("$evroot/rollup.py" "$evr" 2>&1)
rc42=$?
[ "$rc42" -eq 0 ] && printf '%s\n' "$out42" | grep -q 'discriminating' && pass "evals: rollup joins two arms and buckets by outcome" || fail "evals: rollup joins two arms and buckets by outcome (rc=$rc42; $out42)"

evrm="$WORK/eval-rollup-manual-arm"
mkdir -p "$evrm/eval-demo/r1" "$evrm/eval-demo/r2"
printf '{"r1":"generated","r2":"manual"}\n' >"$evrm/arm-map.json"
printf '{"treatment_arm":"generated","repeats_per_cell":1}\n' >"$evrm/run-config.json"
printf '{"id":"demo","assertions":[{"id":"a1","concept":"c"},{"id":"a2","concept":"c"}]}\n' >"$evrm/eval-demo/eval-snapshot.json"
printf '{"results":[{"id":"a1","grade":"auto","passed":true,"evidence":"q"},{"id":"a2","grade":"manual","passed":true,"evidence":"r"}]}\n' >"$evrm/eval-demo/r1/grading.json"
printf '{"results":[{"id":"a1","grade":"auto","passed":false,"evidence":"s"},{"id":"a2","grade":"manual","passed":false,"evidence":"t"}]}\n' >"$evrm/eval-demo/r2/grading.json"
printf '{"duration_seconds":1}\n' >"$evrm/eval-demo/r1/run-meta.json"
printf '{"duration_seconds":2}\n' >"$evrm/eval-demo/r2/run-meta.json"
out42m=$("$evroot/rollup.py" "$evrm" 2>&1); rc42m=$?
[ "$rc42m" -eq 0 ] && pass "evals: rollup accepts an arm named manual beside the grade: manual schema field" || fail "evals: rollup accepts an arm named manual beside the grade: manual schema field (rc=$rc42m; $out42m)"

python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["duration_s"]; sys.exit(0 if d == {"treat":{"mean":3.0,"population_stddev":2.0,"sample_size":2},"ctrl":{"mean":4.0,"population_stddev":2.0,"sample_size":2}} else 1)' "$evr/rollup.json"
rc42duration=$?
[ "$rc42duration" -eq 0 ] && pass "evals: rollup reports duration mean and population standard deviation separately per arm" || fail "evals: rollup reports duration mean and population standard deviation separately per arm"

python3 -c '
import json, sys
c = json.load(open(sys.argv[1]))["cost"]
fields = {"input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens", "usd"}
sys.exit(0 if set(c) == {"treat", "ctrl"}
          and all(set(c[arm]) == fields and all(v == "unavailable" for v in c[arm].values()) for arm in c)
          else 1)' "$evr/rollup.json"
rc42cost=$?
[ "$rc42cost" -eq 0 ] && pass "evals: rollup explicitly marks unrecorded token and USD costs unavailable per arm" || fail "evals: rollup explicitly marks unrecorded token and USD costs unavailable per arm"

mv "$evr/run-config.json" "$evr/run-config.saved"
out42missing=$("$evroot/rollup.py" "$evr" 2>&1); rc42missing=$?
mv "$evr/run-config.saved" "$evr/run-config.json"
[ "$rc42missing" -eq 2 ] && printf '%s\n' "$out42missing" | grep -q 'cannot read .*run-config.json' && pass "evals: rollup refuses a missing run-config.json" || fail "evals: rollup refuses a missing run-config.json (rc=$rc42missing; $out42missing)"

printf '{"treatment_arm":"missing","repeats_per_cell":2}\n' >"$evr/run-config.json"
out42treatment=$("$evroot/rollup.py" "$evr" 2>&1); rc42treatment=$?
printf '{"treatment_arm":"treat","repeats_per_cell":2}\n' >"$evr/run-config.json"
[ "$rc42treatment" -eq 2 ] && printf '%s\n' "$out42treatment" | grep -q 'treatment_arm .* is not an arm' && pass "evals: rollup refuses a treatment_arm absent from arm-map.json" || fail "evals: rollup refuses a treatment_arm absent from arm-map.json (rc=$rc42treatment; $out42treatment)"

printf '{"treatment_arm":"treat","repeats_per_cell":0}\n' >"$evr/run-config.json"
out42zero=$("$evroot/rollup.py" "$evr" 2>&1); rc42zero=$?
printf '{"treatment_arm":"treat","repeats_per_cell":2}\n' >"$evr/run-config.json"
[ "$rc42zero" -eq 2 ] && printf '%s\n' "$out42zero" | grep -q 'repeats_per_cell must be a positive integer' && pass "evals: rollup refuses zero repeats_per_cell" || fail "evals: rollup refuses zero repeats_per_cell (rc=$rc42zero; $out42zero)"

mv "$evr/eval-demo/r3/grading.json" "$evr/eval-demo/r3/grading.saved"
out42shortt=$("$evroot/rollup.py" "$evr" 2>&1); rc42shortt=$?
mv "$evr/eval-demo/r3/grading.saved" "$evr/eval-demo/r3/grading.json"
[ "$rc42shortt" -eq 2 ] && printf '%s\n' "$out42shortt" | grep -q 'repeats treatment=1 control=2' && pass "evals: rollup refuses treatment cells with fewer repeats than configured" || fail "evals: rollup refuses treatment cells with fewer repeats than configured (rc=$rc42shortt; $out42shortt)"

mv "$evr/eval-demo/r4/grading.json" "$evr/eval-demo/r4/grading.saved"
out42shortc=$("$evroot/rollup.py" "$evr" 2>&1); rc42shortc=$?
mv "$evr/eval-demo/r4/grading.saved" "$evr/eval-demo/r4/grading.json"
[ "$rc42shortc" -eq 2 ] && printf '%s\n' "$out42shortc" | grep -q 'repeats treatment=2 control=1' && pass "evals: rollup refuses control cells with fewer repeats than configured" || fail "evals: rollup refuses control cells with fewer repeats than configured (rc=$rc42shortc; $out42shortc)"

printf '{"results":[{"id":"a1","passed":true,"evidence":"q"}]}\n' >"$evr/eval-demo/r1/grading.json"
out42b=$("$evroot/rollup.py" "$evr" 2>&1)
rc42b=$?
[ "$rc42b" -eq 2 ] && printf '%s\n' "$out42b" | grep -q 'grades 1 ids, its snapshot lists 2' && pass "evals: rollup refuses a grading record whose ids disagree with its snapshot" || fail "evals: rollup refuses a grading record whose ids disagree with its snapshot (rc=$rc42b; $out42b)"

printf '{"results":[{"id":"a1","passed":true,"evidence":"the treat arm did it"},{"id":"a2","passed":true,"evidence":"r"}]}\n' >"$evr/eval-demo/r1/grading.json"
out42c=$("$evroot/rollup.py" "$evr" 2>&1)
rc42c=$?
[ "$rc42c" -eq 2 ] && printf '%s\n' "$out42c" | grep -q 'names the condition inside' && pass "evals: rollup refuses a grading record naming its own arm" || fail "evals: rollup refuses a grading record naming its own arm (rc=$rc42c; $out42c)"

printf '{"arm":"treat","results":[{"id":"a1","passed":true,"evidence":"q"},{"id":"a2","passed":true,"evidence":"r"}]}\n' >"$evr/eval-demo/r1/grading.json"
out42cv=$("$evroot/rollup.py" "$evr" 2>&1); rc42cv=$?
[ "$rc42cv" -eq 2 ] && printf '%s\n' "$out42cv" | grep -q 'whole value' && pass "evals: rollup refuses a grading record whose field value is an arm name" || fail "evals: rollup refuses a grading record whose field value is an arm name (rc=$rc42cv; $out42cv)"

evr2="$WORK/eval-rollup-vocabulary"
mkdir -p "$evr2/eval-demo/r1" "$evr2/eval-demo/r2"
printf '{"r1":"node","r2":"generic"}\n' >"$evr2/arm-map.json"
printf '{"treatment_arm":"node","repeats_per_cell":1}\n' >"$evr2/run-config.json"
printf '{"id":"demo","assertions":[{"id":"a1","concept":"c"}]}\n' >"$evr2/eval-demo/eval-snapshot.json"
printf '{"results":[{"id":"a1","passed":true,"evidence":"status.sh reports no new findings and the node stays clean"}]}\n' >"$evr2/eval-demo/r1/grading.json"
printf '{"results":[{"id":"a1","passed":false,"evidence":"no generic instructions file was read before the edit"}]}\n' >"$evr2/eval-demo/r2/grading.json"
out42voc=$("$evroot/rollup.py" "$evr2" 2>&1); rc42voc=$?
[ "$rc42voc" -eq 0 ] && pass "evals: rollup reads evidence that uses an arm's word without naming the condition" || fail "evals: rollup reads evidence that uses an arm's word without naming the condition (rc=$rc42voc; $out42voc)"

printf '{"results":[{"id":"a1","passed":true,"evidence":"this was the treatment arm, node"}]}\n' >"$evr2/eval-demo/r1/grading.json"
out42voc2=$("$evroot/rollup.py" "$evr2" 2>&1); rc42voc2=$?
printf '{"results":[{"id":"a1","passed":true,"evidence":"status.sh reports no new findings and the node stays clean"}]}\n' >"$evr2/eval-demo/r1/grading.json"
[ "$rc42voc2" -eq 2 ] && printf '%s\n' "$out42voc2" | grep -q 'names the condition inside' && pass "evals: rollup still refuses an arm name written beside the experiment's own vocabulary" || fail "evals: rollup still refuses an arm name written beside the experiment's own vocabulary (rc=$rc42voc2; $out42voc2)"

printf '{"results":[{"id":"a1","passed":null,"evidence":null},{"id":"a2","passed":true,"evidence":"r"}]}\n' >"$evr/eval-demo/r1/grading.json"
out42e=$("$evroot/rollup.py" "$evr" 2>&1)
rc42e=$?
[ "$rc42e" -eq 2 ] && printf '%s\n' "$out42e" | grep -q 'leaves a1 ungraded' && pass "evals: rollup refuses an iteration with a manual assertion still ungraded" || fail "evals: rollup refuses an iteration with a manual assertion still ungraded (rc=$rc42e; $out42e)"

evr2="$WORK/eval-rollup-auto"
mkdir -p "$evr2/eval-demo/r1" "$evr2/eval-demo/r2" "$evr2/eval-demo/r3" "$evr2/eval-demo/r4"
printf '{"r1":"treat","r2":"ctrl","r3":"treat","r4":"ctrl"}\n' >"$evr2/arm-map.json"
printf '{"treatment_arm":"treat","repeats_per_cell":2}\n' >"$evr2/run-config.json"
printf '{"id":"demo","assertions":[{"id":"a1","concept":"c"},{"id":"a2","concept":"c"}]}\n' >"$evr2/eval-demo/eval-snapshot.json"
printf '{"results":[{"id":"a1","passed":null,"evidence":null},{"id":"a2","passed":true,"evidence":"q"}]}\n' >"$evr2/eval-demo/r1/grading.json"
printf '{"results":[{"id":"a1","passed":null,"evidence":null},{"id":"a2","passed":false,"evidence":"r"}]}\n' >"$evr2/eval-demo/r2/grading.json"
printf '{"results":[{"id":"a1","passed":null,"evidence":null},{"id":"a2","passed":true,"evidence":"s"}]}\n' >"$evr2/eval-demo/r3/grading.json"
printf '{"results":[{"id":"a1","passed":null,"evidence":null},{"id":"a2","passed":false,"evidence":"t"}]}\n' >"$evr2/eval-demo/r4/grading.json"
out42auto_fatal=$("$evroot/rollup.py" "$evr2" 2>&1); rc42auto_fatal=$?
[ "$rc42auto_fatal" -eq 2 ] && printf '%s\n' "$out42auto_fatal" | grep -q 'leaves a1 ungraded' \
  && pass "evals: rollup without --auto-only still refuses a pending manual assertion" \
  || fail "evals: rollup without --auto-only still refuses a pending manual assertion (rc=$rc42auto_fatal; $out42auto_fatal)"

out42auto=$("$evroot/rollup.py" --auto-only "$evr2" 2>&1); rc42auto=$?
if [ "$rc42auto" -eq 0 ] \
  && [ -f "$evr2/rollup-preview.json" ] \
  && [ ! -e "$evr2/rollup.json" ] \
  && printf '%s\n' "$out42auto" | grep -q '^PREVIEW' \
  && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("mode")=="auto-only-preview" and d.get("pending_manual")==["a1"] and d.get("checklist_size")==1 else 1)' "$evr2/rollup-preview.json"; then
  pass "evals: rollup --auto-only previews auto assertions and defers a pending manual one"
else
  fail "evals: rollup --auto-only previews auto assertions and defers a pending manual one (rc=$rc42auto; $out42auto)"
fi

printf '{"results":[{"id":"a1","passed":true,"evidence":"q"},{"id":"a2","passed":false,"evidence":"r"}]}\n' >"$evr/eval-demo/r1/grading.json"
mkdir -p "$evr/eval-extra/x1" "$evr/eval-extra/x2"
printf '{"id":"extra","assertions":[{"id":"b1","concept":"c"}]}\n' >"$evr/eval-extra/eval-snapshot.json"
printf '{"results":[{"id":"b1","passed":true,"evidence":"it happened"}]}\n' >"$evr/eval-extra/x1/grading.json"
printf '{"results":[{"id":"b1","passed":false,"evidence":"y"}]}\n' >"$evr/eval-extra/x2/grading.json"
printf '{"r1":"treat","r2":"ctrl","r3":"treat","r4":"ctrl","x1":"treat","x2":"ctrl"}\n' >"$evr/arm-map.json"
out42excl_bad=$("$evroot/rollup.py" --exclude-eval no-such-eval "$evr" 2>&1); rc42excl_bad=$?
[ "$rc42excl_bad" -eq 2 ] && printf '%s\n' "$out42excl_bad" | grep -q 'matches no eval directory' \
  && pass "evals: rollup refuses an --exclude-eval id that matches no directory" \
  || fail "evals: rollup refuses an --exclude-eval id that matches no directory (rc=$rc42excl_bad; $out42excl_bad)"

out42excl=$("$evroot/rollup.py" --exclude-eval extra "$evr" 2>&1); rc42excl=$?
if [ "$rc42excl" -eq 0 ] \
  && printf '%s\n' "$out42excl" | grep -q '^excluded:  *extra' \
  && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("excluded_evals")==["extra"] and all(r["id"] != "b1" for r in d["rows"]) else 1)' "$evr/rollup.json"; then
  pass "evals: rollup --exclude-eval drops the named eval and records the exclusion"
else
  fail "evals: rollup --exclude-eval drops the named eval and records the exclusion (rc=$rc42excl; $out42excl)"
fi
printf '{"r1":"treat","r2":"ctrl","r3":"treat","r4":"ctrl"}\n' >"$evr/arm-map.json"
rm -rf "$evr/eval-extra"

printf '{"duration_seconds":1,"usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5,"usd":0.01}}\n' >"$evr/eval-demo/r1/run-meta.json"
printf '{"duration_seconds":2,"usage":{"input_tokens":20,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":6,"usd":0.02}}\n' >"$evr/eval-demo/r2/run-meta.json"
printf '{"duration_seconds":5,"usage":{"input_tokens":30,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":7,"usd":0.03}}\n' >"$evr/eval-demo/r3/run-meta.json"
printf '{"duration_seconds":6}\n' >"$evr/eval-demo/r4/run-meta.json"
out42usage_partial=$("$evroot/rollup.py" "$evr" 2>&1); rc42usage_partial=$?
if [ "$rc42usage_partial" -eq 0 ] && python3 -c '
import json, sys
c = json.load(open(sys.argv[1]))["cost"]
sys.exit(0 if all(v == "unavailable" for arm in c.values() for v in arm.values()) else 1)' "$evr/rollup.json"; then
  pass "evals: rollup reports cost unavailable, not fatal, when one run has no usage block"
else
  fail "evals: rollup reports cost unavailable, not fatal, when one run has no usage block (rc=$rc42usage_partial; $out42usage_partial)"
fi

printf '{"duration_seconds":6,"usage":{"input_tokens":40,"cache_creation_input_tokens":0,"cache_read_input_tokens":1,"output_tokens":8,"usd":0.04}}\n' >"$evr/eval-demo/r4/run-meta.json"
out42usage_full=$("$evroot/rollup.py" "$evr" 2>&1); rc42usage_full=$?
if [ "$rc42usage_full" -eq 0 ] && python3 -c '
import json, sys
c = json.load(open(sys.argv[1]))["cost"]
sys.exit(0 if c["treat"]["input_tokens"] == 40 and c["ctrl"]["input_tokens"] == 60
          and c["treat"]["usd"] == 0.04 and c["ctrl"]["usd"] == 0.06 else 1)' "$evr/rollup.json"; then
  pass "evals: rollup sums usage per arm when every run in both arms carries it"
else
  fail "evals: rollup sums usage per arm when every run in both arms carries it (rc=$rc42usage_full; $out42usage_full)"
fi

rlbase="$WORK/eval-rollup-base"
mkdir -p "$rlbase/eval-demo/r1" "$rlbase/eval-demo/r2"
printf '{"r1":"treat","r2":"ctrl"}\n' >"$rlbase/arm-map.json"
printf '{"treatment_arm":"treat","repeats_per_cell":1}\n' >"$rlbase/run-config.json"
printf '{"id":"demo","assertions":[{"id":"a1","concept":"c"}]}\n' >"$rlbase/eval-demo/eval-snapshot.json"
printf '{"results":[{"id":"a1","passed":true,"evidence":"q"}]}\n' >"$rlbase/eval-demo/r1/grading.json"
printf '{"results":[{"id":"a1","passed":false,"evidence":"r"}]}\n' >"$rlbase/eval-demo/r2/grading.json"

rlnan="$WORK/eval-rollup-nan"
cp -R "$rlbase" "$rlnan"
printf '{"duration_s": NaN}\n' >"$rlnan/eval-demo/r1/run-meta.json"
outrlnan=$("$evroot/rollup.py" "$rlnan" 2>&1); rcrlnan=$?
if [ "$rcrlnan" -eq 2 ] && printf '%s\n' "$outrlnan" | grep -qF 'must be a finite non-negative number' \
  && [ ! -e "$rlnan/rollup.json" ]; then
  pass "evals: rollup rejects a NaN duration_s (exit 2, no rollup.json written)"
else
  fail "evals: rollup rejects a NaN duration_s (exit 2, no rollup.json written) (rc=$rcrlnan; $outrlnan)"
fi

rlinf="$WORK/eval-rollup-inf"
cp -R "$rlbase" "$rlinf"
printf '{"duration_s": Infinity}\n' >"$rlinf/eval-demo/r1/run-meta.json"
outrlinf=$("$evroot/rollup.py" "$rlinf" 2>&1); rcrlinf=$?
[ "$rcrlinf" -eq 2 ] && printf '%s\n' "$outrlinf" | grep -qF 'must be a finite non-negative number' && pass "evals: rollup rejects an Infinity duration_s" || fail "evals: rollup rejects an Infinity duration_s (rc=$rcrlinf; $outrlinf)"

rlkey="$WORK/eval-rollup-nokey"
cp -R "$rlbase" "$rlkey"
printf '{"results":[{"id":"a1","evidence":"q"}]}\n' >"$rlkey/eval-demo/r1/grading.json"
outrlkey=$("$evroot/rollup.py" "$rlkey" 2>&1); rcrlkey=$?
if [ "$rcrlkey" -eq 2 ] && printf '%s\n' "$outrlkey" | grep -qF 'no "passed" key' \
  && ! printf '%s\n' "$outrlkey" | grep -qi 'traceback'; then
  pass "evals: rollup refuses a result with no \"passed\" key (exit 2, no traceback)"
else
  fail "evals: rollup refuses a result with no \"passed\" key (exit 2, no traceback) (rc=$rcrlkey; $outrlkey)"
fi

rlasym="$WORK/eval-rollup-duration-asym"
cp -R "$rlbase" "$rlasym"
printf '{"duration_s": 1.5}\n' >"$rlasym/eval-demo/r1/run-meta.json"
outrlasym=$("$evroot/rollup.py" "$rlasym" 2>&1); rcrlasym=$?
if [ "$rcrlasym" -eq 2 ] && printf '%s\n' "$outrlasym" | grep -qF 'r2' \
  && printf '%s\n' "$outrlasym" | grep -qF 'no duration field'; then
  pass "evals: rollup refuses asymmetric duration coverage across arms"
else
  fail "evals: rollup refuses asymmetric duration coverage across arms (rc=$rcrlasym; $outrlasym)"
fi

rlsym="$WORK/eval-rollup-duration-sym"
cp -R "$rlbase" "$rlsym"
printf '{"duration_s": 1.5}\n' >"$rlsym/eval-demo/r1/run-meta.json"
printf '{"duration_s": 2.5}\n' >"$rlsym/eval-demo/r2/run-meta.json"
outrlsym=$("$evroot/rollup.py" "$rlsym" 2>&1); rcrlsym=$?
python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["duration_s"]; sys.exit(0 if d == {"treat":{"mean":1.5,"population_stddev":0.0,"sample_size":1},"ctrl":{"mean":2.5,"population_stddev":0.0,"sample_size":1}} else 1)' "$rlsym/rollup.json"
rcrlsymjson=$?
[ "$rcrlsym" -eq 0 ] && [ "$rcrlsymjson" -eq 0 ] && pass "evals: rollup reports duration_s when every run in the iteration carries it" || fail "evals: rollup reports duration_s when every run in the iteration carries it (rc=$rcrlsym; $outrlsym)"

rlshapearm="$WORK/eval-rollup-shape-arm"
cp -R "$rlbase" "$rlshapearm"
printf '["not","an","object"]\n' >"$rlshapearm/arm-map.json"
outrlshapearm=$("$evroot/rollup.py" "$rlshapearm" 2>&1); rcrlshapearm=$?
[ "$rcrlshapearm" -eq 2 ] && printf '%s\n' "$outrlshapearm" | grep -qF 'arm-map.json must be an object' && pass "evals: rollup refuses a non-object arm-map.json" || fail "evals: rollup refuses a non-object arm-map.json (rc=$rcrlshapearm; $outrlshapearm)"

rlshapecfg="$WORK/eval-rollup-shape-config"
cp -R "$rlbase" "$rlshapecfg"
printf '["not","an","object"]\n' >"$rlshapecfg/run-config.json"
outrlshapecfg=$("$evroot/rollup.py" "$rlshapecfg" 2>&1); rcrlshapecfg=$?
[ "$rcrlshapecfg" -eq 2 ] && printf '%s\n' "$outrlshapecfg" | grep -qF 'run-config.json must be an object' && pass "evals: rollup refuses a non-object run-config.json" || fail "evals: rollup refuses a non-object run-config.json (rc=$rcrlshapecfg; $outrlshapecfg)"

rlshaperesults="$WORK/eval-rollup-shape-results"
cp -R "$rlbase" "$rlshaperesults"
printf '{"results": "not-a-list"}\n' >"$rlshaperesults/eval-demo/r1/grading.json"
outrlshaperesults=$("$evroot/rollup.py" "$rlshaperesults" 2>&1); rcrlshaperesults=$?
[ "$rcrlshaperesults" -eq 2 ] && printf '%s\n' "$outrlshaperesults" | grep -qF 'results must be a list' && pass "evals: rollup refuses a non-list grading.json results" || fail "evals: rollup refuses a non-list grading.json results (rc=$rcrlshaperesults; $outrlshaperesults)"

rlshapemeta="$WORK/eval-rollup-shape-meta"
cp -R "$rlbase" "$rlshapemeta"
printf '["not","an","object"]\n' >"$rlshapemeta/eval-demo/r1/run-meta.json"
outrlshapemeta=$("$evroot/rollup.py" "$rlshapemeta" 2>&1); rcrlshapemeta=$?
[ "$rcrlshapemeta" -eq 2 ] && printf '%s\n' "$outrlshapemeta" | grep -qF 'run-meta.json must be an object' && pass "evals: rollup refuses a non-object run-meta.json" || fail "evals: rollup refuses a non-object run-meta.json (rc=$rcrlshapemeta; $outrlshapemeta)"

el="$WORK/eval-locale"
mkdir -p "$el"

mkdir -p "$el/rollup-reg/eval-demo/r1" "$el/rollup-reg/eval-demo/r2"
printf '{"r1":"treat","r2":"ctrl"}\n' >"$el/rollup-reg/arm-map.json"
printf '{"treatment_arm":"treat","repeats_per_cell":1}\n' >"$el/rollup-reg/run-config.json"
printf '{"id":"demo","assertions":[{"id":"a1","concept":"c"}]}\n' >"$el/rollup-reg/eval-demo/eval-snapshot.json"
printf '{"results":[{"id":"a1","passed":false,"evidence":"q"}]}\n' >"$el/rollup-reg/eval-demo/r1/grading.json"
printf '{"results":[{"id":"a1","passed":true,"evidence":"r"}]}\n' >"$el/rollup-reg/eval-demo/r2/grading.json"
mkdir -p "$el/rollup-empty"
printf '{}\n' >"$el/rollup-empty/arm-map.json"

printf '{"evals":[]}\n' >"$el/spec-empty.json"

mkdir -p "$el/wsp/iteration-1/eval-demo/r1" "$el/wsp/iteration-1/eval-demo/r2"
printf '{"r1":"treat","r2":"ctrl"}\n' >"$el/wsp/iteration-1/arm-map.json"
printf '{"results":[{"id":"a1","passed":true,"evidence":"q"}]}\n' >"$el/wsp/iteration-1/eval-demo/r1/grading.json"
printf '{"results":[{"id":"a1","passed":false,"evidence":"r"}]}\n' >"$el/wsp/iteration-1/eval-demo/r2/grading.json"
printf '{"kinds":{}}\n' >"$el/kinds-empty.json"

mkdir -p "$el/trg/eval-demo/r1/outputs" "$el/trg-empty"
printf '{"results":[{"id":"a1","passed":null,"evidence":null}]}\n' >"$el/trg/eval-demo/r1/grading.json"
printf 'the change reads catalog.ts and writes new.ts\n' >"$el/trg/eval-demo/r1/outputs/session-transcript.txt"
printf -- '--- /dev/null\n+++ b/src/new.ts\n+const a=1\n' >"$el/trg/eval-demo/r1/outputs/diff.patch"

mkdir -p "$el/grade/r0/outputs" "$el/grade-empty/r0/outputs"
printf '{"id":"g","assertions":[{"id":"g/new","concept":"c","class":"artifact","grade":"auto","check":"product_files_added == 1"}]}' >"$el/grade/r0/snap.json"
printf -- '--- /dev/null\n+++ b/src/new.ts\n+const a = 1\n' >"$el/grade/r0/outputs/diff.patch"
printf '{"id":"g","assertions":[]}' >"$el/grade-empty/r0/snap.json"

printf '{"type":"result","result":"ok"}\n' >"$el/usage-empty.txt"


evloc_checks() {
  local evlc="$1" evlabel="$2" out rc

  out=$(LC_ALL="$evlc" "$evroot/rollup.py" --help 2>&1); rc=$?
  [ "$rc" -eq 0 ] && ! printf '%s\n' "$out" | grep -qi 'traceback\|unicodeencodeerror' \
    && pass "evals: rollup.py --help completes under $evlabel" \
    || fail "evals: rollup.py --help completes under $evlabel (rc=$rc; $out)"

  out=$(LC_ALL="$evlc" "$evroot/rollup.py" "$el/rollup-reg" 2>&1); rc=$?
  [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'REGRESSIONS' \
    && pass "evals: rollup.py prints its regression bucket under $evlabel" \
    || fail "evals: rollup.py prints its regression bucket under $evlabel (rc=$rc; $out)"

  out=$(LC_ALL="$evlc" "$evroot/rollup.py" "$el/rollup-empty" 2>&1); rc=$?
  [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -qF 'arm-map.json is empty' \
    && pass "evals: rollup.py refuses an empty arm-map.json under $evlabel" \
    || fail "evals: rollup.py refuses an empty arm-map.json under $evlabel (rc=$rc; $out)"

  out=$(LC_ALL="$evlc" "$evroot/rollup.py" --exclude-eval 2>&1); rc=$?
  [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -qF -- '--exclude-eval requires an eval id' \
    && pass "evals: rollup.py refuses --exclude-eval with no value under $evlabel" \
    || fail "evals: rollup.py refuses --exclude-eval with no value under $evlabel (rc=$rc; $out)"

  out=$(LC_ALL="$evlc" "$evroot/contamination.py" --help 2>&1); rc=$?
  [ "$rc" -eq 0 ] && ! printf '%s\n' "$out" | grep -qi 'traceback\|unicodeencodeerror' \
    && pass "evals: contamination.py --help completes under $evlabel" \
    || fail "evals: contamination.py --help completes under $evlabel (rc=$rc; $out)"

  out=$(LC_ALL="$evlc" "$evroot/contamination.py" "dir:$reporoot" 2>&1); rc=$?
  [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'scenario overlap' \
    && pass "evals: contamination.py reports scenario overlap on the real corpus under $evlabel" \
    || fail "evals: contamination.py reports scenario overlap on the real corpus under $evlabel (rc=$rc; $out)"

  out=$(LC_ALL="$evlc" "$evroot/contamination.py" --spec "$el/spec-empty.json" "dir:$reporoot" 2>&1); rc=$?
  [ "$rc" -eq 0 ] \
    && pass "evals: contamination.py runs against an empty eval spec under $evlabel" \
    || fail "evals: contamination.py runs against an empty eval spec under $evlabel (rc=$rc; $out)"

  out=$(LC_ALL="$evlc" "$evroot/contamination.py" 2>&1); rc=$?
  [ "$rc" -eq 2 ] \
    && pass "evals: contamination.py refuses no refs under $evlabel" \
    || fail "evals: contamination.py refuses no refs under $evlabel (rc=$rc; $out)"

  out=$(LC_ALL="$evlc" "$evroot/fixture_seed.py" --help 2>&1); rc=$?
  [ "$rc" -eq 0 ] \
    && pass "evals: fixture_seed.py --help completes under $evlabel" \
    || fail "evals: fixture_seed.py --help completes under $evlabel (rc=$rc; $out)"

  printf -- '- Areas and package managers: <placeholder>\n' >"$el/contract.md"
  out=$(LC_ALL="$evlc" "$evroot/fixture_seed.py" fill-contract "$el/contract.md" 2>&1); rc=$?
  [ "$rc" -eq 0 ] && grep -qF 'npm only' "$el/contract.md" \
    && pass "evals: fixture_seed.py fill-contract answers a placeholder under $evlabel" \
    || fail "evals: fixture_seed.py fill-contract answers a placeholder under $evlabel (rc=$rc; $out)"

  printf '' >"$el/contract-empty.md"
  out=$(LC_ALL="$evlc" "$evroot/fixture_seed.py" fill-contract "$el/contract-empty.md" 2>&1); rc=$?
  [ "$rc" -eq 0 ] \
    && pass "evals: fixture_seed.py fill-contract completes on an empty file under $evlabel" \
    || fail "evals: fixture_seed.py fill-contract completes on an empty file under $evlabel (rc=$rc; $out)"

  out=$(LC_ALL="$evlc" "$evroot/fixture_seed.py" fill-contract a b c 2>&1); rc=$?
  [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -qF 'takes exactly one path' \
    && pass "evals: fixture_seed.py fill-contract refuses extra arguments under $evlabel" \
    || fail "evals: fixture_seed.py fill-contract refuses extra arguments under $evlabel (rc=$rc; $out)"

  out=$(LC_ALL="$evlc" "$evroot/pooled.py" --help 2>&1); rc=$?
  [ "$rc" -eq 0 ] \
    && pass "evals: pooled.py --help completes under $evlabel" \
    || fail "evals: pooled.py --help completes under $evlabel (rc=$rc; $out)"

  out=$(LC_ALL="$evlc" "$evroot/pooled.py" --baseline "$el/wsp:ctrl" --candidate "$el/wsp:treat" 2>&1); rc=$?
  [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'unique-win' \
    && pass "evals: pooled.py pools a baseline and a candidate workspace under $evlabel" \
    || fail "evals: pooled.py pools a baseline and a candidate workspace under $evlabel (rc=$rc; $out)"

  out=$(LC_ALL="$evlc" "$evroot/pooled.py" --baseline "$el/wsp:ctrl" --candidate "$el/wsp:treat" --kinds "$el/kinds-empty.json" 2>&1); rc=$?
  [ "$rc" -eq 0 ] \
    && pass "evals: pooled.py runs against an empty assertion-kinds file under $evlabel" \
    || fail "evals: pooled.py runs against an empty assertion-kinds file under $evlabel (rc=$rc; $out)"

  out=$(LC_ALL="$evlc" "$evroot/pooled.py" 2>&1); rc=$?
  [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -qF 'both required' \
    && pass "evals: pooled.py refuses missing --baseline/--candidate under $evlabel" \
    || fail "evals: pooled.py refuses missing --baseline/--candidate under $evlabel (rc=$rc; $out)"

  out=$(LC_ALL="$evlc" "$evroot/triage.py" --help 2>&1); rc=$?
  [ "$rc" -eq 0 ] \
    && pass "evals: triage.py --help completes under $evlabel" \
    || fail "evals: triage.py --help completes under $evlabel (rc=$rc; $out)"

  out=$(LC_ALL="$evlc" "$evroot/triage.py" "$el/trg" 2>&1); rc=$?
  [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'UNSURE' \
    && pass "evals: triage.py proposes a verdict for a pending assertion under $evlabel" \
    || fail "evals: triage.py proposes a verdict for a pending assertion under $evlabel (rc=$rc; $out)"

  out=$(LC_ALL="$evlc" "$evroot/triage.py" "$el/trg-empty" 2>&1); rc=$?
  [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qF 'proposed: 0 PASS, 0 FAIL, 0 UNSURE' \
    && pass "evals: triage.py completes over a root with no eval directories under $evlabel" \
    || fail "evals: triage.py completes over a root with no eval directories under $evlabel (rc=$rc; $out)"

  out=$(LC_ALL="$evlc" "$evroot/triage.py" "$el/no-such-root" 2>&1); rc=$?
  [ "$rc" -ne 0 ] && ! printf '%s\n' "$out" | grep -qi 'unicodeencodeerror' \
    && pass "evals: triage.py fails on a missing root without an encoding error under $evlabel" \
    || fail "evals: triage.py fails on a missing root without an encoding error under $evlabel (rc=$rc; $out)"

  out=$(LC_ALL="$evlc" "$evroot/grade.py" --help 2>&1); rc=$?
  [ "$rc" -eq 0 ] \
    && pass "evals: grade.py --help completes under $evlabel" \
    || fail "evals: grade.py --help completes under $evlabel (rc=$rc; $out)"

  out=$(LC_ALL="$evlc" "$evroot/grade.py" "$el/grade/r0" "$el/grade/r0/snap.json" 2>&1); rc=$?
  [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qF 'graded 1 auto' \
    && pass "evals: grade.py grades one auto assertion under $evlabel" \
    || fail "evals: grade.py grades one auto assertion under $evlabel (rc=$rc; $out)"

  out=$(LC_ALL="$evlc" "$evroot/grade.py" "$el/grade-empty/r0" "$el/grade-empty/r0/snap.json" 2>&1); rc=$?
  [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qF 'graded 0 auto' \
    && pass "evals: grade.py completes over a snapshot with no assertions under $evlabel" \
    || fail "evals: grade.py completes over a snapshot with no assertions under $evlabel (rc=$rc; $out)"

  out=$(LC_ALL="$evlc" "$evroot/grade.py" "$el/no-such-run" "$el/no-such-snap" 2>&1); rc=$?
  [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -qF 'no such run directory' \
    && pass "evals: grade.py refuses a missing run directory under $evlabel" \
    || fail "evals: grade.py refuses a missing run directory under $evlabel (rc=$rc; $out)"

  out=$(LC_ALL="$evlc" "$evroot/run_lib.py" --help 2>&1); rc=$?
  [ "$rc" -eq 0 ] \
    && pass "evals: run_lib.py --help completes under $evlabel" \
    || fail "evals: run_lib.py --help completes under $evlabel (rc=$rc; $out)"

  out=$(LC_ALL="$evlc" "$evroot/run_lib.py" gen-run-id 2>&1); rc=$?
  [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qE '^r[0-9a-f]{32}$' \
    && pass "evals: run_lib.py gen-run-id prints a run id under $evlabel" \
    || fail "evals: run_lib.py gen-run-id prints a run id under $evlabel (rc=$rc; $out)"

  out=$(LC_ALL="$evlc" "$evroot/run_lib.py" agent-usage "$el/usage-empty.txt" claude-stream-json 2>&1); rc=$?
  [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qF '"input_tokens": null' \
    && pass "evals: run_lib.py agent-usage reports null usage on an empty stream under $evlabel" \
    || fail "evals: run_lib.py agent-usage reports null usage on an empty stream under $evlabel (rc=$rc; $out)"

  out=$(LC_ALL="$evlc" "$evroot/run_lib.py" no-such-command 2>&1); rc=$?
  [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -qF 'unknown command' \
    && pass "evals: run_lib.py refuses an unknown command under $evlabel" \
    || fail "evals: run_lib.py refuses an unknown command under $evlabel (rc=$rc; $out)"
}

evloc_checks "C" "LC_ALL=C"

eviso=$(locale -a 2>/dev/null | grep -ix -m1 -e 'en_US.ISO8859-1')
if [ -n "$eviso" ]; then
  evloc_checks "$eviso" "LC_ALL=en_US.ISO8859-1"
else
  for evname in \
    "rollup.py --help completes" \
    "rollup.py prints its regression bucket" \
    "rollup.py refuses an empty arm-map.json" \
    "rollup.py refuses --exclude-eval with no value" \
    "contamination.py --help completes" \
    "contamination.py reports scenario overlap on the real corpus" \
    "contamination.py runs against an empty eval spec" \
    "contamination.py refuses no refs" \
    "fixture_seed.py --help completes" \
    "fixture_seed.py fill-contract answers a placeholder" \
    "fixture_seed.py fill-contract completes on an empty file" \
    "fixture_seed.py fill-contract refuses extra arguments" \
    "pooled.py --help completes" \
    "pooled.py pools a baseline and a candidate workspace" \
    "pooled.py runs against an empty assertion-kinds file" \
    "pooled.py refuses missing --baseline/--candidate" \
    "triage.py --help completes" \
    "triage.py proposes a verdict for a pending assertion" \
    "triage.py completes over a root with no eval directories" \
    "triage.py fails on a missing root without an encoding error" \
    "grade.py --help completes" \
    "grade.py grades one auto assertion" \
    "grade.py completes over a snapshot with no assertions" \
    "grade.py refuses a missing run directory" \
    "run_lib.py --help completes" \
    "run_lib.py gen-run-id prints a run id" \
    "run_lib.py agent-usage reports null usage on an empty stream" \
    "run_lib.py refuses an unknown command" \
  ; do
    pass "evals: $evname not exercised — en_US.ISO8859-1 unavailable on this host"
  done
fi


auth_claude_missing_dir="$evfake/auth-claude-missing"
mkdir -p "$auth_claude_missing_dir"
wsc_auth_claude_missing="$evfake/claude workspace-auth-missing"
conf_auth_claude="$evfake/agents-auth-claude.conf"
eval_conf_write "$conf_auth_claude" "$fake_claude" "$evfake/no-such-codex" 1 60
CLAUDE_CONFIG_DIR="$auth_claude_missing_dir" EVALS_AGENTS_CONF="$conf_auth_claude" \
  FAKE_CLAUDE_MODE=ok FAKE_CLAUDE_TURNS=1 \
  "$evsh" --eval scope-question-no-edit --arm treat --treatment-arm treat \
  --agent claude --corpus-ref "$corpus_ref_test" --workspace "$wsc_auth_claude_missing" >/dev/null 2>&1
rc_auth_claude_missing=$?
auth_claude_missing_run=$(find "$wsc_auth_claude_missing/iteration-1/eval-scope-question-no-edit" \
  -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n1)
if [ "$rc_auth_claude_missing" -ne 0 ] && eval_void_clean "$wsc_auth_claude_missing" scope-question-no-edit \
  && grep -q '"status": "agent_auth_rejected"' "$auth_claude_missing_run/run-meta.json" 2>/dev/null; then
  pass "evals: claude refuses to run without claude.ai credentials"
else
  fail "evals: claude refuses to run without claude.ai credentials (rc=$rc_auth_claude_missing)"
fi

auth_claude_apikey_dir="$evfake/auth-claude-apikey"
mkdir -p "$auth_claude_apikey_dir"
printf '{"apiKeyHelper": true}\n' >"$auth_claude_apikey_dir/.credentials.json"
wsc_auth_claude_apikey="$evfake/claude workspace-auth-apikey"
CLAUDE_CONFIG_DIR="$auth_claude_apikey_dir" EVALS_AGENTS_CONF="$conf_auth_claude" \
  FAKE_CLAUDE_MODE=ok FAKE_CLAUDE_TURNS=1 \
  "$evsh" --eval scope-question-no-edit --arm treat --treatment-arm treat \
  --agent claude --corpus-ref "$corpus_ref_test" --workspace "$wsc_auth_claude_apikey" >/dev/null 2>&1
rc_auth_claude_apikey=$?
if [ "$rc_auth_claude_apikey" -ne 0 ] && eval_void_clean "$wsc_auth_claude_apikey" scope-question-no-edit; then
  pass "evals: claude refuses an API-key-style credentials file with no claude.ai subscription"
else
  fail "evals: claude refuses an API-key-style credentials file with no claude.ai subscription (rc=$rc_auth_claude_apikey)"
fi

auth_codex_missing_dir="$evfake/auth-codex-missing"
mkdir -p "$auth_codex_missing_dir"
wsc_auth_codex_missing="$evfake/codex workspace-auth-missing"
conf_auth_codex="$evfake/agents-auth-codex.conf"
eval_conf_write "$conf_auth_codex" "$evfake/no-such-claude" "$fake_codex" 1 60
CODEX_HOME="$auth_codex_missing_dir" EVALS_AGENTS_CONF="$conf_auth_codex" FAKE_CODEX_MODE=ok \
  "$evsh" --eval scope-question-no-edit --arm treat --treatment-arm treat \
  --agent codex --corpus-ref "$corpus_ref_test" --workspace "$wsc_auth_codex_missing" >/dev/null 2>&1
rc_auth_codex_missing=$?
auth_codex_missing_run=$(find "$wsc_auth_codex_missing/iteration-1/eval-scope-question-no-edit" \
  -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n1)
if [ "$rc_auth_codex_missing" -ne 0 ] && eval_void_clean "$wsc_auth_codex_missing" scope-question-no-edit \
  && grep -q '"status": "agent_auth_rejected"' "$auth_codex_missing_run/run-meta.json" 2>/dev/null; then
  pass "evals: codex refuses to run without ChatGPT credentials"
else
  fail "evals: codex refuses to run without ChatGPT credentials (rc=$rc_auth_codex_missing)"
fi

auth_codex_badmode_dir="$evfake/auth-codex-badmode"
mkdir -p "$auth_codex_badmode_dir"
printf '{"auth_mode": "apikey", "OPENAI_API_KEY": "SECRET-SENTINEL-VALUE-should-never-appear"}\n' \
  >"$auth_codex_badmode_dir/auth.json"
wsc_auth_codex_badmode="$evfake/codex workspace-auth-badmode"
CODEX_HOME="$auth_codex_badmode_dir" EVALS_AGENTS_CONF="$conf_auth_codex" FAKE_CODEX_MODE=ok \
  "$evsh" --eval scope-question-no-edit --arm treat --treatment-arm treat \
  --agent codex --corpus-ref "$corpus_ref_test" --workspace "$wsc_auth_codex_badmode" \
  >"$evfake/auth-codex-badmode.out" 2>&1
rc_auth_codex_badmode=$?
if [ "$rc_auth_codex_badmode" -ne 0 ] && eval_void_clean "$wsc_auth_codex_badmode" scope-question-no-edit; then
  pass "evals: codex refuses an auth_mode other than chatgpt"
else
  fail "evals: codex refuses an auth_mode other than chatgpt (rc=$rc_auth_codex_badmode)"
fi
if ! grep -rq 'SECRET-SENTINEL-VALUE-should-never-appear' \
    "$wsc_auth_codex_badmode" "$evfake/auth-codex-badmode.out" 2>/dev/null; then
  pass "evals: a rejected codex auth_mode never surfaces the credential value"
else
  fail "evals: a rejected codex auth_mode never surfaces the credential value"
fi

leak_claude_out="$evfake/leak-claude-out"
leak_codex_out="$evfake/leak-codex-out"
rm -f "$leak_claude_out" "$leak_codex_out"
wsc_leak_claude="$evfake/claude workspace-env-leak"
conf_leak_claude="$evfake/agents-leak-claude.conf"
eval_conf_write "$conf_leak_claude" "$fake_claude" "$evfake/no-such-codex" 1 60
ANTHROPIC_API_KEY="sk-test-should-never-leak-claude" \
  FAKE_ENV_LEAK_VAR=ANTHROPIC_API_KEY FAKE_ENV_LEAK_OUT="$leak_claude_out" \
  EVALS_AGENTS_CONF="$conf_leak_claude" FAKE_CLAUDE_MODE=ok FAKE_CLAUDE_TURNS=1 \
  "$evsh" --eval scope-question-no-edit --arm treat --treatment-arm treat \
  --agent claude --corpus-ref "$corpus_ref_test" --workspace "$wsc_leak_claude" \
  >"$evfake/leak-claude.out" 2>&1
rc_leak_claude=$?
if [ "$rc_leak_claude" -eq 0 ] && [ "$(cat "$leak_claude_out" 2>/dev/null)" = "ABSENT" ]; then
  pass "evals: ANTHROPIC_API_KEY never reaches the claude subprocess environment"
else
  fail "evals: ANTHROPIC_API_KEY never reaches the claude subprocess environment (rc=$rc_leak_claude leak=$(cat "$leak_claude_out" 2>/dev/null))"
fi
if ! grep -rq 'sk-test-should-never-leak-claude' "$wsc_leak_claude" "$evfake/leak-claude.out" 2>/dev/null; then
  pass "evals: the stripped ANTHROPIC_API_KEY value never appears in any captured artifact"
else
  fail "evals: the stripped ANTHROPIC_API_KEY value never appears in any captured artifact"
fi

wsc_leak_codex="$evfake/codex workspace-env-leak"
conf_leak_codex="$evfake/agents-leak-codex.conf"
eval_conf_write "$conf_leak_codex" "$evfake/no-such-claude" "$fake_codex" 1 60
OPENAI_API_KEY="sk-test-should-never-leak-codex" \
  FAKE_ENV_LEAK_VAR=OPENAI_API_KEY FAKE_ENV_LEAK_OUT="$leak_codex_out" \
  EVALS_AGENTS_CONF="$conf_leak_codex" FAKE_CODEX_MODE=ok \
  "$evsh" --eval scope-question-no-edit --arm treat --treatment-arm treat \
  --agent codex --corpus-ref "$corpus_ref_test" --workspace "$wsc_leak_codex" \
  >"$evfake/leak-codex.out" 2>&1
rc_leak_codex=$?
if [ "$rc_leak_codex" -eq 0 ] && [ "$(cat "$leak_codex_out" 2>/dev/null)" = "ABSENT" ]; then
  pass "evals: OPENAI_API_KEY never reaches the codex subprocess environment"
else
  fail "evals: OPENAI_API_KEY never reaches the codex subprocess environment (rc=$rc_leak_codex leak=$(cat "$leak_codex_out" 2>/dev/null))"
fi
if ! grep -rq 'sk-test-should-never-leak-codex' "$wsc_leak_codex" "$evfake/leak-codex.out" 2>/dev/null; then
  pass "evals: the stripped OPENAI_API_KEY value never appears in any captured artifact"
else
  fail "evals: the stripped OPENAI_API_KEY value never appears in any captured artifact"
fi

for lifecycle_mode in duplicate-thread-started resume-thread-mismatch \
  command-missing-command; do
  wscx_lifecycle="$evfake/codex workspace-$lifecycle_mode"
  conf_codex_lifecycle="$evfake/agents-codex-$lifecycle_mode.conf"
  eval_conf_write "$conf_codex_lifecycle" "$evfake/no-such-claude" "$fake_codex" 1 60
  EVALS_AGENTS_CONF="$conf_codex_lifecycle" FAKE_CODEX_MODE="$lifecycle_mode" \
    "$evsh" --eval bootstrap-once --arm treat --treatment-arm treat \
    --agent codex --corpus-ref "$corpus_ref_test" --workspace "$wscx_lifecycle" >/dev/null 2>&1
  rc_lifecycle=$?
  if [ "$rc_lifecycle" -ne 0 ] && eval_void_clean "$wscx_lifecycle" bootstrap-once; then
    pass "evals: codex $lifecycle_mode is rejected as a lifecycle violation"
  else
    fail "evals: codex $lifecycle_mode is rejected as a lifecycle violation (rc=$rc_lifecycle)"
  fi
done

wscx_fc_started="$evfake/codex workspace-file-change-on-started"
conf_codex_fc_started="$evfake/agents-codex-fc-started.conf"
eval_conf_write "$conf_codex_fc_started" "$evfake/no-such-claude" "$fake_codex" 1 60
EVALS_AGENTS_CONF="$conf_codex_fc_started" FAKE_CODEX_MODE=file-change-on-started \
  "$evsh" --eval bootstrap-once --arm treat --treatment-arm treat \
  --agent codex --corpus-ref "$corpus_ref_test" --workspace "$wscx_fc_started" >/dev/null 2>&1
rc_fc_started=$?
rundir_fc=$(find "$wscx_fc_started/iteration-1/eval-bootstrap-once" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n1)
fc_records=$(grep -c '"tool": "codex.file_change"' "$rundir_fc/outputs/trace.jsonl" 2>/dev/null)
if [ "$rc_fc_started" -eq 0 ] && [ "$fc_records" = "3" ]; then
  pass "evals: a file change announced on both lifecycle events is accepted and traced once per turn"
else
  fail "evals: a file change announced on both lifecycle events is accepted and traced once per turn (rc=$rc_fc_started records=$fc_records)"
fi

wscx_resume_ok="$evfake/codex workspace-resume-thread-started-ok"
conf_codex_resume_ok="$evfake/agents-codex-resume-ok.conf"
eval_conf_write "$conf_codex_resume_ok" "$evfake/no-such-claude" "$fake_codex" 1 60
EVALS_AGENTS_CONF="$conf_codex_resume_ok" FAKE_CODEX_MODE=resume-thread-started-ok \
  "$evsh" --eval bootstrap-once --arm treat --treatment-arm treat \
  --agent codex --corpus-ref "$corpus_ref_test" --workspace "$wscx_resume_ok" >/dev/null 2>&1
rc_resume_ok=$?
[ "$rc_resume_ok" -eq 0 ] && pass "evals: a resumed turn may legitimately re-announce the same thread id" || fail "evals: a resumed turn may legitimately re-announce the same thread id (rc=$rc_resume_ok)"

success_child_pid="$evfake/claude-success-child.pid"
success_grandchild_pid="$evfake/claude-success-grandchild.pid"
rm -f "$success_child_pid" "$success_grandchild_pid"
wsc_success_group="$evfake/claude workspace-success-resistant-child"
conf_success_group="$evfake/agents-success-resistant-child.conf"
eval_conf_write "$conf_success_group" "$fake_claude" "$evfake/no-such-codex" 1 60
FAKE_CLAUDE_CHILD_PID="$success_child_pid" FAKE_CLAUDE_GRANDCHILD_PID="$success_grandchild_pid" \
  EVALS_AGENTS_CONF="$conf_success_group" FAKE_CLAUDE_MODE=success-resistant-child FAKE_CLAUDE_TURNS=1 \
  "$evsh" --eval scope-question-no-edit --arm treat --treatment-arm treat \
  --agent claude --corpus-ref "$corpus_ref_test" --workspace "$wsc_success_group" >/dev/null 2>&1
rc_success_group=$?
success_group_run=$(find "$wsc_success_group/iteration-1/eval-scope-question-no-edit" \
  -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n1)
if [ "$rc_success_group" -eq 0 ] && [ -f "$success_group_run/grading.json" ] \
  && recorded_processes_dead "$success_child_pid" "$success_grandchild_pid"; then
  pass "evals: a successful leader exit still terminates the process group it leaves behind before capture"
else
  fail "evals: a successful leader exit still terminates the process group it leaves behind before capture (rc=$rc_success_group)"
fi

for setup_phase in verifier-setup codex-home-setup; do
  setup_ready="$evfake/$setup_phase-ready"
  setup_release="$evfake/$setup_phase-release"
  setup_path="$evfake/$setup_phase-path"
  rm -f "$setup_ready" "$setup_release" "$setup_path"
  setup_workspace="$evfake/workspace-cancel-$setup_phase"
  setup_conf="$evfake/agents-cancel-$setup_phase.conf"
  if [ "$setup_phase" = verifier-setup ]; then
    eval_conf_write "$setup_conf" "$fake_claude" "$evfake/no-such-codex" 1 60
    PATH="$phase_bin:$PATH" FAKE_REAL_BASH="$real_bash" FAKE_REAL_GIT="$real_git" \
      FAKE_REAL_PYTHON="$real_python" FAKE_REAL_CHMOD="$real_chmod" FAKE_REAL_CAT="$real_cat" \
      FAKE_RUN_PHASE="$setup_phase" FAKE_PHASE_READY="$setup_ready" FAKE_PHASE_PATH="$setup_path" \
      FAKE_PHASE_RELEASE="$setup_release" EVALS_AGENTS_CONF="$setup_conf" \
      FAKE_CLAUDE_MODE=ok FAKE_CLAUDE_TURNS=1 \
      "$evsh" --eval scope-question-no-edit --arm treat --treatment-arm treat \
      --agent claude --corpus-ref "$corpus_ref_test" --workspace "$setup_workspace" >/dev/null 2>&1 &
  else
    eval_conf_write "$setup_conf" "$evfake/no-such-claude" "$fake_codex" 1 60
    PATH="$phase_bin:$PATH" FAKE_REAL_BASH="$real_bash" FAKE_REAL_GIT="$real_git" \
      FAKE_REAL_PYTHON="$real_python" FAKE_REAL_CHMOD="$real_chmod" FAKE_REAL_CAT="$real_cat" \
      FAKE_RUN_PHASE="$setup_phase" FAKE_PHASE_READY="$setup_ready" FAKE_PHASE_PATH="$setup_path" \
      FAKE_PHASE_RELEASE="$setup_release" EVALS_AGENTS_CONF="$setup_conf" \
      FAKE_CODEX_MODE=ok \
      "$evsh" --eval scope-question-no-edit --arm treat --treatment-arm treat \
      --agent codex --corpus-ref "$corpus_ref_test" --workspace "$setup_workspace" >/dev/null 2>&1 &
  fi
  setup_runner_pid=$!
  setup_wait=0
  while [ ! -s "$setup_ready" ] && [ "$setup_wait" -lt 100 ]; do
    sleep 0.1
    setup_wait=$((setup_wait + 1))
  done
  setup_dir=$(cat "$setup_path" 2>/dev/null)
  kill -TERM "$setup_runner_pid" 2>/dev/null
  : >"$setup_release"
  wait "$setup_runner_pid" 2>/dev/null
  setup_rc=$?
  if [ "$setup_rc" -ne 0 ] && [ -s "$setup_ready" ] && [ -n "$setup_dir" ] && [ ! -e "$setup_dir" ]; then
    pass "evals: cancellation during $setup_phase leaves no temp directory behind"
  else
    kill -KILL "$setup_runner_pid" 2>/dev/null
    fail "evals: cancellation during $setup_phase leaves no temp directory behind (rc=$setup_rc dir=$setup_dir)"
  fi
done

wscx_append_fail="$evfake/codex workspace-append-fail"
conf_codex_append_fail="$evfake/agents-codex-append-fail.conf"
eval_conf_write "$conf_codex_append_fail" "$evfake/no-such-claude" "$fake_codex" 1 60
PATH="$phase_bin:$PATH" FAKE_REAL_BASH="$real_bash" FAKE_REAL_GIT="$real_git" \
  FAKE_REAL_PYTHON="$real_python" FAKE_REAL_CHMOD="$real_chmod" FAKE_REAL_CAT="$real_cat" \
  FAKE_CODEX_APPEND_FAIL=".codex-turn-1.json" \
  EVALS_AGENTS_CONF="$conf_codex_append_fail" FAKE_CODEX_MODE=ok \
  "$evsh" --eval scope-question-no-edit --arm treat --treatment-arm treat \
  --agent codex --corpus-ref "$corpus_ref_test" --workspace "$wscx_append_fail" >/dev/null 2>&1
rc_append_fail=$?
append_fail_run=$(find "$wscx_append_fail/iteration-1/eval-scope-question-no-edit" \
  -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n1)
if [ "$rc_append_fail" -ne 0 ] && eval_void_clean "$wscx_append_fail" scope-question-no-edit \
  && grep -q '"status": "codex_stream_append_failed"' "$append_fail_run/run-meta.json" 2>/dev/null; then
  pass "evals: a failed codex stream append voids the run with a truthful status"
else
  fail "evals: a failed codex stream append voids the run with a truthful status (rc=$rc_append_fail)"
fi

concurrent_ws="$evfake/claude workspace-concurrent-dry-run"
conf_concurrent="$evfake/agents-concurrent-dry-run.conf"
eval_conf_write "$conf_concurrent" "$evfake/no-such-claude" "$evfake/no-such-codex" 1 60
concurrent_n=8
concurrent_pids=""
ci=1
while [ "$ci" -le "$concurrent_n" ]; do
  EVALS_AGENTS_CONF="$conf_concurrent" "$evsh" --dry-run --eval scope-question-no-edit \
    --arm treat --treatment-arm treat --agent claude --corpus-ref "$corpus_ref_test" \
    --workspace "$concurrent_ws" --iteration 1 >"$evfake/concurrent-dry-$ci.out" 2>&1 &
  concurrent_pids="$concurrent_pids $!"
  ci=$((ci + 1))
done
concurrent_all_ok=1
for cp in $concurrent_pids; do
  wait "$cp" || concurrent_all_ok=0
done
if [ "$concurrent_all_ok" -eq 1 ]; then
  pass "evals: $concurrent_n concurrent dry runs into one iteration all exit 0"
else
  fail "evals: $concurrent_n concurrent dry runs into one iteration all exit 0"
fi
concurrent_cfg_ok=0
if python3 -c '
import json, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
sys.exit(0 if cfg.get("treatment_arm") == "treat" and cfg.get("arm_variable") else 1)
' "$concurrent_ws/iteration-1/run-config.json" 2>/dev/null; then
  concurrent_cfg_ok=1
fi
[ "$concurrent_cfg_ok" -eq 1 ] && pass "evals: concurrent dry runs leave one consistent run-config.json" || fail "evals: concurrent dry runs leave one consistent run-config.json"
concurrent_map_n=$(python3 -c '
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
print(len(m))
' "$concurrent_ws/iteration-1/arm-map.json" 2>/dev/null)
concurrent_dirs_n=$(find "$concurrent_ws/iteration-1/eval-scope-question-no-edit" \
  -mindepth 1 -maxdepth 1 -type d 2>/dev/null | grep -c .)
if [ "$concurrent_map_n" = "$concurrent_n" ] && [ "$concurrent_dirs_n" = "$concurrent_n" ]; then
  pass "evals: arm-map.json retains a complete run mapping across concurrent dry runs, with no lost updates"
else
  fail "evals: arm-map.json retains a complete run mapping across concurrent dry runs, with no lost updates (map=$concurrent_map_n dirs=$concurrent_dirs_n)"
fi
if [ ! -e "$concurrent_ws/iteration-1/.metadata.lock" ]; then
  pass "evals: the iteration metadata lock is released after concurrent dry runs finish"
else
  fail "evals: the iteration metadata lock is released after concurrent dry runs finish"
fi
