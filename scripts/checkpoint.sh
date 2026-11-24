#!/usr/bin/env bash
set -u
unset CDPATH

selfdir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
[ -f "$selfdir/runtime.sh" ] || { echo 'checkpoint.sh: runtime.sh is missing. Update this node with node.sh update from the dot-agent repository' >&2; exit 1; }
# shellcheck source=runtime.sh
. "$selfdir/runtime.sh"

usage() {
  cat <<'EOF'
Usage: checkpoint.sh --tool NAME --area NAME --summary TEXT
       [--checks CHECK[,CHECK...]] [--verification ID[,ID...]]
       [--verify fail|n/a] [--base REF] [--node-only] [--policy strict|completion] [ROOT]

Situation                                          Flags
Product files changed, not committed               --checks <name>
The work is committed                              --checks <name>
  and no earlier checkpoint was recorded here      --checks <name> --base <commit before the work>
Only ignored node files changed                    --node-only --verify n/a
A check already ran on these inputs                --verification <receipt id>
The work failed and that is the outcome            --verification <receipt id> --verify fail
Nothing can be run for this change                 --verify n/a

--verify pass needs --checks or --verification. Given both, a current receipt
answers for the check it records, and every other named check runs.
--checks n/a means --verify n/a.
Work is reviewed from the last recorded checkpoint. --base overrides that.
strict blocks every status finding. completion defers advisory maintenance.
A rerun over recorded content writes no second log entry.
EOF
}

root=.; base=""; policy=""; tool=""; area=""; summary=""
checks=""; receipts=""; requested_verify=""; node_only=0
failed_checks=""; uncounted=""; unread=""; empty=""; moved=""
lock=""; content_out=""; node=""; status_out=""; status_err=""; publish=""; prepare=""
cleanup() {
  [ -z "$publish" ] || rm -f -- "$publish"
  [ -z "$content_out" ] || rm -f -- "$content_out"
  [ -z "$status_out" ] || rm -f -- "$status_out"
  [ -z "$status_err" ] || rm -f -- "$status_err"
  if [ -n "$prepare" ]; then
    rm -f -- "$prepare/before" "$prepare/after" "$prepare/fingerprint" "$prepare/head" "$prepare/node" "$prepare/log"
    rmdir "$prepare" 2>/dev/null || true
  fi
  [ -z "$lock" ] || da_unlock "$lock"
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
refuse() { da_refuse "$@"; exit $?; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tool|--area|--summary|--checks|--verification|--verify|--base|--policy)
      [ "$#" -ge 2 ] || refuse "$1 needs a value" 'Pass the value after the flag, or run checkpoint.sh --help'
      case "$1" in
        --tool) tool=$2 ;; --area) area=$2 ;; --summary) summary=$2 ;;
        --checks) checks=$2 ;; --verification) receipts=$2 ;;
        --verify) requested_verify=$2 ;; --base) base=$2 ;; --policy) policy=$2 ;;
      esac
      shift 2 ;;
    --help|-h) usage; exit 0 ;;
    --version) echo 'dot-agent checkpoint 6.3'; exit 0 ;;
    --node-only) node_only=1; shift ;;
    --*) refuse "unknown flag: $1" 'Run checkpoint.sh --help for the flags it takes' ;;
    *) root=$1; shift ;;
  esac
done
[ -n "$tool" ] && [ -n "$area" ] && [ -n "$summary" ] || { usage >&2; refuse '--tool, --area, and --summary are required' 'Run this call again with all three'; }
# n/a is no check name. A session with nothing to run says so in whichever
# flag it filled, and refusing the wrong one costs it a second call.
if [ "$checks" = n/a ]; then
  checks=""
  [ -n "$requested_verify" ] || requested_verify=n/a
  echo 'checkpoint.sh: --checks n/a read as --verify n/a'
fi
case "$requested_verify" in ''|pass|fail|n/a) ;; *) refuse '--verify must be pass, fail, or n/a' 'Pass one of those, or drop it when --checks or --verification is given' ;; esac
root=$(da_root "$root") || exit 1
scripts="$root/.agent/scripts"
for helper in review.sh status.sh log.sh verify.sh; do
  [ -f "$scripts/$helper" ] || refuse "$scripts/$helper is missing" 'Update this node with node.sh update from the dot-agent repository'
done
if [ -z "$policy" ]; then
  policy=$(sed -n 's/^POLICY=//p' "$scripts/checkpoint.conf" 2>/dev/null | head -n 1 | sed 's/[[:space:]]*$//')
fi
policy=${policy:-strict}
case "$policy" in strict|completion) ;; *) refuse 'the policy must be strict or completion' 'Fix POLICY in .agent/scripts/checkpoint.conf, or pass --policy strict' ;; esac
bash "$scripts/log.sh" --print-entry --tool "$tool" --area "$area" --verify n/a --summary "$summary" "$root" >/dev/null || exit 1
is_git=0
git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 && is_git=1
if [ "$is_git" -eq 0 ]; then
  [ -z "$base" ] || refuse '--base requires a Git worktree' 'Run this call again without --base'
  non_git_inputs=$(sed -n 's/^NON_GIT_INPUT_ROOTS=//p' "$scripts/verify.conf" 2>/dev/null | head -n 1)
  export DA_NON_GIT_INPUT_ROOTS=".agent${non_git_inputs:+ $non_git_inputs}"
fi

state=$(da_state_dir "$root") || exit 1
lock="$state/checkpoint.lock"
da_lock_wait "$lock" || { lock=""; exit 1; }
log="$root/.agent/session-log.md"
[ -f "$log" ] && [ ! -L "$log" ] || refuse '.agent/session-log.md must be a regular initialized file' 'Restore it, or create the node with node.sh init, then run this call again'
pending="$state/checkpoint.pending"
last="$state/checkpoint.last"
# Named after the worktree: worktrees that share one node share its state, and
# each has its own HEAD.
mark_name="checkpoint.head.$(printf '%s' "$root" | git hash-object --stdin | cut -c1-12)"
mark="$state/$mark_name"
node_mark="$state/checkpoint.node"

hash_file() { git hash-object --no-filters -- "$1"; }
# A digest of the node files Git ignores. The fingerprint does not see them
# through a linked .agent, and the content digest leaves them out.
node_digest() {
  nd_home=$(da_node_dir "$root") || return 1
  nd_home=${nd_home%/.agent}
  nd_dir=$(mktemp -d "${TMPDIR:-/tmp}/checkpoint-node.XXXXXX") || return 1
  node_lines >"$nd_dir/lines" && LC_ALL=C sort "$nd_dir/lines" >"$nd_dir/sorted" && git hash-object --no-filters -- "$nd_dir/sorted"
  nd_rc=$?
  rm -rf -- "$nd_dir"
  return "$nd_rc"
}
node_lines() {
  git -C "$nd_home" ls-files --others --ignored --exclude-standard -z -- .agent >"$nd_dir/paths" || return 1
  : >"$nd_dir/plain" || return 1
  while IFS= read -r -d '' nd_path; do
    da__excluded_path "$nd_home" "$nd_path" && continue
    # Rebuilt from rules/learned/ by the cache refresh below.
    [ "$nd_path" != .agent/rules/learned.md ] || [ ! -d "$nd_home/.agent/rules/learned" ] || continue
    if [ -L "$nd_home/$nd_path" ]; then
      da__line "$nd_path" link "$(readlink "$nd_home/$nd_path")"
      printf '%s\n' "$REPLY" || return 1
    elif [ -f "$nd_home/$nd_path" ]; then
      case "$nd_path" in
      *$'\n'* | *$'\r'*)
        nd_object=$(hash_file "$nd_home/$nd_path") || return 1
        da__line "$nd_path" "$nd_object"
        printf '%s\n' "$REPLY" || return 1 ;;
      *) printf '%s/%s\n' "$nd_home" "$nd_path" >>"$nd_dir/plain" || return 1 ;;
      esac
    fi
  done <"$nd_dir/paths"
  git -C "$nd_home" hash-object --no-filters --stdin-paths <"$nd_dir/plain" >"$nd_dir/objects" 2>/dev/null || return 1
  paste "$nd_dir/plain" "$nd_dir/objects"
}
identify() { printf '%s\n' "$fingerprint" "$identity_base" "$node" | git hash-object --stdin; }
# The mark is the worktree's, and the node digest is the node's, so a worktree
# that shares the node is not asked to record what another one already did. The
# recovery record names the mark, because another worktree may finish it.
record_mark() {
  if [ -f "$pending/head" ]; then
    rm_name=$(sed -n 1p "$pending/head")
    case "$rm_name" in
    checkpoint.head.*[!0-9a-f]* | '') ;;
    checkpoint.head.*) replace_state "$pending/head" "$state/$rm_name" ;;
    esac
  fi
  [ ! -f "$pending/node" ] || replace_state "$pending/node" "$node_mark"
}
replace_state() {
  cp -- "$1" "$2.tmp.$$" && mv -f -- "$2.tmp.$$" "$2" || refuse 'the entry is logged but its commit could not be recorded' 'Check that .agent/.state is writable. Do not log this work again'
}
record_last() {
  printf '%s\n' "$1" >"$last.tmp.$$" && mv -f -- "$last.tmp.$$" "$last" || refuse 'the entry is logged but its identity could not be recorded' 'Check that .agent/.state is writable. Do not log this work again'
}
clear_pending() {
  rm -f -- "$pending/before" "$pending/after" "$pending/fingerprint" "$pending/head" "$pending/node" "$pending/log"
  rmdir "$pending" || refuse 'the entry is logged but .agent/.state/checkpoint.pending holds unexpected files' 'Inspect that folder and remove it. Do not log this work again'
}
publish_log() {
  publish=$(mktemp "$root/.agent/.session-log.checkpoint.XXXXXX") || refuse 'could not create the log replacement' 'Check that .agent is writable, then run this call again. A rerun finishes this entry once'
  cp -p -- "$log" "$publish" || refuse 'could not preserve the log metadata' 'Check that .agent is writable, then run this call again. A rerun finishes this entry once'
  cat "$pending/log" >"$publish" || refuse 'could not prepare the log replacement' 'Check that .agent is writable, then run this call again. A rerun finishes this entry once'
  [ "$(hash_file "$publish")" = "$pending_after" ] || refuse 'the checkpoint recovery log failed its digest check' 'Compare .agent/.state/checkpoint.pending/log with .agent/session-log.md and remove the pending folder. Run this call again only if the entry is not in the session log'
  [ "$(hash_file "$log")" = "$pending_before" ] || refuse 'the session log changed during checkpoint publication' 'Compare .agent/.state/checkpoint.pending/log with .agent/session-log.md and remove the pending folder. Run this call again only if the entry is not in the session log'
  mv -f -- "$publish" "$log" || refuse 'could not publish the session log' 'Check that .agent is writable, then run this call again. A rerun finishes this entry once'
  publish=""
}
if [ -e "$pending" ]; then
  [ -d "$pending" ] && [ ! -L "$pending" ] || refuse '.agent/.state/checkpoint.pending is not a plain folder' 'Remove it, then run this call again'
  for part in before after fingerprint log; do
    [ -f "$pending/$part" ] && [ ! -L "$pending/$part" ] || refuse 'the checkpoint recovery record is incomplete' 'Compare .agent/.state/checkpoint.pending/log with .agent/session-log.md and remove the pending folder. Run this call again only if the entry is not in the session log'
  done
  pending_before=$(cat "$pending/before")
  pending_after=$(cat "$pending/after")
  pending_fingerprint=$(cat "$pending/fingerprint")
  [ "$(hash_file "$pending/log")" = "$pending_after" ] || refuse 'the checkpoint recovery digest is invalid' 'Compare .agent/.state/checkpoint.pending/log with .agent/session-log.md and remove the pending folder. Run this call again only if the entry is not in the session log'
  actual=$(hash_file "$log") || refuse 'could not read the current log' 'Check that .agent/session-log.md is readable, then run this call again'
  if [ "$actual" = "$pending_before" ]; then
    publish_log
  elif [ "$actual" != "$pending_after" ]; then
    refuse 'the session log changed after an interrupted checkpoint' 'Compare .agent/.state/checkpoint.pending/log with .agent/session-log.md and remove the pending folder. Run this call again only if the entry is not in the session log'
  fi
  record_last "$pending_fingerprint"
  record_mark
  clear_pending
fi

identity_base=""
if [ "$is_git" -eq 1 ]; then
  identity_base=$(git -C "$root" merge-base "${base:-HEAD}" HEAD 2>/dev/null) || refuse 'the base has no commit shared with HEAD' 'Pass the commit before your work with --base, or make a first commit'
fi
content_out=$(mktemp "${TMPDIR:-/tmp}/checkpoint-content.XXXXXX") || refuse 'could not prepare the checkpoint' 'Check that the disk and the temporary folder are writable, then run this call again'
fingerprint=$(da_fingerprint "$root" "$content_out") || refuse 'could not fingerprint the current inputs' 'Fix what the lines above name, then run this call again'
# What the review below reads. The mark records these, so a file written while
# the checkpoint runs is still new to the next one.
start_content=$(cat "$content_out")
start_head=""
start_node=""
if [ "$is_git" -eq 1 ]; then
  start_head=$(git -C "$root" rev-parse HEAD) || refuse 'could not prepare the checkpoint' 'Check that the disk and the temporary folder are writable, then run this call again'
  start_node=$(node_digest) || refuse 'could not read the ignored node files' 'Make the files under .agent readable, then run this call again'
fi
node=$start_node
identity=$(identify) || refuse 'could not prepare the checkpoint' 'Check that the disk and the temporary folder are writable, then run this call again'
last_identity=$(cat "$last" 2>/dev/null)
# A --node-only entry reviewed no commit, so it answers only --node-only.
if [ "$last_identity" = "$identity" ] || { [ "$node_only" -eq 1 ] && [ "$last_identity" = "$identity node-only" ]; }; then
  echo 'checkpoint.sh: unchanged; this content is already recorded'
  exit 0
fi
recorded=0
if [ "$is_git" -eq 1 ]; then
  mark_head=$(sed -n 2p "$mark" 2>/dev/null)
  [ -z "$mark_head" ] || [ "$start_content" != "$(sed -n 3p "$mark")" ] || recorded=1
  if [ "$node_only" -eq 1 ] && [ "$recorded" -eq 0 ]; then
    product_changes=$(git -C "$root" status --porcelain --untracked-files=normal -- . ':(exclude).agent' 2>/dev/null) || refuse 'git could not list the product changes' 'Run git status, fix what it reports, then run this call again'
    [ -z "$product_changes" ] || refuse '--node-only cannot skip review of product changes' 'Drop --node-only, or commit the product changes first'
  fi
fi
if [ "$node_only" -eq 1 ] && [ "$recorded" -eq 1 ] && [ -f "$node_mark" ] && [ "$node" = "$(cat "$node_mark")" ]; then
  echo 'checkpoint.sh: unchanged; this content is already recorded'
  exit 0
fi
# With no --base, the last recorded checkpoint says where this work began.
if [ -z "$base" ] && [ "$is_git" -eq 1 ]; then
  base=HEAD
  if [ "$node_only" -eq 0 ]; then
    not_work=(':(exclude).agent/session-log.md' ':(exclude).agent/indexes')
    [ ! -L "$root/.agent" ] || not_work=(':(exclude).agent')
    changes=$(git -C "$root" status --porcelain --untracked-files=normal -- ':(top)' "${not_work[@]}" 2>/dev/null) || refuse 'git could not list the changes' 'Run git status, fix what it reports, then run this call again'
    if [ "$recorded" -eq 1 ]; then
      :
    elif [ -z "$mark_head" ] || ! git -C "$root" merge-base --is-ancestor "$mark_head" HEAD 2>/dev/null; then
      [ -n "$changes" ] || refuse 'the tree is clean and no earlier checkpoint marks where this work began' 'Run this call again with --base <the commit before your work>, or with --node-only if only ignored node files changed'
    elif [ "$mark_head" = "$start_head" ]; then
      [ -n "$changes" ] || recorded=1
    else
      base=$mark_head
      commits=$(git -C "$root" rev-list --count "$mark_head..HEAD")
      noun=commits
      [ "$commits" -ne 1 ] || noun=commit
      echo "checkpoint.sh: using --base ${mark_head:0:12}: $commits $noun since the last checkpoint"
    fi
    if [ "$recorded" -eq 1 ]; then
      [ ! -f "$node_mark" ] || [ "$node" = "$(cat "$node_mark")" ] \
        || refuse 'nothing to review in git, and node files changed since the last checkpoint' 'Run this call again with --node-only'
      echo 'checkpoint.sh: nothing to record since the last checkpoint'
      exit 0
    fi
  fi
fi

# With both flags, a current receipt answers only for the check it records,
# and a named check with no current receipt runs. Refusing the pair cost a
# session one call each time it added a failed check's receipt to its last call.
if [ -n "$checks" ] && [ -n "$receipts" ]; then
  case "$checks" in ,*|*,|*,,*) refuse '--checks holds an empty name' 'Pass check names separated by single commas' ;; esac
  case "$receipts" in ,*|*,|*,,*) refuse '--verification holds an empty receipt id' 'Pass receipt ids separated by single commas' ;; esac
  IFS=',' read -r -a given_checks <<<"$checks"
  IFS=',' read -r -a given_receipts <<<"$receipts"
  covered=","; receipts=""; checks=""; reused=""
  for receipt in "${given_receipts[@]}"; do
    if record=$(bash "$scripts/verify.sh" check "$receipt" --root "$root" 2>/dev/null); then
      IFS=$'\t' read -r _ _ _ covered_check _ <<<"$record"
      covered="$covered$covered_check,"
      receipts="${receipts:+$receipts,}$receipt"
    else
      echo 'checkpoint.sh: a receipt that is missing or stale was left out'
    fi
  done
  for check_name in "${given_checks[@]}"; do
    case "$covered" in
      *",$check_name,"*) reused="${reused:+$reused, }$check_name" ;;
      *) checks="${checks:+$checks,}$check_name" ;;
    esac
  done
  [ -z "$reused" ] || echo "checkpoint.sh: a current receipt answers for $reused, so it did not run again"
fi
if [ -z "$checks" ] && [ -z "$receipts" ]; then
  [ "$requested_verify" != pass ] || refuse '--verify pass requires --checks or --verification' 'Run this call again with --checks <name>'
  [ -n "$requested_verify" ] || refuse 'no verification flag was given' 'Pass --checks <name>, --verification <receipt id>, or, when nothing can be run, --verify n/a'
fi

# Review and status run before verification. A finding they block on costs
# seconds to find, while a check can take minutes and would run again after
# the fix. A check that changes the inputs they read records an inconclusive
# result, and receipts are checked again before logging.
if [ "$is_git" -eq 1 ] && [ "$node_only" -eq 0 ]; then
  review_args=(--root "$root")
  [ -z "$base" ] || review_args+=(--base "$base")
  bash "$scripts/review.sh" "${review_args[@]}" || refuse 'diff review blocked or could not run, so no log entry was written' 'Fix each blocking line above. If the diff is the wrong range, pass the commit before your work with --base. Then run this call again'
else
  echo 'REVIEW: DIFF_UNAVAILABLE node-only or non-Git work; no product diff inspected'
fi
status_out=$(mktemp "${TMPDIR:-/tmp}/checkpoint-status.XXXXXX") || refuse 'could not prepare the checkpoint' 'Check that the disk and the temporary folder are writable, then run this call again'
status_err=$(mktemp "${TMPDIR:-/tmp}/checkpoint-status.XXXXXX") || refuse 'could not prepare the checkpoint' 'Check that the disk and the temporary folder are writable, then run this call again'
bash "$scripts/status.sh" --format tsv "$root" >"$status_out" 2>"$status_err"
status_rc=$?
if [ "$status_rc" -ne 0 ] || [ -s "$status_err" ]; then
  head -c 1000 "$status_err" >&2
  refuse 'status check failed to run cleanly, so no log entry was written' 'Run bash .agent/scripts/status.sh, fix what it reports, then run this call again'
fi
blocked=0
structural=0
while IFS=$'\t' read -r severity code path message; do
  [ -n "$severity" ] || continue
  case "$severity" in block|advisory) ;; *) refuse 'status returned an invalid severity' 'Update this node with node.sh update from the dot-agent repository' ;; esac
  [ -n "$code" ] && [ -n "$path" ] && [ -n "$message" ] || refuse 'status returned an incomplete finding' 'Update this node with node.sh update from the dot-agent repository'
  printf '%s: %s %s %s\n' "$severity" "$code" "$path" "$message"
  if [ "$severity" = block ]; then structural=1; fi
  if [ "$severity" = block ] || [ "$policy" = strict ]; then blocked=1; fi
done <"$status_out"
# The closing line names the next step, so a session need not ask what a block
# means or relax the policy to get past it. The node's contract assigns this
# maintenance to the current session.
if [ "$blocked" -ne 0 ]; then
  if [ "$structural" -eq 0 ]; then
    refuse 'status findings block completion, so no log entry was written' 'Policy is strict, so the advisory lines above block too: do what each says now, without asking first, then run this call again'
  fi
  refuse 'status findings block completion, so no log entry was written' 'Do what each line above says, then run this call again'
fi

verify="$requested_verify"
if [ -n "$checks" ]; then
  case "$checks" in ,*|*,|*,,*) refuse '--checks holds an empty name' 'Pass check names separated by single commas' ;; esac
  IFS=',' read -r -a check_names <<<"$checks"
  # Every check's output lands in this one tool result, and verify.sh sizes
  # its limit for a whole result, so each check gets an equal share of it.
  for check_name in "${check_names[@]}"; do
    result=$(bash "$scripts/verify.sh" run "$check_name" --root "$root" --output-share "${#check_names[@]}")
    run_rc=$?
    IFS=$'\t' read -r tag receipt outcome recorded_check command_exit count extra <<<"$result"
    [ "$tag" = receipt ] && [ -n "$receipt" ] && [ -z "${extra:-}" ] || refuse "verification did not produce a receipt (exit $run_rc), so no log entry was written" 'Fix what the lines above report, or pass a check name that .agent/scripts/checks.sh defines, then run this call again'
    receipts="${receipts:+$receipts,}$receipt"
  done
fi
if [ -n "$receipts" ]; then
  verify=pass
  case "$receipts" in ,*|*,|*,,*) refuse '--verification holds an empty receipt id' 'Pass receipt ids separated by single commas' ;; esac
  IFS=',' read -r -a receipt_ids <<<"$receipts"
  for receipt in "${receipt_ids[@]}"; do
    result=$(bash "$scripts/verify.sh" check "$receipt" --root "$root") || refuse 'the verification receipt is missing, invalid, or stale' 'Run the check again with --checks <name>'
    IFS=$'\t' read -r tag returned_id outcome recorded_check command_exit count extra <<<"$result"
    [ "$tag" = receipt ] && [ "$returned_id" = "$receipt" ] && [ -z "${extra:-}" ] || refuse 'verify.sh returned an invalid result record' 'Run the check again with --checks <name>'
    case "$outcome" in pass) ;; fail|inconclusive) verify=fail ;; *) refuse 'verify.sh returned an unknown outcome' 'Run the check again with --checks <name>' ;; esac
    # An inconclusive run that exited 0 is no failed check. verify.sh says
    # which thing happened, because it owns the count and its configuration.
    if [ "$outcome" = inconclusive ] && [ "$command_exit" = 0 ]; then
      case "$(bash "$scripts/verify.sh" why "$receipt" --root "$root" 2>/dev/null)" in
        uncounted) uncounted="${uncounted:+$uncounted, }$recorded_check" ;;
        format) unread="${unread:+$unread, }$recorded_check" ;;
        empty) empty="${empty:+$empty, }$recorded_check" ;;
        *) moved="${moved:+$moved, }$recorded_check" ;;
      esac
    elif [ "$outcome" != pass ]; then
      failed_checks="${failed_checks:+$failed_checks, }$recorded_check"
    fi
    printf 'VERIFY: %s %s exit=%s tests=%s receipt=%s\n' "$recorded_check" "$outcome" "$command_exit" "$count" "$receipt"
  done
  if [ "$requested_verify" = pass ] && [ "$verify" != pass ]; then refuse 'the receipt does not support --verify pass' 'Fix the failure and run this call again with --checks <name>, or record the failure with --verify fail'; fi
  if [ "$verify" != pass ] && [ "$requested_verify" != fail ]; then
    if [ -n "$failed_checks" ]; then
      refuse "checks failed ($failed_checks)" "Fix and run this call again, or record the final failure by adding --verification $receipts --verify fail"
    elif [ -n "$uncounted" ]; then
      refuse "$uncounted exited 0 with no test count verify.sh reads, so nothing was logged" "Make the check driver run the runner with its TAP reporter or a summary that verify.sh --help lists. Leave the project's own test command as it is. Then run this call again"
    elif [ -n "$unread" ]; then
      refuse "$unread exited 0 and this node's TEST_COUNT_FORMAT read no test count, so nothing was logged" 'If verify.sh --help lists this runner, set TEST_COUNT_FORMAT=auto in .agent/scripts/verify.conf. Otherwise make the check driver run the runner with its TAP reporter. Then run this call again'
    elif [ -n "$empty" ]; then
      refuse "$empty exited 0 and ran 0 tests, so nothing was logged" 'Add or select a test for this change and run this call again. If nothing here can be tested, pass --verify n/a without --checks'
    fi
    refuse "project files changed while $moved ran, or its output was lost, so nothing was logged" 'Run this call again. If it repeats, make the check write only where Git ignores'
  fi
  [ "$requested_verify" != fail ] || verify=fail
fi

indexes=$(sed -n 's/^  indexes:[[:space:]]*\([a-z]*\).*/\1/p' "$root/.agent/purpose.md" | head -n 1)
if [ "$indexes" = generated ]; then
  echo '== cache refresh'
  if [ -f "$scripts/index.sh" ]; then
    bash "$scripts/index.sh" ensure --root "$root" >/dev/null || printf '%s\n' 'checkpoint.sh: cache refresh failed; read .agent/rules/ and .agent/docs/ directly' >&2
  else
    printf '%s\n' 'checkpoint.sh: index.sh is missing; read .agent/rules/ and .agent/docs/ directly' >&2
  fi
fi

entry=$(bash "$scripts/log.sh" --print-entry --tool "$tool" --area "$area" --verify "$verify" --summary "$summary" "$root") || exit 1
if [ -n "$receipts" ]; then
  for receipt in "${receipt_ids[@]}"; do
    bash "$scripts/verify.sh" check "$receipt" --root "$root" >/dev/null || refuse 'the inputs changed before logging' 'Run the check again with --checks <name>'
  done
fi
fingerprint=$(da_fingerprint "$root") || refuse 'could not fingerprint the completed change' 'Fix what the lines above name, then run this call again'
[ "$is_git" -eq 0 ] || node=$(node_digest) || refuse 'could not read the ignored node files' 'Make the files under .agent readable, then run this call again'
identity=$(identify) || refuse 'could not prepare the checkpoint' 'Check that the disk and the temporary folder are writable, then run this call again'
[ "$node_only" -eq 0 ] || identity="$identity node-only"
prepare=$(mktemp -d "$state/checkpoint.prepare.XXXXXX") || refuse 'could not create the checkpoint recovery record' 'Check that .agent/.state is writable, then run this call again'
pending_before=$(hash_file "$log") || refuse 'could not prepare the checkpoint' 'Check that the disk and the temporary folder are writable, then run this call again'
{ cat "$log" && printf '%s\n' "$entry"; } >"$prepare/log" || refuse 'could not prepare the checkpoint log' 'Check that .agent/.state is writable, then run this call again'
pending_after=$(hash_file "$prepare/log") || refuse 'could not prepare the checkpoint' 'Check that the disk and the temporary folder are writable, then run this call again'
printf '%s\n' "$pending_before" >"$prepare/before" || refuse 'could not prepare the checkpoint' 'Check that the disk and the temporary folder are writable, then run this call again'
printf '%s\n' "$pending_after" >"$prepare/after" || refuse 'could not prepare the checkpoint' 'Check that the disk and the temporary folder are writable, then run this call again'
printf '%s\n' "$identity" >"$prepare/fingerprint" || refuse 'could not prepare the checkpoint' 'Check that the disk and the temporary folder are writable, then run this call again'
if [ "$is_git" -eq 1 ]; then
  # --node-only reviews no commit, so it leaves the mark where it was.
  if [ "$node_only" -eq 0 ]; then
    printf '%s\n' "$mark_name" "$start_head" "$start_content" >"$prepare/head" || refuse 'could not prepare the checkpoint' 'Check that the disk and the temporary folder are writable, then run this call again'
  fi
  printf '%s\n' "$start_node" >"$prepare/node" || refuse 'could not prepare the checkpoint' 'Check that the disk and the temporary folder are writable, then run this call again'
fi
mv -- "$prepare" "$pending" || refuse 'could not publish the checkpoint recovery record' 'Check that .agent/.state is writable, then run this call again'
prepare=""
publish_log
record_last "$identity"
record_mark
clear_pending
printf 'checkpoint.sh: recorded verify=%s\n' "$verify"
