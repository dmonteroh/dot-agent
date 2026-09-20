#!/usr/bin/env bash

set -uo pipefail
unset CDPATH

tmpfile=""
cleanup() { [ -n "$tmpfile" ] && rm -f "$tmpfile"; }
trap cleanup EXIT

selfdir=$(cd "$(dirname "$0")" && pwd)

BASE_REF="origin/main"
EXTENSIONS="ts tsx js jsx mjs cs java kt go rs rb py sh bash css scss less html vue svelte c h cc cpp hpp swift php sql"
EXCLUDE_RE='(^|/)\.[^/]+/|(^|/)node_modules/|/dist/|/vendor/|\.min\.'
EXCLUDE_RE_EXTRA=""
BLOCK_RE_EXTRA=""
NARRATION_RE_EXTRA=""
CONSTRAINT_RE_EXTRA=""
PRAGMA_RE_EXTRA=""
CHAT_RE_EXTRA=""
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
  v=$(conf_get CHAT_RE_EXTRA);      [ -n "$v" ] && CHAT_RE_EXTRA="$v"
fi

case "$ROUTINE_MAX_WORDS" in
  "" | *[!0-9]*)
    echo "comments.sh: ROUTINE_MAX_WORDS is not a whole number: $ROUTINE_MAX_WORDS" >&2
    exit 2 ;;
esac

re_require() {
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
[ -n "$CHAT_RE_EXTRA" ]       && re_require awk CHAT_RE_EXTRA "$CHAT_RE_EXTRA"

base="${1:-$BASE_REF}"

if ! git rev-parse --verify -q "$base" >/dev/null; then
  echo "comments.sh: base ref '$base' not found" >&2
  exit 2
fi

exclude_re="$EXCLUDE_RE"
[ -n "$EXCLUDE_RE_EXTRA" ] && exclude_re="$exclude_re|$EXCLUDE_RE_EXTRA"

set --
for ext in $EXTENSIONS; do set -- "$@" "*.${ext}"; done

mb=$(git merge-base "$base" HEAD) || {
  echo "comments.sh: no merge base between '$base' and HEAD" >&2
  exit 2
}

head_sha=$(git rev-parse HEAD 2>/dev/null)
head_rc=$?
if [ "$head_rc" -ne 0 ]; then
  echo "comments.sh: git rev-parse HEAD failed (exit $head_rc)" >&2
  exit 2
fi

git diff --quiet HEAD 2>/dev/null
diffq_rc=$?
if [ "$diffq_rc" -ge 2 ]; then
  echo "comments.sh: git diff --quiet HEAD failed (exit $diffq_rc)" >&2
  exit 2
fi

others=$(git ls-files --others --exclude-standard 2>/dev/null)
others_rc=$?
if [ "$others_rc" -ne 0 ]; then
  echo "comments.sh: git ls-files --others --exclude-standard failed (exit $others_rc)" >&2
  exit 2
fi

if [ "$mb" = "$head_sha" ] && [ "$diffq_rc" -eq 0 ] && [ -z "$others" ]; then
  echo "comments.sh: '$base' resolves to HEAD and the tree is clean, so the diff is empty and this run checks nothing. Pass the change's true parent — the branch base, or the commit before the change." >&2
  exit 2
fi

tmpfile=$(mktemp "${TMPDIR:-/tmp}/comments-diff.XXXXXX") || {
  echo "comments.sh: could not create a temporary file for the diff" >&2
  exit 2
}
git -c core.quotepath=false diff --src-prefix=a/ --dst-prefix=b/ "$mb" -- "$@" >"$tmpfile"
diff_rc=$?
if [ "$diff_rc" -ne 0 ]; then
  echo "comments.sh: git diff against '$mb' failed (exit $diff_rc)" >&2
  exit 2
fi
added=$(awk '
      /^\+\+\+ / {
        p = substr($0, 5)
        sub(/\t.*$/, "", p)
        if (p ~ /^".*"$/) p = substr(p, 2, length(p) - 2)
        sub(/^b\//, "", p)
        file = p
        next
      }
      /^\+/ && !/^\+\+\+/ {
        line = substr($0, 2)
        print file "\t" line
      }' "$tmpfile")
rm -f "$tmpfile"
tmpfile=""

untracked=$(git ls-files --others --exclude-standard -z -- "$@" \
  | while IFS= read -r -d '' uf; do
      [ -f "$uf" ] || continue
      UF="$uf" awk 'BEGIN { f = ENVIRON["UF"] } { print f "\t" $0 }' "$uf"
    done)
untracked_rc=$?
if [ "$untracked_rc" -ne 0 ]; then
  echo "comments.sh: git ls-files --others --exclude-standard -z failed (exit $untracked_rc)" >&2
  exit 2
fi
if [ -n "$untracked" ]; then
  added=$(printf '%s\n%s' "$added" "$untracked")
fi

added=$(printf '%s\n' "$added" \
  | EXCLUDE_RE_AWK="$exclude_re" awk -F'\t' '$1 !~ ENVIRON["EXCLUDE_RE_AWK"]' \
  || true)

pragma_re='eslint|prettier|stylelint|@ts-|<reference|istanbul|jest-environment|#!/|shellcheck|noqa|type: ignore|pylint|biome-ignore'
[ -n "$PRAGMA_RE_EXTRA" ] && pragma_re="$pragma_re|$PRAGMA_RE_EXTRA"

block_re='git (show|log|diff|blame|bisect|merge-base|rev-parse)([^[:alnum:]]|$)|(^|[^[:alnum:]])[0-9a-f]{8,40}([^[:alnum:]]|$)|out of scope|for this pass'
[ -n "$BLOCK_RE_EXTRA" ] && block_re="$block_re|$BLOCK_RE_EXTRA"

narration_re='(^|[^[:alnum:]])(previously|formerly|used to be|no longer|renamed (from|to)|moved (from|to) (the|its)|changed from|as of this (change|commit|pr|version)|(in|for) this (task|change|request|commit|pr|pull request|pass|iteration|implementation|ticket|issue)|this (task|change|request|commit|pr|patch|implementation) (adds|added|removes|removed|changes|changed|fixes|fixed|makes|introduces|updates|updated|supports|supported|handles|handled)|now (returns|supports|uses|handles|takes|accepts|includes|also|correctly|sets|creates|builds|loads|reads|writes)|instead of the (old|previous|former)|was (renamed|moved|replaced|removed|inlined)|(we|i) (added|changed|updated|removed|refactored|implemented|decided|considered|tried)([^[:alnum:]_]|$)|(added|removed|replaced|updated|refactored|migrated|kept) (in|as part of|for) (this|the) (change|commit|pr|pass|task|ticket|refactor))'
[ -n "$NARRATION_RE_EXTRA" ] && narration_re="$narration_re|$NARRATION_RE_EXTRA"

echo_re='(^|[^[:alnum:]])(as (you |the user |the operator )?(requested|asked for|instructed)|as (we |you )?discussed|per (your|the user.s|the operator.s) (request|instruction|ask|comment)|you asked|per our (discussion|chat|conversation)|to answer (your|the) question)'

chat_re='(^|[^[:alnum:]])(as (you |the reviewer |the operator )?suggested([^[:alnum:]]|$)|per (your|the reviewer.s|the operator.s|our) feedback|to address (your|the) (feedback|comments?)|as (we |you |the team )?agreed([,.;:]|$)|here.s the fixed version|here is the fixed version|fixed version:|revised (version|draft)|draft revision)'
[ -n "$CHAT_RE_EXTRA" ] && chat_re="$chat_re|$CHAT_RE_EXTRA"

draft_v_re='^draft v[0-9]+([^[:alnum:]]|$)'

apology_re='^(sorry|my apologies|apologies)([^[:alnum:]]|$)'

routine_re='(^|[^[:alnum:]_])((build|create|initialize|initialise|set|return|fetch|get|parse|validate|call|render|define|declare|import|export|handle|process|construct|convert|map|filter|sort|add|remove|update|check|store|save|send|start|stop|close|open|clear|reset|apply|wrap|extract|format|compute|calculate)(s|es|ed|ing)?[[:space:]]+(the|a|an|this|these|those|it|them)([^[:alnum:]_]|$)|(loop|iterate)(s|d|ing)?[[:space:]]+(over|through)[[:space:]]|(increment|decrement)(s|ed|ing)?[[:space:]])'

constraint_re='because|otherwise|unless|without|so that|until|workaround|bug|quirk|limitation|non[- ]reactive|deadlock|race|invariant|constraint|unsafe|require|must|cannot|can.t|never|only|upstream|vendor|external|protocol|specification|spec |rfc|api|sdk|browser|kernel|driver|compatib|legacy|deliberate|intentional|on purpose|keep in sync'
[ -n "$CONSTRAINT_RE_EXTRA" ] && constraint_re="$constraint_re|$CONSTRAINT_RE_EXTRA"

findings=$(printf '%s\n' "$added" \
  | PRAGMA_RE="$pragma_re" BLOCK_RE="$block_re" NARRATION_RE="$narration_re" \
    ECHO_RE="$echo_re" ROUTINE_RE="$routine_re" CONSTRAINT_RE="$constraint_re" \
    CHAT_RE="$chat_re" DRAFT_V_RE="$draft_v_re" APOLOGY_RE="$apology_re" \
    ROUTINE_MAX_WORDS="$ROUTINE_MAX_WORDS" RESTATE_CHECK="$RESTATE_CHECK" \
    awk '
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

  function body_of(line,   b) {
    b = line
    sub(/^(\/\/+|\/\*+|\*|<!--|#+|--)[[:space:]]*/, "", b)
    sub(/[[:space:]]*(\*\/|-->)[[:space:]]*$/, "", b)
    sub(/[[:space:]]+$/, "", b)
    return b
  }

  function is_code(b) {
    if (b ~ /^[{}();][[:space:]]*$/) return 1
    if (b ~ /;[[:space:]]*$/ && b ~ /[=(){}\[\]]|::|->/) return 1
    if (b ~ /^(if|for|while|foreach|switch)[[:space:]]*\(/) return 1
    if (b ~ /^(if|for|while|foreach|switch|return|throw|else|elif|try|catch|finally|def|class|function|func|fn|import|from|export|const|let|var|public|private|protected|internal|static|await|async|print|println|echo|require|include|using|namespace|package|struct|enum|interface|impl|match|yield|assert|raise|delete|new)[^[:alnum:]_]/ \
        && b ~ /[=(){}\[\];]/) return 1
    if (b ~ /^[[:alnum:]_.$]+\([^;]*\)[;,]?$/) return 1
    if (b ~ /^[[:alnum:]_$.]+[[:space:]]*=[[:space:]]*[^[:space:]=]+[[:space:]]*;?$/) return 1
    return 0
  }

  function words_in(s,   parts) { return split(s, parts, /[[:space:]]+/) }

  function opens_comment(i,   pb) {
    if (i == 1 || F[i - 1] != F[i] || !C[i - 1]) return 1
    pb = body_of(T[i - 1])
    if (pb == "" || pb ~ /^<\/?[[:alpha:]][^>]*>$/) return 1
    return 0
  }

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

  function code_below(i,   j) {
    for (j = i + 1; j <= n && F[j] == F[i]; j++) if (!C[j]) return T[j]
    return ""
  }

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
    chat_re    = tolower(ENVIRON["CHAT_RE"])
    draft_v_re = tolower(ENVIRON["DRAFT_V_RE"])
    apology_re = tolower(ENVIRON["APOLOGY_RE"])
    routine_max = ENVIRON["ROUTINE_MAX_WORDS"] + 0
    restate    = (ENVIRON["RESTATE_CHECK"] != "false")
  }

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
      else if (lb ~ chat_re || (opens_comment(i) && (lb ~ apology_re || lb ~ draft_v_re))) \
                              { class = "BLOCK"; reason = "chat residue" }
      else if (lb ~ routine_re && lb !~ constr_re && opens_comment(i)) {
        reason = "routine narration"
        if (words_in(body) <= routine_max) class = "BLOCK"
      }
      else if (restate && restates(body, code_below(i))) \
                              { reason = "restates the code below" }
      printf "%s\t%s\t%s\t%s\n", class, reason, F[i], L[i]
    }
  }')
findings_rc=$?
if [ "$findings_rc" -ne 0 ]; then
  echo "comments.sh: the comment classifier failed (exit $findings_rc)" >&2
  exit 2
fi

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
  echo "       structure below, an answer to the prompt, or chat residue (a"
  echo "       feedback reference, an agreement, an apology, a draft-revision"
  echo "       label). Delete them, or state the constraint the code cannot;"
  echo "       durable why goes to docs:"
  printf '%s\n' "$blocked" | show
  exit 1
fi

exit 0
