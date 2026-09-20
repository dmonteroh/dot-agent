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
IDXSH="$reporoot/scripts/index.sh"

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
# Do not remove or rewrite this block; update passes may set `migration_target` — version changes only at finalize.
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
<!-- One entry per turn that changed files, newest last. -->

- [2026-01-01] (claude) fixture bootstrap for smoke tests (testing). verify: pass.
EOF
  # rules/contract.md and rules/learned.md are always-loaded canonical
  # files on a real V6 node — status.sh flags either one missing — so the
  # fixture ships both, plus rules/quality-bar.md, to stay a realistic
  # bootstrap-complete node rather than one the bootstrap-completion check
  # (further down in status.sh, untouched by this task) also flags.
  cat >"$fx/.agent/rules/contract.md" <<'EOF'
# Contract

## Project guardrails

- Build: `true`
EOF
  cat >"$fx/.agent/rules/quality-bar.md" <<'EOF'
# Quality bar

Fixture quality-bar body for smoke tests.
EOF
  cat >"$fx/.agent/rules/learned.md" <<'EOF'
# Learned rules
<!-- Binding rules distilled from operator corrections. -->

- [2026-01-01] Fixture learned-rule body for smoke tests.
EOF
  if [ "$fxmode" != "ignore-all" ]; then
    sed "s/^  mode: ignore-all/  mode: $fxmode/" "$fx/.agent/purpose.md" >"$fx/.agent/purpose.md.tmp"
    mv "$fx/.agent/purpose.md.tmp" "$fx/.agent/purpose.md"
  fi
}

# root -> a minimal .agent/rules + .agent/docs tree for index.sh: one rule
# record and one route record, both real enough that render produces one
# page of each kind. index.sh's own fixtures are built here rather than as
# checked-in files, the same way make_v6_fixture is — disposable, built
# fresh per test under $WORK, never touching this repo.
make_index_fixture() {
  ifx="$1"
  mkdir -p "$ifx/.agent/rules" "$ifx/.agent/docs"
  cat >"$ifx/.agent/rules/contract.md" <<'EOF'
# Contract

## Project guardrails

- Build: `true`
EOF
  cat >"$ifx/.agent/docs/architecture.md" <<'EOF'
# Alpha
<!-- Read when: working on auth -->
Body text describing the alpha area.
EOF
}

# path -> epoch mtime, BSD or GNU stat. GNU-first: GNU's `-f` means
# "filesystem status", not a BSD format flag, so `stat -f '%m'` succeeds
# on Linux without erroring and prints an unrelated filesystem report
# instead of the mtime — trying it first can never detect that failure.
# `-c` is GNU-only and BSD stat rejects it outright, so trying `-c`
# first is safe on both.
idx_mtime() {
  stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1"
}

# path -> a snapshot of every file's relative path, byte count, and mtime
# under it, sorted — used to prove a warm run touches nothing at all.
idx_snapshot() {
  find "$1" -type f -exec sh -c 'for f; do
    sz=$(wc -c <"$f"); mt=$(stat -c "%Y" "$f" 2>/dev/null || stat -f "%m" "$f"); printf "%s %s %s\n" "$f" "$sz" "$mt"
  done' sh {} + | sort
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
    for f in status.sh log.sh memory.sh docs.sh links.sh comments.sh checkpoint.sh index.sh finish.sh learn.sh; do
      [ -x "$root/.agent/scripts/$f" ] || missing="$missing $f"
    done
    for f in comments.conf status.conf log.conf; do
      [ -f "$root/.agent/scripts/$f" ] || missing="$missing $f"
    done
    [ -z "$missing" ] && pass "init $preset/$mode: every shipped script and starter conf is in place" || fail "init $preset/$mode: every shipped script and starter conf is in place (missing:$missing)"
    # A node receives executables and their confs. This repo's design notes
    # under scripts/docs/ are not a node's to carry.
    [ ! -e "$root/.agent/scripts/docs" ] && pass "init $preset/$mode: scripts/docs is not shipped into the node" || fail "init $preset/$mode: scripts/docs is not shipped into the node"

    # --indexes defaults to manual when the flag is omitted, so an
    # unmodified `init` call is unaffected by the new field.
    grep -qxF '  indexes: manual        # manual | generated' "$root/.agent/purpose.md" \
      && pass "init $preset/$mode: manifest defaults to indexes: manual" \
      || fail "init $preset/$mode: manifest defaults to indexes: manual"
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

unk_indexes="$WORK/unknown-indexes"
mkdir -p "$unk_indexes"
"$NODE" init --preset software-development --mode ignore-all --indexes bogus-indexes "$unk_indexes" >/dev/null 2>"$WORK/err4"
rc=$?
[ "$rc" -ne 0 ] && pass "unknown --indexes exits nonzero" || fail "unknown --indexes exits nonzero"
[ ! -e "$unk_indexes/.agent" ] && pass "unknown --indexes creates nothing" || fail "unknown --indexes creates nothing"
grep -qF "unknown --indexes: 'bogus-indexes' (must be manual or generated)" "$WORK/err4" \
  && pass "unknown --indexes: message matches the --mode refusal style" \
  || fail "unknown --indexes: message matches the --mode refusal style"

idxman="$WORK/init-indexes-manual"
mkdir -p "$idxman"
"$NODE" init --preset software-development --mode ignore-all --indexes manual "$idxman" >/dev/null 2>&1
grep -qxF '  indexes: manual        # manual | generated' "$idxman/.agent/purpose.md" \
  && pass "init --indexes manual: manifest carries the line" \
  || fail "init --indexes manual: manifest carries the line"

idxgen="$WORK/init-indexes-generated"
mkdir -p "$idxgen"
"$NODE" init --preset software-development --mode ignore-all --indexes generated "$idxgen" >/dev/null 2>&1
grep -qxF '  indexes: generated        # manual | generated' "$idxgen/.agent/purpose.md" \
  && pass "init --indexes generated: manifest carries the line" \
  || fail "init --indexes generated: manifest carries the line"
[ -x "$idxgen/.agent/scripts/index.sh" ] \
  && pass "init --indexes generated: index.sh is installed" \
  || fail "init --indexes generated: index.sh is installed"

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

grep -v '^  version:' "$WORK/purpose-before.md" | grep -v '^  migration_target:' | grep -v '^  indexes:' >"$WORK/pb-noversion"
grep -v '^  version:' "$v6root/.agent/purpose.md" | grep -v '^  migration_target:' | grep -v '^  indexes:' >"$WORK/pa-noversion"
diff -q "$WORK/pb-noversion" "$WORK/pa-noversion" >/dev/null 2>&1 && pass "update: manifest diff touches only the version, migration_target, and indexes lines" || fail "update: manifest diff touches only the version, migration_target, and indexes lines"
grep -q '^  version: 6$' "$v6root/.agent/purpose.md" 2>/dev/null && pass "update: version stays at 6 (unbumped) — finalize's job" || fail "update: version stays at 6 (unbumped) — finalize's job"
grep -q '^  migration_target: "6.2"' "$v6root/.agent/purpose.md" 2>/dev/null && pass "update: migration_target is now \"6.2\"" || fail "update: migration_target is now \"6.2\""
[ "$(grep -A1 '^  version:' "$v6root/.agent/purpose.md" | tail -n1)" = '  migration_target: "6.2"' ] && pass "update: migration_target is inserted right after version" || fail "update: migration_target is inserted right after version"
grep -qF "finalize" "$WORK/update.out" && pass "update: closing message names the pending finalize step" || fail "update: closing message names the pending finalize step"

# make_v6_fixture's manifest carries no indexes line at all; update
# backfills it as manual — the same value an absent field already reads
# as — beside mode.
grep -qxF '  indexes: manual        # manual | generated' "$v6root/.agent/purpose.md" \
  && pass "update: a manifest with no indexes line is backfilled with indexes: manual" \
  || fail "update: a manifest with no indexes line is backfilled with indexes: manual"
[ "$(grep -A1 '^  mode:' "$v6root/.agent/purpose.md" | tail -n1)" = '  indexes: manual        # manual | generated' ] \
  && pass "update: the backfilled indexes line is inserted right after mode" \
  || fail "update: the backfilled indexes line is inserted right after mode"
grep -qF "indexes: manual backfilled" "$WORK/update.out" \
  && pass "update: the backfill is reported" \
  || fail "update: the backfill is reported"
[ -x "$v6root/.agent/scripts/index.sh" ] \
  && pass "update: index.sh is installed alongside the existing seven scripts" \
  || fail "update: index.sh is installed alongside the existing seven scripts"

# ---- 4b. update leaves an already-present indexes line untouched ----
# node.sh:555-564 (version-current) and node.sh:640-649 (older-version,
# mid-migration) both gate the backfill write on the indexes line being
# absent. This proves the gate holds — no duplicate line, no reset to
# manual, no backfill message — when a line is already present, in
# either value, on both branches.
idxpresent_older() {
  io_dir="$1" io_value="$2"
  mkdir -p "$io_dir"
  make_v6_fixture "$io_dir"
  io_modeline=$(grep -n '^  mode:' "$io_dir/.agent/purpose.md" | head -1 | cut -d: -f1)
  awk -v ln="$io_modeline" -v val="$io_value" \
    'NR==ln { print; print "  indexes: " val "        # manual | generated"; next } { print }' \
    "$io_dir/.agent/purpose.md" >"$io_dir/.agent/purpose.md.tmp"
  mv "$io_dir/.agent/purpose.md.tmp" "$io_dir/.agent/purpose.md"
  "$NODE" update "$io_dir" >"$io_dir.out" 2>&1
  io_lines=$(grep -c '^  indexes:' "$io_dir/.agent/purpose.md")
  [ "$io_lines" -eq 1 ] \
    && pass "update (older-version): existing indexes: $io_value is not duplicated" \
    || fail "update (older-version): existing indexes: $io_value is not duplicated (found $io_lines lines)"
  grep -qxF "  indexes: $io_value        # manual | generated" "$io_dir/.agent/purpose.md" \
    && pass "update (older-version): existing indexes: $io_value is left byte-unchanged" \
    || fail "update (older-version): existing indexes: $io_value is left byte-unchanged"
  grep -qF "indexes:" "$io_dir.out" \
    && fail "update (older-version): no backfill message when indexes: $io_value is already present" \
    || pass "update (older-version): no backfill message when indexes: $io_value is already present"
}
idxpresent_older "$WORK/idxpresent-older-generated" generated
idxpresent_older "$WORK/idxpresent-older-manual" manual

idxpresent_current() {
  ic_src="$1" ic_value="$2"
  ic_dir="$WORK/idxpresent-current-$ic_value"
  cp -R "$ic_src" "$ic_dir"
  "$NODE" update "$ic_dir" >"$ic_dir.out" 2>&1
  ic_lines=$(grep -c '^  indexes:' "$ic_dir/.agent/purpose.md")
  [ "$ic_lines" -eq 1 ] \
    && pass "update (version-current): existing indexes: $ic_value is not duplicated" \
    || fail "update (version-current): existing indexes: $ic_value is not duplicated (found $ic_lines lines)"
  grep -qxF "  indexes: $ic_value        # manual | generated" "$ic_dir/.agent/purpose.md" \
    && pass "update (version-current): existing indexes: $ic_value is left byte-unchanged" \
    || fail "update (version-current): existing indexes: $ic_value is left byte-unchanged"
  grep -qF "indexes:" "$ic_dir.out" \
    && fail "update (version-current): no backfill message when indexes: $ic_value is already present" \
    || pass "update (version-current): no backfill message when indexes: $ic_value is already present"
}
idxpresent_current "$idxgen" generated
idxpresent_current "$idxman" manual

flags4=$(status_flags "$v6root")
printf '%s\n' "$flags4" | grep -q '^GROOM: memory/legacy\.md' && pass "update: status.sh flags legacy.md with GROOM" || fail "update: status.sh flags legacy.md with GROOM"
# migration_target is now pending (version stays unbumped until finalize),
# so status.sh's own pending-migration REPAIR is expected here — that is
# the only REPAIR a freshly-updated node should carry.
flags4_repairs=$(printf '%s\n' "$flags4" | grep '^REPAIR:')
[ "$flags4_repairs" = 'REPAIR: purpose.md has migration_target "6.2" pending — run node.sh finalize to stamp version 6.2 and clear migration_target' ] \
  && pass "update: status.sh shows only the pending-migration REPAIR" \
  || fail "update: status.sh shows only the pending-migration REPAIR ($flags4_repairs)"

# ---- 5. update idempotency (second run on v6root, migration_target still pending) ----
# version was never bumped in step 4 — the node still reads oldversion=6
# with migration_target="6.2" pending, so this run must resume, not report
# "current", and must reuse (not re-copy) the existing backup.
cp -R "$v6root/.agent" "$WORK/v6root-agent-snapshot"
"$NODE" update "$v6root" >"$WORK/update2.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "update re-run (pending migration_target) exits 0" || fail "update re-run (pending migration_target) exits 0 (rc=$rc)"
grep -qF "node is current" "$WORK/update2.out" && fail "update re-run with a pending migration_target does not report the node current" || pass "update re-run with a pending migration_target does not report the node current"
grep -qF "resuming" "$WORK/update2.out" && pass "update re-run reports resuming the interrupted update" || fail "update re-run reports resuming the interrupted update"
diff -r "$WORK/v6root-agent-snapshot" "$v6root/.agent" >/dev/null 2>&1 && pass "update re-run with a pending migration_target is a content no-op (diff -r clean)" || fail "update re-run with a pending migration_target is a content no-op (diff -r clean)"

# ---- 5b. update interrupted after the backup, before content mutation: retry resumes ----
# Model the exact interruption point: the backup was made from the
# pre-migration node, migration_target was then written to the live
# manifest, and the process died before any content mutation ran.
interrupt="$WORK/update-interrupted"
mkdir -p "$interrupt"
make_v6_fixture "$interrupt"
cp -R "$interrupt/.agent" "$interrupt/.agent.backup-v6"
printf 'pre-existing backup marker\n' >"$interrupt/.agent.backup-v6/.marker"
awk '/^  version: 6$/ { print; print "  migration_target: \"6.2\""; next } { print }' \
  "$interrupt/.agent/purpose.md" >"$interrupt/.agent/purpose.md.tmp"
mv "$interrupt/.agent/purpose.md.tmp" "$interrupt/.agent/purpose.md"
"$NODE" update "$interrupt" >"$WORK/update-interrupt.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "update: retry of an interrupted update exits 0" || fail "update: retry of an interrupted update exits 0 (rc=$rc)"
grep -qF "backup path already exists" "$WORK/update-interrupt.out" && fail "update: retry of an interrupted update does not abort on its own backup" || pass "update: retry of an interrupted update does not abort on its own backup"
[ -f "$interrupt/.agent.backup-v6/.marker" ] && pass "update: retry does not re-copy over the existing backup" || fail "update: retry does not re-copy over the existing backup"
grep -q "custom auth flow" "$interrupt/.agent.backup-v6/memory.md" 2>/dev/null && pass "update: retry's backup still holds the pre-migration memory.md" || fail "update: retry's backup still holds the pre-migration memory.md"
grep -q '^  migration_target:' "$interrupt/.agent.backup-v6/purpose.md" && fail "update: retry's backup predates migration_target, as the pre-migration node did" || pass "update: retry's backup predates migration_target, as the pre-migration node did"
[ -f "$interrupt/.agent/memory/legacy.md" ] && pass "update: retry completes the interrupted content mutation" || fail "update: retry completes the interrupted content mutation"
legacy_count=$(grep -cF "[Legacy memory](memory/legacy.md)" "$interrupt/.agent/memory.md")
[ "$legacy_count" -eq 1 ] && pass "update: retry does not duplicate the legacy memory index line" || fail "update: retry does not duplicate the legacy memory index line (count=$legacy_count)"
grep -q '^  version: 6$' "$interrupt/.agent/purpose.md" 2>/dev/null && pass "update: retry still leaves version unbumped" || fail "update: retry still leaves version unbumped"

# ---- 5d. memory split interrupted after memory/ is created, before legacy.md is written ----
# Model the crash window inside the split step itself: memory/ exists
# (mkdir succeeded) but nothing has been written into it yet, and
# memory.md still holds its original pre-split prose body untouched.
# FU05 (F4a follow-up): a memdir-existence gate cannot tell this apart
# from a completed split, so it would skip the split forever, stranding
# the prose body outside any legacy.md and never linking it from the
# index.
splitA="$WORK/update-split-interrupted-a"
mkdir -p "$splitA/.agent/memory"
make_v6_fixture "$splitA"
cp -R "$splitA/.agent" "$splitA/.agent.backup-v6"
awk '/^  version: 6$/ { print; print "  migration_target: \"6.2\""; next } { print }' \
  "$splitA/.agent/purpose.md" >"$splitA/.agent/purpose.md.tmp"
mv "$splitA/.agent/purpose.md.tmp" "$splitA/.agent/purpose.md"
"$NODE" update "$splitA" >"$WORK/update-splitA.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "update: resume after memory/ created but empty exits 0" || fail "update: resume after memory/ created but empty exits 0 (rc=$rc)"
grep -q "custom auth flow" "$splitA/.agent/memory/legacy.md" 2>/dev/null && pass "update: resume after an empty memory/ still moves the body to legacy.md" || fail "update: resume after an empty memory/ still moves the body to legacy.md"
splitA_links=$(grep -cF "[Legacy memory](memory/legacy.md)" "$splitA/.agent/memory.md")
[ "$splitA_links" -eq 1 ] && pass "update: resume after an empty memory/ adds exactly one index link" || fail "update: resume after an empty memory/ adds exactly one index link (count=$splitA_links)"
grep -q "custom auth flow" "$splitA/.agent/memory.md" 2>/dev/null && fail "update: resume after an empty memory/ does not leave the body behind in memory.md" || pass "update: resume after an empty memory/ does not leave the body behind in memory.md"

# ---- 5e. memory split interrupted after legacy.md is written, before memory.md is rewritten ----
# Model the crash window between the two writes: legacy.md already holds
# the moved body, but memory.md is still the untouched pre-split original
# (the crash landed before write_memory_header ran). A memdir-existence
# gate would see memory/ present and skip, leaving the fact duplicated —
# once in legacy.md, once still as memory.md's own unconverted body.
splitB="$WORK/update-split-interrupted-b"
mkdir -p "$splitB/.agent/memory"
make_v6_fixture "$splitB"
printf 'This project uses a custom auth flow with rotating tokens. The staging\ndatabase resets nightly at 02:00 UTC. Deploy via the internal release\ntool, never raw kubectl.\n' \
  >"$splitB/.agent/memory/legacy.md"
: >"$splitB/.agent/memory/.split-in-progress"
cp -R "$splitB/.agent" "$splitB/.agent.backup-v6"
awk '/^  version: 6$/ { print; print "  migration_target: \"6.2\""; next } { print }' \
  "$splitB/.agent/purpose.md" >"$splitB/.agent/purpose.md.tmp"
mv "$splitB/.agent/purpose.md.tmp" "$splitB/.agent/purpose.md"
"$NODE" update "$splitB" >"$WORK/update-splitB.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "update: resume after legacy.md written but memory.md not yet rewritten exits 0" || fail "update: resume after legacy.md written but memory.md not yet rewritten exits 0 (rc=$rc)"
splitB_legacy_count=$(grep -c "custom auth flow" "$splitB/.agent/memory/legacy.md" 2>/dev/null)
[ "$splitB_legacy_count" -eq 1 ] && pass "update: resume does not duplicate the fact inside legacy.md" || fail "update: resume does not duplicate the fact inside legacy.md (count=$splitB_legacy_count)"
grep -q "custom auth flow" "$splitB/.agent/memory.md" 2>/dev/null && fail "update: resume converts memory.md into the index, not a second copy of the body" || pass "update: resume converts memory.md into the index, not a second copy of the body"
splitB_links=$(grep -cF "[Legacy memory](memory/legacy.md)" "$splitB/.agent/memory.md")
[ "$splitB_links" -eq 1 ] && pass "update: resume after legacy.md written adds exactly one index link" || fail "update: resume after legacy.md written adds exactly one index link (count=$splitB_links)"
[ ! -e "$splitB/.agent/memory/.split-in-progress" ] && pass "update: resume clears the split-in-progress marker on completion" || fail "update: resume clears the split-in-progress marker on completion"

# ---- 5f. memory split interrupted after memory.md is rewritten, before the index link is appended ----
# Model the crash window after write_memory_header ran: memory.md already
# reads as a fresh index (legacy.md exists with the moved fact), but the
# index line pointing at legacy.md was never appended — the fact would be
# orphaned (unreachable from memory.md, un-flagged by the GROOM check
# that keys off the index line) if a retry re-derived from memory.md's
# current content instead of finishing the append.
splitC="$WORK/update-split-interrupted-c"
mkdir -p "$splitC/.agent/memory"
make_v6_fixture "$splitC"
printf 'This project uses a custom auth flow with rotating tokens. The staging\ndatabase resets nightly at 02:00 UTC. Deploy via the internal release\ntool, never raw kubectl.\n' \
  >"$splitC/.agent/memory/legacy.md"
cat >"$splitC/.agent/memory.md" <<'MEMEOF'
# Memory
<!-- Index only, one line per fact file, newest last. Reorder by relevance only when grooming. Format: - [Title](memory/slug.md) — hook. No prose, no facts inline: a fact that lives only as a line here and not as its own file under memory/ is not recorded. Delete the line when its file is deleted. Preferred writer: .agent/scripts/memory.sh new (scaffolds the fact file and its index line together). This contract covers memory/ too, so fact files carry no header of their own. Each holds one durable fact under date, scope, and type frontmatter. Keep a fact only if work in this node changes when it is true: one carried in from another repo or a migration earns its place again or is dropped. Before writing, search purpose, rules, routed docs, source, and existing facts. If one already states it, update that source or its routing, write no fact, and say which source states it. A defect fixed in the harness or a tool creates no compensating fact. Two halves that would be superseded at different times are two files. Supersede in place with .agent/scripts/memory.sh supersede --slug <slug> --fact "…", which rewrites the fact, restamps the date, and keeps the filename. No dated narratives, no command output, no history. As small as the fact allows. Stable knowledge about how the system works goes to docs/ without a pointer fact; architecture.md already routes it. type: reference points outward at a URL, dashboard, ticket, or spec the node does not own: checked for reachability, not superseded like a fact. -->
MEMEOF
: >"$splitC/.agent/memory/.split-in-progress"
cp -R "$splitC/.agent" "$splitC/.agent.backup-v6"
awk '/^  version: 6$/ { print; print "  migration_target: \"6.2\""; next } { print }' \
  "$splitC/.agent/purpose.md" >"$splitC/.agent/purpose.md.tmp"
mv "$splitC/.agent/purpose.md.tmp" "$splitC/.agent/purpose.md"
"$NODE" update "$splitC" >"$WORK/update-splitC.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "update: resume after memory.md rewritten but link not yet appended exits 0" || fail "update: resume after memory.md rewritten but link not yet appended exits 0 (rc=$rc)"
splitC_legacy_count=$(grep -c "custom auth flow" "$splitC/.agent/memory/legacy.md" 2>/dev/null)
[ "$splitC_legacy_count" -eq 1 ] && pass "update: resume after a rewritten memory.md leaves legacy.md untouched" || fail "update: resume after a rewritten memory.md leaves legacy.md untouched (count=$splitC_legacy_count)"
splitC_links=$(grep -cF "[Legacy memory](memory/legacy.md)" "$splitC/.agent/memory.md")
[ "$splitC_links" -eq 1 ] && pass "update: resume finishes the orphaned legacy.md by appending its missing index link" || fail "update: resume finishes the orphaned legacy.md by appending its missing index link (count=$splitC_links)"
[ ! -e "$splitC/.agent/memory/.split-in-progress" ] && pass "update: resume clears the split-in-progress marker on completion" || fail "update: resume clears the split-in-progress marker on completion"

# ---- 5c. a backup collision WITHOUT a matching migration_target still aborts ----
unexplained="$WORK/update-unexplained-backup"
mkdir -p "$unexplained"
make_v6_fixture "$unexplained"
mkdir -p "$unexplained/.agent.backup-v6"
printf 'unrelated pre-existing directory\n' >"$unexplained/.agent.backup-v6/marker"
cp -R "$unexplained/.agent" "$WORK/unexplained-snapshot"
"$NODE" update "$unexplained" >"$WORK/update-unexplained.out" 2>"$WORK/update-unexplained.err"
rc=$?
[ "$rc" -ne 0 ] && pass "update: an unexplained backup collision (no matching migration_target) aborts" || fail "update: an unexplained backup collision (no matching migration_target) aborts"
grep -qF "backup path already exists" "$WORK/update-unexplained.err" && pass "update: unexplained backup collision prints the existing refusal message" || fail "update: unexplained backup collision prints the existing refusal message"
diff -r "$WORK/unexplained-snapshot" "$unexplained/.agent" >/dev/null 2>&1 && pass "update: unexplained backup collision leaves the node untouched" || fail "update: unexplained backup collision leaves the node untouched"
[ -f "$unexplained/.agent.backup-v6/marker" ] && pass "update: unexplained backup collision leaves the pre-existing backup untouched" || fail "update: unexplained backup collision leaves the pre-existing backup untouched"

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
grep -qF 'If one already states it, update that source or its routing, write no fact, and say which source states it.' "$stale62/.agent/memory.md" && pass "update: a version-current node refreshes a stale memory header" || fail "update: a version-current node refreshes a stale memory header"
grep -qxF -- '- [Keep](memory/keep.md) — keep this hook' "$stale62/.agent/memory.md" && grep -qF 'Keep this fact body.' "$stale62/.agent/memory/keep.md" && pass "update: refreshing the stale memory header keeps facts and index lines" || fail "update: refreshing the stale memory header keeps facts and index lines"
if [ -f "$stale62/.agent.backup-v6.2/marker" ] \
  && [ -f "$stale62/.agent.backup-v6.2-shape/memory.md" ] \
  && ! grep -qF 'If one already states it' "$stale62/.agent.backup-v6.2-shape/memory.md"; then
  pass "update: same-version shape backup does not collide with an earlier backup"
else
  fail "update: same-version shape backup does not collide with an earlier backup"
fi

# ---- 7b. finalize ----
finroot="$WORK/finalize-node"
mkdir -p "$finroot"
make_v6_fixture "$finroot"
"$NODE" update "$finroot" >/dev/null 2>&1
cp "$finroot/.agent/purpose.md" "$WORK/fin-purpose-pending.md"

# status.sh: the pending migration_target itself draws a REPAIR finding,
# naming the target and finalize, before anything else is touched.
flags_pending=$(status_flags "$finroot")
printf '%s\n' "$flags_pending" | grep -qF 'REPAIR: purpose.md has migration_target "6.2" pending' && pass "status.sh: a pending migration_target draws a REPAIR finding naming the target" || fail "status.sh: a pending migration_target draws a REPAIR finding naming the target ($flags_pending)"
printf '%s\n' "$flags_pending" | grep -q 'REPAIR: purpose.md has migration_target.*finalize' && pass "status.sh: the pending-migration REPAIR finding names the finalize command" || fail "status.sh: the pending-migration REPAIR finding names the finalize command ($flags_pending)"

# Deliberately break the node with a real defect status.sh already checks
# for — dropping memory.md's index line for memory/legacy.md while leaving
# the fact file itself in place. This is not a malformed fixture: it is the
# exact shape status.sh's own memory-index REPAIR check exists to catch, so
# a refused finalize below fails for the right reason.
grep -vF '[Legacy memory](memory/legacy.md)' "$finroot/.agent/memory.md" >"$finroot/.agent/memory.md.tmp"
mv "$finroot/.agent/memory.md.tmp" "$finroot/.agent/memory.md"
flags_broken=$(status_flags "$finroot")
printf '%s\n' "$flags_broken" | grep -qF 'REPAIR: memory/legacy.md has no index line in memory.md' && pass "finalize fixture: the deliberate break draws a real REPAIR finding" || fail "finalize fixture: the deliberate break draws a real REPAIR finding ($flags_broken)"

"$NODE" finalize "$finroot" >"$WORK/finalize1.out" 2>"$WORK/finalize1.err"
rc=$?
[ "$rc" -ne 0 ] && pass "finalize: refuses when status.sh reports REPAIR findings" || fail "finalize: refuses when status.sh reports REPAIR findings (rc=$rc)"
grep -qF 'REPAIR: memory/legacy.md has no index line in memory.md' "$WORK/finalize1.err" && pass "finalize: refusal prints the offending REPAIR finding" || fail "finalize: refusal prints the offending REPAIR finding"
diff -q "$WORK/fin-purpose-pending.md" "$finroot/.agent/purpose.md" >/dev/null 2>&1 && pass "finalize: a refused finalize leaves version and migration_target unchanged" || fail "finalize: a refused finalize leaves version and migration_target unchanged"

# Reconcile: restore the dropped index line. The only REPAIR finding left
# is the pending-migration one, which does not count against finalize
# itself (it is true by definition until finalize runs).
printf '\n%s\n' '- [Legacy memory](memory/legacy.md) — unsplit pre-6.1 memory, split per its GROOM flag' >>"$finroot/.agent/memory.md"
flags_reconciled=$(status_flags "$finroot" | grep '^REPAIR:' | grep -v '^REPAIR: purpose\.md has migration_target ')
[ -z "$flags_reconciled" ] && pass "finalize fixture: reconciling the break clears every REPAIR finding but the pending-migration one" || fail "finalize fixture: reconciling the break clears every REPAIR finding but the pending-migration one ($flags_reconciled)"

"$NODE" finalize "$finroot" >"$WORK/finalize2.out" 2>"$WORK/finalize2.err"
rc=$?
[ "$rc" -eq 0 ] && pass "finalize: succeeds once the node is reconciled (zero REPAIR findings)" || fail "finalize: succeeds once the node is reconciled (zero REPAIR findings) (rc=$rc, err=$(cat "$WORK/finalize2.err"))"
grep -q '^  version: "6.2"$' "$finroot/.agent/purpose.md" && pass "finalize: version is stamped to the pending target" || fail "finalize: version is stamped to the pending target"
grep -q '^  migration_target:' "$finroot/.agent/purpose.md" && fail "finalize: migration_target is removed" || pass "finalize: migration_target is removed"

"$NODE" finalize "$finroot" >"$WORK/finalize3.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "finalize: a second finalize on an already-finalized node exits 0" || fail "finalize: a second finalize on an already-finalized node exits 0 (rc=$rc)"
grep -qF "already finalized" "$WORK/finalize3.out" && pass "finalize: a second finalize reports the node already finalized" || fail "finalize: a second finalize reports the node already finalized"

flags_finalized=$(status_flags "$finroot")
printf '%s\n' "$flags_finalized" | grep -qF 'migration_target' && fail "status.sh: a finalized node emits no pending-migration REPAIR finding" || pass "status.sh: a finalized node emits no pending-migration REPAIR finding"

"$NODE" update "$finroot" >"$WORK/finupdate.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "finalize: update after a successful finalize exits 0" || fail "finalize: update after a successful finalize exits 0 (rc=$rc)"
grep -qF "node is current" "$WORK/finupdate.out" && pass "finalize: update after a successful finalize reports the node current" || fail "finalize: update after a successful finalize reports the node current"

# finalize on an unknown/un-adopted path fails the same shape as update
finunadopted="$WORK/finalize-unadopted"
mkdir -p "$finunadopted"
"$NODE" finalize "$finunadopted" >/dev/null 2>"$WORK/finalize-unadopted.err"
rc=$?
[ "$rc" -ne 0 ] && pass "finalize: an un-adopted path (no .agent) exits nonzero" || fail "finalize: an un-adopted path (no .agent) exits nonzero"
grep -qF "no .agent directory at" "$WORK/finalize-unadopted.err" && pass "finalize: an un-adopted path prints the same refusal shape as update" || fail "finalize: an un-adopted path prints the same refusal shape as update"

finnomanifest="$WORK/finalize-no-manifest"
mkdir -p "$finnomanifest/.agent"
touch "$finnomanifest/.agent/placeholder"
"$NODE" finalize "$finnomanifest" >/dev/null 2>"$WORK/finalize-nomanifest.err"
rc=$?
[ "$rc" -ne 0 ] && pass "finalize: an unknown (no-manifest) node exits nonzero" || fail "finalize: an unknown (no-manifest) node exits nonzero"
grep -qF "no dot-agent manifest found at" "$WORK/finalize-nomanifest.err" && pass "finalize: an unknown (no-manifest) node prints the same refusal shape as update" || fail "finalize: an unknown (no-manifest) node prints the same refusal shape as update"

# ---- 7c. finalize refuses when status inspection itself fails ----
# A broken status.sh must refuse finalize before its findings are even
# read — nonzero exit, stderr output, or empty stdout are each, on their
# own, a reason to refuse. The node's own status.sh is swapped out for a
# fake one that exercises each shape in turn; the manifest must stay
# byte-identical across every refusal.
finstatusfail="$WORK/finalize-status-fail"
mkdir -p "$finstatusfail"
make_v6_fixture "$finstatusfail"
"$NODE" update "$finstatusfail" >/dev/null 2>&1
cp "$finstatusfail/.agent/purpose.md" "$WORK/fin-statusfail-purpose.md"
realstatussh="$finstatusfail/.agent/scripts/status.sh"
cp "$realstatussh" "$WORK/fin-statusfail-status.sh.orig"

# Case 1: nonzero exit, with both stdout and stderr output.
cat >"$realstatussh" <<'EOF'
#!/usr/bin/env bash
echo "INDEX: fake finding"
echo "fake status.sh crash" >&2
exit 2
EOF
chmod +x "$realstatussh"
"$NODE" finalize "$finstatusfail" >"$WORK/finalize-statusfail1.out" 2>"$WORK/finalize-statusfail1.err"
rc=$?
[ "$rc" -ne 0 ] && pass "finalize: refuses when status.sh exits nonzero with stdout and stderr" || fail "finalize: refuses when status.sh exits nonzero with stdout and stderr (rc=$rc)"
diff -q "$WORK/fin-statusfail-purpose.md" "$finstatusfail/.agent/purpose.md" >/dev/null 2>&1 && pass "finalize: a nonzero-exit refusal leaves the manifest byte-identical" || fail "finalize: a nonzero-exit refusal leaves the manifest byte-identical"

# Case 2: zero exit, but stderr output present alongside otherwise-clean findings.
cat >"$realstatussh" <<'EOF'
#!/usr/bin/env bash
echo "INDEX: fake finding"
echo "fake status.sh warning" >&2
exit 0
EOF
chmod +x "$realstatussh"
"$NODE" finalize "$finstatusfail" >"$WORK/finalize-statusfail2.out" 2>"$WORK/finalize-statusfail2.err"
rc=$?
[ "$rc" -ne 0 ] && pass "finalize: refuses when status.sh exits zero but writes to stderr" || fail "finalize: refuses when status.sh exits zero but writes to stderr (rc=$rc)"
diff -q "$WORK/fin-statusfail-purpose.md" "$finstatusfail/.agent/purpose.md" >/dev/null 2>&1 && pass "finalize: a stderr-output refusal leaves the manifest byte-identical" || fail "finalize: a stderr-output refusal leaves the manifest byte-identical"

# Case 3: zero exit, empty stdout, no stderr.
cat >"$realstatussh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$realstatussh"
"$NODE" finalize "$finstatusfail" >"$WORK/finalize-statusfail3.out" 2>"$WORK/finalize-statusfail3.err"
rc=$?
[ "$rc" -ne 0 ] && pass "finalize: refuses when status.sh exits zero with empty stdout" || fail "finalize: refuses when status.sh exits zero with empty stdout (rc=$rc)"
diff -q "$WORK/fin-statusfail-purpose.md" "$finstatusfail/.agent/purpose.md" >/dev/null 2>&1 && pass "finalize: an empty-stdout refusal leaves the manifest byte-identical" || fail "finalize: an empty-stdout refusal leaves the manifest byte-identical"

# Restoring the real status.sh and finalizing again proves the new gate
# does not interfere with the ordinary clean path.
cp "$WORK/fin-statusfail-status.sh.orig" "$realstatussh"
chmod +x "$realstatussh"
"$NODE" finalize "$finstatusfail" >"$WORK/finalize-statusfail4.out" 2>"$WORK/finalize-statusfail4.err"
rc=$?
[ "$rc" -eq 0 ] && pass "finalize: succeeds once the real status.sh runs cleanly again" || fail "finalize: succeeds once the real status.sh runs cleanly again (rc=$rc, err=$(cat "$WORK/finalize-statusfail4.err"))"

# ---- 7d. migration manifest writes: abort before dependent mutations on
# write failure ----
# The three manifest helpers (write_migration_target, write_version,
# remove_migration_target) share one scratch path per rewrite:
# <dir>/.purpose.md.new, written then renamed. Pre-occupying that path with
# a directory blocks the write at the shell-redirection level — the same
# failure the 2026-09-14 review reproduced against .agent/.purpose.md.new —
# without needing a fake command for the first two cases.

# Case 1: a blocked pending-marker write must abort update before any
# content mutation, leaving the manifest and the rest of .agent untouched.
pmwfail="$WORK/update-pmw-fail"
mkdir -p "$pmwfail"
make_v6_fixture "$pmwfail"
mkdir -p "$pmwfail/.agent/.purpose.md.new"
cp -R "$pmwfail/.agent" "$WORK/pmw-snapshot"
"$NODE" update "$pmwfail" >"$WORK/pmw.out" 2>"$WORK/pmw.err"
rc=$?
[ "$rc" -ne 0 ] && pass "update: a blocked pending-marker write aborts" || fail "update: a blocked pending-marker write aborts (rc=$rc)"
grep -qF "failed to record migration_target" "$WORK/pmw.err" && pass "update: a blocked pending-marker write prints an actionable error" || fail "update: a blocked pending-marker write prints an actionable error"
grep -qiF "migrated" "$WORK/pmw.out" && fail "update: a blocked pending-marker write prints no success message" || pass "update: a blocked pending-marker write prints no success message"
diff -r "$WORK/pmw-snapshot" "$pmwfail/.agent" >/dev/null 2>&1 && pass "update: a blocked pending-marker write leaves node content and the manifest unchanged" || fail "update: a blocked pending-marker write leaves node content and the manifest unchanged"

# Case 2: a blocked version write must abort finalize before the pending
# marker is touched, preserving both the marker and the original version.
vwfail="$WORK/finalize-vw-fail"
mkdir -p "$vwfail"
make_v6_fixture "$vwfail"
"$NODE" update "$vwfail" >/dev/null 2>&1
cp "$vwfail/.agent/purpose.md" "$WORK/vwf-purpose-pending.md"
mkdir -p "$vwfail/.agent/.purpose.md.new"
"$NODE" finalize "$vwfail" >"$WORK/vwf.out" 2>"$WORK/vwf.err"
rc=$?
[ "$rc" -ne 0 ] && pass "finalize: a blocked version write aborts" || fail "finalize: a blocked version write aborts (rc=$rc)"
grep -qF "failed to write version" "$WORK/vwf.err" && grep -qF "aborting before removing the pending marker" "$WORK/vwf.err" \
  && pass "finalize: a blocked version write prints an actionable error naming the abort-before-removal ordering" \
  || fail "finalize: a blocked version write prints an actionable error naming the abort-before-removal ordering"
grep -qiF "finalized" "$WORK/vwf.out" && fail "finalize: a blocked version write prints no success message" || pass "finalize: a blocked version write prints no success message"
diff -q "$WORK/vwf-purpose-pending.md" "$vwfail/.agent/purpose.md" >/dev/null 2>&1 && pass "finalize: a blocked version write preserves the pending marker and original version" || fail "finalize: a blocked version write preserves the pending marker and original version"

# Case 3: a failed marker removal — version already stamped, migration_target
# still present — must return nonzero and leave the node reading as pending,
# never as silently finished. Directory-blocking the shared scratch path
# would also block write_version (case 2's failure), so isolating the
# removal alone needs a fake mv that fails only on the *second* rewrite of
# purpose.md within this invocation (write_version's rename is the first,
# remove_migration_target's is the second). Disposable fixture only — never
# used against a real or adopted node.
rmfail="$WORK/finalize-rm-fail"
mkdir -p "$rmfail"
make_v6_fixture "$rmfail"
"$NODE" update "$rmfail" >/dev/null 2>&1
fakebin="$WORK/fakebin-mv-fail"
mkdir -p "$fakebin"
cat >"$fakebin/mv" <<'EOF'
#!/usr/bin/env bash
if [ "$#" -eq 2 ] && [[ "$2" == *purpose.md ]]; then
  n=$(cat "$FAKE_MV_COUNTER" 2>/dev/null || echo 0)
  n=$((n + 1))
  printf '%s' "$n" >"$FAKE_MV_COUNTER"
  if [ "$n" -eq 2 ]; then
    echo "fake mv: injected marker-removal failure" >&2
    exit 1
  fi
fi
exec /bin/mv "$@"
EOF
chmod +x "$fakebin/mv"
rm -f "$WORK/rmfail-mv-counter"
FAKE_MV_COUNTER="$WORK/rmfail-mv-counter" PATH="$fakebin:$PATH" "$NODE" finalize "$rmfail" >"$WORK/rmf.out" 2>"$WORK/rmf.err"
rc=$?
[ "$rc" -ne 0 ] && pass "finalize: a failed marker removal returns nonzero" || fail "finalize: a failed marker removal returns nonzero (rc=$rc)"
grep -qF "failed to remove the pending migration_target marker" "$WORK/rmf.err" && pass "finalize: a failed marker removal prints an actionable error" || fail "finalize: a failed marker removal prints an actionable error"
grep -qiF "finalized" "$WORK/rmf.out" && fail "finalize: a failed marker removal prints no success message" || pass "finalize: a failed marker removal prints no success message"
grep -q '^  version: "6.2"$' "$rmfail/.agent/purpose.md" && pass "finalize: a failed marker removal still leaves version stamped (removal runs after the stamp)" || fail "finalize: a failed marker removal still leaves version stamped"
grep -q '^  migration_target:' "$rmfail/.agent/purpose.md" && pass "finalize: a failed marker removal retains a detectable pending migration" || fail "finalize: a failed marker removal retains a detectable pending migration"

# Retrying with the real mv (no injected failure) must complete cleanly —
# the failure above is recoverable, not a wedge.
"$NODE" finalize "$rmfail" >"$WORK/rmf-retry.out" 2>"$WORK/rmf-retry.err"
rc=$?
[ "$rc" -eq 0 ] && pass "finalize: retrying after a failed marker removal succeeds" || fail "finalize: retrying after a failed marker removal succeeds (rc=$rc, err=$(cat "$WORK/rmf-retry.err"))"
grep -q '^  migration_target:' "$rmfail/.agent/purpose.md" && fail "finalize: the retry actually removes the marker" || pass "finalize: the retry actually removes the marker"

# Case 4: a transform that exits 0 but writes corrupted output (wrong line
# count, value missing) is a different failure mode than the OS-level mv
# failures above — the transform itself never errors, so only the helper's
# own line-count-delta and content-grep checks can catch it. A fake awk
# that intercepts only the migration_target insert (matched by the literal
# "migration_target:" text in its script argument) and otherwise defers to
# the real awk exercises exactly that path without disturbing the other awk
# calls update makes (memory split, etc).
wmtcfail="$WORK/update-wmt-corrupt"
mkdir -p "$wmtcfail"
make_v6_fixture "$wmtcfail"
cp -R "$wmtcfail/.agent" "$WORK/wmtc-snapshot"
fakebin_awk="$WORK/fakebin-awk-corrupt"
mkdir -p "$fakebin_awk"
cat >"$fakebin_awk/awk" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    *'migration_target:'*)
      echo "corrupted"
      exit 0
      ;;
  esac
done
exec /usr/bin/awk "$@"
EOF
chmod +x "$fakebin_awk/awk"
PATH="$fakebin_awk:$PATH" "$NODE" update "$wmtcfail" >"$WORK/wmtc.out" 2>"$WORK/wmtc.err"
rc=$?
[ "$rc" -ne 0 ] && pass "update: a corrupted migration_target write (transform exits 0, output truncated) aborts" || fail "update: a corrupted migration_target write (transform exits 0, output truncated) aborts (rc=$rc)"
grep -qF "failed to record migration_target" "$WORK/wmtc.err" && pass "update: a corrupted migration_target write prints the same actionable error as an OS-level failure" || fail "update: a corrupted migration_target write prints the same actionable error as an OS-level failure"
diff -r "$WORK/wmtc-snapshot" "$wmtcfail/.agent" >/dev/null 2>&1 && pass "update: a corrupted migration_target write leaves node content and the manifest unchanged" || fail "update: a corrupted migration_target write leaves node content and the manifest unchanged"

# Case 5: same discriminating coverage for write_version. The fake sed
# intercepts only the version-stamp rewrite (matched by the literal
# "(  version:)" text unique to that sed program, as opposed to the
# version-extraction sed calls elsewhere which use a different pattern) and
# otherwise defers to the real sed.
wvcfail="$WORK/finalize-wv-corrupt"
mkdir -p "$wvcfail"
make_v6_fixture "$wvcfail"
"$NODE" update "$wvcfail" >/dev/null 2>&1
cp "$wvcfail/.agent/purpose.md" "$WORK/wvc-purpose-pending.md"
fakebin_sed="$WORK/fakebin-sed-corrupt"
mkdir -p "$fakebin_sed"
cat >"$fakebin_sed/sed" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    *'(  version:)'*)
      echo "corrupted"
      exit 0
      ;;
  esac
done
exec /usr/bin/sed "$@"
EOF
chmod +x "$fakebin_sed/sed"
PATH="$fakebin_sed:$PATH" "$NODE" finalize "$wvcfail" >"$WORK/wvc.out" 2>"$WORK/wvc.err"
rc=$?
[ "$rc" -ne 0 ] && pass "finalize: a corrupted version write (transform exits 0, output truncated) aborts" || fail "finalize: a corrupted version write (transform exits 0, output truncated) aborts (rc=$rc)"
grep -qF "failed to write version" "$WORK/wvc.err" && pass "finalize: a corrupted version write prints the same actionable error as an OS-level failure" || fail "finalize: a corrupted version write prints the same actionable error as an OS-level failure"
diff -q "$WORK/wvc-purpose-pending.md" "$wvcfail/.agent/purpose.md" >/dev/null 2>&1 && pass "finalize: a corrupted version write preserves the pending marker and original version" || fail "finalize: a corrupted version write preserves the pending marker and original version"

# Case 6: same discriminating coverage for remove_migration_target. The fake
# grep intercepts only the marker-removal call (matched by the combination
# of -v and the migration_target pattern, as opposed to the -q/-n lookups
# elsewhere that use the same pattern without -v) and otherwise defers to
# the real grep.
rmcfail="$WORK/finalize-rm-corrupt"
mkdir -p "$rmcfail"
make_v6_fixture "$rmcfail"
"$NODE" update "$rmcfail" >/dev/null 2>&1
fakebin_grep="$WORK/fakebin-grep-corrupt"
mkdir -p "$fakebin_grep"
cat >"$fakebin_grep/grep" <<'EOF'
#!/usr/bin/env bash
has_v=0
has_pat=0
for a in "$@"; do
  case "$a" in
    -v) has_v=1 ;;
    '^  migration_target:') has_pat=1 ;;
  esac
done
if [ "$has_v" -eq 1 ] && [ "$has_pat" -eq 1 ]; then
  echo "corrupted"
  exit 0
fi
exec /usr/bin/grep "$@"
EOF
chmod +x "$fakebin_grep/grep"
PATH="$fakebin_grep:$PATH" "$NODE" finalize "$rmcfail" >"$WORK/rmc.out" 2>"$WORK/rmc.err"
rc=$?
[ "$rc" -ne 0 ] && pass "finalize: a corrupted marker-removal write (transform exits 0, line not actually removed) returns nonzero" || fail "finalize: a corrupted marker-removal write (transform exits 0, line not actually removed) returns nonzero (rc=$rc)"
grep -qF "failed to remove the pending migration_target marker" "$WORK/rmc.err" && pass "finalize: a corrupted marker-removal write prints the same actionable error as an OS-level failure" || fail "finalize: a corrupted marker-removal write prints the same actionable error as an OS-level failure"
grep -q '^  version: "6.2"$' "$rmcfail/.agent/purpose.md" && pass "finalize: a corrupted marker-removal write still leaves version stamped" || fail "finalize: a corrupted marker-removal write still leaves version stamped"
grep -q '^  migration_target:' "$rmcfail/.agent/purpose.md" && pass "finalize: a corrupted marker-removal write retains a detectable pending migration" || fail "finalize: a corrupted marker-removal write retains a detectable pending migration"

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

# ---- 8b. log.sh: file names and SHAs are refused, with the token named ----
before8c=$(cat "$sessionlog")
out8c=$("$logcopy" --tool claude --area testing --verify pass --summary "Added backoff to submitPayment in src/client.ts" "$logroot" 2>&1)
rc=$?
after8c=$(cat "$sessionlog")
[ "$rc" -ne 0 ] && printf '%s' "$out8c" | grep -qF 'src/client.ts' && pass "log.sh: a summary naming a file is rejected and the token named" || fail "log.sh: a summary naming a file is rejected and the token named"
[ "$before8c" = "$after8c" ] && pass "log.sh: a file-naming summary writes nothing" || fail "log.sh: a file-naming summary writes nothing"
out8d=$("$logcopy" --tool claude --area testing --verify pass --summary "Backoff landed in commit 47feccc" "$logroot" 2>&1)
rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out8d" | grep -qF '47feccc' && pass "log.sh: a summary naming a SHA is rejected and the token named" || fail "log.sh: a summary naming a SHA is rejected and the token named"
"$logcopy" --tool claude --area testing --verify pass --summary "Added exponential backoff, three attempts, ticket PAY-318, version 6.2" "$logroot" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "log.sh: a ticket id and a version number are not read as a file or a SHA" || fail "log.sh: a ticket id and a version number are not read as a file or a SHA"

# ---- 8c. status.sh --load prints the always-loaded set, in the entry point's order ----
load8=$("$logroot/.agent/scripts/status.sh" --load "$logroot" 2>&1)
order8=$(printf '%s\n' "$load8" | grep -n '^==== ' | cut -d: -f2 | tr '\n' ' ')
[ "$order8" = "==== .agent/rules/learned.md ==== ==== .agent/rules/contract.md ==== ==== .agent/purpose.md ==== ==== .agent/memory.md ==== " ] \
  && pass "status.sh --load: the four files print under markers, learned, contract, purpose, memory" \
  || fail "status.sh --load: the four files print under markers, learned, contract, purpose, memory ($order8)"
printf '%s\n' "$load8" | grep -q '^## Kernel' && pass "status.sh --load: the contract body is in the output" || fail "status.sh --load: the contract body is in the output"
plain8=$("$logroot/.agent/scripts/status.sh" "$logroot" 2>&1)
! printf '%s\n' "$plain8" | grep -q '^==== ' && pass "status.sh: without --load no file is printed" || fail "status.sh: without --load no file is printed"

# ---- 8d. the memory GROOM: line names the tokens a groom must keep ----
groomroot="$WORK/groom-tokens"
mkdir -p "$groomroot"
"$NODE" init --preset software-development --mode track-all "$groomroot" >/dev/null 2>&1
finish_bootstrap "$groomroot"
"$groomroot/.agent/scripts/memory.sh" new --slug vendor --title Vendor --hook "vendor calls" --fact "Vendor limit measured on 2026-07-02 for PAY-318 against sandbox.vendor.example:8443; repro with npm run test:integration -- --grep vendor and VENDOR_SANDBOX_KEY set." "$groomroot" >/dev/null 2>&1
printf '\n%s\n' "$(words_n 320)" >>"$groomroot/.agent/memory/vendor.md"
groom8=$("$groomroot/.agent/scripts/status.sh" "$groomroot" 2>&1 | grep '^GROOM: memory/vendor.md')
for tok in PAY-318 sandbox.vendor.example:8443 "npm run test:integration -- --grep vendor" VENDOR_SANDBOX_KEY 2026-07-02; do
  printf '%s' "$groom8" | grep -qF -- "$tok" || groom8_missing="$groom8_missing $tok"
done
[ -n "$groom8" ] && [ -z "${groom8_missing:-}" ] && pass "status.sh: the memory GROOM: line lists ticket, host, command, env var, and date" || fail "status.sh: the memory GROOM: line lists ticket, host, command, env var, and date (missing:${groom8_missing:-} line:${groom8:-none})"

# ---- 8e. docs.sh rehook rewrites the hook in both places, or neither ----
rehookroot="$WORK/rehook"
mkdir -p "$rehookroot"
"$NODE" init --preset software-development --mode track-all "$rehookroot" >/dev/null 2>&1
finish_bootstrap "$rehookroot"
"$rehookroot/.agent/scripts/docs.sh" new --name deploy --read-when "shipping a release" "$rehookroot" >/dev/null 2>&1
"$rehookroot/.agent/scripts/docs.sh" rehook --name deploy --read-when "shipping a release, deploying to production" "$rehookroot" >/dev/null 2>&1
rc=$?
head -n 1 "$rehookroot/.agent/docs/deploy.md" | grep -qF -- '<!-- Read when: shipping a release, deploying to production -->' \
  && grep -qF -- '- **Read when:** shipping a release, deploying to production' "$rehookroot/.agent/docs/architecture.md" \
  && [ "$rc" -eq 0 ] && pass "docs.sh rehook: the doc header and the routing row carry the new hook" || fail "docs.sh rehook: the doc header and the routing row carry the new hook (rc=$rc)"
! "$rehookroot/.agent/scripts/status.sh" "$rehookroot" 2>&1 | grep -q '^INDEX:' && pass "docs.sh rehook: status.sh sees no INDEX: drift afterwards" || fail "docs.sh rehook: status.sh sees no INDEX: drift afterwards"
"$rehookroot/.agent/scripts/docs.sh" rehook --name missing --read-when "anything" "$rehookroot" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "docs.sh rehook: a doc that does not exist is refused" || fail "docs.sh rehook: a doc that does not exist is refused"

# ---- 8f. checkpoint.sh: gate, status check, then the entry, written once on the clean run ----
finroot="$WORK/finish"
mkdir -p "$finroot/src"
"$NODE" init --preset software-development --mode track-all "$finroot" >/dev/null 2>&1
finish_bootstrap "$finroot"
printf 'export const a = 1\n' >"$finroot/src/a.ts"
git -C "$finroot" init -q && git -C "$finroot" add -A && git -C "$finroot" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m base
# A turn that changed nothing is not a turn that finished: the log records
# work, and there is none to record. Without this the hand-back fires on
# every message while the artifact it writes is one entry per turn that
# changed files.
out8e=$("$finroot/.agent/scripts/checkpoint.sh" --tool claude --area testing --verify n/a --summary "answered a question, no change" "$finroot" 2>&1)
rc=$?
n8f=$(grep -c '^- \[' "$finroot/.agent/session-log.md")
[ "$rc" -ne 0 ] && printf '%s' "$out8e" | grep -q 'nothing changed' && [ "$n8f" -eq 0 ] && pass "checkpoint.sh: an unchanged tree writes no entry" || fail "checkpoint.sh: an unchanged tree writes no entry (rc=$rc entries=$n8f)"
printf '// const old = fetch(url)\nexport const b = 2\n' >>"$finroot/src/a.ts"
out8f=$("$finroot/.agent/scripts/checkpoint.sh" --tool claude --area testing --verify pass --summary "added b" "$finroot" 2>&1)
rc=$?
n8f2=$(grep -c '^- \[' "$finroot/.agent/session-log.md")
[ "$rc" -ne 0 ] && printf '%s' "$out8f" | grep -q 'BLOCK' && [ "$n8f2" -eq 0 ] && pass "checkpoint.sh: a BLOCK finding stops it before the log entry" || fail "checkpoint.sh: a BLOCK finding stops it before the log entry (rc=$rc entries=$n8f2)"
printf '// Vendor caps retries at three by contract; a fourth attempt is rejected upstream.\nexport const b = 2\n' >"$finroot/src/a.ts"
"$finroot/.agent/scripts/checkpoint.sh" --tool claude --area testing --verify pass --summary "added b" "$finroot" >/dev/null 2>&1
rc=$?
n8f3=$(grep -c '^- \[' "$finroot/.agent/session-log.md")
[ "$rc" -eq 0 ] && [ "$n8f3" -eq 1 ] && pass "checkpoint.sh: on the clean run the entry is written once" || fail "checkpoint.sh: on the clean run the entry is written once (rc=$rc entries=$n8f3)"
# Committed work leaves a clean tree and still has to log: --base names the
# parent, and the refusal above must not swallow it.
git -C "$finroot" add -A && git -C "$finroot" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m work
"$finroot/.agent/scripts/checkpoint.sh" --tool claude --area testing --verify pass --summary "committed b" --base HEAD~1 "$finroot" >/dev/null 2>&1
rc=$?
n8f3b=$(grep -c '^- \[' "$finroot/.agent/session-log.md")
[ "$rc" -eq 0 ] && [ "$n8f3b" -eq 2 ] && pass "checkpoint.sh: committed work still logs, against --base" || fail "checkpoint.sh: committed work still logs, against --base (rc=$rc entries=$n8f3b)"
i8f=1; while [ "$i8f" -le 3 ]; do printf -- '- [2026-08-0%s] (tool) %s verify: pass.\n' "$i8f" "$(words_n 70)" >>"$finroot/.agent/session-log.md"; i8f=$((i8f + 1)); done
out8g=$("$finroot/.agent/scripts/checkpoint.sh" --tool claude --area testing --verify pass --summary "added c" "$finroot" 2>&1)
rc=$?
n8f4=$(grep -c '^- \[' "$finroot/.agent/session-log.md")
[ "$rc" -ne 0 ] && printf '%s' "$out8g" | grep -q '^GROOM:' && [ "$n8f4" -eq 5 ] && pass "checkpoint.sh: a standing flag stops it before the log entry" || fail "checkpoint.sh: a standing flag stops it before the log entry (rc=$rc entries=$n8f4)"
# A project that is not a git checkout gives no signal either way, so it
# keeps the old behavior rather than being refused on a guess.
finroot_nogit="$WORK/finish-nogit"
mkdir -p "$finroot_nogit"
"$NODE" init --preset software-development --mode ignore-all "$finroot_nogit" >/dev/null 2>&1
finish_bootstrap "$finroot_nogit"
"$finroot_nogit/.agent/scripts/checkpoint.sh" --tool claude --area testing --verify n/a --summary "no repo here" "$finroot_nogit" >/dev/null 2>&1
rc=$?
n8h=$(grep -c '^- \[' "$finroot_nogit/.agent/session-log.md")
[ "$rc" -eq 0 ] && [ "$n8h" -eq 1 ] && pass "checkpoint.sh: a non-git project still writes its entry" || fail "checkpoint.sh: a non-git project still writes its entry (rc=$rc entries=$n8h)"

# ---- 8i. checkpoint.sh: a status check that did not run cleanly blocks completion ----
# finroot above ends this section with a standing GROOM: flag (line 423), so
# it cannot be reused here — case (c)'s re-verification needs a fixture that
# is genuinely clean once status.sh is restored. A fresh root, same pattern.
fsroot="$WORK/finish-statuscheck"
mkdir -p "$fsroot/src"
"$NODE" init --preset software-development --mode track-all "$fsroot" >/dev/null 2>&1
finish_bootstrap "$fsroot"
printf 'export const a = 1\n' >"$fsroot/src/a.ts"
git -C "$fsroot" init -q && git -C "$fsroot" add -A && git -C "$fsroot" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m base
printf '// Vendor caps retries at three by contract; a fourth attempt is rejected upstream.\nexport const b = 2\n' >"$fsroot/src/a.ts"
cp "$fsroot/.agent/scripts/status.sh" "$WORK/fs-status-clean.sh"
n8i0=$(grep -c '^- \[' "$fsroot/.agent/session-log.md")

printf '#!/usr/bin/env bash\nif [ 1 -eq 1 ]\n  echo "missing then"\n' >"$fsroot/.agent/scripts/status.sh"
out8i=$("$fsroot/.agent/scripts/checkpoint.sh" --tool claude --area testing --verify pass --summary "syntax break" "$fsroot" 2>&1)
rc=$?
n8i=$(grep -c '^- \[' "$fsroot/.agent/session-log.md")
[ "$rc" -ne 0 ] && [ "$n8i" -eq "$n8i0" ] && printf '%s' "$out8i" | grep -q 'checkpoint.sh: status check failed to run cleanly' && pass "checkpoint.sh: invalid status.sh syntax blocks completion" || fail "checkpoint.sh: invalid status.sh syntax blocks completion (rc=$rc entries=$n8i)"

printf '#!/usr/bin/env bash\nexit 3\n' >"$fsroot/.agent/scripts/status.sh"
out8j=$("$fsroot/.agent/scripts/checkpoint.sh" --tool claude --area testing --verify pass --summary "quiet exit 3" "$fsroot" 2>&1)
rc=$?
n8j=$(grep -c '^- \[' "$fsroot/.agent/session-log.md")
[ "$rc" -ne 0 ] && [ "$n8j" -eq "$n8i0" ] && printf '%s' "$out8j" | grep -q 'checkpoint.sh: status check failed to run cleanly' && pass "checkpoint.sh: a status.sh that quietly exits nonzero blocks completion" || fail "checkpoint.sh: a status.sh that quietly exits nonzero blocks completion (rc=$rc entries=$n8j)"

printf '#!/usr/bin/env bash\necho "unexpected noise" >&2\nexit 0\n' >"$fsroot/.agent/scripts/status.sh"
out8k=$("$fsroot/.agent/scripts/checkpoint.sh" --tool claude --area testing --verify pass --summary "unexpected stderr" "$fsroot" 2>&1)
rc=$?
n8k=$(grep -c '^- \[' "$fsroot/.agent/session-log.md")
[ "$rc" -ne 0 ] && [ "$n8k" -eq "$n8i0" ] && printf '%s' "$out8k" | grep -q 'checkpoint.sh: status check failed to run cleanly' && pass "checkpoint.sh: unexpected status.sh stderr blocks completion" || fail "checkpoint.sh: unexpected status.sh stderr blocks completion (rc=$rc entries=$n8k)"

cp "$WORK/fs-status-clean.sh" "$fsroot/.agent/scripts/status.sh"
"$fsroot/.agent/scripts/checkpoint.sh" --tool claude --area testing --verify pass --summary "the inspection script is clean again" "$fsroot" >/dev/null 2>&1
rc=$?
n8l=$(grep -c '^- \[' "$fsroot/.agent/session-log.md")
[ "$rc" -eq 0 ] && [ "$n8l" -eq "$((n8i0 + 1))" ] && pass "checkpoint.sh: a clean status check still allows completion" || fail "checkpoint.sh: a clean status check still allows completion (rc=$rc entries=$n8l)"

# ---- 8m. checkpoint.sh: one entry per turn that changed files, across real commits ----
seqA="$WORK/seq-edit-commit-edit-commit-noedit"
mkdir -p "$seqA/src"
"$NODE" init --preset software-development --mode track-all "$seqA" >/dev/null 2>&1
finish_bootstrap "$seqA"
printf 'export const a = 1\n' >"$seqA/src/a.ts"
git -C "$seqA" init -q && git -C "$seqA" add -A && git -C "$seqA" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m base

printf 'export const b = 2\n' >>"$seqA/src/a.ts"
"$seqA/.agent/scripts/checkpoint.sh" --tool claude --area testing --verify pass --summary "turn one edit" "$seqA" >/dev/null 2>&1
rc_a1=$?
git -C "$seqA" add -A && git -C "$seqA" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m turn-one

printf 'export const c = 3\n' >>"$seqA/src/a.ts"
"$seqA/.agent/scripts/checkpoint.sh" --tool claude --area testing --verify pass --summary "turn two edit" "$seqA" >/dev/null 2>&1
rc_a2=$?
git -C "$seqA" add -A && git -C "$seqA" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m turn-two
n_a2=$(grep -c '^- \[' "$seqA/.agent/session-log.md")

out_a3=$("$seqA/.agent/scripts/checkpoint.sh" --tool claude --area testing --verify n/a --summary "turn three no edit" "$seqA" 2>&1)
rc_a3=$?
n_a3=$(grep -c '^- \[' "$seqA/.agent/session-log.md")

[ "$rc_a1" -eq 0 ] && [ "$rc_a2" -eq 0 ] && [ "$n_a2" -eq 2 ] \
  && pass "sequence: edit-commit-edit-commit writes exactly two entries" \
  || fail "sequence: edit-commit-edit-commit writes exactly two entries (rc1=$rc_a1 rc2=$rc_a2 entries=$n_a2)"
[ "$rc_a3" -ne 0 ] && [ "$n_a3" -eq 2 ] && printf '%s' "$out_a3" | grep -q 'nothing changed' \
  && pass "sequence: the trailing no-edit turn exits nonzero and writes nothing" \
  || fail "sequence: the trailing no-edit turn exits nonzero and writes nothing (rc=$rc_a3 entries=$n_a3)"

seqB="$WORK/seq-noedit-then-edit"
mkdir -p "$seqB/src"
"$NODE" init --preset software-development --mode track-all "$seqB" >/dev/null 2>&1
finish_bootstrap "$seqB"
printf 'export const a = 1\n' >"$seqB/src/a.ts"
git -C "$seqB" init -q && git -C "$seqB" add -A && git -C "$seqB" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m base

out_b1=$("$seqB/.agent/scripts/checkpoint.sh" --tool claude --area testing --verify n/a --summary "answered only, no edits" "$seqB" 2>&1)
rc_b1=$?
n_b1=$(grep -c '^- \[' "$seqB/.agent/session-log.md")
[ "$rc_b1" -ne 0 ] && [ "$n_b1" -eq 0 ] && printf '%s' "$out_b1" | grep -q 'nothing changed' \
  && pass "sequence: no-edit before any edit exits nonzero and writes nothing" \
  || fail "sequence: no-edit before any edit exits nonzero and writes nothing (rc=$rc_b1 entries=$n_b1)"

printf 'export const b = 2\n' >>"$seqB/src/a.ts"
"$seqB/.agent/scripts/checkpoint.sh" --tool claude --area testing --verify pass --summary "second turn edits" "$seqB" >/dev/null 2>&1
rc_b2=$?
n_b2=$(grep -c '^- \[' "$seqB/.agent/session-log.md")
[ "$rc_b2" -eq 0 ] && [ "$n_b2" -eq 1 ] \
  && pass "sequence: no-edit then edit writes exactly one entry total" \
  || fail "sequence: no-edit then edit writes exactly one entry total (rc=$rc_b2 entries=$n_b2)"

seqC="$WORK/seq-noedit-only"
mkdir -p "$seqC/src"
"$NODE" init --preset software-development --mode track-all "$seqC" >/dev/null 2>&1
finish_bootstrap "$seqC"
printf 'export const a = 1\n' >"$seqC/src/a.ts"
git -C "$seqC" init -q && git -C "$seqC" add -A && git -C "$seqC" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m base
"$seqC/.agent/scripts/checkpoint.sh" --tool claude --area testing --verify n/a --summary "only answered, nothing to record" "$seqC" >/dev/null 2>&1
rc_c1=$?
n_c1=$(grep -c '^- \[' "$seqC/.agent/session-log.md")
[ "$rc_c1" -ne 0 ] && [ "$n_c1" -eq 0 ] \
  && pass "sequence: a no-edit-only turn over a committed baseline writes zero entries" \
  || fail "sequence: a no-edit-only turn over a committed baseline writes zero entries (rc=$rc_c1 entries=$n_c1)"

# ---- 8n. node.sh update: session-log.md header migration, below-target version ----
migBelow="$WORK/migrate-session-log-below-target"
mkdir -p "$migBelow"
make_v6_fixture "$migBelow"
subst "$migBelow/.agent/session-log.md" 's/One entry per turn that changed files, newest last\./One entry per session, newest last./'
before_mb=$(grep '^- \[' "$migBelow/.agent/session-log.md")
"$NODE" update "$migBelow" >/dev/null 2>&1
after_mb=$(grep '^- \[' "$migBelow/.agent/session-log.md")
grep -qF 'One entry per turn that changed files, newest last.' "$migBelow/.agent/session-log.md" \
  && pass "migrate (below-target): session-log.md header is replaced" \
  || fail "migrate (below-target): session-log.md header is replaced"
[ "$before_mb" = "$after_mb" ] \
  && pass "migrate (below-target): every existing log entry is preserved byte-identical, in order" \
  || fail "migrate (below-target): every existing log entry is preserved byte-identical, in order"
out_mb2=$("$NODE" update "$migBelow" 2>&1)
after_mb2=$(grep '^- \[' "$migBelow/.agent/session-log.md")
[ "$after_mb" = "$after_mb2" ] && printf '%s' "$out_mb2" | grep -qF 'session log header already current' \
  && pass "migrate (below-target): a second run reports the header already current, no further rewrite" \
  || fail "migrate (below-target): a second run reports the header already current, no further rewrite ($out_mb2)"

# ---- 8o. node.sh update: session-log.md header migration, already at target version ----
migSame="$WORK/migrate-session-log-same-version"
mkdir -p "$migSame"
"$NODE" init --preset software-development --mode track-shared "$migSame" >/dev/null 2>&1
printf -- '- [2026-02-02] (claude) pre-migration entry (testing). verify: pass.\n' >>"$migSame/.agent/session-log.md"
subst "$migSame/.agent/session-log.md" 's/One entry per turn that changed files, newest last\./One entry per session, newest last./'
before_ms=$(grep '^- \[' "$migSame/.agent/session-log.md")
"$NODE" update "$migSame" >/dev/null 2>&1
rc_ms1=$?
after_ms=$(grep '^- \[' "$migSame/.agent/session-log.md")
[ "$rc_ms1" -eq 0 ] && grep -qF 'One entry per turn that changed files, newest last.' "$migSame/.agent/session-log.md" \
  && pass "migrate (same-version): a 6.2 node with the old header is refreshed by the shape-refresh branch" \
  || fail "migrate (same-version): a 6.2 node with the old header is refreshed by the shape-refresh branch"
[ "$before_ms" = "$after_ms" ] \
  && pass "migrate (same-version): every existing log entry is preserved byte-identical, in order" \
  || fail "migrate (same-version): every existing log entry is preserved byte-identical, in order"
[ -f "$migSame/.agent.backup-v6.2-shape/session-log.md" ] && grep -qF 'One entry per session, newest last.' "$migSame/.agent.backup-v6.2-shape/session-log.md" \
  && pass "migrate (same-version): the pre-refresh header is preserved behind the existing shape backup" \
  || fail "migrate (same-version): the pre-refresh header is preserved behind the existing shape backup"
out_ms2=$("$NODE" update "$migSame" 2>&1)
rc_ms2=$?
after_ms2=$(grep '^- \[' "$migSame/.agent/session-log.md")
[ "$rc_ms2" -eq 0 ] && [ "$after_ms" = "$after_ms2" ] && printf '%s' "$out_ms2" | grep -qF 'current' \
  && pass "migrate (same-version): a second run leaves the node current with no further rewrite" \
  || fail "migrate (same-version): a second run leaves the node current with no further rewrite ($out_ms2)"

migNew="$WORK/migrate-session-log-already-new"
mkdir -p "$migNew"
"$NODE" init --preset software-development --mode ignore-all "$migNew" >/dev/null 2>&1
before_mn=$(cat "$migNew/.agent/session-log.md")
out_mn=$("$NODE" update "$migNew" 2>&1)
after_mn=$(cat "$migNew/.agent/session-log.md")
[ "$before_mn" = "$after_mn" ] && printf '%s' "$out_mn" | grep -qF 'current' \
  && pass "migrate: update on a node already carrying the new header rewrites nothing and reports current" \
  || fail "migrate: update on a node already carrying the new header rewrites nothing and reports current"

# ---- 8p. node.sh update: a session-log.md with no header comment is left alone ----
noHeaderRoot="$WORK/session-log-no-header"
mkdir -p "$noHeaderRoot"
"$NODE" init --preset software-development --mode ignore-all "$noHeaderRoot" >/dev/null 2>&1
printf '%s\n' '# Session log' >"$noHeaderRoot/.agent/session-log.md"
printf -- '- [2026-01-01] (claude) test entry (testing). verify: pass.\n' >>"$noHeaderRoot/.agent/session-log.md"
before_nh=$(cat "$noHeaderRoot/.agent/session-log.md")
out_nh=$("$NODE" update "$noHeaderRoot" 2>&1)
rc_nh=$?
after_nh=$(cat "$noHeaderRoot/.agent/session-log.md")
[ "$rc_nh" -eq 0 ] && [ "$before_nh" = "$after_nh" ] \
  && pass "update: a session-log.md with no header comment is left untouched" \
  || fail "update: a session-log.md with no header comment is left untouched (rc=$rc_nh)"
printf '%s' "$out_nh" | grep -qF 'no header comment' \
  && pass "update: a headerless session-log.md draws a report, not an error" \
  || fail "update: a headerless session-log.md draws a report, not an error ($out_nh)"

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
grep -qF 'If one already states it, update that source or its routing, write no fact, and say which source states it.' "$memroot/.agent/memory.md" && pass "memory.md's header rejects facts duplicated from canonical sources" || fail "memory.md's header rejects facts duplicated from canonical sources"
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

# memory.sh supersede — the fact contract says rewrite the fact and the
# date and keep the filename. Until this subcommand existed the only path
# was by hand, and the date was the half that got forgotten every time.
# The fixture is hand-written with a stale date so the restamp is visible:
# a fact written by `new` already carries today's.
printf -- '---\ndate: 2020-01-01\nscope: package\ntype: reference\n---\n\nthe superseded body, stale\n' >"$memroot/.agent/memory/vendor-rate-limit.md"
printf -- '- [Vendor Rate Limit](memory/vendor-rate-limit.md) — calling the vendor API\n' >>"$memroot/.agent/memory.md"
supfile="$memroot/.agent/memory/vendor-rate-limit.md"
supindex_before=$(cat "$memroot/.agent/memory.md")

out9s=$("$memcopy" supersede --slug vendor-rate-limit --fact "the vendor allows 240 requests a minute per key, burst 40." "$memroot" 2>&1)
rc=$?
[ "$rc" -eq 0 ] && pass "memory.sh supersede: valid supersede exits 0" || fail "memory.sh supersede: valid supersede exits 0 ($out9s)"
grep -qF 'the vendor allows 240 requests a minute per key' "$supfile" && pass "memory.sh supersede: the new body replaces the old" || fail "memory.sh supersede: the new body replaces the old"
grep -qF 'the superseded body, stale' "$supfile" && fail "memory.sh supersede: the old body is gone" || pass "memory.sh supersede: the old body is gone"
grep -qxF -- "date: $(today)" "$supfile" && pass "memory.sh supersede: the date is restamped to today" || fail "memory.sh supersede: the date is restamped to today ($(grep '^date:' "$supfile"))"
grep -qxF -- "scope: package" "$supfile" && grep -qxF -- "type: reference" "$supfile" && pass "memory.sh supersede: scope and type carry forward unchanged" || fail "memory.sh supersede: scope and type carry forward unchanged"
[ "$supindex_before" = "$(cat "$memroot/.agent/memory.md")" ] && pass "memory.sh supersede: the index line is left alone" || fail "memory.sh supersede: the index line is left alone"
grep -q '<!--' "$supfile" && fail "memory.sh supersede: the rewritten fact carries no header contract" || pass "memory.sh supersede: the rewritten fact carries no header contract"
flags9s=$(status_flags "$memroot" | grep '^REPAIR:')
[ -z "$flags9s" ] && pass "memory.sh supersede: the node draws no REPAIR afterward" || fail "memory.sh supersede: the node draws no REPAIR afterward ($flags9s)"

# An override still validates the way new's does.
"$memcopy" supersede --slug vendor-rate-limit --fact "narrowed to one project" --scope project --type fact "$memroot" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && grep -qxF -- "scope: project" "$supfile" && grep -qxF -- "type: fact" "$supfile" && pass "memory.sh supersede: --scope and --type override the carried values" || fail "memory.sh supersede: --scope and --type override the carried values"
"$memcopy" supersede --slug vendor-rate-limit --fact "bogus scope attempt" --scope everywhere "$memroot" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && grep -qF 'narrowed to one project' "$supfile" && pass "memory.sh supersede: an unknown --scope is rejected, the fact unchanged" || fail "memory.sh supersede: an unknown --scope is rejected, the fact unchanged"

# Every refusal leaves the fact and the index exactly as they were.
"$memcopy" supersede --slug never-written --fact "no such fact" "$memroot" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$memroot/.agent/memory/never-written.md" ] && pass "memory.sh supersede: a missing fact file is rejected, nothing created" || fail "memory.sh supersede: a missing fact file is rejected, nothing created"

printf -- '---\ndate: 2020-01-01\nscope: project\ntype: fact\n---\n\nunindexed body\n' >"$memroot/.agent/memory/unindexed.md"
"$memcopy" supersede --slug unindexed --fact "should not land" "$memroot" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && grep -qF 'unindexed body' "$memroot/.agent/memory/unindexed.md" && pass "memory.sh supersede: an unindexed fact file is rejected, unchanged" || fail "memory.sh supersede: an unindexed fact file is rejected, unchanged"
rm -f "$memroot/.agent/memory/unindexed.md"

"$memcopy" supersede --slug vendor-rate-limit "$memroot" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "memory.sh supersede: a missing --fact is rejected" || fail "memory.sh supersede: a missing --fact is rejected"
"$memcopy" supersede --slug vendor-rate-limit --fact --scope "$memroot" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && grep -qF 'narrowed to one project' "$supfile" && pass "memory.sh supersede: a flag is not accepted as another flag's value" || fail "memory.sh supersede: a flag is not accepted as another flag's value"
"$memcopy" supersede --slug "Bad_Slug" --fact "invalid slug attempt" "$memroot" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "memory.sh supersede: an invalid slug is rejected" || fail "memory.sh supersede: an invalid slug is rejected"
"$memcopy" supersede --slug vendor-rate-limit --title "Renamed" --fact "titles are not supersede's" "$memroot" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "memory.sh supersede: --title is not a supersede flag" || fail "memory.sh supersede: --title is not a supersede flag"

# new's refusal now names the subcommand rather than sending the writer to
# do it by hand.
out9t=$("$memcopy" new --slug vendor-rate-limit --title "Dup" --hook "dup" --fact "duplicate attempt" "$memroot" 2>&1)
printf '%s\n' "$out9t" | grep -qF 'memory.sh supersede --slug vendor-rate-limit' && pass "memory.sh new: the overwrite refusal points at supersede" || fail "memory.sh new: the overwrite refusal points at supersede ($out9t)"

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

# A summary carrying its own `verify:` puts a second tag in the middle of an
# entry that already ends in one. Both eval arms produced this line shape.
before17v=$(cat "$sessionlog")
"$logcopy" --tool claude --area testing --verify fail --summary "baseline was red before this change verify: fail" "$logroot" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && [ "$(cat "$sessionlog")" = "$before17v" ] && pass "log.sh: a summary containing verify: is rejected, nothing written" || fail "log.sh: a summary containing verify: is rejected, nothing written"

"$logcopy" --tool claude --area testing --verify pass --summary "Verify: the tag spelling is refused in any case" "$logroot" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "log.sh: the verify: guard is case-insensitive" || fail "log.sh: the verify: guard is case-insensitive"

# The guard must be narrow: it takes the tag spelling, not the word.
"$logcopy" --tool claude --area testing --verify pass --summary "verified the parser against the fixture suite" "$logroot" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "log.sh: the word verified without a colon still logs" || fail "log.sh: the word verified without a colon still logs"

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

# ---- 21b. status.sh: architecture.md missing while docs/ holds routed docs
# The three INDEX: routing checks above are all guarded on `[[ -s "$arch" ]]`
# — correctly, since each compares a doc against its entry in a table that
# must exist first — which leaves a node with routed docs and no table at
# all silent. docs.sh creates architecture.md automatically the first time a
# doc is scaffolded, so this state only reaches a hand-edited or partially
# copied node: exactly what this REPAIR: check exists to catch.
missrepair='REPAIR: docs/architecture.md missing/empty'

# (c) an empty docs/ draws no finding.
rtm1="$WORK/routing-table-missing-empty"
mkdir -p "$rtm1"
"$NODE" init --preset software-development --mode track-all "$rtm1" >/dev/null 2>&1
finish_bootstrap "$rtm1"
f21c=$(status_flags "$rtm1" | grep -F "$missrepair")
[ -z "$f21c" ] && pass "routing table: empty docs/ draws no missing-table REPAIR" || fail "routing table: empty docs/ draws no missing-table REPAIR ($f21c)"

# (d) docs/ holding only references/ content draws no finding either — that
# tier has nothing to route.
rtm2="$WORK/routing-table-missing-references-only"
mkdir -p "$rtm2"
"$NODE" init --preset software-development --mode track-all "$rtm2" >/dev/null 2>&1
finish_bootstrap "$rtm2"
mkdir -p "$rtm2/.agent/docs/references"
printf '# Vendor spec dump\n\nsome content\n' >"$rtm2/.agent/docs/references/vendor.md"
f21d=$(status_flags "$rtm2" | grep -F "$missrepair")
[ -z "$f21d" ] && pass "routing table: references/-only docs/ draws no missing-table REPAIR" || fail "routing table: references/-only docs/ draws no missing-table REPAIR ($f21d)"

# (a) a routed doc with no table at all fires exactly once, naming the table.
rtm3="$WORK/routing-table-missing-one-doc"
mkdir -p "$rtm3"
"$NODE" init --preset software-development --mode track-all "$rtm3" >/dev/null 2>&1
finish_bootstrap "$rtm3"
rtm3docs="$rtm3/.agent/scripts/docs.sh"
"$rtm3docs" new --name payments --read-when "payment flows and webhooks" "$rtm3" >/dev/null 2>&1
rm -f "$rtm3/.agent/docs/architecture.md"
f21e=$(status_flags "$rtm3")
[ "$(printf '%s\n' "$f21e" | grep -cF "$missrepair")" = "1" ] && pass "routing table: routed doc with no table draws exactly one REPAIR" || fail "routing table: routed doc with no table draws exactly one REPAIR ($f21e)"
printf '%s\n' "$f21e" | grep -qF 'docs/architecture.md' && pass "routing table: the REPAIR line names the missing table" || fail "routing table: the REPAIR line names the missing table ($f21e)"

# (e) several routed docs, including a sub-doc under docs/<area>/, still
# draw exactly one line — the finding is about the node, not any one doc.
rtm4="$WORK/routing-table-missing-several-docs"
mkdir -p "$rtm4"
"$NODE" init --preset software-development --mode track-all "$rtm4" >/dev/null 2>&1
finish_bootstrap "$rtm4"
rtm4docs="$rtm4/.agent/scripts/docs.sh"
"$rtm4docs" new --name payments --read-when "payment flows and webhooks" "$rtm4" >/dev/null 2>&1
"$rtm4docs" new --name refunds --read-when "refund flows" "$rtm4" >/dev/null 2>&1
"$rtm4docs" new --name frontend/grids --read-when "grid layouts" "$rtm4" >/dev/null 2>&1
rm -f "$rtm4/.agent/docs/architecture.md"
f21f=$(status_flags "$rtm4")
[ "$(printf '%s\n' "$f21f" | grep -cF "$missrepair")" = "1" ] && pass "routing table: several routed docs (incl. a sub-doc) still draw exactly one REPAIR" || fail "routing table: several routed docs (incl. a sub-doc) still draw exactly one REPAIR ($f21f)"

# (f) an empty-but-present architecture.md also fires, matching the -s test
# the existing routing checks use.
: >"$rtm4/.agent/docs/architecture.md"
f21g=$(status_flags "$rtm4")
[ "$(printf '%s\n' "$f21g" | grep -cF "$missrepair")" = "1" ] && pass "routing table: an empty-but-present architecture.md still draws exactly one REPAIR" || fail "routing table: an empty-but-present architecture.md still draws exactly one REPAIR ($f21g)"

# (b) a routed doc WITH a present table draws no new finding, and the
# existing INDEX: findings are unaffected.
rtm5="$WORK/routing-table-present"
mkdir -p "$rtm5"
"$NODE" init --preset software-development --mode track-all "$rtm5" >/dev/null 2>&1
finish_bootstrap "$rtm5"
rtm5docs="$rtm5/.agent/scripts/docs.sh"
"$rtm5docs" new --name payments --read-when "payment flows and webhooks" "$rtm5" >/dev/null 2>&1
f21h=$(status_flags "$rtm5")
[ -z "$(printf '%s\n' "$f21h" | grep -F "$missrepair")" ] && pass "routing table: a present architecture.md draws no missing-table REPAIR" || fail "routing table: a present architecture.md draws no missing-table REPAIR ($f21h)"
[ -z "$f21h" ] && pass "routing table: a routed doc with its table stays otherwise INDEX-clean" || fail "routing table: a routed doc with its table stays otherwise INDEX-clean ($f21h)"

# ---- 20. status.sh on a bootstrapped node: no findings, one LOAD line ----
fresh19="$WORK/init-academic-research-track-all"
out19all=$("$fresh19/.agent/scripts/status.sh" "$fresh19" 2>&1 | grep -v '^TOOLS:')
out19=$(printf '%s\n' "$out19all" | grep -v '^LOAD:' | grep -v '^PAYLOAD:')
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

# ---- 24. native memory: what the three inspected settings files request ----
nm="$WORK/native-memory"
mkdir -p "$nm/.claude"
"$NODE" init --preset software-development --mode track-all "$nm" >/dev/null 2>&1
finish_bootstrap "$nm"
f24=$(HOME="$WORK/nm-empty-home" status_flags "$nm")
printf '%s\n' "$f24" | grep -qF 'autoMemoryEnabled is set nowhere' && pass "native memory: an unconfigured .claude/ draws a REPAIR flag" || fail "native memory: an unconfigured .claude/ draws a REPAIR flag ($f24)"
printf '%s\n' "$f24" | grep -qF 'add "autoMemoryEnabled": false to .claude/settings.json' && pass "native memory: the unconfigured-node repair names the settings file to edit" || fail "native memory: the unconfigured-node repair names the settings file to edit ($f24)"

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

# The two node-level files can disagree; the diagnostic names the file that
# requests memory on rather than resolving to one verdict for the node.
printf '{ "autoMemoryEnabled": true }\n' >"$nm/.claude/settings.json"
printf '{ "autoMemoryEnabled": false }\n' >"$nm/.claude/settings.local.json"
f24e=$(HOME="$WORK/nm-empty-home" status_flags "$nm")
printf '%s\n' "$f24e" | grep -qF '.claude/settings.json sets autoMemoryEnabled true' && pass "native memory: a disagreement names the offending file" || fail "native memory: a disagreement names the offending file ($f24e)"
printf '%s\n' "$f24e" | grep -qiE 'sole|effective|resolved' && fail "native memory: no line claims a resolved effective state ($f24e)" || pass "native memory: no line claims a resolved effective state"

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

# ---- 26b. always-loaded canonical files: contract.md and learned.md must
# exist. Both are read by the entry point's bootstrap step every session;
# either one missing used to leave status.sh silent. Each fixture removes
# exactly one file so neither finding depends on the other.
alcf="$WORK/always-loaded-canonical-files"
mkdir -p "$alcf"
"$NODE" init --preset software-development --mode track-all "$alcf" >/dev/null 2>&1
finish_bootstrap "$alcf"
[ -z "$(status_flags "$alcf")" ] && pass "always-loaded: a complete node prints no finding" || fail "always-loaded: a complete node prints no finding ($(status_flags "$alcf"))"

rm -f "$alcf/.agent/rules/contract.md"
f26d=$(status_flags "$alcf")
[ "$f26d" = "REPAIR: rules/contract.md missing/empty — restore it, the entry point loads it every session" ] && pass "always-loaded: a missing contract.md draws exactly one REPAIR finding" || fail "always-loaded: a missing contract.md draws exactly one REPAIR finding ($f26d)"
"$alcf/.agent/scripts/status.sh" "$alcf" >/dev/null 2>&1
[ "$?" -eq 0 ] && pass "always-loaded: status.sh still exits 0 with contract.md missing" || fail "always-loaded: status.sh still exits 0 with contract.md missing"

alcf2="$WORK/always-loaded-canonical-files-learned"
mkdir -p "$alcf2"
"$NODE" init --preset software-development --mode track-all "$alcf2" >/dev/null 2>&1
finish_bootstrap "$alcf2"
rm -f "$alcf2/.agent/rules/learned.md"
f26e=$(status_flags "$alcf2")
[ "$f26e" = "REPAIR: rules/learned/ missing/empty — restore the records, or rules/learned.md on a node that keeps no record directory; the entry point loads them every session" ] && pass "always-loaded: a missing learned.md draws exactly one REPAIR finding" || fail "always-loaded: a missing learned.md draws exactly one REPAIR finding ($f26e)"
"$alcf2/.agent/scripts/status.sh" "$alcf2" >/dev/null 2>&1
[ "$?" -eq 0 ] && pass "always-loaded: status.sh still exits 0 with learned.md missing" || fail "always-loaded: status.sh still exits 0 with learned.md missing"

# An empty-but-present file draws the same finding as a missing one.
alcf3="$WORK/always-loaded-canonical-files-empty"
mkdir -p "$alcf3"
"$NODE" init --preset software-development --mode track-all "$alcf3" >/dev/null 2>&1
finish_bootstrap "$alcf3"
: >"$alcf3/.agent/rules/learned.md"
f26f=$(status_flags "$alcf3")
[ "$f26f" = "REPAIR: rules/learned/ missing/empty — restore the records, or rules/learned.md on a node that keeps no record directory; the entry point loads them every session" ] && pass "always-loaded: an empty learned.md draws the same REPAIR finding as a missing one" || fail "always-loaded: an empty learned.md draws the same REPAIR finding as a missing one ($f26f)"
"$alcf3/.agent/scripts/status.sh" "$alcf3" >/dev/null 2>&1
[ "$?" -eq 0 ] && pass "always-loaded: status.sh still exits 0 with learned.md empty" || fail "always-loaded: status.sh still exits 0 with learned.md empty"

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

# ---- 27b. self-learning: admission contract and routing ----
# The Self-learning section states when a discovery becomes a durable record,
# which of four kinds it is, which surface owns that kind, and which command
# writes it. Every phrase check below is scoped to the section's own extract
# — reusing finish_bootstrap's awk idiom — so a phrase landing in the wrong
# section fails rather than passing.
sl_extract() {
  awk '/^## Self-learning/ { inq = 1 } inq && /^## / && !/^## Self-learning/ { inq = 0 } inq' "$1"
}

sl_bad=""
for p in software-development academic-research domain-knowledge; do
  sl_extract "$reporoot/presets/$p.md" | grep -qF "successful work" || sl_bad="$sl_bad $p"
done
[ -z "$sl_bad" ] && pass "self-learning: successful work is a retro trigger" || fail "self-learning: successful work is a retro trigger ($sl_bad)"

sl_bad=""
for p in software-development academic-research domain-knowledge; do
  sl_extract "$reporoot/presets/$p.md" | grep -qF "neither necessary nor sufficient" || sl_bad="$sl_bad $p"
done
[ -z "$sl_bad" ] && pass "self-learning: a correction alone neither requires nor justifies a record" || fail "self-learning: a correction alone neither requires nor justifies a record ($sl_bad)"

sl_bad=""
for p in software-development academic-research domain-knowledge; do
  sl27=$(sl_extract "$reporoot/presets/$p.md")
  ok27=1
  printf '%s\n' "$sl27" | grep -qF "no durable record" || ok27=0
  printf '%s\n' "$sl27" | grep -qF ".agent/scripts/memory.sh new" || ok27=0
  printf '%s\n' "$sl27" | grep -qF ".agent/scripts/memory.sh supersede --slug" || ok27=0
  printf '%s\n' "$sl27" | grep -qF ".agent/scripts/learn.sh" || ok27=0
  [ "$ok27" -eq 1 ] || sl_bad="$sl_bad $p"
done
[ -z "$sl_bad" ] && pass "self-learning: each of the four kinds names its surface and its writer" || fail "self-learning: each of the four kinds names its surface and its writer ($sl_bad)"

sl_bad=""
for p in software-development academic-research domain-knowledge; do
  sl_extract "$reporoot/presets/$p.md" | grep -qF "never becomes a project-wide rule" || sl_bad="$sl_bad $p"
done
[ -z "$sl_bad" ] && pass "self-learning: a task-scoped constraint stays at its stated scope" || fail "self-learning: a task-scoped constraint stays at its stated scope ($sl_bad)"

sl_bad=""
for p in software-development academic-research domain-knowledge; do
  sl_extract "$reporoot/presets/$p.md" | grep -qF "On a node running \`indexes: generated\`: run \`.agent/scripts/learn.sh lookup\`" || sl_bad="$sl_bad $p"
done
[ -z "$sl_bad" ] && pass "self-learning: a record is looked up before it is written" || fail "self-learning: a record is looked up before it is written ($sl_bad)"

sl_bad=""
for p in software-development academic-research domain-knowledge; do
  sl_extract "$reporoot/presets/$p.md" | grep -qF "merge near-duplicates by hand in \`.agent/rules/learned.md\`" || sl_bad="$sl_bad $p"
done
[ -z "$sl_bad" ] && pass "self-learning: a manual-mode node merges near-duplicates by hand" || fail "self-learning: a manual-mode node merges near-duplicates by hand ($sl_bad)"

sl_bad=""
for p in software-development academic-research domain-knowledge; do
  sl_extract "$reporoot/presets/$p.md" | grep -qF "human-facing text check or a comment gate" || sl_bad="$sl_bad $p"
done
[ -z "$sl_bad" ] && pass "self-learning: no prose scan or comment gate admits a record" || fail "self-learning: no prose scan or comment gate admits a record ($sl_bad)"

sl_handgrep=$(grep -rnF 'grep' \
  "$reporoot/presets/software-development.md" "$reporoot/presets/academic-research.md" \
  "$reporoot/presets/domain-knowledge.md" "$reporoot/tools/skills/retro/SKILL.md" 2>/dev/null)
[ -z "$sl_handgrep" ] && pass "self-learning: no preset or skill text instructs a hand grep over learned.md" || fail "self-learning: no preset or skill text instructs a hand grep over learned.md ($sl_handgrep)"

retro_skill="$reporoot/tools/skills/retro/SKILL.md"
retro_merge=$(awk '/^## Merge, don.t append/ { inq = 1 } inq && /^## / && !/^## Merge, don.t append/ { inq = 0 } inq' "$retro_skill")
printf '%s\n' "$retro_merge" | grep -qF "learn.sh" && pass "retro skill: the merge walkthrough calls learn.sh" || fail "retro skill: the merge walkthrough calls learn.sh"

retro_route=$(awk '/^## Route by scope/ { inq = 1 } inq && /^## / && !/^## Route by scope/ { inq = 0 } inq' "$retro_skill")
rt_ok=1
for rt_kind in "no durable record" ".agent/scripts/memory.sh new" ".agent/scripts/memory.sh supersede" ".agent/scripts/learn.sh"; do
  printf '%s\n' "$retro_route" | grep -qF "$rt_kind" || rt_ok=0
done
[ "$rt_ok" -eq 1 ] && pass "retro skill: the routing section names the four kinds and their writers" || fail "retro skill: the routing section names the four kinds and their writers"

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
  templates/entry-point-generated.md \
  scripts/status.sh scripts/log.sh scripts/memory.sh scripts/docs.sh \
  scripts/links.sh scripts/comments.sh scripts/checkpoint.sh scripts/index.sh \
  scripts/learn.sh \
  scripts/comments.conf scripts/status.conf scripts/log.conf scripts/node.sh 2>/dev/null | grep -vF -f "$lint_allow")
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

# ---- 32b. status.sh: the PAYLOAD line and the byte budget ----
# LOAD: measures the always-loaded set in words and includes members --load
# never prints (architecture.md, the entry point). PAYLOAD: measures exactly
# what --load writes, in bytes — markers included — because the harness's
# tool-result cap is a byte cap, not a word one.
pb="$WORK/payload-budget"
mkdir -p "$pb"
"$NODE" init --preset software-development --mode track-all "$pb" >/dev/null 2>&1
finish_bootstrap "$pb"

"$pb/.agent/scripts/status.sh" "$pb" >"$WORK/pb-noload.out" 2>&1
"$pb/.agent/scripts/status.sh" --load "$pb" >"$WORK/pb-load.out" 2>&1
payloadline_a=$(grep '^PAYLOAD:' "$WORK/pb-load.out")
[ -n "$payloadline_a" ] && pass "status.sh: PAYLOAD line prints on a node under budget" || fail "status.sh: PAYLOAD line prints on a node under budget"
grep -q '^REPAIR:.*payload' "$WORK/pb-load.out" && fail "status.sh: an under-budget node does not overflow" || pass "status.sh: an under-budget node does not overflow"
[ -z "$(status_flags "$pb")" ] && pass "status.sh: PAYLOAD is informational — a quiet under-budget node stays quiet" || fail "status.sh: PAYLOAD is informational — a quiet under-budget node stays quiet ($(status_flags "$pb"))"

# The reported total must equal the exact bytes --load appended to stdout.
# Both calls share the same informational prefix (findings/TOOLS/LOAD/
# PAYLOAD), so the byte difference between the plain call and the --load
# call is exactly what the --load loop wrote — markers and all.
reported_a=$(printf '%s\n' "$payloadline_a" | sed -E 's/^PAYLOAD: [^0-9]*([0-9]+) bytes.*/\1/')
bytes_noload_a=$(wc -c <"$WORK/pb-noload.out" | tr -d '[:space:]')
bytes_load_a=$(wc -c <"$WORK/pb-load.out" | tr -d '[:space:]')
actual_a=$((bytes_load_a - bytes_noload_a))
[ -n "$reported_a" ] && [ "$reported_a" = "$actual_a" ] \
  && pass "status.sh: PAYLOAD total equals the exact bytes --load writes" \
  || fail "status.sh: PAYLOAD total equals the exact bytes --load writes (reported $reported_a, actual $actual_a)"

# Boundary: pad memory.md to a computed size so the total lands exactly on
# PAYLOAD_MAX_BYTES, then push one byte past it.
budget_default=$(sed -n 's/^PAYLOAD_MAX_BYTES=//p' "$reporoot/scripts/status.sh" | head -n 1)
pad_needed=$((budget_default - reported_a))
[ "$pad_needed" -gt 0 ] || fail "status.sh: fixture's natural payload already exceeds PAYLOAD_MAX_BYTES — cannot build the boundary case"
printf '%*s' "$pad_needed" '' | tr ' ' 'x' >>"$pb/.agent/memory.md"

"$pb/.agent/scripts/status.sh" --load "$pb" >"$WORK/pb-exact.out" 2>&1
payloadline_exact=$(grep '^PAYLOAD:' "$WORK/pb-exact.out")
reported_exact=$(printf '%s\n' "$payloadline_exact" | sed -E 's/^PAYLOAD: [^0-9]*([0-9]+) bytes.*/\1/')
[ "$reported_exact" = "$budget_default" ] \
  && pass "status.sh: boundary fixture lands exactly on PAYLOAD_MAX_BYTES" \
  || fail "status.sh: boundary fixture lands exactly on PAYLOAD_MAX_BYTES (reported $reported_exact, budget $budget_default)"
grep -q '^REPAIR:.*payload' "$WORK/pb-exact.out" && fail "status.sh: a payload exactly at budget does not overflow" || pass "status.sh: a payload exactly at budget does not overflow"
grep -q '^==== .*memory.md ====' "$WORK/pb-exact.out" && pass "status.sh: a payload exactly at budget still emits its markers and content" || fail "status.sh: a payload exactly at budget still emits its markers and content"

printf 'x' >>"$pb/.agent/memory.md"
"$pb/.agent/scripts/status.sh" --load "$pb" >"$WORK/pb-over.out" 2>&1
rc_over=$?
overline=$(grep '^REPAIR:.*payload' "$WORK/pb-over.out")
[ -n "$overline" ] && pass "status.sh: one byte over budget reports overflow" || fail "status.sh: one byte over budget reports overflow ($(cat "$WORK/pb-over.out"))"
missing_paths=""
for p in rules/learned.md rules/contract.md purpose.md memory.md; do
  printf '%s\n' "$overline" | grep -qF "$p" || missing_paths="$missing_paths $p"
done
[ -z "$missing_paths" ] && pass "status.sh: the overflow REPAIR line names all four paths" || fail "status.sh: the overflow REPAIR line names all four paths (missing:$missing_paths)"
grep -q '^====' "$WORK/pb-over.out" && fail "status.sh: overflow emits no ==== markers or file content" || pass "status.sh: overflow emits no ==== markers or file content"
[ "$rc_over" -eq 0 ] && pass "status.sh: overflow does not change the exit status" || fail "status.sh: overflow does not change the exit status (rc=$rc_over)"

# A lowered PAYLOAD_MAX_BYTES pushes an otherwise-normal, unpadded node over.
lo="$WORK/payload-lowered"
mkdir -p "$lo"
"$NODE" init --preset software-development --mode track-all "$lo" >/dev/null 2>&1
finish_bootstrap "$lo"
printf 'PAYLOAD_MAX_BYTES=10\n' >>"$lo/.agent/scripts/status.conf"
out32e=$("$lo/.agent/scripts/status.sh" --load "$lo" 2>&1)
printf '%s\n' "$out32e" | grep -q '^REPAIR:.*payload' \
  && pass "status.conf: a lowered PAYLOAD_MAX_BYTES pushes a normal node over budget" \
  || fail "status.conf: a lowered PAYLOAD_MAX_BYTES pushes a normal node over budget ($out32e)"
printf '%s\n' "$out32e" | grep -q '^====' \
  && fail "status.sh: overflow from a lowered budget still emits no markers" \
  || pass "status.sh: overflow from a lowered budget still emits no markers"

# A non-numeric PAYLOAD_MAX_BYTES keeps the shipped default and draws the
# same generic conf-parse REPAIR every other threshold key already gets —
# no special-cased handling for this key.
nc="$WORK/payload-nonnumeric"
mkdir -p "$nc"
"$NODE" init --preset software-development --mode track-all "$nc" >/dev/null 2>&1
finish_bootstrap "$nc"
printf 'PAYLOAD_MAX_BYTES=huge\n' >>"$nc/.agent/scripts/status.conf"
out32f=$("$nc/.agent/scripts/status.sh" --load "$nc" 2>&1)
printf '%s\n' "$out32f" | grep -q '^REPAIR: status.conf PAYLOAD_MAX_BYTES=huge is not a whole number' \
  && pass "status.conf: a non-numeric PAYLOAD_MAX_BYTES draws the generic conf REPAIR line" \
  || fail "status.conf: a non-numeric PAYLOAD_MAX_BYTES draws the generic conf REPAIR line ($out32f)"
payloadline_f=$(printf '%s\n' "$out32f" | grep '^PAYLOAD:')
printf '%s\n' "$payloadline_f" | grep -qF "of a $budget_default byte budget" \
  && pass "status.conf: PAYLOAD_MAX_BYTES keeps its shipped default when the override is invalid" \
  || fail "status.conf: PAYLOAD_MAX_BYTES keeps its shipped default when the override is invalid ($payloadline_f)"

# A multibyte fixture reports the same byte total under all three locales
# the CI gate runs the whole suite under — wc -c must not vary with LC_ALL.
mb="$WORK/payload-multibyte"
mkdir -p "$mb"
"$NODE" init --preset software-development --mode track-all "$mb" >/dev/null 2>&1
finish_bootstrap "$mb"
printf '\nCafé naïve façade — 日本語のテスト — €£¥\n' >>"$mb/.agent/memory.md"
total_mb_c=$(LC_ALL=C "$mb/.agent/scripts/status.sh" --load "$mb" 2>/dev/null | sed -nE 's/^PAYLOAD: [^0-9]*([0-9]+) bytes.*/\1/p')
total_mb_iso=$(LC_ALL=en_US.ISO8859-1 "$mb/.agent/scripts/status.sh" --load "$mb" 2>/dev/null | sed -nE 's/^PAYLOAD: [^0-9]*([0-9]+) bytes.*/\1/p')
total_mb_default=$("$mb/.agent/scripts/status.sh" --load "$mb" 2>/dev/null | sed -nE 's/^PAYLOAD: [^0-9]*([0-9]+) bytes.*/\1/p')
[ -n "$total_mb_c" ] && [ "$total_mb_c" = "$total_mb_iso" ] && [ "$total_mb_c" = "$total_mb_default" ] \
  && pass "status.sh: a multibyte fixture's byte total is locale-invariant" \
  || fail "status.sh: a multibyte fixture's byte total is locale-invariant (C=$total_mb_c ISO=$total_mb_iso default=$total_mb_default)"

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

# Chat residue: echo_re already catches request-shaped replies (e.g.
# [as you ... requested], [as ... discussed]); this is the same audience
# mistake in the shapes a code review produces instead — a feedback reference,
# an agreement, an opening apology, a draft-revision label. Every fixture below pairs a
# flagged line with a clean one sharing its vocabulary, so a pass here rules
# out a naive keyword ban: "feedback", "agree", "suggested", "sorry", and
# "draft" all also appear in comments that must NOT block.
git_cg checkout -q base
git_cg checkout -q -b chat34
cat >>"$cg/src/app.ts" <<'EOF'
// As you suggested, cache the response for five minutes.
const n0 = 0
// Retain the cached result per your feedback.
const n1 = 1
// The cached result remains available, as agreed.
const n2 = 2
// Sorry, this cache uses the wrong table.
const n3 = 3
// Here is the fixed version.
const n4 = 4
// Draft v2 of the retry loop.
const n5 = 5
// The fixed version is 2.3.1.
const n6 = 6
// The audio pipeline debounces feedback from the microphone to prevent howling.
const n7 = 7
// The compiler suggested inlining this call, but the profiler disagreed.
const n8 = 8
// The two clocks rarely agree, so reads are staged through this buffer to hide the drift.
const n9 = 9
// The API returns a 404, not a sorry-not-found redirect, when the vendor id is missing.
const n10 = 10
// This document is not a draft; it defines the wire protocol precisely.
const n11 = 11
// Does NOT retry on 4xx responses because the vendor client treats retries as duplicate charges.
const n12 = 12
// The callback can arrive after cancellation because the vendor retains the handle.
const n13 = 13
// This retry limit is set per the agreement with the vendor, not a guess.
const n14 = 14
// Latency is calculated based on the feedback loop's sampling window.
const n15 = 15
// Per RFC draft v08, the header must be lowercase or the vendor gateway drops it.
const n16 = 16
// The v2 draft of the protocol allows retries, unlike v1, which this client targets.
const n17 = 17
// As agreed by both parties during the handshake, the client sends its cipher list first.
const n18 = 18
// Draft v08 of this fix is ready for review.
const n19 = 19
// As agreed, I'll ship the fix by Friday.
const n20 = 20
// Here's the revised draft based on your comments.
const n21 = 21
// This module implements the retry-header negotiation path end to end.
// Draft v2 of RFC 9110 changed how the retry-after header must be parsed.
const n22 = 22
// Here's the fixed version.
const n23 = 23
// Fixed version: the retry loop now caps at three attempts.
const n24 = 24
// This is the revised version of the retry loop.
const n25 = 25
// This comment is a draft revision of the retry loop.
const n26 = 26
// Updated the cache handling to address your comments.
const n27 = 27
// My apologies, the config value here is stale.
const n28 = 28
EOF
git_cg add -A >/dev/null
git_cg commit -q -m chat34
out34t=$(cd "$cg" && .agent/scripts/comments.sh base 2>&1)
rc34t=$?
block34t=$(printf '%s\n' "$out34t" | sed -n '/^BLOCK:/,$p')
review34t=$(printf '%s\n' "$out34t" | awk '/^BLOCK:/ { exit } { print }')
[ "$rc34t" -eq 1 ] && pass "comments.sh: chat residue exits 1" || fail "comments.sh: chat residue exits 1 (rc=$rc34t; $out34t)"

# Flagged: a feedback reference, an agreement, an opening apology, and a
# draft-revision label — each named "chat residue" rather than an unrelated
# class, and each recognizable by the exact wording the task named.
printf '%s\n' "$block34t" | grep -B1 -F 'As you suggested, cache the response' | grep -qF '[chat residue]' && pass "comments.sh: a feedback-request echo (\"as you suggested\") BLOCKs as chat residue" || fail "comments.sh: a feedback-request echo (\"as you suggested\") BLOCKs as chat residue ($block34t)"
printf '%s\n' "$block34t" | grep -B1 -F 'Retain the cached result per your feedback' | grep -qF '[chat residue]' && pass "comments.sh: a feedback reference (\"per your feedback\") BLOCKs as chat residue" || fail "comments.sh: a feedback reference (\"per your feedback\") BLOCKs as chat residue ($block34t)"
printf '%s\n' "$block34t" | grep -B1 -F 'remains available, as agreed' | grep -qF '[chat residue]' && pass "comments.sh: an agreement reference (\"as agreed\") BLOCKs as chat residue" || fail "comments.sh: an agreement reference (\"as agreed\") BLOCKs as chat residue ($block34t)"
printf '%s\n' "$block34t" | grep -B1 -F 'Sorry, this cache uses the wrong table' | grep -qF '[chat residue]' && pass "comments.sh: an opening apology (\"sorry\") BLOCKs as chat residue" || fail "comments.sh: an opening apology (\"sorry\") BLOCKs as chat residue ($block34t)"
printf '%s\n' "$block34t" | grep -B1 -F 'Here is the fixed version' | grep -qF '[chat residue]' && pass "comments.sh: a draft-revision label (\"here is the fixed version\") BLOCKs as chat residue" || fail "comments.sh: a draft-revision label (\"here is the fixed version\") BLOCKs as chat residue ($block34t)"
printf '%s\n' "$block34t" | grep -B1 -F 'Draft v2 of the retry loop' | grep -qF '[chat residue]' && pass "comments.sh: a draft-revision label (\"draft v2\") BLOCKs as chat residue" || fail "comments.sh: a draft-revision label (\"draft v2\") BLOCKs as chat residue ($block34t)"

# The remaining named forms of the draft-revision label, plus a second
# example each for the feedback reference and the opening apology.
printf '%s\n' "$block34t" | grep -B1 -F "Here's the fixed version" | grep -qF '[chat residue]' && pass "comments.sh: a draft-revision label (\"here's the fixed version\") BLOCKs as chat residue" || fail "comments.sh: a draft-revision label (\"here's the fixed version\") BLOCKs as chat residue ($block34t)"
printf '%s\n' "$block34t" | grep -B1 -F 'Fixed version: the retry loop now caps at three attempts' | grep -qF '[chat residue]' && pass "comments.sh: a draft-revision label (\"fixed version:\") BLOCKs as chat residue" || fail "comments.sh: a draft-revision label (\"fixed version:\") BLOCKs as chat residue ($block34t)"
printf '%s\n' "$block34t" | grep -B1 -F 'the revised version of the retry loop' | grep -qF '[chat residue]' && pass "comments.sh: a draft-revision label (\"revised version\") BLOCKs as chat residue" || fail "comments.sh: a draft-revision label (\"revised version\") BLOCKs as chat residue ($block34t)"
printf '%s\n' "$block34t" | grep -B1 -F 'a draft revision of the retry loop' | grep -qF '[chat residue]' && pass "comments.sh: a draft-revision label (\"draft revision\") BLOCKs as chat residue" || fail "comments.sh: a draft-revision label (\"draft revision\") BLOCKs as chat residue ($block34t)"
printf '%s\n' "$block34t" | grep -B1 -F 'Updated the cache handling to address your comments' | grep -qF '[chat residue]' && pass "comments.sh: a feedback reference (\"to address your comments\") BLOCKs as chat residue" || fail "comments.sh: a feedback reference (\"to address your comments\") BLOCKs as chat residue ($block34t)"
printf '%s\n' "$block34t" | grep -B1 -F 'My apologies, the config value here is stale' | grep -qF '[chat residue]' && pass "comments.sh: an opening apology (\"my apologies\") BLOCKs as chat residue" || fail "comments.sh: an opening apology (\"my apologies\") BLOCKs as chat residue ($block34t)"

# Clean, sharing vocabulary with a flagged line above: a lexical ban on
# "feedback", "agree", "suggested", "sorry", or "draft" alone would also
# catch these, and it must not.
printf '%s\n' "$block34t" | grep -q 'fixed version is 2.3.1' && fail "comments.sh: a real version report is not a draft-revision label" || pass "comments.sh: a real version report is not a draft-revision label"
printf '%s\n' "$block34t" | grep -q 'debounces feedback' && fail "comments.sh: audio feedback is not a feedback reference" || pass "comments.sh: audio feedback is not a feedback reference"
printf '%s\n' "$block34t" | grep -q 'profiler disagreed' && fail "comments.sh: \"suggested\" outside \"as you suggested\" is not chat residue" || pass "comments.sh: \"suggested\" outside \"as you suggested\" is not chat residue"
printf '%s\n' "$block34t" | grep -q 'rarely agree' && fail "comments.sh: \"agree\" outside \"as agreed\" is not chat residue" || pass "comments.sh: \"agree\" outside \"as agreed\" is not chat residue"
printf '%s\n' "$block34t" | grep -q 'sorry-not-found' && fail "comments.sh: a mid-sentence \"sorry\" is not an opening apology" || pass "comments.sh: a mid-sentence \"sorry\" is not an opening apology"
printf '%s\n' "$block34t" | grep -q 'not a draft; it defines' && fail "comments.sh: \"draft\" outside a revision label is not chat residue" || pass "comments.sh: \"draft\" outside a revision label is not chat residue"

# Five false-positive shapes, each a legitimate engineering comment (a
# vendor/contract reference, a technical description, an RFC/spec version
# citation) that a naive keyword match on "agreement", "feedback", or
# "draft v<N>" wrongly BLOCKed. None of these may BLOCK.
printf '%s\n' "$block34t" | grep -qF 'per the agreement with the vendor' && fail "comments.sh: a vendor-contract reference is not an agreement echo" || pass "comments.sh: a vendor-contract reference is not an agreement echo"
printf '%s\n' "$block34t" | grep -qF "based on the feedback loop's sampling window" && fail "comments.sh: a feedback-loop description is not a feedback reference" || pass "comments.sh: a feedback-loop description is not a feedback reference"
printf '%s\n' "$block34t" | grep -qF 'Per RFC draft v08' && fail "comments.sh: an RFC draft citation is not a draft-revision label" || pass "comments.sh: an RFC draft citation is not a draft-revision label"
printf '%s\n' "$block34t" | grep -qF 'The v2 draft of the protocol' && fail "comments.sh: a protocol-version description is not a draft-revision label" || pass "comments.sh: a protocol-version description is not a draft-revision label"
printf '%s\n' "$block34t" | grep -qF 'As agreed by both parties' && fail "comments.sh: a third-party agreement is not an agreement echo" || pass "comments.sh: a third-party agreement is not an agreement echo"

# Minimal pairs: the same key word in an actually chat-shaped comment still
# BLOCKs, so the narrowing above rules out a shape rather than a word.
printf '%s\n' "$block34t" | grep -B1 -F 'Draft v08 of this fix is ready for review' | grep -qF '[chat residue]' && pass "comments.sh: a draft label opening the comment (\"draft v08\") BLOCKs as chat residue" || fail "comments.sh: a draft label opening the comment (\"draft v08\") BLOCKs as chat residue ($block34t)"
printf '%s\n' "$block34t" | grep -B1 -F "I'll ship the fix by Friday" | grep -qF '[chat residue]' && pass "comments.sh: an agreement ending its clause (\"as agreed,\") BLOCKs as chat residue" || fail "comments.sh: an agreement ending its clause (\"as agreed,\") BLOCKs as chat residue ($block34t)"
printf '%s\n' "$block34t" | grep -B1 -F "revised draft based on your comments" | grep -qF '[chat residue]' && pass "comments.sh: a revised-draft label BLOCKs as chat residue" || fail "comments.sh: a revised-draft label BLOCKs as chat residue ($block34t)"

# "draft v2" only counts as a revision label when it opens the comment
# itself, not merely the physical line being scanned. A multi-line comment
# whose SECOND line happens to start with "Draft v2 of RFC ..." is still the
# same RFC/spec version-citation shape as the "Per RFC draft v08" fixture
# above — it must not BLOCK just because "^" matched that line in isolation.
printf '%s\n' "$block34t" | grep -qF 'Draft v2 of RFC 9110 changed how the retry-after header must be parsed' && fail "comments.sh: a draft-v2 spec citation on a comment's second line is not a revision label" || pass "comments.sh: a draft-v2 spec citation on a comment's second line is not a revision label"

# A lexical pass rules a shape out; it never certifies a shape as necessary.
# These two land in REVIEW, for the author to justify or delete — not a
# silent pass that looks the same as "this comment is useful."
printf '%s\n' "$review34t" | grep -qF 'fixed version is 2.3.1' && pass "comments.sh: the real version report lands in REVIEW, not silently endorsed" || fail "comments.sh: the real version report lands in REVIEW ($review34t)"

# Negation is not chat residue and not routine narration: a comment stating
# a real negative property survives with its exact wording, not merely
# "does not block."
printf '%s\n' "$review34t" | grep -qF 'Does NOT retry on 4xx responses because the vendor client treats retries as duplicate charges.' && pass "comments.sh: a negative constraint survives a negation, verbatim" || fail "comments.sh: a negative constraint survives a negation ($review34t)"

# The necessary-constraint fixture: a callback whose timing depends on a
# vendor's own contract is exactly what REVIEW exists to let a human keep,
# and its meaning must reach REVIEW intact, not truncated.
printf '%s\n' "$review34t" | grep -qF 'The callback can arrive after cancellation because the vendor retains the handle.' && pass "comments.sh: a non-obvious callback constraint survives with its meaning intact" || fail "comments.sh: a non-obvious callback constraint survives with its meaning intact ($review34t)"

# CHAT_RE_EXTRA follows the same conf contract as the other _EXTRA keys: ORed
# onto the shipped vocabulary, and a broken pattern fails the run closed
# rather than silently passing as clean.
printf 'CHAT_RE_EXTRA=(^|[^[:alnum:]])lgtm\n' >"$cg/.agent/scripts/comments.conf"
printf '// lgtm, ship it\nconst n22 = 22\n' >>"$cg/src/app.ts"
out34u=$(cd "$cg" && .agent/scripts/comments.sh base 2>&1)
printf '%s\n' "$out34u" | sed -n '/^BLOCK:/,$p' | grep -q 'lgtm, ship it' && pass "comments.sh: CHAT_RE_EXTRA joins the chat-residue class" || fail "comments.sh: CHAT_RE_EXTRA joins the chat-residue class ($out34u)"
git_cg checkout -q -- src/app.ts

printf 'CHAT_RE_EXTRA=(unterminated\n' >"$cg/.agent/scripts/comments.conf"
(cd "$cg" && .agent/scripts/comments.sh base >/dev/null 2>&1)
rc34v=$?
[ "$rc34v" -eq 2 ] && pass "comments.sh: an invalid CHAT_RE_EXTRA fails closed rather than passing clean" || fail "comments.sh: an invalid CHAT_RE_EXTRA fails closed (rc=$rc34v)"
rm -f "$cg/.agent/scripts/comments.conf"

# Exclusion scope stays exactly what it was: Markdown never joins the scanned
# extensions, and a hidden directory (.agent/ included) stays out of the scan
# generically — chat residue is a new class inside the existing gate, not a
# new gate with its own reach.
printf '# As you suggested, cache the response for five minutes.\n' >"$cg/notes.md"
mkdir -p "$cg/.agent/docs"
printf '// As you suggested, cache the response for five minutes.\n' >"$cg/.agent/docs/note.ts"
out34w=$(cd "$cg" && .agent/scripts/comments.sh chat34 2>&1)
rc34w=$?
[ "$rc34w" -eq 0 ] && [ -z "$out34w" ] && pass "comments.sh: chat residue in Markdown and under .agent/ stays out of the gate" || fail "comments.sh: chat residue in Markdown and under .agent/ stays out of the gate (rc=$rc34w; $out34w)"
rm -rf "$cg/notes.md" "$cg/.agent/docs"

# Routine implementation work adds no comment at all, and that is the
# expected shape, not a shortfall the gate makes up for: no comment quota,
# no narration expected in exchange for a clean pass.
cat >>"$cg/src/app.ts" <<'EOF'
function retryOnce(fn) {
  try {
    return fn()
  } catch (e) {
    return fn()
  }
}
EOF
out34x=$(cd "$cg" && .agent/scripts/comments.sh chat34 2>&1)
rc34x=$?
[ "$rc34x" -eq 0 ] && [ -z "$out34x" ] && pass "comments.sh: a routine implementation adding zero comments is silent, not flagged for lacking one" || fail "comments.sh: a routine implementation adding zero comments is silent (rc=$rc34x; $out34x)"
git_cg checkout -q -- src/app.ts

git_cg checkout -q base

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
for f in status.sh log.sh memory.sh docs.sh links.sh comments.sh checkpoint.sh index.sh finish.sh learn.sh; do
  [ -x "$cgu2/.agent/scripts/$f" ] || missing_u="$missing_u $f"
done
for f in comments.conf status.conf log.conf; do
  [ -f "$cgu2/.agent/scripts/$f" ] || missing_u="$missing_u $f"
done
[ -z "$missing_u" ] && pass "update: every shipped script and starter conf reaches an existing node" || fail "update: every shipped script and starter conf reaches an existing node (missing:$missing_u)"

# F2: the gate fails closed when it cannot read what it is meant to read,
# rather than reporting a pass it never earned. GIT_EXTERNAL_DIFF pointed
# at a program that fails is the audit's own reproducer: git diff then
# exits 128, and unless that status is checked, the parser downstream is
# handed an empty stream that reads as a clean diff never taken.
out34diffx=$(cd "$cg" && GIT_EXTERNAL_DIFF=false .agent/scripts/comments.sh base 2>&1)
rc34diffx=$?
[ "$rc34diffx" -eq 2 ] && pass "comments.sh: GIT_EXTERNAL_DIFF pointed at a broken program fails the diff capture closed" || fail "comments.sh: GIT_EXTERNAL_DIFF pointed at a broken program fails the diff capture closed (rc=$rc34diffx; $out34diffx)"

# The rest of the fault injection goes through a PATH-prepended stub that
# fails only the exact call under test and execs the real tool otherwise,
# so every other git or awk call in the run is untouched. The real
# interpreter is resolved once, before PATH is ever touched, and baked
# into each stub's own text rather than re-resolved at the stub's run
# time — a stub that called `command -v` itself would find itself first.
stub34="$WORK/cg-stub"
mkdir -p "$stub34"
real_git34=$(command -v git)
real_awk34=$(command -v awk)

# The diff-capture call is the only one carrying --src-prefix=a/.
cat >"$stub34/git" <<STUBEOF
#!/bin/sh
for a in "\$@"; do
  if [ "\$a" = "--src-prefix=a/" ]; then
    exit 1
  fi
done
exec "$real_git34" "\$@"
STUBEOF
chmod +x "$stub34/git"
out34diffy=$(cd "$cg" && PATH="$stub34:$PATH" .agent/scripts/comments.sh base 2>&1)
rc34diffy=$?
[ "$rc34diffy" -eq 2 ] && pass "comments.sh: a stubbed git failing the diff capture exits 2" || fail "comments.sh: a stubbed git failing the diff capture exits 2 (rc=$rc34diffy; $out34diffy)"
rm -f "$stub34/git"

# Untracked-file discovery carries the only ls-files call with -z, which
# separates it from the identical-looking call in the emptiness guard.
cat >"$stub34/git" <<STUBEOF
#!/bin/sh
for a in "\$@"; do
  if [ "\$a" = "-z" ]; then
    exit 1
  fi
done
exec "$real_git34" "\$@"
STUBEOF
chmod +x "$stub34/git"
out34untrx=$(cd "$cg" && PATH="$stub34:$PATH" .agent/scripts/comments.sh base 2>&1)
rc34untrx=$?
[ "$rc34untrx" -eq 2 ] && pass "comments.sh: a stubbed git failing untracked-file discovery exits 2" || fail "comments.sh: a stubbed git failing untracked-file discovery exits 2 (rc=$rc34untrx; $out34untrx)"
rm -f "$stub34/git"

# The classifier is the only awk invocation that exports BLOCK_RE — a
# blanket awk stub would trip the earlier regex-validation awk calls first
# and pass the assertion below for the wrong reason.
cat >"$stub34/awk" <<STUBEOF
#!/bin/sh
if [ -n "\${BLOCK_RE+x}" ]; then
  exit 1
fi
exec "$real_awk34" "\$@"
STUBEOF
chmod +x "$stub34/awk"
out34clsx=$(cd "$cg" && PATH="$stub34:$PATH" .agent/scripts/comments.sh base 2>&1)
rc34clsx=$?
[ "$rc34clsx" -eq 2 ] && pass "comments.sh: a stubbed awk failing the classifier exits 2" || fail "comments.sh: a stubbed awk failing the classifier exits 2 (rc=$rc34clsx; $out34clsx)"
rm -f "$stub34/awk"

# The emptiness guard's three git calls each fail closed on an error
# status, distinct from the 0/1 outcomes the guard actually reads.
cat >"$stub34/git" <<STUBEOF
#!/bin/sh
if [ "\$1" = "rev-parse" ] && [ "\$2" = "HEAD" ] && [ \$# -eq 2 ]; then
  exit 1
fi
exec "$real_git34" "\$@"
STUBEOF
chmod +x "$stub34/git"
out34headx=$(cd "$cg" && PATH="$stub34:$PATH" .agent/scripts/comments.sh base 2>&1)
rc34headx=$?
[ "$rc34headx" -eq 2 ] && pass "comments.sh: a stubbed 'git rev-parse HEAD' failure exits 2" || fail "comments.sh: a stubbed 'git rev-parse HEAD' failure exits 2 (rc=$rc34headx; $out34headx)"
rm -f "$stub34/git"

cat >"$stub34/git" <<STUBEOF
#!/bin/sh
if [ "\$1" = "diff" ] && [ "\$2" = "--quiet" ] && [ "\$3" = "HEAD" ]; then
  exit 128
fi
exec "$real_git34" "\$@"
STUBEOF
chmod +x "$stub34/git"
out34quietx=$(cd "$cg" && PATH="$stub34:$PATH" .agent/scripts/comments.sh base 2>&1)
rc34quietx=$?
[ "$rc34quietx" -eq 2 ] && pass "comments.sh: a 'git diff --quiet HEAD' error status exits 2" || fail "comments.sh: a 'git diff --quiet HEAD' error status exits 2 (rc=$rc34quietx; $out34quietx)"
rm -f "$stub34/git"

cat >"$stub34/git" <<STUBEOF
#!/bin/sh
if [ "\$1" = "ls-files" ] && [ "\$2" = "--others" ] && [ "\$3" = "--exclude-standard" ] && [ \$# -eq 3 ]; then
  exit 1
fi
exec "$real_git34" "\$@"
STUBEOF
chmod +x "$stub34/git"
out34othersx=$(cd "$cg" && PATH="$stub34:$PATH" .agent/scripts/comments.sh base 2>&1)
rc34othersx=$?
[ "$rc34othersx" -eq 2 ] && pass "comments.sh: a stubbed emptiness-guard 'git ls-files' failure exits 2" || fail "comments.sh: a stubbed emptiness-guard 'git ls-files' failure exits 2 (rc=$rc34othersx; $out34othersx)"
rm -f "$stub34/git"

# checkpoint.sh already maps any non-zero comments.sh exit to a hard stop
# with no log entry (scripts/checkpoint.sh, unchanged here) — a gate that
# now fails closed on a broken diff read has to reach that same stop, not a
# silent pass through it.
cgf34="$WORK/comment-gate-failclosed"
mkdir -p "$cgf34/src"
"$NODE" init --preset software-development --mode track-all "$cgf34" >/dev/null 2>&1
finish_bootstrap "$cgf34"
printf 'export const a = 1\n' >"$cgf34/src/a.ts"
git -C "$cgf34" init -q && git -C "$cgf34" add -A && git -C "$cgf34" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m base
printf 'export const b = 2\n' >>"$cgf34/src/a.ts"
n34before=$(grep -c '^- \[' "$cgf34/.agent/session-log.md")
out34fc=$(GIT_EXTERNAL_DIFF=false "$cgf34/.agent/scripts/checkpoint.sh" --tool claude --area testing --verify pass --summary "should not log" "$cgf34" 2>&1)
rc34fc=$?
n34after=$(grep -c '^- \[' "$cgf34/.agent/session-log.md")
[ "$rc34fc" -ne 0 ] && [ "$n34before" -eq "$n34after" ] && pass "checkpoint.sh: a failed-closed comment gate appends no log entry" || fail "checkpoint.sh: a failed-closed comment gate appends no log entry (rc=$rc34fc before=$n34before after=$n34after; $out34fc)"

# The one temporary file comments.sh writes — the captured diff — survives
# no run, clean or failed: a single trap removes it on every exit path.
tmpdir34="$WORK/cg-tmpdir"
mkdir -p "$tmpdir34"
(cd "$cg" && TMPDIR="$tmpdir34" .agent/scripts/comments.sh base >/dev/null 2>&1)
(cd "$cg" && TMPDIR="$tmpdir34" GIT_EXTERNAL_DIFF=false .agent/scripts/comments.sh base >/dev/null 2>&1)
(cd "$cg" && TMPDIR="$tmpdir34" .agent/scripts/comments.sh nosuchref >/dev/null 2>&1)
leftover34=$(find "$tmpdir34" -type f)
[ -z "$leftover34" ] && pass "comments.sh: no temporary file survives success or failure" || fail "comments.sh: no temporary file survives success or failure ($leftover34)"

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
         DOCS_MAX_WORDS ENTRYPOINT_MAX_WORDS TAIL_LINES PAYLOAD_MAX_BYTES; do
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
om_check session-log.md "One entry per turn that changed files"
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

# 40h. comments.sh is excluded because it takes a base ref, not a root.
# index.sh is excluded because its --help opens with a bare "Usage:" line
# above a four-invocation block, and its exit-0 contract is already
# asserted by section 53.
hp="$WORK/helpcontract"
mkdir -p "$hp"
"$NODE" init --preset software-development --mode track-all "$hp" >/dev/null 2>&1
hp_bad=""
for hp_s in status log memory docs links checkpoint learn; do
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
printf '%s\n' "$f41" | grep -qF 'GROOM: CLAUDE.md > 600 words' && pass "status.sh: an entry point grown past wiring is flagged" || fail "status.sh: an entry point grown past wiring is flagged ($f41)"

printf 'ENTRYPOINT_MAX_WORDS=2000\n' >"$ew/.agent/scripts/status.conf"
status_flags "$ew" | grep -q 'CLAUDE.md > ' && fail "status.conf: the entry-point threshold tunes per node" || pass "status.conf: the entry-point threshold tunes per node"

# The word count measures bloat; the boundary is what actually breaks. A
# deploy command appended under its own heading costs a tenth of the
# threshold and never reaches .agent/ at all, and mirroring it to every entry
# point keeps the drift check quiet while it sits in the wrong file. So the
# shape is checked whatever the size, and that check has no tunable.
ews="$WORK/entrypoint-section"
mkdir -p "$ews"
"$NODE" init --preset software-development --mode ignore-all "$ews" >/dev/null 2>&1
finish_bootstrap "$ews"
printf '# P — Session Bootstrap\n\nRun `bash .agent/scripts/status.sh` first.\n' >"$ews/CLAUDE.md"
status_flags "$ews" | grep -q 'CLAUDE.md' && fail "status.sh: a wiring-only entry point raises no section flag" || pass "status.sh: a wiring-only entry point raises no section flag"
printf '\n## Operations\n\nDeploy with `npm run deploy -- --env prod`. Branches are `feat/<ticket>-<slug>`.\n' >>"$ews/CLAUDE.md"
f41s=$(status_flags "$ews")
printf '%s\n' "$f41s" | grep -qF 'GROOM: CLAUDE.md carries the section "## Operations"' && pass "status.sh: a section added to an entry point is flagged under the word threshold" || fail "status.sh: a section added to an entry point is flagged under the word threshold ($f41s)"
printf 'ENTRYPOINT_MAX_WORDS=2000\n' >"$ews/.agent/scripts/status.conf"
status_flags "$ews" | grep -qF 'carries the section' && pass "status.sh: the section check has no tunable to raise past it" || fail "status.sh: the section check has no tunable to raise past it"
rm -f "$ews/.agent/scripts/status.conf"
# Mirroring the section to every entry point silences the drift check and
# must not silence this one: both copies are flagged, not neither.
cp "$ews/CLAUDE.md" "$ews/AGENTS.md"
f41m=$(status_flags "$ews")
printf '%s\n' "$f41m" | grep -qF 'differs from' && fail "status.sh: mirrored entry points raise no drift flag" || pass "status.sh: mirrored entry points raise no drift flag"
[ "$(printf '%s\n' "$f41m" | grep -cF 'carries the section')" -eq 2 ] && pass "status.sh: a mirrored section is flagged in every entry point" || fail "status.sh: a mirrored section is flagged in every entry point ($f41m)"
# A fenced example inside the load path is not a section.
printf '# P — Session Bootstrap\n\nRun it:\n\n```\n## not a heading\n```\n\nbash .agent/scripts/status.sh\n' >"$ews/CLAUDE.md"
rm -f "$ews/AGENTS.md"
status_flags "$ews" | grep -qF 'carries the section' && fail "status.sh: a heading inside a fenced block is not a section" || pass "status.sh: a heading inside a fenced block is not a section"

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
grep -qF "checkpoint.sh" "$tpl41f" || missing41="$missing41 checkpoint-call"
[ -z "$missing41" ] && pass "template: the entry point carries its timing and boundary rules" || fail "template: the entry point carries its timing and boundary rules (missing:$missing41)"

# A user turn is not a session boundary, and the gate saying so must precede
# the numbered imperative: a literal reader that meets the first numbered step
# before the gate starts the list and never reaches its exception. This is
# structural prompt coverage. Whether a given model honors it is behavior, and
# behavior is measured by the evals under evals/, not asserted here.
gate41=$(grep -nF 'A new user message does not start a new session.' "$tpl41f" | cut -d: -f1)
steps41=$(grep -nE '^1\. ' "$tpl41f" | head -n 1 | cut -d: -f1)
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
  -o -name 'fixtures.sh' -o -name 'fixture_seed.py' -o -name 'rollup.py' -o -name 'grade.py' 2>/dev/null)
[ -z "$leaked43" ] && pass "evals: init puts nothing from evals/ into a node" || fail "evals: init puts nothing from evals/ into a node ($leaked43)"

# The same on the path that reaches nodes already in the field.
evleak2="$WORK/node-scope-update"
mkdir -p "$evleak2"
make_v6_fixture "$evleak2"
"$NODE" update "$evleak2" >/dev/null 2>&1
leaked43b=$(find "$evleak2" -path '*eval*' -o -name 'spec.json' -o -name 'agents.conf' \
  -o -name 'fixtures.sh' -o -name 'fixture_seed.py' -o -name 'rollup.py' -o -name 'grade.py' 2>/dev/null)
[ -z "$leaked43b" ] && pass "evals: update puts nothing from evals/ into a node" || fail "evals: update puts nothing from evals/ into a node ($leaked43b)"

# A node's scripts directory holds exactly the shipped set and nothing else.
# The eval bench is the newest candidate for arriving there by mistake, but
# the assertion is general: what a node receives is a closed list.
extra43=""
for f43 in "$evleak"/.agent/scripts/*; do
  case "$(basename "$f43")" in
  status.sh | log.sh | memory.sh | docs.sh | links.sh | comments.sh | checkpoint.sh | finish.sh | index.sh | learn.sh | status.conf | log.conf | comments.conf) ;;
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

  # heldout.json is the same well-formedness check, run over the reworded
  # prompt set. Before this, nothing parsed it, checked it for well-formedness,
  # or checked it for id parity with the canonical set at all.
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

  # A held-out set that quietly lost or gained an eval or an assertion would
  # report a pass over a smaller checklist than the one the id implies.
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

  # Every assertion id must carry a kind, so a headline pass rate can never
  # silently lean on an untagged, uncategorized row.
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

  # index.sh ensure prints one path and no content, so a check whose only
  # evidence is a call to it is a defect: it proves nothing about what the
  # session read. Every check names the page or the canonical source instead.
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
else
  fail "evals: spec.json is well-formed and every assertion is joinable (python3 absent)"
  fail "evals: heldout.json is well-formed and every assertion is joinable (python3 absent)"
  fail "evals: both prompt sets carry the same eval and assertion ids (python3 absent)"
  fail "evals: every assertion carries a behavior, conformance, or information kind (python3 absent)"
  fail "evals: a page-read assertion names the page, never the script that built it (python3 absent)"
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

# H4: a fixture build now enforces every premise its evals' prompts assert
# about the built tree. A drifted premise must void the build, not the run.
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

# A generated node arrives with a warm cache — fixtures.sh ran the fresh
# node's own index.sh ensure once after seeding, so the fixture never starts
# cold. This is the plain node-mode case; the four below layer a fault on it.
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

# The learning fixture carries the application code the eight admission
# prompts assume. Both prompt sets' premises must hold on the built tree,
# and its own suite must pass, or the first turn of every eval is spent on
# a red baseline instead of on the behavior under test.
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

# The generated node's canonical record surface is rules/learned/*.md; the
# gitignored, derived rules/learned.md never appears in a generated node's
# diff at all. _learned_delta used to read only the latter, so every
# learned-rule check on a generated node graded a confident false against an
# empty delta. This proves the fix: a synthetic node diff that only touches
# a record under rules/learned/ must still be read as one added rule.
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

# Negative control: a drifted premise must be caught, naming the eval it
# belongs to, not silently graded as if the prompt's claim were still true.
sed -i.bak "s/amountMino:/amountMinor:/" "$evdoc/src/client.ts" && rm -f "$evdoc/src/client.ts.bak"
premfail42=$("$evroot/fixture_seed.py" check-premises "$evroot/spec.json" ts-service-with-doc "$evdoc" 2>&1)
premrc42=$?
[ "$premrc42" -eq 2 ] && printf '%s\n' "$premfail42" | grep -q 'routing-scales' \
  && pass "evals: check-premises catches a drifted premise and names the eval" \
  || fail "evals: check-premises catches a drifted premise and names the eval (rc=$premrc42; $premfail42)"

# The harness-cost arms: the same fixture built without the node, so the
# comparison has a control for "does the always-loaded corpus earn its cost".
# The node moves aside rather than being deleted, so the built arm stays
# inspectable and nothing the agent can reach still carries it.
evbare="$WORK/eval-fixture-bare"
"$evroot/fixtures.sh" ts-service "$evbare" --corpus-dir "$reporoot" --no-harness >/dev/null 2>&1
rc42bare=$?
[ "$rc42bare" -eq 0 ] && [ ! -d "$evbare/.agent" ] \
  && [ -f "$evbare.verifier/scripts/status.sh" ] && [ -f "$evbare.verifier/scripts/comments.sh" ] \
  && pass "evals: --no-harness builds a fixture with no node and the verifier beside it" \
  || fail "evals: --no-harness builds a fixture with no node and the verifier beside it (rc=$rc42bare)"

# .claude/settings.json is an eval control (autoMemoryEnabled:false), not
# harness scaffolding, so it survives the strip in every arm — and the
# fixture must still commit a base for the diff assertions to grade against.
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

# The control arm is only a control if it is an ordinary hand-written file:
# dot-agent vocabulary in it would leak the treatment into the comparison,
# and a command that does not exist would measure the fixture, not the file.
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
    # tampered value (the trusted default, 600, does not); EXCLUDE_RE_EXTRA
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
effort_index = require_pair("-c", 'model_reasoning_effort="medium"')
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

# A PATH-level Bash wrapper pauses the existing capture process boundary.
# All other scripts immediately delegate to the real interpreter. The
# grading boundary is a Python one now that grade.py owns it, so its pause
# and failure injections live in the python3 wrapper below.
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
  while [ ! -e "$FAKE_PHASE_RELEASE" ]; do sleep 0.05; done
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
  while [ ! -e "$FAKE_PHASE_RELEASE" ]; do sleep 0.05; done
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

# run workspace, eval id -> true only for a void run with no derived
# artifact and no grading.json. A void withholds the grade, not the
# evidence: a stage that voided before outputs/ was ever created (a fixture
# build failure) has none, which is fine; a stage that voided after the
# agent ran must still show the raw stream and nothing derived from it.
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

# -- claude: one process per turn, one session across them --
# The earlier shape queued every turn onto one process's stdin and required
# one terminal result per turn; the CLI answers a queue as one prompt with
# one result, so every run of the set's only multi-turn eval voided and the
# Claude side of it was never measured. The fake fails closed on the flags
# that carry the session: turn one must open it with --session-id, every
# later turn must resume that same id, and none of them may ask for a
# session that is not persisted or write into a config dir that is not the
# runner's disposable one.
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
# The disposable config dir is the whole reason the session may be persisted
# at all: nothing may be left behind holding a copy of the operator's login.
multi_home=$(cat "$claude_home_path" 2>/dev/null)
case "$multi_home" in
"${TMPDIR:-/tmp}/dot-agent-claude-home."*) multi_home_prefix=1 ;;
*) multi_home_prefix=0 ;;
esac
[ "$multi_home_prefix" -eq 1 ] && [ ! -e "$multi_home" ] && pass "evals: the disposable claude config dir is system-temporary and removed after the run" || fail "evals: the disposable claude config dir is system-temporary and removed after the run (home=$multi_home)"
retained_cred=$(find "$wsc_multi/iteration-1/eval-bootstrap-once" -name '.credentials.json' -print -quit 2>/dev/null)
[ -z "$retained_cred" ] && pass "evals: copied Claude authentication never enters retained outputs" || fail "evals: copied Claude authentication never enters retained outputs ($retained_cred)"

# -- either arm may open a fresh iteration, so both can be launched at once --
# Requiring the creator to *be* the treatment lost a race that nothing about
# the experiment needs run: the treatment is named explicitly on every arm,
# and a treatment that never produces a run is caught at rollup.
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

# -- run-arm.sh: two arms, one workspace, one log file each --
# Both arms run the same eval ids. A shared logs/<id>.log is a race whose
# loser is overwritten, and the console output of a run is the only place a
# fixture-build or auth diagnostic survives.
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

# A background subagent's completion is a turn the CLI ran for itself, with a
# terminal result of its own. That is not a dropped continuation, and voiding
# it cost the one eval that exercises grooming its whole treatment cell.
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

# ... and an injected result must not stand in for a turn that never came back.
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

# A harness-free arm has no .agent/ anywhere under the fixture, and four
# capture paths used to assume one: the verifier snapshot, the status.conf
# restore, the node file listing, and status.sh itself, which refuses a
# rootless tree. Any one of them voids every run in the arm before grading,
# so the control would silently measure nothing.
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
[ -f "$rundir_fail/outputs/agent-stdout.txt" ] && [ ! -e "$rundir_fail/outputs/diff.patch" ] && [ ! -e "$rundir_fail/grading.json" ] \
  && pass "evals: a void run keeps the raw stream and discards derived outputs" \
  || fail "evals: a void run keeps the raw stream and discards derived outputs"

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

# --index-mode inherits the harness field's own drift check for free: the
# first run into $wsc_drift above locked index_mode (manual, the default)
# into every arm entry already recorded there, so asking for generated now
# is exactly the same shape of drift as a moved model or effort.
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
# The "one per turn" count above only means something while the fixture still
# announces each command twice, the way the live CLI does.
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
    FAKE_GRADE_PATH="$evroot/grade.py" FAKE_PHASE_READY="$phase_ready" \
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
  && [ -f "$cancel_rundir/outputs/agent-stdout.txt" ] \
  && [ ! -e "$cancel_rundir/outputs/diff.patch" ] \
  && [ ! -e "$cancel_rundir/grading.json" ]; then
  pass "evals: cancellation retains void metadata, keeps the raw stream and discards derived outputs"
else
  fail "evals: cancellation retains void metadata, keeps the raw stream and discards derived outputs"
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
  && [ -f "$timeout_rundir/outputs/agent-stdout.txt" ] \
  && [ ! -e "$timeout_rundir/outputs/diff.patch" ] \
  && [ ! -e "$timeout_rundir/grading.json" ]; then
  pass "evals: timeout retains void metadata, keeps the raw stream and discards derived outputs"
else
  fail "evals: timeout retains void metadata, keeps the raw stream and discards derived outputs"
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
 {"id":"g/nodeprefix","concept":"c","class":"artifact","grade":"auto","check":"node_file_changed 'memory/x.md'"},
 {"id":"g/human","concept":"c","class":"artifact","grade":"manual"}]}
EOF
# A created file and an appended one, so "added" cannot be inferred from
# "has no removed lines" — the defect that read an append as a creation.
printf -- '--- /dev/null\n+++ b/src/new.ts\n+const a = 1\n' >"$gd/outputs/diff.patch"
# The node diff is generated, not hand-written: a hand-written pin is how the
# `.agent/` prefix run.sh actually emits went unnoticed for a whole run.
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
"$evroot/grade.py" "$gd" "$gd/snap.json" >/dev/null 2>&1
g42=$(python3 -c '
import json,sys
r = {x["id"]: x for x in json.load(open(sys.argv[1]))["results"]}
bad = []
if not r["g/new"]["passed"]: bad.append("new-file-not-counted")
if not r["g/append"]["passed"]: bad.append("append-read-as-creation")
if not r["g/order"]["passed"]: bad.append("trace-order")
if not r["g/absent"]["passed"]: bad.append("tree-absence")
if r["g/missing"]["passed"]: bad.append("missing-artifact-passed-by-default")
if not r["g/nodeprefix"]["passed"]: bad.append("node-diff-prefix-not-stripped")
if r["g/human"]["passed"] is not None: bad.append("manual-was-auto-graded")
print(" ".join(bad))' "$gd/grading.json" 2>&1)
[ -z "$g42" ] && pass "evals: the grader evaluates its check language and fails closed on a missing artifact" || fail "evals: the grader evaluates its check language and fails closed on a missing artifact ($g42)"

# H3: a test file beside the change is the change done properly, not a
# second module — product_modules_added must not count it.
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

# H2: output_claims reads the negation around a forbidden phrase, so a
# refusal that names the phrase is not misread as the failure it forbids.
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

# Trace calls are controller-owned evidence.  In particular, ordering cannot
# infer a missing second call, malformed records cannot be searched, and
# result/non-call records cannot stand in for a tool call.
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

# H10: a trace root can be spelled either side of macOS's /tmp <-> /private/tmp
# alias. normalize_text matches literally, so a command string naming the
# fixture through the alias run.sh did *not* pass in went unstripped.
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

# H13: usage/cost is read from the canonical agent stdout, one pass, for
# either adapter's shape. A field the stream never reported is null, never
# 0, and an older CLI's stream with no usage block at all must not void.
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

# The void detector counts turn boundaries, and the CLI runs turns of its own:
# a background subagent's completion comes back to the main loop as a fresh
# turn with its own terminal result, marked origin.kind "task-notification"
# (claude 2.1.245). Counting those voided a grooming run that had succeeded.
# The one-sided rule stays: fewer results than turns sent is still a crash.
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

# The rollup fails closed on records that cannot support a delta. An id set
# that disagrees with its snapshot silently drops rows; an arm token inside a
# grading record means the grader could see the condition. Either one makes
# the number wrong rather than absent, which is the failure this suite exists
# to catch everywhere else.
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

# The node-mode design names its control arm `manual`, and every grading
# record carries the schema field "grade": "manual"|"auto". The blind guard
# used to read that field as the arm name leaking and voided every rollup
# of the design; the calibration run of 2026-09-20 could not be rolled up
# at all. The schema field is not a leak.
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

# ... and the field that is the arm name outright, whatever it is called.
printf '{"arm":"treat","results":[{"id":"a1","passed":true,"evidence":"q"},{"id":"a2","passed":true,"evidence":"r"}]}\n' >"$evr/eval-demo/r1/grading.json"
out42cv=$("$evroot/rollup.py" "$evr" 2>&1); rc42cv=$?
[ "$rc42cv" -eq 2 ] && printf '%s\n' "$out42cv" | grep -q 'whole value' && pass "evals: rollup refuses a grading record whose field value is an arm name" || fail "evals: rollup refuses a grading record whose field value is an arm name (rc=$rc42cv; $out42cv)"

# The guard must not tax the vocabulary of the thing being measured. An arm
# called what it is — `node`, `generic`, `merged` — collides with words the
# evidence text uses about the corpus, and a bare substring match made a real
# run unrollupable until its arms were relabelled. Evidence that merely uses
# the word is not a leak; the arm being named as the condition still is.
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

# H12: --auto-only previews auto-graded assertions without a fatal error on a
# manual one still ungraded, and never writes rollup.json for a preview.
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

# H6: --exclude-eval drops one eval directory entirely and records the
# exclusion so a partial rollup can never pass as complete.
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

# H13: cost coverage is judged per field. One run missing a usage block
# entirely makes every field "unavailable", but never fails the rollup —
# unlike duration, missing cost is not fatal.
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

# ---- 44b. rollup.py: NaN/Infinity durations, an absent "passed" key, and
#          all-or-nothing duration-reporting symmetry ----
# A duration validated only by `value < 0` lets NaN and Infinity through —
# both compare False to 0 — and rollup.json then ends up with a literal
# NaN/Infinity token and exit 0. Indexing r["passed"] before the
# ungraded-is-None guard raises an uncaught KeyError, not a die(), on a
# result missing the key outright, breaking the "exits 2, never a
# traceback" contract this suite checks everywhere else. And a duration
# field recorded for only some runs used to report only those runs,
# silently hiding the other arm's missing instrumentation.
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

# Lower-priority die() paths flagged as untested but otherwise reachable.
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

# ---- 44c. evals/*.py: stdout/stderr survive single-byte locales ----
# Every evals/*.py entry point now reconfigures stdout/stderr to UTF-8 with
# errors="backslashreplace" before printing anything. Before that fix,
# --help raised UnicodeEncodeError under LC_ALL=en_US.ISO8859-1 in
# contamination.py, fixture_seed.py, pooled.py and triage.py (their
# docstrings carry an em dash), and rollup.py crashed the same way printing
# its regression bucket and its --auto-only preview. Covered here for all
# seven files: --help, a success path, an empty-input path, and an error
# path, under LC_ALL=C (every runner has it) and under en_US.ISO8859-1,
# guarded per the locale check at scripts/test.sh:1894 because the Ubuntu CI
# image does not carry it and the macOS image does.
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

# fixture_seed.py's fill-contract rewrites in place, so its input is
# (re)written fresh inside evloc_checks below rather than once here.

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
# turn, at most one (identity-matched) on a resume, and a command item that
# never carries the command it ran. A second lifecycle event for a call is
# not a violation — the live CLI emits one — so what is rejected here is a
# shape trace extraction could not read, not a shape it ignores. --
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

# Corrected against codex 0.153.1, which reports a file change on starting it
# as well as on finishing it. An extra lifecycle event for one call is not a
# violation: the run must proceed, and the call must still appear once.
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

# ---- 46. the completion-time gate is described accurately, not denied ----
# F10b: README.md used to end its load-path paragraph with "There is no
# completion-time gate," which was false — checkpoint.sh withholds the
# session-log entry on a standing flag or a status check that failed to run
# cleanly. These checks pin the mechanism facts and the retired phrase: the
# anchor check requires status.sh to appear on the SAME README line that
# names checkpoint.sh (not merely somewhere across the union of all
# checkpoint.sh-mentioning lines, which a stray "status.sh" on an unrelated
# line could satisfy on its own), and requires a GROOM:/REPAIR:/INDEX: flag
# to appear in the part of that line AFTER the checkpoint.sh mention
# specifically — that line's opening sentences name the flags for an
# unrelated reason (what the load-time status check prints), so a bare
# same-line check stays satisfied even after the checkpoint.sh-describing
# clause's own flag mention is cut; anchoring to text after checkpoint.sh
# closes that gap. The script check anchors each fail-closed branch to its
# own distinguishing message text rather than a floating count that
# unrelated code (the comment-gate branches also say "No log entry
# written.") could keep satisfied after one branch is deleted.

# -- the retired claim does not return anywhere it was cut from --
stale_hits=$(grep -rIn -- "no completion-time gate" \
  "$reporoot/README.md" "$reporoot/operating-model.md" \
  "$reporoot/presets" "$reporoot/templates" "$reporoot/tools" 2>/dev/null)
if [ -z "$stale_hits" ]; then
  pass "docs: 'no completion-time gate' does not appear in README.md, operating-model.md, presets/, templates/, or tools/"
else
  fail "docs: 'no completion-time gate' does not appear in README.md, operating-model.md, presets/, templates/, or tools/ (found: $(printf '%s' "$stale_hits" | head -n1))"
fi

# -- a single README line naming checkpoint.sh also names status.sh, and
#    names a flag prefix in the text that follows the checkpoint.sh mention
#    itself --
checkpointsh_anchor_ok=0
while IFS= read -r line; do
  case "$line" in
  *checkpoint.sh*status.sh*) ;;
  *status.sh*checkpoint.sh*) ;;
  *) continue ;;
  esac
  after_checkpointsh=${line#*checkpoint.sh}
  case "$after_checkpointsh" in
  *GROOM:* | *REPAIR:* | *INDEX:*) checkpointsh_anchor_ok=1 ;;
  esac
done < <(grep -F "checkpoint.sh" "$reporoot/README.md")
if [ "$checkpointsh_anchor_ok" -eq 1 ]; then
  pass "README.md: a checkpoint.sh line also names status.sh, with a GROOM:/REPAIR:/INDEX: flag named after the checkpoint.sh mention"
else
  fail "README.md: a checkpoint.sh line also names status.sh, with a GROOM:/REPAIR:/INDEX: flag named after the checkpoint.sh mention"
fi

# -- checkpoint.sh still implements both fail-closed branches, each by its own message --
flagstands_ok=0
grep -qF "the flags above are this session's to handle" "$reporoot/scripts/checkpoint.sh" && flagstands_ok=1
statusrc_ok=0
grep -qF "status.sh rc=" "$reporoot/scripts/checkpoint.sh" && statusrc_ok=1
if [ "$flagstands_ok" -eq 1 ] && [ "$statusrc_ok" -eq 1 ]; then
  pass "scripts/checkpoint.sh: both fail-closed branches (a standing flag, a status check that failed to run cleanly) are present"
else
  fail "scripts/checkpoint.sh: both fail-closed branches (a standing flag, a status check that failed to run cleanly) are present (flagstands_ok=$flagstands_ok statusrc_ok=$statusrc_ok)"
fi

# ---- 47. the manifest version example matches the version node.sh stamps ----
# F10c: operating-model.md's example node manifest is a reference copy a
# reader is meant to recognize on their own purpose.md. It is not generated
# from node.sh's TARGET_VERSION, so nothing stops the two from drifting —
# exactly what happened before this check: the example read "6.1" while
# node.sh stamped "6.2". Extract TARGET_VERSION from node.sh at test time
# (never hard-code it here — hard-coding on both sides would defeat the
# point of the check) and compare it against every quoted `version: "…"`
# line in operating-model.md's manifest examples. An empty extraction or a
# document with no `version: "…"` line at all is drift too and must fail,
# not pass vacuously.
node_target_version=$(grep -m1 '^TARGET_VERSION="' "$reporoot/scripts/node.sh" | sed -e 's/^TARGET_VERSION="//' -e 's/"$//')
if [ -z "$node_target_version" ]; then
  fail "scripts/node.sh: TARGET_VERSION could not be extracted (expected a line matching TARGET_VERSION=\"…\")"
else
  doc_versions=$(grep -o 'version: "[^"]*"' "$reporoot/operating-model.md" | sed -e 's/^version: "//' -e 's/"$//')
  if [ -z "$doc_versions" ]; then
    fail "operating-model.md: no version: \"…\" manifest example found (node.sh TARGET_VERSION=\"$node_target_version\")"
  else
    mismatch=""
    while IFS= read -r doc_version; do
      [ -n "$doc_version" ] || continue
      if [ "$doc_version" != "$node_target_version" ]; then
        mismatch="$doc_version"
        break
      fi
    done <<EOF
$doc_versions
EOF
    if [ -z "$mismatch" ]; then
      pass "operating-model.md: every version: \"…\" manifest example matches scripts/node.sh's TARGET_VERSION (\"$node_target_version\")"
    else
      fail "operating-model.md: version: \"$mismatch\" disagrees with scripts/node.sh's TARGET_VERSION=\"$node_target_version\""
    fi
  fi
fi

# ---- 48. routing guidance names architecture.md, and only architecture.md ----
# F10d: the Context loading bullet used to fall back to "the entry point's
# doc index" when architecture.md had no routing table — a mechanism that
# was never built. templates/entry-point.md's step 3 has always pointed at
# architecture.md alone; F6b made the routing table required, so the
# fallback was wrong twice over. Check one pins every routing-guidance file
# to the one routing source that ships. Check two retires the vocabulary
# itself: "doc index" must not survive anywhere routing is described, but
# the bare word "index" is legitimate (memory.md's own index is named two
# lines below the fixed bullet) and must not trip the check.
routing_files48="$reporoot/templates/entry-point.md $reporoot/templates/entry-point-generated.md"
for p48 in "$reporoot"/presets/*.md; do
  grep -qi "routing" "$p48" && routing_files48="$routing_files48 $p48"
done
# For a file that carries its own routing-clause marker ("Routing:" in
# templates/entry-point.md, "Pick area docs" in the preset that has one),
# architecture.md must be named AFTER that marker on the SAME line — not
# merely present somewhere in the file, which a stray mention in the
# unrelated docs/ paragraph (every preset has one) would keep satisfied even
# after the routing clause itself regresses into an if/otherwise fallback
# that names architecture.md only before the marker. This mirrors section
# 46's after-marker anchoring. A file with no such marker line is judged on
# file-wide presence, same as before — there is no clause to anchor to.
missing48=""
for f48 in $routing_files48; do
  if grep -qiE "routing:|pick area docs" "$f48"; then
    ok48=0
    while IFS= read -r line48; do
      low48=$(printf '%s' "$line48" | tr '[:upper:]' '[:lower:]')
      case "$low48" in
      *routing:*) after48=${low48#*routing:} ;;
      *"pick area docs"*) after48=${low48#*"pick area docs"} ;;
      *) continue ;;
      esac
      case "$after48" in
      *architecture.md*) ok48=1 ;;
      esac
    done < <(grep -niE "routing:|pick area docs" "$f48")
    [ "$ok48" -eq 1 ] || missing48="$missing48 $f48"
  else
    grep -qF "architecture.md" "$f48" || missing48="$missing48 $f48"
  fi
done
[ -z "$missing48" ] && pass "routing guidance: every routing-aware file names architecture.md after its routing marker" || fail "routing guidance: architecture.md not named after the routing marker in:$missing48"

phrase_hits48=""
for f48 in "$reporoot/templates/entry-point.md" "$reporoot/templates/entry-point-generated.md" "$reporoot/README.md" "$reporoot/operating-model.md" "$reporoot"/presets/*.md; do
  [ -f "$f48" ] || continue
  hit48=$(grep -n "doc index" "$f48") && phrase_hits48="$phrase_hits48
$f48: $hit48"
done
[ -z "$phrase_hits48" ] && pass "routing guidance: the retired phrase \"doc index\" appears nowhere" || fail "routing guidance: retired phrase \"doc index\" found:$phrase_hits48"

# ---- 41. index.sh: canonical Markdown metadata grammar (parser fixtures) ----
# Pinned before the rendering tests below build on it. A rule record's full
# body renders verbatim behind a Source: pointer; a route record's title
# and hook come from its first "# " heading and first "Read when:" comment,
# with documented fallbacks when either is absent.
g41="$WORK/g41"
mkdir -p "$g41/.agent/rules" "$g41/.agent/docs"
printf '# Rule Title\nLine one.\nLine two.\n' >"$g41/.agent/rules/r.md"
printf '# Doc With Hook\n<!-- Read when: working on billing -->\nBody.\n' >"$g41/.agent/docs/hooked.md"
printf 'No heading here.\n<!-- Read when: no title case -->\n' >"$g41/.agent/docs/notitle.md"
printf '# Doc Without Hook\nJust body, no hook comment.\n' >"$g41/.agent/docs/nohook.md"
printf '# Linked Rule\nSee [sibling](other.md) and [abs](/etc/hosts) and [ext](https://example.com/page) and [titled](other.md "See the other").\n' >"$g41/.agent/rules/linked.md"
printf '# Other\nOther content.\n' >"$g41/.agent/rules/other.md"
mkdir -p "$g41/.agent/rules/sub"
printf '# Nested Rule\nSee [alpha doc](../../docs/hooked.md) for context.\n' >"$g41/.agent/rules/sub/nested.md"
"$IDXSH" ensure --root "$g41" >"$WORK/g41.out" 2>"$WORK/g41.err"
g41gen=$(sed -n 2p "$g41/.agent/indexes/current.md")
g41dir="$g41/.agent/indexes/$g41gen"

grep -qF "Source: $g41/.agent/rules/r.md" "$g41dir"/rules-*.md \
  && grep -qF 'Line one.' "$g41dir"/rules-*.md && grep -qF 'Line two.' "$g41dir"/rules-*.md \
  && pass "grammar: a rule record's full body renders verbatim behind its Source: line" \
  || fail "grammar: a rule record's full body renders verbatim behind its Source: line"

grep -qF -- "- Doc With Hook | working on billing | READ: $g41/.agent/docs/hooked.md" "$g41dir"/routes-*.md \
  && pass "grammar: a route record's title and hook come from its heading and Read-when comment" \
  || fail "grammar: a route record's title and hook come from its heading and Read-when comment"

grep -qF "READ: $g41/.agent/docs/notitle.md" "$g41dir"/routes-*.md \
  && grep -qF '.agent/docs/notitle.md | no title case | READ:' "$g41dir"/routes-*.md \
  && pass "grammar: a missing heading falls back to the record's own path as title" \
  || fail "grammar: a missing heading falls back to the record's own path as title"

grep -qF -- '- Doc Without Hook | (no hook) | READ:' "$g41dir"/routes-*.md \
  && pass "grammar: a missing Read-when comment renders as (no hook)" \
  || fail "grammar: a missing Read-when comment renders as (no hook)"

grep -qF -- '[abs](/etc/hosts)' "$g41dir"/rules-*.md \
  && pass "links: an absolute-path link is left unmodified" \
  || fail "links: an absolute-path link is left unmodified"

grep -qF -- '[ext](https://example.com/page)' "$g41dir"/rules-*.md \
  && pass "links: a scheme URL link is left unmodified" \
  || fail "links: a scheme URL link is left unmodified"

g41sibling=$(grep -ohE '\[sibling\]\([^)]*\)' "$g41dir"/rules-*.md | head -1 | sed -E 's/^\[sibling\]\(([^)]*)\)$/\1/')
[ -n "$g41sibling" ] && [ -f "$g41sibling" ] && [ "$g41sibling" = "$g41/.agent/rules/other.md" ] \
  && pass "links: a relative link between two rule records rewrites to a path that resolves to the original sibling" \
  || fail "links: a relative link between two rule records rewrites to a path that resolves to the original sibling"

g41nested=$(grep -ohE '\[alpha doc\]\([^)]*\)' "$g41dir"/rules-*.md | head -1 | sed -E 's/^\[alpha doc\]\(([^)]*)\)$/\1/')
[ -n "$g41nested" ] && [ -f "$g41nested" ] && [ "$g41nested" = "$g41/.agent/docs/hooked.md" ] \
  && pass "links: a relative link from a nested rule up into .agent/docs/ resolves to the original doc" \
  || fail "links: a relative link from a nested rule up into .agent/docs/ resolves to the original doc"

g41titled=$(grep -ohE '\[titled\]\(.*\)' "$g41dir"/rules-*.md | head -1 | sed -E 's/^\[titled\]\((.*)\)$/\1/')
g41titledpath=$(printf '%s\n' "$g41titled" | sed -E 's/ "[^"]*"$//')
[ -n "$g41titledpath" ] && [ -f "$g41titledpath" ] && [ "$g41titledpath" = "$g41/.agent/rules/other.md" ] \
  && printf '%s\n' "$g41titled" | grep -qF '"See the other"' \
  && pass "links: a titled relative link rewrites the path and preserves the title" \
  || fail "links: a titled relative link rewrites the path and preserves the title ($g41titled)"

# ---- 42. index.sh: initial build, then a warm hit touches nothing ----
i42="$WORK/i42"
make_index_fixture "$i42"
"$IDXSH" ensure --root "$i42" >"$WORK/i42.out1" 2>"$WORK/i42.err1"
grep -q '^BUILT$' "$WORK/i42.err1" && pass "ensure: a missing index is an initial BUILT, not an error" \
  || fail "ensure: a missing index is an initial BUILT, not an error"
[ "$(cat "$WORK/i42.out1")" = "$i42/.agent/indexes/current.md" ] \
  && pass "ensure: stdout is the absolute entry path" || fail "ensure: stdout is the absolute entry path"
i42old=$(cat "$i42/.agent/indexes/current.md")
idx_snapshot "$i42/.agent/indexes" >"$WORK/i42.before"
"$IDXSH" ensure --root "$i42" >"$WORK/i42.out2" 2>"$WORK/i42.err2"
idx_snapshot "$i42/.agent/indexes" >"$WORK/i42.after"
grep -q '^HIT$' "$WORK/i42.err2" && pass "ensure: an unchanged tree is a warm HIT" || fail "ensure: an unchanged tree is a warm HIT"
[ "$i42old" = "$(cat "$i42/.agent/indexes/current.md")" ] && pass "ensure: a warm hit republishes nothing" || fail "ensure: a warm hit republishes nothing"
cmp -s "$WORK/i42.before" "$WORK/i42.after" && pass "ensure: a warm hit writes zero bytes and touches no mtime" \
  || fail "ensure: a warm hit writes zero bytes and touches no mtime"

# ---- 43. index.sh: changed inputs invalidate the cache ----
i43="$WORK/i43"
make_index_fixture "$i43"
"$IDXSH" ensure --root "$i43" >/dev/null 2>&1
i43old=$(cat "$i43/.agent/indexes/current.md")

printf '# Added\nNew record.\n' >"$i43/.agent/docs/added.md"
"$IDXSH" ensure --root "$i43" >/dev/null 2>"$WORK/i43.a.err"
i43new=$(cat "$i43/.agent/indexes/current.md")
[ "$i43old" != "$i43new" ] && grep -q '^BUILT$' "$WORK/i43.a.err" && pass "invalidation: a source addition rebuilds" \
  || fail "invalidation: a source addition rebuilds"
i43old="$i43new"

printf 'Uncommitted change.\n' >>"$i43/.agent/docs/architecture.md"
"$IDXSH" ensure --root "$i43" >/dev/null 2>&1
i43new=$(cat "$i43/.agent/indexes/current.md")
[ "$i43old" != "$i43new" ] && pass "invalidation: an uncommitted content change rebuilds" \
  || fail "invalidation: an uncommitted content change rebuilds"
i43old="$i43new"

touch -r "$i43/.agent/docs/architecture.md" "$WORK/i43.stamp"
sed 's/alpha/omega/' "$i43/.agent/docs/architecture.md" >"$WORK/i43.edit"
cat "$WORK/i43.edit" >"$i43/.agent/docs/architecture.md"
touch -r "$WORK/i43.stamp" "$i43/.agent/docs/architecture.md"
"$IDXSH" ensure --root "$i43" >/dev/null 2>&1
i43new=$(cat "$i43/.agent/indexes/current.md")
[ "$i43old" != "$i43new" ] && pass "invalidation: a same-length, timestamp-preserving edit rebuilds" \
  || fail "invalidation: a same-length, timestamp-preserving edit rebuilds"
i43old="$i43new"

mv "$i43/.agent/docs/added.md" "$i43/.agent/docs/renamed.md"
"$IDXSH" ensure --root "$i43" >/dev/null 2>&1
i43new=$(cat "$i43/.agent/indexes/current.md")
[ "$i43old" != "$i43new" ] && pass "invalidation: a rename rebuilds" || fail "invalidation: a rename rebuilds"
i43old="$i43new"

rm "$i43/.agent/docs/renamed.md"
"$IDXSH" ensure --root "$i43" >/dev/null 2>&1
i43new=$(cat "$i43/.agent/indexes/current.md")
[ "$i43old" != "$i43new" ] && pass "invalidation: a deletion rebuilds" || fail "invalidation: a deletion rebuilds"

# ---- 44. index.sh: damaged pages, missing pages, and entry tampering ----
i44="$WORK/i44"
make_index_fixture "$i44"
"$IDXSH" ensure --root "$i44" >/dev/null 2>&1
i44gen=$(sed -n 2p "$i44/.agent/indexes/current.md")
printf 'damage\n' >>"$i44/.agent/indexes/$i44gen"/routes-1.md
"$IDXSH" ensure --root "$i44" >/dev/null 2>"$WORK/i44.d.err"
grep -q '^BUILT$' "$WORK/i44.d.err" && pass "verification: a damaged page forces a rebuild" \
  || fail "verification: a damaged page forces a rebuild"

i44gen=$(sed -n 2p "$i44/.agent/indexes/current.md")
rm "$i44/.agent/indexes/$i44gen"/rules-1.md
"$IDXSH" ensure --root "$i44" >/dev/null 2>"$WORK/i44.m.err"
grep -q '^BUILT$' "$WORK/i44.m.err" && pass "verification: a missing page forces a rebuild" \
  || fail "verification: a missing page forces a rebuild"

printf 'unexpected instruction\n' >>"$i44/.agent/indexes/current.md"
"$IDXSH" ensure --root "$i44" >/dev/null 2>"$WORK/i44.e.err"
grep -q '^BUILT$' "$WORK/i44.e.err" && pass "verification: tampering with the entry itself forces a rebuild" \
  || fail "verification: tampering with the entry itself forces a rebuild"

# ---- 45. index.sh: generator and render-configuration invalidation, and
# deterministic rendering of equivalent inputs ----
i45="$WORK/i45"
make_index_fixture "$i45"
"$IDXSH" ensure --root "$i45" >/dev/null 2>&1
i45old=$(cat "$i45/.agent/indexes/current.md")
cp "$IDXSH" "$WORK/i45-index.sh"
printf '\n# a generator revision\n' >>"$WORK/i45-index.sh"
chmod +x "$WORK/i45-index.sh"
"$WORK/i45-index.sh" ensure --root "$i45" >/dev/null 2>"$WORK/i45.g.err"
i45new=$(cat "$i45/.agent/indexes/current.md")
[ "$i45old" != "$i45new" ] && grep -q '^BUILT$' "$WORK/i45.g.err" \
  && pass "invalidation: a changed generator rebuilds" || fail "invalidation: a changed generator rebuilds"

i45oldgen=$(sed -n 2p "$i45/.agent/indexes/current.md")
"$IDXSH" ensure --root "$i45" --budget 4096 >/dev/null 2>"$WORK/i45.b.err"
i45newgen=$(sed -n 2p "$i45/.agent/indexes/current.md")
[ "$i45oldgen" != "$i45newgen" ] && grep -q '^BUILT$' "$WORK/i45.b.err" \
  && pass "invalidation: a changed budget rebuilds" || fail "invalidation: a changed budget rebuilds"
cmp -s "$i45/.agent/indexes/$i45oldgen"/rules-1.md "$i45/.agent/indexes/$i45newgen"/rules-1.md \
  && cmp -s "$i45/.agent/indexes/$i45oldgen"/routes-1.md "$i45/.agent/indexes/$i45newgen"/routes-1.md \
  && pass "rendering: equivalent inputs and budget render byte-identical pages" \
  || fail "rendering: equivalent inputs and budget render byte-identical pages"

# ---- 46. index.sh: check reports MISSING/STALE without ever writing,
# then FRESH once ensure has published ----
i46="$WORK/i46"
make_index_fixture "$i46"
i46out=$("$IDXSH" check --root "$i46" 2>"$WORK/i46.err1"); i46rc=$?
[ "$i46rc" -eq 1 ] && [ "$i46out" = STALE ] && [ ! -e "$i46/.agent/indexes" ] \
  && pass "check: no index yet is STALE and creates nothing" || fail "check: no index yet is STALE and creates nothing"
"$IDXSH" ensure --root "$i46" >/dev/null 2>&1
i46out=$("$IDXSH" check --root "$i46" 2>"$WORK/i46.err2"); i46rc=$?
[ "$i46rc" -eq 0 ] && [ "$i46out" = FRESH ] && pass "check: a valid cache is FRESH at exit 0" \
  || fail "check: a valid cache is FRESH at exit 0"
printf 'more\n' >>"$i46/.agent/docs/architecture.md"
i46out=$("$IDXSH" check --root "$i46" 2>"$WORK/i46.err3"); i46rc=$?
[ "$i46rc" -eq 1 ] && [ "$i46out" = STALE ] && pass "check: a changed source is STALE at exit 1" \
  || fail "check: a changed source is STALE at exit 1"

# ---- 47. index.sh: rejected records, oversized records, and entry overflow
# fall back explicitly and never truncate ----
i47sym="$WORK/i47sym"
make_index_fixture "$i47sym"
ln -s architecture.md "$i47sym/.agent/docs/link.md"
"$IDXSH" ensure --root "$i47sym" >/dev/null 2>"$WORK/i47.sym.err"
grep -q 'FALLBACK:' "$WORK/i47.sym.err" && pass "rejection: a source symlink falls back rather than being indexed" \
  || fail "rejection: a source symlink falls back rather than being indexed"

i47bad="$WORK/i47bad"
make_index_fixture "$i47bad"
printf '# Bad\n' >"$i47bad/.agent/docs/bad name.md"
"$IDXSH" ensure --root "$i47bad" >/dev/null 2>"$WORK/i47.bad.err"
grep -q 'FALLBACK:' "$WORK/i47.bad.err" && pass "rejection: an unsupported filename falls back rather than being indexed" \
  || fail "rejection: an unsupported filename falls back rather than being indexed"

i47big="$WORK/i47big"
mkdir -p "$i47big/.agent/rules"
awk 'BEGIN { for (i = 0; i < 2000; i++) print "long rule line filler text" }' >"$i47big/.agent/rules/large.md"
"$IDXSH" ensure --root "$i47big" --budget 256 >/dev/null 2>"$WORK/i47.big.err"
grep -q 'record exceeds page budget' "$WORK/i47.big.err" && grep -q 'FALLBACK:' "$WORK/i47.big.err" \
  && pass "overflow: a record too large for its own page falls back without truncation" \
  || fail "overflow: a record too large for its own page falls back without truncation"

i47long="$WORK/i47long/$(printf '%0140d' 0)"
mkdir -p "$i47long/.agent/docs"
printf '# A\n' >"$i47long/.agent/docs/a.md"
"$IDXSH" ensure --root "$i47long" >/dev/null 2>&1
cp "$i47long/.agent/indexes/current.md" "$WORK/i47.long-entry"
# One byte under the entry's own measured size, not root length plus an
# assumed constant: the fixed per-entry overhead (fingerprint, generation
# name, tree digest, the READ line's own directory prefix) runs well past
# a guessed +80 on some hosts, and a short TMPDIR prefix (bare /tmp on a
# CI runner vs a longer local one) can then put root-length-plus-80 below
# index.sh's own 256-byte floor, hitting the usage-error path instead of
# the overflow fallback this test means to exercise.
i47priorbytes=$(wc -c <"$WORK/i47.long-entry")
i47smallbudget=$((i47priorbytes - 1))
[ "$i47smallbudget" -ge 256 ] || i47smallbudget=256
"$IDXSH" ensure --root "$i47long" --budget "$i47smallbudget" >/dev/null 2>"$WORK/i47.long.err"
grep -q 'entry exceeds page budget' "$WORK/i47.long.err" && grep -q 'FALLBACK:' "$WORK/i47.long.err" \
  && cmp -s "$WORK/i47.long-entry" "$i47long/.agent/indexes/current.md" \
  && pass "overflow: an entry too large for the budget falls back and preserves the prior publication" \
  || fail "overflow: an entry too large for the budget falls back and preserves the prior publication"

# ---- 48. index.sh: bounded retries on sources that keep changing during
# rendering ----
i48="$WORK/i48"
make_index_fixture "$i48"
"$IDXSH" ensure --root "$i48" >/dev/null 2>&1
real_awk=$(command -v awk)
mkdir -p "$WORK/i48bin"
cat >"$WORK/i48bin/awk" <<WRAPPER
#!/bin/sh
"$real_awk" "\$@"
rc=\$?
case "\$*" in *out=*)
  if [ "\${TEST_MODE:-}" = mutate_once ] && [ ! -f "\$MARKER" ]; then
    : >"\$MARKER"
    printf 'transient\n' >>"\$TARGET"
  elif [ "\${TEST_MODE:-}" = mutate_always ]; then
    printf 'mutation\n' >>"\$TARGET"
  elif [ "\${TEST_MODE:-}" = pause ]; then
    printf ready >"\$GATE"
    n=0
    while [ ! -f "\$GATE.go" ]; do sleep 0.05; n=\$((n + 1)); [ "\$n" -lt 100 ] || break; done
    printf done >"\$GATE.done"
  fi ;;
esac
exit "\$rc"
WRAPPER
chmod +x "$WORK/i48bin/awk"

printf 'stale-before-retry\n' >>"$i48/.agent/docs/architecture.md"
i48old=$(cat "$i48/.agent/indexes/current.md")
rm -f "$WORK/i48.marker"
PATH="$WORK/i48bin:$PATH" TEST_MODE=mutate_once MARKER="$WORK/i48.marker" TARGET="$i48/.agent/docs/architecture.md" \
  "$IDXSH" ensure --root "$i48" >/dev/null 2>"$WORK/i48.once.err"
grep -q '^BUILT$' "$WORK/i48.once.err" && [ "$i48old" != "$(cat "$i48/.agent/indexes/current.md")" ] \
  && pass "retry: a one-time transient mutation during rendering still succeeds via retry" \
  || fail "retry: a one-time transient mutation during rendering still succeeds via retry"

i48old=$(cat "$i48/.agent/indexes/current.md")
printf 'force-stale\n' >>"$i48/.agent/docs/architecture.md"
PATH="$WORK/i48bin:$PATH" TEST_MODE=mutate_always TARGET="$i48/.agent/docs/architecture.md" \
  "$IDXSH" ensure --root "$i48" >/dev/null 2>"$WORK/i48.always.err"; i48rc=$?
[ "$i48rc" -eq 1 ] && grep -q 'exhausted' "$WORK/i48.always.err" \
  && [ "$i48old" = "$(cat "$i48/.agent/indexes/current.md")" ] \
  && pass "retry: sources changing on every attempt exhausts the bound and preserves the prior entry" \
  || fail "retry: sources changing on every attempt exhausts the bound and preserves the prior entry"

# ---- 49. index.sh: concurrent refreshes and a killed writer ----
i49="$WORK/i49"
make_index_fixture "$i49"
"$IDXSH" ensure --root "$i49" >/dev/null 2>&1
i49gen=$(sed -n 2p "$i49/.agent/indexes/current.md")
cp -R "$i49/.agent/indexes/$i49gen" "$WORK/i49-old-generation"
printf 'concurrency\n' >>"$i49/.agent/docs/architecture.md"
i49pids=""
for n in 1 2 3 4; do
  "$IDXSH" ensure --root "$i49" >"$WORK/i49.$n.out" 2>"$WORK/i49.$n.err" &
  i49pids="$i49pids $!"
done
for p in $i49pids; do wait "$p"; done
i49fell_back=""
for n in 1 2 3 4; do grep -q 'FALLBACK:' "$WORK/i49.$n.err" && i49fell_back="$i49fell_back $n"; done
[ -z "$i49fell_back" ] && pass "concurrency: four parallel writers all complete without falling back" \
  || fail "concurrency: four parallel writers all complete without falling back (writer(s):$i49fell_back)"
"$IDXSH" ensure --root "$i49" >/dev/null 2>"$WORK/i49.final.err"
grep -q '^HIT$' "$WORK/i49.final.err" && pass "concurrency: the state after concurrent writers is itself a valid, consistent hit" \
  || fail "concurrency: the state after concurrent writers is itself a valid, consistent hit"
diff -r "$WORK/i49-old-generation" "$i49/.agent/indexes/$i49gen" >/dev/null 2>&1 \
  && pass "concurrency: an old generation a reader already selected is left untouched" \
  || fail "concurrency: an old generation a reader already selected is left untouched"

i49k="$WORK/i49k"
make_index_fixture "$i49k"
"$IDXSH" ensure --root "$i49k" >/dev/null 2>&1
i49kold=$(cat "$i49k/.agent/indexes/current.md")
printf 'crash-trigger\n' >>"$i49k/.agent/docs/architecture.md"
PATH="$WORK/i48bin:$PATH" TEST_MODE=pause GATE="$WORK/i49k.gate" \
  "$IDXSH" ensure --root "$i49k" >"$WORK/i49k.out" 2>"$WORK/i49k.err" &
i49kpid=$!
i49kn=0
while [ ! -f "$WORK/i49k.gate" ]; do sleep 0.05; i49kn=$((i49kn + 1)); [ "$i49kn" -lt 100 ] || break; done
kill -KILL "$i49kpid" 2>/dev/null || true
wait "$i49kpid" 2>/dev/null || true
# The paused awk wrapper is a grandchild of this shell (a child of the now-
# dead index.sh), so killing i49kpid alone leaves it orphaned and running.
# Release it immediately rather than letting it idle for up to its own
# 5-second bound — an orphan still writing into $WORK can otherwise race
# this suite's own end-of-run "rm -rf $WORK" and turn into a spurious
# "Directory not empty".
: >"$WORK/i49k.gate.go"
i49kdn=0
while [ ! -f "$WORK/i49k.gate.done" ]; do sleep 0.05; i49kdn=$((i49kdn + 1)); [ "$i49kdn" -lt 100 ] || break; done
[ "$i49kold" = "$(cat "$i49k/.agent/indexes/current.md")" ] \
  && pass "concurrency: a killed writer publishes nothing and leaves the prior entry readable" \
  || fail "concurrency: a killed writer publishes nothing and leaves the prior entry readable"
"$IDXSH" ensure --root "$i49k" >/dev/null 2>"$WORK/i49k.retry1.err"
"$IDXSH" ensure --root "$i49k" >/dev/null 2>"$WORK/i49k.retry2.err"
grep -q '^BUILT$' "$WORK/i49k.retry1.err" && grep -q '^HIT$' "$WORK/i49k.retry2.err" \
  && pass "concurrency: the next run after a kill rebuilds cleanly with no lock recovery" \
  || fail "concurrency: the next run after a kill rebuilds cleanly with no lock recovery"

# ---- 50. index.sh: bounded cleanup reclaims only old, unreferenced
# generations, never one just published or the one it replaced ----
i50="$WORK/i50"
make_index_fixture "$i50"
"$IDXSH" ensure --root "$i50" >/dev/null 2>&1
i50a=$(sed -n 2p "$i50/.agent/indexes/current.md")
touch -t 202001010000 "$i50/.agent/indexes/$i50a"
printf 'v2\n' >>"$i50/.agent/docs/architecture.md"
INDEX_CLEANUP_AGE_SECONDS=60 "$IDXSH" ensure --root "$i50" >/dev/null 2>&1
i50b=$(sed -n 2p "$i50/.agent/indexes/current.md")
[ -d "$i50/.agent/indexes/$i50a" ] \
  && pass "cleanup: the generation this build replaced is exempt even when old" \
  || fail "cleanup: the generation this build replaced is exempt even when old"
touch -t 202001010000 "$i50/.agent/indexes/$i50b"
printf 'v3\n' >>"$i50/.agent/docs/architecture.md"
INDEX_CLEANUP_AGE_SECONDS=60 "$IDXSH" ensure --root "$i50" >/dev/null 2>&1
i50c=$(sed -n 2p "$i50/.agent/indexes/current.md")
[ ! -d "$i50/.agent/indexes/$i50a" ] && [ -d "$i50/.agent/indexes/$i50b" ] && [ -d "$i50/.agent/indexes/$i50c" ] \
  && pass "cleanup: an old generation two publishes stale is reclaimed once past the age bound" \
  || fail "cleanup: an old generation two publishes stale is reclaimed once past the age bound"

i50f="$WORK/i50f"
make_index_fixture "$i50f"
"$IDXSH" ensure --root "$i50f" >/dev/null 2>&1
i50fa=$(sed -n 2p "$i50f/.agent/indexes/current.md")
printf 'v2\n' >>"$i50f/.agent/docs/architecture.md"
INDEX_CLEANUP_AGE_SECONDS=300 "$IDXSH" ensure --root "$i50f" >/dev/null 2>&1
[ -d "$i50f/.agent/indexes/$i50fa" ] \
  && pass "cleanup: a fresh superseded generation stays within the age bound's grace window" \
  || fail "cleanup: a fresh superseded generation stays within the age bound's grace window"

# ---- 51. index.sh: real branch switches and two linked worktrees ----
i51="$WORK/i51"
make_index_fixture "$i51"
git -C "$i51" init -q
git -C "$i51" config user.name Tester
git -C "$i51" config user.email tester@example.invalid
printf '.agent/indexes/\n' >"$i51/.gitignore"
git -C "$i51" add .
git -C "$i51" commit -qm initial
i51base=$(git -C "$i51" symbolic-ref --short HEAD)
"$IDXSH" ensure --root "$i51" >/dev/null 2>&1
i51old=$(cat "$i51/.agent/indexes/current.md")
git -C "$i51" checkout -qb alternate
printf 'alternate branch content\n' >>"$i51/.agent/docs/architecture.md"
git -C "$i51" commit -qam alternate
"$IDXSH" ensure --root "$i51" >/dev/null 2>&1
[ "$i51old" != "$(cat "$i51/.agent/indexes/current.md")" ] \
  && pass "branch switch: checking out a branch with different content invalidates the cache" \
  || fail "branch switch: checking out a branch with different content invalidates the cache"
git -C "$i51" checkout -q "$i51base"
"$IDXSH" ensure --root "$i51" >/dev/null 2>&1
i51back=$(cat "$i51/.agent/indexes/current.md")
[ "$i51old" != "$i51back" ] \
  && pass "branch switch: returning to the original branch rebuilds a fresh generation" \
  || fail "branch switch: returning to the original branch rebuilds a fresh generation"
[ "$(printf '%s\n' "$i51old" | head -1)" = "$(printf '%s\n' "$i51back" | head -1)" ] \
  && pass "branch switch: the fingerprint itself returns to the original value" \
  || fail "branch switch: the fingerprint itself returns to the original value"

git -C "$i51" worktree add -q "$WORK/i51-wt" alternate
"$IDXSH" ensure --root "$WORK/i51-wt" >/dev/null 2>&1
[ -f "$WORK/i51-wt/.agent/indexes/current.md" ] \
  && pass "worktree: a linked worktree builds its own cache" || fail "worktree: a linked worktree builds its own cache"
cmp -s "$i51/.agent/indexes/current.md" "$WORK/i51-wt/.agent/indexes/current.md" \
  && fail "worktree: the two worktrees' caches are isolated" \
  || pass "worktree: the two worktrees' caches are isolated"
[ -z "$(git -C "$i51" status --porcelain)" ] && [ -z "$(git -C "$WORK/i51-wt" status --porcelain)" ] \
  && pass "worktree: the ignored cache leaves both working trees clean" \
  || fail "worktree: the ignored cache leaves both working trees clean"
git -C "$i51" worktree remove -f "$WORK/i51-wt" >/dev/null 2>&1 || rm -rf "$WORK/i51-wt"

# ---- 52. index.sh: check never writes, under repeated calls ----
i52="$WORK/i52"
make_index_fixture "$i52"
"$IDXSH" ensure --root "$i52" >/dev/null 2>&1
idx_snapshot "$i52/.agent/indexes" >"$WORK/i52.before"
"$IDXSH" check --root "$i52" >/dev/null 2>&1
"$IDXSH" check --root "$i52" >/dev/null 2>&1
idx_snapshot "$i52/.agent/indexes" >"$WORK/i52.after"
cmp -s "$WORK/i52.before" "$WORK/i52.after" && pass "check: repeated calls write zero bytes and touch no mtime" \
  || fail "check: repeated calls write zero bytes and touch no mtime"

# ---- 53. index.sh: usage and the documented exit-status table ----
"$IDXSH" --help >"$WORK/i53.help" 2>&1; i53rc=$?
[ "$i53rc" -eq 0 ] && head -n 1 "$WORK/i53.help" | grep -q '^Usage:$' && grep -qF 'index.sh ensure' "$WORK/i53.help" \
  && pass "usage: --help prints usage at exit 0" || fail "usage: --help prints usage at exit 0"
"$IDXSH" --version >"$WORK/i53.version" 2>&1; i53rc=$?
[ "$i53rc" -eq 0 ] && grep -qF 'index.sh schema' "$WORK/i53.version" \
  && pass "usage: --version prints at exit 0" || fail "usage: --version prints at exit 0"
"$IDXSH" >/dev/null 2>&1; [ "$?" -eq 2 ] && pass "usage: no operation is a usage error (exit 2)" \
  || fail "usage: no operation is a usage error (exit 2)"
"$IDXSH" bogus >/dev/null 2>&1; [ "$?" -eq 2 ] && pass "usage: an unknown operation is a usage error (exit 2)" \
  || fail "usage: an unknown operation is a usage error (exit 2)"
"$IDXSH" ensure --budget 4 >/dev/null 2>&1; [ "$?" -eq 2 ] && pass "usage: a budget outside 256..1000000 is a usage error (exit 2)" \
  || fail "usage: a budget outside 256..1000000 is a usage error (exit 2)"
i53noagent="$WORK/i53noagent"
mkdir -p "$i53noagent"
"$IDXSH" ensure --root "$i53noagent" >/dev/null 2>&1; [ "$?" -eq 2 ] \
  && pass "usage: a root with no .agent/ is a usage error (exit 2)" || fail "usage: a root with no .agent/ is a usage error (exit 2)"
i53="$WORK/i53"
make_index_fixture "$i53"
"$IDXSH" ensure --root "$i53" >/dev/null 2>&1; [ "$?" -eq 0 ] \
  && pass "exit status: ensure BUILT is exit 0" || fail "exit status: ensure BUILT is exit 0"
"$IDXSH" ensure --root "$i53" >/dev/null 2>&1; [ "$?" -eq 0 ] \
  && pass "exit status: ensure HIT is exit 0" || fail "exit status: ensure HIT is exit 0"
"$IDXSH" check --root "$i53" >/dev/null 2>&1; [ "$?" -eq 0 ] \
  && pass "exit status: check FRESH is exit 0" || fail "exit status: check FRESH is exit 0"

# ---- 54. index.sh: every generated entry resolves to the canonical source
# or a complete generated page ----
i54="$WORK/i54"
mkdir -p "$i54/.agent/rules" "$i54/.agent/docs/sub"
printf '# Rule A\nBody A.\n' >"$i54/.agent/rules/a.md"
printf '# Rule B\nBody B.\n' >"$i54/.agent/rules/b.md"
printf '# Doc A\n<!-- Read when: doc a -->\nBody.\n' >"$i54/.agent/docs/a.md"
printf '# Sub Doc\n<!-- Read when: sub area -->\nBody.\n' >"$i54/.agent/docs/sub/s.md"
"$IDXSH" ensure --root "$i54" >/dev/null 2>&1
i54gen=$(sed -n 2p "$i54/.agent/indexes/current.md")
i54dir="$i54/.agent/indexes/$i54gen"
i54bad=""
while IFS= read -r rl; do
  target=${rl#READ: }
  [ -f "$target" ] || i54bad="$i54bad $target"
done < <(grep '^READ:' "$i54/.agent/indexes/current.md")
[ -z "$i54bad" ] && pass "resolution: every entry-file READ line names a file that exists" \
  || fail "resolution: every entry-file READ line names a file that exists ($i54bad)"
i54routebad=""
while IFS= read -r rl; do
  target=${rl##*READ: }
  [ -f "$target" ] || i54routebad="$i54routebad $target"
done < <(grep -h '| READ:' "$i54dir"/routes-*.md)
[ -z "$i54routebad" ] && pass "resolution: every route line's READ pointer resolves to a real canonical source" \
  || fail "resolution: every route line's READ pointer resolves to a real canonical source ($i54routebad)"
i54srcbad=""
for f in "$i54dir"/rules-*.md; do
  src=$(sed -n 's/^Source: //p' "$f" | head -1)
  [ -f "$src" ] || i54srcbad="$i54srcbad $src"
done
[ -z "$i54srcbad" ] && pass "resolution: every rule page's Source: pointer resolves to a real canonical source" \
  || fail "resolution: every rule page's Source: pointer resolves to a real canonical source ($i54srcbad)"
grep -qF 'Body A.' "$i54dir"/rules-*.md && grep -qF 'Body B.' "$i54dir"/rules-*.md \
  && pass "resolution: rule pages are complete — every rule record's body is present" \
  || fail "resolution: rule pages are complete — every rule record's body is present"

# ---- 55. index.sh: the stdout/stderr contract — bounded status only ----
i55="$WORK/i55"
make_index_fixture "$i55"
"$IDXSH" ensure --root "$i55" >"$WORK/i55.out" 2>"$WORK/i55.err"
[ "$(wc -l <"$WORK/i55.out" | tr -d ' ')" -eq 1 ] && [ "$(cat "$WORK/i55.out")" = "$i55/.agent/indexes/current.md" ] \
  && pass "contract: ensure's stdout is exactly one line, the entry path" \
  || fail "contract: ensure's stdout is exactly one line, the entry path"
grep -qi 'Read when\|Project guardrails\|Body text' "$WORK/i55.out" \
  && fail "contract: ensure's stdout never carries rule bodies or routing tables" \
  || pass "contract: ensure's stdout never carries rule bodies or routing tables"
"$IDXSH" check --root "$i55" >"$WORK/i55.check.out" 2>"$WORK/i55.check.err"
[ "$(cat "$WORK/i55.check.out")" = FRESH ] \
  && pass "contract: check's stdout is exactly FRESH or STALE, nothing else" \
  || fail "contract: check's stdout is exactly FRESH or STALE, nothing else"

# ---- 56. indexes manifest field: gitignore across the six mode combinations ----
# indexes: generated adds two gitignore rules under track-shared and
# track-all (.agent/indexes/ and .agent/rules/learned.md); manual and
# ignore-all are untouched from today, learned.md's ignore-or-not follows
# the tracking mode's own allowlist, and .agent/indexes/ is covered by the
# blanket .agent/* pattern in track-shared regardless of the new lines.
gi56_combo() {
  gi56_mode="$1" gi56_idx="$2" gi56_exp_learned="$3" gi56_exp_indexes="$4"
  gi56_dir="$WORK/gi56-$gi56_mode-$gi56_idx"
  mkdir -p "$gi56_dir"
  "$NODE" init --preset software-development --mode "$gi56_mode" --indexes "$gi56_idx" "$gi56_dir" >/dev/null 2>&1
  git -C "$gi56_dir" init -q
  if git -C "$gi56_dir" check-ignore -q .agent/rules/learned.md; then gi56_ign1=1; else gi56_ign1=0; fi
  [ "$gi56_ign1" -eq "$gi56_exp_learned" ] \
    && pass "gitignore $gi56_mode/$gi56_idx: .agent/rules/learned.md ignored=$gi56_exp_learned" \
    || fail "gitignore $gi56_mode/$gi56_idx: .agent/rules/learned.md ignored=$gi56_exp_learned (got $gi56_ign1)"
  if git -C "$gi56_dir" check-ignore -q .agent/indexes/current.md; then gi56_ign2=1; else gi56_ign2=0; fi
  [ "$gi56_ign2" -eq "$gi56_exp_indexes" ] \
    && pass "gitignore $gi56_mode/$gi56_idx: .agent/indexes/ ignored=$gi56_exp_indexes" \
    || fail "gitignore $gi56_mode/$gi56_idx: .agent/indexes/ ignored=$gi56_exp_indexes (got $gi56_ign2)"
}
gi56_combo ignore-all manual 1 1
gi56_combo ignore-all generated 1 1
gi56_combo track-shared manual 0 1
gi56_combo track-shared generated 1 1
gi56_combo track-all manual 0 0
gi56_combo track-all generated 1 1

# ignore-all writes only the blanket .agent/ pattern, which the indexes
# field never touches, so its gitignore stays byte-identical either way.
[ "$(cat "$WORK/gi56-ignore-all-manual/.gitignore" 2>/dev/null)" = "$(cat "$WORK/gi56-ignore-all-generated/.gitignore" 2>/dev/null)" ] \
  && pass "gitignore: ignore-all is unchanged from today whether indexes is manual or generated" \
  || fail "gitignore: ignore-all is unchanged from today whether indexes is manual or generated"
[ ! -e "$WORK/gi56-track-all-manual/.gitignore" ] \
  && pass "gitignore: track-all/manual writes no gitignore, as today" \
  || fail "gitignore: track-all/manual writes no gitignore, as today"

# ---- 56b. $HOME guard: track-all + generated warns instead of silently
# skipping the gitignore lines that indexes: generated would otherwise add ----
gi56home="$WORK/gi56-home-track-all-generated"
mkdir -p "$gi56home"
HOME="$gi56home" "$NODE" init --preset software-development --mode track-all --indexes generated "$gi56home" >"$WORK/gi56home.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] && [ -d "$gi56home/.agent" ] && pass "init at \$HOME, track-all/generated, exits 0 and creates the node" || fail "init at \$HOME, track-all/generated, exits 0 and creates the node"
grep -qF 'skipped gitignore at $HOME' "$WORK/gi56home.out" \
  && pass "init at \$HOME, track-all/generated, warns about the skipped gitignore" \
  || fail "init at \$HOME, track-all/generated, warns about the skipped gitignore"
[ ! -e "$gi56home/.gitignore" ] \
  && pass "init at \$HOME, track-all/generated, still writes no gitignore" \
  || fail "init at \$HOME, track-all/generated, still writes no gitignore"

# track-all + manual at $HOME stays silent, as today — only the generated
# combination gained a warning.
gi56homeman="$WORK/gi56-home-track-all-manual"
mkdir -p "$gi56homeman"
HOME="$gi56homeman" "$NODE" init --preset software-development --mode track-all --indexes manual "$gi56homeman" >"$WORK/gi56homeman.out" 2>&1
grep -qF 'skipped gitignore at $HOME' "$WORK/gi56homeman.out" \
  && fail "init at \$HOME, track-all/manual, stays silent (no warning)" \
  || pass "init at \$HOME, track-all/manual, stays silent (no warning)"

# ---- 57. generated-mode entry point: no heading drift against status.sh ----
gep="$WORK/generated-entry-point"
mkdir -p "$gep"
"$NODE" init --preset software-development --mode track-all --indexes generated "$gep" >/dev/null 2>&1
finish_bootstrap "$gep"
cp "$reporoot/templates/entry-point-generated.md" "$gep/CLAUDE.md"
cp "$reporoot/templates/entry-point-generated.md" "$gep/AGENTS.md"
gep_flags=$(status_flags "$gep")
[ -z "$gep_flags" ] \
  && pass "generated-mode entry point: templates/entry-point-generated.md draws no status.sh finding" \
  || fail "generated-mode entry point: templates/entry-point-generated.md draws no status.sh finding ($gep_flags)"

# A mismatched pairing (generated template in one file, manual in the
# other) is real drift and must still be caught, same as any other mirror
# mismatch — the two templates are not interchangeable within one node.
cp "$reporoot/templates/entry-point.md" "$gep/AGENTS.md"
gep_flags2=$(status_flags "$gep")
printf '%s\n' "$gep_flags2" | grep -qF 'REPAIR: AGENTS.md differs from CLAUDE.md' \
  && pass "generated-mode entry point: pairing it with the manual template draws a drift REPAIR" \
  || fail "generated-mode entry point: pairing it with the manual template draws a drift REPAIR ($gep_flags2)"

# ---- 58. index.sh install wiring survives a fresh clone and a fresh
#          worktree of a track-shared node ----
i58src="$WORK/i58-source"
mkdir -p "$i58src"
"$NODE" init --preset software-development --mode track-shared --indexes generated "$i58src" >/dev/null 2>&1
git -C "$i58src" init -q
git -C "$i58src" config user.name Tester
git -C "$i58src" config user.email tester@example.invalid
git -C "$i58src" add -A
git -C "$i58src" commit -qm bootstrap
i58base=$(git -C "$i58src" symbolic-ref --short HEAD)

# Clone: track-shared gitignores .agent/scripts/, so the clone starts
# without index.sh.
i58clone="$WORK/i58-clone"
git clone -q "$i58src" "$i58clone"
[ ! -e "$i58clone/.agent/scripts/index.sh" ] \
  && pass "clone: a fresh clone of a track-shared node starts without index.sh (gitignored)" \
  || fail "clone: a fresh clone of a track-shared node starts without index.sh (gitignored)"
"$NODE" update "$i58clone" >"$WORK/i58-clone-update.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "clone: node.sh update exits 0" || fail "clone: node.sh update exits 0 (rc=$rc)"
[ -x "$i58clone/.agent/scripts/index.sh" ] \
  && pass "clone: node.sh update obtains index.sh" \
  || fail "clone: node.sh update obtains index.sh"
"$i58clone/.agent/scripts/index.sh" ensure --root "$i58clone" >"$WORK/i58-clone-ensure.out" 2>"$WORK/i58-clone-ensure.err"
rc=$?
[ "$rc" -eq 0 ] && [ -f "$i58clone/.agent/indexes/current.md" ] \
  && pass "clone: index.sh ensure succeeds once the indexer is present" \
  || fail "clone: index.sh ensure succeeds once the indexer is present (rc=$rc, err=$(cat "$WORK/i58-clone-ensure.err"))"

# Worktree: a second working tree off the same source repo shares the
# gitignore, so it starts in the same missing-scripts state as the clone.
i58wt="$WORK/i58-worktree"
git -C "$i58src" worktree add -q -b i58-branch "$i58wt" "$i58base"
[ ! -e "$i58wt/.agent/scripts/index.sh" ] \
  && pass "worktree: a fresh worktree of a track-shared node starts without index.sh (gitignored)" \
  || fail "worktree: a fresh worktree of a track-shared node starts without index.sh (gitignored)"
"$NODE" update "$i58wt" >"$WORK/i58-wt-update.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "worktree: node.sh update exits 0" || fail "worktree: node.sh update exits 0 (rc=$rc)"
[ -x "$i58wt/.agent/scripts/index.sh" ] \
  && pass "worktree: node.sh update obtains index.sh" \
  || fail "worktree: node.sh update obtains index.sh"
"$i58wt/.agent/scripts/index.sh" ensure --root "$i58wt" >"$WORK/i58-wt-ensure.out" 2>"$WORK/i58-wt-ensure.err"
rc=$?
[ "$rc" -eq 0 ] && [ -f "$i58wt/.agent/indexes/current.md" ] \
  && pass "worktree: index.sh ensure succeeds once the indexer is present" \
  || fail "worktree: index.sh ensure succeeds once the indexer is present (rc=$rc, err=$(cat "$WORK/i58-wt-ensure.err"))"
git -C "$i58src" worktree remove -f "$i58wt" >/dev/null 2>&1 || rm -rf "$i58wt"

# ---- 59. index.sh: rules/learned/ as a canonical source set, and
# rules/learned.md as its generated, gitignored aggregate ----

# An empty rules/learned/ directory is exactly as inactive as a missing
# one: learned.md stays an ordinary rule record and ensure never touches it.
l59="$WORK/l59"
mkdir -p "$l59/.agent/rules/learned" "$l59/.agent/docs"
printf '# Learned rules\n\nHeader body.\n\n<!-- Format: - [YYYY-MM-DD] x. -->\n' >"$l59/.agent/rules/learned.md"
printf '# Doc\n<!-- Read when: testing -->\nBody.\n' >"$l59/.agent/docs/d.md"
l59before=$(idx_snapshot "$l59/.agent/rules")
"$IDXSH" ensure --root "$l59" >/dev/null 2>"$WORK/l59.err"
l59gen=$(sed -n 2p "$l59/.agent/indexes/current.md")
l59after=$(idx_snapshot "$l59/.agent/rules")
[ "$l59before" = "$l59after" ] \
  && pass "learned aggregate: an empty rules/learned/ directory leaves learned.md untouched, same as no directory at all" \
  || fail "learned aggregate: an empty rules/learned/ directory leaves learned.md untouched, same as no directory at all"
grep -qF "Source: $l59/.agent/rules/learned.md" "$l59/.agent/indexes/$l59gen"/rules-*.md \
  && pass "learned aggregate: with rules/learned/ empty, learned.md still renders as an ordinary source record" \
  || fail "learned aggregate: with rules/learned/ empty, learned.md still renders as an ordinary source record"

# No rules/learned/ directory at all: learned.md renders exactly as any
# other rule record did before this feature, and ensure never rewrites it.
l61="$WORK/l61"
mkdir -p "$l61/.agent/rules" "$l61/.agent/docs"
printf '# Learned rules\n\nHeader body.\n\n<!-- Format: - [YYYY-MM-DD] x. -->\n\n- [2026-01-01] Legacy single-file rule.\n' >"$l61/.agent/rules/learned.md"
printf '# Doc\n<!-- Read when: testing -->\nBody.\n' >"$l61/.agent/docs/d.md"
l61learnedbefore=$(cat "$l61/.agent/rules/learned.md")
"$IDXSH" ensure --root "$l61" >/dev/null 2>"$WORK/l61.err"
l61gen=$(sed -n 2p "$l61/.agent/indexes/current.md")
grep -qF "Source: $l61/.agent/rules/learned.md" "$l61/.agent/indexes/$l61gen"/rules-*.md \
  && grep -qF -- '- [2026-01-01] Legacy single-file rule.' "$l61/.agent/indexes/$l61gen"/rules-*.md \
  && pass "learned aggregate: with no rules/learned/ directory, learned.md renders as an ordinary source record" \
  || fail "learned aggregate: with no rules/learned/ directory, learned.md renders as an ordinary source record"
[ "$(cat "$l61/.agent/rules/learned.md")" = "$l61learnedbefore" ] \
  && pass "learned aggregate: with no rules/learned/ directory, ensure never rewrites learned.md" \
  || fail "learned aggregate: with no rules/learned/ directory, ensure never rewrites learned.md"

# One record, many records, and a record whose body carries several ^-
# lines — the aggregate must carry every one of them forward, path-sorted,
# with qualifiers, Trigger: clauses, and dates intact, and no rule body may
# render twice across the published pages (the gen.*/*.md pages — not the
# standalone aggregate, which is never one of them).
l60="$WORK/l60"
mkdir -p "$l60/.agent/rules/learned" "$l60/.agent/docs"
printf '# Doc\n<!-- Read when: testing -->\nBody.\n' >"$l60/.agent/docs/d.md"
printf -- '- [2026-01-01] First rule. Trigger: alpha.\n' >"$l60/.agent/rules/learned/aa-first.md"
printf -- '- [2026-01-02] Second rule.\n- [2026-01-03] Third rule. Trigger: beta.\n' >"$l60/.agent/rules/learned/bb-second.md"
printf -- '- [2026-01-04] Fourth rule.\n- inline sub-bullet, not a dated rule\n' >"$l60/.agent/rules/learned/cc-third.md"
"$IDXSH" ensure --root "$l60" >/dev/null 2>"$WORK/l60.err"
l60gen=$(sed -n 2p "$l60/.agent/indexes/current.md")
l60dir="$l60/.agent/indexes/$l60gen"
l60agg="$l60/.agent/rules/learned.md"

grep -qF -- '- [2026-01-01] First rule. Trigger: alpha.' "$l60agg" \
  && grep -qF -- '- [2026-01-02] Second rule.' "$l60agg" \
  && grep -qF -- '- [2026-01-03] Third rule. Trigger: beta.' "$l60agg" \
  && grep -qF -- '- [2026-01-04] Fourth rule.' "$l60agg" \
  && grep -qF -- '- inline sub-bullet, not a dated rule' "$l60agg" \
  && pass "learned aggregate: every ^- line from every record is present, qualifiers and Trigger clauses intact" \
  || fail "learned aggregate: every ^- line from every record is present, qualifiers and Trigger clauses intact"

l60posA=$(grep -n -F -- 'First rule' "$l60agg" | head -1 | cut -d: -f1)
l60posB=$(grep -n -F -- 'Second rule' "$l60agg" | head -1 | cut -d: -f1)
l60posC=$(grep -n -F -- 'Fourth rule' "$l60agg" | head -1 | cut -d: -f1)
[ -n "$l60posA" ] && [ -n "$l60posB" ] && [ -n "$l60posC" ] \
  && [ "$l60posA" -lt "$l60posB" ] && [ "$l60posB" -lt "$l60posC" ] \
  && pass "learned aggregate: records concatenate in path-sorted order" \
  || fail "learned aggregate: records concatenate in path-sorted order"

l60rulecount=$(grep -c '^- ' "$l60agg")
[ "$l60rulecount" -eq 5 ] \
  && pass "learned aggregate: the ^- line count is the sum of every record's own rule lines, real bullets and incidental ones alike" \
  || fail "learned aggregate: the ^- line count is the sum of every record's own rule lines, real bullets and incidental ones alike ($l60rulecount)"

l60totalfirst=$(grep -hc -F -- 'First rule' "$l60dir"/*.md 2>/dev/null | awk '{s+=$1} END{print s+0}')
[ "$l60totalfirst" -eq 1 ] \
  && pass "learned aggregate: no rule body from rules/learned/ renders twice across the published pages" \
  || fail "learned aggregate: no rule body from rules/learned/ renders twice across the published pages ($l60totalfirst)"

# Editing one record and re-running ensure updates the aggregate.
l60aggbefore=$(cat "$l60agg")
printf -- '- [2026-01-05] Fifth rule appended.\n' >>"$l60/.agent/rules/learned/aa-first.md"
"$IDXSH" ensure --root "$l60" >/dev/null 2>"$WORK/l60.edit.err"
grep -q '^BUILT$' "$WORK/l60.edit.err" && pass "learned aggregate: editing a record rebuilds" \
  || fail "learned aggregate: editing a record rebuilds"
l60aggafter=$(cat "$l60agg")
[ "$l60aggbefore" != "$l60aggafter" ] && grep -qF -- 'Fifth rule appended.' "$l60agg" \
  && pass "learned aggregate: editing one record and re-running ensure updates the aggregate" \
  || fail "learned aggregate: editing one record and re-running ensure updates the aggregate"

# Re-check the no-double-render guarantee now that learned.md already
# exists on disk from the first ensure — a stronger check than the one
# above, whose fresh-fixture run could pass even with the exclusion gone.
l60gen2=$(sed -n 2p "$l60/.agent/indexes/current.md")
l60dir2="$l60/.agent/indexes/$l60gen2"
l60totalfirst2=$(grep -hc -F -- 'First rule' "$l60dir2"/*.md 2>/dev/null | awk '{s+=$1} END{print s+0}')
[ "$l60totalfirst2" -eq 1 ] \
  && pass "learned aggregate: no rule body from rules/learned/ renders twice across the published pages, once learned.md already exists on disk" \
  || fail "learned aggregate: no rule body from rules/learned/ renders twice across the published pages, once learned.md already exists on disk ($l60totalfirst2)"

# A cache hit (nothing changed) writes nothing at all.
l60hitsnap1=$(idx_snapshot "$l60/.agent/rules")
"$IDXSH" ensure --root "$l60" >/dev/null 2>"$WORK/l60.hit.err"
grep -q '^HIT$' "$WORK/l60.hit.err" && pass "learned aggregate: an unchanged tree after the edit is a warm HIT" \
  || fail "learned aggregate: an unchanged tree after the edit is a warm HIT"
l60hitsnap2=$(idx_snapshot "$l60/.agent/rules")
[ "$l60hitsnap1" = "$l60hitsnap2" ] \
  && pass "learned aggregate: a cache hit writes nothing" \
  || fail "learned aggregate: a cache hit writes nothing"

# check performs no write to the aggregate, even with a stale, changed record.
l60aggcheckbefore=$(cat "$l60agg")
printf -- '- [2026-01-06] Stale edit for check.\n' >>"$l60/.agent/rules/learned/bb-second.md"
"$IDXSH" check --root "$l60" >/dev/null 2>&1
"$IDXSH" check --root "$l60" >/dev/null 2>&1
[ "$(cat "$l60agg")" = "$l60aggcheckbefore" ] \
  && pass "learned aggregate: check writes no file under any input, even a stale record change" \
  || fail "learned aggregate: check writes no file under any input, even a stale record change"

# A failed ensure leaves both the previous entry file and the previous
# aggregate exactly as they were, with no leftover temp file either.
"$IDXSH" ensure --root "$l60" >/dev/null 2>&1
l60entrybefore=$(cat "$l60/.agent/indexes/current.md")
l60aggfailbefore=$(cat "$l60agg")
printf -- '- [2026-01-07] Should never land.\n' >>"$l60/.agent/rules/learned/cc-third.md"
INDEX_FAIL_AT=before-publish "$IDXSH" ensure --root "$l60" >/dev/null 2>"$WORK/l60.fail.err"
l60failrc=$?
[ "$l60failrc" -eq 1 ] && grep -q 'FALLBACK:' "$WORK/l60.fail.err" \
  && pass "learned aggregate: an injected failure before publication is reported and exits 1" \
  || fail "learned aggregate: an injected failure before publication is reported and exits 1"
[ "$(cat "$l60/.agent/indexes/current.md")" = "$l60entrybefore" ] && [ "$(cat "$l60agg")" = "$l60aggfailbefore" ] \
  && pass "learned aggregate: a failed ensure leaves both the previous entry file and the previous aggregate exactly as they were" \
  || fail "learned aggregate: a failed ensure leaves both the previous entry file and the previous aggregate exactly as they were"
[ -z "$(find "$l60/.agent/indexes" -maxdepth 1 -name '.entry.*' 2>/dev/null)" ] \
  && [ -z "$(find "$l60/.agent/rules" -maxdepth 1 -name '.learned.*' 2>/dev/null)" ] \
  && pass "learned aggregate: a failed ensure leaves no leftover temp files" \
  || fail "learned aggregate: a failed ensure leaves no leftover temp files"

# ---- 60. index.sh + status.sh: an unmodified status.sh run against a
# migrated fixture matches the pre-migration verdict ----
m60ctl="$WORK/m60-control"
mkdir -p "$m60ctl"
# indexes: generated on both sides, matching the migrated fixture below —
# the only difference under test is the learned-rules shape, not this field.
"$NODE" init --preset software-development --mode track-all --indexes generated "$m60ctl" >/dev/null 2>&1
finish_bootstrap "$m60ctl"
cat >"$m60ctl/.agent/rules/learned.md" <<'EOF'
# Learned rules

Binding rules distilled from operator corrections and failed verifications on this project, after the canonical-source check in `contract.md`. A correction that exposes a defect in the contract, docs, code, or tooling is fixed there and produces no compensating rule. Merging and compressing entries is allowed. Drop a rule when its failure mode becomes mechanically enforced. Behavioral rules stay here. Area gotchas go to the matching `.agent/docs/` file under `## Gotchas`. Authoring and curation rules: `contract.md`, Self-learning.

<!-- Format: - [YYYY-MM-DD] <imperative rule>. Trigger: <cause, optional>. -->

- [2026-01-01] Rule one about deploys.
- [2026-01-02] Rule two about tests. Trigger: a flaky suite.
- [2026-01-03] Rule three about review turnaround.
EOF
m60ctlflags=$(status_flags "$m60ctl")
m60ctlplain=$("$m60ctl/.agent/scripts/status.sh" "$m60ctl" 2>/dev/null)
m60ctlpayload=$(printf '%s\n' "$m60ctlplain" | grep '^PAYLOAD:' | grep -oE '[0-9]+' | head -1)

m60mig="$WORK/m60-migrated"
mkdir -p "$m60mig"
"$NODE" init --preset software-development --mode track-all --indexes generated "$m60mig" >/dev/null 2>&1
finish_bootstrap "$m60mig"
rm -f "$m60mig/.agent/rules/learned.md"
mkdir -p "$m60mig/.agent/rules/learned"
printf -- '- [2026-01-01] Rule one about deploys.\n' >"$m60mig/.agent/rules/learned/0001.md"
printf -- '- [2026-01-02] Rule two about tests. Trigger: a flaky suite.\n' >"$m60mig/.agent/rules/learned/0002.md"
printf -- '- [2026-01-03] Rule three about review turnaround.\n' >"$m60mig/.agent/rules/learned/0003.md"
"$m60mig/.agent/scripts/index.sh" ensure --root "$m60mig" >/dev/null 2>"$WORK/m60mig.ensure.err"

# The generated aggregate carries one line the pre-migration file never
# had: the "hand edits are lost" marker. It is byte-identical to the
# control only once that marker line is removed; everything else
# (header, blank line, every rule bullet in path-sorted order) must
# still match exactly.
m60migstripped=$(grep -vF '<!-- Generated by index.sh from rules/learned/' "$m60mig/.agent/rules/learned.md")
m60ctlcontent=$(cat "$m60ctl/.agent/rules/learned.md")
[ "$m60migstripped" = "$m60ctlcontent" ] \
  && pass "migration: the regenerated aggregate matches the pre-migration file exactly, apart from the one generated-marker line" \
  || fail "migration: the regenerated aggregate matches the pre-migration file exactly, apart from the one generated-marker line"

m60migflags=$(status_flags "$m60mig")
m60migplain=$("$m60mig/.agent/scripts/status.sh" "$m60mig" 2>/dev/null)
m60migpayload=$(printf '%s\n' "$m60migplain" | grep '^PAYLOAD:' | grep -oE '[0-9]+' | head -1)
m60markerbytes=$(printf '%s\n' '<!-- Generated by index.sh from rules/learned/*.md — hand edits here are lost on the next ensure. -->' | wc -c | tr -d '[:space:]')

printf '%s\n' "$m60migflags" | grep -qF 'REPAIR: rules/learned.md missing/empty' \
  && fail "migration: an unmodified status.sh emits no REPAIR: rules/learned.md missing/empty against the migrated fixture" \
  || pass "migration: an unmodified status.sh emits no REPAIR: rules/learned.md missing/empty against the migrated fixture"
[ "$m60ctlflags" = "$m60migflags" ] \
  && pass "migration: status.sh reaches the same REPAIR/GROOM verdict pre- and post-migration" \
  || fail "migration: status.sh reaches the same REPAIR/GROOM verdict pre- and post-migration ($m60migflags)"
# Both fixtures are indexes: generated, so PAYLOAD: prices purpose and
# memory only — rules/learned.md is a rule page now, not a --load member —
# and the migration's marker-line addition to it moves no payload byte at
# all. The two totals must be equal, not off by the marker line's bytes.
[ -n "$m60ctlpayload" ] && [ -n "$m60migpayload" ] \
  && [ "$m60ctlpayload" -eq "$m60migpayload" ] \
  && pass "migration: status.sh bills the identical payload pre- and post-migration, since rule bodies no longer ride --load" \
  || fail "migration: status.sh bills the identical payload pre- and post-migration, since rule bodies no longer ride --load (ctl=$m60ctlpayload mig=$m60migpayload)"

# The marker line's bytes still have to land somewhere: rules/learned.md
# itself, which the migrated copy carries and the control's does not.
m60ctllearnedbytes=$(wc -c <"$m60ctl/.agent/rules/learned.md" | tr -d '[:space:]')
m60miglearnedbytes=$(wc -c <"$m60mig/.agent/rules/learned.md" | tr -d '[:space:]')
[ "$((m60miglearnedbytes - m60ctllearnedbytes))" -eq "$m60markerbytes" ] \
  && pass "migration: the regenerated rules/learned.md exceeds the control by exactly the marker line's own bytes" \
  || fail "migration: the regenerated rules/learned.md exceeds the control by exactly the marker line's own bytes (ctl=$m60ctllearnedbytes mig=$m60miglearnedbytes marker=$m60markerbytes)"

printf '\n--- status.sh output against the migrated fixture (%s) ---\n' "$m60mig"
"$m60mig/.agent/scripts/status.sh" "$m60mig"
printf -- '--- status.sh --load against the migrated fixture ---\n'
"$m60mig/.agent/scripts/status.sh" --load "$m60mig" 2>/dev/null
printf -- '--- end status.sh output ---\n\n'

# ---- 61. node.sh update, generated indexes: learned-rule extraction,
# doc-hook backfill, and the migration inventory ----

# A V6 fixture (oldversion 6, below TARGET_VERSION, so update takes the
# real-migration branch) with indexes: generated added beside mode,
# rules/learned.md exercising four bullet shapes, and an
# architecture.md/docs/ tree exercising every hook-backfill departure.
r61build() {
  r61_dir="$1"
  mkdir -p "$r61_dir"
  make_v6_fixture "$r61_dir"
  r61_modeline=$(grep -n '^  mode:' "$r61_dir/.agent/purpose.md" | head -1 | cut -d: -f1)
  awk -v ln="$r61_modeline" \
    'NR==ln { print; print "  indexes: generated        # manual | generated"; next } { print }' \
    "$r61_dir/.agent/purpose.md" >"$r61_dir/.agent/purpose.md.tmp"
  mv "$r61_dir/.agent/purpose.md.tmp" "$r61_dir/.agent/purpose.md"

  cat >"$r61_dir/.agent/rules/learned.md" <<'EOF'
# Learned rules

Binding rules distilled from operator corrections and failed verifications on this project, after the canonical-source check in `contract.md`. A correction that exposes a defect in the contract, docs, code, or tooling is fixed there and produces no compensating rule. Merging and compressing entries is allowed. Drop a rule when its failure mode becomes mechanically enforced. Behavioral rules stay here. Area gotchas go to the matching `.agent/docs/` file under `## Gotchas`. Authoring and curation rules: `contract.md`, Self-learning.

<!-- Format: - [YYYY-MM-DD] <imperative rule>. Trigger: <cause, optional>. -->
- [2026-01-01] First rule, flat. Trigger: something.
- [2026-01-02] Second rule with a nested sub-bullet. Trigger: x.
  - qualifier one
  - qualifier two
- [2026-01-03] Third rule, multi paragraph.

  Continuation paragraph here.
- [2026-01-04] Fourth rule, flat, last one.
EOF

  mkdir -p "$r61_dir/.agent/memory"
  cat >"$r61_dir/.agent/memory/staging-reset.md" <<'EOF'
---
date: 2026-01-01
scope: project
type: fact
---

The staging database resets nightly at 02:00 UTC.
EOF
  cat >"$r61_dir/.agent/memory.md" <<'EOF'
# Memory
<!-- Index only, one line per fact file, newest last. Reorder by relevance only when grooming. Format: - [Title](memory/slug.md) — hook. No prose, no facts inline: a fact that lives only as a line here and not as its own file under memory/ is not recorded. Delete the line when its file is deleted. Preferred writer: .agent/scripts/memory.sh new (scaffolds the fact file and its index line together). This contract covers memory/ too, so fact files carry no header of their own. Each holds one durable fact under date, scope, and type frontmatter. Keep a fact only if work in this node changes when it is true: one carried in from another repo or a migration earns its place again or is dropped. Before writing, search purpose, rules, routed docs, source, and existing facts. If one already states it, update that source or its routing, write no fact, and say which source states it. A defect fixed in the harness or a tool creates no compensating fact. Two halves that would be superseded at different times are two files. Supersede in place with .agent/scripts/memory.sh supersede --slug <slug> --fact "…", which rewrites the fact, restamps the date, and keeps the filename. No dated narratives, no command output, no history. As small as the fact allows. Stable knowledge about how the system works goes to docs/ without a pointer fact; architecture.md already routes it. type: reference points outward at a URL, dashboard, ticket, or spec the node does not own: checked for reachability, not superseded like a fact. -->

- [Staging reset](memory/staging-reset.md) — when the staging database resets.
EOF

  mkdir -p "$r61_dir/.agent/docs/area"
  cat >"$r61_dir/.agent/docs/architecture.md" <<'EOF'
# Architecture

### `hooked.md`
- **Read when:** already hooked, never touched.

### `unhooked.md`
- **Read when:** doing unhooked work.

### `area/sub.md`
- **Read when:** doing area sub work.

### `dup.md`
- **Read when:** first dup entry.

### `dup.md`
- **Read when:** second dup entry.

### `badtable.md`
Hand-edited row with no bold marker: whatever hook text.
EOF
  cat >"$r61_dir/.agent/docs/hooked.md" <<'EOF'
<!-- Read when: already hooked, never touched. -->
# Hooked

Body.
EOF
  cat >"$r61_dir/.agent/docs/unhooked.md" <<'EOF'
# Unhooked

Body.
EOF
  cat >"$r61_dir/.agent/docs/area/sub.md" <<'EOF'
# Sub

Body.
EOF
  cat >"$r61_dir/.agent/docs/dup.md" <<'EOF'
# Dup

Body.
EOF
  cat >"$r61_dir/.agent/docs/badtable.md" <<'EOF'
# Badtable

Body.
EOF
  cat >"$r61_dir/.agent/docs/noentry.md" <<'EOF'
# Noentry

Body.
EOF
}

# r61build, then override mode away from its ignore-all default — the same
# post-hoc rewrite make_v6_fixture applies to its own mode argument.
r61mode() {
  r61m_dir="$1"
  r61m_mode="$2"
  r61build "$r61m_dir"
  if [ "$r61m_mode" != ignore-all ]; then
    sed "s/^  mode: ignore-all/  mode: $r61m_mode/" "$r61m_dir/.agent/purpose.md" \
      >"$r61m_dir/.agent/purpose.md.tmp"
    mv "$r61m_dir/.agent/purpose.md.tmp" "$r61m_dir/.agent/purpose.md"
  fi
}

# True when every one of r61build's four original bullets is present
# somewhere in $1 — order-independent, since the aggregate concatenates
# records in identity-sorted order, not original file order.
r61_bullets_present() {
  rbp_file="$1"
  for rbp_marker in 'First rule, flat' 'nested sub-bullet' 'multi paragraph' 'Fourth rule, flat'; do
    grep -qF "$rbp_marker" "$rbp_file" || return 1
  done
  return 0
}

r61dir="$WORK/r61-migration"
r61build "$r61dir"
cp "$r61dir/.agent/docs/architecture.md" "$WORK/r61-arch-before.md"
cp "$r61dir/.agent/rules/learned.md" "$WORK/r61-learned-before.md"
cp "$r61dir/.agent/memory.md" "$WORK/r61-memory-before.md"
cp "$r61dir/.agent/memory/staging-reset.md" "$WORK/r61-memory-fact-before.md"
cp "$r61dir/.agent/docs/hooked.md" "$WORK/r61-hooked-before.md"
cp "$r61dir/.agent/docs/dup.md" "$WORK/r61-dup-before.md"
cp "$r61dir/.agent/docs/badtable.md" "$WORK/r61-badtable-before.md"
cp "$r61dir/.agent/docs/noentry.md" "$WORK/r61-noentry-before.md"

"$NODE" update "$r61dir" >"$WORK/r61-update.out" 2>&1
r61rc=$?
[ "$r61rc" -eq 0 ] && pass "generated-mode update: exits 0" || fail "generated-mode update: exits 0 (rc=$r61rc)"

r61records=$(find "$r61dir/.agent/rules/learned" -maxdepth 1 -name '*.md' 2>/dev/null | sort)
r61count=$(printf '%s\n' "$r61records" | grep -c .)
[ "$r61count" -eq 4 ] && pass "rule extraction: four bullets produce four records" || fail "rule extraction: four bullets produce four records (found $r61count)"

r61badnames=0
for r61f in $r61records; do
  r61base=$(basename "$r61f" .md)
  case "$r61base" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
  *) r61badnames=$((r61badnames + 1)) ;;
  esac
done
[ "$r61badnames" -eq 0 ] \
  && pass "rule extraction: every record filename is 12 lowercase hex characters" \
  || fail "rule extraction: every record filename is 12 lowercase hex characters ($r61badnames bad)"

r61uniq=$(printf '%s\n' "$r61records" | xargs -n1 basename | sort -u | wc -l | tr -d '[:space:]')
[ "$r61uniq" -eq 4 ] && pass "rule extraction: no two records share an identity" || fail "rule extraction: no two records share an identity"

r61flat1=$(grep -lF 'First rule, flat' $r61records)
r61nested=$(grep -lF 'nested sub-bullet' $r61records)
r61multi=$(grep -lF 'multi paragraph' $r61records)
r61flat2=$(grep -lF 'Fourth rule, flat' $r61records)

[ "$(cat "$r61flat1")" = '- [2026-01-01] First rule, flat. Trigger: something.' ] \
  && pass "rule extraction: a flat bullet's record is verbatim, nothing added" \
  || fail "rule extraction: a flat bullet's record is verbatim, nothing added"
[ "$(cat "$r61flat2")" = '- [2026-01-04] Fourth rule, flat, last one.' ] \
  && pass "rule extraction: the last flat bullet's record runs to end of file, verbatim" \
  || fail "rule extraction: the last flat bullet's record runs to end of file, verbatim"

r61nested_expect=$(printf '%s\n' \
  '- [2026-01-02] Second rule with a nested sub-bullet. Trigger: x.' \
  '  - qualifier one' \
  '  - qualifier two')
[ "$(cat "$r61nested")" = "$r61nested_expect" ] \
  && pass "rule extraction: nested sub-bullets stay inside the record that opened them" \
  || fail "rule extraction: nested sub-bullets stay inside the record that opened them"

r61multi_expect=$(printf '%s\n' \
  '- [2026-01-03] Third rule, multi paragraph.' \
  '' \
  '  Continuation paragraph here.')
[ "$(cat "$r61multi")" = "$r61multi_expect" ] \
  && pass "rule extraction: a multi-paragraph bullet keeps its continuation paragraph" \
  || fail "rule extraction: a multi-paragraph bullet keeps its continuation paragraph"

r61inv="$r61dir/.agent/migration-inventory.md"
[ -f "$r61inv" ] && pass "migration inventory: .agent/migration-inventory.md is written" || fail "migration inventory: .agent/migration-inventory.md is written"

r61id1=$(basename "$r61flat1" .md)
r61id2=$(basename "$r61nested" .md)
r61id3=$(basename "$r61multi" .md)
r61id4=$(basename "$r61flat2" .md)
grep -qF "rules/learned/$r61id1.md | id=$r61id1 | migrated" "$r61inv" \
  && pass "migration inventory: flat rule 1 lists migrated with its real identity" \
  || fail "migration inventory: flat rule 1 lists migrated with its real identity"
grep -qF "rules/learned/$r61id2.md | id=$r61id2 | semantic-review-pending" "$r61inv" \
  && pass "migration inventory: the nested-sub-bullet rule lists semantic-review-pending" \
  || fail "migration inventory: the nested-sub-bullet rule lists semantic-review-pending"
grep -qF "rules/learned/$r61id3.md | id=$r61id3 | semantic-review-pending" "$r61inv" \
  && pass "migration inventory: the multi-paragraph rule lists semantic-review-pending" \
  || fail "migration inventory: the multi-paragraph rule lists semantic-review-pending"
grep -qF "rules/learned/$r61id4.md | id=$r61id4 | migrated" "$r61inv" \
  && pass "migration inventory: flat rule 4 lists migrated with its real identity" \
  || fail "migration inventory: flat rule 4 lists migrated with its real identity"

r61_bullets_present "$r61dir/.agent/rules/learned.md" \
  && pass "migration: the regenerated rules/learned.md reproduces every original bullet" \
  || fail "migration: the regenerated rules/learned.md reproduces every original bullet"

diff -q "$WORK/r61-arch-before.md" "$r61dir/.agent/docs/architecture.md" >/dev/null 2>&1 \
  && pass "migration: architecture.md is byte-identical before and after" \
  || fail "migration: architecture.md is byte-identical before and after"

diff -q "$WORK/r61-memory-before.md" "$r61dir/.agent/memory.md" >/dev/null 2>&1 \
  && pass "migration: memory.md is byte-identical before and after" \
  || fail "migration: memory.md is byte-identical before and after"

diff -q "$WORK/r61-memory-fact-before.md" "$r61dir/.agent/memory/staging-reset.md" >/dev/null 2>&1 \
  && pass "migration: a file under memory/ is byte-identical before and after" \
  || fail "migration: a file under memory/ is byte-identical before and after"

diff -q "$WORK/r61-hooked-before.md" "$r61dir/.agent/docs/hooked.md" >/dev/null 2>&1 \
  && pass "hook backfill: a doc that already carries a hook is left untouched" \
  || fail "hook backfill: a doc that already carries a hook is left untouched"

[ "$(sed -n 1p "$r61dir/.agent/docs/unhooked.md")" = '<!-- Read when: doing unhooked work. -->' ] \
  && pass "hook backfill: a missing hook with a matching architecture.md entry is backfilled" \
  || fail "hook backfill: a missing hook with a matching architecture.md entry is backfilled"
[ "$(tail -n +2 "$r61dir/.agent/docs/unhooked.md")" = "$(printf '# Unhooked\n\nBody.')" ] \
  && pass "hook backfill: backfilling a hook changes nothing else in the doc" \
  || fail "hook backfill: backfilling a hook changes nothing else in the doc"

[ "$(sed -n 1p "$r61dir/.agent/docs/area/sub.md")" = '<!-- Read when: doing area sub work. -->' ] \
  && pass "hook backfill: a sub-doc under docs/<area>/ resolves its entry key as area/sub.md" \
  || fail "hook backfill: a sub-doc under docs/<area>/ resolves its entry key as area/sub.md"

diff -q "$WORK/r61-dup-before.md" "$r61dir/.agent/docs/dup.md" >/dev/null 2>&1 \
  && pass "hook backfill: a duplicate architecture.md entry key is left untouched (no winner picked)" \
  || fail "hook backfill: a duplicate architecture.md entry key is left untouched (no winner picked)"

diff -q "$WORK/r61-badtable-before.md" "$r61dir/.agent/docs/badtable.md" >/dev/null 2>&1 \
  && pass "hook backfill: a hand-edited entry with no bold Read-when line is left untouched" \
  || fail "hook backfill: a hand-edited entry with no bold Read-when line is left untouched"

diff -q "$WORK/r61-noentry-before.md" "$r61dir/.agent/docs/noentry.md" >/dev/null 2>&1 \
  && pass "hook backfill: a doc with no architecture.md entry at all is left untouched" \
  || fail "hook backfill: a doc with no architecture.md entry at all is left untouched"

grep -qF 'doc docs/hooked.md -> docs/hooked.md | id=hooked.md | migrated' "$r61inv" \
  && pass "migration inventory: the already-hooked doc lists migrated" \
  || fail "migration inventory: the already-hooked doc lists migrated"
grep -qF 'doc docs/unhooked.md -> docs/unhooked.md | id=unhooked.md | migrated' "$r61inv" \
  && pass "migration inventory: the backfilled doc lists migrated" \
  || fail "migration inventory: the backfilled doc lists migrated"
grep -qF 'doc docs/area/sub.md -> docs/area/sub.md | id=area/sub.md | migrated' "$r61inv" \
  && pass "migration inventory: the backfilled sub-doc lists migrated" \
  || fail "migration inventory: the backfilled sub-doc lists migrated"
grep -qF 'doc docs/dup.md -> docs/dup.md | id=dup.md | hook-missing' "$r61inv" \
  && pass "migration inventory: the duplicate-key doc lists hook-missing" \
  || fail "migration inventory: the duplicate-key doc lists hook-missing"
grep -qF 'doc docs/badtable.md -> docs/badtable.md | id=badtable.md | hook-missing' "$r61inv" \
  && pass "migration inventory: the hand-edited unparseable doc lists hook-missing" \
  || fail "migration inventory: the hand-edited unparseable doc lists hook-missing"
grep -qF 'doc docs/noentry.md -> docs/noentry.md | id=noentry.md | hook-missing' "$r61inv" \
  && pass "migration inventory: the doc with no architecture.md entry lists hook-missing" \
  || fail "migration inventory: the doc with no architecture.md entry lists hook-missing"

grep -qF 'docs/architecture.md' "$r61inv" \
  && fail "migration inventory: architecture.md itself is never listed as a walked item" \
  || pass "migration inventory: architecture.md itself is never listed as a walked item"

# ---- 61b. a second update over an already-populated rules/learned/ mints
# no new identity, rewrites no record, and changes no file ----
r61snapshot() { find "$1/.agent" -type f | sort | xargs shasum 2>/dev/null | sort; }
r61before2=$(r61snapshot "$r61dir")
"$NODE" update "$r61dir" >"$WORK/r61-update2.out" 2>&1
r61rc2=$?
r61after2=$(r61snapshot "$r61dir")
[ "$r61rc2" -eq 0 ] && pass "re-run over an already-populated rules/learned/: exits 0" || fail "re-run over an already-populated rules/learned/: exits 0 (rc=$r61rc2)"
[ "$r61before2" = "$r61after2" ] \
  && pass "re-run over an already-populated rules/learned/: mints no identity, rewrites no record, changes no file" \
  || fail "re-run over an already-populated rules/learned/: mints no identity, rewrites no record, changes no file"

# ---- 61c. a rules/learned.md with zero bullets produces zero records and
# no rule line in the inventory ----
r61zero="$WORK/r61-zero"
mkdir -p "$r61zero"
make_v6_fixture "$r61zero"
r61zero_modeline=$(grep -n '^  mode:' "$r61zero/.agent/purpose.md" | head -1 | cut -d: -f1)
awk -v ln="$r61zero_modeline" \
  'NR==ln { print; print "  indexes: generated        # manual | generated"; next } { print }' \
  "$r61zero/.agent/purpose.md" >"$r61zero/.agent/purpose.md.tmp"
mv "$r61zero/.agent/purpose.md.tmp" "$r61zero/.agent/purpose.md"
cat >"$r61zero/.agent/rules/learned.md" <<'EOF'
# Learned rules

Prose paragraph, no rules recorded yet.

<!-- Format: - [YYYY-MM-DD] <imperative rule>. Trigger: <cause, optional>. -->
EOF
"$NODE" update "$r61zero" >"$WORK/r61-zero-update.out" 2>&1
r61zerorc=$?
[ "$r61zerorc" -eq 0 ] && pass "zero-bullet rules/learned.md: update exits 0" || fail "zero-bullet rules/learned.md: update exits 0 (rc=$r61zerorc)"
r61zerocount=$(find "$r61zero/.agent/rules/learned" -maxdepth 1 -name '*.md' 2>/dev/null | grep -c .)
[ "$r61zerocount" -eq 0 ] && pass "zero-bullet rules/learned.md: no records are created" || fail "zero-bullet rules/learned.md: no records are created (found $r61zerocount)"
grep -q '^- rule ' "$r61zero/.agent/migration-inventory.md" \
  && fail "zero-bullet rules/learned.md: the inventory carries no rule line" \
  || pass "zero-bullet rules/learned.md: the inventory carries no rule line"

# ---- 61d. identity minting: the collision-retry path and the
# 100-consecutive-rejection abort, exercised deterministically ----
# mint_learned_id reads $RANDOM directly (never inside a `$(...)` fork,
# which would perturb bash's generator on every call), so seeding RANDOM
# and sourcing just the function definitions — everything above the
# command dispatch — reproduces its candidate sequence exactly. This
# tests the function in isolation; it does not invoke node.sh's own
# command dispatch, which always exits and so cannot be sourced and
# resumed within one process.
sed -n '1,/^case "\$cmd" in/p' "$NODE" | sed '$d' >"$WORK/node-funcs.sh"

r61mintdir="$WORK/r61-mint-retry"
mkdir -p "$r61mintdir"
r61seed=777
r61first=$(bash -c "RANDOM=$r61seed; printf '%04x%04x%04x' \"\$RANDOM\" \"\$RANDOM\" \"\$RANDOM\"")
: >"$r61mintdir/$r61first.md"
r61mintout=$(bash -c '
  RANDOM='"$r61seed"'
  source "'"$WORK"'/node-funcs.sh"
  : >"'"$r61mintdir"'/.minted"
  if mint_learned_id "'"$r61mintdir"'" "'"$r61mintdir"'/.minted"; then
    printf "MINTED:%s" "$mint_id_result"
  else
    printf "ABORTED"
  fi
')
case "$r61mintout" in
MINTED:*)
  r61second=${r61mintout#MINTED:}
  [ "$r61second" != "$r61first" ] && [ -e "$r61mintdir/$r61second.md" ] \
    && pass "identity minting: a collision on the first candidate is rejected and retried to a fresh id" \
    || fail "identity minting: a collision on the first candidate is rejected and retried to a fresh id ($r61mintout)"
  ;;
*) fail "identity minting: a collision on the first candidate is rejected and retried to a fresh id ($r61mintout)" ;;
esac
[ -e "$r61mintdir/$r61first.md" ] \
  && pass "identity minting: the file that caused the collision is left exactly as it was" \
  || fail "identity minting: the file that caused the collision is left exactly as it was"

r61abortdir="$WORK/r61-mint-abort"
mkdir -p "$r61abortdir"
r61abortseed=999
bash -c '
  RANDOM='"$r61abortseed"'
  i=0
  while [ "$i" -lt 100 ]; do
    printf -v id "%04x%04x%04x" "$RANDOM" "$RANDOM" "$RANDOM"
    : >"'"$r61abortdir"'/$id.md"
    i=$((i + 1))
  done
'
r61beforeabort=$(find "$r61abortdir" -maxdepth 1 -name '*.md' | wc -l | tr -d '[:space:]')
r61abortout=$(bash -c '
  RANDOM='"$r61abortseed"'
  source "'"$WORK"'/node-funcs.sh"
  : >"'"$r61abortdir"'/.minted"
  if mint_learned_id "'"$r61abortdir"'" "'"$r61abortdir"'/.minted"; then
    printf "MINTED:%s" "$mint_id_result"
  else
    printf "ABORTED"
  fi
')
[ "$r61abortout" = "ABORTED" ] \
  && pass "identity minting: 100 consecutive rejections abort minting with no identity" \
  || fail "identity minting: 100 consecutive rejections abort minting with no identity ($r61abortout)"
r61afterabort=$(find "$r61abortdir" -maxdepth 1 -name '*.md' | wc -l | tr -d '[:space:]')
[ "$r61beforeabort" -eq "$r61afterabort" ] \
  && pass "identity minting: an aborted mint creates no additional record file" \
  || fail "identity minting: an aborted mint creates no additional record file"

# ---- 61e. a rules/learned.md with no trailing newline still captures the
# last bullet's final physical line ----
r61ntdir="$WORK/r61-no-trailing-newline"
mkdir -p "$r61ntdir"
make_v6_fixture "$r61ntdir"
r61nt_modeline=$(grep -n '^  mode:' "$r61ntdir/.agent/purpose.md" | head -1 | cut -d: -f1)
awk -v ln="$r61nt_modeline" \
  'NR==ln { print; print "  indexes: generated        # manual | generated"; next } { print }' \
  "$r61ntdir/.agent/purpose.md" >"$r61ntdir/.agent/purpose.md.tmp"
mv "$r61ntdir/.agent/purpose.md.tmp" "$r61ntdir/.agent/purpose.md"
printf '%s\n' \
  '# Learned rules' \
  '' \
  '<!-- Format: - [YYYY-MM-DD] <imperative rule>. Trigger: <cause, optional>. -->' \
  '- [2026-01-01] First rule, flat.' \
  '- [2026-01-02] Last rule spans two lines,' >"$r61ntdir/.agent/rules/learned.md"
printf '  and this second line has NO trailing newline.' >>"$r61ntdir/.agent/rules/learned.md"

"$NODE" update "$r61ntdir" >"$WORK/r61-nt-update.out" 2>&1
r61ntrc=$?
[ "$r61ntrc" -eq 0 ] && pass "no-trailing-newline rules/learned.md: update exits 0" || fail "no-trailing-newline rules/learned.md: update exits 0 (rc=$r61ntrc)"

r61ntrecords=$(find "$r61ntdir/.agent/rules/learned" -maxdepth 1 -name '*.md' 2>/dev/null | sort)
r61ntcount=$(printf '%s\n' "$r61ntrecords" | grep -c .)
[ "$r61ntcount" -eq 2 ] && pass "no-trailing-newline rules/learned.md: two bullets produce two records" || fail "no-trailing-newline rules/learned.md: two bullets produce two records (found $r61ntcount)"

r61ntlast=$(grep -lF 'NO trailing newline' $r61ntrecords)
r61nt_expect=$(printf '%s\n' \
  '- [2026-01-02] Last rule spans two lines,' \
  '  and this second line has NO trailing newline.')
[ "$(cat "$r61ntlast")" = "$r61nt_expect" ] \
  && pass "rule extraction: a rules/learned.md with no trailing newline still captures the last bullet's final line verbatim" \
  || fail "rule extraction: a rules/learned.md with no trailing newline still captures the last bullet's final line verbatim"

# ---- 62. generated-mode migration, boundary 1: interrupted after the
# backup and migration_target write, before anything is staged ----
b1="$WORK/mig-boundary1"
mkdir -p "$b1"
r61mode "$b1" track-shared
cp -R "$b1/.agent" "$b1/.agent.backup-v6"
printf 'pre-existing backup marker\n' >"$b1/.agent.backup-v6/.marker"
awk '/^  version: 6$/ { print; print "  migration_target: \"6.2\""; next } { print }' \
  "$b1/.agent/purpose.md" >"$b1/.agent/purpose.md.tmp"
mv "$b1/.agent/purpose.md.tmp" "$b1/.agent/purpose.md"
"$NODE" update "$b1" >"$WORK/b1-update.out" 2>&1
b1rc=$?
[ "$b1rc" -eq 0 ] && pass "boundary 1: resume before anything is staged exits 0" || fail "boundary 1: resume before anything is staged exits 0 (rc=$b1rc)"
grep -qF "backup path already exists" "$WORK/b1-update.out" \
  && fail "boundary 1: resume does not abort on its own backup" \
  || pass "boundary 1: resume does not abort on its own backup"
[ -f "$b1/.agent.backup-v6/.marker" ] \
  && pass "boundary 1: the pre-existing backup is not re-copied" \
  || fail "boundary 1: the pre-existing backup is not re-copied"
b1count=$(find "$b1/.agent/rules/learned" -maxdepth 1 -name '*.md' 2>/dev/null | grep -c .)
[ "$b1count" -eq 4 ] \
  && pass "boundary 1: resume completes a full migration (four records)" \
  || fail "boundary 1: resume completes a full migration (four records) (found $b1count)"
b1gi1=$(grep -cxF '.agent/indexes/' "$b1/.gitignore" 2>/dev/null)
b1gi2=$(grep -cxF '.agent/rules/learned.md' "$b1/.gitignore" 2>/dev/null)
[ "$b1gi1" -eq 1 ] && [ "$b1gi2" -eq 1 ] \
  && pass "boundary 1: resume writes both generated-mode gitignore lines exactly once" \
  || fail "boundary 1: resume writes both generated-mode gitignore lines exactly once"
r61_bullets_present "$b1/.agent/rules/learned.md" \
  && pass "boundary 1: the regenerated rules/learned.md reproduces every original bullet" \
  || fail "boundary 1: the regenerated rules/learned.md reproduces every original bullet"

# ---- 62b. generated-mode migration, boundary 2: some records staged
# (plus a zero-byte claimed record), before the rename ----
b2="$WORK/mig-boundary2"
mkdir -p "$b2"
r61mode "$b2" track-shared
cp -R "$b2/.agent" "$b2/.agent.backup-v6"
awk '/^  version: 6$/ { print; print "  migration_target: \"6.2\""; next } { print }' \
  "$b2/.agent/purpose.md" >"$b2/.agent/purpose.md.tmp"
mv "$b2/.agent/purpose.md.tmp" "$b2/.agent/purpose.md"

# RANDOM is seeded here only for the discarded staging attempt, never for
# the resumed run below, so a resume that happened to re-mint the same
# identities would not go undetected.
b2staging="$b2/.agent/.learned-staging"
mkdir -p "$b2staging"
b2id1=$(bash -c 'RANDOM=6101; printf "%04x%04x%04x" "$RANDOM" "$RANDOM" "$RANDOM"')
b2id2=$(bash -c 'RANDOM=6102; printf "%04x%04x%04x" "$RANDOM" "$RANDOM" "$RANDOM"')
b2id3=$(bash -c 'RANDOM=6103; printf "%04x%04x%04x" "$RANDOM" "$RANDOM" "$RANDOM"')
printf -- '- [2026-01-01] First rule, flat. Trigger: something.\n' >"$b2staging/$b2id1.md"
printf '%s\n' \
  '- [2026-01-02] Second rule with a nested sub-bullet. Trigger: x.' \
  '  - qualifier one' \
  '  - qualifier two' >"$b2staging/$b2id2.md"
: >"$b2staging/$b2id3.md"
b2stagedids="$b2id1 $b2id2 $b2id3"

"$NODE" update "$b2" >"$WORK/b2-update.out" 2>&1
b2rc=$?
[ "$b2rc" -eq 0 ] && pass "boundary 2: resume after partial staging exits 0" || fail "boundary 2: resume after partial staging exits 0 (rc=$b2rc)"
[ ! -e "$b2staging" ] \
  && pass "boundary 2: the staging directory is gone after resume" \
  || fail "boundary 2: the staging directory is gone after resume"
b2count=$(find "$b2/.agent/rules/learned" -maxdepth 1 -name '*.md' 2>/dev/null | grep -c .)
[ "$b2count" -eq 4 ] \
  && pass "boundary 2: resume records exactly the four original bullets" \
  || fail "boundary 2: resume records exactly the four original bullets (found $b2count)"
r61_bullets_present "$b2/.agent/rules/learned.md" \
  && pass "boundary 2: every original bullet is present in the regenerated aggregate" \
  || fail "boundary 2: every original bullet is present in the regenerated aggregate"
b2leak=0
[ -e "$b2staging" ] && b2leak=1
for b2id in $b2stagedids; do
  [ -e "$b2/.agent/rules/learned/$b2id.md" ] && b2leak=1
  grep -rlF "$b2id" "$b2/.agent" >/dev/null 2>&1 && b2leak=1
done
[ "$b2leak" -eq 0 ] \
  && pass "boundary 2: none of the discarded attempt's identities, the zero-byte one included, ever appears under .agent/" \
  || fail "boundary 2: none of the discarded attempt's identities, the zero-byte one included, ever appears under .agent/"

# ---- 62c. generated-mode migration, boundary 3: interrupted after the
# rename, before index.sh ensure succeeds ----
b3="$WORK/mig-boundary3"
mkdir -p "$b3"
r61mode "$b3" track-shared
git -C "$b3" init -q
git -C "$b3" config user.name Tester
git -C "$b3" config user.email tester@example.invalid
git -C "$b3" add .agent
git -C "$b3" commit -qm initial

cp -R "$b3/.agent" "$b3/.agent.backup-v6"
grep '^- ' "$b3/.agent/rules/learned.md" >"$b3/.agent/.learned-bullets-before"
awk '/^  version: 6$/ { print; print "  migration_target: \"6.2\""; next } { print }' \
  "$b3/.agent/purpose.md" >"$b3/.agent/purpose.md.tmp"
mv "$b3/.agent/purpose.md.tmp" "$b3/.agent/purpose.md"

mkdir -p "$b3/.agent/rules/learned"
b3id1=$(bash -c 'RANDOM=6201; printf "%04x%04x%04x" "$RANDOM" "$RANDOM" "$RANDOM"')
b3id2=$(bash -c 'RANDOM=6202; printf "%04x%04x%04x" "$RANDOM" "$RANDOM" "$RANDOM"')
b3id3=$(bash -c 'RANDOM=6203; printf "%04x%04x%04x" "$RANDOM" "$RANDOM" "$RANDOM"')
b3id4=$(bash -c 'RANDOM=6204; printf "%04x%04x%04x" "$RANDOM" "$RANDOM" "$RANDOM"')
printf -- '- [2026-01-01] First rule, flat. Trigger: something.\n' >"$b3/.agent/rules/learned/$b3id1.md"
printf '%s\n' \
  '- [2026-01-02] Second rule with a nested sub-bullet. Trigger: x.' \
  '  - qualifier one' \
  '  - qualifier two' >"$b3/.agent/rules/learned/$b3id2.md"
printf '%s\n' \
  '- [2026-01-03] Third rule, multi paragraph.' \
  '' \
  '  Continuation paragraph here.' >"$b3/.agent/rules/learned/$b3id3.md"
printf -- '- [2026-01-04] Fourth rule, flat, last one.\n' >"$b3/.agent/rules/learned/$b3id4.md"

"$NODE" update "$b3" >"$WORK/b3-update.out" 2>&1
b3rc=$?
[ "$b3rc" -eq 0 ] && pass "boundary 3: resume after the rename, before ensure, exits 0" || fail "boundary 3: resume after the rename, before ensure, exits 0 (rc=$b3rc)"
b3gi1=$(grep -cxF '.agent/indexes/' "$b3/.gitignore" 2>/dev/null)
b3gi2=$(grep -cxF '.agent/rules/learned.md' "$b3/.gitignore" 2>/dev/null)
[ "$b3gi1" -eq 1 ] && [ "$b3gi2" -eq 1 ] \
  && pass "boundary 3: resume writes both generated-mode gitignore lines exactly once" \
  || fail "boundary 3: resume writes both generated-mode gitignore lines exactly once"
r61_bullets_present "$b3/.agent/rules/learned.md" \
  && pass "boundary 3: resume regenerates the aggregate and reproduces every original bullet" \
  || fail "boundary 3: resume regenerates the aggregate and reproduces every original bullet"
git -C "$b3" ls-files --error-unmatch -- .agent/rules/learned.md >/dev/null 2>&1 \
  && fail "boundary 3: resume untracks rules/learned.md" \
  || pass "boundary 3: resume untracks rules/learned.md"
[ ! -e "$b3/.agent/.learned-bullets-before" ] \
  && pass "boundary 3: the resume snapshot is removed once the untrack completes" \
  || fail "boundary 3: the resume snapshot is removed once the untrack completes"

# ---- 62d. generated-mode migration, boundary 4: interrupted after the
# aggregate check passes, before git rm --cached completes ----
b4="$WORK/mig-boundary4"
mkdir -p "$b4"
r61mode "$b4" track-shared
git -C "$b4" init -q
git -C "$b4" config user.name Tester
git -C "$b4" config user.email tester@example.invalid
git -C "$b4" add .agent
git -C "$b4" commit -qm initial

cp -R "$b4/.agent" "$b4/.agent.backup-v6"
grep '^- ' "$b4/.agent/rules/learned.md" >"$b4/.agent/.learned-bullets-before"
awk '/^  version: 6$/ { print; print "  migration_target: \"6.2\""; next } { print }' \
  "$b4/.agent/purpose.md" >"$b4/.agent/purpose.md.tmp"
mv "$b4/.agent/purpose.md.tmp" "$b4/.agent/purpose.md"

mkdir -p "$b4/.agent/rules/learned"
b4id1=$(bash -c 'RANDOM=6301; printf "%04x%04x%04x" "$RANDOM" "$RANDOM" "$RANDOM"')
b4id2=$(bash -c 'RANDOM=6302; printf "%04x%04x%04x" "$RANDOM" "$RANDOM" "$RANDOM"')
b4id3=$(bash -c 'RANDOM=6303; printf "%04x%04x%04x" "$RANDOM" "$RANDOM" "$RANDOM"')
b4id4=$(bash -c 'RANDOM=6304; printf "%04x%04x%04x" "$RANDOM" "$RANDOM" "$RANDOM"')
printf -- '- [2026-01-01] First rule, flat. Trigger: something.\n' >"$b4/.agent/rules/learned/$b4id1.md"
printf '%s\n' \
  '- [2026-01-02] Second rule with a nested sub-bullet. Trigger: x.' \
  '  - qualifier one' \
  '  - qualifier two' >"$b4/.agent/rules/learned/$b4id2.md"
printf '%s\n' \
  '- [2026-01-03] Third rule, multi paragraph.' \
  '' \
  '  Continuation paragraph here.' >"$b4/.agent/rules/learned/$b4id3.md"
printf -- '- [2026-01-04] Fourth rule, flat, last one.\n' >"$b4/.agent/rules/learned/$b4id4.md"

"$IDXSH" ensure --root "$b4" >/dev/null 2>&1
printf '.agent/indexes/\n' >"$b4/.gitignore"
printf '.agent/rules/learned.md\n' >>"$b4/.gitignore"

"$NODE" update "$b4" >"$WORK/b4-update.out" 2>&1
b4rc=$?
[ "$b4rc" -eq 0 ] && pass "boundary 4: resume after the aggregate check, before untrack, exits 0" || fail "boundary 4: resume after the aggregate check, before untrack, exits 0 (rc=$b4rc)"
b4gi1=$(grep -cxF '.agent/indexes/' "$b4/.gitignore" 2>/dev/null)
b4gi2=$(grep -cxF '.agent/rules/learned.md' "$b4/.gitignore" 2>/dev/null)
[ "$b4gi1" -eq 1 ] && [ "$b4gi2" -eq 1 ] \
  && pass "boundary 4: resume adds no duplicate gitignore line" \
  || fail "boundary 4: resume adds no duplicate gitignore line"
git -C "$b4" ls-files --error-unmatch -- .agent/rules/learned.md >/dev/null 2>&1 \
  && fail "boundary 4: resume untracks rules/learned.md exactly once" \
  || pass "boundary 4: resume untracks rules/learned.md exactly once"
[ ! -e "$b4/.agent/.learned-bullets-before" ] \
  && pass "boundary 4: the resume snapshot is removed after the untrack" \
  || fail "boundary 4: the resume snapshot is removed after the untrack"
r61_bullets_present "$b4/.agent/rules/learned.md" \
  && pass "boundary 4: the aggregate still reproduces every original bullet after resume" \
  || fail "boundary 4: the aggregate still reproduces every original bullet after resume"

# ---- 62e. generated-mode migration: the aggregate-reproduction check
# aborts before untracking when the regenerated aggregate does not
# reproduce every snapshotted bullet, and rules/learned.md is never
# untracked on that failure ----
b5="$WORK/mig-boundary-abort"
mkdir -p "$b5"
r61mode "$b5" track-shared
git -C "$b5" init -q
git -C "$b5" config user.name Tester
git -C "$b5" config user.email tester@example.invalid
git -C "$b5" add .agent
git -C "$b5" commit -qm initial

cp -R "$b5/.agent" "$b5/.agent.backup-v6"
# Seed the pre-migration snapshot with a bogus bullet that no record will
# ever reproduce, forcing the reproduction check to fail deterministically
# rather than corrupting a real record's content.
grep '^- ' "$b5/.agent/rules/learned.md" >"$b5/.agent/.learned-bullets-before"
printf -- '- [2026-01-09] Bogus bullet never present in any record.\n' >>"$b5/.agent/.learned-bullets-before"
awk '/^  version: 6$/ { print; print "  migration_target: \"6.2\""; next } { print }' \
  "$b5/.agent/purpose.md" >"$b5/.agent/purpose.md.tmp"
mv "$b5/.agent/purpose.md.tmp" "$b5/.agent/purpose.md"

mkdir -p "$b5/.agent/rules/learned"
b5id1=$(bash -c 'RANDOM=6501; printf "%04x%04x%04x" "$RANDOM" "$RANDOM" "$RANDOM"')
b5id2=$(bash -c 'RANDOM=6502; printf "%04x%04x%04x" "$RANDOM" "$RANDOM" "$RANDOM"')
b5id3=$(bash -c 'RANDOM=6503; printf "%04x%04x%04x" "$RANDOM" "$RANDOM" "$RANDOM"')
b5id4=$(bash -c 'RANDOM=6504; printf "%04x%04x%04x" "$RANDOM" "$RANDOM" "$RANDOM"')
printf -- '- [2026-01-01] First rule, flat. Trigger: something.\n' >"$b5/.agent/rules/learned/$b5id1.md"
printf '%s\n' \
  '- [2026-01-02] Second rule with a nested sub-bullet. Trigger: x.' \
  '  - qualifier one' \
  '  - qualifier two' >"$b5/.agent/rules/learned/$b5id2.md"
printf '%s\n' \
  '- [2026-01-03] Third rule, multi paragraph.' \
  '' \
  '  Continuation paragraph here.' >"$b5/.agent/rules/learned/$b5id3.md"
printf -- '- [2026-01-04] Fourth rule, flat, last one.\n' >"$b5/.agent/rules/learned/$b5id4.md"

"$NODE" update "$b5" >"$WORK/b5-update.out" 2>&1
b5rc=$?
[ "$b5rc" -ne 0 ] \
  && pass "abort path: update exits nonzero when the regenerated aggregate does not reproduce every snapshotted bullet" \
  || fail "abort path: update exits nonzero when the regenerated aggregate does not reproduce every snapshotted bullet (rc=$b5rc)"
git -C "$b5" ls-files --error-unmatch -- .agent/rules/learned.md >/dev/null 2>&1 \
  && pass "abort path: rules/learned.md stays tracked when the aggregate-reproduction check fails" \
  || fail "abort path: rules/learned.md stays tracked when the aggregate-reproduction check fails"
[ -e "$b5/.agent/.learned-bullets-before" ] \
  && pass "abort path: .learned-bullets-before is not removed when the aggregate-reproduction check fails" \
  || fail "abort path: .learned-bullets-before is not removed when the aggregate-reproduction check fails"

# ---- 63. generated-mode migration, tracking-mode matrix: gitignore,
# untrack, no-duplicate lines on a second update, and a customized doc's
# ownership and visibility, per mode ----
mm_build() {
  mm_dir="$1"
  mm_mode="$2"
  mm_git="$3"
  mkdir -p "$mm_dir"
  r61mode "$mm_dir" "$mm_mode"
  printf '# Custom\n\nHand-authored project note that must survive migration untouched.\n' \
    >"$mm_dir/.agent/docs/custom.md"
  if [ "$mm_git" = yes ]; then
    git -C "$mm_dir" init -q
    git -C "$mm_dir" config user.name Tester
    git -C "$mm_dir" config user.email tester@example.invalid
    git -C "$mm_dir" add .agent
    git -C "$mm_dir" commit -qm initial
  fi
}

# track-shared, real git repo.
mmA="$WORK/mm-track-shared"
mm_build "$mmA" track-shared yes
cp "$mmA/.agent/docs/custom.md" "$WORK/mmA-custom-before.md"
"$NODE" update "$mmA" >"$WORK/mmA-update.out" 2>&1
mmA_rc=$?
[ "$mmA_rc" -eq 0 ] && pass "mode matrix (track-shared): update exits 0" || fail "mode matrix (track-shared): update exits 0 (rc=$mmA_rc)"
mmA_gi1=$(grep -cxF '.agent/indexes/' "$mmA/.gitignore" 2>/dev/null)
mmA_gi2=$(grep -cxF '.agent/rules/learned.md' "$mmA/.gitignore" 2>/dev/null)
[ "$mmA_gi1" -eq 1 ] && [ "$mmA_gi2" -eq 1 ] \
  && pass "mode matrix (track-shared): both gitignore lines are present exactly once" \
  || fail "mode matrix (track-shared): both gitignore lines are present exactly once"
git -C "$mmA" ls-files --error-unmatch -- .agent/rules/learned.md >/dev/null 2>&1 \
  && fail "mode matrix (track-shared): rules/learned.md is untracked after migration" \
  || pass "mode matrix (track-shared): rules/learned.md is untracked after migration"
diff -q "$WORK/mmA-custom-before.md" "$mmA/.agent/docs/custom.md" >/dev/null 2>&1 \
  && pass "mode matrix (track-shared): the customized doc's content survives untouched" \
  || fail "mode matrix (track-shared): the customized doc's content survives untouched"
git -C "$mmA" ls-files --error-unmatch -- .agent/docs/custom.md >/dev/null 2>&1 \
  && pass "mode matrix (track-shared): the customized doc keeps its tracked ownership" \
  || fail "mode matrix (track-shared): the customized doc keeps its tracked ownership"
"$NODE" update "$mmA" >"$WORK/mmA-update2.out" 2>&1
mmA_rc2=$?
[ "$mmA_rc2" -eq 0 ] && pass "mode matrix (track-shared): a second update exits 0" || fail "mode matrix (track-shared): a second update exits 0 (rc=$mmA_rc2)"
mmA_gi1b=$(grep -cxF '.agent/indexes/' "$mmA/.gitignore" 2>/dev/null)
mmA_gi2b=$(grep -cxF '.agent/rules/learned.md' "$mmA/.gitignore" 2>/dev/null)
[ "$mmA_gi1b" -eq 1 ] && [ "$mmA_gi2b" -eq 1 ] \
  && pass "mode matrix (track-shared): a second update adds no duplicate gitignore line" \
  || fail "mode matrix (track-shared): a second update adds no duplicate gitignore line"

# track-all, real git repo: no backup is ever created.
mmB="$WORK/mm-track-all"
mm_build "$mmB" track-all yes
cp "$mmB/.agent/docs/custom.md" "$WORK/mmB-custom-before.md"
"$NODE" update "$mmB" >"$WORK/mmB-update.out" 2>&1
mmB_rc=$?
[ "$mmB_rc" -eq 0 ] && pass "mode matrix (track-all): update exits 0" || fail "mode matrix (track-all): update exits 0 (rc=$mmB_rc)"
[ ! -e "$mmB/.agent.backup-v6" ] \
  && pass "mode matrix (track-all): no backup is created" \
  || fail "mode matrix (track-all): no backup is created"
mmB_gi1=$(grep -cxF '.agent/indexes/' "$mmB/.gitignore" 2>/dev/null)
mmB_gi2=$(grep -cxF '.agent/rules/learned.md' "$mmB/.gitignore" 2>/dev/null)
[ "$mmB_gi1" -eq 1 ] && [ "$mmB_gi2" -eq 1 ] \
  && pass "mode matrix (track-all): both gitignore lines are present exactly once" \
  || fail "mode matrix (track-all): both gitignore lines are present exactly once"
git -C "$mmB" ls-files --error-unmatch -- .agent/rules/learned.md >/dev/null 2>&1 \
  && fail "mode matrix (track-all): rules/learned.md is untracked after migration" \
  || pass "mode matrix (track-all): rules/learned.md is untracked after migration"
diff -q "$WORK/mmB-custom-before.md" "$mmB/.agent/docs/custom.md" >/dev/null 2>&1 \
  && pass "mode matrix (track-all): the customized doc's content survives untouched" \
  || fail "mode matrix (track-all): the customized doc's content survives untouched"
git -C "$mmB" ls-files --error-unmatch -- .agent/docs/custom.md >/dev/null 2>&1 \
  && pass "mode matrix (track-all): the customized doc keeps its tracked ownership" \
  || fail "mode matrix (track-all): the customized doc keeps its tracked ownership"
"$NODE" update "$mmB" >"$WORK/mmB-update2.out" 2>&1
mmB_gi1b=$(grep -cxF '.agent/indexes/' "$mmB/.gitignore" 2>/dev/null)
mmB_gi2b=$(grep -cxF '.agent/rules/learned.md' "$mmB/.gitignore" 2>/dev/null)
[ "$mmB_gi1b" -eq 1 ] && [ "$mmB_gi2b" -eq 1 ] \
  && pass "mode matrix (track-all): a second update adds no duplicate gitignore line" \
  || fail "mode matrix (track-all): a second update adds no duplicate gitignore line"

# ignore-all, outside any git work tree: neither gitignore line, no
# untrack attempted.
mmC="$WORK/mm-ignore-all"
mm_build "$mmC" ignore-all no
cp "$mmC/.agent/docs/custom.md" "$WORK/mmC-custom-before.md"
"$NODE" update "$mmC" >"$WORK/mmC-update.out" 2>&1
mmC_rc=$?
[ "$mmC_rc" -eq 0 ] && pass "mode matrix (ignore-all, no git): update exits 0" || fail "mode matrix (ignore-all, no git): update exits 0 (rc=$mmC_rc)"
[ ! -e "$mmC/.gitignore" ] \
  && pass "mode matrix (ignore-all, no git): no gitignore is written" \
  || fail "mode matrix (ignore-all, no git): no gitignore is written"
diff -q "$WORK/mmC-custom-before.md" "$mmC/.agent/docs/custom.md" >/dev/null 2>&1 \
  && pass "mode matrix (ignore-all, no git): the customized doc's content survives untouched" \
  || fail "mode matrix (ignore-all, no git): the customized doc's content survives untouched"
"$NODE" update "$mmC" >"$WORK/mmC-update2.out" 2>&1
mmC_rc2=$?
[ "$mmC_rc2" -eq 0 ] && pass "mode matrix (ignore-all, no git): a second update exits 0" || fail "mode matrix (ignore-all, no git): a second update exits 0 (rc=$mmC_rc2)"

# track-shared, outside any git work tree: gitignore lines are still
# written (a plain text file, no git needed), but the untrack is skipped
# for lack of a work tree, never as an error.
mmD="$WORK/mm-track-shared-nogit"
mm_build "$mmD" track-shared no
cp "$mmD/.agent/docs/custom.md" "$WORK/mmD-custom-before.md"
"$NODE" update "$mmD" >"$WORK/mmD-update.out" 2>&1
mmD_rc=$?
[ "$mmD_rc" -eq 0 ] && pass "mode matrix (track-shared, no git): update exits 0" || fail "mode matrix (track-shared, no git): update exits 0 (rc=$mmD_rc)"
mmD_gi1=$(grep -cxF '.agent/indexes/' "$mmD/.gitignore" 2>/dev/null)
mmD_gi2=$(grep -cxF '.agent/rules/learned.md' "$mmD/.gitignore" 2>/dev/null)
[ "$mmD_gi1" -eq 1 ] && [ "$mmD_gi2" -eq 1 ] \
  && pass "mode matrix (track-shared, no git): both gitignore lines are still written" \
  || fail "mode matrix (track-shared, no git): both gitignore lines are still written"
diff -q "$WORK/mmD-custom-before.md" "$mmD/.agent/docs/custom.md" >/dev/null 2>&1 \
  && pass "mode matrix (track-shared, no git): the customized doc's content survives untouched" \
  || fail "mode matrix (track-shared, no git): the customized doc's content survives untouched"
"$NODE" update "$mmD" >"$WORK/mmD-update2.out" 2>&1
mmD_gi1b=$(grep -cxF '.agent/indexes/' "$mmD/.gitignore" 2>/dev/null)
mmD_gi2b=$(grep -cxF '.agent/rules/learned.md' "$mmD/.gitignore" 2>/dev/null)
[ "$mmD_gi1b" -eq 1 ] && [ "$mmD_gi2b" -eq 1 ] \
  && pass "mode matrix (track-shared, no git): a second update adds no duplicate gitignore line" \
  || fail "mode matrix (track-shared, no git): a second update adds no duplicate gitignore line"

# ---- 63e. generated-mode migration, mode not ignore-all, root inside a
# git work tree, but rules/learned.md is already untracked when the
# untrack step runs. Distinct from the ignore-all skip (mmC) and the
# outside-a-work-tree skip (mmD): here git is present and the mode would
# normally untrack, but there is nothing left to untrack.
au="$WORK/mm-already-untracked"
mm_build "$au" track-shared yes
"$NODE" update "$au" >"$WORK/au-update1.out" 2>&1
git -C "$au" ls-files --error-unmatch -- .agent/rules/learned.md >/dev/null 2>&1 \
  && fail "already-untracked: the first update untracks rules/learned.md, setting up the fixture" \
  || pass "already-untracked: the first update untracks rules/learned.md, setting up the fixture"
git -C "$au" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  && pass "already-untracked: the fixture remains inside a git work tree" \
  || fail "already-untracked: the fixture remains inside a git work tree"

"$NODE" update "$au" >"$WORK/au-update2.out" 2>&1
au_rc2=$?
[ "$au_rc2" -eq 0 ] \
  && pass "already-untracked: a second update, with the file already untracked, exits 0" \
  || fail "already-untracked: a second update, with the file already untracked, exits 0 (rc=$au_rc2)"
grep -qF 'skipped untracking .agent/rules/learned.md (.agent/rules/learned.md is not tracked)' "$WORK/au-update2.out" \
  && pass "already-untracked: the second update reports the not-tracked skip and runs no git rm --cached" \
  || fail "already-untracked: the second update reports the not-tracked skip and runs no git rm --cached"
git -C "$au" ls-files --error-unmatch -- .agent/rules/learned.md >/dev/null 2>&1 \
  && fail "already-untracked: rules/learned.md is still not tracked after the second update" \
  || pass "already-untracked: rules/learned.md is still not tracked after the second update"

# ---- 64. generated-mode migration, real git merges and a linear replay
# against a migrated node ----
mg="$WORK/mig-merge-base"
mkdir -p "$mg"
r61mode "$mg" track-shared
git -C "$mg" init -q
git -C "$mg" config user.name Tester
git -C "$mg" config user.email tester@example.invalid
git -C "$mg" add .agent
git -C "$mg" commit -qm initial
"$NODE" update "$mg" >/dev/null 2>&1
git -C "$mg" add -A
git -C "$mg" commit -qm "post-migration state"
mgbase=$(git -C "$mg" symbolic-ref --short HEAD)

# A and B each add one distinct new record on their own branch; merging
# both into the base is clean and both bullets reach the regenerated
# aggregate.
git -C "$mg" checkout -qb recA "$mgbase"
printf -- '- [2026-02-01] Branch A added this rule.\n' >"$mg/.agent/rules/learned/branch-a-record.md"
git -C "$mg" add .agent/rules/learned/branch-a-record.md
git -C "$mg" commit -qm "branch A record"

git -C "$mg" checkout -q "$mgbase"
git -C "$mg" checkout -qb recB "$mgbase"
printf -- '- [2026-02-02] Branch B added this rule.\n' >"$mg/.agent/rules/learned/branch-b-record.md"
git -C "$mg" add .agent/rules/learned/branch-b-record.md
git -C "$mg" commit -qm "branch B record"

git -C "$mg" checkout -qb merge-ab "$mgbase"
git -C "$mg" merge -q --no-edit recA >"$WORK/mg-merge-a.out" 2>&1
mgmerge1rc=$?
git -C "$mg" merge -q --no-edit recB >"$WORK/mg-merge-b.out" 2>&1
mgmerge2rc=$?
[ "$mgmerge1rc" -eq 0 ] && [ "$mgmerge2rc" -eq 0 ] \
  && pass "merge fixture: two disjoint new records merge clean" \
  || fail "merge fixture: two disjoint new records merge clean"
"$mg/.agent/scripts/index.sh" ensure --root "$mg" >/dev/null 2>&1
grep -qF 'Branch A added this rule.' "$mg/.agent/rules/learned.md" \
  && grep -qF 'Branch B added this rule.' "$mg/.agent/rules/learned.md" \
  && pass "merge fixture: both merged records reach the regenerated aggregate" \
  || fail "merge fixture: both merged records reach the regenerated aggregate"

# C and D each edit the same record's body differently; the second merge
# conflicts on that record file rather than silently picking a winner.
git -C "$mg" checkout -q "$mgbase"
mgeditfile=$(grep -lF 'First rule, flat' "$mg/.agent/rules/learned"/*.md | head -n1)
mgeditrel=${mgeditfile#"$mg"/}

git -C "$mg" checkout -qb editC "$mgbase"
printf -- '- [2026-01-01] First rule, flat. Trigger: something -- edited by C.\n' >"$mgeditfile"
git -C "$mg" commit -qam "branch C edit"

git -C "$mg" checkout -qb editD "$mgbase"
printf -- '- [2026-01-01] First rule, flat. Trigger: something -- edited by D.\n' >"$mgeditfile"
git -C "$mg" commit -qam "branch D edit"

git -C "$mg" checkout -qb merge-cd "$mgbase"
git -C "$mg" merge -q --no-edit editC >"$WORK/mg-merge-c.out" 2>&1
mgmerge3rc=$?
git -C "$mg" merge -q --no-edit editD >"$WORK/mg-merge-d.out" 2>&1
mgmerge4rc=$?
[ "$mgmerge3rc" -eq 0 ] \
  && pass "merge fixture: the first same-record edit applies clean" \
  || fail "merge fixture: the first same-record edit applies clean"
[ "$mgmerge4rc" -ne 0 ] \
  && pass "merge fixture: a second edit to the same record conflicts rather than silently choosing a winner" \
  || fail "merge fixture: a second edit to the same record conflicts rather than silently choosing a winner"
git -C "$mg" diff --name-only --diff-filter=U 2>/dev/null | grep -qF "$mgeditrel" \
  && pass "merge fixture: the conflict lands on the edited record file" \
  || fail "merge fixture: the conflict lands on the edited record file"
git -C "$mg" merge --abort >/dev/null 2>&1

# Linear replay: two successive commits, each adding one record; both
# bullets survive.
git -C "$mg" checkout -qb linear "$mgbase"
printf -- '- [2026-02-03] Linear commit one added this rule.\n' >"$mg/.agent/rules/learned/linear-one.md"
git -C "$mg" add .agent/rules/learned/linear-one.md
git -C "$mg" commit -qm "linear commit one"
printf -- '- [2026-02-04] Linear commit two added this rule.\n' >"$mg/.agent/rules/learned/linear-two.md"
git -C "$mg" add .agent/rules/learned/linear-two.md
git -C "$mg" commit -qm "linear commit two"
"$mg/.agent/scripts/index.sh" ensure --root "$mg" >/dev/null 2>&1
grep -qF 'Linear commit one added this rule.' "$mg/.agent/rules/learned.md" \
  && grep -qF 'Linear commit two added this rule.' "$mg/.agent/rules/learned.md" \
  && pass "linear replay: both sequential commits' records survive in the regenerated aggregate" \
  || fail "linear replay: both sequential commits' records survive in the regenerated aggregate"

# ---- 65. generated-mode migration, end-to-end: an unmodified status.sh
# run after the real migration chain (migrate_learned_and_docs -> gitignore
# -> index.sh ensure -> aggregate-reproduction check -> git rm --cached)
# emits no REPAIR: finding referencing rules/learned.md or the migration.
# Distinct from check 60's fixture, which hand-writes rules/learned/ and
# calls index.sh ensure directly — it never calls migrate_learned_and_docs,
# writes no gitignore, and never untracks, so it never exercises this
# chain end to end.
e2e="$WORK/mig-e2e-status"
mkdir -p "$e2e"
r61mode "$e2e" track-shared
git -C "$e2e" init -q
git -C "$e2e" config user.name Tester
git -C "$e2e" config user.email tester@example.invalid
git -C "$e2e" add .agent
git -C "$e2e" commit -qm initial

"$NODE" update "$e2e" >"$WORK/e2e-update.out" 2>&1
e2e_rc=$?
[ "$e2e_rc" -eq 0 ] && pass "end-to-end migration: update exits 0" || fail "end-to-end migration: update exits 0 (rc=$e2e_rc)"
git -C "$e2e" ls-files --error-unmatch -- .agent/rules/learned.md >/dev/null 2>&1 \
  && fail "end-to-end migration: the real chain untracks rules/learned.md" \
  || pass "end-to-end migration: the real chain untracks rules/learned.md"

# The pending-migration_target REPAIR is status.sh's own expected finding
# until finalize runs (see the update-command checks above) — filter it
# out, then assert nothing else about rules/learned.md or the migration
# mechanism remains. Unrelated REPAIR/GROOM findings elsewhere in the node
# are not asserted about either way.
e2e_flags_after=$(status_flags "$e2e")
e2e_bad_repairs=$(printf '%s\n' "$e2e_flags_after" \
  | grep '^REPAIR:' \
  | grep -v '^REPAIR: purpose\.md has migration_target ' \
  | grep -i 'learned')
[ -z "$e2e_bad_repairs" ] \
  && pass "end-to-end migration: an unmodified status.sh emits no REPAIR: finding referencing rules/learned.md or the migration, apart from the expected pending-migration_target note" \
  || fail "end-to-end migration: an unmodified status.sh emits no REPAIR: finding referencing rules/learned.md or the migration, apart from the expected pending-migration_target note ($e2e_bad_repairs)"

# ---- 66. checkpoint.sh compatibility shim: finish.sh forwards unchanged,
# plus one deprecation line ----
# An already-adopted node's entry point still says `finish.sh` until it is
# edited by hand, so the old name has to keep working. node.sh update ships
# checkpoint.sh and finish.sh through the same copy loop as init, so it
# gets its own check here rather than reusing the init-time one above. The
# forwarding check below runs two structurally identical fixtures — one
# through checkpoint.sh directly, one through finish.sh — and compares
# their output after stripping each fixture's own root path (so two
# differently named directories don't defeat the diff) and, on the
# finish.sh side, the shim's one added stderr line.
shimU="$WORK/shim-update"
make_v6_fixture "$shimU"
"$NODE" update "$shimU" >/dev/null 2>&1
[ -x "$shimU/.agent/scripts/checkpoint.sh" ] && [ -x "$shimU/.agent/scripts/finish.sh" ] \
  && pass "node.sh update: refreshes both checkpoint.sh and finish.sh on an existing node" \
  || fail "node.sh update: refreshes both checkpoint.sh and finish.sh on an existing node"

shimA="$WORK/shim-direct"
shimB="$WORK/shim-forward"
for shimroot in "$shimA" "$shimB"; do
  mkdir -p "$shimroot/src"
  "$NODE" init --preset software-development --mode track-all "$shimroot" >/dev/null 2>&1
  finish_bootstrap "$shimroot"
  printf 'export const a = 1\n' >"$shimroot/src/a.ts"
  git -C "$shimroot" init -q && git -C "$shimroot" add -A && git -C "$shimroot" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m base
  printf '// Vendor caps retries at three by contract; a fourth attempt is rejected upstream.\nexport const b = 2\n' >"$shimroot/src/a.ts"
done

"$shimA/.agent/scripts/checkpoint.sh" --tool claude --area shimtest --verify pass --summary "checkpoint shim parity" "$shimA" >"$WORK/shimA.out" 2>"$WORK/shimA.err"
rcA=$?
"$shimB/.agent/scripts/finish.sh" --tool claude --area shimtest --verify pass --summary "checkpoint shim parity" "$shimB" >"$WORK/shimB.out" 2>"$WORK/shimB.err"
rcB=$?

sed "s#$shimA#ROOT#g" "$WORK/shimA.out" >"$WORK/shimA.out.norm"
sed "s#$shimB#ROOT#g" "$WORK/shimB.out" >"$WORK/shimB.out.norm"
sed "s#$shimA#ROOT#g" "$WORK/shimA.err" >"$WORK/shimA.err.norm"
sed "s#$shimB#ROOT#g" "$WORK/shimB.err" >"$WORK/shimB.err.norm"

[ "$rcA" -eq "$rcB" ] && pass "checkpoint.sh shim: finish.sh's exit code matches a direct checkpoint.sh call" || fail "checkpoint.sh shim: finish.sh's exit code matches a direct checkpoint.sh call (checkpoint=$rcA finish=$rcB)"

diff -q "$WORK/shimA.out.norm" "$WORK/shimB.out.norm" >/dev/null 2>&1 \
  && pass "checkpoint.sh shim: finish.sh's stdout matches a direct checkpoint.sh call" \
  || fail "checkpoint.sh shim: finish.sh's stdout matches a direct checkpoint.sh call"

head -n 1 "$WORK/shimB.err" | grep -qxF "finish.sh: deprecated — use checkpoint.sh; forwarding unchanged" \
  && pass "checkpoint.sh shim: finish.sh's stderr opens with exactly the deprecation line" \
  || fail "checkpoint.sh shim: finish.sh's stderr opens with exactly the deprecation line"

tail -n +2 "$WORK/shimB.err.norm" >"$WORK/shimB.err.rest"
diff -q "$WORK/shimA.err.norm" "$WORK/shimB.err.rest" >/dev/null 2>&1 \
  && pass "checkpoint.sh shim: finish.sh's stderr past the deprecation line matches a direct checkpoint.sh call" \
  || fail "checkpoint.sh shim: finish.sh's stderr past the deprecation line matches a direct checkpoint.sh call"
# ---- 67. generated-mode bootstrap read set: index pages once, --load
# trimmed to purpose+memory, quality-bar.md and references/ never render ----
# The generated template used to run index.sh ensure and then status.sh
# --load, and --load printed the same rule bodies the index pages just
# built — every rule body loaded twice. Fixtures below build with node.sh
# init --indexes generated, then run the suite's bootstrap helper,
# matching every other generated-mode fixture in this file.

# Cold trace: a fresh node's first ensure is a BUILT, printing the entry
# path; --load then prints the entry-path line, purpose.md and memory.md
# under markers, and no .agent/rules/ marker at all.
rs67="$WORK/read-set-cold"
mkdir -p "$rs67"
"$NODE" init --preset software-development --mode track-all --indexes generated "$rs67" >/dev/null 2>&1
finish_bootstrap "$rs67"
"$IDXSH" ensure --root "$rs67" >"$WORK/rs67.cold.out" 2>"$WORK/rs67.cold.err"
grep -q '^BUILT$' "$WORK/rs67.cold.err" \
  && pass "read set: a cold index.sh ensure reports BUILT" \
  || fail "read set: a cold index.sh ensure reports BUILT"
[ "$(cat "$WORK/rs67.cold.out")" = "$rs67/.agent/indexes/current.md" ] \
  && pass "read set: index.sh ensure prints the entry path" \
  || fail "read set: index.sh ensure prints the entry path"

"$rs67/.agent/scripts/status.sh" --load "$rs67" >"$WORK/rs67.load.out" 2>&1
grep -qF "Rule bodies are not printed here — read every page listed in .agent/indexes/current.md." "$WORK/rs67.load.out" \
  && pass "read set: --load names the index entry path in generated mode" \
  || fail "read set: --load names the index entry path in generated mode"
grep -qF '==== .agent/purpose.md ====' "$WORK/rs67.load.out" \
  && pass "read set: --load prints purpose.md under a marker in generated mode" \
  || fail "read set: --load prints purpose.md under a marker in generated mode"
grep -qF '==== .agent/memory.md ====' "$WORK/rs67.load.out" \
  && pass "read set: --load prints memory.md under a marker in generated mode" \
  || fail "read set: --load prints memory.md under a marker in generated mode"
grep -q '^==== \.agent/rules/' "$WORK/rs67.load.out" \
  && fail "read set: --load prints no .agent/rules/ marker in generated mode" \
  || pass "read set: --load prints no .agent/rules/ marker in generated mode"

# Indexer gone, stale cache still on disk: --load falls back to the manual
# read set, so the rule text is in front of the session without any fallback
# instruction being remembered, and nothing points it at a cache it cannot
# verify. The calibration run of 2026-09-20 saw one session in three trust
# the leftover cache under the old behavior.
rs67ni="$WORK/read-set-no-indexer"
mkdir -p "$rs67ni"
"$NODE" init --preset software-development --mode track-all --indexes generated "$rs67ni" >/dev/null 2>&1
finish_bootstrap "$rs67ni"
"$IDXSH" ensure --root "$rs67ni" >/dev/null 2>&1
rm -f "$rs67ni/.agent/scripts/index.sh"
"$rs67ni/.agent/scripts/status.sh" --load "$rs67ni" >"$WORK/rs67ni.load.out" 2>&1
grep -q '^Indexer missing: purpose.md says indexes: generated but scripts/index.sh is not installed' "$WORK/rs67ni.load.out" \
  && pass "read set: a generated node with no indexer is told so in the load output, not as a REPAIR" \
  || fail "read set: a generated node with no indexer is told so in the load output, not as a REPAIR"
grep -q '^REPAIR: .*index.sh' "$WORK/rs67ni.load.out" \
  && fail "read set: a missing indexer stays a warning, never a checkpoint-blocking REPAIR" \
  || pass "read set: a missing indexer stays a warning, never a checkpoint-blocking REPAIR"
grep -qF '==== .agent/rules/contract.md ====' "$WORK/rs67ni.load.out" \
  && pass "read set: --load prints the contract inline when the indexer is missing" \
  || fail "read set: --load prints the contract inline when the indexer is missing"
grep -qF "read every page listed in .agent/indexes/current.md" "$WORK/rs67ni.load.out" \
  && fail "read set: --load never points at the unverifiable cache when the indexer is missing" \
  || pass "read set: --load never points at the unverifiable cache when the indexer is missing"

# Warm trace: a second ensure is a HIT, prints the same entry path, and
# publishes no new generation.
rs67_snap_before=$(idx_snapshot "$rs67/.agent/indexes")
"$IDXSH" ensure --root "$rs67" >"$WORK/rs67.warm.out" 2>"$WORK/rs67.warm.err"
grep -q '^HIT$' "$WORK/rs67.warm.err" \
  && pass "read set: a warm index.sh ensure reports HIT" \
  || fail "read set: a warm index.sh ensure reports HIT"
[ "$(cat "$WORK/rs67.warm.out")" = "$(cat "$WORK/rs67.cold.out")" ] \
  && pass "read set: a warm ensure prints the same entry path" \
  || fail "read set: a warm ensure prints the same entry path"
rs67_snap_after=$(idx_snapshot "$rs67/.agent/indexes")
[ "$rs67_snap_before" = "$rs67_snap_after" ] \
  && pass "read set: a warm ensure publishes no new generation" \
  || fail "read set: a warm ensure publishes no new generation"

# Duplicate-body: a rule's own distinctive sentence must appear in the
# published pages and nowhere in --load's now-trimmed output.
dup67="$WORK/read-set-dup"
mkdir -p "$dup67"
"$NODE" init --preset software-development --mode track-all --indexes generated "$dup67" >/dev/null 2>&1
finish_bootstrap "$dup67"
printf '# Custom Rule\n\nThe duplicate-body probe sentence lives only in this rule record.\n' >"$dup67/.agent/rules/custom.md"
"$IDXSH" ensure --root "$dup67" >/dev/null 2>"$WORK/dup67.err"
dup67_gen=$(sed -n 2p "$dup67/.agent/indexes/current.md")
grep -qrF -- 'duplicate-body probe sentence' "$dup67/.agent/indexes/$dup67_gen" \
  && pass "read set: a rule's distinctive sentence appears in a published page" \
  || fail "read set: a rule's distinctive sentence appears in a published page"
"$dup67/.agent/scripts/status.sh" --load "$dup67" 2>/dev/null | grep -qF -- 'duplicate-body probe sentence' \
  && fail "read set: the rule's sentence does not also appear in --load output" \
  || pass "read set: the rule's sentence does not also appear in --load output"

# Manual-mode parity: manual mode's --load branch stays the fixed
# learned/contract/purpose/memory sequence this file has always emitted, so
# its output is asserted directly against that fixed shape rather than
# against a second copy of status.sh — a copy sourced from any git ref goes
# stale the moment this branch's own commit becomes that ref's HEAD.
mp67="$WORK/manual-parity"
mkdir -p "$mp67"
"$NODE" init --preset software-development --mode track-all --indexes manual "$mp67" >/dev/null 2>&1
finish_bootstrap "$mp67"
"$mp67/.agent/scripts/status.sh" --load "$mp67" >"$WORK/mp67.cur.out" 2>&1

mp67_order=$(grep -n '^==== ' "$WORK/mp67.cur.out" | cut -d: -f2 | tr '\n' ' ')
[ "$mp67_order" = "==== .agent/rules/learned.md ==== ==== .agent/rules/contract.md ==== ==== .agent/purpose.md ==== ==== .agent/memory.md ==== " ] \
  && pass "manual mode: --load prints the four canonical markers, learned, contract, purpose, memory, in order" \
  || fail "manual mode: --load prints the four canonical markers, learned, contract, purpose, memory, in order ($mp67_order)"

grep -qE '^PAYLOAD: --load would write [0-9]+ bytes of a [0-9]+ byte budget \(learned [0-9]+, contract [0-9]+, purpose [0-9]+, memory [0-9]+\)$' "$WORK/mp67.cur.out" \
  && pass "manual mode: PAYLOAD: line frames all four files, learned first" \
  || fail "manual mode: PAYLOAD: line frames all four files, learned first"

# The marker segment itself — everything from the blank line before the
# first marker onward — is rebuilt here from the fixture's own four files
# and the "\n==== <path> ====\n" + file-body sequence documented above
# status.sh's --load loop, then compared byte for byte against what --load
# actually wrote, so any dropped, reordered, duplicated, or reformatted
# body in that sequence still fails this check.
mp67_expected="$WORK/mp67.expected-tail.out"
: >"$mp67_expected"
for mp67_f in rules/learned.md rules/contract.md purpose.md memory.md; do
  printf '\n==== .agent/%s ====\n' "$mp67_f" >>"$mp67_expected"
  cat "$mp67/.agent/$mp67_f" >>"$mp67_expected"
done
mp67_marker_line=$(grep -n '^==== ' "$WORK/mp67.cur.out" | head -1 | cut -d: -f1)
mp67_actual="$WORK/mp67.actual-tail.out"
tail -n "+$((mp67_marker_line - 1))" "$WORK/mp67.cur.out" >"$mp67_actual"
cmp -s "$mp67_expected" "$mp67_actual" \
  && pass "manual mode: --load's marker segment matches the fixture's own files byte for byte" \
  || fail "manual mode: --load's marker segment matches the fixture's own files byte for byte"

# Template phrases: the same fixed strings written into
# templates/entry-point-generated.md in this task's rewrite, mirroring the
# manual template's own timing/boundary phrase check.
tplgen67="$reporoot/templates/entry-point-generated.md"
missing67=""
grep -qF "run once" "$tplgen67" || grep -qF "runs once" "$tplgen67" || missing67="$missing67 once-per-session"
grep -qF "Do not open this file with a tool when its content is already present in your context." "$tplgen67" || missing67="$missing67 no-reopen-from-disk"
grep -qF "compaction" "$tplgen67" || missing67="$missing67 compaction-rerun"
grep -qF "branch switch" "$tplgen67" || missing67="$missing67 branch-switch-rerun"
grep -qF "opened only to edit it, to check its provenance, or to resolve a concrete uncertainty" "$tplgen67" || missing67="$missing67 rule-source"
grep -qF "the catalog, read whole" "$tplgen67" || missing67="$missing67 routes-catalog"
grep -qF "read \`.agent/rules/\` and \`.agent/docs/architecture.md\` directly and carry on" "$tplgen67" || missing67="$missing67 fallback"
[ -z "$missing67" ] && pass "template: the generated entry point carries its timing, routing, and fallback phrases" || fail "template: the generated entry point carries its timing, routing, and fallback phrases (missing:$missing67)"

# Exclusions: rules/quality-bar.md (split out by the bootstrap helper) and
# every references/ record, at either docs/ level, must render into no
# page and route into no line, while an ordinary rule record and an
# ordinary routed doc both stay reachable.
ex67="$WORK/read-set-exclusions"
mkdir -p "$ex67"
"$NODE" init --preset software-development --mode track-all --indexes generated "$ex67" >/dev/null 2>&1
finish_bootstrap "$ex67"
mkdir -p "$ex67/.agent/docs/area/references" "$ex67/.agent/docs/references"
printf '# Architecture\n\nRouting table placeholder.\n' >"$ex67/.agent/docs/architecture.md"
printf '# Ordinary Doc\n<!-- Read when: testing exclusions -->\nOrdinary doc body.\n' >"$ex67/.agent/docs/ordinary.md"
printf '# Area Reference\n<!-- Read when: never routed -->\nArea reference body, never a routes line.\n' >"$ex67/.agent/docs/area/references/one.md"
printf '# Top Reference\n<!-- Read when: never routed -->\nTop-level reference body, never a routes line.\n' >"$ex67/.agent/docs/references/two.md"
"$IDXSH" ensure --root "$ex67" >/dev/null 2>"$WORK/ex67.err"
ex67_gen=$(sed -n 2p "$ex67/.agent/indexes/current.md")
ex67_dir="$ex67/.agent/indexes/$ex67_gen"

grep -qrF -- 'This rubric loads on demand' "$ex67_dir" \
  && fail "exclusions: no published page carries rules/quality-bar.md's body" \
  || pass "exclusions: no published page carries rules/quality-bar.md's body"
grep -hF -- 'READ:' "$ex67_dir"/routes-*.md 2>/dev/null | grep -qF 'docs/area/references/one.md' \
  && fail "exclusions: no routes line names the area-level references/ file" \
  || pass "exclusions: no routes line names the area-level references/ file"
grep -hF -- 'READ:' "$ex67_dir"/routes-*.md 2>/dev/null | grep -qF 'docs/references/two.md' \
  && fail "exclusions: no routes line names the top-level references/ file" \
  || pass "exclusions: no routes line names the top-level references/ file"
grep -qrF -- 'filled at bootstrap' "$ex67_dir" \
  && pass "exclusions: an ordinary rule record is still reachable from the entry file" \
  || fail "exclusions: an ordinary rule record is still reachable from the entry file"
grep -hF -- 'READ:' "$ex67_dir"/routes-*.md 2>/dev/null | grep -qF 'docs/ordinary.md' \
  && pass "exclusions: an ordinary routed doc is still reachable from the entry file" \
  || fail "exclusions: an ordinary routed doc is still reachable from the entry file"

# Branch-switch staleness: a record changed after a commit and a branch
# makes check report STALE, purely from the content-hash fingerprint — no
# git-specific mechanism — and the next ensure republishes.
bs67="$WORK/read-set-branch-stale"
mkdir -p "$bs67"
"$NODE" init --preset software-development --mode track-all --indexes generated "$bs67" >/dev/null 2>&1
finish_bootstrap "$bs67"
git -C "$bs67" init -q
git -C "$bs67" config user.name Tester
git -C "$bs67" config user.email tester@example.invalid
git -C "$bs67" add -A
git -C "$bs67" commit -qm bootstrap
"$IDXSH" ensure --root "$bs67" >/dev/null 2>/dev/null
bs67_gen1=$(sed -n 2p "$bs67/.agent/indexes/current.md")

git -C "$bs67" checkout -qb bs67-branch
printf -- '\n- Test: run this every time.\n' >>"$bs67/.agent/rules/contract.md"
git -C "$bs67" add -A
git -C "$bs67" commit -qm 'change a rule record'

bs67_check=$("$IDXSH" check --root "$bs67" 2>/dev/null)
[ "$bs67_check" = "STALE" ] \
  && pass "branch switch: index.sh check reports STALE after a record changes on a new branch" \
  || fail "branch switch: index.sh check reports STALE after a record changes on a new branch ($bs67_check)"

"$IDXSH" ensure --root "$bs67" >/dev/null 2>"$WORK/bs67.second.err"
bs67_gen2=$(sed -n 2p "$bs67/.agent/indexes/current.md")
grep -q '^BUILT$' "$WORK/bs67.second.err" \
  && pass "branch switch: the next ensure republishes" \
  || fail "branch switch: the next ensure republishes"
[ "$bs67_gen1" != "$bs67_gen2" ] \
  && pass "branch switch: the republished generation differs from the pre-switch one" \
  || fail "branch switch: the republished generation differs from the pre-switch one"

# A failed ensure leaves the published entry byte-identical, following the
# existing failed-ensure fixture's idiom (INDEX_FAIL_AT=before-publish).
fe67="$WORK/read-set-failed-ensure"
mkdir -p "$fe67"
"$NODE" init --preset software-development --mode track-all --indexes generated "$fe67" >/dev/null 2>&1
finish_bootstrap "$fe67"
"$IDXSH" ensure --root "$fe67" >/dev/null 2>&1
fe67_entry_before=$(cat "$fe67/.agent/indexes/current.md")
printf -- '\n- Test: trigger a rebuild.\n' >>"$fe67/.agent/rules/contract.md"
INDEX_FAIL_AT=before-publish "$IDXSH" ensure --root "$fe67" >/dev/null 2>"$WORK/fe67.err"
fe67_rc=$?
[ "$fe67_rc" -eq 1 ] && grep -q 'FALLBACK:' "$WORK/fe67.err" \
  && pass "failed ensure: an injected failure before publication is reported and exits 1" \
  || fail "failed ensure: an injected failure before publication is reported and exits 1"
[ "$(cat "$fe67/.agent/indexes/current.md")" = "$fe67_entry_before" ] \
  && pass "failed ensure: the published entry stays byte-identical after a failed ensure" \
  || fail "failed ensure: the published entry stays byte-identical after a failed ensure"

# ---- 68. status.sh: rules/learned/ as the canonical source, cache faults
# never become findings; checkpoint.sh refreshes the cache in generated
# mode only ----

# (a) A generated node whose learned rules live only in rules/learned/,
# with no aggregate published, draws no REPAIR: or GROOM: naming
# rules/learned.md.
c68a="$WORK/canonical-records-only"
mkdir -p "$c68a"
"$NODE" init --preset software-development --mode track-all --indexes generated "$c68a" >/dev/null 2>&1
finish_bootstrap "$c68a"
rm -f "$c68a/.agent/rules/learned.md"
mkdir -p "$c68a/.agent/rules/learned"
printf -- '- [2026-01-01] Record one.\n' >"$c68a/.agent/rules/learned/0001.md"
f68a=$(status_flags "$c68a")
[ -z "$f68a" ] && pass "canonical source: a record-only node draws no REPAIR: or GROOM: naming rules/learned.md" \
  || fail "canonical source: a record-only node draws no REPAIR: or GROOM: naming rules/learned.md ($f68a)"

# (b) A node with an empty rules/learned/ directory and no aggregate still
# draws exactly the record-directory REPAIR:, naming what to restore.
c68b="$WORK/canonical-neither"
mkdir -p "$c68b"
"$NODE" init --preset software-development --mode track-all --indexes generated "$c68b" >/dev/null 2>&1
finish_bootstrap "$c68b"
rm -f "$c68b/.agent/rules/learned.md"
mkdir -p "$c68b/.agent/rules/learned"
f68b=$(status_flags "$c68b")
[ "$f68b" = "REPAIR: rules/learned/ missing/empty — restore the records, or rules/learned.md on a node that keeps no record directory; the entry point loads them every session" ] \
  && pass "canonical source: an empty rules/learned/ and no aggregate draws exactly the record-directory REPAIR:" \
  || fail "canonical source: an empty rules/learned/ and no aggregate draws exactly the record-directory REPAIR: ($f68b)"

# (b2) A node whose rules/learned/ holds a non-.md file and no aggregate
# still draws exactly the record-directory REPAIR:, same as an empty
# directory.
c68b2="$WORK/canonical-neither-nonmd"
mkdir -p "$c68b2"
"$NODE" init --preset software-development --mode track-all --indexes generated "$c68b2" >/dev/null 2>&1
finish_bootstrap "$c68b2"
rm -f "$c68b2/.agent/rules/learned.md"
mkdir -p "$c68b2/.agent/rules/learned"
printf -- 'not a record\n' >"$c68b2/.agent/rules/learned/notes.txt"
f68b2=$(status_flags "$c68b2")
[ "$f68b2" = "REPAIR: rules/learned/ missing/empty — restore the records, or rules/learned.md on a node that keeps no record directory; the entry point loads them every session" ] \
  && pass "canonical source: a rules/learned/ holding only a non-.md file and no aggregate draws exactly the record-directory REPAIR:" \
  || fail "canonical source: a rules/learned/ holding only a non-.md file and no aggregate draws exactly the record-directory REPAIR: ($f68b2)"

# (c) A record set crossing LEARNED_MAX_RULES draws the rules/learned/
# GROOM:, at the same count the equivalent aggregate draws its own.
c68c="$WORK/canonical-threshold-records"
mkdir -p "$c68c"
"$NODE" init --preset software-development --mode track-all --indexes generated "$c68c" >/dev/null 2>&1
finish_bootstrap "$c68c"
rm -f "$c68c/.agent/rules/learned.md"
mkdir -p "$c68c/.agent/rules/learned"
i68c=1
while [ "$i68c" -le 61 ]; do
  printf -- '- [2026-01-01] Rule %s.\n' "$i68c" >"$c68c/.agent/rules/learned/$(printf '%04d' "$i68c").md"
  i68c=$((i68c + 1))
done
f68c=$(status_flags "$c68c")
printf '%s\n' "$f68c" | grep -qF 'GROOM: rules/learned/ > 60 rules' \
  && pass "canonical source: 61 one-bullet records cross LEARNED_MAX_RULES and draw the rules/learned/ GROOM:" \
  || fail "canonical source: 61 one-bullet records cross LEARNED_MAX_RULES and draw the rules/learned/ GROOM: ($f68c)"

c68d="$WORK/canonical-threshold-aggregate"
mkdir -p "$c68d"
"$NODE" init --preset software-development --mode track-all --indexes generated "$c68d" >/dev/null 2>&1
finish_bootstrap "$c68d"
i68d=1
while [ "$i68d" -le 61 ]; do
  printf -- '- [2026-01-01] Rule %s.\n' "$i68d" >>"$c68d/.agent/rules/learned.md"
  i68d=$((i68d + 1))
done
f68d=$(status_flags "$c68d")
printf '%s\n' "$f68d" | grep -qF 'GROOM: learned.md > 60 rules' \
  && pass "canonical source: the equivalent aggregate crosses the same 61-record ceiling and draws its own GROOM:" \
  || fail "canonical source: the equivalent aggregate crosses the same 61-record ceiling and draws its own GROOM: ($f68d)"

# (d) No status.sh finding ever names a path under .agent/indexes/, whether
# the cache is absent, empty, or holds a damaged generation.
d68="$WORK/cache-fault-paths"
mkdir -p "$d68"
"$NODE" init --preset software-development --mode track-all --indexes generated "$d68" >/dev/null 2>&1
finish_bootstrap "$d68"
f68e1=$(status_flags "$d68")
printf '%s\n' "$f68e1" | grep -q '\.agent/indexes/' \
  && fail "cache fault: no finding names .agent/indexes/ with the cache absent" \
  || pass "cache fault: no finding names .agent/indexes/ with the cache absent"

mkdir -p "$d68/.agent/indexes"
f68e2=$(status_flags "$d68")
printf '%s\n' "$f68e2" | grep -q '\.agent/indexes/' \
  && fail "cache fault: no finding names .agent/indexes/ with an empty cache directory" \
  || pass "cache fault: no finding names .agent/indexes/ with an empty cache directory"

"$IDXSH" ensure --root "$d68" >/dev/null 2>&1
d68gen=$(sed -n 2p "$d68/.agent/indexes/current.md")
printf 'damage\n' >>"$d68/.agent/indexes/$d68gen/rules-1.md"
f68e3=$(status_flags "$d68")
printf '%s\n' "$f68e3" | grep -q '\.agent/indexes/' \
  && fail "cache fault: no finding names .agent/indexes/ with a damaged generation" \
  || pass "cache fault: no finding names .agent/indexes/ with a damaged generation"

# (e) A generated hand-back refreshes the cache after the clean status
# check, and the log entry is still appended exactly once.
e68="$WORK/finish-cache-refresh"
mkdir -p "$e68/src"
"$NODE" init --preset software-development --mode track-all --indexes generated "$e68" >/dev/null 2>&1
finish_bootstrap "$e68"
printf 'export const a = 1\n' >"$e68/src/a.ts"
git -C "$e68" init -q && git -C "$e68" add -A && git -C "$e68" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m base
"$IDXSH" ensure --root "$e68" >/dev/null 2>&1
e68_before=$(idx_mtime "$e68/.agent/indexes/current.md")
sleep 1
"$e68/.agent/scripts/docs.sh" new --name backend --read-when "backend services" "$e68" >/dev/null 2>&1
printf '// Vendor caps retries at three by contract; a fourth attempt is rejected upstream.\nexport const b = 2\n' >"$e68/src/a.ts"
out68e=$("$e68/.agent/scripts/checkpoint.sh" --tool claude --area testing --verify pass --summary "generated hand-back" "$e68" 2>&1)
rc68e=$?
n68e=$(grep -c '^- \[' "$e68/.agent/session-log.md")
e68_after=$(idx_mtime "$e68/.agent/indexes/current.md")
[ "$rc68e" -eq 0 ] && [ "$n68e" -eq 1 ] && printf '%s' "$out68e" | grep -qF '== cache refresh' \
  && pass "checkpoint.sh: a generated hand-back runs the cache refresh step and logs exactly once" \
  || fail "checkpoint.sh: a generated hand-back runs the cache refresh step and logs exactly once (rc=$rc68e entries=$n68e)"
[ "$e68_after" -gt "$e68_before" ] \
  && pass "checkpoint.sh: the cache refresh leaves current.md newer than the pre-run state" \
  || fail "checkpoint.sh: the cache refresh leaves current.md newer than the pre-run state (before=$e68_before after=$e68_after)"

# (f) A failing index.sh and an absent index.sh each leave checkpoint.sh's
# exit status and log entry unchanged, with exactly one checkpoint.sh:
# warning line naming the canonical directories.
f68="$WORK/finish-cache-fault"
mkdir -p "$f68/src"
"$NODE" init --preset software-development --mode track-all --indexes generated "$f68" >/dev/null 2>&1
finish_bootstrap "$f68"
printf 'export const a = 1\n' >"$f68/src/a.ts"
git -C "$f68" init -q && git -C "$f68" add -A && git -C "$f68" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m base
n68f0=$(grep -c '^- \[' "$f68/.agent/session-log.md")

"$f68/.agent/scripts/docs.sh" new --name frontend --read-when "frontend widgets" "$f68" >/dev/null 2>&1
printf '// Vendor caps retries at three by contract; a fourth attempt is rejected upstream.\nexport const b = 2\n' >"$f68/src/a.ts"
INDEX_FAIL_AT=before-publish "$f68/.agent/scripts/checkpoint.sh" --tool claude --area testing --verify pass --summary "injected index failure" "$f68" >/dev/null 2>"$WORK/f68.err"
rc68f=$?
n68f1=$(grep -c '^- \[' "$f68/.agent/session-log.md")
f68_warn=$(grep -c '^checkpoint.sh: ' "$WORK/f68.err")
[ "$rc68f" -eq 0 ] && [ "$n68f1" -eq "$((n68f0 + 1))" ] && [ "$f68_warn" -eq 1 ] \
  && grep -qF '.agent/rules/' "$WORK/f68.err" && grep -qF '.agent/docs/' "$WORK/f68.err" \
  && pass "checkpoint.sh: a failing index.sh leaves exit status and log entry unchanged, with one warning line" \
  || fail "checkpoint.sh: a failing index.sh leaves exit status and log entry unchanged, with one warning line (rc=$rc68f entries=$n68f1 warn=$f68_warn)"

rm -f "$f68/.agent/scripts/index.sh"
printf '// Vendor caps retries at three by contract; a fourth attempt is rejected upstream.\nexport const c = 3\n' >"$f68/src/a.ts"
"$f68/.agent/scripts/checkpoint.sh" --tool claude --area testing --verify pass --summary "absent indexer" "$f68" >/dev/null 2>"$WORK/f68g.err"
rc68g=$?
n68g=$(grep -c '^- \[' "$f68/.agent/session-log.md")
f68g_warn=$(grep -c '^checkpoint.sh: ' "$WORK/f68g.err")
[ "$rc68g" -eq 0 ] && [ "$n68g" -eq "$((n68f0 + 2))" ] && [ "$f68g_warn" -eq 1 ] \
  && grep -qF '.agent/rules/' "$WORK/f68g.err" && grep -qF '.agent/docs/' "$WORK/f68g.err" \
  && pass "checkpoint.sh: an absent index.sh leaves exit status and log entry unchanged, with one warning line" \
  || fail "checkpoint.sh: an absent index.sh leaves exit status and log entry unchanged, with one warning line (rc=$rc68g entries=$n68g warn=$f68g_warn)"

# (g) A manual-mode node runs no refresh: its output matches the fixed
# pre-change shape exactly, and no .agent/indexes/ directory ever appears.
g68="$WORK/finish-manual-parity"
mkdir -p "$g68/src"
"$NODE" init --preset software-development --mode track-all "$g68" >/dev/null 2>&1
finish_bootstrap "$g68"
printf 'export const a = 1\n' >"$g68/src/a.ts"
git -C "$g68" init -q && git -C "$g68" add -A && git -C "$g68" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m base
printf 'export const a = 1\nexport const b = 2\n' >"$g68/src/a.ts"
g68_expected=$(printf '== comment gate (comments.sh HEAD)\n== status check\nclean\n== session log\nlog.sh: appended session-log entry for %s' "$(today)")
g68_actual=$("$g68/.agent/scripts/checkpoint.sh" --tool claude --area testing --verify pass --summary "manual mode, no refresh" "$g68" 2>&1)
rc68g2=$?
[ "$rc68g2" -eq 0 ] && [ "$g68_actual" = "$g68_expected" ] \
  && pass "checkpoint.sh: a manual-mode node's output matches its pre-change shape exactly, no cache-refresh step" \
  || fail "checkpoint.sh: a manual-mode node's output matches its pre-change shape exactly, no cache-refresh step ($g68_actual)"
[ ! -d "$g68/.agent/indexes" ] \
  && pass "checkpoint.sh: a manual-mode node grows no .agent/indexes/ directory" \
  || fail "checkpoint.sh: a manual-mode node grows no .agent/indexes/ directory"

# (h) The comment gate still excludes Markdown and .agent/, proved by a
# fixture whose only change is a Markdown file under .agent/.
h68="$WORK/finish-markdown-exclusion"
mkdir -p "$h68/src"
"$NODE" init --preset software-development --mode track-all "$h68" >/dev/null 2>&1
finish_bootstrap "$h68"
printf 'export const a = 1\n' >"$h68/src/a.ts"
git -C "$h68" init -q && git -C "$h68" add -A && git -C "$h68" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m base
printf '\nfor this pass, cache the response for five minutes.\n' >>"$h68/.agent/memory.md"
n68h0=$(grep -c '^- \[' "$h68/.agent/session-log.md")
out68h=$("$h68/.agent/scripts/checkpoint.sh" --tool claude --area testing --verify pass --summary "markdown-only change under .agent/" "$h68" 2>&1)
rc68h=$?
n68h1=$(grep -c '^- \[' "$h68/.agent/session-log.md")
[ "$rc68h" -eq 0 ] && [ "$n68h1" -eq "$((n68h0 + 1))" ] && ! printf '%s' "$out68h" | grep -q 'BLOCK' \
  && pass "checkpoint.sh: the comment gate still excludes Markdown and .agent/, a Markdown-only .agent/ change reaches the log entry" \
  || fail "checkpoint.sh: the comment gate still excludes Markdown and .agent/, a Markdown-only .agent/ change reaches the log entry (rc=$rc68h entries=$n68h1)"

# ---- 69. skills: the mechanical half of the authoring bar over every
# tools/skills/*/SKILL.md description ----
# The judged half (does "what" and "when" actually hold) stays a human
# read. What a script can check: a when-to-use clause is present, a
# colon-bearing value is quoted, no second person, and the byte budget.
g69_usewhen=""
g69_quoted=""
g69_2ndperson=""
g69_budget=""
g69_desc_of() { sed -n 's/^description: //p' "$1" | head -n 1; }
for g69_file in "$reporoot"/tools/skills/*/SKILL.md; do
  [ -e "$g69_file" ] || continue
  g69_rel=${g69_file#"$reporoot"/}
  g69_desc=$(g69_desc_of "$g69_file")
  printf '%s' "$g69_desc" | grep -qE 'Use (when|after|before|for|during|whenever) ' \
    || g69_usewhen="$g69_usewhen $g69_rel"
  case "$g69_desc" in
  *:*)
    case "$g69_desc" in
    \"*) ;;
    *) g69_quoted="$g69_quoted $g69_rel" ;;
    esac
    ;;
  esac
  printf '%s' "$g69_desc" | grep -qiE '\byou\b|\byour\b' && g69_2ndperson="$g69_2ndperson $g69_rel"
  g69_bytes=$(printf '%s' "$g69_desc" | LC_ALL=C wc -c | tr -d '[:space:]')
  [ "$g69_bytes" -gt 440 ] && g69_budget="$g69_budget $g69_rel($g69_bytes)"
done
[ -z "$g69_usewhen" ] && pass "skills: every SKILL.md description carries a when-to-use clause" \
  || fail "skills: every SKILL.md description carries a when-to-use clause ($g69_usewhen)"
[ -z "$g69_quoted" ] && pass "skills: a description holding a colon is a quoted YAML value" \
  || fail "skills: a description holding a colon is a quoted YAML value ($g69_quoted)"
[ -z "$g69_2ndperson" ] && pass "skills: no SKILL.md description addresses the reader in the second person" \
  || fail "skills: no SKILL.md description addresses the reader in the second person ($g69_2ndperson)"
[ -z "$g69_budget" ] && pass "skills: every SKILL.md description stays inside the description budget" \
  || fail "skills: every SKILL.md description stays inside the description budget ($g69_budget)"

# The checks above must be able to fail, or a description that violates
# every rule at once reads as clean.
g69_bad="$WORK/g69-bad-skill/SKILL.md"
mkdir -p "$(dirname "$g69_bad")"
g69_longtail=$(words_n 200)
printf 'description: Your favorite: %s\n' "$g69_longtail" >"$g69_bad"
g69_baddesc=$(g69_desc_of "$g69_bad")
g69_badhits=0
printf '%s' "$g69_baddesc" | grep -qE 'Use (when|after|before|for|during|whenever) ' || g69_badhits=$((g69_badhits + 1))
case "$g69_baddesc" in
*:*) case "$g69_baddesc" in \"*) ;; *) g69_badhits=$((g69_badhits + 1)) ;; esac ;;
esac
printf '%s' "$g69_baddesc" | grep -qiE '\byou\b|\byour\b' && g69_badhits=$((g69_badhits + 1))
g69_badbytes=$(printf '%s' "$g69_baddesc" | LC_ALL=C wc -c | tr -d '[:space:]')
[ "$g69_badbytes" -gt 440 ] && g69_badhits=$((g69_badhits + 1))
[ "$g69_badhits" -eq 4 ] && pass "skills: the description-bar checks catch a description that violates every rule at once" \
  || fail "skills: the description-bar checks catch a description that violates every rule at once (caught $g69_badhits/4)"

# ---- 70. groom skill: the generated-mode grooming procedure is documented ----
g70skill="$reporoot/tools/skills/groom/SKILL.md"
grep -qF 'Close a generated-mode pass with `.agent/scripts/index.sh ensure` before the `status.sh` re-run' "$g70skill" \
  && grep -qF 'rebuilt from those records and never edited' "$g70skill" \
  && pass "groom skill: a generated-mode pass edits records and closes with index.sh ensure" \
  || fail "groom skill: a generated-mode pass edits records and closes with index.sh ensure"
grep -qF 'A fold rewrites the record whose entry carries the earlier date and deletes the other record' "$g70skill" \
  && grep -qF 'lower-sorting filename surviving a tie on the same date' "$g70skill" \
  && pass "groom skill: a fold keeps the earlier-dated record and deletes the other" \
  || fail "groom skill: a fold keeps the earlier-dated record and deletes the other"
grep -qF 'A record fold, split, or move runs this same procedure' "$g70skill" \
  && grep -qF 'A dropped fact, qualifier, or source reference fails the pass' "$g70skill" \
  && pass "groom skill: a record fold, split, or move runs the anchor check" \
  || fail "groom skill: a record fold, split, or move runs the anchor check"

# ---- 71. groom: a groom-then-regenerate fixture over a migrated generated
# node — records edited, pages rebuilt, no page hand-edited ----
# Built on r61build plus node.sh update, the real migration chain, the
# same base section 61 uses. r61build's docs tree carries three
# deliberately unbackfillable entries (dup.md, badtable.md, noentry.md) that
# section 61 needs and this fixture does not, so they are trimmed to a
# clean architecture.md before update runs — otherwise their pre-existing
# INDEX: noise would survive every assertion below and mask what grooming
# actually changed.
g71_trim_docs() {
  g71td_dir="$1"
  rm -f "$g71td_dir/.agent/docs/dup.md" "$g71td_dir/.agent/docs/badtable.md" "$g71td_dir/.agent/docs/noentry.md"
  cat >"$g71td_dir/.agent/docs/architecture.md" <<'EOF'
# Architecture

### `hooked.md`
- **Read when:** already hooked, never touched.

### `unhooked.md`
- **Read when:** doing unhooked work.

### `area/sub.md`
- **Read when:** doing area sub work.
EOF
}

g71="$WORK/groom-then-regenerate"
r61build "$g71"
g71_trim_docs "$g71"
"$NODE" update "$g71" >"$WORK/g71-update.out" 2>&1
g71rc=$?
"$NODE" finalize "$g71" >"$WORK/g71-finalize.out" 2>&1
[ "$g71rc" -eq 0 ] && [ -z "$(status_flags "$g71")" ] \
  && pass "groom fixture: the trimmed, finalized migrated node starts status-clean" \
  || fail "groom fixture: the trimmed, finalized migrated node starts status-clean ($(status_flags "$g71"))"

printf 'LEARNED_MAX_RULES=2\n' >>"$g71/.agent/scripts/status.conf"
g71_flagged=$(status_flags "$g71")
printf '%s\n' "$g71_flagged" | grep -q '^GROOM: rules/learned/ > 2 rules' \
  && pass "groom fixture: lowering LEARNED_MAX_RULES draws the learned-rules GROOM line" \
  || fail "groom fixture: lowering LEARNED_MAX_RULES draws the learned-rules GROOM line ($g71_flagged)"

g71r1=$(grep -lF 'First rule, flat' "$g71/.agent/rules/learned"/*.md)
g71r2=$(grep -lF 'nested sub-bullet' "$g71/.agent/rules/learned"/*.md)
g71r3=$(grep -lF 'multi paragraph' "$g71/.agent/rules/learned"/*.md)
g71r4=$(grep -lF 'Fourth rule, flat' "$g71/.agent/rules/learned"/*.md)

g71_idx_before=$(idx_snapshot "$g71/.agent/indexes")

[ "$(cat "$g71r4")" = '- [2026-01-04] Fourth rule, flat, last one.' ] \
  && pass "groom fixture: the record the pass does not touch is unchanged before grooming" \
  || fail "groom fixture: the record the pass does not touch is unchanged before grooming"

# Fold r1+r2 into r1 (earlier date), deleting r2. Move r3, an
# area-specific mechanic, to docs/area/sub.md under Gotchas, deleting r3.
printf -- '- [2026-01-01] First rule, flat, folded with the nested-sub-bullet rule. Trigger: something.\n' >"$g71r1"
rm -f "$g71r2"
printf '\n## Gotchas\n\n- Third rule, multi paragraph, moved from rules/learned/.\n' >>"$g71/.agent/docs/area/sub.md"
rm -f "$g71r3"
subst "$g71/.agent/docs/architecture.md" '/### `area\/sub.md`/,/^$/ { /Read when/a\
- **Sections:** Gotchas
}'

g71_idx_after=$(idx_snapshot "$g71/.agent/indexes")
[ "$g71_idx_before" = "$g71_idx_after" ] \
  && pass "groom: a groomed record set republishes with no hand edit under .agent/indexes/" \
  || fail "groom: a groomed record set republishes with no hand edit under .agent/indexes/"

"$IDXSH" ensure --root "$g71" >"$WORK/g71-ensure.out" 2>&1
g71ensurerc=$?
[ "$g71ensurerc" -eq 0 ] && pass "groom fixture: index.sh ensure republishes after the record edits" \
  || fail "groom fixture: index.sh ensure republishes after the record edits (rc=$g71ensurerc)"
g71gen=$(sed -n 2p "$g71/.agent/indexes/current.md")
g71gendir="$g71/.agent/indexes/$g71gen"

grep -qF 'folded with the nested-sub-bullet rule' "$g71gendir"/rules-*.md \
  && ! grep -qF 'Second rule with a nested sub-bullet' "$g71gendir"/rules-*.md \
  && ! grep -qF 'Third rule, multi paragraph' "$g71gendir"/rules-*.md \
  && grep -qF 'Fourth rule, flat, last one.' "$g71gendir"/rules-*.md \
  && pass "groom fixture: the regenerated rules page carries the folded rule, not the deleted records' text" \
  || fail "groom fixture: the regenerated rules page carries the folded rule, not the deleted records' text"

g71_docs_target=$(grep -F 'area/sub.md' "$g71gendir"/routes-*.md | sed -n 's/.*READ: //p' | head -n1)
[ -n "$g71_docs_target" ] && [ -f "$g71_docs_target" ] && grep -qF 'Third rule, multi paragraph, moved from rules/learned/.' "$g71_docs_target" \
  && pass "groom fixture: the docs page's routing entry resolves to the doc carrying the moved rule" \
  || fail "groom fixture: the docs page's routing entry resolves to the doc carrying the moved rule"

g71_after_flags=$(status_flags "$g71")
[ -z "$g71_after_flags" ] \
  && pass "groom fixture: status.sh is clear once the fold, deletion, and move are done" \
  || fail "groom fixture: status.sh is clear once the fold, deletion, and move are done ($g71_after_flags)"

# ---- 72. groom: a fold-and-delete on one branch and an independent record
# edit on another merge with both changes, and the integrated merge/replay
# fixtures (section 64) re-run unchanged against a groomed node ----
g72="$WORK/mig-groomed-base"
r61build "$g72"
g71_trim_docs "$g72"
sed "s/^  mode: ignore-all/  mode: track-shared/" "$g72/.agent/purpose.md" >"$g72/.agent/purpose.md.tmp"
mv "$g72/.agent/purpose.md.tmp" "$g72/.agent/purpose.md"
git -C "$g72" init -q
git -C "$g72" config user.name Tester
git -C "$g72" config user.email tester@example.invalid
git -C "$g72" add .agent
git -C "$g72" commit -qm initial
"$NODE" update "$g72" >/dev/null 2>&1
git -C "$g72" add -A
git -C "$g72" commit -qm "post-migration state"
"$NODE" finalize "$g72" >/dev/null 2>&1
git -C "$g72" add -A
git -C "$g72" commit -qm finalize --allow-empty
g72pre=$(git -C "$g72" symbolic-ref --short HEAD)

g72r1=$(grep -lF 'First rule, flat' "$g72/.agent/rules/learned"/*.md)
g72r2=$(grep -lF 'nested sub-bullet' "$g72/.agent/rules/learned"/*.md)
g72r4=$(grep -lF 'Fourth rule, flat' "$g72/.agent/rules/learned"/*.md)
g72r1rel=${g72r1#"$g72"/}
g72r2rel=${g72r2#"$g72"/}
g72r4rel=${g72r4#"$g72"/}

# Regroup: fold the first and second learned rules into the earlier-dated
# record and delete the other, on one branch; independently edit the
# fourth, unrelated record, on another.
git -C "$g72" checkout -qb regroup "$g72pre"
printf -- '- [2026-01-01] First rule, flat, folded with the nested-sub-bullet rule. Trigger: something.\n' >"$g72/$g72r1rel"
git -C "$g72" rm -q "$g72r2rel"
git -C "$g72" commit -qam "groom: fold first and second learned rules into the earlier-dated record"

git -C "$g72" checkout -q "$g72pre"
git -C "$g72" checkout -qb otheredit "$g72pre"
printf -- '- [2026-01-04] Fourth rule, flat, independently reworded post-groom.\n' >"$g72/$g72r4rel"
git -C "$g72" commit -qam "independent edit to the fourth record"

git -C "$g72" checkout -qb merge-regroup "$g72pre"
git -C "$g72" merge -q --no-edit regroup >"$WORK/g72-merge1.out" 2>&1
g72mrc1=$?
git -C "$g72" merge -q --no-edit otheredit >"$WORK/g72-merge2.out" 2>&1
g72mrc2=$?
[ "$g72mrc1" -eq 0 ] && [ "$g72mrc2" -eq 0 ] \
  && pass "groom: a fold on one branch and an independent record edit on another merge with both changes" \
  || fail "groom: a fold on one branch and an independent record edit on another merge with both changes"

grep -qF 'folded with the nested-sub-bullet rule' "$g72/$g72r1rel" \
  && pass "groom: the fold's surviving record carries the folded content after the merge" \
  || fail "groom: the fold's surviving record carries the folded content after the merge"
[ ! -e "$g72/$g72r2rel" ] \
  && pass "groom: the record folded away stays deleted after the merge" \
  || fail "groom: the record folded away stays deleted after the merge"
grep -qF 'independently reworded post-groom' "$g72/$g72r4rel" \
  && pass "groom: the independently edited record's edit survives the merge" \
  || fail "groom: the independently edited record's edit survives the merge"

"$IDXSH" ensure --root "$g72" >/dev/null 2>&1
git -C "$g72" add -A
git -C "$g72" commit -qm "index refresh" --allow-empty
g72base=$(git -C "$g72" symbolic-ref --short HEAD)

[ -z "$(status_flags "$g72")" ] \
  && pass "groomed-node base: status.sh is clear once the groomed base is committed" \
  || fail "groomed-node base: status.sh is clear once the groomed base is committed ($(status_flags "$g72"))"

# Re-run section 64's three scenarios against the groomed base rather than
# the freshly-migrated one.
git -C "$g72" checkout -qb grecA "$g72base"
printf -- '- [2026-03-01] Branch A record, groomed base.\n' >"$g72/.agent/rules/learned/g72-branch-a.md"
git -C "$g72" add .agent/rules/learned/g72-branch-a.md
git -C "$g72" commit -qm "branch A record, groomed base"
git -C "$g72" checkout -q "$g72base"
git -C "$g72" checkout -qb grecB "$g72base"
printf -- '- [2026-03-02] Branch B record, groomed base.\n' >"$g72/.agent/rules/learned/g72-branch-b.md"
git -C "$g72" add .agent/rules/learned/g72-branch-b.md
git -C "$g72" commit -qm "branch B record, groomed base"
git -C "$g72" checkout -qb merge-ab "$g72base"
git -C "$g72" merge -q --no-edit grecA >/dev/null 2>&1
g72mrc3=$?
git -C "$g72" merge -q --no-edit grecB >/dev/null 2>&1
g72mrc4=$?
[ "$g72mrc3" -eq 0 ] && [ "$g72mrc4" -eq 0 ] \
  && pass "groomed node: two disjoint new records still merge clean" \
  || fail "groomed node: two disjoint new records still merge clean"
"$g72/.agent/scripts/index.sh" ensure --root "$g72" >/dev/null 2>&1
grep -qF 'Branch A record, groomed base.' "$g72/.agent/rules/learned.md" \
  && grep -qF 'Branch B record, groomed base.' "$g72/.agent/rules/learned.md" \
  && pass "groomed node: both merged records reach the regenerated aggregate" \
  || fail "groomed node: both merged records reach the regenerated aggregate"

git -C "$g72" checkout -q "$g72base"
g72cd_file=$(grep -lF 'Fourth rule, flat' "$g72/.agent/rules/learned"/*.md | head -n1)
g72cd_rel=${g72cd_file#"$g72"/}
git -C "$g72" checkout -qb geditC "$g72base"
printf -- '- [2026-01-04] Fourth rule, flat -- edited by C, groomed base.\n' >"$g72/$g72cd_rel"
git -C "$g72" commit -qam "branch C edit, groomed base"
git -C "$g72" checkout -qb geditD "$g72base"
printf -- '- [2026-01-04] Fourth rule, flat -- edited by D, groomed base.\n' >"$g72/$g72cd_rel"
git -C "$g72" commit -qam "branch D edit, groomed base"
git -C "$g72" checkout -qb merge-cd "$g72base"
git -C "$g72" merge -q --no-edit geditC >/dev/null 2>&1
g72mrc5=$?
git -C "$g72" merge -q --no-edit geditD >/dev/null 2>&1
g72mrc6=$?
[ "$g72mrc5" -eq 0 ] \
  && pass "groomed node: the first same-record edit still applies clean" \
  || fail "groomed node: the first same-record edit still applies clean"
[ "$g72mrc6" -ne 0 ] \
  && pass "groomed node: a second edit to the same record still conflicts rather than silently choosing a winner" \
  || fail "groomed node: a second edit to the same record still conflicts rather than silently choosing a winner"
git -C "$g72" merge --abort >/dev/null 2>&1

git -C "$g72" checkout -qb linear "$g72base"
printf -- '- [2026-03-03] Linear commit one, groomed base.\n' >"$g72/.agent/rules/learned/g72-linear-one.md"
git -C "$g72" add .agent/rules/learned/g72-linear-one.md
git -C "$g72" commit -qm "linear commit one, groomed base"
printf -- '- [2026-03-04] Linear commit two, groomed base.\n' >"$g72/.agent/rules/learned/g72-linear-two.md"
git -C "$g72" add .agent/rules/learned/g72-linear-two.md
git -C "$g72" commit -qm "linear commit two, groomed base"
"$g72/.agent/scripts/index.sh" ensure --root "$g72" >/dev/null 2>&1
grep -qF 'Linear commit one, groomed base.' "$g72/.agent/rules/learned.md" \
  && grep -qF 'Linear commit two, groomed base.' "$g72/.agent/rules/learned.md" \
  && pass "groomed node: both sequential commits' records still survive a linear replay" \
  || fail "groomed node: both sequential commits' records still survive a linear replay"

# ---- 73. learn.sh: the learned-record lookup and upsert helper ----
# Built on r61build plus node.sh update — a generated-mode node with a
# populated rules/learned/ directory, the same base sections 61-65 use.
lrn73="$WORK/learn-fixture"
r61build "$lrn73"
"$NODE" update "$lrn73" >/dev/null 2>&1
LRN="$lrn73/.agent/scripts/learn.sh"

lrn73_memdir_snapshot() { find "$1/.agent/memory" -type f | sort | xargs shasum 2>/dev/null | sort; }
lrn73_mem_before=$(lrn73_memdir_snapshot "$lrn73")
cp "$lrn73/.agent/memory.md" "$WORK/lrn73-memory-md-before.md"

lrn73_before_ids=$(find "$lrn73/.agent/rules/learned" -maxdepth 1 -name '*.md' | sort)
lrn73_pick=$(printf '%s\n' "$lrn73_before_ids" | head -n1)

# lookup: a byte-identical candidate reports duplicate, an overlapping one
# reports overlap, and lookup exits 0 either way.
lrn73_dup_out=$("$LRN" lookup --file "$lrn73_pick" "$lrn73" 2>"$WORK/lrn73-lookup.err")
lrn73_dup_rc=$?
[ "$lrn73_dup_rc" -eq 0 ] && pass "learn.sh: lookup exits 0" || fail "learn.sh: lookup exits 0 (rc=$lrn73_dup_rc)"
printf '%s\n' "$lrn73_dup_out" | grep -qF "duplicate	$lrn73_pick	" \
  && pass "learn.sh: lookup reports a byte-identical record as duplicate" \
  || fail "learn.sh: lookup reports a byte-identical record as duplicate ($lrn73_dup_out)"

printf -- '- [2026-01-09] First rule, flat, reworded slightly. Trigger: something.\n' >"$WORK/lrn73-overlap-cand.md"
lrn73_ov_out=$("$LRN" lookup --file "$WORK/lrn73-overlap-cand.md" "$lrn73" 2>/dev/null)
printf '%s\n' "$lrn73_ov_out" | grep -qF "overlap	$lrn73_pick	" \
  && pass "learn.sh: lookup reports a shared-term record as overlap" \
  || fail "learn.sh: lookup reports a shared-term record as overlap ($lrn73_ov_out)"

# new: writes a well-formed, non-overlapping candidate under a minted
# identity, verbatim.
printf -- '- [2026-01-10] Cache the compiled template before every render. Trigger: repeated recompilation.\n' >"$WORK/lrn73-new-cand.md"
lrn73_new_out=$("$LRN" new --file "$WORK/lrn73-new-cand.md" "$lrn73" 2>"$WORK/lrn73-new.err")
lrn73_new_rc=$?
[ "$lrn73_new_rc" -eq 0 ] && pass "learn.sh: new exits 0 on a well-formed, non-overlapping candidate" || fail "learn.sh: new exits 0 on a well-formed, non-overlapping candidate (rc=$lrn73_new_rc)"
lrn73_new_id=$(printf '%s\n' "$lrn73_new_out" | awk -F'\t' '{print $2}')
[ -f "$lrn73/.agent/rules/learned/$lrn73_new_id.md" ] && pass "learn.sh: new writes the record under its printed id" || fail "learn.sh: new writes the record under its printed id"
diff -q "$WORK/lrn73-new-cand.md" "$lrn73/.agent/rules/learned/$lrn73_new_id.md" >/dev/null 2>&1 \
  && pass "learn.sh: the written record is byte-identical to the candidate" \
  || fail "learn.sh: the written record is byte-identical to the candidate"

case "$lrn73_new_id" in
[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
  pass "learn.sh: new mints a 12-character lowercase-hex identity" ;;
*)
  fail "learn.sh: new mints a 12-character lowercase-hex identity ($lrn73_new_id)" ;;
esac

# new: exact-duplicate refusal (exit 5), naming the record, writing nothing.
"$LRN" new --file "$WORK/lrn73-new-cand.md" "$lrn73" >"$WORK/lrn73-dup.out" 2>"$WORK/lrn73-dup.err"
lrn73_dupnew_rc=$?
[ "$lrn73_dupnew_rc" -eq 5 ] && pass "learn.sh: new refuses an exact duplicate at exit 5" || fail "learn.sh: new refuses an exact duplicate at exit 5 (rc=$lrn73_dupnew_rc)"
grep -qF "$lrn73_new_id.md" "$WORK/lrn73-dup.err" \
  && pass "learn.sh: the duplicate refusal names the record that already holds it" \
  || fail "learn.sh: the duplicate refusal names the record that already holds it"

# new: shared-term overlap refuses at exit 4 without --distinct, naming the
# overlap; --distinct admits it.
"$LRN" new --file "$WORK/lrn73-overlap-cand.md" "$lrn73" >"$WORK/lrn73-ov.out" 2>"$WORK/lrn73-ov.err"
lrn73_ovnew_rc=$?
[ "$lrn73_ovnew_rc" -eq 4 ] && pass "learn.sh: new refuses a shared-term overlap without --distinct at exit 4" || fail "learn.sh: new refuses a shared-term overlap without --distinct at exit 4 (rc=$lrn73_ovnew_rc)"
grep -qF "$lrn73_pick" "$WORK/lrn73-ov.err" \
  && pass "learn.sh: the overlap refusal names the overlapping record" \
  || fail "learn.sh: the overlap refusal names the overlapping record"
lrn73_distinct_out=$("$LRN" new --file "$WORK/lrn73-overlap-cand.md" --distinct "$lrn73" 2>"$WORK/lrn73-distinct.err")
lrn73_distinct_rc=$?
[ "$lrn73_distinct_rc" -eq 0 ] && pass "learn.sh: --distinct admits an overlapping candidate anyway" || fail "learn.sh: --distinct admits an overlapping candidate anyway (rc=$lrn73_distinct_rc)"
printf '%s\n' "$lrn73_distinct_out" | grep -qE '^written	' \
  && pass "learn.sh: a --distinct write's result line starts with written" \
  || fail "learn.sh: a --distinct write's result line starts with written ($lrn73_distinct_out)"

# The C/C++ pair shares every other nontrivial term, so the second create
# needs --distinct — the overlap scan working as intended, not a defect —
# and both still mint distinct identities that neither overwrites.
printf -- '- [2026-02-01] Use C for the embedded firmware module because of strict size constraints.\n' >"$WORK/lrn73-c.md"
printf -- '- [2026-02-02] Use C++ for the embedded firmware module because of strict size constraints.\n' >"$WORK/lrn73-cpp.md"
lrn73_c_out=$("$LRN" new --file "$WORK/lrn73-c.md" "$lrn73" 2>/dev/null)
lrn73_c_id=$(printf '%s\n' "$lrn73_c_out" | awk -F'\t' '{print $2}')
"$LRN" new --file "$WORK/lrn73-cpp.md" "$lrn73" >/dev/null 2>"$WORK/lrn73-cpp-noflag.err"
lrn73_cpp_noflag_rc=$?
[ "$lrn73_cpp_noflag_rc" -eq 4 ] \
  && pass "learn.sh: C and C++ overlap on every other term, so the second create needs --distinct" \
  || fail "learn.sh: C and C++ overlap on every other term, so the second create needs --distinct (rc=$lrn73_cpp_noflag_rc)"
lrn73_cpp_out=$("$LRN" new --file "$WORK/lrn73-cpp.md" --distinct "$lrn73" 2>/dev/null)
lrn73_cpp_id=$(printf '%s\n' "$lrn73_cpp_out" | awk -F'\t' '{print $2}')
[ -n "$lrn73_c_id" ] && [ -n "$lrn73_cpp_id" ] && [ "$lrn73_c_id" != "$lrn73_cpp_id" ] \
  && pass "learn.sh: C and C++ mint two distinct identities, neither overwriting the other" \
  || fail "learn.sh: C and C++ mint two distinct identities, neither overwriting the other (c=$lrn73_c_id cpp=$lrn73_cpp_id)"
[ -f "$lrn73/.agent/rules/learned/$lrn73_c_id.md" ] && [ -f "$lrn73/.agent/rules/learned/$lrn73_cpp_id.md" ] \
  && pass "learn.sh: both the C and C++ records exist on disk" \
  || fail "learn.sh: both the C and C++ records exist on disk"

# revise: rewords the imperative and the Trigger clause but keeps the
# filename — its identity.
lrn73_v0=$(git hash-object --no-filters -- "$lrn73/.agent/rules/learned/$lrn73_new_id.md")
printf -- '- [2026-01-11] A brand-new rule, reworded. Trigger: a completely different cause.\n' >"$WORK/lrn73-revise-cand.md"
lrn73_rev_out=$("$LRN" revise "$lrn73_new_id" --file "$WORK/lrn73-revise-cand.md" --expected "$lrn73_v0" "$lrn73" 2>"$WORK/lrn73-rev.err")
lrn73_rev_rc=$?
[ "$lrn73_rev_rc" -eq 0 ] && pass "learn.sh: revise exits 0 against a fresh --expected" || fail "learn.sh: revise exits 0 against a fresh --expected (rc=$lrn73_rev_rc)"
printf '%s\n' "$lrn73_rev_out" | grep -qF "revised	$lrn73_new_id	" \
  && pass "learn.sh: revise's result line names the same id" \
  || fail "learn.sh: revise's result line names the same id ($lrn73_rev_out)"
[ -f "$lrn73/.agent/rules/learned/$lrn73_new_id.md" ] \
  && pass "learn.sh: revise keeps the record's filename — its identity" \
  || fail "learn.sh: revise keeps the record's filename — its identity"
diff -q "$WORK/lrn73-revise-cand.md" "$lrn73/.agent/rules/learned/$lrn73_new_id.md" >/dev/null 2>&1 \
  && pass "learn.sh: revise's record holds the new wording and Trigger clause" \
  || fail "learn.sh: revise's record holds the new wording and Trigger clause"
lrn73_v1=$(git hash-object --no-filters -- "$lrn73/.agent/rules/learned/$lrn73_new_id.md")

# stale revise: refuses at exit 3 and prints the current version; the
# record is untouched. A distinct candidate body, so the refusal is
# actually the version check and not the duplicate check tripping first on
# a candidate that happens to match what the first revise already wrote.
printf -- '- [2026-01-13] A stale racer with its own distinct wording. Trigger: an old version.\n' >"$WORK/lrn73-stale-cand.md"
"$LRN" revise "$lrn73_new_id" --file "$WORK/lrn73-stale-cand.md" --expected "$lrn73_v0" "$lrn73" >"$WORK/lrn73-stale.out" 2>"$WORK/lrn73-stale.err"
lrn73_stale_rc=$?
[ "$lrn73_stale_rc" -eq 3 ] && pass "learn.sh: revise against a stale --expected refuses at exit 3" || fail "learn.sh: revise against a stale --expected refuses at exit 3 (rc=$lrn73_stale_rc)"
grep -qF "$lrn73_v1" "$WORK/lrn73-stale.err" \
  && pass "learn.sh: the stale refusal prints the current version" \
  || fail "learn.sh: the stale refusal prints the current version ($(cat "$WORK/lrn73-stale.err"))"
diff -q "$WORK/lrn73-revise-cand.md" "$lrn73/.agent/rules/learned/$lrn73_new_id.md" >/dev/null 2>&1 \
  && pass "learn.sh: a stale revise leaves the record byte-identical to the first revise's bytes" \
  || fail "learn.sh: a stale revise leaves the record byte-identical to the first revise's bytes"

# The lost-update pair: two sequential calls carrying the same captured
# version, not backgrounded processes — a single-threaded suite run under
# three locales cannot assert on a real race, and the precondition check
# is what this is actually about.
printf -- '- [2026-01-12] A second racer, also carrying the old version. Trigger: a lost update.\n' >"$WORK/lrn73-lost-cand.md"
"$LRN" revise "$lrn73_new_id" --file "$WORK/lrn73-lost-cand.md" --expected "$lrn73_v0" "$lrn73" >/dev/null 2>"$WORK/lrn73-lost.err"
lrn73_lost_rc=$?
[ "$lrn73_lost_rc" -eq 3 ] \
  && pass "learn.sh: a second revise carrying the version the first one consumed also loses" \
  || fail "learn.sh: a second revise carrying the version the first one consumed also loses (rc=$lrn73_lost_rc)"
diff -q "$WORK/lrn73-revise-cand.md" "$lrn73/.agent/rules/learned/$lrn73_new_id.md" >/dev/null 2>&1 \
  && pass "learn.sh: the record still holds the first revise's bytes after the lost update" \
  || fail "learn.sh: the record still holds the first revise's bytes after the lost update"

# revise whose body equals the record it targets is the same duplicate
# refusal as new, not a no-op success.
"$LRN" revise "$lrn73_new_id" --file "$lrn73/.agent/rules/learned/$lrn73_new_id.md" --expected "$lrn73_v1" "$lrn73" >/dev/null 2>"$WORK/lrn73-revdup.err"
lrn73_revdup_rc=$?
[ "$lrn73_revdup_rc" -eq 5 ] \
  && pass "learn.sh: a revise whose body equals the record it targets refuses at exit 5" \
  || fail "learn.sh: a revise whose body equals the record it targets refuses at exit 5 (rc=$lrn73_revdup_rc)"

# revise against an id nothing has written yet, with --expected absent:
# refuses at exit 2 rather than minting a new record at the caller-chosen
# id — a create must go through new's own overlap gate, not sneak in
# through revise. A candidate distinct from every existing record, so the
# refusal is actually the absent-id check and not the duplicate check
# tripping first.
lrn73_absent_id="deadbeefcafe"
printf -- '- [2026-01-18] A candidate for an id nothing has written yet. Trigger: an absent target.\n' >"$WORK/lrn73-absent-cand.md"
lrn73_absent_before_count=$(find "$lrn73/.agent/rules/learned" -maxdepth 1 -name '*.md' | wc -l | tr -d '[:space:]')
"$LRN" revise "$lrn73_absent_id" --file "$WORK/lrn73-absent-cand.md" --expected absent "$lrn73" >/dev/null 2>"$WORK/lrn73-revabsent.err"
lrn73_revabsent_rc=$?
[ "$lrn73_revabsent_rc" -eq 2 ] \
  && pass "learn.sh: revise against a nonexistent id with --expected absent refuses at exit 2" \
  || fail "learn.sh: revise against a nonexistent id with --expected absent refuses at exit 2 (rc=$lrn73_revabsent_rc)"
lrn73_absent_after_count=$(find "$lrn73/.agent/rules/learned" -maxdepth 1 -name '*.md' | wc -l | tr -d '[:space:]')
[ ! -f "$lrn73/.agent/rules/learned/$lrn73_absent_id.md" ] && [ "$lrn73_absent_before_count" -eq "$lrn73_absent_after_count" ] \
  && pass "learn.sh: the absent-id revise writes no new record file under rules/learned/" \
  || fail "learn.sh: the absent-id revise writes no new record file under rules/learned/ (before=$lrn73_absent_before_count after=$lrn73_absent_after_count)"

# malformed candidates: refused at exit 6, writing nothing.
lrn73_before_count=$(find "$lrn73/.agent/rules/learned" -maxdepth 1 -name '*.md' | wc -l | tr -d '[:space:]')
printf -- 'No date stamp at all.\n' >"$WORK/lrn73-bad-nodate.md"
"$LRN" new --file "$WORK/lrn73-bad-nodate.md" "$lrn73" >/dev/null 2>&1
[ "$?" -eq 6 ] && pass "learn.sh: a candidate with no date stamp refuses at exit 6" || fail "learn.sh: a candidate with no date stamp refuses at exit 6"
printf -- '- [2026-01-13] One.\n- [2026-01-14] Two.\n' >"$WORK/lrn73-bad-twobullet.md"
"$LRN" new --file "$WORK/lrn73-bad-twobullet.md" "$lrn73" >/dev/null 2>&1
[ "$?" -eq 6 ] && pass "learn.sh: a candidate with a second top-level bullet refuses at exit 6" || fail "learn.sh: a candidate with a second top-level bullet refuses at exit 6"
printf -- '---\ndate: 2026-01-01\n---\nbody\n' >"$WORK/lrn73-bad-frontmatter.md"
"$LRN" new --file "$WORK/lrn73-bad-frontmatter.md" "$lrn73" >/dev/null 2>&1
[ "$?" -eq 6 ] && pass "learn.sh: a candidate carrying a frontmatter block refuses at exit 6" || fail "learn.sh: a candidate carrying a frontmatter block refuses at exit 6"
printf -- '- [2026-01-15] A rule.\n# A heading\n' >"$WORK/lrn73-bad-heading.md"
"$LRN" new --file "$WORK/lrn73-bad-heading.md" "$lrn73" >/dev/null 2>&1
[ "$?" -eq 6 ] && pass "learn.sh: a candidate carrying a heading refuses at exit 6" || fail "learn.sh: a candidate carrying a heading refuses at exit 6"
lrn73_after_count=$(find "$lrn73/.agent/rules/learned" -maxdepth 1 -name '*.md' | wc -l | tr -d '[:space:]')
[ "$lrn73_before_count" -eq "$lrn73_after_count" ] \
  && pass "learn.sh: every malformed candidate above wrote nothing" \
  || fail "learn.sh: every malformed candidate above wrote nothing (before=$lrn73_before_count after=$lrn73_after_count)"

# over-length imperative: warns on stderr, still writes.
lrn73_long=$(awk 'BEGIN { for (i = 1; i <= 45; i++) printf "word "; print "." }')
printf -- '- [2026-01-16] %s\n' "$lrn73_long" >"$WORK/lrn73-long.md"
"$LRN" new --file "$WORK/lrn73-long.md" "$lrn73" >"$WORK/lrn73-long.out" 2>"$WORK/lrn73-long.err"
lrn73_long_rc=$?
[ "$lrn73_long_rc" -eq 0 ] && pass "learn.sh: an over-length imperative still writes" || fail "learn.sh: an over-length imperative still writes (rc=$lrn73_long_rc)"
grep -qi '40-word' "$WORK/lrn73-long.err" && pass "learn.sh: an over-length imperative warns on stderr" || fail "learn.sh: an over-length imperative warns on stderr"

# surface refusal: exit 7, naming the owning writer.
printf -- '- [2026-01-17] Some other-surface candidate.\n' >"$WORK/lrn73-surf.md"
"$LRN" new --file "$WORK/lrn73-surf.md" --surface memory "$lrn73" >/dev/null 2>"$WORK/lrn73-surf-mem.err"
lrn73_surfmem_rc=$?
[ "$lrn73_surfmem_rc" -eq 7 ] && pass "learn.sh: --surface memory refuses at exit 7" || fail "learn.sh: --surface memory refuses at exit 7 (rc=$lrn73_surfmem_rc)"
grep -qF 'memory.sh' "$WORK/lrn73-surf-mem.err" \
  && pass "learn.sh: the memory-surface refusal names memory.sh" \
  || fail "learn.sh: the memory-surface refusal names memory.sh"
"$LRN" new --file "$WORK/lrn73-surf.md" --surface docs "$lrn73" >/dev/null 2>"$WORK/lrn73-surf-docs.err"
lrn73_surfdocs_rc=$?
[ "$lrn73_surfdocs_rc" -eq 7 ] && pass "learn.sh: --surface docs refuses at exit 7" || fail "learn.sh: --surface docs refuses at exit 7 (rc=$lrn73_surfdocs_rc)"
grep -qF 'docs.sh' "$WORK/lrn73-surf-docs.err" \
  && pass "learn.sh: the docs-surface refusal names docs.sh" \
  || fail "learn.sh: the docs-surface refusal names docs.sh"
"$LRN" new --file "$WORK/lrn73-surf.md" --surface gotchas "$lrn73" >/dev/null 2>"$WORK/lrn73-surf-gotchas.err"
lrn73_surfgotchas_rc=$?
[ "$lrn73_surfgotchas_rc" -eq 7 ] && pass "learn.sh: --surface gotchas refuses at exit 7" || fail "learn.sh: --surface gotchas refuses at exit 7 (rc=$lrn73_surfgotchas_rc)"

# retire: removes the record; a stale --expected refuses at exit 3 first.
lrn73_retire_v=$(git hash-object --no-filters -- "$lrn73/.agent/rules/learned/$lrn73_c_id.md")
"$LRN" retire "$lrn73_c_id" --expected old-and-wrong "$lrn73" >/dev/null 2>"$WORK/lrn73-retire-stale.err"
lrn73_retirestale_rc=$?
[ "$lrn73_retirestale_rc" -eq 3 ] && pass "learn.sh: retire against a stale --expected refuses at exit 3" || fail "learn.sh: retire against a stale --expected refuses at exit 3 (rc=$lrn73_retirestale_rc)"
[ -f "$lrn73/.agent/rules/learned/$lrn73_c_id.md" ] \
  && pass "learn.sh: a stale retire leaves the record in place" \
  || fail "learn.sh: a stale retire leaves the record in place"
lrn73_retire_out=$("$LRN" retire "$lrn73_c_id" --expected "$lrn73_retire_v" "$lrn73" 2>"$WORK/lrn73-retire.err")
lrn73_retire_rc=$?
[ "$lrn73_retire_rc" -eq 0 ] && pass "learn.sh: retire exits 0 against a fresh --expected" || fail "learn.sh: retire exits 0 against a fresh --expected (rc=$lrn73_retire_rc)"
printf '%s\n' "$lrn73_retire_out" | grep -qF "retired	$lrn73_c_id" \
  && pass "learn.sh: retire prints retired with the id" \
  || fail "learn.sh: retire prints retired with the id ($lrn73_retire_out)"
[ ! -f "$lrn73/.agent/rules/learned/$lrn73_c_id.md" ] && pass "learn.sh: retire removes the record from disk" || fail "learn.sh: retire removes the record from disk"

# Write confinement: nothing above ever touched memory.md or memory/.
lrn73_mem_after=$(lrn73_memdir_snapshot "$lrn73")
[ "$lrn73_mem_before" = "$lrn73_mem_after" ] \
  && pass "learn.sh: memory/ is byte-identical before and after every fixture command above" \
  || fail "learn.sh: memory/ is byte-identical before and after every fixture command above"
diff -q "$WORK/lrn73-memory-md-before.md" "$lrn73/.agent/memory.md" >/dev/null 2>&1 \
  && pass "learn.sh: memory.md is byte-identical before and after every fixture command above" \
  || fail "learn.sh: memory.md is byte-identical before and after every fixture command above"

# A manual-mode node (no indexes: generated, so no rules/learned/ directory
# at all) refuses every write command, naming rules/learned.md as the
# node's surface, and leaves it untouched. lookup is not a write and still
# exits 0 with nothing to compare against.
lrn73_manual="$WORK/learn-manual"
mkdir -p "$lrn73_manual"
"$NODE" init --preset software-development --mode ignore-all "$lrn73_manual" >/dev/null 2>&1
LRNM="$lrn73_manual/.agent/scripts/learn.sh"
printf -- '- [2026-01-01] A manual-mode candidate.\n' >"$WORK/lrn73-manual-cand.md"
cp "$lrn73_manual/.agent/rules/learned.md" "$WORK/lrn73-manual-learned-before.md"

"$LRNM" lookup --file "$WORK/lrn73-manual-cand.md" "$lrn73_manual" >/dev/null 2>&1
[ "$?" -eq 0 ] \
  && pass "learn.sh: lookup on a manual-mode node still exits 0 with nothing to compare against" \
  || fail "learn.sh: lookup on a manual-mode node still exits 0 with nothing to compare against"

"$LRNM" new --file "$WORK/lrn73-manual-cand.md" "$lrn73_manual" >/dev/null 2>"$WORK/lrn73-manual-new.err"
lrn73_manualnew_rc=$?
[ "$lrn73_manualnew_rc" -eq 7 ] \
  && pass "learn.sh: new on a manual-mode node with no rules/learned/ refuses at exit 7" \
  || fail "learn.sh: new on a manual-mode node with no rules/learned/ refuses at exit 7 (rc=$lrn73_manualnew_rc)"
grep -qF 'rules/learned.md' "$WORK/lrn73-manual-new.err" \
  && pass "learn.sh: the manual-mode refusal names rules/learned.md as the node's surface" \
  || fail "learn.sh: the manual-mode refusal names rules/learned.md as the node's surface"

# A fresh generated-mode node has no rules/learned/ either — only the
# migration creates it — and its rules/learned.md is gitignored. The first
# `new` must create the directory and land a tracked record, or the node's
# first learned rule has nowhere git can see. The 2026-09-20 calibration
# rerun found eight sessions hand-editing the ignored aggregate after this
# refusal.
lrn73_gen="$WORK/learn-fresh-generated"
mkdir -p "$lrn73_gen"
"$NODE" init --preset software-development --mode track-all --indexes generated "$lrn73_gen" >/dev/null 2>&1
finish_bootstrap "$lrn73_gen"
git -C "$lrn73_gen" init -q 2>/dev/null
LRNG="$lrn73_gen/.agent/scripts/learn.sh"
printf -- '- [2026-01-02] Never retry a payment POST without an idempotency key.\n' >"$WORK/lrn73-gen-cand.md"
[ ! -e "$lrn73_gen/.agent/rules/learned" ] \
  && pass "learn.sh: a fresh generated-mode init has no rules/learned/ directory yet" \
  || fail "learn.sh: a fresh generated-mode init has no rules/learned/ directory yet"
"$LRNG" new --file "$WORK/lrn73-gen-cand.md" "$lrn73_gen" >"$WORK/lrn73-gen-new.out" 2>"$WORK/lrn73-gen-new.err"
lrn73_gennew_rc=$?
lrn73_gen_records=$(find "$lrn73_gen/.agent/rules/learned" -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' ')
[ "$lrn73_gennew_rc" -eq 0 ] && [ "$lrn73_gen_records" -eq 1 ] \
  && pass "learn.sh: the first new on a fresh generated-mode node creates rules/learned/ and writes one record" \
  || fail "learn.sh: the first new on a fresh generated-mode node creates rules/learned/ and writes one record (rc=$lrn73_gennew_rc records=$lrn73_gen_records; $(cat "$WORK/lrn73-gen-new.err"))"
grep -qF 'idempotency key' "$lrn73_gen/.agent/rules/learned.md" \
  && pass "learn.sh: the regenerated rules/learned.md carries the first record after the write" \
  || fail "learn.sh: the regenerated rules/learned.md carries the first record after the write"
lrn73_gen_untracked=$(git -C "$lrn73_gen" status --porcelain --untracked-files=all -- .agent/rules/learned 2>/dev/null | grep -c '\.md$')
[ "${lrn73_gen_untracked:-0}" -eq 1 ] \
  && pass "learn.sh: the first record on a generated node is visible to git, unlike the ignored aggregate" \
  || fail "learn.sh: the first record on a generated node is visible to git, unlike the ignored aggregate (untracked=$lrn73_gen_untracked)"

"$LRNM" revise deadbeefcafe --file "$WORK/lrn73-manual-cand.md" --expected absent "$lrn73_manual" >/dev/null 2>&1
[ "$?" -eq 7 ] \
  && pass "learn.sh: revise on a manual-mode node with no rules/learned/ refuses at exit 7" \
  || fail "learn.sh: revise on a manual-mode node with no rules/learned/ refuses at exit 7"
"$LRNM" retire deadbeefcafe --expected absent "$lrn73_manual" >/dev/null 2>&1
[ "$?" -eq 7 ] \
  && pass "learn.sh: retire on a manual-mode node with no rules/learned/ refuses at exit 7" \
  || fail "learn.sh: retire on a manual-mode node with no rules/learned/ refuses at exit 7"

diff -q "$WORK/lrn73-manual-learned-before.md" "$lrn73_manual/.agent/rules/learned.md" >/dev/null 2>&1 \
  && pass "learn.sh: rules/learned.md is byte-identical after every refused write on a manual-mode node" \
  || fail "learn.sh: rules/learned.md is byte-identical after every refused write on a manual-mode node"
[ ! -e "$lrn73_manual/.agent/rules/learned" ] \
  && pass "learn.sh: a manual-mode node still has no rules/learned/ directory after these refusals" \
  || fail "learn.sh: a manual-mode node still has no rules/learned/ directory after these refusals"

# Bootstrap absence: nothing on the mechanical load path invokes it.
lrn73_boot_hits=$(grep -l 'learn\.sh' \
  "$reporoot/templates/entry-point.md" "$reporoot/templates/entry-point-generated.md" \
  "$reporoot/scripts/status.sh" "$reporoot/scripts/checkpoint.sh" 2>/dev/null)
[ -z "$lrn73_boot_hits" ] \
  && pass "learn.sh: no entry-point template, status.sh, or checkpoint.sh path invokes it" \
  || fail "learn.sh: no entry-point template, status.sh, or checkpoint.sh path invokes it ($lrn73_boot_hits)"

# Install wiring: both init and update ship it executable, and update's
# refreshed-scripts line names it.
lrn73_wire_init="$WORK/learn-wire-init"
mkdir -p "$lrn73_wire_init"
"$NODE" init --preset software-development --mode ignore-all "$lrn73_wire_init" >/dev/null 2>&1
[ -x "$lrn73_wire_init/.agent/scripts/learn.sh" ] && pass "learn.sh: init installs it executable" || fail "learn.sh: init installs it executable"

lrn73_wire_update="$WORK/learn-wire-update"
mkdir -p "$lrn73_wire_update"
make_v6_fixture "$lrn73_wire_update"
"$NODE" update "$lrn73_wire_update" >"$WORK/lrn73-wire-update.out" 2>&1
[ -x "$lrn73_wire_update/.agent/scripts/learn.sh" ] \
  && pass "learn.sh: update installs it executable into an existing node" \
  || fail "learn.sh: update installs it executable into an existing node"
grep -qF 'learn.sh' "$WORK/lrn73-wire-update.out" \
  && pass "learn.sh: update's refreshed-scripts line names it" \
  || fail "learn.sh: update's refreshed-scripts line names it"

# ---- 74. cross-check: every script node.sh's update loop refreshes is
# named in scripts/docs/README.md's script table ----
# Reads the update loop's own word list rather than restating it, so a
# name added to one and not the other fails this check instead of passing
# it twice. The update loop specifically (not init's, which precedes it in
# the file): the one under the "Refresh the shipped scripts from the
# source repo" comment.
xc74_loop_line=$(awk '
  /Refresh the shipped scripts from the source repo/ { f = 1 }
  f && /^  for script in / { print; exit }
' "$reporoot/scripts/node.sh")
xc74_names=$(printf '%s\n' "$xc74_loop_line" | sed -E 's/^[[:space:]]*for script in (.*); do$/\1/')
xc74_missing=""
for xc74_s in $xc74_names; do
  # finish.sh is the checkpoint.sh compatibility alias, documented in
  # node.md and checkpoint.md — it never gets its own README.md row.
  case "$xc74_s" in
  finish.sh) continue ;;
  esac
  grep -qF "\`$xc74_s\`" "$reporoot/scripts/docs/README.md" || xc74_missing="$xc74_missing $xc74_s"
done
[ -z "$xc74_missing" ] \
  && pass "docs: every script node.sh's update loop refreshes is named in scripts/docs/README.md" \
  || fail "docs: every script node.sh's update loop refreshes is named in scripts/docs/README.md (missing:$xc74_missing)"

# ---- 75. learn.sh pending/resolve: closing the migration's one-time
# semantic-review backlog ----
# A separate fixture directory, built from make_v6_fixture the same way
# r61build is, and never touching r61dir — section 61's later checks
# compare its files byte for byte. Every semantic call below (which rule
# pairs with which, what stays, what goes) is made by this test script
# standing in for the agent; resolve itself only checks preconditions and
# rewrites one disposition field.
rec75="$WORK/reconcile-fixture"
mkdir -p "$rec75"
make_v6_fixture "$rec75"
rec75_modeline=$(grep -n '^  mode:' "$rec75/.agent/purpose.md" | head -1 | cut -d: -f1)
awk -v ln="$rec75_modeline" \
  'NR==ln { print; print "  indexes: generated        # manual | generated"; next } { print }' \
  "$rec75/.agent/purpose.md" >"$rec75/.agent/purpose.md.tmp"
mv "$rec75/.agent/purpose.md.tmp" "$rec75/.agent/purpose.md"

cat >"$rec75/.agent/rules/learned.md" <<'EOF'
# Learned rules

Binding rules distilled from operator corrections and failed verifications on this project.

<!-- Format: - [YYYY-MM-DD] <imperative rule>. Trigger: <cause, optional>. -->
- [2026-01-01] Flat merge-target rule. Trigger: something.
- [2026-01-02] Split-candidate rule with a nested sub-bullet. Trigger: x.
  - qualifier one
  - qualifier two
- [2026-01-03] Keep-candidate rule, multi paragraph.

  Continuation paragraph for the keep candidate.
- [2026-01-04] Merge-source rule, multi paragraph.

  Continuation paragraph for the merge source.
- [2026-01-05] Retire-candidate rule with a nested sub-bullet.
  - qualifier
EOF

mkdir -p "$rec75/.agent/docs"
cat >"$rec75/.agent/docs/architecture.md" <<'EOF'
# Architecture

### `dup.md`
- **Read when:** first dup entry.

### `dup.md`
- **Read when:** second dup entry.

### `badtable.md`
Hand-edited row with no bold marker: whatever hook text.
EOF
cat >"$rec75/.agent/docs/dup.md" <<'EOF'
# Dup

Body.
EOF
cat >"$rec75/.agent/docs/badtable.md" <<'EOF'
# Badtable

Body.
EOF
cat >"$rec75/.agent/docs/noentry.md" <<'EOF'
# Noentry

Body.
EOF

"$NODE" update "$rec75" >"$WORK/rec75-update.out" 2>&1
rec75_updrc=$?
[ "$rec75_updrc" -eq 0 ] && pass "reconcile fixture: generated-mode update exits 0" || fail "reconcile fixture: generated-mode update exits 0 (rc=$rec75_updrc)"

REC="$rec75/.agent/scripts/learn.sh"
RECDOCS="$rec75/.agent/scripts/docs.sh"
rec75_inv="$rec75/.agent/migration-inventory.md"
rec75_learned="$rec75/.agent/rules/learned"

rec75_flat=$(grep -lF 'Flat merge-target rule' "$rec75_learned"/*.md)
rec75_split=$(grep -lF 'Split-candidate rule' "$rec75_learned"/*.md)
rec75_keep=$(grep -lF 'Keep-candidate rule' "$rec75_learned"/*.md)
rec75_mergesrc=$(grep -lF 'Merge-source rule' "$rec75_learned"/*.md)
rec75_retire=$(grep -lF 'Retire-candidate rule' "$rec75_learned"/*.md)
rec75_flat_id=$(basename "$rec75_flat" .md)
rec75_split_id=$(basename "$rec75_split" .md)
rec75_keep_id=$(basename "$rec75_keep" .md)
rec75_mergesrc_id=$(basename "$rec75_mergesrc" .md)
rec75_retire_id=$(basename "$rec75_retire" .md)

# Reads the raw inventory item line naming id $2 in file $1 and prints its
# label field alone — everything before the id field — split from the
# right the same way lrn_split_item does, so a rule preview that happens
# to contain the literal " | " cannot shift the boundary.
rec75_label_for_id() {
  rli_line=$(grep -F "id=$2 | " "$1")
  rli_rest="${rli_line% | *}"
  printf '%s' "${rli_rest% | *}"
}

# ---- pending, first run: every pending rule and hook-missing doc listed
# with its own label, each rule item's version a fresh hash of its own
# record, each doc item's version the literal "-" ----
rec75_pending1=$("$REC" pending "$rec75")
rec75_split_label=$(rec75_label_for_id "$rec75_inv" "$rec75_split_id")
printf '%s\n' "$rec75_pending1" | grep -qF -- "$rec75_split_label | semantic-review-pending | $rec75_split_id | version=$(git hash-object --no-filters -- "$rec75_split")" \
  && pass "learn.sh pending: the split-candidate rule is listed with its label and a fresh version hash" \
  || fail "learn.sh pending: the split-candidate rule is listed with its label and a fresh version hash"
rec75_keep_label=$(rec75_label_for_id "$rec75_inv" "$rec75_keep_id")
printf '%s\n' "$rec75_pending1" | grep -qF -- "$rec75_keep_label | semantic-review-pending | $rec75_keep_id | version=$(git hash-object --no-filters -- "$rec75_keep")" \
  && pass "learn.sh pending: the keep-candidate rule is listed with its label and a fresh version hash" \
  || fail "learn.sh pending: the keep-candidate rule is listed with its label and a fresh version hash"
rec75_mergesrc_label=$(rec75_label_for_id "$rec75_inv" "$rec75_mergesrc_id")
printf '%s\n' "$rec75_pending1" | grep -qF -- "$rec75_mergesrc_label | semantic-review-pending | $rec75_mergesrc_id | version=$(git hash-object --no-filters -- "$rec75_mergesrc")" \
  && pass "learn.sh pending: the merge-source rule is listed with its label and a fresh version hash" \
  || fail "learn.sh pending: the merge-source rule is listed with its label and a fresh version hash"
rec75_retire_label=$(rec75_label_for_id "$rec75_inv" "$rec75_retire_id")
printf '%s\n' "$rec75_pending1" | grep -qF -- "$rec75_retire_label | semantic-review-pending | $rec75_retire_id | version=$(git hash-object --no-filters -- "$rec75_retire")" \
  && pass "learn.sh pending: the retire-candidate rule is listed with its label and a fresh version hash" \
  || fail "learn.sh pending: the retire-candidate rule is listed with its label and a fresh version hash"
rec75_dup_label=$(rec75_label_for_id "$rec75_inv" "dup.md")
printf '%s\n' "$rec75_pending1" | grep -qF -- "$rec75_dup_label | hook-missing | dup.md | version=-" \
  && pass "learn.sh pending: the duplicate-entry doc is listed with its label and version=-" \
  || fail "learn.sh pending: the duplicate-entry doc is listed with its label and version=-"
rec75_badtable_label=$(rec75_label_for_id "$rec75_inv" "badtable.md")
printf '%s\n' "$rec75_pending1" | grep -qF -- "$rec75_badtable_label | hook-missing | badtable.md | version=-" \
  && pass "learn.sh pending: the hand-edited-table doc is listed with its label" \
  || fail "learn.sh pending: the hand-edited-table doc is listed with its label"
rec75_noentry_label=$(rec75_label_for_id "$rec75_inv" "noentry.md")
printf '%s\n' "$rec75_pending1" | grep -qF -- "$rec75_noentry_label | hook-missing | noentry.md | version=-" \
  && pass "learn.sh pending: the no-entry doc is listed with its label" \
  || fail "learn.sh pending: the no-entry doc is listed with its label"
printf '%s\n' "$rec75_pending1" | grep -qF "$rec75_flat_id" \
  && fail "learn.sh pending: the already-migrated flat rule is never listed" \
  || pass "learn.sh pending: the already-migrated flat rule is never listed"
[ "$(printf '%s\n' "$rec75_pending1" | tail -n1)" = "7 pending" ] \
  && pass "learn.sh pending: closes with the exact count of pending items" \
  || fail "learn.sh pending: closes with the exact count of pending items ($(printf '%s\n' "$rec75_pending1" | tail -n1))"

# ---- SPLIT: the nested-sub-bullet rule really names two separate
# qualifiers — the agent's own judgment, made here and nowhere in the
# shell. Revise the original down to the first qualifier, create a second
# record for the other one, then resolve. ----
rec75_split_v0=$(git hash-object --no-filters -- "$rec75_split")
printf -- '- [2026-01-02] Split-candidate rule, qualifier one only. Trigger: x.\n' >"$WORK/rec75-split-revise.md"
"$REC" revise "$rec75_split_id" --file "$WORK/rec75-split-revise.md" --expected "$rec75_split_v0" "$rec75" >"$WORK/rec75-split-revise.out" 2>"$WORK/rec75-split-revise.err"
rec75_split_rev_rc=$?
[ "$rec75_split_rev_rc" -eq 0 ] && pass "reconcile split: revising the original to its first qualifier exits 0" || fail "reconcile split: revising the original to its first qualifier exits 0 (rc=$rec75_split_rev_rc)"
printf -- '- [2026-01-02] Split-candidate rule, qualifier two only. Trigger: x.\n' >"$WORK/rec75-split-new.md"
rec75_split_new_out=$("$REC" new --file "$WORK/rec75-split-new.md" --distinct "$rec75" 2>"$WORK/rec75-split-new.err")
rec75_split_new_rc=$?
[ "$rec75_split_new_rc" -eq 0 ] && pass "reconcile split: creating the second qualifier's record exits 0" || fail "reconcile split: creating the second qualifier's record exits 0 (rc=$rec75_split_new_rc)"
rec75_split_new_id=$(printf '%s\n' "$rec75_split_new_out" | awk -F'\t' '{print $2}')
[ -n "$rec75_split_new_id" ] && [ "$rec75_split_new_id" != "$rec75_split_id" ] \
  && pass "reconcile split: the second record mints a distinct identity" \
  || fail "reconcile split: the second record mints a distinct identity"
rec75_split_resolve_out=$("$REC" resolve --id "$rec75_split_id" --disposition "migrated (split into $rec75_split_new_id)" "$rec75" 2>"$WORK/rec75-split-resolve.err")
rec75_split_resolve_rc=$?
[ "$rec75_split_resolve_rc" -eq 0 ] && pass "reconcile split: resolve exits 0" || fail "reconcile split: resolve exits 0 (rc=$rec75_split_resolve_rc)"
printf '%s\n' "$rec75_split_resolve_out" | grep -qF "resolved	$rec75_split_id	migrated (split into $rec75_split_new_id)" \
  && pass "reconcile split: resolve's result line names the id and the new disposition" \
  || fail "reconcile split: resolve's result line names the id and the new disposition ($rec75_split_resolve_out)"
grep -qF "rule 2: \`- [2026-01-02] Split-candidate rule with a nested sub-bullet. Trigger: x\` -> rules/learned/$rec75_split_id.md | id=$rec75_split_id | migrated (split into $rec75_split_new_id)" "$rec75_inv" \
  && pass "reconcile split: the inventory line now reads migrated (split into ...), nothing else on it changed" \
  || fail "reconcile split: the inventory line now reads migrated (split into ...), nothing else on it changed"
[ -f "$rec75_learned/$rec75_split_id.md" ] && [ -f "$rec75_learned/$rec75_split_new_id.md" ] \
  && pass "reconcile split: both records exist on disk under different identities" \
  || fail "reconcile split: both records exist on disk under different identities"

# ---- MERGE: the merge-source rule's content belongs with the flat
# merge-target rule — again the agent's own call. Revise the target to
# carry both, retire the source's own record, then resolve the source's
# inventory line. ----
rec75_flat_v0=$(git hash-object --no-filters -- "$rec75_flat")
cat >"$WORK/rec75-merge-revise.md" <<'EOF'
- [2026-01-01] Flat merge-target rule, now folded together with the merge source. Trigger: something.
EOF
"$REC" revise "$rec75_flat_id" --file "$WORK/rec75-merge-revise.md" --expected "$rec75_flat_v0" "$rec75" >"$WORK/rec75-merge-revise.out" 2>"$WORK/rec75-merge-revise.err"
rec75_merge_rev_rc=$?
[ "$rec75_merge_rev_rc" -eq 0 ] && pass "reconcile merge: revising the target to fold in the source exits 0" || fail "reconcile merge: revising the target to fold in the source exits 0 (rc=$rec75_merge_rev_rc)"
rec75_mergesrc_v0=$(git hash-object --no-filters -- "$rec75_mergesrc")
"$REC" retire "$rec75_mergesrc_id" --expected "$rec75_mergesrc_v0" "$rec75" >"$WORK/rec75-merge-retire.out" 2>"$WORK/rec75-merge-retire.err"
rec75_merge_retire_rc=$?
[ "$rec75_merge_retire_rc" -eq 0 ] && pass "reconcile merge: retiring the source's own record exits 0" || fail "reconcile merge: retiring the source's own record exits 0 (rc=$rec75_merge_retire_rc)"
rec75_merge_resolve_out=$("$REC" resolve --id "$rec75_mergesrc_id" --disposition "migrated (merged into $rec75_flat_id)" "$rec75" 2>"$WORK/rec75-merge-resolve.err")
rec75_merge_resolve_rc=$?
[ "$rec75_merge_resolve_rc" -eq 0 ] && pass "reconcile merge: resolve exits 0" || fail "reconcile merge: resolve exits 0 (rc=$rec75_merge_resolve_rc)"
printf '%s\n' "$rec75_merge_resolve_out" | grep -qF "resolved	$rec75_mergesrc_id	migrated (merged into $rec75_flat_id)" \
  && pass "reconcile merge: resolve's result line names the id and the new disposition" \
  || fail "reconcile merge: resolve's result line names the id and the new disposition ($rec75_merge_resolve_out)"
grep -qF "id=$rec75_mergesrc_id | migrated (merged into $rec75_flat_id)" "$rec75_inv" \
  && pass "reconcile merge: the source's inventory line now reads migrated (merged into ...)" \
  || fail "reconcile merge: the source's inventory line now reads migrated (merged into ...)"
grep -qF "id=$rec75_flat_id | migrated" "$rec75_inv" \
  && pass "reconcile merge: the target's own inventory line is untouched" \
  || fail "reconcile merge: the target's own inventory line is untouched"
[ ! -f "$rec75_learned/$rec75_mergesrc_id.md" ] \
  && pass "reconcile merge: the source's record no longer exists on disk" \
  || fail "reconcile merge: the source's record no longer exists on disk"

# ---- two refusal classes need a rule item that is still pending, tested
# here against the keep-candidate before it is actually resolved below,
# so the refusal itself leaves nothing to disturb. ----
rec75_inv_snapshot() { git hash-object --no-filters -- "$rec75_inv"; }

rec75_before=$(rec75_inv_snapshot)
"$REC" resolve --id "$rec75_keep_id" --disposition "migrated (split into deadbeefcafe)" "$rec75" >/dev/null 2>"$WORK/rec75-ref-noid.err"
[ "$?" -eq 2 ] && pass "reconcile refusal: naming an identity with no record file refuses at exit 2" || fail "reconcile refusal: naming an identity with no record file refuses at exit 2"
grep -qF 'deadbeefcafe' "$WORK/rec75-ref-noid.err" \
  && pass "reconcile refusal: the no-record refusal names the identity it checked" \
  || fail "reconcile refusal: the no-record refusal names the identity it checked"
[ "$(rec75_inv_snapshot)" = "$rec75_before" ] && pass "reconcile refusal: the no-record refusal writes nothing" || fail "reconcile refusal: the no-record refusal writes nothing"

rec75_before=$(rec75_inv_snapshot)
"$REC" resolve --id "$rec75_keep_id" --disposition retired "$rec75" >/dev/null 2>"$WORK/rec75-ref-existsretire.err"
[ "$?" -eq 2 ] && pass "reconcile refusal: retired on a rule item whose record still exists refuses at exit 2" || fail "reconcile refusal: retired on a rule item whose record still exists refuses at exit 2"
grep -qF 'still exists' "$WORK/rec75-ref-existsretire.err" \
  && pass "reconcile refusal: the still-exists refusal names what it checked" \
  || fail "reconcile refusal: the still-exists refusal names what it checked"
[ "$(rec75_inv_snapshot)" = "$rec75_before" ] && pass "reconcile refusal: the still-exists refusal writes nothing" || fail "reconcile refusal: the still-exists refusal writes nothing"

# ---- KEEP: the multi-paragraph rule needs no split or merge — the agent
# closes it as migrated with the record untouched. This is also the one
# successful resolve the whole-fixture invariants below are proved
# against: exactly one inventory line changes, and every record and every
# doc in the fixture stays byte-identical. ----
rec75_records_snapshot() { find "$1/.agent/rules/learned" -maxdepth 1 -name '*.md' 2>/dev/null | sort | xargs shasum 2>/dev/null | sort; }
rec75_docs_snapshot() { find "$1/.agent/docs" -type f 2>/dev/null | sort | xargs shasum 2>/dev/null | sort; }

cp "$rec75_keep" "$WORK/rec75-keep-before.md"
cp "$rec75_inv" "$WORK/rec75-inventory-before.md"
rec75_records_before=$(rec75_records_snapshot "$rec75")
rec75_docs_before=$(rec75_docs_snapshot "$rec75")
rec75_keep_resolve_out=$("$REC" resolve --id "$rec75_keep_id" --disposition migrated "$rec75" 2>"$WORK/rec75-keep-resolve.err")
rec75_keep_resolve_rc=$?
[ "$rec75_keep_resolve_rc" -eq 0 ] && pass "reconcile keep: resolve exits 0" || fail "reconcile keep: resolve exits 0 (rc=$rec75_keep_resolve_rc)"
printf '%s\n' "$rec75_keep_resolve_out" | grep -qF "resolved	$rec75_keep_id	migrated" \
  && pass "reconcile keep: resolve's result line names the id and migrated" \
  || fail "reconcile keep: resolve's result line names the id and migrated ($rec75_keep_resolve_out)"
grep -qF "id=$rec75_keep_id | migrated" "$rec75_inv" \
  && pass "reconcile keep: the inventory line now reads migrated" \
  || fail "reconcile keep: the inventory line now reads migrated"
diff -q "$WORK/rec75-keep-before.md" "$rec75_keep" >/dev/null 2>&1 \
  && pass "reconcile keep: the record is byte-identical before and after resolve" \
  || fail "reconcile keep: the record is byte-identical before and after resolve"

# Acceptance box 2: a resolve changes only the named item's disposition
# field, nothing else on its line and no other line in the file.
cp "$rec75_inv" "$WORK/rec75-inventory-after.md"
rec75_inv_before_line=$(grep -F "id=$rec75_keep_id " "$WORK/rec75-inventory-before.md")
rec75_inv_after_line=$(grep -F "id=$rec75_keep_id " "$WORK/rec75-inventory-after.md")
[ "${rec75_inv_before_line% | *}" = "${rec75_inv_after_line% | *}" ] \
  && pass "reconcile keep: the resolved line's label, location, and id fields are unchanged" \
  || fail "reconcile keep: the resolved line's label, location, and id fields are unchanged"
[ "${rec75_inv_before_line##* | }" != "${rec75_inv_after_line##* | }" ] \
  && pass "reconcile keep: only the text after the resolved line's last field changed" \
  || fail "reconcile keep: only the text after the resolved line's last field changed"
grep -vF "id=$rec75_keep_id " "$WORK/rec75-inventory-before.md" >"$WORK/rec75-inv-before-rest.md"
grep -vF "id=$rec75_keep_id " "$WORK/rec75-inventory-after.md" >"$WORK/rec75-inv-after-rest.md"
diff -q "$WORK/rec75-inv-before-rest.md" "$WORK/rec75-inv-after-rest.md" >/dev/null 2>&1 \
  && pass "reconcile keep: every other inventory line is byte-identical across the resolve" \
  || fail "reconcile keep: every other inventory line is byte-identical across the resolve"

# Acceptance box 6: resolve creates, edits, splits, merges, and deletes no
# record and no doc anywhere in the fixture — not just the item resolved.
rec75_records_after=$(rec75_records_snapshot "$rec75")
rec75_docs_after=$(rec75_docs_snapshot "$rec75")
[ "$rec75_records_before" = "$rec75_records_after" ] \
  && pass "reconcile keep: every record under rules/learned/ is byte-identical across the resolve" \
  || fail "reconcile keep: every record under rules/learned/ is byte-identical across the resolve"
[ "$rec75_docs_before" = "$rec75_docs_after" ] \
  && pass "reconcile keep: every doc under docs/ is byte-identical across the resolve" \
  || fail "reconcile keep: every doc under docs/ is byte-identical across the resolve"

# ---- RETIRE: the nested-sub-bullet rule turns out to duplicate a source
# already covered elsewhere — the agent retires it outright. ----
rec75_retire_v0=$(git hash-object --no-filters -- "$rec75_retire")
"$REC" retire "$rec75_retire_id" --expected "$rec75_retire_v0" "$rec75" >"$WORK/rec75-retire.out" 2>"$WORK/rec75-retire.err"
rec75_retire_rmrc=$?
[ "$rec75_retire_rmrc" -eq 0 ] && pass "reconcile retire: retiring the record exits 0" || fail "reconcile retire: retiring the record exits 0 (rc=$rec75_retire_rmrc)"
rec75_retire_resolve_out=$("$REC" resolve --id "$rec75_retire_id" --disposition retired "$rec75" 2>"$WORK/rec75-retire-resolve.err")
rec75_retire_resolve_rc=$?
[ "$rec75_retire_resolve_rc" -eq 0 ] && pass "reconcile retire: resolve exits 0" || fail "reconcile retire: resolve exits 0 (rc=$rec75_retire_resolve_rc)"
printf '%s\n' "$rec75_retire_resolve_out" | grep -qF "resolved	$rec75_retire_id	retired" \
  && pass "reconcile retire: resolve's result line names the id and retired" \
  || fail "reconcile retire: resolve's result line names the id and retired ($rec75_retire_resolve_out)"
grep -qF "id=$rec75_retire_id | retired" "$rec75_inv" \
  && pass "reconcile retire: the inventory line now reads retired" \
  || fail "reconcile retire: the inventory line now reads retired"

# ---- doc repair: three hand edits (no headerless-doc writer exists, by
# design — docs.sh rehook refuses one), then rehook, then resolve. ----
cat >"$rec75/.agent/docs/architecture.md" <<'EOF'
# Architecture

### `dup.md`
- **Read when:** first dup entry.

### `badtable.md`
- **Read when:** placeholder, to be set by rehook.

### `noentry.md`
- **Read when:** placeholder, to be set by rehook.
EOF
for rec75_doc in dup badtable noentry; do
  printf '<!-- Read when: placeholder, to be set by rehook. -->\n' >"$WORK/rec75-$rec75_doc.hdr"
  cat "$WORK/rec75-$rec75_doc.hdr" "$rec75/.agent/docs/$rec75_doc.md" >"$WORK/rec75-$rec75_doc.new"
  mv "$WORK/rec75-$rec75_doc.new" "$rec75/.agent/docs/$rec75_doc.md"
done
"$RECDOCS" rehook --name dup --read-when "reading about the duplicate entry" "$rec75" >"$WORK/rec75-rehook-dup.out" 2>&1
rec75_rehook_dup_rc=$?
"$RECDOCS" rehook --name badtable --read-when "reading about the hand-edited table" "$rec75" >"$WORK/rec75-rehook-badtable.out" 2>&1
rec75_rehook_badtable_rc=$?
"$RECDOCS" rehook --name noentry --read-when "reading about the doc with no entry" "$rec75" >"$WORK/rec75-rehook-noentry.out" 2>&1
rec75_rehook_noentry_rc=$?
[ "$rec75_rehook_dup_rc" -eq 0 ] && [ "$rec75_rehook_badtable_rc" -eq 0 ] && [ "$rec75_rehook_noentry_rc" -eq 0 ] \
  && pass "reconcile doc repair: docs.sh rehook succeeds on all three repaired docs" \
  || fail "reconcile doc repair: docs.sh rehook succeeds on all three repaired docs (rc=$rec75_rehook_dup_rc/$rec75_rehook_badtable_rc/$rec75_rehook_noentry_rc)"
for rec75_doc in dup badtable noentry; do
  [ "$(sed -n 1p "$rec75/.agent/docs/$rec75_doc.md")" != '<!-- Read when: placeholder, to be set by rehook. -->' ] \
    && pass "reconcile doc repair: $rec75_doc.md's header now reads the real hook text" \
    || fail "reconcile doc repair: $rec75_doc.md's header now reads the real hook text"
  "$REC" resolve --id "$rec75_doc.md" --disposition migrated "$rec75" >"$WORK/rec75-resolve-$rec75_doc.out" 2>"$WORK/rec75-resolve-$rec75_doc.err"
  rec75_doc_resolve_rc=$?
  [ "$rec75_doc_resolve_rc" -eq 0 ] \
    && pass "reconcile doc repair: resolve $rec75_doc.md to migrated exits 0" \
    || fail "reconcile doc repair: resolve $rec75_doc.md to migrated exits 0 (rc=$rec75_doc_resolve_rc)"
  grep -qF "id=$rec75_doc.md | migrated" "$rec75_inv" \
    && pass "reconcile doc repair: $rec75_doc.md's inventory line now reads migrated" \
    || fail "reconcile doc repair: $rec75_doc.md's inventory line now reads migrated"
done

# ---- refusal classes, continued: each refuses at exit 2, writes
# nothing, and names what it checked ----
rec75_before=$(rec75_inv_snapshot)
"$REC" resolve --id deadbeef0000 --disposition migrated "$rec75" >/dev/null 2>"$WORK/rec75-ref-absent.err"
[ "$?" -eq 2 ] && pass "reconcile refusal: an id the inventory does not carry refuses at exit 2" || fail "reconcile refusal: an id the inventory does not carry refuses at exit 2"
grep -qF 'carries no item with id=deadbeef0000' "$WORK/rec75-ref-absent.err" \
  && pass "reconcile refusal: the absent-id refusal names the id it checked" \
  || fail "reconcile refusal: the absent-id refusal names the id it checked"
[ "$(rec75_inv_snapshot)" = "$rec75_before" ] && pass "reconcile refusal: the absent-id refusal writes nothing" || fail "reconcile refusal: the absent-id refusal writes nothing"

"$REC" resolve --id "$rec75_keep_id" --disposition migrated "$rec75" >/dev/null 2>"$WORK/rec75-ref-already.err"
[ "$?" -eq 2 ] && pass "reconcile refusal: an item already resolved refuses at exit 2" || fail "reconcile refusal: an item already resolved refuses at exit 2"
grep -qF 'is not pending' "$WORK/rec75-ref-already.err" \
  && pass "reconcile refusal: the already-resolved refusal names the current disposition" \
  || fail "reconcile refusal: the already-resolved refusal names the current disposition"

# A fresh doc item, still pending, to test the three rule-only forms and
# the still-missing-hook refusal without reusing an already-resolved id.
rec75_2="$WORK/reconcile-fixture-2"
mkdir -p "$rec75_2"
make_v6_fixture "$rec75_2"
rec75_2_modeline=$(grep -n '^  mode:' "$rec75_2/.agent/purpose.md" | head -1 | cut -d: -f1)
awk -v ln="$rec75_2_modeline" \
  'NR==ln { print; print "  indexes: generated        # manual | generated"; next } { print }' \
  "$rec75_2/.agent/purpose.md" >"$rec75_2/.agent/purpose.md.tmp"
mv "$rec75_2/.agent/purpose.md.tmp" "$rec75_2/.agent/purpose.md"
mkdir -p "$rec75_2/.agent/docs"
cat >"$rec75_2/.agent/docs/noentry.md" <<'EOF'
# Noentry

Body.
EOF
"$NODE" update "$rec75_2" >"$WORK/rec75-2-update.out" 2>&1
REC2="$rec75_2/.agent/scripts/learn.sh"
rec75_2_inv="$rec75_2/.agent/migration-inventory.md"

rec75_2_before=$(git hash-object --no-filters -- "$rec75_2_inv")
"$REC2" resolve --id noentry.md --disposition retired "$rec75_2" >/dev/null 2>"$WORK/rec75-ref-docretired.err"
[ "$?" -eq 2 ] && pass "reconcile refusal: retired on a doc item refuses at exit 2" || fail "reconcile refusal: retired on a doc item refuses at exit 2"
grep -qF 'rule-only' "$WORK/rec75-ref-docretired.err" \
  && pass "reconcile refusal: the doc-retired refusal names the three forms as rule-only" \
  || fail "reconcile refusal: the doc-retired refusal names the three forms as rule-only"
[ "$(git hash-object --no-filters -- "$rec75_2_inv")" = "$rec75_2_before" ] \
  && pass "reconcile refusal: the doc-retired refusal writes nothing" \
  || fail "reconcile refusal: the doc-retired refusal writes nothing"

rec75_2_before=$(git hash-object --no-filters -- "$rec75_2_inv")
"$REC2" resolve --id noentry.md --disposition "migrated (split into deadbeefcafe)" "$rec75_2" >/dev/null 2>"$WORK/rec75-ref-docsplit.err"
[ "$?" -eq 2 ] && pass "reconcile refusal: split on a doc item refuses at exit 2" || fail "reconcile refusal: split on a doc item refuses at exit 2"
[ "$(git hash-object --no-filters -- "$rec75_2_inv")" = "$rec75_2_before" ] \
  && pass "reconcile refusal: the doc-split refusal writes nothing" \
  || fail "reconcile refusal: the doc-split refusal writes nothing"

rec75_2_before=$(git hash-object --no-filters -- "$rec75_2_inv")
"$REC2" resolve --id noentry.md --disposition "migrated (merged into deadbeefcafe)" "$rec75_2" >/dev/null 2>"$WORK/rec75-ref-docmerge.err"
[ "$?" -eq 2 ] && pass "reconcile refusal: merge on a doc item refuses at exit 2" || fail "reconcile refusal: merge on a doc item refuses at exit 2"
[ "$(git hash-object --no-filters -- "$rec75_2_inv")" = "$rec75_2_before" ] \
  && pass "reconcile refusal: the doc-merge refusal writes nothing" \
  || fail "reconcile refusal: the doc-merge refusal writes nothing"

rec75_2_before=$(git hash-object --no-filters -- "$rec75_2_inv")
"$REC2" resolve --id noentry.md --disposition migrated "$rec75_2" >/dev/null 2>"$WORK/rec75-ref-nohook.err"
[ "$?" -eq 2 ] && pass "reconcile refusal: migrated on a doc whose hook is still missing refuses at exit 2" || fail "reconcile refusal: migrated on a doc whose hook is still missing refuses at exit 2"
grep -qF 'still carries no' "$WORK/rec75-ref-nohook.err" \
  && pass "reconcile refusal: the still-missing-hook refusal names the predicate it checked" \
  || fail "reconcile refusal: the still-missing-hook refusal names the predicate it checked"
[ "$(git hash-object --no-filters -- "$rec75_2_inv")" = "$rec75_2_before" ] \
  && pass "reconcile refusal: the still-missing-hook refusal writes nothing" \
  || fail "reconcile refusal: the still-missing-hook refusal writes nothing"

# Duplicate-id refusal: only reachable through a hand-edited inventory —
# resolve never produces one itself.
cp "$rec75_2_inv" "$WORK/rec75-2-inv-before.md"
rec75_dupline=$(grep -F 'id=noentry.md' "$rec75_2_inv")
{ cat "$rec75_2_inv"; printf '%s\n' "$rec75_dupline"; } >"$WORK/rec75-2-inv-dup.md"
cp "$WORK/rec75-2-inv-dup.md" "$rec75_2_inv"
rec75_dupline_before=$(git hash-object --no-filters -- "$rec75_2_inv")
"$REC2" resolve --id noentry.md --disposition migrated "$rec75_2" >/dev/null 2>"$WORK/rec75-ref-dupline.err"
[ "$?" -eq 2 ] && pass "reconcile refusal: an id on more than one inventory line refuses at exit 2" || fail "reconcile refusal: an id on more than one inventory line refuses at exit 2"
grep -qF 'more than one line' "$WORK/rec75-ref-dupline.err" \
  && pass "reconcile refusal: the duplicate-line refusal names what it checked" \
  || fail "reconcile refusal: the duplicate-line refusal names what it checked"
[ "$(git hash-object --no-filters -- "$rec75_2_inv")" = "$rec75_dupline_before" ] \
  && pass "reconcile refusal: the duplicate-line refusal writes nothing" \
  || fail "reconcile refusal: the duplicate-line refusal writes nothing"
cp "$WORK/rec75-2-inv-before.md" "$rec75_2_inv"

# ---- Acceptance box 2's other half: pending on a node that carries no
# migration-inventory.md at all — a plain generated-mode node that never
# migrated, not a missing root. ----
rec75_noinv="$WORK/reconcile-no-inventory"
mkdir -p "$rec75_noinv"
"$NODE" init --preset software-development --mode ignore-all --indexes generated "$rec75_noinv" >/dev/null 2>&1
[ ! -f "$rec75_noinv/.agent/migration-inventory.md" ] \
  && pass "learn.sh pending: the no-inventory fixture genuinely carries no migration-inventory.md" \
  || fail "learn.sh pending: the no-inventory fixture genuinely carries no migration-inventory.md"
RECNOINV="$rec75_noinv/.agent/scripts/learn.sh"
rec75_noinv_pending_out=$("$RECNOINV" pending "$rec75_noinv" 2>"$WORK/rec75-noinv-pending.err")
rec75_noinv_pending_rc=$?
[ "$rec75_noinv_pending_rc" -eq 0 ] \
  && pass "learn.sh pending: a node with no migration-inventory.md exits 0" \
  || fail "learn.sh pending: a node with no migration-inventory.md exits 0 (rc=$rec75_noinv_pending_rc)"
[ -z "$rec75_noinv_pending_out" ] \
  && pass "learn.sh pending: a node with no migration-inventory.md prints nothing" \
  || fail "learn.sh pending: a node with no migration-inventory.md prints nothing ($rec75_noinv_pending_out)"

# ---- final pending: the backlog is empty ----
rec75_pending2=$("$REC" pending "$rec75")
rec75_pending2_rc=$?
[ "$rec75_pending2_rc" -eq 0 ] \
  && pass "learn.sh pending: a fully reconciled node's second run exits 0" \
  || fail "learn.sh pending: a fully reconciled node's second run exits 0 (rc=$rec75_pending2_rc)"
[ -z "$rec75_pending2" ] \
  && pass "learn.sh pending: a fully reconciled node's second run lists nothing" \
  || fail "learn.sh pending: a fully reconciled node's second run lists nothing ($rec75_pending2)"

# A second node.sh update over the reconciled node rewrites no record and
# no inventory line. Scoped to exactly that: rules/learned/*.md and
# migration-inventory.md, not the whole tree — indexes/ regenerates a
# fresh gen.XXXXXXXX cache directory on every ensure by design (unrelated
# to reconciliation), and the derived aggregate rules/learned.md is
# excluded for the same reason index.sh regenerates it on every ensure.
rec75_snapshot() {
  { find "$1/.agent/rules/learned" -maxdepth 1 -name '*.md' 2>/dev/null; printf '%s\n' "$1/.agent/migration-inventory.md"; } \
    | sort | xargs shasum 2>/dev/null | sort
}
rec75_before_update=$(rec75_snapshot "$rec75")
"$NODE" update "$rec75" >"$WORK/rec75-update2.out" 2>&1
rec75_update2_rc=$?
rec75_after_update=$(rec75_snapshot "$rec75")
[ "$rec75_update2_rc" -eq 0 ] && pass "reconcile: a second node.sh update over the reconciled node exits 0" || fail "reconcile: a second node.sh update over the reconciled node exits 0 (rc=$rec75_update2_rc)"
[ "$rec75_before_update" = "$rec75_after_update" ] \
  && pass "reconcile: a second node.sh update rewrites no record and no inventory line, rules/learned.md aside" \
  || fail "reconcile: a second node.sh update rewrites no record and no inventory line, rules/learned.md aside"

# ---- summary ----
ran=$((PASS + FAIL))

# The denominator is computed from what ran, so a check that stops running
# — a fixture that failed to build, a variable gone empty — used to lower
# the total silently and still report every check passing. Update this
# number when you add or remove a check, deliberately.
EXPECTED_CHECKS=1331
if [ "$ran" -ne "$EXPECTED_CHECKS" ]; then
  printf 'FAIL check count: expected %d, ran %d — a check was added, removed, or stopped running\n' "$EXPECTED_CHECKS" "$ran"
  FAIL=$((FAIL + 1))
fi

total=$((PASS + FAIL))
printf '\n%d/%d checks passed (%d failed)\n' "$PASS" "$total" "$FAIL"
[ "$FAIL" -eq 0 ] && exit 0
exit 1
