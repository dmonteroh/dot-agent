#!/usr/bin/env bash
# The node at .agents/: init beside foreign content, the per-mode gitignore,
# the move from .agent/, the write-free load, the relocatable index, installed
# skill checks, and frontmatter-free rule files.
set -eu
unset CDPATH
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/agents-dir-v63.XXXXXX")
scratch=$(cd "$scratch" && pwd -P)
trap 'chmod -R u+w "$scratch" 2>/dev/null; rm -rf "$scratch"' EXIT
fail() { echo "FAIL agents-dir-v63: $*" >&2; exit 1; }
node_sh="$repo/scripts/node.sh"
commit() { git -C "$1" add -A && git -C "$1" -c user.name=fixture -c user.email=fixture@local -c commit.gpgsign=false commit -qm "$2"; }

# init beside an installer's skills directory
root="$scratch/foreign"
mkdir -p "$root/.agents/skills/vendor"
printf -- '---\nname: vendor\ndescription: Vendor skill.\n---\n' >"$root/.agents/skills/vendor/SKILL.md"
git -C "$root" init -q
bash "$node_sh" init --preset software-development --mode track-shared "$root" >/dev/null || fail 'init refused a .agents/ holding only foreign skills'
[ -f "$root/.agents/purpose.md" ] || fail 'init wrote no manifest beside foreign skills'
grep -qx 'description: Vendor skill.' "$root/.agents/skills/vendor/SKILL.md" || fail 'init touched a foreign skill'
git -C "$root" check-ignore -q .agents/skills/vendor/SKILL.md && fail 'track-shared ignores installed skills'
git -C "$root" check-ignore -q .agents/memory.md || fail 'track-shared does not ignore memory.md'
git -C "$root" check-ignore -q .agents/rules/contract.md && fail 'track-shared ignores rules/'
if bash "$node_sh" init --preset software-development --mode track-shared "$root" >/dev/null 2>&1; then fail 'init overwrote a live node'; fi

orphan="$scratch/orphan"
mkdir -p "$orphan/.agents/memory"
if bash "$node_sh" init --preset software-development --mode ignore-all "$orphan" >/dev/null 2>&1; then fail 'init accepted a node-owned path with no manifest'; fi

for mode in ignore-all track-shared track-all; do
  for indexes in manual generated; do
    m="$scratch/mode-$mode-$indexes"
    mkdir -p "$m"
    git -C "$m" init -q
    bash "$node_sh" init --preset software-development --mode "$mode" --indexes "$indexes" "$m" >/dev/null
    case "$mode" in
    ignore-all) want_ignored='purpose.md rules/contract.md docs/x.md memory.md session-log.md scripts/status.sh'; want_tracked='skills/s/SKILL.md' ;;
    track-shared) want_ignored='memory.md memory/x.md session-log.md scripts/status.sh archive/x.md .state/x'; want_tracked='purpose.md rules/contract.md docs/x.md skills/s/SKILL.md' ;;
    track-all) want_ignored=''; want_tracked='purpose.md memory.md session-log.md skills/s/SKILL.md' ;;
    esac
    if [ "$indexes" = generated ] && [ "$mode" != ignore-all ]; then want_ignored="$want_ignored indexes/x rules/learned.md"; fi
    for p in $want_ignored; do git -C "$m" check-ignore -q ".agents/$p" || fail "$mode/$indexes does not ignore .agents/$p"; done
    for p in $want_tracked; do if git -C "$m" check-ignore -q ".agents/$p"; then fail "$mode/$indexes ignores .agents/$p"; fi; done
    before=$(cat "$m/.gitignore" 2>/dev/null || true)
    bash "$node_sh" update "$m" >/dev/null || fail "$mode/$indexes update failed"
    [ "$before" = "$(cat "$m/.gitignore" 2>/dev/null || true)" ] || fail "$mode/$indexes update rewrote a current gitignore"
  done
done

# Every rule file the presets and node.sh write stays frontmatter-free:
# Antigravity loads top-level .agents/rules/*.md only with frontmatter.
for preset in "$repo"/presets/*.md; do
  [ "$(head -n 1 "$preset")" != '---' ] || fail "preset $(basename "$preset") opens with frontmatter"
done
for f in "$scratch"/mode-*/.agents/rules/*.md; do
  [ "$(head -n 1 "$f")" != '---' ] || fail "${f#"$scratch"/} opens with frontmatter"
done

# The move from .agent/
legacy="$scratch/legacy"
mkdir -p "$legacy"
git -C "$legacy" init -q
printf 'node_modules\n' >"$legacy/.gitignore"
bash "$node_sh" init --preset software-development --mode track-shared "$legacy" >/dev/null
# Rebuild the pre-6.3 layout: the node at .agent/ naming its own paths that way.
mv "$legacy/.agents" "$legacy/.agent"
find "$legacy/.agent" -type f \( -name '*.md' -o -name '*.conf' \) -exec perl -pi -e 's/\.agents(?![A-Za-z0-9_])/.agent/g' {} +
grep -v '^\.agents/' "$legacy/.gitignore" >"$scratch/gi" && cp "$scratch/gi" "$legacy/.gitignore"
printf '.agent/*\n!.agent/purpose.md\n!.agent/rules/\n!.agent/docs/\n' >>"$legacy/.gitignore"
printf '# P\n\nRun `bash .agent/scripts/status.sh --load`.\n' >"$legacy/CLAUDE.md"
cp "$legacy/CLAUDE.md" "$legacy/AGENTS.md"
printf -- '- [2026-09-01] (tool) wrote .agent/docs/a.md. verify: n/a.\n' >>"$legacy/.agent/session-log.md"
mkdir -p "$legacy/.agent/skills/groom" "$legacy/.claude" "$legacy/.codex"
cp "$repo/tools/skills/groom/SKILL.md" "$legacy/.agent/skills/groom/"
ln -s ../.agent/skills "$legacy/.claude/skills"
ln -s ../.agent/skills "$legacy/.codex/skills"
commit "$legacy" legacy
log_before=$(cat "$legacy/.agent/session-log.md")

mkdir -p "$legacy/.agents/skills"
if bash "$node_sh" update "$legacy" >"$scratch/clash.out" 2>&1; then fail 'update moved the node over a clashing name'; fi
grep -q 'exist in both: skills' "$scratch/clash.out" || fail 'the clash refusal does not name the clashing entry'
[ -f "$legacy/.agent/purpose.md" ] || fail 'a refused move still moved the manifest'
rmdir "$legacy/.agents/skills" "$legacy/.agents"

# An interrupted move: some entries already moved, the manifest not yet.
mkdir -p "$legacy/.agents"
git -C "$legacy" mv .agent/rules .agents/rules
bash "$node_sh" update "$legacy" >"$scratch/move.out" 2>&1 || { cat "$scratch/move.out" >&2; fail 'update did not resume an interrupted move'; }
[ ! -e "$legacy/.agent" ] || fail 'the old node directory is still there'
[ -f "$legacy/.agents/purpose.md" ] || fail 'the manifest did not move'
[ -d "$legacy/.agent.backup-v6.3-relocate" ] || fail 'no backup before the move'
git -C "$legacy" ls-files --error-unmatch .agents/rules/contract.md >/dev/null 2>&1 || fail 'a tracked rule file did not move in git'
[ "$(cat "$legacy/.agents/session-log.md")" = "$log_before" ] || fail 'the move rewrote the session log'
grep -q '\.agent/' "$legacy/.agents/rules/contract.md" && fail 'the contract still names .agent/'
grep -qF 'bash .agents/scripts/status.sh --load' "$legacy/CLAUDE.md" || fail 'CLAUDE.md was not rewritten'
grep -qF 'bash .agents/scripts/status.sh --load' "$legacy/AGENTS.md" || fail 'AGENTS.md was not rewritten'
[ "$(readlink "$legacy/.claude/skills")" = ../.agents/skills ] || fail '.claude/skills was not repointed'
[ ! -L "$legacy/.codex/skills" ] || fail '.codex/skills was left pointing at the old node'
grep -q '^\.agent/' "$legacy/.gitignore" && fail 'the pre-6.3 gitignore lines survived'
grep -qx '\.agents/memory\.md' "$legacy/.gitignore" || fail 'the new gitignore list was not written'
grep -qx node_modules "$legacy/.gitignore" || fail 'the move dropped a project gitignore line'
bash "$legacy/.agents/scripts/status.sh" "$legacy" >"$scratch/status.out" 2>&1 || { cat "$scratch/status.out" >&2; fail 'status.sh fails after the move'; }
if bash "$node_sh" finalize "$legacy" >/dev/null 2>&1; then :; fi
second=$(bash "$node_sh" update "$legacy" 2>&1) || fail 'a second update failed'
printf '%s\n' "$second" | grep -q 'moved the node' && fail 'a second update moved the node again'

stale="$scratch/stale"
mkdir -p "$stale/.agent"
cp "$legacy/.agents/purpose.md" "$stale/.agent/purpose.md"
if bash "$node_sh" init --preset software-development --mode ignore-all "$stale" >/dev/null 2>&1; then fail 'init ignored a node at .agent/'; fi
if bash "$node_sh" finalize "$stale" >/dev/null 2>&1; then fail 'finalize accepted a node at .agent/'; fi

# status.sh --load writes nothing
tree_state() { (cd "$1" && find . -path ./.git -prune -o -print | LC_ALL=C sort | while IFS= read -r p; do
  if [ -f "$p" ]; then printf '%s %s\n' "$p" "$(cksum <"$p")"; else printf '%s\n' "$p"; fi
done); }
for indexes in manual generated; do
  w="$scratch/mode-track-shared-$indexes"
  [ "$indexes" = manual ] || bash "$w/.agents/scripts/index.sh" ensure --root "$w" >/dev/null 2>&1
  before=$(tree_state "$w")
  bash "$w/.agents/scripts/status.sh" --load "$w" >/dev/null 2>&1 || fail "status.sh --load failed ($indexes)"
  [ "$before" = "$(tree_state "$w")" ] || fail "status.sh --load changed the tree ($indexes)"
  if [ "$(id -u)" -ne 0 ]; then
    chmod -R a-w "$w"
    bash "$w/.agents/scripts/status.sh" --load "$w" >/dev/null 2>"$scratch/ro.err" || { chmod -R u+w "$w"; fail "status.sh --load failed on a read-only node ($indexes)"; }
    chmod -R u+w "$w"
    [ ! -s "$scratch/ro.err" ] || fail "status.sh --load wrote to stderr on a read-only node ($indexes)"
  fi
done

# A copied index stays valid
src="$scratch/mode-track-shared-generated"
printf '# Area\n<!-- Read when: touching the area -->\n\nSee [the contract](../rules/contract.md).\n' >"$src/.agents/docs/area.md"
printf -- '- [Area](area.md) — Read when: touching the area\n' >>"$src/.agents/docs/architecture.md"
printf '\nSee [area](../docs/area.md).\n' >>"$src/.agents/rules/contract.md"
bash "$src/.agents/scripts/index.sh" ensure --root "$src" >/dev/null 2>&1 || fail 'index.sh ensure failed'
grep -rqF "$src" "$src/.agents/indexes" && fail 'the index names its absolute root'
grep -q '^READ: \.agents/indexes/gen\.' "$src/.agents/indexes/current.md" || fail 'the entry does not list root-relative pages'
grep -rqF 'READ: .agents/docs/area.md' "$src/.agents/indexes" || fail 'a route does not name its doc root-relative'
grep -rqF '(.agents/docs/area.md)' "$src/.agents/indexes" || fail 'a rule link was not rewritten root-relative'
copy="$scratch/copied node"
cp -R "$src" "$copy"
[ "$(bash "$copy/.agents/scripts/index.sh" check --root "$copy" 2>/dev/null)" = FRESH ] || fail 'a copied node reports a stale index'
before=$(tree_state "$copy")
bash "$copy/.agents/scripts/index.sh" ensure --root "$copy" >/dev/null 2>&1 || fail 'ensure failed in a copy'
[ "$before" = "$(tree_state "$copy")" ] || fail 'ensure rewrote a valid copied index'

# Installed skills
sk="$scratch/mode-track-all-manual"
mkdir -p "$sk/.agents/skills/empty" "$sk/.agents/skills/bad" "$sk/.agents/skills/folded" "$sk/.agents/skills/long" "$sk/.claude/skills/retro"
cp -R "$repo/tools/skills/groom" "$repo/tools/skills/retro" "$sk/.agents/skills/"
printf -- '---\nname: wrong\n---\n' >"$sk/.agents/skills/bad/SKILL.md"
printf -- '---\nname: folded\ndescription: >-\n  Line one\n  line two.\n---\n' >"$sk/.agents/skills/folded/SKILL.md"
{ printf -- '---\nname: long\ndescription: '; head -c 1100 /dev/zero | tr '\0' a; printf '\n---\n'; } >"$sk/.agents/skills/long/SKILL.md"
out=$(bash "$sk/.agents/scripts/status.sh" "$sk" 2>&1 || true)
has() { printf '%s\n' "$out" | grep -qF "$1" || fail "status.sh did not report: $1"; }
lacks() { if printf '%s\n' "$out" | grep -qF "$1"; then fail "status.sh wrongly reported: $1"; fi; }
has 'GROOM: skills/empty has no SKILL.md'
has "GROOM: skills/bad/SKILL.md frontmatter name 'wrong' does not match"
has 'GROOM: skills/bad/SKILL.md has no frontmatter description'
has 'GROOM: skills/long/SKILL.md description is 1100 characters'
has 'GROOM: skills/retro has a separate copy at .claude/skills/retro'
lacks 'skills/groom'
lacks 'skills/folded'
rm -rf "$sk/.claude/skills"
ln -s ../.agents/skills "$sk/.claude/skills"
out=$(bash "$sk/.agents/scripts/status.sh" "$sk" 2>&1 || true)
lacks 'separate copy'
exit 0
