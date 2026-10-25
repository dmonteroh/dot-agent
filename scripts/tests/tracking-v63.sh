#!/usr/bin/env bash
set -eu
unset CDPATH
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/tracking-v63.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
fail() { echo "FAIL tracking-v63: $*" >&2; exit 1; }
root="$scratch/ignored node"
mkdir -p "$root/src"
bash "$repo/scripts/node.sh" init --preset software-development --mode ignore-all "$root" >/dev/null
contract="$root/.agents/rules/contract.md"
awk '/^## Quality bar/{q=1} q && /^## / && !/^## Quality bar/{q=0} q' "$contract" >"$root/.agents/rules/quality-bar.md"
awk '/^## Quality bar/{q=1} q && /^## / && !/^## Quality bar/{q=0} !q' "$contract" >"$scratch/contract"
sed 's/^\(- [A-Za-z][^:]*:\) <.*>$/\1 configured/' "$scratch/contract" >"$contract"
printf '#!/usr/bin/env bash\nprintf "1..1\\nok 1 - fixture\\n"\n' >"$root/.agents/scripts/checks.sh"
printf 'export const value = 1\n' >"$root/src/input.ts"
git -C "$root" init -q
git -C "$root" add .
git -C "$root" -c user.name=fixture -c user.email=fixture@local -c commit.gpgsign=false commit -qm fixture
verify="$root/.agents/scripts/verify.sh"
fresh_receipt() { bash "$verify" run test --root "$root" 2>"$scratch/verify.err" | cut -f2; }
receipt=$(fresh_receipt)
printf '# changed driver\n' >>"$root/.agents/scripts/checks.sh"
if bash "$verify" check "$receipt" --root "$root" >/dev/null 2>&1; then fail 'ignored driver change did not stale receipt'; fi
receipt=$(fresh_receipt)
printf 'TIMEOUT_SECONDS=40\n' >>"$root/.agents/scripts/verify.conf"
if bash "$verify" check "$receipt" --root "$root" >/dev/null 2>&1; then fail 'ignored configuration change did not stale receipt'; fi
receipt=$(fresh_receipt)
printf '\n- [2026-09-27] Preserve local boundaries.\n' >>"$root/.agents/rules/learned.md"
if bash "$verify" check "$receipt" --root "$root" >/dev/null 2>&1; then fail 'manual learned source was excluded'; fi
bash "$root/.agents/scripts/memory.sh" new --slug timezone --title Timezone --hook 'scheduling calls' --fact 'The project uses UTC.' "$root" >/dev/null
checkpoint() {
  bash "$root/.agents/scripts/checkpoint.sh" --node-only --tool test --area memory --verify n/a --summary 'Updated durable project context' "$root" >"$scratch/out" 2>"$scratch/err"
}
checkpoint || { cat "$scratch/err" >&2; fail 'ignored node write could not be logged'; }
checkpoint || fail 'ignored-node retry failed'
[ "$(grep -c '^- \[' "$root/.agents/session-log.md")" -eq 1 ] || fail 'ignored-node retry duplicated entry'
bash "$root/.agents/scripts/memory.sh" supersede --slug timezone --fact 'The project uses Europe/Helsinki.' "$root" >/dev/null
checkpoint || fail 'second ignored-node write failed'
[ "$(grep -c '^- \[' "$root/.agents/session-log.md")" -eq 2 ] || fail 'second ignored-node write was skipped'
printf 'export const value = 2\n' >"$root/src/input.ts"
if checkpoint; then fail 'node-only mode skipped product review'; fi

non_git="$scratch/future git"
mkdir -p "$non_git"
bash "$repo/scripts/node.sh" init --preset domain-knowledge --mode track-all "$non_git" >/dev/null
# shellcheck source=../runtime.sh
. "$repo/scripts/runtime.sh"
state=$(da_state_dir "$non_git")
printf 'private receipt\n' >"$state/private"
git -C "$non_git" init -q
if git -C "$non_git" status --porcelain --untracked-files=all | grep -q '\.agents/\.state/'; then
  fail 'non-Git state became trackable after Git initialization'
fi
printf 'tracking-v63: ignored inputs, node-only logging, and private state boundaries passed\n'
