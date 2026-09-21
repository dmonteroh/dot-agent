#!/usr/bin/env bash

set -u

finish_status_stderr=""
finish_status_stdout=""
finish_index_stderr=""
cleanup() {
  [ -n "$finish_status_stderr" ] && rm -f "$finish_status_stderr"
  [ -n "$finish_status_stdout" ] && rm -f "$finish_status_stdout"
  [ -n "$finish_index_stderr" ] && rm -f "$finish_index_stderr"
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage: checkpoint.sh --tool <name> --area <name> --verify <pass|fail|n/a> --summary "…" [--base <ref>] [root]

Runs, in order: comments.sh against --base (default: HEAD over uncommitted
work), status.sh printing only its flag lines, then log.sh with the same
--tool/--area/--verify/--summary. Stops before the log entry when the gate
blocks or a flag stands, so a re-run appends once. A clean tree with no
--base changed nothing: no entry is written and the script exits 1.
EOF
}

base=""
root="."
logargs=()
while [ $# -gt 0 ]; do
  case "$1" in
  --tool | --area | --verify | --summary)
    if [ $# -lt 2 ]; then
      echo "checkpoint.sh: $1 needs a value" >&2; usage >&2; exit 1
    fi
    logargs+=("$1" "$2"); shift 2 ;;
  --base)
    if [ $# -lt 2 ]; then
      echo "checkpoint.sh: --base needs a value" >&2; usage >&2; exit 1
    fi
    base="$2"; shift 2 ;;
  -h | --help)
    usage; exit 0 ;;
  --*)
    echo "checkpoint.sh: unknown flag: $1" >&2; usage >&2; exit 1 ;;
  *)
    root="$1"; shift ;;
  esac
done

if [ "${#logargs[@]}" -lt 8 ]; then
  echo "checkpoint.sh: --tool, --area, --verify, and --summary are all required" >&2
  usage >&2
  exit 1
fi

scripts="$root/.agent/scripts"
for s in comments.sh log.sh status.sh; do
  [ -f "$scripts/$s" ] || { echo "checkpoint.sh: $scripts/$s is missing — not an initialized node" >&2; exit 1; }
done

gate_rc=0
unchanged=0
if [ -z "$base" ]; then
  if git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
    if [ -n "$(git -C "$root" status --porcelain 2>/dev/null)" ]; then
      base="HEAD"
    else
      unchanged=1
    fi
  fi
fi

if [ "$unchanged" -eq 1 ]; then
  echo "checkpoint.sh: nothing changed — the working tree is clean and no --base was given, so there is no diff to gate and no work to record. A turn that only answered writes no entry. Pass --base <ref> if this session's work is already committed." >&2
  exit 1
fi

if [ -n "$base" ]; then
  echo "== comment gate (comments.sh $base)"
  (cd "$root" && bash "$scripts/comments.sh" "$base")
  gate_rc=$?
  case "$gate_rc" in
  0) ;;
  1)
    echo "checkpoint.sh: the comment gate BLOCKED — delete or rewrite the comments above, then run checkpoint.sh again. No log entry written." >&2
    exit 1 ;;
  *)
    echo "checkpoint.sh: comments.sh exited $gate_rc — read its message above; pass --base <ref> for a committed change. No log entry written." >&2
    exit 1 ;;
  esac
else
  echo "== comment gate: skipped — not a git checkout, so no diff can be read (pass --base <ref> to gate a committed branch)"
fi

echo "== status check"
finish_status_stderr=$(mktemp "${TMPDIR:-/tmp}/finish-status-err.XXXXXX")
finish_status_stdout=$(mktemp "${TMPDIR:-/tmp}/finish-status-out.XXXXXX")
bash "$scripts/status.sh" "$root" 2>"$finish_status_stderr" | grep -E '^(GROOM|REPAIR|INDEX):' >"$finish_status_stdout"
status_rc=${PIPESTATUS[0]}
flags=$(cat "$finish_status_stdout")
if [ "$status_rc" -ne 0 ] || [ -s "$finish_status_stderr" ]; then
  stderr_line=$(tr '\n' ' ' <"$finish_status_stderr" | cut -c1-120)
  [ -n "$stderr_line" ] || stderr_line="none"
  echo "checkpoint.sh: status check failed to run cleanly (status.sh rc=$status_rc, stderr: $stderr_line). No log entry written." >&2
  exit 1
fi
if [ -n "$flags" ]; then
  printf '%s\n' "$flags"
  echo "checkpoint.sh: the flags above are this session's to handle — fix them, then run checkpoint.sh again. No log entry written." >&2
  exit 1
fi
echo "clean"

indexes_line=$(grep -m1 '^  indexes:' "$root/.agent/purpose.md" 2>/dev/null)
indexes=$(printf '%s\n' "$indexes_line" | sed -E 's/^[[:space:]]*indexes:[[:space:]]*([A-Za-z-]+).*/\1/')
[ -n "$indexes" ] || indexes=manual
if [ "$indexes" = generated ]; then
  echo "== cache refresh"
  if [ ! -f "$scripts/index.sh" ]; then
    echo "checkpoint.sh: indexes: generated but .agent/scripts/index.sh is not installed — run node.sh update to obtain it; read .agent/rules/ and .agent/docs/ directly meanwhile." >&2
  else
    finish_index_stderr=$(mktemp "${TMPDIR:-/tmp}/finish-index-err.XXXXXX")
    bash "$scripts/index.sh" ensure --root "$root" >/dev/null 2>"$finish_index_stderr"
    index_rc=$?
    if [ "$index_rc" -ne 0 ]; then
      cat "$finish_index_stderr" >&2
      echo "checkpoint.sh: index refresh failed — the cache no longer reflects this session's writes; read .agent/rules/ and .agent/docs/ directly until the next successful ensure." >&2
    fi
  fi
fi

echo "== session log"
bash "$scripts/log.sh" "${logargs[@]}" "$root" || exit 1
exit 0
