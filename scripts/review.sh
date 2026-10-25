#!/usr/bin/env bash

set -uo pipefail
unset CDPATH

VERSION=6.3.0
SOURCE_ROOTS=src
TEST_PATH_RE='(^|/)(test|tests|spec|specs)/|(^|/)[^/]*(test|spec)\.[^/]+$'
CATALOGS=auto
MAX_FINDINGS=20

usage() {
  cat <<'EOF'
Usage: review.sh [--base REF] [--root ROOT]
       review.sh --help | --version

Runs comments.sh once, then lists bounded, advisory candidates for new helper
catalog entries and test coverage. It does not stage files or claim that a
catalog match proves reuse or that a test name proves coverage.

Exit 0 means the review completed, 1 means comments.sh found blocking
comments, and 2 means the change could not be inspected.
EOF
}

selfdir=$(cd "$(dirname "$0")" && pwd)
root=.
base=""
base_given=0
while [ $# -gt 0 ]; do
  case "$1" in
  --base)
    [ $# -ge 2 ] || { echo "review.sh: --base needs a value" >&2; usage >&2; exit 2; }
    base=$2; base_given=1; shift 2 ;;
  --root)
    [ $# -ge 2 ] || { echo "review.sh: --root needs a value" >&2; usage >&2; exit 2; }
    root=$2; shift 2 ;;
  -h | --help) usage; exit 0 ;;
  --version) printf 'review.sh %s\n' "$VERSION"; exit 0 ;;
  *) echo "review.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

conf="$selfdir/review.conf"
conf_get() { sed -n "s/^$1=//p" "$conf" 2>/dev/null | head -n 1; }
if [ -f "$conf" ]; then
  v=$(conf_get SOURCE_ROOTS); [ -n "$v" ] && SOURCE_ROOTS=$v
  v=$(conf_get TEST_PATH_RE); [ -n "$v" ] && TEST_PATH_RE=$v
  v=$(conf_get CATALOGS);     [ -n "$v" ] && CATALOGS=$v
  v=$(conf_get MAX_FINDINGS); [ -n "$v" ] && MAX_FINDINGS=$v
fi

case "$MAX_FINDINGS" in
  "" | *[!0-9]*)
    echo "review.sh: MAX_FINDINGS must be a positive whole number: $MAX_FINDINGS" >&2
    exit 2 ;;
esac
if [ "$MAX_FINDINGS" -eq 0 ]; then
  echo "review.sh: MAX_FINDINGS must be greater than zero" >&2
  exit 2
fi
printf '' | grep -E "$TEST_PATH_RE" >/dev/null 2>&1
regex_rc=$?
if [ "$regex_rc" -gt 1 ]; then
  echo "review.sh: TEST_PATH_RE is not a valid regular expression: $TEST_PATH_RE" >&2
  exit 2
fi

root=$(cd "$root" 2>/dev/null && pwd -P) || {
  echo "review.sh: root is not a readable directory: $root" >&2
  exit 2
}
git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "review.sh: root is not a Git worktree: $root" >&2
  exit 2
}
[ -x "$selfdir/comments.sh" ] || [ -f "$selfdir/comments.sh" ] || {
  echo "review.sh: comments.sh is missing beside review.sh" >&2
  exit 2
}

if [ "$base_given" -eq 0 ]; then
  comments_conf="$selfdir/comments.conf"
  configured_base=$(sed -n 's/^BASE_REF=//p' "$comments_conf" 2>/dev/null | head -n 1)
  base=${configured_base:-origin/main}
fi

if [ "$base_given" -eq 1 ]; then
  (cd "$root" && bash "$selfdir/comments.sh" "$base")
else
  (cd "$root" && bash "$selfdir/comments.sh")
fi
comments_rc=$?
case "$comments_rc" in
0 | 1) ;;
*) exit 2 ;;
esac

merge_base=$(git -C "$root" merge-base "$base" HEAD 2>/dev/null) || {
  echo "review.sh: no merge base between '$base' and HEAD" >&2
  exit 2
}

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/review-v63.XXXXXX") || {
  echo "review.sh: could not create temporary workspace" >&2
  exit 2
}
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT HUP INT TERM
changed_z="$tmpdir/changed.z"
: >"$changed_z"
git -C "$root" -c core.quotepath=false diff --name-only -z "$merge_base" -- >"$changed_z" || {
  echo "review.sh: git diff against '$merge_base' failed" >&2
  exit 2
}
git -C "$root" ls-files --others --exclude-standard -z >>"$changed_z" || {
  echo "review.sh: could not list untracked files" >&2
  exit 2
}

changed=()
while IFS= read -r -d '' path; do
  [ -f "$root/$path" ] || continue
  duplicate=0
  for known in "${changed[@]-}"; do
    [ "$known" = "$path" ] && { duplicate=1; break; }
  done
  [ "$duplicate" -eq 1 ] || changed+=("$path")
done <"$changed_z"

catalogs=()
if [ "$CATALOGS" = auto ]; then
  for catalog in "$root"/.agents/docs/*catalog*.md; do
    [ -f "$catalog" ] && catalogs+=("$catalog")
  done
else
  set -f
  for catalog in $CATALOGS; do
    case "$catalog" in /*) catalog_path=$catalog ;; *) catalog_path="$root/$catalog" ;; esac
    [ -f "$catalog_path" ] && catalogs+=("$catalog_path")
  done
  set +f
fi

is_test_path() { printf '%s\n' "$1" | grep -Eq "$TEST_PATH_RE"; }
is_source_path() {
  source_path=$1
  set -f
  for source_root in $SOURCE_ROOTS; do
    source_root=${source_root%/}
    case "$source_path" in "$source_root"/*) set +f; return 0 ;; esac
  done
  set +f
  return 1
}
supported_source() {
  case "$1" in
    *.js | *.jsx | *.mjs | *.cjs | *.ts | *.tsx | *.py | *.rb | *.go | *.sh | *.bash) return 0 ;;
    *) return 1 ;;
  esac
}

findings=0
findings_shown=0
emit_review() {
  findings=$((findings + 1))
  [ "$findings_shown" -lt "$MAX_FINDINGS" ] || return 0
  printf 'REVIEW: %s %s %s\n' "$1" "$2" "$3"
  findings_shown=$((findings_shown + 1))
}

tests=()
for path in "${changed[@]-}"; do
  [ -n "$path" ] || continue
  is_test_path "$path" && tests+=("$path")
done

for path in "${changed[@]-}"; do
  [ -n "$path" ] || continue
  is_source_path "$path" || continue
  supported_source "$path" || continue
  is_test_path "$path" && continue

  added="$tmpdir/added"
  : >"$added"
  if git -C "$root" ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
    git -C "$root" -c core.quotepath=false diff --unified=0 "$merge_base" -- "$path" \
      | awk '/^\+\+\+ / { next } /^\+/ { print substr($0, 2) }' >"$added"
    diff_rc=${PIPESTATUS[0]}
    [ "$diff_rc" -eq 0 ] || { echo "review.sh: could not inspect $path" >&2; exit 2; }
  else
    cp "$root/$path" "$added" || { echo "review.sh: could not inspect $path" >&2; exit 2; }
  fi

  symbols="$tmpdir/symbols"
  : >"$symbols"
  case "$path" in
  *.js | *.jsx | *.mjs | *.cjs | *.ts | *.tsx)
    sed -nE 's/^[[:space:]]*export[[:space:]]+(default[[:space:]]+)?(async[[:space:]]+)?function[[:space:]]+([A-Za-z_$][A-Za-z0-9_$]*).*/\3/p; s/^[[:space:]]*export[[:space:]]+(default[[:space:]]+)?class[[:space:]]+([A-Za-z_$][A-Za-z0-9_$]*).*/\2/p; s/^[[:space:]]*export[[:space:]]+(const|let|var)[[:space:]]+([A-Za-z_$][A-Za-z0-9_$]*)[[:space:]]*=.*/\2/p' "$added" >"$symbols" ;;
  *.py)
    sed -nE 's/^def[[:space:]]+([A-Za-z][A-Za-z0-9_]*)[[:space:]]*\(.*/\1/p' "$added" | grep -v '^_' >"$symbols" || true ;;
  *.rb)
    sed -nE 's/^[[:space:]]*def[[:space:]]+(self\.)?([A-Za-z][A-Za-z0-9_!?=]*).*/\2/p' "$added" >"$symbols" ;;
  *.go)
    sed -nE 's/^func[[:space:]]+(\([^)]*\)[[:space:]]+)?([A-Z][A-Za-z0-9_]*)[[:space:]]*\(.*/\2/p' "$added" >"$symbols" ;;
  *.sh | *.bash)
    sed -nE 's/^[[:space:]]*(function[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*(\(\))?[[:space:]]*\{[[:space:]]*$/\2/p' "$added" >"$symbols" ;;
  esac

  while IFS= read -r symbol; do
    [ -n "$symbol" ] || continue
    cataloged=0
    for catalog in "${catalogs[@]-}"; do
      [ -n "$catalog" ] || continue
      grep -Fq -- "$symbol" "$catalog" && { cataloged=1; break; }
    done
    if [ "$cataloged" -eq 0 ]; then
      if [ "${#catalogs[@]}" -eq 0 ]; then
        emit_review CATALOG_CANDIDATE "$path" "new helper '$symbol'; no configured catalog is available to compare"
      else
        emit_review CATALOG_CANDIDATE "$path" "new helper '$symbol' was not found textually in the configured catalogs; review whether a catalog entry belongs"
      fi
    fi
  done <"$symbols"

  source_name=${path##*/}
  source_stem=${source_name%.*}
  related_test=""
  for test_path in "${tests[@]-}"; do
    test_name=${test_path##*/}
    case "$test_name" in *"$source_stem"*) related_test=$test_path; break ;; esac
  done
  if [ -z "$related_test" ]; then
    if [ "${#tests[@]}" -eq 0 ]; then
      emit_review TEST_COVERAGE "$path" "no changed test file was detected; review whether this change needs focused coverage"
    else
      emit_review TEST_COVERAGE "$path" "changed tests exist, but none has a filename containing '$source_stem'; review coverage rather than inferring it from names"
    fi
  fi
done

if [ "$findings" -gt "$findings_shown" ]; then
  printf 'REVIEW: FINDINGS_TRUNCATED review.conf %d additional candidate(s) omitted by MAX_FINDINGS=%d\n' \
    "$((findings - findings_shown))" "$MAX_FINDINGS"
fi

exit "$comments_rc"
