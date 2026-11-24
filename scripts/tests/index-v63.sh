#!/usr/bin/env bash
# Two index.sh ensure calls racing on one stale cache: one entry file, one
# complete live generation, a FRESH check afterwards, and a later sweep that
# removes the losing generation.
set -eu
unset CDPATH
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/index-v63.XXXXXX")
scratch=$(cd "$scratch" && pwd -P)
trap 'rm -rf "$scratch"' EXIT
# Past this line a failed command is recorded by fail and the file goes on,
# so one run under verify.sh prove shows every failing assertion.
[ -z "${DA_PROVE:-}" ] || set +e
fail() { echo "FAIL index-v63: $*" >&2; [ -n "${DA_PROVE:-}" ] || exit 1; proved_failures=1; }

n="$scratch/node"
mkdir -p "$n"
git -C "$n" init -q
bash "$repo/scripts/node.sh" init --preset software-development --mode track-all --indexes generated "$n" >/dev/null
idx="$n/.agent/scripts/index.sh"
mkdir -p "$n/.agent/docs"
printf '# Billing\n<!-- Read when: billing work -->\nBody.\n' >"$n/.agent/docs/billing.md"
bash "$idx" ensure --root "$n" >/dev/null 2>&1 || fail 'first ensure failed'
printf '# Extra rule\n\nA new rule makes the cache stale.\n' >"$n/.agent/rules/extra.md"
[ "$(bash "$idx" check --root "$n" 2>/dev/null)" = STALE ] || fail 'the edited cache does not read as STALE'

# Several rounds, because a single pair can finish one after the other.
for round in 1 2 3 4 5; do
  printf 'Round %s.\n' "$round" >>"$n/.agent/rules/extra.md"
  bash "$idx" ensure --root "$n" >"$scratch/a.out" 2>"$scratch/a.err" &
  a=$!
  bash "$idx" ensure --root "$n" >"$scratch/b.out" 2>"$scratch/b.err" &
  b=$!
  wait "$a" || fail "round $round: first concurrent ensure failed: $(cat "$scratch/a.err")"
  wait "$b" || fail "round $round: second concurrent ensure failed: $(cat "$scratch/b.err")"
  [ "$(cat "$scratch/a.out")" = "$n/.agent/indexes/current.md" ] || fail "round $round: first ensure printed $(cat "$scratch/a.out")"
  [ "$(cat "$scratch/b.out")" = "$n/.agent/indexes/current.md" ] || fail "round $round: second ensure printed $(cat "$scratch/b.out")"

  entries=$(find "$n/.agent/indexes" -maxdepth 1 \( -name 'current.md' -o -name '.entry.*' \) | wc -l | tr -d '[:space:]')
  [ "$entries" = 1 ] || fail "round $round: $entries entry files, temporary ones included"
  live=$(sed -n 2p "$n/.agent/indexes/current.md")
  case "$live" in gen.*) ;; *) fail "round $round: entry names no generation: $live" ;; esac
  [ -d "$n/.agent/indexes/$live" ] || fail "round $round: the live generation $live does not exist"
  while IFS= read -r page; do
    [ -s "$n/$page" ] || fail "round $round: the entry lists $page, which is missing or empty"
  done < <(sed -n 's/^READ: //p' "$n/.agent/indexes/current.md")
  grep -rqF "Round $round." "$n/.agent/indexes/$live" || fail "round $round: the live generation misses the round's own edit"
  [ "$(bash "$idx" check --root "$n" 2>/dev/null)" = FRESH ] || fail "round $round: check is not FRESH after the race"
done

# The losers are younger than the sweep age, so they stay until an ensure
# past that age removes everything but the live and the replaced generation.
printf 'Final.\n' >>"$n/.agent/rules/extra.md"
INDEX_CLEANUP_AGE_SECONDS=0 bash "$idx" ensure --root "$n" >/dev/null 2>&1 || fail 'sweeping ensure failed'
gens=$(find "$n/.agent/indexes" -maxdepth 1 -type d -name 'gen.*' | wc -l | tr -d '[:space:]')
[ "$gens" -le 2 ] || fail "$gens generations remain after a sweep at age 0"
[ "$(bash "$idx" check --root "$n" 2>/dev/null)" = FRESH ] || fail 'check is not FRESH after the sweep'

[ -z "${proved_failures:-}" ] || exit 1
echo "ok index-v63"
