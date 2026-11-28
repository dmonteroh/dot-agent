#!/usr/bin/env bash
# shellcheck disable=SC2034
# Which project files resolve a bare citation: links.sh takes them from git in
# a repository and from a find walk outside one.

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/links-walk-v63-test.XXXXXX") || exit 1
tmp=$(cd "$tmp" && pwd -P)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT HUP INT TERM
# The non-git cases must not find a repository above the scratch directory.
export GIT_CEILING_DIRECTORIES="$tmp"

passes=0
failures=0
pass() { printf 'ok - %s\n' "$1"; passes=$((passes + 1)); }
fail() { printf 'not ok - %s\n%s\n' "$1" "${out:-}"; failures=$((failures + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

g() { git -c user.email=test@example.invalid -c user.name=test -c protocol.file.allow=always -C "$@"; }
node() { # $1: root  $2...: cited names — a node whose one doc cites them
  local root=$1 name
  shift
  mkdir -p "$root/.agent/docs"
  printf '%s\n' '<!-- Read when: x -->' '# X' >"$root/.agent/docs/x.md"
  for name in "$@"; do printf 'See `%s`.\n' "$name" >>"$root/.agent/docs/x.md"; done
}
put() { # $1: path — a Markdown file there
  mkdir -p "$(dirname "$1")"
  printf '# File\n' >"$1"
}
audit() { out=$(bash "$repo_root/scripts/links.sh" "$@" 2>&1); }
broken() { printf '%s\n' "$out" | grep -qF "cites $1 — no such file"; }
resolves() { ! broken "$1"; }

p="$tmp/my proj"
node "$p" tracked.md untracked.md ignored.md docs/suffix.md LOCAL.md docs/local.md gone.md \
  'with space.md' 'résumé.md' in-vendor.md in-sub.md deep-sub.md in-worktree.md in-nested.md \
  node-ref.md nowhere.md
printf '%s\n' 'out/' 'LOCAL.md' 'docs/local.md' '/.agent/' '/.wt-ignored/' >"$p/.gitignore"
put "$p/notes/tracked.md"
put "$p/notes/gone.md"
put "$p/notes/with space.md"
put "$p/notes/résumé.md"
put "$p/vendor/in-vendor.md"
put "$p/out/ignored.md"
put "$p/out/docs/suffix.md"
put "$p/LOCAL.md"
put "$p/docs/local.md"
put "$p/.agent/docs/area/references/node-ref.md"
put "$tmp/sub/in-sub.md"
put "$tmp/sub/deep/deep-sub.md"
g "$tmp/sub" init -q
g "$tmp/sub" add -A
g "$tmp/sub" commit -qm base
g "$p" init -q
g "$p" add -A
g "$p" commit -qm base
g "$p" submodule add -q "$tmp/sub" libs/sub 2>/dev/null
g "$p" commit -qm submodule
put "$p/notes/untracked.md"
rm "$p/notes/gone.md"
g "$p" worktree add -q .wt/w1 -b w1
g "$p" worktree add -q .wt-ignored/w2 -b w2
put "$p/.wt/w1/in-worktree.md"
put "$p/.wt-ignored/w2/in-worktree.md"
put "$p/copy/in-nested.md"
g "$p/copy" init -q
g "$p/copy" add -A
g "$p/copy" commit -qm base

audit "$p"
check "a tracked file resolves a bare citation" 'resolves tracked.md'
check "an untracked file that is not ignored resolves a bare citation" 'resolves untracked.md'
check "an ignored file does not resolve a bare citation" 'broken ignored.md'
check "an ignored file does not resolve a citation by the end of its path" 'broken docs/suffix.md'
check "an ignored file at the root resolves a citation of its path" 'resolves LOCAL.md && resolves docs/local.md'
check "a tracked file deleted from the checkout does not resolve" 'broken gone.md'
check "names with spaces and non-ASCII letters resolve" 'resolves "with space.md" && resolves résumé.md'
check "a tracked file under a dependency directory does not resolve" 'broken in-vendor.md'
check "a submodule's files resolve" 'resolves in-sub.md && resolves deep-sub.md'
check "a linked worktree's files do not resolve" 'broken in-worktree.md'
check "a nested checkout's files do not resolve" 'broken in-nested.md'
check "an ignored node's own files are still walked" \
  'resolves node-ref.md && printf "%s\n" "$out" | grep -qF "ORPHAN: docs/x.md"'
check "a name held nowhere is broken" 'broken nowhere.md'
from_abs=$out
out=$(cd "$p" && bash "$repo_root/scripts/links.sh" 2>&1)
check "the root given as . reports the same" '[ "$out" = "$from_abs" ]'
g "$p" add -A 2>/dev/null
audit "$p"
check "a linked worktree added to the index by mistake does not resolve" \
  'g "$p" ls-files -s | grep -q "^160000 .*\.wt/w1$" && broken in-worktree.md'

sub="$tmp/mono/pkg/app"
node "$sub" here.md elsewhere.md ignored.md
put "$sub/notes/here.md"
put "$sub/out/ignored.md"
put "$tmp/mono/other/elsewhere.md"
printf 'out/\n' >"$tmp/mono/.gitignore"
g "$tmp/mono" init -q
g "$tmp/mono" add -A
g "$tmp/mono" commit -qm base
audit "$sub"
check "a root below the top of its repository lists its own files" 'resolves here.md && broken elsewhere.md'
check "ignore rules above the root apply to it" 'broken ignored.md'

held="$tmp/outer/scratch/proj"
node "$held" loose.md forced.md
put "$held/notes/loose.md"
put "$held/notes/forced.md"
printf 'scratch/\n' >"$tmp/outer/.gitignore"
g "$tmp/outer" init -q
g "$tmp/outer" add -A
g "$tmp/outer" add -f scratch/proj/notes/forced.md
g "$tmp/outer" commit -qm base
audit "$held"
check "a root its outer repository ignores is walked with find" 'resolves loose.md && resolves forced.md'

kept="$tmp/allow/kept"
node "$kept" loose.md ignored.md
put "$kept/notes/loose.md"
put "$kept/out/ignored.md"
printf '%s\n' '/*' '!/kept/' 'out/' >"$tmp/allow/.gitignore"
g "$tmp/allow" init -q
audit "$kept"
check "a root an ignore rule excepts is listed by git" 'resolves loose.md && broken ignored.md'

plain="$tmp/plain"
node "$plain" loose.md nowhere.md
put "$plain/out/loose.md"
printf 'out/\n' >"$plain/.gitignore"
audit "$plain"
check "outside git the find walk resolves a bare citation" 'resolves loose.md && broken nowhere.md'

printf '1..%d\n' "$((passes + failures))"
[ "$failures" -eq 0 ]
