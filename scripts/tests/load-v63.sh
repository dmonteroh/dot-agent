#!/usr/bin/env bash
# status.sh --load: files before the log tail, a PAYLOAD: count of every byte
# written, the HOOK: advisory, --tail, the hook's --tail 0 retry, the
# MEMORY_INDEX_BYTES advisory, and the generated-mode page list.
set -eu
unset CDPATH
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/load-v63.XXXXXX")
scratch=$(cd "$scratch" && pwd -P)
trap 'rm -rf "$scratch"' EXIT
fail() { echo "FAIL load-v63: $*" >&2; exit 1; }

mknode() { # $1 dir  $2 indexes  [$3 hooks]
  mkdir -p "$1"
  git -C "$1" init -q
  bash "$repo/scripts/node.sh" init --preset software-development --mode track-all \
    --indexes "$2" --hooks "${3:-session-start}" "$1" >/dev/null 2>&1
}
add_entries() { # $1 dir  $2 count
  local i
  for i in $(seq 1 "$2"); do
    printf -- '- [2026-11-09] claude | load | entry %s pads the session log with a few more words\n' "$i" >>"$1/.agent/session-log.md"
  done
}
reported() { sed -nE 's/^PAYLOAD: [^0-9]*([0-9]+) bytes.*/\1/p' "$1"; }
first_line() { grep -n -m1 -E "$2" "$1" | cut -d: -f1; }

for indexes in manual generated; do
  n="$scratch/$indexes"
  mknode "$n" "$indexes"
  add_entries "$n" 30
  # Lower than either fixture's output, so both carry a HOOK: line to count.
  printf 'HOOK_MAX_BYTES=4000\n' >>"$n/.agent/scripts/status.conf"
  [ "$indexes" = manual ] || bash "$n/.agent/scripts/index.sh" ensure --root "$n" >/dev/null 2>&1
  out="$scratch/$indexes.out"
  (cd "$n" && bash .agent/scripts/status.sh --load) >"$out"

  # The files come before the log tail, and the tail is last.
  marker=$(first_line "$out" '^==== ')
  entry=$(first_line "$out" '^- \[')
  [ -n "$marker" ] && [ -n "$entry" ] && [ "$marker" -lt "$entry" ] \
    || fail "$indexes: the first marker (line $marker) does not precede the first log entry (line $entry)"
  [ "$(grep '^==== ' "$out" | tail -n 1)" = '==== .agent/session-log.md, newest 25 entries ====' ] \
    || fail "$indexes: the log tail is not the last section"
  [ "$(tail -n 1 "$out")" = "$(grep '^- \[' "$n/.agent/session-log.md" | tail -n 1)" ] \
    || fail "$indexes: the output does not end on the newest log entry"

  # PAYLOAD: is the byte count of the whole output, HOOK: line included.
  grep -q '^HOOK: ' "$out" || fail "$indexes: an output over the hook limit printed no HOOK: line"
  [ "$(reported "$out")" = "$(wc -c <"$out" | tr -d '[:space:]')" ] \
    || fail "$indexes: PAYLOAD: says $(reported "$out") bytes, the output is $(wc -c <"$out" | tr -d '[:space:]')"
  sum=$(sed -nE 's/^PAYLOAD: .*\((.*)\)$/\1/p' "$out" | tr ',' '\n' | awk '{ s += $2 } END { print s }')
  [ "$sum" = "$(reported "$out")" ] || fail "$indexes: PAYLOAD: parts sum to $sum, not the total"
  (cd "$n" && bash .agent/scripts/status.sh) >"$scratch/$indexes.plain"
  [ "$(reported "$scratch/$indexes.plain")" = "$(reported "$out")" ] \
    || fail "$indexes: the plain run predicts a different --load size"

  # --tail 0 leaves the tail out and still counts exactly.
  (cd "$n" && bash .agent/scripts/status.sh --load --tail 0) >"$scratch/$indexes.t0"
  ! grep -q '^- \[' "$scratch/$indexes.t0" || fail "$indexes: --tail 0 printed log entries"
  [ "$(reported "$scratch/$indexes.t0")" = "$(wc -c <"$scratch/$indexes.t0" | tr -d '[:space:]')" ] \
    || fail "$indexes: --tail 0 PAYLOAD: is not the output's size"
  (cd "$n" && bash .agent/scripts/status.sh --load --tail 3) | grep -qF '==== .agent/session-log.md, newest 3 entries ====' \
    || fail "$indexes: --tail 3 did not print three entries"
  ! (cd "$n" && bash .agent/scripts/status.sh --load --tail x) 2>/dev/null || fail "$indexes: --tail x was accepted"
done

# A small node prints no HOOK: line; a node whose hook is off prints none.
s="$scratch/small"
mknode "$s" generated
bash "$s/.agent/scripts/index.sh" ensure --root "$s" >/dev/null 2>&1
(cd "$s" && bash .agent/scripts/status.sh --load) >"$scratch/small.out"
! grep -q '^HOOK: ' "$scratch/small.out" || fail 'a node under the hook limit printed a HOOK: line'
[ "$(reported "$scratch/small.out")" = "$(wc -c <"$scratch/small.out" | tr -d '[:space:]')" ] || fail 'small node PAYLOAD: is not exact'
off="$scratch/off"
mknode "$off" manual none
add_entries "$off" 30
! (cd "$off" && bash .agent/scripts/status.sh --load) | grep -q '^HOOK: ' || fail 'hooks: none still printed a HOOK: line'

# Against the hook itself: HOOK: appears exactly when the hook
# cannot deliver the full output, and names the --tail 0 retry when it fits.
r="$scratch/retry"
mknode "$r" generated
bash "$r/.agent/scripts/index.sh" ensure --root "$r" >/dev/null 2>&1
add_entries "$r" 25
full=$(cd "$r" && bash .agent/scripts/status.sh --load --tail 0 | wc -c | tr -d '[:space:]')
header0=$(bash "$r/.agent/scripts/session-start.sh" --header tail0 | wc -c | tr -d '[:space:]')
limit=$((full + header0 + 10))
printf 'HOOK_MAX_BYTES=%s\n' "$limit" >>"$r/.agent/scripts/status.conf"
(cd "$r" && bash .agent/scripts/status.sh --load) >"$scratch/retry.out"
grep -q '^HOOK: .*delivers it without the session-log tail' "$scratch/retry.out" \
  || fail "the HOOK: line does not name the --tail 0 delivery: $(grep '^HOOK:' "$scratch/retry.out")"
hook_out=$(bash "$r/.agent/scripts/session-start.sh" --max-bytes "$limit")
printf '%s\n' "$hook_out" | head -n 1 | grep -qF '`bash .agent/scripts/status.sh --load --tail 0`' \
  || fail "the hook did not deliver the --tail 0 output: $(printf '%s\n' "$hook_out" | head -n 1)"
printf '%s\n' "$hook_out" | grep -qF '==== .agent/memory.md ====' || fail 'the retried hook output lost the files'
! printf '%s\n' "$hook_out" | grep -q '^- \[' || fail 'the retried hook output kept log entries'
[ "$(bash "$r/.agent/scripts/session-start.sh" --max-bytes "$limit" | wc -c | tr -d '[:space:]')" -le "$limit" ] \
  || fail 'the retried hook output passes its own limit'
printf 'HOOK_MAX_BYTES=%s\n' 100000 >"$scratch/conf" && cat "$r/.agent/scripts/status.conf" | grep -v '^HOOK_MAX_BYTES=' >>"$scratch/conf"
cp "$scratch/conf" "$r/.agent/scripts/status.conf"
! (cd "$r" && bash .agent/scripts/status.sh --load) | grep -q '^HOOK: ' || fail 'a raised HOOK_MAX_BYTES still printed HOOK:'
bash "$r/.agent/scripts/session-start.sh" --max-bytes 100000 | head -n 1 | grep -qF 'the output of `bash .agent/scripts/status.sh --load` for' \
  || fail 'a node under the limit did not get the full output'
small_limit=$((header0 + 20))
pointer=$(bash "$r/.agent/scripts/session-start.sh" --max-bytes "$small_limit")
[ "$(printf '%s\n' "$pointer" | wc -l | tr -d '[:space:]')" = 1 ] || fail 'a node over the limit without its tail got more than the pointer line'
printf '%s\n' "$pointer" | grep -qF 'even without the session-log tail' || fail "pointer line wrong: $pointer"

# MEMORY_INDEX_BYTES is half of HOOK_MAX_BYTES unless pinned.
m="$scratch/memory"
mknode "$m" manual
python3 -I -c 'import sys; open(sys.argv[1], "a").write("".join("- [Fact %d](memory/fact-%d.md) - a hook long enough to make the index heavy\n" % (i, i) for i in range(80)))' "$m/.agent/memory.md"
mb=$(wc -c <"$m/.agent/memory.md" | tr -d '[:space:]')
[ "$mb" -gt 5000 ] || fail "fixture memory.md is only $mb bytes"
(cd "$m" && bash .agent/scripts/status.sh --format tsv) | grep -q $'^advisory\tMEMORY_INDEX_BYTES_OVERSIZE\tmemory.md\t' \
  || fail 'a memory.md over 5000 bytes drew no MEMORY_INDEX_BYTES_OVERSIZE'
printf 'HOOK_MAX_BYTES=%s\n' $((mb * 2 + 2)) >>"$m/.agent/scripts/status.conf"
! (cd "$m" && bash .agent/scripts/status.sh --format tsv) | grep -q 'MEMORY_INDEX_BYTES_OVERSIZE' \
  || fail 'MEMORY_INDEX_BYTES did not follow a raised HOOK_MAX_BYTES'
printf 'MEMORY_INDEX_BYTES=100\n' >>"$m/.agent/scripts/status.conf"
(cd "$m" && bash .agent/scripts/status.sh --format tsv) | grep -q 'MEMORY_INDEX_BYTES_OVERSIZE' \
  || fail 'a pinned MEMORY_INDEX_BYTES did not win over the derived value'
[ "$(sed -n 's/^MEMORY_INDEX_BYTES=//p' "$repo/scripts/status.sh")" = $(( $(sed -n 's/^HOOK_MAX_BYTES=//p' "$repo/scripts/status.sh") / 2 )) ] \
  || fail "status.sh's shown MEMORY_INDEX_BYTES is not half its HOOK_MAX_BYTES"
claude_limit=$(grep -o -- '--max-bytes [0-9]*' "$repo/tools/hooks/install.sh" | sort -u)
[ "$claude_limit" = "--max-bytes $(sed -n 's/^HOOK_MAX_BYTES=//p' "$repo/scripts/status.sh")" ] \
  || fail "HOOK_MAX_BYTES differs from the installed hook's limit ($claude_limit)"

# A fresh cache lists the entry file's pages, a stale one names the
# canonical paths, and neither run writes anything.
g="$scratch/pages"
mknode "$g" generated
mkdir -p "$g/.agent/docs"
printf '# Billing\n<!-- Read when: billing work -->\nBody.\n' >"$g/.agent/docs/billing.md"
bash "$g/.agent/scripts/index.sh" ensure --root "$g" >/dev/null 2>&1
snapshot() { (cd "$g" && find . -path ./.git -prune -o -print | sort | while IFS= read -r p; do
  if [ -f "$p" ]; then printf '%s %s\n' "$p" "$(git hash-object --no-filters -- "$p")"; else printf '%s\n' "$p"; fi
done); }
snapshot >"$scratch/before"
(cd "$g" && bash .agent/scripts/status.sh --load) >"$scratch/fresh.out"
snapshot | cmp -s - "$scratch/before" || fail 'a fresh-cache --load wrote under the node'
want=$(sed -n '/^READ: /p' "$g/.agent/indexes/current.md")
[ -n "$want" ] || fail 'fixture entry file lists no page'
[ "$(sed -n '/^READ: /p' "$scratch/fresh.out")" = "$want" ] || fail 'a fresh-cache --load does not list the entry file pages'
grep -q '^READ: .agent/indexes/gen\..*/routes-1.md$' "$scratch/fresh.out" || fail 'the page list has no routes page'
! grep -qF 'is stale or missing' "$scratch/fresh.out" || fail 'a fresh cache printed the stale fallback'
printf '# New rule\n\nStale now.\n' >"$g/.agent/rules/new.md"
snapshot >"$scratch/before"
(cd "$g" && bash .agent/scripts/status.sh --load) >"$scratch/stale.out"
snapshot | cmp -s - "$scratch/before" || fail 'a stale-cache --load wrote under the node'
grep -qF 'read .agent/rules/ and .agent/docs/architecture.md directly' "$scratch/stale.out" || fail 'a stale cache does not name the canonical paths'
! grep -q '^READ: ' "$scratch/stale.out" || fail 'a stale cache still listed pages'
[ "$(bash "$g/.agent/scripts/index.sh" check --root "$g" 2>/dev/null || true)" = STALE ] || fail '--load rebuilt the stale cache'
# The stale line tells the session how to get the pages back, and what it
# names works: ensure prints a file whose READ: lines are the pages
grep -qF 'bash .agent/scripts/index.sh ensure' "$scratch/stale.out" || fail 'a stale cache does not tell the session to rebuild it'
grep -qF 'A subagent never runs it' "$scratch/stale.out" || fail 'the stale line does not keep ensure from a subagent'
entry=$(cd "$g" && bash .agent/scripts/index.sh ensure 2>/dev/null) || fail 'ensure failed on the stale fixture'
grep -q '^READ: ' "$entry" || fail 'the file ensure prints lists no page'

echo "ok load-v63"
