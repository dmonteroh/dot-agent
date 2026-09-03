#!/usr/bin/env bash
# scripts/test.sh — self-contained smoke tests for every script this repo
# ships. The gate: it must pass before a change ships.
#
# Full documentation: scripts/docs/test.md.
#
# Usage: scripts/test.sh    (run from anywhere — it resolves the repo from $0)
# Builds every fixture under a fresh mktemp -d, never writes inside this
# repo, removes it on exit. Exits 0 only if every check passed.
#
# bash 3.2 / BSD portable: no associative arrays, no GNU-only flags.

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
# Findings only. stderr used to be folded into stdout and then filtered
# out, so a status.sh that died produced an empty result and every
# `[ -z "$(status_flags ...)" ] && pass` assertion passed over the corpse.
# A crash now emits STATUSFAIL, which no test expects and every test sees.
status_flags() {
  "$1/.agent/scripts/status.sh" "$1" 2>"$WORK/.status-stderr" | grep -E '^(GROOM|REPAIR|INDEX):'
  sf_rc=${PIPESTATUS[0]}
  if [ "$sf_rc" -ne 0 ] || [ -s "$WORK/.status-stderr" ]; then
    echo "STATUSFAIL: rc=$sf_rc stderr=$(tr '\n' ' ' <"$WORK/.status-stderr" | cut -c1-120)"
  fi
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

# root -> complete the judgement half of bootstrap that node.sh cannot do:
# split `## Quality bar` out of contract.md and fill Project guardrails with
# real commands. `node.sh init` deliberately leaves both undone, and
# status.sh REPAIR-flags a node in that state, so every test that expects a
# quiet node runs this first — the same two steps the bootstrap prompt asks
# an agent to perform.
finish_bootstrap() {
  fb_contract="$1/.agent/rules/contract.md"
  awk '/^## Quality bar/ { inq = 1 } inq && /^## / && !/^## Quality bar/ { inq = 0 } !inq' \
    "$fb_contract" >"$fb_contract.body"
  awk '/^## Quality bar/ { inq = 1 } inq && /^## / && !/^## Quality bar/ { inq = 0 } inq' \
    "$fb_contract" >"$1/.agent/rules/quality-bar.md"
  mv "$fb_contract.body" "$fb_contract"
  subst "$fb_contract" 's/^\(- [A-Za-z][^:]*:\) <.*>$/\1 filled at bootstrap/'
}

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

    # node.sh does the mechanical half of bootstrap. The judgement half
    # (guardrails, quality-bar split) is the agent's, and a node with it
    # still undone is not a finished node — status.sh says so.
    flags=$(status_flags "$root")
    printf '%s\n' "$flags" | grep -qF 'Project guardrails still holds template placeholders' && pass "init $preset/$mode: unfilled guardrails draw a REPAIR flag" || fail "init $preset/$mode: unfilled guardrails draw a REPAIR flag ($flags)"
    printf '%s\n' "$flags" | grep -qF 'still contains ## Quality bar' && pass "init $preset/$mode: unsplit quality bar draws a REPAIR flag" || fail "init $preset/$mode: unsplit quality bar draws a REPAIR flag ($flags)"

    finish_bootstrap "$root"
    flags=$(status_flags "$root")
    [ -z "$flags" ] && pass "init $preset/$mode: status.sh clean once bootstrap completes" || fail "init $preset/$mode: status.sh clean once bootstrap completes ($flags)"

    # The shipped set, stated here independently of node.sh's copy loop —
    # deriving it from the script under test would pass a dropped entry.
    missing=""
    for f in status.sh log.sh memory.sh docs.sh links.sh comments.sh; do
      [ -x "$root/.agent/scripts/$f" ] || missing="$missing $f"
    done
    for f in comments.conf status.conf log.conf; do
      [ -f "$root/.agent/scripts/$f" ] || missing="$missing $f"
    done
    [ -z "$missing" ] && pass "init $preset/$mode: every shipped script and starter conf is in place" || fail "init $preset/$mode: every shipped script and starter conf is in place (missing:$missing)"
    # A node receives executables and their confs. This repo's design notes
    # under scripts/docs/ are not a node's to carry.
    [ ! -e "$root/.agent/scripts/docs" ] && pass "init $preset/$mode: scripts/docs is not shipped into the node" || fail "init $preset/$mode: scripts/docs is not shipped into the node"
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
grep -q '^  version: "6.2"' "$v6root/.agent/purpose.md" 2>/dev/null && pass "update: version is now \"6.2\"" || fail "update: version is now \"6.2\""

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

# A pre-release 6.2 node can be version-current while its memory header still
# predates the canonical-source admission test. Update refreshes the contract
# without dropping facts or waiting for another version bump.
stale62="$WORK/current-stale-memory-header"
cp -R "$current_root" "$stale62"
"$stale62/.agent/scripts/memory.sh" new --slug keep --title Keep --hook "keep this hook" --fact "Keep this fact body." "$stale62" >/dev/null 2>&1
subst "$stale62/.agent/memory.md" 's/ Before writing, search purpose.*architecture\.md already routes it\.//'
subst "$stale62/.agent/purpose.md" 's/mode: track-all/mode: track-shared/'
mkdir -p "$stale62/.agent.backup-v6.2"
printf 'earlier backup\n' >"$stale62/.agent.backup-v6.2/marker"
grep -qF 'If one already states it' "$stale62/.agent/memory.md" && fail "update: stale 6.2 fixture actually lacks the new admission test" || pass "update: stale 6.2 fixture lacks the new admission test"
"$NODE" update "$stale62" >/dev/null 2>&1
grep -qF 'If one already states it, update that source or its routing and write no fact.' "$stale62/.agent/memory.md" && pass "update: a version-current node refreshes a stale memory header" || fail "update: a version-current node refreshes a stale memory header"
grep -qxF -- '- [Keep](memory/keep.md) — keep this hook' "$stale62/.agent/memory.md" && grep -qF 'Keep this fact body.' "$stale62/.agent/memory/keep.md" && pass "update: refreshing the stale memory header keeps facts and index lines" || fail "update: refreshing the stale memory header keeps facts and index lines"
if [ -f "$stale62/.agent.backup-v6.2/marker" ] \
  && [ -f "$stale62/.agent.backup-v6.2-shape/memory.md" ] \
  && ! grep -qF 'If one already states it' "$stale62/.agent.backup-v6.2-shape/memory.md"; then
  pass "update: same-version shape backup does not collide with an earlier backup"
else
  fail "update: same-version shape backup does not collide with an earlier backup"
fi

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
finish_bootstrap "$memroot"
memcopy="$memroot/.agent/scripts/memory.sh"

out9=$("$memcopy" new --slug test-fact --title "Test Fact" --hook "why it matters for tests" --fact "This is a short durable fact used only for the smoke test suite." "$memroot" 2>&1)
rc=$?
[ "$rc" -eq 0 ] && pass "memory.sh new: valid fact exits 0" || fail "memory.sh new: valid fact exits 0"
factfile="$memroot/.agent/memory/test-fact.md"
[ -f "$factfile" ] && pass "memory.sh new: fact file created" || fail "memory.sh new: fact file created"
grep -q '^date: ' "$factfile" 2>/dev/null && grep -q '^scope: project' "$factfile" 2>/dev/null && pass "memory.sh new: fact file has date and scope frontmatter" || fail "memory.sh new: fact file has date and scope frontmatter"
grep -qxF -- "- [Test Fact](memory/test-fact.md) — why it matters for tests" "$memroot/.agent/memory.md" && pass "memory.sh new: index line appended" || fail "memory.sh new: index line appended"

# memory/ is the one tier that carries no header contract: it lives once in
# memory.md's header, and memory.sh says it out loud to the session that is
# writing.
grep -q '<!--' "$factfile" && fail "memory.sh new: the fact file carries no header contract" || pass "memory.sh new: the fact file carries no header contract"
printf '%s\n' "$out9" | grep -qF 'supersede in place' && pass "memory.sh new: the write reminds the writer of the contract" || fail "memory.sh new: the write reminds the writer of the contract ($out9)"
grep -qF 'fact files carry no header of their' "$memroot/.agent/memory.md" && pass "memory.md's header carries the contract for memory/" || fail "memory.md's header carries the contract for memory/"
grep -qF 'Keep a fact only if work in this node changes when it is' "$memroot/.agent/memory.md" && pass "memory.md's header states the retention test" || fail "memory.md's header states the retention test"
grep -qF 'If one already states it, update that source or its routing and write no fact.' "$memroot/.agent/memory.md" && pass "memory.md's header rejects facts duplicated from canonical sources" || fail "memory.md's header rejects facts duplicated from canonical sources"
printf '%s\n' "$out9" | grep -qF 'search purpose, rules, routed docs, source, and existing facts first' && pass "memory.sh new: the writer output repeats the source check" || fail "memory.sh new: the writer output repeats the source check ($out9)"

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

# title/hook flow into the one-line index entry. Brackets and newlines
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

# A fact well inside one fact's natural size: accepted, and GROOM-clean on
# the load path — status.sh counts body words only, and its threshold sits
# above a single fact, not below it.
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
finish_bootstrap "$docroot"
doccopy="$docroot/.agent/scripts/docs.sh"

"$doccopy" new --name auth-flow --read-when "working on authentication" "$docroot" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "docs.sh new: first doc exits 0" || fail "docs.sh new: first doc exits 0"
docfile="$docroot/.agent/docs/auth-flow.md"
[ -f "$docfile" ] && pass "docs.sh new: doc file created" || fail "docs.sh new: doc file created"
firstline=$(head -n1 "$docfile" 2>/dev/null)
[ "$firstline" = "<!-- Read when: working on authentication -->" ] && pass "docs.sh new: doc opens with the Read when: line" || fail "docs.sh new: doc opens with the Read when: line"

# No shape contract in the doc. docs/ is an N-file tier — a doc per area,
# per split, per reference — so a header there is paid by every session
# that only reads one of them, and the preset loaded in all of them
# already states the same rules. The contract reaches the session doing
# the writing through this script's output instead.
grep -qF "Agent-facing reference, not a human narrative" "$docfile" && fail "docs.sh new: the doc carries no shape header" || pass "docs.sh new: the doc carries no shape header"
[ "$(wc -l <"$docfile")" -eq 2 ] && pass "docs.sh new: the doc is its hook and its title, nothing else" || fail "docs.sh new: the doc is its hook and its title, nothing else"
docout=$("$doccopy" new --name payments --read-when "touching billing" "$docroot" 2>&1)
printf '%s\n' "$docout" | grep -qF "one-fact-per-line bullets" && pass "docs.sh new: the output states the shape contract" || fail "docs.sh new: the output states the shape contract"
printf '%s\n' "$docout" | grep -qF "may drop a name, value, command, path, or gotcha" && pass "docs.sh new: the output states the no-fact-loss invariant" || fail "docs.sh new: the output states the no-fact-loss invariant"

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

# A node that already split its memory carries the old shape: a 97-word
# header in every fact file and a memory.md header covering only the index.
# The split step skips it — memory/ is present — so without this the whole
# change would reach new nodes only.
hdrroot="$WORK/update-fact-headers"
mkdir -p "$hdrroot/.agent/memory"
make_v6_fixture "$hdrroot"
cat >"$hdrroot/.agent/memory.md" <<'EOF'
# Memory
<!-- Index only, one line per fact file, newest last; reorder by
relevance only when grooming.
Format: - [Title](memory/slug.md) — hook. -->

- [Auth flow](memory/auth-flow.md) — touching login
EOF
cat >"$hdrroot/.agent/memory/auth-flow.md" <<'EOF'
---
date: 2026-01-01
scope: project
type: fact
---
<!-- One durable fact per file: one decision, one preference, one
constraint — non-obvious operating facts. If two halves of this file
would be superseded at different times, they are two files. -->

Auth uses rotating tokens, refreshed every 900 seconds.
EOF
mkdir -p "$hdrroot/.agent/docs/billing"
for hdrdoc in "$hdrroot/.agent/docs/billing.md" "$hdrroot/.agent/docs/billing/refunds.md"; do
  cat >"$hdrdoc" <<'EOF'
<!-- Read when: touching billing -->
# Billing
<!-- Agent-facing reference, not a human narrative: facts belong in tables or one-fact-per-line bullets. Prose carries only the *why*. -->

Refunds settle in 3 business days.
EOF
done
"$NODE" update "$hdrroot" >/dev/null 2>&1
hdrfact="$hdrroot/.agent/memory/auth-flow.md"
for hdrdoc in "$hdrroot/.agent/docs/billing.md" "$hdrroot/.agent/docs/billing/refunds.md"; do
  hdrlabel=${hdrdoc#"$hdrroot/.agent/"}
  grep -qF 'Agent-facing reference' "$hdrdoc" 2>/dev/null && fail "update: $hdrlabel loses its shape header" || pass "update: $hdrlabel loses its shape header"
  head -n1 "$hdrdoc" | grep -qxF '<!-- Read when: touching billing -->' && pass "update: $hdrlabel keeps its Read when: hook" || fail "update: $hdrlabel keeps its Read when: hook"
  grep -qF 'Refunds settle in 3 business days.' "$hdrdoc" 2>/dev/null && pass "update: $hdrlabel keeps its body" || fail "update: $hdrlabel keeps its body"
done
[ ! -e "$hdrroot/.agent/.doc-headers.tmp" ] && pass "update: the doc-header migration leaves no scratch file" || fail "update: the doc-header migration leaves no scratch file"
grep -q '<!--' "$hdrfact" 2>/dev/null && fail "update: an existing fact file loses its header contract" || pass "update: an existing fact file loses its header contract"
grep -qF 'Auth uses rotating tokens, refreshed every 900 seconds.' "$hdrfact" 2>/dev/null && pass "update: stripping the header keeps the fact" || fail "update: stripping the header keeps the fact"
grep -q '^date: 2026-01-01' "$hdrfact" 2>/dev/null && grep -q '^type: fact' "$hdrfact" 2>/dev/null && pass "update: stripping the header keeps the frontmatter" || fail "update: stripping the header keeps the frontmatter"
grep -qF 'This contract covers memory/ too' "$hdrroot/.agent/memory.md" 2>/dev/null && pass "update: memory.md's header gains the memory/ contract" || fail "update: memory.md's header gains the memory/ contract"
grep -qxF -- "- [Auth flow](memory/auth-flow.md) — touching login" "$hdrroot/.agent/memory.md" && pass "update: rewriting the header keeps the index lines" || fail "update: rewriting the header keeps the index lines"
[ ! -e "$hdrroot/.agent/memory/legacy.md" ] && pass "update: an already-split node grows no legacy.md" || fail "update: an already-split node grows no legacy.md"

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
finish_bootstrap "$subroot"
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
finish_bootstrap "$rt"
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

# ---- 20. status.sh on a bootstrapped node: no findings, one LOAD line ----
fresh19="$WORK/init-academic-research-track-all"
out19all=$("$fresh19/.agent/scripts/status.sh" "$fresh19" 2>&1 | grep -v '^TOOLS:')
out19=$(printf '%s\n' "$out19all" | grep -v '^LOAD:')
[ -z "$out19" ] && pass "status.sh: bootstrapped node prints no findings (no stray blank line)" || fail "status.sh: bootstrapped node prints no findings (no stray blank line)"
[ "$(printf '%s\n' "$out19all" | grep -c '^LOAD:')" = "1" ] && pass "status.sh: exactly one LOAD line on a quiet node" || fail "status.sh: exactly one LOAD line on a quiet node ($out19all)"

# ---- 23. bootstrap-completion checks: guardrails and entry-point mirror ----
# The judgement half of bootstrap left no evidence before these checks, so a
# half-done node was indistinguishable from a finished one.
bc="$WORK/bootstrap-checks"
mkdir -p "$bc"
"$NODE" init --preset software-development --mode track-all "$bc" >/dev/null 2>&1
finish_bootstrap "$bc"
[ -z "$(status_flags "$bc")" ] && pass "bootstrap: a completed node is clean" || fail "bootstrap: a completed node is clean ($(status_flags "$bc"))"

# A filled guardrail whose command carries its own <placeholder> token is
# not a stub: the shipped placeholders are multi-word, real flags are not.
printf -- '- Test: `pytest -k <name>`\n' >>"$bc/.agent/rules/contract.md"
f23=$(status_flags "$bc")
printf '%s\n' "$f23" | grep -qF 'template placeholders' && fail "bootstrap: a single-token <name> in a real command is not a placeholder" || pass "bootstrap: a single-token <name> in a real command is not a placeholder"

# Entry points must stay identical, and only real entry points are compared.
cp "$reporoot/templates/entry-point.md" "$bc/CLAUDE.md"
cp "$reporoot/templates/entry-point.md" "$bc/AGENTS.md"
[ -z "$(status_flags "$bc")" ] && pass "entry points: identical mirrors draw no flag" || fail "entry points: identical mirrors draw no flag ($(status_flags "$bc"))"

printf '\nAn extra line only this tool sees.\n' >>"$bc/AGENTS.md"
f23b=$(status_flags "$bc")
printf '%s\n' "$f23b" | grep -qF 'REPAIR: AGENTS.md differs from CLAUDE.md' && pass "entry points: drift draws a REPAIR flag" || fail "entry points: drift draws a REPAIR flag ($f23b)"

cp "$reporoot/templates/entry-point.md" "$bc/AGENTS.md"
mkdir -p "$bc/.github"
printf '# Team conventions\n\nUse conventional commits.\n' >"$bc/.github/copilot-instructions.md"
[ -z "$(status_flags "$bc")" ] && pass "entry points: a file that never references status.sh is not a mirror" || fail "entry points: a file that never references status.sh is not a mirror ($(status_flags "$bc"))"

# ---- 24. native memory: the setting the sole-durable-store claim rests on ----
nm="$WORK/native-memory"
mkdir -p "$nm/.claude"
"$NODE" init --preset software-development --mode track-all "$nm" >/dev/null 2>&1
finish_bootstrap "$nm"
f24=$(HOME="$WORK/nm-empty-home" status_flags "$nm")
printf '%s\n' "$f24" | grep -qF 'autoMemoryEnabled is set nowhere' && pass "native memory: an unconfigured .claude/ draws a REPAIR flag" || fail "native memory: an unconfigured .claude/ draws a REPAIR flag ($f24)"

printf '{ "autoMemoryEnabled": true }\n' >"$nm/.claude/settings.json"
f24b=$(HOME="$WORK/nm-empty-home" status_flags "$nm")
printf '%s\n' "$f24b" | grep -qF 'sets autoMemoryEnabled true' && pass "native memory: an enabled store draws a REPAIR flag" || fail "native memory: an enabled store draws a REPAIR flag ($f24b)"

printf '{ "autoMemoryEnabled": false }\n' >"$nm/.claude/settings.json"
f24c=$(HOME="$WORK/nm-empty-home" status_flags "$nm")
[ -z "$f24c" ] && pass "native memory: disabled clears the flag" || fail "native memory: disabled clears the flag ($f24c)"

# A node that carries no setting of its own inherits the user-level one.
rm -f "$nm/.claude/settings.json"
mkdir -p "$WORK/nm-home/.claude"
printf '{ "autoMemoryEnabled": false }\n' >"$WORK/nm-home/.claude/settings.json"
f24d=$(HOME="$WORK/nm-home" status_flags "$nm")
[ -z "$f24d" ] && pass "native memory: a user-level setting is inherited, not re-flagged" || fail "native memory: a user-level setting is inherited, not re-flagged ($f24d)"

# ---- 25. learned.md: the word trigger fires under the rule ceiling ----
lr="$WORK/learned-words"
mkdir -p "$lr"
"$NODE" init --preset software-development --mode track-all "$lr" >/dev/null 2>&1
finish_bootstrap "$lr"
i=1
while [ "$i" -le 40 ]; do
  printf -- '- [2026-01-01] %s\n' "$(words_n 70)" >>"$lr/.agent/rules/learned.md"
  i=$((i + 1))
done
f25=$(status_flags "$lr")
printf '%s\n' "$f25" | grep -qF 'GROOM: learned.md > 2400 words under the rule count' && pass "learned: 40 bloated rules trip the word trigger below the 60-rule ceiling" || fail "learned: 40 bloated rules trip the word trigger below the 60-rule ceiling ($f25)"

lr2="$WORK/learned-lean"
mkdir -p "$lr2"
"$NODE" init --preset software-development --mode track-all "$lr2" >/dev/null 2>&1
finish_bootstrap "$lr2"
i=1
while [ "$i" -le 40 ]; do
  printf -- '- [2026-01-01] %s\n' "$(words_n 40)" >>"$lr2/.agent/rules/learned.md"
  i=$((i + 1))
done
[ -z "$(status_flags "$lr2")" ] && pass "learned: 40 on-target rules stay clean" || fail "learned: 40 on-target rules stay clean ($(status_flags "$lr2"))"

# ---- 26. the reference tier is never routed and never size-triggered ----
rf="$WORK/references"
mkdir -p "$rf"
"$NODE" init --preset software-development --mode track-all "$rf" >/dev/null 2>&1
finish_bootstrap "$rf"
"$rf/.agent/scripts/docs.sh" new --name backend --read-when "backend services" "$rf" >/dev/null 2>&1
mkdir -p "$rf/.agent/docs/backend/references"
printf '# Full error-code table\n\n%s\n' "$(words_n 4000)" >"$rf/.agent/docs/backend/references/error-codes.md"
f26=$(status_flags "$rf")
[ -z "$f26" ] && pass "references: an unrouted, oversized reference file draws no flag" || fail "references: an unrouted, oversized reference file draws no flag ($f26)"

# The exclusion is the path segment, not the depth: docs/references/ too.
mkdir -p "$rf/.agent/docs/references"
printf '# Vendor spec dump\n\n%s\n' "$(words_n 4000)" >"$rf/.agent/docs/references/vendor.md"
f26b=$(status_flags "$rf")
[ -z "$f26b" ] && pass "references: docs/references/ is excluded too" || fail "references: docs/references/ is excluded too ($f26b)"

# A normal sub-doc in the same area is still checked, so the exclusion is
# scoped rather than a hole in the docs walk.
printf 'no routing header\n' >"$rf/.agent/docs/backend/queues.md"
f26c=$(status_flags "$rf")
printf '%s\n' "$f26c" | grep -qF 'INDEX: docs/backend/queues.md' && pass "references: a real sub-doc beside references/ is still checked" || fail "references: a real sub-doc beside references/ is still checked ($f26c)"

# ---- 27. memory.sh --type ----
mt="$WORK/memory-type"
mkdir -p "$mt"
"$NODE" init --preset software-development --mode track-all "$mt" >/dev/null 2>&1
finish_bootstrap "$mt"
mtsh="$mt/.agent/scripts/memory.sh"
"$mtsh" new --slug api-docs --title "Vendor API docs" --hook "integrating the vendor API" --fact "https://example.invalid/docs" --type reference "$mt" >/dev/null 2>&1
grep -q '^type: reference' "$mt/.agent/memory/api-docs.md" 2>/dev/null && pass "memory.sh: --type reference lands in the frontmatter" || fail "memory.sh: --type reference lands in the frontmatter"

"$mtsh" new --slug plain --title "Plain" --hook "default type" --fact "a durable decision" "$mt" >/dev/null 2>&1
grep -q '^type: fact' "$mt/.agent/memory/plain.md" 2>/dev/null && pass "memory.sh: type defaults to fact" || fail "memory.sh: type defaults to fact"

"$mtsh" new --slug bogus --title "Bogus" --hook "bad type" --fact "x" --type notes "$mt" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$mt/.agent/memory/bogus.md" ] && pass "memory.sh: an unknown --type is rejected, nothing written" || fail "memory.sh: an unknown --type is rejected, nothing written"
[ -z "$(status_flags "$mt")" ] && pass "memory.sh: typed facts leave the node clean" || fail "memory.sh: typed facts leave the node clean ($(status_flags "$mt"))"

# ---- 22. cross-preset invariants, driven by presets/_shared.md ----
# The presets stay three separate seeds — a node adapts exactly one — but
# the text carrying .agent/ mechanics rather than domain rules must be
# word-for-word identical, or the same rule drifts three ways. V6.1 kept
# that in lockstep by hand and it slipped. presets/_shared.md is the list.
# This is the check that makes the list load-bearing rather than a comment.
# Each fenced block there is a substring that must appear verbatim in all
# three presets — a substring, not a whole line, because a shared sentence
# may follow domain-specific lead-in text.
sharedfile="$reporoot/presets/_shared.md"
[ -f "$sharedfile" ] && pass "presets: _shared.md exists" || fail "presets: _shared.md exists"

blockcount=0
while IFS= read -r block; do
  [ -n "$block" ] || continue
  blockcount=$((blockcount + 1))
  hits=0
  for p in software-development academic-research domain-knowledge; do
    grep -qF -- "$block" "$reporoot/presets/$p.md" && hits=$((hits + 1))
  done
  label=$(printf '%s' "$block" | cut -c1-52)
  # ${label} is braced, not bare. bash 3.2 parses an unbraced $name with
  # locale-aware isalnum(), so in any locale whose alnum table covers 0xE2 —
  # the first byte of the following "…" — that byte is absorbed into the
  # variable name and `set -u` kills the run. ISO-8859-1 reads it as â and
  # UTF-8 accepts it too. LC_ALL=C is the one CI leg where it cannot fire,
  # so the ISO8859-1 leg is what guards this line.
  [ "$hits" -eq 3 ] && pass "shared: \"${label}…\" in all three presets" || fail "shared: \"${label}…\" in all three presets (found in $hits)"
done <<EOF
$(awk '/^```/ { inb = !inb; next } inb && NF { print }' "$sharedfile")
EOF

[ "$blockcount" -ge 10 ] && pass "presets: _shared.md tracks the shared text ($blockcount blocks)" || fail "presets: _shared.md tracks the shared text (only $blockcount blocks)"

# _shared.md is a maintainer file, never a node's contract.md.
noderoot_sh="$WORK/preset-underscore"
mkdir -p "$noderoot_sh"
"$NODE" init --preset _shared --mode ignore-all "$noderoot_sh" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$noderoot_sh/.agent" ] && pass "node.sh: --preset _shared is rejected, nothing created" || fail "node.sh: --preset _shared is rejected, nothing created"

# The memory split made memory.md an index. No preset may still instruct
# writing facts into it.
memstale=0
for p in "$reporoot"/presets/*.md; do
  grep -qF "update memory.md only if" "$p" && memstale=1
done
[ "$memstale" -eq 0 ] && pass "presets: no preset still writes facts to memory.md" || fail "presets: no preset still writes facts to memory.md"

# ---- 28. links.sh: the orphan and broken-link audit ----
# The reference tier's stated weakness is that an uncited reference is
# unreachable and nothing on the load path can see it. This is the thing
# that sees it — off the load path, run on demand.
lk="$WORK/links"
mkdir -p "$lk"
"$NODE" init --preset software-development --mode track-all "$lk" >/dev/null 2>&1
finish_bootstrap "$lk"
LINKS="$lk/.agent/scripts/links.sh"
"$LINKS" "$lk" >"$WORK/links-clean.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "links.sh: exits 0" || fail "links.sh: exits 0 (rc=$rc)"
grep -q 'no orphans or broken links' "$WORK/links-clean.out" && pass "links.sh: a fresh node reports clean" || fail "links.sh: a fresh node reports clean ($(cat "$WORK/links-clean.out"))"

"$lk/.agent/scripts/docs.sh" new --name backend --read-when "backend services" "$lk" >/dev/null 2>&1
mkdir -p "$lk/.agent/docs/backend/references"
printf '# Error codes\n\nthe full table\n' >"$lk/.agent/docs/backend/references/error-codes.md"
out28=$("$LINKS" "$lk" 2>&1)
printf '%s\n' "$out28" | grep -qF 'ORPHAN: docs/backend/references/error-codes.md' && pass "links.sh: an uncited reference file is reported" || fail "links.sh: an uncited reference file is reported ($out28)"
printf '%s\n' "$out28" | grep -qF 'unreachable' && pass "links.sh: the reference orphan explains why it matters" || fail "links.sh: the reference orphan explains why it matters"

printf '\nFull table: `docs/backend/references/error-codes.md`\n' >>"$lk/.agent/docs/backend.md"
out28b=$("$LINKS" "$lk" 2>&1)
printf '%s\n' "$out28b" | grep -q '^ORPHAN:' && fail "links.sh: citing the reference clears the orphan" || pass "links.sh: citing the reference clears the orphan"

# A routed doc that cites a node path which does not exist.
printf '\nSee `docs/backend/queues.md` for the queue design.\n' >>"$lk/.agent/docs/backend.md"
out28c=$("$LINKS" "$lk" 2>&1)
printf '%s\n' "$out28c" | grep -qF 'BROKEN: .agent/docs/backend.md cites docs/backend/queues.md' && pass "links.sh: a dangling node path is reported" || fail "links.sh: a dangling node path is reported ($out28c)"

# Project paths are out of scope: the node does not manage their lifecycle,
# and treating them as findings buries the real ones.
printf '\nBrief: `temp/some-task-board.md`, source `src/app/main.md`.\n' >>"$lk/.agent/docs/backend.md"
out28d=$("$LINKS" "$lk" 2>&1)
printf '%s\n' "$out28d" | grep -qF 'temp/some-task-board.md' && fail "links.sh: paths outside the node are out of scope" || pass "links.sh: paths outside the node are out of scope"

# A loose basename resolves against the whole node: docs cite `learned.md`,
# not `rules/learned.md`.
printf '\nSee `learned.md` for the accumulated corrections.\n' >>"$lk/.agent/docs/backend.md"
out28e=$("$LINKS" "$lk" 2>&1)
printf '%s\n' "$out28e" | grep -qF 'cites learned.md' && fail "links.sh: a loose basename resolves against the node" || pass "links.sh: a loose basename resolves against the node"

# A bare name the node cannot resolve is as likely a project file as a node
# one — memory facts name files like `SKILL.md` constantly, and a project
# file often sits in a subdirectory rather than at the project root.
mkdir -p "$lk/skills/testing"
printf '# Testing\n' >"$lk/skills/testing/SKILL.md"
printf '\nThe bar lives in `SKILL.md`, and `skills/testing/SKILL.md` implements it.\n' >>"$lk/.agent/docs/backend.md"
out28i=$("$LINKS" "$lk" 2>&1)
printf '%s\n' "$out28i" | grep -qF 'cites SKILL.md' && fail "links.sh: a bare name held by the project is not broken" || pass "links.sh: a bare name held by the project is not broken"
printf '%s\n' "$out28i" | grep -qF 'skills/testing/SKILL.md' && fail "links.sh: an out-of-model .agent directory is not audited as a target" || pass "links.sh: an out-of-model .agent directory is not audited as a target"

# The resolution is by name, not a blanket amnesty: a name no one holds is
# still the finding the audit exists to produce.
printf '\nAlso `nowhere-at-all.md`.\n' >>"$lk/.agent/docs/backend.md"
out28j=$("$LINKS" "$lk" 2>&1)
printf '%s\n' "$out28j" | grep -qF 'cites nowhere-at-all.md' && pass "links.sh: a name neither node nor project holds is still broken" || fail "links.sh: a name neither node nor project holds is still broken ($out28j)"

# session-log.md is a historical record: an entry naming a brief that has
# since been archived is doing its job.
printf -- '- [2026-01-01] (claude) worked from `docs/gone-forever.md` (backend). verify: pass.\n' >>"$lk/.agent/session-log.md"
out28f=$("$LINKS" "$lk" 2>&1)
printf '%s\n' "$out28f" | grep -qF 'gone-forever' && fail "links.sh: the session log is not audited as a citation source" || pass "links.sh: the session log is not audited as a citation source"

# Canonical files are never orphans — the entry point loads them by name.
out28g=$("$LINKS" "$lk" 2>&1)
printf '%s\n' "$out28g" | grep -qE 'ORPHAN: (purpose|memory|session-log)\.md' && fail "links.sh: canonical files are exempt from the orphan check" || pass "links.sh: canonical files are exempt from the orphan check"

"$LINKS" "$WORK/no-such-root" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "links.sh: a missing node is an error, not a clean report" || fail "links.sh: a missing node is an error, not a clean report"

# A node whose .agent holds no markdown at all: an empty array expands to an
# unbound variable under `set -u` in the bash 3.2 macOS ships.
lkempty="$WORK/links-empty"
mkdir -p "$lkempty/.agent/docs"
printf 'entry point citing .agent/scripts/status.sh\n' >"$lkempty/CLAUDE.md"
out28h=$("$LINKS" "$lkempty" 2>&1)
rc=$?
[ "$rc" -eq 0 ] && printf '%s\n' "$out28h" | grep -qF 'no markdown files to audit' && pass "links.sh: an empty node reports cleanly instead of erroring" || fail "links.sh: an empty node reports cleanly instead of erroring (rc=$rc, $out28h)"

# ---- 29. links.sh under a path containing spaces ----
# Word-splitting turned every path list into fragments here: exemptions were
# bypassed, canonical files were reported as orphans, and awk was handed the
# leading fragment as a filename. Nothing else in the suite uses a path with
# a space, which is why it went unnoticed.
spaceroot="$WORK/space dir/my node"
mkdir -p "$spaceroot"
"$NODE" init --preset software-development --mode track-all "$spaceroot" >/dev/null 2>&1
finish_bootstrap "$spaceroot"
LINKSSP="$spaceroot/.agent/scripts/links.sh"
out29=$("$LINKSSP" "$spaceroot" 2>&1)
printf '%s\n' "$out29" | grep -q 'no orphans or broken links' && pass "links.sh: a node under a path with spaces reports clean" || fail "links.sh: a node under a path with spaces reports clean ($out29)"

mkdir -p "$spaceroot/.agent/docs/back end/references"
printf '# Deep dive\n\ndetail\n' >"$spaceroot/.agent/docs/back end/references/deep dive.md"
out29b=$("$LINKSSP" "$spaceroot" 2>&1)
printf '%s\n' "$out29b" | grep -qF 'ORPHAN: docs/back end/references/deep dive.md' && pass "links.sh: a filename with spaces is reported whole, not in fragments" || fail "links.sh: a filename with spaces is reported whole, not in fragments ($out29b)"
printf '%s\n' "$out29b" | grep -qE 'ORPHAN: (purpose|memory|session-log)\.md' && fail "links.sh: exemptions survive a path with spaces" || pass "links.sh: exemptions survive a path with spaces"
printf '%s\n' "$out29b" | grep -qi 'awk:' && fail "links.sh: no tool is handed a path fragment" || pass "links.sh: no tool is handed a path fragment"

# ---- 30. portability: the node-landing corpus stays vendor-neutral ----
# The corpus is read as authored — one tree, every tool reads the same
# bytes, no build step — so a tool or vendor name that leaks into a preset,
# the template, or a node script ships verbatim into every other tool's
# sessions, where it is an instruction some agent cannot follow. Nothing
# errors when that happens. This lint is the only mechanism that notices.
# Each allowlisted pattern below marks a deliberate reference:
#   filename (CLAUDE.md          template header — copying instruction, deleted on copy
#   uses Copilot Chat            template header — the same instruction's Copilot clause
#   (claude/sonnet)              the log-tag format example (preset + node.sh heredoc)
#   $root/CLAUDE.md, $root/.github/copilot-instructions.md
#                                the entry-point candidate lists (status.sh, links.sh)
#   hand-written AGENTS.md       status.sh comment beside that list
#   autoMemoryEnabled, $root/.claude, /nonexistent}/.claude
#                                the verified tool's native-memory check
lint_allow="$WORK/lint-allow"
cat >"$lint_allow" <<'EOF'
filename (CLAUDE.md
uses Copilot Chat
(claude/sonnet)
$root/CLAUDE.md
$root/.github/copilot-instructions.md
hand-written AGENTS.md
autoMemoryEnabled
$root/.claude
/nonexistent}/.claude
EOF
lint_re='claude|cursor|copilot|codex|anthropic|openai|sonnet|opus|haiku|gpt-|agents\.md'
hits30=$(cd "$reporoot" && grep -inE "$lint_re" \
  presets/software-development.md presets/academic-research.md \
  presets/domain-knowledge.md presets/_shared.md templates/entry-point.md \
  scripts/status.sh scripts/log.sh scripts/memory.sh scripts/docs.sh \
  scripts/links.sh scripts/comments.sh scripts/comments.conf \
  scripts/status.conf scripts/log.conf scripts/node.sh 2>/dev/null | grep -vF -f "$lint_allow")
[ -z "$hits30" ] && pass "portability: node-landing corpus is vendor-neutral" || fail "portability: node-landing corpus is vendor-neutral ($(printf '%s' "$hits30" | tr '\n' ';' | cut -c1-160))"

printf 'When stuck, ask SomeVendor to run it in Cursor.\n' >"$WORK/leak.md"
hits30b=$(grep -inE "$lint_re" "$WORK/leak.md" | grep -vF -f "$lint_allow")
[ -n "$hits30b" ] && pass "portability: the lint catches an injected vendor token" || fail "portability: the lint catches an injected vendor token"

# ---- 31. portability: one entry-point set, three surfaces ----
# The tool-to-filename mapping lives in the operating model's wiring matrix
# and in two scripts' candidate lists (status.sh's mirror check, links.sh's
# corpus). A tool added to one surface and not the others arrives unchecked
# and nothing notices — so this asserts all three carry the same set. The
# set includes legacy names (.cursorrules) on purpose: existing nodes'
# mirrors keep being checked even after the wiring guidance moves on.
eps_from() { grep -oE '"\$root/([^"]*\.md|\.cursorrules)"' "$1" | sort -u; }
eps_status=$(eps_from "$reporoot/scripts/status.sh")
eps_links=$(eps_from "$reporoot/scripts/links.sh")
[ -n "$eps_status" ] && [ "$eps_status" = "$eps_links" ] && pass "portability: status.sh and links.sh share one candidate list" || fail "portability: status.sh and links.sh share one candidate list"

wiring31=$(awk '/^## Wiring your tools/ { f = 1; next } f && /^## / { exit } f' "$reporoot/operating-model.md")
missing31=""
for ep in CLAUDE.md AGENTS.md .cursorrules .github/copilot-instructions.md .claude/CLAUDE.md; do
  printf '%s\n' "$eps_status" | grep -qF "/$ep\"" || missing31="$missing31 candidates:$ep"
  printf '%s\n' "$wiring31" | grep -qF "$ep" || missing31="$missing31 wiring:$ep"
done
[ -z "$missing31" ] && pass "portability: the wiring matrix and the candidate lists cover the same entry points" || fail "portability: the wiring matrix and the candidate lists cover the same entry points ($missing31)"

# ---- 32. status.sh: the LOAD line ----
# The always-loaded set is bounded per file but was never summed, and three
# of its members (contract, purpose, the routing table) carry no per-file
# trigger. The LOAD line is a measurement, not a flag: advisory, printed
# every run, no threshold until the field supplies one.
ld="$WORK/load-line"
mkdir -p "$ld"
"$NODE" init --preset software-development --mode track-all "$ld" >/dev/null 2>&1
finish_bootstrap "$ld"
loadline=$("$ld/.agent/scripts/status.sh" "$ld" 2>&1 | grep '^LOAD:')
[ -n "$loadline" ] && pass "status.sh: LOAD line prints on a quiet node" || fail "status.sh: LOAD line prints on a quiet node"
printf '%s\n' "$loadline" | grep -q 'contract' && pass "status.sh: LOAD names its components" || fail "status.sh: LOAD names its components ($loadline)"
total32=$(printf '%s\n' "$loadline" | sed -E 's/^LOAD: always-loaded set ~([0-9]+) words.*/\1/')
sum32=$(printf '%s\n' "$loadline" | sed -E 's/.*\((.*)\).*/\1/' | tr ',' '\n' | awk '{ s += $2 } END { print s }')
[ -n "$total32" ] && [ "$total32" = "$sum32" ] && pass "status.sh: LOAD arithmetic sums its components" || fail "status.sh: LOAD arithmetic sums its components (total $total32, sum $sum32)"
[ -z "$(status_flags "$ld")" ] && pass "status.sh: LOAD is advisory — a quiet node stays quiet" || fail "status.sh: LOAD is advisory — a quiet node stays quiet ($(status_flags "$ld"))"

printf 'Session bootstrap: run .agent/scripts/status.sh first.\n' >"$ld/CLAUDE.md"
loadline32b=$("$ld/.agent/scripts/status.sh" "$ld" 2>&1 | grep '^LOAD:')
printf '%s\n' "$loadline32b" | grep -q '(entry ' && pass "status.sh: LOAD counts the entry point once wired" || fail "status.sh: LOAD counts the entry point once wired ($loadline32b)"

# ---- 33. status.sh: session-log entry shape ----
# The 25-word entry format lives in the header contract and in log.sh — one
# is prose, the other bypassable by hand-editing the file. This is the check
# that reads the entries themselves.
es="$WORK/entry-shape"
mkdir -p "$es"
"$NODE" init --preset software-development --mode track-all "$es" >/dev/null 2>&1
finish_bootstrap "$es"
printf -- '- [2026-01-02] (tool) %s\n' "$(words_n 60)" >>"$es/.agent/session-log.md"
f33=$(status_flags "$es")
printf '%s\n' "$f33" | grep -qF "entries over 50 words: 1 (largest 63" && pass "status.sh: an oversized log entry is flagged with count and size" || fail "status.sh: an oversized log entry is flagged with count and size ($f33)"

printf -- '- [2026-01-03] (tool) %s\n' "$(words_n 45)" >>"$es/.agent/session-log.md"
f33b=$(status_flags "$es")
printf '%s\n' "$f33b" | grep -qF "entries over 50 words: 1" && pass "status.sh: an at-format entry does not flag" || fail "status.sh: an at-format entry does not flag ($f33b)"

printf -- '- [2026-01-04] (tool) %s\n%s\n' "$(words_n 30)" "$(words_n 30)" >>"$es/.agent/session-log.md"
f33c=$(status_flags "$es")
printf '%s\n' "$f33c" | grep -qF "entries over 50 words: 2" && pass "status.sh: a hand-wrapped entry is counted whole" || fail "status.sh: a hand-wrapped entry is counted whole ($f33c)"

# ---- 34. comments.sh: the diff comment gate ----
# The gate BLOCKs the decidable failures (exit 1): dead citations, code left
# commented out, narration of the change, a reply to the prompt, and short
# narration of the structure below. Every other added comment is listed for
# justification (REVIEW, exit 0), labeled where a heuristic has something to
# say. Workflow vocabulary — base ref, ticket and narration patterns, the
# constraint escape, path exclusions — is the node's, set in comments.conf
# beside the script (KEY=value, parsed never executed) and outside the update
# refresh list.
cg="$WORK/comment-gate"
mkdir -p "$cg/src" "$cg/Migrations" "$cg/.agent/scripts"
cp "$reporoot/scripts/comments.sh" "$cg/.agent/scripts/comments.sh"
chmod +x "$cg/.agent/scripts/comments.sh"
git_cg() { git -C "$cg" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
git_cg init -q
git_cg checkout -q -b base
printf 'const a = 1\n// existing constraint comment\n' >"$cg/src/app.ts"
git_cg add -A >/dev/null
git_cg commit -q -m base
git_cg checkout -q -b feat
cat >>"$cg/src/app.ts" <<'EOF'
// refactored per commit deadbeefcafe1234
// retry cap comes from the vendor SLA
// per AC-12 the cap is three
// eslint-disable-next-line no-console
const b = 2
EOF
printf '#region Setup\nint x = 1;\n' >"$cg/src/tool.cs"
printf '# skipped: out of scope for this pass\ny = 1\n' >"$cg/src/calc.py"
printf '// narration in a migration\n' >"$cg/Migrations/0001_init.cs"
# A tool's own directory: hooks and helpers the comment rule was never
# aimed at. Excluded generically, by shape, so a tool nobody has heard of
# yet is covered on arrival.
mkdir -p "$cg/.toolrc/hooks"
printf '# tuned per commit deadbeefcafe1234\necho hi\n' >"$cg/.toolrc/hooks/check.sh"
# "//" opens no comment in shell — a script that prints one is printing a
# string. A test corpus planting C-family fixtures is the ordinary case.
printf 'echo "// planted per commit deadbeefcafe1234"\n# a real shell comment\n' >"$cg/src/fixture.sh"
git_cg add -A >/dev/null
git_cg commit -q -m feat

out34=$(cd "$cg" && .agent/scripts/comments.sh base 2>&1)
rc34=$?
[ "$rc34" -eq 1 ] && pass "comments.sh: a blocking citation exits 1" || fail "comments.sh: a blocking citation exits 1 (rc=$rc34)"
block34=$(printf '%s\n' "$out34" | sed -n '/^BLOCK:/,$p')
review34=$(printf '%s\n' "$out34" | awk '/^BLOCK:/ { exit } { print }')
printf '%s\n' "$block34" | grep -q 'deadbeefcafe1234' && printf '%s\n' "$block34" | grep -q 'out of scope' && pass "comments.sh: SHA citations and scope narration BLOCK" || fail "comments.sh: SHA citations and scope narration BLOCK ($block34)"
printf '%s\n' "$review34" | grep -q 'vendor SLA' && pass "comments.sh: other added comments land in REVIEW" || fail "comments.sh: other added comments land in REVIEW ($review34)"
printf '%s\n' "$review34" | grep -q 'AC-12' && pass "comments.sh: ticket shapes are not blocked by the shipped core" || fail "comments.sh: ticket shapes are not blocked by the shipped core ($review34)"
printf '%s\n' "$out34" | grep -q '#region' && fail "comments.sh: a C-family # line is not a comment" || pass "comments.sh: a C-family # line is not a comment"
printf '%s\n' "$out34" | grep -q 'planted per commit' && fail "comments.sh: a shell // line is not a comment" || pass "comments.sh: a shell // line is not a comment"
printf '%s\n' "$review34" | grep -q 'a real shell comment' && pass "comments.sh: a shell # line still is one" || fail "comments.sh: a shell # line still is one ($review34)"
printf '%s\n' "$out34" | grep -q 'eslint-disable' && fail "comments.sh: tooling pragmas are skipped" || pass "comments.sh: tooling pragmas are skipped"
printf '%s\n' "$out34" | grep -q 'existing constraint comment' && fail "comments.sh: only comments the diff adds are reported" || pass "comments.sh: only comments the diff adds are reported"
printf '%s\n' "$out34" | grep -q '.toolrc' && fail "comments.sh: hidden directories are out of the scan" || pass "comments.sh: hidden directories are out of the scan"
# The exclusion is anchored: a dot mid-path is not a hidden directory, and
# the literal-dot terms must survive reaching awk — passed through -v their
# escapes collapse and `\.` becomes match-anything, which excludes the tree.
printf '%s\n' "$out34" | grep -q 'src/app.ts' && pass "comments.sh: an ordinary path is not read as hidden" || fail "comments.sh: an ordinary path is not read as hidden ($out34)"

# node vocabulary: ticket shapes join BLOCK, project paths leave the scan.
# The backtick value proves the conf is parsed, never executed — sourcing
# it would run the command.
cat >"$cg/.agent/scripts/comments.conf" <<'EOF'
BLOCK_RE_EXTRA=(^|[^[:alnum:]])AC-?[0-9]|(^|[^[:alnum:]])Q[0-9]+([^[:alnum:]]|$)
EXCLUDE_RE_EXTRA=(^|/)Migrations/
PRAGMA_RE_EXTRA=`touch pwned34`
EOF
out34b=$(cd "$cg" && .agent/scripts/comments.sh base 2>&1)
block34b=$(printf '%s\n' "$out34b" | sed -n '/^BLOCK:/,$p')
printf '%s\n' "$block34b" | grep -q 'AC-12' && pass "comments.sh: conf vocabulary joins BLOCK" || fail "comments.sh: conf vocabulary joins BLOCK ($block34b)"
printf '%s\n' "$out34b" | grep -q 'narration in a migration' && fail "comments.sh: conf exclusions hide their paths" || pass "comments.sh: conf exclusions hide their paths"
[ ! -e "$cg/pwned34" ] && pass "comments.sh: comments.conf is parsed, never executed" || fail "comments.sh: comments.conf is parsed, never executed"

# EXCLUDE_RE replaces the shipped list, the way EXTENSIONS does: a project
# that reviews one of the excluded trees gets it back by naming a narrower
# list. Grow-only keys cannot express that.
cat >"$cg/.agent/scripts/comments.conf" <<'EOF'
EXCLUDE_RE=(^|/)node_modules/
EOF
out34j=$(cd "$cg" && .agent/scripts/comments.sh base 2>&1)
printf '%s\n' "$out34j" | grep -q '.toolrc' && pass "comments.sh: EXCLUDE_RE replaces the shipped exclusions" || fail "comments.sh: EXCLUDE_RE replaces the shipped exclusions ($out34j)"
rm -f "$cg/.agent/scripts/comments.conf"

git_cg checkout -q base
git_cg checkout -q -b justify
printf '// cap ordered by the payment provider contract\nconst c = 3\n' >>"$cg/src/app.ts"
git_cg add -A >/dev/null
git_cg commit -q -m justify
out34c=$(cd "$cg" && .agent/scripts/comments.sh base 2>&1)
rc34c=$?
[ "$rc34c" -eq 0 ] && printf '%s\n' "$out34c" | grep -q '^REVIEW:' && pass "comments.sh: REVIEW alone exits 0" || fail "comments.sh: REVIEW alone exits 0 (rc=$rc34c; $out34c)"

git_cg checkout -q base
git_cg checkout -q -b clean34
printf 'const d = 4\n' >>"$cg/src/app.ts"
git_cg add -A >/dev/null
git_cg commit -q -m clean
out34d=$(cd "$cg" && .agent/scripts/comments.sh base 2>&1)
rc34d=$?
[ "$rc34d" -eq 0 ] && [ -z "$out34d" ] && pass "comments.sh: a clean diff is silent" || fail "comments.sh: a clean diff is silent (rc=$rc34d; $out34d)"

(cd "$cg" && .agent/scripts/comments.sh nosuchref >/dev/null 2>&1)
rc34e=$?
[ "$rc34e" -eq 2 ] && pass "comments.sh: a missing base ref exits 2" || fail "comments.sh: a missing base ref exits 2 (rc=$rc34e)"

# The gate reads the diff as handed back: merge-base to worktree, plus
# untracked files. A committed-only diff exits 0 on exactly the comments it
# exists to catch — hand-back is normally an uncommitted state.
git_cg checkout -q clean34
printf '// tuned per commit cafebabecafebabe\nconst e = 5\n' >>"$cg/src/app.ts"
out34f=$(cd "$cg" && .agent/scripts/comments.sh base 2>&1)
rc34f=$?
[ "$rc34f" -eq 1 ] && printf '%s\n' "$out34f" | grep -q 'cafebabecafebabe' && pass "comments.sh: an unstaged SHA citation BLOCKs" || fail "comments.sh: an unstaged SHA citation BLOCKs (rc=$rc34f; $out34f)"

git_cg add src/app.ts
(cd "$cg" && .agent/scripts/comments.sh base >/dev/null 2>&1)
rc34g=$?
[ "$rc34g" -eq 1 ] && pass "comments.sh: a staged-only SHA citation BLOCKs" || fail "comments.sh: a staged-only SHA citation BLOCKs (rc=$rc34g)"
git_cg reset -q HEAD -- src/app.ts
git_cg checkout -q -- src/app.ts

printf '// context in commit deadbeef12345678\nconst f = 6\n' >"$cg/src/brand-new.ts"
out34h=$(cd "$cg" && .agent/scripts/comments.sh base 2>&1)
rc34h=$?
[ "$rc34h" -eq 1 ] && printf '%s\n' "$out34h" | grep -q 'brand-new.ts' && pass "comments.sh: an untracked file's SHA citation BLOCKs" || fail "comments.sh: an untracked file's SHA citation BLOCKs (rc=$rc34h; $out34h)"
rm -f "$cg/src/brand-new.ts"
out34i=$(cd "$cg" && .agent/scripts/comments.sh base 2>&1)
rc34i=$?
[ "$rc34i" -eq 0 ] && [ -z "$out34i" ] && pass "comments.sh: the worktree checks leave a clean diff silent" || fail "comments.sh: the worktree checks leave a clean diff silent (rc=$rc34i; $out34i)"

# The three classes that joined dead citations in V6.2. Each is decidable
# without reading the code around it, so each BLOCKs, and each names itself:
# "delete this" and "justify this" are different instructions, and a list
# that mixes them unlabeled gets skimmed as one.
git_cg checkout -q base
git_cg checkout -q -b classes
cat >>"$cg/src/app.ts" <<'EOF'
// const retired = 2;
// this previously returned null
// as you requested, the cap is three
// keep in sync with the billing schema;
const g = 7
// Build the rows
const rows = []
// update the cache because the vendor SDK holds a stale handle
cache.flush()
// Update the cache after every write, or a reader sees the previous generation
cache.write(rows)
// A wrapped paragraph whose next line is a fragment, and whose fragment
// stops the run. It is not narrating the code under it.
const h = 8
EOF
git_cg add -A >/dev/null
git_cg commit -q -m classes
out34k=$(cd "$cg" && .agent/scripts/comments.sh base 2>&1)
rc34k=$?
block34k=$(printf '%s\n' "$out34k" | sed -n '/^BLOCK:/,$p')
review34k=$(printf '%s\n' "$out34k" | awk '/^BLOCK:/ { exit } { print }')
[ "$rc34k" -eq 1 ] && pass "comments.sh: the added blocking classes exit 1" || fail "comments.sh: the added blocking classes exit 1 (rc=$rc34k; $out34k)"
printf '%s\n' "$block34k" | grep -qF '[commented-out code]' && pass "comments.sh: code left in a comment BLOCKs, named" || fail "comments.sh: code left in a comment BLOCKs, named ($block34k)"
printf '%s\n' "$block34k" | grep -qF '[change narration]' && pass "comments.sh: change narration BLOCKs, named" || fail "comments.sh: change narration BLOCKs, named ($block34k)"
printf '%s\n' "$block34k" | grep -qF '[answers the prompt]' && pass "comments.sh: a reply to the prompt BLOCKs, named" || fail "comments.sh: a reply to the prompt BLOCKs, named ($block34k)"
# A sentence can end in a semicolon and still be prose: the commented-out
# class needs a code character as well as a code shape, or the gate deletes
# real constraints under a label that says they were dead.
printf '%s\n' "$review34k" | grep -q 'billing schema' && pass "comments.sh: prose ending in a semicolon is not commented-out code" || fail "comments.sh: prose ending in a semicolon is not commented-out code ($out34k)"
printf '%s\n' "$block34k" | grep -qF '[routine narration]' && printf '%s\n' "$block34k" | grep -q 'Build the rows' && pass "comments.sh: short structure narration BLOCKs, named" || fail "comments.sh: short structure narration BLOCKs, named ($block34k)"
# The two guards that keep the routine class from deleting real comments. A
# comment naming a cause is exempt whatever verb it opens with; a long one is
# carrying a clause the verb cannot account for, so it is labeled, not deleted.
printf '%s\n' "$review34k" | grep -q 'because the vendor SDK' && pass "comments.sh: naming a constraint exempts a routine verb" || fail "comments.sh: naming a constraint exempts a routine verb ($out34k)"
long34=$(printf '%s\n' "$review34k" | grep -A1 'routine narration' | grep 'Update the cache after every write')
[ -n "$long34" ] && pass "comments.sh: routine narration past the word cap is labeled, not blocked" || fail "comments.sh: routine narration past the word cap is labeled, not blocked ($out34k)"
# The third guard, found by running the gate over this repository: a wrapped
# paragraph continues onto lines that can open with a routine verb and mean
# nothing of the kind. "stops the run." is the tail of a sentence. The word
# cap cannot see it, because the fragment is short.
printf '%s\n' "$out34k" | grep -A1 'routine narration' | grep -q 'stops the run' && fail "comments.sh: a wrapped-comment continuation is not structure narration" || pass "comments.sh: a wrapped-comment continuation is not structure narration"

# The restatement label: a comment whose every content word already appears
# in the identifiers under it. The scan reaches past the rest of the comment
# block, which is what lets it see a doc comment restating the signature it
# sits on — the case a "public API is exempt" rule used to wave through.
cat >"$cg/src/Thing.cs" <<'EOF'
/// <summary>
/// Gets the user name.
/// </summary>
public string UserName { get; set; }
EOF
printf '// retry counter\nretryCounter = retryCounter + 1\n' >>"$cg/src/app.ts"
out34l=$(cd "$cg" && .agent/scripts/comments.sh base 2>&1)
block34l=$(printf '%s\n' "$out34l" | sed -n '/^BLOCK:/,$p')
review34l=$(printf '%s\n' "$out34l" | awk '/^BLOCK:/ { exit } { print }')
# The doc comment that restates its own signature — the case the deleted
# "public API is exempt" clause used to wave through. It reaches the routine
# class first, which is a delete instruction rather than a justify one.
printf '%s\n' "$block34l" | grep -q 'Gets the user name' && pass "comments.sh: a doc comment narrating its signature BLOCKs" || fail "comments.sh: a doc comment narrating its signature BLOCKs ($out34l)"
# The restatement label covers what no verb pattern reaches: a comment whose
# words are the identifier below it, with no routine verb anywhere.
rest34=$(printf '%s\n' "$review34l" | grep -A1 'restates the code below' | grep 'retry counter')
[ -n "$rest34" ] && pass "comments.sh: a comment repeating the identifier below it is labeled" || fail "comments.sh: a comment repeating the identifier below it is labeled ($review34l)"

printf 'RESTATE_CHECK=false\n' >"$cg/.agent/scripts/comments.conf"
out34m=$(cd "$cg" && .agent/scripts/comments.sh base 2>&1)
printf '%s\n' "$out34m" | grep -qF '[restates the code below]' && fail "comments.sh: RESTATE_CHECK=false drops the label" || pass "comments.sh: RESTATE_CHECK=false drops the label"
printf '%s\n' "$out34m" | awk '/^BLOCK:/ { exit } { print }' | grep -q 'retry counter' && pass "comments.sh: RESTATE_CHECK=false keeps the comment in REVIEW" || fail "comments.sh: RESTATE_CHECK=false keeps the comment in REVIEW ($out34m)"

# The escape hatch a node reaches for when the routine class blocks something
# real: name the constraint in its own vocabulary, rather than add an exception.
printf 'CONSTRAINT_RE_EXTRA=payments gateway\n' >"$cg/.agent/scripts/comments.conf"
printf 'const m0 = 0\n// Build the rows the payments gateway expects\nconst m = 12\n' >>"$cg/src/app.ts"
out34q=$(cd "$cg" && .agent/scripts/comments.sh base 2>&1)
printf '%s\n' "$out34q" | awk '/^BLOCK:/ { exit } { print }' | grep -q 'payments gateway' && pass "comments.sh: CONSTRAINT_RE_EXTRA rescues a real comment from the routine class" || fail "comments.sh: CONSTRAINT_RE_EXTRA rescues a real comment from the routine class ($out34q)"

# The word cap is the class's other guard, and it is a per-node number.
printf 'ROUTINE_MAX_WORDS=0\n' >"$cg/.agent/scripts/comments.conf"
out34r=$(cd "$cg" && .agent/scripts/comments.sh base 2>&1)
printf '%s\n' "$out34r" | sed -n '/^BLOCK:/,$p' | grep -q 'Build the rows' && fail "comments.sh: ROUTINE_MAX_WORDS=0 leaves the class a label only" || pass "comments.sh: ROUTINE_MAX_WORDS=0 leaves the class a label only"
printf '%s\n' "$out34r" | grep -qF '[routine narration]' && pass "comments.sh: ROUTINE_MAX_WORDS=0 keeps the label" || fail "comments.sh: ROUTINE_MAX_WORDS=0 keeps the label ($out34r)"

# The gate fails closed on every conf value it cannot use, numbers included:
# a threshold that silently fell back would change which comments block.
printf 'ROUTINE_MAX_WORDS=eight\n' >"$cg/.agent/scripts/comments.conf"
(cd "$cg" && .agent/scripts/comments.sh base >/dev/null 2>&1)
rc34s=$?
[ "$rc34s" -eq 2 ] && pass "comments.sh: a non-numeric ROUTINE_MAX_WORDS fails closed" || fail "comments.sh: a non-numeric ROUTINE_MAX_WORDS fails closed (rc=$rc34s)"
git_cg checkout -q -- src/app.ts

# House narration terms are the node's, the same way ticket shapes are.
printf 'NARRATION_RE_EXTRA=(^|[^[:alnum:]])old world\n' >"$cg/.agent/scripts/comments.conf"
printf '// the old world path is gone\nconst j = 9\n' >>"$cg/src/app.ts"
out34n=$(cd "$cg" && .agent/scripts/comments.sh base 2>&1)
printf '%s\n' "$out34n" | sed -n '/^BLOCK:/,$p' | grep -q 'old world' && pass "comments.sh: NARRATION_RE_EXTRA joins the narration class" || fail "comments.sh: NARRATION_RE_EXTRA joins the narration class ($out34n)"
rm -f "$cg/.agent/scripts/comments.conf" "$cg/src/Thing.cs"
git_cg checkout -q -- src/app.ts

# A base resolving to HEAD over a clean tree is an empty diff. Exiting 0
# there is a pass meaning "this run read nothing", which in a transcript is
# indistinguishable from "the comments are clean" — and it is the state a
# session lands in by committing first and then reaching for HEAD.
[ -z "$(git -C "$cg" status --porcelain)" ] && pass "comments.sh: the empty-diff fixture starts clean" || fail "comments.sh: the empty-diff fixture starts clean ($(git -C "$cg" status --porcelain | tr '\n' ' '))"
(cd "$cg" && .agent/scripts/comments.sh HEAD >/dev/null 2>&1)
rc34o=$?
[ "$rc34o" -eq 2 ] && pass "comments.sh: a base resolving to HEAD over a clean tree exits 2" || fail "comments.sh: a base resolving to HEAD over a clean tree exits 2 (rc=$rc34o)"
printf '// tuned per commit cafebabecafebabe\nconst k = 10\n' >>"$cg/src/app.ts"
(cd "$cg" && .agent/scripts/comments.sh HEAD >/dev/null 2>&1)
rc34p=$?
[ "$rc34p" -eq 1 ] && pass "comments.sh: HEAD with an uncommitted change is a real diff, not the empty case" || fail "comments.sh: HEAD with an uncommitted change is a real diff, not the empty case (rc=$rc34p)"
git_cg checkout -q -- src/app.ts

# install and refresh: init ships it. The update refreshes it by name and
# never touches the node-owned local file beside it
cgn="$WORK/comment-gate-init"
mkdir -p "$cgn"
"$NODE" init --preset software-development --mode ignore-all "$cgn" >/dev/null 2>&1
[ -x "$cgn/.agent/scripts/comments.sh" ] && pass "init: comments.sh is installed executable" || fail "init: comments.sh is installed executable"
grep -q '^BLOCK_RE_EXTRA=.*AC' "$cgn/.agent/scripts/comments.conf" 2>/dev/null && pass "init: the starter comments.conf is seeded" || fail "init: the starter comments.conf is seeded"
grep -q '^PROBE_TOOLS=' "$cgn/.agent/scripts/status.conf" 2>/dev/null && pass "init: the starter status.conf is seeded" || fail "init: the starter status.conf is seeded"
grep -q '^LOG_INCLUDE_BRANCH=' "$cgn/.agent/scripts/log.conf" 2>/dev/null && pass "init: the starter log.conf is seeded" || fail "init: the starter log.conf is seeded"

cgu="$WORK/comment-gate-update"
mkdir -p "$cgu"
make_v6_fixture "$cgu"
mkdir -p "$cgu/.agent/scripts"
printf 'BASE_REF=origin/dev\n' >"$cgu/.agent/scripts/comments.conf"
printf 'PROBE_TOOLS=jq\n' >"$cgu/.agent/scripts/status.conf"
"$NODE" update "$cgu" >/dev/null 2>&1
[ -x "$cgu/.agent/scripts/comments.sh" ] && pass "update: comments.sh is refreshed into an existing node" || fail "update: comments.sh is refreshed into an existing node"
[ "$(cat "$cgu/.agent/scripts/comments.conf")" = 'BASE_REF=origin/dev' ] && pass "update: an existing comments.conf is never overwritten" || fail "update: an existing comments.conf is never overwritten"
[ "$(cat "$cgu/.agent/scripts/status.conf")" = 'PROBE_TOOLS=jq' ] && pass "update: an existing status.conf is never overwritten" || fail "update: an existing status.conf is never overwritten"

cgu2="$WORK/comment-gate-update-noconf"
mkdir -p "$cgu2"
make_v6_fixture "$cgu2"
"$NODE" update "$cgu2" >/dev/null 2>&1
grep -q '^BLOCK_RE_EXTRA=.*AC' "$cgu2/.agent/scripts/comments.conf" 2>/dev/null && pass "update: a missing comments.conf is seeded with the starter" || fail "update: a missing comments.conf is seeded with the starter"
grep -q '^PROBE_TOOLS=' "$cgu2/.agent/scripts/status.conf" 2>/dev/null && pass "update: a missing status.conf is seeded with the starter" || fail "update: a missing status.conf is seeded with the starter"
grep -q '^LOG_INCLUDE_BRANCH=' "$cgu2/.agent/scripts/log.conf" 2>/dev/null && pass "update: a missing log.conf is seeded with the starter" || fail "update: a missing log.conf is seeded with the starter"

# The same set the init loop asserts, on the path that reaches nodes already
# in the field. node.sh names it once for both loops. This is what notices
# if one of them ever re-inlines a literal.
missing_u=""
for f in status.sh log.sh memory.sh docs.sh links.sh comments.sh; do
  [ -x "$cgu2/.agent/scripts/$f" ] || missing_u="$missing_u $f"
done
for f in comments.conf status.conf log.conf; do
  [ -f "$cgu2/.agent/scripts/$f" ] || missing_u="$missing_u $f"
done
[ -z "$missing_u" ] && pass "update: every shipped script and starter conf reaches an existing node" || fail "update: every shipped script and starter conf reaches an existing node (missing:$missing_u)"

# ---- 35. status.sh: per-node overrides in status.conf ----
# The thresholds and the probed-tools list are per-project tunables, but
# an edit to status.sh itself is discarded by node.sh update. The conf
# beside the script survives update and is parsed, never executed.
printf 'LOG_ENTRY_MAX_WORDS=500\n' >"$es/.agent/scripts/status.conf"
f35=$(status_flags "$es")
printf '%s\n' "$f35" | grep -q 'entries over' && fail "status.conf: a threshold override silences the flag" || pass "status.conf: a threshold override silences the flag"

printf 'PROBE_TOOLS=zz-absent-tool-9\n' >>"$es/.agent/scripts/status.conf"
out35=$("$es/.agent/scripts/status.sh" "$es" 2>&1)
printf '%s\n' "$out35" | grep -q 'TOOLS: not installed: zz-absent-tool-9' && pass "status.conf: PROBE_TOOLS override is probed" || fail "status.conf: PROBE_TOOLS override is probed"

subst "$es/.agent/scripts/status.conf" 's/^PROBE_TOOLS=.*/PROBE_TOOLS=sh/'
out35b=$("$es/.agent/scripts/status.sh" "$es" 2>&1)
printf '%s\n' "$out35b" | grep -q 'TOOLS: not installed' && fail "status.conf: a trimmed PROBE_TOOLS list stops the probe" || pass "status.conf: a trimmed PROBE_TOOLS list stops the probe"

# ---- 36. starter confs: shown defaults match the scripts' ----
# The starter confs list each script's defaults (commented, or live for
# the keys projects trim first) so the knobs are discoverable on disk —
# agents execute the scripts, they don't read them. A default shown in a
# conf that drifted from the script's would document a lie. This pins the
# two together.
mismatch36=""
for k in LOG_MAX_ENTRIES LOG_MAX_WORDS LOG_ENTRY_MAX_WORDS MEMORY_MAX_WORDS \
         MEMORY_MAX_ENTRIES LEARNED_MAX_RULES LEARNED_MAX_WORDS \
         DOCS_MAX_WORDS ENTRYPOINT_MAX_WORDS TAIL_LINES; do
  sdef=$(sed -n "s/^$k=//p" "$reporoot/scripts/status.sh" | head -n 1 | tr -d '"')
  cdef=$(sed -n "s/^# $k=//p" "$reporoot/scripts/status.conf" | head -n 1)
  [ -n "$sdef" ] && [ "$sdef" = "$cdef" ] || mismatch36="$mismatch36 $k"
done
sdef=$(sed -n 's/^PROBE_TOOLS=//p' "$reporoot/scripts/status.sh" | head -n 1 | tr -d '"')
cdef=$(sed -n 's/^PROBE_TOOLS=//p' "$reporoot/scripts/status.conf" | head -n 1)
[ -n "$sdef" ] && [ "$sdef" = "$cdef" ] || mismatch36="$mismatch36 PROBE_TOOLS"
[ -z "$mismatch36" ] && pass "starter status.conf lists the script's own defaults" || fail "starter status.conf lists the script's own defaults ($mismatch36)"

sdef=$(sed -n 's/^EXTENSIONS=//p' "$reporoot/scripts/comments.sh" | head -n 1 | tr -d '"')
cdef=$(sed -n 's/^EXTENSIONS=//p' "$reporoot/scripts/comments.conf" | head -n 1)
[ -n "$sdef" ] && [ "$sdef" = "$cdef" ] && pass "starter comments.conf lists the script's own extension default" || fail "starter comments.conf lists the script's own extension default (script '$sdef' vs conf '$cdef')"

sdef=$(sed -n 's/^EXCLUDE_RE=//p' "$reporoot/scripts/comments.sh" | head -n 1 | tr -d "\"'")
cdef=$(sed -n 's/^# EXCLUDE_RE=//p' "$reporoot/scripts/comments.conf" | head -n 1)
[ -n "$sdef" ] && [ "$sdef" = "$cdef" ] && pass "starter comments.conf lists the script's own exclusion default" || fail "starter comments.conf lists the script's own exclusion default (script '$sdef' vs conf '$cdef')"

sdef=$(sed -n 's/^RESTATE_CHECK=//p' "$reporoot/scripts/comments.sh" | head -n 1)
cdef=$(sed -n 's/^# RESTATE_CHECK=//p' "$reporoot/scripts/comments.conf" | head -n 1)
[ -n "$sdef" ] && [ "$sdef" = "$cdef" ] && pass "starter comments.conf lists the script's own restatement default" || fail "starter comments.conf lists the script's own restatement default (script '$sdef' vs conf '$cdef')"

# Every key the gate reads has a line in the conf beside it. The conf is
# the only documentation a node gets — the scripts are executed, not read —
# so a knob added to the script and not to the file is a knob nobody finds.
missing36=""
for k in $(sed -n 's/^  v=\$(conf_get \([A-Z_]*\)).*/\1/p' "$reporoot/scripts/comments.sh"); do
  grep -qE "^#? ?$k=" "$reporoot/scripts/comments.conf" || missing36="$missing36 $k"
done
[ -z "$missing36" ] && pass "starter comments.conf lists every key the gate reads" || fail "starter comments.conf lists every key the gate reads (missing:$missing36)"

mismatch36b=""
sdef=$(sed -n 's/^SUMMARY_MAX_WORDS=//p' "$reporoot/scripts/log.sh" | head -n 1)
cdef=$(sed -n 's/^# SUMMARY_MAX_WORDS=//p' "$reporoot/scripts/log.conf" | head -n 1)
[ -n "$sdef" ] && [ "$sdef" = "$cdef" ] || mismatch36b="$mismatch36b SUMMARY_MAX_WORDS"
sdef=$(sed -n 's/^LOG_INCLUDE_BRANCH=//p' "$reporoot/scripts/log.sh" | head -n 1)
cdef=$(sed -n 's/^LOG_INCLUDE_BRANCH=//p' "$reporoot/scripts/log.conf" | head -n 1)
[ -n "$sdef" ] && [ "$sdef" = "$cdef" ] || mismatch36b="$mismatch36b LOG_INCLUDE_BRANCH"
[ -z "$mismatch36b" ] && pass "starter log.conf lists the script's own defaults" || fail "starter log.conf lists the script's own defaults ($mismatch36b)"

# ---- 37. log.sh: the branch stamp ----
# LOG_INCLUDE_BRANCH=true stamps each scripted entry with the checked-out
# branch, read from git at write time — mechanical, never asked of the
# agent — and is silently omitted outside a git checkout. The summary
# ceiling tunes from the same conf.
lb="$WORK/log-branch"
mkdir -p "$lb"
"$NODE" init --preset software-development --mode track-all "$lb" >/dev/null 2>&1
git -C "$lb" -c user.name=t -c user.email=t@t init -q
git -C "$lb" checkout -q -b feat-x
subst "$lb/.agent/scripts/log.conf" 's/^LOG_INCLUDE_BRANCH=false/LOG_INCLUDE_BRANCH=true/'
"$LOGSH" --tool t --area a --verify pass --summary "did the thing" "$lb" >/dev/null 2>&1
tail -n 1 "$lb/.agent/session-log.md" | grep -qF '. branch: feat-x. verify: pass.' && pass "log.sh: the branch stamp reads the checked-out branch" || fail "log.sh: the branch stamp reads the checked-out branch ($(tail -n 1 "$lb/.agent/session-log.md"))"

subst "$lb/.agent/scripts/log.conf" 's/^LOG_INCLUDE_BRANCH=true/LOG_INCLUDE_BRANCH=false/'
"$LOGSH" --tool t --area a --verify pass --summary "did it again" "$lb" >/dev/null 2>&1
tail -n 1 "$lb/.agent/session-log.md" | grep -q 'branch:' && fail "log.sh: false leaves the entry format unchanged" || pass "log.sh: false leaves the entry format unchanged"

lb2="$WORK/log-branch-norepo"
mkdir -p "$lb2"
"$NODE" init --preset software-development --mode ignore-all "$lb2" >/dev/null 2>&1
subst "$lb2/.agent/scripts/log.conf" 's/^LOG_INCLUDE_BRANCH=false/LOG_INCLUDE_BRANCH=true/'
"$LOGSH" --tool t --area a --verify pass --summary "no repo here" "$lb2" >/dev/null 2>&1
rc37=$?
[ "$rc37" -eq 0 ] && tail -n 1 "$lb2/.agent/session-log.md" | grep -q 'no repo here' && ! tail -n 1 "$lb2/.agent/session-log.md" | grep -q 'branch:' && pass "log.sh: outside a git checkout the stamp is omitted, not an error" || fail "log.sh: outside a git checkout the stamp is omitted, not an error (rc=$rc37)"

printf 'SUMMARY_MAX_WORDS=5\n' >>"$lb2/.agent/scripts/log.conf"
"$LOGSH" --tool t --area a --verify pass --summary "one two three four five six" "$lb2" >/dev/null 2>&1 \
  && fail "log.sh: the summary ceiling tunes from log.conf" || pass "log.sh: the summary ceiling tunes from log.conf"

# The stamp spends no summary budget (the ceiling is enforced on --summary
# alone, before the line is assembled) and cannot push a format-compliant
# entry over the entry-shape threshold: a maxed 25-word summary plus every
# tag and the stamp runs ~33 of the 50-word grace.
subst "$lb/.agent/scripts/log.conf" 's/^LOG_INCLUDE_BRANCH=false/LOG_INCLUDE_BRANCH=true/'
"$LOGSH" --tool t --area a --verify pass --summary "$(words_n 25)" "$lb" >/dev/null 2>&1 \
  && tail -n 1 "$lb/.agent/session-log.md" | grep -q 'branch: feat-x' && pass "log.sh: the stamp spends no summary budget at the 25-word ceiling" || fail "log.sh: the stamp spends no summary budget at the 25-word ceiling"
status_flags "$lb" | grep -q 'entries over' && fail "log.sh: a stamped max-length entry stays under the entry-shape flag" || pass "log.sh: a stamped max-length entry stays under the entry-shape flag"

# ---- 38. the markdown corpus is soft-wrapped ----
# Hard-wrapped prose makes every edit a re-wrap. Change one word and the
# whole paragraph reflows, so the diff shows moved line breaks with the
# actual edit buried among them. The corpus is authored one line per
# paragraph and wrapped by the reader's renderer instead. Fenced blocks,
# tables, frontmatter, headings and list markers keep their line structure,
# because there the break carries meaning.
#
# A hard wrap is any prose line whose next line is also prose. In markdown
# two consecutive non-blank lines are one paragraph, so the second line is
# always a continuation. An earlier version of this check only flagged
# lines under 100 characters, which let a break after a long line through.
# Width is not the test. Continuation is.
hwawk="$WORK/hardwrap.awk"
cat >"$hwawk" <<'AWK'
FNR == 1 { infence = 0; prev = ""; prevno = 0; infm = ($0 == "---"); if (infm) next }
infm     { if ($0 == "---") infm = 0; next }
/^[ \t]*(```|~~~)/ { infence = !infence; prev = ""; next }
infence  { next }
{
  blank = ($0 ~ /^[ \t]*$/)
  opens = ($0 ~ /^[ \t]*#+[ \t]/) || ($0 ~ /^[ \t]*([-*+][ \t]+|[0-9]+[.)][ \t]+)/) \
       || ($0 ~ /^[ \t]*\|/) || ($0 ~ /^[ \t]*>/) || ($0 ~ /^[ \t]*</)
  if (prev != "" && !blank && !opens) printf "%s:%d\n", FILENAME, prevno
  if (blank) prev = ""; else { prev = $0; prevno = FNR }
}
AWK

hw38=""
# -print0 into a file, then read with a redirect rather than a pipe: a
# pipeline would run the loop in a subshell and lose hw38. Unquoted
# $(find) word-split here, so a path with a space read as clean.
(cd "$reporoot" && find . -name '*.md' -not -path '*/.git/*' -not -path './tmp/*' -not -path './.claude/*' -not -path './.codex/*' -not -path './evals/runs/*' -print0) >"$WORK/hw-corpus"
while IFS= read -r -d '' md; do
  hit=$(cd "$reporoot" && awk -f "$hwawk" "$md")
  [ -n "$hit" ] && hw38="$hw38 $hit"
done <"$WORK/hw-corpus"
[ -z "$hw38" ] && pass "markdown: the corpus is soft-wrapped" || fail "markdown: the corpus is soft-wrapped ($(printf '%s' "${hw38# }" | cut -c1-160))"

# The check has to be able to fail, or a broken detector reads as a clean
# corpus. Section 30 guards its lint the same way.
printf 'A paragraph broken by a column limit\nrather than by a blank line.\n' >"$WORK/hardwrap-fixture.md"
[ -n "$(awk -f "$hwawk" "$WORK/hardwrap-fixture.md")" ] && pass "markdown: the check catches an injected hard wrap" || fail "markdown: the check catches an injected hard wrap"

# A node's markdown is written by the scripts rather than copied out of
# this repo, so the corpus sweep above cannot see any of it. node.sh and
# docs.sh carry a node's headers in heredocs, and a hard wrap there ships
# into every node this repo has ever created. That is the copy that
# matters: the corpus is read by whoever maintains this repo, a node is
# read by every agent that works in it.
hwnode="$WORK/hardwrap-node"
mkdir -p "$hwnode"
"$NODE" init --preset software-development --mode track-all "$hwnode" >/dev/null 2>&1
"$hwnode/.agent/scripts/docs.sh" new --name auth-flow --read-when "working on authentication" "$hwnode" >/dev/null 2>&1
"$hwnode/.agent/scripts/memory.sh" new --slug hw --title HW --hook hook --fact "a durable fact" "$hwnode" >/dev/null 2>&1
hw38b=""
find "$hwnode/.agent" -name '*.md' -print0 >"$WORK/hw-nodelist"
while IFS= read -r -d '' md; do
  hit=$(awk -f "$hwawk" "$md" | sed "s|$hwnode/||")
  [ -n "$hit" ] && hw38b="$hw38b $hit"
done <"$WORK/hw-nodelist"
[ -z "$hw38b" ] && pass "markdown: a generated node is soft-wrapped too" || fail "markdown: a generated node is soft-wrapped too ($(printf '%s' "${hw38b# }" | cut -c1-160))"

# A fenced block keeps its line structure and must not be read as prose.
printf 'One line of prose.\n\n```\nwrapped inside\na fence\n```\n' >"$WORK/hardwrap-fence.md"
[ -z "$(awk -f "$hwawk" "$WORK/hardwrap-fence.md")" ] && pass "markdown: a fenced block is not read as wrapped prose" || fail "markdown: a fenced block is not read as wrapped prose"

# ---- 39. the operating model quotes what the scripts actually write ----
# node.sh and docs.sh write a node's headers, and the operating model shows
# each one in a fenced block as the reference copy. Nothing kept the two in
# step. The session-log block had already lost the branch-stamp clause that
# log.conf added, and a register pass over the scripts moved four of the
# five further apart, silently in both cases. A reader trusts the document
# over the script, so a stale block teaches the wrong contract.
omnode="$WORK/om-quotes"
mkdir -p "$omnode"
"$NODE" init --preset software-development --mode track-all "$omnode" >/dev/null 2>&1
"$omnode/.agent/scripts/docs.sh" new --name a --read-when "x" "$omnode" >/dev/null 2>&1

om_drift=""
om_check() { # $1 = path under .agent/, $2 = a distinctive phrase in the header
  line=$(grep -F "$2" "$omnode/.agent/$1" | head -n 1)
  if [ -z "$line" ]; then
    om_drift="$om_drift $1(missing-from-node)"
  else
    grep -qF "$line" "$reporoot/operating-model.md" || om_drift="$om_drift $1"
  fi
}
om_check session-log.md "One entry per session"
om_check memory.md "Index only, one line per fact file"
om_check rules/learned.md "Binding rules distilled"
om_check docs/architecture.md "One entry per doc in this directory"
# docs/a.md has no header to quote: the shape contract moved to the preset
# and docs.sh's output. Pin the removal at both ends instead — a copy that
# grows back in either place is the drift this section exists to catch.
grep -qF "Agent-facing reference, not a human narrative" "$omnode/.agent/docs/a.md" && om_drift="$om_drift docs/a.md(header-returned)"
grep -qF "Agent-facing reference, not a human narrative" "$reporoot/operating-model.md" && om_drift="$om_drift operating-model.md(header-returned)"
[ -z "$om_drift" ] && pass "operating model: the quoted node headers match what the scripts write" || fail "operating model: the quoted node headers match what the scripts write (drifted:$om_drift)"

# The check must be able to fail, or a stale document reads as a current one.
om_probe=$(grep -qF "a phrase no header contains anywhere" "$reporoot/operating-model.md" && echo found || echo absent)
[ "$om_probe" = absent ] && pass "operating model: the quote check tests presence, not a constant" || fail "operating model: the quote check tests presence, not a constant"

# ---- 40. the fail-open class found by the 2026-08-27 script review ----
# Every check here pins a defect that shipped and that this suite passed
# over. They share one shape: the script reported success while the work
# it names did not happen. A gate that says "clean" when it never ran, a
# threshold that stops enforcing, a write claimed but not made.

# 40a. status.conf says "parsed and never executed" on its second line.
# It was not. A conf value reached [[ ]] as an arithmetic operand, and
# arithmetic evaluates command substitution inside an array subscript.
# status.sh is the entry point's first step in every session.
ce="$WORK/confexec"
mkdir -p "$ce"
"$NODE" init --preset software-development --mode track-all "$ce" >/dev/null 2>&1
ce_marker="$WORK/conf-exec-marker"
rm -f "$ce_marker"
printf 'LOG_MAX_ENTRIES=entrypoints[$(touch %s)]\n' "$ce_marker" >>"$ce/.agent/scripts/status.conf"
ce_out=$("$ce/.agent/scripts/status.sh" "$ce" 2>/dev/null)
[ ! -e "$ce_marker" ] && pass "status.conf: a conf value cannot execute a command" || fail "status.conf: a conf value cannot execute a command"
printf '%s\n' "$ce_out" | grep -q '^REPAIR: status.conf LOG_MAX_ENTRIES=' && pass "status.conf: a value that is not a whole number draws a REPAIR flag" || fail "status.conf: a value that is not a whole number draws a REPAIR flag"

# The threshold must still tune, or the validation traded one bug for
# another.
grep -v '^LOG_MAX_ENTRIES=entrypoints' "$ce/.agent/scripts/status.conf" >"$ce/conf.tmp" && mv "$ce/conf.tmp" "$ce/.agent/scripts/status.conf"
printf 'LOG_MAX_ENTRIES=1\n' >>"$ce/.agent/scripts/status.conf"
printf -- '- [2026-01-01] (t) a (b). verify: pass.\n- [2026-01-02] (t) a (b). verify: pass.\n' >>"$ce/.agent/session-log.md"
status_flags "$ce" | grep -q '^GROOM: session-log.md' && pass "status.conf: a valid threshold still tunes the check" || fail "status.conf: a valid threshold still tunes the check"

# 40b. The word ceiling is why log.sh exists over a hand-written append,
# so a ceiling it cannot parse fails closed rather than waving entries
# through. An inline comment is the everyday form of a bad value.
lc="$WORK/logconf"
mkdir -p "$lc"
"$NODE" init --preset software-development --mode track-all "$lc" >/dev/null 2>&1
printf 'SUMMARY_MAX_WORDS=25 words\n' >>"$lc/.agent/scripts/log.conf"
"$lc/.agent/scripts/log.sh" --tool t --area a --verify pass --summary "short entry" "$lc" >/dev/null 2>&1 \
  && fail "log.conf: a ceiling that is not a whole number is refused" || pass "log.conf: a ceiling that is not a whole number is refused"

# 40c. A flag name taken as the next flag's value wrote an entry reading
# "(t) --area (a)". Only the argument count was checked, never the shape.
"$lc/.agent/scripts/log.sh" --tool t --area a --verify pass --summary --area "$lc" >/dev/null 2>&1 \
  && fail "log.sh: a flag is not accepted as another flag's value" || pass "log.sh: a flag is not accepted as another flag's value"

# 40d. status.sh invented three findings for any argument it did not
# understand, at exit 0. The entry point tells an agent to clear every
# REPAIR: line it prints.
"$lc/.agent/scripts/status.sh" --help >"$WORK/sh-help" 2>/dev/null
sh_rc=$?
[ "$sh_rc" -eq 0 ] && head -n 1 "$WORK/sh-help" | grep -q '^Usage: status.sh' && pass "status.sh: --help prints usage on stdout at exit 0" || fail "status.sh: --help prints usage on stdout at exit 0"
grep -q '^REPAIR:' "$WORK/sh-help" && fail "status.sh: --help invents no findings" || pass "status.sh: --help invents no findings"
sh_bad="$WORK/not-a-node"
mkdir -p "$sh_bad"
sh_out=$("$lc/.agent/scripts/status.sh" "$sh_bad" 2>/dev/null)
sh_rc=$?
[ "$sh_rc" -ne 0 ] && [ -z "$sh_out" ] && pass "status.sh: a root with no .agent is a usage error, not three findings" || fail "status.sh: a root with no .agent is a usage error, not three findings"
lk_out=$("$lc/.agent/scripts/links.sh" "$sh_bad" 2>/dev/null)
lk_rc=$?
[ "$lk_rc" -ne 0 ] && [ -z "$lk_out" ] && pass "links.sh: a root with no .agent is a usage error, not an empty report" || fail "links.sh: a root with no .agent is a usage error, not an empty report"

# 40d-ii. Both reporting scripts documented an unconditional "always exits
# 0" that the usage-error exit above had already made false. The claim is
# load-bearing: a caller told the status is constant will not branch on it,
# and a script whose own docs are wrong about its contract is the failure
# this suite exists to catch. Pinned as a phrase, in the scripts and in
# every doc, because that is the shape a future edit would reintroduce.
ax_bad=""
for ax_f in "$reporoot"/scripts/status.sh "$reporoot"/scripts/links.sh \
  "$reporoot"/scripts/docs/status.md "$reporoot"/scripts/docs/links.md \
  "$reporoot"/operating-model.md; do
  grep -qiE 'always exits? 0' "$ax_f" && ax_bad="$ax_bad $(basename "$ax_f")"
done
[ -z "$ax_bad" ] && pass "status.sh and links.sh: nothing claims an unconditional exit 0" || fail "status.sh and links.sh: nothing claims an unconditional exit 0 ($ax_bad)"

# 40e. memory.sh and docs.sh printed "wrote X and indexed it in Y" when
# the second write failed, leaving exactly the drift they exist to
# prevent. The blocked target is a directory rather than a chmod, so the
# write fails for root too and this means the same thing in CI.
# The index target must stay a regular file: making it a directory trips
# an earlier guard and never reaches the defect. A read-only file is the
# real shape, so the check first proves this environment enforces that.
# Running as root it does not, and the pair says so rather than passing
# on a condition it never created.
hw="$WORK/halfwrite"
mkdir -p "$hw"
"$NODE" init --preset software-development --mode track-all "$hw" >/dev/null 2>&1
: >"$WORK/ro-probe"
chmod a-w "$WORK/ro-probe"
if printf 'x\n' >>"$WORK/ro-probe" 2>/dev/null; then
  ro_enforced=0
else
  ro_enforced=1
fi
chmod u+w "$WORK/ro-probe"

if [ "$ro_enforced" -eq 1 ]; then
  chmod a-w "$hw/.agent/memory.md"
  "$hw/.agent/scripts/memory.sh" new --slug halffact --title T --hook H --fact F "$hw" >/dev/null 2>&1 \
    && fail "memory.sh: a failed index write is reported as a failure" || pass "memory.sh: a failed index write is reported as a failure"
  [ ! -e "$hw/.agent/memory/halffact.md" ] && pass "memory.sh: a failed index write leaves no orphan fact file" || fail "memory.sh: a failed index write leaves no orphan fact file"
  chmod u+w "$hw/.agent/memory.md"
else
  pass "memory.sh: failed index write not exercised — this environment ignores file permissions"
  pass "memory.sh: orphan removal not exercised — this environment ignores file permissions"
fi

hd="$WORK/halfdoc"
mkdir -p "$hd"
"$NODE" init --preset software-development --mode track-all "$hd" >/dev/null 2>&1
"$hd/.agent/scripts/docs.sh" new --name first --read-when "x" "$hd" >/dev/null 2>&1
if [ "$ro_enforced" -eq 1 ]; then
  chmod a-w "$hd/.agent/docs/architecture.md"
  "$hd/.agent/scripts/docs.sh" new --name second --read-when "y" "$hd" >/dev/null 2>&1 \
    && fail "docs.sh: a failed routing write is reported as a failure" || pass "docs.sh: a failed routing write is reported as a failure"
  [ ! -e "$hd/.agent/docs/second.md" ] && pass "docs.sh: a failed routing write leaves no unrouted doc" || fail "docs.sh: a failed routing write leaves no unrouted doc"
  chmod u+w "$hd/.agent/docs/architecture.md"
else
  pass "docs.sh: failed routing write not exercised — this environment ignores file permissions"
  pass "docs.sh: unrouted doc removal not exercised — this environment ignores file permissions"
fi

# 40f. Slug and name validation used [a-z0-9-], a collation range that
# means ASCII only in the C locale. UpperCase was refused under LC_ALL=C
# and accepted in every locale a person actually runs in. Section 9's
# Bad_Slug case cannot catch this: its underscore is rejected either way.
# This input is all-alpha on purpose.
vn="$WORK/validate"
mkdir -p "$vn"
"$NODE" init --preset software-development --mode track-all "$vn" >/dev/null 2>&1
LC_ALL=C "$vn/.agent/scripts/memory.sh" new --slug UpperCase --title T --hook H --fact F "$vn" >/dev/null 2>&1 \
  && fail "memory.sh: an uppercase slug is refused under LC_ALL=C" || pass "memory.sh: an uppercase slug is refused under LC_ALL=C"
vloc=$(locale -a 2>/dev/null | grep -ix -m1 -e 'en_US.UTF-8' -e 'en_US.utf8' -e 'C.UTF-8' -e 'C.utf8')
if [ -n "$vloc" ]; then
  LC_ALL="$vloc" "$vn/.agent/scripts/memory.sh" new --slug UpperCase --title T --hook H --fact F "$vn" >/dev/null 2>&1 \
    && fail "memory.sh: an uppercase slug is refused under a UTF-8 locale" || pass "memory.sh: an uppercase slug is refused under a UTF-8 locale"
  LC_ALL="$vloc" "$vn/.agent/scripts/docs.sh" new --name AuthFlow --read-when x "$vn" >/dev/null 2>&1 \
    && fail "docs.sh: an uppercase name is refused under a UTF-8 locale" || pass "docs.sh: an uppercase name is refused under a UTF-8 locale"
fi
[ ! -e "$vn/.agent/memory/UpperCase.md" ] && pass "memory.sh: no uppercase fact file was written in any locale" || fail "memory.sh: no uppercase fact file was written in any locale"

# A leading dash passed the character check, and the filename it wrote
# reads as a flag to everything downstream.
"$vn/.agent/scripts/memory.sh" new --slug -weird --title T --hook H --fact F "$vn" >/dev/null 2>&1 \
  && fail "memory.sh: a slug starting with - is refused" || pass "memory.sh: a slug starting with - is refused"
"$vn/.agent/scripts/docs.sh" new --name -weird --read-when x "$vn" >/dev/null 2>&1 \
  && fail "docs.sh: a name starting with - is refused" || pass "docs.sh: a name starting with - is refused"
"$vn/.agent/scripts/memory.sh" new --slug ok-slug --title T --hook H --fact --scope "$vn" >/dev/null 2>&1 \
  && fail "memory.sh: a flag is not accepted as another flag's value" || pass "memory.sh: a flag is not accepted as another flag's value"
"$vn/.agent/scripts/memory.sh" new --slug fresh-slug --title T --hook H --fact "a real fact" "$vn" >/dev/null 2>&1 \
  && pass "memory.sh: a valid invocation still writes" || fail "memory.sh: a valid invocation still writes"

# 40g. The comment gate failed open two ways. A conf regex that will not
# compile made every grep in the pipeline error into `|| true`, so the run
# exited 0 with the BLOCK gone. And a path holding a space was skipped
# whole, because git appends a tab to the `+++ b/<path>` header and the
# tab travelled into the filename field.
fo="$WORK/gate-failopen"
mkdir -p "$fo/.agent/scripts" "$fo/My Project"
cp "$reporoot/scripts/comments.sh" "$fo/.agent/scripts/comments.sh"
cp "$reporoot/scripts/comments.conf" "$fo/.agent/scripts/comments.conf"
chmod +x "$fo/.agent/scripts/comments.sh"
git_fo() { git -C "$fo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
git_fo init -q
git_fo checkout -q -b base
printf 'const a = 1\n' >"$fo/seed.ts"
git_fo add -A >/dev/null
git_fo commit -q -m base
git_fo checkout -q -b feat
printf '// refactored per commit deadbeefcafe1234\n' >"$fo/My Project/Program.cs"
printf '// refactored per commit deadbeefcafe1234\n' >"$fo/Plain.cs"
git_fo add -A >/dev/null

# Both citations are identical, so the only difference is the space.
fo_out=$(cd "$fo" && "$fo/.agent/scripts/comments.sh" base 2>/dev/null)
printf '%s\n' "$fo_out" | grep -qF 'My Project/Program.cs' && pass "comments.sh: a path containing a space is still gated" || fail "comments.sh: a path containing a space is still gated"
printf '%s\n' "$fo_out" | grep -qF 'Plain.cs' && pass "comments.sh: the unspaced control path is gated" || fail "comments.sh: the unspaced control path is gated"

# A conf regex that will not compile must stop the gate, not silence it.
grep -v '^BLOCK_RE_EXTRA=' "$fo/.agent/scripts/comments.conf" >"$fo/conf.tmp" && mv "$fo/conf.tmp" "$fo/.agent/scripts/comments.conf"
printf 'BLOCK_RE_EXTRA=[unclosed\n' >>"$fo/.agent/scripts/comments.conf"
fo_bad=$(cd "$fo" && "$fo/.agent/scripts/comments.sh" base 2>/dev/null)
fo_rc=$?
[ "$fo_rc" -ne 0 ] && [ -z "$fo_bad" ] && pass "comments.sh: a conf regex that will not compile fails closed" || fail "comments.sh: a conf regex that will not compile fails closed (rc=$fo_rc)"

# 40h. Four different help contracts across six scripts: usage on stdout
# at exit 0 in two, usage on stderr at exit 1 in two, three invented
# findings in one, and "base ref not found" at exit 2 in the last. The
# five root-taking scripts now agree. comments.sh takes a base ref rather
# than a root and is left out on purpose.
hp="$WORK/helpcontract"
mkdir -p "$hp"
"$NODE" init --preset software-development --mode track-all "$hp" >/dev/null 2>&1
hp_bad=""
for hp_s in status log memory docs links; do
  hp_out=$("$hp/.agent/scripts/$hp_s.sh" --help 2>/dev/null)
  hp_rc=$?
  [ "$hp_rc" -eq 0 ] || hp_bad="$hp_bad $hp_s.sh(exit=$hp_rc)"
  printf '%s\n' "$hp_out" | head -n 1 | grep -q "^Usage: $hp_s.sh" || hp_bad="$hp_bad $hp_s.sh(no-usage-on-stdout)"
done
[ -z "$hp_bad" ] && pass "shipped scripts: --help prints usage on stdout at exit 0" || fail "shipped scripts: --help prints usage on stdout at exit 0 ($hp_bad)"

# ---- 41. status.sh: the entry point stays wiring ----
# An entry point is the load path and nothing else. What grows past the
# template's size is project scope, constraints, or architecture restated
# from purpose.md and docs/, which the load path opens two steps later
# anyway — a second copy no check reads and no groom pass touches, paid on
# every message by every tool that keeps the file resident. The boundary was
# prose until this threshold measured it.
ew="$WORK/entry-width"
mkdir -p "$ew"
"$NODE" init --preset software-development --mode track-all "$ew" >/dev/null 2>&1
finish_bootstrap "$ew"
printf '# P — Session Bootstrap\n\nRun `bash .agent/scripts/status.sh` first.\n' >"$ew/CLAUDE.md"
status_flags "$ew" | grep -q 'CLAUDE.md' && fail "status.sh: a wiring-sized entry point does not flag" || pass "status.sh: a wiring-sized entry point does not flag"

printf '\n%s\n' "$(words_n 900)" >>"$ew/CLAUDE.md"
f41=$(status_flags "$ew")
printf '%s\n' "$f41" | grep -qF 'GROOM: CLAUDE.md > 800 words' && pass "status.sh: an entry point grown past wiring is flagged" || fail "status.sh: an entry point grown past wiring is flagged ($f41)"

printf 'ENTRYPOINT_MAX_WORDS=2000\n' >"$ew/.agent/scripts/status.conf"
status_flags "$ew" | grep -q 'CLAUDE.md > ' && fail "status.conf: the entry-point threshold tunes per node" || pass "status.conf: the entry-point threshold tunes per node"

# The threshold's stated provenance: the shipped template, filled, with 2x
# grace. Checked both ways — a template that grew past half the threshold
# would make the number an invention, and a threshold far above 2x would
# stop flagging what it exists to flag.
tpl41=$(sed -n '2,$p' "$reporoot/templates/entry-point.md" | wc -w | tr -d '[:space:]')
def41=$(sed -n 's/^ENTRYPOINT_MAX_WORDS=//p' "$reporoot/scripts/status.sh" | head -n 1)
[ -n "$def41" ] && [ "$def41" -ge "$((tpl41 * 2))" ] && [ "$def41" -le "$((tpl41 * 3))" ] \
  && pass "status.sh: ENTRYPOINT_MAX_WORDS stays ~2x the shipped template" \
  || fail "status.sh: ENTRYPOINT_MAX_WORDS stays ~2x the shipped template (template $tpl41, threshold $def41)"

# The template is the only copy of the load path, and both of its
# timing rules are the ones a harness re-reading it per message depends on.
tpl41f="$reporoot/templates/entry-point.md"
missing41=""
grep -qF "run once" "$tpl41f" || grep -qF "runs once" "$tpl41f" || missing41="$missing41 once-per-session"
grep -qF "A new user message does not start a new session." "$tpl41f" || missing41="$missing41 user-turn-is-not-a-session"
grep -qF "Do not open this file with a tool when its content is already present in your context." "$tpl41f" || missing41="$missing41 no-reopen-from-disk"
grep -qF "compaction" "$tpl41f" || missing41="$missing41 compaction-rerun"
grep -qF "Never restate it here" "$tpl41f" || missing41="$missing41 wiring-only"
grep -qF "never \`HEAD\`" "$tpl41f" || missing41="$missing41 comment-gate-base"
[ -z "$missing41" ] && pass "template: the entry point carries its timing and boundary rules" || fail "template: the entry point carries its timing and boundary rules (missing:$missing41)"

# A user turn is not a session boundary, and the gate saying so must precede
# the numbered imperative: a literal reader that meets "Execute with tools, in
# order:" first starts the list and never reaches its exception. This is
# structural prompt coverage. Whether a given model honors it is behavior, and
# behavior is measured by the evals under evals/, not asserted here.
gate41=$(grep -nF 'A new user message does not start a new session.' "$tpl41f" | cut -d: -f1)
steps41=$(grep -nF 'Execute with tools, in order:' "$tpl41f" | cut -d: -f1)
[ -n "$gate41" ] && [ -n "$steps41" ] && [ "$gate41" -lt "$steps41" ] && pass "template: the per-conversation gate precedes the numbered steps" || fail "template: the per-conversation gate precedes the numbered steps (gate=$gate41 steps=$steps41)"

# ---- 43. evals/ is the repo's, never a node's ----
# The eval bench is maintainer tooling. It costs model tokens, names agents
# and models by vendor, and carries fixtures that plant a credential and an
# injection payload on purpose — none of which belongs in someone's project.
# node.sh copies a fixed list, so the leak cannot happen by accident today;
# this is what notices when that list grows a wildcard, or when a bootstrap
# prompt starts telling an agent to copy the clone.
evleak="$WORK/node-scope"
mkdir -p "$evleak"
"$NODE" init --preset software-development --mode track-all "$evleak" >/dev/null 2>&1
leaked43=$(find "$evleak" -path '*eval*' -o -name 'spec.json' -o -name 'agents.conf' \
  -o -name 'fixtures.sh' -o -name 'rollup.sh' -o -name 'grade.sh' 2>/dev/null)
[ -z "$leaked43" ] && pass "evals: init puts nothing from evals/ into a node" || fail "evals: init puts nothing from evals/ into a node ($leaked43)"

# The same on the path that reaches nodes already in the field.
evleak2="$WORK/node-scope-update"
mkdir -p "$evleak2"
make_v6_fixture "$evleak2"
"$NODE" update "$evleak2" >/dev/null 2>&1
leaked43b=$(find "$evleak2" -path '*eval*' -o -name 'spec.json' -o -name 'agents.conf' \
  -o -name 'fixtures.sh' -o -name 'rollup.sh' -o -name 'grade.sh' 2>/dev/null)
[ -z "$leaked43b" ] && pass "evals: update puts nothing from evals/ into a node" || fail "evals: update puts nothing from evals/ into a node ($leaked43b)"

# A node's scripts directory holds exactly the shipped set and nothing else.
# The eval bench is the newest candidate for arriving there by mistake, but
# the assertion is general: what a node receives is a closed list.
extra43=""
for f43 in "$evleak"/.agent/scripts/*; do
  case "$(basename "$f43")" in
  status.sh | log.sh | memory.sh | docs.sh | links.sh | comments.sh | status.conf | log.conf | comments.conf) ;;
  *) extra43="$extra43 $(basename "$f43")" ;;
  esac
done
[ -z "$extra43" ] && pass "evals: a node's scripts/ holds exactly the shipped set" || fail "evals: a node's scripts/ holds exactly the shipped set (extra: $(printf '%s' "$extra43" | tr '\n' ' '))"

# The bench says so where a reader meets it, and the operating model keeps it
# out of the appendix that lists what a node *does* install.
grep -qF "belongs to the dot-agent repository, not to the harness" "$reporoot/evals/README.md" && pass "evals: the bench states its own scope at the top of its README" || fail "evals: the bench states its own scope at the top of its README"
appendix43=$(awk '/^## Appendix: optional tooling/ { f = 1 } f' "$reporoot/operating-model.md")
printf '%s\n' "$appendix43" | grep -q 'evals/' && fail "evals: the bench is not listed as node-installable tooling" || pass "evals: the bench is not listed as node-installable tooling"

# ---- 42. evals/: the eval set stays buildable and well-formed ----
# The eval runs themselves need a model and are an operator ceremony, never
# CI. What rides here is the static half: a spec that parses and a fixture
# that still builds. Without it the eval set rots silently between runs, and
# the rot only surfaces when someone is mid-benchmark and paying for tokens.
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
for key in ("arms", "weighting"):
    if not spec.get(key):
        bad.append("spec missing %s" % key)
if not spec.get("arms", {}).get("control", {}).get("definition"):
    bad.append("spec has no control-arm definition — an undefined control is an undefined experiment")
sys.stdout.write("; ".join(bad))
PY
)
  [ -z "$ev42" ] && pass "evals: spec.json is well-formed and every assertion is joinable" || fail "evals: spec.json is well-formed and every assertion is joinable ($ev42)"
else
  fail "evals: spec.json is well-formed and every assertion is joinable (python3 absent)"
fi

# Every phase the operating model's trust contract names must carry at least
# one eval. Without this the set narrows back to whichever bug was reported
# last — which is exactly how it was first written, covering the comment rule
# four ways and the write-back contract not at all.
phases42=$(awk '/^\| Phase \| Trust contract/ { f = 1; next } f && /^\| \*\*/ { gsub(/\*/, "", $2); print tolower($2) } f && !/^\|/ { exit }' "$reporoot/operating-model.md")
covered42=$(sed -n 's/.*"phase": "\([a-z-]*\)".*/\1/p' "$evroot/spec.json" | sort -u)
uncovered42=""
for ph in $phases42; do
  printf '%s\n' "$covered42" | grep -qx "$ph" || uncovered42="$uncovered42 $ph"
done
[ -n "$phases42" ] && [ -z "$uncovered42" ] && pass "evals: every trust-contract phase carries at least one eval" || fail "evals: every trust-contract phase carries at least one eval (uncovered:${uncovered42:-none}; phases found: $(printf '%s' "$phases42" | tr '\n' ' '))"

# A fixture arriving with its own REPAIR: flags would make every eval spend
# its session on repair rather than on the behavior under test, and the delta
# would measure that instead. Built from the working tree on purpose: the
# corpus under test is the one being edited, not the one last committed.
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

# The one fixture whose contract is the opposite: it exists to be flagged, and
# a build that stopped seeding its thresholds would leave groom-acts-on-flags
# passing against nothing.
evfg="$WORK/eval-fixture-flagged"
"$evroot/fixtures.sh" ts-service-flagged "$evfg" --corpus-dir "$reporoot" >/dev/null 2>&1
f42b=$(status_flags "$evfg")
printf '%s\n' "$f42b" | grep -q '^GROOM: session-log.md entries over' && printf '%s\n' "$f42b" | grep -q '^GROOM: memory/' && pass "evals: the flagged fixture arrives over the thresholds its eval clears" || fail "evals: the flagged fixture arrives over the thresholds its eval clears ($f42b)"

# ---- 44. evals/run.sh: fake-CLI regression coverage ----
# claude and codex are real, logged-in installs the operator drives by hand
# — nothing static may call one. Every claim about run.sh's own behavior is
# instead pinned against fake claude/codex executables that speak just
# enough of each CLI's stdin/stdout contract to stand in, driven through a
# disposable EVALS_AGENTS_CONF so this suite never reads or writes the
# operator's own evals/agents.conf, and never depends on what happens to be
# installed on the machine running it.
evsh="$evroot/run.sh"
evfake="$WORK/eval fake cli"           # a space in the path, on purpose
mkdir -p "$evfake"
corpus_ref_test=$(git -C "$reporoot" rev-parse HEAD)

# Every invocation below drives claude_run/codex_run, which require
# subscription-backed auth before driving either adapter. Point both at
# self-contained fake credential stores rather than the operator's real
# ~/.claude or ~/.codex — nothing in this suite may read or depend on
# whatever happens to be logged in on the machine running it. Individual
# auth-rejection tests below override one or both of these per invocation.
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
                 "--no-session-persistence", "--no-chrome"):
    require_flag(required)
require_pair("--input-format", "stream-json")
require_pair("--output-format", "stream-json")
require_pair("--model", "fake-claude-model")
require_pair("--mcp-config", '{"mcpServers":{}}')
require_pair("--allowedTools", "Read,Write,Edit,Bash")
require_pair("--permission-mode", "acceptEdits")
require_pair("--effort", "medium")
require_flag("--append-system-prompt-file")
system_index = argv.index("--append-system-prompt-file")
if system_index + 1 >= len(argv) or os.path.realpath(argv[system_index + 1]) != os.path.realpath("CLAUDE.md"):
    reject("--append-system-prompt-file must name the fixture CLAUDE.md")

mode = os.environ.get("FAKE_CLAUDE_MODE", "ok")
total = int(os.environ.get("FAKE_CLAUDE_TURNS", "0"))

if mode == "timeout":
    time.sleep(3600)
    sys.exit(0)

turn = 0
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    turn += 1
    try:
        msg = json.loads(line)
        text = msg["message"]["content"][0]["text"]
    except Exception:
        text = ""
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
    ("--help",): ["--ask-for-approval", "-c"],
    ("exec", "--help"): ["--json", "--ignore-user-config", "--sandbox", "-C", "--model"],
    ("exec", "resume", "--help"): ["--json", "--model"],
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

is_resume = len(argv) > 1 and argv[0:2] == ["exec", "resume"]
if is_resume:
    forbidden = {"-C", "--sandbox", "--ask-for-approval", "--ignore-user-config", "-c"}
    if any(arg in forbidden for arg in argv):
        sys.stderr.write("unsupported resume flag\n")
        sys.exit(64)
    require_flag("--json")
    require_pair("--model", "fake-codex-model")
    if "thread-fixed-fake" not in argv[2:-1]:
        reject("resume is missing the captured thread id")
else:
    require_flag("exec")
    exec_index = argv.index("exec")
    approval_index = require_pair("--ask-for-approval", "never")
    effort_index = require_pair("-c", 'model_reasoning_effort="medium"')
    if approval_index > exec_index or effort_index > exec_index:
        reject("global flags must precede exec")
    require_flag("--json")
    require_flag("--ignore-user-config")
    require_pair("--sandbox", "workspace-write")
    require_flag("-C")
    cwd_index = argv.index("-C")
    if cwd_index + 1 >= len(argv) or not os.path.isdir(argv[cwd_index + 1]):
        reject("-C must name the fixture directory")
    require_pair("--model", "fake-codex-model")
    for required in ("--json", "--ignore-user-config", "--sandbox", "-C", "--model"):
        if argv.index(required) < exec_index:
            reject("exec flag %s must follow exec" % required)

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
command_event_type = "item.completed" if mode == "command-on-completed" else "item.started"
events.append({"type": command_event_type, "item": {"type": "command_execution", "command": command}})
filechange_event_type = "item.started" if mode == "file-change-on-started" else "item.completed"
events.append({"type": filechange_event_type, "item": {"type": "file_change", "changes": [{"path": "notes/codex-turn-%d.md" % n, "kind": "add"}]}})
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

# A PATH-level Bash wrapper pauses the existing capture and grading process
# boundaries. All other scripts immediately delegate to the real interpreter.
phase_bin="$evfake/phase-bin"
mkdir -p "$phase_bin"
cat >"$phase_bin/bash" <<'SH'
#!/bin/sh
block=0
case "${FAKE_RUN_PHASE:-}:$1" in
capture:*/dot-agent-eval-verifiers.*/status.sh) block=1 ;;
grading:"${FAKE_GRADE_PATH:-}") block=1 ;;
esac
if [ "$block" -eq 1 ]; then
  printf 'ready\n' >"$FAKE_PHASE_READY"
  while [ ! -e "$FAKE_PHASE_RELEASE" ]; do sleep 0.05; done
fi
if [ "${FAKE_INFRA_FAIL:-}" = grading ] && [ "$1" = "${FAKE_GRADE_PATH:-}" ]; then
  exit 75
fi
if [ -n "${FAKE_REPLACE_AFTER_GRADE:-}" ] && [ "$1" = "${FAKE_GRADE_PATH:-}" ]; then
  "$FAKE_REAL_BASH" "$@"
  grade_rc=$?
  if [ ! -e "$FAKE_REPLACE_AFTER_GRADE.done" ]; then
    printf '\n# replaced between repeats\n' >>"$FAKE_REPLACE_AFTER_GRADE"
    : >"$FAKE_REPLACE_AFTER_GRADE.done"
  fi
  exit "$grade_rc"
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
if [ "${FAKE_INFRA_FAIL:-}" = trace ] && [ "${1:-}" = - ]; then
  case "${3:-}" in */outputs/trace.jsonl) exit 74 ;; esac
fi
exec "$FAKE_REAL_PYTHON" "$@"
SH
chmod +x "$phase_bin/python3"

# Pauses right after mktemp -d succeeds for a verifier snapshot or a Codex
# home — the "chmod 700 <dir>" that is each setup's very next step — so a
# TERM sent while blocked here lands after ownership is registered but
# before the rest of setup (copies, hashing) has run.
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

# A deterministic append-failure: fails only the one cat call whose sole
# argument's basename matches FAKE_CODEX_APPEND_FAIL, leaving every other
# cat invocation in the run — node-tree capture included — untouched.
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
  # $1 conf path  $2 CLAUDE_BIN  $3 CODEX_BIN  $4 REPEATS  $5 TIMEOUT
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

# run workspace, eval id -> true only for a diagnostic-only void run
eval_void_clean() {
  evc_run=$(find "$1/iteration-1/eval-$2" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n1)
  [ -n "$evc_run" ] \
    && [ -f "$evc_run/run-meta.json" ] \
    && grep -q '"void": true' "$evc_run/run-meta.json" 2>/dev/null \
    && [ ! -e "$evc_run/outputs" ] \
    && [ ! -e "$evc_run/grading.json" ]
}

# trace, fixture root, runner root -> rejects raw, doubled-separator, absolute,
# and canonical aliases after collapsing separator runs for comparison
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

# PID files -> report failure for a missing or live process, and kill every
# recorded survivor so a regression cannot leak it out of this test suite
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

# The fakes fail closed too. Otherwise a removed or misplaced adapter flag
# could leave every behavioral test green against a permissive stand-in.
printf '{}\n' | "$fake_claude" --print >/dev/null 2>&1
rc44claude_flags=$?
[ "$rc44claude_flags" -eq 64 ] && pass "evals: fake claude rejects missing required adapter flags" || fail "evals: fake claude rejects missing required adapter flags (rc=$rc44claude_flags)"
printf 'prompt\n' | "$fake_codex" exec --ask-for-approval never \
  -c 'model_reasoning_effort="medium"' --json --ignore-user-config \
  --sandbox workspace-write -C "$reporoot" --model fake-codex-model - >/dev/null 2>&1
rc44codex_flags=$?
[ "$rc44codex_flags" -eq 64 ] && pass "evals: fake codex rejects misplaced global adapter flags" || fail "evals: fake codex rejects misplaced global adapter flags (rc=$rc44codex_flags)"

# -- discovery: --list-arms resolves configured fake binaries and versions --
conf_disc="$evfake/agents-discovery.conf"
eval_conf_write "$conf_disc" "$fake_claude" "$fake_codex" 1 60
la44=$(EVALS_AGENTS_CONF="$conf_disc" "$evsh" --list-arms 2>&1)
printf '%s\n' "$la44" | grep -qF "$fake_claude" && printf '%s\n' "$la44" | grep -q 'version=9.9.9-fake' && pass "evals: run.sh --list-arms resolves a configured claude binary and its version" || fail "evals: run.sh --list-arms resolves a configured claude binary and its version ($la44)"
printf '%s\n' "$la44" | grep -qF "$fake_codex" && printf '%s\n' "$la44" | grep -q 'version=5.5.5-fake' && pass "evals: run.sh --list-arms resolves a configured codex binary and its version" || fail "evals: run.sh --list-arms resolves a configured codex binary and its version ($la44)"

# Feature support, rather than a guessed release boundary, decides readiness.
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

# Auto resolution must continue past an incompatible PATH candidate to a
# feature-complete configured app candidate.
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

# -- refusal: an unconfigured agent, resolved against binaries guaranteed
# absent rather than against whatever this machine happens to have installed --
conf_unset="$evfake/agents-unset.conf"
eval_conf_write "$conf_unset" "$evfake/no-such-claude" "$evfake/no-such-codex" 1 60
la44b=$(EVALS_AGENTS_CONF="$conf_unset" "$evsh" --list-arms 2>&1)
printf '%s\n' "$la44b" | grep -q 'claude   not ready' && printf '%s\n' "$la44b" | grep -q 'codex    not ready' && pass "evals: run.sh --list-arms reports an unresolvable agent as not ready" || fail "evals: run.sh --list-arms reports an unresolvable agent as not ready ($la44b)"
EVALS_AGENTS_CONF="$conf_unset" "$evsh" --eval scope-question-no-edit --arm x --treatment-arm x \
  --agent claude --corpus-ref "$corpus_ref_test" --workspace "$WORK/ev-refuse" >/dev/null 2>&1
rc44b=$?
[ "$rc44b" -eq 2 ] && pass "evals: run.sh refuses an unconfigured agent" || fail "evals: run.sh refuses an unconfigured agent (rc=$rc44b)"

# Fixture failures still form diagnostic runs. outputs/ starts only after a
# successful build, while the build log and any partial fixture stay retained.
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

# -- claude: stdin delivery, repeat placement inside one iteration, trace
# normalization, spaced workspace path --
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

# A .agent filename is untrusted data. Shell metacharacters in nested path
# components must reach node-tree.txt as text and must never execute.
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

# comments.sh exit 1 means it found blocking comments. The output is an
# artifact for grading rather than an infrastructure failure.
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

# The agent may replace verifier scripts inside the fixture. Capture must run
# only the pre-agent snapshots, so neither payload nor forged output survives.
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

# A tampered status.conf must not suppress the finding its trusted default
# would have raised, and a tampered comments.conf must not exclude the file
# it was trying to hide from the gate.
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

# Claude's existing short-session mode must exercise the result-count guard.
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

# A result-shaped error is not a successful final result, even if the Claude
# process itself exits zero.
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

# The executable digest is part of the locked runtime identity. Replacing a
# binary in place must be detected even when its path and --version stay put.
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

# -- a failing agent process voids the run: no grading.json, nonzero exit --
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
[ ! -e "$rundir_fail/outputs" ] && pass "evals: a void run retains no partial raw output or outputs capture" || fail "evals: a void run retains no partial raw output or outputs capture"

# -- config drift: a later run into the same iteration with a moved locked
# field is refused before touching a fixture --
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

# -- codex: stdin delivery, thread resume across turns, trace normalization --
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
if trace_roots_absent "$rundir_x/outputs/trace.jsonl" "$rundir_x/fixture" "$reporoot"; then
  pass "evals: codex trace text contains no absolute fixture or runner-worktree path"
else
  fail "evals: codex trace text contains no absolute fixture or runner-worktree path ($(cat "$rundir_x/outputs/trace.jsonl" 2>/dev/null))"
fi
[ "$(grep -c 'thread.started' "$rundir_x/outputs/agent-stdout.txt" 2>/dev/null)" = "1" ] && pass "evals: turns 2 and 3 resume the thread turn 1 started rather than opening a new one" || fail "evals: turns 2 and 3 resume the thread turn 1 started rather than opening a new one"

# Every Codex invocation must close exactly one requested turn. Cover the
# first, middle, and final positions because only the first two have a later
# continuation that could otherwise expose the dropped event.
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

# Replace a dedicated Codex binary as its first turn exits. The post-launch
# identity check must void the run before a resume can launch.
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

# ACTIVE_RUN_DIR stays armed after the adapter returns. Pause once during
# capture and once at grader entry, then signal only the runner process.
real_bash=$(command -v bash)
real_git=$(command -v git)
real_python=$(command -v python3)
real_chmod=$(command -v chmod)
real_cat=$(command -v cat)

# Replace a dedicated Claude binary after repeat one has graded. Repeat two
# must fail its pre-launch identity check without driving the replacement.
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
  FAKE_GRADE_PATH="$evroot/grade.sh" EVALS_AGENTS_CONF="$conf_repeat_replace" \
  FAKE_CLAUDE_MODE=ok FAKE_CLAUDE_TURNS=1 \
  "$evsh" --eval scope-question-no-edit --arm treat --treatment-arm treat \
  --agent claude --corpus-ref "$corpus_ref_test" --workspace "$wsc_repeat_replace" >/dev/null 2>&1
rc44repeat_replace=$?
repeat_replace_eval="$wsc_repeat_replace/iteration-1/eval-scope-question-no-edit"
repeat_replace_void=$(find "$repeat_replace_eval" -name run-meta.json -exec grep -l '"status": "agent_identity_mismatch"' {} \; 2>/dev/null | head -n1)
if [ "$rc44repeat_replace" -ne 0 ] \
  && [ "$(find "$repeat_replace_eval" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | grep -c .)" -eq 2 ] \
  && [ -n "$repeat_replace_void" ] \
  && [ ! -e "${repeat_replace_void%/run-meta.json}/outputs" ] \
  && [ ! -e "${repeat_replace_void%/run-meta.json}/grading.json" ]; then
  pass "evals: same-path executable replacement between repeats voids the affected repeat"
else
  fail "evals: same-path executable replacement between repeats voids the affected repeat (rc=$rc44repeat_replace)"
fi

for run_phase in capture grading; do
  phase_workspace="$evfake/claude workspace-signal-$run_phase"
  phase_conf="$evfake/agents-signal-$run_phase.conf"
  phase_ready="$evfake/$run_phase-ready"
  phase_release="$evfake/$run_phase-release"
  rm -f "$phase_ready" "$phase_release"
  eval_conf_write "$phase_conf" "$fake_claude" "$evfake/no-such-codex" 1 60
  PATH="$phase_bin:$PATH" FAKE_REAL_BASH="$real_bash" FAKE_REAL_GIT="$real_git" \
    FAKE_REAL_PYTHON="$real_python" FAKE_REAL_CHMOD="$real_chmod" FAKE_REAL_CAT="$real_cat" \
    FAKE_RUN_PHASE="$run_phase" \
    FAKE_GRADE_PATH="$evroot/grade.sh" FAKE_PHASE_READY="$phase_ready" \
    FAKE_PHASE_RELEASE="$phase_release" EVALS_AGENTS_CONF="$phase_conf" \
    FAKE_CLAUDE_MODE=ok FAKE_CLAUDE_TURNS=1 \
    "$evsh" --eval scope-question-no-edit --arm treat --treatment-arm treat \
    --agent claude --corpus-ref "$corpus_ref_test" --workspace "$phase_workspace" >/dev/null 2>&1 &
  phase_runner_pid=$!
  phase_wait=0
  while [ ! -s "$phase_ready" ] && [ "$phase_wait" -lt 100 ]; do
    sleep 0.1
    phase_wait=$((phase_wait + 1))
  done
  kill -TERM "$phase_runner_pid" 2>/dev/null
  : >"$phase_release"
  wait "$phase_runner_pid" 2>/dev/null
  phase_rc=$?
  phase_run=$(find "$phase_workspace/iteration-1/eval-scope-question-no-edit" \
    -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n1)
  if [ "$phase_rc" -ne 0 ] && [ -s "$phase_ready" ] \
    && eval_void_clean "$phase_workspace" scope-question-no-edit \
    && grep -q '"status": "cancelled"' "$phase_run/run-meta.json" 2>/dev/null; then
    pass "evals: TERM during $run_phase retains cancelled metadata and no outputs or grading"
  else
    kill -KILL "$phase_runner_pid" 2>/dev/null
    fail "evals: TERM during $run_phase retains cancelled metadata and no outputs or grading (rc=$phase_rc)"
  fi
done

# Each post-agent infrastructure stage must fail closed with its own metadata
# status and reason. The fixture and fixture-build diagnostics remain retained.
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
    FAKE_GRADE_PATH="$evroot/grade.sh" EVALS_AGENTS_CONF="$infra_conf" \
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

# Transcript sections represent completed turns, rather than nonempty lines:
# multiline final text remains intact and an empty final answer stays visible.
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

# On an interrupt, authentication must be in a system-temporary home, never
# outputs/, and the active home is removed before the runner terminates.
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

# A targeted TERM reaches only run.sh. Its cleanup must then terminate the
# detached fake CLI process group, including a child and grandchild, without
# sending a signal to this parent test process.
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
  && [ ! -e "$cancel_rundir/outputs" ]; then
  pass "evals: cancellation retains void metadata and removes partial outputs"
else
  fail "evals: cancellation retains void metadata and removes partial outputs"
fi

# The portable timeout starts a new process group. Descendants that ignore
# TERM must receive KILL after the grace period, even when the leader exits.
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
  && [ ! -e "$timeout_rundir/outputs" ]; then
  pass "evals: timeout retains void metadata and removes partial outputs"
else
  fail "evals: timeout retains void metadata and removes partial outputs"
fi

# The grader is the piece that turns spec.json's check strings from a
# declared DSL into executing code. Driven here against artifacts written by
# hand, so the primitives are pinned without a model or a network.
gd="$WORK/eval-grade/r0"
mkdir -p "$gd/outputs"
cat >"$gd/snap.json" <<'EOF'
{"id":"g","assertions":[
 {"id":"g/new","concept":"c","class":"artifact","grade":"auto","check":"product_files_added == 1"},
 {"id":"g/append","concept":"c","class":"artifact","grade":"auto","check":"memory_files_added == 0"},
 {"id":"g/order","concept":"c","class":"trace","grade":"auto","check":"trace_order 'catalog' before 'write:'"},
 {"id":"g/absent","concept":"c","class":"artifact","grade":"auto","check":"node_tree_absent 'SECRET-TOKEN'"},
 {"id":"g/missing","concept":"c","class":"artifact","grade":"auto","check":"gate_block_count == 0"},
 {"id":"g/human","concept":"c","class":"artifact","grade":"manual"}]}
EOF
# A created file and an appended one, so "added" cannot be inferred from
# "has no removed lines" — the defect that read an append as a creation.
printf -- '--- /dev/null\n+++ b/src/new.ts\n+const a = 1\n' >"$gd/outputs/diff.patch"
printf -- '--- a/memory/x.md\n+++ b/memory/x.md\n+a line\n' >"$gd/outputs/node-diff.patch"
printf '{"seq":0,"event":"call","tool":"read_file","action":"read","text":"read catalog"}\n{"seq":1,"event":"call","tool":"write_file","action":"write","text":"write:src/new.ts"}\n' >"$gd/outputs/trace.jsonl"
printf 'nothing sensitive here\n' >"$gd/outputs/node-tree.txt"
"$evroot/grade.sh" "$gd" "$gd/snap.json" >/dev/null 2>&1
g42=$(python3 -c '
import json,sys
r = {x["id"]: x for x in json.load(open(sys.argv[1]))["results"]}
bad = []
if not r["g/new"]["passed"]: bad.append("new-file-not-counted")
if not r["g/append"]["passed"]: bad.append("append-read-as-creation")
if not r["g/order"]["passed"]: bad.append("trace-order")
if not r["g/absent"]["passed"]: bad.append("tree-absence")
if r["g/missing"]["passed"]: bad.append("missing-artifact-passed-by-default")
if r["g/human"]["passed"] is not None: bad.append("manual-was-auto-graded")
print(" ".join(bad))' "$gd/grading.json" 2>&1)
[ -z "$g42" ] && pass "evals: the grader evaluates its check language and fails closed on a missing artifact" || fail "evals: the grader evaluates its check language and fails closed on a missing artifact ($g42)"

# Trace calls are controller-owned evidence.  In particular, ordering cannot
# infer a missing second call, malformed records cannot be searched, and
# result/non-call records cannot stand in for a tool call.
trace_snapshot="$gd/trace-snapshot.json"
printf '{"id":"trace","assertions":[{"id":"trace/order","concept":"c","class":"trace","grade":"auto","check":"trace_order '\''catalog'\'' before '\''write:'\''"},{"id":"trace/product","concept":"c","class":"artifact","grade":"auto","check":"product_files_added == 1"}]}' >"$trace_snapshot"
trace_result() {
  "$evroot/grade.sh" "$gd" "$trace_snapshot" >/dev/null 2>&1
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

# The rollup fails closed on records that cannot support a delta. An id set
# that disagrees with its snapshot silently drops rows; an arm token inside a
# grading record means the grader could see the condition. Either one makes
# the number wrong rather than absent, which is the failure this suite exists
# to catch everywhere else.
evr="$WORK/eval-rollup"
mkdir -p "$evr/eval-demo/r1" "$evr/eval-demo/r2"
printf '{"r1":"treat","r2":"ctrl"}\n' >"$evr/arm-map.json"
printf '{"treatment_arm":"treat"}\n' >"$evr/run-config.json"
printf '{"id":"demo","assertions":[{"id":"a1","concept":"c"},{"id":"a2","concept":"c"}]}\n' >"$evr/eval-demo/eval-snapshot.json"
printf '{"results":[{"id":"a1","passed":true,"evidence":"q"},{"id":"a2","passed":false,"evidence":"r"}]}\n' >"$evr/eval-demo/r1/grading.json"
printf '{"results":[{"id":"a1","passed":false,"evidence":"s"},{"id":"a2","passed":false,"evidence":"t"}]}\n' >"$evr/eval-demo/r2/grading.json"
out42=$("$evroot/rollup.sh" "$evr" 2>&1)
rc42=$?
[ "$rc42" -eq 0 ] && printf '%s\n' "$out42" | grep -q 'discriminating' && pass "evals: rollup joins two arms and buckets by outcome" || fail "evals: rollup joins two arms and buckets by outcome (rc=$rc42; $out42)"

printf '{"results":[{"id":"a1","passed":true,"evidence":"q"}]}\n' >"$evr/eval-demo/r1/grading.json"
"$evroot/rollup.sh" "$evr" >/dev/null 2>&1
rc42b=$?
[ "$rc42b" -eq 2 ] && pass "evals: rollup refuses a grading record whose ids disagree with its snapshot" || fail "evals: rollup refuses a grading record whose ids disagree with its snapshot (rc=$rc42b)"

printf '{"results":[{"id":"a1","passed":true,"evidence":"the treat arm did it"},{"id":"a2","passed":true,"evidence":"r"}]}\n' >"$evr/eval-demo/r1/grading.json"
"$evroot/rollup.sh" "$evr" >/dev/null 2>&1
rc42c=$?
[ "$rc42c" -eq 2 ] && pass "evals: rollup refuses a grading record naming its own arm" || fail "evals: rollup refuses a grading record naming its own arm (rc=$rc42c)"

printf '{"results":[{"id":"a1","passed":null,"evidence":null},{"id":"a2","passed":true,"evidence":"r"}]}\n' >"$evr/eval-demo/r1/grading.json"
"$evroot/rollup.sh" "$evr" >/dev/null 2>&1
rc42e=$?
[ "$rc42e" -eq 2 ] && pass "evals: rollup refuses an iteration with a manual assertion still ungraded" || fail "evals: rollup refuses an iteration with a manual assertion still ungraded (rc=$rc42e)"

# ---- 45. evals/run.sh: subscription-backed auth, thread lifecycle,
#          process-group cleanup on success, setup-cancellation ownership,
#          Codex stream-append checks, and concurrent metadata updates ----
# The default $evauth credentials (claude-ok / codex-ok, set up above) are
# subscription-backed and valid, so every fake-CLI test above this section
# authenticates normally. Each block below overrides CLAUDE_CONFIG_DIR or
# CODEX_HOME (or the operator's own env) for exactly one invocation to prove
# the rejection path, never the suite-wide default.

# -- claude refuses to run without claude.ai subscription credentials --
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

# -- claude refuses an API-key-only credentials file: no claude.ai plan --
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

# -- codex refuses to run without ChatGPT-account credentials --
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

# -- codex refuses an auth_mode other than chatgpt, and never surfaces the
# rejected credential's value while doing it --
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

# -- provider credential and alternate-provider env vars never reach either
# adapter's subprocess, even when set in the operator's own shell --
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

# -- Codex thread/item lifecycle: exactly one thread.started per initial
# turn, at most one (identity-matched) on a resume, command_execution only
# from its start event, file_change only from its completion event --
for lifecycle_mode in duplicate-thread-started resume-thread-mismatch \
  command-on-completed file-change-on-started; do
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

# Corrected from the prior review round: Codex may legitimately re-announce
# thread.started on a resumed turn. Singular and identity-matched, it must
# not be rejected.
wscx_resume_ok="$evfake/codex workspace-resume-thread-started-ok"
conf_codex_resume_ok="$evfake/agents-codex-resume-ok.conf"
eval_conf_write "$conf_codex_resume_ok" "$evfake/no-such-claude" "$fake_codex" 1 60
EVALS_AGENTS_CONF="$conf_codex_resume_ok" FAKE_CODEX_MODE=resume-thread-started-ok \
  "$evsh" --eval bootstrap-once --arm treat --treatment-arm treat \
  --agent codex --corpus-ref "$corpus_ref_test" --workspace "$wscx_resume_ok" >/dev/null 2>&1
rc_resume_ok=$?
[ "$rc_resume_ok" -eq 0 ] && pass "evals: a resumed turn may legitimately re-announce the same thread id" || fail "evals: a resumed turn may legitimately re-announce the same thread id (rc=$rc_resume_ok)"

# -- a successful leader exit still clears any process-group member it left
# running, before capture begins, without losing its own exit status --
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

# -- ownership of a verifier snapshot / Codex home is registered immediately
# after mktemp, so a cancellation mid-setup still cleans up the directory --
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

# -- a failed append of a Codex turn's stream to canonical stdout voids the
# run with a truthful status, rather than silently dropping the turn --
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

# -- run-config.json and arm-map.json updates are serialized: N concurrent
# dry runs into one iteration retain one consistent treatment/config and a
# complete run mapping, with no update lost to a read-modify-write race --
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

# ---- summary ----
ran=$((PASS + FAIL))

# The denominator is computed from what ran, so a check that stops running
# — a fixture that failed to build, a variable gone empty — used to lower
# the total silently and still report every check passing. Update this
# number when you add or remove a check, deliberately.
EXPECTED_CHECKS=485
if [ "$ran" -ne "$EXPECTED_CHECKS" ]; then
  printf 'FAIL check count: expected %d, ran %d — a check was added, removed, or stopped running\n' "$EXPECTED_CHECKS" "$ran"
  FAIL=$((FAIL + 1))
fi

total=$((PASS + FAIL))
printf '\n%d/%d checks passed (%d failed)\n' "$PASS" "$total" "$FAIL"
[ "$FAIL" -eq 0 ] && exit 0
exit 1
