#!/usr/bin/env bash
set -u
export LC_ALL=C
unset CDPATH
selfdir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || exit 2
# shellcheck source=runtime.sh
. "$selfdir/runtime.sh"

usage() {
  cat <<'EOF'
Usage: absorb.sh mark [root]
       absorb.sh records --from <worker-root> [root]
       absorb.sh docs --from <worker-root> [root]

Merges what a worker wrote into its own copy of the node back into the main
node. root defaults to . — the project root holding .agent/.

mark runs in the worker's checkout when the orchestrator dispatches it, and
records the size and hash of every node file as the worker's base.
records applies the worker's experience records: entries appended to
session-log.md, memory.md, and a manual-mode rules/learned.md, and new or
superseded files under memory/ and rules/learned/. Run it when each attempt
ends, failed and discarded attempts included.
docs applies code-coupled writes: purpose.md, rules/*.md other than
learned.md, and docs/. Run it when the worker's code is integrated.

A file is applied only when the main node has not changed it since the
worker's base; otherwise it is a conflict and stays as the main node has it.
Removals are reported, never applied. Output is one TSV line per decision:
applied, duplicate, conflict, or not-applied, then the path.
Exit 0 when nothing conflicted, 3 when something did, 2 on refusal.
EOF
}

action="${1:-}"
case "$action" in
-h | --help) usage; exit 0 ;;
mark | records | docs) shift ;;
*) usage >&2; exit 2 ;;
esac
from=""
root="."
while [ $# -gt 0 ]; do
  case "$1" in
  --from) [ $# -ge 2 ] || { usage >&2; exit 2; }; from="$2"; shift 2 ;;
  -h | --help) usage; exit 0 ;;
  --*) echo "absorb.sh: unknown flag: $1" >&2; usage >&2; exit 2 ;;
  *) root="$1"; shift ;;
  esac
done

root=$(da_root "$root") || exit 2
[ -f "$root/.agent/purpose.md" ] || { echo "absorb.sh: no node manifest at $root/.agent/purpose.md" >&2; exit 2; }

hash_file() { git hash-object --no-filters -- "$1"; }
file_size() { wc -c <"$1" | tr -d '[:space:]'; }
prefix_hash() { head -c "$2" "$1" | git hash-object --stdin; }
manifest_field() { grep -m1 "^  $2:" "$1/.agent/purpose.md" | sed -E "s/^[[:space:]]*$2:[[:space:]]*\"?([^\"[:space:]]*)\"?.*/\\1/"; }

# Node files a worker may write, relative to <root>/.agent. Scripts, confs,
# indexes, archive/, and private state never travel.
node_files() {
  (cd "$1/.agent" && find . \( -path ./.state -o -path ./scripts -o -path ./indexes -o -path ./archive \) -prune \
    -o -type f -name '*.md' -print) | sed 's|^\./||' | LC_ALL=C sort
}

if [ "$action" = mark ]; then
  state=$(da_state_dir "$root") || exit 2
  base_tmp=$(mktemp "$state/.absorb-base.XXXXXX") || exit 2
  node_files "$root" | while IFS= read -r rel; do
    printf '%s\t%s\t%s\n' "$rel" "$(file_size "$root/.agent/$rel")" "$(hash_file "$root/.agent/$rel")"
  done >"$base_tmp" && mv -f "$base_tmp" "$state/absorb-base.tsv" || { rm -f "$base_tmp"; exit 2; }
  printf 'marked\t%s\n' "$(wc -l <"$state/absorb-base.tsv" | tr -d '[:space:]')"
  exit 0
fi

[ -n "$from" ] || { echo "absorb.sh: $action requires --from <worker-root>" >&2; usage >&2; exit 2; }
from=$(da_root "$from") || exit 2
[ "$from" != "$root" ] || { echo "absorb.sh: --from names the main node itself" >&2; exit 2; }
[ -f "$from/.agent/purpose.md" ] || { echo "absorb.sh: no node manifest at $from/.agent/purpose.md" >&2; exit 2; }
base="$from/.agent/.state/absorb-base.tsv"
[ -f "$base" ] || { echo "absorb.sh: $from has no absorb base — run absorb.sh mark in the worker checkout when it is dispatched" >&2; exit 2; }
main_version=$(manifest_field "$root" version)
worker_version=$(manifest_field "$from" version)
[ "$main_version" = "$worker_version" ] || {
  echo "absorb.sh: worker node is version $worker_version, main node is $main_version — absorb only between nodes of one version" >&2; exit 2; }

# The same locks log.sh, memory.sh, and learn.sh take, so no writer runs
# against the main node while a worker's node merges into it.
state=$(da_state_dir "$root") || exit 2
locks=()
tmp=""
cleanup() {
  local held
  [ -z "$tmp" ] || rm -f "$tmp" "$tmp.line"
  for held in "${locks[@]+"${locks[@]}"}"; do da_unlock "$held"; done
}
trap cleanup EXIT
take_lock() { da_lock "$1" || exit 2; locks+=("$1"); }
take_lock "$state/checkpoint.lock"
take_lock "$state/memory.lock"
[ ! -d "$root/.agent/rules/learned" ] || take_lock "$root/.agent/rules/learned/.learn-writer.lock"
tmp=$(mktemp "$state/.absorb.XXXXXX") || exit 2

conflicts=0
rules_changed=0
main_node="$root/.agent"
worker_node="$from/.agent"
indexes=$(manifest_field "$root" indexes)
learned_dir_active=0
[ -n "$(find "$main_node/rules/learned" -type f -name '*.md' -print -quit 2>/dev/null)" ] && learned_dir_active=1

base_of() { awk -F '\t' -v p="$1" '$1 == p { print $2 "\t" $3; exit }' "$base"; }
report() { printf '%s\t%s\n' "$1" "$2"; }
conflict() { conflicts=$((conflicts + 1)); printf 'conflict\t%s\t%s\n' "$1" "$2"; }

# A worker that only appended to a file left the base bytes as they were.
appended_tail() { # rel → writes the appended bytes to $tmp; 1 = no tail, 2 = not append-only
  local rel="$1" b size hash
  b=$(base_of "$rel")
  [ -f "$worker_node/$rel" ] || return 1
  if [ -z "$b" ]; then cp "$worker_node/$rel" "$tmp"; return 0; fi
  size=${b%%$'\t'*}; hash=${b#*$'\t'}
  [ "$(file_size "$worker_node/$rel")" -gt "$size" ] || { [ "$(hash_file "$worker_node/$rel")" = "$hash" ] && return 1; return 2; }
  [ "$(prefix_hash "$worker_node/$rel" "$size")" = "$hash" ] || return 2
  tail -c +"$((size + 1))" "$worker_node/$rel" >"$tmp"
}

append_to_main() { # rel, file holding lines to add
  local target="$main_node/$1"
  if [ -s "$target" ] && [ -n "$(tail -c 1 "$target")" ]; then printf '\n' >>"$target"; fi
  cat "$2" >>"$target"
}

absorb_appended() { # rel — appends each new line the main file does not already hold
  local rel="$1" added="" line rc
  appended_tail "$rel"; rc=$?
  [ "$rc" -ne 1 ] || return 0
  if [ "$rc" -eq 2 ]; then conflict "$rel" "the worker rewrote earlier entries, not only appended"; return 0; fi
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    if [ -f "$main_node/$rel" ] && grep -qxF -- "$line" "$main_node/$rel"; then continue; fi
    if [ "${learned_dedupe:-0}" -eq 1 ] && [ "${line#- [}" != "$line" ]; then
      printf '%s\n' "$line" >"$tmp.line"
      if is_learned_duplicate "$tmp.line"; then rm -f "$tmp.line"; report duplicate "$rel: ${line:0:80}"; continue; fi
      rm -f "$tmp.line"
    fi
    added="$added$line"$'\n'
  done <"$tmp"
  [ -n "$added" ] || return 0
  printf '%s' "$added" >"$tmp"
  append_to_main "$rel" "$tmp"
  report applied "$rel"
}

absorb_file() { # rel — a whole-file record or doc
  local rel="$1" b bhash whash mhash
  b=$(base_of "$rel")
  whash=$(hash_file "$worker_node/$rel")
  bhash=${b#*$'\t'}
  [ -z "$b" ] || [ "$whash" != "$bhash" ] || return 0
  if [ -f "$main_node/$rel" ]; then
    mhash=$(hash_file "$main_node/$rel")
    [ "$mhash" != "$whash" ] || return 0
    if [ -z "$b" ]; then conflict "$rel" "the main node created a different file with this name"; return 0; fi
    if [ "$mhash" != "$bhash" ]; then conflict "$rel" "the main node changed it since the worker's base"; return 0; fi
  elif [ -n "$b" ]; then
    conflict "$rel" "the main node removed it since the worker's base"; return 0
  fi
  mkdir -p "$(dirname "$main_node/$rel")" && cp "$worker_node/$rel" "$tmp" && mv -f "$tmp" "$main_node/$rel" \
    || { conflict "$rel" "could not write it"; return 0; }
  tmp=$(mktemp "$state/.absorb.XXXXXX") || exit 2
  case "$rel" in rules/* | docs/*) rules_changed=1 ;; esac
  report applied "$rel"
}

report_removals() { # glob-free prefix filter as an awk regex
  awk -F '\t' -v re="$1" '$1 ~ re { print $1 }' "$base" | while IFS= read -r rel; do
    [ -e "$worker_node/$rel" ] || printf 'not-applied\t%s\tthe worker removed it; retire or delete it from the main node if that was intended\n' "$rel"
  done
}

is_learned_duplicate() { # file holding one candidate rule
  "$main_node/scripts/learn.sh" lookup --file "$1" "$root" 2>/dev/null | grep -q '^duplicate'
}

worker_files=$(node_files "$from")
if [ "$action" = records ]; then
  absorb_appended session-log.md
  absorb_appended memory.md
  while IFS= read -r rel; do absorb_file "$rel"; done < <(printf '%s\n' "$worker_files" | grep '^memory/')
  if [ "$learned_dir_active" -eq 1 ] || [ "$indexes" = generated ]; then
    while IFS= read -r rel; do
      if [ -z "$(base_of "$rel")" ] && [ ! -e "$main_node/$rel" ] && is_learned_duplicate "$worker_node/$rel"; then
        report duplicate "$rel"; continue
      fi
      absorb_file "$rel"
    done < <(printf '%s\n' "$worker_files" | grep '^rules/learned/')
  else
    learned_dedupe=1 absorb_appended rules/learned.md
  fi
  report_removals '^(memory/|rules/learned/)'
else
  while IFS= read -r rel; do absorb_file "$rel"; done \
    < <(printf '%s\n' "$worker_files" | grep -E '^(purpose\.md|rules/[^/]+\.md|docs/)' | grep -vx 'rules/learned.md')
  report_removals '^(rules/[^/]+\.md|docs/)'
fi

if [ "$rules_changed" -eq 1 ] && [ "$indexes" = generated ] && [ -x "$main_node/scripts/index.sh" ]; then
  "$main_node/scripts/index.sh" ensure --root "$root" >/dev/null 2>&1 \
    || printf 'not-applied\t.agent/indexes\tindex.sh ensure failed after the merge; run it by hand\n'
fi
[ "$conflicts" -eq 0 ] || exit 3
exit 0
