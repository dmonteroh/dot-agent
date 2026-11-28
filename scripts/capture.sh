#!/usr/bin/env bash
set -u
unset CDPATH
selfdir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || exit 2
# shellcheck source=runtime.sh
. "$selfdir/runtime.sh"
usage() {
  cat <<'EOF'
Usage: capture.sh begin|end|show|clear --id SESSION [--root ROOT]
       capture.sh --help | --version

Optional lifecycle snapshot prototype. The adapter supplies a stable session ID.
Stores fingerprints in private state, never transcripts, memory facts, or log entries.
show compares live inputs with the starting snapshot, including after interruption.
It reports changed content, not task success or whether a session was completed.
EOF
}
case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --version) echo 'dot-agent capture 6.3'; exit 0 ;;
  begin|end|show|clear) action=$1; shift ;;
  *) usage >&2; exit 2 ;;
esac
root=.; session=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --id|--root)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      if [ "$1" = --id ]; then session=$2; else root=$2; fi
      shift 2 ;;
    *) usage >&2; exit 2 ;;
  esac
done
case "$session" in ''|*[!A-Za-z0-9_.-]*|.|..) echo 'capture.sh: supply a path-safe session ID' >&2; exit 2 ;; esac
[ "${#session}" -le 128 ] || { echo 'capture.sh: session ID exceeds 128 characters' >&2; exit 2; }
root=$(da_root "$root") || exit 2
state=$(da_state_dir "$root") || exit 2
directory="$state/captures"
[ ! -L "$directory" ] || { echo 'capture.sh: capture directory must not be a symlink' >&2; exit 2; }
(umask 077; mkdir -p "$directory") || exit 2
lock="$directory/$session.lock"
da_lock "$lock" || exit 2
temp=""
cleanup() { [ -z "$temp" ] || rm -f "$temp"; da_unlock "$lock"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
record="$directory/$session"
[ ! -L "$record" ] || { echo 'capture.sh: capture record must not be a symlink' >&2; exit 2; }
if [ "$action" = clear ]; then
  rm -f "$record" || exit 2
  printf 'capture\t%s\tcleared\n' "$session"
  exit 0
fi
current=$(da_fingerprint "$root") || exit 2
if [ "$action" = begin ]; then
  if [ -f "$record" ]; then
    echo 'capture.sh: this session already has a start snapshot; use another ID or clear it explicitly' >&2
    exit 2
  fi
  temp=$(mktemp "$directory/.capture.XXXXXX") || exit 2
  printf '%s\n' "$current" >"$temp" && mv "$temp" "$record" || exit 2
  temp=""
  printf 'capture\t%s\tstarted\t%s\n' "$session" "$current"
  exit 0
fi
[ -f "$record" ] || { echo 'capture.sh: no starting snapshot for this session' >&2; exit 2; }
start=$(cat "$record") || exit 2
case "$start" in ''|*[!0-9a-f]*) echo 'capture.sh: malformed starting snapshot' >&2; exit 2 ;; esac
outcome=unchanged
[ "$start" = "$current" ] || outcome=changed
printf 'capture\t%s\t%s\t%s\n' "$session" "$outcome" "$current"
