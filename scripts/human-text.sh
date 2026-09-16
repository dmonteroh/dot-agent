#!/usr/bin/env bash
# human-text.sh — scans an explicit commit message, pull-request body, or
# release note for chat residue: a discussion or feedback reference, an
# opening apology, or a standalone draft-revision label. A clean scan
# rules a shape out; it never endorses one.
#
# Full documentation: scripts/docs/human-text.md in the dot-agent repo.
#
# Usage: human-text.sh --kind commit|pr|release [--] [FILE ...]
#        Reads stdin when FILE is omitted. Use - for stdin once.
#
# bash 3.2 / BSD portable: no associative arrays, no GNU-only flags.

set -Eeuo pipefail
unset CDPATH
usage() {
  printf '%s\n' 'Usage: human-text.sh --kind commit|pr|release [--] [FILE ...]' \
    'Read stdin when FILE is omitted. Use - for stdin once.' \
    'Exit 0: clean. Exit 1: residue. Exit 2: invalid input or scan failure.' \
    'Clean scans are silent. Findings and errors use stderr.'
}
die() { printf 'human-text.sh: %s\n' "$1" >&2; exit 2; }
kind=''
files=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) [ "$#" -eq 1 ] && [ -z "$kind" ] || die 'Use --help alone.'; usage; exit 0 ;;
    --kind)
      [ "$#" -ge 2 ] || die 'Supply a value for --kind.'
      [ -z "$kind" ] || die 'Supply --kind once.'
      kind=$2
      shift 2 ;;
    --) shift; files+=("$@"); break ;;
    -) files+=("$1"); shift ;;
    -*) die "Unknown option: $1" ;;
    *) files+=("$1"); shift ;;
  esac
done
case "$kind" in commit|pr|release) ;; *) die 'Select --kind commit, pr, or release.' ;; esac
[ "${#files[@]}" -gt 0 ] || files=('-')
seen_stdin=0
for source in "${files[@]}"; do
  if [ "$source" = - ]; then
    [ "$seen_stdin" -eq 0 ] || die 'Read stdin only once.'
    seen_stdin=1
    [ ! -t 0 ] || die 'Provide text through stdin or a file.'
  else
    [ -f "$source" ] && [ -r "$source" ] || die "Cannot read file: $source"
  fi
done
scratch=$(mktemp -d "${TMPDIR:-/tmp}/human-text.XXXXXX") || die 'Cannot create temporary directory.'
trap 'rm -rf "$scratch"' EXIT
trap 'exit 2' HUP INT TERM
: > "$scratch/findings"
for source in "${files[@]}"; do
  if [ "$source" = - ]; then
    cat > "$scratch/input" || die 'Cannot read stdin.'
  else
    cat -- "$source" > "$scratch/input" || die "Cannot read file: $source"
  fi
  LC_ALL=C awk '
    /[^[:space:]]/ { present = 1 }
    END { exit !present }
  ' "$scratch/input" || die "Input is empty or unreadable: $source"
  if ! SOURCE_LABEL="$source" LC_ALL=C awk '
    {
      text = tolower($0)
      reason = ""
      if (text ~ /(^|[^[:alnum:]_])(as (we |you )?(discussed|agreed)|per (your|the user.s) (feedback|request|instructions?|comments?)|you asked|per our (discussion|chat|conversation))([^[:alnum:]_]|$)/)
        reason = "chat-reference"
      else if (text ~ /^[[:space:]#>*-]*(sorry([,! .]|$)|i (am sorry|apologi[sz]e)([^[:alnum:]_]|$)|my apologies([^[:alnum:]_]|$)|apologies[,:!])/)
        reason = "apology"
      else if (text ~ /^[[:space:]#>*-]*(fixed version[[:space:]]*[:.!]?[[:space:]]*$|here(.s| is) (the |a )?(fixed|corrected|revised) version([^[:alnum:]_]|$)|this is (the |a )?fixed version([^[:alnum:]_]|$))/)
        reason = "revision-label"
      if (reason != "")
        printf "%s:%d: %s\n", ENVIRON["SOURCE_LABEL"], FNR, reason
    }
  ' "$scratch/input" >> "$scratch/findings"; then
    die "Scan failed: $source"
  fi
done
if [ -s "$scratch/findings" ]; then
  cat "$scratch/findings" >&2 || die 'Cannot write findings.'
  exit 1
fi
