#!/usr/bin/env bash
# learn.sh — finds the records under rules/learned/ that already cover a
# discovery, writes a new one under a minted identity, and revises or
# retires an existing one only against the version it was read at.
#
# Full documentation: scripts/docs/learn.md in the dot-agent repo.
#
# Usage:
#   learn.sh lookup  --file <path|-> [root]
#   learn.sh new     --file <path|-> [--distinct] [--surface learned|memory|docs|gotchas] [root]
#   learn.sh revise  <id> --file <path|-> --expected <version> [root]
#   learn.sh retire  <id> --expected <version> [root]
#   learn.sh --help
#
# root defaults to . — the project root holding .agent/. A record lives at
# <root>/.agent/rules/learned/<id>.md, its filename a minted 12-character
# lowercase-hex identity. <version> is git hash-object --no-filters -- of
# that record file. Every check runs before any write, and a create or a
# replacement is never left half-written.

set -u
export LC_ALL=C
unset CDPATH   # an exported CDPATH corrupts $(cd … && pwd) for relative paths

usage() {
  cat <<'EOF'
Usage: learn.sh lookup  --file <path|-> [root]
       learn.sh new     --file <path|-> [--distinct] [--surface learned|memory|docs|gotchas] [root]
       learn.sh revise  <id> --file <path|-> --expected <version> [root]
       learn.sh retire  <id> --expected <version> [root]

root defaults to . — the project root holding .agent/. A record lives at
<root>/.agent/rules/learned/<id>.md; <id> is its filename without .md, a
minted 12-character lowercase-hex identity. <version> is
git hash-object --no-filters -- of that record file. --file - reads the
candidate body from stdin. Full documentation: scripts/docs/learn.md.
EOF
}

# A token beginning with -- is the next flag, not this flag's value. Call
# as `need_value "$@"` from inside the parse loop, where $1 is the flag and
# $2 is its candidate value — the same shape scripts/memory.sh's need_value
# guards against.
need_value() {
  case "${2-}" in
  --file | --surface | --expected | --distinct)
    echo "learn.sh: $1 needs a value, got the flag $2" >&2
    usage >&2
    exit 2 ;;
  esac
  if [ $# -lt 2 ]; then
    echo "learn.sh: $1 needs a value" >&2
    usage >&2
    exit 2
  fi
}

candidate_tmp=""
cleanup() { [ -n "$candidate_tmp" ] && rm -f "$candidate_tmp"; }
trap cleanup EXIT

# True when $1 is a real, non-symlink directory — the same test
# index.sh's learned_dir_active opens with, applied here to the directory
# itself rather than its record count.
lrn_dir_is_real() {
  [ -d "$1" ] && [ ! -L "$1" ]
}

# Reads the candidate body named by $1 (a path, or - for stdin) into a
# fresh temporary file and sets $candidate_tmp to it.
read_candidate() {
  candidate_tmp=$(mktemp "${TMPDIR:-/tmp}/learn-candidate.XXXXXX") || {
    echo "learn.sh: could not create a temporary file for the candidate" >&2
    exit 2
  }
  if [ "$1" = "-" ]; then
    cat >"$candidate_tmp"
  else
    if [ ! -f "$1" ]; then
      echo "learn.sh: --file $1 does not exist" >&2
      exit 2
    fi
    cat "$1" >"$candidate_tmp"
  fi
}

# A well-formed candidate is exactly one top-level "- [YYYY-MM-DD] " bullet
# with its continuation lines: no second top-level bullet, no frontmatter
# block (which would already fail the first-line check below), and no
# Markdown heading anywhere in the body. Digits are spelled out one by one
# rather than written as a [0-9] range: outside the C locale a bracket
# range is a collation range, not an ASCII range — this script forces
# LC_ALL=C above, but the class is spelled out anyway, the way
# scripts/memory.sh does, so the check reads the same regardless.
lrn_grammar_ok() {
  gcd_digit='[0123456789]'
  gcd_pat="^- \\[${gcd_digit}${gcd_digit}${gcd_digit}${gcd_digit}-${gcd_digit}${gcd_digit}-${gcd_digit}${gcd_digit}\\] "
  head -n 1 "$1" | grep -qE "$gcd_pat" || return 1
  tail -n +2 "$1" | grep -qE '^- ' && return 1
  grep -qE '^#' "$1" && return 1
  return 0
}

# The preset's "imperative, ≤40 words" line is a curation rule, not a
# parser rule (see scripts/docs/learn.md): this warns on stderr and never
# refuses.
lrn_warn_word_ceiling() {
  wwc_first=$(head -n 1 "$1")
  wwc_clause=$(printf '%s\n' "$wwc_first" | sed -E 's/^- \[[^]]*\] //')
  wwc_words=$(printf '%s\n' "$wwc_clause" | wc -w | tr -d '[:space:]')
  if [ "$wwc_words" -gt 40 ]; then
    echo "learn.sh: the rule clause is $wwc_words words, over the preset's 40-word curation ceiling — tighten it when convenient" >&2
  fi
}

# The shared-term overlap scan: lowercase, strip to letters and digits,
# keep words over two characters that are not on the stopword list below,
# then test whether the two sets intersect. A record carries no separate
# subject/alias fields to scan — this reads the whole body of each file,
# so a retrieval word only ever has to be written into the rule's own
# imperative to be found by it.
lrn_related() {
  awk '
    function words(s, a,   n, i, t) {
      s = tolower(s)
      gsub(/[^abcdefghijklmnopqrstuvwxyz0123456789]+/, " ", s)
      n = split(s, t, " ")
      for (i = 1; i <= n; i++)
        if (length(t[i]) > 2 && t[i] !~ /^(the|and|for|with|from|this|that|must|should|trigger)$/)
          a[t[i]] = 1
    }
    # The leading "- [YYYY-MM-DD] " on line 1 is provenance, not retrieval
    # text — every record carries one, so leaving it in would make every
    # candidate overlap every record on its year alone. "trigger" is
    # filtered as a stopword for the same reason: it is the format label
    # itself, present in most records regardless of subject.
    FNR == 1 { sub(/^- \[[^]]*\] /, "") }
    FNR == NR { words($0, a); next }
    { words($0, b) }
    END {
      for (k in a) if (k in b) hit++
      exit(hit ? 0 : 1)
    }
  ' "$1" "$2"
}

# Prints the path of an existing record under $2 whose bytes are identical
# to $1, if any, and returns 0 — the exact-duplicate refusal, checked
# before overlap because an exact duplicate trivially overlaps too.
lrn_find_duplicate() {
  for fd_f in "$2"/*.md; do
    [ -e "$fd_f" ] || continue
    if cmp -s "$1" "$fd_f"; then
      printf '%s\n' "$fd_f"
      return 0
    fi
  done
  return 1
}

# Prints one path per record under $2 that shares nontrivial terms with
# $1, and returns 0 if at least one was found.
lrn_overlap_scan() {
  os_found=1
  for os_f in "$2"/*.md; do
    [ -e "$os_f" ] || continue
    if lrn_related "$1" "$os_f"; then
      printf '%s\n' "$os_f"
      os_found=0
    fi
  done
  return "$os_found"
}

# The literal string "absent" when $1 does not exist, else its
# git hash-object --no-filters version — so a revise or retire naming an
# id with no record on disk fails the ordinary stale check instead of
# needing a second code for the same shape of mistake.
lrn_current_version() {
  if [ -f "$1" ]; then
    git hash-object --no-filters -- "$1"
  else
    printf 'absent'
  fi
}

# Mints a 12-lowercase-hex-char identity exactly as node.sh's
# mint_learned_id does — printf '%04x%04x%04x' $RANDOM $RANDOM $RANDOM,
# read directly into shell variables rather than inside a $(...) fork —
# and claims it by writing the candidate under `set -C` in the same step,
# so a lost create race is one more rejection, never an overwrite. Sets
# $lrn_new_id on success. Returns nonzero after 100 consecutive
# rejections, having written nothing.
lrn_mint_and_write() {
  lmw_tries=0
  lrn_new_id=""
  while :; do
    lmw_r1="$RANDOM"
    lmw_r2="$RANDOM"
    lmw_r3="$RANDOM"
    printf -v lmw_id '%04x%04x%04x' "$lmw_r1" "$lmw_r2" "$lmw_r3"
    lmw_target="$2/$lmw_id.md"
    if [ -e "$lmw_target" ]; then
      lmw_tries=$((lmw_tries + 1))
      [ "$lmw_tries" -lt 100 ] && continue
      return 1
    fi
    if (set -C; cat >"$lmw_target") <"$1" 2>/dev/null; then
      lrn_new_id="$lmw_id"
      return 0
    fi
    lmw_tries=$((lmw_tries + 1))
    [ "$lmw_tries" -lt 100 ] || return 1
  done
}

# Writes $1 to a temporary file beside $2 and publishes it with a
# same-directory mv — the scripts/memory.sh supersede shape. A write that
# fails leaves $2 exactly as it was.
lrn_publish_replace() {
  pr_tmp="$2.tmp.$$"
  if cat "$1" >"$pr_tmp"; then
    :
  else
    echo "learn.sh: could not write $pr_tmp — $2 is unchanged" >&2
    rm -f "$pr_tmp"
    return 1
  fi
  if mv "$pr_tmp" "$2"; then
    return 0
  fi
  echo "learn.sh: could not replace $2 — it is unchanged" >&2
  rm -f "$pr_tmp"
  return 1
}

# node.sh reads the manifest's indexes: field with this same grep -m1 plus
# sed -E pair; an absent field reads as manual, same as node.sh.
lrn_indexes_mode() {
  im_purpose="$1/.agent/purpose.md"
  [ -f "$im_purpose" ] || { printf 'manual'; return; }
  im_line=$(grep -m1 '^  indexes:' "$im_purpose")
  im_val=$(printf '%s\n' "$im_line" | sed -E 's/^[[:space:]]*indexes:[[:space:]]*([A-Za-z-]+).*/\1/')
  [ -n "$im_val" ] || im_val=manual
  printf '%s' "$im_val"
}

# After a successful write, when the node runs generated indexes, refresh
# its own cache. An absent or failing indexer warns and never changes this
# script's exit status — a cache fault is not a defect, and a clone whose
# .agent/scripts/ is gitignored has no indexer yet by design.
lrn_refresh_index() {
  [ "$(lrn_indexes_mode "$1")" = generated ] || return 0
  ri_idx="$1/.agent/scripts/index.sh"
  if [ -x "$ri_idx" ]; then
    "$ri_idx" ensure --root "$1" >/dev/null 2>&1 \
      || echo "learn.sh: index refresh failed after the write — read $1/.agent/rules/ and $1/.agent/docs/ directly until it is fixed" >&2
  else
    echo "learn.sh: no index.sh at $ri_idx to refresh the cache — read $1/.agent/rules/ and $1/.agent/docs/ directly" >&2
  fi
}

# id must be 12 lowercase hex characters — spelled out rather than written
# as [0-9a-f], for the same reason lrn_grammar_ok spells its digit class.
lrn_id_ok() {
  hx='[0123456789abcdef]'
  # Unquoted on purpose: $hx must stay a glob bracket expression here, not
  # become a literal string once it reaches the case pattern.
  # shellcheck disable=SC2254
  case "$1" in
  $hx$hx$hx$hx$hx$hx$hx$hx$hx$hx$hx$hx) return 0 ;;
  *) return 1 ;;
  esac
}

cmd="${1:-}"
[ $# -ge 1 ] && shift

case "$cmd" in
-h | --help)
  usage
  exit 0 ;;
esac

case "$cmd" in
lookup)
  file=""
  root="."
  while [ $# -gt 0 ]; do
    case "$1" in
    --file)
      need_value "$@"
      file="$2"; shift 2 ;;
    -h | --help)
      usage; exit 0 ;;
    --*)
      echo "learn.sh: unknown flag: $1" >&2; usage >&2; exit 2 ;;
    *)
      root="$1"; shift ;;
    esac
  done
  [ -n "$file" ] || { echo "learn.sh: lookup requires --file <path|->" >&2; usage >&2; exit 2; }

  read_candidate "$file"
  agent="$root/.agent"
  learned_dir="$agent/rules/learned"
  if lrn_dir_is_real "$learned_dir"; then
    for lk_f in "$learned_dir"/*.md; do
      [ -e "$lk_f" ] || continue
      if cmp -s "$candidate_tmp" "$lk_f"; then
        lk_v=$(git hash-object --no-filters -- "$lk_f")
        printf 'duplicate\t%s\t%s\n' "$lk_f" "$lk_v"
      elif lrn_related "$candidate_tmp" "$lk_f"; then
        lk_v=$(git hash-object --no-filters -- "$lk_f")
        printf 'overlap\t%s\t%s\n' "$lk_f" "$lk_v"
      fi
    done
  fi
  exit 0
  ;;

new)
  file=""
  distinct=0
  surface="learned"
  root="."
  while [ $# -gt 0 ]; do
    case "$1" in
    --file)
      need_value "$@"
      file="$2"; shift 2 ;;
    --distinct)
      distinct=1; shift ;;
    --surface)
      need_value "$@"
      surface="$2"; shift 2 ;;
    -h | --help)
      usage; exit 0 ;;
    --*)
      echo "learn.sh: unknown flag: $1" >&2; usage >&2; exit 2 ;;
    *)
      root="$1"; shift ;;
    esac
  done
  [ -n "$file" ] || { echo "learn.sh: new requires --file <path|->" >&2; usage >&2; exit 2; }
  case "$surface" in
  learned | memory | docs | gotchas) ;;
  *)
    echo "learn.sh: --surface must be learned, memory, docs, or gotchas (got '$surface')" >&2
    exit 2 ;;
  esac

  agent="$root/.agent"
  learned_dir="$agent/rules/learned"
  if ! lrn_dir_is_real "$learned_dir"; then
    echo "learn.sh: $learned_dir does not exist — this node's learned-rules surface is $agent/rules/learned.md, which learn.sh does not write" >&2
    exit 7
  fi

  read_candidate "$file"
  lrn_grammar_ok "$candidate_tmp" || {
    echo "learn.sh: candidate is not a well-formed record — exactly one top-level \"- [YYYY-MM-DD] \" bullet, no second top-level bullet, no frontmatter block, no heading" >&2
    exit 6
  }
  lrn_warn_word_ceiling "$candidate_tmp"

  case "$surface" in
  learned) ;;
  memory)
    echo "learn.sh: --surface memory belongs to memory.sh, not learn.sh — write it with memory.sh new or memory.sh supersede" >&2
    exit 7 ;;
  docs)
    echo "learn.sh: --surface docs belongs to docs.sh, not learn.sh — write it there" >&2
    exit 7 ;;
  gotchas)
    echo "learn.sh: --surface gotchas belongs to the area doc's own ## Gotchas section, not learn.sh — edit that doc directly" >&2
    exit 7 ;;
  esac

  if new_dup=$(lrn_find_duplicate "$candidate_tmp" "$learned_dir"); then
    new_dup_v=$(git hash-object --no-filters -- "$new_dup")
    echo "learn.sh: candidate is byte-identical to $new_dup (version $new_dup_v) — refusing to write a duplicate" >&2
    exit 5
  fi

  new_overlaps=$(lrn_overlap_scan "$candidate_tmp" "$learned_dir")
  if [ -n "$new_overlaps" ] && [ "$distinct" -ne 1 ]; then
    echo "learn.sh: candidate shares nontrivial terms with:" >&2
    printf '%s\n' "$new_overlaps" | sed 's/^/  /' >&2
    echo "learn.sh: pass --distinct once you have confirmed this is a separate rule" >&2
    exit 4
  fi

  lrn_mint_and_write "$candidate_tmp" "$learned_dir" || {
    echo "learn.sh: aborting — 100 consecutive identity collisions in $learned_dir" >&2
    exit 2
  }
  new_version=$(git hash-object --no-filters -- "$learned_dir/$lrn_new_id.md")
  lrn_refresh_index "$root"
  printf 'written\t%s\t%s\n' "$lrn_new_id" "$new_version"
  exit 0
  ;;

revise)
  id=""
  file=""
  expected=""
  root="."
  while [ $# -gt 0 ]; do
    case "$1" in
    --file)
      need_value "$@"
      file="$2"; shift 2 ;;
    --expected)
      need_value "$@"
      expected="$2"; shift 2 ;;
    -h | --help)
      usage; exit 0 ;;
    --*)
      echo "learn.sh: unknown flag: $1" >&2; usage >&2; exit 2 ;;
    *)
      if [ -z "$id" ]; then id="$1"; else root="$1"; fi
      shift ;;
    esac
  done
  [ -n "$id" ] || { echo "learn.sh: revise requires <id>" >&2; usage >&2; exit 2; }
  lrn_id_ok "$id" || { echo "learn.sh: <id> must be 12 lowercase hex characters (got '$id')" >&2; exit 2; }
  [ -n "$file" ] || { echo "learn.sh: revise requires --file <path|->" >&2; usage >&2; exit 2; }
  [ -n "$expected" ] || { echo "learn.sh: revise requires --expected <version>" >&2; usage >&2; exit 2; }

  agent="$root/.agent"
  learned_dir="$agent/rules/learned"
  if ! lrn_dir_is_real "$learned_dir"; then
    echo "learn.sh: $learned_dir does not exist — this node's learned-rules surface is $agent/rules/learned.md, which learn.sh does not write" >&2
    exit 7
  fi
  target="$learned_dir/$id.md"

  read_candidate "$file"
  lrn_grammar_ok "$candidate_tmp" || {
    echo "learn.sh: candidate is not a well-formed record — exactly one top-level \"- [YYYY-MM-DD] \" bullet, no second top-level bullet, no frontmatter block, no heading" >&2
    exit 6
  }
  lrn_warn_word_ceiling "$candidate_tmp"

  if rv_dup=$(lrn_find_duplicate "$candidate_tmp" "$learned_dir"); then
    rv_dup_v=$(git hash-object --no-filters -- "$rv_dup")
    echo "learn.sh: candidate is byte-identical to $rv_dup (version $rv_dup_v) — refusing to write a duplicate" >&2
    exit 5
  fi

  rv_actual=$(lrn_current_version "$target")
  if [ "$expected" != "$rv_actual" ]; then
    echo "learn.sh: stale --expected for $id — current version: $rv_actual" >&2
    exit 3
  fi
  if [ "$rv_actual" = absent ]; then
    echo "learn.sh: $target does not exist — nothing to revise" >&2
    exit 2
  fi

  lrn_publish_replace "$candidate_tmp" "$target" || exit 2
  rv_version=$(git hash-object --no-filters -- "$target")
  lrn_refresh_index "$root"
  printf 'revised\t%s\t%s\n' "$id" "$rv_version"
  exit 0
  ;;

retire)
  id=""
  expected=""
  root="."
  while [ $# -gt 0 ]; do
    case "$1" in
    --expected)
      need_value "$@"
      expected="$2"; shift 2 ;;
    -h | --help)
      usage; exit 0 ;;
    --*)
      echo "learn.sh: unknown flag: $1" >&2; usage >&2; exit 2 ;;
    *)
      if [ -z "$id" ]; then id="$1"; else root="$1"; fi
      shift ;;
    esac
  done
  [ -n "$id" ] || { echo "learn.sh: retire requires <id>" >&2; usage >&2; exit 2; }
  lrn_id_ok "$id" || { echo "learn.sh: <id> must be 12 lowercase hex characters (got '$id')" >&2; exit 2; }
  [ -n "$expected" ] || { echo "learn.sh: retire requires --expected <version>" >&2; usage >&2; exit 2; }

  agent="$root/.agent"
  learned_dir="$agent/rules/learned"
  if ! lrn_dir_is_real "$learned_dir"; then
    echo "learn.sh: $learned_dir does not exist — this node's learned-rules surface is $agent/rules/learned.md, which learn.sh does not write" >&2
    exit 7
  fi
  target="$learned_dir/$id.md"

  rt_actual=$(lrn_current_version "$target")
  if [ "$expected" != "$rt_actual" ]; then
    echo "learn.sh: stale --expected for $id — current version: $rt_actual" >&2
    exit 3
  fi
  if [ "$rt_actual" = absent ]; then
    echo "learn.sh: $target does not exist — nothing to retire" >&2
    exit 2
  fi

  if rm -f "$target"; then
    lrn_refresh_index "$root"
    printf 'retired\t%s\n' "$id"
    exit 0
  fi
  echo "learn.sh: could not remove $target" >&2
  exit 2
  ;;

"")
  usage >&2
  exit 2 ;;

*)
  echo "learn.sh: unknown command: $cmd" >&2
  usage >&2
  exit 2 ;;
esac
