#!/usr/bin/env bash
set -u
export LC_ALL=C
unset CDPATH

schema_version=3
# Only prove sets these, for the driver in its checkout. A caller's copies
# must not reach a run of the current tree.
unset DA_PROVE DA_PROVE_MAIN
self_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=runtime.sh
. "$self_dir/runtime.sh"

usage() {
  cat <<'EOF'
Usage:
  verify.sh run CHECK [--root ROOT] [--timeout SECONDS] [--output-share N]
  verify.sh prove CHECK --test PATH... [--base REF] [--root ROOT] [--timeout SECONDS]
  verify.sh prove CHECK --break PATH=FILE... [--test PATH...] [--root ROOT] [--timeout SECONDS]
  verify.sh check RECEIPT [--root ROOT]
  verify.sh why RECEIPT [--root ROOT]
  verify.sh --help
  verify.sh --version

A check named in POSITIVE_TEST_CHECKS passes only when its output shows a test
ran. TEST_COUNT_FORMAT=auto counts TAP, and otherwise the closing summary of
node --test, pytest, unittest, Jest, Vitest, cargo test, go test -v, minitest,
and bun test. tap counts TAP alone. A runner outside that list needs its TAP
reporter in .agent/scripts/checks.sh. Skipped tests are not counted.

prove runs CHECK on the current tree, then in a throwaway checkout without
the change, and records on the receipt whether it fails there. --base REF
(default HEAD) is the commit before the change, and each --test PATH is a
test file copied onto it, Git-ignored or not. --break PATH=FILE proves a
rule the old code already met: it replaces PATH with the broken copy FILE in
a checkout of the current files. prove exits 0 only when the check passes now
and fails without the change. The driver runs in the checkout with DA_PROVE=1
and DA_PROVE_MAIN set to the project, for what the checkout lacks.

why prints one word for a current receipt: pass, proved or unproved (a pass
whose proof ran and held or did not), failed, uncounted (a
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
  printf 'version=%s\ncheck=%s\nstatus=%s\nexit=%s\ncount=%s\nfingerprint=%s\nworktree=%s\ninvocation=%s\nexecuted_at=%s\nproof=%s\nfails_without_change=%s\n' \
    "$schema_version" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" | git hash-object --stdin
}

# Whether the check was seen failing without the change: yes, no, or unknown.
# Only prove sets it. proof names what the verdict rests on, so it stays on
# record after a Git-ignored scratch test is deleted: none, or the mode, the
# base commit or the digest of the broken copies, and the digest of the test
# files.
fails_without_change=unknown
proof=none

prove_path_ok() {
  case "$1" in '' | /* | .. | ../* | */../* | */.. | .git | .git/* | */.git | */.git/*) return 1 ;; esac
  safe_value "$1"
}

# prove_copy SRC DST: copies the file SRC over DST, a path of the checkout
# relative to the Git top level. A missing SRC removes DST, which is how a
# deleted file reaches the checkout. A parent of DST that is a symbolic link
# could lead back into the project, so such a path is refused.
prove_copy() {
  pcp_walk=$prove_tree; pcp_rest=$2
  while :; do
    case "$pcp_rest" in */*) pcp_walk="$pcp_walk/${pcp_rest%%/*}"; pcp_rest=${pcp_rest#*/} ;; *) break ;; esac
    [ ! -L "$pcp_walk" ] || return 1
  done
  rm -rf -- "${prove_tree:?}/$2" || return 1
  if [ -e "$1" ] || [ -L "$1" ]; then
    mkdir -p -- "$(dirname -- "$prove_tree/$2")" && cp -pPR -- "$1" "$prove_tree/$2"
  fi
}

prove_tests_in() {
  [ "${#prove_tests[@]}" -gt 0 ] || return 0
  for pt in "${prove_tests[@]}"; do prove_copy "$prove_dir/in/$pt" "$prove_prefix$pt" || return 1; done
}

# Digest of the named snapshot files as "path<TAB>blob" lines, so a proof
# names the exact content that ran.
prove_digest() {
  for pd in "$@"; do
    pd_blob=$(git hash-object --no-filters -- "$prove_dir/in/$pd") || return 1
    printf '%s\t%s\n' "$pd" "$pd_blob"
  done >"$prove_dir/digest" || return 1
  LC_ALL=C sort "$prove_dir/digest" | git hash-object --stdin
}

# Runs the check without the change in a throwaway clone, after a control run
# of the current files there. The control separates a checkout that cannot
# run the check from a test that fails for the change. Sets
# fails_without_change, proof, prove_said, and prove_show. The session's
# tree, index, and repository are never written.
prove_change() {
  pc_rc=$driver_rc; pc_timed_out=$timed_out
  pc_restore() { driver_rc=$pc_rc; timed_out=$pc_timed_out; }
  pc_stop() { prove_said=$1; pc_restore; return 0; }
  prove_said=; prove_show=
  prove_top=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null) || { pc_stop "prove needs a Git worktree, so nothing was proved"; return 0; }
  prove_prefix=$(git -C "$root" rev-parse --show-prefix 2>/dev/null)
  pc_head=$(git -C "$root" rev-parse -q --verify 'HEAD^{commit}') || { pc_stop "the repository has no commit, so nothing was proved. Commit once, then run this call again"; return 0; }
  pc_base=$pc_head
  if [ -n "$prove_base" ]; then
    pc_base=$(git -C "$root" rev-parse -q --verify "$prove_base^{commit}") || { pc_stop "--base $prove_base names no commit, so nothing was proved. Pass the commit before the change"; return 0; }
    git -C "$root" merge-base --is-ancestor "$pc_base" "$pc_head" 2>/dev/null || { pc_stop "--base $prove_base is no ancestor of HEAD, so nothing was proved. Pass the commit before the change"; return 0; }
  fi
  if [ -n "$(git -C "$prove_top" submodule status 2>/dev/null)" ]; then
    pc_stop "the checkout would lack this repository's submodules, so nothing was proved. See the failure by hand in a copy, and say so in the report"; return 0
  fi
  prove_dir=$(mktemp -d "${TMPDIR:-/tmp}/verify-prove.XXXXXX") || { pc_stop "could not create the proving folder, so nothing was proved. Check the temporary folder and run this call again"; return 0; }
  prove_tree="$prove_dir/tree"
  # The proof runs and is digested from this snapshot, so a file edited or
  # deleted while the runs go on cannot change what the receipt names.
  pc_inputs=()
  [ "${#prove_tests[@]}" -eq 0 ] || pc_inputs+=("${prove_tests[@]}")
  if [ "${#prove_breaks[@]}" -gt 0 ]; then
    for pc_pair in "${prove_breaks[@]}"; do pc_inputs+=("${pc_pair#*=}"); done
  fi
  for pc_in in "${pc_inputs[@]}"; do
    mkdir -p -- "$(dirname -- "$prove_dir/in/$pc_in")" && cp -p -- "$root/$pc_in" "$prove_dir/in/$pc_in" \
      || { pc_stop "could not read $pc_in, so nothing was proved. Check that the file is readable and run this call again"; return 0; }
  done
  # A caller's GIT_DIR or GIT_WORK_TREE would aim the commands below, and the
  # driver in the checkout, at the session's repository.
  # shellcheck disable=SC2046
  unset $(git rev-parse --local-env-vars 2>/dev/null)
  if ! git clone -q --shared --no-checkout "$prove_top" "$prove_tree" >/dev/null 2>&1 \
    || ! git -C "$prove_tree" checkout -q --detach "$pc_head" >/dev/null 2>&1; then
    pc_stop "could not build the proving checkout, so nothing was proved. Run git status, fix what it reports, then run this call again"; return 0
  fi
  if ! { GIT_OPTIONAL_LOCKS=0 git -C "$prove_top" diff --no-renames --name-only -z HEAD -- && git -C "$prove_top" ls-files -o --exclude-standard -z; } >"$prove_dir/paths" 2>/dev/null; then
    pc_stop "git could not list the current changes, so nothing was proved. Run git status, fix what it reports, then run this call again"; return 0
  fi
  while IFS= read -r -d '' pc_path; do
    prove_copy "$prove_top/$pc_path" "$pc_path" || { pc_stop "could not copy $pc_path into the proving checkout, so nothing was proved. Check that the file is readable and run this call again"; return 0; }
  done <"$prove_dir/paths"
  prove_tests_in || { pc_stop "a --test path passes through a symbolic link in the proving checkout, so nothing was proved. Name a test file in a real folder"; return 0; }
  export DA_PROVE=1 DA_PROVE_MAIN="$root"
  drive "$prove_tree/$prove_prefix" "$prove_dir/control"
  if [ "$timed_out" -eq 1 ]; then
    pc_stop "$check timed out in the proving checkout with the current files, so nothing was proved. Raise --timeout or prove a narrower check"; return 0
  fi
  if [ "$driver_rc" -ne 0 ]; then
    prove_show="$prove_dir/control"
    pc_stop "$check fails in the proving checkout with the current files, so nothing was proved. The checkout holds tracked and unignored files only. Make $CHECK_DRIVER read what it lacks from \$DA_PROVE_MAIN when DA_PROVE is set"; return 0
  fi
  pc_timeout=0; pc_passing=
  : >"$prove_dir/target"
  if [ "${#prove_breaks[@]}" -gt 0 ]; then
    pc_mode='break'
    pc_files=()
    for pc_pair in "${prove_breaks[@]}"; do
      pc_files+=("${pc_pair#*=}")
      # A build that compares modification times must see the copy as newer
      # than what the control run built.
      prove_copy "$prove_dir/in/${pc_pair#*=}" "$prove_prefix${pc_pair%%=*}" && touch -- "$prove_tree/$prove_prefix${pc_pair%%=*}" \
        || { pc_stop "${pc_pair%%=*} passes through a symbolic link in the proving checkout, so nothing was proved. Break a file in a real folder of the project"; return 0; }
    done
    drive "$prove_tree/$prove_prefix" "$prove_dir/target"
    pc_timeout=$timed_out
    [ "$driver_rc" -ne 0 ] || pc_passing=all
    pc_ref=$(prove_digest "${pc_files[@]}") || pc_ref=
    pc_without="with ${#prove_breaks[@]} broken file(s) in place"
  else
    pc_mode=base
    # One run for each test file, with that file alone copied onto the base.
    # A runner that stops at its first failure would otherwise let one
    # failing test stand for the others.
    for pt in "${prove_tests[@]}"; do
      if ! git -C "$prove_tree" checkout -q -f --detach "$pc_base" >/dev/null 2>&1 || ! git -C "$prove_tree" clean -q -ffdx >/dev/null 2>&1; then
        pc_stop "could not put the proving checkout at ${pc_base:0:12}, so nothing was proved. Run this call again"; return 0
      fi
      prove_copy "$prove_dir/in/$pt" "$prove_prefix$pt" || { pc_stop "$pt passes through a symbolic link at ${pc_base:0:12}, so nothing was proved. Name a test file in a real folder"; return 0; }
      drive "$prove_tree/$prove_prefix" "$prove_dir/one"
      [ "$timed_out" -eq 0 ] || { pc_timeout=1; break; }
      { printf '== %s copied onto %s: exit %s ==\n' "$pt" "${pc_base:0:12}" "$driver_rc"; cat "$prove_dir/one"; } >>"$prove_dir/target"
      [ "$driver_rc" -ne 0 ] || pc_passing="${pc_passing:+$pc_passing, }$pt"
    done
    pc_ref=$pc_base
    pc_without="at ${pc_base:0:12} with each of ${#prove_tests[@]} test file(s) copied in"
  fi
  prove_show="$prove_dir/target"
  pc_tests=$(prove_digest ${prove_tests[@]+"${prove_tests[@]}"}) || pc_tests=
  if [ "$pc_timeout" -eq 1 ]; then
    prove_said="$check timed out without the change, so nothing was proved. Raise --timeout or prove a narrower check"
  elif [ -z "$pc_tests" ] || [ -z "$pc_ref" ]; then
    prove_said="could not digest the proof's files, so nothing was proved. Run this call again"
  elif [ -z "$pc_passing" ]; then
    fails_without_change=yes
    proof="$pc_mode:$pc_ref:$pc_tests"
    prove_said="$check fails $pc_without and passes on the current tree. Read the output above and confirm each failure is the one you mean"
  else
    fails_without_change=no
    proof="$pc_mode:$pc_ref:$pc_tests"
    if [ "$pc_mode" = break ]; then
      prove_said="$check still passes $pc_without, so no test here protects that behavior. Add or fix the test, then run this call again"
    else
      prove_said="$check passes at ${pc_base:0:12} with $pc_passing copied in, so that does not prove the change. Make it fail without the change, pass --base <commit before the change> when the change is committed, or prove a rule the old code already met with --break PATH=FILE"
    fi
  fi
  pc_restore
}

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
  case "${prove_dir:-}" in */verify-prove.*) rm -rf -- "$prove_dir" ;; esac
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
  # start with that stream closed.
  { (cd "$1" && exec bash "$driver" "$check") >"$2" 2>&1 & } 2>/dev/null
  child=$!
  # With monitor mode, Bash assigns an asynchronous job a new process group whose
  # id is the job leader's pid.  This avoids depending on ps permissions.
  pgid=$child
  {
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
  } 2>/dev/null
  watchdog=$!
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
  run | check | why | prove) op=$1; shift ;;
  *) usage >&2; exit 2 ;;
esac

root=.
timeout=
output_share=1
prove_base=; prove_tests=(); prove_breaks=(); prove_dir=; prove_said=; prove_show=
if [ "$op" = run ] || [ "$op" = prove ]; then
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
      [ "$op" = run ] || [ "$op" = prove ] || die "--timeout is valid only with run and prove"
      [ "$#" -ge 2 ] || die "--timeout needs a value"; timeout=$2; shift 2 ;;
    --output-share)
      [ "$op" = run ] || die "--output-share is valid only with run"
      [ "$#" -ge 2 ] || die "--output-share needs a value"; output_share=$2; shift 2 ;;
    --base)
      [ "$op" = prove ] || die "--base is valid only with prove"
      [ "$#" -ge 2 ] || die "--base needs a value"; prove_base=$2; shift 2 ;;
    --test)
      [ "$op" = prove ] || die "--test is valid only with prove"
      [ "$#" -ge 2 ] || die "--test needs a value"; prove_tests+=("$2"); shift 2 ;;
    --break)
      [ "$op" = prove ] || die "--break is valid only with prove"
      [ "$#" -ge 2 ] || die "--break needs a value"; prove_breaks+=("$2"); shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
root=$(da_root "$root") || exit 2
if [ "$op" = prove ]; then
  # Two check outputs print into one tool result.
  output_share=2
  [ -z "$prove_base" ] || [ "${#prove_breaks[@]}" -eq 0 ] || die "--base and --break were both given. Pass one of them"
  [ "${#prove_tests[@]}" -gt 0 ] || [ "${#prove_breaks[@]}" -gt 0 ] || die "prove needs --test PATH for the test that proves the change, or --break PATH=FILE for a rule the old code already met"
  if [ "${#prove_tests[@]}" -gt 0 ]; then
    for pt in "${prove_tests[@]}"; do
      prove_path_ok "$pt" || die "--test takes a path inside the project, without a leading slash, .., or .git: $pt"
      [ -f "$root/$pt" ] && [ ! -L "$root/$pt" ] || die "--test names no regular file: $pt. Pass the test file's path from the project folder"
    done
  fi
  if [ "${#prove_breaks[@]}" -gt 0 ]; then
    for pb in "${prove_breaks[@]}"; do
      case "$pb" in ?*=?*) ;; *) die "--break takes PATH=FILE, the file to replace and its broken copy: $pb" ;; esac
      prove_path_ok "${pb%%=*}" && prove_path_ok "${pb#*=}" || die "--break takes paths inside the project, without a leading slash, .., or .git: $pb. Keep the broken copy in the project's scratch folder"
      [ -f "$root/${pb%%=*}" ] && [ ! -L "$root/${pb%%=*}" ] || die "--break names no regular file to replace: ${pb%%=*}"
      [ -f "$root/${pb#*=}" ] && [ ! -L "$root/${pb#*=}" ] || die "--break names no regular broken copy: ${pb#*=}. Copy the file, break the behavior in the copy, and pass the copy"
    done
  fi
fi
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

if [ "$op" = check ] || [ "$op" = why ]; then
  case "$receipt_arg" in '' | *[!A-Za-z0-9_.-]*) die "RECEIPT must be an opaque id" ;; esac
  receipt="$receipts/$receipt_arg.receipt"
  [ -f "$receipt" ] && [ ! -L "$receipt" ] || die "receipt is missing or not a regular file: $receipt_arg"
  lines=$(wc -l <"$receipt" | tr -d '[:space:]')
  [ "$lines" = 12 ] || die "invalid receipt shape"
  IFS= read -r r1 <"$receipt"
  r2=$(sed -n '2p' "$receipt"); r3=$(sed -n '3p' "$receipt"); r4=$(sed -n '4p' "$receipt")
  r5=$(sed -n '5p' "$receipt"); r6=$(sed -n '6p' "$receipt"); r7=$(sed -n '7p' "$receipt")
  r8=$(sed -n '8p' "$receipt"); r9=$(sed -n '9p' "$receipt"); r10=$(sed -n '10p' "$receipt")
  r11=$(sed -n '11p' "$receipt"); r12=$(sed -n '12p' "$receipt")
  [ "$r1" = "version=$schema_version" ] || die "invalid receipt version"
  id=${r2#id=}; rcheck=${r3#check=}; status=${r4#status=}; exit_code=${r5#exit=}; count=${r6#count=}; recorded=${r7#fingerprint=}
  recorded_root=${r8#worktree=}; recorded_invocation=${r9#invocation=}; executed_at=${r10#executed_at=}
  recorded_proof=${r11#proof=}
  [ "$r11" = "proof=$recorded_proof" ] || die "receipt has no proof field"
  printf '%s\n' "$recorded_proof" | grep -Eq '^(none|(base|break):[0-9a-f]+:[0-9a-f]+)$' || die "invalid receipt proof"
  recorded_fwc=${r12#fails_without_change=}
  [ "$r12" = "fails_without_change=$recorded_fwc" ] || die "receipt has no fails_without_change field"
  case "$recorded_fwc" in yes | no | unknown) ;; *) die "invalid receipt fails_without_change" ;; esac
  case "$recorded_proof:$recorded_fwc" in none:unknown | base:*:yes | base:*:no | break:*:yes | break:*:no) ;; *) die "receipt proof does not match its fails_without_change" ;; esac
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
  expected_receipt_digest=$(receipt_digest "$rcheck" "$status" "$exit_code" "$count" "$recorded" "$recorded_root" "$recorded_invocation" "$executed_at" "$recorded_proof" "$recorded_fwc") || die "could not validate receipt digest"
  [ "${id##*-}" = "$expected_receipt_digest" ] || die "receipt content digest does not match its id"
  current=$(da_fingerprint "$root") || exit 2
  [ "$current" = "$recorded" ] || die "receipt is stale: project inputs changed"
  if [ "$op" = why ]; then
    case "$status:$exit_code" in
      pass:*)
        case "$recorded_proof:$recorded_fwc" in
          none:*) echo pass ;;
          *:yes) echo proved ;;
          *) echo unproved ;;
        esac ;;
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
if [ "$op" = prove ]; then
  if [ "$status" = pass ]; then
    prove_change
  else
    prove_said="$check does not pass on the current tree, so there is nothing to prove. Make it pass first, then run this call again"
  fi
fi
executed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
stamp=$(date -u +%Y%m%dT%H%M%SZ)
invocation="bash:$(hex_value "$CHECK_DRIVER"):$(hex_value "$check")"
content_digest=$(receipt_digest "$check" "$status" "$driver_rc" "$count" "$after" "$root" "$invocation" "$executed_at" "$proof" "$fails_without_change") || die "could not digest receipt"
tries=0
while :; do
  id="$stamp-$$-$RANDOM-$content_digest"
  receipt="$receipts/$id.receipt"
  if (set -C; umask 077; {
      printf 'version=%s\n' "$schema_version"
      printf 'id=%s\ncheck=%s\nstatus=%s\nexit=%s\ncount=%s\nfingerprint=%s\n' "$id" "$check" "$status" "$driver_rc" "$count" "$after"
      printf 'worktree=%s\ninvocation=%s\nexecuted_at=%s\n' "$root" "$invocation" "$executed_at"
      printf 'proof=%s\nfails_without_change=%s\n' "$proof" "$fails_without_change"
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
if [ -n "$prove_show" ] && [ -s "$prove_show" ]; then
  echo "verify.sh: prove: the run without the change printed:" >&2
  emit_output "$prove_show" ""
fi
[ -z "$prove_said" ] || echo "verify.sh: prove: $prove_said" >&2
print_record "$id" "$status" "$check" "$driver_rc" "$count"
case "$driver_rc:$status" in 124:*) exit 124 ;; *:pass) ;; *) exit 1 ;; esac
[ "$op" != prove ] || [ "$fails_without_change" = yes ] || exit 1
exit 0
