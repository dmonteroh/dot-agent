#!/usr/bin/env bash
set -euo pipefail

root="${1:-.}"
memory="$root/.agent/memory.md"
log="$root/.agent/session-log.md"

if [[ ! -s "$memory" ]]; then
  echo "Missing or empty: $memory"
  exit 1
fi

if [[ ! -s "$log" ]]; then
  echo "Missing or empty: $log"
  exit 1
fi

today="$(date +%F)"
if ! grep -q "$today" "$log"; then
  echo "No session-log entry found for $today in $log"
  echo "Add a short entry before marking work complete."
  exit 1
fi

echo "OK: .agent context files exist and session-log has an entry for $today"
