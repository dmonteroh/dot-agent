#!/usr/bin/env bash
# evals/run-arm.sh — one arm, every eval in a spec, into one workspace, up to
# --jobs N evals at a time.
#
# Usage: run-arm.sh [--jobs N] [--agent claude|codex] [--spec <spec.json>]
#                   [--evals <id,id,...>] <workspace> <arm> <corpus-ref>
#
# run.sh locks only its metadata writes (arm-map.json, run-config.json), so
# concurrent invocations into one workspace are safe, and --treatment-arm may
# be passed on every one of them: only a mismatch is refused. Each eval's own
# output goes to <workspace>/logs/<id>.log; <workspace>/run.log carries one
# line per finished eval and an ARM DONE line. Grooming and the multi-file
# feature evals start first, so the batch's wall time tracks the slowest eval
# rather than the order of the spec. REPEATS comes from agents.conf, or from
# the file EVALS_AGENTS_CONF names. --spec selects an alternate prompt set
# (heldout.json) through EVALS_SPEC.

set -u

selfdir=$(cd "$(dirname "$0")" && pwd)
reporoot=$(cd "$selfdir/.." && pwd)

usage() {
  cat <<'USAGE'
Usage: run-arm.sh [--jobs N] [--agent claude|codex] [--spec <spec.json>]
                  [--evals <id,id,...>] <workspace> <arm> <corpus-ref>

Runs every eval in the spec (default: spec.json; --evals narrows it) for one
arm into one workspace, N at a time (default 1). Per-eval output lands in
<workspace>/logs/<id>.log; <workspace>/run.log summarises.
USAGE
}

jobs=1
agent=claude
spec=""
only=""
while [ $# -gt 0 ]; do
  case "$1" in
  --jobs) jobs="${2:-}"; shift 2 ;;
  --agent) agent="${2:-}"; shift 2 ;;
  --spec) spec="${2:-}"; shift 2 ;;
  --evals) only="${2:-}"; shift 2 ;;
  -h | --help) usage; exit 0 ;;
  --*) echo "run-arm.sh: unknown flag: $1" >&2; usage >&2; exit 2 ;;
  *) break ;;
  esac
done
[ $# -eq 3 ] || { usage >&2; exit 2; }
workspace="$1"; arm="$2"; ref="$3"
case "$jobs" in "" | *[!0-9]*) echo "run-arm.sh: --jobs must be a whole number (got '$jobs')" >&2; exit 2 ;; esac

if [ -n "$spec" ]; then
  spec=$(cd "$(dirname "$spec")" && pwd)/$(basename "$spec")
  [ -f "$spec" ] || { echo "run-arm.sh: no such spec: $spec" >&2; exit 2; }
  export EVALS_SPEC="$spec"
fi
specfile="${spec:-$selfdir/spec.json}"

mkdir -p "$workspace/logs" || exit 1
workspace=$(cd "$workspace" && pwd)
log="$workspace/run.log"

# Eval ids from the spec, slowest first. The five named here are the ones
# that took the longest in every run so far; the rest follow in spec order.
ids=$(python3 -c '
import json, sys
ids = [e["id"] for e in json.load(open(sys.argv[1]))["evals"]]
only = [x for x in sys.argv[2].split(",") if x]
if only:
    missing = [x for x in only if x not in ids]
    if missing:
        sys.exit("run-arm.sh: not in the spec: " + ", ".join(missing))
    ids = [i for i in ids if i in only]
slow = ["groom-acts-on-flags", "routing-catalog-first", "continuity-writes-back", "verify-no-false-done", "comments-feature"]
print("\n".join([i for i in slow if i in ids] + [i for i in ids if i not in slow]))
' "$specfile" "$only") || exit 2

export RUN_ARM_WORKSPACE="$workspace" RUN_ARM_ARM="$arm" RUN_ARM_REF="$ref" RUN_ARM_AGENT="$agent" RUN_ARM_LOG="$log" RUN_ARM_ROOT="$reporoot"
run_one() {
  local id="$1" rc
  (cd "$RUN_ARM_ROOT" && evals/run.sh --eval "$id" --arm "$RUN_ARM_ARM" --treatment-arm "$RUN_ARM_ARM" \
    --agent "$RUN_ARM_AGENT" --corpus-ref "$RUN_ARM_REF" --workspace "$RUN_ARM_WORKSPACE") \
    >"$RUN_ARM_WORKSPACE/logs/$id.log" 2>&1
  rc=$?
  echo "== $(date +%H:%M:%S) $RUN_ARM_ARM $id exit=$rc" >>"$RUN_ARM_LOG"
}
export -f run_one

echo "START $arm ref=$ref agent=$agent jobs=$jobs spec=$(basename "$specfile") $(date +%H:%M:%S)" >>"$log"
printf '%s\n' "$ids" | xargs -n 1 -P "$jobs" bash -c 'run_one "$0"'
echo "ARM DONE $arm $(date +%H:%M:%S)" >>"$log"
