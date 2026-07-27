#!/usr/bin/env bash
# log.sh — appends one session-log entry per session-log.md's header
# contract. Stamps the date and enforces the summary word ceiling so
# neither is something an agent can get wrong by hand.
#
# Usage: log.sh --tool <name> --area <name> --verify <pass|fail|n/a> --summary "…" [root]
#
# root defaults to . ; appends to <root>/.agent/session-log.md. Refuses to
# run if that file does not already exist (an uninitialized node).

set -u

# Tunable per project. 25 words is the field presets' entry ceiling
# (V6 harvest); at that length a 120-entry log stays near the 5,000-word
# grooming trigger (see status.sh).
SUMMARY_MAX_WORDS=25

usage() {
  cat <<'EOF'
Usage: log.sh --tool <name> --area <name> --verify <pass|fail|n/a> --summary "…" [root]

root defaults to . ; appends to <root>/.agent/session-log.md
EOF
}

tool=""
area=""
verify=""
summary=""
root="."

while [ $# -gt 0 ]; do
  case "$1" in
  --tool)
    [ $# -ge 2 ] || { echo "log.sh: --tool needs a value" >&2; usage >&2; exit 1; }
    tool="$2"; shift 2 ;;
  --area)
    [ $# -ge 2 ] || { echo "log.sh: --area needs a value" >&2; usage >&2; exit 1; }
    area="$2"; shift 2 ;;
  --verify)
    [ $# -ge 2 ] || { echo "log.sh: --verify needs a value" >&2; usage >&2; exit 1; }
    verify="$2"; shift 2 ;;
  --summary)
    [ $# -ge 2 ] || { echo "log.sh: --summary needs a value" >&2; usage >&2; exit 1; }
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

# The entry is one line: `- [date] (tool) summary (area). verify: …` —
# newlines would forge extra entries, and parentheses in the tags would
# corrupt the (tool)/(area) delimiters.
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

# Count words, not punctuation: a free-standing separator (an em dash,
# a lone hyphen) does not spend the ceiling.
summary_words=$(printf '%s' "$summary" \
  | awk '{ n = 0; for (i = 1; i <= NF; i++) if ($i ~ /[[:alnum:]]/) n++; print n }')
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
printf -- '- [%s] (%s) %s (%s). verify: %s.\n' "$date_stamp" "$tool" "$summary" "$area" "$verify" >>"$log"

echo "log.sh: appended session-log entry for $date_stamp"
exit 0
