#!/usr/bin/env bash

set -u

root="${1:-.}"
case "$root" in
-h | --help)
  cat <<'EOF'
Usage: links.sh [root]

Reports ORPHAN: (a file in the node nothing cites) and BROKEN: (a node path
cited by a node file that does not exist). Paths outside .agent/ are out of
scope. root defaults to . — findings never change the exit status. A root
holding no .agent/ is a usage error and exits 1.
EOF
  exit 0 ;;
esac

agent="$root/.agent"
if [ ! -d "$agent" ]; then
  echo "links.sh: no .agent directory at $agent — run from the node's project root, or pass that root as an argument" >&2
  exit 1
fi

is_exempt() {
  case "$1" in
  purpose.md | memory.md | session-log.md) return 0 ;;
  rules/* | docs/architecture.md) return 0 ;;
  memory/* | archive/* | scripts/* | indexes/*) return 0 ;;
  skills/* | workflows/* | agents/* | others/* | tmp/*) return 0 ;;
  esac
  return 1
}

nodefiles=()
while IFS= read -r f; do
  [ -n "$f" ] && nodefiles+=("$f")
done < <(find "$agent" -type f -name '*.md' 2>/dev/null | LC_ALL=C sort)

projbasenames=$'\n'
while IFS= read -r f; do
  [ -n "$f" ] && projbasenames="$projbasenames${f##*/}"$'\n'
done < <(find "$root" \( -name .git -o -name node_modules -o -name vendor \
  -o -name .venv -o -name dist -o -name build -o -name target \) -prune -o \
  -type f -name '*.md' -print 2>/dev/null)

strip_comments() {
  awk '
    incm { if (/-->/) { incm = 0; sub(/.*-->/, "") } else next }
    { gsub(/<!--.*-->/, "") }
    /<!--/ { incm = 1; sub(/<!--.*/, "") }
    { print }
  ' "$1"
}

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

    stripped=${target#./}
    inagent=${stripped#.agent/}
    case "$inagent" in
    docs/* | memory/* | rules/* | archive/* | scripts/*) ;;
    */*) continue ;;
    *) ;;
    esac

    tbase=${inagent##*/}
    if [ -e "$dir/$stripped" ] || [ -e "$agent/$inagent" ] || [ -e "$root/$stripped" ]; then
      continue
    fi
    resolved=0
    for nf in "${nodefiles[@]}"; do
      case "$nf" in */"$tbase") resolved=1; break ;; esac
    done
    [ "$resolved" -eq 1 ] && continue
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
