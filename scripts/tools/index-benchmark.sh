#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
idx="$here/../index.sh"
repeats=${1:-15}
[ "$#" -le 1 ] || { printf 'Usage: scripts/tools/index-benchmark.sh [REPEATS >= 10]\n' >&2; exit 2; }
case "$repeats" in '' | *[!0-9]*) printf 'Usage: scripts/tools/index-benchmark.sh [REPEATS >= 10]\n' >&2; exit 2 ;; esac
[ "$repeats" -ge 10 ] || { printf 'Usage: scripts/tools/index-benchmark.sh [REPEATS >= 10]\n' >&2; exit 2; }

scratch=$(mktemp -d "${TMPDIR:-/tmp}/index-bench.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT
trap 'exit 130' INT TERM

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
