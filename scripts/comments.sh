#!/usr/bin/env bash
# comments.sh — the comment gate. Flags comments a diff adds to source
# files, against the contract's comment rule. BLOCK (exit 1): the comment
# cites what a fresh clone cannot open. REVIEW (exit 0): every other added
# comment, for the author to justify or delete.
#
# Tunables: comments.conf beside this script, which lists every key.
# Full documentation: scripts/docs/comments.md in the dot-agent repo.
#
# Usage: comments.sh [base-ref]      # default: $BASE_REF (origin/main)

set -uo pipefail
unset CDPATH   # an exported CDPATH corrupts $(cd … && pwd) for relative paths

selfdir=$(cd "$(dirname "$0")" && pwd)

BASE_REF="origin/main"
EXTENSIONS="ts tsx js jsx mjs cs java kt go rs rb py sh bash css scss less html vue svelte c h cc cpp hpp swift php sql"
# Trees no one reviews comment-by-comment. Hidden directories are matched
# generically rather than by name: a tool's own directory holds hooks and
# helpers the contract's comment rule was never aimed at, and naming the
# tools we can think of today misses whichever arrives next.
EXCLUDE_RE='(^|/)\.[^/]+/|(^|/)node_modules/|/dist/|/vendor/|\.min\.'
EXCLUDE_RE_EXTRA=""
BLOCK_RE_EXTRA=""
PRAGMA_RE_EXTRA=""

conf="$selfdir/comments.conf"
conf_get() { sed -n "s/^$1=//p" "$conf" 2>/dev/null | head -n 1; }
if [ -f "$conf" ]; then
  v=$(conf_get BASE_REF);         [ -n "$v" ] && BASE_REF="$v"
  v=$(conf_get EXTENSIONS);       [ -n "$v" ] && EXTENSIONS="$v"
  v=$(conf_get EXCLUDE_RE);       [ -n "$v" ] && EXCLUDE_RE="$v"
  v=$(conf_get EXCLUDE_RE_EXTRA); [ -n "$v" ] && EXCLUDE_RE_EXTRA="$v"
  v=$(conf_get BLOCK_RE_EXTRA);   [ -n "$v" ] && BLOCK_RE_EXTRA="$v"
  v=$(conf_get PRAGMA_RE_EXTRA);  [ -n "$v" ] && PRAGMA_RE_EXTRA="$v"
fi

# Fail closed on a conf regex that will not compile. Every filter below is
# followed by `|| true` to absorb grep's exit 1, which means "no match" and
# is not an error. That same `|| true` would absorb the exit 2 a broken
# pattern raises, and the run would report a clean diff it never read. So
# each conf-supplied pattern is compiled here first, by the engine that
# will consume it, and a bad one stops the run.
re_require() {   # re_require <awk|grep> <key> <pattern>
  case "$1" in
    awk)  RE_CHECK="$3" awk 'BEGIN { if ("" ~ ENVIRON["RE_CHECK"]) n = 1 }' \
            >/dev/null 2>&1 ;;
    grep) printf '' | grep -E "$3" >/dev/null 2>&1 ;;
  esac
  [ $? -le 1 ] && return 0
  echo "comments.sh: $2 is not a valid regular expression: $3" >&2
  exit 2
}
re_require awk EXCLUDE_RE "$EXCLUDE_RE"
[ -n "$EXCLUDE_RE_EXTRA" ] && re_require awk EXCLUDE_RE_EXTRA "$EXCLUDE_RE_EXTRA"
[ -n "$BLOCK_RE_EXTRA" ]   && re_require grep BLOCK_RE_EXTRA "$BLOCK_RE_EXTRA"
[ -n "$PRAGMA_RE_EXTRA" ]  && re_require grep PRAGMA_RE_EXTRA "$PRAGMA_RE_EXTRA"

base="${1:-$BASE_REF}"

if ! git rev-parse --verify -q "$base" >/dev/null; then
  echo "comments.sh: base ref '$base' not found" >&2
  exit 2
fi

exclude_re="$EXCLUDE_RE"
[ -n "$EXCLUDE_RE_EXTRA" ] && exclude_re="$exclude_re|$EXCLUDE_RE_EXTRA"

set --
for ext in $EXTENSIONS; do set -- "$@" "*.${ext}"; done

# Merge-base → worktree, not base...HEAD: a diff ending at the last commit
# cannot see staged or unstaged changes, and the state being handed back is
# normally uncommitted.
mb=$(git merge-base "$base" HEAD) || {
  echo "comments.sh: no merge base between '$base' and HEAD" >&2
  exit 2
}

# The prefixes are forced and quoting is turned off, because the header
# line is the only place the filename comes from. `diff.noprefix` or
# `diff.mnemonicPrefix` in a node's git config renames the `b/` the parser
# looks for, and a path holding a non-ASCII byte arrives quoted. Either one
# leaves the filename unset, and every added line is then judged with no
# extension and no path to match the exclusions against.
added=$(git -c core.quotepath=false diff --src-prefix=a/ --dst-prefix=b/ "$mb" -- "$@" \
  | awk '
      /^\+\+\+ / {
        p = substr($0, 5)
        # git appends a tab to this header when the path holds a space.
        sub(/\t.*$/, "", p)
        # A path holding a quote or a control byte is quoted even so.
        if (p ~ /^".*"$/) p = substr(p, 2, length(p) - 2)
        sub(/^b\//, "", p)
        file = p
        next
      }
      /^\+/ && !/^\+\+\+/ {
        line = substr($0, 2)
        print file "\t" line
      }')

# The diff never shows untracked files, so a brand-new unadded source file
# is scanned whole: every comment line in it is a line this diff adds.
# -z, because a name git would quote is not a path any longer, and the
# file would be skipped whole. ENVIRON for the same reason -v is avoided
# below: -v collapses the backslash escapes in a name.
untracked=$(git ls-files --others --exclude-standard -z -- "$@" \
  | while IFS= read -r -d '' uf; do
      [ -f "$uf" ] || continue
      UF="$uf" awk 'BEGIN { f = ENVIRON["UF"] } { print f "\t" $0 }' "$uf"
    done)
if [ -n "$untracked" ]; then
  added=$(printf '%s\n%s' "$added" "$untracked")
fi

# ENVIRON, not -v: an assignment made with -v has its backslash escapes
# processed, so an ERE arriving from the conf reaches awk with `\.` already
# collapsed to `.` — a literal-dot term silently becoming match-anything.
added=$(printf '%s\n' "$added" \
  | EXCLUDE_RE_AWK="$exclude_re" awk -F'\t' '$1 !~ ENVIRON["EXCLUDE_RE_AWK"]' \
  || true)

# Comment lines only, and a marker opens a comment only in the languages
# where it does: "#" in shell, python and ruby but not in C-family sources,
# where it is a preprocessor directive or a region marker. "//" runs the
# other way round, since in shell it is a string or a syntax error. "--"
# opens a comment only in SQL. PHP takes both "#" and "//", so it gets its
# own branch rather than joining either one.
#
# A leading "*" continues a comment only inside an open /* */, and a diff
# of added lines cannot see whether one is open: the line that opened it is
# usually unchanged context. So the pattern is narrowed rather than tracked
# — "*" then a space then content, minus the CSS universal selector and its
# combinators. "*p = 5;" and "* { box-sizing: border-box; }" are code.
comments=$(printf '%s\n' "$added" \
  | awk -F'\t' '{
      line = $2
      sub(/^[[:space:]]+/, "", line)
      star = (line ~ /^\*[[:space:]]/ && line !~ /^\*[[:space:]]*[{,+>~=]/)
      if ($1 ~ /\.(sh|bash|py|rb)$/)      keep = (line ~ /^#/)
      else if ($1 ~ /\.sql$/)             keep = (line ~ /^--/)
      else if ($1 ~ /\.php$/)             keep = (line ~ /^(\/\/|\/\*|<!--)/ \
                                                  || (line ~ /^#/ && line !~ /^#\[/) \
                                                  || star)
      else                                keep = (line ~ /^(\/\/|\/\*|<!--)/ || star)
      if (line == "/**" || line == "/*" || line == "*/" || line == "*") keep = 0
      if (keep) print $0
    }' \
  || true)

pragma_re='eslint|prettier|stylelint|@ts-|<reference|istanbul|jest-environment|#!/|shellcheck|noqa|type: ignore|pylint|biome-ignore'
[ -n "$PRAGMA_RE_EXTRA" ] && pragma_re="$pragma_re|$PRAGMA_RE_EXTRA"
comments=$(printf '%s\n' "$comments" | grep -ivE "$pragma_re" || true)

[ -z "$comments" ] && exit 0

# The core names only universal dead citations. Workflow-specific reference
# shapes (ticket ids, task numbers) are the node's BLOCK_RE_EXTRA.
block_re='git (show|log|diff|blame|bisect|merge-base|rev-parse)([^[:alnum:]]|$)|(^|[^[:alnum:]])[0-9a-f]{8,40}([^[:alnum:]]|$)|out of scope|for this pass'
[ -n "$BLOCK_RE_EXTRA" ] && block_re="$block_re|$BLOCK_RE_EXTRA"

blocked=$(printf '%s\n' "$comments" | grep -iE "$block_re" || true)
review=$(printf '%s\n' "$comments" | grep -ivE "$block_re" || true)

if [ -n "$review" ]; then
  echo "REVIEW: comments this diff adds — justify each as a non-obvious invariant,"
  echo "        constraint, or workaround, or delete it:"
  printf '%s\n' "$review" | awk -F'\t' '{printf "  %s\n    %s\n", $1, $2}'
fi

if [ -n "$blocked" ]; then
  [ -n "$review" ] && echo
  echo "BLOCK: comments citing an artifact a fresh clone cannot open — a commit"
  echo "       SHA, a git transcript, scope narration. Delete them; durable why"
  echo "       goes to docs:"
  printf '%s\n' "$blocked" | awk -F'\t' '{printf "  %s\n    %s\n", $1, $2}'
  exit 1
fi

exit 0
