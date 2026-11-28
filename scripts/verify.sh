#!/usr/bin/env bash
set -u
export LC_ALL=C
unset CDPATH

schema_version=3
self_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=runtime.sh
. "$self_dir/runtime.sh"

usage() {
  cat <<'EOF'
Usage:
  verify.sh run CHECK [--root ROOT] [--timeout SECONDS] [--output-share N]
  verify.sh check RECEIPT [--root ROOT]
  verify.sh why RECEIPT [--root ROOT]
  verify.sh --help
  verify.sh --version

A check named in POSITIVE_TEST_CHECKS passes only when its output shows a test
ran. TEST_COUNT_FORMAT=auto counts TAP, and otherwise the closing summary of
node --test, pytest, unittest, Jest, Vitest, cargo test, go test -v, minitest,
and bun test. tap counts TAP alone. A runner outside that list needs its TAP
reporter in .agent/scripts/checks.sh. Skipped tests are not counted.

why prints one word for a current receipt: pass, failed, uncounted (a
positive check with no test count in its output), format (the same, when
TEST_COUNT_FORMAT is tap or none), empty (a positive check that ran 0 tests),
or changed (any other inconclusive run: project files changed, or its output
was lost).
EOF
}

die() { echo "verify.sh: $*" >&2; exit 2; }
safe_value() { case "$1" in *$'\n'* | *$'\r'* | *$'\t'*) return 1 ;; esac; return 0; }

load_config() {
  cfg=$1
  CHECK_DRIVER=.agent/scripts/checks.sh
  POSITIVE_TEST_CHECKS='test'
  TEST_COUNT_FORMAT=auto
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
  case "$TEST_COUNT_FORMAT" in auto | tap | none) ;; *) die "unsupported TEST_COUNT_FORMAT: $TEST_COUNT_FORMAT" ;; esac
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
  case "$TEST_COUNT_FORMAT" in
    tap) eo_tap=1 ;;
    auto) ! is_tap "$eo_file" || eo_tap=1 ;;
  esac
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
    /^ +---[[:space:]]*$/ && !yaml { yaml=index($0,"-"); next }
    yaml {
      if ($0 ~ /^ +\.\.\.[[:space:]]*$/ && index($0,".") == yaml) yaml=0
      next
    }
    /^ *(1\.\.|(ok|not ok)([[:space:]]|$))/ {
      line=$0
      sub(/^ +/, "", line)
      spaces=length($0) - length(line)
      if (spaces % 4) next
      depth=spaces / 4
      if (line ~ /^1\.\./) {
        if (depth) { child_plan[depth]=1; next }
        if (line !~ /^1\.\.[0-9]+([[:space:]]+#.*)?[[:space:]]*$/) bad=1
        else { plans++; sub(/^1\.\./, "", line); sub(/[[:space:]#].*$/, "", line); n=line }
        next
      }
      if (!depth) {
        if (line !~ /^(ok|not ok)[[:space:]]+[0-9]+([[:space:]]|$)/) { bad=1; next }
        result=line
        sub(/^(ok|not ok)[[:space:]]+/, "", result)
        sub(/[^0-9].*$/, "", result)
        if (result != ++results) bad=1
      }
      # A parent result closes the preceding indented subtest. A whole
      # skipped group supplies no more execution evidence than a skipped leaf.
      if (tolower(line) !~ /[[:space:]]+#[[:space:]]*(skip|todo)([[:space:]]|$)/ &&
          (!child_plan[depth+1] || executed[depth+1])) executed[depth]++
      delete child_plan[depth+1]
      delete executed[depth+1]
    }
    END {
      if (!bad && plans == 1 && n ~ /^[0-9]+$/ && results+0 == n+0) print executed[0]+0
      else print "unknown"
    }
  ' "$1"
}

# TAP output opens with a version line or carries a top-level plan. With
# TEST_COUNT_FORMAT=auto such output is counted by tap_count alone, so a
# summary line never stands in for a TAP stream that was cut short.
is_tap() { grep -Eq '^(TAP version [0-9]+|1\.\.[0-9]+)' "$1"; }

# The number of tests a runner's own closing summary says passed or failed, or
# "unknown" when no line has one of these shapes. Each shape was read from the
# runner named beside it: observed output, except Jest, whose line is the
# template in its SummaryReporter source (scripts/docs/verify.md lists the
# versions). Skipped and filtered tests are left out, so a run whose every
# test was skipped or filtered away counts 0. Several summaries add up, as
# cargo prints one per test binary.
summary_count() {
  awk '
    function before(s, word,   n) {
      if (!match(s, "[0-9]+ " word)) return 0
      n = substr(s, RSTART, RLENGTH); sub(/ .*/, "", n)
      return n + 0
    }
    function add(n) { total += n; seen = 1 }
    # node --test, spec reporter: "<U+2139> pass 2", "<U+2139> fail 0"
    $0 ~ "^\342\204\271 (pass|fail) [0-9]+$" { add($3); next }
    # bun test: " 2 pass", " 0 fail". Its "Ran 2 tests" line counts skips.
    /^ [0-9]+ (pass|fail)$/ { add($1); next }
    # Python unittest: "Ran 3 tests in 0.000s", then "OK (skipped=1)"
    /^Ran [0-9]+ tests? in [0-9.]+s$/ { add($2); next }
    /^(OK|FAILED) \(.*skipped=[0-9]+/ { n = $0; sub(/.*skipped=/, "", n); sub(/[^0-9].*/, "", n); add(-n); next }
    # Jest: "Tests:       1 failed, 2 passed, 3 total"
    /^Tests: +([0-9]+ [a-z]+, )*[0-9]+ total$/ { add(before($0, "passed") + before($0, "failed")); next }
    # Vitest: "      Tests  1 failed | 2 passed (3)"
    /^ +Tests  [0-9]+ [a-z]+( \| [0-9]+ [a-z]+)* \([0-9]+\)$/ { add(before($0, "passed") + before($0, "failed")); next }
    # cargo test: "test result: ok. 2 passed; 0 failed; 0 ignored; ..."
    /^test result: [A-Za-z]+\. [0-9]+ passed; [0-9]+ failed;/ { add($4 + $6); next }
    # go test -v, top-level tests: "--- PASS: TestA (0.00s)"
    /^--- (PASS|FAIL): / { add(1); next }
    # minitest: "2 runs, 1 assertions, 0 failures, 0 errors, 1 skips"
    /^[0-9]+ runs, [0-9]+ assertions, [0-9]+ failures, [0-9]+ errors, [0-9]+ skips$/ { add($1 - $9); next }
    # pytest: "==== 1 failed, 2 passed in 0.02s ====", or bare under -q
    {
      line = $0
      gsub(/^=+ | =+$/, "", line)
      if (line ~ /^no tests ran in [0-9.]+s/) { add(0); next }
      if (line ~ /^[0-9]+ [a-z]+(, [0-9]+ [a-z]+)* in [0-9.]+s( \([0-9:]+\))?$/)
        add(before(line, "passed") + before(line, "failed") + before(line, "xfailed") + before(line, "xpassed"))
    }
    # unittest counts class, module, and subtest skips in "skipped" and not
    # in "Ran", so the difference can fall below 0. No test ran then.
    END { if (!seen) print "unknown"; else if (total < 0) print 0; else print total + 0 }
  ' "$1"
}

# Why a run that exited 0 is inconclusive, as one word, from what its receipt
# holds: the check and the count. A positive check with no count or a count of
# 0 is inconclusive for that reason, whatever else happened. Any other
# inconclusive run changed the project files, or lost its output.
inconclusive_code() {
  if is_positive_check "$1"; then
    case "$2" in
      unknown) if [ "$TEST_COUNT_FORMAT" = auto ]; then echo uncounted; else echo format; fi; return 0 ;;
      0) echo empty; return 0 ;;
    esac
  fi
  echo changed
}

inconclusive_reason() {
  case "$(inconclusive_code "$1" "$2")" in
    uncounted) echo "$1 exited 0, but its output carries no test count this script reads, so the result is inconclusive. Make $CHECK_DRIVER run the runner with its TAP reporter or a summary that verify.sh --help lists. Leave the project's own test command as it is" ;;
    format) echo "$1 exited 0, but TEST_COUNT_FORMAT=$TEST_COUNT_FORMAT read no test count from its output, so the result is inconclusive. If verify.sh --help lists this runner, set TEST_COUNT_FORMAT=auto in .agent/scripts/verify.conf. Otherwise make $CHECK_DRIVER run the runner with its TAP reporter. Leave the project's own test command as it is" ;;
    empty) echo "$1 exited 0 and ran 0 tests, so the result is inconclusive. Run it over at least one test" ;;
    *) echo "project files changed while $1 ran, so the result is inconclusive. Run the check again. If it repeats, make the check write only where Git ignores" ;;
  esac
}

print_record() { printf 'receipt\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5"; }

receipt_digest() {
  printf 'version=%s\ncheck=%s\nstatus=%s\nexit=%s\ncount=%s\nfingerprint=%s\nworktree=%s\ninvocation=%s\nexecuted_at=%s\nfails_without_change=%s\n' \
    "$schema_version" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" | git hash-object --stdin
}

# Whether the check was seen failing at the base commit with only the
# change's test files applied: yes, no, or unknown. Nothing runs that proof
# yet, so every run records unknown (scripts/docs/verify.md, design note).
fails_without_change=unknown

hex_value() { printf '%s' "$1" | od -An -tx1 | tr -d ' \n'; }

cancel_watchdog() {
  case "${watchdog:-}" in
    '' | *[!0-9]*) ;;
    *)
      kill -TERM -- "-$watchdog" 2>/dev/null || kill -TERM "$watchdog" 2>/dev/null || :
      wait "$watchdog" 2>/dev/null || :
      # A sleep forked as the signal arrived can outlive the shell that ran it.
      kill -KILL -- "-$watchdog" 2>/dev/null || :
      watchdog=
      ;;
  esac
}

# A child signalled before it resets its traps runs the handlers below, and the
# output, the lock, and the check are its parent's. $$ is the parent's in both.
owns_run() { [ "$(exec sh -c 'echo "$PPID"')" = "$$" ]; }

cleanup_run() {
  owns_run || return 0
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
  owns_run || { trap - EXIT; exit "$ir_code"; }
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

# drive DIR OUT: runs the driver for $check in DIR with its output in OUT, and
# sets driver_rc and timed_out. Job control gives the driver an
# invocation-owned process group on Bash 3.2.
drive() {
  rm -f "$watchdog_marker"
  set -m
  # Each forked shell sets its process group before it applies its
  # redirection. When that call loses a race it prints "child setpgid" on this
  # script's stderr, where a caller reads the check's output. Both forks below
  # start with that stream on descriptor 9 and close their copy, so a
  # watchdog that outlives a killed run holds no pipe of the caller's open.
  exec 9>&2 2>/dev/null
  (cd "$1" && exec bash "$driver" "$check") >"$2" 2>&1 9>&- &
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
  ) </dev/null >/dev/null 2>&1 9>&- &
  watchdog=$!
  exec 2>&9 9>&-
  set +m
  wait "$child" 2>/dev/null
  driver_rc=$?
  child=
  if [ -f "$watchdog_marker" ]; then
    wait "$watchdog" 2>/dev/null || :
  else
    cancel_watchdog
  fi
  watchdog=
  if [ -f "$watchdog_marker" ]; then timed_out=1; driver_rc=124; else timed_out=0; fi
}

case "${1:-}" in
  --help | -h) usage; exit 0 ;;
  --version) printf 'dot-agent v6.3; verify.sh receipt schema %s\n' "$schema_version"; exit 0 ;;
  run | check | why) op=$1; shift ;;
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

if [ "$op" != run ]; then
  case "$receipt_arg" in '' | *[!A-Za-z0-9_.-]*) die "RECEIPT must be an opaque id" ;; esac
  receipt="$receipts/$receipt_arg.receipt"
  [ -f "$receipt" ] && [ ! -L "$receipt" ] || die "receipt is missing or not a regular file: $receipt_arg"
  lines=$(wc -l <"$receipt" | tr -d '[:space:]')
  [ "$lines" = 11 ] || die "invalid receipt shape"
  IFS= read -r r1 <"$receipt"
  r2=$(sed -n '2p' "$receipt"); r3=$(sed -n '3p' "$receipt"); r4=$(sed -n '4p' "$receipt")
  r5=$(sed -n '5p' "$receipt"); r6=$(sed -n '6p' "$receipt"); r7=$(sed -n '7p' "$receipt")
  r8=$(sed -n '8p' "$receipt"); r9=$(sed -n '9p' "$receipt"); r10=$(sed -n '10p' "$receipt")
  r11=$(sed -n '11p' "$receipt")
  [ "$r1" = "version=$schema_version" ] || die "invalid receipt version"
  id=${r2#id=}; rcheck=${r3#check=}; status=${r4#status=}; exit_code=${r5#exit=}; count=${r6#count=}; recorded=${r7#fingerprint=}
  recorded_root=${r8#worktree=}; recorded_invocation=${r9#invocation=}; executed_at=${r10#executed_at=}
  recorded_fwc=${r11#fails_without_change=}
  [ "$r11" = "fails_without_change=$recorded_fwc" ] || die "receipt has no fails_without_change field"
  case "$recorded_fwc" in yes | no | unknown) ;; *) die "invalid receipt fails_without_change" ;; esac
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
  expected_receipt_digest=$(receipt_digest "$rcheck" "$status" "$exit_code" "$count" "$recorded" "$recorded_root" "$recorded_invocation" "$executed_at" "$recorded_fwc") || die "could not validate receipt digest"
  [ "${id##*-}" = "$expected_receipt_digest" ] || die "receipt content digest does not match its id"
  current=$(da_fingerprint "$root") || exit 2
  [ "$current" = "$recorded" ] || die "receipt is stale: project inputs changed"
  if [ "$op" = why ]; then
    case "$status:$exit_code" in
      pass:*) echo pass ;;
      inconclusive:0) inconclusive_code "$rcheck" "$count" ;;
      *) echo failed ;;
    esac
    exit 0
  fi
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

drive "$root" "$out_tmp"
after=$(da_fingerprint "$root") || exit 2
count=unknown
output_lost=0
[ -f "$out_tmp" ] || output_lost=1
if [ "$output_lost" -eq 0 ]; then
  case "$TEST_COUNT_FORMAT" in
    tap) count=$(tap_count "$out_tmp") ;;
    auto) if is_tap "$out_tmp"; then count=$(tap_count "$out_tmp"); else count=$(summary_count "$out_tmp"); fi ;;
  esac
fi
# A receipt holds a count of digits or "unknown", and check refuses any other.
case "$count" in unknown) ;; '' | *[!0-9]*) count=unknown ;; esac
why=
if [ "$timed_out" -eq 1 ]; then
  status=fail
elif [ "$before" != "$after" ]; then
  status=inconclusive
  if [ "$driver_rc" -eq 0 ]; then why=$(inconclusive_reason "$check" "$count"); else why=$(inconclusive_reason "$check" changed); fi
elif [ "$driver_rc" -ne 0 ]; then
  status=fail
elif [ "$output_lost" -eq 1 ]; then
  status=inconclusive
elif is_positive_check "$check" && { [ "$count" = unknown ] || [ "$count" -eq 0 ]; }; then
  status=inconclusive
  why=$(inconclusive_reason "$check" "$count")
else
  status=pass
fi
executed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
stamp=$(date -u +%Y%m%dT%H%M%SZ)
invocation="bash:$(hex_value "$CHECK_DRIVER"):$(hex_value "$check")"
content_digest=$(receipt_digest "$check" "$status" "$driver_rc" "$count" "$after" "$root" "$invocation" "$executed_at" "$fails_without_change") || die "could not digest receipt"
tries=0
while :; do
  id="$stamp-$$-$RANDOM-$content_digest"
  receipt="$receipts/$id.receipt"
  if (set -C; umask 077; {
      printf 'version=%s\n' "$schema_version"
      printf 'id=%s\ncheck=%s\nstatus=%s\nexit=%s\ncount=%s\nfingerprint=%s\n' "$id" "$check" "$status" "$driver_rc" "$count" "$after"
      printf 'worktree=%s\ninvocation=%s\nexecuted_at=%s\n' "$root" "$invocation" "$executed_at"
      printf 'fails_without_change=%s\n' "$fails_without_change"
    } >"$receipt") 2>/dev/null; then break; fi
  tries=$((tries + 1)); [ "$tries" -lt 100 ] || die "could not allocate receipt id"
done
chmod 444 "$receipt" 2>/dev/null || :
saved=
if [ "$output_lost" -eq 1 ]; then
  echo "verify.sh: the check's output was removed while it ran, so the result is inconclusive. Run the check again" >&2
elif [ "$(wc -c <"$out_tmp" | tr -d '[:space:]')" -gt "$OUTPUT_MAX_BYTES" ] \
  && mkdir -p "$state/output" 2>/dev/null && cp "$out_tmp" "$state/output/$id.log" 2>/dev/null; then
  saved="$state/output/$id.log"
  case "$saved" in "$root"/*) saved=${saved#"$root"/} ;; esac
fi
[ "$output_lost" -eq 1 ] || emit_output "$out_tmp" "$saved"
output_emitted=1
[ -z "$why" ] || echo "verify.sh: $why" >&2
print_record "$id" "$status" "$check" "$driver_rc" "$count"
case "$driver_rc:$status" in 124:*) exit 124 ;; *:pass) exit 0 ;; *) exit 1 ;; esac
