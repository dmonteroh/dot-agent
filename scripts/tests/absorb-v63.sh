#!/usr/bin/env bash
# absorb.sh: a worker's node merged back into the main node, and the memory
# writer lock that lets workers in one checkout write directly.
set -eu
unset CDPATH
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/absorb-v63.XXXXXX")
scratch=$(cd "$scratch" && pwd -P)
trap 'rm -rf "$scratch"' EXIT
fail() { echo "FAIL absorb-v63: $*" >&2; exit 1; }

main="$scratch/main node"
mkdir -p "$main"
git -C "$main" init -q
bash "$repo/scripts/node.sh" init --preset software-development --mode track-shared --indexes generated "$main" >/dev/null
bash "$main/.agent/scripts/index.sh" ensure --root "$main" >/dev/null 2>&1
printf -- '- [2026-01-01] Keep refunds idempotent. Trigger: refund work.\n' | bash "$main/.agent/scripts/learn.sh" new --file - "$main" >/dev/null
absorb="$main/.agent/scripts/absorb.sh"

worker() { # name — a worker checkout carrying a copy of the main node, marked at dispatch
  cp -R "$main" "$scratch/$1"
  bash "$scratch/$1/.agent/scripts/absorb.sh" mark "$scratch/$1" >/dev/null || fail "mark failed in $1"
}

if bash "$absorb" records --from "$main" "$main" >/dev/null 2>&1; then fail 'absorb accepted the main node as its own worker'; fi
cp -R "$main" "$scratch/unmarked"
if bash "$absorb" records --from "$scratch/unmarked" "$main" >/dev/null 2>&1; then fail 'absorb accepted a worker with no base'; fi

# A worker's experience records and code-coupled writes
worker w1
w1="$scratch/w1"
bash "$w1/.agent/scripts/log.sh" --tool w1 --area svc --summary 'Worker one added retries' --verify n/a "$w1" >/dev/null
bash "$w1/.agent/scripts/memory.sh" new --slug vendor-limit --title 'Vendor limit' --hook 'vendor calls' \
  --fact 'The vendor allows 10 requests per second.' "$w1" >/dev/null
printf -- '- [2026-10-25] Run the contract tests before touching the client. Trigger: worker failure.\n' \
  | bash "$w1/.agent/scripts/learn.sh" new --file - "$w1" >/dev/null
printf '# Client\n<!-- Read when: client -->\nRetries live in src/client.ts.\n' >"$w1/.agent/docs/client.md"

out=$(bash "$absorb" records --from "$w1" "$main") || fail "records exited $? on a clean merge"
for want in 'applied	session-log.md' 'applied	memory.md' 'applied	memory/vendor-limit.md'; do
  printf '%s\n' "$out" | grep -qxF "$want" || fail "records did not report: $want"
done
grep -qF '(w1) Worker one added retries' "$main/.agent/session-log.md" || fail 'the session-log entry did not reach the main node'
grep -qF '(memory/vendor-limit.md)' "$main/.agent/memory.md" || fail 'the memory index line did not reach the main node'
cmp -s "$w1/.agent/memory/vendor-limit.md" "$main/.agent/memory/vendor-limit.md" || fail 'the fact file did not reach the main node'
grep -rqF 'Run the contract tests before touching the client' "$main/.agent/rules/learned" || fail 'the learned rule did not reach the main node'
[ ! -e "$main/.agent/docs/client.md" ] || fail 'records applied a code-coupled write'
grep -qF 'Run the contract tests before touching the client' "$main/.agent/rules/learned.md" || fail 'the generated aggregate was not rebuilt'

out=$(bash "$absorb" records --from "$w1" "$main") || fail 'a second records run failed'
[ -z "$out" ] || fail "a second records run applied something again: $out"

out=$(bash "$absorb" docs --from "$w1" "$main") || fail "docs exited $? on a clean merge"
printf '%s\n' "$out" | grep -qxF 'applied	docs/client.md' || fail 'docs did not apply the new doc'
grep -rqF 'READ: .agent/docs/client.md' "$main/.agent/indexes" || fail 'the index was not rebuilt after a doc merge'

# Conflicts, duplicates, removals, refusals
worker w2
w2="$scratch/w2"
bash "$w2/.agent/scripts/memory.sh" supersede --slug vendor-limit --fact 'The vendor allows 20 requests per second.' "$w2" >/dev/null
bash "$main/.agent/scripts/memory.sh" supersede --slug vendor-limit --fact 'The vendor allows 15 requests per second.' "$main" >/dev/null
{ printf '<!-- rewritten -->\n'; cat "$w2/.agent/session-log.md"; } >"$scratch/log" && cp "$scratch/log" "$w2/.agent/session-log.md"
existing=$(find "$main/.agent/rules/learned" -name '*.md' | head -n 1)
cp "$existing" "$w2/.agent/rules/learned/aaaaaaaaaaaa.md"
if out=$(bash "$absorb" records --from "$w2" "$main"); then fail 'records exited 0 with conflicts'; else rc=$?; fi
[ "$rc" -eq 3 ] || fail "records exited $rc with conflicts, not 3"
printf '%s\n' "$out" | grep -q '^conflict	session-log.md	' || fail 'a rewritten log was not a conflict'
printf '%s\n' "$out" | grep -q '^conflict	memory/vendor-limit.md	' || fail 'a fact changed on both sides was not a conflict'
printf '%s\n' "$out" | grep -qxF 'duplicate	rules/learned/aaaaaaaaaaaa.md' || fail 'an exact duplicate rule was not reported'
grep -qF '15 requests' "$main/.agent/memory/vendor-limit.md" || fail 'a conflict overwrote the main node'
[ ! -e "$main/.agent/rules/learned/aaaaaaaaaaaa.md" ] || fail 'a duplicate rule was applied'
rm "$w2/.agent/memory/vendor-limit.md"
bash "$absorb" records --from "$w2" "$main" 2>/dev/null | grep -q '^not-applied	memory/vendor-limit.md	' || fail 'a removal was not reported'
[ -f "$main/.agent/memory/vendor-limit.md" ] || fail 'a worker removal was applied'

worker w3
sed -i.bak 's/^  version: .*/  version: "6.2"/' "$scratch/w3/.agent/purpose.md" && rm -f "$scratch/w3/.agent/purpose.md.bak"
if bash "$absorb" records --from "$scratch/w3" "$main" >/dev/null 2>&1; then fail 'absorb merged a node of another version'; fi

# memory.sh serializes on the node's memory lock
state="$main/.agent/.state"
mkdir -p "$state/memory.lock"
sleep 60 &
holder=$!
printf '%s\n' "$holder" >"$state/memory.lock/owner"
if bash "$main/.agent/scripts/memory.sh" new --slug locked --title Locked --hook 'lock test' --fact 'Held.' "$main" >/dev/null 2>&1; then
  kill "$holder" 2>/dev/null; fail 'memory.sh wrote while another writer held the lock'
fi
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null || :
[ ! -e "$main/.agent/memory/locked.md" ] || fail 'a refused memory write left a fact file'
bash "$main/.agent/scripts/memory.sh" new --slug unlocked --title Unlocked --hook 'lock test' --fact 'Free.' "$main" >/dev/null \
  || fail 'memory.sh did not recover a lock whose owner died'

# A worker's Checked stamp names a commit in the worker's checkout. An
# integration by cherry-pick gives the main checkout a copy of that commit,
# never the commit itself, so the stamp would read as stale or broken there.
proj="$scratch/stamped"
mkdir -p "$proj/src"
g() { git -C "$proj" "$@"; }
g init -q
g config user.email test@example.invalid
g config user.name test
bash "$repo/scripts/node.sh" init --preset software-development --mode ignore-all --hooks none "$proj" >/dev/null
printf 'export const client = 1;\n' >"$proj/src/client.ts"
printf 'export const other = 1;\n' >"$proj/src/other.ts"
g add -A && g commit -qm base
pabsorb="$proj/.agent/scripts/absorb.sh"
plinks="$proj/.agent/scripts/links.sh"
stamp_in() { sed -n 's/^<!-- Checked: \(.*\) -->$/\1/p' "$1"; }
stamped_worker() { # name, branch — a git worktree of the project carrying a copy of its node, marked at dispatch
  g worktree add -q -b "$2" "$scratch/$1"
  cp -R "$proj/.agent" "$scratch/$1/.agent"
  bash "$scratch/$1/.agent/scripts/absorb.sh" mark "$scratch/$1" >/dev/null || fail "mark failed in $1"
}

stamped_worker sw1 task-1
sw1="$scratch/sw1"
printf 'export const client = 2;\n' >"$sw1/src/client.ts"
git -C "$sw1" commit -qam 'client retries'
bash "$sw1/.agent/scripts/docs.sh" new --name client --read-when 'client retries' "$sw1" >/dev/null
printf '\nRetries live in `src/client.ts`.\n' >>"$sw1/.agent/docs/client.md"
task_commit=$(git -C "$sw1" rev-parse --short HEAD)
[ "$(stamp_in "$sw1/.agent/docs/client.md")" = "$task_commit" ] || fail 'the worker doc was not stamped at the task commit'
printf 'export const other = 2;\n' >"$proj/src/other.ts"
g commit -qam 'other work'
g cherry-pick task-1 >/dev/null
! g merge-base --is-ancestor "$task_commit" HEAD || fail 'the cherry-pick made the task commit an ancestor'

out=$(bash "$pabsorb" docs --from "$sw1" "$proj") || fail "docs exited $? integrating a stamped doc"
links_out=$(bash "$plinks" "$proj")
! printf '%s\n' "$links_out" | grep -q '^STALE: docs/client.md' || fail "links.sh reports the absorbed doc stale: $links_out"
! printf '%s\n' "$links_out" | grep -q 'docs/client.md is stamped at' || fail "links.sh reports the absorbed doc's stamp unknown: $links_out"
[ -z "$(stamp_in "$proj/.agent/docs/client.md")" ] || fail 'the absorbed doc kept a stamp the main checkout does not hold'
printf '%s\n' "$out" | grep -q "^applied	docs/client.md	dropped its Checked stamp $task_commit" \
  || fail "absorb did not report the dropped stamp: $out"
cmp -s <(grep -v '^<!-- Checked: ' "$sw1/.agent/docs/client.md") "$proj/.agent/docs/client.md" \
  || fail 'dropping the stamp changed the rest of the doc'
out=$(bash "$pabsorb" docs --from "$sw1" "$proj") || fail "a second docs run exited $? after a dropped stamp"
[ -z "$out" ] || fail "a second docs run applied something again: $out"
cp "$proj/.agent/docs/client.md" "$scratch/client.absorbed"
cp "$sw1/.agent/docs/client.md" "$proj/.agent/docs/client.md"
out=$(bash "$pabsorb" docs --from "$sw1" "$proj") || fail "docs exited $? over a doc git already carried"
[ -z "$out" ] || fail "docs rewrote a doc the main node already holds as the worker wrote it: $out"
cp "$scratch/client.absorbed" "$proj/.agent/docs/client.md"

# A stamp at a commit the main checkout already holds is kept, and so is the
# drift check it opts the doc into.
stamped_worker sw2 task-2
sw2="$scratch/sw2"
bash "$sw2/.agent/scripts/docs.sh" check --name client "$sw2" >/dev/null
printf '<!-- Read when: legacy billing -->\n<!-- Checked: 0123abc -->\n# Legacy\n\nCalls `src/client.ts`.\n' >"$sw2/.agent/docs/legacy.md"
head_commit=$(g rev-parse --short HEAD)
out=$(bash "$pabsorb" docs --from "$sw2" "$proj") || fail "docs exited $? integrating a doc stamped at an ancestor"
printf '%s\n' "$out" | grep -qxF 'applied	docs/client.md' || fail "a stamp at an ancestor was reported: $out"
[ "$(stamp_in "$proj/.agent/docs/client.md")" = "$head_commit" ] || fail 'a stamp at an ancestor of HEAD was dropped'
printf '%s\n' "$out" | grep -q '^applied	docs/legacy.md	dropped its Checked stamp 0123abc' || fail "a stamp naming no commit was kept: $out"
[ -z "$(stamp_in "$proj/.agent/docs/legacy.md")" ] || fail 'a stamp naming no commit reached the main node'
printf 'export const client = 3;\n' >"$proj/src/client.ts"
g commit -qam 'client change after the check'
bash "$plinks" "$proj" | grep -q "^STALE: docs/client.md cites src/client.ts, changed in 1 commit since checked at $head_commit" \
  || fail 'the kept stamp does not report a later change to the cited code'
exit 0
