#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
unset CDPATH
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

usage() {
  cat <<'EOF'
Usage: scripts/tools/timing-benchmark.sh [--scripts DIR]... [--runs N] [--sizes "N..." | --checkpoint-files "N..."]

Times read-side helpers by node size, or a checkpoint by source-file count.
Each command gets one warm-up run and N timed runs. The report gives the
median and 90th percentile in milliseconds.

--scripts DIR  the scripts/ directory of a dot-agent checkout to time (default:
               the one this file is in). Repeat it to compare revisions: every
               run times each directory in turn, so a change in machine load
               reaches all of them.
--runs N       timed runs per command (default 10)
--sizes "N..." fixture sizes in records (default "10 60 200")
--checkpoint-files "N..."  time checkpoint instead, at each tracked source-file count
EOF
}
die() { printf 'timing-benchmark.sh: %s\n' "$1" >&2; usage >&2; exit 2; }
whole() { case "$2" in '' | 0 | *[!0-9]*) die "$1 takes a whole number above 0" ;; esac; }

sets=()
runs=10
sizes=
size_label=Records
commands="status_load status_tsv memory_lookup index_check review links"
while [ "$#" -gt 0 ]; do
  case "$1" in
  -h | --help) usage; exit 0 ;;
  --scripts | --runs | --sizes | --checkpoint-files) [ "$#" -ge 2 ] || die "$1 needs a value" ;;
  *) die "unknown argument: $1" ;;
  esac
  case "$1" in
  --scripts)
    [ -f "$2/node.sh" ] || die "no node.sh in $2"
    sets+=("$(cd "$2" && pwd -P)") ;;
  --runs) whole --runs "$2"; runs=$2 ;;
  --sizes | --checkpoint-files)
    [ -z "$sizes" ] || die "pass one size list"
    [ -n "${2// /}" ] || die "$1 needs a size"
    if [ "$1" = --checkpoint-files ]; then size_label="Source files"; commands=checkpoint; fi
    for size in $2; do whole --sizes "$size"; done
    sizes=$2 ;;
  esac
  shift 2
done
sizes=${sizes:-"10 60 200"}
[ "${#sets[@]}" -gt 0 ] || sets=("${here%/*}")

scratch=$(mktemp -d "${TMPDIR:-/tmp}/timing-bench.XXXXXXXX")
scratch=$(cd "$scratch" && pwd -P)
trap 'rm -rf "$scratch"' EXIT
trap 'exit 130' INT TERM
export HOME="$scratch/home" GIT_CONFIG_GLOBAL="$scratch/home/.gitconfig" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME"
git config --global user.name bench
git config --global user.email bench@example.invalid

words() { # $1: count  $2: seed — a line of $1 words
  awk -v n="$1" -v seed="$2" 'BEGIN {
    for (i = 1; i <= n; i++) printf "%sword%d", (i > 1 ? " " : ""), (seed * 7 + i) % 997
    print ""
  }'
}

write_record() { # $1: node directory  $2: record number
  case $(($2 % 4)) in
  0)
    {
      printf -- '---\ndate: 2026-01-01\nscope: project\ntype: fact\n---\n\n'
      words 120 "$2"
    } >"$1/memory/fact-$2.md"
    printf -- '- [Fact %d](memory/fact-%d.md) — touching area %d\n' "$2" "$2" "$2" >>"$1/memory.md" ;;
  1)
    { printf -- '- [2026-01-01] '; words 40 "$2"; } >"$1/rules/learned/$(printf '%012x' "$2").md" ;;
  2)
    {
      printf '<!-- Read when: touching area %d -->\n# Area %d\n' "$2" "$2"
      for section in Shape Commands Limits Gotchas; do
        printf '\n## %s\n\n' "$section"
        words 100 "$2"
      done
      # shellcheck disable=SC2016 # literal backticks
      printf '\nSee `docs/area-%d.md` and [notes](note-%d.md).\n' "$2" "$2"
    } >"$1/docs/area-$2.md"
    # shellcheck disable=SC2016 # literal backticks
    printf '\n### `area-%d.md`\n- **Read when:** touching area %d\n- **Sections:** Shape · Commands · Limits · Gotchas\n' \
      "$2" "$2" >>"$1/docs/architecture.md" ;;
  3)
    { printf -- '- [2026-01-01] (bench) '; words 20 "$2" | tr '\n' '.'; printf ' verify: pass.\n'; } >>"$1/session-log.md" ;;
  esac
}

make_project() { # $1: project directory  $2: records or source files  $3: scripts directory
  local node="$1/.agent" n index_mode=generated hooks=session-start records=$2
  if [ "$commands" = checkpoint ]; then index_mode=manual; hooks=none; records=0; fi
  mkdir -p "$1/src" "$1/notes" "$1/out"
  git -C "$1" init -q
  bash "$3/node.sh" init --preset software-development --mode track-all \
    --indexes "$index_mode" --hooks "$hooks" "$1" >/dev/null 2>&1
  awk -v bar="$node/rules/quality-bar.md" '
    /^## / { in_bar = /^## Quality bar/ }
    in_bar { print > bar; next }
    { print }
  ' "$node/rules/contract.md" | sed 's/^\(- [A-Za-z][^:]*:\) <.*>$/\1 set/' >"$scratch/contract"
  cp "$scratch/contract" "$node/rules/contract.md"
  mkdir -p "$node/memory" "$node/rules/learned" "$node/docs"
  [ -s "$node/docs/architecture.md" ] || printf '# Architecture routing table\n' >"$node/docs/architecture.md"
  printf 'out/\n' >>"$1/.gitignore"
  n=1
  while [ "$n" -le "$records" ]; do
    write_record "$node" "$n"
    printf '# Note %d\n' "$n" >"$1/notes/note-$n.md"
    for copy in 0 1 2 3 4 5 6 7 8 9; do printf '# Output\n' >"$1/out/run-$n-$copy.md"; done
    n=$((n + 1))
  done
  if [ "$commands" = checkpoint ]; then
    while [ "$n" -lt "$2" ]; do
      printf 'value = 0\n' >"$1/src/file-$n.py"
      n=$((n + 1))
    done
    cat >"$node/scripts/checks.sh" <<'DRIVER'
#!/usr/bin/env bash
[ "$1" = test ] && grep -Eq '^value = [0-9]+$' src/client.py || exit 1
printf '1..1\nok 1 - value is numeric\n'
DRIVER
  fi
  printf 'one\n' >"$1/src/client.py"
  git -C "$1" add -A
  git -C "$1" commit -qm base
  if [ "$index_mode" = generated ]; then bash "$node/scripts/index.sh" ensure --root "$1" >/dev/null 2>&1 || true; fi
  printf 'def two():\n    return 2\n' >"$1/src/client.py"
}

label() {
  case "$1" in
  status_load) echo 'status.sh --load' ;;
  status_tsv) echo 'status.sh --format tsv' ;;
  memory_lookup) echo 'memory.sh lookup' ;;
  index_check) echo 'index.sh check' ;;
  checkpoint) echo 'checkpoint.sh --checks test' ;;
  review) echo 'review.sh' ;;
  links) echo 'links.sh' ;;
  esac
}
run_command() { # $1: command  $2: project directory
  local s="$2/.agent/scripts"
  case "$1" in
  status_load) bash "$s/status.sh" --load "$2" ;;
  status_tsv) bash "$s/status.sh" --format tsv "$2" ;;
  memory_lookup) bash "$s/memory.sh" lookup --query 'area word12' "$2" ;;
  index_check) bash "$s/index.sh" check --root "$2" ;;
  checkpoint)
    bash "$s/checkpoint.sh" --tool bench --area fixture --summary "Updated the numeric value" --checks test "$2" ;;
  review) bash "$s/review.sh" --base HEAD --root "$2" ;;
  links) bash "$s/links.sh" "$2" ;;
  esac
}

# The time keyword reports milliseconds; /usr/bin/time -p stops at hundredths
# of a second and is absent from many Linux images.
TIMEFORMAT=%3R
time_command() { # $1: command  $2: project directory — prints seconds
  { time run_command "$1" "$2" >"$scratch/out" 2>"$scratch/err"; } 2>&1
}
warm_up() { # $1: command  $2: project directory
  run_command "$1" "$2" >"$scratch/out" 2>"$scratch/err" && return 0
  printf 'timing-benchmark.sh: %s failed on its warm-up run\n' "$(label "$1")" >&2
  cat "$scratch/err" >&2
  exit 1
}

printf '%s, %s, bash %s, git %s\n' "$(uname -srm)" "$(date +%Y-%m-%d)" "$BASH_VERSION" "$(git --version | awk '{ print $3 }')"
i=0
for set in "${sets[@]}"; do
  i=$((i + 1))
  printf 'scripts %d: %s\n' "$i" "$set"
done
printf '\n| %s | Command | Scripts | n | Median ms | p90 ms |\n| --- | --- | --- | --- | --- | --- |\n' "$size_label"

for size in $sizes; do
  i=0
  for set in "${sets[@]}"; do
    i=$((i + 1))
    make_project "$scratch/p$size-$i" "$size" "$set"
  done
  for cmd in $commands; do
    run=0
    while [ "$run" -le "$runs" ]; do
      i=0
      for set in "${sets[@]}"; do
        i=$((i + 1))
        if [ "$cmd" = checkpoint ]; then
          git -C "$scratch/p$size-$i" checkout -- .agent/session-log.md
          printf 'value = %d\n' "$run" >"$scratch/p$size-$i/src/client.py"
        fi
        if [ "$run" -eq 0 ]; then
          warm_up "$cmd" "$scratch/p$size-$i"
        else
          time_command "$cmd" "$scratch/p$size-$i" >>"$scratch/$size-$cmd-$i"
        fi
        if [ "$cmd" = checkpoint ]; then
          grep -qx 'checkpoint.sh: recorded verify=pass' "$scratch/out" || die 'checkpoint did not record a fresh pass'
        fi
      done
      run=$((run + 1))
    done
    i=0
    for set in "${sets[@]}"; do
      i=$((i + 1))
      sort -n "$scratch/$size-$cmd-$i" | awk -v size="$size" -v cmd="$(label "$cmd")" -v set="$i" '
        { a[NR] = $1 * 1000 }
        END {
          mid = int((NR + 1) / 2)
          median = NR % 2 ? a[mid] : (a[mid] + a[mid + 1]) / 2
          p90 = int(0.9 * NR)
          if (p90 < 0.9 * NR) p90++
          printf "| %d | `%s` | %d | %d | %.0f | %.0f |\n", size, cmd, set, NR, median, a[p90]
        }
      '
    done
  done
done
