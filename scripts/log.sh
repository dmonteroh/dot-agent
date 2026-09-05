#!/usr/bin/env bash
# log.sh — appends one session-log entry per session-log.md's header
# contract, stamping the date and enforcing the summary word ceiling so
# neither is something an agent can get wrong by hand.
#
# Tunables: log.conf beside this script, which lists every key.
# Full documentation: scripts/docs/log.md in the dot-agent repo.
#
# Usage: log.sh --tool <name, no parentheses> --area <name, no parentheses> --verify <pass|fail|n/a> --summary "…" [root]
#
# root defaults to . — appends to <root>/.agent/session-log.md. Refuses to
# run if that file does not already exist (an uninitialized node).

set -u

# Tune in the node's log.conf, never here: node.sh update refreshes this
# script and discards edits to it. 25 words is the session-log header
# contract's entry format. log.conf states it beside the key.
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

# A flag's value must exist and must not itself be a flag: a dropped value
# otherwise swallows the next flag silently, and `--summary --area <root>`
# logs the entry with `--area` as its summary. Called as `need_value "$@"`,
# so $1 is the flag and $2 is whatever followed it.
need_value() {
  # Reject only a value that is one of this script's own flags: that is
  # the real mistake, a flag whose value was left out. A free-text value
  # may legitimately begin with -- , so shape alone is not the test.
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

# The entry carries exactly one verify tag, written from --verify at the end
# of the line. A summary that also contains `verify:` puts a second one in
# the middle, where a reader and status.sh's entry parsing both take the
# wrong one as the entry's result. The verification outcome belongs in the
# tag; a baseline failure that predates the change belongs in the summary's
# own words, without the tag spelling.
#
# The alphabet is spelled out rather than written as A-Z: inside tr a range
# is a collation range, not an ASCII range, in every locale but C. Listing
# the characters means the same thing everywhere and leaves date's and
# grep's locale alone — the same reason memory.sh spells out its slug class.
summary_lc=$(printf '%s' "$summary" \
  | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz')
case "$summary_lc" in
*verify:*)
  echo "log.sh: --summary must not contain 'verify:' — the entry already carries one verify tag; state the outcome in words instead" >&2
  exit 1 ;;
esac

# The header contract's "no file lists, SHAs" is enforced here, not asked
# for: a summary token that ends in a source extension, carries a slash and
# an extension, or is a 7–40 character hex run with both letters and digits
# is refused with the token named. The entry records task, area, and
# outcome; a path or a SHA in it is narrative that git already holds, and a
# session reading the log later cannot open either from the line.
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

# Per-node overrides: <root>/.agent/scripts/log.conf, plain KEY=value,
# parsed and never executed. Each value is checked before it is used:
# `SUMMARY_MAX_WORDS=25 words` reaching the `-gt` below stops the ceiling
# from being enforced at all, and enforcing that ceiling is why this script
# exists instead of a hand-written append. A value this script cannot use is
# refused, the way every other bad input here is refused — a config that
# quietly disables the check is worse than one that will not run.
conf="$root/.agent/scripts/log.conf"
# The trailing-space strip forgives a stray space or a CR from an editor on
# another platform; nothing else about the value is repaired.
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
# literal bytes rather than by asking the locale what counts as a letter.
# Where the locale's alnum table covers 0xE2 — the em dash's leading byte,
# "â" in Latin-1 — [[:alnum:]] reads that byte as a letter and the dash
# spends a word. LC_ALL=C is the one locale here that does not.
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
