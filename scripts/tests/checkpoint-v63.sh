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
contract="$project/.agents/rules/contract.md"
awk '/^## Quality bar/{q=1} q && /^## / && !/^## Quality bar/{q=0} q' "$contract" >"$project/.agents/rules/quality-bar.md"
awk '/^## Quality bar/{q=1} q && /^## / && !/^## Quality bar/{q=0} !q' "$contract" >"$scratch/contract"
sed 's/^\(- [A-Za-z][^:]*:\) <.*>$/\1 configured/' "$scratch/contract" >"$contract"
cat >"$project/.agents/scripts/checks.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
[ "$1" = test ] || exit 2
state="$PWD/.agents/.state"
mkdir -p "$state"
printf 'run\n' >>"$state/check-count"
mode=$(cat .agents/scripts/test-mode)
case "$mode" in
  pass) printf 'TAP version 13\n1..1\nok 1 - fixture\n# tests 1\n' ;;
  zero) printf 'TAP version 13\n1..0\n# tests 0\n' ;;
  fail) printf 'TAP version 13\n1..1\nnot ok 1 - fixture\n# tests 1\n'; exit 9 ;;
esac
EOF
printf 'pass\n' >"$project/.agents/scripts/test-mode"
printf 'const amount = 1\n' >"$project/src/client.ts"
git -C "$project" init -q
git -C "$project" add .
git -C "$project" -c user.name=fixture -c user.email=fixture@local -c commit.gpgsign=false commit -qm fixture
checkpoint="$project/.agents/scripts/checkpoint.sh"
log="$project/.agents/session-log.md"
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
[ "$(wc -l <"$project/.agents/.state/check-count" | tr -d ' ')" -eq 1 ] || fail 'identical retry reran verification'

printf 'const amount = 3\n' >"$project/src/client.ts"
receipt_record=$(bash "$project/.agents/scripts/verify.sh" run test --root "$project" 2>"$scratch/verify.err")
receipt=$(printf '%s\n' "$receipt_record" | cut -f2)
printf 'const amount = 4\n' >"$project/src/client.ts"
if checkpoint --verification "$receipt"; then fail 'stale receipt was accepted'; fi
[ "$(entries)" -eq 1 ] || fail 'stale receipt appended a log entry'

printf 'zero\n' >"$project/.agents/scripts/test-mode"
before=$(entries)
if checkpoint --checks test; then fail 'zero-test result did not stop automatic completion'; fi
[ "$(entries)" -eq "$before" ] || fail 'zero tests wrote a premature entry'
checkpoint --checks test --verify fail || { cat "$scratch/err" >&2; fail 'explicit zero-test failure could not be recorded honestly'; }
tail -1 "$log" | grep -q 'verify: fail' || fail 'zero tests became a passing claim'
printf 'fail\n' >"$project/.agents/scripts/test-mode"
if checkpoint --checks test; then fail 'failing check did not stop automatic completion'; fi
checkpoint --checks test --verify fail || fail 'explicit failing verification could not be recorded'
tail -1 "$log" | grep -q 'verify: fail' || fail 'nonzero check became a passing claim'

printf 'LOG_MAX_ENTRIES=1\n' >"$project/.agents/scripts/status.conf"
before=$(entries)
if checkpoint --verify n/a; then fail 'strict policy ignored maintenance'; fi
[ "$(entries)" -eq "$before" ] || fail 'blocked maintenance appended an entry'
checkpoint --verify n/a --policy completion || fail 'completion policy blocked size-only maintenance'
before=$(entries)
mv "$project/.agents/memory.md" "$scratch/memory.md"
if checkpoint --verify n/a --policy completion; then fail 'completion policy ignored missing memory'; fi
[ "$(entries)" -eq "$before" ] || fail 'structurally invalid node appended an entry'
mv "$scratch/memory.md" "$project/.agents/memory.md"
printf 'LOG_MAX_ENTRIES=120\n' >"$project/.agents/scripts/status.conf"

# shellcheck source=../runtime.sh
. "$repo/scripts/runtime.sh"
da_lock "$project/.agents/.state/checkpoint.lock"
if checkpoint --verify n/a; then fail 'live writer lock was ignored'; fi
da_unlock "$project/.agents/.state/checkpoint.lock"

mkdir "$scratch/bin"
real_mv=$(command -v mv)
cat >"$scratch/bin/mv" <<'EOF'
#!/usr/bin/env bash
last=""
for last in "$@"; do :; done
case "$last" in
  */.agents/session-log.md)
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
printf 'checkpoint-v63: verification, stale evidence, deduplication, policies, locking, and publication recovery passed\n'
