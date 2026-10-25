#!/usr/bin/env bash
set -eu
unset CDPATH
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/install-v63.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
project="$scratch/project"
mkdir -p "$project"
fail() { echo "FAIL install-v63: $*" >&2; exit 1; }
bash "$repo/scripts/node.sh" init --preset software-development --mode ignore-all "$project" >/dev/null
for file in runtime.sh verify.sh review.sh checks.sh checkpoint.conf verify.conf review.conf; do
  [ -f "$project/.agent/scripts/$file" ] || fail "missing installed $file"
done
if bash "$project/.agent/scripts/checks.sh" test >/dev/null 2>&1; then fail 'unconfigured driver returned success'; fi
printf '#!/usr/bin/env bash\nprintf "project-owned driver\\n"\n' >"$project/.agent/scripts/checks.sh"
printf 'CHECK_DRIVER=scripts/custom-checks.sh\n' >"$project/.agent/scripts/verify.conf"
printf '\nLocal project rule survives.\n' >>"$project/.agent/rules/contract.md"
printf '\nA current private fact.\n' >>"$project/.agent/memory.md"
for file in scripts/checks.sh scripts/verify.conf rules/contract.md memory.md; do
  mkdir -p "$scratch/original/$(dirname "$file")"
  cp "$project/.agent/$file" "$scratch/original/$file"
done
sed 's/version: "6.3"/version: "6.2"/' "$project/.agent/purpose.md" >"$scratch/purpose"
mv "$scratch/purpose" "$project/.agent/purpose.md"
rm "$project/.agent/scripts/runtime.sh" "$project/.agent/scripts/verify.sh" "$project/.agent/scripts/review.sh"
printf 'project-owned older helper\n' >"$project/.agent/scripts/verify.sh"
if bash "$repo/scripts/node.sh" update "$project" >/dev/null 2>&1; then fail 'new helper collision was overwritten'; fi
grep -q 'project-owned older helper' "$project/.agent/scripts/verify.sh" || fail 'colliding helper was lost'
if grep -q 'migration_target:' "$project/.agent/purpose.md"; then fail 'collision changed the manifest'; fi
rm "$project/.agent/scripts/verify.sh"
bash "$repo/scripts/node.sh" update "$project" >"$scratch/update.out"
grep -q 'migration_target: "6.3"' "$project/.agent/purpose.md" || fail 'migration target missing'
grep -q 'version: "6.2"' "$project/.agent/purpose.md" || fail 'version advanced before finalize'
[ -d "$project/.agent.backup-v6.2" ] || fail 'old node was not backed up'
for file in scripts/checks.sh scripts/verify.conf rules/contract.md memory.md; do
  cmp "$project/.agent/$file" "$scratch/original/$file" || fail "update replaced project-owned $file"
done
for file in runtime.sh verify.sh review.sh; do
  cmp "$repo/scripts/$file" "$project/.agent/scripts/$file" || fail "update omitted $file"
done
sed -e 's/version: "6.2"/version: "6.3"/' -e '/migration_target:/d' "$project/.agent/purpose.md" >"$scratch/purpose"
mv "$scratch/purpose" "$project/.agent/purpose.md"
printf 'old runtime inode\n' >"$project/.agent/scripts/status.sh"
ln "$project/.agent/scripts/status.sh" "$scratch/old-runtime"
rm "$project/.agent/scripts/verify.sh"
bash "$repo/scripts/node.sh" update "$project" >/dev/null
cmp "$repo/scripts/verify.sh" "$project/.agent/scripts/verify.sh" || fail 'same-version update did not restore runtime'
grep -q 'old runtime inode' "$scratch/old-runtime" || fail 'refresh modified a live runtime inode'
cmp "$repo/scripts/status.sh" "$project/.agent/scripts/status.sh" || fail 'runtime refresh failed'
cmp "$project/.agent/scripts/checks.sh" "$scratch/original/scripts/checks.sh" || fail 'same-version refresh replaced driver'
printf 'install-v63: fresh install, 6.2 migration, customization preservation, and atomic runtime refresh passed\n'
