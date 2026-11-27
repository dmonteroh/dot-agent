#!/usr/bin/env bash

set -u
export LC_ALL=C
unset CDPATH

selfdir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || exit 2
[ -f "$selfdir/runtime.sh" ] || { echo 'learn.sh: runtime.sh is missing. Update this node with node.sh update from the dot-agent repository' >&2; exit 2; }
# shellcheck source=runtime.sh
. "$selfdir/runtime.sh"

usage() {
  cat <<'EOF'
Usage: learn.sh lookup   --file <path|-> [root]
       learn.sh new      --file <path|-> [--distinct-from <id>[,<id>...]] [--surface learned|memory|docs|gotchas] [root]
       learn.sh revise   <id> --file <path|-> --expected <version> [root]
       learn.sh retire   <id> --expected <version> --enforced-by <path> [root]
       learn.sh pending  [root]
       learn.sh resolve  --id <id> --disposition <value> [root]

root defaults to . — the project root holding .agent/. A record lives at
<root>/.agent/rules/learned/<id>.md; <id> is its filename without .md, a
minted 12-character lowercase-hex identity. <version> is
git hash-object --no-filters -- of that record file. --file - reads the
candidate body from stdin. retire names, as a path under root, the check,
script, doc, or surviving record that now enforces the rule. pending lists the migration's open
semantic-review-pending and hook-missing items from
<root>/.agent/migration-inventory.md; resolve closes one, --disposition
one of migrated, "migrated (split into <id>[, <id>]...)",
"migrated (merged into <id>)", or retired. Full documentation:
scripts/docs/learn.md.
EOF
}

refuse() { da_refuse "$1" "$2" "${3:-2}"; exit $?; }
refuse_usage() { usage >&2; refuse "$@"; }

need_value() {
  case "${2-}" in
  --file | --surface | --expected | --distinct-from | --id | --disposition | --enforced-by)
    refuse_usage "$1 needs a value, got the flag $2" "Pass a value after $1" ;;
  esac
  if [ $# -lt 2 ]; then
    refuse_usage "$1 needs a value" "Pass a value after $1"
  fi
}

candidate_tmp=""
resolve_tmp=""
writer_lock=""
cleanup() {
  [ -n "$candidate_tmp" ] && rm -f "$candidate_tmp"
  [ -n "$resolve_tmp" ] && rm -f "$resolve_tmp"
  if [ -n "$writer_lock" ] && [ -d "$writer_lock" ] \
    && [ "$(cat "$writer_lock/owner" 2>/dev/null)" = "$$" ]; then
    rm -f "$writer_lock/owner"
    rmdir "$writer_lock" 2>/dev/null || :
  fi
}
trap cleanup EXIT

lrn_dir_is_real() {
  [ -d "$1" ] && [ ! -L "$1" ]
}

read_candidate() {
  candidate_tmp=$(mktemp "${TMPDIR:-/tmp}/learn-candidate.XXXXXX") || {
    refuse "could not create a temporary file for the candidate" "Check that the temporary folder is writable, then run this call again"
  }
  if [ "$1" = "-" ]; then
    cat >"$candidate_tmp"
  else
    if [ ! -f "$1" ]; then
      refuse "--file $1 does not exist" "Pass an existing file, or --file - with the candidate on stdin"
    fi
    cat "$1" >"$candidate_tmp"
  fi
}

lrn_grammar_ok() {
  gcd_digit='[0123456789]'
  gcd_pat="^- \\[${gcd_digit}${gcd_digit}${gcd_digit}${gcd_digit}-${gcd_digit}${gcd_digit}-${gcd_digit}${gcd_digit}\\] "
  head -n 1 "$1" | grep -qE "$gcd_pat" || return 1
  tail -n +2 "$1" | grep -qE '^- ' && return 1
  grep -qE '^#' "$1" && return 1
  return 0
}

lrn_scan_records() {
  sr_candidate="$1"
  sr_dir="$2"
  set -- "$sr_candidate"
  for sr_f in "$sr_dir"/*.md; do
    [ -e "$sr_f" ] || continue
    set -- "$@" "$sr_f"
  done
  awk -v candidate="$sr_candidate" '
    function words(s,a, n,i,t) {
      s=tolower(s); gsub(/[^abcdefghijklmnopqrstuvwxyz0123456789]+/," ",s)
      n=split(s,t," "); for(i=1;i<=n;i++) if(length(t[i])>2 && t[i] !~ /^(the|and|for|with|from|this|that|must|should|trigger)$/) a[t[i]]=1
    }
    function finish( k,n,shared,small) {
      if(name=="") return
      if(name==candidate) { cand=body; for(k in curterms) { cterms[k]=1; nc++ } }
      else {
        n=shared=0; for(k in curterms) { n++; if(k in cterms) shared++ }
        small=(n<nc ? n : nc)
        if(body==cand) print "duplicate\t" name
        else if(shared>=2 && 4*shared>=small) print "overlap\t" name
      }
    }
    FNR==1 { finish(); name=FILENAME; body=""; first=1; cause=0; delete curterms }
    {
      line=$0
      if(first) { sub(/^- \[[0123456789][0123456789][0123456789][0123456789]-[0123456789][0123456789]-[0123456789][0123456789]\] /,"",line); first=0 }
      body=body (body=="" ? "" : "\n") line
      if(cause) next
      if(at=index(line,"Trigger:")) { line=substr(line,1,at-1); cause=1 }
      words(line,curterms)
    }
    END { finish() }
  ' "$@" || return 2
}

lrn_find_duplicate() {
  fd_all=$(lrn_scan_records "$1" "$2") || return 2
  fd_one=$(printf '%s\n' "$fd_all" | awk -F '\t' '$1=="duplicate" {print $2; exit}')
  [ -n "$fd_one" ] || return 1
  printf '%s\n' "$fd_one"
}

# The records and contract sections new makes the caller name, one per line:
# record<TAB>path<TAB>rule, or section<TAB>file:heading<TAB>path. Only the rule
# counts, not its Trigger clause. A record is listed when the two rules share a
# quarter of the shorter one's terms and at least two, and a section when it
# holds half of the candidate's and at least five (chosen defaults). One shared
# term would list nearly every record and section. lookup lists records by the
# same record test.
lrn_gate() {
  ga_candidate="$1"
  ga_contract="$3/contract.md"
  ga_bar="$3/quality-bar.md"
  set -- "$1" "$2"/*.md
  [ -e "$2" ] || set -- "$1"
  for ga_f in "$ga_contract" "$ga_bar"; do
    [ ! -f "$ga_f" ] || set -- "$@" "$ga_f"
  done
  awk -v candidate="$ga_candidate" -v contract="$ga_contract" -v bar="$ga_bar" '
    function words(s,a, n,i,t) {
      s=tolower(s); gsub(/[^abcdefghijklmnopqrstuvwxyz0123456789]+/," ",s)
      n=split(s,t," "); for(i=1;i<=n;i++) if(length(t[i])>2 && t[i] !~ /^(the|and|for|with|from|this|that|must|should|trigger)$/) a[t[i]]=1
    }
    function finish( k,n,shared,small) {
      if(name==candidate) { for(k in cur) { cand[k]=1; nc++ } }
      else if(name!="" && (kind=="record" || heading!="")) {
        n=shared=0; for(k in cur) { n++; if(k in cand) shared++ }
        small=(n<nc ? n : nc)
        if(kind=="record" && shared>=2 && 4*shared>=small) print "record\t" name "\t" rule
        if(kind=="section" && shared>=5 && 2*shared>=nc) print "section\t" label ":" heading "\t" name
      }
      delete cur; heading=""; rule=""; cause=0
    }
    FNR==1 { finish(); name=FILENAME; kind=(name==contract || name==bar ? "section" : "record"); label=(name==bar ? "quality-bar" : "contract") }
    kind=="section" {
      if($0 ~ /^## /) { finish(); heading=substr($0,4); sub(/[[:space:]]+$/,"",heading) }
      else if(heading!="") words($0,cur)
      next
    }
    {
      line=$0
      if(FNR==1) { sub(/^- \[[-0123456789]*\] /,"",line); rule=line }
      if(cause) next
      if(at=index(line,"Trigger:")) { line=substr(line,1,at-1); cause=1 }
      words(line,cur)
    }
    END { finish() }
  ' "$@"
}

lrn_manual_lookup() {
  ml_candidate="$1"
  ml_file="$2"
  ml_rel="$3"
  ml_version=$(git hash-object --no-filters -- "$ml_file") || return 2
  awk -v path="$ml_rel" -v version="$ml_version" '
    function words(s,a, n,i,t) { s=tolower(s); gsub(/[^abcdefghijklmnopqrstuvwxyz0123456789]+/," ",s); n=split(s,t," "); for(i=1;i<=n;i++) if(length(t[i])>2 && t[i] !~ /^(the|and|for|with|from|this|that|must|should|trigger)$/) a[t[i]]=1 }
    function normfirst(s) { sub(/^- \[[0123456789][0123456789][0123456789][0123456789]-[0123456789][0123456789]-[0123456789][0123456789]\] /,"",s); return s }
    function rule(s,a) {
      if(cause) return
      if(at=index(s,"Trigger:")) { s=substr(s,1,at-1); cause=1 }
      words(s,a)
    }
    function judge( k,n,shared,small) {
      if(rec=="") return
      if(nc=="") { nc=0; for(k in ct) nc++ }
      n=shared=0; for(k in rt) { n++; if(k in ct) shared++ }
      small=(n<nc ? n : nc)
      if(rec==cand) dup=1
      else if(shared>=2 && 4*shared>=small) near=1
    }
    NR==FNR { line=$0; if(FNR==1) line=normfirst(line); cand=cand (cand==""?"":"\n") line; rule(line,ct); next }
    /^- \[[0123456789][0123456789][0123456789][0123456789]-[0123456789][0123456789]-[0123456789][0123456789]\] / { judge(); delete rt; cause=0; rec=normfirst($0); rule(rec,rt); next }
    rec!="" { rec=rec "\n" $0; rule($0,rt) }
    END {
      judge()
      if(dup) print "duplicate\t" path "\t" version
      if(near) print "overlap\t" path "\t" version
    }
  ' "$ml_candidate" "$ml_file"
}

lrn_current_version() {
  if [ -f "$1" ]; then
    git hash-object --no-filters -- "$1"
  else
    printf 'absent'
  fi
}

lrn_lock_writers() {
  da_lock_wait "$1/.learn-writer.lock" || exit 2
  writer_lock="$1/.learn-writer.lock"
}

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

lrn_publish_replace() {
  pr_tmp="$2.tmp.$$"
  if cat "$1" >"$pr_tmp"; then
    :
  else
    rm -f "$pr_tmp"
    da_refuse "could not write $pr_tmp, and $2 is unchanged" "Check that the folder is writable, then run this call again"
    return 1
  fi
  if [ "$#" -ge 4 ]; then
    pr_actual=$(lrn_current_version "$2") || {
      rm -f "$pr_tmp"
      return 2
    }
    if [ "$3" != "$pr_actual" ]; then
      rm -f "$pr_tmp"
      da_refuse "stale --expected for $4, whose current version is $pr_actual" "Read the record again, then run this call with the current version as --expected"
      return 3
    fi
  fi
  if mv "$pr_tmp" "$2"; then
    return 0
  fi
  rm -f "$pr_tmp"
  da_refuse "could not replace $2, which is unchanged" "Check that the folder is writable, then run this call again"
  return 1
}

lrn_indexes_mode() {
  im_purpose="$1/.agent/purpose.md"
  [ -f "$im_purpose" ] || { printf 'manual'; return; }
  im_line=$(grep -m1 '^  indexes:' "$im_purpose")
  im_val=$(printf '%s\n' "$im_line" | sed -E 's/^[[:space:]]*indexes:[[:space:]]*([A-Za-z-]+).*/\1/')
  [ -n "$im_val" ] || im_val=manual
  printf '%s' "$im_val"
}

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

lrn_id_ok() {
  hx='[0123456789abcdef]'
  # shellcheck disable=SC2254
  case "$1" in
  $hx$hx$hx$hx$hx$hx$hx$hx$hx$hx$hx$hx) return 0 ;;
  *) return 1 ;;
  esac
}

lrn_split_item() {
  si_rest="${1% | *}"
  lrn_item_disp="${1##* | }"
  lrn_item_idfield="${si_rest##* | }"
  lrn_item_label="${si_rest% | *}"
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
      refuse_usage "unknown flag: $1" "Pass only the flags listed above" ;;
    *)
      root="$1"; shift ;;
    esac
  done
  [ -n "$file" ] || refuse_usage "lookup requires --file <path|->" "Run this call again with --file"

  read_candidate "$file"
  agent="$root/.agent"
  learned_dir="$agent/rules/learned"
  if lrn_dir_is_real "$learned_dir"; then
    lk_results=$(lrn_scan_records "$candidate_tmp" "$learned_dir") || refuse "could not read the records in $learned_dir" "Check that they are readable, then run this call again"
    for lk_kind in duplicate overlap; do
      printf '%s\n' "$lk_results" | while IFS="$(printf '\t')" read -r lk_type lk_f; do
        [ "$lk_type" = "$lk_kind" ] || continue
        lk_v=$(git hash-object --no-filters -- "$lk_f") || refuse "could not read the records in $learned_dir" "Check that they are readable, then run this call again"
        printf '%s\t%s\t%s\n' "$lk_type" "$lk_f" "$lk_v"
      done || exit 2
    done
  elif [ -f "$agent/rules/learned.md" ]; then
    lrn_manual_lookup "$candidate_tmp" "$agent/rules/learned.md" "$agent/rules/learned.md"
  fi
  exit 0
  ;;

new)
  file=""
  distinct_from=""
  surface="learned"
  root="."
  while [ $# -gt 0 ]; do
    case "$1" in
    --file)
      need_value "$@"
      file="$2"; shift 2 ;;
    --distinct-from)
      need_value "$@"
      distinct_from="$distinct_from,$2"; shift 2 ;;
    --surface)
      need_value "$@"
      surface="$2"; shift 2 ;;
    -h | --help)
      usage; exit 0 ;;
    --*)
      refuse_usage "unknown flag: $1" "Pass only the flags listed above" ;;
    *)
      root="$1"; shift ;;
    esac
  done
  [ -n "$file" ] || refuse_usage "new requires --file <path|->" "Run this call again with --file"
  case "$surface" in
  learned | memory | docs | gotchas) ;;
  *)
    refuse "--surface must be learned, memory, docs, or gotchas (got '$surface')" "Pass one of those, or drop --surface" ;;
  esac

  agent="$root/.agent"
  learned_dir="$agent/rules/learned"
  if ! lrn_dir_is_real "$learned_dir"; then
    if [ "$(lrn_indexes_mode "$root")" = generated ] && [ ! -e "$learned_dir" ]; then
      mkdir -p "$learned_dir" || refuse "could not create $learned_dir" "Check that the folder is writable, then run this call again"
    else
      refuse "$learned_dir does not exist, and learn.sh does not write this node's learned rules in $agent/rules/learned.md" "Edit that file by hand, and merge near-duplicates there" 7
    fi
  fi
  lrn_lock_writers "$learned_dir"

  read_candidate "$file"
  lrn_grammar_ok "$candidate_tmp" || refuse "the candidate is not a well-formed record" "Write exactly one top-level \"- [YYYY-MM-DD] \" bullet with no second bullet, frontmatter, or heading" 6

  case "$surface" in
  learned) ;;
  memory)
    refuse "--surface memory belongs to memory.sh" "Write it with memory.sh new or memory.sh supersede" 7 ;;
  docs)
    refuse "--surface docs belongs to the area doc" "Edit that doc, or add one with docs.sh new" 7 ;;
  gotchas)
    refuse "--surface gotchas belongs to the area doc's own ## Gotchas section" "Edit that doc directly" 7 ;;
  esac

  if new_dup=$(lrn_find_duplicate "$candidate_tmp" "$learned_dir"); then
    new_dup_v=$(git hash-object --no-filters -- "$new_dup")
    refuse "the candidate body (ignoring its leading date) duplicates $new_dup (version $new_dup_v)" "Nothing is owed: the rule is already recorded" 5
  fi

  new_hits=$(lrn_gate "$candidate_tmp" "$learned_dir" "$agent/rules") || refuse "could not compare the candidate with the node's rules" "Check that the files under .agent/rules/ are readable, then run this call again"
  new_sections=0
  new_unnamed=0
  distinct_from=",$(printf '%s' "$distinct_from" | sed 's/ *, */,/g'),"
  while IFS="$(printf '\t')" read -r new_kind new_name new_text; do
    [ -n "$new_kind" ] || continue
    new_token="$new_name"
    [ "$new_kind" = section ] || { new_token="${new_name##*/}"; new_token="${new_token%.md}"; }
    case "$distinct_from" in *",$(printf '%s' "$new_token" | sed 's/ *, */,/g'),"*) continue ;; esac
    new_unnamed=1
    if [ "$new_kind" = section ]; then
      new_sections=1
      printf '  %s  the section in %s\n' "$new_name" "$new_text" >&2
    else
      printf '  %s  %s\n' "$new_name" "$new_text" >&2
    fi
  done <<EOF
$new_hits
EOF
  if [ "$new_unnamed" -eq 1 ]; then
    new_next="If one of the records covers it, revise that record with learn.sh revise. If the candidate says something none of them says, run this call again with --distinct-from and every id above, separated by commas"
    [ "$new_sections" -eq 0 ] || new_next="A rule the contract already states is not a learned rule: if a section above is wrong or incomplete, change it there. $new_next"
    refuse "the candidate shares much of its wording with each rule listed above" "$new_next" 4
  fi

  lrn_mint_and_write "$candidate_tmp" "$learned_dir" || refuse "could not write a record in $learned_dir after 100 tries" "Check that the folder is writable, then run this call again"
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
      refuse_usage "unknown flag: $1" "Pass only the flags listed above" ;;
    *)
      if [ -z "$id" ]; then id="$1"; else root="$1"; fi
      shift ;;
    esac
  done
  [ -n "$id" ] || refuse_usage "revise requires <id>" "Run this call again with the record's id"
  lrn_id_ok "$id" || refuse "<id> must be 12 lowercase hex characters (got '$id')" "Pass the record's file name without .md"
  [ -n "$file" ] || refuse_usage "revise requires --file <path|->" "Run this call again with --file"
  [ -n "$expected" ] || refuse_usage "revise requires --expected <version>" "Pass the version learn.sh lookup prints"

  agent="$root/.agent"
  learned_dir="$agent/rules/learned"
  if ! lrn_dir_is_real "$learned_dir"; then
    refuse "$learned_dir does not exist, and learn.sh does not write this node's learned rules in $agent/rules/learned.md" "Edit that file by hand, and merge near-duplicates there" 7
  fi
  target="$learned_dir/$id.md"
  lrn_lock_writers "$learned_dir"

  read_candidate "$file"
  lrn_grammar_ok "$candidate_tmp" || refuse "the candidate is not a well-formed record" "Write exactly one top-level \"- [YYYY-MM-DD] \" bullet with no second bullet, frontmatter, or heading" 6

  if rv_dup=$(lrn_find_duplicate "$candidate_tmp" "$learned_dir"); then
    rv_dup_v=$(git hash-object --no-filters -- "$rv_dup")
    refuse "the candidate body (ignoring its leading date) duplicates $rv_dup (version $rv_dup_v)" "Nothing is owed if that is the record being revised. Otherwise retire one of the two" 5
  fi

  rv_actual=$(lrn_current_version "$target")
  if [ "$expected" != "$rv_actual" ]; then
    refuse "stale --expected for $id, whose current version is $rv_actual" "Read the record again, then run this call with the current version as --expected" 3
  fi
  if [ "$rv_actual" = absent ]; then
    refuse "$target does not exist, so there is nothing to revise" "Use learn.sh new for a new rule"
  fi

  if lrn_publish_replace "$candidate_tmp" "$target" "$expected" "$id"; then
    :
  else
    rv_status=$?
    [ "$rv_status" -eq 3 ] && exit 3
    exit 2
  fi
  rv_version=$(git hash-object --no-filters -- "$target")
  lrn_refresh_index "$root"
  printf 'revised\t%s\t%s\n' "$id" "$rv_version"
  exit 0
  ;;

retire)
  id=""
  expected=""
  enforced_by=""
  root="."
  while [ $# -gt 0 ]; do
    case "$1" in
    --expected)
      need_value "$@"
      expected="$2"; shift 2 ;;
    --enforced-by)
      need_value "$@"
      enforced_by="$2"; shift 2 ;;
    -h | --help)
      usage; exit 0 ;;
    --*)
      refuse_usage "unknown flag: $1" "Pass only the flags listed above" ;;
    *)
      if [ -z "$id" ]; then id="$1"; else root="$1"; fi
      shift ;;
    esac
  done
  [ -n "$id" ] || refuse_usage "retire requires <id>" "Run this call again with the record's id"
  lrn_id_ok "$id" || refuse "<id> must be 12 lowercase hex characters (got '$id')" "Pass the record's file name without .md"
  [ -n "$expected" ] || refuse_usage "retire requires --expected <version>" "Pass the version learn.sh lookup prints"
  # A rule leaves only when something else now enforces it: a check, script,
  # doc, contract section, or the record it was folded into.
  [ -n "$enforced_by" ] || refuse_usage "retire requires --enforced-by <path>" "Name the check, script, doc, or record that now enforces this rule, and keep the rule if nothing does"
  case "$enforced_by" in
  /* | ../* | */../* | .. | */..)
    refuse "--enforced-by must be a path inside the project root, relative to it (got '$enforced_by')" "Pass a relative path such as .agent/rules/contract.md" ;;
  esac
  if [ ! -e "$root/$enforced_by" ]; then
    refuse "--enforced-by $enforced_by does not exist under $root" "Name the check, script, doc, or record that enforces this rule"
  fi
  case "${enforced_by#./}" in
  ".agent/rules/learned/$id.md")
    refuse "--enforced-by names the record being retired" "Name what enforces the rule once it is gone" ;;
  esac

  agent="$root/.agent"
  learned_dir="$agent/rules/learned"
  if ! lrn_dir_is_real "$learned_dir"; then
    refuse "$learned_dir does not exist, and learn.sh does not write this node's learned rules in $agent/rules/learned.md" "Edit that file by hand, and merge near-duplicates there" 7
  fi
  target="$learned_dir/$id.md"
  lrn_lock_writers "$learned_dir"

  rt_actual=$(lrn_current_version "$target")
  if [ "$expected" != "$rt_actual" ]; then
    refuse "stale --expected for $id, whose current version is $rt_actual" "Read the record again, then run this call with the current version as --expected" 3
  fi
  if [ "$rt_actual" = absent ]; then
    refuse "$target does not exist, so there is nothing to retire" "Check the id against .agent/rules/learned/"
  fi

  rt_publish_actual=$(lrn_current_version "$target")
  if [ "$expected" != "$rt_publish_actual" ]; then
    refuse "stale --expected for $id, whose current version is $rt_publish_actual" "Read the record again, then run this call with the current version as --expected" 3
  fi

  if rm -f "$target"; then
    lrn_refresh_index "$root"
    printf 'retired\t%s\n' "$id"
    exit 0
  fi
  refuse "could not remove $target" "Check that the folder is writable, then run this call again"
  ;;

pending)
  root="."
  while [ $# -gt 0 ]; do
    case "$1" in
    -h | --help)
      usage; exit 0 ;;
    --*)
      refuse_usage "unknown flag: $1" "Pass only the flags listed above" ;;
    *)
      root="$1"; shift ;;
    esac
  done

  agent="$root/.agent"
  learned_dir="$agent/rules/learned"
  inventory="$agent/migration-inventory.md"
  [ -f "$inventory" ] || exit 0

  pnd_n=0
  while IFS= read -r pnd_line || [ -n "$pnd_line" ]; do
    case "$pnd_line" in
    '- rule '* | '- doc '*) ;;
    *) continue ;;
    esac
    lrn_split_item "$pnd_line"
    case "$lrn_item_disp" in
    semantic-review-pending | hook-missing) ;;
    *) continue ;;
    esac
    pnd_id="${lrn_item_idfield#id=}"
    case "$pnd_line" in
    '- rule '*)
      pnd_record="$learned_dir/$pnd_id.md"
      if [ -f "$pnd_record" ]; then
        pnd_version=$(git hash-object --no-filters -- "$pnd_record")
      else
        pnd_version="absent"
      fi ;;
    *)
      pnd_version="-" ;;
    esac
    printf '%s | %s | %s | version=%s\n' "$lrn_item_label" "$lrn_item_disp" "$pnd_id" "$pnd_version"
    pnd_n=$((pnd_n + 1))
  done <"$inventory"

  [ "$pnd_n" -gt 0 ] && printf '%d pending\n' "$pnd_n"
  exit 0
  ;;

resolve)
  id=""
  disp=""
  root="."
  while [ $# -gt 0 ]; do
    case "$1" in
    --id)
      need_value "$@"
      id="$2"; shift 2 ;;
    --disposition)
      need_value "$@"
      disp="$2"; shift 2 ;;
    -h | --help)
      usage; exit 0 ;;
    --*)
      refuse_usage "unknown flag: $1" "Pass only the flags listed above" ;;
    *)
      root="$1"; shift ;;
    esac
  done
  [ -n "$id" ] || refuse_usage "resolve requires --id <id>" "Pass an id learn.sh pending lists"
  [ -n "$disp" ] || refuse_usage "resolve requires --disposition <value>" "Pass one of the dispositions listed above"

  agent="$root/.agent"
  learned_dir="$agent/rules/learned"
  docs_dir="$agent/docs"
  inventory="$agent/migration-inventory.md"
  [ -f "$inventory" ] || refuse "$inventory does not exist, so there is nothing to resolve" "Nothing is owed on this node"

  rsv_matches=0
  rsv_kind=""
  rsv_disp=""
  while IFS= read -r rsv_line || [ -n "$rsv_line" ]; do
    case "$rsv_line" in
    '- rule '*) rsv_this_kind=rule ;;
    '- doc '*) rsv_this_kind=doc ;;
    *) continue ;;
    esac
    lrn_split_item "$rsv_line"
    if [ "${lrn_item_idfield#id=}" = "$id" ]; then
      rsv_matches=$((rsv_matches + 1))
      rsv_kind="$rsv_this_kind"
      rsv_disp="$lrn_item_disp"
    fi
  done <"$inventory"

  if [ "$rsv_matches" -eq 0 ]; then
    refuse "$inventory carries no item with id=$id" "Pass an id learn.sh pending lists"
  fi
  if [ "$rsv_matches" -gt 1 ]; then
    refuse "$inventory carries id=$id on more than one line" "Edit it to a single match, then run this call again"
  fi

  case "$rsv_disp" in
  semantic-review-pending | hook-missing) ;;
  *)
    refuse "id=$id is not pending, and its disposition is already: $rsv_disp" "Nothing is owed for this item" ;;
  esac

  case "$disp" in
  migrated)
    rsv_form="migrated"
    rsv_check_ids="$id" ;;
  retired)
    rsv_form="retired"
    rsv_check_ids="$id" ;;
  'migrated (split into '*')')
    rsv_form="split"
    rsv_targets="${disp#*split into }"
    rsv_targets="${rsv_targets%)}"
    rsv_check_ids=$(printf '%s' "$rsv_targets" | tr ',' '\n' | sed 's/^ *//; s/ *$//') ;;
  'migrated (merged into '*')')
    rsv_form="merged"
    rsv_target="${disp#*merged into }"
    rsv_check_ids="${rsv_target%)}" ;;
  *)
    refuse "--disposition must be migrated, retired, 'migrated (split into <id>[, <id>]...)', or 'migrated (merged into <id>)' (got '$disp')" "Pass one of those" ;;
  esac

  if [ "$rsv_kind" = doc ]; then
    case "$rsv_form" in
    split | merged | retired)
      refuse "split, merge, and retired are rule-only dispositions, and id=$id is a doc item" "Pass --disposition migrated" ;;
    esac
  fi

  if [ "$rsv_form" = split ] || [ "$rsv_form" = merged ]; then
    for rsv_t in $rsv_check_ids; do
      lrn_id_ok "$rsv_t" || {
        refuse "--disposition names '$rsv_t', not a 12-lowercase-hex identity" "Pass the record's file name without .md"
      }
    done
  fi

  if [ "$rsv_kind" = rule ]; then
    case "$rsv_form" in
    migrated | split | merged)
      for rsv_t in $rsv_check_ids; do
        [ -f "$learned_dir/$rsv_t.md" ] || {
          refuse "--disposition names $rsv_t, which has no $learned_dir/$rsv_t.md" "Write that record first, then run this call again"
        }
      done ;;
    retired)
      if [ -f "$learned_dir/$id.md" ]; then
        refuse "id=$id is given retired but $learned_dir/$id.md still exists" "Retire the record with learn.sh retire, then run this call again"
      fi ;;
    esac
  else
    rsv_doc="$docs_dir/$id"
    if ! head -n 5 "$rsv_doc" 2>/dev/null | grep -q '^<!-- Read when: .* -->$'; then
      refuse "$rsv_doc still carries no \"<!-- Read when: ... -->\" header in its first five lines" "Run docs.sh sync --name $id --read-when with its hook, then run this call again"
    fi
  fi

  resolve_tmp=$(mktemp "${TMPDIR:-/tmp}/learn-resolve.XXXXXX") || {
    refuse "could not create a temporary file to rewrite $inventory" "Check that the temporary folder is writable, then run this call again"
  }
  : >"$resolve_tmp"
  while IFS= read -r rsv_line2 || [ -n "$rsv_line2" ]; do
    case "$rsv_line2" in
    '- rule '* | '- doc '*)
      lrn_split_item "$rsv_line2"
      if [ "${lrn_item_idfield#id=}" = "$id" ]; then
        printf '%s | %s\n' "${rsv_line2% | *}" "$disp" >>"$resolve_tmp"
        continue
      fi ;;
    esac
    printf '%s\n' "$rsv_line2" >>"$resolve_tmp"
  done <"$inventory"

  lrn_publish_replace "$resolve_tmp" "$inventory" || exit 2
  rm -f "$resolve_tmp"
  resolve_tmp=""
  printf 'resolved\t%s\t%s\n' "$id" "$disp"
  exit 0
  ;;

"")
  refuse_usage "no command was given" "Pass one of the commands listed above" ;;

*)
  refuse_usage "unknown command: $cmd" "Pass one of the commands listed above" ;;
esac
