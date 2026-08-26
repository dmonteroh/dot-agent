#!/usr/bin/env bash
# docs.sh — scaffolds an area doc and its architecture.md routing-table
# row as one operation: a two-place write that drifts if done by hand.
#
# Full documentation: scripts/docs/docs.md in the dot-agent repo.
#
# Usage: docs.sh new --name <file> --read-when "…" [root]
#
# root defaults to . — ".md" is appended to <file> if missing. Writes
# <root>/.agent/docs/<file> and appends a row to
# <root>/.agent/docs/architecture.md, creating it with a minimal routing
# header if it does not already exist.

set -u

usage() {
  cat <<'EOF'
Usage: docs.sh new --name <file> --read-when "…" [root]

root defaults to . — writes <root>/.agent/docs/<file> and a routing row in
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

  # --read-when lands in two one-line formats: the `<!-- Read when: … -->`
  # header and a `| file | hook |` routing-table row.
  nl='
'
  case "$readwhen" in
  *"$nl"*)
    echo "docs.sh: --read-when must be single-line" >&2
    exit 1 ;;
  *"|"*)
    echo "docs.sh: --read-when must not contain | — it becomes a routing-table cell" >&2
    exit 1 ;;
  *"-->"*)
    echo "docs.sh: --read-when must not contain --> — it would close the \"Read when:\" header comment early" >&2
    exit 1 ;;
  esac

  case "$name" in
  *.md) base="${name%.md}" ;;
  *) base="$name" ;;
  esac
  filename="$base.md"

  # One folder of nesting at most: an area that outgrew one file becomes
  # docs/<area>/<sub-doc>.md, and status.sh walks exactly one sublevel.
  case "$base" in
  */*/*)
    echo "docs.sh: --name may nest at most one folder deep (got '$name')" >&2
    exit 1 ;;
  */*)
    subdir="${base%%/*}"
    leaf="${base##*/}"
    if [ -z "$subdir" ]; then
      echo "docs.sh: --name parts must match [a-z0-9-]+ (got '$name')" >&2
      exit 1
    fi ;;
  *)
    subdir=""
    leaf="$base" ;;
  esac
  case "$subdir" in
  *[!a-z0-9-]*)
    echo "docs.sh: --name parts must match [a-z0-9-]+ (got '$name')" >&2
    exit 1 ;;
  esac
  case "$leaf" in
  *[!a-z0-9-]* | "")
    echo "docs.sh: --name parts must match [a-z0-9-]+ (got '$name')" >&2
    exit 1 ;;
  esac

  if [ "$leaf" = "architecture" ]; then
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

  mkdir -p "$(dirname "$doc")"

  title=$(printf '%s' "$leaf" | tr '-' ' ' | awk '{for(i=1;i<=NF;i++){$i=toupper(substr($i,1,1)) substr($i,2)} print}')

  # Two heredocs on purpose: the routing header interpolates, the header
  # contract must not (it carries backticks and would otherwise run as
  # command substitution). "Read when:" stays on line 1, where status.sh
  # looks for it.
  cat >"$doc" <<EOF
<!-- Read when: $readwhen -->
# $title
EOF
  cat >>"$doc" <<'EOF'
<!-- Agent-facing reference, not a human narrative: facts belong in tables
or one-fact-per-line bullets; prose carries only the *why*. Cite the code
or test path that pins a behavior instead of restating it. Timeless — no
change narration, no dates. Area traps go under `## Gotchas`. Restructuring
changes shape, never content: no tightening or splitting pass may drop an
operational fact — a name, value, command, path, or gotcha. Preferred
writer when this doc splits into docs/<area>/ sub-docs:
.agent/scripts/docs.sh new (scaffolds each sub-doc and its routing row
together). -->
EOF

  if [ ! -s "$arch" ]; then
    cat >"$arch" <<'EOF'
# Architecture routing table
<!-- One entry per doc in this directory, in this format:

### `<file>`
- **Read when:** <hook — the same text as the doc's own "Read when:" header>
- **Sections:** <the doc's `## ` headings, separated by " · ">

Read when: is precision — skip the doc when the hook doesn't match. Sections:
is recall — find the doc that holds a topic its hook never names. Refresh both
when the doc changes: status.sh flags a hook that disagrees with the doc's own
header, and a `## ` heading missing from Sections. A section entry may say more
than its heading; it may not say less. A doc whose hook is unconditional
("ANY <area> work — check here before creating a new …") is a catalog: it loads
for every task in its area, not only when a hook matches. -->
EOF
  fi

  {
    printf -- '\n### `%s`\n' "$filename"
    printf -- '- **Read when:** %s\n' "$readwhen"
    printf -- '- **Sections:**\n'
  } >>"$arch"

  echo "docs.sh: wrote $doc and added its routing entry to $arch"
  exit 0
  ;;

*)
  usage >&2
  exit 1
  ;;
esac
