#!/usr/bin/env bash
# Session-start hook body. Prints this node's `status.sh --load` output under a
# header naming it, so a session opens with the node already loaded. When the
# output would pass the hook's byte limit, it tries once more without the
# session-log tail (`--tail 0`), and past the limit again it prints one line
# naming the call to make instead: a harness cuts oversized hook output, and a
# cut payload is the failure status.sh's own budget refuses. Any problem
# prints nothing and exits 0, so the entry point's load step still runs.
#
# --header full|tail0 prints only the header line each attempt uses, so
# status.sh can count it in its HOOK: line without running this hook.
set -u
unset CDPATH

# The tool-result cap PAYLOAD_MAX_BYTES defaults to. A harness whose hook
# output limit is lower passes its own with --max-bytes.
max_bytes=30000
header_only=""
while [ $# -gt 0 ]; do
  case "$1" in
  --max-bytes)
    [ $# -ge 2 ] || exit 0
    max_bytes=$2
    shift 2 ;;
  --header)
    [ $# -ge 2 ] || exit 0
    header_only=$2
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

# The header names the node the way the entry point does, never by absolute
# path: the --load output itself carries only relative paths, and an absolute
# one here would hand the session a long path to retype that the call never
# shows it.
home=$(cd "${HOME:-/nonexistent}" 2>/dev/null && pwd -P)
if [ -n "$home" ] && [ "$node" = "$home" ]; then
  call='bash ~/.agent/scripts/status.sh --load ~'
  call_tail0='bash ~/.agent/scripts/status.sh --load --tail 0 ~'
  # shellcheck disable=SC2088 # printed for the agent to read, never expanded
  where='~/.agent/'
else
  call='bash .agent/scripts/status.sh --load'
  call_tail0='bash .agent/scripts/status.sh --load --tail 0'
  where='.agent/'
fi

header="dot-agent session-start hook: the output of \`$call\` for the node at $where follows, run for this session. Read it here and do not make that call again."
header_tail0="dot-agent session-start hook: the output of \`$call_tail0\` for the node at $where follows, run for this session. The full \`$call\` output passes this hook's $max_bytes-byte limit, so the session-log tail is left out; .agent/session-log.md holds it. Read the output here and do not make either call again."
case "$header_only" in
'') ;;
full) printf '%s\n' "$header"; exit 0 ;;
tail0) printf '%s\n' "$header_tail0"; exit 0 ;;
*) exit 0 ;;
esac

# The trailing x keeps the output's own trailing newlines, so the size
# checked here is the size printed, byte for byte.
load() { # $@: extra status.sh flags — sets out
  out=$(cd "$node" && bash "$scripts/status.sh" --load "$@" . 2>/dev/null </dev/null && printf x) || return 1
  out=${out%x}
  [ -n "$out" ]
}
fits() { # $1: header — true when the header line and out pass no limit
  [ $(( $(printf '%s\n%s' "$1" "$out" | wc -c | tr -d '[:space:]') )) -le "$max_bytes" ]
}

load || exit 0
if fits "$header"; then
  printf '%s\n%s' "$header" "$out"
  exit 0
fi
size=$(printf '%s\n%s' "$header" "$out" | wc -c | tr -d '[:space:]')
if load --tail 0 && fits "$header_tail0"; then
  printf '%s\n%s' "$header_tail0" "$out"
  exit 0
fi
printf 'dot-agent session-start hook: `%s` for the node at %s prints %s bytes, over this hook'"'"'s %s-byte limit even without the session-log tail, so its output is not here. Make that call as your first tool call, before you answer, plan, or edit.\n' \
  "$call" "$where" "$size" "$max_bytes"
exit 0
