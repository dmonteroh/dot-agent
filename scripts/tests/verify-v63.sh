#!/usr/bin/env bash
set -u
export LC_ALL=C
unset CDPATH

here=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/verify-v63.XXXXXX") || exit 1
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT HUP INT TERM
pass=0
fail=0

ok() { pass=$((pass + 1)); printf 'ok %s - %s\n' "$pass" "$1"; }
bad() { fail=$((fail + 1)); printf 'not ok - %s\n' "$1"; }
expect_rc() {
  er_want=$1 er_name=$2; shift 2
  "$@" >"$tmp/stdout" 2>"$tmp/stderr"; er_got=$?
  if [ "$er_got" -eq "$er_want" ]; then ok "$er_name"; else
    bad "$er_name (wanted $er_want, got $er_got)"
    sed 's/^/# stdout: /' "$tmp/stdout"; sed 's/^/# stderr: /' "$tmp/stderr"
  fi
}
has() { grep -Eq "$1" "$2"; }

new_git() {
  ng_root=$1
  mkdir -p "$ng_root/.agent/scripts" "$ng_root/src"
  cp "$here/verify.sh" "$here/runtime.sh" "$ng_root/.agent/scripts/"
  cat >"$ng_root/.agent/scripts/verify.conf" <<'EOF'
CHECK_DRIVER=.agent/scripts/checks.sh
POSITIVE_TEST_CHECKS=test,zero,unknown,nested,node,planonly,missing,numbering,duplicate,malformed,mutate,timeout
TEST_COUNT_FORMAT=tap
TIMEOUT_SECONDS=5
EOF
  cat >"$ng_root/src/input.txt" <<'EOF'
input
EOF
  git -C "$ng_root" init -q
  git -C "$ng_root" config user.email test@example.invalid
  git -C "$ng_root" config user.name Test
}

write_driver() {
  wd_root=$1
  cat >"$wd_root/.agent/scripts/checks.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  test) printf 'TAP version 13\n1..2\nok 1 - one\nok 2 - two\n' ;;
  zero) printf 'TAP version 13\n1..0\n' ;;
  unknown) printf 'ok 1 - no plan\n' ;;
  nested) printf '    1..4\n    ok 1 - nested\n' ;;
  node) printf 'TAP version 13\n# Subtest: child\n    1..1\n    ok 1 - child result\nok 1 - child\n1..1\n' ;;
  planonly) printf 'TAP version 13\n1..2\n' ;;
  missing) printf 'TAP version 13\nok 1 - one\n1..2\n' ;;
  numbering) printf 'TAP version 13\nok 1 - one\nok 3 - three\n1..2\n' ;;
  duplicate) printf '1..1\nok 1 - one\n1..1\n' ;;
  malformed) printf '1..wat\nok 1 - unknown plan\n' ;;
  fail) printf '1..1\nnot ok 1 - failure\n'; exit 7 ;;
  mutate) printf 'changed\n' >>src/input.txt; printf '1..1\nok 1 - mutation\n' ;;
  timeout)
    sleep 30 &
    printf '%s\n' "$!" >.agent/.state/timeout-child.pid
    wait ;;
  *) exit 9 ;;
esac
EOF
  chmod +x "$wd_root/.agent/scripts/checks.sh"
}

root="$tmp/project with spaces"
new_git "$root"
write_driver "$root"
mkdir -p "$root/.agent/.state" "$root/src/dir with spaces"
printf 'space\n' >"$root/src/dir with spaces/a file.txt"
git -C "$root" add .
git -C "$root" commit -qm initial
verify="$root/.agent/scripts/verify.sh"

version=$(bash "$verify" --version)
printf '%s\n' "$version" | grep -qF 'dot-agent v6.3' \
  && printf '%s\n' "$version" | grep -qF 'receipt schema 2' \
  && ok "version identifies dot-agent and receipt schema" || bad "incomplete version output: $version"

expect_rc 0 "genuine TAP success and paths with spaces" bash "$verify" run test --root "$root"
record=$(cat "$tmp/stdout"); receipt_id=$(printf '%s\n' "$record" | awk -F '\t' '{print $2}')
if printf '%s\n' "$record" | grep -Eq '^receipt\t[^[:space:]]+\tpass\ttest\t0\t2$'; then ok "success result record"; else bad "success result record: $record"; fi
expect_rc 0 "current receipt validates" bash "$verify" check "$receipt_id" --root "$root"
receipt_file="$root/.agent/.state/receipts/$receipt_id.receipt"
has '^worktree=' "$receipt_file" && has '^invocation=' "$receipt_file" && has '^executed_at=[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$receipt_file" \
  && ok "receipt stores worktree, invocation, and execution time" || bad "receipt metadata is incomplete"
expect_rc 2 "receipt paths are rejected in favor of opaque ids" bash "$verify" check "$receipt_file" --root "$root"
cp "$root/.agent/scripts/checks.sh" "$root/.agent/scripts/checks-alt.sh"
sed 's#CHECK_DRIVER=.agent/scripts/checks.sh#CHECK_DRIVER=.agent/scripts/checks-alt.sh#' "$root/.agent/scripts/verify.conf" >"$root/.agent/scripts/verify.conf.tmp" && mv "$root/.agent/scripts/verify.conf.tmp" "$root/.agent/scripts/verify.conf"
expect_rc 2 "receipt is bound to exact configured driver invocation" bash "$verify" check "$receipt_id" --root "$root"
has 'driver invocation does not match' "$tmp/stderr" && ok "driver mismatch is diagnosed before generic staleness" || bad "driver mismatch diagnostic is missing"
sed 's#CHECK_DRIVER=.agent/scripts/checks-alt.sh#CHECK_DRIVER=.agent/scripts/checks.sh#' "$root/.agent/scripts/verify.conf" >"$root/.agent/scripts/verify.conf.tmp" && mv "$root/.agent/scripts/verify.conf.tmp" "$root/.agent/scripts/verify.conf"
rm -f "$root/.agent/scripts/checks-alt.sh"

expect_rc 1 "nonzero check fails" bash "$verify" run fail --root "$root"
has '^receipt\t.*\tfail\tfail\t7\t1$' "$tmp/stdout" && ok "nonzero result preserves exit" || bad "nonzero result preserves exit"
fail_id=$(awk -F '\t' '{print $2}' "$tmp/stdout")
expect_rc 0 "current failed receipt validates" bash "$verify" check "$fail_id" --root "$root"
expect_rc 1 "zero-count positive check is inconclusive" bash "$verify" run zero --root "$root"
has $'\tinconclusive\tzero\t0\t0$' "$tmp/stdout" && ok "zero-count record" || bad "zero-count record"
expect_rc 1 "unknown-count positive check is inconclusive" bash "$verify" run unknown --root "$root"
has $'\tinconclusive\tunknown\t0\tunknown$' "$tmp/stdout" && ok "unknown-count record" || bad "unknown-count record"
expect_rc 1 "indented nested TAP plan is not top-level evidence" bash "$verify" run nested --root "$root"
has $'\tinconclusive\tnested\t0\tunknown$' "$tmp/stdout" && ok "nested plan count is unknown" || bad "nested plan count is unknown"
expect_rc 0 "Node-style nested TAP with a complete outer result set passes" bash "$verify" run node --root "$root"
has $'\tpass\tnode\t0\t1$' "$tmp/stdout" && ok "nested Node TAP uses only top-level evidence" || bad "nested Node TAP result is wrong"
expect_rc 1 "positive plan without results is inconclusive" bash "$verify" run planonly --root "$root"
has $'\tinconclusive\tplanonly\t0\tunknown$' "$tmp/stdout" && ok "plan-only TAP count is unknown" || bad "plan-only TAP count is wrong"
expect_rc 1 "positive plan with missing results is inconclusive" bash "$verify" run missing --root "$root"
has $'\tinconclusive\tmissing\t0\tunknown$' "$tmp/stdout" && ok "incomplete TAP count is unknown" || bad "incomplete TAP count is wrong"
expect_rc 1 "malformed top-level result numbering is inconclusive" bash "$verify" run numbering --root "$root"
has $'\tinconclusive\tnumbering\t0\tunknown$' "$tmp/stdout" && ok "malformed numbering count is unknown" || bad "malformed numbering count is wrong"
expect_rc 1 "duplicate top-level TAP plans are ambiguous" bash "$verify" run duplicate --root "$root"
has $'\tinconclusive\tduplicate\t0\tunknown$' "$tmp/stdout" && ok "duplicate plan count is unknown" || bad "duplicate plan count is unknown"
expect_rc 1 "malformed top-level TAP plan is unknown" bash "$verify" run malformed --root "$root"
has $'\tinconclusive\tmalformed\t0\tunknown$' "$tmp/stdout" && ok "malformed plan count is unknown" || bad "malformed plan count is unknown"

expect_rc 0 "fresh receipt before stale edit" bash "$verify" run test --root "$root"
stale_id=$(awk -F '\t' '{print $2}' "$tmp/stdout")
printf 'edit\n' >>"$root/src/input.txt"
expect_rc 2 "source edit makes receipt stale" bash "$verify" check "$stale_id" --root "$root"
git -C "$root" checkout -q -- src/input.txt

expect_rc 1 "source edit during check is inconclusive" bash "$verify" run mutate --root "$root"
has $'\tinconclusive\tmutate\t0\t1$' "$tmp/stdout" && ok "mutation result record" || bad "mutation result record"
mutate_id=$(awk -F '\t' '{print $2}' "$tmp/stdout")
expect_rc 0 "changed-input run leaves an honestly inconclusive current receipt" bash "$verify" check "$mutate_id" --root "$root"
git -C "$root" checkout -q -- src/input.txt

expect_rc 0 "fresh receipt before executable-bit edit" bash "$verify" run test --root "$root"
exec_id=$(awk -F '\t' '{print $2}' "$tmp/stdout")
chmod +x "$root/src/input.txt"
expect_rc 2 "working-tree executable-bit edit makes receipt stale" bash "$verify" check "$exec_id" --root "$root"
chmod -x "$root/src/input.txt"

expect_rc 0 "fresh receipt before untracked edit" bash "$verify" run test --root "$root"
untracked_id=$(awk -F '\t' '{print $2}' "$tmp/stdout")
printf 'new\n' >"$root/src/untracked.txt"
expect_rc 2 "untracked input makes receipt stale" bash "$verify" check "$untracked_id" --root "$root"
git -C "$root" add src/untracked.txt
expect_rc 0 "receipt captures staged state" bash "$verify" run test --root "$root"
staged_id=$(awk -F '\t' '{print $2}' "$tmp/stdout")
printf 'staged again\n' >>"$root/src/untracked.txt"
git -C "$root" add src/untracked.txt
expect_rc 2 "staged change makes receipt stale" bash "$verify" check "$staged_id" --root "$root"
git -C "$root" reset -q HEAD -- src/untracked.txt
rm -f "$root/src/untracked.txt"

expect_rc 0 "fresh receipt for tamper test" bash "$verify" run test --root "$root"
tamper_id=$(awk -F '\t' '{print $2}' "$tmp/stdout")
tamper="$root/.agent/.state/receipts/$tamper_id.receipt"
chmod 644 "$tamper"; printf 'extra=bad\n' >>"$tamper"
expect_rc 2 "tampered receipt shape is rejected" bash "$verify" check "$tamper_id" --root "$root"

expect_rc 0 "fresh receipt for valid-shape tamper test" bash "$verify" run test --root "$root"
tamper_id=$(awk -F '\t' '{print $2}' "$tmp/stdout")
tamper="$root/.agent/.state/receipts/$tamper_id.receipt"
chmod 644 "$tamper"
sed 's/^status=pass$/status=fail/' "$tamper" >"$tamper.tmp" && mv "$tamper.tmp" "$tamper"
expect_rc 2 "valid-shape receipt tampering is rejected" bash "$verify" check "$tamper_id" --root "$root"

expect_rc 124 "timeout returns 124" bash "$verify" run timeout --root "$root" --timeout 1
timeout_id=$(awk -F '\t' '{print $2}' "$tmp/stdout")
expect_rc 0 "timeout leaves a valid failed receipt" bash "$verify" check "$timeout_id" --root "$root"
child_pid=$(cat "$root/.agent/.state/timeout-child.pid")
sleep 1
if kill -0 "$child_pid" 2>/dev/null && [ "$(ps -o state= -p "$child_pid" 2>/dev/null | tr -d '[:space:]')" != Z ]; then
  bad "timeout child process was left running: $child_pid"
  kill "$child_pid" 2>/dev/null || :
else
  ok "timeout cleans invocation-owned child group"
fi

sleep_stub="$tmp/sleep-stub"
mkdir "$sleep_stub"
sleep_log="$tmp/watchdog-sleepers"
: >"$sleep_log"
real_sleep=$(command -v sleep)
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'printf "%s\\n" "$$" >>"$DA_TEST_SLEEP_LOG"'
  printf 'exec %q "$@"\n' "$real_sleep"
} >"$sleep_stub/sleep"
chmod +x "$sleep_stub/sleep"
watchdog_start=$(date +%s)
watchdog_runs=0
while [ "$watchdog_runs" -lt 3 ]; do
  captured=$(DA_TEST_SLEEP_LOG="$sleep_log" PATH="$sleep_stub:$PATH" bash "$verify" run test --root "$root" --timeout 300 2>"$tmp/nested.err")
  captured_rc=$?
  [ "$captured_rc" -eq 0 ] && printf '%s\n' "$captured" | grep -q $'\tpass\ttest\t0\t2$' || break
  watchdog_runs=$((watchdog_runs + 1))
done
watchdog_elapsed=$(($(date +%s) - watchdog_start))
watchdog_live=0
while IFS= read -r sleeper_pid; do
  case "$sleeper_pid" in '' | *[!0-9]*) continue ;; esac
  if kill -0 "$sleeper_pid" 2>/dev/null \
    && [ "$(ps -o state= -p "$sleeper_pid" 2>/dev/null | tr -d '[:space:]')" != Z ]; then
    watchdog_live=1
  fi
done <"$sleep_log"
[ "$watchdog_runs" -eq 3 ] && [ "$watchdog_elapsed" -lt 8 ] && [ "$watchdog_live" -eq 0 ] \
  && ok "nested captures cancel and reap watchdog sleepers immediately" \
  || bad "nested captures leaked or waited (runs=$watchdog_runs elapsed=$watchdog_elapsed live=$watchdog_live)"

# shellcheck source=../runtime.sh
. "$here/runtime.sh"
index_before=$(cksum <"$root/.git/index")
objects_before=$(find "$root/.git/objects" -type f -exec cksum {} \; | LC_ALL=C sort | cksum)
da_fingerprint "$root" >"$tmp/fingerprint"
fp_rc=$?
index_after=$(cksum <"$root/.git/index")
objects_after=$(find "$root/.git/objects" -type f -exec cksum {} \; | LC_ALL=C sort | cksum)
[ "$fp_rc" -eq 0 ] && [ "$index_before" = "$index_after" ] && [ "$objects_before" = "$objects_after" ] \
  && ok "fingerprinting changes neither index bytes nor object store" || bad "fingerprinting modified Git state"

base_fp=$(da_fingerprint "$root")
printf 'atomic one\n' >"$root/.agent/.session-log.checkpoint.test"
git -C "$root" add -f .agent/.session-log.checkpoint.test
printf 'atomic two\n' >"$root/.agent/.session-log.checkpoint.test"
excluded_fp=$(da_fingerprint "$root")
[ "$base_fp" = "$excluded_fp" ] && ok "atomic session checkpoint is excluded from index and worktree evidence" || bad "atomic session checkpoint changed fingerprint"
git -C "$root" reset -q HEAD -- .agent/.session-log.checkpoint.test
rm -f "$root/.agent/.session-log.checkpoint.test"

mkdir -p "$root/.agent/rules/learned"
printf '<!-- Generated by index.sh from rules/learned/ records. -->\ngenerated one\n' >"$root/.agent/rules/learned.md"
generated_fp=$(da_fingerprint "$root")
printf '<!-- Generated by index.sh from rules/learned/ records. -->\ngenerated two\n' >"$root/.agent/rules/learned.md"
[ "$(da_fingerprint "$root")" = "$generated_fp" ] && ok "generated learned aggregate is excluded" || bad "generated learned aggregate changed fingerprint"
rmdir "$root/.agent/rules/learned"
manual_fp=$(da_fingerprint "$root")
printf 'manual edit\n' >>"$root/.agent/rules/learned.md"
[ "$(da_fingerprint "$root")" != "$manual_fp" ] && ok "manual learned file remains fingerprinted" || bad "manual learned file was excluded"
rm -f "$root/.agent/rules/learned.md"

copy="$tmp/physical copy"
cp -R "$root" "$copy"
[ "$(da_fingerprint "$root")" != "$(da_fingerprint "$copy")" ] && ok "physical worktree identity distinguishes identical copies" || bad "identical copies shared a fingerprint"
expect_rc 2 "receipt metadata refuses a copied worktree" bash "$copy/.agent/scripts/verify.sh" check "$receipt_id" --root "$copy"

conflict="$tmp/conflicted index"
new_git "$conflict"
printf 'base\n' >"$conflict/src/conflict.txt"
git -C "$conflict" add . && git -C "$conflict" commit -qm base
blob1=$(printf 'one\n' | git -C "$conflict" hash-object -w --stdin)
blob2=$(printf 'two\n' | git -C "$conflict" hash-object -w --stdin)
git -C "$conflict" update-index --force-remove src/conflict.txt
printf '100644 %s 1\tsrc/conflict.txt\n100644 %s 2\tsrc/conflict.txt\n' "$blob1" "$blob2" | git -C "$conflict" update-index --index-info
da_fingerprint "$conflict" >"$tmp/conflict.out" 2>"$tmp/conflict.err"; conflict_rc=$?
[ "$conflict_rc" -eq 2 ] && has 'unresolved index stage' "$tmp/conflict.err" && ok "unresolved index stages are rejected clearly" || bad "unresolved index was not rejected clearly"

lock_path="$tmp/denied.lock"
mkdir "$lock_path"; printf '%s\n' "$$" >"$lock_path/owner"
kill() { return 1; }
da_lock "$lock_path" >"$tmp/lock.out" 2>"$tmp/lock.err"; lock_rc=$?
unset -f kill
case "$lock_rc" in 1 | 2) lock_refused=1 ;; *) lock_refused=0 ;; esac
[ "$lock_refused" -eq 1 ] && [ -d "$lock_path" ] && ok "signal denial is not treated as proof of dead lock owner" || bad "lock recovered after signal denial"

non="$tmp/non git"
mkdir -p "$non/.agent/scripts" "$non/app"
cp "$here/verify.sh" "$here/runtime.sh" "$non/.agent/scripts/"
cat >"$non/.agent/scripts/checks.sh" <<'EOF'
#!/usr/bin/env bash
printf '1..1\nok 1 - non-git\n'
EOF
chmod +x "$non/.agent/scripts/checks.sh"
cat >"$non/.agent/scripts/verify.conf" <<'EOF'
CHECK_DRIVER=.agent/scripts/checks.sh
POSITIVE_TEST_CHECKS=test
TEST_COUNT_FORMAT=tap
TIMEOUT_SECONDS=5
EOF
printf 'app\n' >"$non/app/file"
expect_rc 2 "non-Git pass refuses implicit boundary" bash "$non/.agent/scripts/verify.sh" run test --root "$non"
printf 'NON_GIT_INPUT_ROOTS=.agent app\n' >>"$non/.agent/scripts/verify.conf"
expect_rc 0 "non-Git pass accepts explicit boundary" bash "$non/.agent/scripts/verify.sh" run test --root "$non"
non_id=$(awk -F '\t' '{print $2}' "$tmp/stdout")
printf 'change\n' >>"$non/app/file"
expect_rc 2 "non-Git declared input edit is stale" bash "$non/.agent/scripts/verify.sh" check "$non_id" --root "$non"
printf 'app\n' >"$non/app/file"
expect_rc 0 "fresh non-Git receipt before omitted agent input changes" bash "$non/.agent/scripts/verify.sh" run test --root "$non"
non_agent_id=$(awk -F '\t' '{print $2}' "$tmp/stdout")
sed 's/NON_GIT_INPUT_ROOTS=.agent app/NON_GIT_INPUT_ROOTS=app/' "$non/.agent/scripts/verify.conf" >"$non/.agent/scripts/verify.conf.tmp" && mv "$non/.agent/scripts/verify.conf.tmp" "$non/.agent/scripts/verify.conf"
expect_rc 2 "non-Git config remains fingerprinted when roots omit agent" bash "$non/.agent/scripts/verify.sh" check "$non_agent_id" --root "$non"
expect_rc 0 "fresh receipt with config outside declared roots" bash "$non/.agent/scripts/verify.sh" run test --root "$non"
non_config_id=$(awk -F '\t' '{print $2}' "$tmp/stdout")
printf '# config edit\n' >>"$non/.agent/scripts/verify.conf"
expect_rc 2 "non-Git config bytes remain fingerprinted outside declared roots" bash "$non/.agent/scripts/verify.sh" check "$non_config_id" --root "$non"
expect_rc 0 "fresh receipt before driver edit outside declared roots" bash "$non/.agent/scripts/verify.sh" run test --root "$non"
non_driver_id=$(awk -F '\t' '{print $2}' "$tmp/stdout")
printf '# driver edit\n' >>"$non/.agent/scripts/checks.sh"
expect_rc 2 "non-Git declared driver remains fingerprinted when roots omit agent" bash "$non/.agent/scripts/verify.sh" check "$non_driver_id" --root "$non"
[ -f "$non/.agent/.state/.gitignore" ] && has '^\*$' "$non/.agent/.state/.gitignore" && ok "non-Git state installs a self-ignore file" || bad "non-Git state lacks self-ignore"

expression_root="$tmp/find expressions"
mkdir -p "$expression_root/.agent/scripts" "$expression_root/!"
cp "$here/verify.sh" "$here/runtime.sh" "$expression_root/.agent/scripts/"
cp "$non/.agent/scripts/checks.sh" "$expression_root/.agent/scripts/checks.sh"
cat >"$expression_root/.agent/scripts/verify.conf" <<'EOF'
CHECK_DRIVER=.agent/scripts/checks.sh
POSITIVE_TEST_CHECKS=test
TEST_COUNT_FORMAT=tap
TIMEOUT_SECONDS=5
NON_GIT_INPUT_ROOTS=!
EOF
printf 'input\n' >"$expression_root/!/file"
expect_rc 0 "non-Git find roots cannot be parsed as expressions" bash "$expression_root/.agent/scripts/verify.sh" run test --root "$expression_root"

symlink_state="$tmp/symlink state"
mkdir -p "$symlink_state/.agent" "$tmp/state target"
ln -s "$tmp/state target" "$symlink_state/.agent/.state"
da_state_dir "$symlink_state" >"$tmp/symlink-state.out" 2>"$tmp/symlink-state.err"; symlink_state_rc=$?
[ "$symlink_state_rc" -eq 2 ] && has 'symlink state directory' "$tmp/symlink-state.err" && ok "symlink state directory is rejected" || bad "symlink state directory was accepted"

symlink_receipts="$tmp/symlink receipts"
new_git "$symlink_receipts"; write_driver "$symlink_receipts"
git -C "$symlink_receipts" add . && git -C "$symlink_receipts" commit -qm initial
mkdir -p "$symlink_receipts/.agent/.state" "$tmp/receipt target"
ln -s "$tmp/receipt target" "$symlink_receipts/.agent/.state/receipts"
expect_rc 2 "symlink receipt directory is rejected" bash "$symlink_receipts/.agent/scripts/verify.sh" run test --root "$symlink_receipts"

agent_symlink_escape="$tmp/agent symlink escape"
mkdir -p "$(dirname "$agent_symlink_escape")" "$tmp/escape target"
mkdir -p "$agent_symlink_escape"
ln -s "$tmp/escape target" "$agent_symlink_escape/.agent"
da_state_dir "$agent_symlink_escape" >"$tmp/agent-escape.out" 2>"$tmp/agent-escape.err"; agent_escape_rc=$?
[ "$agent_escape_rc" -eq 2 ] && has 'symlink \.agent directory' "$tmp/agent-escape.err" \
  && ok "symlink .agent parent is rejected" || bad ".agent parent symlink escape was accepted"

readonly_git="$tmp/readonly git"
new_git "$readonly_git"; write_driver "$readonly_git"
git -C "$readonly_git" add . && git -C "$readonly_git" commit -qm initial
chmod -R a-w "$readonly_git/.git"
expect_rc 0 "verify run tolerates a read-only .git directory" bash "$readonly_git/.agent/scripts/verify.sh" run test --root "$readonly_git"
readonly_id=$(awk -F '\t' '{print $2}' "$tmp/stdout")
[ -d "$readonly_git/.agent/.state" ] && [ ! -e "$readonly_git/.git/dot-agent" ] \
  && ok "state lives under .agent/.state despite a read-only .git directory" \
  || bad "state was not created under .agent/.state with a read-only .git directory"
expect_rc 0 "verify check tolerates a read-only .git directory" bash "$readonly_git/.agent/scripts/verify.sh" check "$readonly_id" --root "$readonly_git"
status_output=$(git -C "$readonly_git" status --porcelain)
printf '%s\n' "$status_output" | grep -q '.agent/.state' \
  && bad "git status exposed state files" || ok "git status does not expose state files"
chmod -R u+w "$readonly_git/.git"

# Output past OUTPUT_MAX_BYTES: failure lines first, then the tail, all
# numbered, within the limit, with the full output kept beside the receipts.
out_root="$tmp/output project"
new_git "$out_root"
cat >>"$out_root/.agent/scripts/verify.conf" <<'EOF'
OUTPUT_MAX_BYTES=4000
EOF
cat >"$out_root/.agent/scripts/checks.sh" <<'EOF'
#!/usr/bin/env bash
noise() { i=$1; while [ "$i" -le "$2" ]; do printf 'progress line %s of a long run\n' "$i"; i=$((i + 1)); done; }
case "$1" in
  long)
    noise 1 99
    printf 'not ok 3 - currency rounding\n  at src/money.ts:12\n'
    noise 102 3000
    exit 1 ;;
  quiet) noise 1 3000 ;;
  *) exit 9 ;;
esac
EOF
chmod +x "$out_root/.agent/scripts/checks.sh"
git -C "$out_root" add . && git -C "$out_root" commit -qm initial
out_verify="$out_root/.agent/scripts/verify.sh"
expect_rc 1 "long failing output still fails" bash "$out_verify" run long --root "$out_root"
long_id=$(awk -F '\t' '{print $2}' "$tmp/stdout")
[ "$(wc -c <"$tmp/stderr" | tr -d '[:space:]')" -le 4000 ] && ok "long output stays within OUTPUT_MAX_BYTES" || bad "long output is $(wc -c <"$tmp/stderr") bytes"
has '^100\| not ok 3 - currency rounding$' "$tmp/stderr" && has '^101\|   at src/money\.ts:12$' "$tmp/stderr" \
  && ok "the failing line and the line after it print, numbered" || bad "failure lines missing from long output"
[ "$(grep -n '^--- failure lines ---$' "$tmp/stderr" | cut -d: -f1)" -lt "$(grep -n '^100| ' "$tmp/stderr" | cut -d: -f1)" ] \
  && [ "$(grep -n '^100| ' "$tmp/stderr" | cut -d: -f1)" -lt "$(grep -n '^--- last lines ---$' "$tmp/stderr" | cut -d: -f1)" ] \
  && ok "failure lines print before the tail" || bad "failure lines are not first"
has '^3000\| progress line 3000 of a long run$' "$tmp/stderr" && ok "the last line prints" || bad "tail missing the last line"
saved="$out_root/.agent/.state/output/$long_id.log"
[ "$(wc -l <"$saved" | tr -d '[:space:]')" = 3000 ] && cmp -s "$saved" <(cd "$out_root" && bash .agent/scripts/checks.sh long) \
  && ok "the full output is kept under the receipt id" || bad "full output was not kept intact"
has "\.agent/\.state/output/$long_id\.log" "$tmp/stderr" && ok "the header names the kept output" || bad "header does not name the kept output"
expect_rc 0 "long passing output passes" bash "$out_verify" run quiet --root "$out_root"
has '^--- failure lines ---$' "$tmp/stderr" && ! grep -Eq '^[0-9]+\| ' <(sed -n '/^--- failure lines ---$/,/^--- last lines ---$/p' "$tmp/stderr") \
  && has '^3000\| ' "$tmp/stderr" && ok "no match leaves the failure section empty and fills with the tail" || bad "no-match output is wrong"
expect_rc 1 "short output prints whole" bash "$verify" run fail --root "$root"
[ "$(cat "$tmp/stderr")" = "$(printf '1..1\nnot ok 1 - failure')" ] && ok "output under the limit is unchanged" || bad "short output was altered: $(cat "$tmp/stderr")"
# --output-share N divides the limit, so N runs printed into one tool result
# stay within one limit together.
expect_rc 1 "a shared limit still reports the failing run" bash "$out_verify" run long --root "$out_root" --output-share 2
[ "$(wc -c <"$tmp/stderr" | tr -d '[:space:]')" -le 2000 ] && has 'over the 2000-byte limit' "$tmp/stderr" \
  && ok "--output-share 2 halves OUTPUT_MAX_BYTES" || bad "shared output is $(wc -c <"$tmp/stderr") bytes"
has '^100\| not ok 3 - currency rounding$' "$tmp/stderr" && has '^3000\| ' "$tmp/stderr" \
  && ok "a shared limit keeps the failing line and the last line" || bad "shared output lost the failing or last line"
expect_rc 1 "a share smaller than the header still reports the run" bash "$out_verify" run long --root "$out_root" --output-share 4000
has 'over the 1-byte limit' "$tmp/stderr" && has '^--- last lines ---$' "$tmp/stderr" && ! has '^[0-9]+\| ' "$tmp/stderr" \
  && ok "a 1-byte share prints the header and section markers alone" || bad "tiny share output is wrong: $(head -c 400 "$tmp/stderr")"
expect_rc 1 "a share of 1 runs" bash "$verify" run fail --root "$root" --output-share 1
[ "$(cat "$tmp/stderr")" = "$(printf '1..1\nnot ok 1 - failure')" ] && ok "a share of 1 leaves short output unchanged" || bad "share 1 altered output: $(cat "$tmp/stderr")"
expect_rc 1 "short output under a shared limit prints whole" bash "$verify" run fail --root "$root" --output-share 3
[ "$(cat "$tmp/stderr")" = "$(printf '1..1\nnot ok 1 - failure')" ] && ok "short output under a shared limit is unchanged" || bad "share 3 altered short output: $(cat "$tmp/stderr")"
expect_rc 2 "a zero output share is refused" bash "$out_verify" run long --root "$out_root" --output-share 0
expect_rc 2 "a non-numeric output share is refused" bash "$out_verify" run long --root "$out_root" --output-share two
expect_rc 2 "a missing output share value is refused" bash "$out_verify" run long --root "$out_root" --output-share
expect_rc 2 "an output share with check is refused" bash "$out_verify" check "$long_id" --root "$out_root" --output-share 2
printf 'OUTPUT_FAILURE_PATTERN=(\n' >>"$out_root/.agent/scripts/verify.conf"
expect_rc 1 "a broken failure pattern still reports the run" bash "$out_verify" run long --root "$out_root"
has 'selection failed' "$tmp/stderr" && has '^progress line 3000 of a long run$' "$tmp/stderr" \
  && ok "a failed selection falls back to the plain tail" || bad "fallback tail missing"
printf 'OUTPUT_MAX_BYTES=many\n' >>"$out_root/.agent/scripts/verify.conf"
expect_rc 2 "a non-numeric OUTPUT_MAX_BYTES is refused" bash "$out_verify" run long --root "$out_root"

printf '1..%s\n' "$((pass + fail))"
printf '# passed %s; failed %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
