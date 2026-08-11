#!/usr/bin/env bash
# memory.sh — scaffolds a fact file and its memory.md index line as one
# operation. This is a two-place write that drifts if done by hand; the
# point of the script is to make that drift impossible, not just detect it
# (status.sh's REPAIR check does the detecting for facts written by hand).
# No size gate: writes are never refused for length; status.sh flags
# outliers on the load path for grooming.
#
# Usage:
#   memory.sh new --slug <slug> --title <title> --hook <hook> --fact "…" [--scope <project|package|root>] [--type <fact|reference>] [root]
#
# root defaults to . ; scope defaults to project, type to fact. Writes
# <root>/.agent/memory/<slug>.md and appends its index line to
# <root>/.agent/memory.md — both or neither: every check runs before any
# write happens.

set -u

usage() {
  cat <<'EOF'
Usage: memory.sh new --slug <slug> --title <title> --hook <hook> --fact "…" [--scope <project|package|root>] [--type <fact|reference>] [root]

root defaults to . ; scope defaults to project, type to fact. Writes
<root>/.agent/memory/<slug>.md and indexes it in <root>/.agent/memory.md.
EOF
}

cmd="${1:-}"
[ $# -ge 1 ] && shift

case "$cmd" in
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
      [ $# -ge 2 ] || { echo "memory.sh: --slug needs a value" >&2; usage >&2; exit 1; }
      slug="$2"; shift 2 ;;
    --title)
      [ $# -ge 2 ] || { echo "memory.sh: --title needs a value" >&2; usage >&2; exit 1; }
      title="$2"; shift 2 ;;
    --hook)
      [ $# -ge 2 ] || { echo "memory.sh: --hook needs a value" >&2; usage >&2; exit 1; }
      hook="$2"; shift 2 ;;
    --fact)
      [ $# -ge 2 ] || { echo "memory.sh: --fact needs a value" >&2; usage >&2; exit 1; }
      fact="$2"; shift 2 ;;
    --scope)
      [ $# -ge 2 ] || { echo "memory.sh: --scope needs a value" >&2; usage >&2; exit 1; }
      scope="$2"; shift 2 ;;
    --type)
      [ $# -ge 2 ] || { echo "memory.sh: --type needs a value" >&2; usage >&2; exit 1; }
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

  case "$slug" in
  *[!a-z0-9-]* | "")
    echo "memory.sh: --slug must match [a-z0-9-]+ (got '$slug')" >&2
    exit 1 ;;
  esac

  # Title and hook become the one-line index entry `- [title](…) — hook`;
  # brackets or newlines in them would corrupt that line's format.
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
    echo "memory.sh: $factfile already exists — refusing to overwrite; supersede in place by hand, or pick a new slug" >&2
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
  # file carries its own because there is one of it; memory/ is the only
  # tier with N files, and at ~60 words a fact the contract outweighed the
  # facts it governed 1.4 to 1 on a 15-fact field node. It lives once in
  # memory.md's header, which loads every session and is the tier's index.

  cat >"$factfile" <<EOF
---
date: $date_stamp
scope: $scope
type: $type
---

$fact
EOF

  printf -- '- [%s](memory/%s.md) — %s\n' "$title" "$slug" "$hook" >>"$memory"

  # The contract reaches the writer through the script's output rather than
  # through a header copied into the file. Same words, but they arrive in
  # the session holding the fact in hand and cost nothing on every later
  # read; a header would be paid by every session that only opens the file.
  echo "memory.sh: wrote $factfile and indexed it in $memory"
  echo "memory.sh: one fact per file — supersede in place (rewrite the fact and the date, keep the filename), and drop it once no work here changes on it. Full contract: memory.md's header."
  exit 0
  ;;

*)
  usage >&2
  exit 1
  ;;
esac
