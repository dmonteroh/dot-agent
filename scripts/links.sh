#!/usr/bin/env bash

set -u
unset CDPATH

root="${1:-.}"
case "$root" in
-h | --help)
  cat <<'EOF'
Usage: links.sh [root]

Reports ORPHAN: (a file in the node nothing cites) and BROKEN: (a node path
cited by a node file that does not exist). Paths outside .agent/ are out of
scope for both. A doc under docs/ stamped <!-- Checked: <sha> --> by
docs.sh check also gets STALE: (a project path it cites changed in a commit
after the stamp). root defaults to . — findings never change the exit status.
A root holding no .agent/ is a usage error and exits 1.
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

# The drift check is opt-in per doc: only a doc docs.sh check has stamped is
# compared against git history, and a node with no stamp prints nothing here.
stamp_of() { # the doc's Checked stamp, from its opening lines
  head -n 5 "$1" | sed -n 's/^<!-- Checked: \(.*\) -->$/\1/p' | head -n 1
}
project_path() { # $1 a cited path, $2 the citing doc's directory: the project-relative path, or nothing
  pp_c=${1#./}
  [ -n "$pp_c" ] || return 0
  for pp_base in "$root" "$2"; do
    pp_t="$pp_base/$pp_c"
    [ -e "$pp_t" ] || continue
    if [ -d "$pp_t" ]; then
      pp_p=$(cd "$pp_t" 2>/dev/null && pwd -P) || continue
    else
      pp_p=$(cd "$(dirname "$pp_t")" 2>/dev/null && pwd -P) || continue
      pp_p="$pp_p/${pp_t##*/}"
    fi
    case "$pp_p" in "$root_phys"/*) ;; *) continue ;; esac
    pp_rel=${pp_p#"$root_phys"/}
    case "$pp_rel" in .agent | .agent/* | .git | .git/*) return 0 ;; esac
    [ -d "$pp_t" ] && pp_rel="$pp_rel/"
    printf '%s\n' "$pp_rel"
    return 0
  done
}

# A cited path that no longer exists is checked against the tree at the
# stamp: if it was a project path then, it was removed or renamed since, the
# worst drift a doc can carry. Only a path git held at the stamp counts, so
# an arbitrary backticked word is never reported.
gone_path() { # $1 a cited path, $2 the citing doc's directory, $3 the stamp: the project-relative path, or nothing
  gp_c=${1#./}
  gp_c=${gp_c%/}
  case "$gp_c" in '' | /* | *[[:space:]]*) return 0 ;; esac
  gp_docdir=${2#"$root"/}
  gp_docdir=${gp_docdir#./}
  for gp_try in "$gp_c" "$gp_docdir/$gp_c"; do
    gp_n=$(printf '%s\n' "$gp_try" | awk -F/ '{
      n = 0
      for (i = 1; i <= NF; i++) {
        if ($i == "" || $i == ".") continue
        if ($i == "..") { if (n == 0) { print ""; exit } n--; continue }
        part[++n] = $i
      }
      out = part[1]; for (i = 2; i <= n; i++) out = out "/" part[i]
      print out
    }')
    case "$gp_n" in '' | .agent | .agent/* | .git | .git/*) continue ;; esac
    [ ! -e "$root/$gp_n" ] || continue
    gp_type=$(git -C "$root" cat-file -t "$3:$gp_n" 2>/dev/null) || continue
    if [ "$gp_type" = tree ]; then printf '%s/\n' "$gp_n"; else printf '%s\n' "$gp_n"; fi
    return 0
  done
}

stamped=()
unstamped=0
for f in "${nodefiles[@]}"; do
  case "${f#"$agent"/}" in
  docs/architecture.md) continue ;;
  docs/*) ;;
  *) continue ;;
  esac
  if [ -n "$(stamp_of "$f")" ]; then stamped+=("$f"); else unstamped=$((unstamped + 1)); fi
done

if [ "${#stamped[@]}" -gt 0 ]; then
  root_phys=$(cd "$root" && pwd -P)
  if ! command -v git >/dev/null 2>&1 \
    || ! git -C "$root" rev-parse --verify --quiet 'HEAD^{commit}' >/dev/null 2>&1; then
    echo "links.sh: ${#stamped[@]} docs carry a Checked stamp, but $root is not a git repository with commits — drift check skipped"
    exit 0
  fi
  stale=0
  for d in "${stamped[@]}"; do
    rel=${d#"$agent"/}
    stamp=$(stamp_of "$d")
    known=1
    case "$stamp" in *[!0123456789abcdef]*) known=0 ;; esac
    if [ "$known" -eq 1 ]; then
      git -C "$root" rev-parse --verify --quiet "$stamp^{commit}" >/dev/null 2>&1 || known=0
    fi
    if [ "$known" -eq 0 ]; then
      echo "links.sh: $rel is stamped at $stamp, which is not a commit in this repository — re-read the code it cites, then restamp it with docs.sh check"
      continue
    fi
    # A commit that also changed the doc is not counted: the doc moved with
    # the code, which is what restamping in the same change records.
    doc_commits=$(git -C "$root" --literal-pathspecs log --format=%H "$stamp..HEAD" -- ".agent/$rel" 2>/dev/null | tr '\n' ' ')
    dir=$(dirname "$d")
    seen=$'\n'
    while IFS= read -r cand; do
      [ -n "$cand" ] || continue
      path=$(project_path "$cand" "$dir")
      gone=0
      if [ -z "$path" ]; then
        path=$(gone_path "$cand" "$dir" "$stamp")
        [ -n "$path" ] || continue
        gone=1
      fi
      case "$seen" in *$'\n'"$path"$'\n'*) continue ;; esac
      seen="$seen$path"$'\n'
      n=$(git -C "$root" --literal-pathspecs log --format=%H "$stamp..HEAD" -- "$path" 2>/dev/null \
        | awk -v skip="$doc_commits" '
            BEGIN { k = split(skip, s, " "); for (i = 1; i <= k; i++) moved[s[i]] = 1 }
            NF && !($1 in moved) { c++ }
            END { print c + 0 }
          ')
      [ "$n" -gt 0 ] || continue
      if [ "$n" -eq 1 ]; then word=commit; else word=commits; fi
      if [ "$gone" -eq 1 ]; then
        echo "STALE: $rel cites $path, removed or renamed in $n $word since checked at $stamp"
      else
        echo "STALE: $rel cites $path, changed in $n $word since checked at $stamp"
      fi
      stale=$((stale + 1))
    done <<EOF
$(strip_comments "$d" | grep -oE '\]\([^)]+\)' 2>/dev/null | sed 's/^](//; s/)$//; s/[[:space:]].*//; s/#.*//'
  strip_comments "$d" | grep -oE '`[^`]+`' 2>/dev/null | tr -d '`' | sed 's/:[0-9][0-9-]*$//')
EOF
  done
  if [ "$stale" -eq 0 ]; then
    echo "links.sh: drift check — ${#stamped[@]} stamped docs, $unstamped unstamped, no cited project path changed since its stamp"
  else
    echo "links.sh: drift check — ${#stamped[@]} stamped docs, $unstamped unstamped, $stale stale citations — re-read the cited code, update the doc, then restamp it with docs.sh check --name <doc>"
  fi
fi

exit 0
