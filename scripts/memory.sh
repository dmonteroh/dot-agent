#!/usr/bin/env bash

set -u
export LC_ALL=C
unset CDPATH

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

need_value() {
  case "${2-}" in
  --slug|--title|--hook|--fact|--file|--expected|--scope|--type|--query|--limit)
    echo "memory.sh: $1 needs a value, got the flag $2" >&2
    usage >&2
    exit 1 ;;
  esac
  if [ $# -lt 2 ]; then
    echo "memory.sh: $1 needs a value" >&2
    usage >&2
    exit 1
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
    echo "memory.sh: could not create a temporary body file" >&2
    exit 1
  }
  if [ "$1" = - ]; then
    cat >"$body_tmp" || exit 1
  elif [ -f "$1" ]; then
    cat "$1" >"$body_tmp" || exit 1
  else
    echo "memory.sh: --file $1 does not exist" >&2
    exit 1
  fi
}

digest_file() {
  git hash-object --no-filters -- "$1"
}

lookup_add() {
  la_rel="$1"
  la_file="$2"
  if printf '%s%s' "$la_rel" "$la_file" | grep -q '[[:cntrl:]]'; then
    echo "memory.sh: canonical lookup path contains a control character and cannot be represented safely" >&2
    return 1
  fi
  if [ ! -e "$la_file" ] && [ ! -L "$la_file" ]; then
    return 0
  fi
  if [ ! -f "$la_file" ] || [ -L "$la_file" ]; then
    echo "memory.sh: canonical lookup path is not a regular non-symlink file: $la_rel" >&2
    return 1
  fi
  la_parent=$(cd "$(dirname "$la_file")" 2>/dev/null && pwd -P) || {
    echo "memory.sh: cannot resolve canonical lookup parent for $la_rel" >&2
    return 1
  }
  case "$la_parent" in
  "$lookup_root_phys"|"$lookup_root_phys"/*) ;;
  *) echo "memory.sh: canonical lookup path resolves outside the project: $la_rel" >&2; return 1 ;;
  esac
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
    echo "memory.sh: could not read routed docs from $lr_arch" >&2
    return 1
  fi
  while IFS= read -r lr_name; do
    case "$lr_name" in
    ""|/*|.|..|../*|*/../*|*/..|*/.|*'/./'*|./*|*'`'*|*'|'*|*'\'*|*.md.md) lr_bad=1 ;;
    *.md) lr_bad=0 ;;
    *) lr_bad=1 ;;
    esac
    if [ "$lr_bad" -ne 0 ] || printf '%s' "$lr_name" | grep -q '[[:cntrl:]]'; then
      rm -f "$lr_names"
      echo "memory.sh: routed canonical document has an unsafe path: $lr_name" >&2
      return 1
    fi
    if [ ! -e "$1/.agent/docs/$lr_name" ] && [ ! -L "$1/.agent/docs/$lr_name" ]; then
      rm -f "$lr_names"
      echo "memory.sh: routed canonical document is missing: .agent/docs/$lr_name" >&2
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
  if printf '%s' "$rl_root" | grep -q '[[:cntrl:]]'; then
    echo "memory.sh: project root contains a control character and cannot be searched safely" >&2
    return 1
  fi
  lookup_root_phys=$(cd "$rl_root" 2>/dev/null && pwd -P) || {
    echo "memory.sh: cannot resolve project root: $rl_root" >&2
    return 1
  }
  if printf '%s' "$lookup_root_phys" | grep -q '[[:cntrl:]]'; then
    echo "memory.sh: physical project root contains a control character and cannot be searched safely" >&2
    return 1
  fi
  lookup_list=$(mktemp "${TMPDIR:-/tmp}/memory-lookup-list.XXXXXX") || exit 1
  lookup_hits=$(mktemp "${TMPDIR:-/tmp}/memory-lookup-hits.XXXXXX") || exit 1
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
    echo "memory.sh: canonical lookup could not read all selected files" >&2
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
    echo "memory.sh: --slug must not start with - (got '$1') — the filename would read as a flag" >&2
    exit 1 ;;
  esac
  case "$1" in
  *[!abcdefghijklmnopqrstuvwxyz0123456789-]* | "")
    echo "memory.sh: --slug must match [a-z0-9-]+ (got '$1')" >&2
    exit 1 ;;
  esac
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
    --*) echo "memory.sh: unknown flag: $1" >&2; usage >&2; exit 1 ;;
    *) root="$1"; shift ;;
    esac
  done
  [ -n "$query" ] || { echo "memory.sh: lookup requires --query <text>" >&2; exit 1; }
  case "$limit" in *[!0-9]*|"") echo "memory.sh: --limit must be an integer from 1 to 100" >&2; exit 1 ;; esac
  [ "$limit" -ge 1 ] && [ "$limit" -le 100 ] || { echo "memory.sh: --limit must be an integer from 1 to 100" >&2; exit 1; }
  [ -d "$root/.agent" ] || { echo "memory.sh: $root/.agent does not exist" >&2; exit 1; }
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
      echo "memory.sh: unknown flag: $1" >&2; usage >&2; exit 1 ;;
    *)
      root="$1"; shift ;;
    esac
  done

  if [ -z "$slug" ] || [ -z "$title" ] || [ -z "$hook" ] || { [ -z "$fact" ] && [ -z "$file" ]; }; then
    echo "memory.sh: --slug, --title, --hook, and one of --fact or --file are required" >&2
    usage >&2
    exit 1
  fi
  if [ -n "$fact" ] && [ -n "$file" ]; then
    echo "memory.sh: use exactly one of --fact or --file" >&2
    exit 1
  fi
  [ -z "$file" ] || read_body "$file"

  validate_slug "$slug"

  case "$title" in
  *\[* | *\]*)
    echo "memory.sh: --title must not contain [ or ] — it becomes the index link text" >&2
    exit 1 ;;
  esac
  nl='
'
  case "$title$hook" in
  *"$nl"*)
    echo "memory.sh: --title and --hook must be single-line" >&2
    exit 1 ;;
  esac

  case "$scope" in
  project | package | root) ;;
  *)
    echo "memory.sh: --scope must be project, package, or root (got '$scope')" >&2
    exit 1 ;;
  esac

  case "$type" in
  fact | reference) ;;
  *)
    echo "memory.sh: --type must be fact or reference (got '$type')" >&2
    exit 1 ;;
  esac

  agent="$root/.agent"
  memory="$agent/memory.md"
  memdir="$agent/memory"
  factfile="$memdir/$slug.md"

  if [ ! -f "$memory" ]; then
    echo "memory.sh: $memory does not exist — refusing to write outside an initialized node" >&2
    exit 1
  fi
  if [ ! -w "$memory" ]; then
    echo "memory.sh: $memory is not writable — refusing to publish an unindexable fact" >&2
    exit 1
  fi
  if [ -e "$factfile" ]; then
    echo "memory.sh: $factfile already exists — refusing to overwrite; run memory.sh supersede --slug $slug --fact \"…\" to rewrite it, or pick a new slug" >&2
    exit 1
  fi
  if grep -qE "^- \[[^]]*\]\(memory/$slug\.md\)" "$memory" 2>/dev/null; then
    echo "memory.sh: $memory already indexes memory/$slug.md — refusing to add a duplicate index line" >&2
    exit 1
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
    echo "memory.sh: could not stage $factfile — nothing was written" >&2
    rm -f "$facttmp"
    exit 1
  fi

  memorytmp="$memory.tmp.$$"
  if cat "$memory" >"$memorytmp" && printf -- '- [%s](memory/%s.md) — %s\n' "$title" "$slug" "$hook" >>"$memorytmp" \
    && mv "$facttmp" "$factfile" && mv "$memorytmp" "$memory"; then
    echo "memory.sh: wrote $factfile and indexed it in $memory"
    echo "memory.sh: search purpose, rules, routed docs, source, and existing facts first."
    echo "memory.sh: if one already states this, remove the new fact and update that source or its routing."
    echo "memory.sh: one fact per file — supersede in place with memory.sh supersede --slug <slug> --fact \"…\" (the body is rewritten, the date restamped, the filename kept), and drop it once no work here changes on it. Full contract: memory.md's header."
    exit 0
  fi

  echo "memory.sh: could not publish the fact and index — removed $factfile" >&2
  rm -f "$factfile"
  rm -f "$facttmp" "$memorytmp"
  exit 1
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
      echo "memory.sh: unknown flag: $1" >&2; usage >&2; exit 1 ;;
    *)
      root="$1"; shift ;;
    esac
  done

  if [ -z "$slug" ] || { [ -z "$fact" ] && [ -z "$file" ]; }; then
    echo "memory.sh: supersede needs --slug and one of --fact or --file" >&2
    usage >&2
    exit 1
  fi
  if [ -n "$fact" ] && [ -n "$file" ]; then
    echo "memory.sh: use exactly one of --fact or --file" >&2
    exit 1
  fi
  [ -z "$file" ] || read_body "$file"
  validate_slug "$slug"

  if [ -n "$scope" ]; then
    case "$scope" in
    project | package | root) ;;
    *)
      echo "memory.sh: --scope must be project, package, or root (got '$scope')" >&2
      exit 1 ;;
    esac
  fi
  if [ -n "$type" ]; then
    case "$type" in
    fact | reference) ;;
    *)
      echo "memory.sh: --type must be fact or reference (got '$type')" >&2
      exit 1 ;;
    esac
  fi

  agent="$root/.agent"
  memory="$agent/memory.md"
  memdir="$agent/memory"
  factfile="$memdir/$slug.md"

  if [ ! -f "$memory" ]; then
    echo "memory.sh: $memory does not exist — refusing to write outside an initialized node" >&2
    exit 1
  fi
  if [ ! -f "$factfile" ]; then
    echo "memory.sh: $factfile does not exist — nothing to supersede; use memory.sh new to write a new fact" >&2
    exit 1
  fi
  if ! grep -qE "^- \[[^]]*\]\(memory/$slug\.md\)" "$memory" 2>/dev/null; then
    echo "memory.sh: $memory does not index memory/$slug.md — add its index line first, then supersede" >&2
    exit 1
  fi
  actual=$(digest_file "$factfile") || exit 1
  if [ -n "$expected" ] && [ "$expected" != "$actual" ]; then
    echo "memory.sh: stale --expected for $slug — current version: $actual" >&2
    exit 3
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
    echo "memory.sh: could not write $tmpfile — $factfile is unchanged" >&2
    rm -f "$tmpfile"
    exit 1
  fi
  if [ -n "$expected" ]; then
    actual=$(digest_file "$factfile") || { rm -f "$tmpfile"; exit 1; }
    if [ "$expected" != "$actual" ]; then
      echo "memory.sh: stale --expected for $slug immediately before publication — current version: $actual" >&2
      rm -f "$tmpfile"
      exit 3
    fi
  fi
  if mv "$tmpfile" "$factfile"
  then
    echo "memory.sh: superseded $factfile and stamped $date_stamp"
    echo "memory.sh: the index line in $memory is unchanged — edit its title or hook by hand if the fact's hook moved."
    echo "memory.sh: drop the fact once no work here changes on it. Full contract: memory.md's header."
    exit 0
  fi

  echo "memory.sh: could not replace $factfile — it is unchanged" >&2
  rm -f "$tmpfile"
  exit 1
  ;;

"")
  usage >&2
  exit 1
  ;;

*)
  echo "memory.sh: unknown command: $cmd" >&2
  usage >&2
  exit 1
  ;;
esac
