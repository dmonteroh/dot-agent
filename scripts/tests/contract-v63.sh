#!/usr/bin/env bash
# The worker-load contract page and node.sh describe: the page is linked and
# vendor-neutral, describe prints KEY=value read from the node, and both
# name the same commands.
set -eu
[ -z "${DA_PROVE:-}" ] || set +e
unset CDPATH
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/contract-v63.XXXXXX")
scratch=$(cd "$scratch" && pwd -P)
trap 'rm -rf "$scratch"' EXIT
fail() { echo "FAIL contract-v63: $*" >&2; [ -n "${DA_PROVE:-}" ] || exit 1; proved_failures=1; }
page="$repo/scripts/docs/worker-contract.md"

# The page is cited where a reader looks for it, and its own links resolve.
grep -qF '(worker-contract.md)' "$repo/scripts/docs/README.md" || fail 'scripts/docs/README.md does not link the contract'
grep -qF '(scripts/docs/worker-contract.md)' "$repo/operating-model.md" || fail "the operating model's subagents section does not link the contract"
grep -qF '(worker-contract.md#worker-checkouts-and-versions)' "$repo/scripts/docs/absorb.md" || fail 'absorb.md does not point its version rule at the contract'
while IFS= read -r target; do
  target=${target%%#*}
  [ -n "$target" ] || continue
  [ -e "$repo/scripts/docs/$target" ] || fail "the contract links $target, which does not exist"
done < <(grep -oE '\]\([^)]+\)' "$page" | sed -E 's/^\]\(//; s/\)$//' | grep -v '^https\?:')
! grep -inE 'claude|cursor|copilot|codex|anthropic|openai|sonnet|opus|haiku|gpt-|agents\.md' "$page" \
  || fail 'the contract names a vendor or a tool'

# The page's command block.
block=$(awk '/^```worker-commands$/ { inb = 1; next } inb && /^```$/ { exit } inb' "$page")
page_run=$(printf '%s\n' "$block" | sed -n 's/^WORKER_MAY_RUN=//p')
page_orch=$(printf '%s\n' "$block" | sed -n 's/^ORCHESTRATOR_ONLY=//p')
[ -n "$page_run" ] && [ -n "$page_orch" ] || fail 'the contract page has no worker-commands block'

n="$scratch/node"
mkdir -p "$n"
git -C "$n" init -q
bash "$repo/scripts/node.sh" init --preset software-development --mode track-all --indexes generated "$n" >/dev/null 2>&1
out=$(bash "$repo/scripts/node.sh" describe "$n")
printf '%s\n' "$out" | grep -vqE '^[A-Z_]+=' && fail "describe printed a line that is not KEY=value: $(printf '%s\n' "$out" | grep -vE '^[A-Z_]+=' | head -n 1)"
[ "$(printf '%s\n' "$out" | cut -d= -f1 | sort | uniq -d)" = '' ] || fail 'describe printed a key twice'
get() { printf '%s\n' "$out" | sed -n "s/^$1=//p"; }
[ "$(get ROOT)" = "$n" ] || fail "ROOT is $(get ROOT)"
[ "$(get VERSION)" = "$(sed -n 's/^TARGET_VERSION="\(.*\)"$/\1/p' "$repo/scripts/node.sh")" ] || fail "VERSION is $(get VERSION)"
[ "$(get PRESET)" = software-development ] && [ "$(get MODE)" = track-all ] && [ "$(get INDEXES)" = generated ] && [ "$(get HOOKS)" = session-start ] \
  || fail 'describe misread the manifest'
[ "$(get WORKER_CONTRACT)" = "$(sed -n 's/^WORKER_CONTRACT=//p' "$repo/scripts/status.sh")" ] || fail "WORKER_CONTRACT is $(get WORKER_CONTRACT)"
[ "$(get BOOTSTRAP)" = 'bash .agent/scripts/status.sh --load --tail 0' ] || fail "BOOTSTRAP is $(get BOOTSTRAP)"
[ "$(get WORKER_MAY_RUN)" = "$page_run" ] || fail "WORKER_MAY_RUN differs from the page: $(get WORKER_MAY_RUN)"
[ "$(get ORCHESTRATOR_ONLY)" = "$page_orch" ] || fail "ORCHESTRATOR_ONLY differs from the page: $(get ORCHESTRATOR_ONLY)"
for helper in status.sh links.sh comments.sh review.sh verify.sh index.sh log.sh memory.sh learn.sh docs.sh checkpoint.sh absorb.sh; do
  awk '/^## Exit codes$/ { on = 1; next } /^## / { on = 0 } on && /^\|/' "$page" | grep -qF "\`$helper" || fail "the exit-code table leaves out $helper"
done
for template in "$repo"/templates/entry-point*.md; do
  grep -qF 'Write `.agent/` only through its scripts, lessons only.' "$template" || fail "${template##*/} does not limit a subagent's writes to lessons"
  grep -qF -- '--summary "<task and outcome, ≤25 words, no paths or ids>"' "$template" || fail "${template##*/} does not state both summary limits"
done
grep -qF 'and so are `checkpoint.sh` and `index.sh ensure`' "$repo/templates/entry-point-generated.md" \
  || fail "the generated entry point does not name index.sh ensure as the orchestrator's"
[ -z "$(get MIGRATION_TARGET)" ] || fail 'a finalized node reports a migration target'

# Read from the node: a missing helper leaves its commands out, an older
# status.sh reports contract 0, and a pending migration is named.
rm "$n/.agent/scripts/absorb.sh"
sed '/^WORKER_CONTRACT=/d' "$n/.agent/scripts/status.sh" >"$scratch/status.sh" && cp "$scratch/status.sh" "$n/.agent/scripts/status.sh"
printf '  migration_target: "9.9"\n' >"$scratch/target"
awk -v f="$scratch/target" 'NR == 2 { while ((getline l < f) > 0) print l } { print }' "$n/.agent/purpose.md" >"$scratch/purpose" \
  && cp "$scratch/purpose" "$n/.agent/purpose.md"
out=$(bash "$repo/scripts/node.sh" describe "$n")
[ "$(get ORCHESTRATOR_ONLY)" = 'checkpoint.sh, index.sh ensure' ] || fail "a missing absorb.sh is still listed: $(get ORCHESTRATOR_ONLY)"
[ "$(get WORKER_CONTRACT)" = 0 ] || fail 'a status.sh without WORKER_CONTRACT does not report 0'
printf 'case "$1" in --load) ;; esac\n' >"$n/.agent/scripts/status.sh"
[ "$(bash "$repo/scripts/node.sh" describe "$n" | sed -n 's/^BOOTSTRAP=//p')" = 'bash .agent/scripts/status.sh --load' ] || fail 'a status.sh with no --tail is given the flag'
[ "$(get MIGRATION_TARGET)" = 9.9 ] || fail "a pending migration is not named: $(get MIGRATION_TARGET)"

# A root node at the home directory names the absolute call.
h="$scratch/home"
mkdir -p "$h"
HOME="$h" bash "$repo/scripts/node.sh" init --preset domain-knowledge --mode track-all --hooks none "$h" >/dev/null 2>&1
[ "$(HOME="$h" bash "$repo/scripts/node.sh" describe "$h" | sed -n 's/^BOOTSTRAP=//p')" = 'bash ~/.agent/scripts/status.sh --load --tail 0 ~' ] \
  || fail 'a root node does not get the root call'
! bash "$repo/scripts/node.sh" describe "$scratch/nowhere" 2>/dev/null || fail 'describe accepted a root with no node'

[ -z "${proved_failures:-}" ] || exit 1
echo "ok contract-v63"
