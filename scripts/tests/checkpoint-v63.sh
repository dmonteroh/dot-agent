#!/usr/bin/env bash
set -eu
unset CDPATH
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/checkpoint-v63.XXXXXX")
scratch=$(cd "$scratch" && pwd -P)
trap 'rm -rf "$scratch"' EXIT
# Past this line a failed command is recorded by fail and the file goes on,
# so one run under verify.sh prove shows every failing assertion.
[ -z "${DA_PROVE:-}" ] || set +e
fail() { echo "FAIL checkpoint-v63: $*" >&2; [ -n "${DA_PROVE:-}" ] || exit 1; proved_failures=1; }
project="$scratch/project with spaces"
mkdir -p "$project/src"
bash "$repo/scripts/node.sh" init --preset software-development --mode track-all "$project" >/dev/null
contract="$project/.agent/rules/contract.md"
awk '/^## Quality bar/{q=1} q && /^## / && !/^## Quality bar/{q=0} q' "$contract" >"$project/.agent/rules/quality-bar.md"
awk '/^## Quality bar/{q=1} q && /^## / && !/^## Quality bar/{q=0} !q' "$contract" >"$scratch/contract"
sed 's/^\(- [A-Za-z][^:]*:\) <.*>$/\1 configured/' "$scratch/contract" >"$contract"
cat >"$project/.agent/scripts/checks.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
[ "$1" = test ] || exit 2
state="$PWD/.agent/.state"
mkdir -p "$state"
printf 'run\n' >>"$state/check-count"
for scratch_test in src/*.test.sh tmp/scratch/*.test.sh; do
  [ -f "$scratch_test" ] || continue
  bash "$scratch_test" || { printf 'TAP version 13\n1..1\nnot ok 1 - %s\n' "$scratch_test"; exit 1; }
done
mode=$(cat .agent/scripts/test-mode)
case "$mode" in
  pass) printf 'TAP version 13\n1..1\nok 1 - fixture\n# tests 1\n' ;;
  zero) printf 'TAP version 13\n1..0\n# tests 0\n' ;;
  fail) printf 'TAP version 13\n1..1\nnot ok 1 - fixture\n# tests 1\n'; exit 9 ;;
  silent) printf 'all good\n' ;;
  mutate) printf 'changed\n' >>src/mutated.ts; printf 'TAP version 13\n1..1\nok 1 - fixture\n' ;;
esac
EOF
printf 'pass\n' >"$project/.agent/scripts/test-mode"
printf 'const amount = 1\n' >"$project/src/client.ts"
git -C "$project" init -q
git -C "$project" add .
git -C "$project" -c user.name=fixture -c user.email=fixture@local -c commit.gpgsign=false commit -qm fixture
checkpoint="$project/.agent/scripts/checkpoint.sh"
log="$project/.agent/session-log.md"
entries() { awk '/^- \[/{n++} END{print n+0}' "$log"; }
checkpoint() {
  bash "$checkpoint" --tool test --area fixture --summary 'Changed fixture behavior' "$@" "$project" >"$scratch/out" 2>"$scratch/err"
}

printf 'const amount = 2\n' >"$project/src/client.ts"
if checkpoint --verify pass; then fail 'caller-supplied pass was accepted'; fi
[ "$(entries)" -eq 0 ] || fail 'unverified work was logged'
checkpoint --checks test || { cat "$scratch/err" >&2; fail 'verified checkpoint failed'; }
[ "$(entries)" -eq 1 ] || fail 'first checkpoint did not append once'
checkpoint --checks test || fail 'identical retry failed'
[ "$(entries)" -eq 1 ] || fail 'identical retry duplicated the log'
[ "$(wc -l <"$project/.agent/.state/check-count" | tr -d ' ')" -eq 1 ] || fail 'identical retry reran verification'

printf 'const amount = 3\n' >"$project/src/client.ts"
receipt_record=$(bash "$project/.agent/scripts/verify.sh" run test --root "$project" 2>"$scratch/verify.err")
receipt=$(printf '%s\n' "$receipt_record" | cut -f2)
printf 'const amount = 4\n' >"$project/src/client.ts"
if checkpoint --verification "$receipt"; then fail 'stale receipt was accepted'; fi
tail -1 "$scratch/err" | grep -q 'Run the check again with --checks <name>$' || fail 'a stale receipt did not name the next step'
[ "$(entries)" -eq 1 ] || fail 'stale receipt appended a log entry'

# Review and status run before verification, so a finding that blocks costs
# no check run.
check_runs() { wc -l <"$project/.agent/.state/check-count" | tr -d ' '; }
runs_before=$(check_runs)
before=$(entries)
printf 'const amount = 5\n// const amount = 4;\n' >"$project/src/client.ts"
if checkpoint --checks test; then fail 'a blocking review finding let checkpoint complete'; fi
tail -1 "$scratch/err" | grep -q 'If the diff is the wrong range, pass the commit before your work with --base. Then run this call again$' || fail 'a blocked review did not name the next step'
grep -q 'diff review blocked' "$scratch/err" || fail 'the review block was not the reason checkpoint stopped'
[ "$(check_runs)" -eq "$runs_before" ] || fail 'verification ran before the diff review that blocked'
[ "$(entries)" -eq "$before" ] || fail 'a blocked review appended an entry'
printf 'const amount = 5\n' >"$project/src/client.ts"
cp "$project/.agent/scripts/status.conf" "$scratch/status.conf"
printf 'LOG_MAX_ENTRIES=0\n' >"$project/.agent/scripts/status.conf"
if checkpoint --checks test; then fail 'a blocking status finding let checkpoint complete'; fi
grep -q 'status findings block completion' "$scratch/err" || fail 'the status block was not the reason checkpoint stopped'
grep -q 'the advisory lines above block too: do what each says now, without asking first, then run this call again' "$scratch/err" \
  || fail 'a strict block on an advisory finding did not name the next step'
[ "$(check_runs)" -eq "$runs_before" ] || fail 'verification ran before the status check that blocked'
cp "$scratch/status.conf" "$project/.agent/scripts/status.conf"
if checkpoint; then fail 'checkpoint ran with no verification flag'; fi
grep -q 'Pass --checks' "$scratch/err" || fail 'a missing verification flag was not refused first'

# A session with nothing to run fills --checks with n/a, and that is --verify n/a.
before=$(entries)
checkpoint --checks n/a || { cat "$scratch/err" >&2; fail '--checks n/a was refused'; }
[ "$(entries)" -eq "$((before + 1))" ] || fail '--checks n/a wrote no entry'
tail -1 "$log" | grep -q 'verify: n/a' || fail '--checks n/a did not record verify n/a'
[ "$(check_runs)" -eq "$runs_before" ] || fail '--checks n/a ran a check'

# A current receipt beside --checks answers for its check without a second run.
printf 'const amount = 6\n' >"$project/src/client.ts"
printf 'fail\n' >"$project/.agent/scripts/test-mode"
before=$(entries)
if checkpoint --checks test; then fail 'a failing check completed the checkpoint'; fi
tail -1 "$scratch/err" | grep -Eq 'checks failed \(test\)\. Fix and run this call again, or record the final failure by adding --verification [^ ]+ --verify fail$' \
  || fail "a failed check did not name the next step: $(tail -1 "$scratch/err")"
receipt=$(sed -n 's/.* receipt=//p' "$scratch/out" | tail -1)
runs=$(check_runs)
checkpoint --checks test --verification "$receipt" --verify fail || { cat "$scratch/err" >&2; fail 'a current receipt beside --checks was refused'; }
[ "$(check_runs)" -eq "$runs" ] || fail 'a current receipt beside --checks ran the check again'
[ "$(entries)" -eq "$((before + 1))" ] || fail 'a current receipt beside --checks wrote no entry'
tail -1 "$log" | grep -q 'verify: fail' || fail 'a failed receipt beside --checks was not recorded as a failure'

# A stale receipt beside --checks runs the checks.
printf 'const amount = 7\n' >"$project/src/client.ts"
printf 'pass\n' >"$project/.agent/scripts/test-mode"
checkpoint --checks test --verification "$receipt" || { cat "$scratch/err" >&2; fail 'a stale receipt beside --checks did not fall back to the checks'; }
[ "$(check_runs)" -eq "$((runs + 1))" ] || fail 'a stale receipt beside --checks ran no check'
tail -1 "$log" | grep -q 'verify: pass' || fail 'the fallback check was not recorded as a pass'

# A receipt answers only for the check it records. One for another check
# does not stand in for a named check.
printf 'const amount = 9\n' >"$project/src/client.ts"
other=$(bash "$project/.agent/scripts/verify.sh" run lint --root "$project" 2>/dev/null | cut -f2)
runs=$(check_runs)
before=$(entries)
if checkpoint --checks test --verification "$other"; then fail 'a receipt for another check completed the checkpoint'; fi
[ "$(check_runs)" -eq "$((runs + 1))" ] || fail 'a receipt for another check kept the named check from running'
tail -1 "$scratch/err" | grep -q 'checks failed (lint)' || fail "the other check's failed receipt was not counted: $(tail -1 "$scratch/err")"
[ "$(entries)" -eq "$before" ] || fail 'a receipt for another check wrote an entry'

# A check that exits 0 and shows no test is not a failure of the work, and
# the refusal keeps the session away from the project's own test command.
printf 'const amount = 8\n' >"$project/src/client.ts"
printf 'silent\n' >"$project/.agent/scripts/test-mode"
before=$(entries)
if checkpoint --checks test; then fail 'a check that showed no test completed the checkpoint'; fi
tail -1 "$scratch/err" | grep -q "test exited 0 with no test count verify.sh reads, so nothing was logged\. Make the check driver run the runner with its TAP reporter or a summary that verify.sh --help lists\. Leave the project's own test command as it is\. Then run this call again$" \
  || fail "an uncounted check did not name the next step: $(tail -1 "$scratch/err")"
[ "$(entries)" -eq "$before" ] || fail 'an uncounted check wrote an entry'
printf 'mutate\n' >"$project/.agent/scripts/test-mode"
if checkpoint --checks test; then fail 'a check that changed project files completed the checkpoint'; fi
tail -1 "$scratch/err" | grep -q 'project files changed while test ran, or its output was lost, so nothing was logged\. Run this call again\. If it repeats, make the check write only where Git ignores$' \
  || fail "a check that changed files did not name the next step: $(tail -1 "$scratch/err")"
rm -f "$project/src/mutated.ts"
printf 'pass\n' >"$project/.agent/scripts/test-mode"

# --prove proves, logs, and removes a scratch test in the one closing call.
printf 'tmp/\n' >>"$project/.git/info/exclude"
mkdir -p "$project/tmp/scratch"
printf 'const amount = 9\n' >"$project/src/client.ts"
printf "grep -q 'amount = 9' src/client.ts\n" >"$project/tmp/scratch/amount.test.sh"
before=$(entries)
checkpoint --checks test --prove tmp/scratch/amount.test.sh || { cat "$scratch/err" >&2; fail '--prove did not complete the checkpoint'; }
[ "$(entries)" -eq "$((before + 1))" ] && tail -1 "$log" | grep -q 'verify: pass' || fail '--prove wrote no passing entry'
grep -q '^PROVED: test fails at [0-9a-f]* with tmp/scratch/amount.test.sh copied in$' "$scratch/out" || fail "--prove did not report the proof: $(cat "$scratch/out")"
[ ! -e "$project/tmp/scratch/amount.test.sh" ] || fail 'a proved scratch test was left behind'
! grep -q 'SCRATCH_LEFT\|TEST_COVERAGE' "$scratch/out" || fail "--prove still drew a prompt to prove or clean up: $(grep 'REVIEW:' "$scratch/out")"
printf 'const amount = 10\n' >"$project/src/client.ts"
printf "grep -q 'amount = 10' src/client.ts\n" >"$project/src/amount.test.sh"
checkpoint --checks test --prove src/amount.test.sh || { cat "$scratch/err" >&2; fail '--prove refused a kept test'; }
[ -f "$project/src/amount.test.sh" ] || fail 'a proved test that Git does not ignore was removed'
rm "$project/src/amount.test.sh"
printf 'const amount = 11\n' >"$project/src/client.ts"
printf 'true\n' >"$project/tmp/scratch/weak.test.sh"
before=$(entries)
if checkpoint --checks test --prove tmp/scratch/weak.test.sh; then fail 'a test that passes at the base completed the checkpoint'; fi
tail -1 "$scratch/err" | grep -q 'the check passes, but the proof did not hold, so nothing was logged\. Do what the verify.sh prove line above says, then run this call again\. To log without the proof, drop --prove$' \
  || fail "a proof that did not hold did not name the next step: $(tail -1 "$scratch/err")"
[ "$(entries)" -eq "$before" ] && [ -f "$project/tmp/scratch/weak.test.sh" ] || fail 'a proof that did not hold logged an entry or removed the test'
prove_rows=0
while IFS='|' read -r prove_want prove_args; do
  # shellcheck disable=SC2086
  if checkpoint $prove_args; then fail "--prove was accepted with: $prove_args"; fi
  tail -1 "$scratch/err" | grep -q "$prove_want" || fail "--prove with '$prove_args' ended on: $(tail -1 "$scratch/err")"
  prove_rows=$((prove_rows + 1))
done <<'ROWS'
prove needs --checks with one check name|--prove tmp/scratch/weak.test.sh
prove needs --checks with one check name|--checks test,test --prove tmp/scratch/weak.test.sh
prove and --verification were both given|--checks test --verification abc --prove tmp/scratch/weak.test.sh
prove and --verify were both given|--checks test --verify fail --prove tmp/scratch/weak.test.sh
ROWS
[ "$prove_rows" -eq 4 ] || fail "--prove usage rows ran: $prove_rows"
if checkpoint --checks test --prove ''; then fail 'an empty --prove logged a pass with no proof'; fi
tail -1 "$scratch/err" | grep -q 'prove holds an empty path' || fail "an empty --prove ended on: $(tail -1 "$scratch/err")"
rm -f "$project/tmp/scratch/weak.test.sh"
printf 'pass\n' >"$project/.agent/scripts/test-mode"

printf 'zero\n' >"$project/.agent/scripts/test-mode"
before=$(entries)
if checkpoint --checks test; then fail 'zero-test result did not stop automatic completion'; fi
tail -1 "$scratch/err" | grep -q 'test exited 0 and ran 0 tests, so nothing was logged\. Add or select a test for this change and run this call again\. If nothing here can be tested, pass --verify n/a without --checks$' \
  || fail "a zero-test run did not name the next step: $(tail -1 "$scratch/err")"
[ "$(entries)" -eq "$before" ] || fail 'zero tests wrote a premature entry'
checkpoint --checks test --verify fail || { cat "$scratch/err" >&2; fail 'explicit zero-test failure could not be recorded honestly'; }
tail -1 "$log" | grep -q 'verify: fail' || fail 'zero tests became a passing claim'
printf 'fail\n' >"$project/.agent/scripts/test-mode"
if checkpoint --checks test; then fail 'failing check did not stop automatic completion'; fi
checkpoint --checks test --verify fail || fail 'explicit failing verification could not be recorded'
tail -1 "$log" | grep -q 'verify: fail' || fail 'nonzero check became a passing claim'

printf 'LOG_MAX_ENTRIES=1\n' >"$project/.agent/scripts/status.conf"
before=$(entries)
if checkpoint --verify n/a; then fail 'strict policy ignored maintenance'; fi
[ "$(entries)" -eq "$before" ] || fail 'blocked maintenance appended an entry'
checkpoint --verify n/a --policy completion || fail 'completion policy blocked size-only maintenance'
before=$(entries)
mv "$project/.agent/memory.md" "$scratch/memory.md"
if checkpoint --verify n/a --policy completion; then fail 'completion policy ignored missing memory'; fi
[ "$(entries)" -eq "$before" ] || fail 'structurally invalid node appended an entry'
mv "$scratch/memory.md" "$project/.agent/memory.md"
printf 'LOG_MAX_ENTRIES=120\n' >"$project/.agent/scripts/status.conf"

# shellcheck source=../runtime.sh
. "$repo/scripts/runtime.sh"
da_lock "$project/.agent/.state/checkpoint.lock"
if DA_LOCK_WAIT_SECONDS=0 checkpoint --verify n/a; then fail 'live writer lock was ignored'; fi
tail -1 "$scratch/err" | grep -q 'Wait for it and run this call again' || fail 'a held lock did not name the next step'
da_unlock "$project/.agent/.state/checkpoint.lock"

mkdir "$scratch/bin"
real_mv=$(command -v mv)
cat >"$scratch/bin/mv" <<'EOF'
#!/usr/bin/env bash
last=""
for last in "$@"; do :; done
case "$last" in
  */.agent/session-log.md)
    if [ ! -e "$CHECKPOINT_FAULT_MARKER" ]; then
      : >"$CHECKPOINT_FAULT_MARKER"
      if [ "$CHECKPOINT_FAULT" = after ]; then "$CHECKPOINT_REAL_MV" "$@" || exit $?; fi
      exit 73
    fi ;;
esac
exec "$CHECKPOINT_REAL_MV" "$@"
EOF
chmod +x "$scratch/bin/mv"
for boundary in before after; do
  printf 'const boundary = "%s"\n' "$boundary" >"$project/src/client.ts"
  before=$(entries)
  if PATH="$scratch/bin:$PATH" CHECKPOINT_REAL_MV="$real_mv" CHECKPOINT_FAULT="$boundary" CHECKPOINT_FAULT_MARKER="$scratch/$boundary.fired" checkpoint --verify n/a; then
    fail "publication fault $boundary did not fire"
  fi
  checkpoint --verify n/a || { cat "$scratch/err" >&2; fail "recovery failed at $boundary"; }
  [ "$(entries)" -eq "$((before + 1))" ] || fail "recovery duplicated or lost the entry at $boundary"
done
# Every check's output lands in one tool result, so the checks share one
# OUTPUT_MAX_BYTES limit.
printf 'OUTPUT_MAX_BYTES=4000\n' >>"$project/.agent/scripts/verify.conf"
cat >"$project/.agent/scripts/checks.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
case "$1" in
  long1 | long2)
    i=1
    while [ "$i" -le 3000 ]; do printf '%s progress line %s of a long run\n' "$1" "$i"; i=$((i + 1)); done ;;
  *) exit 2 ;;
esac
EOF
printf 'const shared = 2\n' >"$project/src/client.ts"
checkpoint --checks long1,long2 || { cat "$scratch/err" >&2; fail 'two long checks could not checkpoint'; }
[ "$(wc -c <"$scratch/err" | tr -d ' ')" -le 4000 ] || fail "two long checks printed $(wc -c <"$scratch/err" | tr -d ' ') bytes, over the 4000-byte limit"
[ "$(grep -c 'over the 2000-byte limit' "$scratch/err")" -eq 2 ] || fail 'two checks did not each get half the limit'
grep -q '^3000| long1 progress line 3000 ' "$scratch/err" && grep -q '^3000| long2 progress line 3000 ' "$scratch/err" || fail 'a shared limit dropped the last line of a check'
printf 'const shared = 1\n' >"$project/src/client.ts"
checkpoint --checks long1 || { cat "$scratch/err" >&2; fail 'one long check could not checkpoint'; }
single=$(wc -c <"$scratch/err" | tr -d ' ')
[ "$single" -le 4000 ] && [ "$single" -gt 2000 ] || fail "one long check printed $single bytes, not the whole 4000-byte limit"
grep -q 'over the 4000-byte limit' "$scratch/err" || fail 'one check did not get the whole limit'

# Committed work: the base comes from the last recorded checkpoint.
later="$scratch/later"
mkdir -p "$later/src"
bash "$repo/scripts/node.sh" init --preset software-development --mode ignore-all "$later" >/dev/null
awk '/^## Quality bar/{q=1} q && /^## / && !/^## Quality bar/{q=0} q' "$later/.agent/rules/contract.md" >"$later/.agent/rules/quality-bar.md"
awk '/^## Quality bar/{q=1} q && /^## / && !/^## Quality bar/{q=0} !q' "$later/.agent/rules/contract.md" | sed 's/^\(- [A-Za-z][^:]*:\) <.*>$/\1 configured/' >"$scratch/contract"
cp "$scratch/contract" "$later/.agent/rules/contract.md"
git_later() { git -C "$later" -c user.name=fixture -c user.email=fixture@local -c commit.gpgsign=false "$@"; }
commit_later() { printf '%s\n' "$2" >"$later/src/$1"; git_later add -A; git_later commit -qm "$1"; }
later_log="$later/.agent/session-log.md"
later_entries() { awk '/^- \[/{n++} END{print n+0}' "$later_log"; }
checkpoint_later() {
  bash "$later/.agent/scripts/checkpoint.sh" --tool test --area fixture --summary 'Changed fixture behavior' "$@" "$later" >"$scratch/out" 2>"$scratch/err"
}
expect_entries() { [ "$(later_entries)" -eq "$1" ] || { cat "$scratch/out" "$scratch/err" >&2; fail "$2"; }; }
git_later init -q
git_later add -A
git_later commit -q --allow-empty -m fixture
commit_later first.ts 'const first = 1'
if checkpoint_later --verify n/a; then fail 'a clean tree with no earlier checkpoint was accepted'; fi
tail -1 "$scratch/err" | grep -q 'no earlier checkpoint marks where this work began. Run this call again with --base <the commit before your work>' || fail 'a first checkpoint over committed work did not ask for --base'
checkpoint_later --verify n/a --base HEAD~1 || fail 'an explicit base was refused'
expect_entries 1 'an explicit base did not record'
checkpoint_later --verify n/a || fail 'a clean tree with nothing new did not exit 0'
grep -q 'nothing to record since the last checkpoint' "$scratch/out" || fail 'a clean tree with nothing new did not say so'
expect_entries 1 'a clean tree with nothing new logged an entry'
one=$(git -C "$later" rev-parse HEAD)
commit_later second.ts 'const second = 2'
checkpoint_later --verify n/a || { cat "$scratch/err" >&2; fail 'a commit after a checkpoint was refused'; }
grep -q "using --base ${one:0:12}: 1 commit since the last checkpoint" "$scratch/out" || fail 'the inferred base was not named'
expect_entries 2 'a commit after a checkpoint did not record'
checkpoint_later --verify n/a || fail 'a rerun over inferred work did not exit 0'
expect_entries 2 'a rerun over inferred work logged twice'
commit_later third.ts '// const third = 2;'
commit_later fourth.ts 'const fourth = 4'
if checkpoint_later --verify n/a; then fail 'the review did not cover the older of two commits'; fi
grep -q ': 2 commits since the last checkpoint' "$scratch/out" || fail 'the count did not say two commits'
grep -q 'third.ts' "$scratch/out" "$scratch/err" || fail 'the review did not name the older commit'
commit_later third.ts 'const third = 3'
checkpoint_later --verify n/a || fail 'two fixed commits were refused'
expect_entries 3 'two commits did not record one entry'
# The same content, recorded before its commit, is not recorded again after it.
printf 'const fifth = 5\n' >"$later/src/fifth.ts"
printf 'const first = 10\n' >"$later/src/first.ts"
rm "$later/src/second.ts"
checkpoint_later --verify n/a || fail 'uncommitted work was refused'
expect_entries 4 'uncommitted work did not record'
git_later add -A
git_later commit -qm 'the recorded work'
checkpoint_later --verify n/a || fail 'committing recorded work was refused'
grep -q 'nothing to record since the last checkpoint' "$scratch/out" || fail 'committing recorded work was not recognized'
expect_entries 4 'committing recorded work logged it twice'
# A leftover untracked file does not hide committed work.
printf 'leftover\n' >"$later/leftover.txt"
commit_side() { printf '%s\n' "$2" >"$later/src/$1"; git_later add src; git_later commit -qm "$1"; }
commit_side hidden.ts '// const hidden = 1;'
if checkpoint_later --verify n/a; then fail 'a leftover file hid a commit from the review'; fi
grep -q 'hidden.ts' "$scratch/out" "$scratch/err" || fail 'the review beside a leftover file did not name the committed file'
printf 'const hidden = 1\n' >"$later/src/hidden.ts"
checkpoint_later --verify n/a || { cat "$scratch/err" >&2; fail 'a commit and its uncommitted fix were refused'; }
expect_entries 5 'a commit and its uncommitted fix did not record one entry'
git_later add src
git_later commit -qm 'the recorded fix'
checkpoint_later --verify n/a || fail 'a recorded fix was refused after its commit'
grep -q 'nothing to record since the last checkpoint' "$scratch/out" || fail 'a recorded fix beside a leftover file was not recognized'
# The named rerun records an ignored node change beside a recorded leftover.
printf -- '- another rule\n' >>"$later/.agent/rules/learned.md"
if checkpoint_later --verify n/a; then fail 'an ignored node change beside a leftover was recorded without --node-only'; fi
tail -1 "$scratch/err" | grep -q 'Run this call again with --node-only$' || fail 'an ignored node change beside a leftover did not name --node-only'
checkpoint_later --verify n/a --node-only || { cat "$scratch/err" >&2; fail 'the two refusals point at each other'; }
expect_entries 6 'a node change beside a leftover did not record'
rm "$later/leftover.txt"
checkpoint_later --verify n/a || { cat "$scratch/err" >&2; fail 'removing a leftover file was refused'; }
later_start=$(later_entries)
# Work recorded and then committed logs once, and new work beside it once.
printf 'const hidden = 2\n' >"$later/src/hidden.ts"
checkpoint_later --verify n/a || fail 'uncommitted work was refused'
git_later add src
git_later commit -qm 'the recorded second fix'
printf 'const hidden = 3\n' >"$later/src/hidden.ts"
checkpoint_later --verify n/a || fail 'new uncommitted work after a recorded commit was refused'
expect_entries $((later_start + 2)) 'new uncommitted work after a recorded commit did not record'
# A rerun after an inferred base is covered, with uncommitted work in it too.
printf 'const hidden = 4\n' >"$later/src/hidden.ts"
git_later commit -qam 'unrecorded'
printf 'const hidden = 5\n' >"$later/src/hidden.ts"
checkpoint_later --verify n/a || fail 'a commit and an uncommitted change were refused'
grep -q 'using --base' "$scratch/out" || fail 'an unrecorded commit got no base'
expect_entries $((later_start + 3)) 'a commit and an uncommitted change did not record one entry'
checkpoint_later --verify n/a || fail 'a rerun after an inferred base was refused'
expect_entries $((later_start + 3)) 'a rerun after an inferred base logged twice'
# A mode change is work.
git_later commit -qam 'recorded'
chmod +x "$later/src/hidden.ts"
git_later commit -qam 'mode'
checkpoint_later --verify n/a || fail 'a mode change was refused'
expect_entries $((later_start + 4)) 'a committed mode change was not recorded'
# --node-only reviews no commit, so it does not move past one.
commit_later unseen.ts '// const unseen = 1;'
printf -- '- a third rule\n' >>"$later/.agent/rules/learned.md"
checkpoint_later --verify n/a --node-only || fail '--node-only beside a commit was refused'
if checkpoint_later --verify n/a; then fail '--node-only hid a commit from the next review'; fi
grep -q 'unseen.ts' "$scratch/out" "$scratch/err" || fail 'the review after --node-only did not name the commit'
commit_later unseen.ts 'const unseen = 1'
checkpoint_later --verify n/a || fail 'the fixed commit was refused'
# What the review did not read is new to the next call.
cat >"$later/.agent/scripts/checks.sh" <<'EOF'
#!/usr/bin/env bash
printf '// const made = 1;\n' >src/made.ts
printf 'TAP version 13\n1..1\nok 1 - fixture\n# tests 1\n'
EOF
printf 'const ok = 1\n' >"$later/src/ok.ts"
checkpoint_later --checks test --verify fail || { cat "$scratch/err" >&2; fail 'a check that writes a file could not be recorded as failed'; }
git_later add -A
git_later commit -qm 'made by the check'
if checkpoint_later --verify n/a; then fail 'a file the check wrote was never reviewed'; fi
grep -q 'made.ts' "$scratch/out" "$scratch/err" || fail 'the review did not name the file the check wrote'
git_later rm -q src/made.ts
git_later commit -qm 'removed'
checkpoint_later --verify n/a || { cat "$scratch/err" >&2; fail 'the fixed tree was refused'; }
# An untracked repository with no commits does not hide other work.
git init -q "$later/vendor-empty"
printf '// const bad = 1;\n' >"$later/src/bad.ts"
if checkpoint_later --verify n/a; then fail 'an embedded empty repository hid unreviewed work'; fi
rm -rf "$later/vendor-empty" "$later/src/bad.ts"
# A status configuration that hides untracked files does not hide work.
git_later config status.showUntrackedFiles no
printf 'const extra = 1\n' >"$later/src/extra.ts"
before=$(later_entries)
checkpoint_later --verify n/a || fail 'an untracked file was refused'
expect_entries $((before + 1)) 'a status setting hid an untracked file'
git_later config --unset status.showUntrackedFiles
git_later add -A
git_later commit -qm extra
later_start=$(later_entries)
# An ignored node file: git shows nothing, and --node-only records it.
printf -- '- a rule written by hand\n' >>"$later/.agent/rules/learned.md"
if checkpoint_later --verify n/a; then fail 'an ignored node change was recorded without --node-only'; fi
tail -1 "$scratch/err" | grep -q 'node files changed since the last checkpoint. Run this call again with --node-only$' || { cat "$scratch/err" >&2; fail 'an ignored node change did not name --node-only'; }
checkpoint_later --verify n/a --node-only || { cat "$scratch/err" >&2; fail 'the named rerun did not record'; }
expect_entries $((later_start + 1)) 'the named rerun did not append one entry'
printf 'const x = 1\n' >"$later/.agent/ignored-note.txt"
checkpoint_later --verify n/a --node-only || fail 'a new ignored file could not be recorded'
rm "$later/.agent/ignored-note.txt"
if checkpoint_later --verify n/a; then fail 'a deleted ignored node file was not seen'; fi
checkpoint_later --verify n/a --node-only || fail 'a deleted ignored node file could not be recorded'
later_start=$(($(later_entries) - 1))
printf 'anything\n' >"$later/.agent/.state/unrelated"
checkpoint_later --verify n/a || fail 'private state counted as a node change'
expect_entries $((later_start + 1)) 'private state logged an entry'
# An entry written by log.sh is not work to checkpoint.
bash "$later/.agent/scripts/log.sh" --tool test --area fixture --verify n/a --summary 'A direct entry' "$later" >/dev/null
checkpoint_later --verify n/a || fail 'a direct log entry counted as a node change'
expect_entries $((later_start + 2)) 'a direct log entry led to another one'
# A rewritten history leaves the recorded commit off this branch.
commit_later amended.ts 'const amended = 1'
checkpoint_later --verify n/a || fail 'a commit before the amend was refused'
checkpoint_later --verify n/a || fail 'recorded work was refused'
git_later commit -q --amend -m 'only the message'
before=$(later_entries)
checkpoint_later --verify n/a || fail 'amending only a message was refused'
expect_entries "$before" 'amending only a message logged again'
printf 'const amended = 2\n' >"$later/src/amended.ts"
git_later commit -qa --amend -m 'rewritten'
if checkpoint_later --verify n/a; then fail 'a base was inferred across a rewritten history'; fi
grep -q 'using --base' "$scratch/out" && fail 'a base was inferred across a rewritten history'
tail -1 "$scratch/err" | grep -q 'Run this call again with --base' || fail 'a rewritten history did not ask for --base'
# A linked worktree that shares the node keeps its own mark.
checkpoint_later --verify n/a --base HEAD~1 || fail 'the rewritten commit could not be recorded'
git_later worktree add -q -b side "$scratch/side" >/dev/null 2>&1
ln -s "$later/.agent" "$scratch/side/.agent"
printf 'const side = 1\n' >"$scratch/side/src/side.ts"
git -C "$scratch/side" add src
git -C "$scratch/side" -c user.name=fixture -c user.email=fixture@local -c commit.gpgsign=false commit -qm side
bash "$later/.agent/scripts/checkpoint.sh" --tool test --area fixture --summary 'Side work' --verify n/a --base HEAD~1 "$scratch/side" >"$scratch/out" 2>"$scratch/err" || { cat "$scratch/err" >&2; fail 'a shared-node worktree could not checkpoint'; }
commit_later sixth.ts 'const sixth = 6'
checkpoint_later --verify n/a || fail 'a sibling worktree moved this one'
grep -q ': 1 commit since the last checkpoint' "$scratch/out" || { cat "$scratch/out" >&2; fail 'a sibling worktree moved the mark'; }

bash "$later/.agent/scripts/memory.sh" new --slug side --title Side --hook side --fact 'a side fact' "$scratch/side" >/dev/null
bash "$later/.agent/scripts/checkpoint.sh" --tool test --area fixture --summary 'Side fact' --verify n/a --node-only "$scratch/side" >"$scratch/out" 2>"$scratch/err" || { cat "$scratch/err" >&2; fail 'a side fact could not be recorded'; }
before=$(later_entries)
printf -- '- a side rule\n' >>"$later/.agent/rules/learned.md"
bash "$later/.agent/scripts/checkpoint.sh" --tool test --area fixture --summary 'Side rule' --verify n/a --node-only "$scratch/side" >"$scratch/out" 2>"$scratch/err" || fail 'a second node write from the side was refused'
expect_entries $((before + 1)) 'a node write behind the link read as unchanged'
checkpoint_later --verify n/a --node-only || fail 'a node write the side recorded was refused with --node-only'
[ "$(later_entries)" -eq "$((before + 1))" ] || fail 'a node write the side recorded was logged again with --node-only'
before=$(later_entries)
checkpoint_later --verify n/a || { cat "$scratch/err" >&2; fail 'a node write the side recorded was asked of this worktree'; }
expect_entries "$before" 'a node write the side recorded was logged again'
# The side worktree sees its own commits, with .agent as an untracked link.
printf '// const side = 1;\n' >"$scratch/side/src/side.ts"
git -C "$scratch/side" add src
git -C "$scratch/side" -c user.name=fixture -c user.email=fixture@local -c commit.gpgsign=false commit -qm side-two
side_checkpoint() { bash "$later/.agent/scripts/checkpoint.sh" --tool test --area fixture --summary 'Side work' --verify n/a "$scratch/side" >"$scratch/out" 2>"$scratch/err"; }
if side_checkpoint; then fail 'a commit in a shared-node worktree was not reviewed'; fi
printf 'const side = 2\n' >"$scratch/side/src/side.ts"
side_checkpoint || { cat "$scratch/err" >&2; fail 'a fixed commit in a shared-node worktree was refused'; }
before=$(later_entries)
side_checkpoint || fail 'a rerun in a shared-node worktree was refused'
expect_entries "$before" 'a rerun in a shared-node worktree logged twice'

# A worktree that finishes another one's interrupted entry keeps its own mark.
commit_later own.ts '// const own = 1;'
printf 'const side = 3\n' >"$scratch/side/src/side.ts"
if PATH="$scratch/bin:$PATH" CHECKPOINT_REAL_MV="$real_mv" CHECKPOINT_FAULT=after CHECKPOINT_FAULT_MARKER="$scratch/side.fired" side_checkpoint; then fail 'the publication fault in the side worktree did not fire'; fi
before=$(later_entries)
if checkpoint_later --verify n/a; then fail "recovering another worktree's entry hid a commit from the review"; fi
grep -q 'own.ts' "$scratch/out" "$scratch/err" || fail 'the review after a foreign recovery did not name the commit'
commit_later own.ts 'const own = 1'
checkpoint_later --verify n/a || fail 'the fixed commit after a foreign recovery was refused'
expect_entries $((before + 1)) 'a foreign recovery lost or duplicated an entry'
side_checkpoint || { cat "$scratch/err" >&2; fail 'the recovered worktree was refused'; }
expect_entries $((before + 1)) 'the recovered worktree logged its entry again'

# A root below the repository top, tracked log included, with odd file names.
mono="$scratch/mono"
mkdir -p "$mono/pkg/src" "$mono/src"
cp -R "$project/.agent" "$mono/pkg/.agent"
rm -rf "$mono/pkg/.agent/.state"
printf 'const top = 1\n' >"$mono/src/a.ts"
printf 'const a = 1\n' >"$mono/pkg/src/a.ts"
git -C "$mono" init -q
git_mono() { git -C "$mono" -c user.name=fixture -c user.email=fixture@local -c commit.gpgsign=false "$@"; }
git_mono add -A
git_mono commit -qm base
mono_checkpoint() { bash "$mono/pkg/.agent/scripts/checkpoint.sh" --tool test --area fixture --summary 'Package work' --verify n/a --policy completion "$mono/pkg" >"$scratch/out" 2>"$scratch/err"; }
mono_entries() { awk '/^- \[/{n++} END{print n+0}' "$mono/pkg/.agent/session-log.md"; }
printf 'const a = 2\n' >"$mono/pkg/src/a.ts"
printf 'const q = 1\n' >"$mono/pkg/src/\"q\" ü.ts"
mono_checkpoint || { cat "$scratch/out" "$scratch/err" >&2; fail 'a nested root could not checkpoint'; }
[ ! -s "$scratch/err" ] || { cat "$scratch/err" >&2; fail 'a nested root printed an error and recorded'; }
before=$(mono_entries)
git_mono add -A
git_mono commit -qm recorded
mono_checkpoint || fail 'a nested root refused recorded work'
[ "$(mono_entries)" -eq "$before" ] || fail 'a nested root logged recorded work twice'
printf '// const a = 2;\n' >"$mono/pkg/src/a.ts"
git_mono commit -qam bad
if mono_checkpoint; then fail 'a nested root skipped the review of a commit'; fi
printf 'const a = 3\n' >"$mono/pkg/src/a.ts"
git_mono commit -qam fixed
mono_checkpoint || { cat "$scratch/err" >&2; fail 'a nested root refused a fixed commit'; }
[ "$(mono_entries)" -eq "$((before + 1))" ] || fail 'a nested root did not record a fixed commit once'
mono_checkpoint || fail 'a nested root refused a rerun'
[ "$(mono_entries)" -eq "$((before + 1))" ] || fail 'a tracked session log counted as new work'
[ -z "$(git -C "$mono" status --porcelain -- pkg/src)" ] || fail 'a checkpoint changed the index'
# Names that break a line, and a type change, keep the digest exact.
printf 'const one = 1\n' >"$mono/pkg/src/one.ts"
printf 'const two = 2\n' >"$mono/pkg/src/two.ts"
printf 'x\n' >"$mono/pkg/src/a
b.txt"
mkdir "$mono/pkg/src/kind"
printf 'k\n' >"$mono/pkg/src/kind/k.txt"
mono_checkpoint || { cat "$scratch/err" >&2; fail 'a file name with a newline was refused'; }
git_mono add -A
git_mono commit -qm names
before=$(mono_entries)
mono_checkpoint || fail 'recorded odd names were refused after their commit'
[ "$(mono_entries)" -eq "$before" ] || fail 'recorded odd names were logged twice'
printf '// const one = 1;\n' >"$mono/pkg/src/two.ts"
if mono_checkpoint; then fail 'a file name with a newline hid a change'; fi
printf 'const one = 1\n' >"$mono/pkg/src/two.ts"
printf 'const two = 2\n' >"$mono/pkg/src/one.ts"
rm -r "$mono/pkg/src/kind"
ln -s one.ts "$mono/pkg/src/kind"
mono_checkpoint || fail 'swapped files were refused'
[ "$(mono_entries)" -eq "$((before + 1))" ] || fail 'swapped file contents read as recorded'
git_mono add -A
git_mono commit -qm swapped
mono_checkpoint || fail 'a recorded type change was refused after its commit'
[ "$(mono_entries)" -eq "$((before + 1))" ] || fail 'a recorded type change was logged twice'

# --prove takes its base from the review, so committed work is proved against
# the commit before it. A proof that could not run is no proof.
proved="$scratch/proved"
mkdir -p "$proved/src" "$proved/tmp/scratch"
bash "$repo/scripts/node.sh" init --preset software-development --mode ignore-all "$proved" >/dev/null
cp "$later/.agent/rules/contract.md" "$later/.agent/rules/quality-bar.md" "$proved/.agent/rules/"
cat >"$proved/.agent/scripts/checks.sh" <<'EOF'
#!/usr/bin/env bash
[ -z "${DA_PROVE:-}" ] || [ ! -f "$DA_PROVE_MAIN/tmp/stop-control" ] || { echo 'the checkout cannot run this'; exit 1; }
for scratch_test in tmp/scratch/*.test.sh; do
  [ -f "$scratch_test" ] || continue
  bash "$scratch_test" || { printf 'TAP version 13\n1..1\nnot ok 1 - %s\n' "$scratch_test"; exit 1; }
done
printf 'TAP version 13\n1..1\nok 1 - fixture\n'
EOF
git_proved() { git -C "$proved" -c user.name=fixture -c user.email=fixture@local -c commit.gpgsign=false "$@"; }
checkpoint_proved() {
  bash "$proved/.agent/scripts/checkpoint.sh" --tool test --area fixture --summary 'Changed fixture behavior' "$@" "$proved" >"$scratch/out" 2>"$scratch/err"
}
git_proved init -q
printf 'tmp/\n' >>"$proved/.git/info/exclude"
printf 'const value = 1\n' >"$proved/src/value.ts"
git_proved add -A
git_proved commit -qm fixture
printf 'const value = 2\n' >"$proved/src/value.ts"
git_proved add -A
git_proved commit -qm second
checkpoint_proved --verify n/a --base HEAD~1 || { cat "$scratch/err" >&2; fail 'the proved fixture did not record its first checkpoint'; }
proved_mark=$(git -C "$proved" rev-parse HEAD)
printf 'const value = 3\n' >"$proved/src/value.ts"
git_proved add -A
git_proved commit -qm work
printf "grep -q 'value = 3' src/value.ts\n" >"$proved/tmp/scratch/value.test.sh"
checkpoint_proved --checks test --prove tmp/scratch/value.test.sh || { cat "$scratch/err" >&2; fail 'committed work was not proved against the commit before it'; }
grep -q "^PROVED: test fails at ${proved_mark:0:12} with tmp/scratch/value.test.sh copied in$" "$scratch/out" || fail "the proof did not use the review's base: $(grep PROVED "$scratch/out")"
printf 'const value = 4\n' >"$proved/src/value.ts"
printf "grep -q 'value = 4' src/value.ts\n" >"$proved/tmp/scratch/value.test.sh"
: >"$proved/tmp/stop-control"
proved_before=$(awk '/^- \[/{n++} END{print n+0}' "$proved/.agent/session-log.md")
if checkpoint_proved --checks test --prove tmp/scratch/value.test.sh; then fail 'a proof that could not run completed the checkpoint'; fi
tail -1 "$scratch/err" | grep -q 'the proof did not hold, so nothing was logged' || fail "a proof that could not run ended on: $(tail -1 "$scratch/err")"
[ "$(awk '/^- \[/{n++} END{print n+0}' "$proved/.agent/session-log.md")" -eq "$proved_before" ] || fail 'a proof that could not run logged an entry'
[ -z "${proved_failures:-}" ] || exit 1
printf 'checkpoint-v63: verification, stale evidence, deduplication, policies, locking, and publication recovery passed\n'
