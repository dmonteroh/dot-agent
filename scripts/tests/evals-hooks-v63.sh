#!/usr/bin/env bash
set -eu
unset CDPATH
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/evals-hooks-v63.XXXXXX")
scratch=$(cd "$scratch" && pwd -P)
trap 'rm -rf "$scratch"' EXIT
fail() { echo "FAIL evals-hooks-v63: $*" >&2; exit 1; }
lib="$repo/evals/run_lib.py"
fx="$scratch/fixture"
mkdir -p "$fx/src"

payload='dot-agent session-start hook: the output of `bash .agent/scripts/status.sh --load` for the node at /x follows, run for this session. Read it here and do not make that call again.\n==== .agent/purpose.md ===='
pointer='dot-agent session-start hook: `bash .agent/scripts/status.sh --load` for the node at /x prints 14720 bytes, over this hook'"'"'s 10000-byte limit, so its output is not here.'

# Claude: hook_response events become one hook event per delivered payload.
claude_stream() {
  printf '{"type":"system","subtype":"init","session_id":"s1"}\n'
  printf '{"type":"system","subtype":"hook_response","hook_event":"SessionStart","session_id":"s1","exit_code":0,"stdout":"%s"}\n' "$1"
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"%s/src/a.ts"}}]}}\n' "$fx"
  printf '{"type":"result","subtype":"success","is_error":false,"result":"done"}\n'
}
claude_stream "$payload" >"$scratch/claude-payload.jsonl"
claude_stream "$pointer" >"$scratch/claude-pointer.jsonl"
"$lib" extract-claude-trace "$scratch/claude-payload.jsonl" "$scratch/t1.jsonl" "$scratch/x1.txt" "$fx" r1 "$repo"
first=$(head -n 1 "$scratch/t1.jsonl")
printf '%s' "$first" | grep -qF '"event": "hook"' || fail "payload did not become a hook event: $first"
printf '%s' "$first" | grep -qF '"text": "hook:execute:bash .agent/scripts/status.sh --load"' || fail "hook event text wrong: $first"
[ "$(sed -n 2p "$scratch/t1.jsonl" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["seq"])')" = 1 ] || fail 'call after the hook is not seq 1'
"$lib" extract-claude-trace "$scratch/claude-pointer.jsonl" "$scratch/t2.jsonl" "$scratch/x2.txt" "$fx" r2 "$repo"
! grep -qF '"event": "hook"' "$scratch/t2.jsonl" || fail 'a pointer became a load'
[ "$("$lib" claude-hook-deliveries "$scratch/claude-payload.jsonl" | cut -f1,2)" = "$(printf 's1\tpayload')" ] || fail 'Claude payload delivery not reported'
[ "$("$lib" claude-hook-deliveries "$scratch/claude-pointer.jsonl" | cut -f2)" = pointer ] || fail 'Claude pointer delivery not reported'
sed 's/"exit_code":0/"exit_code":1/' "$scratch/claude-payload.jsonl" >"$scratch/claude-failed.jsonl"
[ "$("$lib" claude-hook-deliveries "$scratch/claude-failed.jsonl" | cut -f2)" = failed ] || fail 'failed hook not reported as failed'

# Codex: deliveries come from the rollout; the trace event opens that thread.
mkdir -p "$scratch/codex-home/sessions/2026/10/27"
{
  printf '{"timestamp":"t0","type":"session_meta","payload":{"id":"th1"}}\n'
  printf '{"timestamp":"t1","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"%s"}]}}\n' "$payload"
  printf '{"timestamp":"t2","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"%s"}]}}\n' "$payload"
} >"$scratch/codex-home/sessions/2026/10/27/rollout-th1.jsonl"
"$lib" codex-hook-deliveries "$scratch/codex-home" >"$scratch/deliveries.txt"
[ "$(wc -l <"$scratch/deliveries.txt" | tr -d '[:space:]')" = 1 ] || fail 'a user message counted as a hook delivery'
[ "$(cut -f1,2 "$scratch/deliveries.txt")" = "$(printf 'th1\tpayload')" ] || fail "Codex delivery wrong: $(cat "$scratch/deliveries.txt")"
{
  printf '{"type":"thread.started","thread_id":"th1"}\n'
  printf '{"type":"item.started","item":{"type":"command_execution","command":"cat src/a.ts"}}\n'
  printf '{"type":"turn.completed"}\n'
} >"$scratch/codex.jsonl"
"$lib" extract-codex-trace "$scratch/codex.jsonl" "$scratch/t3.jsonl" "$scratch/x3.txt" "$fx" r3 "$repo" "$scratch/deliveries.txt"
head -n 1 "$scratch/t3.jsonl" | grep -qF '"event": "hook"' || fail 'Codex thread start lacks the hook event'
"$lib" extract-codex-trace "$scratch/codex.jsonl" "$scratch/t4.jsonl" "$scratch/x4.txt" "$fx" r4 "$repo"
! grep -qF '"event": "hook"' "$scratch/t4.jsonl" || fail 'Codex trace gained a hook event without deliveries'

# Grading: a delivered load satisfies status-first and counts as the one load.
grade_run() {
  rd="$scratch/grade-$1"
  mkdir -p "$rd/outputs"
  cp "$2" "$rd/outputs/trace.jsonl"
  cat >"$rd/snapshot.json" <<'EOF'
{"id": "bootstrap-complete", "assertions": [
  {"id": "bootstrap-complete/status-first", "grade": "auto", "check": "trace_order 'status.sh' before 'src/'", "text": "t", "class": "trace", "concept": "c"},
  {"id": "bootstrap-once/status-once", "grade": "auto", "check": "trace_count 'status.sh' == 1", "text": "t", "class": "trace", "concept": "c"}]}
EOF
  python3 -I "$repo/evals/grade.py" "$rd" "$rd/snapshot.json" >/dev/null
  python3 -I -c 'import json,sys; print(" ".join(str(r["passed"]) for r in json.load(open(sys.argv[1]))["results"]))' "$rd/grading.json"
}
[ "$(grade_run hook "$scratch/t1.jsonl")" = "True True" ] || fail "hook-delivered load not graded as first and once: $(grade_run hook "$scratch/t1.jsonl")"
[ "$(grade_run pointer "$scratch/t2.jsonl")" = "False False" ] || fail 'a pointer with no call was graded as a load'

# Run config: hook-mode records and locks hook_mode; other variables never gain the key.
lockenv() {
  env IT="$1" AV="$2" TA=on AG=claude AM="$3" MD=m CR=ref RP=1 AB=b AV2=v AE=medium AR=b AH=h AO=o \
    HM="${HM:-node}" IM=manual CH=none HKM="$4" "$lib" "$5"
}
mkdir -p "$scratch/it-hook" "$scratch/it-corpus"
lockenv "$scratch/it-hook" hook-mode on session-start lock-run-config-create
lockenv "$scratch/it-hook" hook-mode off none lock-run-config-update
python3 -I -c 'import json,sys; c=json.load(open(sys.argv[1])); assert c["arms"]["on"]["hook_mode"]=="session-start" and c["arms"]["off"]["hook_mode"]=="none" and c["locked_corpus_ref"]=="ref" and c["locked_harness"]=="node"' "$scratch/it-hook/run-config.json" || fail 'hook-mode run-config wrong'
if lockenv "$scratch/it-hook" hook-mode on none lock-run-config-update 2>/dev/null; then fail 'an arm switched hook mode mid-iteration'; fi
if HM=generic lockenv "$scratch/it-hook" hook-mode off none lock-run-config-update 2>/dev/null; then fail 'harness drift accepted in a hook-mode comparison'; fi
lockenv "$scratch/it-corpus" corpus base "" lock-run-config-create
! grep -qF hook_mode "$scratch/it-corpus/run-config.json" || fail 'a corpus comparison recorded hook_mode'

# run.sh: --hook-mode is the hook-mode design, on corpus-variable evals only.
rs() { "$repo/evals/run.sh" --arm on --agent claude --corpus-ref HEAD --workspace "$scratch/ws" "$@" 2>&1; }
rs --eval routing-catalog-first --hook-mode session-start --dry-run --treatment-arm on >/dev/null || fail 'dry run with --hook-mode failed'
python3 -I -c 'import json,sys; c=json.load(open(sys.argv[1])); assert c["arm_variable"]=="hook-mode" and c["arms"]["on"]["hook_mode"]=="session-start"' "$scratch/ws/iteration-1/run-config.json" || fail 'dry run did not lock a hook-mode design'
built=$(find "$scratch/ws/iteration-1" -type d -name fixture | head -n 1)
grep -qF '.agent/scripts/session-start.sh' "$built/.codex/hooks.json" || fail 'session-start fixture lacks the Codex hook'
grep -qF '.agent/scripts/session-start.sh' "$built/.claude/settings.json" || fail 'session-start fixture lacks the Claude hook'
rs --eval routing-catalog-first --hook-mode bogus | grep -qF 'must be none or session-start' || fail 'bad --hook-mode accepted'
rs --eval bootstrap-once --hook-mode none | grep -qF 'varies agent' || fail '--hook-mode accepted on an agent-variable eval'
rs --eval routing-catalog-first --hook-mode none --no-harness | grep -qF 'requires the node harness' || fail '--hook-mode accepted without the node'
"$repo/evals/run-arm.sh" --hook-mode bogus "$scratch/ws2" on HEAD 2>&1 | grep -qF 'must be none or session-start' || fail 'run-arm.sh accepted a bad --hook-mode'

# load_first.py: first event, hook or call.
w="$scratch/lf"
for r in a b c; do mkdir -p "$w/iteration-1/eval-e/$r/outputs"; echo '{}' >"$w/iteration-1/eval-e/$r/grading.json"; done
cp "$scratch/t1.jsonl" "$w/iteration-1/eval-e/a/outputs/trace.jsonl"
printf '{"seq":0,"event":"call","tool":"Bash","action":"execute","text":"execute:bash .agent/scripts/status.sh --load"}\n' >"$w/iteration-1/eval-e/b/outputs/trace.jsonl"
cp "$scratch/t2.jsonl" "$w/iteration-1/eval-e/c/outputs/trace.jsonl"
printf '{"a": "x", "b": "x", "c": "x"}\n' >"$w/iteration-1/arm-map.json"
out=$(python3 -I "$repo/evals/load_first.py" "$w")
printf '%s' "$out" | grep -qF 'load-first 2/3 (67%)  by hook 1, by call 1' || fail "load_first.py wrong: $out"
echo 'ok evals-hooks-v63'
