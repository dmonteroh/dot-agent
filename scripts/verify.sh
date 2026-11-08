#!/usr/bin/env bash
set -u
export LC_ALL=C
unset CDPATH

schema_version=2
self_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=runtime.sh
. "$self_dir/runtime.sh"

usage() {
  cat <<'EOF'
Usage:
  verify.sh run CHECK [--root ROOT] [--timeout SECONDS] [--output-share N]
  verify.sh check RECEIPT [--root ROOT]
  verify.sh --help
  verify.sh --version
EOF
}

die() { echo "verify.sh: $*" >&2; exit 2; }
safe_value() { case "$1" in *$'\n'* | *$'\r'* | *$'\t'*) return 1 ;; esac; return 0; }

load_config() {
  cfg=$1
  CHECK_DRIVER=.agent/scripts/checks.sh
  POSITIVE_TEST_CHECKS='test'
  TEST_COUNT_FORMAT=tap
  TIMEOUT_SECONDS=300
  NON_GIT_INPUT_ROOTS=
  # The harness tool-result cap PAYLOAD_MAX_BYTES defaults to (30000), less a
  # chosen 1000 bytes for the receipt record printed on stdout.
  OUTPUT_MAX_BYTES=29000
  OUTPUT_FAILURE_PATTERN='not ok|FAIL|Error|ERROR|error:|Exception|Traceback|panic:|[Aa]ssert'
  [ -f "$cfg" ] || return 0
  while IFS= read -r cfg_line || [ -n "$cfg_line" ]; do
    case "$cfg_line" in '' | \#*) continue ;; esac
    case "$cfg_line" in
      CHECK_DRIVER=*) CHECK_DRIVER=${cfg_line#*=} ;;
      POSITIVE_TEST_CHECKS=*) POSITIVE_TEST_CHECKS=${cfg_line#*=} ;;
      TEST_COUNT_FORMAT=*) TEST_COUNT_FORMAT=${cfg_line#*=} ;;
      TIMEOUT_SECONDS=*) TIMEOUT_SECONDS=${cfg_line#*=} ;;
      NON_GIT_INPUT_ROOTS=*) NON_GIT_INPUT_ROOTS=${cfg_line#*=} ;;
      OUTPUT_MAX_BYTES=*) OUTPUT_MAX_BYTES=${cfg_line#*=} ;;
      OUTPUT_FAILURE_PATTERN=*) OUTPUT_FAILURE_PATTERN=${cfg_line#*=} ;;
      *) die "invalid configuration line in $cfg" ;;
    esac
  done <"$cfg"
  safe_value "$CHECK_DRIVER" && safe_value "$POSITIVE_TEST_CHECKS" && safe_value "$NON_GIT_INPUT_ROOTS" || die "control character in configuration"
  case "$CHECK_DRIVER" in '' | /* | *'..'* ) die "CHECK_DRIVER must be a project-relative path without .." ;; esac
  case "$TEST_COUNT_FORMAT" in tap | none) ;; *) die "unsupported TEST_COUNT_FORMAT: $TEST_COUNT_FORMAT" ;; esac
  case "$TIMEOUT_SECONDS" in '' | *[!0-9]*) die "TIMEOUT_SECONDS must be a positive integer" ;; esac
  [ "$TIMEOUT_SECONDS" -gt 0 ] || die "TIMEOUT_SECONDS must be a positive integer"
  case "$OUTPUT_MAX_BYTES" in '' | *[!0-9]*) die "OUTPUT_MAX_BYTES must be a positive integer" ;; esac
  [ "$OUTPUT_MAX_BYTES" -gt 0 ] || die "OUTPUT_MAX_BYTES must be a positive integer"
  safe_value "$OUTPUT_FAILURE_PATTERN" && [ -n "$OUTPUT_FAILURE_PATTERN" ] || die "OUTPUT_FAILURE_PATTERN must be one non-empty line"
}

# Prints the driver's output on stderr within OUTPUT_MAX_BYTES. Output that
# fits prints whole. Longer output prints the lines matching
# OUTPUT_FAILURE_PATTERN, each with the lines after it, then as many of the
# last lines as fit, every line numbered against the full output, which is
# kept beside the receipts. A harness cuts an oversized tool result wherever
# its limit falls, which can drop the one failing assertion; choosing what
# to drop here keeps it. If the selection fails, the plain tail prints.
# With TAP output, every failing result line is chosen before any context
# line, so one failure's context never crowds out another failure's name.
# A "not ok" marked "# TODO" is an expected failure and is not chosen.
emit_output() {
  eo_file=$1 eo_saved=$2
  eo_size=$(wc -c <"$eo_file" | tr -d '[:space:]')
  if [ "$eo_size" -le "$OUTPUT_MAX_BYTES" ]; then
    cat "$eo_file" >&2
    return 0
  fi
  if [ -n "$eo_saved" ]; then
    eo_where="the full output is kept at $eo_saved"
  else
    eo_where="the full output could not be kept"
  fi
  eo_pick=$(mktemp "${TMPDIR:-/tmp}/verify-pick.XXXXXX") || eo_pick=
  # Five lines after a match: an assertion message and the first frames of
  # its stack (chosen default).
  eo_tap=0
  [ "$TEST_COUNT_FORMAT" != tap ] || eo_tap=1
  if [ -n "$eo_pick" ] && awk -v max="$OUTPUT_MAX_BYTES" -v pat="$OUTPUT_FAILURE_PATTERN" \
      -v size="$eo_size" -v where="$eo_where" -v ctx=5 -v tap="$eo_tap" '
    { line[NR] = $0 }
    END {
      if (tap) first_part = "Failing TAP results, then lines matching the failure pattern, come first"
      else first_part = "Lines matching the failure pattern come first"
      header = "verify.sh: check output is " size " bytes, over the " max "-byte limit. " first_part ", then the last lines; numbers count lines of the full output, and " where "."
      budget = max - length(header) - 1 - length("--- failure lines ---") - 1 - length("--- last lines ---") - 1
      for (i = 1; i <= NR; i++) {
        tapfail = tap && line[i] ~ /^[[:space:]]*not ok([[:space:]]|$)/
        if (tapfail && line[i] ~ /#[[:space:]]*[Tt][Oo][Dd][Oo]/) continue
        if (tapfail) failed[i] = 1
        if (tapfail || line[i] ~ pat)
          for (j = i; j <= i + ctx && j <= NR; j++) keep[j] = 1
      }
      half = int(budget / 2); used = 0
      for (i = 1; i <= NR; i++) {
        if (!failed[i]) continue
        cost = length(i "| " line[i]) + 1
        if (used + cost > half) break
        sel[i] = 1; used += cost
      }
      for (i = 1; i <= NR; i++) {
        if (!keep[i] || sel[i]) continue
        cost = length(i "| " line[i]) + 1
        if (used + cost > half) break
        sel[i] = 1; used += cost
      }
      first = NR + 1
      for (i = NR; i >= 1; i--) {
        if (sel[i]) continue
        cost = length(i "| " line[i]) + 1
        if (used + cost > budget) break
        used += cost; first = i
      }
      print header
      print "--- failure lines ---"
      for (i = 1; i <= NR; i++) if (sel[i]) print i "| " line[i]
      print "--- last lines ---"
      for (i = first; i <= NR; i++) if (!sel[i]) print i "| " line[i]
    }' "$eo_file" >"$eo_pick" 2>/dev/null; then
    cat "$eo_pick" >&2
  else
    echo "verify.sh: check output is $eo_size bytes, over the $OUTPUT_MAX_BYTES-byte limit, and failure-line selection failed; the last bytes follow, and $eo_where." >&2
    tail -c "$OUTPUT_MAX_BYTES" "$eo_file" >&2
  fi
  [ -z "$eo_pick" ] || rm -f "$eo_pick"
  return 0
}

is_positive_check() {
  oldifs=$IFS; IFS=', '
  for pc in $POSITIVE_TEST_CHECKS; do [ "$pc" = "$1" ] && { IFS=$oldifs; return 0; }; done
  IFS=$oldifs
  return 1
}

tap_count() {
  awk '
    BEGIN { results=0 }
    /^[^[:space:]]/ && /^1\.\./ {
      if ($0 !~ /^1\.\.[0-9]+([[:space:]]+#.*)?[[:space:]]*$/) bad=1
      else {
        plans++
        line=$0; sub(/^1\.\./, "", line); sub(/[[:space:]#].*$/, "", line); n=line
      }
    }
    /^[^[:space:]]/ && /^(ok|not ok)([[:space:]]|$)/ {
      if ($0 !~ /^(ok|not ok)[[:space:]]+[0-9]+([[:space:]]|$)/) bad=1
      else {
        result=$0
        sub(/^(ok|not ok)[[:space:]]+/, "", result)
        sub(/[^0-9].*$/, "", result)
        results++
        if (result != results) bad=1
      }
    }
    END {
      if (!bad && plans == 1 && n ~ /^[0-9]+$/ && results == n) print n
      else print "unknown"
    }
  ' "$1"
}

print_record() { printf 'receipt\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5"; }

receipt_digest() {
  printf 'version=%s\ncheck=%s\nstatus=%s\nexit=%s\ncount=%s\nfingerprint=%s\nworktree=%s\ninvocation=%s\nexecuted_at=%s\n' \
    "$schema_version" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" | git hash-object --stdin
}

hex_value() { printf '%s' "$1" | od -An -tx1 | tr -d ' \n'; }

cancel_watchdog() {
  case "${watchdog:-}" in
    '' | *[!0-9]*) ;;
    *)
      kill -TERM -- "-$watchdog" 2>/dev/null || kill -TERM "$watchdog" 2>/dev/null || :
      wait "$watchdog" 2>/dev/null || :
      watchdog=
      ;;
  esac
}

cleanup_run() {
  # A run that exits before printing its output (a failed fingerprint, no
  # receipt) still shows the session what the check said.
  if [ -n "${out_tmp:-}" ] && [ "${output_emitted:-0}" -eq 0 ] && [ -s "$out_tmp" ]; then
    emit_output "$out_tmp" "" || :
  fi
  [ -z "${out_tmp:-}" ] || rm -f "$out_tmp"
  [ -z "${watchdog_marker:-}" ] || rm -f "$watchdog_marker"
  cancel_watchdog
  if [ "${lock_owned:-0}" -eq 1 ]; then
    da_unlock "$lock" >/dev/null 2>&1 || :
    lock_owned=0
  fi
}

interrupt_run() {
  ir_code=$1
  case "${child:-}" in
    '' | *[!0-9]*) ;;
    *)
      if kill -0 "$child" 2>/dev/null; then
        kill -TERM -- "-$child" 2>/dev/null || kill -TERM "$child" 2>/dev/null || :
        kill -KILL -- "-$child" 2>/dev/null || kill -KILL "$child" 2>/dev/null || :
        wait "$child" 2>/dev/null || :
      fi ;;
  esac
  cleanup_run
  exit "$ir_code"
}

case "${1:-}" in
  --help | -h) usage; exit 0 ;;
  --version) printf 'dot-agent v6.3; verify.sh receipt schema %s\n' "$schema_version"; exit 0 ;;
  run | check) op=$1; shift ;;
  *) usage >&2; exit 2 ;;
esac

root=.
timeout=
output_share=1
if [ "$op" = run ]; then
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  check=$1; shift
  case "$check" in '' | *[!A-Za-z0-9_.-]*) die "CHECK must contain only letters, digits, dot, underscore, or hyphen" ;; esac
else
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  receipt_arg=$1; shift
fi
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) [ "$#" -ge 2 ] || die "--root needs a value"; root=$2; shift 2 ;;
    --timeout)
      [ "$op" = run ] || die "--timeout is valid only with run"
      [ "$#" -ge 2 ] || die "--timeout needs a value"; timeout=$2; shift 2 ;;
    --output-share)
      [ "$op" = run ] || die "--output-share is valid only with run"
      [ "$#" -ge 2 ] || die "--output-share needs a value"; output_share=$2; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
root=$(da_root "$root") || exit 2
safe_value "$root" || die "worktree path contains a control character"
cfg="$root/.agent/scripts/verify.conf"
[ -f "$cfg" ] || cfg="$self_dir/verify.conf"
load_config "$cfg"
[ -n "$timeout" ] || timeout=$TIMEOUT_SECONDS
case "$timeout" in '' | *[!0-9]*) die "timeout must be a positive integer" ;; esac
[ "$timeout" -gt 0 ] || die "timeout must be a positive integer"
case "$output_share" in '' | *[!0-9]*) die "output share must be a positive integer" ;; esac
[ "$output_share" -gt 0 ] || die "output share must be a positive integer"
# A caller that prints several runs into one tool result (checkpoint.sh
# --checks) passes their count, so the runs together stay within one limit.
# The limit never drops below 1 byte. A share smaller than the trimming
# header prints the header and section markers alone.
if [ "$output_share" -gt 1 ]; then
  OUTPUT_MAX_BYTES=$((10#$OUTPUT_MAX_BYTES / 10#$output_share))
  [ "$OUTPUT_MAX_BYTES" -gt 0 ] || OUTPUT_MAX_BYTES=1
fi
if [ -n "$NON_GIT_INPUT_ROOTS" ]; then export DA_NON_GIT_INPUT_ROOTS=$NON_GIT_INPUT_ROOTS; else unset DA_NON_GIT_INPUT_ROOTS; fi
export DA_VERIFY_CONFIG=.agent/scripts/verify.conf
export DA_CHECK_DRIVER=$CHECK_DRIVER
state=$(da_state_dir "$root") || exit 2
receipts="$state/receipts"
if [ -L "$receipts" ]; then die "refusing symlink receipt directory: $receipts"; fi
(umask 077 && mkdir -p "$receipts") || die "cannot create receipt directory"
[ -d "$receipts" ] && [ ! -L "$receipts" ] || die "receipt path is not a physical directory: $receipts"

if [ "$op" = check ]; then
  case "$receipt_arg" in '' | *[!A-Za-z0-9_.-]*) die "RECEIPT must be an opaque id" ;; esac
  receipt="$receipts/$receipt_arg.receipt"
  [ -f "$receipt" ] && [ ! -L "$receipt" ] || die "receipt is missing or not a regular file: $receipt_arg"
  lines=$(wc -l <"$receipt" | tr -d '[:space:]')
  [ "$lines" = 10 ] || die "invalid receipt shape"
  IFS= read -r r1 <"$receipt"
  r2=$(sed -n '2p' "$receipt"); r3=$(sed -n '3p' "$receipt"); r4=$(sed -n '4p' "$receipt")
  r5=$(sed -n '5p' "$receipt"); r6=$(sed -n '6p' "$receipt"); r7=$(sed -n '7p' "$receipt")
  r8=$(sed -n '8p' "$receipt"); r9=$(sed -n '9p' "$receipt"); r10=$(sed -n '10p' "$receipt")
  [ "$r1" = "version=$schema_version" ] || die "invalid receipt version"
  id=${r2#id=}; rcheck=${r3#check=}; status=${r4#status=}; exit_code=${r5#exit=}; count=${r6#count=}; recorded=${r7#fingerprint=}
  recorded_root=${r8#worktree=}; recorded_invocation=${r9#invocation=}; executed_at=${r10#executed_at=}
  [ "$r2" = "id=$id" ] && [ "$r3" = "check=$rcheck" ] && [ "$r4" = "status=$status" ] && [ "$r5" = "exit=$exit_code" ] && [ "$r6" = "count=$count" ] && [ "$r7" = "fingerprint=$recorded" ] && [ "$r8" = "worktree=$recorded_root" ] && [ "$r9" = "invocation=$recorded_invocation" ] && [ "$r10" = "executed_at=$executed_at" ] || die "invalid receipt fields"
  case "$id" in '' | *[!A-Za-z0-9_.-]*) die "invalid receipt id" ;; esac
  case "$rcheck" in '' | *[!A-Za-z0-9_.-]*) die "invalid receipt check" ;; esac
  case "$status" in pass | fail | inconclusive) ;; *) die "invalid receipt status" ;; esac
  case "$exit_code" in '' | *[!0-9]*) die "invalid receipt exit code" ;; esac
  case "$count" in unknown) ;; '' | *[!0-9]*) die "invalid receipt count" ;; esac
  case "$recorded" in *[!0-9a-f]* | '') die "invalid receipt fingerprint" ;; esac
  [ "$recorded_root" = "$root" ] || die "receipt belongs to a different worktree"
  invocation="bash:$(hex_value "$CHECK_DRIVER"):$(hex_value "$rcheck")"
  [ "$recorded_invocation" = "$invocation" ] || die "receipt driver invocation does not match configuration"
  printf '%s\n' "$executed_at" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' || die "invalid receipt execution timestamp"
  [ "${receipt##*/}" = "$id.receipt" ] || die "receipt name does not match its id"
  expected_receipt_digest=$(receipt_digest "$rcheck" "$status" "$exit_code" "$count" "$recorded" "$recorded_root" "$recorded_invocation" "$executed_at") || die "could not validate receipt digest"
  [ "${id##*-}" = "$expected_receipt_digest" ] || die "receipt content digest does not match its id"
  current=$(da_fingerprint "$root") || exit 2
  [ "$current" = "$recorded" ] || die "receipt is stale: project inputs changed"
  print_record "$id" "$status" "$rcheck" "$exit_code" "$count"
  exit 0
fi

if ! git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 && [ -z "$NON_GIT_INPUT_ROOTS" ]; then
  die "non-Git verification requires NON_GIT_INPUT_ROOTS in verify.conf"
fi
driver="$root/$CHECK_DRIVER"
[ -f "$driver" ] && [ ! -L "$driver" ] || die "check driver is missing or unsafe: $CHECK_DRIVER"
lock="$state/verify.lock"; lock_owned=0; out_tmp=; child=; watchdog=; watchdog_marker=; output_emitted=0
da_lock "$lock" || exit 2
lock_owned=1
trap cleanup_run EXIT
trap 'interrupt_run 129' HUP
trap 'interrupt_run 130' INT
trap 'interrupt_run 143' TERM
before=$(da_fingerprint "$root") || exit 2
out_tmp=$(mktemp "${TMPDIR:-/tmp}/verify-output.XXXXXX") || die "cannot create output file"
watchdog_marker=$(mktemp "${TMPDIR:-/tmp}/verify-watchdog.XXXXXX") || die "cannot create watchdog marker"
rm -f "$watchdog_marker"

# Job control gives the driver an invocation-owned process group on Bash 3.2.
set -m
(cd "$root" && exec bash "$driver" "$check") >"$out_tmp" 2>&1 &
child=$!
# With monitor mode, Bash assigns an asynchronous job a new process group whose
# id is the job leader's pid.  This avoids depending on ps permissions.
pgid=$child
(
    trap - EXIT HUP INT TERM
    set +m
    exec </dev/null >/dev/null 2>&1
    sleep "$timeout" || exit 0
    (umask 077; printf 'timeout\n' >"$watchdog_marker") || exit 0
    kill -TERM -- "-$pgid" 2>/dev/null || kill -TERM "$child" 2>/dev/null || :
    sleep 2
    kill -KILL -- "-$pgid" 2>/dev/null || kill -KILL "$child" 2>/dev/null || :
) </dev/null >/dev/null 2>&1 &
watchdog=$!
set +m
wait "$child" 2>/dev/null
driver_rc=$?
if [ -f "$watchdog_marker" ]; then
  wait "$watchdog" 2>/dev/null || :
else
  cancel_watchdog
fi
watchdog=
if [ -f "$watchdog_marker" ]; then timed_out=1; driver_rc=124; else timed_out=0; fi
after=$(da_fingerprint "$root") || exit 2
count=unknown
[ "$TEST_COUNT_FORMAT" != tap ] || count=$(tap_count "$out_tmp")
if [ "$timed_out" -eq 1 ]; then
  status=fail
elif [ "$before" != "$after" ]; then
  status=inconclusive
elif [ "$driver_rc" -ne 0 ]; then
  status=fail
elif is_positive_check "$check" && { [ "$count" = unknown ] || [ "$count" -eq 0 ]; }; then
  status=inconclusive
else
  status=pass
fi
executed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
stamp=$(date -u +%Y%m%dT%H%M%SZ)
invocation="bash:$(hex_value "$CHECK_DRIVER"):$(hex_value "$check")"
content_digest=$(receipt_digest "$check" "$status" "$driver_rc" "$count" "$after" "$root" "$invocation" "$executed_at") || die "could not digest receipt"
tries=0
while :; do
  id="$stamp-$$-$RANDOM-$content_digest"
  receipt="$receipts/$id.receipt"
  if (set -C; umask 077; {
      printf 'version=%s\n' "$schema_version"
      printf 'id=%s\ncheck=%s\nstatus=%s\nexit=%s\ncount=%s\nfingerprint=%s\n' "$id" "$check" "$status" "$driver_rc" "$count" "$after"
      printf 'worktree=%s\ninvocation=%s\nexecuted_at=%s\n' "$root" "$invocation" "$executed_at"
    } >"$receipt") 2>/dev/null; then break; fi
  tries=$((tries + 1)); [ "$tries" -lt 100 ] || die "could not allocate receipt id"
done
chmod 444 "$receipt" 2>/dev/null || :
saved=
if [ "$(wc -c <"$out_tmp" | tr -d '[:space:]')" -gt "$OUTPUT_MAX_BYTES" ] \
  && mkdir -p "$state/output" 2>/dev/null && cp "$out_tmp" "$state/output/$id.log" 2>/dev/null; then
  saved="$state/output/$id.log"
  case "$saved" in "$root"/*) saved=${saved#"$root"/} ;; esac
fi
emit_output "$out_tmp" "$saved"
output_emitted=1
print_record "$id" "$status" "$check" "$driver_rc" "$count"
case "$driver_rc:$status" in 124:*) exit 124 ;; *:pass) exit 0 ;; *) exit 1 ;; esac
