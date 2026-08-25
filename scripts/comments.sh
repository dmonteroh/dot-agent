#!/usr/bin/env bash
# scripts/comments.sh — the comment gate: flags comments a diff adds to
# source files, against the contract's comment rule (a comment states a
# constraint the code cannot express; never change narration or citations
# of artifacts a fresh clone cannot open).
#
# The rule was prose in three places on a live field node and was breached
# anyway — "is this comment narrative?" is a judgement call a reviewer can
# wave through. This makes the objective half mechanical:
#
#   BLOCK:  the added comment cites something a fresh clone cannot open —
#           a commit SHA, a git command transcript, scope narration.
#           Exits 1. Delete these; durable why goes to docs.
#   REVIEW: every other comment the diff adds. Exits 0 — the author
#           justifies each as a non-obvious invariant, constraint, or
#           workaround, or deletes it.
#
# To customize: edit comments.conf beside this script (node.sh init seeds
# a starter; update seeds it only when absent, never overwrites) —
# node-owned and parsed as plain KEY=value lines,
# never executed (a config read every session is an injection surface; this
# one cannot run code). Everything after `=` is the raw value — no quoting,
# no escaping. Recognized keys, e.g.:
#   BASE_REF=origin/dev
#   EXTENSIONS=ts tsx cs py
#   EXCLUDE_RE_EXTRA=/types/generated/|(^|/)Migrations/
#   BLOCK_RE_EXTRA=(^|[^[:alnum:]])AC-?[0-9]|(^|[^[:alnum:]])Q[0-9]+([^[:alnum:]]|$)
#   PRAGMA_RE_EXTRA=noinspection
# BASE_REF is the default base when none is passed; EXTENSIONS replaces the
# scanned extension list; the *_EXTRA keys are EREs ORed onto the shipped
# defaults. Ticket and task-reference shapes belong in BLOCK_RE_EXTRA, not
# in the shipped core: no two teams number work the same way. The retro
# skill routes comment-hygiene lessons here.
#
# .agent/ itself, vendored and minified trees, and pragmas are skipped.
#
# Usage: comments.sh [base-ref]      # default: $BASE_REF (origin/main)

set -uo pipefail

selfdir=$(cd "$(dirname "$0")" && pwd)

BASE_REF="origin/main"
EXTENSIONS="ts tsx js jsx mjs cs java kt go rs rb py sh bash css scss less html vue svelte c h cc cpp hpp swift php sql"
EXCLUDE_RE_EXTRA=""
BLOCK_RE_EXTRA=""
PRAGMA_RE_EXTRA=""

conf="$selfdir/comments.conf"
conf_get() { sed -n "s/^$1=//p" "$conf" 2>/dev/null | head -n 1; }
if [ -f "$conf" ]; then
  v=$(conf_get BASE_REF);         [ -n "$v" ] && BASE_REF="$v"
  v=$(conf_get EXTENSIONS);       [ -n "$v" ] && EXTENSIONS="$v"
  v=$(conf_get EXCLUDE_RE_EXTRA); [ -n "$v" ] && EXCLUDE_RE_EXTRA="$v"
  v=$(conf_get BLOCK_RE_EXTRA);   [ -n "$v" ] && BLOCK_RE_EXTRA="$v"
  v=$(conf_get PRAGMA_RE_EXTRA);  [ -n "$v" ] && PRAGMA_RE_EXTRA="$v"
fi

base="${1:-$BASE_REF}"

if ! git rev-parse --verify -q "$base" >/dev/null; then
  echo "comments.sh: base ref '$base' not found" >&2
  exit 2
fi

# chosen defaults: trees no one reviews comment-by-comment
exclude_re='(^|/)\.agent/|(^|/)node_modules/|/dist/|/vendor/|\.min\.'
[ -n "$EXCLUDE_RE_EXTRA" ] && exclude_re="$exclude_re|$EXCLUDE_RE_EXTRA"

set --
for ext in $EXTENSIONS; do set -- "$@" "*.${ext}"; done

added=$(git diff "$base...HEAD" -- "$@" \
  | awk '
      /^\+\+\+ b\// { file = substr($0, 7); next }
      /^\+/ && !/^\+\+\+/ {
        line = substr($0, 2)
        print file "\t" line
      }')

added=$(printf '%s\n' "$added" \
  | awk -F'\t' -v re="$exclude_re" '$1 !~ re' \
  || true)

# comment lines only. "#" counts as a comment only where it opens one
# (shell, python, ruby): in C-family sources it is a preprocessor directive
# or region marker. "--" likewise only in SQL.
comments=$(printf '%s\n' "$added" \
  | awk -F'\t' '{
      line = $2
      sub(/^[[:space:]]+/, "", line)
      keep = (line ~ /^(\/\/|\/\*|\*|<!--)/)
      if (line == "/**" || line == "/*" || line == "*/" || line == "*") keep = 0
      if (!keep && $1 ~ /\.(sh|bash|py|rb)$/ && line ~ /^#/) keep = 1
      if (!keep && $1 ~ /\.sql$/ && line ~ /^--/) keep = 1
      if (keep) print $0
    }' \
  || true)

pragma_re='eslint|prettier|stylelint|@ts-|<reference|istanbul|jest-environment|#!/|shellcheck|noqa|type: ignore|pylint|biome-ignore'
[ -n "$PRAGMA_RE_EXTRA" ] && pragma_re="$pragma_re|$PRAGMA_RE_EXTRA"
comments=$(printf '%s\n' "$comments" | grep -ivE "$pragma_re" || true)

[ -z "$comments" ] && exit 0

# the core names only universal dead citations; workflow-specific reference
# shapes (ticket ids, task numbers) are the node's BLOCK_RE_EXTRA
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
