#!/usr/bin/env bash
# memory.sh — scaffolds a fact file and its memory.md index line as one
# operation: a two-place write that drifts if done by hand.
#
# Full documentation: scripts/docs/memory.md in the dot-agent repo.
#
# Usage:
#   memory.sh new --slug <slug> --title <title> --hook <hook> --fact "…" [--scope <project|package|root>] [--type <fact|reference>] [root]
#   memory.sh supersede --slug <slug> --fact "…" [--scope <project|package|root>] [--type <fact|reference>] [root]
#
# root defaults to . — scope defaults to project, type to fact. new writes
# <root>/.agent/memory/<slug>.md and appends its index line to
# <root>/.agent/memory.md — both or neither: every check runs before any
# write happens. supersede rewrites an existing fact file's body, restamps
# its date, and leaves the index line alone.

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

# A token beginning with -- is the next flag, not this flag's value:
# `--fact --scope` otherwise writes the literal text "--scope" as the fact.
# Call as `need_value "$@"` from inside the parse loop, where $1 is the
# flag and $2 is its candidate value.
need_value() {
  # Reject only a value that is one of this script's own flags: that is
  # the real mistake, a flag whose value was left out. A free-text value
  # may legitimately begin with -- , so shape alone is not the test.
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

# The slug becomes a filename in both subcommands, so the check is shared.
# A leading - makes that filename read as a flag to every later tool that
# globs the directory, so it is refused ahead of the character check, which
# would otherwise admit it.
#
# The class is spelled out character by character rather than as [a-z0-9-]:
# inside a bracket expression a-z is a collation range, not an ASCII range,
# in every locale but C. Under en_US.UTF-8 *[!a-z0-9-]* matches nothing in
# "UpperCase" and the slug passes. Listing the characters means the same
# thing everywhere, and unlike pinning LC_ALL it leaves date's and grep's
# locale alone.
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

# Help is a top-level arm, before the subcommand dispatch, so it works
# the same way here as in log.sh and links.sh. It used to reach the
# catch-all and read as an unknown command.
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

  # Title and hook become the one-line index entry `- [title](…) — hook`.
  # Brackets or newlines in them would corrupt that line's format.
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
  # Anchor to the index line's own link, not the whole line: a hook that
  # merely mentions this path must not block a legitimately new slug.
  if grep -qE "^- \[[^]]*\]\(memory/$slug\.md\)" "$memory" 2>/dev/null; then
    echo "memory.sh: $memory already indexes memory/$slug.md — refusing to add a duplicate index line" >&2
    exit 1
  fi

  mkdir -p "$memdir"
  date_stamp=$(date +%Y-%m-%d)

  # Frontmatter and the fact, and no header contract. Every other canonical
  # file carries its own because there is one of it. memory/ is the only
  # tier with N files, where a header is paid once per fact and outweighs
  # the fact itself. It lives once in memory.md's header, which loads every
  # session and is the tier's index.

  # `if cmd >file; then … else`, not `if ! cmd >file`: bash 3.2 does not run
  # the negation when a compound command's own redirection is what failed,
  # so the ! form is a trap the moment either write grows into a { } group.
  # Both writers here use the same shape for that reason.
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

  # Both writes or neither. The index append is the one that fails in the
  # field (a read-only memory.md, a full disk), and reporting success after
  # it fails ships exactly the drift this script exists to prevent —
  # status.sh then flags the fact file as REPAIR. The orphan is removed
  # rather than left: this run created it, so nothing of the writer's is
  # lost, and the retry that follows would otherwise hit "already exists".
  #
  # The contract reaches the writer through the script's output rather than
  # through a header copied into the file. Same words, but they arrive in
  # the session holding the fact in hand and cost nothing on every later
  # read. A header would be paid by every session that only opens the file.
  # It belongs to the success path only: a failed write has no fact to
  # supersede, and the reminder would read as a confirmation.
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

  # Empty means "keep what the file already carries". Validate only what
  # was actually supplied, so an override is held to the same values new is.
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
  # Superseding an unindexed fact file would leave the two-place write
  # exactly as split as writing one by hand does, which is the drift this
  # script exists to prevent. status.sh already flags the split; repairing
  # the index is the writer's job, and it is one line.
  if ! grep -qE "^- \[[^]]*\]\(memory/$slug\.md\)" "$memory" 2>/dev/null; then
    echo "memory.sh: $memory does not index memory/$slug.md — add its index line first, then supersede" >&2
    exit 1
  fi

  # Read the values being carried forward from the leading frontmatter
  # block only: a `scope:` line further down is body text, not metadata.
  # A file missing the block, or missing a key inside it, falls back to the
  # same defaults new uses — the rewrite repairs the frontmatter either way.
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

  # Write beside the file and rename over it. A truncating write that fails
  # partway leaves the fact half-gone with no copy anywhere — the one
  # outcome worse than refusing. mv within the same directory is atomic.
  #
  # `if cmd >file; then … else`, not `if ! cmd >file`: bash 3.2 does not run
  # the negation when a compound command's own redirection is what failed,
  # so the ! form is a trap the moment the write grows into a { } group.
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
