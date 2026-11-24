#!/usr/bin/env bash

set -u

selfdir=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
[ -f "$selfdir/runtime.sh" ] || { echo 'log.sh: runtime.sh is missing. Update this node with node.sh update from the dot-agent repository' >&2; exit 1; }
# shellcheck source=runtime.sh
. "$selfdir/runtime.sh"

SUMMARY_MAX_WORDS=25
LOG_INCLUDE_BRANCH=false

usage() {
  cat <<'EOF'
Usage: log.sh [--print-entry] --tool <name, no parentheses> --area <name, no parentheses> --verify <pass|fail|n/a> --summary "…" [root]

root defaults to . — appends to <root>/.agent/session-log.md
EOF
}

refuse() { da_refuse "$@"; exit $?; }
refuse_usage() { usage >&2; refuse "$@"; }

tool=""
area=""
verify=""
summary=""
root="."
print_entry=0

need_value() {
  case "${2-}" in
  --tool|--area|--verify|--summary)
    refuse_usage "$1 needs a value, got the flag $2" "Pass a value after $1" ;;
  esac
  if [ $# -lt 2 ]; then
    refuse_usage "$1 needs a value" "Pass a value after $1"
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
  --print-entry)
    print_entry=1; shift ;;
  --version)
    echo 'dot-agent log 6.3'; exit 0 ;;
  --tool)
    need_value "$@"
    tool="$2"; shift 2 ;;
  --area)
    need_value "$@"
    area="$2"; shift 2 ;;
  --verify)
    need_value "$@"
    verify="$2"; shift 2 ;;
  --summary)
    need_value "$@"
    summary="$2"; shift 2 ;;
  -h | --help)
    usage; exit 0 ;;
  --*)
    refuse_usage "unknown flag: $1" 'Pass only the flags listed above' ;;
  *)
    root="$1"; shift ;;
  esac
done

if [ -z "$tool" ] || [ -z "$area" ] || [ -z "$verify" ] || [ -z "$summary" ]; then
  refuse_usage '--tool, --area, --verify, and --summary are all required' 'Run this call again with all four'
fi

case "$verify" in
pass | fail | n/a) ;;
*)
  refuse "--verify must be pass, fail, or n/a (got '$verify')" 'Run this call again with one of those' ;;
esac

summary_lc=$(printf '%s' "$summary" \
  | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz')
case "$summary_lc" in
*verify:*)
  refuse "--summary must not contain 'verify:', because the entry already carries one verify tag" 'State the outcome in words and run this call again' ;;
esac

bad_token=$(printf '%s' "$summary" | awk '
  {
    for (i = 1; i <= NF; i++) {
      t = $i
      gsub(/^[`"'"'"'(\[]+|[`"'"'"')\],.;:!?]+$/, "", t)
      if (t == "") continue
      if (t ~ /\.(ts|tsx|js|jsx|mjs|cjs|cs|java|kt|go|rs|rb|py|sh|bash|css|scss|less|html|vue|svelte|json|yaml|yml|toml|md|sql|c|h|cc|cpp|hpp|swift|php|lock)$/) { print t; exit }
      if (t ~ /\// && t ~ /\.[A-Za-z0-9]+$/) { print t; exit }
      if (length(t) >= 7 && length(t) <= 40 && t ~ /^[0-9a-f]+$/ && t ~ /[a-f]/ && t ~ /[0-9]/) { print t; exit }
    }
  }')
if [ -n "$bad_token" ]; then
  refuse "--summary names a file or a SHA ($bad_token), which live in git" 'Reword it without that token and run this call again'
fi

conf="$root/.agent/scripts/log.conf"
conf_get() { sed -n "s/^$1=//p" "$conf" 2>/dev/null | head -n 1 | sed 's/[[:space:]]*$//'; }
if [ -f "$conf" ]; then
  v=$(conf_get SUMMARY_MAX_WORDS)
  if [ -n "$v" ]; then
    case "$v" in
    *[!0-9]*)
      refuse "log.conf SUMMARY_MAX_WORDS=$v is not a whole number" 'Fix that line in .agent/scripts/log.conf, which takes digits only with no inline comment and no units, then run this call again' ;;
    esac
    SUMMARY_MAX_WORDS="$v"
  fi
  v=$(conf_get LOG_INCLUDE_BRANCH)
  if [ -n "$v" ]; then
    case "$v" in
    true | false) LOG_INCLUDE_BRANCH="$v" ;;
    *)
      refuse "log.conf LOG_INCLUDE_BRANCH=$v is not true or false" 'Fix that line in .agent/scripts/log.conf, with no inline comment, then run this call again' ;;
    esac
  fi
fi

nl='
'
case "$tool$area$summary" in
*"$nl"*)
  refuse '--tool, --area, and --summary must be single-line' 'Remove the line breaks and run this call again' ;;
esac
case "$tool$area" in
*"("* | *")"*)
  refuse '--tool and --area must not contain parentheses, because they become the (tool) and (area) tags' 'Remove them and run this call again' ;;
esac
case "$summary" in
*[![:space:]]*) ;;
*)
  refuse '--summary must not be blank' 'State the task and its outcome and run this call again' ;;
esac

summary_words=$(printf '%s' "$summary" \
  | awk '{
      n = 0
      for (i = 1; i <= NF; i++) {
        t = $i
        gsub(/[-|\/]/, "", t)
        gsub(/—/, "", t)
        gsub(/–/, "", t)
        gsub(/·/, "", t)
        if (t != "") n++
      }
      print n
    }')
if [ "$summary_words" -gt "$SUMMARY_MAX_WORDS" ]; then
  over=$((summary_words - SUMMARY_MAX_WORDS))
  noun=words
  [ "$over" -ne 1 ] || noun=word
  refuse "--summary is $summary_words words, over the $SUMMARY_MAX_WORDS-word ceiling" "Shorten it by $over $noun and run this call again"
fi

log="$root/.agent/session-log.md"
if [ ! -f "$log" ]; then
  refuse "$log does not exist, and log.sh writes only to an initialized node" 'Pass the folder that holds .agent/ as the last argument'
fi

date_stamp=$(date +%Y-%m-%d)
branch=""
if [ "$LOG_INCLUDE_BRANCH" = "true" ]; then
  branch=$(git -C "$root" symbolic-ref --short -q HEAD 2>/dev/null || true)
fi
if [ -n "$branch" ]; then
  entry=$(printf -- '- [%s] (%s) %s (%s). branch: %s. verify: %s.' "$date_stamp" "$tool" "$summary" "$area" "$branch" "$verify")
else
  entry=$(printf -- '- [%s] (%s) %s (%s). verify: %s.' "$date_stamp" "$tool" "$summary" "$area" "$verify")
fi

if [ "$print_entry" -eq 1 ]; then
  printf '%s\n' "$entry"
  exit 0
fi
state=$(da_state_dir "$root") || exit 1
log_lock="$state/checkpoint.lock"
da_lock_wait "$log_lock" || exit 1
trap 'da_unlock "$log_lock"' EXIT
printf '%s\n' "$entry" >>"$log" || refuse 'could not append the entry' 'Check that .agent/session-log.md is writable, then run this call again'

echo "log.sh: appended session-log entry for $date_stamp"
exit 0
