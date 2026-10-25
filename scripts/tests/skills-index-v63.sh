#!/usr/bin/env bash
# Frontmatter-free rule files, the write-free load, the relocatable index, and
# installed skill checks under <root>/.agents/skills/.
set -eu
unset CDPATH
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/skills-index-v63.XXXXXX")
scratch=$(cd "$scratch" && pwd -P)
trap 'chmod -R u+w "$scratch" 2>/dev/null; rm -rf "$scratch"' EXIT
fail() { echo "FAIL skills-index-v63: $*" >&2; exit 1; }
node_sh="$repo/scripts/node.sh"

for mode in track-shared track-all; do
  for indexes in manual generated; do
    m="$scratch/$mode-$indexes"
    mkdir -p "$m"
    git -C "$m" init -q
    bash "$node_sh" init --preset software-development --mode "$mode" --indexes "$indexes" "$m" >/dev/null
  done
done

# Every rule file the presets and node.sh write stays frontmatter-free:
# Antigravity loads top-level .agent/rules/*.md as rules only with frontmatter.
for preset in "$repo"/presets/*.md; do
  [ "$(head -n 1 "$preset")" != '---' ] || fail "preset $(basename "$preset") opens with frontmatter"
done
for f in "$scratch"/*/.agent/rules/*.md; do
  [ "$(head -n 1 "$f")" != '---' ] || fail "${f#"$scratch"/} opens with frontmatter"
done

# status.sh --load writes nothing
tree_state() { (cd "$1" && find . -path ./.git -prune -o -print | LC_ALL=C sort | while IFS= read -r p; do
  if [ -f "$p" ]; then printf '%s %s\n' "$p" "$(cksum <"$p")"; else printf '%s\n' "$p"; fi
done); }
for indexes in manual generated; do
  w="$scratch/track-shared-$indexes"
  [ "$indexes" = manual ] || bash "$w/.agent/scripts/index.sh" ensure --root "$w" >/dev/null 2>&1
  before=$(tree_state "$w")
  bash "$w/.agent/scripts/status.sh" --load "$w" >/dev/null 2>&1 || fail "status.sh --load failed ($indexes)"
  [ "$before" = "$(tree_state "$w")" ] || fail "status.sh --load changed the tree ($indexes)"
  if [ "$(id -u)" -ne 0 ]; then
    chmod -R a-w "$w"
    bash "$w/.agent/scripts/status.sh" --load "$w" >/dev/null 2>"$scratch/ro.err" || { chmod -R u+w "$w"; fail "status.sh --load failed on a read-only node ($indexes)"; }
    chmod -R u+w "$w"
    [ ! -s "$scratch/ro.err" ] || fail "status.sh --load wrote to stderr on a read-only node ($indexes)"
  fi
done

# A copied index stays valid
src="$scratch/track-shared-generated"
printf '# Area\n<!-- Read when: touching the area -->\n\nSee [the contract](../rules/contract.md).\n' >"$src/.agent/docs/area.md"
printf -- '- [Area](area.md) — Read when: touching the area\n' >>"$src/.agent/docs/architecture.md"
printf '\nSee [area](../docs/area.md).\n' >>"$src/.agent/rules/contract.md"
bash "$src/.agent/scripts/index.sh" ensure --root "$src" >/dev/null 2>&1 || fail 'index.sh ensure failed'
if grep -rqF "$src" "$src/.agent/indexes"; then fail 'the index names its absolute root'; fi
grep -q '^READ: \.agent/indexes/gen\.' "$src/.agent/indexes/current.md" || fail 'the entry does not list root-relative pages'
grep -rqF 'READ: .agent/docs/area.md' "$src/.agent/indexes" || fail 'a route does not name its doc root-relative'
grep -rqF '(.agent/docs/area.md)' "$src/.agent/indexes" || fail 'a rule link was not rewritten root-relative'
copy="$scratch/copied node"
cp -R "$src" "$copy"
[ "$(bash "$copy/.agent/scripts/index.sh" check --root "$copy" 2>/dev/null)" = FRESH ] || fail 'a copied node reports a stale index'
before=$(tree_state "$copy")
bash "$copy/.agent/scripts/index.sh" ensure --root "$copy" >/dev/null 2>&1 || fail 'ensure failed in a copy'
[ "$before" = "$(tree_state "$copy")" ] || fail 'ensure rewrote a valid copied index'

# Skills installed inside the node before 6.3 move beside it on update
mv_node="$scratch/skills-move"
mkdir -p "$mv_node"
git -C "$mv_node" init -q
bash "$node_sh" init --preset software-development --mode track-shared "$mv_node" >/dev/null
mkdir -p "$mv_node/.agent/skills" "$mv_node/.claude" "$mv_node/.codex"
cp -R "$repo/tools/skills/groom" "$mv_node/.agent/skills/"
ln -s ../.agent/skills "$mv_node/.claude/skills"
ln -s ../.agent/skills "$mv_node/.codex/skills"
bash "$node_sh" update "$mv_node" >"$scratch/skills-move.out" 2>&1 || { cat "$scratch/skills-move.out" >&2; fail 'update failed while moving skills'; }
[ -f "$mv_node/.agents/skills/groom/SKILL.md" ] || fail 'update did not move installed skills to .agents/skills/'
[ ! -e "$mv_node/.agent/skills" ] || fail 'update left .agent/skills/ behind'
[ "$(readlink "$mv_node/.claude/skills")" = ../.agents/skills ] || fail 'update did not repoint .claude/skills'
[ ! -L "$mv_node/.codex/skills" ] || fail 'update kept a .codex/skills link to the old location'
bash "$node_sh" update "$mv_node" >/dev/null 2>&1 || fail 'a second update failed after the skills move'
clash="$scratch/skills-clash"
mkdir -p "$clash"
git -C "$clash" init -q
bash "$node_sh" init --preset software-development --mode track-shared "$clash" >/dev/null
mkdir -p "$clash/.agent/skills/groom" "$clash/.agents/skills/groom"
bash "$node_sh" update "$clash" >"$scratch/skills-clash.out" 2>&1 || fail 'update failed on a skills clash instead of leaving the skills in place'
[ -d "$clash/.agent/skills/groom" ] || fail 'update moved skills over a clashing name'
grep -q 'already exist in' "$scratch/skills-clash.out" || fail 'the skills clash was not reported'

# Installed skills
sk="$scratch/track-all-manual"
mkdir -p "$sk/.agents/skills/empty" "$sk/.agents/skills/bad" "$sk/.agents/skills/folded" "$sk/.agents/skills/long" "$sk/.claude/skills/retro"
cp -R "$repo/tools/skills/groom" "$repo/tools/skills/retro" "$sk/.agents/skills/"
printf -- '---\nname: wrong\n---\n' >"$sk/.agents/skills/bad/SKILL.md"
printf -- '---\nname: folded\ndescription: >-\n  Line one\n  line two.\n---\n' >"$sk/.agents/skills/folded/SKILL.md"
{ printf -- '---\nname: long\ndescription: '; head -c 1100 /dev/zero | tr '\0' a; printf '\n---\n'; } >"$sk/.agents/skills/long/SKILL.md"
out=$(bash "$sk/.agent/scripts/status.sh" "$sk" 2>&1 || true)
has() { printf '%s\n' "$out" | grep -qF "$1" || fail "status.sh did not report: $1"; }
lacks() { if printf '%s\n' "$out" | grep -qF "$1"; then fail "status.sh wrongly reported: $1"; fi; }
has 'GROOM: .agents/skills/empty has no SKILL.md'
has "GROOM: .agents/skills/bad/SKILL.md frontmatter name 'wrong' does not match"
has 'GROOM: .agents/skills/bad/SKILL.md has no frontmatter description'
has 'GROOM: .agents/skills/long/SKILL.md description is 1100 characters'
has 'GROOM: .agents/skills/retro has a separate copy at .claude/skills/retro'
lacks '.agents/skills/groom'
lacks '.agents/skills/folded'
rm -rf "$sk/.claude/skills"
ln -s ../.agents/skills "$sk/.claude/skills"
out=$(bash "$sk/.agent/scripts/status.sh" "$sk" 2>&1 || true)
lacks 'separate copy'
exit 0
