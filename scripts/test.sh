#!/usr/bin/env bash

set -u

selfdir=$(cd "$(dirname "$0")" && pwd)
reporoot=$(cd "$selfdir/.." && pwd)
NODE="$reporoot/scripts/node.sh"
LOGSH="$reporoot/scripts/log.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/dot-agent-test.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }

# The v6.3 test files are standalone scripts. They run one after another in
# the background while the sections below run, and report at the end.
v63_out="$WORK/v63-checks"
mkdir -p "$v63_out"
(
  trap - EXIT
  for v63_test in "$reporoot"/scripts/tests/*-v63.sh; do
    [ -f "$v63_test" ] || continue
    bash "$v63_test" >"$v63_out/${v63_test##*/}.out" 2>&1
    echo "$?" >"$v63_out/${v63_test##*/}.rc"
  done
) &
v63_pid=$!


status_flags() {
  "$1/.agent/scripts/status.sh" "$1" 2>"$WORK/.status-stderr" | grep -E '^(GROOM|REPAIR|INDEX):'
  sf_rc=${PIPESTATUS[0]}
  if [ "$sf_rc" -ne 0 ] || [ -s "$WORK/.status-stderr" ]; then
    echo "STATUSFAIL: rc=$sf_rc stderr=$(tr '\n' ' ' <"$WORK/.status-stderr" | cut -c1-120)"
  fi
}

subst() {
  sed "$2" "$1" >"$1.tmp" && mv "$1.tmp" "$1"
}

words_n() {
  n="$1"; i=1; out=""
  while [ "$i" -le "$n" ]; do out="$out w$i"; i=$((i + 1)); done
  printf '%s' "${out# }"
}

today() { date +%Y-%m-%d; }

finish_bootstrap() {
  fb_contract="$1/.agent/rules/contract.md"
  awk '/^## Quality bar/ { inq = 1 } inq && /^## / && !/^## Quality bar/ { inq = 0 } !inq' \
    "$fb_contract" >"$fb_contract.body"
  awk '/^## Quality bar/ { inq = 1 } inq && /^## / && !/^## Quality bar/ { inq = 0 } inq' \
    "$fb_contract" >"$1/.agent/rules/quality-bar.md"
  mv "$fb_contract.body" "$fb_contract"
  subst "$fb_contract" 's/^\(- [A-Za-z][^:]*:\) <.*>$/\1 filled at bootstrap/'
  if [ -f "$1/.agent/scripts/verify.sh" ]; then
    cat >"$1/.agent/scripts/checks.sh" <<'CHECKS'
#!/usr/bin/env bash
printf 'TAP version 13\n1..1\nok 1 - controlled fixture check\n'
CHECKS
  fi
}

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

# The eval-harness checks drive run.sh end to end against fake CLIs and take
# about half the suite's wall time. They read only the helpers above and share
# no files with the other sections, so they start first, in a background
# subshell, and run beside everything below. Their check lines and
# counts merge into the totals at the end, so the check-count gate stays exact.
eval_checks_out="$WORK/eval-checks.out"
(
  trap - EXIT
  . "$selfdir/tests/eval-suite.sh"
) >"$eval_checks_out" 2>&1 &
eval_checks_pid=$!

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

idx_mtime() {
  stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1"
}

idx_snapshot() {
  find "$1" -type f -exec sh -c 'for f; do
    sz=$(wc -c <"$f"); mt=$(stat -c "%Y" "$f" 2>/dev/null || stat -f "%m" "$f"); printf "%s %s %s\n" "$f" "$sz" "$mt"
  done' sh {} + | sort
}

PRESETS="software-development academic-research domain-knowledge"
MODES="ignore-all track-shared track-all"

"$NODE" --help >"$WORK/node-help.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "node.sh: top-level --help exits 0" || fail "node.sh: top-level --help exits 0 (rc=$rc)"
grep -qF 'update preserves the manifest value when' "$WORK/node-help.out" \
  && pass "node.sh: help distinguishes init's default from update's preserved mode" \
  || fail "node.sh: help distinguishes init's default from update's preserved mode"

for preset in $PRESETS; do
  for mode in $MODES; do
    root="$WORK/init-$preset-$mode"
    mkdir -p "$root"
    "$NODE" init --preset "$preset" --mode "$mode" "$root" >"$WORK/init.out" 2>&1
    rc=$?
    [ "$rc" -eq 0 ] && pass "init $preset/$mode exits 0" || fail "init $preset/$mode exits 0 (rc=$rc)"

    flags=$(status_flags "$root")
    printf '%s\n' "$flags" | grep -qF 'Project guardrails still holds template placeholders' && pass "init $preset/$mode: unfilled guardrails draw a REPAIR flag" || fail "init $preset/$mode: unfilled guardrails draw a REPAIR flag ($flags)"
    printf '%s\n' "$flags" | grep -qF 'still contains ## Quality bar' && pass "init $preset/$mode: unsplit quality bar draws a REPAIR flag" || fail "init $preset/$mode: unsplit quality bar draws a REPAIR flag ($flags)"

    finish_bootstrap "$root"
    flags=$(status_flags "$root")
    [ -z "$flags" ] && pass "init $preset/$mode: status.sh clean once bootstrap completes" || fail "init $preset/$mode: status.sh clean once bootstrap completes ($flags)"

    missing=""
    for f in status.sh log.sh memory.sh docs.sh links.sh comments.sh checkpoint.sh index.sh learn.sh runtime.sh verify.sh review.sh capture.sh absorb.sh checks.sh; do
      [ -x "$root/.agent/scripts/$f" ] || missing="$missing $f"
    done
    for f in comments.conf status.conf log.conf; do
      [ -f "$root/.agent/scripts/$f" ] || missing="$missing $f"
    done
    [ -z "$missing" ] && pass "init $preset/$mode: every shipped script and starter conf is in place" || fail "init $preset/$mode: every shipped script and starter conf is in place (missing:$missing)"
    [ ! -e "$root/.agent/scripts/docs" ] && pass "init $preset/$mode: scripts/docs is not shipped into the node" || fail "init $preset/$mode: scripts/docs is not shipped into the node"

    grep -qxF '  indexes: manual        # manual | generated' "$root/.agent/purpose.md" \
      && pass "init $preset/$mode: manifest defaults to indexes: manual" \
      || fail "init $preset/$mode: manifest defaults to indexes: manual"
  done
done

gi_ignore="$WORK/init-software-development-ignore-all/.gitignore"
[ "$(cat "$gi_ignore" 2>/dev/null)" = ".agent/" ] && pass "ignore-all: gitignore is exactly '.agent/'" || fail "ignore-all: gitignore is exactly '.agent/'"

gi_shared="$WORK/init-software-development-track-shared/.gitignore"
expected_shared=$(printf '.agent/*\n!.agent/purpose.md\n!.agent/rules/\n!.agent/docs/')
[ "$(cat "$gi_shared" 2>/dev/null)" = "$expected_shared" ] && pass "track-shared: gitignore matches the 4-line allowlist" || fail "track-shared: gitignore matches the 4-line allowlist"

gi_all="$WORK/init-software-development-track-all/.gitignore"
[ ! -e "$gi_all" ] && pass "track-all: no gitignore created" || fail "track-all: no gitignore created"

root2="$WORK/gitignore-preserve-ignore"
mkdir -p "$root2"
printf 'custom-content\n' >"$root2/.gitignore"
"$NODE" init --preset software-development --mode ignore-all "$root2" >/dev/null 2>&1
expected2=$(printf 'custom-content\n.agent/')
[ "$(cat "$root2/.gitignore" 2>/dev/null)" = "$expected2" ] && pass "ignore-all: pre-existing gitignore content preserved" || fail "ignore-all: pre-existing gitignore content preserved"

root3="$WORK/gitignore-preserve-shared"
mkdir -p "$root3"
printf 'foo\n' >"$root3/.gitignore"
"$NODE" init --preset software-development --mode track-shared "$root3" >/dev/null 2>&1
expected3=$(printf 'foo\n\n.agent/*\n!.agent/purpose.md\n!.agent/rules/\n!.agent/docs/')
[ "$(cat "$root3/.gitignore" 2>/dev/null)" = "$expected3" ] && pass "track-shared: pre-existing gitignore content preserved" || fail "track-shared: pre-existing gitignore content preserved"

root4="$WORK/gitignore-fresh-ignore"
mkdir -p "$root4"
"$NODE" init --preset software-development --mode ignore-all "$root4" >/dev/null 2>&1
if [ "$(cat "$root4/.gitignore" 2>/dev/null)" = ".agent/" ] && grep -qF "custom-content" "$root2/.gitignore" 2>/dev/null; then
  pass "re-init into another root does not cross-contaminate gitignores"
else
  fail "re-init into another root does not cross-contaminate gitignores"
fi

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
finish_bootstrap "$idxgen"
"$idxgen/.agent/scripts/index.sh" ensure --root "$idxgen" >/dev/null 2>&1
idx_links=$("$idxgen/.agent/scripts/links.sh" "$idxgen" 2>&1)
[ -e "$idxgen/.agent/indexes/current.md" ] && ! printf '%s\n' "$idx_links" | grep -q 'ORPHAN: indexes/' && pass "links.sh: the generated index cache is not an orphan" || fail "links.sh: the generated index cache is not an orphan ($idx_links)"

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

grep -v '^  version:' "$WORK/purpose-before.md" | grep -v '^  migration_target:' | grep -v '^  indexes:' | grep -v '^  hooks:' >"$WORK/pb-noversion"
grep -v '^  version:' "$v6root/.agent/purpose.md" | grep -v '^  migration_target:' | grep -v '^  indexes:' | grep -v '^  hooks:' >"$WORK/pa-noversion"
diff -q "$WORK/pb-noversion" "$WORK/pa-noversion" >/dev/null 2>&1 && pass "update: manifest diff touches only the version, migration_target, indexes, and hooks lines" || fail "update: manifest diff touches only the version, migration_target, indexes, and hooks lines"
grep -q '^  version: 6$' "$v6root/.agent/purpose.md" 2>/dev/null && pass "update: version stays at 6 (unbumped) — finalize's job" || fail "update: version stays at 6 (unbumped) — finalize's job"
grep -q '^  migration_target: "6.3"' "$v6root/.agent/purpose.md" 2>/dev/null && pass "update: migration_target is now \"6.3\"" || fail "update: migration_target is now \"6.3\""
[ "$(grep -A1 '^  version:' "$v6root/.agent/purpose.md" | tail -n1)" = '  migration_target: "6.3"' ] && pass "update: migration_target is inserted right after version" || fail "update: migration_target is inserted right after version"
grep -qF "finalize" "$WORK/update.out" && pass "update: closing message names the pending finalize step" || fail "update: closing message names the pending finalize step"

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

adopt_migrating="$WORK/adopt-generated-migrating"
mkdir -p "$adopt_migrating"
make_v6_fixture "$adopt_migrating" track-shared
git -C "$adopt_migrating" init -q
git -C "$adopt_migrating" add .agent/purpose.md .agent/rules .agent/docs
git -C "$adopt_migrating" -c user.name=Fixture -c user.email=fixture@example.com commit -qm base
"$NODE" update --indexes generated "$adopt_migrating" >"$WORK/adopt-generated-migrating.out" 2>&1
rc_adopt_migrating=$?
[ "$rc_adopt_migrating" -eq 0 ] \
  && grep -qxF '  indexes: generated        # manual | generated' "$adopt_migrating/.agent/purpose.md" \
  && pass "update --indexes generated selects generated mode during a version migration" \
  || fail "update --indexes generated selects generated mode during a version migration (rc=$rc_adopt_migrating; $(cat "$WORK/adopt-generated-migrating.out"))"
[ -f "$adopt_migrating/.agent/indexes/current.md" ] \
  && [ "$(find "$adopt_migrating/.agent/rules/learned" -maxdepth 1 -name '*.md' -type f | wc -l | tr -d ' ')" -eq 1 ] \
  && pass "migration-time generated adoption extracts rules and builds the index" \
  || fail "migration-time generated adoption extracts rules and builds the index"

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

adopt_current="$WORK/adopt-generated-current"
mkdir -p "$adopt_current"
git -C "$adopt_current" init -q
"$NODE" init --preset software-development --mode track-shared --indexes manual "$adopt_current" >/dev/null 2>&1
cat >>"$adopt_current/.agent/rules/learned.md" <<'EOF'
- [2026-09-20] Keep the payment timeout aligned with the vendor SLA. Trigger: timeout drift.
- [2026-09-20] Run the reconciliation check before deployment. Trigger: missed reconciliation.
EOF
git -C "$adopt_current" add .gitignore .agent/purpose.md .agent/rules .agent/docs
git -C "$adopt_current" -c user.name=Fixture -c user.email=fixture@example.com commit -qm base
"$NODE" update --indexes generated "$adopt_current" >"$WORK/adopt-generated-current.out" 2>&1
rc_adopt_current=$?
[ "$rc_adopt_current" -eq 0 ] && pass "update --indexes generated adopts generated mode on a version-current node" || fail "update --indexes generated adopts generated mode on a version-current node (rc=$rc_adopt_current; $(cat "$WORK/adopt-generated-current.out"))"
[ -d "$adopt_current/.agent.backup-v6.3-indexes-generated" ] \
  && pass "generated-mode adoption backs up a version-current track-shared node" \
  || fail "generated-mode adoption backs up a version-current track-shared node"
grep -qxF '  indexes: generated        # manual | generated' "$adopt_current/.agent/purpose.md" \
  && pass "generated-mode adoption records indexes: generated" \
  || fail "generated-mode adoption records indexes: generated"
adopt_record_count=$(find "$adopt_current/.agent/rules/learned" -maxdepth 1 -name '*.md' -type f | wc -l | tr -d ' ')
[ "$adopt_record_count" -eq 2 ] \
  && pass "generated-mode adoption extracts every learned rule into a record" \
  || fail "generated-mode adoption extracts every learned rule into a record (count=$adopt_record_count)"
grep -qF 'Keep the payment timeout aligned with the vendor SLA.' "$adopt_current/.agent/rules/learned.md" \
  && grep -qF 'Run the reconciliation check before deployment.' "$adopt_current/.agent/rules/learned.md" \
  && pass "generated-mode adoption regenerates the aggregate without rule loss" \
  || fail "generated-mode adoption regenerates the aggregate without rule loss"
if grep -qxF '.agent/indexes/' "$adopt_current/.gitignore" \
  && grep -qxF '.agent/rules/learned.md' "$adopt_current/.gitignore"; then
  pass "generated-mode adoption adds both ignore rules"
else
  fail "generated-mode adoption adds both ignore rules"
fi
git -C "$adopt_current" ls-files --error-unmatch -- .agent/rules/learned.md >/dev/null 2>&1 \
  && fail "generated-mode adoption untracks the derived learned aggregate" \
  || pass "generated-mode adoption untracks the derived learned aggregate"
[ -f "$adopt_current/.agent/indexes/current.md" ] && [ -x "$adopt_current/.agent/scripts/learn.sh" ] \
  && pass "generated-mode adoption builds the index and installs its learned-record writer" \
  || fail "generated-mode adoption builds the index and installs its learned-record writer"
adopt_records_before=$(find "$adopt_current/.agent/rules/learned" -maxdepth 1 -name '*.md' -type f -exec shasum {} + | sort)
"$NODE" update --indexes generated "$adopt_current" >"$WORK/adopt-generated-current-2.out" 2>&1
rc_adopt_current_2=$?
adopt_records_after=$(find "$adopt_current/.agent/rules/learned" -maxdepth 1 -name '*.md' -type f -exec shasum {} + | sort)
[ "$rc_adopt_current_2" -eq 0 ] && [ "$adopt_records_before" = "$adopt_records_after" ] \
  && pass "generated-mode adoption is idempotent on a second explicit run" \
  || fail "generated-mode adoption is idempotent on a second explicit run (rc=$rc_adopt_current_2)"
"$NODE" update --indexes manual "$adopt_current" >"$WORK/adopt-generated-revert.out" 2>&1
rc_adopt_revert=$?
[ "$rc_adopt_revert" -ne 0 ] && grep -qF 'refusing generated-to-manual conversion' "$WORK/adopt-generated-revert.out" \
  && pass "update refuses generated-to-manual conversion outside the documented procedure" \
  || fail "update refuses generated-to-manual conversion outside the documented procedure (rc=$rc_adopt_revert)"
grep -qxF '  indexes: generated        # manual | generated' "$adopt_current/.agent/purpose.md" \
  && pass "a refused generated-to-manual update leaves the manifest unchanged" \
  || fail "a refused generated-to-manual update leaves the manifest unchanged"

adopt_collision="$WORK/adopt-generated-shape-collision"
mkdir -p "$adopt_collision"
"$NODE" init --preset software-development --mode track-shared --indexes manual "$adopt_collision" >/dev/null 2>&1
subst "$adopt_collision/.agent/memory.md" 's/This contract covers memory\/ too/This older header lacks the directory contract/'
mkdir -p "$adopt_collision/.agent.backup-v6.3-shape"
printf 'pre-existing shape backup\n' >"$adopt_collision/.agent.backup-v6.3-shape/marker"
cp -R "$adopt_collision/.agent" "$WORK/adopt-collision-agent-before"
cp "$adopt_collision/.gitignore" "$WORK/adopt-collision-gitignore-before"
"$NODE" update --indexes generated "$adopt_collision" >"$WORK/adopt-collision.out" 2>&1
rc_adopt_collision=$?
[ "$rc_adopt_collision" -ne 0 ] && grep -qF 'backup path already exists' "$WORK/adopt-collision.out" \
  && pass "generated adoption preflights a conflicting shape backup" \
  || fail "generated adoption preflights a conflicting shape backup (rc=$rc_adopt_collision; $(cat "$WORK/adopt-collision.out"))"
if diff -r "$WORK/adopt-collision-agent-before" "$adopt_collision/.agent" >/dev/null 2>&1 \
  && diff -q "$WORK/adopt-collision-gitignore-before" "$adopt_collision/.gitignore" >/dev/null 2>&1 \
  && [ ! -e "$adopt_collision/.agent.backup-v6.3-indexes-generated" ]; then
  pass "a generated-adoption backup collision leaves the node untouched"
else
  fail "a generated-adoption backup collision leaves the node untouched"
fi

flags4=$(status_flags "$v6root")
printf '%s\n' "$flags4" | grep -q '^GROOM: memory/legacy\.md' && pass "update: status.sh flags legacy.md with GROOM" || fail "update: status.sh flags legacy.md with GROOM"
flags4_repairs=$(printf '%s\n' "$flags4" | grep '^REPAIR:')
[ "$flags4_repairs" = 'REPAIR: purpose.md has migration_target "6.3" pending — run node.sh finalize to stamp version 6.3 and clear migration_target' ] \
  && pass "update: status.sh shows only the pending-migration REPAIR" \
  || fail "update: status.sh shows only the pending-migration REPAIR ($flags4_repairs)"

cp -R "$v6root/.agent" "$WORK/v6root-agent-snapshot"
"$NODE" update "$v6root" >"$WORK/update2.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "update re-run (pending migration_target) exits 0" || fail "update re-run (pending migration_target) exits 0 (rc=$rc)"
grep -qF "node is current" "$WORK/update2.out" && fail "update re-run with a pending migration_target does not report the node current" || pass "update re-run with a pending migration_target does not report the node current"
grep -qF "resuming" "$WORK/update2.out" && pass "update re-run reports resuming the interrupted update" || fail "update re-run reports resuming the interrupted update"
diff -r "$WORK/v6root-agent-snapshot" "$v6root/.agent" >/dev/null 2>&1 && pass "update re-run with a pending migration_target is a content no-op (diff -r clean)" || fail "update re-run with a pending migration_target is a content no-op (diff -r clean)"

interrupt="$WORK/update-interrupted"
mkdir -p "$interrupt"
make_v6_fixture "$interrupt"
cp -R "$interrupt/.agent" "$interrupt/.agent.backup-v6"
printf 'pre-existing backup marker\n' >"$interrupt/.agent.backup-v6/.marker"
awk '/^  version: 6$/ { print; print "  migration_target: \"6.3\""; next } { print }' \
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

splitA="$WORK/update-split-interrupted-a"
mkdir -p "$splitA/.agent/memory"
make_v6_fixture "$splitA"
cp -R "$splitA/.agent" "$splitA/.agent.backup-v6"
awk '/^  version: 6$/ { print; print "  migration_target: \"6.3\""; next } { print }' \
  "$splitA/.agent/purpose.md" >"$splitA/.agent/purpose.md.tmp"
mv "$splitA/.agent/purpose.md.tmp" "$splitA/.agent/purpose.md"
"$NODE" update "$splitA" >"$WORK/update-splitA.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "update: resume after memory/ created but empty exits 0" || fail "update: resume after memory/ created but empty exits 0 (rc=$rc)"
grep -q "custom auth flow" "$splitA/.agent/memory/legacy.md" 2>/dev/null && pass "update: resume after an empty memory/ still moves the body to legacy.md" || fail "update: resume after an empty memory/ still moves the body to legacy.md"
splitA_links=$(grep -cF "[Legacy memory](memory/legacy.md)" "$splitA/.agent/memory.md")
[ "$splitA_links" -eq 1 ] && pass "update: resume after an empty memory/ adds exactly one index link" || fail "update: resume after an empty memory/ adds exactly one index link (count=$splitA_links)"
grep -q "custom auth flow" "$splitA/.agent/memory.md" 2>/dev/null && fail "update: resume after an empty memory/ does not leave the body behind in memory.md" || pass "update: resume after an empty memory/ does not leave the body behind in memory.md"

splitB="$WORK/update-split-interrupted-b"
mkdir -p "$splitB/.agent/memory"
make_v6_fixture "$splitB"
printf 'This project uses a custom auth flow with rotating tokens. The staging\ndatabase resets nightly at 02:00 UTC. Deploy via the internal release\ntool, never raw kubectl.\n' \
  >"$splitB/.agent/memory/legacy.md"
: >"$splitB/.agent/memory/.split-in-progress"
cp -R "$splitB/.agent" "$splitB/.agent.backup-v6"
awk '/^  version: 6$/ { print; print "  migration_target: \"6.3\""; next } { print }' \
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
awk '/^  version: 6$/ { print; print "  migration_target: \"6.3\""; next } { print }' \
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

nomanifest="$WORK/update-no-manifest"
mkdir -p "$nomanifest/.agent"
touch "$nomanifest/.agent/placeholder"
cp -R "$nomanifest/.agent" "$WORK/nomanifest-snapshot"
"$NODE" update "$nomanifest" >"$WORK/update3.out" 2>"$WORK/update3.err"
rc=$?
[ "$rc" -ne 0 ] && pass "update with no manifest exits nonzero" || fail "update with no manifest exits nonzero"
diff -r "$WORK/nomanifest-snapshot" "$nomanifest/.agent" >/dev/null 2>&1 && pass "update with no manifest leaves the node untouched" || fail "update with no manifest leaves the node untouched"

current_root="$WORK/init-software-development-track-all"
cp -R "$current_root/.agent" "$WORK/current-snapshot"
"$NODE" update "$current_root" >"$WORK/update4.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "update on a current node exits 0" || fail "update on a current node exits 0 (rc=$rc)"
grep -q "current" "$WORK/update4.out" && pass "update on a current node prints 'current'" || fail "update on a current node prints 'current'"
diff -r "$WORK/current-snapshot" "$current_root/.agent" >/dev/null 2>&1 && pass "update on a current node is a no-op" || fail "update on a current node is a no-op"

stale62="$WORK/current-stale-memory-header"
cp -R "$current_root" "$stale62"
"$stale62/.agent/scripts/memory.sh" new --slug keep --title Keep --hook "keep this hook" --fact "Keep this fact body." "$stale62" >/dev/null 2>&1
subst "$stale62/.agent/memory.md" 's/ Before writing, search purpose.*architecture\.md already routes it\.//'
subst "$stale62/.agent/purpose.md" 's/mode: track-all/mode: track-shared/'
mkdir -p "$stale62/.agent.backup-v6.3"
printf 'earlier backup\n' >"$stale62/.agent.backup-v6.3/marker"
grep -qF 'If one already states it' "$stale62/.agent/memory.md" && fail "update: stale 6.3 fixture actually lacks the new admission test" || pass "update: stale 6.3 fixture lacks the new admission test"
"$NODE" update "$stale62" >/dev/null 2>&1
grep -qF 'If one already states it, update that source or its routing, write no fact, and say which source states it.' "$stale62/.agent/memory.md" && pass "update: a version-current node refreshes a stale memory header" || fail "update: a version-current node refreshes a stale memory header"
grep -qxF -- '- [Keep](memory/keep.md) — keep this hook' "$stale62/.agent/memory.md" && grep -qF 'Keep this fact body.' "$stale62/.agent/memory/keep.md" && pass "update: refreshing the stale memory header keeps facts and index lines" || fail "update: refreshing the stale memory header keeps facts and index lines"
if [ -f "$stale62/.agent.backup-v6.3/marker" ] \
  && [ -f "$stale62/.agent.backup-v6.3-shape/memory.md" ] \
  && ! grep -qF 'If one already states it' "$stale62/.agent.backup-v6.3-shape/memory.md"; then
  pass "update: same-version shape backup does not collide with an earlier backup"
else
  fail "update: same-version shape backup does not collide with an earlier backup"
fi

finroot="$WORK/finalize-node"
mkdir -p "$finroot"
make_v6_fixture "$finroot"
"$NODE" update "$finroot" >/dev/null 2>&1
cp "$finroot/.agent/purpose.md" "$WORK/fin-purpose-pending.md"

flags_pending=$(status_flags "$finroot")
printf '%s\n' "$flags_pending" | grep -qF 'REPAIR: purpose.md has migration_target "6.3" pending' && pass "status.sh: a pending migration_target draws a REPAIR finding naming the target" || fail "status.sh: a pending migration_target draws a REPAIR finding naming the target ($flags_pending)"
printf '%s\n' "$flags_pending" | grep -q 'REPAIR: purpose.md has migration_target.*finalize' && pass "status.sh: the pending-migration REPAIR finding names the finalize command" || fail "status.sh: the pending-migration REPAIR finding names the finalize command ($flags_pending)"

grep -vF '[Legacy memory](memory/legacy.md)' "$finroot/.agent/memory.md" >"$finroot/.agent/memory.md.tmp"
mv "$finroot/.agent/memory.md.tmp" "$finroot/.agent/memory.md"
flags_broken=$(status_flags "$finroot")
printf '%s\n' "$flags_broken" | grep -qF 'REPAIR: memory/legacy.md has no index line in memory.md' && pass "finalize fixture: the deliberate break draws a real REPAIR finding" || fail "finalize fixture: the deliberate break draws a real REPAIR finding ($flags_broken)"

"$NODE" finalize "$finroot" >"$WORK/finalize1.out" 2>"$WORK/finalize1.err"
rc=$?
[ "$rc" -ne 0 ] && pass "finalize: refuses when status.sh reports REPAIR findings" || fail "finalize: refuses when status.sh reports REPAIR findings (rc=$rc)"
grep -qF 'REPAIR: memory/legacy.md has no index line in memory.md' "$WORK/finalize1.err" && pass "finalize: refusal prints the offending REPAIR finding" || fail "finalize: refusal prints the offending REPAIR finding"
diff -q "$WORK/fin-purpose-pending.md" "$finroot/.agent/purpose.md" >/dev/null 2>&1 && pass "finalize: a refused finalize leaves version and migration_target unchanged" || fail "finalize: a refused finalize leaves version and migration_target unchanged"

printf '\n%s\n' '- [Legacy memory](memory/legacy.md) — unsplit pre-6.1 memory, split per its GROOM flag' >>"$finroot/.agent/memory.md"
flags_reconciled=$(status_flags "$finroot" | grep '^REPAIR:' | grep -v '^REPAIR: purpose\.md has migration_target ')
[ -z "$flags_reconciled" ] && pass "finalize fixture: reconciling the break clears every REPAIR finding but the pending-migration one" || fail "finalize fixture: reconciling the break clears every REPAIR finding but the pending-migration one ($flags_reconciled)"

"$NODE" finalize "$finroot" >"$WORK/finalize2.out" 2>"$WORK/finalize2.err"
rc=$?
[ "$rc" -eq 0 ] && pass "finalize: succeeds once the node is reconciled (zero REPAIR findings)" || fail "finalize: succeeds once the node is reconciled (zero REPAIR findings) (rc=$rc, err=$(cat "$WORK/finalize2.err"))"
grep -q '^  version: "6.3"$' "$finroot/.agent/purpose.md" && pass "finalize: version is stamped to the pending target" || fail "finalize: version is stamped to the pending target"
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

finstatusfail="$WORK/finalize-status-fail"
mkdir -p "$finstatusfail"
make_v6_fixture "$finstatusfail"
"$NODE" update "$finstatusfail" >/dev/null 2>&1
cp "$finstatusfail/.agent/purpose.md" "$WORK/fin-statusfail-purpose.md"
realstatussh="$finstatusfail/.agent/scripts/status.sh"
cp "$realstatussh" "$WORK/fin-statusfail-status.sh.orig"

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

cat >"$realstatussh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$realstatussh"
"$NODE" finalize "$finstatusfail" >"$WORK/finalize-statusfail3.out" 2>"$WORK/finalize-statusfail3.err"
rc=$?
[ "$rc" -ne 0 ] && pass "finalize: refuses when status.sh exits zero with empty stdout" || fail "finalize: refuses when status.sh exits zero with empty stdout (rc=$rc)"
diff -q "$WORK/fin-statusfail-purpose.md" "$finstatusfail/.agent/purpose.md" >/dev/null 2>&1 && pass "finalize: an empty-stdout refusal leaves the manifest byte-identical" || fail "finalize: an empty-stdout refusal leaves the manifest byte-identical"

cp "$WORK/fin-statusfail-status.sh.orig" "$realstatussh"
chmod +x "$realstatussh"
"$NODE" finalize "$finstatusfail" >"$WORK/finalize-statusfail4.out" 2>"$WORK/finalize-statusfail4.err"
rc=$?
[ "$rc" -eq 0 ] && pass "finalize: succeeds once the real status.sh runs cleanly again" || fail "finalize: succeeds once the real status.sh runs cleanly again (rc=$rc, err=$(cat "$WORK/finalize-statusfail4.err"))"


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
grep -q '^  version: "6.3"$' "$rmfail/.agent/purpose.md" && pass "finalize: a failed marker removal still leaves version stamped (removal runs after the stamp)" || fail "finalize: a failed marker removal still leaves version stamped"
grep -q '^  migration_target:' "$rmfail/.agent/purpose.md" && pass "finalize: a failed marker removal retains a detectable pending migration" || fail "finalize: a failed marker removal retains a detectable pending migration"

"$NODE" finalize "$rmfail" >"$WORK/rmf-retry.out" 2>"$WORK/rmf-retry.err"
rc=$?
[ "$rc" -eq 0 ] && pass "finalize: retrying after a failed marker removal succeeds" || fail "finalize: retrying after a failed marker removal succeeds (rc=$rc, err=$(cat "$WORK/rmf-retry.err"))"
grep -q '^  migration_target:' "$rmfail/.agent/purpose.md" && fail "finalize: the retry actually removes the marker" || pass "finalize: the retry actually removes the marker"

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
grep -q '^  version: "6.3"$' "$rmcfail/.agent/purpose.md" && pass "finalize: a corrupted marker-removal write still leaves version stamped" || fail "finalize: a corrupted marker-removal write still leaves version stamped"
grep -q '^  migration_target:' "$rmcfail/.agent/purpose.md" && pass "finalize: a corrupted marker-removal write retains a detectable pending migration" || fail "finalize: a corrupted marker-removal write retains a detectable pending migration"

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

"$logcopy" --tool claude --area testing --verify pass --summary "Renamed submitPayment in src/client.ts, commit 47feccc" "$logroot" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && tail -n 1 "$sessionlog" | grep -qF ') Renamed submitPayment in src/client.ts, commit 47feccc (testing). verify: pass.' && pass "log.sh: a summary naming a file or a SHA is written as given" || fail "log.sh: a summary naming a file or a SHA is written as given"

load8=$("$logroot/.agent/scripts/status.sh" --load "$logroot" 2>&1)
order8=$(printf '%s\n' "$load8" | grep -n '^==== ' | grep -v 'session-log.md, newest' | cut -d: -f2 | tr '\n' ' ')
[ "$order8" = "==== .agent/rules/learned.md ==== ==== .agent/rules/contract.md ==== ==== .agent/purpose.md ==== ==== .agent/memory.md ==== " ] \
  && pass "status.sh --load: the four files print under markers, learned, contract, purpose, memory" \
  || fail "status.sh --load: the four files print under markers, learned, contract, purpose, memory ($order8)"
printf '%s\n' "$load8" | grep -q '^## Kernel' && pass "status.sh --load: the contract body is in the output" || fail "status.sh --load: the contract body is in the output"
plain8=$("$logroot/.agent/scripts/status.sh" "$logroot" 2>&1)
! printf '%s\n' "$plain8" | grep '^==== ' | grep -vq 'session-log.md, newest' && pass "status.sh: without --load no file is printed" || fail "status.sh: without --load no file is printed"

groomroot="$WORK/groom-tokens"
mkdir -p "$groomroot"
"$NODE" init --preset software-development --mode track-all "$groomroot" >/dev/null 2>&1
finish_bootstrap "$groomroot"
"$groomroot/.agent/scripts/memory.sh" new --slug vendor --title Vendor --hook "vendor calls" --fact "Vendor limit measured on 2026-07-02 for PAY-318 against sandbox.vendor.example:8443; repro with npm run test:integration -- --grep vendor and VENDOR_SANDBOX_KEY set." "$groomroot" >/dev/null 2>&1
printf '\n%s\n' "$(words_n 320)" >>"$groomroot/.agent/memory/vendor.md"
groom8=$("$groomroot/.agent/scripts/status.sh" "$groomroot" 2>&1 | grep '^GROOM: memory/vendor.md')
groom8_missing=""
for tok in PAY-318 sandbox.vendor.example:8443 "npm run test:integration -- --grep vendor" VENDOR_SANDBOX_KEY 2026-07-02; do
  printf '%s' "$groom8" | grep -qF -- "$tok" || groom8_missing="$groom8_missing $tok"
done
[ -n "$groom8" ] && [ -z "${groom8_missing:-}" ] && pass "status.sh: the memory GROOM: line lists ticket, host, command, env var, and date" || fail "status.sh: the memory GROOM: line lists ticket, host, command, env var, and date (missing:${groom8_missing:-} line:${groom8:-none})"

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

finroot="$WORK/finish"
mkdir -p "$finroot/src"
"$NODE" init --preset software-development --mode track-all "$finroot" >/dev/null 2>&1
finish_bootstrap "$finroot"
printf 'export const a = 1\n' >"$finroot/src/a.ts"
# A parent commit: a first commit with a clean tree is reviewed whole.
git -C "$finroot" init -q && git -C "$finroot" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m init
git -C "$finroot" add -A && git -C "$finroot" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m base
out8e=$("$finroot/.agent/scripts/checkpoint.sh" --tool claude --area testing --verify n/a --summary "answered a question, no change" "$finroot" 2>&1)
rc=$?
n8f=$(grep -c '^- \[' "$finroot/.agent/session-log.md")
[ "$rc" -ne 0 ] && printf '%s' "$out8e" | grep -q 'no earlier checkpoint marks where this work began' && [ "$n8f" -eq 0 ] && pass "checkpoint.sh: an unchanged tree writes no entry" || fail "checkpoint.sh: an unchanged tree writes no entry (rc=$rc entries=$n8f)"
printf '// const old = fetch(url)\nexport const b = 2\n' >>"$finroot/src/a.ts"
out8f=$("$finroot/.agent/scripts/checkpoint.sh" --tool claude --area testing --checks test --summary "added b" "$finroot" 2>&1)
rc=$?
n8f2=$(grep -c '^- \[' "$finroot/.agent/session-log.md")
[ "$rc" -ne 0 ] && printf '%s' "$out8f" | grep -q 'BLOCK' && [ "$n8f2" -eq 0 ] && pass "checkpoint.sh: a BLOCK finding stops it before the log entry" || fail "checkpoint.sh: a BLOCK finding stops it before the log entry (rc=$rc entries=$n8f2)"
printf '// Vendor caps retries at three by contract; a fourth attempt is rejected upstream.\nexport const b = 2\n' >"$finroot/src/a.ts"
"$finroot/.agent/scripts/checkpoint.sh" --tool claude --area testing --checks test --summary "added b" "$finroot" >/dev/null 2>&1
rc=$?
n8f3=$(grep -c '^- \[' "$finroot/.agent/session-log.md")
[ "$rc" -eq 0 ] && [ "$n8f3" -eq 1 ] && pass "checkpoint.sh: on the clean run the entry is written once" || fail "checkpoint.sh: on the clean run the entry is written once (rc=$rc entries=$n8f3)"
git -C "$finroot" add -A && git -C "$finroot" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m work
"$finroot/.agent/scripts/checkpoint.sh" --tool claude --area testing --checks test --summary "committed b" --base HEAD~1 "$finroot" >/dev/null 2>&1
rc=$?
n8f3b=$(grep -c '^- \[' "$finroot/.agent/session-log.md")
[ "$rc" -eq 0 ] && [ "$n8f3b" -eq 2 ] && pass "checkpoint.sh: committed work still logs, against --base" || fail "checkpoint.sh: committed work still logs, against --base (rc=$rc entries=$n8f3b)"
i8f=1; while [ "$i8f" -le 3 ]; do printf -- '- [2026-08-0%s] (tool) %s verify: pass.\n' "$i8f" "$(words_n 70)" >>"$finroot/.agent/session-log.md"; i8f=$((i8f + 1)); done
printf 'export const c = 3\n' >>"$finroot/src/a.ts"
out8g=$("$finroot/.agent/scripts/checkpoint.sh" --tool claude --area testing --checks test --summary "added c" "$finroot" 2>&1)
rc=$?
n8f4=$(grep -c '^- \[' "$finroot/.agent/session-log.md")
[ "$rc" -ne 0 ] && printf '%s' "$out8g" | grep -q 'LOG_.*OVERSIZE\|^GROOM:' && [ "$n8f4" -eq 5 ] && pass "checkpoint.sh: a standing flag stops it before the log entry" || fail "checkpoint.sh: a standing flag stops it before the log entry (rc=$rc entries=$n8f4)"
finroot_nogit="$WORK/finish-nogit"
mkdir -p "$finroot_nogit"
"$NODE" init --preset software-development --mode ignore-all "$finroot_nogit" >/dev/null 2>&1
finish_bootstrap "$finroot_nogit"
"$finroot_nogit/.agent/scripts/checkpoint.sh" --tool claude --area testing --verify n/a --summary "no repo here" "$finroot_nogit" >/dev/null 2>&1
rc=$?
n8h=$(grep -c '^- \[' "$finroot_nogit/.agent/session-log.md")
[ "$rc" -eq 0 ] && [ "$n8h" -eq 1 ] && pass "checkpoint.sh: a non-git project still writes its entry" || fail "checkpoint.sh: a non-git project still writes its entry (rc=$rc entries=$n8h)"

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
out8i=$("$fsroot/.agent/scripts/checkpoint.sh" --tool claude --area testing --checks test --summary "syntax break" "$fsroot" 2>&1)
rc=$?
n8i=$(grep -c '^- \[' "$fsroot/.agent/session-log.md")
[ "$rc" -ne 0 ] && [ "$n8i" -eq "$n8i0" ] && printf '%s' "$out8i" | grep -q 'checkpoint.sh: status check failed to run cleanly' && pass "checkpoint.sh: invalid status.sh syntax blocks completion" || fail "checkpoint.sh: invalid status.sh syntax blocks completion (rc=$rc entries=$n8i)"

printf '#!/usr/bin/env bash\nexit 3\n' >"$fsroot/.agent/scripts/status.sh"
out8j=$("$fsroot/.agent/scripts/checkpoint.sh" --tool claude --area testing --checks test --summary "quiet exit 3" "$fsroot" 2>&1)
rc=$?
n8j=$(grep -c '^- \[' "$fsroot/.agent/session-log.md")
[ "$rc" -ne 0 ] && [ "$n8j" -eq "$n8i0" ] && printf '%s' "$out8j" | grep -q 'checkpoint.sh: status check failed to run cleanly' && pass "checkpoint.sh: a status.sh that quietly exits nonzero blocks completion" || fail "checkpoint.sh: a status.sh that quietly exits nonzero blocks completion (rc=$rc entries=$n8j)"

printf '#!/usr/bin/env bash\necho "unexpected noise" >&2\nexit 0\n' >"$fsroot/.agent/scripts/status.sh"
out8k=$("$fsroot/.agent/scripts/checkpoint.sh" --tool claude --area testing --checks test --summary "unexpected stderr" "$fsroot" 2>&1)
rc=$?
n8k=$(grep -c '^- \[' "$fsroot/.agent/session-log.md")
[ "$rc" -ne 0 ] && [ "$n8k" -eq "$n8i0" ] && printf '%s' "$out8k" | grep -q 'checkpoint.sh: status check failed to run cleanly' && pass "checkpoint.sh: unexpected status.sh stderr blocks completion" || fail "checkpoint.sh: unexpected status.sh stderr blocks completion (rc=$rc entries=$n8k)"

cp "$WORK/fs-status-clean.sh" "$fsroot/.agent/scripts/status.sh"
"$fsroot/.agent/scripts/checkpoint.sh" --tool claude --area testing --checks test --summary "the inspection script is clean again" "$fsroot" >/dev/null 2>&1
rc=$?
n8l=$(grep -c '^- \[' "$fsroot/.agent/session-log.md")
[ "$rc" -eq 0 ] && [ "$n8l" -eq "$((n8i0 + 1))" ] && pass "checkpoint.sh: a clean status check still allows completion" || fail "checkpoint.sh: a clean status check still allows completion (rc=$rc entries=$n8l)"

seqA="$WORK/seq-edit-commit-edit-commit-noedit"
mkdir -p "$seqA/src"
"$NODE" init --preset software-development --mode track-all "$seqA" >/dev/null 2>&1
finish_bootstrap "$seqA"
printf 'export const a = 1\n' >"$seqA/src/a.ts"
git -C "$seqA" init -q && git -C "$seqA" add -A && git -C "$seqA" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m base

printf 'export const b = 2\n' >>"$seqA/src/a.ts"
"$seqA/.agent/scripts/checkpoint.sh" --tool claude --area testing --checks test --summary "turn one edit" "$seqA" >/dev/null 2>&1
rc_a1=$?
git -C "$seqA" add -A && git -C "$seqA" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m turn-one

printf 'export const c = 3\n' >>"$seqA/src/a.ts"
"$seqA/.agent/scripts/checkpoint.sh" --tool claude --area testing --checks test --summary "turn two edit" "$seqA" >/dev/null 2>&1
rc_a2=$?
git -C "$seqA" add -A && git -C "$seqA" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m turn-two
n_a2=$(grep -c '^- \[' "$seqA/.agent/session-log.md")

out_a3=$("$seqA/.agent/scripts/checkpoint.sh" --tool claude --area testing --verify n/a --summary "turn three no edit" "$seqA" 2>&1)
rc_a3=$?
n_a3=$(grep -c '^- \[' "$seqA/.agent/session-log.md")

[ "$rc_a1" -eq 0 ] && [ "$rc_a2" -eq 0 ] && [ "$n_a2" -eq 2 ] \
  && pass "sequence: edit-commit-edit-commit writes exactly two entries" \
  || fail "sequence: edit-commit-edit-commit writes exactly two entries (rc1=$rc_a1 rc2=$rc_a2 entries=$n_a2)"
[ "$rc_a3" -eq 0 ] && [ "$n_a3" -eq 2 ] && printf '%s' "$out_a3" | grep -q 'nothing to record since the last checkpoint' \
  && pass "sequence: the trailing no-edit turn exits 0 and writes nothing" \
  || fail "sequence: the trailing no-edit turn exits 0 and writes nothing (rc=$rc_a3 entries=$n_a3)"

seqB="$WORK/seq-noedit-then-edit"
mkdir -p "$seqB/src"
"$NODE" init --preset software-development --mode track-all "$seqB" >/dev/null 2>&1
finish_bootstrap "$seqB"
printf 'export const a = 1\n' >"$seqB/src/a.ts"
git -C "$seqB" init -q && git -C "$seqB" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m init
git -C "$seqB" add -A && git -C "$seqB" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m base

out_b1=$("$seqB/.agent/scripts/checkpoint.sh" --tool claude --area testing --verify n/a --summary "answered only, no edits" "$seqB" 2>&1)
rc_b1=$?
n_b1=$(grep -c '^- \[' "$seqB/.agent/session-log.md")
[ "$rc_b1" -ne 0 ] && [ "$n_b1" -eq 0 ] && printf '%s' "$out_b1" | grep -q 'no earlier checkpoint marks where this work began' \
  && pass "sequence: no-edit before any edit exits nonzero and writes nothing" \
  || fail "sequence: no-edit before any edit exits nonzero and writes nothing (rc=$rc_b1 entries=$n_b1)"

printf 'export const b = 2\n' >>"$seqB/src/a.ts"
"$seqB/.agent/scripts/checkpoint.sh" --tool claude --area testing --checks test --summary "second turn edits" "$seqB" >/dev/null 2>&1
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
git -C "$seqC" init -q && git -C "$seqC" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m init
git -C "$seqC" add -A && git -C "$seqC" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m base
"$seqC/.agent/scripts/checkpoint.sh" --tool claude --area testing --verify n/a --summary "only answered, nothing to record" "$seqC" >/dev/null 2>&1
rc_c1=$?
n_c1=$(grep -c '^- \[' "$seqC/.agent/session-log.md")
[ "$rc_c1" -ne 0 ] && [ "$n_c1" -eq 0 ] \
  && pass "sequence: a no-edit-only turn over a committed baseline writes zero entries" \
  || fail "sequence: a no-edit-only turn over a committed baseline writes zero entries (rc=$rc_c1 entries=$n_c1)"

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
  && pass "migrate (same-version): a 6.3 node with the old header is refreshed by the shape-refresh branch" \
  || fail "migrate (same-version): a 6.3 node with the old header is refreshed by the shape-refresh branch"
[ "$before_ms" = "$after_ms" ] \
  && pass "migrate (same-version): every existing log entry is preserved byte-identical, in order" \
  || fail "migrate (same-version): every existing log entry is preserved byte-identical, in order"
[ -f "$migSame/.agent.backup-v6.3-shape/session-log.md" ] && grep -qF 'One entry per session, newest last.' "$migSame/.agent.backup-v6.3-shape/session-log.md" \
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

"$memcopy" new --slug bad-title --title "Bad [Title]" --hook "ok" --fact "bracketed title attempt" "$memroot" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "memory.sh new: bracketed title rejected" || fail "memory.sh new: bracketed title rejected"
[ ! -e "$memroot/.agent/memory/bad-title.md" ] && pass "memory.sh new: bracketed title creates no file" || fail "memory.sh new: bracketed title creates no file"

"$memcopy" new --slug bad-hook --title "Ok" --hook "line one
line two" --fact "multiline hook attempt" "$memroot" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "memory.sh new: multiline hook rejected" || fail "memory.sh new: multiline hook rejected"
[ ! -e "$memroot/.agent/memory/bad-hook.md" ] && pass "memory.sh new: multiline hook creates no file" || fail "memory.sh new: multiline hook creates no file"

"$memcopy" new --slug field-size --title "Field Size" --hook "field regression case" --fact "$(words_n 130)" "$memroot" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "memory.sh new: field-size fact (130 words) accepted" || fail "memory.sh new: field-size fact (130 words) accepted"
flags9b=$(status_flags "$memroot")
[ -z "$flags9b" ] && pass "memory.sh new: field-size fact stays GROOM-clean" || fail "memory.sh new: field-size fact stays GROOM-clean ($flags9b)"

"$memcopy" new --slug outlier --title "Outlier" --hook "outlier alarm case" --fact "$(words_n 320)" "$memroot" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "memory.sh new: outlier fact (320 words) still writes" || fail "memory.sh new: outlier fact (320 words) still writes"
flags9c=$(status_flags "$memroot")
printf '%s\n' "$flags9c" | grep -q '^GROOM: memory/outlier\.md' && pass "memory.sh new: outlier fact draws a GROOM flag" || fail "memory.sh new: outlier fact draws a GROOM flag ($flags9c)"

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

"$memcopy" supersede --slug vendor-rate-limit --fact "narrowed to one project" --scope project --type fact "$memroot" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && grep -qxF -- "scope: project" "$supfile" && grep -qxF -- "type: fact" "$supfile" && pass "memory.sh supersede: --scope and --type override the carried values" || fail "memory.sh supersede: --scope and --type override the carried values"
"$memcopy" supersede --slug vendor-rate-limit --fact "bogus scope attempt" --scope everywhere "$memroot" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && grep -qF 'narrowed to one project' "$supfile" && pass "memory.sh supersede: an unknown --scope is rejected, the fact unchanged" || fail "memory.sh supersede: an unknown --scope is rejected, the fact unchanged"

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

out9t=$("$memcopy" new --slug vendor-rate-limit --title "Dup" --hook "dup" --fact "duplicate attempt" "$memroot" 2>&1)
printf '%s\n' "$out9t" | grep -qF 'memory.sh supersede --slug vendor-rate-limit' && pass "memory.sh new: the overwrite refusal points at supersede" || fail "memory.sh new: the overwrite refusal points at supersede ($out9t)"

# A rewrite may change a fact but not lose what the node knows: a ticket or
# path no other node file holds is refused unless --drop names it as false.
"$memcopy" new --slug deploy-ticket --title "Deploy ticket" --hook "deploy history" --fact "Deploys moved under PAY-318; see docs/deploy.md." "$memroot" >/dev/null 2>&1
out9u=$("$memcopy" supersede --slug deploy-ticket --fact "Deploys moved." "$memroot" 2>&1)
rc=$?
[ "$rc" -eq 1 ] && grep -qF 'PAY-318' "$memroot/.agent/memory/deploy-ticket.md" && printf '%s\n' "$out9u" | grep -qF 'would drop PAY-318, docs/deploy.md' && pass "memory.sh supersede: a rewrite losing a ticket and a path no other node file holds is refused" || fail "memory.sh supersede: a rewrite losing a ticket and a path no other node file holds is refused ($rc: $out9u)"
"$memcopy" supersede --slug deploy-ticket --fact "Deploys moved; docs/deploy.md holds how." --drop PAY-318 "$memroot" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && ! grep -qF 'PAY-318' "$memroot/.agent/memory/deploy-ticket.md" && pass "memory.sh supersede: --drop names a value dropped as no longer true" || fail "memory.sh supersede: --drop names a value dropped as no longer true ($rc)"
"$memcopy" new --slug backoff --title "Backoff" --hook "retry timing" --fact "Per docs/backoff.md's table, retries start at 200ms. HTTP 200 is success." "$memroot" >/dev/null 2>&1
out9v=$("$memcopy" supersede --slug backoff --fact "Per docs/backoff.md, retries back off. HTTP 200 is success." "$memroot" 2>&1)
rc=$?
[ "$rc" -eq 0 ] && printf '%s\n' "$out9v" | grep -qF 'any more: 200ms.' && pass "memory.sh supersede: a possessive path is held bare, and a number counts only with its unit" || fail "memory.sh supersede: a possessive path is held bare, and a number counts only with its unit ($rc: $out9v)"

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

nlroot="$WORK/gitignore-no-newline"
mkdir -p "$nlroot"
printf 'node_modules' >"$nlroot/.gitignore"
"$NODE" init --preset software-development --mode ignore-all "$nlroot" >/dev/null 2>&1
expected_nl=$(printf 'node_modules\n.agent/')
[ "$(cat "$nlroot/.gitignore" 2>/dev/null)" = "$expected_nl" ] && pass "init: no-trailing-newline gitignore keeps its pattern and gains .agent/ on its own line" || fail "init: no-trailing-newline gitignore keeps its pattern and gains .agent/ on its own line"

fakehome="$WORK/fake-home"
mkdir -p "$fakehome"
HOME="$fakehome" "$NODE" init --preset software-development --mode ignore-all "$fakehome" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && [ -d "$fakehome/.agent" ] && pass "init at \$HOME exits 0 and creates the node" || fail "init at \$HOME exits 0 and creates the node"
[ ! -e "$fakehome/.gitignore" ] && pass "init at \$HOME skips the gitignore" || fail "init at \$HOME skips the gitignore"

realhome="$WORK/real-home"
mkdir -p "$realhome"
ln -s "$realhome" "$WORK/link-home"
HOME="$WORK/link-home" "$NODE" init --preset software-development --mode ignore-all "$realhome" >/dev/null 2>&1
[ ! -e "$realhome/.gitignore" ] && pass "init at \$HOME skips the gitignore through a symlinked HOME" || fail "init at \$HOME skips the gitignore through a symlinked HOME"

tsroot="$WORK/update-v6-track-shared"
mkdir -p "$tsroot"
make_v6_fixture "$tsroot" track-shared
"$NODE" update "$tsroot" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "update on a track-shared V6 fixture exits 0" || fail "update on a track-shared V6 fixture exits 0 (rc=$rc)"
[ -d "$tsroot/.agent.backup-v6" ] && grep -q "custom auth flow" "$tsroot/.agent.backup-v6/memory.md" 2>/dev/null && pass "update: track-shared node backed up before the migration" || fail "update: track-shared node backed up before the migration"

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

headroot="$WORK/update-custom-heading"
mkdir -p "$headroot"
make_v6_fixture "$headroot"
cat >"$headroot/.agent/memory.md" <<'EOF'
# Deploy facts

Deploys go through the internal release tool only.
EOF
"$NODE" update "$headroot" >/dev/null 2>&1
grep -q '^# Deploy facts' "$headroot/.agent/memory/legacy.md" 2>/dev/null && pass "update: a custom first-line heading survives into legacy.md" || fail "update: a custom first-line heading survives into legacy.md"

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

before17v=$(cat "$sessionlog")
"$logcopy" --tool claude --area testing --verify fail --summary "baseline was red before this change verify: fail" "$logroot" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && [ "$(cat "$sessionlog")" = "$before17v" ] && pass "log.sh: a summary containing verify: is rejected, nothing written" || fail "log.sh: a summary containing verify: is rejected, nothing written"

"$logcopy" --tool claude --area testing --verify pass --summary "Verify: the tag spelling is refused in any case" "$logroot" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "log.sh: the verify: guard is case-insensitive" || fail "log.sh: the verify: guard is case-insensitive"

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

printf -- '---\ndate: 2026-01-01\nscope: project\n---\n\ncpp notes fact body\n' >"$memroot/.agent/memory/c++notes.md"
printf -- '- [Cpp notes](memory/c++notes.md) — cpp gotchas\n' >>"$memroot/.agent/memory.md"
flags18c=$(status_flags "$memroot" | grep '^REPAIR:')
[ -z "$flags18c" ] && pass "status.sh: regex metacharacters in a fact filename draw no phantom REPAIR" || fail "status.sh: regex metacharacters in a fact filename draw no phantom REPAIR ($flags18c)"

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
printf '%s\n' "$flags19c" | grep -qF 'restructure without dropping facts' && pass "status.sh: docs GROOM flag names the no-fact-loss invariant" || fail "status.sh: docs GROOM flag names the no-fact-loss invariant"

"$subdocs" new --name budget --read-when "docs budget fixture" "$subroot" >/dev/null 2>&1
printf '%s\n' "$(words_n 1900)" >>"$subroot/.agent/docs/budget.md"
flags19d=$(status_flags "$subroot")
printf '%s\n' "$flags19d" | grep -q '^GROOM: docs/budget\.md' && fail "status.sh: header contract costs no body words" || pass "status.sh: header contract costs no body words"
rm -f "$subroot/.agent/docs/budget.md"

rt="$WORK/routing"
mkdir -p "$rt"
"$NODE" init --preset software-development --mode track-all "$rt" >/dev/null 2>&1
finish_bootstrap "$rt"
rtdocs="$rt/.agent/scripts/docs.sh"
rtarch="$rt/.agent/docs/architecture.md"
"$rtdocs" new --name payments --read-when "payment flows and webhooks" "$rt" >/dev/null 2>&1
[ -z "$(status_flags "$rt")" ] && pass "routing: a freshly scaffolded doc is INDEX-clean" || fail "routing: a freshly scaffolded doc is INDEX-clean ($(status_flags "$rt"))"

printf '\n## Webhook retries\n\n## Refund flow\n' >>"$rt/.agent/docs/payments.md"
f21=$(status_flags "$rt")
printf '%s\n' "$f21" | grep -qF 'INDEX: docs/payments.md sections missing from its architecture.md entry' && pass "routing: unlisted sections draw an INDEX flag" || fail "routing: unlisted sections draw an INDEX flag ($f21)"
printf '%s\n' "$f21" | grep -qF 'Webhook retries' && printf '%s\n' "$f21" | grep -qF 'Refund flow' && pass "routing: the flag names every missing section" || fail "routing: the flag names every missing section"

subst "$rtarch" 's/^- \*\*Sections:\*\*$/- **Sections:** Webhook retries (exponential backoff) · Refund flow/'
[ -z "$(status_flags "$rt")" ] && pass "routing: listing the sections clears the flag, enrichment allowed" || fail "routing: listing the sections clears the flag, enrichment allowed ($(status_flags "$rt"))"

subst "$rt/.agent/docs/payments.md" 's/^<!-- Read when: payment flows and webhooks -->$/<!-- Read when: payment flows, webhooks, and refunds -->/'
f21b=$(status_flags "$rt")
printf '%s\n' "$f21b" | grep -qF 'INDEX: docs/payments.md hook disagrees with its architecture.md entry' && pass "routing: hook drift draws an INDEX flag" || fail "routing: hook drift draws an INDEX flag ($f21b)"
subst "$rtarch" 's/^- \*\*Read when:\*\* payment flows and webhooks$/- **Read when:** payment flows, webhooks, and refunds/'
[ -z "$(status_flags "$rt")" ] && pass "routing: refreshing both sides clears the hook flag" || fail "routing: refreshing both sides clears the hook flag ($(status_flags "$rt"))"

printf '\n### `payments.md`\n\n- **Read when:** refund disputes only\n- **Sections:**\n' >>"$rtarch"
f21c=$(status_flags "$rt")
printf '%s\n' "$f21c" | grep -qF 'INDEX: docs/payments.md has 2 entries in architecture.md' && pass "routing: a second entry for one doc draws an INDEX flag even when the first matches" || fail "routing: a second entry for one doc draws an INDEX flag even when the first matches ($f21c)"

missrepair='REPAIR: docs/architecture.md missing/empty'

rtm1="$WORK/routing-table-missing-empty"
mkdir -p "$rtm1"
"$NODE" init --preset software-development --mode track-all "$rtm1" >/dev/null 2>&1
finish_bootstrap "$rtm1"
f21c=$(status_flags "$rtm1" | grep -F "$missrepair")
[ -z "$f21c" ] && pass "routing table: empty docs/ draws no missing-table REPAIR" || fail "routing table: empty docs/ draws no missing-table REPAIR ($f21c)"

rtm2="$WORK/routing-table-missing-references-only"
mkdir -p "$rtm2"
"$NODE" init --preset software-development --mode track-all "$rtm2" >/dev/null 2>&1
finish_bootstrap "$rtm2"
mkdir -p "$rtm2/.agent/docs/references"
printf '# Vendor spec dump\n\nsome content\n' >"$rtm2/.agent/docs/references/vendor.md"
f21d=$(status_flags "$rtm2" | grep -F "$missrepair")
[ -z "$f21d" ] && pass "routing table: references/-only docs/ draws no missing-table REPAIR" || fail "routing table: references/-only docs/ draws no missing-table REPAIR ($f21d)"

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

: >"$rtm4/.agent/docs/architecture.md"
f21g=$(status_flags "$rtm4")
[ "$(printf '%s\n' "$f21g" | grep -cF "$missrepair")" = "1" ] && pass "routing table: an empty-but-present architecture.md still draws exactly one REPAIR" || fail "routing table: an empty-but-present architecture.md still draws exactly one REPAIR ($f21g)"

rtm5="$WORK/routing-table-present"
mkdir -p "$rtm5"
"$NODE" init --preset software-development --mode track-all "$rtm5" >/dev/null 2>&1
finish_bootstrap "$rtm5"
rtm5docs="$rtm5/.agent/scripts/docs.sh"
"$rtm5docs" new --name payments --read-when "payment flows and webhooks" "$rtm5" >/dev/null 2>&1
f21h=$(status_flags "$rtm5")
[ -z "$(printf '%s\n' "$f21h" | grep -F "$missrepair")" ] && pass "routing table: a present architecture.md draws no missing-table REPAIR" || fail "routing table: a present architecture.md draws no missing-table REPAIR ($f21h)"
[ -z "$f21h" ] && pass "routing table: a routed doc with its table stays otherwise INDEX-clean" || fail "routing table: a routed doc with its table stays otherwise INDEX-clean ($f21h)"

fresh19="$WORK/init-academic-research-track-all"
out19all=$("$fresh19/.agent/scripts/status.sh" "$fresh19" 2>&1 | grep -v '^TOOLS:')
out19=$(printf '%s\n' "$out19all" | grep -v '^LOAD:' | grep -v '^PAYLOAD:')
[ -z "$out19" ] && pass "status.sh: bootstrapped node prints no findings (no stray blank line)" || fail "status.sh: bootstrapped node prints no findings (no stray blank line)"
[ "$(printf '%s\n' "$out19all" | grep -c '^LOAD:')" = "1" ] && pass "status.sh: exactly one LOAD line on a quiet node" || fail "status.sh: exactly one LOAD line on a quiet node ($out19all)"

bc="$WORK/bootstrap-checks"
mkdir -p "$bc"
"$NODE" init --preset software-development --mode track-all "$bc" >/dev/null 2>&1
finish_bootstrap "$bc"
[ -z "$(status_flags "$bc")" ] && pass "bootstrap: a completed node is clean" || fail "bootstrap: a completed node is clean ($(status_flags "$bc"))"

printf -- '- Test: `pytest -k <name>`\n' >>"$bc/.agent/rules/contract.md"
f23=$(status_flags "$bc")
printf '%s\n' "$f23" | grep -qF 'template placeholders' && fail "bootstrap: a single-token <name> in a real command is not a placeholder" || pass "bootstrap: a single-token <name> in a real command is not a placeholder"

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

nm="$WORK/native-memory"
mkdir -p "$nm/.claude"
"$NODE" init --preset software-development --mode track-all --hooks none "$nm" >/dev/null 2>&1
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

rm -f "$nm/.claude/settings.json"
mkdir -p "$WORK/nm-home/.claude"
printf '{ "autoMemoryEnabled": false }\n' >"$WORK/nm-home/.claude/settings.json"
f24d=$(HOME="$WORK/nm-home" status_flags "$nm")
[ -z "$f24d" ] && pass "native memory: a user-level setting is inherited, not re-flagged" || fail "native memory: a user-level setting is inherited, not re-flagged ($f24d)"

printf '{ "autoMemoryEnabled": true }\n' >"$nm/.claude/settings.json"
printf '{ "autoMemoryEnabled": false }\n' >"$nm/.claude/settings.local.json"
f24e=$(HOME="$WORK/nm-empty-home" status_flags "$nm")
printf '%s\n' "$f24e" | grep -qF '.claude/settings.json sets autoMemoryEnabled true' && pass "native memory: a disagreement names the offending file" || fail "native memory: a disagreement names the offending file ($f24e)"
printf '%s\n' "$f24e" | grep -qiE 'sole|effective|resolved' && fail "native memory: no line claims a resolved effective state ($f24e)" || pass "native memory: no line claims a resolved effective state"

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

rf="$WORK/references"
mkdir -p "$rf"
"$NODE" init --preset software-development --mode track-all "$rf" >/dev/null 2>&1
finish_bootstrap "$rf"
"$rf/.agent/scripts/docs.sh" new --name backend --read-when "backend services" "$rf" >/dev/null 2>&1
mkdir -p "$rf/.agent/docs/backend/references"
printf '# Full error-code table\n\n%s\n' "$(words_n 4000)" >"$rf/.agent/docs/backend/references/error-codes.md"
f26=$(status_flags "$rf")
[ -z "$f26" ] && pass "references: an unrouted, oversized reference file draws no flag" || fail "references: an unrouted, oversized reference file draws no flag ($f26)"

mkdir -p "$rf/.agent/docs/references"
printf '# Vendor spec dump\n\n%s\n' "$(words_n 4000)" >"$rf/.agent/docs/references/vendor.md"
f26b=$(status_flags "$rf")
[ -z "$f26b" ] && pass "references: docs/references/ is excluded too" || fail "references: docs/references/ is excluded too ($f26b)"

printf 'no routing header\n' >"$rf/.agent/docs/backend/queues.md"
f26c=$(status_flags "$rf")
printf '%s\n' "$f26c" | grep -qF 'INDEX: docs/backend/queues.md' && pass "references: a real sub-doc beside references/ is still checked" || fail "references: a real sub-doc beside references/ is still checked ($f26c)"

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

alcf3="$WORK/always-loaded-canonical-files-empty"
mkdir -p "$alcf3"
"$NODE" init --preset software-development --mode track-all "$alcf3" >/dev/null 2>&1
finish_bootstrap "$alcf3"
: >"$alcf3/.agent/rules/learned.md"
f26f=$(status_flags "$alcf3")
[ "$f26f" = "REPAIR: rules/learned/ missing/empty — restore the records, or rules/learned.md on a node that keeps no record directory; the entry point loads them every session" ] && pass "always-loaded: an empty learned.md draws the same REPAIR finding as a missing one" || fail "always-loaded: an empty learned.md draws the same REPAIR finding as a missing one ($f26f)"
"$alcf3/.agent/scripts/status.sh" "$alcf3" >/dev/null 2>&1
[ "$?" -eq 0 ] && pass "always-loaded: status.sh still exits 0 with learned.md empty" || fail "always-loaded: status.sh still exits 0 with learned.md empty"

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
  [ "$hits" -eq 3 ] && pass "shared: \"${label}…\" in all three presets" || fail "shared: \"${label}…\" in all three presets (found in $hits)"
done <<EOF
$(awk '/^```/ { inb = !inb; next } inb && NF { print }' "$sharedfile")
EOF

[ "$blockcount" -ge 10 ] && pass "presets: _shared.md tracks the shared text ($blockcount blocks)" || fail "presets: _shared.md tracks the shared text (only $blockcount blocks)"

noderoot_sh="$WORK/preset-underscore"
mkdir -p "$noderoot_sh"
"$NODE" init --preset _shared --mode ignore-all "$noderoot_sh" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$noderoot_sh/.agent" ] && pass "node.sh: --preset _shared is rejected, nothing created" || fail "node.sh: --preset _shared is rejected, nothing created"

memstale=0
for p in "$reporoot"/presets/*.md; do
  grep -qF "update memory.md only if" "$p" && memstale=1
done
[ "$memstale" -eq 0 ] && pass "presets: no preset still writes facts to memory.md" || fail "presets: no preset still writes facts to memory.md"

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
  sl_extract "$reporoot/presets/$p.md" | grep -qF "does not require a record" || sl_bad="$sl_bad $p"
done
[ -z "$sl_bad" ] && pass "self-learning: a correction alone neither requires nor justifies a record" || fail "self-learning: a correction alone neither requires nor justifies a record ($sl_bad)"

sl_bad=""
for p in software-development academic-research domain-knowledge; do
  sl27=$(cat "$reporoot/presets/$p.md")
  ok27=1
  printf '%s\n' "$sl27" | grep -qF "no durable record" || ok27=0
  printf '%s\n' "$sl27" | grep -qF "memory.sh new" || ok27=0
  printf '%s\n' "$sl27" | grep -qF "supersede" || ok27=0
  printf '%s\n' "$sl27" | grep -qF "learn.sh new" || ok27=0
  [ "$ok27" -eq 1 ] || sl_bad="$sl_bad $p"
done
[ -z "$sl_bad" ] && pass "self-learning: each of the four kinds names its surface and its writer" || fail "self-learning: each of the four kinds names its surface and its writer ($sl_bad)"

sl_bad=""
for p in software-development academic-research domain-knowledge; do
  sl_extract "$reporoot/presets/$p.md" | grep -qF "They create no durable record" || sl_bad="$sl_bad $p"
done
[ -z "$sl_bad" ] && pass "self-learning: a task-scoped constraint stays at its stated scope" || fail "self-learning: a task-scoped constraint stays at its stated scope ($sl_bad)"

sl_bad=""
for p in software-development academic-research domain-knowledge; do
  sl_extract "$reporoot/presets/$p.md" | grep -qF "before adding a lesson" || sl_bad="$sl_bad $p"
done
[ -z "$sl_bad" ] && pass "self-learning: a record is looked up before it is written" || fail "self-learning: a record is looked up before it is written ($sl_bad)"

sl_bad=""
for p in software-development academic-research domain-knowledge; do
  sl_extract "$reporoot/presets/$p.md" | grep -qF "merge near-duplicates in \`rules/learned.md\`" || sl_bad="$sl_bad $p"
done
[ -z "$sl_bad" ] && pass "self-learning: a manual-mode node merges near-duplicates by hand" || fail "self-learning: a manual-mode node merges near-duplicates by hand ($sl_bad)"

sl_bad=""
for p in software-development academic-research domain-knowledge; do
  sl_extract "$reporoot/presets/$p.md" | grep -qF "Passing a text or comment check does not establish either" || sl_bad="$sl_bad $p"
done
[ -z "$sl_bad" ] && pass "self-learning: no prose scan or comment gate admits a record" || fail "self-learning: no prose scan or comment gate admits a record ($sl_bad)"

sl_handgrep=$(grep -rnF 'grep' \
  "$reporoot/presets/software-development.md" "$reporoot/presets/academic-research.md" \
  "$reporoot/presets/domain-knowledge.md" "$reporoot/tools/skills/retro/SKILL.md" 2>/dev/null)
[ -z "$sl_handgrep" ] && pass "self-learning: no preset or skill text instructs a hand grep over learned.md" || fail "self-learning: no preset or skill text instructs a hand grep over learned.md ($sl_handgrep)"

retro_skill="$reporoot/tools/skills/retro/SKILL.md"
retro_merge=$(awk '/^## Merge, don.t append/ { inq = 1 } inq && /^## / && !/^## Merge, don.t append/ { inq = 0 } inq' "$retro_skill")
printf '%s\n' "$retro_merge" | grep -qF "learn.sh" && pass "retro skill: the merge walkthrough calls learn.sh" || fail "retro skill: the merge walkthrough calls learn.sh"

rd_draft=$(grep -n '^## Draft from the evidence before reading the records$' "$retro_skill" | cut -d: -f1)
rd_source=$(grep -n '^## Find the failing source before distilling$' "$retro_skill" | cut -d: -f1)
[ -n "$rd_draft" ] && [ -n "$rd_source" ] && [ "$rd_draft" -lt "$rd_source" ] \
  && awk '/^## Draft from the evidence/ { inq = 1; next } inq && /^## / { exit } inq' "$retro_skill" | grep -qF 'before you open `rules/learned.md`' \
  && pass "retro skill: the evidence draft comes before reading learned records" || fail "retro skill: the evidence draft comes before reading learned records"

retro_route=$(awk '/^## Route by scope/ { inq = 1 } inq && /^## / && !/^## Route by scope/ { inq = 0 } inq' "$retro_skill")
rt_ok=1
for rt_kind in "no durable record" ".agent/scripts/memory.sh new" ".agent/scripts/memory.sh supersede" ".agent/scripts/learn.sh"; do
  printf '%s\n' "$retro_route" | grep -qF "$rt_kind" || rt_ok=0
done
[ "$rt_ok" -eq 1 ] && pass "retro skill: the routing section names the four kinds and their writers" || fail "retro skill: the routing section names the four kinds and their writers"

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

printf '\nSee `docs/backend/queues.md` for the queue design.\n' >>"$lk/.agent/docs/backend.md"
out28c=$("$LINKS" "$lk" 2>&1)
printf '%s\n' "$out28c" | grep -qF 'BROKEN: .agent/docs/backend.md cites docs/backend/queues.md' && pass "links.sh: a dangling node path is reported" || fail "links.sh: a dangling node path is reported ($out28c)"

printf '\nBrief: `temp/some-task-board.md`, source `src/app/main.md`.\n' >>"$lk/.agent/docs/backend.md"
out28d=$("$LINKS" "$lk" 2>&1)
printf '%s\n' "$out28d" | grep -qF 'temp/some-task-board.md' && fail "links.sh: paths outside the node are out of scope" || pass "links.sh: paths outside the node are out of scope"

printf '\nSee `learned.md` for the accumulated corrections.\n' >>"$lk/.agent/docs/backend.md"
out28e=$("$LINKS" "$lk" 2>&1)
printf '%s\n' "$out28e" | grep -qF 'cites learned.md' && fail "links.sh: a loose basename resolves against the node" || pass "links.sh: a loose basename resolves against the node"

mkdir -p "$lk/skills/testing"
printf '# Testing\n' >"$lk/skills/testing/SKILL.md"
printf '\nThe bar lives in `SKILL.md`, and `skills/testing/SKILL.md` implements it.\n' >>"$lk/.agent/docs/backend.md"
out28i=$("$LINKS" "$lk" 2>&1)
printf '%s\n' "$out28i" | grep -qF 'cites SKILL.md' && fail "links.sh: a bare name held by the project is not broken" || pass "links.sh: a bare name held by the project is not broken"
printf '%s\n' "$out28i" | grep -qF 'skills/testing/SKILL.md' && fail "links.sh: an out-of-model .agent directory is not audited as a target" || pass "links.sh: an out-of-model .agent directory is not audited as a target"

printf '\nAlso `nowhere-at-all.md`.\n' >>"$lk/.agent/docs/backend.md"
out28j=$("$LINKS" "$lk" 2>&1)
printf '%s\n' "$out28j" | grep -qF 'cites nowhere-at-all.md' && pass "links.sh: a name neither node nor project holds is still broken" || fail "links.sh: a name neither node nor project holds is still broken ($out28j)"

printf -- '- [2026-01-01] (claude) worked from `docs/gone-forever.md` (backend). verify: pass.\n' >>"$lk/.agent/session-log.md"
out28f=$("$LINKS" "$lk" 2>&1)
printf '%s\n' "$out28f" | grep -qF 'gone-forever' && fail "links.sh: the session log is not audited as a citation source" || pass "links.sh: the session log is not audited as a citation source"

out28g=$("$LINKS" "$lk" 2>&1)
printf '%s\n' "$out28g" | grep -qE 'ORPHAN: (purpose|memory|session-log)\.md' && fail "links.sh: canonical files are exempt from the orphan check" || pass "links.sh: canonical files are exempt from the orphan check"

"$LINKS" "$WORK/no-such-root" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "links.sh: a missing node is an error, not a clean report" || fail "links.sh: a missing node is an error, not a clean report"

lkempty="$WORK/links-empty"
mkdir -p "$lkempty/.agent/docs"
printf 'entry point citing .agent/scripts/status.sh\n' >"$lkempty/CLAUDE.md"
out28h=$("$LINKS" "$lkempty" 2>&1)
rc=$?
[ "$rc" -eq 0 ] && printf '%s\n' "$out28h" | grep -qF 'no markdown files to audit' && pass "links.sh: an empty node reports cleanly instead of erroring" || fail "links.sh: an empty node reports cleanly instead of erroring (rc=$rc, $out28h)"

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
at .claude/skills/$skill_dir
EOF
lint_re='claude|cursor|copilot|codex|anthropic|openai|sonnet|opus|haiku|gpt-|agents\.md'
hits30=$(cd "$reporoot" && grep -inE "$lint_re" \
  presets/software-development.md presets/academic-research.md \
  presets/domain-knowledge.md presets/_shared.md templates/entry-point.md \
  templates/entry-point-generated.md \
  scripts/status.sh scripts/log.sh scripts/memory.sh scripts/docs.sh \
  scripts/links.sh scripts/comments.sh scripts/checkpoint.sh scripts/index.sh \
  scripts/learn.sh scripts/session-start.sh scripts/docs/worker-contract.md \
  scripts/comments.conf scripts/status.conf scripts/log.conf scripts/node.sh 2>/dev/null | grep -vF -f "$lint_allow")
[ -z "$hits30" ] && pass "portability: node-landing corpus is vendor-neutral" || fail "portability: node-landing corpus is vendor-neutral ($(printf '%s' "$hits30" | tr '\n' ';' | cut -c1-160))"

# A corpus that names its own eval ids, assertion ids, or fixtures has been
# fitted to the bench. Hyphenated names only: single words such as "routed"
# are ordinary prose. contamination.py --judge still owns retold scenarios.
evtok30=$(python3 - "$reporoot/evals/spec.json" "$reporoot/evals/heldout.json" <<'PY'
import json, sys
names = set()
for path in sys.argv[1:]:
    for e in json.load(open(path))["evals"]:
        names.add(e["id"])
        if e.get("fixture"):
            names.add(e["fixture"])
        for a in e.get("assertions", []):
            names.update([a["id"], a["id"].split("/")[-1]])
print("\n".join(sorted(n for n in names if "-" in n)))
PY
)
evhits30=""
if [ -n "$evtok30" ]; then
  evhits30=$(cd "$reporoot" && printf '%s\n' "$evtok30" | grep -rnwF -f - \
    presets/software-development.md presets/academic-research.md \
    presets/domain-knowledge.md presets/_shared.md templates/entry-point.md \
    templates/entry-point-generated.md scripts/status.sh scripts/log.sh scripts/memory.sh \
    scripts/docs.sh scripts/links.sh scripts/comments.sh scripts/checkpoint.sh scripts/index.sh \
    scripts/learn.sh scripts/absorb.sh scripts/comments.conf scripts/status.conf scripts/log.conf \
    tools/skills/groom/SKILL.md tools/skills/retro/SKILL.md 2>/dev/null)
fi
[ -n "$evtok30" ] && [ -z "$evhits30" ] && pass "portability: node-landing corpus names no eval, assertion, or fixture" \
  || fail "portability: node-landing corpus names no eval, assertion, or fixture ($(printf '%s' "$evhits30" | tr '\n' ';' | cut -c1-160))"

printf 'When stuck, ask SomeVendor to run it in Cursor.\n' >"$WORK/leak.md"
hits30b=$(grep -inE "$lint_re" "$WORK/leak.md" | grep -vF -f "$lint_allow")
[ -n "$hits30b" ] && pass "portability: the lint catches an injected vendor token" || fail "portability: the lint catches an injected vendor token"

iv_hits=$(cd "$reporoot" && grep -nE '\{[0-9]+(,[0-9]*)?\}' \
  scripts/status.sh scripts/log.sh scripts/memory.sh scripts/docs.sh \
  scripts/links.sh scripts/comments.sh scripts/checkpoint.sh scripts/index.sh \
  scripts/learn.sh scripts/node.sh scripts/comments.conf | grep -v 'grep' | grep -vF '/^a{2}$/')
[ -z "$iv_hits" ] && pass "portability: no {n,m} interval reaches awk, which mawk 1.3.4 20200120 silently never matches" || fail "portability: no {n,m} interval reaches awk, which mawk 1.3.4 20200120 silently never matches ($(printf '%s' "$iv_hits" | tr '\n' ';' | cut -c1-200))"

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

reported_a=$(printf '%s\n' "$payloadline_a" | sed -E 's/^PAYLOAD: [^0-9]*([0-9]+) bytes.*/\1/')
actual_a=$(wc -c <"$WORK/pb-load.out" | tr -d '[:space:]')
[ -n "$reported_a" ] && [ "$reported_a" = "$actual_a" ] \
  && pass "status.sh: PAYLOAD total equals the exact bytes --load writes" \
  || fail "status.sh: PAYLOAD total equals the exact bytes --load writes (reported $reported_a, actual $actual_a)"

budget_default=$(sed -n 's/^PAYLOAD_MAX_BYTES=//p' "$reporoot/scripts/status.sh" | head -n 1)
pad_needed=$((budget_default - reported_a))
[ "$pad_needed" -gt 0 ] || fail "status.sh: fixture's natural payload already exceeds PAYLOAD_MAX_BYTES — cannot build the boundary case"
# PAYLOAD: counts its own line, whose digits grow with the padding, and a
# HOOK: line past the hook limit, which this case is not about.
printf 'HOOK_MAX_BYTES=1000000\n' >>"$pb/.agent/scripts/status.conf"
for _ in 1 2 3 4; do
  if [ "$pad_needed" -gt 0 ]; then
    printf '%*s' "$pad_needed" '' | tr ' ' 'x' >>"$pb/.agent/memory.md"
  elif [ "$pad_needed" -lt 0 ]; then
    pad_size=$(wc -c <"$pb/.agent/memory.md" | tr -d '[:space:]')
    head -c "$((pad_size + pad_needed))" "$pb/.agent/memory.md" >"$pb/.agent/memory.md.pad" && mv "$pb/.agent/memory.md.pad" "$pb/.agent/memory.md"
  fi
  "$pb/.agent/scripts/status.sh" --load "$pb" >"$WORK/pb-exact.out" 2>&1
  payloadline_exact=$(grep '^PAYLOAD:' "$WORK/pb-exact.out")
  reported_exact=$(printf '%s\n' "$payloadline_exact" | sed -E 's/^PAYLOAD: [^0-9]*([0-9]+) bytes.*/\1/')
  pad_needed=$((budget_default - reported_exact))
  [ "$pad_needed" -eq 0 ] && break
done
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
mkdir -p "$cg/.toolrc/hooks"
printf '# tuned per commit deadbeefcafe1234\necho hi\n' >"$cg/.toolrc/hooks/check.sh"
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
printf '%s\n' "$out34" | grep -q 'src/app.ts' && pass "comments.sh: an ordinary path is not read as hidden" || fail "comments.sh: an ordinary path is not read as hidden ($out34)"

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
printf '%s\n' "$review34k" | grep -q 'billing schema' && pass "comments.sh: prose ending in a semicolon is not commented-out code" || fail "comments.sh: prose ending in a semicolon is not commented-out code ($out34k)"
printf '%s\n' "$block34k" | grep -qF '[routine narration]' && printf '%s\n' "$block34k" | grep -q 'Build the rows' && pass "comments.sh: short structure narration BLOCKs, named" || fail "comments.sh: short structure narration BLOCKs, named ($block34k)"
printf '%s\n' "$review34k" | grep -q 'because the vendor SDK' && pass "comments.sh: naming a constraint exempts a routine verb" || fail "comments.sh: naming a constraint exempts a routine verb ($out34k)"
long34=$(printf '%s\n' "$review34k" | grep -A1 'routine narration' | grep 'Update the cache after every write')
[ -n "$long34" ] && pass "comments.sh: routine narration past the word cap is labeled, not blocked" || fail "comments.sh: routine narration past the word cap is labeled, not blocked ($out34k)"
printf '%s\n' "$out34k" | grep -A1 'routine narration' | grep -q 'stops the run' && fail "comments.sh: a wrapped-comment continuation is not structure narration" || pass "comments.sh: a wrapped-comment continuation is not structure narration"

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
printf '%s\n' "$block34l" | grep -q 'Gets the user name' && pass "comments.sh: a doc comment narrating its signature BLOCKs" || fail "comments.sh: a doc comment narrating its signature BLOCKs ($out34l)"
rest34=$(printf '%s\n' "$review34l" | grep -A1 'restates the code below' | grep 'retry counter')
[ -n "$rest34" ] && pass "comments.sh: a comment repeating the identifier below it is labeled" || fail "comments.sh: a comment repeating the identifier below it is labeled ($review34l)"

printf 'RESTATE_CHECK=false\n' >"$cg/.agent/scripts/comments.conf"
out34m=$(cd "$cg" && .agent/scripts/comments.sh base 2>&1)
printf '%s\n' "$out34m" | grep -qF '[restates the code below]' && fail "comments.sh: RESTATE_CHECK=false drops the label" || pass "comments.sh: RESTATE_CHECK=false drops the label"
printf '%s\n' "$out34m" | awk '/^BLOCK:/ { exit } { print }' | grep -q 'retry counter' && pass "comments.sh: RESTATE_CHECK=false keeps the comment in REVIEW" || fail "comments.sh: RESTATE_CHECK=false keeps the comment in REVIEW ($out34m)"

printf 'CONSTRAINT_RE_EXTRA=payments gateway\n' >"$cg/.agent/scripts/comments.conf"
printf 'const m0 = 0\n// Build the rows the payments gateway expects\nconst m = 12\n' >>"$cg/src/app.ts"
out34q=$(cd "$cg" && .agent/scripts/comments.sh base 2>&1)
printf '%s\n' "$out34q" | awk '/^BLOCK:/ { exit } { print }' | grep -q 'payments gateway' && pass "comments.sh: CONSTRAINT_RE_EXTRA rescues a real comment from the routine class" || fail "comments.sh: CONSTRAINT_RE_EXTRA rescues a real comment from the routine class ($out34q)"

printf 'ROUTINE_MAX_WORDS=0\n' >"$cg/.agent/scripts/comments.conf"
out34r=$(cd "$cg" && .agent/scripts/comments.sh base 2>&1)
printf '%s\n' "$out34r" | sed -n '/^BLOCK:/,$p' | grep -q 'Build the rows' && fail "comments.sh: ROUTINE_MAX_WORDS=0 leaves the class a label only" || pass "comments.sh: ROUTINE_MAX_WORDS=0 leaves the class a label only"
printf '%s\n' "$out34r" | grep -qF '[routine narration]' && pass "comments.sh: ROUTINE_MAX_WORDS=0 keeps the label" || fail "comments.sh: ROUTINE_MAX_WORDS=0 keeps the label ($out34r)"

printf 'ROUTINE_MAX_WORDS=eight\n' >"$cg/.agent/scripts/comments.conf"
(cd "$cg" && .agent/scripts/comments.sh base >/dev/null 2>&1)
rc34s=$?
[ "$rc34s" -eq 2 ] && pass "comments.sh: a non-numeric ROUTINE_MAX_WORDS fails closed" || fail "comments.sh: a non-numeric ROUTINE_MAX_WORDS fails closed (rc=$rc34s)"
git_cg checkout -q -- src/app.ts

printf 'NARRATION_RE_EXTRA=(^|[^[:alnum:]])old world\n' >"$cg/.agent/scripts/comments.conf"
printf '// the old world path is gone\nconst j = 9\n' >>"$cg/src/app.ts"
out34n=$(cd "$cg" && .agent/scripts/comments.sh base 2>&1)
printf '%s\n' "$out34n" | sed -n '/^BLOCK:/,$p' | grep -q 'old world' && pass "comments.sh: NARRATION_RE_EXTRA joins the narration class" || fail "comments.sh: NARRATION_RE_EXTRA joins the narration class ($out34n)"
rm -f "$cg/.agent/scripts/comments.conf" "$cg/src/Thing.cs"
git_cg checkout -q -- src/app.ts

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

printf '%s\n' "$block34t" | grep -B1 -F 'As you suggested, cache the response' | grep -qF '[chat residue]' && pass "comments.sh: a feedback-request echo (\"as you suggested\") BLOCKs as chat residue" || fail "comments.sh: a feedback-request echo (\"as you suggested\") BLOCKs as chat residue ($block34t)"
printf '%s\n' "$block34t" | grep -B1 -F 'Retain the cached result per your feedback' | grep -qF '[chat residue]' && pass "comments.sh: a feedback reference (\"per your feedback\") BLOCKs as chat residue" || fail "comments.sh: a feedback reference (\"per your feedback\") BLOCKs as chat residue ($block34t)"
printf '%s\n' "$block34t" | grep -B1 -F 'remains available, as agreed' | grep -qF '[chat residue]' && pass "comments.sh: an agreement reference (\"as agreed\") BLOCKs as chat residue" || fail "comments.sh: an agreement reference (\"as agreed\") BLOCKs as chat residue ($block34t)"
printf '%s\n' "$block34t" | grep -B1 -F 'Sorry, this cache uses the wrong table' | grep -qF '[chat residue]' && pass "comments.sh: an opening apology (\"sorry\") BLOCKs as chat residue" || fail "comments.sh: an opening apology (\"sorry\") BLOCKs as chat residue ($block34t)"
printf '%s\n' "$block34t" | grep -B1 -F 'Here is the fixed version' | grep -qF '[chat residue]' && pass "comments.sh: a draft-revision label (\"here is the fixed version\") BLOCKs as chat residue" || fail "comments.sh: a draft-revision label (\"here is the fixed version\") BLOCKs as chat residue ($block34t)"
printf '%s\n' "$block34t" | grep -B1 -F 'Draft v2 of the retry loop' | grep -qF '[chat residue]' && pass "comments.sh: a draft-revision label (\"draft v2\") BLOCKs as chat residue" || fail "comments.sh: a draft-revision label (\"draft v2\") BLOCKs as chat residue ($block34t)"

printf '%s\n' "$block34t" | grep -B1 -F "Here's the fixed version" | grep -qF '[chat residue]' && pass "comments.sh: a draft-revision label (\"here's the fixed version\") BLOCKs as chat residue" || fail "comments.sh: a draft-revision label (\"here's the fixed version\") BLOCKs as chat residue ($block34t)"
printf '%s\n' "$block34t" | grep -B1 -F 'Fixed version: the retry loop now caps at three attempts' | grep -qF '[chat residue]' && pass "comments.sh: a draft-revision label (\"fixed version:\") BLOCKs as chat residue" || fail "comments.sh: a draft-revision label (\"fixed version:\") BLOCKs as chat residue ($block34t)"
printf '%s\n' "$block34t" | grep -B1 -F 'the revised version of the retry loop' | grep -qF '[chat residue]' && pass "comments.sh: a draft-revision label (\"revised version\") BLOCKs as chat residue" || fail "comments.sh: a draft-revision label (\"revised version\") BLOCKs as chat residue ($block34t)"
printf '%s\n' "$block34t" | grep -B1 -F 'a draft revision of the retry loop' | grep -qF '[chat residue]' && pass "comments.sh: a draft-revision label (\"draft revision\") BLOCKs as chat residue" || fail "comments.sh: a draft-revision label (\"draft revision\") BLOCKs as chat residue ($block34t)"
printf '%s\n' "$block34t" | grep -B1 -F 'Updated the cache handling to address your comments' | grep -qF '[chat residue]' && pass "comments.sh: a feedback reference (\"to address your comments\") BLOCKs as chat residue" || fail "comments.sh: a feedback reference (\"to address your comments\") BLOCKs as chat residue ($block34t)"
printf '%s\n' "$block34t" | grep -B1 -F 'My apologies, the config value here is stale' | grep -qF '[chat residue]' && pass "comments.sh: an opening apology (\"my apologies\") BLOCKs as chat residue" || fail "comments.sh: an opening apology (\"my apologies\") BLOCKs as chat residue ($block34t)"

printf '%s\n' "$block34t" | grep -q 'fixed version is 2.3.1' && fail "comments.sh: a real version report is not a draft-revision label" || pass "comments.sh: a real version report is not a draft-revision label"
printf '%s\n' "$block34t" | grep -q 'debounces feedback' && fail "comments.sh: audio feedback is not a feedback reference" || pass "comments.sh: audio feedback is not a feedback reference"
printf '%s\n' "$block34t" | grep -q 'profiler disagreed' && fail "comments.sh: \"suggested\" outside \"as you suggested\" is not chat residue" || pass "comments.sh: \"suggested\" outside \"as you suggested\" is not chat residue"
printf '%s\n' "$block34t" | grep -q 'rarely agree' && fail "comments.sh: \"agree\" outside \"as agreed\" is not chat residue" || pass "comments.sh: \"agree\" outside \"as agreed\" is not chat residue"
printf '%s\n' "$block34t" | grep -q 'sorry-not-found' && fail "comments.sh: a mid-sentence \"sorry\" is not an opening apology" || pass "comments.sh: a mid-sentence \"sorry\" is not an opening apology"
printf '%s\n' "$block34t" | grep -q 'not a draft; it defines' && fail "comments.sh: \"draft\" outside a revision label is not chat residue" || pass "comments.sh: \"draft\" outside a revision label is not chat residue"

printf '%s\n' "$block34t" | grep -qF 'per the agreement with the vendor' && fail "comments.sh: a vendor-contract reference is not an agreement echo" || pass "comments.sh: a vendor-contract reference is not an agreement echo"
printf '%s\n' "$block34t" | grep -qF "based on the feedback loop's sampling window" && fail "comments.sh: a feedback-loop description is not a feedback reference" || pass "comments.sh: a feedback-loop description is not a feedback reference"
printf '%s\n' "$block34t" | grep -qF 'Per RFC draft v08' && fail "comments.sh: an RFC draft citation is not a draft-revision label" || pass "comments.sh: an RFC draft citation is not a draft-revision label"
printf '%s\n' "$block34t" | grep -qF 'The v2 draft of the protocol' && fail "comments.sh: a protocol-version description is not a draft-revision label" || pass "comments.sh: a protocol-version description is not a draft-revision label"
printf '%s\n' "$block34t" | grep -qF 'As agreed by both parties' && fail "comments.sh: a third-party agreement is not an agreement echo" || pass "comments.sh: a third-party agreement is not an agreement echo"

printf '%s\n' "$block34t" | grep -B1 -F 'Draft v08 of this fix is ready for review' | grep -qF '[chat residue]' && pass "comments.sh: a draft label opening the comment (\"draft v08\") BLOCKs as chat residue" || fail "comments.sh: a draft label opening the comment (\"draft v08\") BLOCKs as chat residue ($block34t)"
printf '%s\n' "$block34t" | grep -B1 -F "I'll ship the fix by Friday" | grep -qF '[chat residue]' && pass "comments.sh: an agreement ending its clause (\"as agreed,\") BLOCKs as chat residue" || fail "comments.sh: an agreement ending its clause (\"as agreed,\") BLOCKs as chat residue ($block34t)"
printf '%s\n' "$block34t" | grep -B1 -F "revised draft based on your comments" | grep -qF '[chat residue]' && pass "comments.sh: a revised-draft label BLOCKs as chat residue" || fail "comments.sh: a revised-draft label BLOCKs as chat residue ($block34t)"

printf '%s\n' "$block34t" | grep -qF 'Draft v2 of RFC 9110 changed how the retry-after header must be parsed' && fail "comments.sh: a draft-v2 spec citation on a comment's second line is not a revision label" || pass "comments.sh: a draft-v2 spec citation on a comment's second line is not a revision label"

printf '%s\n' "$review34t" | grep -qF 'fixed version is 2.3.1' && pass "comments.sh: the real version report lands in REVIEW, not silently endorsed" || fail "comments.sh: the real version report lands in REVIEW ($review34t)"

printf '%s\n' "$review34t" | grep -qF 'Does NOT retry on 4xx responses because the vendor client treats retries as duplicate charges.' && pass "comments.sh: a negative constraint survives a negation, verbatim" || fail "comments.sh: a negative constraint survives a negation ($review34t)"

printf '%s\n' "$review34t" | grep -qF 'The callback can arrive after cancellation because the vendor retains the handle.' && pass "comments.sh: a non-obvious callback constraint survives with its meaning intact" || fail "comments.sh: a non-obvious callback constraint survives with its meaning intact ($review34t)"

cat >>"$cg/src/app.ts" <<'EOF'
// Keep the label readable in diagnostic output.
const diagnosticLabel = "left — right"
EOF
out34utf8=$(cd "$cg" && LC_ALL=C.UTF-8 .agent/scripts/comments.sh chat34 2>&1)
rc34utf8=$?
[ "$rc34utf8" -eq 0 ] && printf '%s\n' "$out34utf8" | grep -qF 'Keep the label readable in diagnostic output.' \
  && pass "comments.sh: UTF-8 code below a review comment does not break classification" \
  || fail "comments.sh: UTF-8 code below a review comment does not break classification (rc=$rc34utf8; $out34utf8)"
git_cg checkout -q -- src/app.ts

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

printf '# As you suggested, cache the response for five minutes.\n' >"$cg/notes.md"
mkdir -p "$cg/.agent/docs"
printf '// As you suggested, cache the response for five minutes.\n' >"$cg/.agent/docs/note.ts"
out34w=$(cd "$cg" && .agent/scripts/comments.sh chat34 2>&1)
rc34w=$?
[ "$rc34w" -eq 0 ] && [ -z "$out34w" ] && pass "comments.sh: chat residue in Markdown and under .agent/ stays out of the gate" || fail "comments.sh: chat residue in Markdown and under .agent/ stays out of the gate (rc=$rc34w; $out34w)"
rm -rf "$cg/notes.md" "$cg/.agent/docs"

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

[ -z "$(git -C "$cg" status --porcelain)" ] && pass "comments.sh: the empty-diff fixture starts clean" || fail "comments.sh: the empty-diff fixture starts clean ($(git -C "$cg" status --porcelain | tr '\n' ' '))"
(cd "$cg" && .agent/scripts/comments.sh HEAD >/dev/null 2>&1)
rc34o=$?
[ "$rc34o" -eq 2 ] && pass "comments.sh: a base resolving to HEAD over a clean tree exits 2" || fail "comments.sh: a base resolving to HEAD over a clean tree exits 2 (rc=$rc34o)"
printf '// tuned per commit cafebabecafebabe\nconst k = 10\n' >>"$cg/src/app.ts"
(cd "$cg" && .agent/scripts/comments.sh HEAD >/dev/null 2>&1)
rc34p=$?
[ "$rc34p" -eq 1 ] && pass "comments.sh: HEAD with an uncommitted change is a real diff, not the empty case" || fail "comments.sh: HEAD with an uncommitted change is a real diff, not the empty case (rc=$rc34p)"
git_cg checkout -q -- src/app.ts

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

missing_u=""
for f in status.sh log.sh memory.sh docs.sh links.sh comments.sh checkpoint.sh index.sh learn.sh runtime.sh verify.sh review.sh capture.sh absorb.sh checks.sh; do
  [ -x "$cgu2/.agent/scripts/$f" ] || missing_u="$missing_u $f"
done
for f in comments.conf status.conf log.conf; do
  [ -f "$cgu2/.agent/scripts/$f" ] || missing_u="$missing_u $f"
done
[ -z "$missing_u" ] && pass "update: every shipped script and starter conf reaches an existing node" || fail "update: every shipped script and starter conf reaches an existing node (missing:$missing_u)"

out34diffx=$(cd "$cg" && GIT_EXTERNAL_DIFF=false .agent/scripts/comments.sh base 2>&1)
rc34diffx=$?
[ "$rc34diffx" -eq 2 ] && pass "comments.sh: GIT_EXTERNAL_DIFF pointed at a broken program fails the diff capture closed" || fail "comments.sh: GIT_EXTERNAL_DIFF pointed at a broken program fails the diff capture closed (rc=$rc34diffx; $out34diffx)"

stub34="$WORK/cg-stub"
mkdir -p "$stub34"
real_git34=$(command -v git)
real_awk34=$(command -v awk)

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

cgf34="$WORK/comment-gate-failclosed"
mkdir -p "$cgf34/src"
"$NODE" init --preset software-development --mode track-all "$cgf34" >/dev/null 2>&1
finish_bootstrap "$cgf34"
printf 'export const a = 1\n' >"$cgf34/src/a.ts"
git -C "$cgf34" init -q && git -C "$cgf34" add -A && git -C "$cgf34" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m base
printf 'export const b = 2\n' >>"$cgf34/src/a.ts"
n34before=$(grep -c '^- \[' "$cgf34/.agent/session-log.md")
out34fc=$(GIT_EXTERNAL_DIFF=false "$cgf34/.agent/scripts/checkpoint.sh" --tool claude --area testing --checks test --summary "should not log" "$cgf34" 2>&1)
rc34fc=$?
n34after=$(grep -c '^- \[' "$cgf34/.agent/session-log.md")
[ "$rc34fc" -ne 0 ] && [ "$n34before" -eq "$n34after" ] && pass "checkpoint.sh: a failed-closed comment gate appends no log entry" || fail "checkpoint.sh: a failed-closed comment gate appends no log entry (rc=$rc34fc before=$n34before after=$n34after; $out34fc)"

tmpdir34="$WORK/cg-tmpdir"
mkdir -p "$tmpdir34"
(cd "$cg" && TMPDIR="$tmpdir34" .agent/scripts/comments.sh base >/dev/null 2>&1)
(cd "$cg" && TMPDIR="$tmpdir34" GIT_EXTERNAL_DIFF=false .agent/scripts/comments.sh base >/dev/null 2>&1)
(cd "$cg" && TMPDIR="$tmpdir34" .agent/scripts/comments.sh nosuchref >/dev/null 2>&1)
leftover34=$(find "$tmpdir34" -type f)
[ -z "$leftover34" ] && pass "comments.sh: no temporary file survives success or failure" || fail "comments.sh: no temporary file survives success or failure ($leftover34)"

printf 'LOG_ENTRY_MAX_WORDS=500\n' >"$es/.agent/scripts/status.conf"
f35=$(status_flags "$es")
printf '%s\n' "$f35" | grep -q 'entries over' && fail "status.conf: a threshold override silences the flag" || pass "status.conf: a threshold override silences the flag"

printf 'PROBE_TOOLS=zz-absent-tool-9\n' >>"$es/.agent/scripts/status.conf"
out35=$("$es/.agent/scripts/status.sh" "$es" 2>&1)
printf '%s\n' "$out35" | grep -q 'TOOLS: not installed: zz-absent-tool-9' && pass "status.conf: PROBE_TOOLS override is probed" || fail "status.conf: PROBE_TOOLS override is probed"

subst "$es/.agent/scripts/status.conf" 's/^PROBE_TOOLS=.*/PROBE_TOOLS=sh/'
out35b=$("$es/.agent/scripts/status.sh" "$es" 2>&1)
printf '%s\n' "$out35b" | grep -q 'TOOLS: not installed' && fail "status.conf: a trimmed PROBE_TOOLS list stops the probe" || pass "status.conf: a trimmed PROBE_TOOLS list stops the probe"

mismatch36=""
for k in LOG_MAX_ENTRIES LOG_MAX_WORDS LOG_ENTRY_MAX_WORDS MEMORY_MAX_WORDS \
         MEMORY_MAX_ENTRIES LEARNED_MAX_RULES LEARNED_MAX_WORDS \
         DOCS_MAX_WORDS ENTRYPOINT_MAX_WORDS TAIL_LINES PAYLOAD_MAX_BYTES \
         HOOK_MAX_BYTES MEMORY_INDEX_BYTES; do
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

mismatch36c=""
for k in SOURCE_ROOTS TEST_PATH_RE CATALOGS MAX_FINDINGS SCRATCH_DIR; do
  sdef=$(sed -n "s/^$k=//p" "$reporoot/scripts/review.sh" | head -n 1 | tr -d "'")
  cdef=$(sed -n "s/^$k=//p" "$reporoot/scripts/review.conf" | head -n 1)
  [ -n "$sdef" ] && [ "$sdef" = "$cdef" ] || mismatch36c="$mismatch36c $k"
done
[ -z "$mismatch36c" ] && pass "starter review.conf lists the script's own defaults" || fail "starter review.conf lists the script's own defaults ($mismatch36c)"

lb="$WORK/log-branch"
mkdir -p "$lb"
"$NODE" init --preset software-development --mode track-all "$lb" >/dev/null 2>&1
git -C "$lb" -c user.name=t -c user.email=t@t init -q
git -C "$lb" checkout -q -b feat-x
subst "$lb/.agent/scripts/log.conf" 's/^LOG_INCLUDE_BRANCH=false/LOG_INCLUDE_BRANCH=true/'
"$LOGSH" --tool t --area a --verify pass --summary "did the thing" "$lb" >/dev/null 2>&1
tail -n 1 "$lb/.agent/session-log.md" | grep -qF '. branch: feat-x. verify: pass.' && pass "log.sh: the branch stamp reads the checked-out branch" || fail "log.sh: the branch stamp reads the checked-out branch ($(tail -n 1 "$lb/.agent/session-log.md"))"

"$LOGSH" --tool t --area a --verify pass --summary "stamped" --session s-1.x_Y "$lb" >/dev/null 2>&1
"$LOGSH" --tool t --area a --verify pass --summary "bad id" --session 'a b' "$lb" >/dev/null 2>&1
rc_ls=$?
ls_last=$(tail -n 1 "$lb/.agent/session-log.md")
case "$rc_ls:$ls_last" in
  [1-9]*:*' (t) stamped (a). branch: feat-x. session: s-1.x_Y. verify: pass.') pass "log.sh: a session id is stamped between branch and verify, and an unsafe one is refused" ;;
  *) fail "log.sh: a session id is stamped between branch and verify, and an unsafe one is refused (rc=$rc_ls; $ls_last)" ;;
esac

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

subst "$lb/.agent/scripts/log.conf" 's/^LOG_INCLUDE_BRANCH=false/LOG_INCLUDE_BRANCH=true/'
"$LOGSH" --tool t --area a --verify pass --summary "$(words_n 25)" "$lb" >/dev/null 2>&1 \
  && tail -n 1 "$lb/.agent/session-log.md" | grep -q 'branch: feat-x' && pass "log.sh: the stamp spends no summary budget at the 25-word ceiling" || fail "log.sh: the stamp spends no summary budget at the 25-word ceiling"
status_flags "$lb" | grep -q 'entries over' && fail "log.sh: a stamped max-length entry stays under the entry-shape flag" || pass "log.sh: a stamped max-length entry stays under the entry-shape flag"

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
(cd "$reporoot" && find . -name '*.md' -not -path '*/.git/*' -not -path './tmp/*' -not -path './.claude/*' -not -path './.codex/*' -not -path './evals/runs/*' -not -path './evals/prose/continuity-core.md' -print0) >"$WORK/hw-corpus"
while IFS= read -r -d '' md; do
  hit=$(cd "$reporoot" && awk -f "$hwawk" "$md")
  [ -n "$hit" ] && hw38="$hw38 $hit"
done <"$WORK/hw-corpus"
[ -z "$hw38" ] && pass "markdown: the corpus is soft-wrapped" || fail "markdown: the corpus is soft-wrapped ($(printf '%s' "${hw38# }" | cut -c1-160))"

printf 'A paragraph broken by a column limit\nrather than by a blank line.\n' >"$WORK/hardwrap-fixture.md"
[ -n "$(awk -f "$hwawk" "$WORK/hardwrap-fixture.md")" ] && pass "markdown: the check catches an injected hard wrap" || fail "markdown: the check catches an injected hard wrap"

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

printf 'One line of prose.\n\n```\nwrapped inside\na fence\n```\n' >"$WORK/hardwrap-fence.md"
[ -z "$(awk -f "$hwawk" "$WORK/hardwrap-fence.md")" ] && pass "markdown: a fenced block is not read as wrapped prose" || fail "markdown: a fenced block is not read as wrapped prose"

omnode="$WORK/om-quotes"
mkdir -p "$omnode"
"$NODE" init --preset software-development --mode track-all "$omnode" >/dev/null 2>&1
"$omnode/.agent/scripts/docs.sh" new --name a --read-when "x" "$omnode" >/dev/null 2>&1

om_drift=""
om_check() {
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
grep -qF "Agent-facing reference, not a human narrative" "$omnode/.agent/docs/a.md" && om_drift="$om_drift docs/a.md(header-returned)"
grep -qF "Agent-facing reference, not a human narrative" "$reporoot/operating-model.md" && om_drift="$om_drift operating-model.md(header-returned)"
[ -z "$om_drift" ] && pass "operating model: the quoted node headers match what the scripts write" || fail "operating model: the quoted node headers match what the scripts write (drifted:$om_drift)"

om_probe=$(grep -qF "a phrase no header contains anywhere" "$reporoot/operating-model.md" && echo found || echo absent)
[ "$om_probe" = absent ] && pass "operating model: the quote check tests presence, not a constant" || fail "operating model: the quote check tests presence, not a constant"


ce="$WORK/confexec"
mkdir -p "$ce"
"$NODE" init --preset software-development --mode track-all "$ce" >/dev/null 2>&1
ce_marker="$WORK/conf-exec-marker"
rm -f "$ce_marker"
printf 'LOG_MAX_ENTRIES=entrypoints[$(touch %s)]\n' "$ce_marker" >>"$ce/.agent/scripts/status.conf"
ce_out=$("$ce/.agent/scripts/status.sh" "$ce" 2>/dev/null)
[ ! -e "$ce_marker" ] && pass "status.conf: a conf value cannot execute a command" || fail "status.conf: a conf value cannot execute a command"
printf '%s\n' "$ce_out" | grep -q '^REPAIR: status.conf LOG_MAX_ENTRIES=' && pass "status.conf: a value that is not a whole number draws a REPAIR flag" || fail "status.conf: a value that is not a whole number draws a REPAIR flag"

grep -v '^LOG_MAX_ENTRIES=entrypoints' "$ce/.agent/scripts/status.conf" >"$ce/conf.tmp" && mv "$ce/conf.tmp" "$ce/.agent/scripts/status.conf"
printf 'LOG_MAX_ENTRIES=1\n' >>"$ce/.agent/scripts/status.conf"
printf -- '- [2026-01-01] (t) a (b). verify: pass.\n- [2026-01-02] (t) a (b). verify: pass.\n' >>"$ce/.agent/session-log.md"
status_flags "$ce" | grep -q '^GROOM: session-log.md' && pass "status.conf: a valid threshold still tunes the check" || fail "status.conf: a valid threshold still tunes the check"

lc="$WORK/logconf"
mkdir -p "$lc"
"$NODE" init --preset software-development --mode track-all "$lc" >/dev/null 2>&1
printf 'SUMMARY_MAX_WORDS=25 words\n' >>"$lc/.agent/scripts/log.conf"
"$lc/.agent/scripts/log.sh" --tool t --area a --verify pass --summary "short entry" "$lc" >/dev/null 2>&1 \
  && fail "log.conf: a ceiling that is not a whole number is refused" || pass "log.conf: a ceiling that is not a whole number is refused"

"$lc/.agent/scripts/log.sh" --tool t --area a --verify pass --summary --area "$lc" >/dev/null 2>&1 \
  && fail "log.sh: a flag is not accepted as another flag's value" || pass "log.sh: a flag is not accepted as another flag's value"

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

ax_bad=""
for ax_f in "$reporoot"/scripts/status.sh "$reporoot"/scripts/links.sh \
  "$reporoot"/scripts/docs/status.md "$reporoot"/scripts/docs/links.md \
  "$reporoot"/operating-model.md; do
  grep -qiE 'always exits? 0' "$ax_f" && ax_bad="$ax_bad $(basename "$ax_f")"
done
[ -z "$ax_bad" ] && pass "status.sh and links.sh: nothing claims an unconditional exit 0" || fail "status.sh and links.sh: nothing claims an unconditional exit 0 ($ax_bad)"

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

"$vn/.agent/scripts/memory.sh" new --slug -weird --title T --hook H --fact F "$vn" >/dev/null 2>&1 \
  && fail "memory.sh: a slug starting with - is refused" || pass "memory.sh: a slug starting with - is refused"
"$vn/.agent/scripts/docs.sh" new --name -weird --read-when x "$vn" >/dev/null 2>&1 \
  && fail "docs.sh: a name starting with - is refused" || pass "docs.sh: a name starting with - is refused"
"$vn/.agent/scripts/memory.sh" new --slug ok-slug --title T --hook H --fact --scope "$vn" >/dev/null 2>&1 \
  && fail "memory.sh: a flag is not accepted as another flag's value" || pass "memory.sh: a flag is not accepted as another flag's value"
"$vn/.agent/scripts/memory.sh" new --slug fresh-slug --title T --hook H --fact "a real fact" "$vn" >/dev/null 2>&1 \
  && pass "memory.sh: a valid invocation still writes" || fail "memory.sh: a valid invocation still writes"

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

fo_out=$(cd "$fo" && "$fo/.agent/scripts/comments.sh" base 2>/dev/null)
printf '%s\n' "$fo_out" | grep -qF 'My Project/Program.cs' && pass "comments.sh: a path containing a space is still gated" || fail "comments.sh: a path containing a space is still gated"
printf '%s\n' "$fo_out" | grep -qF 'Plain.cs' && pass "comments.sh: the unspaced control path is gated" || fail "comments.sh: the unspaced control path is gated"

grep -v '^BLOCK_RE_EXTRA=' "$fo/.agent/scripts/comments.conf" >"$fo/conf.tmp" && mv "$fo/conf.tmp" "$fo/.agent/scripts/comments.conf"
printf 'BLOCK_RE_EXTRA=[unclosed\n' >>"$fo/.agent/scripts/comments.conf"
fo_bad=$(cd "$fo" && "$fo/.agent/scripts/comments.sh" base 2>/dev/null)
fo_rc=$?
[ "$fo_rc" -ne 0 ] && [ -z "$fo_bad" ] && pass "comments.sh: a conf regex that will not compile fails closed" || fail "comments.sh: a conf regex that will not compile fails closed (rc=$fo_rc)"

grep -v '^BLOCK_RE_EXTRA=' "$fo/.agent/scripts/comments.conf" >"$fo/conf.tmp" && mv "$fo/conf.tmp" "$fo/.agent/scripts/comments.conf"
printf 'BLOCK_RE_EXTRA=(^|[^[:alnum:]])TKT-[0-9]{3}\n' >>"$fo/.agent/scripts/comments.conf"
noiv="$WORK/no-interval-awk"
mkdir -p "$noiv"
printf '#!/bin/sh\ncase "$*" in *"{2}"*) exit 1 ;; esac\nexec %s "$@"\n' "$(command -v awk)" >"$noiv/awk"
chmod +x "$noiv/awk"
fo_iv=$(cd "$fo" && PATH="$noiv:$PATH" "$fo/.agent/scripts/comments.sh" base 2>&1 >/dev/null)
fo_rc=$?
[ "$fo_rc" -eq 2 ] && printf '%s' "$fo_iv" | grep -qF 'interval' && pass "comments.sh: a conf interval regex fails closed under an awk that cannot match intervals" || fail "comments.sh: a conf interval regex fails closed under an awk that cannot match intervals (rc=$fo_rc; $fo_iv)"

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
cp "$ews/CLAUDE.md" "$ews/AGENTS.md"
f41m=$(status_flags "$ews")
printf '%s\n' "$f41m" | grep -qF 'differs from' && fail "status.sh: mirrored entry points raise no drift flag" || pass "status.sh: mirrored entry points raise no drift flag"
[ "$(printf '%s\n' "$f41m" | grep -cF 'carries the section')" -eq 2 ] && pass "status.sh: a mirrored section is flagged in every entry point" || fail "status.sh: a mirrored section is flagged in every entry point ($f41m)"
printf '# P — Session Bootstrap\n\nRun it:\n\n```\n## not a heading\n```\n\nbash .agent/scripts/status.sh\n' >"$ews/CLAUDE.md"
rm -f "$ews/AGENTS.md"
status_flags "$ews" | grep -qF 'carries the section' && fail "status.sh: a heading inside a fenced block is not a section" || pass "status.sh: a heading inside a fenced block is not a section"

tpl41=$(sed -n '2,$p' "$reporoot/templates/entry-point.md" | wc -w | tr -d '[:space:]')
def41=$(sed -n 's/^ENTRYPOINT_MAX_WORDS=//p' "$reporoot/scripts/status.sh" | head -n 1)
[ -n "$def41" ] && [ "$def41" -ge "$((tpl41 * 2))" ] && [ "$def41" -le "$((tpl41 * 3))" ] \
  && pass "status.sh: ENTRYPOINT_MAX_WORDS stays ~2x the shipped template" \
  || fail "status.sh: ENTRYPOINT_MAX_WORDS stays ~2x the shipped template (template $tpl41, threshold $def41)"

tpl41f="$reporoot/templates/entry-point.md"
missing41=""
grep -qF "run once" "$tpl41f" || grep -qF "runs once" "$tpl41f" || missing41="$missing41 once-per-session"
grep -qF "A new user message does not start a new session." "$tpl41f" || missing41="$missing41 user-turn-is-not-a-session"
grep -qF "Do not open this file with a tool when its content is already present in your context." "$tpl41f" || missing41="$missing41 no-reopen-from-disk"
grep -qF "compaction" "$tpl41f" || missing41="$missing41 compaction-rerun"
grep -qF "Never restate it here" "$tpl41f" || missing41="$missing41 wiring-only"
grep -qF "checkpoint.sh" "$tpl41f" || missing41="$missing41 checkpoint-call"
[ -z "$missing41" ] && pass "template: the entry point carries its timing and boundary rules" || fail "template: the entry point carries its timing and boundary rules (missing:$missing41)"

gate41=$(grep -nF 'A new user message does not start a new session.' "$tpl41f" | cut -d: -f1)
steps41=$(grep -nE '^1\. ' "$tpl41f" | head -n 1 | cut -d: -f1)
[ -n "$gate41" ] && [ -n "$steps41" ] && [ "$gate41" -lt "$steps41" ] && pass "template: the per-conversation gate precedes the numbered steps" || fail "template: the per-conversation gate precedes the numbered steps (gate=$gate41 steps=$steps41)"



stale_hits=$(grep -rIn -- "no completion-time gate" \
  "$reporoot/README.md" "$reporoot/operating-model.md" \
  "$reporoot/presets" "$reporoot/templates" "$reporoot/tools" 2>/dev/null)
if [ -z "$stale_hits" ]; then
  pass "docs: 'no completion-time gate' does not appear in README.md, operating-model.md, presets/, templates/, or tools/"
else
  fail "docs: 'no completion-time gate' does not appear in README.md, operating-model.md, presets/, templates/, or tools/ (found: $(printf '%s' "$stale_hits" | head -n1))"
fi

if grep -qF 'status.sh --format tsv' "$reporoot/README.md" && grep -qF 'strict policy' "$reporoot/README.md"; then
  pass "README.md: checkpoint uses structured status and documents strict policy"
else
  fail "README.md: checkpoint uses structured status and documents strict policy"
fi

flagstands_ok=0
grep -qF "status findings block completion" "$reporoot/scripts/checkpoint.sh" && flagstands_ok=1
statusrc_ok=0
grep -qF "status check failed to run cleanly" "$reporoot/scripts/checkpoint.sh" && statusrc_ok=1
if [ "$flagstands_ok" -eq 1 ] && [ "$statusrc_ok" -eq 1 ]; then
  pass "scripts/checkpoint.sh: both fail-closed branches (a standing flag, a status check that failed to run cleanly) are present"
else
  fail "scripts/checkpoint.sh: both fail-closed branches (a standing flag, a status check that failed to run cleanly) are present (flagstands_ok=$flagstands_ok statusrc_ok=$statusrc_ok)"
fi

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

routing_files48="$reporoot/templates/entry-point.md $reporoot/templates/entry-point-generated.md"
for p48 in "$reporoot"/presets/*.md; do
  grep -qi "routing" "$p48" && routing_files48="$routing_files48 $p48"
done
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

. "$selfdir/tests/generated-index-suite.sh"

wait "$eval_checks_pid"
cat "$eval_checks_out"
PASS=$((PASS + $(grep -c '^ok   ' "$eval_checks_out")))
FAIL=$((FAIL + $(grep -c '^FAIL ' "$eval_checks_out")))

wait "$v63_pid"
for v63_test in "$reporoot"/scripts/tests/*-v63.sh; do
  [ -f "$v63_test" ] || continue
  if [ "$(cat "$v63_out/${v63_test##*/}.rc" 2>/dev/null)" = 0 ]; then
    pass "v6.3: ${v63_test##*/}"
  else
    cat "$v63_out/${v63_test##*/}.out" 2>/dev/null
    fail "v6.3: ${v63_test##*/}"
  fi
done

ran=$((PASS + FAIL))
EXPECTED_CHECKS=1403
if [ "$ran" -ne "$EXPECTED_CHECKS" ]; then
  printf 'FAIL check count: expected %d, ran %d — a check was added, removed, or stopped running\n' "$EXPECTED_CHECKS" "$ran"
  FAIL=$((FAIL + 1))
fi
total=$((PASS + FAIL))

printf '\n%d/%d checks passed (%d failed)\n' "$PASS" "$total" "$FAIL"
[ "$FAIL" -eq 0 ] && exit 0
exit 1
