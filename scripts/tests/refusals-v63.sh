#!/usr/bin/env bash
set -u
unset CDPATH
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/refusals-v63.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
failed=0
fail() { echo "FAIL refusals-v63: $*" >&2; failed=1; }

# A refusal in the record writers and checkpoint says what was refused and the
# next step. Every call to the helper passes both on its own line, and no
# message reaches stderr beside the helper and then ends the script.
bare_refusals() {
  awk '
    FNR==1 { name=FILENAME; sub(/.*\//, "", name); pending="" }
    function arg(s) {
      if (match(s, /^"([^"\\]|\\.)+"/) || match(s, /^\047[^\047]+\047/)) return RLENGTH
      return 0
    }
    {
      line=$0
      while (match(line, /(^|[;&|{ ])(da_refuse|refuse|refuse_usage) /)) {
        line=substr(line, RSTART+RLENGTH)
        n=arg(line)
        rest=n ? substr(line, n+2) : ""
        if ((!n || !arg(rest)) && line !~ /^"\$@"|^"\$1" "\$2"/) print name ":" FNR ": " $0
      }
      if ($0 ~ /(echo|printf) .*(checkpoint|log|memory|learn)\.sh: .*>&2/ && $0 !~ /runtime\.sh is missing/) pending=FNR
      if (pending && FNR-pending<=3 && $0 ~ /(^|[^_a-z])(exit|return) [1-9]/) { print name ":" pending ": a bare message ends the script"; pending="" }
      if ($0 ~ /(^|[^_a-z])die /) print name ":" FNR ": " $0
    }
  ' "$@"
}
writers=("$repo/scripts/checkpoint.sh" "$repo/scripts/log.sh" "$repo/scripts/memory.sh" "$repo/scripts/learn.sh")
found=$(bare_refusals "${writers[@]}")
[ -z "$found" ] || fail "refusals with no next step: $found"

cat >"$scratch/bad.sh" <<'BAD'
refuse 'nothing changed'
refuse "nothing $changed" ""
echo "log.sh: nothing changed" >&2
exit 1
die 'nothing changed'
refuse 'nothing changed' 'Run this call again'
BAD
[ "$(bare_refusals "$scratch/bad.sh" | wc -l | tr -d ' ')" -eq 4 ] || fail "the structural check missed a bare refusal: $(bare_refusals "$scratch/bad.sh")"

for script in "${writers[@]}"; do
  [ "$(grep -c 'da_refuse "\$@"\|da_refuse "\$1" "\$2"' "$script")" -eq 1 ] || fail "${script##*/} does not refuse through da_refuse"
done

printf '. "%s/scripts/runtime.sh"\nda_refuse "nothing done" "Do it again" 7\n' "$repo" >"$scratch/caller.sh"
out=$(bash "$scratch/caller.sh" 2>&1); rc=$?
[ "$rc" -eq 7 ] && [ "$out" = 'caller.sh: nothing done. Do it again' ] || fail "da_refuse printed '$out' and returned $rc"
printf '. "%s/scripts/runtime.sh"\nda_refuse "nothing done"\n' "$repo" >"$scratch/caller.sh"
bash "$scratch/caller.sh" >/dev/null 2>&1
[ "$?" -eq 2 ] || fail 'da_refuse accepted a refusal with no next step'

node="$scratch/node"
mkdir -p "$node"
bash "$repo/scripts/node.sh" init --preset software-development --mode track-all --indexes generated "$node" >/dev/null
s="$node/.agent/scripts"
# The last line of a refusal carries the next step, so it survives tail -1.
last_line() { # expected ending, then the call
  want=$1; shift
  got=$("$@" 2>&1 </dev/null | tail -1)
  case "$got" in *". $want") ;; *) fail "$(basename "$2") ended on '$got', not on '$want'" ;; esac
}
long='one two three four five six seven eight nine ten one two three four five six seven eight nine ten one two three four five six seven'
last_line 'Shorten it by 2 words and run this call again' bash "$s/log.sh" --tool t --area a --verify pass --summary "$long" "$node"
last_line 'Shorten it by 1 word and run this call again' bash "$s/log.sh" --tool t --area a --verify pass --summary "${long% *}" "$node"
last_line 'Reword it without that token and run this call again' bash "$s/log.sh" --tool t --area a --verify pass --summary 'fixed src/client.ts' "$node"
last_line 'Run this call again with all four' bash "$s/log.sh" --tool t
last_line 'Run this call again with all three' bash "$s/checkpoint.sh" --tool t
last_line 'Pass only the flags listed above' bash "$s/memory.sh" new --nope
last_line 'Pass only the flags listed above' bash "$s/learn.sh" new --distinct --file /dev/null "$node"
last_line 'Use memory.sh new to write a new fact' bash "$s/memory.sh" supersede --slug gone --fact x "$node"
last_line 'Pass a file under .agent/docs/, or remove its entry in architecture.md' bash "$s/docs.sh" sync --name gone "$node"
. "$repo/scripts/runtime.sh"
lock="$node/.agent/.state/checkpoint.lock"
mkdir -p "$node/.agent/.state"
da_lock "$lock"
export DA_LOCK_WAIT_SECONDS=0
last_line 'Wait for it and run this call again' bash "$s/log.sh" --tool t --area a --verify pass --summary x "$node"
da_unlock "$lock"

help=$(bash "$s/checkpoint.sh" --help)
for situation in 'Product files changed, not committed' 'The work is committed' 'Only ignored node files changed' 'A check already ran on these inputs' 'The work failed and that is the outcome' 'Nothing can be run for this change'; do
  printf '%s\n' "$help" | grep -q "^$situation  *--" || fail "checkpoint.sh --help does not say which flags to use when: $situation"
done

[ "$failed" -eq 0 ] || exit 1
echo 'refusals-v63: every refusal names its next step'
