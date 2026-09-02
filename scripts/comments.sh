#!/usr/bin/env bash
# comments.sh — the comment gate. Flags comments a diff adds to source
# files, against the preset's Comments rule. BLOCK (exit 1): the comment is
# dead on arrival — it cites what a fresh clone cannot open, is commented-out
# code, narrates the change, answers the prompt, or narrates the structure of
# the code under it. REVIEW (exit 0): every other added comment, for the
# author to justify or delete.
#
# Tunables: comments.conf beside this script, which lists every key.
# Full documentation: scripts/docs/comments.md in the dot-agent repo.
#
# Usage: comments.sh [base-ref]      # default: $BASE_REF (origin/main)
#        The change's true parent — never HEAD, which diffs a committed
#        change against itself and passes without reading anything.

set -uo pipefail
unset CDPATH   # an exported CDPATH corrupts $(cd … && pwd) for relative paths

selfdir=$(cd "$(dirname "$0")" && pwd)

BASE_REF="origin/main"
EXTENSIONS="ts tsx js jsx mjs cs java kt go rs rb py sh bash css scss less html vue svelte c h cc cpp hpp swift php sql"
# Trees no one reviews comment-by-comment. Hidden directories are matched
# generically rather than by name: a tool's own directory holds hooks and
# helpers the contract's comment rule was never aimed at, and naming the
# tools we can think of today misses whichever arrives next.
EXCLUDE_RE='(^|/)\.[^/]+/|(^|/)node_modules/|/dist/|/vendor/|\.min\.'
EXCLUDE_RE_EXTRA=""
BLOCK_RE_EXTRA=""
NARRATION_RE_EXTRA=""
CONSTRAINT_RE_EXTRA=""
PRAGMA_RE_EXTRA=""
ROUTINE_MAX_WORDS=8
RESTATE_CHECK=true

conf="$selfdir/comments.conf"
conf_get() { sed -n "s/^$1=//p" "$conf" 2>/dev/null | head -n 1; }
if [ -f "$conf" ]; then
  v=$(conf_get BASE_REF);           [ -n "$v" ] && BASE_REF="$v"
  v=$(conf_get EXTENSIONS);         [ -n "$v" ] && EXTENSIONS="$v"
  v=$(conf_get EXCLUDE_RE);         [ -n "$v" ] && EXCLUDE_RE="$v"
  v=$(conf_get EXCLUDE_RE_EXTRA);   [ -n "$v" ] && EXCLUDE_RE_EXTRA="$v"
  v=$(conf_get BLOCK_RE_EXTRA);     [ -n "$v" ] && BLOCK_RE_EXTRA="$v"
  v=$(conf_get NARRATION_RE_EXTRA); [ -n "$v" ] && NARRATION_RE_EXTRA="$v"
  v=$(conf_get CONSTRAINT_RE_EXTRA);[ -n "$v" ] && CONSTRAINT_RE_EXTRA="$v"
  v=$(conf_get PRAGMA_RE_EXTRA);    [ -n "$v" ] && PRAGMA_RE_EXTRA="$v"
  v=$(conf_get ROUTINE_MAX_WORDS);  [ -n "$v" ] && ROUTINE_MAX_WORDS="$v"
  v=$(conf_get RESTATE_CHECK);      [ -n "$v" ] && RESTATE_CHECK="$v"
fi

# The one numeric key. It reaches awk rather than a shell arithmetic context,
# so a bad value cannot run anything — but it would compare as a string and
# silently change which comments block, and this gate fails closed on a conf
# it cannot use.
case "$ROUTINE_MAX_WORDS" in
  "" | *[!0-9]*)
    echo "comments.sh: ROUTINE_MAX_WORDS is not a whole number: $ROUTINE_MAX_WORDS" >&2
    exit 2 ;;
esac

# Fail closed on a conf regex that will not compile. Every filter below is
# followed by `|| true` to absorb a no-match exit, which is not an error.
# That same `|| true` would absorb the exit a broken pattern raises, and the
# run would report a clean diff it never read. So each conf-supplied pattern
# is compiled here first, by the engine that will consume it, and a bad one
# stops the run.
re_require() {   # re_require <awk|grep> <key> <pattern>
  case "$1" in
    awk)  RE_CHECK="$3" awk 'BEGIN { if ("" ~ ENVIRON["RE_CHECK"]) n = 1 }' \
            >/dev/null 2>&1 ;;
    grep) printf '' | grep -E "$3" >/dev/null 2>&1 ;;
  esac
  [ $? -le 1 ] && return 0
  echo "comments.sh: $2 is not a valid regular expression: $3" >&2
  exit 2
}
re_require awk EXCLUDE_RE "$EXCLUDE_RE"
[ -n "$EXCLUDE_RE_EXTRA" ]    && re_require awk EXCLUDE_RE_EXTRA "$EXCLUDE_RE_EXTRA"
[ -n "$BLOCK_RE_EXTRA" ]      && re_require awk BLOCK_RE_EXTRA "$BLOCK_RE_EXTRA"
[ -n "$NARRATION_RE_EXTRA" ]  && re_require awk NARRATION_RE_EXTRA "$NARRATION_RE_EXTRA"
[ -n "$CONSTRAINT_RE_EXTRA" ] && re_require awk CONSTRAINT_RE_EXTRA "$CONSTRAINT_RE_EXTRA"
[ -n "$PRAGMA_RE_EXTRA" ]     && re_require awk PRAGMA_RE_EXTRA "$PRAGMA_RE_EXTRA"

base="${1:-$BASE_REF}"

if ! git rev-parse --verify -q "$base" >/dev/null; then
  echo "comments.sh: base ref '$base' not found" >&2
  exit 2
fi

exclude_re="$EXCLUDE_RE"
[ -n "$EXCLUDE_RE_EXTRA" ] && exclude_re="$exclude_re|$EXCLUDE_RE_EXTRA"

set --
for ext in $EXTENSIONS; do set -- "$@" "*.${ext}"; done

# Merge-base → worktree, not base...HEAD: a diff ending at the last commit
# cannot see staged or unstaged changes, and the state being handed back is
# normally uncommitted.
mb=$(git merge-base "$base" HEAD) || {
  echo "comments.sh: no merge base between '$base' and HEAD" >&2
  exit 2
}

# A base that resolves to HEAD, with nothing uncommitted, describes an empty
# diff. The gate would read no lines and exit 0 — a pass meaning "this run
# checked nothing", which in a transcript is indistinguishable from a pass
# meaning "the comments are clean". It is the shape a session lands in by
# committing first and then reaching for `comments.sh HEAD`.
if [ "$mb" = "$(git rev-parse HEAD)" ] \
  && git diff --quiet HEAD 2>/dev/null \
  && [ -z "$(git ls-files --others --exclude-standard)" ]; then
  echo "comments.sh: '$base' resolves to HEAD and the tree is clean, so the diff is empty and this run checks nothing. Pass the change's true parent — the branch base, or the commit before the change." >&2
  exit 2
fi

# The prefixes are forced and quoting is turned off, because the header
# line is the only place the filename comes from. `diff.noprefix` or
# `diff.mnemonicPrefix` in a node's git config renames the `b/` the parser
# looks for, and a path holding a non-ASCII byte arrives quoted. Either one
# leaves the filename unset, and every added line is then judged with no
# extension and no path to match the exclusions against.
added=$(git -c core.quotepath=false diff --src-prefix=a/ --dst-prefix=b/ "$mb" -- "$@" \
  | awk '
      /^\+\+\+ / {
        p = substr($0, 5)
        # git appends a tab to this header when the path holds a space.
        sub(/\t.*$/, "", p)
        # A path holding a quote or a control byte is quoted even so.
        if (p ~ /^".*"$/) p = substr(p, 2, length(p) - 2)
        sub(/^b\//, "", p)
        file = p
        next
      }
      /^\+/ && !/^\+\+\+/ {
        line = substr($0, 2)
        print file "\t" line
      }')

# The diff never shows untracked files, so a brand-new unadded source file
# is scanned whole: every comment line in it is a line this diff adds.
# -z, because a name git would quote is not a path any longer, and the
# file would be skipped whole. ENVIRON for the same reason -v is avoided
# below: -v collapses the backslash escapes in a name.
untracked=$(git ls-files --others --exclude-standard -z -- "$@" \
  | while IFS= read -r -d '' uf; do
      [ -f "$uf" ] || continue
      UF="$uf" awk 'BEGIN { f = ENVIRON["UF"] } { print f "\t" $0 }' "$uf"
    done)
if [ -n "$untracked" ]; then
  added=$(printf '%s\n%s' "$added" "$untracked")
fi

# ENVIRON, not -v: an assignment made with -v has its backslash escapes
# processed, so an ERE arriving from the conf reaches awk with `\.` already
# collapsed to `.` — a literal-dot term silently becoming match-anything.
added=$(printf '%s\n' "$added" \
  | EXCLUDE_RE_AWK="$exclude_re" awk -F'\t' '$1 !~ ENVIRON["EXCLUDE_RE_AWK"]' \
  || true)

pragma_re='eslint|prettier|stylelint|@ts-|<reference|istanbul|jest-environment|#!/|shellcheck|noqa|type: ignore|pylint|biome-ignore'
[ -n "$PRAGMA_RE_EXTRA" ] && pragma_re="$pragma_re|$PRAGMA_RE_EXTRA"

# Citations of what a fresh clone cannot open. The core names only the
# universal ones. Workflow-specific reference shapes — ticket ids, task
# numbers — are the node's BLOCK_RE_EXTRA.
block_re='git (show|log|diff|blame|bisect|merge-base|rev-parse)([^[:alnum:]]|$)|(^|[^[:alnum:]])[0-9a-f]{8,40}([^[:alnum:]]|$)|out of scope|for this pass'
[ -n "$BLOCK_RE_EXTRA" ] && block_re="$block_re|$BLOCK_RE_EXTRA"

# Change narration: a comment written from the diff's point of view rather
# than the file's. It carries information to whoever wrote it and none to
# the next reader, who has no before-state to compare against. The terms
# are the ones that cannot be anything else: a comment describing what the
# code did before is describing a version that is not in the file.
narration_re='(^|[^[:alnum:]])(previously|formerly|used to be|no longer|renamed (from|to)|moved (from|to) (the|its)|changed from|as of this (change|commit|pr|version)|(in|for) this (task|change|request|commit|pr|pull request|pass|iteration|implementation|ticket|issue)|this (task|change|request|commit|pr|patch|implementation) (adds|added|removes|removed|changes|changed|fixes|fixed|makes|introduces|updates|updated|supports|supported|handles|handled)|now (returns|supports|uses|handles|takes|accepts|includes|also|correctly|sets|creates|builds|loads|reads|writes)|instead of the (old|previous|former)|was (renamed|moved|replaced|removed|inlined)|(we|i) (added|changed|updated|removed|refactored|implemented|decided|considered|tried)([^[:alnum:]_]|$)|(added|removed|replaced|updated|refactored|migrated|kept) (in|as part of|for) (this|the) (change|commit|pr|pass|task|ticket|refactor))'
[ -n "$NARRATION_RE_EXTRA" ] && narration_re="$narration_re|$NARRATION_RE_EXTRA"

# A comment addressed to whoever asked for the change. The answer belongs in
# the reply, where it is read once; in the file it is read forever, by people
# who never saw the question.
echo_re='(^|[^[:alnum:]])(as (you |the user |the operator )?(requested|asked for|instructed)|as (we |you )?discussed|per (your|the user.s|the operator.s) (request|instruction|ask|comment)|you asked|per our (discussion|chat|conversation)|to answer (your|the) question)'

# Structure narration: the comment that says in English what the next few
# lines say in code — "build the rows", "loop over the items", "increment
# the counter". It is the single most common valueless comment, and unlike a
# restatement its words need not match any identifier, so word-matching
# cannot find it. A verb of routine action plus an article is the shape.
routine_re='(^|[^[:alnum:]_])((build|create|initialize|initialise|set|return|fetch|get|parse|validate|call|render|define|declare|import|export|handle|process|construct|convert|map|filter|sort|add|remove|update|check|store|save|send|start|stop|close|open|clear|reset|apply|wrap|extract|format|compute|calculate)(s|es|ed|ing)?[[:space:]]+(the|a|an|this|these|those|it|them)([^[:alnum:]_]|$)|(loop|iterate)(s|d|ing)?[[:space:]]+(over|through)[[:space:]]|(increment|decrement)(s|ed|ing)?[[:space:]])'

# The escape hatch, and the reason the routine class can block at all. A
# comment that names a cause, a constraint, or an external actor is doing the
# job the rule asks for, whatever verb it opens with: "update the cache
# because the vendor SDK caches credentials" is not structure narration.
# A false positive is repaired by naming the constraint, not by an exception.
constraint_re='because|otherwise|unless|without|so that|until|workaround|bug|quirk|limitation|non[- ]reactive|deadlock|race|invariant|constraint|unsafe|require|must|cannot|can.t|never|only|upstream|vendor|external|protocol|specification|spec |rfc|api|sdk|browser|kernel|driver|compatib|legacy|deliberate|intentional|on purpose|keep in sync'
[ -n "$CONSTRAINT_RE_EXTRA" ] && constraint_re="$constraint_re|$CONSTRAINT_RE_EXTRA"

findings=$(printf '%s\n' "$added" \
  | PRAGMA_RE="$pragma_re" BLOCK_RE="$block_re" NARRATION_RE="$narration_re" \
    ECHO_RE="$echo_re" ROUTINE_RE="$routine_re" CONSTRAINT_RE="$constraint_re" \
    ROUTINE_MAX_WORDS="$ROUTINE_MAX_WORDS" RESTATE_CHECK="$RESTATE_CHECK" \
    awk '
  # A marker opens a comment only in the languages where it does: "#" in
  # shell, python and ruby but not in C-family sources, where it is a
  # preprocessor directive or a region marker. "//" runs the other way
  # round, since in shell it is a string or a syntax error. "--" opens a
  # comment only in SQL. PHP takes both "#" and "//", so it gets its own
  # branch rather than joining either one.
  #
  # A leading "*" continues a comment only inside an open /* */, and a diff
  # of added lines cannot see whether one is open: the line that opened it
  # is usually unchanged context. So the pattern is narrowed rather than
  # tracked — "*" then a space then content, minus the CSS universal
  # selector and its combinators. "*p = 5;" and "* { box-sizing: … }" are
  # code.
  function is_comment(file, line,   star) {
    if (line == "/**" || line == "/*" || line == "*/" || line == "*") return 0
    star = (line ~ /^\*[[:space:]]/ && line !~ /^\*[[:space:]]*[{,+>~=]/)
    if (file ~ /\.(sh|bash|py|rb)$/) return (line ~ /^#/)
    if (file ~ /\.sql$/)             return (line ~ /^--/)
    if (file ~ /\.php$/)             return (line ~ /^(\/\/|\/\*|<!--)/ \
                                             || (line ~ /^#/ && line !~ /^#\[/) \
                                             || star)
    return (line ~ /^(\/\/|\/\*|<!--)/ || star)
  }

  # The comment without its delimiters, so every test below reads the
  # sentence the author wrote rather than the syntax around it.
  function body_of(line,   b) {
    b = line
    sub(/^(\/\/+|\/\*+|\*|<!--|#+|--)[[:space:]]*/, "", b)
    sub(/[[:space:]]*(\*\/|-->)[[:space:]]*$/, "", b)
    sub(/[[:space:]]+$/, "", b)
    return b
  }

  # Code commented out rather than deleted. Every term needs both a code
  # shape and a code character, because a sentence can open with "if" or
  # end with a semicolon and still be prose.
  function is_code(b) {
    if (b ~ /^[{}();][[:space:]]*$/) return 1
    if (b ~ /;[[:space:]]*$/ && b ~ /[=(){}\[\]]|::|->/) return 1
    if (b ~ /^(if|for|while|foreach|switch)[[:space:]]*\(/) return 1
    if (b ~ /^(if|for|while|foreach|switch|return|throw|else|elif|try|catch|finally|def|class|function|func|fn|import|from|export|const|let|var|public|private|protected|internal|static|await|async|print|println|echo|require|include|using|namespace|package|struct|enum|interface|impl|match|yield|assert|raise|delete|new)[^[:alnum:]_]/ \
        && b ~ /[=(){}\[\];]/) return 1
    if (b ~ /^[[:alnum:]_.$]+\([^;]*\)[;,]?$/) return 1
    # An assignment whose right side is a single token ending the line. Prose
    # naming a value runs on past it ("x = the number of retries"), so the
    # end-of-line anchor is what separates the two.
    if (b ~ /^[[:alnum:]_$.]+[[:space:]]*=[[:space:]]*[^[:space:]=]+[[:space:]]*;?$/) return 1
    return 0
  }

  function words_in(s,   parts) { return split(s, parts, /[[:space:]]+/) }

  # Structure narration is the line that opens its comment, never a fragment
  # carried over from the line above. A wrapped paragraph continues onto lines
  # that can start with a routine verb and mean nothing of the kind — "stops
  # the run." is the tail of a sentence, not a narration of the code below.
  # The word cap already covers a long opening line; this covers the short
  # continuation, which is the case that cap cannot see.
  #
  # A markup-only line does not count as an opener. `/// <summary>` above a doc
  # comment is syntax, and the sentence under it is not continuing anything.
  function opens_comment(i,   pb) {
    if (i == 1 || F[i - 1] != F[i] || !C[i - 1]) return 1
    pb = body_of(T[i - 1])
    if (pb == "" || pb ~ /^<\/?[[:alpha:]][^>]*>$/) return 1
    return 0
  }

  # camelCase and PascalCase carry the words a restating comment repeats,
  # so an identifier is split before it is compared. gsub cannot do it —
  # POSIX awk has no backreference in the replacement.
  function decamel(s,   i, ch, prev, out) {
    out = ""
    for (i = 1; i <= length(s); i++) {
      ch = substr(s, i, 1)
      if (ch ~ /[A-Z]/ && prev ~ /[a-z0-9]/) out = out " "
      out = out ch
      prev = ch
    }
    return out
  }

  function stem(w) { sub(/s$/, "", w); return w }

  # The next line of code under a comment, scanning past the rest of its
  # block. A doc comment sits above its member with the block terminator in
  # between, so stopping at the very next line would exempt exactly the
  # doc comments that restate the signature they sit on.
  function code_below(i,   j) {
    for (j = i + 1; j <= n && F[j] == F[i]; j++) if (!C[j]) return T[j]
    return ""
  }

  # A comment whose every content word already appears in the identifiers on
  # the line below it is that line, spelled out. Two content words minimum,
  # so "// the id" over `const id = …` is not a finding.
  function restates(b, code,   n, i, seen, parts, cn, w) {
    if (code == "") return 0
    code = tolower(decamel(code))
    gsub(/[^a-z0-9]+/, " ", code)
    n = split(code, parts, " ")
    if (n == 0) return 0
    for (i = 1; i <= n; i++) seen[stem(parts[i])] = 1
    b = tolower(b)
    gsub(/[^a-z]+/, " ", b)
    cn = split(b, parts, " ")
    n = 0
    for (i = 1; i <= cn; i++) {
      w = parts[i]
      if (length(w) < 3 || index(STOP, " " w " ") > 0) continue
      if (!(stem(w) in seen)) return 0
      n++
    }
    return (n >= 2)
  }

  BEGIN {
    FS = "\t"
    STOP = " the and any all are but for from into its not now that this" \
           " those these with when where which while you your has have had" \
           " will was were been they them their there then than out "
    pragma_re  = tolower(ENVIRON["PRAGMA_RE"])
    block_re   = tolower(ENVIRON["BLOCK_RE"])
    narr_re    = tolower(ENVIRON["NARRATION_RE"])
    echo_re    = tolower(ENVIRON["ECHO_RE"])
    routine_re = tolower(ENVIRON["ROUTINE_RE"])
    constr_re  = tolower(ENVIRON["CONSTRAINT_RE"])
    routine_max = ENVIRON["ROUTINE_MAX_WORDS"] + 0
    restate    = (ENVIRON["RESTATE_CHECK"] != "false")
  }

  # Split on the first tab only: a source line may hold tabs of its own,
  # and $2 would then stop at the first one.
  {
    n++
    tab = index($0, "\t")
    F[n] = substr($0, 1, tab - 1)
    L[n] = substr($0, tab + 1)
    T[n] = L[n]
    sub(/^[[:space:]]+/, "", T[n])
    C[n] = is_comment(F[n], T[n])
  }

  END {
    for (i = 1; i <= n; i++) {
      if (!C[i]) continue
      if (tolower(T[i]) ~ pragma_re) continue
      body = body_of(T[i])
      if (body == "") continue
      lb = tolower(body)
      class = "REVIEW"; reason = ""
      if (lb ~ block_re)      { class = "BLOCK"; reason = "dead citation" }
      else if (is_code(body)) { class = "BLOCK"; reason = "commented-out code" }
      else if (lb ~ narr_re)  { class = "BLOCK"; reason = "change narration" }
      else if (lb ~ echo_re)  { class = "BLOCK"; reason = "answers the prompt" }
      # Routine narration blocks only while it is short. Past the word cap a
      # comment is carrying a clause the verb alone cannot account for, so it
      # is labeled and left to the author rather than deleted on a keyword.
      else if (lb ~ routine_re && lb !~ constr_re && opens_comment(i)) {
        reason = "routine narration"
        if (words_in(body) <= routine_max) class = "BLOCK"
      }
      else if (restate && restates(body, code_below(i))) \
                              { reason = "restates the code below" }
      printf "%s\t%s\t%s\t%s\n", class, reason, F[i], L[i]
    }
  }' \
  || true)

[ -z "$findings" ] && exit 0

show() { awk -F'\t' '{ printf "  %s%s\n    %s\n", $3, ($2 == "" ? "" : "  [" $2 "]"), $4 }'; }

blocked=$(printf '%s\n' "$findings" | grep '^BLOCK	' || true)
review=$(printf '%s\n' "$findings" | grep '^REVIEW	' || true)

if [ -n "$review" ]; then
  echo "REVIEW: comments this diff adds — justify each as a non-obvious invariant,"
  echo "        constraint, or workaround, or delete it:"
  printf '%s\n' "$review" | show
fi

if [ -n "$blocked" ]; then
  [ -n "$review" ] && echo
  echo "BLOCK: comments that are dead on arrival — a citation a fresh clone cannot"
  echo "       open, code left commented out, narration of the change or of the"
  echo "       structure below, or an answer to the prompt. Delete them, or state"
  echo "       the constraint the code cannot; durable why goes to docs:"
  printf '%s\n' "$blocked" | show
  exit 1
fi

exit 0
