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
TIMEOUT_SECONDS=60
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
  lost) printf 'TAP version 13\n1..1\nok 1 - one\n'; rm -f "$TMPDIR"/verify-output.* ;;
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
  && printf '%s\n' "$version" | grep -qF 'receipt schema 3' \
  && ok "version identifies dot-agent and receipt schema" || bad "incomplete version output: $version"

expect_rc 0 "genuine TAP success and paths with spaces" bash "$verify" run test --root "$root"
record=$(cat "$tmp/stdout"); receipt_id=$(printf '%s\n' "$record" | awk -F '\t' '{print $2}')
if printf '%s\n' "$record" | grep -Eq $'^receipt\t[^[:space:]]+\tpass\ttest\t0\t2$'; then ok "success result record"; else bad "success result record: $record"; fi
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
has $'^receipt\t.*\tfail\tfail\t7\t1$' "$tmp/stdout" && ok "nonzero result preserves exit" || bad "nonzero result preserves exit"
fail_id=$(awk -F '\t' '{print $2}' "$tmp/stdout")
expect_rc 0 "current failed receipt validates" bash "$verify" check "$fail_id" --root "$root"
mkdir "$tmp/lost"
expect_rc 1 "a check whose output was removed is inconclusive" env TMPDIR="$tmp/lost" bash "$verify" run lost --root "$root"
has $'\tinconclusive\tlost\t0\tunknown$' "$tmp/stdout" && has 'output was removed while it ran' "$tmp/stderr" && ok "lost output is never a pass" || bad "lost output is never a pass"
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
has 'project files changed while mutate ran, so the result is inconclusive\. Run the check again' "$tmp/stderr" \
  && ok "a changed-input run says why it is inconclusive" || bad "changed-input run gave no reason"
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

expect_rc 0 "fresh receipt for the fails_without_change field" bash "$verify" run test --root "$root"
fwc_id=$(awk -F '\t' '{print $2}' "$tmp/stdout")
fwc="$root/.agent/.state/receipts/$fwc_id.receipt"
[ "$(tail -n 1 "$fwc")" = 'fails_without_change=unknown' ] && [ "$(sed -n 11p "$fwc")" = 'proof=none' ] \
  && ok "a run records fails_without_change=unknown" || bad "receipt fails_without_change line: $(tail -n 1 "$fwc")"
expect_rc 0 "a receipt carrying fails_without_change validates" bash "$verify" check "$fwc_id" --root "$root"
cp "$fwc" "$tmp/fwc.saved"
chmod 644 "$fwc"
sed '$d' "$tmp/fwc.saved" >"$fwc"
expect_rc 2 "a receipt missing fails_without_change is refused" bash "$verify" check "$fwc_id" --root "$root"
{ sed '$d' "$tmp/fwc.saved"; printf 'shipped=unknown\n'; } >"$fwc"
expect_rc 2 "a receipt with another key in its place is refused" bash "$verify" check "$fwc_id" --root "$root"
{ sed '$d' "$tmp/fwc.saved"; printf 'fails_without_change=maybe\n'; } >"$fwc"
expect_rc 2 "a fails_without_change outside yes, no, unknown is refused" bash "$verify" check "$fwc_id" --root "$root"
{ sed '$d' "$tmp/fwc.saved"; printf 'fails_without_change=yes\n'; } >"$fwc"
expect_rc 2 "an edited fails_without_change breaks the receipt digest" bash "$verify" check "$fwc_id" --root "$root"

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
# A sleeper is signalled before the run returns and dies when it is scheduled.
watchdog_tries=0
while :; do
  watchdog_live=0
  while IFS= read -r sleeper_pid; do
    case "$sleeper_pid" in '' | *[!0-9]*) continue ;; esac
    if kill -0 "$sleeper_pid" 2>/dev/null \
      && [ "$(ps -o state= -p "$sleeper_pid" 2>/dev/null | tr -d '[:space:]')" != Z ]; then
      watchdog_live=1
    fi
  done <"$sleep_log"
  watchdog_tries=$((watchdog_tries + 1))
  [ "$watchdog_live" -eq 1 ] && [ "$watchdog_tries" -lt 25 ] || break
  sleep 0.2
done
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
TIMEOUT_SECONDS=60
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
TIMEOUT_SECONDS=60
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
  manyfail)
    printf 'TAP version 13\n1..21\n'
    k=1
    while [ "$k" -le 20 ]; do
      noise 1 100
      printf 'not ok %s - case %s\n' "$k" "$k"
      f=1; while [ "$f" -le 5 ]; do printf '  at frame %s of case %s\n' "$f" "$k"; f=$((f + 1)); done
      [ "$k" -ne 10 ] || printf 'not ok 21 - flaky # TODO fix later\n'
      k=$((k + 1))
    done
    noise 1 100
    exit 1 ;;
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
# TAP output: every failing result is named before any failure's context, and
# an expected failure marked TODO is not chosen.
expect_rc 1 "many failing TAP results still fail" bash "$out_verify" run manyfail --root "$out_root"
[ "$(wc -c <"$tmp/stderr" | tr -d '[:space:]')" -le 4000 ] && ok "many failing TAP results stay within OUTPUT_MAX_BYTES" || bad "many-failure output is $(wc -c <"$tmp/stderr") bytes"
sed -n '/^--- failure lines ---$/,/^--- last lines ---$/p' "$tmp/stderr" >"$tmp/failure-section"
named=0; k=1
while [ "$k" -le 20 ]; do
  has "^[0-9]+\\| not ok $k - case $k\$" "$tmp/failure-section" && named=$((named + 1))
  k=$((k + 1))
done
[ "$named" -eq 20 ] && ok "every failing TAP result prints in the failure section" || bad "only $named of 20 failing TAP results printed"
has '\| not ok 1 - case 1$' "$tmp/failure-section" && has '\|   at frame 1 of case 1$' "$tmp/failure-section" \
  && ok "context lines fill the rest of the failure section" || bad "no context printed after the failing results"
! has 'flaky # TODO' "$tmp/failure-section" && ok "a TODO failure is not chosen as a failure line" || bad "a TODO failure was chosen"
has 'Failing TAP results, then lines matching the failure pattern, come first' "$tmp/stderr" \
  && ok "the header names the failing TAP results" || bad "header does not name the failing TAP results"
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

# TEST_COUNT_FORMAT=auto reads a runner's own closing summary when the output
# is not TAP. Each driver line is the shape that runner prints, and each row
# below takes its own counting rule or its own outcome. Skipped tests are in
# the lines and out of the counts.
auto_root="$tmp/auto"
new_git "$auto_root"
cat >"$auto_root/.agent/scripts/verify.conf" <<'EOF'
CHECK_DRIVER=.agent/scripts/checks.sh
POSITIVE_TEST_CHECKS=node,bun,unittest,unittestskip,jest,vitest,cargo,gov,goplain,minitest,pytest,pytestnone,cutversion,cutplan
TEST_COUNT_FORMAT=auto
TIMEOUT_SECONDS=60
EOF
cat >"$auto_root/.agent/scripts/checks.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  node) printf '\342\204\271 tests 3\n\342\204\271 suites 0\n\342\204\271 pass 2\n\342\204\271 fail 0\n\342\204\271 skipped 1\n' ;;
  bun) printf ' 2 pass\n 1 skip\n 0 fail\nRan 3 tests across 1 file. [32.00ms]\n' ;;
  unittest) printf 's..\n-----\nRan 3 tests in 0.000s\n\nOK (skipped=1)\n' ;;
  unittestskip) printf 's\n-----\nRan 0 tests in 0.000s\n\nOK (skipped=1)\n' ;;
  jest) printf 'Test Suites: 1 passed, 1 total\nTests:       1 skipped, 2 passed, 3 total\nSnapshots:   0 total\n' ;;
  vitest) printf ' Test Files  1 passed (1)\n      Tests  1 failed | 2 passed (3)\n' ;;
  cargo) printf 'test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s\n\n   Doc-tests x\n\ntest result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s\n' ;;
  gov) printf '=== RUN   TestA\n--- PASS: TestA (0.00s)\n--- PASS: TestB (0.00s)\n    --- PASS: TestB/sub (0.00s)\nPASS\nok  \tx\t0.244s\n' ;;
  goplain) printf 'ok  \tx\t0.382s\n' ;;
  minitest) printf '2 runs, 1 assertions, 0 failures, 0 errors, 1 skips\n' ;;
  pytest) printf '========================= 1 failed, 2 passed in 0.02s ==========================\n' ;;
  pytestnone) printf '============================ 2 deselected in 0.00s =============================\n' ;;
  cutversion) printf 'TAP version 13\nok 1 - one\nRan 3 tests in 0.100s\n' ;;
  cutplan) printf '1..3\nok 1 - one\nRan 3 tests in 0.100s\n' ;;
  build) printf 'built\n' >>src/input.txt; printf 'built\n' ;;
  *) exit 9 ;;
esac
EOF
git -C "$auto_root" add .
git -C "$auto_root" commit -qm initial
auto_verify="$auto_root/.agent/scripts/verify.sh"
auto_case() {
  bash "$auto_verify" run "$1" --root "$auto_root" >"$tmp/stdout" 2>"$tmp/stderr"
  if has "$(printf '\t%s\t%s\t0\t%s$' "$2" "$1" "$3")" "$tmp/stdout"; then ok "auto: $1 is $2 with count $3"; else bad "auto: $1 is not $2 with count $3: $(cat "$tmp/stdout")"; fi
}
auto_rows=0
while read -r auto_check auto_status auto_count; do
  auto_case "$auto_check" "$auto_status" "$auto_count"
  auto_rows=$((auto_rows + 1))
done <<'EOF'
node pass 2
bun pass 2
unittest pass 2
jest pass 2
vitest pass 3
cargo pass 2
gov pass 2
minitest pass 1
pytest pass 3
unittestskip inconclusive 0
cutversion inconclusive unknown
cutplan inconclusive unknown
EOF
[ "$auto_rows" -eq 12 ] && ok "every auto row ran" || bad "auto rows ran: $auto_rows"
# why names the cause of the run just recorded, in the one word checkpoint.sh
# reads, and the run's last line carries the matching next step.
auto_why() {
  aw_got=$(bash "$auto_verify" why "$(cut -f2 "$tmp/stdout")" --root "$auto_root" 2>&1)
  [ "$aw_got" = "$1" ] && has "$2" "$tmp/stderr" && ok "why: $1" || bad "why wanted $1, got $aw_got after: $(tail -1 "$tmp/stderr")"
}
auto_case pytestnone inconclusive 0
auto_why empty 'pytestnone exited 0 and ran 0 tests, so the result is inconclusive\. Run it over at least one test$'
auto_case goplain inconclusive unknown
auto_why uncounted "goplain exited 0, but its output carries no test count this script reads.*Make \.agent/scripts/checks\.sh run the runner with its TAP reporter.*Leave the project's own test command as it is$"
auto_case build inconclusive unknown
auto_why changed 'project files changed while build ran, so the result is inconclusive\. Run the check again'
git -C "$auto_root" checkout -q -- src/input.txt
sed 's/^TEST_COUNT_FORMAT=auto$/TEST_COUNT_FORMAT=tap/' "$auto_root/.agent/scripts/verify.conf" >"$tmp/verify.conf" && cp "$tmp/verify.conf" "$auto_root/.agent/scripts/verify.conf"
auto_case unittest inconclusive unknown
auto_why format 'TEST_COUNT_FORMAT=tap read no test count from its output.*set TEST_COUNT_FORMAT=auto in \.agent/scripts/verify\.conf'
bash "$auto_verify" --help | grep -q 'TEST_COUNT_FORMAT=auto counts TAP' && ok "--help names the counted formats" || bad "--help does not name the counted formats"

# prove runs the check without the change in a throwaway checkout. The node,
# the scratch folder, and config.local are Git-ignored here, as in a project
# whose node is local.
pv="$tmp/prove"
mkdir -p "$pv/.agent/scripts" "$pv/src" "$pv/test" "$pv/tmp/scratch" "$tmp/prove-tmp"
cp "$here/verify.sh" "$here/runtime.sh" "$pv/.agent/scripts/"
cat >"$pv/.agent/scripts/verify.conf" <<'EOF'
CHECK_DRIVER=.agent/scripts/checks.sh
POSITIVE_TEST_CHECKS=
TEST_COUNT_FORMAT=auto
TIMEOUT_SECONDS=60
EOF
cat >"$pv/.agent/scripts/checks.sh" <<'EOF'
#!/usr/bin/env bash
all() { for f in test/*.test.sh tmp/scratch/*.test.sh; do [ -f "$f" ] || continue; bash "$f" || { echo "not ok - $f"; exit 1; }; done; }
case "$1" in
  test) all ;;
  local) [ -f config.local ] || { echo 'config.local is missing'; exit 1; }; all ;;
  shared) [ -f "${DA_PROVE_MAIN:-.}/config.local" ] || { echo 'config.local is missing'; exit 1; }; all ;;
  linked) [ -z "${DA_PROVE:-}" ] || [ -e gen ] || ln -s "$DA_PROVE_MAIN/gen" gen; all ;;
  built) if [ ! -e out/calc.sh ] || [ src/calc.sh -nt out/calc.sh ]; then mkdir -p out && cp src/calc.sh out/calc.sh; fi; [ "$(bash out/calc.sh 2 3)" = 5 ] ;;
  readonly) [ -z "${DA_PROVE:-}" ] || { mkdir -p ro/sub locked && chmod 555 ro && chmod 000 locked && ln "$DA_PROVE_MAIN/gen/double.sh" hardlink; }; all ;;
  flagged) [ -f src/flag ] || { echo 'no flag'; exit 1; }; all ;;
  plain) [ -z "${DA_PROVE:-}" ] || { echo 'DA_PROVE reached a run'; exit 1; } ;;
  slow) if [ -n "${DA_PROVE:-}" ] && [ "$(bash src/calc.sh 2 3)" != 5 ]; then sleep 20; fi; all ;;
  *) exit 9 ;;
esac
EOF
printf '.agent/\ntmp/\nconfig.local\ngen/\nout/\n' >"$pv/.gitignore"
printf 'echo $(( $1 - $2 ))\n' >"$pv/src/calc.sh"
printf '[ "$(bash src/calc.sh 2 0)" = 2 ]\n' >"$pv/test/calc.test.sh"
git -C "$pv" init -q
git -C "$pv" config user.email test@example.invalid
git -C "$pv" config user.name Test
git -C "$pv" add .
git -C "$pv" commit -qm base
pv_base=$(git -C "$pv" rev-parse HEAD)
pv_verify="$pv/.agent/scripts/verify.sh"
pv_run() { TMPDIR="$tmp/prove-tmp" bash "$pv_verify" prove "$@" --root "$pv" >"$tmp/stdout" 2>"$tmp/stderr"; }
pv_line() { sed -n "$1p" "$pv/.agent/.state/receipts/$(cut -f2 "$tmp/stdout").receipt"; }
pv_tree() { (cd "$pv" && git symbolic-ref HEAD && git rev-parse HEAD && git ls-files -s && git status --porcelain --ignored && find src test tmp gen config.local -type f -exec git hash-object {} + 2>/dev/null) | git hash-object --stdin; }
printf 'echo $(( $1 + $2 ))\n' >"$pv/src/calc.sh"
printf '[ "$(bash src/calc.sh 2 3)" = 5 ]\n' >"$pv/tmp/scratch/sum.test.sh"
pv_before=$(pv_tree)
pv_run test --test tmp/scratch/sum.test.sh; pv_rc=$?
[ "$pv_rc" -eq 0 ] && [ "$(pv_line 12)" = 'fails_without_change=yes' ] \
  && ok "prove records yes for a test that fails at the base and passes now" || bad "prove yes: rc $pv_rc, $(pv_line 12), $(tail -1 "$tmp/stderr")"
pv_digest=$(printf 'tmp/scratch/sum.test.sh\t%s\n' "$(git hash-object "$pv/tmp/scratch/sum.test.sh")" | git hash-object --stdin)
[ "$(pv_line 11)" = "proof=base:$pv_base:$pv_digest" ] \
  && ok "the receipt names the base and the content of a Git-ignored test" || bad "proof line: $(pv_line 11)"
pv_id=$(cut -f2 "$tmp/stdout")
expect_rc 0 "a proved receipt validates" bash "$pv_verify" check "$pv_id" --root "$pv"
[ "$(bash "$pv_verify" why "$pv_id" --root "$pv")" = proved ] && ok "why names a proof that held" || bad "why after yes: $(bash "$pv_verify" why "$pv_id" --root "$pv" 2>&1)"
[ "$(pv_tree)" = "$pv_before" ] && [ -z "$(ls "$tmp/prove-tmp")" ] \
  && ok "prove leaves the session's tree and the temporary folder as they were" || bad "prove left something behind: $(ls "$tmp/prove-tmp")"
pv_receipt="$pv/.agent/.state/receipts/$pv_id.receipt"
chmod u+w "$pv_receipt"
cp "$pv_receipt" "$tmp/proof.saved"
sed 's/^proof=base:/proof=break:/' "$tmp/proof.saved" >"$pv_receipt"
expect_rc 2 "an edited proof breaks the receipt digest" bash "$pv_verify" check "$pv_id" --root "$pv"
sed 's/^fails_without_change=yes$/fails_without_change=no/' "$tmp/proof.saved" >"$pv_receipt"
expect_rc 2 "an edited verdict on a proved receipt breaks its digest" bash "$pv_verify" check "$pv_id" --root "$pv"
printf '[ "$(bash src/calc.sh 2 0)" = 2 ]\n' >"$pv/tmp/scratch/weak.test.sh"
pv_run test --test tmp/scratch/sum.test.sh --test tmp/scratch/weak.test.sh; pv_rc=$?
[ "$pv_rc" -eq 1 ] && [ "$(pv_line 12)" = 'fails_without_change=no' ] \
  && has "passes at ${pv_base:0:12} with tmp/scratch/weak\.test\.sh copied in, so that does not prove the change" "$tmp/stderr" \
  && ok "each test file is proved on its own run, and one that passes at the base is named" || bad "prove no: rc $pv_rc, $(tail -1 "$tmp/stderr")"
[ "$(bash "$pv_verify" why "$(cut -f2 "$tmp/stdout")" --root "$pv")" = unproved ] && ok "why names a proof that did not hold" || bad "why after no: $(bash "$pv_verify" why "$(cut -f2 "$tmp/stdout")" --root "$pv" 2>&1)"
rm "$pv/tmp/scratch/sum.test.sh" "$pv/tmp/scratch/weak.test.sh"
git -C "$pv" add src
git -C "$pv" commit -qm fix
printf 'echo $(( $1 - $2 ))\n' >"$pv/tmp/scratch/calc.broken"
pv_run test --break src/calc.sh=tmp/scratch/calc.broken; pv_rc=$?
[ "$pv_rc" -eq 1 ] && [ "$(pv_line 12)" = 'fails_without_change=no' ] && has 'no test here protects that behavior' "$tmp/stderr" \
  && ok "a broken copy that no test notices records no" || bad "break no: rc $pv_rc, $(tail -1 "$tmp/stderr")"
printf '[ "$(bash src/calc.sh 2 3)" = 5 ]\n' >"$pv/test/sum.test.sh"
pv_run test --break src/calc.sh=tmp/scratch/calc.broken; pv_rc=$?
[ "$pv_rc" -eq 0 ] && [ "$(pv_line 12)" = 'fails_without_change=yes' ] && printf '%s\n' "$(pv_line 11)" | grep -q '^proof=break:' \
  && ok "a broken copy proves a test for a rule the old code already met" || bad "break yes: rc $pv_rc, $(pv_line 11), $(tail -1 "$tmp/stderr")"
: >"$pv/config.local"
pv_run local --test test/sum.test.sh; pv_rc=$?
[ "$pv_rc" -eq 1 ] && [ "$(pv_line 11)" = 'proof=none' ] && [ "$(pv_line 12)" = 'fails_without_change=unknown' ] \
  && has 'local fails in the proving checkout with the current files, so nothing was proved\..*\$DA_PROVE_MAIN when DA_PROVE is set$' "$tmp/stderr" \
  && has $'\tpass\tlocal\t0\t' "$tmp/stdout" \
  && ok "a check the checkout cannot run proves nothing and says why" || bad "control: rc $pv_rc, $(tail -1 "$tmp/stderr")"
pv_run shared --base "$pv_base" --test test/sum.test.sh; pv_rc=$?
[ "$pv_rc" -eq 0 ] && [ "$(pv_line 12)" = 'fails_without_change=yes' ] \
  && ok "a driver reads what the checkout lacks through DA_PROVE_MAIN, and --base proves a committed change" || bad "shared: rc $pv_rc, $(tail -1 "$tmp/stderr")"
pv_before=$(pv_tree)
GIT_DIR="$pv/.git" GIT_WORK_TREE="$pv" TMPDIR="$tmp/prove-tmp" bash "$pv_verify" prove shared --base "$pv_base" --test test/sum.test.sh --root "$pv" >"$tmp/stdout" 2>"$tmp/stderr"; pv_rc=$?
[ "$pv_rc" -eq 0 ] && [ "$(pv_tree)" = "$pv_before" ] \
  && ok "a caller's Git environment cannot aim prove at the session's repository" || bad "GIT_DIR: rc $pv_rc, HEAD $(git -C "$pv" rev-parse --abbrev-ref HEAD), $(tail -1 "$tmp/stderr")"
mkdir -p "$pv/gen"
printf 'echo kept\n' >"$pv/gen/double.sh"
printf 'echo broken\n' >"$pv/tmp/scratch/double.broken"
pv_run linked --break gen/double.sh=tmp/scratch/double.broken; pv_rc=$?
[ "$pv_rc" -eq 1 ] && [ "$(pv_line 11)" = 'proof=none' ] && [ "$(cat "$pv/gen/double.sh")" = 'echo kept' ] \
  && has 'gen/double\.sh passes through a symbolic link in the proving checkout, so nothing was proved' "$tmp/stderr" \
  && ok "prove never writes through a link that leads out of its checkout" || bad "link: rc $pv_rc, gen holds $(cat "$pv/gen/double.sh"), $(tail -1 "$tmp/stderr")"
touch "$pv/src/calc.sh"
pv_index=$(git hash-object "$pv/.git/index")
chmod 444 "$pv/gen/double.sh"
pv_run readonly --base "$pv_base" --test test/sum.test.sh; pv_rc=$?
[ "$pv_rc" -eq 0 ] && [ -z "$(ls "$tmp/prove-tmp")" ] \
  && ok "a folder the driver leaves read-only or closed does not block the proof or its cleanup" || bad "read-only: rc $pv_rc, left $(ls "$tmp/prove-tmp"), $(tail -1 "$tmp/stderr")"
[ ! -w "$pv/gen/double.sh" ] && ok "a project file the driver hard-linked into the checkout keeps its mode" || bad "prove changed the mode of a hard-linked project file"
chmod 644 "$pv/gen/double.sh"
: >"$pv/src/flag"
pv_run flagged --test test/sum.test.sh; pv_rc=$?
[ "$pv_rc" -eq 1 ] && [ "$(pv_line 11)" = 'proof=none' ] && has 'flagged already fails at [0-9a-f]* without the test files, so a failure there proves nothing\. If that is because it found no test to run, make .*checks\.sh exit 0 for that case when DA_PROVE is set\. Otherwise prove a narrower check that passes at the base$' "$tmp/stderr" \
  && ok "a check that already fails at the base proves nothing" || bad "red base: rc $pv_rc, $(pv_line 12), $(tail -1 "$tmp/stderr")"
rm "$pv/src/flag"
[ "$(git hash-object "$pv/.git/index")" = "$pv_index" ] \
  && ok "prove does not refresh the session's index" || bad "prove rewrote the index"
pv_orphan=$(git -C "$pv" commit-tree -m unrelated "$(git -C "$pv" hash-object -t tree /dev/null)")
pv_run test --base "$pv_orphan" --test test/sum.test.sh; pv_rc=$?
[ "$pv_rc" -eq 1 ] && [ "$(pv_line 11)" = 'proof=none' ] && has 'is no ancestor of HEAD, so nothing was proved' "$tmp/stderr" \
  && ok "a base that is no ancestor of HEAD proves nothing" || bad "orphan base: rc $pv_rc, $(tail -1 "$tmp/stderr")"
pv_run built --break src/calc.sh=tmp/scratch/calc.broken; pv_rc=$?
[ "$pv_rc" -eq 0 ] && [ "$(pv_line 12)" = 'fails_without_change=yes' ] \
  && ok "a broken copy is a whole second newer than what the control run built" || bad "mtime build: rc $pv_rc, $(tail -1 "$tmp/stderr")"
DA_PROVE=1 DA_PROVE_MAIN=/nonexistent bash "$pv_verify" run plain --root "$pv" >"$tmp/stdout" 2>"$tmp/stderr"; pv_rc=$?
[ "$pv_rc" -eq 0 ] && ok "a caller's DA_PROVE does not reach a run of the current tree" || bad "DA_PROVE leak: rc $pv_rc, $(tail -1 "$tmp/stderr")"
pv_run slow --base "$pv_base" --test test/sum.test.sh --timeout 3; pv_rc=$?
[ "$pv_rc" -eq 1 ] && [ "$(pv_line 11)" = 'proof=none' ] && [ "$(pv_line 12)" = 'fails_without_change=unknown' ] && has 'timed out at [0-9a-f]*, so nothing was proved' "$tmp/stderr" \
  && ok "a run that times out without the change proves nothing" || bad "timeout: rc $pv_rc, $(pv_line 12), $(tail -1 "$tmp/stderr")"
TMPDIR="$tmp/prove-tmp" bash "$pv_verify" prove slow --base "$pv_base" --test test/sum.test.sh --timeout 60 --root "$pv" >/dev/null 2>&1 &
pv_pid=$!
pv_wait=0
until compgen -G "$tmp/prove-tmp/verify-prove.*/one" >/dev/null || [ "$pv_wait" -ge 600 ]; do sleep 0.05; pv_wait=$((pv_wait + 1)); done
kill -TERM "$pv_pid" 2>/dev/null
wait "$pv_pid" 2>/dev/null
[ "$pv_wait" -lt 600 ] && [ -z "$(ls "$tmp/prove-tmp")" ] \
  && ok "an interrupted prove removes its checkout" || bad "interrupt left: $(ls "$tmp/prove-tmp") after $pv_wait polls"
printf 'false\n' >"$pv/test/red.test.sh"
pv_run test --test test/sum.test.sh; pv_rc=$?
[ "$pv_rc" -eq 1 ] && has $'\tfail\ttest\t1\t' "$tmp/stdout" && [ "$(pv_line 11)" = 'proof=none' ] \
  && has 'test does not pass on the current tree, so there is nothing to prove' "$tmp/stderr" \
  && ok "a check that fails now is recorded as a failed run with no proof" || bad "red: rc $pv_rc, $(tail -1 "$tmp/stderr")"
rm "$pv/test/red.test.sh"
ln -s sum.test.sh "$pv/test/link.test.sh"
pv_rows=0
while IFS='|' read -r pv_want pv_args; do
  # shellcheck disable=SC2086
  TMPDIR="$tmp/prove-tmp" bash "$pv_verify" prove test $pv_args --root "$pv" >"$tmp/stdout" 2>"$tmp/stderr"; pv_rc=$?
  [ "$pv_rc" -eq 2 ] && has "$pv_want" "$tmp/stderr" && ok "prove refuses: $pv_want" || bad "prove usage ($pv_args): rc $pv_rc, $(tail -1 "$tmp/stderr")"
  pv_rows=$((pv_rows + 1))
done <<'EOF'
prove needs --test PATH|
base and --break were both given|--base HEAD --break src/calc.sh=tmp/scratch/calc.broken
without a leading slash, \.\., or \.git|--test ../outside
without a leading slash, \.\., or \.git|--test .git/config
without a leading slash, \.\., or \.git|--test .GIT
test names no regular file|--test test/none.test.sh
test names no regular file|--test test/link.test.sh
break takes PATH=FILE|--break src/calc.sh
EOF
[ "$pv_rows" -eq 8 ] && ok "every prove usage row ran" || bad "prove usage rows ran: $pv_rows"
pm="$tmp/prove-mono"
mkdir -p "$pm/pkg/.agent/scripts" "$pm/pkg/test"
cp "$here/verify.sh" "$here/runtime.sh" "$pv/.agent/scripts/verify.conf" "$pm/pkg/.agent/scripts/"
printf '#!/usr/bin/env bash\nbash test/one.test.sh\n' >"$pm/pkg/.agent/scripts/checks.sh"
printf '.agent/\n' >"$pm/.gitignore"
printf 'old\n' >"$pm/pkg/value"
printf 'true\n' >"$pm/pkg/test/one.test.sh"
git -C "$pm" init -q
git -C "$pm" config user.email test@example.invalid
git -C "$pm" config user.name Test
git -C "$pm" add .
git -C "$pm" commit -qm base
printf 'new\n' >"$pm/pkg/value"
printf '[ "$(cat value)" = new ]\n' >"$pm/pkg/test/one.test.sh"
TMPDIR="$tmp/prove-tmp" bash "$pm/pkg/.agent/scripts/verify.sh" prove test --test test/one.test.sh --root "$pm/pkg" >"$tmp/stdout" 2>"$tmp/stderr"; pv_rc=$?
[ "$pv_rc" -eq 0 ] && ok "prove works for a node below the Git top level" || bad "prove in a subfolder: rc $pv_rc, $(tail -1 "$tmp/stderr")"
# Enough shared lines for Git to read the move below as a rename.
printf ': one\n: two\n: three\n: four\n: five\n[ "$(cat value)" = new ]\n' >"$pm/pkg/test/one.test.sh"
git -C "$pm" add -A
git -C "$pm" commit -qm change
git -C "$pm" mv pkg/test/one.test.sh pkg/test/two.test.sh
printf '#!/usr/bin/env bash\nfor f in test/*.test.sh; do bash "$f" || exit 1; done\n' >"$pm/pkg/.agent/scripts/checks.sh"
printf 'newer\n' >"$pm/pkg/value"
printf ': one\n: two\n: three\n: four\n: five\n[ "$(cat value)" = newer ]\n' >"$pm/pkg/test/two.test.sh"
TMPDIR="$tmp/prove-tmp" bash "$pm/pkg/.agent/scripts/verify.sh" prove test --test test/two.test.sh --root "$pm/pkg" >"$tmp/stdout" 2>"$tmp/stderr"; pv_rc=$?
[ "$pv_rc" -eq 0 ] && ok "a renamed file leaves no old copy in the proving checkout" || bad "rename: rc $pv_rc, $(tail -1 "$tmp/stderr")"

printf '1..%s\n' "$((pass + fail))"
printf '# passed %s; failed %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
