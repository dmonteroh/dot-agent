#!/usr/bin/env bash
# scripts/index-benchmark.sh — measures index.sh's process latency at 100
# and 1,000 canonical-source records, cold and warm cache, on this
# machine, and reports median and p95 real time (not mean/min/max).
#
# Methodology ported from tmp/merge-6.2/spikes/indexes/benchmark.sh: an
# external process timer (/usr/bin/time -p) wraps each invocation,
# repeated REPEATS times per case. Cold removes the cache directory
# before every invocation; warm primes one verified HIT first, then
# times repeated hits. Results: scripts/docs/index-benchmark.md.
#
# Usage: index-benchmark.sh [REPEATS >= 10]
set -Eeuo pipefail
export LC_ALL=C
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
idx="$here/index.sh"
repeats=${1:-15}
[ "$#" -le 1 ] || { printf 'Usage: index-benchmark.sh [REPEATS >= 10]\n' >&2; exit 2; }
case "$repeats" in '' | *[!0-9]*) printf 'Usage: index-benchmark.sh [REPEATS >= 10]\n' >&2; exit 2 ;; esac
[ "$repeats" -ge 10 ] || { printf 'Usage: index-benchmark.sh [REPEATS >= 10]\n' >&2; exit 2; }

scratch=$(mktemp -d "${TMPDIR:-/tmp}/index-bench.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT
trap 'exit 130' INT TERM

# Builds $count records under $fdir/.agent/{rules,docs}, alternating
# record kind, each with a small heading and a two-line body — the same
# per-record shape make_index_fixture uses in scripts/test.sh, just
# generated at scale rather than checked in.
make_fixture() {
  fdir="$1"; count="$2"
  mkdir -p "$fdir/.agent/rules" "$fdir/.agent/docs"
  n=0
  while [ "$n" -lt "$count" ]; do
    if [ $((n % 2)) -eq 0 ]; then
      printf '# Rule %d\nBody line one for record %d.\nBody line two.\n' "$n" "$n" >"$fdir/.agent/rules/r$n.md"
    else
      printf '# Doc %d\n<!-- Read when: record %d -->\nBody text for record %d.\n' "$n" "$n" "$n" >"$fdir/.agent/docs/d$n.md"
    fi
    n=$((n + 1))
  done
}

printf 'records mode n median_s p95_s\n'
for count in 100 1000; do
  project="$scratch/project$count"
  make_fixture "$project" "$count"
  for mode in cold warm; do
    "$idx" ensure --root "$project" >/dev/null 2>"$scratch/diag" || true
    : >"$scratch/samples"
    i=0
    while [ "$i" -lt "$repeats" ]; do
      if [ "$mode" = cold ]; then rm -rf "$project/.agent/indexes"; fi
      /usr/bin/time -p -o "$scratch/time" "$idx" ensure --root "$project" >/dev/null 2>"$scratch/diag"
      if [ "$mode" = warm ]; then grep -q '^HIT$' "$scratch/diag"; fi
      awk '$1=="real"{print $2}' "$scratch/time" >>"$scratch/samples"
      i=$((i + 1))
    done
    sort -n "$scratch/samples" >"$scratch/sorted"
    awk -v records="$count" -v mode="$mode" '
      { a[NR] = $1 }
      END {
        n = NR
        mid = int((n + 1) / 2)
        if (n % 2 == 1) { med = a[mid] } else { med = (a[mid] + a[mid + 1]) / 2 }
        pidx = int(0.95 * n)
        if (pidx * 1.0 < 0.95 * n) pidx++
        if (pidx < 1) pidx = 1
        if (pidx > n) pidx = n
        printf "%s %s %d %.3f %.3f\n", records, mode, n, med, a[pidx]
      }
    ' "$scratch/sorted"
  done
done
