#!/usr/bin/env bash
# links.sh — on-demand link audit for a node. Reports ORPHAN (a file
# nothing cites) and BROKEN (a cited path that does not exist). Findings
# are review triggers, not errors; always exits 0.
#
# Full documentation: scripts/docs/links.md in the dot-agent repo.
#
# Usage: links.sh [root]    # root defaults to . ; audits <root>/.agent/

set -u

root="${1:-.}"
case "$root" in
-h | --help)
  cat <<'EOF'
Usage: links.sh [root]

Reports ORPHAN: (a file in the node nothing cites) and BROKEN: (a node path
cited by a node file that does not exist). Paths outside .agent/ are out of
scope. root defaults to . ; always exits 0.
EOF
  exit 0 ;;
esac

agent="$root/.agent"
if [ ! -d "$agent" ]; then
  echo "links.sh: no .agent directory at $agent — run from the node's project root, or pass that root as an argument" >&2
  exit 1
fi

# Files exempt from the orphan check — each is reached by a route the link
# graph cannot see, or is placed outside the model. Per-entry reasons:
# scripts/docs/links.md.
is_exempt() {
  case "$1" in
  purpose.md | memory.md | session-log.md) return 0 ;;
  rules/* | docs/architecture.md) return 0 ;;
  memory/* | archive/* | scripts/*) return 0 ;;
  skills/* | workflows/* | agents/* | others/* | tmp/*) return 0 ;;
  esac
  return 1
}

# Arrays and newline-delimited reads throughout: a node under a path with a
# space in it ("~/My Projects/app") word-split every list here into garbage
# and silently bypassed the exemptions.
nodefiles=()
while IFS= read -r f; do
  [ -n "$f" ] && nodefiles+=("$f")
done < <(find "$agent" -type f -name '*.md' 2>/dev/null | LC_ALL=C sort)

# Every markdown basename in the project, newline-delimited and newline-
# bounded so a lookup is one `case` against a string rather than a loop or a
# subprocess per candidate. Built once; the walk below consults it for every
# cited name that the node itself cannot resolve. The heavy vendored trees
# are pruned because they hold thousands of files and none of them is what a
# node doc means by a bare name.
projbasenames=$'\n'
while IFS= read -r f; do
  [ -n "$f" ] && projbasenames="$projbasenames${f##*/}"$'\n'
done < <(find "$root" \( -name .git -o -name node_modules -o -name vendor \
  -o -name .venv -o -name dist -o -name build -o -name target \) -prune -o \
  -type f -name '*.md' -print 2>/dev/null)

# A file's body with <!-- --> comments stripped. Header contracts live in
# comments and state formats by example — memory.md's says
# `- [Title](memory/slug.md) — hook` — so a comment is a spec, not a
# citation, and reading one as a link invents a broken path on every node.
strip_comments() {
  awk '
    incm { if (/-->/) { incm = 0; sub(/.*-->/, "") } else next }
    { gsub(/<!--.*-->/, "") }
    /<!--/ { incm = 1; sub(/<!--.*/, "") }
    { print }
  ' "$1"
}

# Every markdown file in the node that is not retired or out of model, plus
# the tool entry points at the project root, which reference into .agent/
# from outside it.
# An empty array expands to an unbound variable under `set -u` in bash 3.2,
# which is what macOS ships, so the emptiness check comes before any use.
if [ "${#nodefiles[@]}" -eq 0 ]; then
  echo "links.sh: no markdown files to audit under $agent"
  exit 0
fi

corpus=()
for f in "${nodefiles[@]}"; do
  rel=${f#"$agent"/}
  case "$rel" in
  archive/* | skills/* | workflows/* | agents/* | others/* | tmp/*) continue ;;
  esac
  corpus+=("$f")
done
for ep in "$root/CLAUDE.md" "$root/AGENTS.md" "$root/.cursorrules" \
  "$root/.github/copilot-instructions.md" "$root/.claude/CLAUDE.md"; do
  [ -s "$ep" ] && corpus+=("$ep")
done

if [ "${#corpus[@]}" -eq 0 ]; then
  echo "links.sh: no markdown files to audit under $agent"
  exit 0
fi

findings=0
audited=0

# ---- ORPHAN: files nothing cites ------------------------------------
#
# Matched on node-relative path or bare basename, because docs cite each
# other both ways. Two files sharing a basename can mask one another: the
# one case where this check knowingly under-reports, and the quiet
# direction to fail in.
# One `grep -l` over the whole corpus per candidate, never one per
# (candidate, file) pair — the pairwise form is quadratic in processes and
# unusable on a large node for the same answer.
for f in "${nodefiles[@]}"; do
  rel=${f#"$agent"/}
  is_exempt "$rel" && continue
  audited=$((audited + 1))
  base=${rel##*/}
  cited=0
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    if [ "$hit" != "$f" ]; then
      cited=1
      break
    fi
  done < <(grep -lF -e "$rel" -e "$base" -- "${corpus[@]}" 2>/dev/null)
  if [ "$cited" -eq 0 ]; then
    case "$rel" in
    */references/* | references/*)
      echo "ORPHAN: $rel — nothing cites it; a reference carries no routing entry, so an uncited one is unreachable: cite it from its area doc, or retire it to archive/" ;;
    *)
      echo "ORPHAN: $rel — nothing in the node cites it" ;;
    esac
    findings=$((findings + 1))
  fi
done

# ---- BROKEN: cited node paths that do not exist ----------------------
#
# Candidates come from markdown link targets and backticked .md paths.
# session-log.md, archive/ and rules/ are excluded: they name files as
# record or as instruction, not as citation, so a name they carry is not a
# claim the path resolves. Why each: scripts/docs/links.md.
for c in "${corpus[@]}"; do
  case "${c#"$agent"/}" in
  session-log.md | archive/* | rules/*) continue ;;
  esac
  dir=$(dirname "$c")
  reported=""
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    case "$target" in
    http* | \#* | mailto:*) continue ;;
    *'<'* | *'>'* | *'…'* | *'*'*) continue ;;   # template placeholders
    esac
    case "$target" in *.md) ;; *) continue ;; esac

    # In scope only if the target addresses the node: an .agent/-prefixed
    # path, a path under one of the node's own directories, or a bare
    # basename. Anything else is a project path. skills/ and its siblings are
    # not on that list even though they sit under .agent/ — the operating
    # model places them outside itself, never loaded and never audited, so a
    # cited skills/testing/SKILL.md is the project's file to keep alive.
    stripped=${target#./}
    inagent=${stripped#.agent/}
    case "$inagent" in
    docs/* | memory/* | rules/* | archive/* | scripts/*) ;;
    */*) continue ;;
    *) ;;
    esac

    # A bare or loosely-written basename resolves if the node holds a file
    # by that name anywhere: `learned.md` is how docs cite `rules/learned.md`.
    tbase=${inagent##*/}
    if [ -e "$dir/$stripped" ] || [ -e "$agent/$inagent" ] || [ -e "$root/$stripped" ]; then
      continue
    fi
    resolved=0
    for nf in "${nodefiles[@]}"; do
      case "$nf" in */"$tbase") resolved=1; break ;; esac
    done
    [ "$resolved" -eq 1 ] && continue
    # Not the node's, but the project holds a file by that name: a memory
    # fact naming `SKILL.md` or `implementer-prompt.md` is describing the
    # project, and the project's files are not the node's to audit.
    case "$projbasenames" in *$'\n'"$tbase"$'\n'*) continue ;; esac
    case " $reported " in *" $target "*) continue ;; esac
    reported="$reported $target"
    echo "BROKEN: ${c#"$root"/} cites $target — no such file in the node"
    findings=$((findings + 1))
  done <<EOF
$(strip_comments "$c" | grep -oE '\]\([^)]+\)' 2>/dev/null | sed 's/^](//; s/)$//'
  strip_comments "$c" | grep -oE '`[^`]+\.md`' 2>/dev/null | tr -d '`')
EOF
done

if [ "$findings" -eq 0 ]; then
  echo "links.sh: $audited files audited, no orphans or broken links"
fi

exit 0
