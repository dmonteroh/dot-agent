#!/usr/bin/env bash
# evals/run-arm.sh — one arm, every eval in a spec, into one workspace, up to
# --jobs N evals at a time.
#
# Usage: run-arm.sh [--jobs N] [--agent claude|codex] [--spec <spec.json>]
#                   [--evals <id,id,...>] [--harness node|generic|none]
#                   [--index-mode manual|generated]
#                   [--treatment-arm <name>] <workspace> <arm> <corpus-ref>
#
# run.sh locks only its metadata writes (arm-map.json, run-config.json), so
# concurrent invocations into one workspace are safe, and --treatment-arm may
# be passed on every one of them: only a mismatch is refused. Each eval's own
# output goes to <workspace>/logs/<arm>/<id>.log — per arm, because two arms
# of one workspace run the same eval ids, and a shared logs/<id>.log is a
# race whose loser silently overwrites the winner's console output.
# <workspace>/run.log carries one line per finished eval and an ARM DONE
# line. Grooming and the multi-file feature evals start first, so the batch's
# wall time tracks the slowest eval rather than the order of the spec.
# REPEATS comes from agents.conf, or from the file EVALS_AGENTS_CONF names.
# --spec selects an alternate prompt set (heldout.json) through EVALS_SPEC.
# --harness builds the arm's fixtures with the node replaced by a plain
# instructions file (generic) or by nothing at all (none), which is how a
# whole arm asks what the node itself is worth rather than what one revision
# of it changed. --index-mode (default manual) selects run.sh's own
# --index-mode flag: the node-mode arm variable's generated-vs-manual
# comparison. A workspace records one treatment arm and refuses any run
# that disagrees, so every arm but the treatment needs --treatment-arm
# naming it. Passing it on both arms lets them start together: whichever run
# reaches the fresh iteration first records the same design.

set -u

selfdir=$(cd "$(dirname "$0")" && pwd)
reporoot=$(cd "$selfdir/.." && pwd)

usage() {
  cat <<'USAGE'
Usage: run-arm.sh [--jobs N] [--agent claude|codex] [--spec <spec.json>]
                  [--evals <id,id,...>] [--harness node|generic|none]
                  [--index-mode manual|generated]
                  [--treatment-arm <name>] <workspace> <arm> <corpus-ref>

Runs every eval in the spec (default: spec.json; --evals narrows it) for one
arm into one workspace, N at a time (default 1). Per-eval output lands in
<workspace>/logs/<arm>/<id>.log; <workspace>/run.log summarises. --harness
builds the arm without the node: 'generic' leaves a plain instructions file,
'none' leaves neither. --index-mode (default manual) builds the arm's
fixtures generated or manual — the node-mode arm variable's own comparison.
--treatment-arm defaults to <arm>; pass it on every arm of a workspace so
both arms agree on which one is the treatment, and either may create the
workspace.
USAGE
}

jobs=1
agent=claude
spec=""
only=""
harness=node
index_mode=manual
treatment=""
while [ $# -gt 0 ]; do
  case "$1" in
  --jobs) jobs="${2:-}"; shift 2 ;;
  --agent) agent="${2:-}"; shift 2 ;;
  --spec) spec="${2:-}"; shift 2 ;;
  --evals) only="${2:-}"; shift 2 ;;
  --harness) harness="${2:-}"; shift 2 ;;
  --index-mode) index_mode="${2:-}"; shift 2 ;;
  --treatment-arm) treatment="${2:-}"; shift 2 ;;
  -h | --help) usage; exit 0 ;;
  --*) echo "run-arm.sh: unknown flag: $1" >&2; usage >&2; exit 2 ;;
  *) break ;;
  esac
done
[ $# -eq 3 ] || { usage >&2; exit 2; }
workspace="$1"; arm="$2"; ref="$3"
treatment="${treatment:-$arm}"
case "$jobs" in "" | *[!0-9]*) echo "run-arm.sh: --jobs must be a whole number (got '$jobs')" >&2; exit 2 ;; esac
case "$harness" in
node) harness_flag="" ;;
generic) harness_flag="--generic-claude" ;;
none) harness_flag="--no-harness" ;;
*) echo "run-arm.sh: --harness must be node, generic, or none (got '$harness')" >&2; exit 2 ;;
esac
case "$index_mode" in
manual | generated) ;;
*) echo "run-arm.sh: --index-mode must be manual or generated (got '$index_mode')" >&2; exit 2 ;;
esac

if [ -n "$spec" ]; then
  spec=$(cd "$(dirname "$spec")" && pwd)/$(basename "$spec")
  [ -f "$spec" ] || { echo "run-arm.sh: no such spec: $spec" >&2; exit 2; }
  export EVALS_SPEC="$spec"
fi
specfile="${spec:-$selfdir/spec.json}"

mkdir -p "$workspace/logs/$arm" || exit 1
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

export RUN_ARM_WORKSPACE="$workspace" RUN_ARM_ARM="$arm" RUN_ARM_REF="$ref" RUN_ARM_AGENT="$agent" RUN_ARM_LOG="$log" RUN_ARM_ROOT="$reporoot" RUN_ARM_HARNESS_FLAG="$harness_flag" RUN_ARM_INDEX_MODE="$index_mode" RUN_ARM_TREATMENT="$treatment"
run_one() {
  local id="$1" rc
  # Unquoted on purpose: empty means the default node fixture, and an empty
  # quoted word would reach run.sh as an argument it rejects.
  # shellcheck disable=SC2086
  (cd "$RUN_ARM_ROOT" && evals/run.sh --eval "$id" --arm "$RUN_ARM_ARM" --treatment-arm "$RUN_ARM_TREATMENT" \
    --agent "$RUN_ARM_AGENT" --corpus-ref "$RUN_ARM_REF" --workspace "$RUN_ARM_WORKSPACE" \
    --index-mode "$RUN_ARM_INDEX_MODE" \
    $RUN_ARM_HARNESS_FLAG) \
    >"$RUN_ARM_WORKSPACE/logs/$RUN_ARM_ARM/$id.log" 2>&1
  rc=$?
  echo "== $(date +%H:%M:%S) $RUN_ARM_ARM $id exit=$rc" >>"$RUN_ARM_LOG"
}
export -f run_one

echo "START $arm ref=$ref agent=$agent harness=$harness index_mode=$index_mode treatment=$treatment jobs=$jobs spec=$(basename "$specfile") $(date +%H:%M:%S)" >>"$log"
printf '%s\n' "$ids" | xargs -n 1 -P "$jobs" bash -c 'run_one "$0"'
echo "ARM DONE $arm $(date +%H:%M:%S)" >>"$log"
