#!/usr/bin/env bash
set -eu
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/capture-v63.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/project/.agents" "$scratch/project/src"
root="$scratch/project"
printf 'first\n' >"$root/src/file"
git -C "$root" init -q
git -C "$root" add .
capture="$repo/scripts/capture.sh"
bash "$capture" begin --id session-a --root "$root" >/dev/null
if bash "$capture" begin --id session-a --root "$root" >/dev/null 2>&1; then echo 'capture: duplicate start accepted' >&2; exit 1; fi
bash "$capture" end --id session-a --root "$root" | grep -q 'unchanged'
printf 'changed\n' >"$root/src/file"
# An interrupted session has no end event, but its start snapshot still helps.
bash "$capture" show --id session-a --root "$root" >"$scratch/first"
grep -q 'changed' "$scratch/first"
bash "$capture" show --id session-a --root "$root" >"$scratch/second"
cmp "$scratch/first" "$scratch/second"
[ ! -e "$root/.agents/session-log.md" ] || exit 1
[ ! -e "$root/.agents/memory.md" ] || exit 1
bash "$capture" clear --id session-a --root "$root" >/dev/null
if bash "$capture" show --id session-a --root "$root" >/dev/null 2>&1; then exit 1; fi
if bash "$capture" begin --id ../outside --root "$root" >/dev/null 2>&1; then exit 1; fi
echo 'capture-v63: interruption, duplicate events, isolation, and path validation passed'
