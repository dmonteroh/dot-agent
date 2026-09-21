#!/usr/bin/env bash

set -u

SUMMARY_MAX_WORDS=25
LOG_INCLUDE_BRANCH=false

usage() {
  cat <<'EOF'
Usage: log.sh --tool <name, no parentheses> --area <name, no parentheses> --verify <pass|fail|n/a> --summary "…" [root]

root defaults to . — appends to <root>/.agent/session-log.md
EOF
}

tool=""
area=""
verify=""
summary=""
root="."

need_value() {
  case "${2-}" in
  --tool|--area|--verify|--summary)
    echo "log.sh: $1 needs a value, got the flag $2" >&2
    usage >&2
    exit 1 ;;
  esac
  if [ $# -lt 2 ]; then
    echo "log.sh: $1 needs a value" >&2
    usage >&2
    exit 1
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
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
    echo "log.sh: unknown flag: $1" >&2; usage >&2; exit 1 ;;
  *)
    root="$1"; shift ;;
  esac
done

if [ -z "$tool" ] || [ -z "$area" ] || [ -z "$verify" ] || [ -z "$summary" ]; then
  echo "log.sh: --tool, --area, --verify, and --summary are all required" >&2
  usage >&2
  exit 1
fi

case "$verify" in
pass | fail | n/a) ;;
*)
  echo "log.sh: --verify must be pass, fail, or n/a (got '$verify')" >&2
  exit 1 ;;
esac

summary_lc=$(printf '%s' "$summary" \
  | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz')
case "$summary_lc" in
*verify:*)
  echo "log.sh: --summary must not contain 'verify:' — the entry already carries one verify tag; state the outcome in words instead" >&2
  exit 1 ;;
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
  echo "log.sh: --summary names a file or a SHA ($bad_token) — the entry records task, area, and outcome; files and SHAs live in git. Reword without it" >&2
  exit 1
fi

conf="$root/.agent/scripts/log.conf"
conf_get() { sed -n "s/^$1=//p" "$conf" 2>/dev/null | head -n 1 | sed 's/[[:space:]]*$//'; }
if [ -f "$conf" ]; then
  v=$(conf_get SUMMARY_MAX_WORDS)
  if [ -n "$v" ]; then
    case "$v" in
    *[!0-9]*)
      echo "log.sh: log.conf SUMMARY_MAX_WORDS=$v is not a whole number — fix the line, which takes digits only (no inline comment, no units)" >&2
      exit 1 ;;
    esac
    SUMMARY_MAX_WORDS="$v"
  fi
  v=$(conf_get LOG_INCLUDE_BRANCH)
  if [ -n "$v" ]; then
    case "$v" in
    true | false) LOG_INCLUDE_BRANCH="$v" ;;
    *)
      echo "log.sh: log.conf LOG_INCLUDE_BRANCH=$v is not true or false — fix the line (no inline comment)" >&2
      exit 1 ;;
    esac
  fi
fi

nl='
'
case "$tool$area$summary" in
*"$nl"*)
  echo "log.sh: --tool, --area, and --summary must be single-line" >&2
  exit 1 ;;
esac
case "$tool$area" in
*"("* | *")"*)
  echo "log.sh: --tool and --area must not contain parentheses — they become the (tool) and (area) tags" >&2
  exit 1 ;;
esac
case "$summary" in
*[![:space:]]*) ;;
*)
  echo "log.sh: --summary must not be blank" >&2
  exit 1 ;;
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
  echo "log.sh: --summary is $summary_words words, over the $SUMMARY_MAX_WORDS-word ceiling" >&2
  exit 1
fi

log="$root/.agent/session-log.md"
if [ ! -f "$log" ]; then
  echo "log.sh: $log does not exist — refusing to write outside an initialized node" >&2
  exit 1
fi

date_stamp=$(date +%Y-%m-%d)
branch=""
if [ "$LOG_INCLUDE_BRANCH" = "true" ]; then
  branch=$(git -C "$root" symbolic-ref --short -q HEAD 2>/dev/null || true)
fi
if [ -n "$branch" ]; then
  printf -- '- [%s] (%s) %s (%s). branch: %s. verify: %s.\n' "$date_stamp" "$tool" "$summary" "$area" "$branch" "$verify" >>"$log"
else
  printf -- '- [%s] (%s) %s (%s). verify: %s.\n' "$date_stamp" "$tool" "$summary" "$area" "$verify" >>"$log"
fi

echo "log.sh: appended session-log entry for $date_stamp"
exit 0
