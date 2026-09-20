#!/usr/bin/env bash

set -u

usage() {
  cat <<'EOF'
Usage: memory.sh new --slug <slug> --title <title> --hook <hook> --fact "…" [--scope <project|package|root>] [--type <fact|reference>] [root]
       memory.sh supersede --slug <slug> --fact "…" [--scope <project|package|root>] [--type <fact|reference>] [root]

root defaults to . — scope defaults to project, type to fact. new writes
<root>/.agent/memory/<slug>.md and indexes it in <root>/.agent/memory.md.
supersede rewrites an existing fact file's body, restamps its date, and
leaves the index line alone.
EOF
}

need_value() {
  case "${2-}" in
  --slug|--title|--hook|--fact|--scope|--type)
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
new)
  slug=""
  title=""
  hook=""
  fact=""
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

  if [ -z "$slug" ] || [ -z "$title" ] || [ -z "$hook" ] || [ -z "$fact" ]; then
    echo "memory.sh: --slug, --title, --hook, and --fact are all required" >&2
    usage >&2
    exit 1
  fi

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


  if cat >"$factfile" <<EOF
---
date: $date_stamp
scope: $scope
type: $type
---

$fact
EOF
  then :
  else
    echo "memory.sh: could not write $factfile — nothing was written" >&2
    rm -f "$factfile"
    exit 1
  fi

  if printf -- '- [%s](memory/%s.md) — %s\n' "$title" "$slug" "$hook" >>"$memory"
  then
    echo "memory.sh: wrote $factfile and indexed it in $memory"
    echo "memory.sh: search purpose, rules, routed docs, source, and existing facts first."
    echo "memory.sh: if one already states this, remove the new fact and update that source or its routing."
    echo "memory.sh: one fact per file — supersede in place with memory.sh supersede --slug <slug> --fact \"…\" (the body is rewritten, the date restamped, the filename kept), and drop it once no work here changes on it. Full contract: memory.md's header."
    exit 0
  fi

  echo "memory.sh: could not append the index line to $memory — removed $factfile, nothing was written" >&2
  rm -f "$factfile"
  exit 1
  ;;

supersede)
  slug=""
  fact=""
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

  if [ -z "$slug" ] || [ -z "$fact" ]; then
    echo "memory.sh: supersede needs --slug and --fact" >&2
    usage >&2
    exit 1
  fi
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
  if cat >"$tmpfile" <<EOF
---
date: $date_stamp
scope: $scope
type: $type
---

$fact
EOF
  then :
  else
    echo "memory.sh: could not write $tmpfile — $factfile is unchanged" >&2
    rm -f "$tmpfile"
    exit 1
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
