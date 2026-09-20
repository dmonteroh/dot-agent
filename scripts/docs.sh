#!/usr/bin/env bash

set -u

usage() {
  cat <<'EOF'
Usage: docs.sh new --name <file> --read-when "…" [root]
       docs.sh rehook --name <file> --read-when "…" [root]

root defaults to . — new writes <root>/.agent/docs/<file> and a routing row
in <root>/.agent/docs/architecture.md; rehook rewrites an existing doc's
"Read when:" header and its routing row to the new text, both or neither.
EOF
}

need_value() {
  case "${2-}" in
  --name|--read-when)
    echo "docs.sh: $1 needs a value, got the flag $2" >&2
    usage >&2
    exit 1 ;;
  esac
  if [ $# -lt 2 ]; then
    echo "docs.sh: $1 needs a value" >&2
    usage >&2
    exit 1
  fi
}

cmd="${1:-}"
[ $# -ge 1 ] && shift

case "$cmd" in
-h|--help)
  usage
  exit 0 ;;
new)
  name=""
  readwhen=""
  root="."
  while [ $# -gt 0 ]; do
    case "$1" in
    --name)
      need_value "$@"
      name="$2"; shift 2 ;;
    --read-when)
      need_value "$@"
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
  -*)
    echo "docs.sh: --name parts must not start with - (got '$name') — the filename would read as a flag" >&2
    exit 1 ;;
  esac
  case "$leaf" in
  -*)
    echo "docs.sh: --name parts must not start with - (got '$name') — the filename would read as a flag" >&2
    exit 1 ;;
  esac
  case "$subdir" in
  *[!abcdefghijklmnopqrstuvwxyz0123456789-]*)
    echo "docs.sh: --name parts must match [a-z0-9-]+ (got '$name')" >&2
    exit 1 ;;
  esac
  case "$leaf" in
  *[!abcdefghijklmnopqrstuvwxyz0123456789-]* | "")
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

  if cat >"$doc" <<EOF
<!-- Read when: $readwhen -->
# $title
EOF
  then :
  else
    echo "docs.sh: could not write $doc — nothing was written" >&2
    rm -f "$doc"
    exit 1
  fi

  if [ ! -s "$arch" ]; then
    cat >"$arch" <<'EOF'
# Architecture routing table
<!-- One entry per doc in this directory, in this format:

### `<file>`
- **Read when:** <hook — the same text as the doc's own "Read when:" header>
- **Sections:** <the doc's `## ` headings, separated by " · ">

Read when: is precision — skip the doc when the hook doesn't match. Sections: is recall — find the doc that holds a topic its hook never names. Refresh both when the doc changes: status.sh flags a hook that disagrees with the doc's own header, and a `## ` heading missing from Sections. A section entry may say more than its heading. It may not say less. A doc whose hook is unconditional ("ANY <area> work — check here before creating a new …") is a catalog. It loads for every task in its area, even when no hook matches.

The docs in this table are the node's design of record: a design fact, number, or open question lives in one of them, and a design change lands there. Material under `archive/` is superseded — never an entry here, never routed, and never cited as intent by a routed or always-loaded file. -->
EOF
  fi

  if {
    printf -- '\n### `%s`\n' "$filename"
    printf -- '- **Read when:** %s\n' "$readwhen"
    printf -- '- **Sections:**\n'
  } >>"$arch"
  then
    echo "docs.sh: wrote $doc and added its routing entry to $arch"
    echo "docs.sh: agent-facing reference — facts as tables or one-fact-per-line bullets, prose only for the *why*, timeless, area traps under ## Gotchas. Restructuring changes shape, never content: no tightening or split may drop a name, value, command, path, or gotcha. Full contract: the preset's docs/ bullet."
    exit 0
  fi

  echo "docs.sh: could not append the routing entry to $arch — removed $doc, nothing was written" >&2
  rm -f "$doc"
  exit 1
  ;;

rehook)
  name=""
  readwhen=""
  root="."
  while [ $# -gt 0 ]; do
    case "$1" in
    --name)
      need_value "$@"
      name="$2"; shift 2 ;;
    --read-when)
      need_value "$@"
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
  *.md) filename="$name" ;;
  *) filename="$name.md" ;;
  esac
  case "$filename" in
  /* | ../* | */../* | *"$nl"*)
    echo "docs.sh: --name must be a path under .agent/docs/ (got '$name')" >&2
    exit 1 ;;
  esac
  docs="$root/.agent/docs"
  doc="$docs/$filename"
  arch="$docs/architecture.md"
  if [ ! -s "$doc" ]; then
    echo "docs.sh: $doc does not exist — rehook edits an existing doc; use new to create one" >&2
    exit 1
  fi
  if ! head -n 5 "$doc" | grep -qF "Read when:"; then
    echo "docs.sh: $doc has no \"Read when:\" header in its first five lines — add one by hand, then rehook" >&2
    exit 1
  fi
  if [ ! -s "$arch" ] || ! grep -qF "### \`$filename\`" "$arch"; then
    echo "docs.sh: $arch has no entry for $filename — add the routing entry first" >&2
    exit 1
  fi
  HOOK="$readwhen" awk '
    NR <= 5 && !done && /<!-- Read when: .* -->$/ { print "<!-- Read when: " ENVIRON["HOOK"] " -->"; done = 1; next }
    { print }
  ' "$doc" >"$doc.rehook.tmp" || { rm -f "$doc.rehook.tmp"; exit 1; }
  HOOK="$readwhen" FILE="$filename" awk '
    $0 == "### `" ENVIRON["FILE"] "`" { inb = 1; print; next }
    inb && index($0, "### ") == 1 { inb = 0 }
    inb && /^- \*\*Read when:\*\* / { print "- **Read when:** " ENVIRON["HOOK"]; inb = 0; next }
    { print }
  ' "$arch" >"$arch.rehook.tmp" || { rm -f "$doc.rehook.tmp" "$arch.rehook.tmp"; exit 1; }
  if ! grep -qF -- "- **Read when:** $readwhen" "$arch.rehook.tmp"; then
    rm -f "$doc.rehook.tmp" "$arch.rehook.tmp"
    echo "docs.sh: could not find a \"- **Read when:**\" line under the $filename entry in $arch — nothing was changed" >&2
    exit 1
  fi
  mv "$doc.rehook.tmp" "$doc" && mv "$arch.rehook.tmp" "$arch" || {
    rm -f "$doc.rehook.tmp" "$arch.rehook.tmp"
    echo "docs.sh: rehook failed mid-swap — check $doc and $arch by hand" >&2
    exit 1
  }
  echo "docs.sh: rehooked docs/$filename — header and routing row now read: $readwhen"
  exit 0
  ;;

"")
  usage >&2
  exit 1
  ;;

*)
  echo "docs.sh: unknown command: $cmd" >&2
  usage >&2
  exit 1
  ;;
esac
