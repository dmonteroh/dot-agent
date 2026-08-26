#!/usr/bin/env bash
# scripts/test.sh — self-contained smoke tests for node.sh, status.sh,
# log.sh, memory.sh, docs.sh, links.sh, and comments.sh (the scripts this
# repo ships under scripts/, which node.sh init/update copies into every
# node).
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

    # node.sh does the mechanical half of bootstrap; the judgement half
    # (guardrails, quality-bar split) is the agent's, and a node with it
    # still undone is not a finished node — status.sh says so.
    flags=$(status_flags "$root")
    printf '%s\n' "$flags" | grep -qF 'Project guardrails still holds template placeholders' && pass "init $preset/$mode: unfilled guardrails draw a REPAIR flag" || fail "init $preset/$mode: unfilled guardrails draw a REPAIR flag ($flags)"
    printf '%s\n' "$flags" | grep -qF 'still contains ## Quality bar' && pass "init $preset/$mode: unsplit quality bar draws a REPAIR flag" || fail "init $preset/$mode: unsplit quality bar draws a REPAIR flag ($flags)"

    finish_bootstrap "$root"
    flags=$(status_flags "$root")
    [ -z "$flags" ] && pass "init $preset/$mode: status.sh clean once bootstrap completes" || fail "init $preset/$mode: status.sh clean once bootstrap completes ($flags)"

    scriptsok=true
    for f in status.sh log.sh memory.sh docs.sh links.sh; do
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
finish_bootstrap "$docroot"
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
"$NODE" update "$hdrroot" >/dev/null 2>&1
hdrfact="$hdrroot/.agent/memory/auth-flow.md"
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
# that in lockstep by hand and it slipped. presets/_shared.md is the list;
# this is the check that makes the list load-bearing rather than a comment.
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
  # ${label} is braced, not bare: in a single-byte locale the first byte of
  # the following "…" (0xE2) is the letter â, and bash 3.2 parses an
  # unbraced $name with locale-aware isalnum(), so it absorbs that byte into
  # the variable name and `set -u` kills the run.
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

# The memory split made memory.md an index; no preset may still instruct
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
# and treating them as findings buried the real ones in the field run.
printf '\nBrief: `temp/some-task-board.md`, source `src/app/main.md`.\n' >>"$lk/.agent/docs/backend.md"
out28d=$("$LINKS" "$lk" 2>&1)
printf '%s\n' "$out28d" | grep -qF 'temp/some-task-board.md' && fail "links.sh: paths outside the node are out of scope" || pass "links.sh: paths outside the node are out of scope"

# A loose basename resolves against the whole node: docs cite `learned.md`,
# not `rules/learned.md`.
printf '\nSee `learned.md` for the accumulated corrections.\n' >>"$lk/.agent/docs/backend.md"
out28e=$("$LINKS" "$lk" 2>&1)
printf '%s\n' "$out28e" | grep -qF 'cites learned.md' && fail "links.sh: a loose basename resolves against the node" || pass "links.sh: a loose basename resolves against the node"

# A bare name the node cannot resolve is as likely a project file as a node
# one — memory facts name `SKILL.md` and `implementer-prompt.md` constantly.
# A field node reported 12 BROKEN links, 11 of them project files sitting in
# a subdirectory rather than at the project root.
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
# errors when that happens; this lint is the only mechanism that notices.
# Each allowlisted pattern below marks a deliberate reference:
#   filename (CLAUDE.md          template header — copying instruction, deleted on copy
#   uses Copilot Chat            template header — the same instruction's Copilot clause
#   and AGENTS.md identical      template — the mirror rule
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
and AGENTS.md identical
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
# is prose, the other bypassable by hand-editing the file. A live node
# hand-appended 32/32 narrative entries (largest 306 words) with zero flags
# while a sibling held 0/88; this is the check that tells them apart.
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
# The preset's comment rule was prose in three places on a live field node
# and was breached anyway. The gate mechanizes the objective half: an added
# comment citing what a fresh clone cannot open BLOCKs (exit 1); every
# other added comment is listed for justification (REVIEW, exit 0). The
# shipped core carries only universal dead citations; workflow vocabulary —
# base ref, ticket patterns, path exclusions — is the node's, set in
# comments.conf beside the script (KEY=value, parsed never executed) and
# outside the update refresh list.
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
printf '%s\n' "$out34" | grep -q 'eslint-disable' && fail "comments.sh: tooling pragmas are skipped" || pass "comments.sh: tooling pragmas are skipped"
printf '%s\n' "$out34" | grep -q 'existing constraint comment' && fail "comments.sh: only comments the diff adds are reported" || pass "comments.sh: only comments the diff adds are reported"

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

# install and refresh: init ships it; update refreshes it by name and never
# touches the node-owned local file beside it
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

# ---- 35. status.sh: per-node overrides in status.conf ----
# The thresholds and the probed-tools list are per-project tunables, but
# an edit to status.sh itself is discarded by node.sh update — a field
# node patching gh out of PROBE_TOOLS lost the edit that way. The conf
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
# conf that drifted from the script's would document a lie; this pins the
# two together.
mismatch36=""
for k in LOG_MAX_ENTRIES LOG_MAX_WORDS LOG_ENTRY_MAX_WORDS MEMORY_MAX_WORDS \
         MEMORY_MAX_ENTRIES LEARNED_MAX_RULES LEARNED_MAX_WORDS \
         DOCS_MAX_WORDS TAIL_LINES; do
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

# ---- summary ----
total=$((PASS + FAIL))
printf '\n%d/%d checks passed (%d failed)\n' "$PASS" "$total" "$FAIL"
[ "$FAIL" -eq 0 ] && exit 0
exit 1
