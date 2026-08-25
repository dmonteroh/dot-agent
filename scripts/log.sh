#!/usr/bin/env bash
# log.sh — appends one session-log entry per session-log.md's header
# contract. Stamps the date and enforces the summary word ceiling so
# neither is something an agent can get wrong by hand. With
# LOG_INCLUDE_BRANCH=true in the node's log.conf, also stamps the
# checked-out branch (read from git at write time — mechanical, never
# asked of the agent; silently omitted outside a git checkout).
#
# Usage: log.sh --tool <name> --area <name> --verify <pass|fail|n/a> --summary "…" [root]
#
# root defaults to . ; appends to <root>/.agent/session-log.md. Refuses to
# run if that file does not already exist (an uninitialized node).

set -u

# Tunable per project — in the node's log.conf (seeded at init), never by
# editing these lines: node.sh update refreshes this script and discards
# edits. 25 words is the field presets' entry ceiling (V6 harvest); at
# that length a 120-entry log stays near the 5,000-word grooming trigger
# (see status.sh).
SUMMARY_MAX_WORDS=25
LOG_INCLUDE_BRANCH=false

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

# Per-node overrides: <root>/.agent/scripts/log.conf, plain KEY=value,
# parsed and never executed.
conf="$root/.agent/scripts/log.conf"
conf_get() { sed -n "s/^$1=//p" "$conf" 2>/dev/null | head -n 1; }
if [ -f "$conf" ]; then
  v=$(conf_get SUMMARY_MAX_WORDS);  [ -n "$v" ] && SUMMARY_MAX_WORDS="$v"
  v=$(conf_get LOG_INCLUDE_BRANCH); [ -n "$v" ] && LOG_INCLUDE_BRANCH="$v"
fi

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
# a lone hyphen) does not spend the ceiling. Separators are matched as
# literal bytes rather than by asking the locale what counts as a letter:
# under a single-byte locale, [[:alnum:]] treats the em dash's leading
# byte (0xE2, "â" in Latin-1) as alphanumeric, and the dash spends a word.
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
# symbolic-ref, not rev-parse: it names the branch even before its first
# commit, and stays empty (stamp omitted) when detached or outside git.
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
