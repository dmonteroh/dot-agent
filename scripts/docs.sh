#!/usr/bin/env bash
# docs.sh — scaffolds an area doc and its architecture.md routing-table
# row as one operation. This is a two-place write that drifts if done by
# hand; the point of the script is to make that drift impossible (the
# INDEX check in status.sh does the detecting for docs written by hand).
#
# Usage: docs.sh new --name <file> --read-when "…" [root]
#
# root defaults to . ; ".md" is appended to <file> if missing. Writes
# <root>/.agent/docs/<file> and appends a row to
# <root>/.agent/docs/architecture.md, creating it with a minimal routing
# header if it does not already exist.

set -u

usage() {
  cat <<'EOF'
Usage: docs.sh new --name <file> --read-when "…" [root]

root defaults to . ; writes <root>/.agent/docs/<file> and a routing row in
<root>/.agent/docs/architecture.md.
EOF
}

cmd="${1:-}"
[ $# -ge 1 ] && shift

case "$cmd" in
new)
  name=""
  readwhen=""
  root="."
  while [ $# -gt 0 ]; do
    case "$1" in
    --name)
      [ $# -ge 2 ] || { echo "docs.sh: --name needs a value" >&2; usage >&2; exit 1; }
      name="$2"; shift 2 ;;
    --read-when)
      [ $# -ge 2 ] || { echo "docs.sh: --read-when needs a value" >&2; usage >&2; exit 1; }
      readwhen="$2"; shift 2 ;;
    -h | --help)
      usage; exit 0 ;;
    --*)
      echo "docs.sh: unknown flag: $1" >&2; usage >&2; exit 1 ;;
    *)
      root="$1"; shift ;;
    esac
  done

  if [ -z "$name" ] || [ -z "$readwhen" ]; then
    echo "docs.sh: --name and --read-when are both required" >&2
    usage >&2
    exit 1
  fi

  case "$name" in
  *.md) base="${name%.md}" ;;
  *) base="$name" ;;
  esac
  filename="$base.md"

  case "$base" in
  *[!a-z0-9-]* | "")
    echo "docs.sh: --name must match [a-z0-9-]+(.md) (got '$name')" >&2
    exit 1 ;;
  esac

  if [ "$base" = "architecture" ]; then
    echo "docs.sh: 'architecture' is the routing table itself, not a scaffoldable doc" >&2
    exit 1
  fi

  agent="$root/.agent"
  docs="$agent/docs"
  doc="$docs/$filename"
  arch="$docs/architecture.md"

  if [ ! -d "$agent" ]; then
    echo "docs.sh: $agent does not exist — refusing to write outside an initialized node" >&2
    exit 1
  fi
  if [ -e "$doc" ]; then
    echo "docs.sh: $doc already exists — refusing to overwrite" >&2
    exit 1
  fi

  mkdir -p "$docs"

  title=$(printf '%s' "$base" | tr '-' ' ' | awk '{for(i=1;i<=NF;i++){$i=toupper(substr($i,1,1)) substr($i,2)} print}')

  cat >"$doc" <<EOF
<!-- Read when: $readwhen -->
# $title
EOF

  if [ ! -s "$arch" ]; then
    cat >"$arch" <<'EOF'
# Architecture routing table
<!-- One row per doc in this directory. Format: | file | read-when hook |. -->

| Doc | Read when |
|---|---|
EOF
  fi

  printf -- '| %s | %s |\n' "$filename" "$readwhen" >>"$arch"

  echo "docs.sh: wrote $doc and added its routing row to $arch"
  exit 0
  ;;

*)
  usage >&2
  exit 1
  ;;
esac
