#!/usr/bin/env bash

set -u
export LC_ALL=C

here=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd -P) || exit 1
tmp=$(mktemp -d "${TMPDIR:-/tmp}/records-v63.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
n=0
failed=0

ok() { n=$((n + 1)); printf 'ok %d - %s\n' "$n" "$1"; }
bad() { n=$((n + 1)); failed=$((failed + 1)); printf 'not ok %d - %s\n' "$n" "$1"; }
assert_file_has() { grep -qF -- "$2" "$1" && ok "$3" || bad "$3"; }

node="$tmp/node"
mkdir -p "$node/.agents/rules/learned" "$node/.agents/memory" "$node/.agents/docs" "$node/src"
printf '%s\n' '# Purpose' 'refundPayment service' '  indexes: generated' >"$node/.agents/purpose.md"
printf '%s\n' '# Core rules' 'Never expose secret tokens.' >"$node/.agents/rules/core.md"
printf '%s\n' '# Memory' >"$node/.agents/memory.md"
printf '%s\n' '- [2026-01-01] Keep refund retry bounded. Trigger: refund work.' >"$node/.agents/rules/learned/aaaaaaaaaaaa.md"

generated=$(printf '%s\n' '- [2026-09-27] Keep refund retry bounded. Trigger: refund work.' | "$here/scripts/learn.sh" lookup --file - "$node")
printf '%s\n' "$generated" | grep -qF "duplicate	$node/.agents/rules/learned/aaaaaaaaaaaa.md" && ok 'generated lookup ignores leading dates for duplicate bodies' || bad 'generated lookup ignores leading dates for duplicate bodies'

printf '%s\n' '- [2026-01-01] Boundary text follows.' >"$node/.agents/rules/learned/bbbbbbbbbbbb.md"
printf '\034fabricated-record\n' >>"$node/.agents/rules/learned/bbbbbbbbbbbb.md"
printf '%s\n' 'separator proof' >>"$node/.agents/rules/learned/bbbbbbbbbbbb.md"
separator_candidate="$tmp/separator-candidate.md"
printf '%s\n' '- [2026-09-27] Boundary text follows.' >"$separator_candidate"
printf '\034fabricated-record\n' >>"$separator_candidate"
printf '%s\n' 'separator proof' >>"$separator_candidate"
separator_learn=$("$here/scripts/learn.sh" lookup --file "$separator_candidate" "$node")
if printf '%s\n' "$separator_learn" | grep -qF "duplicate	$node/.agents/rules/learned/bbbbbbbbbbbb.md" && ! printf '%s\n' "$separator_learn" | grep -q 'fabricated-record'; then
  ok 'learned scan treats the old separator as record body text'
else
  bad 'learned scan treats the old separator as record body text'
fi

if printf '%s\n' '- [2026-09-27] Keep refund retry bounded. Trigger: refund work.' | "$here/scripts/learn.sh" new --file - "$node" >/dev/null 2>&1; then status=0; else status=$?; fi
[ "$status" -eq 5 ] && ok 'new refuses a date-only duplicate with legacy exit 5' || bad 'new refuses a date-only duplicate with legacy exit 5'

written=$(printf '%s\n' '- [2026-09-27] Calibrate zircon widgets before launch.' | "$here/scripts/learn.sh" new --file - "$node" 2>/dev/null)
learn_id=$(printf '%s\n' "$written" | awk -F '\t' '$1=="written" {print $2}')
learn_version=$(printf '%s\n' "$written" | awk -F '\t' '$1=="written" {print $3}')
[ -n "$learn_id" ] && [ -n "$learn_version" ] && ok 'generated new still returns identity and version' || bad 'generated new still returns identity and version'
revised=$(printf '%s\n' '- [2026-09-27] Recalibrate zircon widgets before launch.' | "$here/scripts/learn.sh" revise "$learn_id" --file - --expected "$learn_version" "$node" 2>/dev/null)
revised_version=$(printf '%s\n' "$revised" | awk -F '\t' '$1=="revised" {print $3}')
[ -n "$revised_version" ] && [ "$revised_version" != "$learn_version" ] && ok 'generated revise preserves expected-version behavior' || bad 'generated revise preserves expected-version behavior'
if printf '%s\n' '- [2026-09-27] Retune zircon widgets before launch.' | "$here/scripts/learn.sh" revise "$learn_id" --file - --expected stale "$node" >/dev/null 2>&1; then status=0; else status=$?; fi
[ "$status" -eq 3 ] && ok 'generated revise retains stale exit 3' || bad 'generated revise retains stale exit 3'
"$here/scripts/learn.sh" retire "$learn_id" --expected "$revised_version" "$node" >/dev/null 2>&1
[ ! -e "$node/.agents/rules/learned/$learn_id.md" ] && ok 'generated retire retains versioned removal' || bad 'generated retire retains versioned removal'

learn_race_bin="$tmp/learn-race-bin"
learn_race_state="$tmp/learn-race-state"
learn_real_git=$(command -v git)
mkdir -p "$learn_race_bin"
cat >"$learn_race_bin/git" <<'EOF'
#!/bin/sh
race_output=$("$LEARN_REAL_GIT" "$@") || exit $?
if [ "$1" = hash-object ] && [ "${4-}" = "$LEARN_RACE_TARGET" ]; then
  race_count=$(cat "$LEARN_RACE_STATE" 2>/dev/null || printf '0')
  race_count=$((race_count + 1))
  printf '%s\n' "$race_count" >"$LEARN_RACE_STATE"
  if [ "$race_count" -eq 1 ]; then
    printf '%s\n' "$LEARN_RACE_NEWER" >"$LEARN_RACE_TARGET"
  fi
fi
printf '%s\n' "$race_output"
EOF
chmod +x "$learn_race_bin/git"

revise_race_target="$node/.agents/rules/learned/cccccccccccc.md"
revise_race_newer='- [2026-09-27] Preserve the newer revise race record.'
printf '%s\n' '- [2026-09-27] Original revise race record.' >"$revise_race_target"
revise_race_expected=$(git hash-object --no-filters -- "$revise_race_target")
rm -f "$learn_race_state"
if printf '%s\n' '- [2026-09-27] Candidate revise race record.' \
  | LEARN_REAL_GIT="$learn_real_git" LEARN_RACE_TARGET="$revise_race_target" \
    LEARN_RACE_STATE="$learn_race_state" LEARN_RACE_NEWER="$revise_race_newer" \
    PATH="$learn_race_bin:$PATH" "$here/scripts/learn.sh" revise cccccccccccc --file - \
      --expected "$revise_race_expected" "$node" >/dev/null 2>&1; then
  status=0
else
  status=$?
fi
[ "$status" -eq 3 ] && grep -qxF -- "$revise_race_newer" "$revise_race_target" \
  && ok 'learn revise rechecks expected immediately before publication' \
  || bad 'learn revise rechecks expected immediately before publication'

retire_race_target="$node/.agents/rules/learned/dddddddddddd.md"
retire_race_newer='- [2026-09-27] Preserve the newer retire race record.'
printf '%s\n' '- [2026-09-27] Original retire race record.' >"$retire_race_target"
retire_race_expected=$(git hash-object --no-filters -- "$retire_race_target")
rm -f "$learn_race_state"
if LEARN_REAL_GIT="$learn_real_git" LEARN_RACE_TARGET="$retire_race_target" \
  LEARN_RACE_STATE="$learn_race_state" LEARN_RACE_NEWER="$retire_race_newer" \
  PATH="$learn_race_bin:$PATH" "$here/scripts/learn.sh" retire dddddddddddd \
    --expected "$retire_race_expected" "$node" >/dev/null 2>&1; then
  status=0
else
  status=$?
fi
[ "$status" -eq 3 ] && grep -qxF -- "$retire_race_newer" "$retire_race_target" \
  && ok 'learn retire rechecks expected immediately before removal' \
  || bad 'learn retire rechecks expected immediately before removal'

manual="$tmp/manual"
mkdir -p "$manual/.agents/rules" "$manual/.agents/docs"
printf '%s\n' '# Purpose' '  indexes: manual' >"$manual/.agents/purpose.md"
printf '%s\n' '# Learned' '- [2026-02-02] Keep refund retry bounded. Trigger: refund work.' >"$manual/.agents/rules/learned.md"
manual_result=$(printf '%s\n' '- [2026-09-27] Keep refund retry bounded. Trigger: refund work.' | "$here/scripts/learn.sh" lookup --file - "$manual")
printf '%s\n' "$manual_result" | grep -qF "duplicate	$manual/.agents/rules/learned.md" && ok 'manual learned lookup reads without migrating storage' || bad 'manual learned lookup reads without migrating storage'
[ ! -d "$manual/.agents/rules/learned" ] && ok 'manual lookup creates no generated record directory' || bad 'manual lookup creates no generated record directory'

"$here/scripts/docs.sh" new --name service-catalog --read-when 'ANY service work' "$node" >/dev/null
printf '%s\n' '' '## Building blocks' 'refundPayment lives here.' >>"$node/.agents/docs/service-catalog.md"
for x in 1 2 3 4 5; do
  printf '%s\n' "refund item $x" >"$node/.agents/memory/item-$x.md"
  printf -- '- [Item %s](memory/item-%s.md) — refund item\n' "$x" "$x" >>"$node/.agents/memory.md"
done
bounded_err="$tmp/bounded.err"
bounded=$("$here/scripts/memory.sh" lookup --query refund --limit 3 "$node" 2>"$bounded_err")
[ "$(printf '%s\n' "$bounded" | awk 'NF{n++} END{print n+0}')" -eq 3 ] && ok 'canonical lookup enforces its result bound' || bad 'canonical lookup enforces its result bound'
printf '%s\n' "$bounded" | awk -F '\t' 'NF!=4 || $2 !~ /^\.agents\// || length($4)>240 {bad=1} END{exit bad}' && ok 'lookup returns bounded paths, versions, and excerpts' || bad 'lookup returns bounded paths, versions, and excerpts'
grep -Eq 'lookup showed 3 of [4-9][0-9]* matches; rerun with --limit [4-9][0-9]*' "$bounded_err" && ok 'bounded lookup reports shown and total counts with a follow-up limit' || bad 'bounded lookup reports shown and total counts with a follow-up limit'

separator_memory="$node/.agents/memory/separator-body.md"
printf '\034.agents/memory/fabricated.md\n' >"$separator_memory"
printf '%s\n' 'unique separator needle' >>"$separator_memory"
if separator_found=$("$here/scripts/memory.sh" lookup --query 'unique separator needle' "$node" 2>/dev/null) \
  && printf '%s\n' "$separator_found" | awk -F '\t' '$2==".agents/memory/separator-body.md" {found=1} $2==".agents/memory/fabricated.md" {bad=1} END {exit !(found && !bad)}'; then
  ok 'canonical scan treats the old separator as file body text'
else
  bad 'canonical scan treats the old separator as file body text'
fi

tab_rule="$node/.agents/rules/control"
tab_rule="${tab_rule}$(printf '\t')path.md"
printf '%s\n' 'control path body' >"$tab_rule"
if "$here/scripts/memory.sh" lookup --query control "$node" >/dev/null 2>&1; then status=0; else status=$?; fi
[ "$status" -ne 0 ] && ok 'canonical lookup rejects paths its TSV interface cannot represent' || bad 'canonical lookup rejects paths its TSV interface cannot represent'
rm -f "$tab_rule"

outside="$tmp/outside-agent"
escaped="$tmp/escaped-node"
mkdir -p "$outside" "$escaped"
printf '%s\n' 'outside-only needle' >"$outside/purpose.md"
ln -s "$outside" "$escaped/.agents"
if "$here/scripts/memory.sh" lookup --query outside-only "$escaped" >/dev/null 2>&1; then status=0; else status=$?; fi
[ "$status" -ne 0 ] && ok 'canonical lookup refuses parent-directory symlink escapes' || bad 'canonical lookup refuses parent-directory symlink escapes'

printf '%s\n' '' '### `missing-routed.md`' '- **Read when:** missing route' '- **Sections:**' >>"$node/.agents/docs/architecture.md"
if "$here/scripts/memory.sh" lookup --query missing "$node" >/dev/null 2>&1; then status=0; else status=$?; fi
[ "$status" -ne 0 ] && ok 'canonical lookup does not turn a missing routed file into an empty success' || bad 'canonical lookup does not turn a missing routed file into an empty success'
awk 'BEGIN{drop=0} $0=="### `missing-routed.md`" {drop=1} drop && /^### `/ && $0!="### `missing-routed.md`" {drop=0} !drop {print}' "$node/.agents/docs/architecture.md" >"$node/.agents/docs/architecture.clean"
mv "$node/.agents/docs/architecture.clean" "$node/.agents/docs/architecture.md"

printf '%s\n' 'body from stdin' | "$here/scripts/memory.sh" new --slug stdin-fact --title Stdin --hook safe --file - "$node" >/dev/null
assert_file_has "$node/.agents/memory/stdin-fact.md" 'body from stdin' 'memory new safely reads standard input'
"$here/scripts/memory.sh" new --slug legacy-fact --title Legacy --hook compatible --fact 'legacy argument body' "$node" >/dev/null
assert_file_has "$node/.agents/memory/legacy-fact.md" 'legacy argument body' 'legacy memory --fact remains supported'
chmod a-w "$node/.agents/memory.md"
if "$here/scripts/memory.sh" new --slug readonly-index --title Readonly --hook blocked --fact body "$node" >/dev/null 2>&1; then status=0; else status=$?; fi
chmod u+w "$node/.agents/memory.md"
[ "$status" -ne 0 ] && [ ! -e "$node/.agents/memory/readonly-index.md" ] && ok 'memory new respects a read-only index target' || bad 'memory new respects a read-only index target'
before=$(git hash-object --no-filters -- "$node/.agents/memory/stdin-fact.md")
if printf '%s\n' changed | "$here/scripts/memory.sh" supersede --slug stdin-fact --file - --expected stale "$node" >/dev/null 2>&1; then status=0; else status=$?; fi
after=$(git hash-object --no-filters -- "$node/.agents/memory/stdin-fact.md")
[ "$status" -eq 3 ] && [ "$before" = "$after" ] && ok 'stale memory supersede is refused atomically' || bad 'stale memory supersede is refused atomically'

syncdoc="$node/.agents/docs/sync-target.md"
printf '%s\n' '# Sync target' '' '## Visible' '' '```md' '## Hidden in fence' '```' >"$syncdoc"
chmod a-w "$node/.agents/docs/architecture.md"
if "$here/scripts/docs.sh" new --name readonly-route --read-when blocked "$node" >/dev/null 2>&1; then status=0; else status=$?; fi
chmod u+w "$node/.agents/docs/architecture.md"
[ "$status" -ne 0 ] && [ ! -e "$node/.agents/docs/readonly-route.md" ] && ok 'docs new respects a read-only routing target' || bad 'docs new respects a read-only routing target'
if "$here/scripts/docs.sh" sync --name sync-target "$node" >/dev/null 2>&1; then status=0; else status=$?; fi
[ "$status" -ne 0 ] && ok 'sync requires supplied text for a missing hook' || bad 'sync requires supplied text for a missing hook'
"$here/scripts/docs.sh" sync --name sync-target --read-when 'sync work' "$node" >/dev/null
assert_file_has "$node/.agents/docs/architecture.md" '- **Sections:** Visible' 'sync derives visible headings'
if grep -F -- '- **Sections:** Visible · Hidden in fence' "$node/.agents/docs/architecture.md" >/dev/null; then bad 'sync ignores headings inside code fences'; else ok 'sync ignores headings inside code fences'; fi
cp "$node/.agents/docs/architecture.md" "$node/.agents/docs/architecture.before"
printf '%s\n' '' '### `sync-target.md`' '- **Read when:** duplicate' '- **Sections:** duplicate' >>"$node/.agents/docs/architecture.md"
if "$here/scripts/docs.sh" sync --name sync-target "$node" >/dev/null 2>&1; then status=0; else status=$?; fi
[ "$status" -ne 0 ] && ok 'sync refuses ambiguous routing entries' || bad 'sync refuses ambiguous routing entries'
mv "$node/.agents/docs/architecture.before" "$node/.agents/docs/architecture.md"

sync_body_before=$(git hash-object --no-filters -- "$syncdoc")
mv "$node/.agents/docs/architecture.md" "$node/.agents/docs/architecture.real"
ln -s architecture.real "$node/.agents/docs/architecture.md"
if "$here/scripts/docs.sh" sync --name sync-target "$node" >/dev/null 2>"$tmp/sync-symlink.err"; then status=0; else status=$?; fi
sync_body_after=$(git hash-object --no-filters -- "$syncdoc")
if [ "$status" -ne 0 ] && [ "$sync_body_before" = "$sync_body_after" ] && grep -q 'architecture.md is a symlink' "$tmp/sync-symlink.err"; then
  ok 'sync refuses an architecture symlink before changing the document'
else
  bad 'sync refuses an architecture symlink before changing the document'
fi
rm -f "$node/.agents/docs/architecture.md"
mv "$node/.agents/docs/architecture.real" "$node/.agents/docs/architecture.md"

printf '%s\n' '' '| Block | Path | Use when |' '| --- | --- | --- |' '| `old` | `src/old.ts` | old use |' >>"$node/.agents/docs/service-catalog.md"
printf '%s\n' old >"$node/src/old.ts"
printf '%s\n' new >"$node/src/new.ts"
"$here/scripts/docs.sh" catalog --catalog service-catalog --name newThing --path src/new.ts --when 'new work' "$node" >/dev/null
assert_file_has "$node/.agents/docs/service-catalog.md" '| `newThing` | `src/new.ts` | new work |' 'catalog inserts one structured row'
mkdir -p "$node/src/space dir"
printf '%s\n' spaced >"$node/src/space dir/file name.ts"
"$here/scripts/docs.sh" catalog --catalog service-catalog --name spacedThing --path 'src/space dir/file name.ts' --when 'space path work' "$node" >/dev/null
assert_file_has "$node/.agents/docs/service-catalog.md" '| `spacedThing` | `src/space dir/file name.ts` | space path work |' 'catalog accepts ordinary spaces in an existing project path'
"$here/scripts/docs.sh" catalog --catalog service-catalog --name newThing --path src/old.ts --when 'revised work' "$node" >/dev/null
[ "$(grep -c '^| `newThing` |' "$node/.agents/docs/service-catalog.md")" -eq 1 ] && grep -qF '| `newThing` | `src/old.ts` | revised work |' "$node/.agents/docs/service-catalog.md" && ok 'catalog updates exactly one existing key' || bad 'catalog updates exactly one existing key'
printf '%s\n' '| `newThing` | `src/new.ts` | duplicate |' >>"$node/.agents/docs/service-catalog.md"
if "$here/scripts/docs.sh" catalog --catalog service-catalog --name newThing --path src/new.ts --when x "$node" >/dev/null 2>&1; then status=0; else status=$?; fi
[ "$status" -ne 0 ] && ok 'catalog refuses duplicate keys' || bad 'catalog refuses duplicate keys'
if "$here/scripts/docs.sh" catalog --catalog service-catalog --name escape --path ../outside --when x "$node" >/dev/null 2>&1; then status=0; else status=$?; fi
[ "$status" -ne 0 ] && ok 'catalog refuses paths outside the project' || bad 'catalog refuses paths outside the project'
if "$here/scripts/docs.sh" catalog --catalog service-catalog --name 'bad|key' --path src/new.ts --when x "$node" >/dev/null 2>&1; then status=0; else status=$?; fi
[ "$status" -ne 0 ] && ok 'catalog refuses table escaping hazards' || bad 'catalog refuses table escaping hazards'

amb="$node/.agents/docs/ambiguous.md"
printf '%s\n' '| Symbol | Path | Use when |' '| --- | --- | --- |' '' '| Name | Path | Read when |' '| --- | --- | --- |' >"$amb"
if "$here/scripts/docs.sh" catalog --catalog ambiguous --name x --path src/new.ts --when x "$node" >/dev/null 2>&1; then status=0; else status=$?; fi
[ "$status" -ne 0 ] && ok 'catalog refuses ambiguous tables' || bad 'catalog refuses ambiguous tables'

"$here/scripts/docs.sh" rehook --name service-catalog --read-when 'ALL service work' "$node" >/dev/null
assert_file_has "$node/.agents/docs/service-catalog.md" '<!-- Read when: ALL service work -->' 'legacy docs rehook still works'
printf '%s\n' legacy | "$here/scripts/memory.sh" supersede --slug stdin-fact --file - --expected "$after" "$node" >/dev/null
assert_file_has "$node/.agents/memory/stdin-fact.md" legacy 'expected-version supersede succeeds at the current version'

race_fact="$node/.agents/memory/stdin-fact.md"
race_expected=$(git hash-object --no-filters -- "$race_fact")
race_bin="$tmp/race-bin"
mkdir -p "$race_bin"
cat >"$race_bin/date" <<'EOF'
#!/bin/sh
printf '%s\n' 'concurrent writer body' >"$RACE_FACT"
printf '%s\n' 2026-09-27
EOF
chmod +x "$race_bin/date"
if printf '%s\n' replacement | RACE_FACT="$race_fact" PATH="$race_bin:$PATH" "$here/scripts/memory.sh" supersede --slug stdin-fact --file - --expected "$race_expected" "$node" >/dev/null 2>&1; then status=0; else status=$?; fi
[ "$status" -eq 3 ] && grep -qF 'concurrent writer body' "$race_fact" && ok 'memory supersede rechecks expected immediately before replacement' || bad 'memory supersede rechecks expected immediately before replacement'

abs_node="$tmp/abs-node"
mkdir -p "$abs_node/.agents/rules/learned"
printf '%s\n' '# Purpose' '  indexes: generated' >"$abs_node/.agents/purpose.md"
printf '%s\n' '- [2026-01-01] Keep refund retry bounded absolute style. Trigger: refund work.' >"$abs_node/.agents/rules/learned/eeeeeeeeeeee.md"
abs_lookup=$(printf '%s\n' '- [2026-09-27] Keep refund retry bounded absolute style. Trigger: refund work.' | "$here/scripts/learn.sh" lookup --file - "$abs_node")
if printf '%s\n' "$abs_lookup" | awk -F '\t' -v want="$abs_node/.agents/rules/learned/eeeeeeeeeeee.md" 'NF!=3 {bad=1} $1=="duplicate" && $2==want {found=1} END{exit !(found && !bad)}'; then
  ok 'generated lookup returns exactly three root-prefixed fields under an absolute root'
else
  bad 'generated lookup returns exactly three root-prefixed fields under an absolute root'
fi

manual_abs_result=$(printf '%s\n' '- [2026-09-27] Keep refund retry bounded. Trigger: refund work.' | "$here/scripts/learn.sh" lookup --file - "$manual")
if printf '%s\n' "$manual_abs_result" | awk -F '\t' -v want="$manual/.agents/rules/learned.md" 'NF!=3 {bad=1} $1=="duplicate" && $2==want {found=1} END{exit !(found && !bad)}'; then
  ok 'manual lookup returns exactly three root-prefixed fields under an absolute root'
else
  bad 'manual lookup returns exactly three root-prefixed fields under an absolute root'
fi

rel_root_parent="$tmp/rel-root-parent"
mkdir -p "$rel_root_parent/rel-node/.agents/rules/learned"
printf '%s\n' '# Purpose' '  indexes: generated' >"$rel_root_parent/rel-node/.agents/purpose.md"
printf '%s\n' '- [2026-01-01] Keep refund retry bounded relative style. Trigger: refund work.' >"$rel_root_parent/rel-node/.agents/rules/learned/ffffffffffff.md"
rel_lookup=$(cd "$rel_root_parent" && printf '%s\n' '- [2026-09-27] Keep refund retry bounded relative style. Trigger: refund work.' | "$here/scripts/learn.sh" lookup --file - rel-node)
if printf '%s\n' "$rel_lookup" | awk -F '\t' 'NF!=3 {bad=1} $1=="duplicate" && $2=="rel-node/.agents/rules/learned/ffffffffffff.md" {found=1} END{exit !(found && !bad)}'; then
  ok 'generated lookup returns a root-prefixed path under a relative root'
else
  bad 'generated lookup returns a root-prefixed path under a relative root'
fi

unicode_doc="$node/.agents/docs/café notes.md"
printf '%s\n' '<!-- Read when: unicode work -->' '# Café Notes' '' '## Visible Section' >"$unicode_doc"
"$here/scripts/docs.sh" sync --name 'café notes' --read-when 'unicode work' "$node" >/dev/null
assert_file_has "$node/.agents/docs/architecture.md" '### `café notes.md`' 'sync accepts a routed filename with Unicode and a space'

names_node="$tmp/names-node"
mkdir -p "$names_node/.agents/docs" "$names_node/src"
printf '%s\n' '<!-- Read when: names work -->' '# Names Catalog' '' '| Symbol | Path | Use when |' '| --- | --- | --- |' >"$names_node/.agents/docs/names-catalog.md"
printf '%s\n' entry >"$names_node/src/entry.ts"
"$here/scripts/docs.sh" catalog --catalog names-catalog --name 'events$' --path src/entry.ts --when 'dollar name work' "$names_node" >/dev/null
assert_file_has "$names_node/.agents/docs/names-catalog.md" '| `events$` | `src/entry.ts` | dollar name work |' 'catalog accepts a catalog name containing $'
"$here/scripts/docs.sh" catalog --catalog names-catalog --name 'Human Block' --path src/entry.ts --when 'human block work' "$names_node" >/dev/null
assert_file_has "$names_node/.agents/docs/names-catalog.md" '| `Human Block` | `src/entry.ts` | human block work |' 'catalog accepts a human-readable block name with spaces'

printf '1..%d\n' "$n"
[ "$failed" -eq 0 ]
