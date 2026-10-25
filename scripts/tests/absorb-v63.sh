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
exit 0
