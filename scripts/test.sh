#!/usr/bin/env bash
# scripts/test.sh — self-contained smoke tests for node.sh, status.sh,
# log.sh, memory.sh, and docs.sh (the scripts this repo ships under
# scripts/, which node.sh init/update copies into every node).
#
# Usage: scripts/test.sh    (run from anywhere; resolves the repo from its
# own location via $0). Builds every fixture under a fresh mktemp -d
# directory, never writes inside this repo, and removes the directory on
# exit. Prints one ok/FAIL line per check and a summary line at the end.
# Exits 0 only if every check passed.
#
# bash 3.2 / BSD portable: no associative arrays, no `local`-only idioms
# assumed, no GNU-only flags.

set -u

selfdir=$(cd "$(dirname "$0")" && pwd)
reporoot=$(cd "$selfdir/.." && pwd)
NODE="$reporoot/scripts/node.sh"
LOGSH="$reporoot/scripts/log.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/dot-agent-test.XXXXXX")
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }

# ---- helpers ---------------------------------------------------------

# root -> GROOM:/REPAIR:/INDEX: lines from the node's own copy of status.sh
status_flags() {
  "$1/.agent/scripts/status.sh" "$1" 2>&1 | grep -E '^(GROOM|REPAIR|INDEX):'
}

# file, sed-expr -> apply the expression in place. Avoids `sed -i`, whose
# backup-suffix argument differs between BSD and GNU.
subst() {
  sed "$2" "$1" >"$1.tmp" && mv "$1.tmp" "$1"
}

# n -> "w1 w2 ... wn" (n space-separated words)
words_n() {
  n="$1"; i=1; out=""
  while [ "$i" -le "$n" ]; do out="$out w$i"; i=$((i + 1)); done
  printf '%s' "${out# }"
}

today() { date +%Y-%m-%d; }

# V6-style fixture: manifest version 6 (unquoted), mode ignore-all unless
# a second argument overrides it, old-style memory.md with a prose body
# under the header comment.
make_v6_fixture() {
  fx="$1"
  fxmode="${2:-ignore-all}"
  mkdir -p "$fx/.agent/rules" "$fx/.agent/docs"
  cat >"$fx/.agent/purpose.md" <<'EOF'
---
# Do not remove or rewrite this block; update passes may change only `version`.
dot-agent:
  source: https://github.com/dmonteroh/dot-agent
  version: 6
  preset: software-development
  mode: ignore-all        # ignore-all | track-shared | track-all
  children: []              # repo-relative paths to child .agent/ nodes
---

# Purpose

Fixture project for smoke tests.
EOF
  cat >"$fx/.agent/memory.md" <<'EOF'
# Memory
<!-- Prose facts about the project, one paragraph per entry, newest first. -->

This project uses a custom auth flow with rotating tokens. The staging
database resets nightly at 02:00 UTC. Deploy via the internal release
tool, never raw kubectl.
EOF
  cat >"$fx/.agent/session-log.md" <<'EOF'
# Session log
<!-- One entry per session, newest last. -->

- [2026-01-01] (claude) fixture bootstrap for smoke tests (testing). verify: pass.
EOF
  if [ "$fxmode" != "ignore-all" ]; then
    sed "s/^  mode: ignore-all/  mode: $fxmode/" "$fx/.agent/purpose.md" >"$fx/.agent/purpose.md.tmp"
    mv "$fx/.agent/purpose.md.tmp" "$fx/.agent/purpose.md"
  fi
}

# ---- 1. init x 3 presets x 3 modes ----
PRESETS="software-development academic-research domain-knowledge"
MODES="ignore-all track-shared track-all"

for preset in $PRESETS; do
  for mode in $MODES; do
    root="$WORK/init-$preset-$mode"
    mkdir -p "$root"
    "$NODE" init --preset "$preset" --mode "$mode" "$root" >"$WORK/init.out" 2>&1
    rc=$?
    [ "$rc" -eq 0 ] && pass "init $preset/$mode exits 0" || fail "init $preset/$mode exits 0 (rc=$rc)"

    flags=$(status_flags "$root")
    [ -z "$flags" ] && pass "init $preset/$mode: status.sh clean" || fail "init $preset/$mode: status.sh clean ($flags)"

    scriptsok=true
    for f in status.sh log.sh memory.sh docs.sh; do
      [ -x "$root/.agent/scripts/$f" ] || scriptsok=false
    done
    $scriptsok && pass "init $preset/$mode: scripts present and executable" || fail "init $preset/$mode: scripts present and executable"
  done
done

# ---- 2. gitignore per mode ----
gi_ignore="$WORK/init-software-development-ignore-all/.gitignore"
[ "$(cat "$gi_ignore" 2>/dev/null)" = ".agent/" ] && pass "ignore-all: gitignore is exactly '.agent/'" || fail "ignore-all: gitignore is exactly '.agent/'"

gi_shared="$WORK/init-software-development-track-shared/.gitignore"
expected_shared=$(printf '.agent/*\n!.agent/purpose.md\n!.agent/rules/\n!.agent/docs/')
[ "$(cat "$gi_shared" 2>/dev/null)" = "$expected_shared" ] && pass "track-shared: gitignore matches the 4-line allowlist" || fail "track-shared: gitignore matches the 4-line allowlist"

gi_all="$WORK/init-software-development-track-all/.gitignore"
[ ! -e "$gi_all" ] && pass "track-all: no gitignore created" || fail "track-all: no gitignore created"

# pre-existing gitignore is preserved (ignore-all)
root2="$WORK/gitignore-preserve-ignore"
mkdir -p "$root2"
printf 'custom-content\n' >"$root2/.gitignore"
"$NODE" init --preset software-development --mode ignore-all "$root2" >/dev/null 2>&1
expected2=$(printf 'custom-content\n.agent/')
[ "$(cat "$root2/.gitignore" 2>/dev/null)" = "$expected2" ] && pass "ignore-all: pre-existing gitignore content preserved" || fail "ignore-all: pre-existing gitignore content preserved"

# pre-existing gitignore is preserved (track-shared, blank-line separator)
root3="$WORK/gitignore-preserve-shared"
mkdir -p "$root3"
printf 'foo\n' >"$root3/.gitignore"
"$NODE" init --preset software-development --mode track-shared "$root3" >/dev/null 2>&1
expected3=$(printf 'foo\n\n.agent/*\n!.agent/purpose.md\n!.agent/rules/\n!.agent/docs/')
[ "$(cat "$root3/.gitignore" 2>/dev/null)" = "$expected3" ] && pass "track-shared: pre-existing gitignore content preserved" || fail "track-shared: pre-existing gitignore content preserved"

# a fresh, unrelated root is unaffected by another root's init
root4="$WORK/gitignore-fresh-ignore"
mkdir -p "$root4"
"$NODE" init --preset software-development --mode ignore-all "$root4" >/dev/null 2>&1
if [ "$(cat "$root4/.gitignore" 2>/dev/null)" = ".agent/" ] && grep -qF "custom-content" "$root2/.gitignore" 2>/dev/null; then
  pass "re-init into another root does not cross-contaminate gitignores"
else
  fail "re-init into another root does not cross-contaminate gitignores"
fi

# ---- 3. init refusals: existing .agent, unknown --preset, unknown --mode ----
existing="$WORK/existing-agent"
mkdir -p "$existing/.agent"
touch "$existing/.agent/marker"
"$NODE" init --preset software-development --mode ignore-all "$existing" >/dev/null 2>"$WORK/err1"
rc=$?
[ "$rc" -ne 0 ] && pass "init refuses an existing .agent (nonzero exit)" || fail "init refuses an existing .agent (nonzero exit)"
count=$(find "$existing/.agent" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')
[ "$count" -eq 1 ] && pass "init refuses an existing .agent (no changes made)" || fail "init refuses an existing .agent (no changes made, found $count entries)"

unk_preset="$WORK/unknown-preset"
mkdir -p "$unk_preset"
"$NODE" init --preset bogus-preset --mode ignore-all "$unk_preset" >/dev/null 2>"$WORK/err2"
rc=$?
[ "$rc" -ne 0 ] && pass "unknown --preset exits nonzero" || fail "unknown --preset exits nonzero"
[ ! -e "$unk_preset/.agent" ] && pass "unknown --preset creates nothing" || fail "unknown --preset creates nothing"

unk_mode="$WORK/unknown-mode"
mkdir -p "$unk_mode"
"$NODE" init --preset software-development --mode bogus-mode "$unk_mode" >/dev/null 2>"$WORK/err3"
rc=$?
[ "$rc" -ne 0 ] && pass "unknown --mode exits nonzero" || fail "unknown --mode exits nonzero"
[ ! -e "$unk_mode/.agent" ] && pass "unknown --mode creates nothing" || fail "unknown --mode creates nothing"

# ---- 4. update: V6 fixture reaches the mechanical baseline ----
v6root="$WORK/update-v6"
mkdir -p "$v6root"
make_v6_fixture "$v6root"
cp "$v6root/.agent/purpose.md" "$WORK/purpose-before.md"

"$NODE" update "$v6root" >"$WORK/update.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "update on V6 fixture exits 0" || fail "update on V6 fixture exits 0 (rc=$rc)"

backup="$v6root/.agent.backup-v6"
[ -d "$backup" ] && grep -q "custom auth flow" "$backup/memory.md" 2>/dev/null && pass "update: .agent.backup-v6 created with the pre-update memory.md" || fail "update: .agent.backup-v6 created with the pre-update memory.md"

legacy="$v6root/.agent/memory/legacy.md"
[ -f "$legacy" ] && grep -q "custom auth flow" "$legacy" && pass "update: memory/legacy.md holds the prose body" || fail "update: memory/legacy.md holds the prose body"

grep -qF "[Legacy memory](memory/legacy.md)" "$v6root/.agent/memory.md" 2>/dev/null && pass "update: memory.md is the new index with the legacy line" || fail "update: memory.md is the new index with the legacy line"

grep -v '^  version:' "$WORK/purpose-before.md" >"$WORK/pb-noversion"
grep -v '^  version:' "$v6root/.agent/purpose.md" >"$WORK/pa-noversion"
diff -q "$WORK/pb-noversion" "$WORK/pa-noversion" >/dev/null 2>&1 && pass "update: manifest diff touches only the version line" || fail "update: manifest diff touches only the version line"
grep -q '^  version: "6.1"' "$v6root/.agent/purpose.md" 2>/dev/null && pass "update: version is now \"6.1\"" || fail "update: version is now \"6.1\""

flags4=$(status_flags "$v6root")
printf '%s\n' "$flags4" | grep -q '^GROOM: memory/legacy\.md' && pass "update: status.sh flags legacy.md with GROOM" || fail "update: status.sh flags legacy.md with GROOM"
printf '%s\n' "$flags4" | grep -q '^REPAIR:' && fail "update: status.sh shows no REPAIR" || pass "update: status.sh shows no REPAIR"

# ---- 5. update idempotency (second run on the now-6.1 v6root) ----
cp -R "$v6root/.agent" "$WORK/v6root-agent-snapshot"
"$NODE" update "$v6root" >"$WORK/update2.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "update re-run exits 0" || fail "update re-run exits 0 (rc=$rc)"
grep -q "current" "$WORK/update2.out" && pass "update re-run prints 'current'" || fail "update re-run prints 'current'"
diff -r "$WORK/v6root-agent-snapshot" "$v6root/.agent" >/dev/null 2>&1 && pass "update re-run is a no-op (diff -r clean)" || fail "update re-run is a no-op (diff -r clean)"

# ---- 6. update on a node with no manifest ----
nomanifest="$WORK/update-no-manifest"
mkdir -p "$nomanifest/.agent"
touch "$nomanifest/.agent/placeholder"
cp -R "$nomanifest/.agent" "$WORK/nomanifest-snapshot"
"$NODE" update "$nomanifest" >"$WORK/update3.out" 2>"$WORK/update3.err"
rc=$?
[ "$rc" -ne 0 ] && pass "update with no manifest exits nonzero" || fail "update with no manifest exits nonzero"
diff -r "$WORK/nomanifest-snapshot" "$nomanifest/.agent" >/dev/null 2>&1 && pass "update with no manifest leaves the node untouched" || fail "update with no manifest leaves the node untouched"

# ---- 7. update on an already-current (6.1) node ----
current_root="$WORK/init-software-development-track-all"
cp -R "$current_root/.agent" "$WORK/current-snapshot"
"$NODE" update "$current_root" >"$WORK/update4.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "update on a current node exits 0" || fail "update on a current node exits 0 (rc=$rc)"
grep -q "current" "$WORK/update4.out" && pass "update on a current node prints 'current'" || fail "update on a current node prints 'current'"
diff -r "$WORK/current-snapshot" "$current_root/.agent" >/dev/null 2>&1 && pass "update on a current node is a no-op" || fail "update on a current node is a no-op"

# ---- 8. log.sh ----
logroot="$WORK/log-tests"
mkdir -p "$logroot"
"$NODE" init --preset software-development --mode track-all "$logroot" >/dev/null 2>&1
logcopy="$logroot/.agent/scripts/log.sh"
sessionlog="$logroot/.agent/session-log.md"

"$logcopy" --tool claude --area testing --verify pass --summary "smoke test entry for the log script" "$logroot" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "log.sh: valid append exits 0" || fail "log.sh: valid append exits 0"
expected_line="- [$(today)] (claude) smoke test entry for the log script (testing). verify: pass."
grep -qxF -- "$expected_line" "$sessionlog" && pass "log.sh: appended entry matches the expected line exactly" || fail "log.sh: appended entry matches the expected line exactly"

# status.sh's recent-entries block shows entries only, never the header comment
recent=$("$logroot/.agent/scripts/status.sh" "$logroot" 2>&1)
if printf '%s\n' "$recent" | grep -qF -- "$expected_line" && ! printf '%s\n' "$recent" | grep -qF "<!--"; then
  pass "status.sh: recent entries exclude the header comment"
else
  fail "status.sh: recent entries exclude the header comment"
fi

before8=$(cat "$sessionlog")
"$logcopy" --tool claude --area testing --verify pass --summary "$(words_n 26)" "$logroot" >/dev/null 2>&1
rc=$?
after8=$(cat "$sessionlog")
[ "$rc" -ne 0 ] && pass "log.sh: over-ceiling summary (26 words) rejected" || fail "log.sh: over-ceiling summary (26 words) rejected"
[ "$before8" = "$after8" ] && pass "log.sh: over-ceiling summary writes nothing" || fail "log.sh: over-ceiling summary writes nothing"

before8b=$(cat "$sessionlog")
"$logcopy" --tool claude --area testing --verify maybe --summary "bad verify value" "$logroot" >/dev/null 2>&1
rc=$?
after8b=$(cat "$sessionlog")
[ "$rc" -ne 0 ] && pass "log.sh: bad --verify rejected" || fail "log.sh: bad --verify rejected"
[ "$before8b" = "$after8b" ] && pass "log.sh: bad --verify writes nothing" || fail "log.sh: bad --verify writes nothing"

nolog="$WORK/log-no-session-log"
mkdir -p "$nolog/.agent"
"$LOGSH" --tool claude --area testing --verify pass --summary "should not write" "$nolog" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "log.sh: missing session-log.md rejected" || fail "log.sh: missing session-log.md rejected"
[ ! -e "$nolog/.agent/session-log.md" ] && pass "log.sh: missing session-log.md creates nothing" || fail "log.sh: missing session-log.md creates nothing"

# ---- 9. memory.sh new ----
memroot="$WORK/memory-tests"
mkdir -p "$memroot"
"$NODE" init --preset domain-knowledge --mode track-all "$memroot" >/dev/null 2>&1
memcopy="$memroot/.agent/scripts/memory.sh"

"$memcopy" new --slug test-fact --title "Test Fact" --hook "why it matters for tests" --fact "This is a short durable fact used only for the smoke test suite." "$memroot" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "memory.sh new: valid fact exits 0" || fail "memory.sh new: valid fact exits 0"
factfile="$memroot/.agent/memory/test-fact.md"
[ -f "$factfile" ] && pass "memory.sh new: fact file created" || fail "memory.sh new: fact file created"
grep -q '^date: ' "$factfile" 2>/dev/null && grep -q '^scope: project' "$factfile" 2>/dev/null && pass "memory.sh new: fact file has date and scope frontmatter" || fail "memory.sh new: fact file has date and scope frontmatter"
grep -qxF -- "- [Test Fact](memory/test-fact.md) — why it matters for tests" "$memroot/.agent/memory.md" && pass "memory.sh new: index line appended" || fail "memory.sh new: index line appended"

flags9=$(status_flags "$memroot")
[ -z "$flags9" ] && pass "memory.sh new: status.sh clean afterward" || fail "memory.sh new: status.sh clean afterward ($flags9)"

before9=$(cat "$memroot/.agent/memory.md")
"$memcopy" new --slug test-fact --title "Dup" --hook "dup" --fact "duplicate attempt" "$memroot" >/dev/null 2>&1
rc=$?
after9=$(cat "$memroot/.agent/memory.md")
[ "$rc" -ne 0 ] && pass "memory.sh new: duplicate slug rejected" || fail "memory.sh new: duplicate slug rejected"
[ "$before9" = "$after9" ] && pass "memory.sh new: duplicate slug leaves index unchanged" || fail "memory.sh new: duplicate slug leaves index unchanged"

"$memcopy" new --slug "Bad_Slug" --title "Bad" --hook "bad" --fact "invalid slug attempt" "$memroot" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "memory.sh new: invalid slug rejected" || fail "memory.sh new: invalid slug rejected"
[ ! -e "$memroot/.agent/memory/Bad_Slug.md" ] && pass "memory.sh new: invalid slug creates no file" || fail "memory.sh new: invalid slug creates no file"

# title/hook flow into the one-line index entry; brackets and newlines
# there would corrupt its format
"$memcopy" new --slug bad-title --title "Bad [Title]" --hook "ok" --fact "bracketed title attempt" "$memroot" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "memory.sh new: bracketed title rejected" || fail "memory.sh new: bracketed title rejected"
[ ! -e "$memroot/.agent/memory/bad-title.md" ] && pass "memory.sh new: bracketed title creates no file" || fail "memory.sh new: bracketed title creates no file"

"$memcopy" new --slug bad-hook --title "Ok" --hook "line one
line two" --fact "multiline hook attempt" "$memroot" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "memory.sh new: multiline hook rejected" || fail "memory.sh new: multiline hook rejected"
[ ! -e "$memroot/.agent/memory/bad-hook.md" ] && pass "memory.sh new: multiline hook creates no file" || fail "memory.sh new: multiline hook creates no file"

# field-size fact (130 words, the scale of the largest fact observed in a
# mature field instance): accepted, and GROOM-clean on the load path —
# status.sh counts body words only, and its threshold sits above real
# field facts, not below them.
"$memcopy" new --slug field-size --title "Field Size" --hook "field regression case" --fact "$(words_n 130)" "$memroot" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "memory.sh new: field-size fact (130 words) accepted" || fail "memory.sh new: field-size fact (130 words) accepted"
flags9b=$(status_flags "$memroot")
[ -z "$flags9b" ] && pass "memory.sh new: field-size fact stays GROOM-clean" || fail "memory.sh new: field-size fact stays GROOM-clean ($flags9b)"

# outlier fact (well past the review threshold): the write still succeeds
# — no size gate on writes — and status.sh flags it for grooming.
"$memcopy" new --slug outlier --title "Outlier" --hook "outlier alarm case" --fact "$(words_n 320)" "$memroot" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "memory.sh new: outlier fact (320 words) still writes" || fail "memory.sh new: outlier fact (320 words) still writes"
flags9c=$(status_flags "$memroot")
printf '%s\n' "$flags9c" | grep -q '^GROOM: memory/outlier\.md' && pass "memory.sh new: outlier fact draws a GROOM flag" || fail "memory.sh new: outlier fact draws a GROOM flag ($flags9c)"

# ---- 10. docs.sh new ----
docroot="$WORK/docs-tests"
mkdir -p "$docroot"
"$NODE" init --preset academic-research --mode track-all "$docroot" >/dev/null 2>&1
doccopy="$docroot/.agent/scripts/docs.sh"

"$doccopy" new --name auth-flow --read-when "working on authentication" "$docroot" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "docs.sh new: first doc exits 0" || fail "docs.sh new: first doc exits 0"
docfile="$docroot/.agent/docs/auth-flow.md"
[ -f "$docfile" ] && pass "docs.sh new: doc file created" || fail "docs.sh new: doc file created"
firstline=$(head -n1 "$docfile" 2>/dev/null)
[ "$firstline" = "<!-- Read when: working on authentication -->" ] && pass "docs.sh new: doc opens with the Read when: line" || fail "docs.sh new: doc opens with the Read when: line"

# The header contract ships inside the doc, the way every other canonical
# file carries its own: the shape rules are in context when the doc is
# written, not only when status.sh flags it for size.
grep -qF "Agent-facing reference, not a human narrative" "$docfile" && pass "docs.sh new: doc carries its header contract" || fail "docs.sh new: doc carries its header contract"
grep -qF "no tightening or splitting pass may drop an" "$docfile" && pass "docs.sh new: header contract states the no-fact-loss invariant" || fail "docs.sh new: header contract states the no-fact-loss invariant"

archfile="$docroot/.agent/docs/architecture.md"
[ -f "$archfile" ] && grep -qF '### `auth-flow.md`' "$archfile" && grep -qF -- "- **Read when:** working on authentication" "$archfile" && pass "docs.sh new: architecture.md created with the routing entry" || fail "docs.sh new: architecture.md created with the routing entry"
grep -qF -- "- **Sections:**" "$archfile" && pass "docs.sh new: routing entry carries a Sections field" || fail "docs.sh new: routing entry carries a Sections field"

flags10=$(status_flags "$docroot")
printf '%s\n' "$flags10" | grep -q '^INDEX:' && fail "docs.sh new: status.sh emits no INDEX flags" || pass "docs.sh new: status.sh emits no INDEX flags"

before10=$(cat "$archfile")
"$doccopy" new --name auth-flow --read-when "duplicate attempt" "$docroot" >/dev/null 2>&1
rc=$?
after10=$(cat "$archfile")
[ "$rc" -ne 0 ] && pass "docs.sh new: duplicate doc rejected" || fail "docs.sh new: duplicate doc rejected"
[ "$before10" = "$after10" ] && pass "docs.sh new: duplicate doc leaves architecture.md unchanged" || fail "docs.sh new: duplicate doc leaves architecture.md unchanged"

# ---- 11. init: a gitignore without a trailing newline is not spliced ----
nlroot="$WORK/gitignore-no-newline"
mkdir -p "$nlroot"
printf 'node_modules' >"$nlroot/.gitignore"
"$NODE" init --preset software-development --mode ignore-all "$nlroot" >/dev/null 2>&1
expected_nl=$(printf 'node_modules\n.agent/')
[ "$(cat "$nlroot/.gitignore" 2>/dev/null)" = "$expected_nl" ] && pass "init: no-trailing-newline gitignore keeps its pattern and gains .agent/ on its own line" || fail "init: no-trailing-newline gitignore keeps its pattern and gains .agent/ on its own line"

# ---- 12. init at \$HOME writes no gitignore ----
fakehome="$WORK/fake-home"
mkdir -p "$fakehome"
HOME="$fakehome" "$NODE" init --preset software-development --mode ignore-all "$fakehome" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && [ -d "$fakehome/.agent" ] && pass "init at \$HOME exits 0 and creates the node" || fail "init at \$HOME exits 0 and creates the node"
[ ! -e "$fakehome/.gitignore" ] && pass "init at \$HOME skips the gitignore" || fail "init at \$HOME skips the gitignore"

# same guard through mismatched symlink forms of the same directory
realhome="$WORK/real-home"
mkdir -p "$realhome"
ln -s "$realhome" "$WORK/link-home"
HOME="$WORK/link-home" "$NODE" init --preset software-development --mode ignore-all "$realhome" >/dev/null 2>&1
[ ! -e "$realhome/.gitignore" ] && pass "init at \$HOME skips the gitignore through a symlinked HOME" || fail "init at \$HOME skips the gitignore through a symlinked HOME"

# ---- 13. update: track-shared nodes are backed up too ----
tsroot="$WORK/update-v6-track-shared"
mkdir -p "$tsroot"
make_v6_fixture "$tsroot" track-shared
"$NODE" update "$tsroot" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "update on a track-shared V6 fixture exits 0" || fail "update on a track-shared V6 fixture exits 0 (rc=$rc)"
[ -d "$tsroot/.agent.backup-v6" ] && grep -q "custom auth flow" "$tsroot/.agent.backup-v6/memory.md" 2>/dev/null && pass "update: track-shared node backed up before the migration" || fail "update: track-shared node backed up before the migration"

# ---- 14. update: header-less memory.md with --> in the body loses nothing ----
arrowroot="$WORK/update-arrow-body"
mkdir -p "$arrowroot"
make_v6_fixture "$arrowroot"
cat >"$arrowroot/.agent/memory.md" <<'EOF'
# Memory

Fact one: deploys flow build --> stage --> prod, never direct.
Fact two: staging resets nightly.
EOF
"$NODE" update "$arrowroot" >/dev/null 2>&1
legacy_arrow="$arrowroot/.agent/memory/legacy.md"
if grep -q "Fact one" "$legacy_arrow" 2>/dev/null && grep -q "Fact two" "$legacy_arrow" 2>/dev/null; then
  pass "update: --> in a header-less body loses no facts"
else
  fail "update: --> in a header-less body loses no facts"
fi
grep -q '^# Memory' "$legacy_arrow" 2>/dev/null && fail "update: legacy.md does not inherit the # Memory heading" || pass "update: legacy.md does not inherit the # Memory heading"

# a custom heading is content, not scaffolding — it must survive the split
headroot="$WORK/update-custom-heading"
mkdir -p "$headroot"
make_v6_fixture "$headroot"
cat >"$headroot/.agent/memory.md" <<'EOF'
# Deploy facts

Deploys go through the internal release tool only.
EOF
"$NODE" update "$headroot" >/dev/null 2>&1
grep -q '^# Deploy facts' "$headroot/.agent/memory/legacy.md" 2>/dev/null && pass "update: a custom first-line heading survives into legacy.md" || fail "update: a custom first-line heading survives into legacy.md"

# ---- 15. update: a failed backup aborts before touching the node ----
if [ "$(id -u)" -eq 0 ]; then
  pass "update: failed backup exits nonzero (skipped: running as root)"
  pass "update: failed backup leaves memory.md untouched (skipped: running as root)"
else
  roroot="$WORK/update-backup-fails"
  mkdir -p "$roroot"
  make_v6_fixture "$roroot"
  before_ro=$(cat "$roroot/.agent/memory.md")
  chmod 555 "$roroot"
  "$NODE" update "$roroot" >/dev/null 2>&1
  rc=$?
  chmod 755 "$roroot"
  [ "$rc" -ne 0 ] && pass "update: failed backup exits nonzero" || fail "update: failed backup exits nonzero"
  [ "$(cat "$roroot/.agent/memory.md")" = "$before_ro" ] && pass "update: failed backup leaves memory.md untouched" || fail "update: failed backup leaves memory.md untouched"
fi

# ---- 16. update: version guardrails ----
malroot="$WORK/update-bad-version"
mkdir -p "$malroot"
make_v6_fixture "$malroot"
sed 's/^  version: 6$/  version: unknown/' "$malroot/.agent/purpose.md" >"$malroot/.agent/purpose.md.tmp"
mv "$malroot/.agent/purpose.md.tmp" "$malroot/.agent/purpose.md"
cp -R "$malroot/.agent" "$WORK/malroot-snapshot"
"$NODE" update "$malroot" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "update: non-numeric version exits nonzero" || fail "update: non-numeric version exits nonzero"
diff -r "$WORK/malroot-snapshot" "$malroot/.agent" >/dev/null 2>&1 && pass "update: non-numeric version leaves the node untouched" || fail "update: non-numeric version leaves the node untouched"

futroot="$WORK/update-future-version"
mkdir -p "$futroot"
make_v6_fixture "$futroot"
sed 's/^  version: 6$/  version: "6.10"/' "$futroot/.agent/purpose.md" >"$futroot/.agent/purpose.md.tmp"
mv "$futroot/.agent/purpose.md.tmp" "$futroot/.agent/purpose.md"
cp -R "$futroot/.agent" "$WORK/futroot-snapshot"
"$NODE" update "$futroot" >"$WORK/update-fut.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] && grep -q "current" "$WORK/update-fut.out" && pass "update: newer node (6.10 vs 6.1) is a 'current' no-op" || fail "update: newer node (6.10 vs 6.1) is a 'current' no-op"
diff -r "$WORK/futroot-snapshot" "$futroot/.agent" >/dev/null 2>&1 && pass "update: newer node left untouched" || fail "update: newer node left untouched"

# ---- 17. writers: one-line format guards ----
before17=$(cat "$sessionlog")
"$logcopy" --tool claude --area testing --verify pass --summary "line one
line two" "$logroot" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && [ "$(cat "$sessionlog")" = "$before17" ] && pass "log.sh: multiline summary rejected, nothing written" || fail "log.sh: multiline summary rejected, nothing written"

"$logcopy" --tool claude --area testing --verify pass --summary "   " "$logroot" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "log.sh: blank summary rejected" || fail "log.sh: blank summary rejected"

"$logcopy" --tool claude --area "test(ing)" --verify pass --summary "parens in area" "$logroot" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "log.sh: parentheses in --area rejected" || fail "log.sh: parentheses in --area rejected"

"$logcopy" --tool claude --area testing --verify pass --summary "$(words_n 24) — w25" "$logroot" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "log.sh: free-standing em dash does not spend the word ceiling" || fail "log.sh: free-standing em dash does not spend the word ceiling"

before17d=$(cat "$archfile")
"$doccopy" new --name pipe-doc --read-when "a | b" "$docroot" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$docroot/.agent/docs/pipe-doc.md" ] && [ "$(cat "$archfile")" = "$before17d" ] && pass "docs.sh: pipe in --read-when rejected, nothing written" || fail "docs.sh: pipe in --read-when rejected, nothing written"

"$doccopy" new --name arrow-doc --read-when "before --> after" "$docroot" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$docroot/.agent/docs/arrow-doc.md" ] && pass "docs.sh: --> in --read-when rejected" || fail "docs.sh: --> in --read-when rejected"

# ---- 18. memory index parsing is anchored to the line's own link ----
"$memcopy" new --slug pointer-fact --title "Pointer" --hook "detail lives in (memory/expanded-detail.md)" --fact "pointer fact for the anchor regression" "$memroot" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "memory.sh: hook naming another memory path accepted" || fail "memory.sh: hook naming another memory path accepted"
flags18=$(status_flags "$memroot" | grep '^REPAIR:')
[ -z "$flags18" ] && pass "status.sh: hook-mentioned path draws no phantom REPAIR" || fail "status.sh: hook-mentioned path draws no phantom REPAIR ($flags18)"
"$memcopy" new --slug expanded-detail --title "Expanded Detail" --hook "the detail itself" --fact "detail body for the anchor regression" "$memroot" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "memory.sh: slug mentioned in a prior hook still creatable" || fail "memory.sh: slug mentioned in a prior hook still creatable"
flags18b=$(status_flags "$memroot" | grep '^REPAIR:')
[ -z "$flags18b" ] && pass "status.sh: index and fact files agree after the anchor regression" || fail "status.sh: index and fact files agree after the anchor regression ($flags18b)"

# hand-written fact file whose name carries a regex metacharacter
printf -- '---\ndate: 2026-01-01\nscope: project\n---\n\ncpp notes fact body\n' >"$memroot/.agent/memory/c++notes.md"
printf -- '- [Cpp notes](memory/c++notes.md) — cpp gotchas\n' >>"$memroot/.agent/memory.md"
flags18c=$(status_flags "$memroot" | grep '^REPAIR:')
[ -z "$flags18c" ] && pass "status.sh: regex metacharacters in a fact filename draw no phantom REPAIR" || fail "status.sh: regex metacharacters in a fact filename draw no phantom REPAIR ($flags18c)"

# ---- 19. docs: sub-docs and the size trigger ----
subroot="$WORK/docs-subdocs"
mkdir -p "$subroot"
"$NODE" init --preset software-development --mode track-all "$subroot" >/dev/null 2>&1
subdocs="$subroot/.agent/scripts/docs.sh"

"$subdocs" new --name frontend/grids --read-when "grid layouts and gridstack" "$subroot" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "docs.sh: one-level sub-doc path accepted" || fail "docs.sh: one-level sub-doc path accepted (rc=$rc)"
[ -f "$subroot/.agent/docs/frontend/grids.md" ] && pass "docs.sh: sub-doc file created under docs/frontend/" || fail "docs.sh: sub-doc file created under docs/frontend/"
grep -qF '### `frontend/grids.md`' "$subroot/.agent/docs/architecture.md" 2>/dev/null && pass "docs.sh: routing entry carries the relative path" || fail "docs.sh: routing entry carries the relative path"
flags19=$(status_flags "$subroot")
[ -z "$flags19" ] && pass "status.sh: routed sub-doc is INDEX-clean" || fail "status.sh: routed sub-doc is INDEX-clean ($flags19)"

"$subdocs" new --name a/b/c --read-when "too deep" "$subroot" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$subroot/.agent/docs/a" ] && pass "docs.sh: two-level nesting rejected" || fail "docs.sh: two-level nesting rejected"

printf 'no routing header here\n' >"$subroot/.agent/docs/frontend/loose.md"
flags19b=$(status_flags "$subroot")
printf '%s\n' "$flags19b" | grep -qF 'INDEX: docs/frontend/loose.md missing its "Read when:" header' && pass "status.sh: unrouted sub-doc draws the header INDEX flag with its relative path" || fail "status.sh: unrouted sub-doc draws the header INDEX flag with its relative path ($flags19b)"
printf '%s\n' "$flags19b" | grep -qF "INDEX: docs/frontend/loose.md not in the architecture.md routing table" && pass "status.sh: unrouted sub-doc draws the routing INDEX flag" || fail "status.sh: unrouted sub-doc draws the routing INDEX flag"
rm -f "$subroot/.agent/docs/frontend/loose.md"

"$subdocs" new --name huge --read-when "docs size-trigger fixture" "$subroot" >/dev/null 2>&1
printf '%s\n' "$(words_n 2100)" >>"$subroot/.agent/docs/huge.md"
flags19c=$(status_flags "$subroot")
printf '%s\n' "$flags19c" | grep -q '^GROOM: docs/huge\.md' && pass "status.sh: oversized area doc draws a GROOM flag" || fail "status.sh: oversized area doc draws a GROOM flag ($flags19c)"
printf '%s\n' "$flags19c" | grep -q '^GROOM: docs/frontend/grids\.md' && fail "status.sh: small sub-doc stays GROOM-clean" || pass "status.sh: small sub-doc stays GROOM-clean"
# The flag is the only guidance a node with no skills installed gets, so it
# carries the invariant the header contract states.
printf '%s\n' "$flags19c" | grep -qF 'restructure without dropping facts' && pass "status.sh: docs GROOM flag names the no-fact-loss invariant" || fail "status.sh: docs GROOM flag names the no-fact-loss invariant"

# The header contract is an HTML comment, so it must not eat into the
# DOCS_MAX_WORDS budget: 1900 body words stays clean under a 2000 ceiling.
"$subdocs" new --name budget --read-when "docs budget fixture" "$subroot" >/dev/null 2>&1
printf '%s\n' "$(words_n 1900)" >>"$subroot/.agent/docs/budget.md"
flags19d=$(status_flags "$subroot")
printf '%s\n' "$flags19d" | grep -q '^GROOM: docs/budget\.md' && fail "status.sh: header contract costs no body words" || pass "status.sh: header contract costs no body words"
rm -f "$subroot/.agent/docs/budget.md"

# ---- 21. routing entries: hook drift and section drift ----
# The hook is precision, the Sections list is recall. Both live in two
# places and both are checkable, so status.sh checks them.
rt="$WORK/routing"
mkdir -p "$rt"
"$NODE" init --preset software-development --mode track-all "$rt" >/dev/null 2>&1
rtdocs="$rt/.agent/scripts/docs.sh"
rtarch="$rt/.agent/docs/architecture.md"
"$rtdocs" new --name payments --read-when "payment flows and webhooks" "$rt" >/dev/null 2>&1
[ -z "$(status_flags "$rt")" ] && pass "routing: a freshly scaffolded doc is INDEX-clean" || fail "routing: a freshly scaffolded doc is INDEX-clean ($(status_flags "$rt"))"

# A doc that grows sections its entry never learned about.
printf '\n## Webhook retries\n\n## Refund flow\n' >>"$rt/.agent/docs/payments.md"
f21=$(status_flags "$rt")
printf '%s\n' "$f21" | grep -qF 'INDEX: docs/payments.md sections missing from its architecture.md entry' && pass "routing: unlisted sections draw an INDEX flag" || fail "routing: unlisted sections draw an INDEX flag ($f21)"
printf '%s\n' "$f21" | grep -qF 'Webhook retries' && printf '%s\n' "$f21" | grep -qF 'Refund flow' && pass "routing: the flag names every missing section" || fail "routing: the flag names every missing section"

# Listing them clears it, and an entry may say MORE than the heading.
subst "$rtarch" 's/^- \*\*Sections:\*\*$/- **Sections:** Webhook retries (exponential backoff) · Refund flow/'
[ -z "$(status_flags "$rt")" ] && pass "routing: listing the sections clears the flag, enrichment allowed" || fail "routing: listing the sections clears the flag, enrichment allowed ($(status_flags "$rt"))"

# A hook that drifts on one side only.
subst "$rt/.agent/docs/payments.md" 's/^<!-- Read when: payment flows and webhooks -->$/<!-- Read when: payment flows, webhooks, and refunds -->/'
f21b=$(status_flags "$rt")
printf '%s\n' "$f21b" | grep -qF 'INDEX: docs/payments.md hook disagrees with its architecture.md entry' && pass "routing: hook drift draws an INDEX flag" || fail "routing: hook drift draws an INDEX flag ($f21b)"
subst "$rtarch" 's/^- \*\*Read when:\*\* payment flows and webhooks$/- **Read when:** payment flows, webhooks, and refunds/'
[ -z "$(status_flags "$rt")" ] && pass "routing: refreshing both sides clears the hook flag" || fail "routing: refreshing both sides clears the hook flag ($(status_flags "$rt"))"

# ---- 20. status.sh is fully silent on a fresh node ----
fresh19="$WORK/init-academic-research-track-all"
out19=$("$fresh19/.agent/scripts/status.sh" "$fresh19" 2>&1 | grep -v '^TOOLS:')
[ -z "$out19" ] && pass "status.sh: fresh node prints nothing (no stray blank line)" || fail "status.sh: fresh node prints nothing (no stray blank line)"

# ---- 22. cross-preset invariants ----
# The presets are three separate seeds on purpose — a node adapts exactly
# one — but the lines that carry .agent/ mechanics rather than domain
# rules must stay word-for-word identical, or the same rule drifts three
# ways. V6.1 kept that in lockstep by hand; this is the check. Leading
# Comparison starts at the anchor, so a shared sentence may sit after
# domain-specific lead-in text without counting as drift.
shared_line() { # file, anchor -> the matching line from the anchor onward
  grep -F -- "$2" "$1" | head -n 1 |
    awk -v a="$2" '{ i = index($0, a); if (i) print substr($0, i) }'
}
INVARIANTS="Retention_test_for_every_rule_below
Numbers,_defaults,_and_thresholds_carry_stated_provenance
Subagents:_report_continuity_facts
Act_on_GROOM:/REPAIR:/INDEX:_flags
Before_finishing:_append_one_session-log_entry
Area_docs_are_agent-facing_reference
If_a_doc_was_tightened_or_split
This_rubric_is_the_judgement_layer"
for enc in $INVARIANTS; do
  anchor=$(printf '%s' "$enc" | tr '_' ' ')
  a=$(shared_line "$reporoot/presets/software-development.md" "$anchor")
  b=$(shared_line "$reporoot/presets/academic-research.md" "$anchor")
  c=$(shared_line "$reporoot/presets/domain-knowledge.md" "$anchor")
  if [ -z "$a" ] || [ -z "$b" ] || [ -z "$c" ]; then
    fail "presets: \"$anchor\" present in all three"
  elif [ "$a" = "$b" ] && [ "$b" = "$c" ]; then
    pass "presets: \"$anchor\" identical across all three"
  else
    fail "presets: \"$anchor\" identical across all three (drifted)"
  fi
done

# The memory split made memory.md an index; no preset may still instruct
# writing facts into it.
memstale=0
for p in "$reporoot"/presets/*.md; do
  grep -qF "update memory.md only if" "$p" && memstale=1
done
[ "$memstale" -eq 0 ] && pass "presets: no preset still writes facts to memory.md" || fail "presets: no preset still writes facts to memory.md"

# ---- summary ----
total=$((PASS + FAIL))
printf '\n%d/%d checks passed (%d failed)\n' "$PASS" "$total" "$FAIL"
[ "$FAIL" -eq 0 ] && exit 0
exit 1
