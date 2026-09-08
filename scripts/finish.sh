#!/usr/bin/env bash
# finish.sh — the end-of-session call, in one command: the comment gate
# against the change's true parent, the session-log entry, and a re-run of
# the status check so a flag this session left behind is seen before the
# hand-back. Three calls became one because every call re-reads the whole
# context; the work each does is unchanged and lives in the scripts it
# calls (comments.sh, log.sh, status.sh).
#
# The gate and the status check run first and stop the script on a BLOCK or
# a standing flag: a log entry is a claim the session finished, and it is
# not written over a diff the gate refused or a node still flagged. Fix,
# run finish.sh again; the entry is appended once, on the clean run.
#
# Usage: finish.sh --tool <name> --area <name> --verify <pass|fail|n/a> --summary "…" [--base <ref>] [root]
#
# --base names the change's true parent for the gate — the branch base when
# the work is committed. Without it, uncommitted work is gated against HEAD.
# A clean tree with no --base is a turn that changed nothing: there is
# nothing to gate and nothing to log, and the script says so and stops.
# root defaults to . — the node's project root.

set -u

selfdir=$(cd "$(dirname "$0")" && pwd)

usage() {
  cat <<'EOF'
Usage: finish.sh --tool <name> --area <name> --verify <pass|fail|n/a> --summary "…" [--base <ref>] [root]

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
      echo "finish.sh: $1 needs a value" >&2; usage >&2; exit 1
    fi
    logargs+=("$1" "$2"); shift 2 ;;
  --base)
    if [ $# -lt 2 ]; then
      echo "finish.sh: --base needs a value" >&2; usage >&2; exit 1
    fi
    base="$2"; shift 2 ;;
  -h | --help)
    usage; exit 0 ;;
  --*)
    echo "finish.sh: unknown flag: $1" >&2; usage >&2; exit 1 ;;
  *)
    root="$1"; shift ;;
  esac
done

if [ "${#logargs[@]}" -lt 8 ]; then
  echo "finish.sh: --tool, --area, --verify, and --summary are all required" >&2
  usage >&2
  exit 1
fi

scripts="$root/.agent/scripts"
for s in comments.sh log.sh status.sh; do
  [ -f "$scripts/$s" ] || { echo "finish.sh: $scripts/$s is missing — not an initialized node" >&2; exit 1; }
done

# 1. The comment gate. comments.sh reads the diff relative to the caller's
#    working directory, so it runs from the project root.
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

# A turn that changed nothing is not a session that finished. The entry
# point's bootstrap is scoped to the conversation but the hand-back is not —
# handing back happens on every message — so an unqualified finish.sh runs
# per turn while the artifact it writes is per session: one measured
# three-turn session wrote three log entries, two of them a question
# answered. At a hundred messages that is a hundred entries riding the
# printed tail into every future session. The clean tree is the observable
# the agent lacks: no diff to gate, nothing verified, nothing to record.
# Committed work still logs — it names its parent with --base — and a
# project that is not a git checkout has no signal here, so it keeps the
# old behavior rather than being refused on a guess.
if [ "$unchanged" -eq 1 ]; then
  echo "finish.sh: nothing changed — the working tree is clean and no --base was given, so there is no diff to gate and no work to record. A turn that only answered writes no entry. Pass --base <ref> if this session's work is already committed." >&2
  exit 1
fi

if [ -n "$base" ]; then
  echo "== comment gate (comments.sh $base)"
  (cd "$root" && bash "$scripts/comments.sh" "$base")
  gate_rc=$?
  case "$gate_rc" in
  0) ;;
  1)
    echo "finish.sh: the comment gate BLOCKED — delete or rewrite the comments above, then run finish.sh again. No log entry written." >&2
    exit 1 ;;
  *)
    echo "finish.sh: comments.sh exited $gate_rc — read its message above; pass --base <ref> for a committed change. No log entry written." >&2
    exit 1 ;;
  esac
else
  echo "== comment gate: skipped — not a git checkout, so no diff can be read (pass --base <ref> to gate a committed branch)"
fi

# 2. The status check, flags only, before the log entry: a flag still
#    standing — one this session inherited and did not handle, or one its
#    own edit introduced (a doc without its routing row) — is this session's
#    to fix, and the log entry is written once, after the node is clean, so
#    a second finish.sh run never appends a duplicate.
echo "== status check"
flags=$(bash "$scripts/status.sh" "$root" 2>/dev/null | grep -E '^(GROOM|REPAIR|INDEX):' || true)
if [ -n "$flags" ]; then
  printf '%s\n' "$flags"
  echo "finish.sh: the flags above are this session's to handle — fix them, then run finish.sh again. No log entry written." >&2
  exit 1
fi
echo "clean"

# 3. The session-log entry, through log.sh's own checks.
echo "== session log"
bash "$scripts/log.sh" "${logargs[@]}" "$root" || exit 1
exit 0
