#!/usr/bin/env bash

set -u
export LC_ALL=C
unset CDPATH

selfdir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
[ -f "$selfdir/runtime.sh" ] || { echo 'memory.sh: runtime.sh is missing. Update this node with node.sh update from the dot-agent repository' >&2; exit 1; }
# shellcheck source=runtime.sh
. "$selfdir/runtime.sh"

usage() {
  cat <<'EOF'
Usage: memory.sh lookup --query <text> [--limit <n>] [root]
       memory.sh new --slug <slug> --title <title> --hook <hook> (--fact "…" | --file <path|->) [--scope <project|package|root>] [--type <fact|reference>] [root]
       memory.sh supersede --slug <slug> (--fact "…" | --file <path|->) [--expected <digest>] [--scope <project|package|root>] [--type <fact|reference>] [root]

root defaults to . — scope defaults to project, type to fact. new writes
<root>/.agent/memory/<slug>.md and indexes it in <root>/.agent/memory.md.
supersede rewrites an existing fact file's body, restamps its date, and
leaves the index line alone.
EOF
}

refuse() { da_refuse "$@"; exit $?; }
refuse_usage() { usage >&2; refuse "$@"; }

need_value() {
  case "${2-}" in
  --slug|--title|--hook|--fact|--file|--expected|--scope|--type|--query|--limit)
    refuse_usage "$1 needs a value, got the flag $2" "Pass a value after $1" ;;
  esac
  if [ $# -lt 2 ]; then
    refuse_usage "$1 needs a value" "Pass a value after $1"
  fi
}

body_tmp=""
lookup_list=""
lookup_hits=""
cleanup() {
  [ -n "$body_tmp" ] && rm -f "$body_tmp"
  [ -n "$lookup_list" ] && rm -f "$lookup_list"
  [ -n "$lookup_hits" ] && rm -f "$lookup_hits"
}
trap cleanup EXIT

read_body() {
  body_tmp=$(mktemp "${TMPDIR:-/tmp}/memory-body.XXXXXX") || {
    refuse "could not create a temporary body file" "Check that the temporary folder is writable, then run this call again"
  }
  if [ "$1" = - ]; then
    cat >"$body_tmp" || refuse "could not create or read a temporary file" "Check that the temporary folder is writable, then run this call again"
  elif [ -f "$1" ]; then
    cat "$1" >"$body_tmp" || refuse "could not create or read a temporary file" "Check that the temporary folder is writable, then run this call again"
  else
    refuse "--file $1 does not exist" "Pass an existing file, or --file - with the body on stdin"
  fi
}

digest_file() {
  git hash-object --no-filters -- "$1"
}

# grep reads a newline as a line break, not a control character, so the
# builtin match only decides when grep has to run.
has_cntrl() {
  case "$1" in
  *[[:cntrl:]]*) printf '%s' "$1" | grep -q '[[:cntrl:]]' ;;
  *) return 1 ;;
  esac
}

# Files arrive a folder at a time, so each folder is resolved once.
lookup_parent_dir=""
lookup_parent_phys=""
lookup_add() {
  la_rel="$1"
  la_file="$2"
  if has_cntrl "$la_rel$la_file"; then
    da_refuse "canonical lookup path contains a control character and cannot be represented safely" "Rename that file, then run this call again"
    return 1
  fi
  if [ ! -e "$la_file" ] && [ ! -L "$la_file" ]; then
    return 0
  fi
  if [ ! -f "$la_file" ] || [ -L "$la_file" ]; then
    da_refuse "canonical lookup path is not a regular non-symlink file: $la_rel" "Replace it with a regular file, then run this call again"
    return 1
  fi
  la_dir="${la_file%/*}"
  if [ "$la_dir" != "$lookup_parent_dir" ]; then
    lookup_parent_phys=$(cd "$la_dir" 2>/dev/null && pwd -P) || {
      da_refuse "cannot resolve canonical lookup parent for $la_rel" "Check that its folder exists and is readable, then run this call again"
      return 1
    }
    lookup_parent_dir="$la_dir"
  fi
  la_parent="$lookup_parent_phys"
  la_inside=0
  case "$la_parent" in
  "$lookup_root_phys"|"$lookup_root_phys"/*) la_inside=1 ;;
  esac
  # An empty node pattern would match every absolute path, so test it only when set.
  if [ "$la_inside" = 0 ] && [ -n "$lookup_node_phys" ]; then
    case "$la_parent" in
    "$lookup_node_phys"|"$lookup_node_phys"/*) la_inside=1 ;;
    esac
  fi
  if [ "$la_inside" = 0 ]; then
    da_refuse "canonical lookup path resolves outside the project: $la_rel" "Move it inside the project or remove the link, then run this call again"
    return 1
  fi
  printf '%s\n' "$lookup_root_phys/$la_rel" >>"$lookup_list" || return 1
}

lookup_routed_docs() {
  lr_arch="$1/.agent/docs/architecture.md"
  [ -e "$lr_arch" ] || [ -L "$lr_arch" ] || return 0
  lookup_add ".agent/docs/architecture.md" "$lr_arch" || return 1
  lr_names=$(mktemp "${TMPDIR:-/tmp}/memory-routed-docs.XXXXXX") || return 1
  if ! awk '
    /<!--/ && /-->/ { next }
    /<!--/ { incm=1; next }
    incm { if ($0 ~ /-->/) incm=0; next }
    /^### / {
      if ($0 !~ /^### `.*`[[:space:]]*$/) exit 2
      p=$0; sub(/^### `/, "", p); sub(/`[[:space:]]*$/, "", p)
      if (!seen[p]++) print p
    }
  ' "$lr_arch" >"$lr_names"; then
    rm -f "$lr_names"
    da_refuse "could not read routed docs from $lr_arch" "Fix its ### \`<file>\` headings, then run this call again"
    return 1
  fi
  while IFS= read -r lr_name; do
    case "$lr_name" in
    ""|/*|.|..|../*|*/../*|*/..|*/.|*'/./'*|./*|*'`'*|*'|'*|*'\'*|*.md.md) lr_bad=1 ;;
    *.md) lr_bad=0 ;;
    *) lr_bad=1 ;;
    esac
    if [ "$lr_bad" -ne 0 ] || has_cntrl "$lr_name"; then
      rm -f "$lr_names"
      da_refuse "routed canonical document has an unsafe path: $lr_name" "Fix that entry in .agent/docs/architecture.md, then run this call again"
    return 1
    fi
    if [ ! -e "$1/.agent/docs/$lr_name" ] && [ ! -L "$1/.agent/docs/$lr_name" ]; then
      rm -f "$lr_names"
      da_refuse "routed canonical document is missing: .agent/docs/$lr_name" "Restore the doc or remove its entry in .agent/docs/architecture.md, then run this call again"
    return 1
    fi
    lookup_add ".agent/docs/$lr_name" "$1/.agent/docs/$lr_name" || { rm -f "$lr_names"; return 1; }
  done <"$lr_names"
  rm -f "$lr_names"
}

run_lookup() {
  rl_root="$1"
  rl_query="$2"
  rl_limit="$3"
  if has_cntrl "$rl_root"; then
    da_refuse "project root contains a control character and cannot be searched safely" "Pass a root path without control characters"
    return 1
  fi
  lookup_root_phys=$(cd "$rl_root" 2>/dev/null && pwd -P) || {
    da_refuse "cannot resolve project root: $rl_root" "Pass the folder that holds .agent/ as the last argument"
    return 1
  }
  if has_cntrl "$lookup_root_phys"; then
    da_refuse "physical project root contains a control character and cannot be searched safely" "Move the project to a path without control characters"
    return 1
  fi
  # A shared node (.agent linked to another checkout's node) lies outside the
  # root by design; runtime.sh decides which links count as one.
  lookup_node_phys=""
  if [ -L "$rl_root/.agent" ]; then
    lookup_node_phys=$(da_node_dir "$rl_root") || return 1
  fi
  lookup_list=$(mktemp "${TMPDIR:-/tmp}/memory-lookup-list.XXXXXX") || refuse "could not create or read a temporary file" "Check that the temporary folder is writable, then run this call again"
  lookup_hits=$(mktemp "${TMPDIR:-/tmp}/memory-lookup-hits.XXXXXX") || refuse "could not create or read a temporary file" "Check that the temporary folder is writable, then run this call again"
  : >"$lookup_list"
  lookup_add ".agent/purpose.md" "$rl_root/.agent/purpose.md" || return 1
  for rl_f in "$rl_root"/.agent/rules/*.md; do
    [ -e "$rl_f" ] || continue
    if [ "${rl_f##*/}" = learned.md ] && [ -d "$rl_root/.agent/rules/learned" ] && [ ! -L "$rl_root/.agent/rules/learned" ]; then
      continue
    fi
    lookup_add ".agent/rules/${rl_f##*/}" "$rl_f" || return 1
  done
  if [ -d "$rl_root/.agent/rules/learned" ] && [ ! -L "$rl_root/.agent/rules/learned" ]; then
    for rl_f in "$rl_root"/.agent/rules/learned/*.md; do
      [ -e "$rl_f" ] || continue
      lookup_add ".agent/rules/learned/${rl_f##*/}" "$rl_f" || return 1
    done
  fi
  lookup_add ".agent/memory.md" "$rl_root/.agent/memory.md" || return 1
  if [ -d "$rl_root/.agent/memory" ] && [ ! -L "$rl_root/.agent/memory" ]; then
    for rl_f in "$rl_root"/.agent/memory/*.md; do
      [ -e "$rl_f" ] || continue
      lookup_add ".agent/memory/${rl_f##*/}" "$rl_f" || return 1
    done
  fi
  lookup_routed_docs "$rl_root" || return 1

  set --
  while IFS= read -r rl_file; do
    set -- "$@" "$rl_file"
  done <"$lookup_list"

  # A single awk process scans literal file arguments and owns the boundaries.
  if [ "$#" -gt 0 ]; then
  awk -v query="$rl_query" -v prefix="$lookup_root_phys/" '
    function clean(s) { gsub(/[\t\r\n]+/, " ", s); gsub(/[[:space:]]+/, " ", s); return substr(s,1,240) }
    function terms(s,a, n,i,t) {
      s=tolower(s); gsub(/[^abcdefghijklmnopqrstuvwxyz0123456789_.\/-]+/," ",s)
      n=split(s,t," "); for(i=1;i<=n;i++) if(length(t[i])>2 && t[i] !~ /^(the|and|for|with|from|this|that|when|read)$/) a[t[i]]=1
    }
    FNR==1 {
      if (seen) emit(); seen=1; file=FILENAME
      if (index(file,prefix)==1) file=substr(file,length(prefix)+1)
      exact=0; score=0; excerpt=""; exact_excerpt=""
    }
    {
      if(index(tolower($0),tolower(query))) { exact=1; if(exact_excerpt=="") exact_excerpt=clean($0) }
      delete lt; terms($0,lt); for(k in qt) if(k in lt) score++
      if(excerpt=="" && $0 !~ /^[[:space:]]*$/) excerpt=clean($0)
    }
    function emit( kind,e) {
      kind=exact ? "exact" : (score ? "overlap" : "")
      e=(exact ? exact_excerpt : excerpt)
      if(kind!="") print kind "\t" file "\t" clean(e)
    }
    BEGIN { terms(query,qt) }
    END { if(seen) emit() }
  ' "$@" >"$lookup_hits" || {
    da_refuse "canonical lookup could not read all selected files" "Check that the files under .agent/ are readable, then run this call again"
    return 1
  }
  else
    : >"$lookup_hits"
  fi

  rl_n=0
  rl_total=$(wc -l <"$lookup_hits" | tr -d '[:space:]') || return 1
  for rl_kind in exact overlap; do
    while IFS="$(printf '\t')" read -r rl_hit_kind rl_file rl_excerpt; do
      [ "$rl_hit_kind" = "$rl_kind" ] || continue
      rl_rel="$rl_file"
      rl_abs="$rl_root/$rl_rel"
      if [ "$rl_n" -lt "$rl_limit" ]; then
        rl_version=$(digest_file "$rl_abs") || return 1
        printf '%s\t%s\t%s\t%s\n' "$rl_kind" "$rl_rel" "$rl_version" "$rl_excerpt"
        rl_n=$((rl_n + 1))
      fi
    done <"$lookup_hits"
  done
  if [ "$rl_total" -gt "$rl_n" ]; then
    if [ "$rl_n" -ge 100 ]; then
      echo "memory.sh: lookup showed $rl_n of $rl_total matches; refine --query to see omitted matches (--limit maximum is 100)" >&2
    else
      rl_follow=$rl_total
      [ "$rl_follow" -le 100 ] || rl_follow=100
      echo "memory.sh: lookup showed $rl_n of $rl_total matches; rerun with --limit $rl_follow to show more (maximum 100)" >&2
    fi
  fi
}

validate_slug() {
  case "$1" in
  -*)
    refuse "--slug must not start with - (got '$1'), because the filename would read as a flag" "Pick another slug" ;;
  esac
  case "$1" in
  *[!abcdefghijklmnopqrstuvwxyz0123456789-]* | "")
    refuse "--slug must match [a-z0-9-]+ (got '$1')" "Pick a slug of lowercase letters, digits, and hyphens" ;;
  esac
}

# Writers in one checkout serialize on one lock per node, so parallel workers
# can write memory directly. absorb.sh takes the same lock.
memory_lock() {
  local state
  state=$(da_state_dir "$1") || exit 1
  memory_lock_path="$state/memory.lock"
  da_lock_wait "$memory_lock_path" || exit 1
  trap 'da_unlock "$memory_lock_path"; cleanup' EXIT
}

cmd="${1:-}"
[ $# -ge 1 ] && shift

case "$cmd" in
-h|--help)
  usage
  exit 0 ;;
lookup)
  query=""
  limit=20
  root="."
  while [ $# -gt 0 ]; do
    case "$1" in
    --query) need_value "$@"; query="$2"; shift 2 ;;
    --limit) need_value "$@"; limit="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --*) refuse_usage "unknown flag: $1" "Pass only the flags listed above" ;;
    *) root="$1"; shift ;;
    esac
  done
  [ -n "$query" ] || refuse "lookup requires --query <text>" "Run this call again with --query and the words to search for"
  case "$limit" in *[!0-9]*|"") refuse "--limit must be an integer from 1 to 100" "Pass such a number, or drop --limit for 20" ;; esac
  [ "$limit" -ge 1 ] && [ "$limit" -le 100 ] || refuse "--limit must be an integer from 1 to 100" "Pass such a number, or drop --limit for 20"
  [ -d "$root/.agent" ] || refuse "$root/.agent does not exist" "Pass the folder that holds .agent/ as the last argument"
  run_lookup "$root" "$query" "$limit" || exit 1
  exit 0 ;;
new)
  slug=""
  title=""
  hook=""
  fact=""
  file=""
  scope="project"
  type="fact"
  root="."
  while [ $# -gt 0 ]; do
    case "$1" in
    --slug)
      need_value "$@"
      slug="$2"; shift 2 ;;
    --title)
      need_value "$@"
      title="$2"; shift 2 ;;
    --hook)
      need_value "$@"
      hook="$2"; shift 2 ;;
    --fact)
      need_value "$@"
      fact="$2"; shift 2 ;;
    --file)
      need_value "$@"
      file="$2"; shift 2 ;;
    --scope)
      need_value "$@"
      scope="$2"; shift 2 ;;
    --type)
      need_value "$@"
      type="$2"; shift 2 ;;
    -h | --help)
      usage; exit 0 ;;
    --*)
      refuse_usage "unknown flag: $1" "Pass only the flags listed above" ;;
    *)
      root="$1"; shift ;;
    esac
  done

  if [ -z "$slug" ] || [ -z "$title" ] || [ -z "$hook" ] || { [ -z "$fact" ] && [ -z "$file" ]; }; then
    refuse_usage "--slug, --title, --hook, and one of --fact or --file are required" "Run this call again with all of them"
  fi
  if [ -n "$fact" ] && [ -n "$file" ]; then
    refuse "--fact and --file were both given" "Pass one of them"
  fi
  [ -z "$file" ] || read_body "$file"

  validate_slug "$slug"

  case "$title" in
  *\[* | *\]*)
    refuse "--title must not contain [ or ], because it becomes the index link text" "Reword the title" ;;
  esac
  nl='
'
  case "$title$hook" in
  *"$nl"*)
    refuse "--title and --hook must be single-line" "Remove the line breaks" ;;
  esac

  case "$scope" in
  project | package | root) ;;
  *)
    refuse "--scope must be project, package, or root (got '$scope')" "Pass one of those, or drop --scope" ;;
  esac

  case "$type" in
  fact | reference) ;;
  *)
    refuse "--type must be fact or reference (got '$type')" "Pass one of those, or drop --type" ;;
  esac

  agent="$root/.agent"
  memory="$agent/memory.md"
  memdir="$agent/memory"
  factfile="$memdir/$slug.md"

  if [ ! -f "$memory" ]; then
    refuse "$memory does not exist, and memory.sh writes only to an initialized node" "Pass the folder that holds .agent/ as the last argument"
  fi
  if [ ! -w "$memory" ]; then
    refuse "$memory is not writable, so the fact could not be indexed" "Make it writable, then run this call again"
  fi
  memory_lock "$root"
  if [ -e "$factfile" ]; then
    refuse "$factfile already exists" "Run memory.sh supersede --slug $slug --fact \"…\" to rewrite it, or pick a new slug"
  fi
  if grep -qE "^- \[[^]]*\]\(memory/$slug\.md\)" "$memory" 2>/dev/null; then
    refuse "$memory already indexes memory/$slug.md, which does not exist" "Remove that index line, or pick a new slug, then run this call again"
  fi

  mkdir -p "$memdir"
  date_stamp=$(date +%Y-%m-%d)


  facttmp="$factfile.tmp.$$"
  if {
    cat <<EOF
---
date: $date_stamp
scope: $scope
type: $type
---

EOF
    if [ -n "$file" ]; then cat "$body_tmp"; else printf '%s\n' "$fact"; fi
  } >"$facttmp"
  then :
  else
    rm -f "$facttmp"
    refuse "could not stage $factfile, so nothing was written" "Check that .agent/memory/ is writable, then run this call again"
  fi

  memorytmp="$memory.tmp.$$"
  if cat "$memory" >"$memorytmp" && printf -- '- [%s](memory/%s.md) — %s\n' "$title" "$slug" "$hook" >>"$memorytmp" \
    && mv "$facttmp" "$factfile" && mv "$memorytmp" "$memory"; then
    echo "memory.sh: wrote $factfile and indexed it in $memory"
    echo "memory.sh: search purpose, rules, routed docs, source, and existing facts first."
    echo "memory.sh: if one already states this, remove the new fact and update that source or its routing."
    echo "memory.sh: one fact per file — supersede in place with memory.sh supersede --slug <slug> --fact \"…\" (the body is rewritten, the date restamped, the filename kept), and drop it once no work here changes on it. Full contract: memory.md's header."
    printf 'written\t%s\t%s\n' "$slug" "$(digest_file "$factfile")"
    exit 0
  fi

  rm -f "$factfile"
  rm -f "$facttmp" "$memorytmp"
  refuse "could not publish the fact and its index line, so $factfile was removed" "Check that .agent/memory.md is writable, then run this call again"
  ;;

supersede)
  slug=""
  fact=""
  file=""
  expected=""
  scope=""
  type=""
  root="."
  while [ $# -gt 0 ]; do
    case "$1" in
    --slug)
      need_value "$@"
      slug="$2"; shift 2 ;;
    --fact)
      need_value "$@"
      fact="$2"; shift 2 ;;
    --file)
      need_value "$@"
      file="$2"; shift 2 ;;
    --expected)
      need_value "$@"
      expected="$2"; shift 2 ;;
    --scope)
      need_value "$@"
      scope="$2"; shift 2 ;;
    --type)
      need_value "$@"
      type="$2"; shift 2 ;;
    -h | --help)
      usage; exit 0 ;;
    --*)
      refuse_usage "unknown flag: $1" "Pass only the flags listed above" ;;
    *)
      root="$1"; shift ;;
    esac
  done

  if [ -z "$slug" ] || { [ -z "$fact" ] && [ -z "$file" ]; }; then
    refuse_usage "supersede needs --slug and one of --fact or --file" "Run this call again with both"
  fi
  if [ -n "$fact" ] && [ -n "$file" ]; then
    refuse "--fact and --file were both given" "Pass one of them"
  fi
  [ -z "$file" ] || read_body "$file"
  validate_slug "$slug"

  if [ -n "$scope" ]; then
    case "$scope" in
    project | package | root) ;;
    *)
      refuse "--scope must be project, package, or root (got '$scope')" "Pass one of those, or drop --scope" ;;
    esac
  fi
  if [ -n "$type" ]; then
    case "$type" in
    fact | reference) ;;
    *)
      refuse "--type must be fact or reference (got '$type')" "Pass one of those, or drop --type" ;;
    esac
  fi

  agent="$root/.agent"
  memory="$agent/memory.md"
  memdir="$agent/memory"
  factfile="$memdir/$slug.md"

  if [ ! -f "$memory" ]; then
    refuse "$memory does not exist, and memory.sh writes only to an initialized node" "Pass the folder that holds .agent/ as the last argument"
  fi
  memory_lock "$root"
  if [ ! -f "$factfile" ]; then
    refuse "$factfile does not exist, so there is nothing to supersede" "Use memory.sh new to write a new fact"
  fi
  if ! grep -qE "^- \[[^]]*\]\(memory/$slug\.md\)" "$memory" 2>/dev/null; then
    refuse "$memory does not index memory/$slug.md" "Add its index line, then run this call again"
  fi
  actual=$(digest_file "$factfile") || refuse "could not read $factfile" "Check that it is readable, then run this call again"
  if [ -n "$expected" ] && [ "$expected" != "$actual" ]; then
    refuse "stale --expected for $slug, whose current version is $actual" "Read the fact again, then run this call with --expected $actual" 3
  fi

  fm_get() {
    awk -v k="$1" '
      NR == 1 && $0 != "---" { exit }
      NR == 1 { next }
      $0 == "---" { exit }
      index($0, k ": ") == 1 { print substr($0, length(k) + 3); exit }
    ' "$factfile"
  }
  [ -n "$scope" ] || scope=$(fm_get scope)
  [ -n "$type" ] || type=$(fm_get type)
  [ -n "$scope" ] || scope="project"
  [ -n "$type" ] || type="fact"

  date_stamp=$(date +%Y-%m-%d)

  tmpfile="$factfile.tmp.$$"
  if {
    cat <<EOF
---
date: $date_stamp
scope: $scope
type: $type
---

EOF
    if [ -n "$file" ]; then cat "$body_tmp"; else printf '%s\n' "$fact"; fi
  } >"$tmpfile"
  then :
  else
    rm -f "$tmpfile"
    refuse "could not write $tmpfile, and $factfile is unchanged" "Check that .agent/memory/ is writable, then run this call again"
  fi
  if [ -n "$expected" ]; then
    actual=$(digest_file "$factfile") || { rm -f "$tmpfile"; refuse "could not read $factfile" "Check that it is readable, then run this call again"; }
    if [ "$expected" != "$actual" ]; then
      rm -f "$tmpfile"
      refuse "stale --expected for $slug immediately before publication, whose current version is $actual" "Read the fact again, then run this call with --expected $actual" 3
    fi
  fi
  if mv "$tmpfile" "$factfile"
  then
    echo "memory.sh: superseded $factfile and stamped $date_stamp"
    echo "memory.sh: the index line in $memory is unchanged — edit its title or hook by hand if the fact's hook moved."
    echo "memory.sh: drop the fact once no work here changes on it. Full contract: memory.md's header."
    printf 'superseded\t%s\t%s\n' "$slug" "$(digest_file "$factfile")"
    exit 0
  fi

  rm -f "$tmpfile"
  refuse "could not replace $factfile, which is unchanged" "Check that .agent/memory/ is writable, then run this call again"
  ;;

"")
  refuse_usage "no command was given" "Pass one of the commands listed above"
  ;;

*)
  refuse_usage "unknown command: $cmd" "Pass one of the commands listed above"
  ;;
esac
