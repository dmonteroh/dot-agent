#!/usr/bin/env bash
set -u
unset CDPATH

selfdir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
[ -f "$selfdir/runtime.sh" ] || { echo 'checkpoint.sh: runtime.sh is missing; update this node' >&2; exit 1; }
# shellcheck source=runtime.sh
. "$selfdir/runtime.sh"

usage() {
  cat <<'EOF'
Usage: checkpoint.sh --tool NAME --area NAME --summary TEXT
       [--checks CHECK[,CHECK...]] [--verification ID[,ID...]]
       [--verify fail|n/a] [--base REF] [--node-only] [--policy strict|completion] [ROOT]

--checks runs configured verification before recording the result.
--verification reuses valid receipts for unchanged inputs.
--verify pass requires receipts or --checks. fail and n/a remain explicit reports.
strict blocks every status finding. completion defers advisory maintenance.
A successful retry over unchanged content writes no second log entry.
--node-only records explicitly changed node content hidden by Git ignore rules.
EOF
}

root=.; base=""; policy=""; tool=""; area=""; summary=""
checks=""; receipts=""; requested_verify=""; node_only=0
lock=""; status_out=""; status_err=""; publish=""; prepare=""
cleanup() {
  [ -z "$publish" ] || rm -f -- "$publish"
  [ -z "$status_out" ] || rm -f -- "$status_out"
  [ -z "$status_err" ] || rm -f -- "$status_err"
  if [ -n "$prepare" ]; then
    rm -f -- "$prepare/before" "$prepare/after" "$prepare/fingerprint" "$prepare/log"
    rmdir "$prepare" 2>/dev/null || true
  fi
  [ -z "$lock" ] || da_unlock "$lock"
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
die() { printf 'checkpoint.sh: %s\n' "$*" >&2; exit 1; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tool|--area|--summary|--checks|--verification|--verify|--base|--policy)
      [ "$#" -ge 2 ] || die "$1 needs a value"
      case "$1" in
        --tool) tool=$2 ;; --area) area=$2 ;; --summary) summary=$2 ;;
        --checks) checks=$2 ;; --verification) receipts=$2 ;;
        --verify) requested_verify=$2 ;; --base) base=$2 ;; --policy) policy=$2 ;;
      esac
      shift 2 ;;
    --help|-h) usage; exit 0 ;;
    --version) echo 'dot-agent checkpoint 6.3'; exit 0 ;;
    --node-only) node_only=1; shift ;;
    --*) die "unknown flag: $1" ;;
    *) root=$1; shift ;;
  esac
done
[ -n "$tool" ] && [ -n "$area" ] && [ -n "$summary" ] || { usage >&2; die '--tool, --area, and --summary are required'; }
[ -z "$checks" ] || [ -z "$receipts" ] || die 'choose --checks or --verification'
case "$requested_verify" in ''|pass|fail|n/a) ;; *) die '--verify must be pass, fail, or n/a' ;; esac
root=$(da_root "$root") || exit 1
scripts="$root/.agent/scripts"
for helper in review.sh status.sh log.sh verify.sh; do
  [ -f "$scripts/$helper" ] || die "$scripts/$helper is missing; update this node"
done
if [ -z "$policy" ]; then
  policy=$(sed -n 's/^POLICY=//p' "$scripts/checkpoint.conf" 2>/dev/null | head -n 1 | sed 's/[[:space:]]*$//')
fi
policy=${policy:-strict}
case "$policy" in strict|completion) ;; *) die 'policy must be strict or completion' ;; esac
bash "$scripts/log.sh" --print-entry --tool "$tool" --area "$area" --verify n/a --summary "$summary" "$root" >/dev/null || exit 1
is_git=0
git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 && is_git=1
if [ "$is_git" -eq 0 ]; then
  [ -z "$base" ] || die '--base requires a Git worktree'
  non_git_inputs=$(sed -n 's/^NON_GIT_INPUT_ROOTS=//p' "$scripts/verify.conf" 2>/dev/null | head -n 1)
  export DA_NON_GIT_INPUT_ROOTS=".agent${non_git_inputs:+ $non_git_inputs}"
fi

state=$(da_state_dir "$root") || exit 1
lock="$state/checkpoint.lock"
da_lock "$lock" || { lock=""; die 'another checkpoint or log writer owns this node'; }
log="$root/.agent/session-log.md"
[ -f "$log" ] && [ ! -L "$log" ] || die 'session-log.md must be a regular initialized file'
pending="$state/checkpoint.pending"
last="$state/checkpoint.last"

hash_file() { git hash-object --no-filters -- "$1"; }
record_last() {
  printf '%s\n' "$1" >"$last.tmp.$$" && mv -f -- "$last.tmp.$$" "$last" || die 'could not record checkpoint identity'
}
clear_pending() {
  rm -f -- "$pending/before" "$pending/after" "$pending/fingerprint" "$pending/log"
  rmdir "$pending" || die 'checkpoint recovery contains unexpected files'
}
publish_log() {
  publish=$(mktemp "$root/.agent/.session-log.checkpoint.XXXXXX") || die 'could not create log replacement'
  cp -p -- "$log" "$publish" || die 'could not preserve log metadata'
  cat "$pending/log" >"$publish" || die 'could not prepare log replacement'
  [ "$(hash_file "$publish")" = "$pending_after" ] || die 'checkpoint recovery log failed its digest check'
  [ "$(hash_file "$log")" = "$pending_before" ] || die 'session log changed during checkpoint publication'
  mv -f -- "$publish" "$log" || die 'could not publish session log'
  publish=""
}
if [ -e "$pending" ]; then
  [ -d "$pending" ] && [ ! -L "$pending" ] || die 'invalid checkpoint recovery directory'
  for part in before after fingerprint log; do
    [ -f "$pending/$part" ] && [ ! -L "$pending/$part" ] || die 'incomplete checkpoint recovery record'
  done
  pending_before=$(cat "$pending/before")
  pending_after=$(cat "$pending/after")
  pending_fingerprint=$(cat "$pending/fingerprint")
  [ "$(hash_file "$pending/log")" = "$pending_after" ] || die 'invalid checkpoint recovery digest'
  actual=$(hash_file "$log") || die 'could not read the current log'
  if [ "$actual" = "$pending_before" ]; then
    publish_log
  elif [ "$actual" != "$pending_after" ]; then
    die 'session log changed after an interrupted checkpoint; inspect checkpoint.pending before retrying'
  fi
  record_last "$pending_fingerprint"
  clear_pending
fi

identity_base=""
if [ "$is_git" -eq 1 ]; then
  identity_base=$(git -C "$root" merge-base "${base:-HEAD}" HEAD 2>/dev/null) || die 'base has no commit shared with HEAD'
fi
fingerprint=$(da_fingerprint "$root") || die 'could not fingerprint current inputs'
identity=$(printf '%s\n%s\n' "$fingerprint" "$identity_base" | git hash-object --stdin) || exit 1
if [ -f "$last" ] && [ "$(cat "$last")" = "$identity" ]; then
  echo 'checkpoint.sh: unchanged; this content is already recorded'
  exit 0
fi
if [ "$node_only" -eq 1 ] && [ "$is_git" -eq 1 ]; then
  product_changes=$(git -C "$root" status --porcelain -- . ':(exclude).agent' 2>/dev/null) || die 'could not inspect product changes'
  [ -z "$product_changes" ] || die '--node-only cannot skip review of product changes'
fi
if [ -z "$base" ] && [ "$is_git" -eq 1 ]; then
  if [ -z "$(git -C "$root" status --porcelain 2>/dev/null)" ]; then
    [ "$node_only" -eq 1 ] || die 'nothing changed; use --node-only for an explicit ignored-node write or --base for committed work'
  fi
  base=HEAD
fi

if [ -z "$checks" ] && [ -z "$receipts" ]; then
  [ "$requested_verify" != pass ] || die '--verify pass requires --checks or --verification; run verify.sh for execution evidence'
  [ -n "$requested_verify" ] || die 'supply --checks, --verification, or an explicit --verify fail|n/a'
fi

# Review and status run before verification. A finding they block on costs
# seconds to find, while a check can take minutes and would run again after
# the fix. A check that changes the inputs they read records an inconclusive
# result, and receipts are checked again before logging.
if [ "$is_git" -eq 1 ] && [ "$node_only" -eq 0 ]; then
  review_args=(--root "$root")
  [ -z "$base" ] || review_args+=(--base "$base")
  bash "$scripts/review.sh" "${review_args[@]}" || die 'diff review blocked or could not run; no log entry written'
else
  echo 'REVIEW: DIFF_UNAVAILABLE node-only or non-Git work; no product diff inspected'
fi
status_out=$(mktemp "${TMPDIR:-/tmp}/checkpoint-status.XXXXXX") || exit 1
status_err=$(mktemp "${TMPDIR:-/tmp}/checkpoint-status.XXXXXX") || exit 1
bash "$scripts/status.sh" --format tsv "$root" >"$status_out" 2>"$status_err"
status_rc=$?
if [ "$status_rc" -ne 0 ] || [ -s "$status_err" ]; then
  head -c 1000 "$status_err" >&2
  die 'status check failed to run cleanly; no log entry written'
fi
blocked=0
while IFS=$'\t' read -r severity code path message; do
  [ -n "$severity" ] || continue
  case "$severity" in block|advisory) ;; *) die 'status returned an invalid severity' ;; esac
  [ -n "$code" ] && [ -n "$path" ] && [ -n "$message" ] || die 'status returned an incomplete finding'
  printf '%s: %s %s %s\n' "$severity" "$code" "$path" "$message"
  if [ "$severity" = block ] || [ "$policy" = strict ]; then blocked=1; fi
done <"$status_out"
[ "$blocked" -eq 0 ] || die 'status findings block completion; no log entry written'

verify="$requested_verify"
if [ -n "$checks" ]; then
  case "$checks" in ,*|*,|*,,*) die 'empty check name' ;; esac
  IFS=',' read -r -a check_names <<<"$checks"
  # Every check's output lands in this one tool result, and verify.sh sizes
  # its limit for a whole result, so each check gets an equal share of it.
  for check_name in "${check_names[@]}"; do
    result=$(bash "$scripts/verify.sh" run "$check_name" --root "$root" --output-share "${#check_names[@]}")
    run_rc=$?
    IFS=$'\t' read -r tag receipt outcome recorded_check command_exit count extra <<<"$result"
    [ "$tag" = receipt ] && [ -n "$receipt" ] && [ -z "${extra:-}" ] || die "verification did not produce a receipt (exit $run_rc)"
    receipts="${receipts:+$receipts,}$receipt"
  done
fi
if [ -n "$receipts" ]; then
  verify=pass
  case "$receipts" in ,*|*,|*,,*) die 'empty receipt identity' ;; esac
  IFS=',' read -r -a receipt_ids <<<"$receipts"
  for receipt in "${receipt_ids[@]}"; do
    result=$(bash "$scripts/verify.sh" check "$receipt" --root "$root") || die 'verification receipt is missing, invalid, or stale'
    IFS=$'\t' read -r tag returned_id outcome recorded_check command_exit count extra <<<"$result"
    [ "$tag" = receipt ] && [ "$returned_id" = "$receipt" ] && [ -z "${extra:-}" ] || die 'invalid verification result record'
    case "$outcome" in pass) ;; fail|inconclusive) verify=fail ;; *) die 'unknown verification outcome' ;; esac
    printf 'VERIFY: %s %s exit=%s tests=%s receipt=%s\n' "$recorded_check" "$outcome" "$command_exit" "$count" "$receipt"
  done
  if [ "$requested_verify" = pass ] && [ "$verify" != pass ]; then die 'the receipt does not support --verify pass'; fi
  if [ "$verify" != pass ] && [ "$requested_verify" != fail ]; then
    die "checks failed or were inconclusive; fix and retry, or record the final failure with --verification $receipts --verify fail"
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
    bash "$scripts/verify.sh" check "$receipt" --root "$root" >/dev/null || die 'inputs changed before logging; run verification again'
  done
fi
fingerprint=$(da_fingerprint "$root") || die 'could not fingerprint the completed change'
identity=$(printf '%s\n%s\n' "$fingerprint" "$identity_base" | git hash-object --stdin) || exit 1
prepare=$(mktemp -d "$state/checkpoint.prepare.XXXXXX") || die 'could not create checkpoint recovery record'
pending_before=$(hash_file "$log") || exit 1
{ cat "$log" && printf '%s\n' "$entry"; } >"$prepare/log" || die 'could not prepare checkpoint log'
pending_after=$(hash_file "$prepare/log") || exit 1
printf '%s\n' "$pending_before" >"$prepare/before" || exit 1
printf '%s\n' "$pending_after" >"$prepare/after" || exit 1
printf '%s\n' "$identity" >"$prepare/fingerprint" || exit 1
mv -- "$prepare" "$pending" || die 'could not publish checkpoint recovery record'
prepare=""
publish_log
record_last "$identity"
clear_pending
printf 'checkpoint.sh: recorded verify=%s\n' "$verify"
