#!/usr/bin/env bash
# docs.sh — scaffolds an area doc and its architecture.md routing-table
# row as one operation: a two-place write that drifts if done by hand.
#
# Full documentation: scripts/docs/docs.md in the dot-agent repo.
#
# Usage: docs.sh new --name <file> --read-when "…" [root]
#        docs.sh rehook --name <file> --read-when "…" [root]
#
# rehook replaces an existing doc's "Read when:" hook in both places at
# once — the doc's own header line and its architecture.md routing row —
# which is the fix for a routed doc a session failed to reach: the hook
# did not name the word the task used. Two hand edits drift; one command
# does not.
#
# root defaults to . — ".md" is appended to <file> if missing. Writes
# <root>/.agent/docs/<file> and appends a row to
# <root>/.agent/docs/architecture.md, creating it with a minimal routing
# header if it does not already exist.

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

# A token beginning with -- is the next flag, not this flag's value:
# `--read-when --name` otherwise writes the literal text "--name" into the
# doc's "Read when:" header. Call as `need_value "$@"` from inside the
# parse loop, where $1 is the flag and $2 is its candidate value.
need_value() {
  # Reject only a value that is one of this script's own flags: that is
  # the real mistake, a flag whose value was left out. A free-text value
  # may legitimately begin with -- , so shape alone is not the test.
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

# Help is a top-level arm, before the subcommand dispatch, so it works
# the same way here as in log.sh and links.sh. It used to reach the
# catch-all and read as an unknown command.
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
  # Each part becomes a path component. A leading - makes that filename read
  # as a flag to every later tool that globs the directory, so it is refused
  # ahead of the character check, which would otherwise admit it.
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
  # The class is spelled out character by character rather than as [a-z0-9-]:
  # inside a bracket expression a-z is a collation range, not an ASCII range,
  # in every locale but C. Under en_US.UTF-8 *[!a-z0-9-]* matches nothing in
  # "AuthFlow" and the name passes. Listing the characters means the same
  # thing everywhere, and unlike pinning LC_ALL it leaves date's and grep's
  # locale alone.
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

  # The doc opens with its routing hook and its title, and no shape
  # contract. Every canonical singleton carries its own because there is
  # one of it. docs/ is the N-file tier — one doc per area, another per
  # split into docs/<area>/, another per reference — where a header is
  # paid by every session that only opens the file and says what the
  # preset, loaded in all of them, already says. The contract reaches the
  # writer through this script's output instead. "Read when:" stays on
  # line 1, where status.sh looks for it.
  # `if cmd >file; then … else`, not `if ! cmd >file`: bash 3.2 does not
  # run the negation when the redirection is what failed, so the ! form
  # never reaches its then-branch. Verified against 3.2.57.
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

  # Both writes or neither. The routing append is the one that fails in the
  # field (a read-only architecture.md, a full disk), and reporting success
  # after it fails ships exactly the drift this script exists to prevent —
  # status.sh then flags the doc as INDEX. The orphan is removed rather than
  # left: this run created it, so nothing of the writer's is lost, and the
  # retry that follows would otherwise hit "already exists".
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
  # Both files are rewritten to temporaries first and swapped in together:
  # a hook changed in one place and not the other is the drift status.sh
  # flags as INDEX, and the reason this is one command.
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
