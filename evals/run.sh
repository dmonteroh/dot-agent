#!/usr/bin/env bash
# evals/run.sh — runs one eval in one arm: builds the fixture at that arm's
# corpus revision, drives the agent, captures the artifact set, and grades
# the auto assertions.
#
# The arm never reaches a path, a filename, or a grading record. It is written
# to arm-map.json alone, which the grader does not open. A run id is a hash of
# the eval id and a nonce, and carries no condition token.
#
# Tunables: agents.conf beside this script, which lists every key. It ships
# with every command line commented out: a run drives the binary and model YOU
# name, and refuses rather than guessing.
#
# Full documentation: evals/README.md.
#
# Usage: run.sh --eval <id> --arm <name> --agent <claude|codex|other>
#                --corpus-ref <ref> --workspace <dir> [--iteration <n>]
#        run.sh --dry-run ...     # build and print, drive nothing
#        run.sh --list-arms       # what agents.conf actually has configured

set -u

selfdir=$(cd "$(dirname "$0")" && pwd)
conf="$selfdir/agents.conf"
spec="$selfdir/spec.json"

conf_get() { sed -n "s/^$1=//p" "$conf" 2>/dev/null | head -n 1; }

usage() { sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//;$d'; }

REPEATS=$(conf_get REPEATS); REPEATS=${REPEATS:-1}
TIMEOUT=$(conf_get TIMEOUT); TIMEOUT=${TIMEOUT:-900}

if [ "${1:-}" = "--list-arms" ]; then
  echo "Agents configured in agents.conf:"
  found=0
  for arm in CLAUDE CODEX OTHER; do
    cmd=$(conf_get "${arm}_CMD")
    if [ -n "$cmd" ]; then
      printf '  %-8s model=%-24s cmd=%s\n' "$(echo "$arm" | tr 'A-Z' 'a-z')" \
        "$(conf_get "${arm}_MODEL")" "$cmd"
      found=1
    else
      printf '  %-8s (not configured — its command line is still commented out)\n' \
        "$(echo "$arm" | tr 'A-Z' 'a-z')"
    fi
  done
  [ "$found" -eq 0 ] && echo "
None are configured. Uncomment one in agents.conf and give it the exact
invocation your install uses. Nothing here is guessed for you, because a
wrong flag would silently drive the wrong model and the delta would be
attributed to the corpus."
  exit 0
fi

case "${1:-}" in -h | --help | "") usage; exit 0 ;; esac

evalid=""; arm=""; agent=""; corpus_ref=""; workspace=""; iteration="1"; dry=0
while [ $# -gt 0 ]; do
  case "$1" in
  --eval) evalid="${2:-}"; shift 2 ;;
  --arm) arm="${2:-}"; shift 2 ;;
  --agent) agent="${2:-}"; shift 2 ;;
  --corpus-ref) corpus_ref="${2:-}"; shift 2 ;;
  --workspace) workspace="${2:-}"; shift 2 ;;
  --iteration) iteration="${2:-}"; shift 2 ;;
  --dry-run) dry=1; shift ;;
  *) echo "run.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

for req in evalid arm agent corpus_ref workspace; do
  eval "v=\$$req"
  [ -n "$v" ] || { echo "run.sh: --${req%id} is required" >&2; usage >&2; exit 2; }
done

command -v python3 >/dev/null 2>&1 || { echo "run.sh: python3 not found" >&2; exit 2; }

# The eval's own entry, read from the frozen spec. A run that invented its
# prompt would not be comparable with the other arm, which is the whole point.
entry=$(EVALID="$evalid" SPEC="$spec" python3 -c '
import json, os, sys
spec = json.load(open(os.environ["SPEC"], encoding="utf-8"))
for e in spec["evals"]:
    if e["id"] == os.environ["EVALID"]:
        json.dump(e, sys.stdout); break
else:
    sys.exit(1)') || {
  echo "run.sh: no eval with id '$evalid' in spec.json" >&2; exit 2; }

fixture=$(printf '%s' "$entry" | python3 -c 'import json,sys; print(json.load(sys.stdin)["fixture"])')
prompt=$(printf '%s' "$entry" | python3 -c 'import json,sys; print(json.load(sys.stdin)["prompt"])')

up=$(printf '%s' "$agent" | tr 'a-z' 'A-Z')
agent_cmd=$(conf_get "${up}_CMD")
agent_model=$(conf_get "${up}_MODEL")
agent_trace=$(conf_get "${up}_TRACE")

if [ "$dry" -eq 0 ] && [ -z "$agent_cmd" ]; then
  cat >&2 <<EOF
run.sh: agent '$agent' has no command line in agents.conf.

Nothing is guessed for you. A wrong flag drives the wrong binary or the wrong
model, the run still produces numbers, and the delta gets attributed to the
corpus. Uncomment ${up}_CMD in $conf and put your own invocation in it, then
re-run. --list-arms shows what is configured, --dry-run builds the fixture
and prints the prompt without driving anything.
EOF
  exit 2
fi

iterdir="$workspace/iteration-$iteration"
mkdir -p "$iterdir" || exit 1

# The run id is a hash, so nothing about the arm survives into a path the
# grader will see. The mapping lives in arm-map.json and nowhere else.
runid=$(printf '%s|%s|%s' "$evalid" "$arm" "$(date +%s%N 2>/dev/null || date +%s)" \
  | cksum | awk '{printf "r%08x", $1}')
evaldir="$iterdir/eval-$evalid"
rundir="$evaldir/$runid"
mkdir -p "$rundir/outputs" || exit 1

# The snapshot is what grading reads, so an eval edited later cannot silently
# change what an earlier iteration was graded against.
printf '%s\n' "$entry" | python3 -m json.tool >"$evaldir/eval-snapshot.json"

fixdir="$rundir/fixture"
"$selfdir/fixtures.sh" "$fixture" "$fixdir" --corpus-ref "$corpus_ref" \
  >"$rundir/fixture-build.txt" 2>&1 || {
  echo "run.sh: fixture build failed — see $rundir/fixture-build.txt" >&2; exit 1; }
base=$(git -C "$fixdir" rev-parse HEAD)

cat >"$rundir/run-meta.json" <<EOF
{
  "eval": "$evalid",
  "fixture": "$fixture",
  "fixture_base": "$base",
  "corpus_ref": "$corpus_ref",
  "agent": "$agent",
  "model": "${agent_model:-not recorded}",
  "trace_format": "${agent_trace:-none}",
  "timeout_s": $TIMEOUT,
  "started": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

python3 - "$iterdir/arm-map.json" "$runid" "$arm" <<'PY'
import json, os, sys
path, runid, arm = sys.argv[1], sys.argv[2], sys.argv[3]
m = json.load(open(path, encoding="utf-8")) if os.path.exists(path) else {}
m[runid] = arm
json.dump(m, open(path, "w", encoding="utf-8"), indent=2, sort_keys=True)
PY

if [ "$dry" -eq 1 ]; then
  cat <<EOF
run.sh: dry run — nothing was driven.
  eval:     $evalid
  fixture:  $fixdir  (base $base)
  agent:    $agent  model=${agent_model:-unset}  trace=${agent_trace:-none}
  run dir:  $rundir

Prompt, verbatim:
------------------------------------------------------------------
$prompt
------------------------------------------------------------------

Open a session in the fixture directory, paste that prompt, then capture the
artifacts into $rundir/outputs/ and run:
  evals/grade.sh $rundir $evaldir/eval-snapshot.json
EOF
  exit 0
fi

# Drive the agent. The command comes from the conf verbatim with the three
# placeholders substituted; nothing else about it is interpreted here.
cmd=$agent_cmd
cmd=${cmd//\{model\}/$agent_model}
cmd=${cmd//\{cwd\}/$fixdir}
quoted=$(printf '%s' "$prompt" | sed "s/'/'\\\\''/g")
cmd=${cmd//\{prompt\}/\'$quoted\'}

# timeout(1) is GNU coreutils and is absent from a stock macOS, where the
# reference deployments run. Without this the wrapper is a command-not-found
# and every run exits 127 having driven nothing — while still producing a full
# set of artifacts and a plausible grading record.
timeout_bin=""
for cand in timeout gtimeout; do
  command -v "$cand" >/dev/null 2>&1 && { timeout_bin="$cand"; break; }
done
if [ -n "$timeout_bin" ]; then
  ( cd "$fixdir" && eval "$timeout_bin ${TIMEOUT}s $cmd" ) \
    >"$rundir/outputs/agent-stdout.txt" 2>"$rundir/outputs/agent-stderr.txt"
  rc=$?
  [ "$rc" -eq 124 ] && echo "run.sh: agent hit the ${TIMEOUT}s timeout" >&2
else
  echo "run.sh: no timeout(1) — running unbounded. Install coreutils for gtimeout, or watch the run." >&2
  ( cd "$fixdir" && eval "$cmd" ) \
    >"$rundir/outputs/agent-stdout.txt" 2>"$rundir/outputs/agent-stderr.txt"
  rc=$?
fi

# A run that drove nothing must not produce a grading record that reads like
# one that did. 127 is command-not-found, which is a misconfigured arm.
if [ "$rc" -eq 127 ]; then
  echo "run.sh: the agent command exited 127 (not found). Check ${up}_CMD in agents.conf — nothing was driven and this run is void." >&2
  exit 2
fi

# ---- capture the artifact set ------------------------------------------
# Same names in every run of every arm, so the grader looks in the same
# places both times and neither arm can win by reshaping its deliverable.

git -C "$fixdir" add -A >/dev/null 2>&1
git -C "$fixdir" diff --cached "$base" -- . ':(exclude).agent' \
  >"$rundir/outputs/diff.patch" 2>/dev/null
git -C "$fixdir" diff --cached "$base" -- .agent \
  >"$rundir/outputs/node-diff.patch" 2>/dev/null

( cd "$fixdir" && find .agent -type f -print0 2>/dev/null \
  | xargs -0 -I{} sh -c 'printf "== %s\n" "{}"; cat "{}"' ) \
  >"$rundir/outputs/node-tree.txt" 2>/dev/null

bash "$fixdir/.agent/scripts/status.sh" "$fixdir" \
  >"$rundir/outputs/status-after.txt" 2>&1

( cd "$fixdir" && bash .agent/scripts/comments.sh "$base" ) \
  >"$rundir/outputs/gate.txt" 2>&1

cp "$rundir/outputs/agent-stdout.txt" "$rundir/outputs/session-transcript.txt"

# The trace is what makes the ordering assertions gradeable. Normalized to
# one {"seq","text"} object per line, so a check reads the same whatever the
# agent emitted. An agent with no structured output gets no trace file, and
# grade.sh then fails its trace assertions with the reason named rather than
# passing them by default.
case "${agent_trace:-none}" in
stream-json)
  python3 - "$rundir/outputs/agent-stdout.txt" "$rundir/outputs/trace.jsonl" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
def walk(o, out):
    if isinstance(o, dict):
        for k, v in o.items():
            if isinstance(v, str):
                out.append("%s=%s" % (k, v))
            else:
                walk(v, out)
    elif isinstance(o, list):
        for v in o:
            walk(v, out)
seq = 0
with open(dst, "w", encoding="utf-8") as w:
    for line in open(src, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        parts = []
        walk(ev, parts)
        text = " ".join(parts)
        if not text:
            continue
        w.write(json.dumps({"seq": seq, "text": text}) + "\n")
        seq += 1
PY
  ;;
*)
  echo "run.sh: agent '$agent' has TRACE=${agent_trace:-none} — no trace captured, so this run's trace assertions will grade as unjudgeable" >&2
  ;;
esac

"$selfdir/grade.sh" "$rundir" "$evaldir/eval-snapshot.json"

cat <<EOF

run.sh: $evalid / arm hidden in arm-map.json / agent $agent (${agent_model:-model not recorded})
  run dir: $rundir
  agent exit: $rc
Run the other arm before reading anything into this. A single arm's pass rate
is not a result.
EOF
