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

# n -> "w1 w2 ... wn" (n space-separated words)
words_n() {
  n="$1"; i=1; out=""
  while [ "$i" -le "$n" ]; do out="$out w$i"; i=$((i + 1)); done
  printf '%s' "${out# }"
}

today() { date +%Y-%m-%d; }

# V6-style fixture: manifest version 6 (unquoted), mode ignore-all,
# old-style memory.md with a prose body under the header comment.
make_v6_fixture() {
  fx="$1"
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

archfile="$docroot/.agent/docs/architecture.md"
[ -f "$archfile" ] && grep -qF "| auth-flow.md | working on authentication |" "$archfile" && pass "docs.sh new: architecture.md created with the routing row" || fail "docs.sh new: architecture.md created with the routing row"

flags10=$(status_flags "$docroot")
printf '%s\n' "$flags10" | grep -q '^INDEX:' && fail "docs.sh new: status.sh emits no INDEX flags" || pass "docs.sh new: status.sh emits no INDEX flags"

before10=$(cat "$archfile")
"$doccopy" new --name auth-flow --read-when "duplicate attempt" "$docroot" >/dev/null 2>&1
rc=$?
after10=$(cat "$archfile")
[ "$rc" -ne 0 ] && pass "docs.sh new: duplicate doc rejected" || fail "docs.sh new: duplicate doc rejected"
[ "$before10" = "$after10" ] && pass "docs.sh new: duplicate doc leaves architecture.md unchanged" || fail "docs.sh new: duplicate doc leaves architecture.md unchanged"

# ---- summary ----
total=$((PASS + FAIL))
printf '\n%d/%d checks passed (%d failed)\n' "$PASS" "$total" "$FAIL"
[ "$FAIL" -eq 0 ] && exit 0
exit 1
