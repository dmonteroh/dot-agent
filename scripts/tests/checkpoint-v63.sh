#!/usr/bin/env bash
set -eu
unset CDPATH
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/checkpoint-v63.XXXXXX")
scratch=$(cd "$scratch" && pwd -P)
trap 'rm -rf "$scratch"' EXIT
fail() { echo "FAIL checkpoint-v63: $*" >&2; exit 1; }
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
mode=$(cat .agent/scripts/test-mode)
case "$mode" in
  pass) printf 'TAP version 13\n1..1\nok 1 - fixture\n# tests 1\n' ;;
  zero) printf 'TAP version 13\n1..0\n# tests 0\n' ;;
  fail) printf 'TAP version 13\n1..1\nnot ok 1 - fixture\n# tests 1\n'; exit 9 ;;
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
[ "$(entries)" -eq 1 ] || fail 'stale receipt appended a log entry'

# Review and status run before verification, so a finding that blocks costs
# no check run.
check_runs() { wc -l <"$project/.agent/.state/check-count" | tr -d ' '; }
runs_before=$(check_runs)
before=$(entries)
printf 'const amount = 5\n// const amount = 4;\n' >"$project/src/client.ts"
if checkpoint --checks test; then fail 'a blocking review finding let checkpoint complete'; fi
grep -q 'diff review blocked' "$scratch/err" || fail 'the review block was not the reason checkpoint stopped'
[ "$(check_runs)" -eq "$runs_before" ] || fail 'verification ran before the diff review that blocked'
[ "$(entries)" -eq "$before" ] || fail 'a blocked review appended an entry'
printf 'const amount = 5\n' >"$project/src/client.ts"
cp "$project/.agent/scripts/status.conf" "$scratch/status.conf"
printf 'LOG_MAX_ENTRIES=0\n' >"$project/.agent/scripts/status.conf"
if checkpoint --checks test; then fail 'a blocking status finding let checkpoint complete'; fi
grep -q 'status findings block completion' "$scratch/err" || fail 'the status block was not the reason checkpoint stopped'
[ "$(check_runs)" -eq "$runs_before" ] || fail 'verification ran before the status check that blocked'
cp "$scratch/status.conf" "$project/.agent/scripts/status.conf"
if checkpoint; then fail 'checkpoint ran with no verification flag'; fi
grep -q 'supply --checks' "$scratch/err" || fail 'a missing verification flag was not refused first'

printf 'zero\n' >"$project/.agent/scripts/test-mode"
before=$(entries)
if checkpoint --checks test; then fail 'zero-test result did not stop automatic completion'; fi
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
if checkpoint --verify n/a; then fail 'live writer lock was ignored'; fi
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

printf 'checkpoint-v63: verification, stale evidence, deduplication, policies, locking, and publication recovery passed\n'
