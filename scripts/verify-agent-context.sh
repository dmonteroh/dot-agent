#!/usr/bin/env bash
# DEPRECATED (V6): retired from routine use. The status check now rides the
# load path — the entry point's first step runs `.agent/scripts/status.sh`
# (see scripts/status.sh), which checks artifacts and prints GROOM:/REPAIR:/
# INDEX: flags; there is no completion-time gate. This file is kept only
# because existing instance rule files reference its path. Do not wire it
# into new nodes.
set -euo pipefail

echo "DEPRECATED: verify-agent-context.sh is retired from routine use;" \
  "the entry point runs .agent/scripts/status.sh instead." >&2

usage() {
  cat <<'EOF'
Usage: verify-agent-context.sh [--fix] [root]

Checks:
  - .agent/memory.md exists and is non-empty
  - .agent/session-log.md exists and is non-empty
  - session-log.md contains today's date (YYYY-MM-DD)

Options:
  --fix   Create minimal scaffolding for missing/empty files and add a
          clearly marked placeholder entry for today when missing.
EOF
}

fix_mode=0
root="."

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fix)
      fix_mode=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      root="$1"
      shift
      ;;
  esac
done

memory="$root/.agent/memory.md"
log="$root/.agent/session-log.md"
today="$(date +%F)"
fixed_any=0

mkdir -p "$root/.agent"

ensure_memory() {
  if [[ -s "$memory" ]]; then
    return 0
  fi

  if [[ "$fix_mode" -eq 0 ]]; then
    echo "Missing or empty: $memory"
    return 1
  fi

  cat >"$memory" <<EOF
# Memory

- $today: Autofix scaffold created by verify-agent-context.sh --fix.
- REPLACE THIS: add real project memory and decisions from this session.
EOF
  echo "FIXED: created scaffold $memory"
  fixed_any=1
}

ensure_log() {
  if [[ -s "$log" ]]; then
    return 0
  fi

  if [[ "$fix_mode" -eq 0 ]]; then
    echo "Missing or empty: $log"
    return 1
  fi

  cat >"$log" <<EOF
# Session Log
EOF
  echo "FIXED: created scaffold $log"
  fixed_any=1
}

ensure_today_entry() {
  if grep -q "$today" "$log"; then
    return 0
  fi

  if [[ "$fix_mode" -eq 0 ]]; then
    echo "No session-log entry found for $today in $log"
    echo "Add a short entry before marking work complete."
    return 1
  fi

  {
    echo
    echo "- $today: Autofix placeholder entry by verify-agent-context.sh --fix."
    echo "  REPLACE THIS with a real session summary before marking work complete."
  } >>"$log"
  echo "FIXED: added placeholder entry for $today to $log"
  fixed_any=1
}

if ! ensure_memory; then
  exit 1
fi

if ! ensure_log; then
  exit 1
fi

if ! ensure_today_entry; then
  exit 1
fi

if [[ "$fix_mode" -eq 1 && "$fixed_any" -eq 1 ]]; then
  echo "INFO: Autofix created placeholders. Replace them with real session details."
fi

echo "OK: .agent context files exist and session-log has an entry for $today"
