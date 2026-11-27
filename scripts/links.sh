#!/usr/bin/env bash

set -u
unset CDPATH

case "${BASH_SOURCE[0]}" in */*) selfdir=${BASH_SOURCE[0]%/*} ;; *) selfdir=. ;; esac
[ -f "$selfdir/runtime.sh" ] || { echo 'links.sh: runtime.sh is missing. Update this node with node.sh update from the dot-agent repository' >&2; exit 1; }
# shellcheck source=runtime.sh
. "$selfdir/runtime.sh"

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

# -H follows a link given on the command line: a worktree may hold .agent as a
# link to the node of another checkout, and find would otherwise stop at it.
nodefiles=()
while IFS= read -r f; do
  [ -n "$f" ] && nodefiles+=("$f")
done < <(find -H "$agent" -type f -name '*.md' 2>/dev/null | LC_ALL=C sort)

# Other checkouts under the root, linked worktrees above all, hold files that
# are not this checkout's, and an orchestrator can keep dozens of them there.
# Git lists no file of another checkout, and the find walk prunes the
# worktrees git names.
git_lists_root() { # the root is in a work tree that does not ignore it
  local top prefix
  top=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null) || return 1
  prefix=$(git -C "$root" rev-parse --show-prefix 2>/dev/null) || return 1
  [ -n "$prefix" ] || return 0
  git -C "$top" check-ignore -q --no-index -- "${prefix%/}" 2>/dev/null
  [ "$?" -eq 1 ]
}
git_markdown() { # the basenames git lists, tracked and untracked; fails when git cannot list them
  set -o pipefail
  {
    git -C "$root" ls-files -z --recurse-submodules -- '*.md' \
      && git -C "$root" ls-files -z --others --exclude-standard -- '*.md'
  } 2>/dev/null | while IFS= read -r -d '' f; do
    case "/$f" in
    */node_modules/* | */vendor/* | */.venv/* | */dist/* | */build/* | */target/*) continue ;;
    esac
    if [ -f "$root/$f" ] && [ ! -L "$root/$f" ]; then printf '%s\n' "${f##*/}"; fi
  done | LC_ALL=C sort -u
}
find_markdown() { # the basenames under the root
  local worktree_prune=() phys wt
  phys=$(cd "$root" 2>/dev/null && pwd -P) || phys=""
  if [ -n "$phys" ]; then
    while IFS= read -r wt; do
      case "$wt" in
      "$phys"/*) worktree_prune+=(-o -path "${root%/}/${wt#"$phys"/}") ;;
      esac
    done < <(git -C "$root" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
  fi
  find "$root" \( -name .git -o -name node_modules -o -name vendor \
    -o -name .venv -o -name dist -o -name build -o -name target \
    ${worktree_prune[@]+"${worktree_prune[@]}"} \) -prune -o \
    -type f -name '*.md' -print 2>/dev/null | sed 's|.*/||' | LC_ALL=C sort -u
}
{ git_lists_root && projbasenames=$(git_markdown); } || projbasenames=$(find_markdown)
projbasenames=$'\n'"$projbasenames"$'\n'

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
audit=()
for f in "${nodefiles[@]}"; do
  rel=${f#"$agent"/}
  is_exempt "$rel" && continue
  audited=$((audited + 1))
  audit+=("$rel")
done

# One awk pass over the corpus answers every audited file. A line citing a
# file's path also holds its basename, so the basename alone decides. Every
# basename ends in .md, so each ".md" in a line is looked up at the lengths
# the basenames take.
uncited=$'\n'
if [ "$audited" -gt 0 ]; then
  uncited=$'\n'$(
    LINKS_AGENT=$agent LINKS_AUDIT=$(printf '%s\n' "${audit[@]}") awk '
      BEGIN {
        n = split(ENVIRON["LINKS_AUDIT"], rel, "\n")
        for (i = 1; i <= n; i++) {
          path[i] = ENVIRON["LINKS_AGENT"] "/" rel[i]
          base = rel[i]
          sub(/.*\//, "", base)
          want[base] = want[base] " " i
          size[length(base)] = 1
        }
        left = n
        for (a = 1; a < ARGC && left > 0; a++) {
          c = ARGV[a]
          while (left > 0 && (getline line < c) > 0) {
            p = 0
            while ((k = index(substr(line, p + 1), ".md")) > 0) {
              p += k
              for (l in size) {
                if (l + 0 > p + 2) continue
                s = substr(line, p + 3 - l, l + 0)
                if (!(s in want)) continue
                m = split(want[s], ids, " ")
                for (j = 1; j <= m; j++)
                  if (!cited[ids[j]] && path[ids[j]] != c) { cited[ids[j]] = 1; left-- }
              }
            }
          }
          close(c)
        }
        for (i = 1; i <= n; i++) if (!cited[i]) print rel[i]
        exit
      }
    ' "${corpus[@]}"
  )$'\n'
fi
for rel in ${audit[@]+"${audit[@]}"}; do
  case "$uncited" in *$'\n'"$rel"$'\n'*) ;; *) continue ;; esac
  case "$rel" in
  */references/* | references/*)
    echo "ORPHAN: $rel — nothing cites it; a reference carries no routing entry, so an uncited one is unreachable: cite it from its area doc, or retire it to archive/" ;;
  *)
    echo "ORPHAN: $rel — nothing in the node cites it" ;;
  esac
  findings=$((findings + 1))
done

nodebases=$'\n'
for nf in "${nodefiles[@]}"; do nodebases="$nodebases${nf##*/}"$'\n'; done
sources=()
for c in "${corpus[@]}"; do
  case "${c#"$agent"/}" in
  session-log.md | archive/* | rules/*) continue ;;
  esac
  sources+=("$c")
done
# One awk pass reads every source. Per file it prints the name, then the link
# targets and backticked .md spans outside comments. An unreadable file comes
# back marked, and strip_comments reports it on stderr as before.
while IFS= read -r rec; do
  case "$rec" in
  U*)
    strip_comments "${rec#U}" >/dev/null
    strip_comments "${rec#U}" >/dev/null
    continue ;;
  F*)
    c=${rec#F}
    dir=${c%/*}
    reported=""
    continue ;;
  esac
  target=${rec#T}
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
  case "$nodebases" in *$'\n'"$tbase"$'\n'*) continue ;; esac
  case "$projbasenames" in *$'\n'"$tbase"$'\n'*) continue ;; esac
  case " $reported " in *" $target "*) continue ;; esac
  reported="$reported $target"
  echo "BROKEN: ${c#"$root"/} cites $target — no such file in the node"
  findings=$((findings + 1))
done < <(
  [ "${#sources[@]}" -eq 0 ] || awk '
    BEGIN {
      for (a = 1; a < ARGC; a++) {
        c = ARGV[a]
        incm = 0
        links = 0
        spans = 0
        r = (getline < c)
        if (r < 0) { print "U" c; continue }
        print "F" c
        for (; r > 0; r = (getline < c)) {
          if (incm) { if (/-->/) { incm = 0; sub(/.*-->/, "") } else continue }
          gsub(/<!--.*-->/, "")
          if (/<!--/) { incm = 1; sub(/<!--.*/, "") }
          s = $0
          while (match(s, /[]][(][^)]+[)]/)) {
            link[++links] = substr(s, RSTART + 2, RLENGTH - 3)
            s = substr(s, RSTART + RLENGTH)
          }
          s = $0
          while (match(s, /`[^`]+\.md`/)) {
            span[++spans] = substr(s, RSTART + 1, RLENGTH - 2)
            s = substr(s, RSTART + RLENGTH)
          }
        }
        close(c)
        for (i = 1; i <= links; i++) print "T" link[i]
        for (i = 1; i <= spans; i++) print "T" span[i]
      }
      exit
    }
  ' "${sources[@]}"
)

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

docfiles=()
for f in "${nodefiles[@]}"; do
  case "${f#"$agent"/}" in
  docs/architecture.md) continue ;;
  docs/*) docfiles+=("$f") ;;
  esac
done
# One awk pass reads every doc's stamp the way stamp_of does. An unreadable
# doc comes back marked, and stamp_of reports it on stderr as before.
stamped=()
stamps=()
unstamped=0
i=0
while IFS= read -r rec; do
  f=${docfiles[$i]}
  i=$((i + 1))
  case "$rec" in
  U) stamp_of "$f" >/dev/null; unstamped=$((unstamped + 1)) ;;
  S) unstamped=$((unstamped + 1)) ;;
  *) stamped+=("$f"); stamps+=("${rec#S}") ;;
  esac
done < <(
  [ "${#docfiles[@]}" -eq 0 ] || awk '
    BEGIN {
      for (a = 1; a < ARGC; a++) {
        c = ARGV[a]
        r = (getline < c)
        if (r < 0) { print "U"; continue }
        found = 0
        stamp = ""
        for (k = 1; r > 0 && k <= 5; k++) {
          if (!found && /^<!-- Checked: .* -->$/) { found = 1; stamp = substr($0, 15, length($0) - 18) }
          r = (getline < c)
        }
        close(c)
        print "S" stamp
      }
      exit
    }
  ' "${docfiles[@]}"
)

if [ "${#stamped[@]}" -gt 0 ]; then
  root_phys=$(cd "$root" && pwd -P)
  if ! command -v git >/dev/null 2>&1 \
    || ! git -C "$root" rev-parse --verify --quiet 'HEAD^{commit}' >/dev/null 2>&1; then
    echo "links.sh: ${#stamped[@]} docs carry a Checked stamp, but $root is not a git repository with commits — drift check skipped"
    exit 0
  fi
  stale=0
  for i in "${!stamped[@]}"; do
    d=${stamped[$i]}
    rel=${d#"$agent"/}
    stamp=${stamps[$i]}
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
    dir=${d%/*}
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
$(da_doc_citations "$d")
EOF
  done
  if [ "$stale" -eq 0 ]; then
    echo "links.sh: drift check — ${#stamped[@]} stamped docs, $unstamped unstamped, no cited project path changed since its stamp"
  else
    echo "links.sh: drift check — ${#stamped[@]} stamped docs, $unstamped unstamped, $stale stale citations — re-read the cited code, update the doc, then restamp it with docs.sh check --name <doc>"
  fi
fi

exit 0
