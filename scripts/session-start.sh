#!/usr/bin/env bash
# Session-start hook body. Prints this node's `status.sh --load` output under a
# header naming it, so a session opens with the node already loaded. When the
# output would pass the hook's byte limit, it prints one line naming the call
# to make instead: a harness cuts oversized hook output, and a cut payload is
# the failure status.sh's own budget refuses. Any problem prints nothing and
# exits 0, so the entry point's load step still runs.
set -u
unset CDPATH

# The tool-result cap PAYLOAD_MAX_BYTES defaults to. A harness whose hook
# output limit is lower passes its own with --max-bytes.
max_bytes=30000
while [ $# -gt 0 ]; do
  case "$1" in
  --max-bytes)
    [ $# -ge 2 ] || exit 0
    max_bytes=$2
    shift 2 ;;
  *) shift ;;
  esac
done
case "$max_bytes" in
'' | *[!0-9]*) exit 0 ;;
esac

scripts=$(cd "$(dirname "$0")" 2>/dev/null && pwd -P) || exit 0
node=$(cd "$scripts/../.." 2>/dev/null && pwd -P) || exit 0
[ -f "$scripts/status.sh" ] || exit 0

home=$(cd "${HOME:-/nonexistent}" 2>/dev/null && pwd -P)
if [ -n "$home" ] && [ "$node" = "$home" ]; then
  call='bash ~/.agent/scripts/status.sh --load ~'
else
  call='bash .agent/scripts/status.sh --load'
fi

out=$(cd "$node" && bash "$scripts/status.sh" --load . 2>/dev/null </dev/null) || exit 0
[ -n "$out" ] || exit 0

header="dot-agent session-start hook: the output of \`$call\` for the node at $node follows, run for this session. Read it here and do not make that call again."
size=$(printf '%s\n%s\n' "$header" "$out" | wc -c | tr -d '[:space:]')
if [ "$size" -le "$max_bytes" ]; then
  printf '%s\n%s\n' "$header" "$out"
else
  printf 'dot-agent session-start hook: `%s` for the node at %s prints %s bytes, over this hook'"'"'s %s-byte limit, so its output is not here. Make that call as your first tool call, before you answer, plan, or edit.\n' \
    "$call" "$node" "$size" "$max_bytes"
fi
exit 0
