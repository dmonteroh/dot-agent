#!/usr/bin/env bash
# A shared node: a worker checkout whose .agent is a symlink to the node of
# another checkout of the same repository. The record writers write that node
# under its locks, absorb.sh reports shared and merges nothing, every other
# symlinked .agent is refused, and a writer waits for a held lock.
set -eu
unset CDPATH
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/shared-node-v63.XXXXXX")
scratch=$(cd "$scratch" && pwd -P)
trap 'rm -rf "$scratch"' EXIT
fail() { echo "FAIL shared-node-v63: $*" >&2; exit 1; }

# The main checkout: an ignore-all node, so a worktree holds no .agent of its
# own, which is the layout an orchestrator links the node into.
main="$scratch/main"
mkdir -p "$main"
git -C "$main" init -q
git -C "$main" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
bash "$repo/scripts/node.sh" init --preset software-development --mode ignore-all --indexes generated --hooks none "$main" >/dev/null
bash "$main/.agent/scripts/index.sh" ensure --root "$main" >/dev/null 2>&1
main_node=$(cd "$main/.agent" && pwd -P)
scripts="$main/.agent/scripts"

worktree() { # name — a linked worktree of main whose .agent links to main's node
  git -C "$main" worktree add -q "$scratch/$1" -b "$1"
  [ ! -e "$scratch/$1/.agent" ] || fail "the worktree $1 carries its own .agent"
  ln -s "$main_node" "$scratch/$1/.agent"
}

# Resolution
worktree wt
wt="$scratch/wt"
# shellcheck source=../runtime.sh
. "$scripts/runtime.sh"
[ "$(da_node_dir "$wt")" = "$main_node" ] || fail 'da_node_dir did not resolve the link to the main node'
da_node_shared "$wt" || fail 'da_node_shared did not recognise the linked worktree'
! da_node_shared "$main" || fail 'da_node_shared called the main checkout shared'
[ "$(da_state_dir "$wt")" = "$main_node/.state" ] || fail 'the linked worktree did not get the main node state directory'

# The writers write the main node through the link
bash "$wt/.agent/scripts/log.sh" --tool wt --area svc --summary 'Linked worker logged an outcome' --verify n/a "$wt" >/dev/null \
  || fail 'log.sh refused the linked worktree'
grep -qF '(wt) Linked worker logged an outcome' "$main/.agent/session-log.md" || fail 'the log entry did not reach the main node'
bash "$wt/.agent/scripts/memory.sh" new --slug shared-fact --title 'Shared fact' --hook 'shared node' \
  --fact 'The linked worker wrote this fact.' "$wt" >/dev/null || fail 'memory.sh refused the linked worktree'
[ -f "$main/.agent/memory/shared-fact.md" ] || fail 'the fact file did not reach the main node'
grep -qF '(memory/shared-fact.md)' "$main/.agent/memory.md" || fail 'the memory index line did not reach the main node'
printf -- '- [2026-11-09] Run the smoke test before a handoff. Trigger: shared node work.\n' \
  | bash "$wt/.agent/scripts/learn.sh" new --file - "$wt" >/dev/null || fail 'learn.sh refused the linked worktree'
grep -rqF 'Run the smoke test before a handoff' "$main/.agent/rules/learned" || fail 'the learned rule did not reach the main node'
bash "$wt/.agent/scripts/memory.sh" lookup --query 'linked worker' "$wt" >/dev/null || fail 'memory.sh lookup refused the linked worktree'
bash "$wt/.agent/scripts/status.sh" --load "$wt" | grep -qF '==== .agent/purpose.md ====' || fail 'status.sh --load did not read the node through the link'
for left in "$main_node/.state"/*.lock; do [ ! -e "$left" ] || fail "a writer left a lock behind in the shared state directory: ${left##*/}"; done

# absorb.sh: nothing to mark or merge for a shared node
out=$(bash "$scripts/absorb.sh" mark "$wt") || fail "mark exited $? on a linked worktree"
[ "$out" = "shared	$main_node" ] || fail "mark did not report the shared node: $out"
[ ! -e "$main_node/.state/absorb-base.tsv" ] || fail 'mark recorded a base for a shared node'
out=$(bash "$scripts/absorb.sh" records --from "$wt" "$main") || fail "records exited $? on a linked worktree"
[ "$out" = "shared	$main_node" ] || fail "records did not report the shared node: $out"
out=$(bash "$scripts/absorb.sh" docs --from "$wt" "$main") || fail "docs exited $? on a linked worktree"
[ "$out" = "shared	$main_node" ] || fail "docs did not report the shared node: $out"

# absorb.sh run from a linked checkout merges a copied worker into the main node
cp -R "$main" "$scratch/copy"
rm -rf "$scratch/copy/.agent/.state"
bash "$scratch/copy/.agent/scripts/absorb.sh" mark "$scratch/copy" >/dev/null || fail 'mark failed in the copied worker'
bash "$scratch/copy/.agent/scripts/log.sh" --tool copy --area svc --summary 'Copied worker logged an outcome' --verify n/a "$scratch/copy" >/dev/null
out=$(bash "$wt/.agent/scripts/absorb.sh" records --from "$scratch/copy" "$wt") || fail "records exited $? when run from the linked checkout"
printf '%s\n' "$out" | grep -qxF 'applied	session-log.md' || fail "records run from the linked checkout did not apply the log: $out"
grep -qF '(copy) Copied worker logged an outcome' "$main/.agent/session-log.md" || fail 'the copied worker entry did not reach the main node'

# Refusals: a link that is not a shared node
refused() { # label, root — the node does not resolve, and log.sh refuses and writes nothing
  if (da_node_dir "$2" >/dev/null 2>"$scratch/err"); then fail "da_node_dir accepted $1"; fi
  grep -q 'refusing symlink .agent directory' "$scratch/err" || fail "da_node_dir refused $1 without naming the link: $(cat "$scratch/err")"
  before=$(cat "$main/.agent/session-log.md")
  if bash "$scripts/log.sh" --tool x --area svc --summary 'Must not land' --verify n/a "$2" >/dev/null 2>&1; then
    fail "log.sh accepted $1"
  fi
  [ "$before" = "$(cat "$main/.agent/session-log.md")" ] || fail "log.sh wrote the main node for $1"
}
mkdir -p "$scratch/plain/.agent" "$scratch/notnode"
git -C "$main" worktree add -q "$scratch/wt-dir" -b wt-dir
ln -s "$scratch/notnode" "$scratch/wt-dir/.agent"
refused 'a link to a directory not named .agent' "$scratch/wt-dir"
git -C "$main" worktree add -q "$scratch/wt-bare" -b wt-bare
ln -s "$scratch/plain/.agent" "$scratch/wt-bare/.agent"
refused 'a link to a .agent directory with no manifest' "$scratch/wt-bare"
other="$scratch/other"
mkdir -p "$other"
git -C "$other" init -q
bash "$repo/scripts/node.sh" init --preset software-development --mode ignore-all --hooks none "$other" >/dev/null
git -C "$main" worktree add -q "$scratch/wt-other" -b wt-other
ln -s "$other/.agent" "$scratch/wt-other/.agent"
refused 'a link to a node in another repository' "$scratch/wt-other"
grep -qF 'Must not land' "$other/.agent/session-log.md" && fail 'log.sh wrote the other repository node'
mkdir -p "$scratch/nogit"
ln -s "$main_node" "$scratch/nogit/.agent"
refused 'a link from a root that is not a Git checkout' "$scratch/nogit"

# A reader sees the linked node as the node: links.sh audits the same files
# from the worktree as from the main checkout
links_main=$(bash "$scripts/links.sh" "$main" 2>&1)
links_wt=$(bash "$scripts/links.sh" "$wt" 2>&1)
case "$links_wt" in *'no markdown files to audit'*) fail 'links.sh found no files through the linked node' ;; esac
[ "$links_wt" = "$links_main" ] || fail 'links.sh reported differently from the linked worktree'

# A writer waits for a held lock, and a zero wait refuses at once
lock="$main_node/.state/checkpoint.lock"
mkdir "$lock"
sh -c 'echo $$ >"$1/owner"; sleep 1; rm -f "$1/owner"; rmdir "$1"' sh "$lock" &
holder=$!
start=$(date +%s)
bash "$wt/.agent/scripts/log.sh" --tool wt --area svc --summary 'Waited for the lock' --verify n/a "$wt" >/dev/null \
  || { kill "$holder" 2>/dev/null; fail 'log.sh did not wait for a lock released within the wait'; }
wait "$holder" 2>/dev/null || true
[ $(( $(date +%s) - start )) -lt 10 ] || fail 'log.sh waited longer than the released lock required'
grep -qF 'Waited for the lock' "$main/.agent/session-log.md" || fail 'the entry written after the wait did not land'
mkdir "$lock"
sleep 60 &
holder=$!
printf '%s\n' "$holder" >"$lock/owner"
start=$(date +%s)
if DA_LOCK_WAIT_SECONDS=0 bash "$wt/.agent/scripts/log.sh" --tool wt --area svc --summary 'Must wait forever' --verify n/a "$wt" >/dev/null 2>&1; then
  kill "$holder" 2>/dev/null; fail 'log.sh wrote while a live writer held the lock'
fi
[ $(( $(date +%s) - start )) -lt 5 ] || { kill "$holder" 2>/dev/null; fail 'a zero wait still waited'; }
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null || true
rm -f "$lock/owner"; rmdir "$lock"

# A lock directory left with no owner file: a zero wait refuses and leaves it,
# and a whole wait ends by taking it
mem_lock="$main_node/.state/memory.lock"
mkdir "$mem_lock"
if DA_LOCK_WAIT_SECONDS=0 bash "$scripts/memory.sh" new --slug ownerless-zero --title 'Ownerless zero' --hook 'lock test' --fact 'Refused.' "$main" >/dev/null 2>&1; then
  fail 'a zero wait took a lock with no owner'
fi
[ -d "$mem_lock" ] || fail 'a zero wait removed a lock with no owner'
DA_LOCK_WAIT_SECONDS=1 bash "$scripts/memory.sh" new --slug ownerless-wait --title 'Ownerless wait' --hook 'lock test' --fact 'Written.' "$main" >/dev/null 2>"$scratch/ownerless.err" \
  || fail 'memory.sh did not take a lock left with no owner'
grep -qF 'took a lock left with no owner' "$scratch/ownerless.err" || fail 'taking a lock left with no owner was not reported'
[ -f "$main_node/memory/ownerless-wait.md" ] || fail 'the fact written after the recovery did not land'
[ ! -e "$mem_lock" ] || fail 'the lock taken from an ownerless directory was not released'

# A lock that names a live owner through the whole wait is not removed
mkdir "$mem_lock"
sleep 60 &
holder=$!
printf '%s\n' "$holder" >"$mem_lock/owner"
if DA_LOCK_WAIT_SECONDS=1 bash "$scripts/memory.sh" new --slug owned-wait --title 'Owned wait' --hook 'lock test' --fact 'Refused.' "$main" >/dev/null 2>&1; then
  kill "$holder" 2>/dev/null; fail 'memory.sh wrote while a live writer held the lock'
fi
[ "$(cat "$mem_lock/owner" 2>/dev/null)" = "$holder" ] || { kill "$holder" 2>/dev/null; fail 'a live writer lost its lock'; }
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null || true
rm -f "$mem_lock/owner"; rmdir "$mem_lock"

# learn.sh recovers a lock whose writer is dead, as the other record writers do
learn_lock="$main_node/rules/learned/.learn-writer.lock"
mkdir -p "$learn_lock"
sh -c 'exit 0' &
dead=$!
wait "$dead" 2>/dev/null || true
printf '%s\n' "$dead" >"$learn_lock/owner"
printf '%s\n' '- [2026-09-27] Recover a writer lock whose owner is dead. Trigger: lock test.' \
  | bash "$scripts/learn.sh" new --file - "$main" >"$scratch/learn.out" 2>&1 \
  || fail "learn.sh did not recover a dead writer's lock: $(cat "$scratch/learn.out")"
[ ! -e "$learn_lock" ] || fail 'learn.sh left its writer lock behind'

echo 'shared-node-v63: ok'
