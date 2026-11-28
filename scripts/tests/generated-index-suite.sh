#!/usr/bin/env bash

: "${reporoot:?run scripts/test.sh}"
IDXSH="$reporoot/scripts/index.sh"

g41="$WORK/g41"
mkdir -p "$g41/.agent/rules" "$g41/.agent/docs"
printf '# Rule Title\nLine one.\nLine two.\n' >"$g41/.agent/rules/r.md"
printf '# Doc With Hook\n<!-- Read when: working on billing -->\nBody.\n' >"$g41/.agent/docs/hooked.md"
printf 'No heading here.\n<!-- Read when: no title case -->\n' >"$g41/.agent/docs/notitle.md"
printf '# Doc Without Hook\nJust body, no hook comment.\n' >"$g41/.agent/docs/nohook.md"
printf '# Linked Rule\nSee [sibling](other.md) and [abs](/etc/hosts) and [ext](https://example.com/page) and [titled](other.md "See the other").\n' >"$g41/.agent/rules/linked.md"
printf '# Other\nOther content.\n' >"$g41/.agent/rules/other.md"
mkdir -p "$g41/.agent/rules/sub"
printf '# Nested Rule\nSee [alpha doc](../../docs/hooked.md) for context.\n' >"$g41/.agent/rules/sub/nested.md"
"$IDXSH" ensure --root "$g41" >"$WORK/g41.out" 2>"$WORK/g41.err"
g41gen=$(sed -n 2p "$g41/.agent/indexes/current.md")
g41dir="$g41/.agent/indexes/$g41gen"

grep -qF "Source: .agent/rules/r.md" "$g41dir"/rules-*.md \
  && grep -qF 'Line one.' "$g41dir"/rules-*.md && grep -qF 'Line two.' "$g41dir"/rules-*.md \
  && pass "grammar: a rule record's full body renders verbatim behind its Source: line" \
  || fail "grammar: a rule record's full body renders verbatim behind its Source: line"

grep -qF -- "- Doc With Hook | working on billing | READ: .agent/docs/hooked.md" "$g41dir"/routes-*.md \
  && pass "grammar: a route record's title and hook come from its heading and Read-when comment" \
  || fail "grammar: a route record's title and hook come from its heading and Read-when comment"

grep -qF "READ: .agent/docs/notitle.md" "$g41dir"/routes-*.md \
  && grep -qF '.agent/docs/notitle.md | no title case | READ:' "$g41dir"/routes-*.md \
  && pass "grammar: a missing heading falls back to the record's own path as title" \
  || fail "grammar: a missing heading falls back to the record's own path as title"

grep -qF -- '- Doc Without Hook | (no hook) | READ:' "$g41dir"/routes-*.md \
  && pass "grammar: a missing Read-when comment renders as (no hook)" \
  || fail "grammar: a missing Read-when comment renders as (no hook)"

grep -qF -- '[abs](/etc/hosts)' "$g41dir"/rules-*.md \
  && pass "links: an absolute-path link is left unmodified" \
  || fail "links: an absolute-path link is left unmodified"

grep -qF -- '[ext](https://example.com/page)' "$g41dir"/rules-*.md \
  && pass "links: a scheme URL link is left unmodified" \
  || fail "links: a scheme URL link is left unmodified"

g41sibling=$(grep -ohE '\[sibling\]\([^)]*\)' "$g41dir"/rules-*.md | head -1 | sed -E 's/^\[sibling\]\(([^)]*)\)$/\1/')
[ -n "$g41sibling" ] && [ -f "$g41/$g41sibling" ] && [ "$g41sibling" = ".agent/rules/other.md" ] \
  && pass "links: a relative link between two rule records rewrites to a path that resolves to the original sibling" \
  || fail "links: a relative link between two rule records rewrites to a path that resolves to the original sibling"

g41nested=$(grep -ohE '\[alpha doc\]\([^)]*\)' "$g41dir"/rules-*.md | head -1 | sed -E 's/^\[alpha doc\]\(([^)]*)\)$/\1/')
[ -n "$g41nested" ] && [ -f "$g41/$g41nested" ] && [ "$g41nested" = ".agent/docs/hooked.md" ] \
  && pass "links: a relative link from a nested rule up into .agent/docs/ resolves to the original doc" \
  || fail "links: a relative link from a nested rule up into .agent/docs/ resolves to the original doc"

g41titled=$(grep -ohE '\[titled\]\(.*\)' "$g41dir"/rules-*.md | head -1 | sed -E 's/^\[titled\]\((.*)\)$/\1/')
g41titledpath=$(printf '%s\n' "$g41titled" | sed -E 's/ "[^"]*"$//')
[ -n "$g41titledpath" ] && [ -f "$g41/$g41titledpath" ] && [ "$g41titledpath" = ".agent/rules/other.md" ] \
  && printf '%s\n' "$g41titled" | grep -qF '"See the other"' \
  && pass "links: a titled relative link rewrites the path and preserves the title" \
  || fail "links: a titled relative link rewrites the path and preserves the title ($g41titled)"

i42="$WORK/i42"
make_index_fixture "$i42"
"$IDXSH" ensure --root "$i42" >"$WORK/i42.out1" 2>"$WORK/i42.err1"
grep -q '^BUILT$' "$WORK/i42.err1" && pass "ensure: a missing index is an initial BUILT, not an error" \
  || fail "ensure: a missing index is an initial BUILT, not an error"
[ "$(cat "$WORK/i42.out1")" = "$i42/.agent/indexes/current.md" ] \
  && pass "ensure: stdout is the absolute entry path" || fail "ensure: stdout is the absolute entry path"
i42old=$(cat "$i42/.agent/indexes/current.md")
idx_snapshot "$i42/.agent/indexes" >"$WORK/i42.before"
"$IDXSH" ensure --root "$i42" >"$WORK/i42.out2" 2>"$WORK/i42.err2"
idx_snapshot "$i42/.agent/indexes" >"$WORK/i42.after"
grep -q '^HIT$' "$WORK/i42.err2" && pass "ensure: an unchanged tree is a warm HIT" || fail "ensure: an unchanged tree is a warm HIT"
[ "$i42old" = "$(cat "$i42/.agent/indexes/current.md")" ] && pass "ensure: a warm hit republishes nothing" || fail "ensure: a warm hit republishes nothing"
cmp -s "$WORK/i42.before" "$WORK/i42.after" && pass "ensure: a warm hit writes zero bytes and touches no mtime" \
  || fail "ensure: a warm hit writes zero bytes and touches no mtime"

i43="$WORK/i43"
make_index_fixture "$i43"
"$IDXSH" ensure --root "$i43" >/dev/null 2>&1
i43old=$(cat "$i43/.agent/indexes/current.md")

printf '# Added\nNew record.\n' >"$i43/.agent/docs/added.md"
"$IDXSH" ensure --root "$i43" >/dev/null 2>"$WORK/i43.a.err"
i43new=$(cat "$i43/.agent/indexes/current.md")
[ "$i43old" != "$i43new" ] && grep -q '^BUILT$' "$WORK/i43.a.err" && pass "invalidation: a source addition rebuilds" \
  || fail "invalidation: a source addition rebuilds"
i43old="$i43new"

printf 'Uncommitted change.\n' >>"$i43/.agent/docs/architecture.md"
"$IDXSH" ensure --root "$i43" >/dev/null 2>&1
i43new=$(cat "$i43/.agent/indexes/current.md")
[ "$i43old" != "$i43new" ] && pass "invalidation: an uncommitted content change rebuilds" \
  || fail "invalidation: an uncommitted content change rebuilds"
i43old="$i43new"

touch -r "$i43/.agent/docs/architecture.md" "$WORK/i43.stamp"
sed 's/alpha/omega/' "$i43/.agent/docs/architecture.md" >"$WORK/i43.edit"
cat "$WORK/i43.edit" >"$i43/.agent/docs/architecture.md"
touch -r "$WORK/i43.stamp" "$i43/.agent/docs/architecture.md"
"$IDXSH" ensure --root "$i43" >/dev/null 2>&1
i43new=$(cat "$i43/.agent/indexes/current.md")
[ "$i43old" != "$i43new" ] && pass "invalidation: a same-length, timestamp-preserving edit rebuilds" \
  || fail "invalidation: a same-length, timestamp-preserving edit rebuilds"
i43old="$i43new"

mv "$i43/.agent/docs/added.md" "$i43/.agent/docs/renamed.md"
"$IDXSH" ensure --root "$i43" >/dev/null 2>&1
i43new=$(cat "$i43/.agent/indexes/current.md")
[ "$i43old" != "$i43new" ] && pass "invalidation: a rename rebuilds" || fail "invalidation: a rename rebuilds"
i43old="$i43new"

rm "$i43/.agent/docs/renamed.md"
"$IDXSH" ensure --root "$i43" >/dev/null 2>&1
i43new=$(cat "$i43/.agent/indexes/current.md")
[ "$i43old" != "$i43new" ] && pass "invalidation: a deletion rebuilds" || fail "invalidation: a deletion rebuilds"

i44="$WORK/i44"
make_index_fixture "$i44"
"$IDXSH" ensure --root "$i44" >/dev/null 2>&1
i44gen=$(sed -n 2p "$i44/.agent/indexes/current.md")
printf 'damage\n' >>"$i44/.agent/indexes/$i44gen"/routes-1.md
"$IDXSH" ensure --root "$i44" >/dev/null 2>"$WORK/i44.d.err"
grep -q '^BUILT$' "$WORK/i44.d.err" && pass "verification: a damaged page forces a rebuild" \
  || fail "verification: a damaged page forces a rebuild"

i44gen=$(sed -n 2p "$i44/.agent/indexes/current.md")
rm "$i44/.agent/indexes/$i44gen"/rules-1.md
"$IDXSH" ensure --root "$i44" >/dev/null 2>"$WORK/i44.m.err"
grep -q '^BUILT$' "$WORK/i44.m.err" && pass "verification: a missing page forces a rebuild" \
  || fail "verification: a missing page forces a rebuild"

printf 'unexpected instruction\n' >>"$i44/.agent/indexes/current.md"
"$IDXSH" ensure --root "$i44" >/dev/null 2>"$WORK/i44.e.err"
grep -q '^BUILT$' "$WORK/i44.e.err" && pass "verification: tampering with the entry itself forces a rebuild" \
  || fail "verification: tampering with the entry itself forces a rebuild"

i45="$WORK/i45"
make_index_fixture "$i45"
"$IDXSH" ensure --root "$i45" >/dev/null 2>&1
i45old=$(cat "$i45/.agent/indexes/current.md")
cp "$IDXSH" "$WORK/i45-index.sh"
printf '\n# a generator revision\n' >>"$WORK/i45-index.sh"
chmod +x "$WORK/i45-index.sh"
"$WORK/i45-index.sh" ensure --root "$i45" >/dev/null 2>"$WORK/i45.g.err"
i45new=$(cat "$i45/.agent/indexes/current.md")
[ "$i45old" != "$i45new" ] && grep -q '^BUILT$' "$WORK/i45.g.err" \
  && pass "invalidation: a changed generator rebuilds" || fail "invalidation: a changed generator rebuilds"

i45oldgen=$(sed -n 2p "$i45/.agent/indexes/current.md")
"$IDXSH" ensure --root "$i45" --budget 4096 >/dev/null 2>"$WORK/i45.b.err"
i45newgen=$(sed -n 2p "$i45/.agent/indexes/current.md")
[ "$i45oldgen" != "$i45newgen" ] && grep -q '^BUILT$' "$WORK/i45.b.err" \
  && pass "invalidation: a changed budget rebuilds" || fail "invalidation: a changed budget rebuilds"
cmp -s "$i45/.agent/indexes/$i45oldgen"/rules-1.md "$i45/.agent/indexes/$i45newgen"/rules-1.md \
  && cmp -s "$i45/.agent/indexes/$i45oldgen"/routes-1.md "$i45/.agent/indexes/$i45newgen"/routes-1.md \
  && pass "rendering: equivalent inputs and budget render byte-identical pages" \
  || fail "rendering: equivalent inputs and budget render byte-identical pages"

i46="$WORK/i46"
make_index_fixture "$i46"
i46out=$("$IDXSH" check --root "$i46" 2>"$WORK/i46.err1"); i46rc=$?
[ "$i46rc" -eq 1 ] && [ "$i46out" = STALE ] && [ ! -e "$i46/.agent/indexes" ] \
  && pass "check: no index yet is STALE and creates nothing" || fail "check: no index yet is STALE and creates nothing"
"$IDXSH" ensure --root "$i46" >/dev/null 2>&1
i46out=$("$IDXSH" check --root "$i46" 2>"$WORK/i46.err2"); i46rc=$?
[ "$i46rc" -eq 0 ] && [ "$i46out" = FRESH ] && pass "check: a valid cache is FRESH at exit 0" \
  || fail "check: a valid cache is FRESH at exit 0"
printf 'more\n' >>"$i46/.agent/docs/architecture.md"
i46out=$("$IDXSH" check --root "$i46" 2>"$WORK/i46.err3"); i46rc=$?
[ "$i46rc" -eq 1 ] && [ "$i46out" = STALE ] && pass "check: a changed source is STALE at exit 1" \
  || fail "check: a changed source is STALE at exit 1"

i47sym="$WORK/i47sym"
make_index_fixture "$i47sym"
ln -s architecture.md "$i47sym/.agent/docs/link.md"
"$IDXSH" ensure --root "$i47sym" >/dev/null 2>"$WORK/i47.sym.err"
grep -q 'FALLBACK:' "$WORK/i47.sym.err" && pass "rejection: a source symlink falls back rather than being indexed" \
  || fail "rejection: a source symlink falls back rather than being indexed"

i47bad="$WORK/i47bad"
make_index_fixture "$i47bad"
printf '# Bad\n' >"$i47bad/.agent/docs/bad name.md"
"$IDXSH" ensure --root "$i47bad" >/dev/null 2>"$WORK/i47.bad.err"
grep -q 'FALLBACK:' "$WORK/i47.bad.err" && pass "rejection: an unsupported filename falls back rather than being indexed" \
  || fail "rejection: an unsupported filename falls back rather than being indexed"

i47big="$WORK/i47big"
mkdir -p "$i47big/.agent/rules"
awk 'BEGIN { for (i = 0; i < 2000; i++) print "long rule line filler text" }' >"$i47big/.agent/rules/large.md"
"$IDXSH" ensure --root "$i47big" --budget 256 >/dev/null 2>"$WORK/i47.big.err"
grep -q 'record exceeds page budget' "$WORK/i47.big.err" && grep -q 'FALLBACK:' "$WORK/i47.big.err" \
  && pass "overflow: a record too large for its own page falls back without truncation" \
  || fail "overflow: a record too large for its own page falls back without truncation"

# The entry holds one READ line per page, so many small routes split across
# many pages at a small budget, and the entry outgrows that budget.
i47long="$WORK/i47long"
mkdir -p "$i47long/.agent/docs"
i47n=0
while [ "$i47n" -lt 40 ]; do printf '# Doc %s\n' "$i47n" >"$i47long/.agent/docs/doc-$i47n.md"; i47n=$((i47n + 1)); done
"$IDXSH" ensure --root "$i47long" >/dev/null 2>&1
cp "$i47long/.agent/indexes/current.md" "$WORK/i47.long-entry"
"$IDXSH" ensure --root "$i47long" --budget 256 >/dev/null 2>"$WORK/i47.long.err"
grep -q 'entry exceeds page budget' "$WORK/i47.long.err" && grep -q 'FALLBACK:' "$WORK/i47.long.err" \
  && cmp -s "$WORK/i47.long-entry" "$i47long/.agent/indexes/current.md" \
  && pass "overflow: an entry too large for the budget falls back and preserves the prior publication" \
  || fail "overflow: an entry too large for the budget falls back and preserves the prior publication"

i48="$WORK/i48"
make_index_fixture "$i48"
"$IDXSH" ensure --root "$i48" >/dev/null 2>&1
real_awk=$(command -v awk)
mkdir -p "$WORK/i48bin"
cat >"$WORK/i48bin/awk" <<WRAPPER
#!/bin/sh
"$real_awk" "\$@"
rc=\$?
case "\$*" in *out=*)
  if [ "\${TEST_MODE:-}" = mutate_once ] && [ ! -f "\$MARKER" ]; then
    : >"\$MARKER"
    printf 'transient\n' >>"\$TARGET"
  elif [ "\${TEST_MODE:-}" = mutate_always ]; then
    printf 'mutation\n' >>"\$TARGET"
  elif [ "\${TEST_MODE:-}" = pause ]; then
    printf ready >"\$GATE"
    n=0
    while [ ! -f "\$GATE.go" ]; do sleep 0.05; n=\$((n + 1)); [ "\$n" -lt 100 ] || break; done
    printf done >"\$GATE.done"
  fi ;;
esac
exit "\$rc"
WRAPPER
chmod +x "$WORK/i48bin/awk"

printf 'stale-before-retry\n' >>"$i48/.agent/docs/architecture.md"
i48old=$(cat "$i48/.agent/indexes/current.md")
rm -f "$WORK/i48.marker"
PATH="$WORK/i48bin:$PATH" TEST_MODE=mutate_once MARKER="$WORK/i48.marker" TARGET="$i48/.agent/docs/architecture.md" \
  "$IDXSH" ensure --root "$i48" >/dev/null 2>"$WORK/i48.once.err"
grep -q '^BUILT$' "$WORK/i48.once.err" && [ "$i48old" != "$(cat "$i48/.agent/indexes/current.md")" ] \
  && pass "retry: a one-time transient mutation during rendering still succeeds via retry" \
  || fail "retry: a one-time transient mutation during rendering still succeeds via retry"

i48old=$(cat "$i48/.agent/indexes/current.md")
printf 'force-stale\n' >>"$i48/.agent/docs/architecture.md"
PATH="$WORK/i48bin:$PATH" TEST_MODE=mutate_always TARGET="$i48/.agent/docs/architecture.md" \
  "$IDXSH" ensure --root "$i48" >/dev/null 2>"$WORK/i48.always.err"; i48rc=$?
[ "$i48rc" -eq 1 ] && grep -q 'exhausted' "$WORK/i48.always.err" \
  && [ "$i48old" = "$(cat "$i48/.agent/indexes/current.md")" ] \
  && pass "retry: sources changing on every attempt exhausts the bound and preserves the prior entry" \
  || fail "retry: sources changing on every attempt exhausts the bound and preserves the prior entry"

i49="$WORK/i49"
make_index_fixture "$i49"
"$IDXSH" ensure --root "$i49" >/dev/null 2>&1
i49gen=$(sed -n 2p "$i49/.agent/indexes/current.md")
cp -R "$i49/.agent/indexes/$i49gen" "$WORK/i49-old-generation"
printf 'concurrency\n' >>"$i49/.agent/docs/architecture.md"
i49pids=""
for n in 1 2 3 4; do
  "$IDXSH" ensure --root "$i49" >"$WORK/i49.$n.out" 2>"$WORK/i49.$n.err" &
  i49pids="$i49pids $!"
done
for p in $i49pids; do wait "$p"; done
i49fell_back=""
for n in 1 2 3 4; do grep -q 'FALLBACK:' "$WORK/i49.$n.err" && i49fell_back="$i49fell_back $n"; done
[ -z "$i49fell_back" ] && pass "concurrency: four parallel writers all complete without falling back" \
  || fail "concurrency: four parallel writers all complete without falling back (writer(s):$i49fell_back)"
"$IDXSH" ensure --root "$i49" >/dev/null 2>"$WORK/i49.final.err"
grep -q '^HIT$' "$WORK/i49.final.err" && pass "concurrency: the state after concurrent writers is itself a valid, consistent hit" \
  || fail "concurrency: the state after concurrent writers is itself a valid, consistent hit"
diff -r "$WORK/i49-old-generation" "$i49/.agent/indexes/$i49gen" >/dev/null 2>&1 \
  && pass "concurrency: an old generation a reader already selected is left untouched" \
  || fail "concurrency: an old generation a reader already selected is left untouched"

i49k="$WORK/i49k"
make_index_fixture "$i49k"
"$IDXSH" ensure --root "$i49k" >/dev/null 2>&1
i49kold=$(cat "$i49k/.agent/indexes/current.md")
printf 'crash-trigger\n' >>"$i49k/.agent/docs/architecture.md"
PATH="$WORK/i48bin:$PATH" TEST_MODE=pause GATE="$WORK/i49k.gate" \
  "$IDXSH" ensure --root "$i49k" >"$WORK/i49k.out" 2>"$WORK/i49k.err" &
i49kpid=$!
i49kn=0
while [ ! -f "$WORK/i49k.gate" ]; do sleep 0.05; i49kn=$((i49kn + 1)); [ "$i49kn" -lt 100 ] || break; done
kill -KILL "$i49kpid" 2>/dev/null || true
wait "$i49kpid" 2>/dev/null || true
: >"$WORK/i49k.gate.go"
i49kdn=0
while [ ! -f "$WORK/i49k.gate.done" ]; do sleep 0.05; i49kdn=$((i49kdn + 1)); [ "$i49kdn" -lt 100 ] || break; done
[ "$i49kold" = "$(cat "$i49k/.agent/indexes/current.md")" ] \
  && pass "concurrency: a killed writer publishes nothing and leaves the prior entry readable" \
  || fail "concurrency: a killed writer publishes nothing and leaves the prior entry readable"
"$IDXSH" ensure --root "$i49k" >/dev/null 2>"$WORK/i49k.retry1.err"
"$IDXSH" ensure --root "$i49k" >/dev/null 2>"$WORK/i49k.retry2.err"
grep -q '^BUILT$' "$WORK/i49k.retry1.err" && grep -q '^HIT$' "$WORK/i49k.retry2.err" \
  && pass "concurrency: the next run after a kill rebuilds cleanly with no lock recovery" \
  || fail "concurrency: the next run after a kill rebuilds cleanly with no lock recovery"

i50="$WORK/i50"
make_index_fixture "$i50"
"$IDXSH" ensure --root "$i50" >/dev/null 2>&1
i50a=$(sed -n 2p "$i50/.agent/indexes/current.md")
touch -t 202001010000 "$i50/.agent/indexes/$i50a"
printf 'v2\n' >>"$i50/.agent/docs/architecture.md"
INDEX_CLEANUP_AGE_SECONDS=60 "$IDXSH" ensure --root "$i50" >/dev/null 2>&1
i50b=$(sed -n 2p "$i50/.agent/indexes/current.md")
[ -d "$i50/.agent/indexes/$i50a" ] \
  && pass "cleanup: the generation this build replaced is exempt even when old" \
  || fail "cleanup: the generation this build replaced is exempt even when old"
touch -t 202001010000 "$i50/.agent/indexes/$i50b"
printf 'v3\n' >>"$i50/.agent/docs/architecture.md"
INDEX_CLEANUP_AGE_SECONDS=60 "$IDXSH" ensure --root "$i50" >/dev/null 2>&1
i50c=$(sed -n 2p "$i50/.agent/indexes/current.md")
[ ! -d "$i50/.agent/indexes/$i50a" ] && [ -d "$i50/.agent/indexes/$i50b" ] && [ -d "$i50/.agent/indexes/$i50c" ] \
  && pass "cleanup: an old generation two publishes stale is reclaimed once past the age bound" \
  || fail "cleanup: an old generation two publishes stale is reclaimed once past the age bound"

i50f="$WORK/i50f"
make_index_fixture "$i50f"
"$IDXSH" ensure --root "$i50f" >/dev/null 2>&1
i50fa=$(sed -n 2p "$i50f/.agent/indexes/current.md")
printf 'v2\n' >>"$i50f/.agent/docs/architecture.md"
INDEX_CLEANUP_AGE_SECONDS=300 "$IDXSH" ensure --root "$i50f" >/dev/null 2>&1
[ -d "$i50f/.agent/indexes/$i50fa" ] \
  && pass "cleanup: a fresh superseded generation stays within the age bound's grace window" \
  || fail "cleanup: a fresh superseded generation stays within the age bound's grace window"

i51="$WORK/i51"
make_index_fixture "$i51"
git -C "$i51" init -q
git -C "$i51" config user.name Tester
git -C "$i51" config user.email tester@example.invalid
printf '.agent/indexes/\n' >"$i51/.gitignore"
git -C "$i51" add .
git -C "$i51" commit -qm initial
i51base=$(git -C "$i51" symbolic-ref --short HEAD)
"$IDXSH" ensure --root "$i51" >/dev/null 2>&1
i51old=$(cat "$i51/.agent/indexes/current.md")
git -C "$i51" checkout -qb alternate
printf 'alternate branch content\n' >>"$i51/.agent/docs/architecture.md"
git -C "$i51" commit -qam alternate
"$IDXSH" ensure --root "$i51" >/dev/null 2>&1
[ "$i51old" != "$(cat "$i51/.agent/indexes/current.md")" ] \
  && pass "branch switch: checking out a branch with different content invalidates the cache" \
  || fail "branch switch: checking out a branch with different content invalidates the cache"
git -C "$i51" checkout -q "$i51base"
"$IDXSH" ensure --root "$i51" >/dev/null 2>&1
i51back=$(cat "$i51/.agent/indexes/current.md")
[ "$i51old" != "$i51back" ] \
  && pass "branch switch: returning to the original branch rebuilds a fresh generation" \
  || fail "branch switch: returning to the original branch rebuilds a fresh generation"
[ "$(printf '%s\n' "$i51old" | head -1)" = "$(printf '%s\n' "$i51back" | head -1)" ] \
  && pass "branch switch: the fingerprint itself returns to the original value" \
  || fail "branch switch: the fingerprint itself returns to the original value"

git -C "$i51" worktree add -q "$WORK/i51-wt" alternate
"$IDXSH" ensure --root "$WORK/i51-wt" >/dev/null 2>&1
[ -f "$WORK/i51-wt/.agent/indexes/current.md" ] \
  && pass "worktree: a linked worktree builds its own cache" || fail "worktree: a linked worktree builds its own cache"
cmp -s "$i51/.agent/indexes/current.md" "$WORK/i51-wt/.agent/indexes/current.md" \
  && fail "worktree: the two worktrees' caches are isolated" \
  || pass "worktree: the two worktrees' caches are isolated"
[ -z "$(git -C "$i51" status --porcelain)" ] && [ -z "$(git -C "$WORK/i51-wt" status --porcelain)" ] \
  && pass "worktree: the ignored cache leaves both working trees clean" \
  || fail "worktree: the ignored cache leaves both working trees clean"
git -C "$i51" worktree remove -f "$WORK/i51-wt" >/dev/null 2>&1 || rm -rf "$WORK/i51-wt"

i52="$WORK/i52"
make_index_fixture "$i52"
"$IDXSH" ensure --root "$i52" >/dev/null 2>&1
idx_snapshot "$i52/.agent/indexes" >"$WORK/i52.before"
"$IDXSH" check --root "$i52" >/dev/null 2>&1
"$IDXSH" check --root "$i52" >/dev/null 2>&1
idx_snapshot "$i52/.agent/indexes" >"$WORK/i52.after"
cmp -s "$WORK/i52.before" "$WORK/i52.after" && pass "check: repeated calls write zero bytes and touch no mtime" \
  || fail "check: repeated calls write zero bytes and touch no mtime"

"$IDXSH" --help >"$WORK/i53.help" 2>&1; i53rc=$?
[ "$i53rc" -eq 0 ] && head -n 1 "$WORK/i53.help" | grep -q '^Usage:$' && grep -qF 'index.sh ensure' "$WORK/i53.help" \
  && pass "usage: --help prints usage at exit 0" || fail "usage: --help prints usage at exit 0"
"$IDXSH" --version >"$WORK/i53.version" 2>&1; i53rc=$?
[ "$i53rc" -eq 0 ] && grep -qF 'index.sh schema' "$WORK/i53.version" \
  && pass "usage: --version prints at exit 0" || fail "usage: --version prints at exit 0"
"$IDXSH" >/dev/null 2>&1; [ "$?" -eq 2 ] && pass "usage: no operation is a usage error (exit 2)" \
  || fail "usage: no operation is a usage error (exit 2)"
"$IDXSH" bogus >/dev/null 2>&1; [ "$?" -eq 2 ] && pass "usage: an unknown operation is a usage error (exit 2)" \
  || fail "usage: an unknown operation is a usage error (exit 2)"
"$IDXSH" ensure --budget 4 >/dev/null 2>&1; [ "$?" -eq 2 ] && pass "usage: a budget outside 256..1000000 is a usage error (exit 2)" \
  || fail "usage: a budget outside 256..1000000 is a usage error (exit 2)"
i53noagent="$WORK/i53noagent"
mkdir -p "$i53noagent"
"$IDXSH" ensure --root "$i53noagent" >/dev/null 2>&1; [ "$?" -eq 2 ] \
  && pass "usage: a root with no .agent/ is a usage error (exit 2)" || fail "usage: a root with no .agent/ is a usage error (exit 2)"
i53="$WORK/i53"
make_index_fixture "$i53"
"$IDXSH" ensure --root "$i53" >/dev/null 2>&1; [ "$?" -eq 0 ] \
  && pass "exit status: ensure BUILT is exit 0" || fail "exit status: ensure BUILT is exit 0"
"$IDXSH" ensure --root "$i53" >/dev/null 2>&1; [ "$?" -eq 0 ] \
  && pass "exit status: ensure HIT is exit 0" || fail "exit status: ensure HIT is exit 0"
"$IDXSH" check --root "$i53" >/dev/null 2>&1; [ "$?" -eq 0 ] \
  && pass "exit status: check FRESH is exit 0" || fail "exit status: check FRESH is exit 0"

i54="$WORK/i54"
mkdir -p "$i54/.agent/rules" "$i54/.agent/docs/sub"
printf '# Rule A\nBody A.\n' >"$i54/.agent/rules/a.md"
printf '# Rule B\nBody B.\n' >"$i54/.agent/rules/b.md"
printf '# Doc A\n<!-- Read when: doc a -->\nBody.\n' >"$i54/.agent/docs/a.md"
printf '# Sub Doc\n<!-- Read when: sub area -->\nBody.\n' >"$i54/.agent/docs/sub/s.md"
"$IDXSH" ensure --root "$i54" >/dev/null 2>&1
i54gen=$(sed -n 2p "$i54/.agent/indexes/current.md")
i54dir="$i54/.agent/indexes/$i54gen"
i54bad=""
while IFS= read -r rl; do
  target=${rl#READ: }
  [ -f "$i54/$target" ] || i54bad="$i54bad $target"
done < <(grep '^READ:' "$i54/.agent/indexes/current.md")
[ -z "$i54bad" ] && pass "resolution: every entry-file READ line names a file that exists" \
  || fail "resolution: every entry-file READ line names a file that exists ($i54bad)"
i54routebad=""
while IFS= read -r rl; do
  target=${rl##*READ: }
  [ -f "$i54/$target" ] || i54routebad="$i54routebad $target"
done < <(grep -h '| READ:' "$i54dir"/routes-*.md)
[ -z "$i54routebad" ] && pass "resolution: every route line's READ pointer resolves to a real canonical source" \
  || fail "resolution: every route line's READ pointer resolves to a real canonical source ($i54routebad)"
i54srcbad=""
for f in "$i54dir"/rules-*.md; do
  src=$(sed -n 's/^Source: //p' "$f" | head -1)
  [ -f "$i54/$src" ] || i54srcbad="$i54srcbad $src"
done
[ -z "$i54srcbad" ] && pass "resolution: every rule page's Source: pointer resolves to a real canonical source" \
  || fail "resolution: every rule page's Source: pointer resolves to a real canonical source ($i54srcbad)"
grep -qF 'Body A.' "$i54dir"/rules-*.md && grep -qF 'Body B.' "$i54dir"/rules-*.md \
  && pass "resolution: rule pages are complete — every rule record's body is present" \
  || fail "resolution: rule pages are complete — every rule record's body is present"

i55="$WORK/i55"
make_index_fixture "$i55"
"$IDXSH" ensure --root "$i55" >"$WORK/i55.out" 2>"$WORK/i55.err"
[ "$(wc -l <"$WORK/i55.out" | tr -d ' ')" -eq 1 ] && [ "$(cat "$WORK/i55.out")" = "$i55/.agent/indexes/current.md" ] \
  && pass "contract: ensure's stdout is exactly one line, the entry path" \
  || fail "contract: ensure's stdout is exactly one line, the entry path"
grep -qi 'Read when\|Project guardrails\|Body text' "$WORK/i55.out" \
  && fail "contract: ensure's stdout never carries rule bodies or routing tables" \
  || pass "contract: ensure's stdout never carries rule bodies or routing tables"
"$IDXSH" check --root "$i55" >"$WORK/i55.check.out" 2>"$WORK/i55.check.err"
[ "$(cat "$WORK/i55.check.out")" = FRESH ] \
  && pass "contract: check's stdout is exactly FRESH or STALE, nothing else" \
  || fail "contract: check's stdout is exactly FRESH or STALE, nothing else"

gi56_combo() {
  gi56_mode="$1" gi56_idx="$2" gi56_exp_learned="$3" gi56_exp_indexes="$4"
  gi56_dir="$WORK/gi56-$gi56_mode-$gi56_idx"
  mkdir -p "$gi56_dir"
  "$NODE" init --preset software-development --mode "$gi56_mode" --indexes "$gi56_idx" "$gi56_dir" >/dev/null 2>&1
  git -C "$gi56_dir" init -q
  if git -C "$gi56_dir" check-ignore -q .agent/rules/learned.md; then gi56_ign1=1; else gi56_ign1=0; fi
  [ "$gi56_ign1" -eq "$gi56_exp_learned" ] \
    && pass "gitignore $gi56_mode/$gi56_idx: .agent/rules/learned.md ignored=$gi56_exp_learned" \
    || fail "gitignore $gi56_mode/$gi56_idx: .agent/rules/learned.md ignored=$gi56_exp_learned (got $gi56_ign1)"
  if git -C "$gi56_dir" check-ignore -q .agent/indexes/current.md; then gi56_ign2=1; else gi56_ign2=0; fi
  [ "$gi56_ign2" -eq "$gi56_exp_indexes" ] \
    && pass "gitignore $gi56_mode/$gi56_idx: .agent/indexes/ ignored=$gi56_exp_indexes" \
    || fail "gitignore $gi56_mode/$gi56_idx: .agent/indexes/ ignored=$gi56_exp_indexes (got $gi56_ign2)"
}
gi56_combo ignore-all manual 1 1
gi56_combo ignore-all generated 1 1
gi56_combo track-shared manual 0 1
gi56_combo track-shared generated 1 1
gi56_combo track-all manual 0 0
gi56_combo track-all generated 1 1

[ "$(cat "$WORK/gi56-ignore-all-manual/.gitignore" 2>/dev/null)" = "$(cat "$WORK/gi56-ignore-all-generated/.gitignore" 2>/dev/null)" ] \
  && pass "gitignore: ignore-all is unchanged from today whether indexes is manual or generated" \
  || fail "gitignore: ignore-all is unchanged from today whether indexes is manual or generated"
[ ! -e "$WORK/gi56-track-all-manual/.gitignore" ] \
  && pass "gitignore: track-all/manual writes no gitignore, as today" \
  || fail "gitignore: track-all/manual writes no gitignore, as today"

gi56home="$WORK/gi56-home-track-all-generated"
mkdir -p "$gi56home"
HOME="$gi56home" "$NODE" init --preset software-development --mode track-all --indexes generated "$gi56home" >"$WORK/gi56home.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] && [ -d "$gi56home/.agent" ] && pass "init at \$HOME, track-all/generated, exits 0 and creates the node" || fail "init at \$HOME, track-all/generated, exits 0 and creates the node"
grep -qF 'skipped gitignore at $HOME' "$WORK/gi56home.out" \
  && pass "init at \$HOME, track-all/generated, warns about the skipped gitignore" \
  || fail "init at \$HOME, track-all/generated, warns about the skipped gitignore"
[ ! -e "$gi56home/.gitignore" ] \
  && pass "init at \$HOME, track-all/generated, still writes no gitignore" \
  || fail "init at \$HOME, track-all/generated, still writes no gitignore"
HOME="$gi56home" "$NODE" update --indexes generated "$gi56home" >"$WORK/gi56home-update.out" 2>&1
rc_gi56home_update=$?
[ "$rc_gi56home_update" -eq 0 ] && [ -f "$gi56home/.agent/indexes/current.md" ] \
  && pass "generated adoption at \$HOME still builds and verifies the index" \
  || fail "generated adoption at \$HOME still builds and verifies the index (rc=$rc_gi56home_update)"
[ ! -e "$gi56home/.gitignore" ] && grep -qF 'skipped gitignore at $HOME' "$WORK/gi56home-update.out" \
  && pass "generated adoption at \$HOME leaves gitignore reconciliation to the operator" \
  || fail "generated adoption at \$HOME leaves gitignore reconciliation to the operator"

gi56homeman="$WORK/gi56-home-track-all-manual"
mkdir -p "$gi56homeman"
HOME="$gi56homeman" "$NODE" init --preset software-development --mode track-all --indexes manual "$gi56homeman" >"$WORK/gi56homeman.out" 2>&1
grep -qF 'skipped gitignore at $HOME' "$WORK/gi56homeman.out" \
  && fail "init at \$HOME, track-all/manual, stays silent (no warning)" \
  || pass "init at \$HOME, track-all/manual, stays silent (no warning)"

gep="$WORK/generated-entry-point"
mkdir -p "$gep"
"$NODE" init --preset software-development --mode track-all --indexes generated "$gep" >/dev/null 2>&1
finish_bootstrap "$gep"
cp "$reporoot/templates/entry-point-generated.md" "$gep/CLAUDE.md"
cp "$reporoot/templates/entry-point-generated.md" "$gep/AGENTS.md"
gep_flags=$(status_flags "$gep")
[ -z "$gep_flags" ] \
  && pass "generated-mode entry point: templates/entry-point-generated.md draws no status.sh finding" \
  || fail "generated-mode entry point: templates/entry-point-generated.md draws no status.sh finding ($gep_flags)"

cp "$reporoot/templates/entry-point.md" "$gep/AGENTS.md"
gep_flags2=$(status_flags "$gep")
printf '%s\n' "$gep_flags2" | grep -qF 'REPAIR: AGENTS.md differs from CLAUDE.md' \
  && pass "generated-mode entry point: pairing it with the manual template draws a drift REPAIR" \
  || fail "generated-mode entry point: pairing it with the manual template draws a drift REPAIR ($gep_flags2)"

i58src="$WORK/i58-source"
mkdir -p "$i58src"
"$NODE" init --preset software-development --mode track-shared --indexes generated "$i58src" >/dev/null 2>&1
git -C "$i58src" init -q
git -C "$i58src" config user.name Tester
git -C "$i58src" config user.email tester@example.invalid
git -C "$i58src" add -A
git -C "$i58src" commit -qm bootstrap
i58base=$(git -C "$i58src" symbolic-ref --short HEAD)

i58clone="$WORK/i58-clone"
git clone -q "$i58src" "$i58clone"
[ ! -e "$i58clone/.agent/scripts/index.sh" ] \
  && pass "clone: a fresh clone of a track-shared node starts without index.sh (gitignored)" \
  || fail "clone: a fresh clone of a track-shared node starts without index.sh (gitignored)"
"$NODE" update "$i58clone" >"$WORK/i58-clone-update.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "clone: node.sh update exits 0" || fail "clone: node.sh update exits 0 (rc=$rc)"
[ -x "$i58clone/.agent/scripts/index.sh" ] \
  && pass "clone: node.sh update obtains index.sh" \
  || fail "clone: node.sh update obtains index.sh"
"$i58clone/.agent/scripts/index.sh" ensure --root "$i58clone" >"$WORK/i58-clone-ensure.out" 2>"$WORK/i58-clone-ensure.err"
rc=$?
[ "$rc" -eq 0 ] && [ -f "$i58clone/.agent/indexes/current.md" ] \
  && pass "clone: index.sh ensure succeeds once the indexer is present" \
  || fail "clone: index.sh ensure succeeds once the indexer is present (rc=$rc, err=$(cat "$WORK/i58-clone-ensure.err"))"

i58wt="$WORK/i58-worktree"
git -C "$i58src" worktree add -q -b i58-branch "$i58wt" "$i58base"
[ ! -e "$i58wt/.agent/scripts/index.sh" ] \
  && pass "worktree: a fresh worktree of a track-shared node starts without index.sh (gitignored)" \
  || fail "worktree: a fresh worktree of a track-shared node starts without index.sh (gitignored)"
"$NODE" update "$i58wt" >"$WORK/i58-wt-update.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "worktree: node.sh update exits 0" || fail "worktree: node.sh update exits 0 (rc=$rc)"
[ -x "$i58wt/.agent/scripts/index.sh" ] \
  && pass "worktree: node.sh update obtains index.sh" \
  || fail "worktree: node.sh update obtains index.sh"
"$i58wt/.agent/scripts/index.sh" ensure --root "$i58wt" >"$WORK/i58-wt-ensure.out" 2>"$WORK/i58-wt-ensure.err"
rc=$?
[ "$rc" -eq 0 ] && [ -f "$i58wt/.agent/indexes/current.md" ] \
  && pass "worktree: index.sh ensure succeeds once the indexer is present" \
  || fail "worktree: index.sh ensure succeeds once the indexer is present (rc=$rc, err=$(cat "$WORK/i58-wt-ensure.err"))"
git -C "$i58src" worktree remove -f "$i58wt" >/dev/null 2>&1 || rm -rf "$i58wt"


l59="$WORK/l59"
mkdir -p "$l59/.agent/rules/learned" "$l59/.agent/docs"
printf '# Learned rules\n\nHeader body.\n\n<!-- Format: - [YYYY-MM-DD] x. -->\n' >"$l59/.agent/rules/learned.md"
printf '# Doc\n<!-- Read when: testing -->\nBody.\n' >"$l59/.agent/docs/d.md"
l59before=$(idx_snapshot "$l59/.agent/rules")
"$IDXSH" ensure --root "$l59" >/dev/null 2>"$WORK/l59.err"
l59gen=$(sed -n 2p "$l59/.agent/indexes/current.md")
l59after=$(idx_snapshot "$l59/.agent/rules")
[ "$l59before" = "$l59after" ] \
  && pass "learned aggregate: an empty rules/learned/ directory leaves learned.md untouched, same as no directory at all" \
  || fail "learned aggregate: an empty rules/learned/ directory leaves learned.md untouched, same as no directory at all"
grep -qF "Source: .agent/rules/learned.md" "$l59/.agent/indexes/$l59gen"/rules-*.md \
  && pass "learned aggregate: with rules/learned/ empty, learned.md still renders as an ordinary source record" \
  || fail "learned aggregate: with rules/learned/ empty, learned.md still renders as an ordinary source record"

l61="$WORK/l61"
mkdir -p "$l61/.agent/rules" "$l61/.agent/docs"
printf '# Learned rules\n\nHeader body.\n\n<!-- Format: - [YYYY-MM-DD] x. -->\n\n- [2026-01-01] Legacy single-file rule.\n' >"$l61/.agent/rules/learned.md"
printf '# Doc\n<!-- Read when: testing -->\nBody.\n' >"$l61/.agent/docs/d.md"
l61learnedbefore=$(cat "$l61/.agent/rules/learned.md")
"$IDXSH" ensure --root "$l61" >/dev/null 2>"$WORK/l61.err"
l61gen=$(sed -n 2p "$l61/.agent/indexes/current.md")
grep -qF "Source: .agent/rules/learned.md" "$l61/.agent/indexes/$l61gen"/rules-*.md \
  && grep -qF -- '- [2026-01-01] Legacy single-file rule.' "$l61/.agent/indexes/$l61gen"/rules-*.md \
  && pass "learned aggregate: with no rules/learned/ directory, learned.md renders as an ordinary source record" \
  || fail "learned aggregate: with no rules/learned/ directory, learned.md renders as an ordinary source record"
[ "$(cat "$l61/.agent/rules/learned.md")" = "$l61learnedbefore" ] \
  && pass "learned aggregate: with no rules/learned/ directory, ensure never rewrites learned.md" \
  || fail "learned aggregate: with no rules/learned/ directory, ensure never rewrites learned.md"

l60="$WORK/l60"
mkdir -p "$l60/.agent/rules/learned" "$l60/.agent/docs"
printf '# Doc\n<!-- Read when: testing -->\nBody.\n' >"$l60/.agent/docs/d.md"
printf -- '- [2026-01-01] First rule. Trigger: alpha.\n' >"$l60/.agent/rules/learned/aa-first.md"
printf -- '- [2026-01-02] Second rule.\n- [2026-01-03] Third rule. Trigger: beta.\n' >"$l60/.agent/rules/learned/bb-second.md"
printf -- '- [2026-01-04] Fourth rule.\n- inline sub-bullet, not a dated rule\n' >"$l60/.agent/rules/learned/cc-third.md"
"$IDXSH" ensure --root "$l60" >/dev/null 2>"$WORK/l60.err"
l60gen=$(sed -n 2p "$l60/.agent/indexes/current.md")
l60dir="$l60/.agent/indexes/$l60gen"
l60agg="$l60/.agent/rules/learned.md"

grep -qF -- '- [2026-01-01] First rule. Trigger: alpha.' "$l60agg" \
  && grep -qF -- '- [2026-01-02] Second rule.' "$l60agg" \
  && grep -qF -- '- [2026-01-03] Third rule. Trigger: beta.' "$l60agg" \
  && grep -qF -- '- [2026-01-04] Fourth rule.' "$l60agg" \
  && grep -qF -- '- inline sub-bullet, not a dated rule' "$l60agg" \
  && pass "learned aggregate: every ^- line from every record is present, qualifiers and Trigger clauses intact" \
  || fail "learned aggregate: every ^- line from every record is present, qualifiers and Trigger clauses intact"

l60posA=$(grep -n -F -- 'First rule' "$l60agg" | head -1 | cut -d: -f1)
l60posB=$(grep -n -F -- 'Second rule' "$l60agg" | head -1 | cut -d: -f1)
l60posC=$(grep -n -F -- 'Fourth rule' "$l60agg" | head -1 | cut -d: -f1)
[ -n "$l60posA" ] && [ -n "$l60posB" ] && [ -n "$l60posC" ] \
  && [ "$l60posA" -lt "$l60posB" ] && [ "$l60posB" -lt "$l60posC" ] \
  && pass "learned aggregate: records concatenate in path-sorted order" \
  || fail "learned aggregate: records concatenate in path-sorted order"

l60rulecount=$(grep -c '^- ' "$l60agg")
[ "$l60rulecount" -eq 5 ] \
  && pass "learned aggregate: the ^- line count is the sum of every record's own rule lines, real bullets and incidental ones alike" \
  || fail "learned aggregate: the ^- line count is the sum of every record's own rule lines, real bullets and incidental ones alike ($l60rulecount)"

l60totalfirst=$(grep -hc -F -- 'First rule' "$l60dir"/*.md 2>/dev/null | awk '{s+=$1} END{print s+0}')
[ "$l60totalfirst" -eq 1 ] \
  && pass "learned aggregate: no rule body from rules/learned/ renders twice across the published pages" \
  || fail "learned aggregate: no rule body from rules/learned/ renders twice across the published pages ($l60totalfirst)"

l60aggbefore=$(cat "$l60agg")
printf -- '- [2026-01-05] Fifth rule appended.\n' >>"$l60/.agent/rules/learned/aa-first.md"
"$IDXSH" ensure --root "$l60" >/dev/null 2>"$WORK/l60.edit.err"
grep -q '^BUILT$' "$WORK/l60.edit.err" && pass "learned aggregate: editing a record rebuilds" \
  || fail "learned aggregate: editing a record rebuilds"
l60aggafter=$(cat "$l60agg")
[ "$l60aggbefore" != "$l60aggafter" ] && grep -qF -- 'Fifth rule appended.' "$l60agg" \
  && pass "learned aggregate: editing one record and re-running ensure updates the aggregate" \
  || fail "learned aggregate: editing one record and re-running ensure updates the aggregate"

l60gen2=$(sed -n 2p "$l60/.agent/indexes/current.md")
l60dir2="$l60/.agent/indexes/$l60gen2"
l60totalfirst2=$(grep -hc -F -- 'First rule' "$l60dir2"/*.md 2>/dev/null | awk '{s+=$1} END{print s+0}')
[ "$l60totalfirst2" -eq 1 ] \
  && pass "learned aggregate: no rule body from rules/learned/ renders twice across the published pages, once learned.md already exists on disk" \
  || fail "learned aggregate: no rule body from rules/learned/ renders twice across the published pages, once learned.md already exists on disk ($l60totalfirst2)"

l60hitsnap1=$(idx_snapshot "$l60/.agent/rules")
"$IDXSH" ensure --root "$l60" >/dev/null 2>"$WORK/l60.hit.err"
grep -q '^HIT$' "$WORK/l60.hit.err" && pass "learned aggregate: an unchanged tree after the edit is a warm HIT" \
  || fail "learned aggregate: an unchanged tree after the edit is a warm HIT"
l60hitsnap2=$(idx_snapshot "$l60/.agent/rules")
[ "$l60hitsnap1" = "$l60hitsnap2" ] \
  && pass "learned aggregate: a cache hit writes nothing" \
  || fail "learned aggregate: a cache hit writes nothing"

l60aggcheckbefore=$(cat "$l60agg")
printf -- '- [2026-01-06] Stale edit for check.\n' >>"$l60/.agent/rules/learned/bb-second.md"
"$IDXSH" check --root "$l60" >/dev/null 2>&1
"$IDXSH" check --root "$l60" >/dev/null 2>&1
[ "$(cat "$l60agg")" = "$l60aggcheckbefore" ] \
  && pass "learned aggregate: check writes no file under any input, even a stale record change" \
  || fail "learned aggregate: check writes no file under any input, even a stale record change"

"$IDXSH" ensure --root "$l60" >/dev/null 2>&1
l60entrybefore=$(cat "$l60/.agent/indexes/current.md")
l60aggfailbefore=$(cat "$l60agg")
printf -- '- [2026-01-07] Should never land.\n' >>"$l60/.agent/rules/learned/cc-third.md"
INDEX_FAIL_AT=before-publish "$IDXSH" ensure --root "$l60" >/dev/null 2>"$WORK/l60.fail.err"
l60failrc=$?
[ "$l60failrc" -eq 1 ] && grep -q 'FALLBACK:' "$WORK/l60.fail.err" \
  && pass "learned aggregate: an injected failure before publication is reported and exits 1" \
  || fail "learned aggregate: an injected failure before publication is reported and exits 1"
[ "$(cat "$l60/.agent/indexes/current.md")" = "$l60entrybefore" ] && [ "$(cat "$l60agg")" = "$l60aggfailbefore" ] \
  && pass "learned aggregate: a failed ensure leaves both the previous entry file and the previous aggregate exactly as they were" \
  || fail "learned aggregate: a failed ensure leaves both the previous entry file and the previous aggregate exactly as they were"
[ -z "$(find "$l60/.agent/indexes" -maxdepth 1 -name '.entry.*' 2>/dev/null)" ] \
  && [ -z "$(find "$l60/.agent/rules" -maxdepth 1 -name '.learned.*' 2>/dev/null)" ] \
  && pass "learned aggregate: a failed ensure leaves no leftover temp files" \
  || fail "learned aggregate: a failed ensure leaves no leftover temp files"

m60ctl="$WORK/m60-control"
mkdir -p "$m60ctl"
"$NODE" init --preset software-development --mode track-all --indexes generated "$m60ctl" >/dev/null 2>&1
finish_bootstrap "$m60ctl"
cat >"$m60ctl/.agent/rules/learned.md" <<'EOF'
# Learned rules

Binding rules distilled from operator corrections and failed verifications on this project, after the canonical-source check in `contract.md`. A correction that exposes a defect in the contract, docs, code, or tooling is fixed there and produces no compensating rule. Merging and compressing entries is allowed. Drop a rule when its failure mode becomes mechanically enforced. Behavioral rules stay here. Area gotchas go to the matching `.agent/docs/` file under `## Gotchas`. Authoring and curation rules: `contract.md`, Self-learning.

<!-- Format: - [YYYY-MM-DD] <imperative rule>. Trigger: <cause, optional>. -->

- [2026-01-01] Rule one about deploys.
- [2026-01-02] Rule two about tests. Trigger: a flaky suite.
- [2026-01-03] Rule three about review turnaround.
EOF
m60ctlflags=$(status_flags "$m60ctl")
m60ctlplain=$("$m60ctl/.agent/scripts/status.sh" "$m60ctl" 2>/dev/null)
m60ctlpayload=$(printf '%s\n' "$m60ctlplain" | grep '^PAYLOAD:' | grep -oE '[0-9]+' | head -1)

m60mig="$WORK/m60-migrated"
mkdir -p "$m60mig"
"$NODE" init --preset software-development --mode track-all --indexes generated "$m60mig" >/dev/null 2>&1
finish_bootstrap "$m60mig"
rm -f "$m60mig/.agent/rules/learned.md"
mkdir -p "$m60mig/.agent/rules/learned"
printf -- '- [2026-01-01] Rule one about deploys.\n' >"$m60mig/.agent/rules/learned/0001.md"
printf -- '- [2026-01-02] Rule two about tests. Trigger: a flaky suite.\n' >"$m60mig/.agent/rules/learned/0002.md"
printf -- '- [2026-01-03] Rule three about review turnaround.\n' >"$m60mig/.agent/rules/learned/0003.md"
"$m60mig/.agent/scripts/index.sh" ensure --root "$m60mig" >/dev/null 2>"$WORK/m60mig.ensure.err"

m60migstripped=$(grep -vF '<!-- Generated by index.sh from rules/learned/' "$m60mig/.agent/rules/learned.md")
m60ctlcontent=$(cat "$m60ctl/.agent/rules/learned.md")
[ "$m60migstripped" = "$m60ctlcontent" ] \
  && pass "migration: the regenerated aggregate matches the pre-migration file exactly, apart from the one generated-marker line" \
  || fail "migration: the regenerated aggregate matches the pre-migration file exactly, apart from the one generated-marker line"

m60migflags=$(status_flags "$m60mig")
m60migplain=$("$m60mig/.agent/scripts/status.sh" "$m60mig" 2>/dev/null)
m60migpayload=$(printf '%s\n' "$m60migplain" | grep '^PAYLOAD:' | grep -oE '[0-9]+' | head -1)
m60markerbytes=$(printf '%s\n' '<!-- Generated by index.sh from rules/learned/*.md — hand edits here are lost on the next ensure. -->' | wc -c | tr -d '[:space:]')

printf '%s\n' "$m60migflags" | grep -qF 'REPAIR: rules/learned.md missing/empty' \
  && fail "migration: an unmodified status.sh emits no REPAIR: rules/learned.md missing/empty against the migrated fixture" \
  || pass "migration: an unmodified status.sh emits no REPAIR: rules/learned.md missing/empty against the migrated fixture"
[ "$m60ctlflags" = "$m60migflags" ] \
  && pass "migration: status.sh reaches the same REPAIR/GROOM verdict pre- and post-migration" \
  || fail "migration: status.sh reaches the same REPAIR/GROOM verdict pre- and post-migration ($m60migflags)"
m60ctlfiles=$(printf '%s\n' "$m60ctlplain" | grep '^PAYLOAD:' | grep -oE '(purpose|memory) [0-9]+' | tr '\n' ' ')
m60migfiles=$(printf '%s\n' "$m60migplain" | grep '^PAYLOAD:' | grep -oE '(purpose|memory) [0-9]+' | tr '\n' ' ')
[ -n "$m60ctlpayload" ] && [ -n "$m60migpayload" ] && [ -n "$m60ctlfiles" ] \
  && [ "$m60ctlfiles" = "$m60migfiles" ] \
  && pass "migration: status.sh bills the identical files pre- and post-migration, since rule bodies no longer ride --load" \
  || fail "migration: status.sh bills the identical files pre- and post-migration, since rule bodies no longer ride --load (ctl=$m60ctlfiles mig=$m60migfiles)"

m60ctllearnedbytes=$(wc -c <"$m60ctl/.agent/rules/learned.md" | tr -d '[:space:]')
m60miglearnedbytes=$(wc -c <"$m60mig/.agent/rules/learned.md" | tr -d '[:space:]')
[ "$((m60miglearnedbytes - m60ctllearnedbytes))" -eq "$m60markerbytes" ] \
  && pass "migration: the regenerated rules/learned.md exceeds the control by exactly the marker line's own bytes" \
  || fail "migration: the regenerated rules/learned.md exceeds the control by exactly the marker line's own bytes (ctl=$m60ctllearnedbytes mig=$m60miglearnedbytes marker=$m60markerbytes)"

printf '\n--- status.sh output against the migrated fixture (%s) ---\n' "$m60mig"
"$m60mig/.agent/scripts/status.sh" "$m60mig"
printf -- '--- status.sh --load against the migrated fixture ---\n'
"$m60mig/.agent/scripts/status.sh" --load "$m60mig" 2>/dev/null
printf -- '--- end status.sh output ---\n\n'


r61build() {
  r61_dir="$1"
  mkdir -p "$r61_dir"
  make_v6_fixture "$r61_dir"
  r61_modeline=$(grep -n '^  mode:' "$r61_dir/.agent/purpose.md" | head -1 | cut -d: -f1)
  awk -v ln="$r61_modeline" \
    'NR==ln { print; print "  indexes: generated        # manual | generated"; next } { print }' \
    "$r61_dir/.agent/purpose.md" >"$r61_dir/.agent/purpose.md.tmp"
  mv "$r61_dir/.agent/purpose.md.tmp" "$r61_dir/.agent/purpose.md"

  cat >"$r61_dir/.agent/rules/learned.md" <<'EOF'
# Learned rules

Binding rules distilled from operator corrections and failed verifications on this project, after the canonical-source check in `contract.md`. A correction that exposes a defect in the contract, docs, code, or tooling is fixed there and produces no compensating rule. Merging and compressing entries is allowed. Drop a rule when its failure mode becomes mechanically enforced. Behavioral rules stay here. Area gotchas go to the matching `.agent/docs/` file under `## Gotchas`. Authoring and curation rules: `contract.md`, Self-learning.

<!-- Format: - [YYYY-MM-DD] <imperative rule>. Trigger: <cause, optional>. -->
- [2026-01-01] First rule, flat. Trigger: something.
- [2026-01-02] Second rule with a nested sub-bullet. Trigger: x.
  - qualifier one
  - qualifier two
- [2026-01-03] Third rule, multi paragraph.

  Continuation paragraph here.
- [2026-01-04] Fourth rule, flat, last one.
EOF

  mkdir -p "$r61_dir/.agent/memory"
  cat >"$r61_dir/.agent/memory/staging-reset.md" <<'EOF'
---
date: 2026-01-01
scope: project
type: fact
---

The staging database resets nightly at 02:00 UTC.
EOF
  cat >"$r61_dir/.agent/memory.md" <<'EOF'
# Memory
<!-- Index only, one line per fact file, newest last. Reorder by relevance only when grooming. Format: - [Title](memory/slug.md) — hook. No prose, no facts inline: a fact that lives only as a line here and not as its own file under memory/ is not recorded. Delete the line when its file is deleted. Preferred writer: .agent/scripts/memory.sh new (scaffolds the fact file and its index line together). This contract covers memory/ too, so fact files carry no header of their own. Each holds one durable fact under date, scope, and type frontmatter. Keep a fact only if work in this node changes when it is true: one carried in from another repo or a migration earns its place again or is dropped. Before writing, search purpose, rules, routed docs, source, and existing facts. If one already states it, update that source or its routing, write no fact, and say which source states it. A defect fixed in the harness or a tool creates no compensating fact. Two halves that would be superseded at different times are two files. Supersede in place with .agent/scripts/memory.sh supersede --slug <slug> --fact "…", which rewrites the fact, restamps the date, and keeps the filename. No dated narratives, no command output, no history. As small as the fact allows. Stable knowledge about how the system works goes to docs/ without a pointer fact; architecture.md already routes it. type: reference points outward at a URL, dashboard, ticket, or spec the node does not own: checked for reachability, not superseded like a fact. -->

- [Staging reset](memory/staging-reset.md) — when the staging database resets.
EOF

  mkdir -p "$r61_dir/.agent/docs/area"
  cat >"$r61_dir/.agent/docs/architecture.md" <<'EOF'
# Architecture

### `hooked.md`
- **Read when:** already hooked, never touched.

### `unhooked.md`
- **Read when:** doing unhooked work.

### `area/sub.md`
- **Read when:** doing area sub work.

### `dup.md`
- **Read when:** first dup entry.

### `dup.md`
- **Read when:** second dup entry.

### `badtable.md`
Hand-edited row with no bold marker: whatever hook text.
EOF
  cat >"$r61_dir/.agent/docs/hooked.md" <<'EOF'
<!-- Read when: already hooked, never touched. -->
# Hooked

Body.
EOF
  cat >"$r61_dir/.agent/docs/unhooked.md" <<'EOF'
# Unhooked

Body.
EOF
  cat >"$r61_dir/.agent/docs/area/sub.md" <<'EOF'
# Sub

Body.
EOF
  cat >"$r61_dir/.agent/docs/dup.md" <<'EOF'
# Dup

Body.
EOF
  cat >"$r61_dir/.agent/docs/badtable.md" <<'EOF'
# Badtable

Body.
EOF
  cat >"$r61_dir/.agent/docs/noentry.md" <<'EOF'
# Noentry

Body.
EOF
}

r61mode() {
  r61m_dir="$1"
  r61m_mode="$2"
  r61build "$r61m_dir"
  if [ "$r61m_mode" != ignore-all ]; then
    sed "s/^  mode: ignore-all/  mode: $r61m_mode/" "$r61m_dir/.agent/purpose.md" \
      >"$r61m_dir/.agent/purpose.md.tmp"
    mv "$r61m_dir/.agent/purpose.md.tmp" "$r61m_dir/.agent/purpose.md"
  fi
}

r61_bullets_present() {
  rbp_file="$1"
  for rbp_marker in 'First rule, flat' 'nested sub-bullet' 'multi paragraph' 'Fourth rule, flat'; do
    grep -qF "$rbp_marker" "$rbp_file" || return 1
  done
  return 0
}

r61dir="$WORK/r61-migration"
r61build "$r61dir"
cp "$r61dir/.agent/docs/architecture.md" "$WORK/r61-arch-before.md"
cp "$r61dir/.agent/rules/learned.md" "$WORK/r61-learned-before.md"
cp "$r61dir/.agent/memory.md" "$WORK/r61-memory-before.md"
cp "$r61dir/.agent/memory/staging-reset.md" "$WORK/r61-memory-fact-before.md"
cp "$r61dir/.agent/docs/hooked.md" "$WORK/r61-hooked-before.md"
cp "$r61dir/.agent/docs/dup.md" "$WORK/r61-dup-before.md"
cp "$r61dir/.agent/docs/badtable.md" "$WORK/r61-badtable-before.md"
cp "$r61dir/.agent/docs/noentry.md" "$WORK/r61-noentry-before.md"

"$NODE" update "$r61dir" >"$WORK/r61-update.out" 2>&1
r61rc=$?
[ "$r61rc" -eq 0 ] && pass "generated-mode update: exits 0" || fail "generated-mode update: exits 0 (rc=$r61rc)"

r61records=$(find "$r61dir/.agent/rules/learned" -maxdepth 1 -name '*.md' 2>/dev/null | sort)
r61count=$(printf '%s\n' "$r61records" | grep -c .)
[ "$r61count" -eq 4 ] && pass "rule extraction: four bullets produce four records" || fail "rule extraction: four bullets produce four records (found $r61count)"

r61badnames=0
for r61f in $r61records; do
  r61base=$(basename "$r61f" .md)
  case "$r61base" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
  *) r61badnames=$((r61badnames + 1)) ;;
  esac
done
[ "$r61badnames" -eq 0 ] \
  && pass "rule extraction: every record filename is 12 lowercase hex characters" \
  || fail "rule extraction: every record filename is 12 lowercase hex characters ($r61badnames bad)"

r61uniq=$(printf '%s\n' "$r61records" | xargs -n1 basename | sort -u | wc -l | tr -d '[:space:]')
[ "$r61uniq" -eq 4 ] && pass "rule extraction: no two records share an identity" || fail "rule extraction: no two records share an identity"

r61flat1=$(grep -lF 'First rule, flat' $r61records)
r61nested=$(grep -lF 'nested sub-bullet' $r61records)
r61multi=$(grep -lF 'multi paragraph' $r61records)
r61flat2=$(grep -lF 'Fourth rule, flat' $r61records)

[ "$(cat "$r61flat1")" = '- [2026-01-01] First rule, flat. Trigger: something.' ] \
  && pass "rule extraction: a flat bullet's record is verbatim, nothing added" \
  || fail "rule extraction: a flat bullet's record is verbatim, nothing added"
[ "$(cat "$r61flat2")" = '- [2026-01-04] Fourth rule, flat, last one.' ] \
  && pass "rule extraction: the last flat bullet's record runs to end of file, verbatim" \
  || fail "rule extraction: the last flat bullet's record runs to end of file, verbatim"

r61nested_expect=$(printf '%s\n' \
  '- [2026-01-02] Second rule with a nested sub-bullet. Trigger: x.' \
  '  - qualifier one' \
  '  - qualifier two')
[ "$(cat "$r61nested")" = "$r61nested_expect" ] \
  && pass "rule extraction: nested sub-bullets stay inside the record that opened them" \
  || fail "rule extraction: nested sub-bullets stay inside the record that opened them"

r61multi_expect=$(printf '%s\n' \
  '- [2026-01-03] Third rule, multi paragraph.' \
  '' \
  '  Continuation paragraph here.')
[ "$(cat "$r61multi")" = "$r61multi_expect" ] \
  && pass "rule extraction: a multi-paragraph bullet keeps its continuation paragraph" \
  || fail "rule extraction: a multi-paragraph bullet keeps its continuation paragraph"

r61inv="$r61dir/.agent/migration-inventory.md"
[ -f "$r61inv" ] && pass "migration inventory: .agent/migration-inventory.md is written" || fail "migration inventory: .agent/migration-inventory.md is written"

r61id1=$(basename "$r61flat1" .md)
r61id2=$(basename "$r61nested" .md)
r61id3=$(basename "$r61multi" .md)
r61id4=$(basename "$r61flat2" .md)
grep -qF "rules/learned/$r61id1.md | id=$r61id1 | migrated" "$r61inv" \
  && pass "migration inventory: flat rule 1 lists migrated with its real identity" \
  || fail "migration inventory: flat rule 1 lists migrated with its real identity"
grep -qF "rules/learned/$r61id2.md | id=$r61id2 | semantic-review-pending" "$r61inv" \
  && pass "migration inventory: the nested-sub-bullet rule lists semantic-review-pending" \
  || fail "migration inventory: the nested-sub-bullet rule lists semantic-review-pending"
grep -qF "rules/learned/$r61id3.md | id=$r61id3 | semantic-review-pending" "$r61inv" \
  && pass "migration inventory: the multi-paragraph rule lists semantic-review-pending" \
  || fail "migration inventory: the multi-paragraph rule lists semantic-review-pending"
grep -qF "rules/learned/$r61id4.md | id=$r61id4 | migrated" "$r61inv" \
  && pass "migration inventory: flat rule 4 lists migrated with its real identity" \
  || fail "migration inventory: flat rule 4 lists migrated with its real identity"

r61_bullets_present "$r61dir/.agent/rules/learned.md" \
  && pass "migration: the regenerated rules/learned.md reproduces every original bullet" \
  || fail "migration: the regenerated rules/learned.md reproduces every original bullet"

diff -q "$WORK/r61-arch-before.md" "$r61dir/.agent/docs/architecture.md" >/dev/null 2>&1 \
  && pass "migration: architecture.md is byte-identical before and after" \
  || fail "migration: architecture.md is byte-identical before and after"

diff -q "$WORK/r61-memory-before.md" "$r61dir/.agent/memory.md" >/dev/null 2>&1 \
  && pass "migration: memory.md is byte-identical before and after" \
  || fail "migration: memory.md is byte-identical before and after"

diff -q "$WORK/r61-memory-fact-before.md" "$r61dir/.agent/memory/staging-reset.md" >/dev/null 2>&1 \
  && pass "migration: a file under memory/ is byte-identical before and after" \
  || fail "migration: a file under memory/ is byte-identical before and after"

diff -q "$WORK/r61-hooked-before.md" "$r61dir/.agent/docs/hooked.md" >/dev/null 2>&1 \
  && pass "hook backfill: a doc that already carries a hook is left untouched" \
  || fail "hook backfill: a doc that already carries a hook is left untouched"

[ "$(sed -n 1p "$r61dir/.agent/docs/unhooked.md")" = '<!-- Read when: doing unhooked work. -->' ] \
  && pass "hook backfill: a missing hook with a matching architecture.md entry is backfilled" \
  || fail "hook backfill: a missing hook with a matching architecture.md entry is backfilled"
[ "$(tail -n +2 "$r61dir/.agent/docs/unhooked.md")" = "$(printf '# Unhooked\n\nBody.')" ] \
  && pass "hook backfill: backfilling a hook changes nothing else in the doc" \
  || fail "hook backfill: backfilling a hook changes nothing else in the doc"

[ "$(sed -n 1p "$r61dir/.agent/docs/area/sub.md")" = '<!-- Read when: doing area sub work. -->' ] \
  && pass "hook backfill: a sub-doc under docs/<area>/ resolves its entry key as area/sub.md" \
  || fail "hook backfill: a sub-doc under docs/<area>/ resolves its entry key as area/sub.md"

diff -q "$WORK/r61-dup-before.md" "$r61dir/.agent/docs/dup.md" >/dev/null 2>&1 \
  && pass "hook backfill: a duplicate architecture.md entry key is left untouched (no winner picked)" \
  || fail "hook backfill: a duplicate architecture.md entry key is left untouched (no winner picked)"

diff -q "$WORK/r61-badtable-before.md" "$r61dir/.agent/docs/badtable.md" >/dev/null 2>&1 \
  && pass "hook backfill: a hand-edited entry with no bold Read-when line is left untouched" \
  || fail "hook backfill: a hand-edited entry with no bold Read-when line is left untouched"

diff -q "$WORK/r61-noentry-before.md" "$r61dir/.agent/docs/noentry.md" >/dev/null 2>&1 \
  && pass "hook backfill: a doc with no architecture.md entry at all is left untouched" \
  || fail "hook backfill: a doc with no architecture.md entry at all is left untouched"

grep -qF 'doc docs/hooked.md -> docs/hooked.md | id=hooked.md | migrated' "$r61inv" \
  && pass "migration inventory: the already-hooked doc lists migrated" \
  || fail "migration inventory: the already-hooked doc lists migrated"
grep -qF 'doc docs/unhooked.md -> docs/unhooked.md | id=unhooked.md | migrated' "$r61inv" \
  && pass "migration inventory: the backfilled doc lists migrated" \
  || fail "migration inventory: the backfilled doc lists migrated"
grep -qF 'doc docs/area/sub.md -> docs/area/sub.md | id=area/sub.md | migrated' "$r61inv" \
  && pass "migration inventory: the backfilled sub-doc lists migrated" \
  || fail "migration inventory: the backfilled sub-doc lists migrated"
grep -qF 'doc docs/dup.md -> docs/dup.md | id=dup.md | hook-missing' "$r61inv" \
  && pass "migration inventory: the duplicate-key doc lists hook-missing" \
  || fail "migration inventory: the duplicate-key doc lists hook-missing"
grep -qF 'doc docs/badtable.md -> docs/badtable.md | id=badtable.md | hook-missing' "$r61inv" \
  && pass "migration inventory: the hand-edited unparseable doc lists hook-missing" \
  || fail "migration inventory: the hand-edited unparseable doc lists hook-missing"
grep -qF 'doc docs/noentry.md -> docs/noentry.md | id=noentry.md | hook-missing' "$r61inv" \
  && pass "migration inventory: the doc with no architecture.md entry lists hook-missing" \
  || fail "migration inventory: the doc with no architecture.md entry lists hook-missing"

grep -qF 'docs/architecture.md' "$r61inv" \
  && fail "migration inventory: architecture.md itself is never listed as a walked item" \
  || pass "migration inventory: architecture.md itself is never listed as a walked item"

r61snapshot() { find "$1/.agent" -type f | sort | xargs shasum 2>/dev/null | sort; }
r61before2=$(r61snapshot "$r61dir")
"$NODE" update "$r61dir" >"$WORK/r61-update2.out" 2>&1
r61rc2=$?
r61after2=$(r61snapshot "$r61dir")
[ "$r61rc2" -eq 0 ] && pass "re-run over an already-populated rules/learned/: exits 0" || fail "re-run over an already-populated rules/learned/: exits 0 (rc=$r61rc2)"
[ "$r61before2" = "$r61after2" ] \
  && pass "re-run over an already-populated rules/learned/: mints no identity, rewrites no record, changes no file" \
  || fail "re-run over an already-populated rules/learned/: mints no identity, rewrites no record, changes no file"

r61zero="$WORK/r61-zero"
mkdir -p "$r61zero"
make_v6_fixture "$r61zero"
r61zero_modeline=$(grep -n '^  mode:' "$r61zero/.agent/purpose.md" | head -1 | cut -d: -f1)
awk -v ln="$r61zero_modeline" \
  'NR==ln { print; print "  indexes: generated        # manual | generated"; next } { print }' \
  "$r61zero/.agent/purpose.md" >"$r61zero/.agent/purpose.md.tmp"
mv "$r61zero/.agent/purpose.md.tmp" "$r61zero/.agent/purpose.md"
cat >"$r61zero/.agent/rules/learned.md" <<'EOF'
# Learned rules

Prose paragraph, no rules recorded yet.

<!-- Format: - [YYYY-MM-DD] <imperative rule>. Trigger: <cause, optional>. -->
EOF
"$NODE" update "$r61zero" >"$WORK/r61-zero-update.out" 2>&1
r61zerorc=$?
[ "$r61zerorc" -eq 0 ] && pass "zero-bullet rules/learned.md: update exits 0" || fail "zero-bullet rules/learned.md: update exits 0 (rc=$r61zerorc)"
r61zerocount=$(find "$r61zero/.agent/rules/learned" -maxdepth 1 -name '*.md' 2>/dev/null | grep -c .)
[ "$r61zerocount" -eq 0 ] && pass "zero-bullet rules/learned.md: no records are created" || fail "zero-bullet rules/learned.md: no records are created (found $r61zerocount)"
grep -q '^- rule ' "$r61zero/.agent/migration-inventory.md" \
  && fail "zero-bullet rules/learned.md: the inventory carries no rule line" \
  || pass "zero-bullet rules/learned.md: the inventory carries no rule line"

sed -n '1,/^case "\$cmd" in/p' "$NODE" | sed '$d' >"$WORK/node-funcs.sh"

r61mintdir="$WORK/r61-mint-retry"
mkdir -p "$r61mintdir"
r61seed=777
r61first=$(bash -c "RANDOM=$r61seed; printf '%04x%04x%04x' \"\$RANDOM\" \"\$RANDOM\" \"\$RANDOM\"")
: >"$r61mintdir/$r61first.md"
r61mintout=$(bash -c '
  RANDOM='"$r61seed"'
  source "'"$WORK"'/node-funcs.sh"
  : >"'"$r61mintdir"'/.minted"
  if mint_learned_id "'"$r61mintdir"'" "'"$r61mintdir"'/.minted"; then
    printf "MINTED:%s" "$mint_id_result"
  else
    printf "ABORTED"
  fi
')
case "$r61mintout" in
MINTED:*)
  r61second=${r61mintout#MINTED:}
  [ "$r61second" != "$r61first" ] && [ -e "$r61mintdir/$r61second.md" ] \
    && pass "identity minting: a collision on the first candidate is rejected and retried to a fresh id" \
    || fail "identity minting: a collision on the first candidate is rejected and retried to a fresh id ($r61mintout)"
  ;;
*) fail "identity minting: a collision on the first candidate is rejected and retried to a fresh id ($r61mintout)" ;;
esac
[ -e "$r61mintdir/$r61first.md" ] \
  && pass "identity minting: the file that caused the collision is left exactly as it was" \
  || fail "identity minting: the file that caused the collision is left exactly as it was"

r61abortdir="$WORK/r61-mint-abort"
mkdir -p "$r61abortdir"
r61abortseed=999
bash -c '
  RANDOM='"$r61abortseed"'
  i=0
  while [ "$i" -lt 100 ]; do
    printf -v id "%04x%04x%04x" "$RANDOM" "$RANDOM" "$RANDOM"
    : >"'"$r61abortdir"'/$id.md"
    i=$((i + 1))
  done
'
r61beforeabort=$(find "$r61abortdir" -maxdepth 1 -name '*.md' | wc -l | tr -d '[:space:]')
r61abortout=$(bash -c '
  RANDOM='"$r61abortseed"'
  source "'"$WORK"'/node-funcs.sh"
  : >"'"$r61abortdir"'/.minted"
  if mint_learned_id "'"$r61abortdir"'" "'"$r61abortdir"'/.minted"; then
    printf "MINTED:%s" "$mint_id_result"
  else
    printf "ABORTED"
  fi
')
[ "$r61abortout" = "ABORTED" ] \
  && pass "identity minting: 100 consecutive rejections abort minting with no identity" \
  || fail "identity minting: 100 consecutive rejections abort minting with no identity ($r61abortout)"
r61afterabort=$(find "$r61abortdir" -maxdepth 1 -name '*.md' | wc -l | tr -d '[:space:]')
[ "$r61beforeabort" -eq "$r61afterabort" ] \
  && pass "identity minting: an aborted mint creates no additional record file" \
  || fail "identity minting: an aborted mint creates no additional record file"

r61ntdir="$WORK/r61-no-trailing-newline"
mkdir -p "$r61ntdir"
make_v6_fixture "$r61ntdir"
r61nt_modeline=$(grep -n '^  mode:' "$r61ntdir/.agent/purpose.md" | head -1 | cut -d: -f1)
awk -v ln="$r61nt_modeline" \
  'NR==ln { print; print "  indexes: generated        # manual | generated"; next } { print }' \
  "$r61ntdir/.agent/purpose.md" >"$r61ntdir/.agent/purpose.md.tmp"
mv "$r61ntdir/.agent/purpose.md.tmp" "$r61ntdir/.agent/purpose.md"
printf '%s\n' \
  '# Learned rules' \
  '' \
  '<!-- Format: - [YYYY-MM-DD] <imperative rule>. Trigger: <cause, optional>. -->' \
  '- [2026-01-01] First rule, flat.' \
  '- [2026-01-02] Last rule spans two lines,' >"$r61ntdir/.agent/rules/learned.md"
printf '  and this second line has NO trailing newline.' >>"$r61ntdir/.agent/rules/learned.md"

"$NODE" update "$r61ntdir" >"$WORK/r61-nt-update.out" 2>&1
r61ntrc=$?
[ "$r61ntrc" -eq 0 ] && pass "no-trailing-newline rules/learned.md: update exits 0" || fail "no-trailing-newline rules/learned.md: update exits 0 (rc=$r61ntrc)"

r61ntrecords=$(find "$r61ntdir/.agent/rules/learned" -maxdepth 1 -name '*.md' 2>/dev/null | sort)
r61ntcount=$(printf '%s\n' "$r61ntrecords" | grep -c .)
[ "$r61ntcount" -eq 2 ] && pass "no-trailing-newline rules/learned.md: two bullets produce two records" || fail "no-trailing-newline rules/learned.md: two bullets produce two records (found $r61ntcount)"

r61ntlast=$(grep -lF 'NO trailing newline' $r61ntrecords)
r61nt_expect=$(printf '%s\n' \
  '- [2026-01-02] Last rule spans two lines,' \
  '  and this second line has NO trailing newline.')
[ "$(cat "$r61ntlast")" = "$r61nt_expect" ] \
  && pass "rule extraction: a rules/learned.md with no trailing newline still captures the last bullet's final line verbatim" \
  || fail "rule extraction: a rules/learned.md with no trailing newline still captures the last bullet's final line verbatim"

b1="$WORK/mig-boundary1"
mkdir -p "$b1"
r61mode "$b1" track-shared
cp -R "$b1/.agent" "$b1/.agent.backup-v6"
printf 'pre-existing backup marker\n' >"$b1/.agent.backup-v6/.marker"
awk '/^  version: 6$/ { print; print "  migration_target: \"6.3\""; next } { print }' \
  "$b1/.agent/purpose.md" >"$b1/.agent/purpose.md.tmp"
mv "$b1/.agent/purpose.md.tmp" "$b1/.agent/purpose.md"
"$NODE" update "$b1" >"$WORK/b1-update.out" 2>&1
b1rc=$?
[ "$b1rc" -eq 0 ] && pass "boundary 1: resume before anything is staged exits 0" || fail "boundary 1: resume before anything is staged exits 0 (rc=$b1rc)"
grep -qF "backup path already exists" "$WORK/b1-update.out" \
  && fail "boundary 1: resume does not abort on its own backup" \
  || pass "boundary 1: resume does not abort on its own backup"
[ -f "$b1/.agent.backup-v6/.marker" ] \
  && pass "boundary 1: the pre-existing backup is not re-copied" \
  || fail "boundary 1: the pre-existing backup is not re-copied"
b1count=$(find "$b1/.agent/rules/learned" -maxdepth 1 -name '*.md' 2>/dev/null | grep -c .)
[ "$b1count" -eq 4 ] \
  && pass "boundary 1: resume completes a full migration (four records)" \
  || fail "boundary 1: resume completes a full migration (four records) (found $b1count)"
b1gi1=$(grep -cxF '.agent/indexes/' "$b1/.gitignore" 2>/dev/null)
b1gi2=$(grep -cxF '.agent/rules/learned.md' "$b1/.gitignore" 2>/dev/null)
[ "$b1gi1" -eq 1 ] && [ "$b1gi2" -eq 1 ] \
  && pass "boundary 1: resume writes both generated-mode gitignore lines exactly once" \
  || fail "boundary 1: resume writes both generated-mode gitignore lines exactly once"
r61_bullets_present "$b1/.agent/rules/learned.md" \
  && pass "boundary 1: the regenerated rules/learned.md reproduces every original bullet" \
  || fail "boundary 1: the regenerated rules/learned.md reproduces every original bullet"

b2="$WORK/mig-boundary2"
mkdir -p "$b2"
r61mode "$b2" track-shared
cp -R "$b2/.agent" "$b2/.agent.backup-v6"
awk '/^  version: 6$/ { print; print "  migration_target: \"6.3\""; next } { print }' \
  "$b2/.agent/purpose.md" >"$b2/.agent/purpose.md.tmp"
mv "$b2/.agent/purpose.md.tmp" "$b2/.agent/purpose.md"

b2staging="$b2/.agent/.learned-staging"
mkdir -p "$b2staging"
b2id1=$(bash -c 'RANDOM=6101; printf "%04x%04x%04x" "$RANDOM" "$RANDOM" "$RANDOM"')
b2id2=$(bash -c 'RANDOM=6102; printf "%04x%04x%04x" "$RANDOM" "$RANDOM" "$RANDOM"')
b2id3=$(bash -c 'RANDOM=6103; printf "%04x%04x%04x" "$RANDOM" "$RANDOM" "$RANDOM"')
printf -- '- [2026-01-01] First rule, flat. Trigger: something.\n' >"$b2staging/$b2id1.md"
printf '%s\n' \
  '- [2026-01-02] Second rule with a nested sub-bullet. Trigger: x.' \
  '  - qualifier one' \
  '  - qualifier two' >"$b2staging/$b2id2.md"
: >"$b2staging/$b2id3.md"
b2stagedids="$b2id1 $b2id2 $b2id3"

"$NODE" update "$b2" >"$WORK/b2-update.out" 2>&1
b2rc=$?
[ "$b2rc" -eq 0 ] && pass "boundary 2: resume after partial staging exits 0" || fail "boundary 2: resume after partial staging exits 0 (rc=$b2rc)"
[ ! -e "$b2staging" ] \
  && pass "boundary 2: the staging directory is gone after resume" \
  || fail "boundary 2: the staging directory is gone after resume"
b2count=$(find "$b2/.agent/rules/learned" -maxdepth 1 -name '*.md' 2>/dev/null | grep -c .)
[ "$b2count" -eq 4 ] \
  && pass "boundary 2: resume records exactly the four original bullets" \
  || fail "boundary 2: resume records exactly the four original bullets (found $b2count)"
r61_bullets_present "$b2/.agent/rules/learned.md" \
  && pass "boundary 2: every original bullet is present in the regenerated aggregate" \
  || fail "boundary 2: every original bullet is present in the regenerated aggregate"
b2leak=0
[ -e "$b2staging" ] && b2leak=1
for b2id in $b2stagedids; do
  [ -e "$b2/.agent/rules/learned/$b2id.md" ] && b2leak=1
  grep -rlF "$b2id" "$b2/.agent" >/dev/null 2>&1 && b2leak=1
done
[ "$b2leak" -eq 0 ] \
  && pass "boundary 2: none of the discarded attempt's identities, the zero-byte one included, ever appears under .agent/" \
  || fail "boundary 2: none of the discarded attempt's identities, the zero-byte one included, ever appears under .agent/"

b3="$WORK/mig-boundary3"
mkdir -p "$b3"
r61mode "$b3" track-shared
git -C "$b3" init -q
git -C "$b3" config user.name Tester
git -C "$b3" config user.email tester@example.invalid
git -C "$b3" add .agent
git -C "$b3" commit -qm initial

cp -R "$b3/.agent" "$b3/.agent.backup-v6"
grep '^- ' "$b3/.agent/rules/learned.md" >"$b3/.agent/.learned-bullets-before"
awk '/^  version: 6$/ { print; print "  migration_target: \"6.3\""; next } { print }' \
  "$b3/.agent/purpose.md" >"$b3/.agent/purpose.md.tmp"
mv "$b3/.agent/purpose.md.tmp" "$b3/.agent/purpose.md"

mkdir -p "$b3/.agent/rules/learned"
b3id1=$(bash -c 'RANDOM=6201; printf "%04x%04x%04x" "$RANDOM" "$RANDOM" "$RANDOM"')
b3id2=$(bash -c 'RANDOM=6202; printf "%04x%04x%04x" "$RANDOM" "$RANDOM" "$RANDOM"')
b3id3=$(bash -c 'RANDOM=6203; printf "%04x%04x%04x" "$RANDOM" "$RANDOM" "$RANDOM"')
b3id4=$(bash -c 'RANDOM=6204; printf "%04x%04x%04x" "$RANDOM" "$RANDOM" "$RANDOM"')
printf -- '- [2026-01-01] First rule, flat. Trigger: something.\n' >"$b3/.agent/rules/learned/$b3id1.md"
printf '%s\n' \
  '- [2026-01-02] Second rule with a nested sub-bullet. Trigger: x.' \
  '  - qualifier one' \
  '  - qualifier two' >"$b3/.agent/rules/learned/$b3id2.md"
printf '%s\n' \
  '- [2026-01-03] Third rule, multi paragraph.' \
  '' \
  '  Continuation paragraph here.' >"$b3/.agent/rules/learned/$b3id3.md"
printf -- '- [2026-01-04] Fourth rule, flat, last one.\n' >"$b3/.agent/rules/learned/$b3id4.md"

"$NODE" update "$b3" >"$WORK/b3-update.out" 2>&1
b3rc=$?
[ "$b3rc" -eq 0 ] && pass "boundary 3: resume after the rename, before ensure, exits 0" || fail "boundary 3: resume after the rename, before ensure, exits 0 (rc=$b3rc)"
b3gi1=$(grep -cxF '.agent/indexes/' "$b3/.gitignore" 2>/dev/null)
b3gi2=$(grep -cxF '.agent/rules/learned.md' "$b3/.gitignore" 2>/dev/null)
[ "$b3gi1" -eq 1 ] && [ "$b3gi2" -eq 1 ] \
  && pass "boundary 3: resume writes both generated-mode gitignore lines exactly once" \
  || fail "boundary 3: resume writes both generated-mode gitignore lines exactly once"
r61_bullets_present "$b3/.agent/rules/learned.md" \
  && pass "boundary 3: resume regenerates the aggregate and reproduces every original bullet" \
  || fail "boundary 3: resume regenerates the aggregate and reproduces every original bullet"
git -C "$b3" ls-files --error-unmatch -- .agent/rules/learned.md >/dev/null 2>&1 \
  && fail "boundary 3: resume untracks rules/learned.md" \
  || pass "boundary 3: resume untracks rules/learned.md"
[ ! -e "$b3/.agent/.learned-bullets-before" ] \
  && pass "boundary 3: the resume snapshot is removed once the untrack completes" \
  || fail "boundary 3: the resume snapshot is removed once the untrack completes"

b4="$WORK/mig-boundary4"
mkdir -p "$b4"
r61mode "$b4" track-shared
git -C "$b4" init -q
git -C "$b4" config user.name Tester
git -C "$b4" config user.email tester@example.invalid
git -C "$b4" add .agent
git -C "$b4" commit -qm initial

cp -R "$b4/.agent" "$b4/.agent.backup-v6"
grep '^- ' "$b4/.agent/rules/learned.md" >"$b4/.agent/.learned-bullets-before"
awk '/^  version: 6$/ { print; print "  migration_target: \"6.3\""; next } { print }' \
  "$b4/.agent/purpose.md" >"$b4/.agent/purpose.md.tmp"
mv "$b4/.agent/purpose.md.tmp" "$b4/.agent/purpose.md"

mkdir -p "$b4/.agent/rules/learned"
b4id1=$(bash -c 'RANDOM=6301; printf "%04x%04x%04x" "$RANDOM" "$RANDOM" "$RANDOM"')
b4id2=$(bash -c 'RANDOM=6302; printf "%04x%04x%04x" "$RANDOM" "$RANDOM" "$RANDOM"')
b4id3=$(bash -c 'RANDOM=6303; printf "%04x%04x%04x" "$RANDOM" "$RANDOM" "$RANDOM"')
b4id4=$(bash -c 'RANDOM=6304; printf "%04x%04x%04x" "$RANDOM" "$RANDOM" "$RANDOM"')
printf -- '- [2026-01-01] First rule, flat. Trigger: something.\n' >"$b4/.agent/rules/learned/$b4id1.md"
printf '%s\n' \
  '- [2026-01-02] Second rule with a nested sub-bullet. Trigger: x.' \
  '  - qualifier one' \
  '  - qualifier two' >"$b4/.agent/rules/learned/$b4id2.md"
printf '%s\n' \
  '- [2026-01-03] Third rule, multi paragraph.' \
  '' \
  '  Continuation paragraph here.' >"$b4/.agent/rules/learned/$b4id3.md"
printf -- '- [2026-01-04] Fourth rule, flat, last one.\n' >"$b4/.agent/rules/learned/$b4id4.md"

"$IDXSH" ensure --root "$b4" >/dev/null 2>&1
printf '.agent/indexes/\n' >"$b4/.gitignore"
printf '.agent/rules/learned.md\n' >>"$b4/.gitignore"

"$NODE" update "$b4" >"$WORK/b4-update.out" 2>&1
b4rc=$?
[ "$b4rc" -eq 0 ] && pass "boundary 4: resume after the aggregate check, before untrack, exits 0" || fail "boundary 4: resume after the aggregate check, before untrack, exits 0 (rc=$b4rc)"
b4gi1=$(grep -cxF '.agent/indexes/' "$b4/.gitignore" 2>/dev/null)
b4gi2=$(grep -cxF '.agent/rules/learned.md' "$b4/.gitignore" 2>/dev/null)
[ "$b4gi1" -eq 1 ] && [ "$b4gi2" -eq 1 ] \
  && pass "boundary 4: resume adds no duplicate gitignore line" \
  || fail "boundary 4: resume adds no duplicate gitignore line"
git -C "$b4" ls-files --error-unmatch -- .agent/rules/learned.md >/dev/null 2>&1 \
  && fail "boundary 4: resume untracks rules/learned.md exactly once" \
  || pass "boundary 4: resume untracks rules/learned.md exactly once"
[ ! -e "$b4/.agent/.learned-bullets-before" ] \
  && pass "boundary 4: the resume snapshot is removed after the untrack" \
  || fail "boundary 4: the resume snapshot is removed after the untrack"
r61_bullets_present "$b4/.agent/rules/learned.md" \
  && pass "boundary 4: the aggregate still reproduces every original bullet after resume" \
  || fail "boundary 4: the aggregate still reproduces every original bullet after resume"

b5="$WORK/mig-boundary-abort"
mkdir -p "$b5"
r61mode "$b5" track-shared
git -C "$b5" init -q
git -C "$b5" config user.name Tester
git -C "$b5" config user.email tester@example.invalid
git -C "$b5" add .agent
git -C "$b5" commit -qm initial

cp -R "$b5/.agent" "$b5/.agent.backup-v6"
grep '^- ' "$b5/.agent/rules/learned.md" >"$b5/.agent/.learned-bullets-before"
printf -- '- [2026-01-09] Bogus bullet never present in any record.\n' >>"$b5/.agent/.learned-bullets-before"
awk '/^  version: 6$/ { print; print "  migration_target: \"6.3\""; next } { print }' \
  "$b5/.agent/purpose.md" >"$b5/.agent/purpose.md.tmp"
mv "$b5/.agent/purpose.md.tmp" "$b5/.agent/purpose.md"

mkdir -p "$b5/.agent/rules/learned"
b5id1=$(bash -c 'RANDOM=6501; printf "%04x%04x%04x" "$RANDOM" "$RANDOM" "$RANDOM"')
b5id2=$(bash -c 'RANDOM=6502; printf "%04x%04x%04x" "$RANDOM" "$RANDOM" "$RANDOM"')
b5id3=$(bash -c 'RANDOM=6503; printf "%04x%04x%04x" "$RANDOM" "$RANDOM" "$RANDOM"')
b5id4=$(bash -c 'RANDOM=6504; printf "%04x%04x%04x" "$RANDOM" "$RANDOM" "$RANDOM"')
printf -- '- [2026-01-01] First rule, flat. Trigger: something.\n' >"$b5/.agent/rules/learned/$b5id1.md"
printf '%s\n' \
  '- [2026-01-02] Second rule with a nested sub-bullet. Trigger: x.' \
  '  - qualifier one' \
  '  - qualifier two' >"$b5/.agent/rules/learned/$b5id2.md"
printf '%s\n' \
  '- [2026-01-03] Third rule, multi paragraph.' \
  '' \
  '  Continuation paragraph here.' >"$b5/.agent/rules/learned/$b5id3.md"
printf -- '- [2026-01-04] Fourth rule, flat, last one.\n' >"$b5/.agent/rules/learned/$b5id4.md"

"$NODE" update "$b5" >"$WORK/b5-update.out" 2>&1
b5rc=$?
[ "$b5rc" -ne 0 ] \
  && pass "abort path: update exits nonzero when the regenerated aggregate does not reproduce every snapshotted bullet" \
  || fail "abort path: update exits nonzero when the regenerated aggregate does not reproduce every snapshotted bullet (rc=$b5rc)"
git -C "$b5" ls-files --error-unmatch -- .agent/rules/learned.md >/dev/null 2>&1 \
  && pass "abort path: rules/learned.md stays tracked when the aggregate-reproduction check fails" \
  || fail "abort path: rules/learned.md stays tracked when the aggregate-reproduction check fails"
[ -e "$b5/.agent/.learned-bullets-before" ] \
  && pass "abort path: .learned-bullets-before is not removed when the aggregate-reproduction check fails" \
  || fail "abort path: .learned-bullets-before is not removed when the aggregate-reproduction check fails"

mm_build() {
  mm_dir="$1"
  mm_mode="$2"
  mm_git="$3"
  mkdir -p "$mm_dir"
  r61mode "$mm_dir" "$mm_mode"
  printf '# Custom\n\nHand-authored project note that must survive migration untouched.\n' \
    >"$mm_dir/.agent/docs/custom.md"
  if [ "$mm_git" = yes ]; then
    git -C "$mm_dir" init -q
    git -C "$mm_dir" config user.name Tester
    git -C "$mm_dir" config user.email tester@example.invalid
    git -C "$mm_dir" add .agent
    git -C "$mm_dir" commit -qm initial
  fi
}

mmA="$WORK/mm-track-shared"
mm_build "$mmA" track-shared yes
cp "$mmA/.agent/docs/custom.md" "$WORK/mmA-custom-before.md"
"$NODE" update "$mmA" >"$WORK/mmA-update.out" 2>&1
mmA_rc=$?
[ "$mmA_rc" -eq 0 ] && pass "mode matrix (track-shared): update exits 0" || fail "mode matrix (track-shared): update exits 0 (rc=$mmA_rc)"
mmA_gi1=$(grep -cxF '.agent/indexes/' "$mmA/.gitignore" 2>/dev/null)
mmA_gi2=$(grep -cxF '.agent/rules/learned.md' "$mmA/.gitignore" 2>/dev/null)
[ "$mmA_gi1" -eq 1 ] && [ "$mmA_gi2" -eq 1 ] \
  && pass "mode matrix (track-shared): both gitignore lines are present exactly once" \
  || fail "mode matrix (track-shared): both gitignore lines are present exactly once"
git -C "$mmA" ls-files --error-unmatch -- .agent/rules/learned.md >/dev/null 2>&1 \
  && fail "mode matrix (track-shared): rules/learned.md is untracked after migration" \
  || pass "mode matrix (track-shared): rules/learned.md is untracked after migration"
diff -q "$WORK/mmA-custom-before.md" "$mmA/.agent/docs/custom.md" >/dev/null 2>&1 \
  && pass "mode matrix (track-shared): the customized doc's content survives untouched" \
  || fail "mode matrix (track-shared): the customized doc's content survives untouched"
git -C "$mmA" ls-files --error-unmatch -- .agent/docs/custom.md >/dev/null 2>&1 \
  && pass "mode matrix (track-shared): the customized doc keeps its tracked ownership" \
  || fail "mode matrix (track-shared): the customized doc keeps its tracked ownership"
"$NODE" update "$mmA" >"$WORK/mmA-update2.out" 2>&1
mmA_rc2=$?
[ "$mmA_rc2" -eq 0 ] && pass "mode matrix (track-shared): a second update exits 0" || fail "mode matrix (track-shared): a second update exits 0 (rc=$mmA_rc2)"
mmA_gi1b=$(grep -cxF '.agent/indexes/' "$mmA/.gitignore" 2>/dev/null)
mmA_gi2b=$(grep -cxF '.agent/rules/learned.md' "$mmA/.gitignore" 2>/dev/null)
[ "$mmA_gi1b" -eq 1 ] && [ "$mmA_gi2b" -eq 1 ] \
  && pass "mode matrix (track-shared): a second update adds no duplicate gitignore line" \
  || fail "mode matrix (track-shared): a second update adds no duplicate gitignore line"

mmB="$WORK/mm-track-all"
mm_build "$mmB" track-all yes
cp "$mmB/.agent/docs/custom.md" "$WORK/mmB-custom-before.md"
"$NODE" update "$mmB" >"$WORK/mmB-update.out" 2>&1
mmB_rc=$?
[ "$mmB_rc" -eq 0 ] && pass "mode matrix (track-all): update exits 0" || fail "mode matrix (track-all): update exits 0 (rc=$mmB_rc)"
[ ! -e "$mmB/.agent.backup-v6" ] \
  && pass "mode matrix (track-all): no backup is created" \
  || fail "mode matrix (track-all): no backup is created"
mmB_gi1=$(grep -cxF '.agent/indexes/' "$mmB/.gitignore" 2>/dev/null)
mmB_gi2=$(grep -cxF '.agent/rules/learned.md' "$mmB/.gitignore" 2>/dev/null)
[ "$mmB_gi1" -eq 1 ] && [ "$mmB_gi2" -eq 1 ] \
  && pass "mode matrix (track-all): both gitignore lines are present exactly once" \
  || fail "mode matrix (track-all): both gitignore lines are present exactly once"
git -C "$mmB" ls-files --error-unmatch -- .agent/rules/learned.md >/dev/null 2>&1 \
  && fail "mode matrix (track-all): rules/learned.md is untracked after migration" \
  || pass "mode matrix (track-all): rules/learned.md is untracked after migration"
diff -q "$WORK/mmB-custom-before.md" "$mmB/.agent/docs/custom.md" >/dev/null 2>&1 \
  && pass "mode matrix (track-all): the customized doc's content survives untouched" \
  || fail "mode matrix (track-all): the customized doc's content survives untouched"
git -C "$mmB" ls-files --error-unmatch -- .agent/docs/custom.md >/dev/null 2>&1 \
  && pass "mode matrix (track-all): the customized doc keeps its tracked ownership" \
  || fail "mode matrix (track-all): the customized doc keeps its tracked ownership"
"$NODE" update "$mmB" >"$WORK/mmB-update2.out" 2>&1
mmB_gi1b=$(grep -cxF '.agent/indexes/' "$mmB/.gitignore" 2>/dev/null)
mmB_gi2b=$(grep -cxF '.agent/rules/learned.md' "$mmB/.gitignore" 2>/dev/null)
[ "$mmB_gi1b" -eq 1 ] && [ "$mmB_gi2b" -eq 1 ] \
  && pass "mode matrix (track-all): a second update adds no duplicate gitignore line" \
  || fail "mode matrix (track-all): a second update adds no duplicate gitignore line"

mmC="$WORK/mm-ignore-all"
mm_build "$mmC" ignore-all no
cp "$mmC/.agent/docs/custom.md" "$WORK/mmC-custom-before.md"
"$NODE" update "$mmC" >"$WORK/mmC-update.out" 2>&1
mmC_rc=$?
[ "$mmC_rc" -eq 0 ] && pass "mode matrix (ignore-all, no git): update exits 0" || fail "mode matrix (ignore-all, no git): update exits 0 (rc=$mmC_rc)"
[ ! -e "$mmC/.gitignore" ] \
  && pass "mode matrix (ignore-all, no git): no gitignore is written" \
  || fail "mode matrix (ignore-all, no git): no gitignore is written"
diff -q "$WORK/mmC-custom-before.md" "$mmC/.agent/docs/custom.md" >/dev/null 2>&1 \
  && pass "mode matrix (ignore-all, no git): the customized doc's content survives untouched" \
  || fail "mode matrix (ignore-all, no git): the customized doc's content survives untouched"
"$NODE" update "$mmC" >"$WORK/mmC-update2.out" 2>&1
mmC_rc2=$?
[ "$mmC_rc2" -eq 0 ] && pass "mode matrix (ignore-all, no git): a second update exits 0" || fail "mode matrix (ignore-all, no git): a second update exits 0 (rc=$mmC_rc2)"

mmD="$WORK/mm-track-shared-nogit"
mm_build "$mmD" track-shared no
cp "$mmD/.agent/docs/custom.md" "$WORK/mmD-custom-before.md"
"$NODE" update "$mmD" >"$WORK/mmD-update.out" 2>&1
mmD_rc=$?
[ "$mmD_rc" -eq 0 ] && pass "mode matrix (track-shared, no git): update exits 0" || fail "mode matrix (track-shared, no git): update exits 0 (rc=$mmD_rc)"
mmD_gi1=$(grep -cxF '.agent/indexes/' "$mmD/.gitignore" 2>/dev/null)
mmD_gi2=$(grep -cxF '.agent/rules/learned.md' "$mmD/.gitignore" 2>/dev/null)
[ "$mmD_gi1" -eq 1 ] && [ "$mmD_gi2" -eq 1 ] \
  && pass "mode matrix (track-shared, no git): both gitignore lines are still written" \
  || fail "mode matrix (track-shared, no git): both gitignore lines are still written"
diff -q "$WORK/mmD-custom-before.md" "$mmD/.agent/docs/custom.md" >/dev/null 2>&1 \
  && pass "mode matrix (track-shared, no git): the customized doc's content survives untouched" \
  || fail "mode matrix (track-shared, no git): the customized doc's content survives untouched"
"$NODE" update "$mmD" >"$WORK/mmD-update2.out" 2>&1
mmD_gi1b=$(grep -cxF '.agent/indexes/' "$mmD/.gitignore" 2>/dev/null)
mmD_gi2b=$(grep -cxF '.agent/rules/learned.md' "$mmD/.gitignore" 2>/dev/null)
[ "$mmD_gi1b" -eq 1 ] && [ "$mmD_gi2b" -eq 1 ] \
  && pass "mode matrix (track-shared, no git): a second update adds no duplicate gitignore line" \
  || fail "mode matrix (track-shared, no git): a second update adds no duplicate gitignore line"

au="$WORK/mm-already-untracked"
mm_build "$au" track-shared yes
"$NODE" update "$au" >"$WORK/au-update1.out" 2>&1
git -C "$au" ls-files --error-unmatch -- .agent/rules/learned.md >/dev/null 2>&1 \
  && fail "already-untracked: the first update untracks rules/learned.md, setting up the fixture" \
  || pass "already-untracked: the first update untracks rules/learned.md, setting up the fixture"
git -C "$au" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  && pass "already-untracked: the fixture remains inside a git work tree" \
  || fail "already-untracked: the fixture remains inside a git work tree"

"$NODE" update "$au" >"$WORK/au-update2.out" 2>&1
au_rc2=$?
[ "$au_rc2" -eq 0 ] \
  && pass "already-untracked: a second update, with the file already untracked, exits 0" \
  || fail "already-untracked: a second update, with the file already untracked, exits 0 (rc=$au_rc2)"
grep -qF 'skipped untracking .agent/rules/learned.md (.agent/rules/learned.md is not tracked)' "$WORK/au-update2.out" \
  && pass "already-untracked: the second update reports the not-tracked skip and runs no git rm --cached" \
  || fail "already-untracked: the second update reports the not-tracked skip and runs no git rm --cached"
git -C "$au" ls-files --error-unmatch -- .agent/rules/learned.md >/dev/null 2>&1 \
  && fail "already-untracked: rules/learned.md is still not tracked after the second update" \
  || pass "already-untracked: rules/learned.md is still not tracked after the second update"

mg="$WORK/mig-merge-base"
mkdir -p "$mg"
r61mode "$mg" track-shared
git -C "$mg" init -q
git -C "$mg" config user.name Tester
git -C "$mg" config user.email tester@example.invalid
git -C "$mg" add .agent
git -C "$mg" commit -qm initial
"$NODE" update "$mg" >/dev/null 2>&1
git -C "$mg" add -A
git -C "$mg" commit -qm "post-migration state"
mgbase=$(git -C "$mg" symbolic-ref --short HEAD)

git -C "$mg" checkout -qb recA "$mgbase"
printf -- '- [2026-02-01] Branch A added this rule.\n' >"$mg/.agent/rules/learned/branch-a-record.md"
git -C "$mg" add .agent/rules/learned/branch-a-record.md
git -C "$mg" commit -qm "branch A record"

git -C "$mg" checkout -q "$mgbase"
git -C "$mg" checkout -qb recB "$mgbase"
printf -- '- [2026-02-02] Branch B added this rule.\n' >"$mg/.agent/rules/learned/branch-b-record.md"
git -C "$mg" add .agent/rules/learned/branch-b-record.md
git -C "$mg" commit -qm "branch B record"

git -C "$mg" checkout -qb merge-ab "$mgbase"
git -C "$mg" merge -q --no-edit recA >"$WORK/mg-merge-a.out" 2>&1
mgmerge1rc=$?
git -C "$mg" merge -q --no-edit recB >"$WORK/mg-merge-b.out" 2>&1
mgmerge2rc=$?
[ "$mgmerge1rc" -eq 0 ] && [ "$mgmerge2rc" -eq 0 ] \
  && pass "merge fixture: two disjoint new records merge clean" \
  || fail "merge fixture: two disjoint new records merge clean"
"$mg/.agent/scripts/index.sh" ensure --root "$mg" >/dev/null 2>&1
grep -qF 'Branch A added this rule.' "$mg/.agent/rules/learned.md" \
  && grep -qF 'Branch B added this rule.' "$mg/.agent/rules/learned.md" \
  && pass "merge fixture: both merged records reach the regenerated aggregate" \
  || fail "merge fixture: both merged records reach the regenerated aggregate"

git -C "$mg" checkout -q "$mgbase"
mgeditfile=$(grep -lF 'First rule, flat' "$mg/.agent/rules/learned"/*.md | head -n1)
mgeditrel=${mgeditfile#"$mg"/}

git -C "$mg" checkout -qb editC "$mgbase"
printf -- '- [2026-01-01] First rule, flat. Trigger: something -- edited by C.\n' >"$mgeditfile"
git -C "$mg" commit -qam "branch C edit"

git -C "$mg" checkout -qb editD "$mgbase"
printf -- '- [2026-01-01] First rule, flat. Trigger: something -- edited by D.\n' >"$mgeditfile"
git -C "$mg" commit -qam "branch D edit"

git -C "$mg" checkout -qb merge-cd "$mgbase"
git -C "$mg" merge -q --no-edit editC >"$WORK/mg-merge-c.out" 2>&1
mgmerge3rc=$?
git -C "$mg" merge -q --no-edit editD >"$WORK/mg-merge-d.out" 2>&1
mgmerge4rc=$?
[ "$mgmerge3rc" -eq 0 ] \
  && pass "merge fixture: the first same-record edit applies clean" \
  || fail "merge fixture: the first same-record edit applies clean"
[ "$mgmerge4rc" -ne 0 ] \
  && pass "merge fixture: a second edit to the same record conflicts rather than silently choosing a winner" \
  || fail "merge fixture: a second edit to the same record conflicts rather than silently choosing a winner"
git -C "$mg" diff --name-only --diff-filter=U 2>/dev/null | grep -qF "$mgeditrel" \
  && pass "merge fixture: the conflict lands on the edited record file" \
  || fail "merge fixture: the conflict lands on the edited record file"
git -C "$mg" merge --abort >/dev/null 2>&1

git -C "$mg" checkout -qb linear "$mgbase"
printf -- '- [2026-02-03] Linear commit one added this rule.\n' >"$mg/.agent/rules/learned/linear-one.md"
git -C "$mg" add .agent/rules/learned/linear-one.md
git -C "$mg" commit -qm "linear commit one"
printf -- '- [2026-02-04] Linear commit two added this rule.\n' >"$mg/.agent/rules/learned/linear-two.md"
git -C "$mg" add .agent/rules/learned/linear-two.md
git -C "$mg" commit -qm "linear commit two"
"$mg/.agent/scripts/index.sh" ensure --root "$mg" >/dev/null 2>&1
grep -qF 'Linear commit one added this rule.' "$mg/.agent/rules/learned.md" \
  && grep -qF 'Linear commit two added this rule.' "$mg/.agent/rules/learned.md" \
  && pass "linear replay: both sequential commits' records survive in the regenerated aggregate" \
  || fail "linear replay: both sequential commits' records survive in the regenerated aggregate"

e2e="$WORK/mig-e2e-status"
mkdir -p "$e2e"
r61mode "$e2e" track-shared
git -C "$e2e" init -q
git -C "$e2e" config user.name Tester
git -C "$e2e" config user.email tester@example.invalid
git -C "$e2e" add .agent
git -C "$e2e" commit -qm initial

"$NODE" update "$e2e" >"$WORK/e2e-update.out" 2>&1
e2e_rc=$?
[ "$e2e_rc" -eq 0 ] && pass "end-to-end migration: update exits 0" || fail "end-to-end migration: update exits 0 (rc=$e2e_rc)"
git -C "$e2e" ls-files --error-unmatch -- .agent/rules/learned.md >/dev/null 2>&1 \
  && fail "end-to-end migration: the real chain untracks rules/learned.md" \
  || pass "end-to-end migration: the real chain untracks rules/learned.md"

e2e_flags_after=$(status_flags "$e2e")
e2e_bad_repairs=$(printf '%s\n' "$e2e_flags_after" \
  | grep '^REPAIR:' \
  | grep -v '^REPAIR: purpose\.md has migration_target ' \
  | grep -i 'learned')
[ -z "$e2e_bad_repairs" ] \
  && pass "end-to-end migration: an unmodified status.sh emits no REPAIR: finding referencing rules/learned.md or the migration, apart from the expected pending-migration_target note" \
  || fail "end-to-end migration: an unmodified status.sh emits no REPAIR: finding referencing rules/learned.md or the migration, apart from the expected pending-migration_target note ($e2e_bad_repairs)"

shimU="$WORK/shim-update"
make_v6_fixture "$shimU"
"$NODE" update "$shimU" >/dev/null 2>&1
[ -x "$shimU/.agent/scripts/checkpoint.sh" ] && [ ! -e "$shimU/.agent/scripts/finish.sh" ] \
  && pass "node.sh update: refreshes checkpoint.sh and installs no finish.sh" \
  || fail "node.sh update: refreshes checkpoint.sh and installs no finish.sh"

rs67="$WORK/read-set-cold"
mkdir -p "$rs67"
"$NODE" init --preset software-development --mode track-all --indexes generated "$rs67" >/dev/null 2>&1
finish_bootstrap "$rs67"
"$IDXSH" ensure --root "$rs67" >"$WORK/rs67.cold.out" 2>"$WORK/rs67.cold.err"
grep -q '^BUILT$' "$WORK/rs67.cold.err" \
  && pass "read set: a cold index.sh ensure reports BUILT" \
  || fail "read set: a cold index.sh ensure reports BUILT"
[ "$(cat "$WORK/rs67.cold.out")" = "$rs67/.agent/indexes/current.md" ] \
  && pass "read set: index.sh ensure prints the entry path" \
  || fail "read set: index.sh ensure prints the entry path"

"$rs67/.agent/scripts/status.sh" --load "$rs67" >"$WORK/rs67.load.out" 2>&1
grep -qF "Index pages: open every page listed here before the work." "$WORK/rs67.load.out" \
  && [ "$(grep '^READ: ' "$WORK/rs67.load.out")" = "$(grep '^READ: ' "$rs67/.agent/indexes/current.md")" ] \
  && pass "read set: --load lists the index entry file's pages in generated mode" \
  || fail "read set: --load lists the index entry file's pages in generated mode"
grep -qF '==== .agent/purpose.md ====' "$WORK/rs67.load.out" \
  && pass "read set: --load prints purpose.md under a marker in generated mode" \
  || fail "read set: --load prints purpose.md under a marker in generated mode"
grep -qF '==== .agent/memory.md ====' "$WORK/rs67.load.out" \
  && pass "read set: --load prints memory.md under a marker in generated mode" \
  || fail "read set: --load prints memory.md under a marker in generated mode"
grep -q '^==== \.agent/rules/' "$WORK/rs67.load.out" \
  && fail "read set: --load prints no .agent/rules/ marker in generated mode" \
  || pass "read set: --load prints no .agent/rules/ marker in generated mode"

rs67ni="$WORK/read-set-no-indexer"
mkdir -p "$rs67ni"
"$NODE" init --preset software-development --mode track-all --indexes generated "$rs67ni" >/dev/null 2>&1
finish_bootstrap "$rs67ni"
"$IDXSH" ensure --root "$rs67ni" >/dev/null 2>&1
rm -f "$rs67ni/.agent/scripts/index.sh"
"$rs67ni/.agent/scripts/status.sh" --load "$rs67ni" >"$WORK/rs67ni.load.out" 2>&1
grep -q '^Indexer missing: purpose.md says indexes: generated but scripts/index.sh is not installed' "$WORK/rs67ni.load.out" \
  && pass "read set: a generated node with no indexer is told so in the load output, not as a REPAIR" \
  || fail "read set: a generated node with no indexer is told so in the load output, not as a REPAIR"
grep -q '^REPAIR: .*index.sh' "$WORK/rs67ni.load.out" \
  && fail "read set: a missing indexer stays a warning, never a checkpoint-blocking REPAIR" \
  || pass "read set: a missing indexer stays a warning, never a checkpoint-blocking REPAIR"
grep -qF '==== .agent/rules/contract.md ====' "$WORK/rs67ni.load.out" \
  && pass "read set: --load prints the contract inline when the indexer is missing" \
  || fail "read set: --load prints the contract inline when the indexer is missing"
grep -qF "read every page listed in .agent/indexes/current.md" "$WORK/rs67ni.load.out" \
  && fail "read set: --load never points at the unverifiable cache when the indexer is missing" \
  || pass "read set: --load never points at the unverifiable cache when the indexer is missing"

rs67_snap_before=$(idx_snapshot "$rs67/.agent/indexes")
"$IDXSH" ensure --root "$rs67" >"$WORK/rs67.warm.out" 2>"$WORK/rs67.warm.err"
grep -q '^HIT$' "$WORK/rs67.warm.err" \
  && pass "read set: a warm index.sh ensure reports HIT" \
  || fail "read set: a warm index.sh ensure reports HIT"
[ "$(cat "$WORK/rs67.warm.out")" = "$(cat "$WORK/rs67.cold.out")" ] \
  && pass "read set: a warm ensure prints the same entry path" \
  || fail "read set: a warm ensure prints the same entry path"
rs67_snap_after=$(idx_snapshot "$rs67/.agent/indexes")
[ "$rs67_snap_before" = "$rs67_snap_after" ] \
  && pass "read set: a warm ensure publishes no new generation" \
  || fail "read set: a warm ensure publishes no new generation"

dup67="$WORK/read-set-dup"
mkdir -p "$dup67"
"$NODE" init --preset software-development --mode track-all --indexes generated "$dup67" >/dev/null 2>&1
finish_bootstrap "$dup67"
printf '# Custom Rule\n\nThe duplicate-body probe sentence lives only in this rule record.\n' >"$dup67/.agent/rules/custom.md"
"$IDXSH" ensure --root "$dup67" >/dev/null 2>"$WORK/dup67.err"
dup67_gen=$(sed -n 2p "$dup67/.agent/indexes/current.md")
grep -qrF -- 'duplicate-body probe sentence' "$dup67/.agent/indexes/$dup67_gen" \
  && pass "read set: a rule's distinctive sentence appears in a published page" \
  || fail "read set: a rule's distinctive sentence appears in a published page"
"$dup67/.agent/scripts/status.sh" --load "$dup67" 2>/dev/null | grep -qF -- 'duplicate-body probe sentence' \
  && fail "read set: the rule's sentence does not also appear in --load output" \
  || pass "read set: the rule's sentence does not also appear in --load output"

mp67="$WORK/manual-parity"
mkdir -p "$mp67"
"$NODE" init --preset software-development --mode track-all --indexes manual "$mp67" >/dev/null 2>&1
finish_bootstrap "$mp67"
"$mp67/.agent/scripts/status.sh" --load "$mp67" >"$WORK/mp67.cur.out" 2>&1

mp67_order=$(grep -n '^==== ' "$WORK/mp67.cur.out" | cut -d: -f2 | tr '\n' ' ')
[ "$mp67_order" = "==== .agent/rules/learned.md ==== ==== .agent/rules/contract.md ==== ==== .agent/purpose.md ==== ==== .agent/memory.md ==== " ] \
  && pass "manual mode: --load prints the four canonical markers, learned, contract, purpose, memory, in order" \
  || fail "manual mode: --load prints the four canonical markers, learned, contract, purpose, memory, in order ($mp67_order)"

grep -qE '^PAYLOAD: --load would write [0-9]+ bytes of a [0-9]+ byte budget \(notes [0-9]+, learned [0-9]+, contract [0-9]+, purpose [0-9]+, memory [0-9]+, tail [0-9]+\)$' "$WORK/mp67.cur.out" \
  && pass "manual mode: PAYLOAD: line frames all four files, learned first" \
  || fail "manual mode: PAYLOAD: line frames all four files, learned first"

mp67_expected="$WORK/mp67.expected-tail.out"
: >"$mp67_expected"
for mp67_f in rules/learned.md rules/contract.md purpose.md memory.md; do
  printf '\n==== .agent/%s ====\n' "$mp67_f" >>"$mp67_expected"
  cat "$mp67/.agent/$mp67_f" >>"$mp67_expected"
done
mp67_marker_line=$(grep -n '^==== ' "$WORK/mp67.cur.out" | head -1 | cut -d: -f1)
mp67_actual="$WORK/mp67.actual-tail.out"
tail -n "+$((mp67_marker_line - 1))" "$WORK/mp67.cur.out" >"$mp67_actual"
cmp -s "$mp67_expected" "$mp67_actual" \
  && pass "manual mode: --load's marker segment matches the fixture's own files byte for byte" \
  || fail "manual mode: --load's marker segment matches the fixture's own files byte for byte"

tplgen67="$reporoot/templates/entry-point-generated.md"
missing67=""
grep -qF "run once" "$tplgen67" || grep -qF "runs once" "$tplgen67" || missing67="$missing67 once-per-session"
grep -qF "Do not open this file with a tool when its content is already present in your context." "$tplgen67" || missing67="$missing67 no-reopen-from-disk"
grep -qF "compaction" "$tplgen67" || missing67="$missing67 compaction-rerun"
grep -qF "branch switch" "$tplgen67" || missing67="$missing67 branch-switch-rerun"
grep -qF "opened only to edit it, to check its provenance, or to resolve a concrete uncertainty" "$tplgen67" || missing67="$missing67 rule-source"
grep -qF "the catalog, read whole" "$tplgen67" || missing67="$missing67 routes-catalog"
grep -qF "read \`.agent/rules/\` and \`.agent/docs/architecture.md\` directly and carry on" "$tplgen67" || missing67="$missing67 fallback"
[ -z "$missing67" ] && pass "template: the generated entry point carries its timing, routing, and fallback phrases" || fail "template: the generated entry point carries its timing, routing, and fallback phrases (missing:$missing67)"

ex67="$WORK/read-set-exclusions"
mkdir -p "$ex67"
"$NODE" init --preset software-development --mode track-all --indexes generated "$ex67" >/dev/null 2>&1
finish_bootstrap "$ex67"
mkdir -p "$ex67/.agent/docs/area/references" "$ex67/.agent/docs/references"
printf '# Architecture\n\nRouting table placeholder.\n' >"$ex67/.agent/docs/architecture.md"
printf '# Ordinary Doc\n<!-- Read when: testing exclusions -->\nOrdinary doc body.\n' >"$ex67/.agent/docs/ordinary.md"
printf '# Area Reference\n<!-- Read when: never routed -->\nArea reference body, never a routes line.\n' >"$ex67/.agent/docs/area/references/one.md"
printf '# Top Reference\n<!-- Read when: never routed -->\nTop-level reference body, never a routes line.\n' >"$ex67/.agent/docs/references/two.md"
"$IDXSH" ensure --root "$ex67" >/dev/null 2>"$WORK/ex67.err"
ex67_gen=$(sed -n 2p "$ex67/.agent/indexes/current.md")
ex67_dir="$ex67/.agent/indexes/$ex67_gen"

grep -qrF -- 'This rubric loads on demand' "$ex67_dir" \
  && fail "exclusions: no published page carries rules/quality-bar.md's body" \
  || pass "exclusions: no published page carries rules/quality-bar.md's body"
grep -hF -- 'READ:' "$ex67_dir"/routes-*.md 2>/dev/null | grep -qF 'docs/area/references/one.md' \
  && fail "exclusions: no routes line names the area-level references/ file" \
  || pass "exclusions: no routes line names the area-level references/ file"
grep -hF -- 'READ:' "$ex67_dir"/routes-*.md 2>/dev/null | grep -qF 'docs/references/two.md' \
  && fail "exclusions: no routes line names the top-level references/ file" \
  || pass "exclusions: no routes line names the top-level references/ file"
grep -qrF -- 'filled at bootstrap' "$ex67_dir" \
  && pass "exclusions: an ordinary rule record is still reachable from the entry file" \
  || fail "exclusions: an ordinary rule record is still reachable from the entry file"
grep -hF -- 'READ:' "$ex67_dir"/routes-*.md 2>/dev/null | grep -qF 'docs/ordinary.md' \
  && pass "exclusions: an ordinary routed doc is still reachable from the entry file" \
  || fail "exclusions: an ordinary routed doc is still reachable from the entry file"

bs67="$WORK/read-set-branch-stale"
mkdir -p "$bs67"
"$NODE" init --preset software-development --mode track-all --indexes generated "$bs67" >/dev/null 2>&1
finish_bootstrap "$bs67"
git -C "$bs67" init -q
git -C "$bs67" config user.name Tester
git -C "$bs67" config user.email tester@example.invalid
git -C "$bs67" add -A
git -C "$bs67" commit -qm bootstrap
"$IDXSH" ensure --root "$bs67" >/dev/null 2>/dev/null
bs67_gen1=$(sed -n 2p "$bs67/.agent/indexes/current.md")

git -C "$bs67" checkout -qb bs67-branch
printf -- '\n- Test: run this every time.\n' >>"$bs67/.agent/rules/contract.md"
git -C "$bs67" add -A
git -C "$bs67" commit -qm 'change a rule record'

bs67_check=$("$IDXSH" check --root "$bs67" 2>/dev/null)
[ "$bs67_check" = "STALE" ] \
  && pass "branch switch: index.sh check reports STALE after a record changes on a new branch" \
  || fail "branch switch: index.sh check reports STALE after a record changes on a new branch ($bs67_check)"

"$IDXSH" ensure --root "$bs67" >/dev/null 2>"$WORK/bs67.second.err"
bs67_gen2=$(sed -n 2p "$bs67/.agent/indexes/current.md")
grep -q '^BUILT$' "$WORK/bs67.second.err" \
  && pass "branch switch: the next ensure republishes" \
  || fail "branch switch: the next ensure republishes"
[ "$bs67_gen1" != "$bs67_gen2" ] \
  && pass "branch switch: the republished generation differs from the pre-switch one" \
  || fail "branch switch: the republished generation differs from the pre-switch one"

fe67="$WORK/read-set-failed-ensure"
mkdir -p "$fe67"
"$NODE" init --preset software-development --mode track-all --indexes generated "$fe67" >/dev/null 2>&1
finish_bootstrap "$fe67"
"$IDXSH" ensure --root "$fe67" >/dev/null 2>&1
fe67_entry_before=$(cat "$fe67/.agent/indexes/current.md")
printf -- '\n- Test: trigger a rebuild.\n' >>"$fe67/.agent/rules/contract.md"
INDEX_FAIL_AT=before-publish "$IDXSH" ensure --root "$fe67" >/dev/null 2>"$WORK/fe67.err"
fe67_rc=$?
[ "$fe67_rc" -eq 1 ] && grep -q 'FALLBACK:' "$WORK/fe67.err" \
  && pass "failed ensure: an injected failure before publication is reported and exits 1" \
  || fail "failed ensure: an injected failure before publication is reported and exits 1"
[ "$(cat "$fe67/.agent/indexes/current.md")" = "$fe67_entry_before" ] \
  && pass "failed ensure: the published entry stays byte-identical after a failed ensure" \
  || fail "failed ensure: the published entry stays byte-identical after a failed ensure"


c68a="$WORK/canonical-records-only"
mkdir -p "$c68a"
"$NODE" init --preset software-development --mode track-all --indexes generated "$c68a" >/dev/null 2>&1
finish_bootstrap "$c68a"
rm -f "$c68a/.agent/rules/learned.md"
mkdir -p "$c68a/.agent/rules/learned"
printf -- '- [2026-01-01] Record one.\n' >"$c68a/.agent/rules/learned/0001.md"
f68a=$(status_flags "$c68a")
[ -z "$f68a" ] && pass "canonical source: a record-only node draws no REPAIR: or GROOM: naming rules/learned.md" \
  || fail "canonical source: a record-only node draws no REPAIR: or GROOM: naming rules/learned.md ($f68a)"

c68b="$WORK/canonical-neither"
mkdir -p "$c68b"
"$NODE" init --preset software-development --mode track-all --indexes generated "$c68b" >/dev/null 2>&1
finish_bootstrap "$c68b"
rm -f "$c68b/.agent/rules/learned.md"
mkdir -p "$c68b/.agent/rules/learned"
f68b=$(status_flags "$c68b")
[ "$f68b" = "REPAIR: rules/learned/ missing/empty — restore the records, or rules/learned.md on a node that keeps no record directory; the entry point loads them every session" ] \
  && pass "canonical source: an empty rules/learned/ and no aggregate draws exactly the record-directory REPAIR:" \
  || fail "canonical source: an empty rules/learned/ and no aggregate draws exactly the record-directory REPAIR: ($f68b)"

c68b2="$WORK/canonical-neither-nonmd"
mkdir -p "$c68b2"
"$NODE" init --preset software-development --mode track-all --indexes generated "$c68b2" >/dev/null 2>&1
finish_bootstrap "$c68b2"
rm -f "$c68b2/.agent/rules/learned.md"
mkdir -p "$c68b2/.agent/rules/learned"
printf -- 'not a record\n' >"$c68b2/.agent/rules/learned/notes.txt"
f68b2=$(status_flags "$c68b2")
[ "$f68b2" = "REPAIR: rules/learned/ missing/empty — restore the records, or rules/learned.md on a node that keeps no record directory; the entry point loads them every session" ] \
  && pass "canonical source: a rules/learned/ holding only a non-.md file and no aggregate draws exactly the record-directory REPAIR:" \
  || fail "canonical source: a rules/learned/ holding only a non-.md file and no aggregate draws exactly the record-directory REPAIR: ($f68b2)"

c68c="$WORK/canonical-threshold-records"
mkdir -p "$c68c"
"$NODE" init --preset software-development --mode track-all --indexes generated "$c68c" >/dev/null 2>&1
finish_bootstrap "$c68c"
rm -f "$c68c/.agent/rules/learned.md"
mkdir -p "$c68c/.agent/rules/learned"
i68c=1
while [ "$i68c" -le 61 ]; do
  printf -- '- [2026-01-01] Rule %s.\n' "$i68c" >"$c68c/.agent/rules/learned/$(printf '%04d' "$i68c").md"
  i68c=$((i68c + 1))
done
f68c=$(status_flags "$c68c")
printf '%s\n' "$f68c" | grep -qF 'GROOM: rules/learned/ > 60 rules' \
  && pass "canonical source: 61 one-bullet records cross LEARNED_MAX_RULES and draw the rules/learned/ GROOM:" \
  || fail "canonical source: 61 one-bullet records cross LEARNED_MAX_RULES and draw the rules/learned/ GROOM: ($f68c)"

c68d="$WORK/canonical-threshold-aggregate"
mkdir -p "$c68d"
"$NODE" init --preset software-development --mode track-all --indexes generated "$c68d" >/dev/null 2>&1
finish_bootstrap "$c68d"
i68d=1
while [ "$i68d" -le 61 ]; do
  printf -- '- [2026-01-01] Rule %s.\n' "$i68d" >>"$c68d/.agent/rules/learned.md"
  i68d=$((i68d + 1))
done
f68d=$(status_flags "$c68d")
printf '%s\n' "$f68d" | grep -qF 'GROOM: learned.md > 60 rules' \
  && pass "canonical source: the equivalent aggregate crosses the same 61-record ceiling and draws its own GROOM:" \
  || fail "canonical source: the equivalent aggregate crosses the same 61-record ceiling and draws its own GROOM: ($f68d)"

d68="$WORK/cache-fault-paths"
mkdir -p "$d68"
"$NODE" init --preset software-development --mode track-all --indexes generated "$d68" >/dev/null 2>&1
finish_bootstrap "$d68"
f68e1=$(status_flags "$d68")
printf '%s\n' "$f68e1" | grep -q '\.agent/indexes/' \
  && fail "cache fault: no finding names .agent/indexes/ with the cache absent" \
  || pass "cache fault: no finding names .agent/indexes/ with the cache absent"

mkdir -p "$d68/.agent/indexes"
f68e2=$(status_flags "$d68")
printf '%s\n' "$f68e2" | grep -q '\.agent/indexes/' \
  && fail "cache fault: no finding names .agent/indexes/ with an empty cache directory" \
  || pass "cache fault: no finding names .agent/indexes/ with an empty cache directory"

"$IDXSH" ensure --root "$d68" >/dev/null 2>&1
d68gen=$(sed -n 2p "$d68/.agent/indexes/current.md")
printf 'damage\n' >>"$d68/.agent/indexes/$d68gen/rules-1.md"
f68e3=$(status_flags "$d68")
printf '%s\n' "$f68e3" | grep -q '\.agent/indexes/' \
  && fail "cache fault: no finding names .agent/indexes/ with a damaged generation" \
  || pass "cache fault: no finding names .agent/indexes/ with a damaged generation"

e68="$WORK/finish-cache-refresh"
mkdir -p "$e68/src"
"$NODE" init --preset software-development --mode track-all --indexes generated "$e68" >/dev/null 2>&1
finish_bootstrap "$e68"
printf 'export const a = 1\n' >"$e68/src/a.ts"
git -C "$e68" init -q && git -C "$e68" add -A && git -C "$e68" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m base
"$IDXSH" ensure --root "$e68" >/dev/null 2>&1
e68_before=$(idx_mtime "$e68/.agent/indexes/current.md")
sleep 1
"$e68/.agent/scripts/docs.sh" new --name backend --read-when "backend services" "$e68" >/dev/null 2>&1
printf '// Vendor caps retries at three by contract; a fourth attempt is rejected upstream.\nexport const b = 2\n' >"$e68/src/a.ts"
out68e=$("$e68/.agent/scripts/checkpoint.sh" --tool claude --area testing --checks test --summary "generated hand-back" "$e68" 2>&1)
rc68e=$?
n68e=$(grep -c '^- \[' "$e68/.agent/session-log.md")
e68_after=$(idx_mtime "$e68/.agent/indexes/current.md")
[ "$rc68e" -eq 0 ] && [ "$n68e" -eq 1 ] && printf '%s' "$out68e" | grep -qF 'checkpoint.sh: recorded' \
  && pass "checkpoint.sh: a generated hand-back runs the cache refresh step and logs exactly once" \
  || fail "checkpoint.sh: a generated hand-back runs the cache refresh step and logs exactly once (rc=$rc68e entries=$n68e)"
[ "$e68_after" -gt "$e68_before" ] \
  && pass "checkpoint.sh: the cache refresh leaves current.md newer than the pre-run state" \
  || fail "checkpoint.sh: the cache refresh leaves current.md newer than the pre-run state (before=$e68_before after=$e68_after)"

f68="$WORK/finish-cache-fault"
mkdir -p "$f68/src"
"$NODE" init --preset software-development --mode track-all --indexes generated "$f68" >/dev/null 2>&1
finish_bootstrap "$f68"
printf 'export const a = 1\n' >"$f68/src/a.ts"
git -C "$f68" init -q && git -C "$f68" add -A && git -C "$f68" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m base
n68f0=$(grep -c '^- \[' "$f68/.agent/session-log.md")

"$f68/.agent/scripts/docs.sh" new --name frontend --read-when "frontend widgets" "$f68" >/dev/null 2>&1
printf '// Vendor caps retries at three by contract; a fourth attempt is rejected upstream.\nexport const b = 2\n' >"$f68/src/a.ts"
INDEX_FAIL_AT=before-publish "$f68/.agent/scripts/checkpoint.sh" --tool claude --area testing --checks test --summary "injected index failure" "$f68" >/dev/null 2>"$WORK/f68.err"
rc68f=$?
n68f1=$(grep -c '^- \[' "$f68/.agent/session-log.md")
f68_warn=$(grep -c '^checkpoint.sh: ' "$WORK/f68.err")
[ "$rc68f" -eq 0 ] && [ "$n68f1" -eq "$((n68f0 + 1))" ] && [ "$f68_warn" -eq 1 ] \
  && grep -qF '.agent/rules/' "$WORK/f68.err" && grep -qF '.agent/docs/' "$WORK/f68.err" \
  && pass "checkpoint.sh: a failing index.sh leaves exit status and log entry unchanged, with one warning line" \
  || fail "checkpoint.sh: a failing index.sh leaves exit status and log entry unchanged, with one warning line (rc=$rc68f entries=$n68f1 warn=$f68_warn)"

rm -f "$f68/.agent/scripts/index.sh"
printf '// Vendor caps retries at three by contract; a fourth attempt is rejected upstream.\nexport const c = 3\n' >"$f68/src/a.ts"
"$f68/.agent/scripts/checkpoint.sh" --tool claude --area testing --checks test --summary "absent indexer" "$f68" >/dev/null 2>"$WORK/f68g.err"
rc68g=$?
n68g=$(grep -c '^- \[' "$f68/.agent/session-log.md")
f68g_warn=$(grep -c '^checkpoint.sh: ' "$WORK/f68g.err")
[ "$rc68g" -eq 0 ] && [ "$n68g" -eq "$((n68f0 + 2))" ] && [ "$f68g_warn" -eq 1 ] \
  && grep -qF '.agent/rules/' "$WORK/f68g.err" && grep -qF '.agent/docs/' "$WORK/f68g.err" \
  && pass "checkpoint.sh: an absent index.sh leaves exit status and log entry unchanged, with one warning line" \
  || fail "checkpoint.sh: an absent index.sh leaves exit status and log entry unchanged, with one warning line (rc=$rc68g entries=$n68g warn=$f68g_warn)"

g68="$WORK/finish-manual-parity"
mkdir -p "$g68/src"
"$NODE" init --preset software-development --mode track-all "$g68" >/dev/null 2>&1
finish_bootstrap "$g68"
printf 'export const a = 1\n' >"$g68/src/a.ts"
git -C "$g68" init -q && git -C "$g68" add -A && git -C "$g68" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m base
printf 'export const a = 1\nexport const b = 2\n' >"$g68/src/a.ts"
g68_actual=$("$g68/.agent/scripts/checkpoint.sh" --tool claude --area testing --checks test --summary "manual mode, no refresh" "$g68" 2>&1)
printf '%s\n' "$g68_actual" | grep -qF 'checkpoint.sh: recorded' \
  && ! printf '%s\n' "$g68_actual" | grep -qF 'cache refresh' \
  && pass "checkpoint.sh: a manual-mode node records completion without a cache refresh" \
  || fail "checkpoint.sh: a manual-mode node records completion without a cache refresh ($g68_actual)"
[ ! -d "$g68/.agent/indexes" ] \
  && pass "checkpoint.sh: a manual-mode node grows no .agent/indexes/ directory" \
  || fail "checkpoint.sh: a manual-mode node grows no .agent/indexes/ directory"

h68="$WORK/finish-markdown-exclusion"
mkdir -p "$h68/src"
"$NODE" init --preset software-development --mode track-all "$h68" >/dev/null 2>&1
finish_bootstrap "$h68"
printf 'export const a = 1\n' >"$h68/src/a.ts"
git -C "$h68" init -q && git -C "$h68" add -A && git -C "$h68" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m base
printf '\nfor this pass, cache the response for five minutes.\n' >>"$h68/.agent/memory.md"
n68h0=$(grep -c '^- \[' "$h68/.agent/session-log.md")
out68h=$("$h68/.agent/scripts/checkpoint.sh" --tool claude --area testing --checks test --summary "markdown-only change under .agent/" "$h68" 2>&1)
rc68h=$?
n68h1=$(grep -c '^- \[' "$h68/.agent/session-log.md")
[ "$rc68h" -eq 0 ] && [ "$n68h1" -eq "$((n68h0 + 1))" ] && ! printf '%s' "$out68h" | grep -q 'BLOCK' \
  && pass "checkpoint.sh: the comment gate still excludes Markdown and .agent/, a Markdown-only .agent/ change reaches the log entry" \
  || fail "checkpoint.sh: the comment gate still excludes Markdown and .agent/, a Markdown-only .agent/ change reaches the log entry (rc=$rc68h entries=$n68h1)"

g69_usewhen=""
g69_quoted=""
g69_2ndperson=""
g69_budget=""
g69_desc_of() { sed -n 's/^description: //p' "$1" | head -n 1; }
for g69_file in "$reporoot"/tools/skills/*/SKILL.md; do
  [ -e "$g69_file" ] || continue
  g69_rel=${g69_file#"$reporoot"/}
  g69_desc=$(g69_desc_of "$g69_file")
  printf '%s' "$g69_desc" | grep -qE 'Use (when|after|before|for|during|whenever) ' \
    || g69_usewhen="$g69_usewhen $g69_rel"
  case "$g69_desc" in
  *:*)
    case "$g69_desc" in
    \"*) ;;
    *) g69_quoted="$g69_quoted $g69_rel" ;;
    esac
    ;;
  esac
  printf '%s' "$g69_desc" | grep -qiE '\byou\b|\byour\b' && g69_2ndperson="$g69_2ndperson $g69_rel"
  g69_bytes=$(printf '%s' "$g69_desc" | LC_ALL=C wc -c | tr -d '[:space:]')
  [ "$g69_bytes" -gt 440 ] && g69_budget="$g69_budget $g69_rel($g69_bytes)"
done
[ -z "$g69_usewhen" ] && pass "skills: every SKILL.md description carries a when-to-use clause" \
  || fail "skills: every SKILL.md description carries a when-to-use clause ($g69_usewhen)"
[ -z "$g69_quoted" ] && pass "skills: a description holding a colon is a quoted YAML value" \
  || fail "skills: a description holding a colon is a quoted YAML value ($g69_quoted)"
[ -z "$g69_2ndperson" ] && pass "skills: no SKILL.md description addresses the reader in the second person" \
  || fail "skills: no SKILL.md description addresses the reader in the second person ($g69_2ndperson)"
[ -z "$g69_budget" ] && pass "skills: every SKILL.md description stays inside the description budget" \
  || fail "skills: every SKILL.md description stays inside the description budget ($g69_budget)"

g69_bad="$WORK/g69-bad-skill/SKILL.md"
mkdir -p "$(dirname "$g69_bad")"
g69_longtail=$(words_n 200)
printf 'description: Your favorite: %s\n' "$g69_longtail" >"$g69_bad"
g69_baddesc=$(g69_desc_of "$g69_bad")
g69_badhits=0
printf '%s' "$g69_baddesc" | grep -qE 'Use (when|after|before|for|during|whenever) ' || g69_badhits=$((g69_badhits + 1))
case "$g69_baddesc" in
*:*) case "$g69_baddesc" in \"*) ;; *) g69_badhits=$((g69_badhits + 1)) ;; esac ;;
esac
printf '%s' "$g69_baddesc" | grep -qiE '\byou\b|\byour\b' && g69_badhits=$((g69_badhits + 1))
g69_badbytes=$(printf '%s' "$g69_baddesc" | LC_ALL=C wc -c | tr -d '[:space:]')
[ "$g69_badbytes" -gt 440 ] && g69_badhits=$((g69_badhits + 1))
[ "$g69_badhits" -eq 4 ] && pass "skills: the description-bar checks catch a description that violates every rule at once" \
  || fail "skills: the description-bar checks catch a description that violates every rule at once (caught $g69_badhits/4)"

g70skill="$reporoot/tools/skills/groom/SKILL.md"
grep -qF 'Close a generated-mode pass with `.agent/scripts/index.sh ensure` before the `status.sh` re-run' "$g70skill" \
  && grep -qF 'rebuilt from those records and never edited' "$g70skill" \
  && pass "groom skill: a generated-mode pass edits records and closes with index.sh ensure" \
  || fail "groom skill: a generated-mode pass edits records and closes with index.sh ensure"
grep -qF 'A fold rewrites the record whose entry carries the earlier date and retires the other with `learn.sh retire --enforced-by' "$g70skill" \
  && grep -qF 'lower-sorting filename surviving a tie on the same date' "$g70skill" \
  && pass "groom skill: a fold keeps the earlier-dated record and retires the other against it" \
  || fail "groom skill: a fold keeps the earlier-dated record and retires the other against it"
grep -qF 'A record fold, split, or move runs this same procedure' "$g70skill" \
  && grep -qF 'A dropped fact, qualifier, or source reference fails the pass' "$g70skill" \
  && pass "groom skill: a record fold, split, or move runs the anchor check" \
  || fail "groom skill: a record fold, split, or move runs the anchor check"

g71_trim_docs() {
  g71td_dir="$1"
  rm -f "$g71td_dir/.agent/docs/dup.md" "$g71td_dir/.agent/docs/badtable.md" "$g71td_dir/.agent/docs/noentry.md"
  cat >"$g71td_dir/.agent/docs/architecture.md" <<'EOF'
# Architecture

### `hooked.md`
- **Read when:** already hooked, never touched.

### `unhooked.md`
- **Read when:** doing unhooked work.

### `area/sub.md`
- **Read when:** doing area sub work.
EOF
}

g71="$WORK/groom-then-regenerate"
r61build "$g71"
g71_trim_docs "$g71"
"$NODE" update "$g71" >"$WORK/g71-update.out" 2>&1
g71rc=$?
"$NODE" finalize "$g71" >"$WORK/g71-finalize.out" 2>&1
[ "$g71rc" -eq 0 ] && [ -z "$(status_flags "$g71")" ] \
  && pass "groom fixture: the trimmed, finalized migrated node starts status-clean" \
  || fail "groom fixture: the trimmed, finalized migrated node starts status-clean ($(status_flags "$g71"))"

printf 'LEARNED_MAX_RULES=2\n' >>"$g71/.agent/scripts/status.conf"
g71_flagged=$(status_flags "$g71")
printf '%s\n' "$g71_flagged" | grep -q '^GROOM: rules/learned/ > 2 rules' \
  && pass "groom fixture: lowering LEARNED_MAX_RULES draws the learned-rules GROOM line" \
  || fail "groom fixture: lowering LEARNED_MAX_RULES draws the learned-rules GROOM line ($g71_flagged)"

g71r1=$(grep -lF 'First rule, flat' "$g71/.agent/rules/learned"/*.md)
g71r2=$(grep -lF 'nested sub-bullet' "$g71/.agent/rules/learned"/*.md)
g71r3=$(grep -lF 'multi paragraph' "$g71/.agent/rules/learned"/*.md)
g71r4=$(grep -lF 'Fourth rule, flat' "$g71/.agent/rules/learned"/*.md)

g71_idx_before=$(idx_snapshot "$g71/.agent/indexes")

[ "$(cat "$g71r4")" = '- [2026-01-04] Fourth rule, flat, last one.' ] \
  && pass "groom fixture: the record the pass does not touch is unchanged before grooming" \
  || fail "groom fixture: the record the pass does not touch is unchanged before grooming"

printf -- '- [2026-01-01] First rule, flat, folded with the nested-sub-bullet rule. Trigger: something.\n' >"$g71r1"
rm -f "$g71r2"
printf '\n## Gotchas\n\n- Third rule, multi paragraph, moved from rules/learned/.\n' >>"$g71/.agent/docs/area/sub.md"
rm -f "$g71r3"
subst "$g71/.agent/docs/architecture.md" '/### `area\/sub.md`/,/^$/ { /Read when/a\
- **Sections:** Gotchas
}'

g71_idx_after=$(idx_snapshot "$g71/.agent/indexes")
[ "$g71_idx_before" = "$g71_idx_after" ] \
  && pass "groom: a groomed record set republishes with no hand edit under .agent/indexes/" \
  || fail "groom: a groomed record set republishes with no hand edit under .agent/indexes/"

"$IDXSH" ensure --root "$g71" >"$WORK/g71-ensure.out" 2>&1
g71ensurerc=$?
[ "$g71ensurerc" -eq 0 ] && pass "groom fixture: index.sh ensure republishes after the record edits" \
  || fail "groom fixture: index.sh ensure republishes after the record edits (rc=$g71ensurerc)"
g71gen=$(sed -n 2p "$g71/.agent/indexes/current.md")
g71gendir="$g71/.agent/indexes/$g71gen"

grep -qF 'folded with the nested-sub-bullet rule' "$g71gendir"/rules-*.md \
  && ! grep -qF 'Second rule with a nested sub-bullet' "$g71gendir"/rules-*.md \
  && ! grep -qF 'Third rule, multi paragraph' "$g71gendir"/rules-*.md \
  && grep -qF 'Fourth rule, flat, last one.' "$g71gendir"/rules-*.md \
  && pass "groom fixture: the regenerated rules page carries the folded rule, not the deleted records' text" \
  || fail "groom fixture: the regenerated rules page carries the folded rule, not the deleted records' text"

g71_docs_target=$(grep -F 'area/sub.md' "$g71gendir"/routes-*.md | sed -n 's/.*READ: //p' | head -n1)
[ -n "$g71_docs_target" ] && [ -f "$g71/$g71_docs_target" ] && grep -qF 'Third rule, multi paragraph, moved from rules/learned/.' "$g71/$g71_docs_target" \
  && pass "groom fixture: the docs page's routing entry resolves to the doc carrying the moved rule" \
  || fail "groom fixture: the docs page's routing entry resolves to the doc carrying the moved rule"

g71_after_flags=$(status_flags "$g71")
[ -z "$g71_after_flags" ] \
  && pass "groom fixture: status.sh is clear once the fold, deletion, and move are done" \
  || fail "groom fixture: status.sh is clear once the fold, deletion, and move are done ($g71_after_flags)"

g72="$WORK/mig-groomed-base"
r61build "$g72"
g71_trim_docs "$g72"
sed "s/^  mode: ignore-all/  mode: track-shared/" "$g72/.agent/purpose.md" >"$g72/.agent/purpose.md.tmp"
mv "$g72/.agent/purpose.md.tmp" "$g72/.agent/purpose.md"
git -C "$g72" init -q
git -C "$g72" config user.name Tester
git -C "$g72" config user.email tester@example.invalid
git -C "$g72" add .agent
git -C "$g72" commit -qm initial
"$NODE" update "$g72" >/dev/null 2>&1
git -C "$g72" add -A
git -C "$g72" commit -qm "post-migration state"
"$NODE" finalize "$g72" >/dev/null 2>&1
git -C "$g72" add -A
git -C "$g72" commit -qm finalize --allow-empty
g72pre=$(git -C "$g72" symbolic-ref --short HEAD)

g72r1=$(grep -lF 'First rule, flat' "$g72/.agent/rules/learned"/*.md)
g72r2=$(grep -lF 'nested sub-bullet' "$g72/.agent/rules/learned"/*.md)
g72r4=$(grep -lF 'Fourth rule, flat' "$g72/.agent/rules/learned"/*.md)
g72r1rel=${g72r1#"$g72"/}
g72r2rel=${g72r2#"$g72"/}
g72r4rel=${g72r4#"$g72"/}

git -C "$g72" checkout -qb regroup "$g72pre"
printf -- '- [2026-01-01] First rule, flat, folded with the nested-sub-bullet rule. Trigger: something.\n' >"$g72/$g72r1rel"
git -C "$g72" rm -q "$g72r2rel"
git -C "$g72" commit -qam "groom: fold first and second learned rules into the earlier-dated record"

git -C "$g72" checkout -q "$g72pre"
git -C "$g72" checkout -qb otheredit "$g72pre"
printf -- '- [2026-01-04] Fourth rule, flat, independently reworded post-groom.\n' >"$g72/$g72r4rel"
git -C "$g72" commit -qam "independent edit to the fourth record"

git -C "$g72" checkout -qb merge-regroup "$g72pre"
git -C "$g72" merge -q --no-edit regroup >"$WORK/g72-merge1.out" 2>&1
g72mrc1=$?
git -C "$g72" merge -q --no-edit otheredit >"$WORK/g72-merge2.out" 2>&1
g72mrc2=$?
[ "$g72mrc1" -eq 0 ] && [ "$g72mrc2" -eq 0 ] \
  && pass "groom: a fold on one branch and an independent record edit on another merge with both changes" \
  || fail "groom: a fold on one branch and an independent record edit on another merge with both changes"

grep -qF 'folded with the nested-sub-bullet rule' "$g72/$g72r1rel" \
  && pass "groom: the fold's surviving record carries the folded content after the merge" \
  || fail "groom: the fold's surviving record carries the folded content after the merge"
[ ! -e "$g72/$g72r2rel" ] \
  && pass "groom: the record folded away stays deleted after the merge" \
  || fail "groom: the record folded away stays deleted after the merge"
grep -qF 'independently reworded post-groom' "$g72/$g72r4rel" \
  && pass "groom: the independently edited record's edit survives the merge" \
  || fail "groom: the independently edited record's edit survives the merge"

"$IDXSH" ensure --root "$g72" >/dev/null 2>&1
git -C "$g72" add -A
git -C "$g72" commit -qm "index refresh" --allow-empty
g72base=$(git -C "$g72" symbolic-ref --short HEAD)

[ -z "$(status_flags "$g72")" ] \
  && pass "groomed-node base: status.sh is clear once the groomed base is committed" \
  || fail "groomed-node base: status.sh is clear once the groomed base is committed ($(status_flags "$g72"))"

git -C "$g72" checkout -qb grecA "$g72base"
printf -- '- [2026-03-01] Branch A record, groomed base.\n' >"$g72/.agent/rules/learned/g72-branch-a.md"
git -C "$g72" add .agent/rules/learned/g72-branch-a.md
git -C "$g72" commit -qm "branch A record, groomed base"
git -C "$g72" checkout -q "$g72base"
git -C "$g72" checkout -qb grecB "$g72base"
printf -- '- [2026-03-02] Branch B record, groomed base.\n' >"$g72/.agent/rules/learned/g72-branch-b.md"
git -C "$g72" add .agent/rules/learned/g72-branch-b.md
git -C "$g72" commit -qm "branch B record, groomed base"
git -C "$g72" checkout -qb merge-ab "$g72base"
git -C "$g72" merge -q --no-edit grecA >/dev/null 2>&1
g72mrc3=$?
git -C "$g72" merge -q --no-edit grecB >/dev/null 2>&1
g72mrc4=$?
[ "$g72mrc3" -eq 0 ] && [ "$g72mrc4" -eq 0 ] \
  && pass "groomed node: two disjoint new records still merge clean" \
  || fail "groomed node: two disjoint new records still merge clean"
"$g72/.agent/scripts/index.sh" ensure --root "$g72" >/dev/null 2>&1
grep -qF 'Branch A record, groomed base.' "$g72/.agent/rules/learned.md" \
  && grep -qF 'Branch B record, groomed base.' "$g72/.agent/rules/learned.md" \
  && pass "groomed node: both merged records reach the regenerated aggregate" \
  || fail "groomed node: both merged records reach the regenerated aggregate"

git -C "$g72" checkout -q "$g72base"
g72cd_file=$(grep -lF 'Fourth rule, flat' "$g72/.agent/rules/learned"/*.md | head -n1)
g72cd_rel=${g72cd_file#"$g72"/}
git -C "$g72" checkout -qb geditC "$g72base"
printf -- '- [2026-01-04] Fourth rule, flat -- edited by C, groomed base.\n' >"$g72/$g72cd_rel"
git -C "$g72" commit -qam "branch C edit, groomed base"
git -C "$g72" checkout -qb geditD "$g72base"
printf -- '- [2026-01-04] Fourth rule, flat -- edited by D, groomed base.\n' >"$g72/$g72cd_rel"
git -C "$g72" commit -qam "branch D edit, groomed base"
git -C "$g72" checkout -qb merge-cd "$g72base"
git -C "$g72" merge -q --no-edit geditC >/dev/null 2>&1
g72mrc5=$?
git -C "$g72" merge -q --no-edit geditD >/dev/null 2>&1
g72mrc6=$?
[ "$g72mrc5" -eq 0 ] \
  && pass "groomed node: the first same-record edit still applies clean" \
  || fail "groomed node: the first same-record edit still applies clean"
[ "$g72mrc6" -ne 0 ] \
  && pass "groomed node: a second edit to the same record still conflicts rather than silently choosing a winner" \
  || fail "groomed node: a second edit to the same record still conflicts rather than silently choosing a winner"
git -C "$g72" merge --abort >/dev/null 2>&1

git -C "$g72" checkout -qb linear "$g72base"
printf -- '- [2026-03-03] Linear commit one, groomed base.\n' >"$g72/.agent/rules/learned/g72-linear-one.md"
git -C "$g72" add .agent/rules/learned/g72-linear-one.md
git -C "$g72" commit -qm "linear commit one, groomed base"
printf -- '- [2026-03-04] Linear commit two, groomed base.\n' >"$g72/.agent/rules/learned/g72-linear-two.md"
git -C "$g72" add .agent/rules/learned/g72-linear-two.md
git -C "$g72" commit -qm "linear commit two, groomed base"
"$g72/.agent/scripts/index.sh" ensure --root "$g72" >/dev/null 2>&1
grep -qF 'Linear commit one, groomed base.' "$g72/.agent/rules/learned.md" \
  && grep -qF 'Linear commit two, groomed base.' "$g72/.agent/rules/learned.md" \
  && pass "groomed node: both sequential commits' records still survive a linear replay" \
  || fail "groomed node: both sequential commits' records still survive a linear replay"

lrn73="$WORK/learn-fixture"
r61build "$lrn73"
"$NODE" update "$lrn73" >/dev/null 2>&1
LRN="$lrn73/.agent/scripts/learn.sh"

lrn73_memdir_snapshot() { find "$1/.agent/memory" -type f | sort | xargs shasum 2>/dev/null | sort; }
lrn73_mem_before=$(lrn73_memdir_snapshot "$lrn73")
cp "$lrn73/.agent/memory.md" "$WORK/lrn73-memory-md-before.md"

lrn73_before_ids=$(find "$lrn73/.agent/rules/learned" -maxdepth 1 -name '*.md' | sort)
lrn73_pick=$(printf '%s\n' "$lrn73_before_ids" | head -n1)

lrn73_dup_out=$("$LRN" lookup --file "$lrn73_pick" "$lrn73" 2>"$WORK/lrn73-lookup.err")
lrn73_dup_rc=$?
[ "$lrn73_dup_rc" -eq 0 ] && pass "learn.sh: lookup exits 0" || fail "learn.sh: lookup exits 0 (rc=$lrn73_dup_rc)"
printf '%s\n' "$lrn73_dup_out" | grep -qF "duplicate	$lrn73_pick	" \
  && pass "learn.sh: lookup reports a byte-identical record as duplicate" \
  || fail "learn.sh: lookup reports a byte-identical record as duplicate ($lrn73_dup_out)"

printf -- '- [2026-01-09] First rule, flat, reworded slightly. Trigger: something.\n' >"$WORK/lrn73-overlap-cand.md"
lrn73_ov_out=$("$LRN" lookup --file "$WORK/lrn73-overlap-cand.md" "$lrn73" 2>/dev/null)
lrn73_first=$(grep -l 'First rule, flat' "$lrn73"/.agent/rules/learned/*.md)
printf '%s\n' "$lrn73_ov_out" | grep -qF "overlap	$lrn73_first	" \
  && pass "learn.sh: lookup reports a near record as overlap" \
  || fail "learn.sh: lookup reports a near record as overlap ($lrn73_ov_out)"

printf -- '- [2026-01-10] Cache the compiled template before every render. Trigger: repeated recompilation.\n' >"$WORK/lrn73-new-cand.md"
lrn73_new_out=$("$LRN" new --file "$WORK/lrn73-new-cand.md" "$lrn73" 2>"$WORK/lrn73-new.err")
lrn73_new_rc=$?
[ "$lrn73_new_rc" -eq 0 ] && pass "learn.sh: new exits 0 on a well-formed, non-overlapping candidate" || fail "learn.sh: new exits 0 on a well-formed, non-overlapping candidate (rc=$lrn73_new_rc)"
lrn73_new_id=$(printf '%s\n' "$lrn73_new_out" | awk -F'\t' '{print $2}')
[ -f "$lrn73/.agent/rules/learned/$lrn73_new_id.md" ] && pass "learn.sh: new writes the record under its printed id" || fail "learn.sh: new writes the record under its printed id"
diff -q "$WORK/lrn73-new-cand.md" "$lrn73/.agent/rules/learned/$lrn73_new_id.md" >/dev/null 2>&1 \
  && pass "learn.sh: the written record is byte-identical to the candidate" \
  || fail "learn.sh: the written record is byte-identical to the candidate"

case "$lrn73_new_id" in
[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
  pass "learn.sh: new mints a 12-character lowercase-hex identity" ;;
*)
  fail "learn.sh: new mints a 12-character lowercase-hex identity ($lrn73_new_id)" ;;
esac

"$LRN" new --file "$WORK/lrn73-new-cand.md" "$lrn73" >"$WORK/lrn73-dup.out" 2>"$WORK/lrn73-dup.err"
lrn73_dupnew_rc=$?
[ "$lrn73_dupnew_rc" -eq 5 ] && pass "learn.sh: new refuses an exact duplicate at exit 5" || fail "learn.sh: new refuses an exact duplicate at exit 5 (rc=$lrn73_dupnew_rc)"
grep -qF "$lrn73_new_id.md" "$WORK/lrn73-dup.err" \
  && pass "learn.sh: the duplicate refusal names the record that already holds it" \
  || fail "learn.sh: the duplicate refusal names the record that already holds it"

"$LRN" new --file "$WORK/lrn73-overlap-cand.md" "$lrn73" >"$WORK/lrn73-ov.out" 2>"$WORK/lrn73-ov.err"
lrn73_ovnew_rc=$?
[ "$lrn73_ovnew_rc" -eq 4 ] && pass "learn.sh: new refuses a near candidate without --distinct-from at exit 4" || fail "learn.sh: new refuses a near candidate without --distinct-from at exit 4 (rc=$lrn73_ovnew_rc)"
lrn73_first=$(grep -l 'First rule, flat' "$lrn73"/.agent/rules/learned/*.md | head -n 1)
grep -qF "$lrn73_first" "$WORK/lrn73-ov.err" \
  && pass "learn.sh: the overlap refusal names the overlapping record" \
  || fail "learn.sh: the overlap refusal names the overlapping record"
lrn73_near=$(sed -n 's/^  .*\/\([0-9a-f]*\)\.md  .*/\1/p' "$WORK/lrn73-ov.err" | paste -sd, -)
lrn73_distinct_out=$("$LRN" new --file "$WORK/lrn73-overlap-cand.md" --distinct-from "$lrn73_near" "$lrn73" 2>"$WORK/lrn73-distinct.err")
lrn73_distinct_rc=$?
[ "$lrn73_distinct_rc" -eq 0 ] && pass "learn.sh: --distinct-from naming every listed record admits the candidate" || fail "learn.sh: --distinct-from naming every listed record admits the candidate (rc=$lrn73_distinct_rc)"
printf '%s\n' "$lrn73_distinct_out" | grep -qE '^written	' \
  && pass "learn.sh: a --distinct-from write's result line starts with written" \
  || fail "learn.sh: a --distinct-from write's result line starts with written ($lrn73_distinct_out)"

printf -- '- [2026-02-01] Use C for the embedded firmware module because of strict size constraints.\n' >"$WORK/lrn73-c.md"
printf -- '- [2026-02-02] Use C++ for the embedded firmware module because of strict size constraints.\n' >"$WORK/lrn73-cpp.md"
lrn73_c_out=$("$LRN" new --file "$WORK/lrn73-c.md" "$lrn73" 2>/dev/null)
lrn73_c_id=$(printf '%s\n' "$lrn73_c_out" | awk -F'\t' '{print $2}')
"$LRN" new --file "$WORK/lrn73-cpp.md" "$lrn73" >/dev/null 2>"$WORK/lrn73-cpp-noflag.err"
lrn73_cpp_noflag_rc=$?
[ "$lrn73_cpp_noflag_rc" -eq 4 ] \
  && pass "learn.sh: C and C++ overlap on every other term, so the second create needs --distinct-from" \
  || fail "learn.sh: C and C++ overlap on every other term, so the second create needs --distinct-from (rc=$lrn73_cpp_noflag_rc)"
lrn73_cpp_out=$("$LRN" new --file "$WORK/lrn73-cpp.md" --distinct-from "$lrn73_c_id" "$lrn73" 2>/dev/null)
lrn73_cpp_id=$(printf '%s\n' "$lrn73_cpp_out" | awk -F'\t' '{print $2}')
[ -n "$lrn73_c_id" ] && [ -n "$lrn73_cpp_id" ] && [ "$lrn73_c_id" != "$lrn73_cpp_id" ] \
  && pass "learn.sh: C and C++ mint two distinct identities, neither overwriting the other" \
  || fail "learn.sh: C and C++ mint two distinct identities, neither overwriting the other (c=$lrn73_c_id cpp=$lrn73_cpp_id)"
[ -f "$lrn73/.agent/rules/learned/$lrn73_c_id.md" ] && [ -f "$lrn73/.agent/rules/learned/$lrn73_cpp_id.md" ] \
  && pass "learn.sh: both the C and C++ records exist on disk" \
  || fail "learn.sh: both the C and C++ records exist on disk"

lrn73_v0=$(git hash-object --no-filters -- "$lrn73/.agent/rules/learned/$lrn73_new_id.md")
printf -- '- [2026-01-11] A brand-new rule, reworded. Trigger: a completely different cause.\n' >"$WORK/lrn73-revise-cand.md"
lrn73_rev_out=$("$LRN" revise "$lrn73_new_id" --file "$WORK/lrn73-revise-cand.md" --expected "$lrn73_v0" "$lrn73" 2>"$WORK/lrn73-rev.err")
lrn73_rev_rc=$?
[ "$lrn73_rev_rc" -eq 0 ] && pass "learn.sh: revise exits 0 against a fresh --expected" || fail "learn.sh: revise exits 0 against a fresh --expected (rc=$lrn73_rev_rc)"
printf '%s\n' "$lrn73_rev_out" | grep -qF "revised	$lrn73_new_id	" \
  && pass "learn.sh: revise's result line names the same id" \
  || fail "learn.sh: revise's result line names the same id ($lrn73_rev_out)"
[ -f "$lrn73/.agent/rules/learned/$lrn73_new_id.md" ] \
  && pass "learn.sh: revise keeps the record's filename — its identity" \
  || fail "learn.sh: revise keeps the record's filename — its identity"
diff -q "$WORK/lrn73-revise-cand.md" "$lrn73/.agent/rules/learned/$lrn73_new_id.md" >/dev/null 2>&1 \
  && pass "learn.sh: revise's record holds the new wording and Trigger clause" \
  || fail "learn.sh: revise's record holds the new wording and Trigger clause"
lrn73_v1=$(git hash-object --no-filters -- "$lrn73/.agent/rules/learned/$lrn73_new_id.md")

printf -- '- [2026-01-13] A stale racer with its own distinct wording. Trigger: an old version.\n' >"$WORK/lrn73-stale-cand.md"
"$LRN" revise "$lrn73_new_id" --file "$WORK/lrn73-stale-cand.md" --expected "$lrn73_v0" "$lrn73" >"$WORK/lrn73-stale.out" 2>"$WORK/lrn73-stale.err"
lrn73_stale_rc=$?
[ "$lrn73_stale_rc" -eq 3 ] && pass "learn.sh: revise against a stale --expected refuses at exit 3" || fail "learn.sh: revise against a stale --expected refuses at exit 3 (rc=$lrn73_stale_rc)"
grep -qF "$lrn73_v1" "$WORK/lrn73-stale.err" \
  && pass "learn.sh: the stale refusal prints the current version" \
  || fail "learn.sh: the stale refusal prints the current version ($(cat "$WORK/lrn73-stale.err"))"
diff -q "$WORK/lrn73-revise-cand.md" "$lrn73/.agent/rules/learned/$lrn73_new_id.md" >/dev/null 2>&1 \
  && pass "learn.sh: a stale revise leaves the record byte-identical to the first revise's bytes" \
  || fail "learn.sh: a stale revise leaves the record byte-identical to the first revise's bytes"

printf -- '- [2026-01-12] A second racer, also carrying the old version. Trigger: a lost update.\n' >"$WORK/lrn73-lost-cand.md"
"$LRN" revise "$lrn73_new_id" --file "$WORK/lrn73-lost-cand.md" --expected "$lrn73_v0" "$lrn73" >/dev/null 2>"$WORK/lrn73-lost.err"
lrn73_lost_rc=$?
[ "$lrn73_lost_rc" -eq 3 ] \
  && pass "learn.sh: a second revise carrying the version the first one consumed also loses" \
  || fail "learn.sh: a second revise carrying the version the first one consumed also loses (rc=$lrn73_lost_rc)"
diff -q "$WORK/lrn73-revise-cand.md" "$lrn73/.agent/rules/learned/$lrn73_new_id.md" >/dev/null 2>&1 \
  && pass "learn.sh: the record still holds the first revise's bytes after the lost update" \
  || fail "learn.sh: the record still holds the first revise's bytes after the lost update"

"$LRN" revise "$lrn73_new_id" --file "$lrn73/.agent/rules/learned/$lrn73_new_id.md" --expected "$lrn73_v1" "$lrn73" >/dev/null 2>"$WORK/lrn73-revdup.err"
lrn73_revdup_rc=$?
[ "$lrn73_revdup_rc" -eq 5 ] \
  && pass "learn.sh: a revise whose body equals the record it targets refuses at exit 5" \
  || fail "learn.sh: a revise whose body equals the record it targets refuses at exit 5 (rc=$lrn73_revdup_rc)"

lrn73_absent_id="deadbeefcafe"
printf -- '- [2026-01-18] A candidate for an id nothing has written yet. Trigger: an absent target.\n' >"$WORK/lrn73-absent-cand.md"
lrn73_absent_before_count=$(find "$lrn73/.agent/rules/learned" -maxdepth 1 -name '*.md' | wc -l | tr -d '[:space:]')
"$LRN" revise "$lrn73_absent_id" --file "$WORK/lrn73-absent-cand.md" --expected absent "$lrn73" >/dev/null 2>"$WORK/lrn73-revabsent.err"
lrn73_revabsent_rc=$?
[ "$lrn73_revabsent_rc" -eq 2 ] \
  && pass "learn.sh: revise against a nonexistent id with --expected absent refuses at exit 2" \
  || fail "learn.sh: revise against a nonexistent id with --expected absent refuses at exit 2 (rc=$lrn73_revabsent_rc)"
lrn73_absent_after_count=$(find "$lrn73/.agent/rules/learned" -maxdepth 1 -name '*.md' | wc -l | tr -d '[:space:]')
[ ! -f "$lrn73/.agent/rules/learned/$lrn73_absent_id.md" ] && [ "$lrn73_absent_before_count" -eq "$lrn73_absent_after_count" ] \
  && pass "learn.sh: the absent-id revise writes no new record file under rules/learned/" \
  || fail "learn.sh: the absent-id revise writes no new record file under rules/learned/ (before=$lrn73_absent_before_count after=$lrn73_absent_after_count)"

lrn73_before_count=$(find "$lrn73/.agent/rules/learned" -maxdepth 1 -name '*.md' | wc -l | tr -d '[:space:]')
printf -- 'No date stamp at all.\n' >"$WORK/lrn73-bad-nodate.md"
"$LRN" new --file "$WORK/lrn73-bad-nodate.md" "$lrn73" >/dev/null 2>&1
[ "$?" -eq 6 ] && pass "learn.sh: a candidate with no date stamp refuses at exit 6" || fail "learn.sh: a candidate with no date stamp refuses at exit 6"
printf -- '- [2026-01-13] One.\n- [2026-01-14] Two.\n' >"$WORK/lrn73-bad-twobullet.md"
"$LRN" new --file "$WORK/lrn73-bad-twobullet.md" "$lrn73" >/dev/null 2>&1
[ "$?" -eq 6 ] && pass "learn.sh: a candidate with a second top-level bullet refuses at exit 6" || fail "learn.sh: a candidate with a second top-level bullet refuses at exit 6"
printf -- '---\ndate: 2026-01-01\n---\nbody\n' >"$WORK/lrn73-bad-frontmatter.md"
"$LRN" new --file "$WORK/lrn73-bad-frontmatter.md" "$lrn73" >/dev/null 2>&1
[ "$?" -eq 6 ] && pass "learn.sh: a candidate carrying a frontmatter block refuses at exit 6" || fail "learn.sh: a candidate carrying a frontmatter block refuses at exit 6"
printf -- '- [2026-01-15] A rule.\n# A heading\n' >"$WORK/lrn73-bad-heading.md"
"$LRN" new --file "$WORK/lrn73-bad-heading.md" "$lrn73" >/dev/null 2>&1
[ "$?" -eq 6 ] && pass "learn.sh: a candidate carrying a heading refuses at exit 6" || fail "learn.sh: a candidate carrying a heading refuses at exit 6"
lrn73_after_count=$(find "$lrn73/.agent/rules/learned" -maxdepth 1 -name '*.md' | wc -l | tr -d '[:space:]')
[ "$lrn73_before_count" -eq "$lrn73_after_count" ] \
  && pass "learn.sh: every malformed candidate above wrote nothing" \
  || fail "learn.sh: every malformed candidate above wrote nothing (before=$lrn73_before_count after=$lrn73_after_count)"

lrn73_long=$(awk 'BEGIN { for (i = 1; i <= 45; i++) printf "word "; print "." }')
printf -- '- [2026-01-16] %s\n' "$lrn73_long" >"$WORK/lrn73-long.md"
"$LRN" new --file "$WORK/lrn73-long.md" "$lrn73" >"$WORK/lrn73-long.out" 2>"$WORK/lrn73-long.err"
lrn73_long_rc=$?
[ "$lrn73_long_rc" -eq 0 ] && pass "learn.sh: an over-length imperative still writes" || fail "learn.sh: an over-length imperative still writes (rc=$lrn73_long_rc)"
[ -s "$WORK/lrn73-long.err" ] && fail "learn.sh: an over-length imperative prints no line that asks for a second write" || pass "learn.sh: an over-length imperative prints no line that asks for a second write"

printf -- '- [2026-01-17] Some other-surface candidate.\n' >"$WORK/lrn73-surf.md"
"$LRN" new --file "$WORK/lrn73-surf.md" --surface memory "$lrn73" >/dev/null 2>"$WORK/lrn73-surf-mem.err"
lrn73_surfmem_rc=$?
[ "$lrn73_surfmem_rc" -eq 7 ] && pass "learn.sh: --surface memory refuses at exit 7" || fail "learn.sh: --surface memory refuses at exit 7 (rc=$lrn73_surfmem_rc)"
grep -qF 'memory.sh' "$WORK/lrn73-surf-mem.err" \
  && pass "learn.sh: the memory-surface refusal names memory.sh" \
  || fail "learn.sh: the memory-surface refusal names memory.sh"
"$LRN" new --file "$WORK/lrn73-surf.md" --surface docs "$lrn73" >/dev/null 2>"$WORK/lrn73-surf-docs.err"
lrn73_surfdocs_rc=$?
[ "$lrn73_surfdocs_rc" -eq 7 ] && pass "learn.sh: --surface docs refuses at exit 7" || fail "learn.sh: --surface docs refuses at exit 7 (rc=$lrn73_surfdocs_rc)"
grep -qF 'docs.sh' "$WORK/lrn73-surf-docs.err" \
  && pass "learn.sh: the docs-surface refusal names docs.sh" \
  || fail "learn.sh: the docs-surface refusal names docs.sh"
"$LRN" new --file "$WORK/lrn73-surf.md" --surface gotchas "$lrn73" >/dev/null 2>"$WORK/lrn73-surf-gotchas.err"
lrn73_surfgotchas_rc=$?
[ "$lrn73_surfgotchas_rc" -eq 7 ] && pass "learn.sh: --surface gotchas refuses at exit 7" || fail "learn.sh: --surface gotchas refuses at exit 7 (rc=$lrn73_surfgotchas_rc)"

lrn73_retire_v=$(git hash-object --no-filters -- "$lrn73/.agent/rules/learned/$lrn73_c_id.md")
"$LRN" retire "$lrn73_c_id" --expected old-and-wrong --enforced-by .agent/rules/contract.md "$lrn73" >/dev/null 2>"$WORK/lrn73-retire-stale.err"
lrn73_retirestale_rc=$?
[ "$lrn73_retirestale_rc" -eq 3 ] && pass "learn.sh: retire against a stale --expected refuses at exit 3" || fail "learn.sh: retire against a stale --expected refuses at exit 3 (rc=$lrn73_retirestale_rc)"
[ -f "$lrn73/.agent/rules/learned/$lrn73_c_id.md" ] \
  && pass "learn.sh: a stale retire leaves the record in place" \
  || fail "learn.sh: a stale retire leaves the record in place"
lrn73_retire_out=$("$LRN" retire "$lrn73_c_id" --expected "$lrn73_retire_v" --enforced-by .agent/rules/contract.md "$lrn73" 2>"$WORK/lrn73-retire.err")
lrn73_retire_rc=$?
[ "$lrn73_retire_rc" -eq 0 ] && pass "learn.sh: retire exits 0 against a fresh --expected" || fail "learn.sh: retire exits 0 against a fresh --expected (rc=$lrn73_retire_rc)"
printf '%s\n' "$lrn73_retire_out" | grep -qF "retired	$lrn73_c_id" \
  && pass "learn.sh: retire prints retired with the id" \
  || fail "learn.sh: retire prints retired with the id ($lrn73_retire_out)"
[ ! -f "$lrn73/.agent/rules/learned/$lrn73_c_id.md" ] && pass "learn.sh: retire removes the record from disk" || fail "learn.sh: retire removes the record from disk"

lrn73_mem_after=$(lrn73_memdir_snapshot "$lrn73")
[ "$lrn73_mem_before" = "$lrn73_mem_after" ] \
  && pass "learn.sh: memory/ is byte-identical before and after every fixture command above" \
  || fail "learn.sh: memory/ is byte-identical before and after every fixture command above"
diff -q "$WORK/lrn73-memory-md-before.md" "$lrn73/.agent/memory.md" >/dev/null 2>&1 \
  && pass "learn.sh: memory.md is byte-identical before and after every fixture command above" \
  || fail "learn.sh: memory.md is byte-identical before and after every fixture command above"

lrn73_manual="$WORK/learn-manual"
mkdir -p "$lrn73_manual"
"$NODE" init --preset software-development --mode ignore-all "$lrn73_manual" >/dev/null 2>&1
LRNM="$lrn73_manual/.agent/scripts/learn.sh"
printf -- '- [2026-01-01] A manual-mode candidate.\n' >"$WORK/lrn73-manual-cand.md"
cp "$lrn73_manual/.agent/rules/learned.md" "$WORK/lrn73-manual-learned-before.md"

"$LRNM" lookup --file "$WORK/lrn73-manual-cand.md" "$lrn73_manual" >/dev/null 2>&1
[ "$?" -eq 0 ] \
  && pass "learn.sh: lookup on a manual-mode node still exits 0 with nothing to compare against" \
  || fail "learn.sh: lookup on a manual-mode node still exits 0 with nothing to compare against"

"$LRNM" new --file "$WORK/lrn73-manual-cand.md" "$lrn73_manual" >/dev/null 2>"$WORK/lrn73-manual-new.err"
lrn73_manualnew_rc=$?
[ "$lrn73_manualnew_rc" -eq 7 ] \
  && pass "learn.sh: new on a manual-mode node with no rules/learned/ refuses at exit 7" \
  || fail "learn.sh: new on a manual-mode node with no rules/learned/ refuses at exit 7 (rc=$lrn73_manualnew_rc)"
grep -qF 'rules/learned.md' "$WORK/lrn73-manual-new.err" \
  && pass "learn.sh: the manual-mode refusal names rules/learned.md as the node's surface" \
  || fail "learn.sh: the manual-mode refusal names rules/learned.md as the node's surface"

lrn73_gen="$WORK/learn-fresh-generated"
mkdir -p "$lrn73_gen"
"$NODE" init --preset software-development --mode track-all --indexes generated "$lrn73_gen" >/dev/null 2>&1
finish_bootstrap "$lrn73_gen"
git -C "$lrn73_gen" init -q 2>/dev/null
LRNG="$lrn73_gen/.agent/scripts/learn.sh"
printf -- '- [2026-01-02] Never retry a payment POST without an idempotency key.\n' >"$WORK/lrn73-gen-cand.md"
[ ! -e "$lrn73_gen/.agent/rules/learned" ] \
  && pass "learn.sh: a fresh generated-mode init has no rules/learned/ directory yet" \
  || fail "learn.sh: a fresh generated-mode init has no rules/learned/ directory yet"
"$LRNG" new --file "$WORK/lrn73-gen-cand.md" "$lrn73_gen" >"$WORK/lrn73-gen-new.out" 2>"$WORK/lrn73-gen-new.err"
lrn73_gennew_rc=$?
lrn73_gen_records=$(find "$lrn73_gen/.agent/rules/learned" -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' ')
[ "$lrn73_gennew_rc" -eq 0 ] && [ "$lrn73_gen_records" -eq 1 ] \
  && pass "learn.sh: the first new on a fresh generated-mode node creates rules/learned/ and writes one record" \
  || fail "learn.sh: the first new on a fresh generated-mode node creates rules/learned/ and writes one record (rc=$lrn73_gennew_rc records=$lrn73_gen_records; $(cat "$WORK/lrn73-gen-new.err"))"
grep -qF 'idempotency key' "$lrn73_gen/.agent/rules/learned.md" \
  && pass "learn.sh: the regenerated rules/learned.md carries the first record after the write" \
  || fail "learn.sh: the regenerated rules/learned.md carries the first record after the write"
lrn73_gen_untracked=$(git -C "$lrn73_gen" status --porcelain --untracked-files=all -- .agent/rules/learned 2>/dev/null | grep -c '\.md$')
[ "${lrn73_gen_untracked:-0}" -eq 1 ] \
  && pass "learn.sh: the first record on a generated node is visible to git, unlike the ignored aggregate" \
  || fail "learn.sh: the first record on a generated node is visible to git, unlike the ignored aggregate (untracked=$lrn73_gen_untracked)"

"$LRNM" revise deadbeefcafe --file "$WORK/lrn73-manual-cand.md" --expected absent "$lrn73_manual" >/dev/null 2>&1
[ "$?" -eq 7 ] \
  && pass "learn.sh: revise on a manual-mode node with no rules/learned/ refuses at exit 7" \
  || fail "learn.sh: revise on a manual-mode node with no rules/learned/ refuses at exit 7"
"$LRNM" retire deadbeefcafe --expected absent --enforced-by .agent/rules/contract.md "$lrn73_manual" >/dev/null 2>&1
[ "$?" -eq 7 ] \
  && pass "learn.sh: retire on a manual-mode node with no rules/learned/ refuses at exit 7" \
  || fail "learn.sh: retire on a manual-mode node with no rules/learned/ refuses at exit 7"

diff -q "$WORK/lrn73-manual-learned-before.md" "$lrn73_manual/.agent/rules/learned.md" >/dev/null 2>&1 \
  && pass "learn.sh: rules/learned.md is byte-identical after every refused write on a manual-mode node" \
  || fail "learn.sh: rules/learned.md is byte-identical after every refused write on a manual-mode node"
[ ! -e "$lrn73_manual/.agent/rules/learned" ] \
  && pass "learn.sh: a manual-mode node still has no rules/learned/ directory after these refusals" \
  || fail "learn.sh: a manual-mode node still has no rules/learned/ directory after these refusals"

lrn73_boot_hits=$(grep -l 'learn\.sh' \
  "$reporoot/templates/entry-point.md" "$reporoot/templates/entry-point-generated.md" \
  "$reporoot/scripts/status.sh" "$reporoot/scripts/checkpoint.sh" 2>/dev/null)
[ -z "$lrn73_boot_hits" ] \
  && pass "learn.sh: no entry-point template, status.sh, or checkpoint.sh path invokes it" \
  || fail "learn.sh: no entry-point template, status.sh, or checkpoint.sh path invokes it ($lrn73_boot_hits)"

lrn73_wire_init="$WORK/learn-wire-init"
mkdir -p "$lrn73_wire_init"
"$NODE" init --preset software-development --mode ignore-all "$lrn73_wire_init" >/dev/null 2>&1
[ -x "$lrn73_wire_init/.agent/scripts/learn.sh" ] && pass "learn.sh: init installs it executable" || fail "learn.sh: init installs it executable"

lrn73_wire_update="$WORK/learn-wire-update"
mkdir -p "$lrn73_wire_update"
make_v6_fixture "$lrn73_wire_update"
"$NODE" update "$lrn73_wire_update" >"$WORK/lrn73-wire-update.out" 2>&1
[ -x "$lrn73_wire_update/.agent/scripts/learn.sh" ] \
  && pass "learn.sh: update installs it executable into an existing node" \
  || fail "learn.sh: update installs it executable into an existing node"
grep -qF 'learn.sh' "$WORK/lrn73-wire-update.out" \
  && pass "learn.sh: update's refreshed-scripts line names it" \
  || fail "learn.sh: update's refreshed-scripts line names it"

xc74_loop_line=$(awk '
  /Refresh the shipped scripts from the source repo/ { f = 1 }
  f && /^  for script in / { print; exit }
' "$reporoot/scripts/node.sh")
xc74_names=$(printf '%s\n' "$xc74_loop_line" | sed -E 's/^[[:space:]]*for script in (.*); do$/\1/')
xc74_missing=""
for xc74_s in $xc74_names; do
  grep -qF "\`$xc74_s\`" "$reporoot/scripts/docs/README.md" || xc74_missing="$xc74_missing $xc74_s"
done
[ -z "$xc74_missing" ] \
  && pass "docs: every script node.sh's update loop refreshes is named in scripts/docs/README.md" \
  || fail "docs: every script node.sh's update loop refreshes is named in scripts/docs/README.md (missing:$xc74_missing)"

rec75="$WORK/reconcile-fixture"
mkdir -p "$rec75"
make_v6_fixture "$rec75"
rec75_modeline=$(grep -n '^  mode:' "$rec75/.agent/purpose.md" | head -1 | cut -d: -f1)
awk -v ln="$rec75_modeline" \
  'NR==ln { print; print "  indexes: generated        # manual | generated"; next } { print }' \
  "$rec75/.agent/purpose.md" >"$rec75/.agent/purpose.md.tmp"
mv "$rec75/.agent/purpose.md.tmp" "$rec75/.agent/purpose.md"

cat >"$rec75/.agent/rules/learned.md" <<'EOF'
# Learned rules

Binding rules distilled from operator corrections and failed verifications on this project.

<!-- Format: - [YYYY-MM-DD] <imperative rule>. Trigger: <cause, optional>. -->
- [2026-01-01] Flat merge-target rule. Trigger: something.
- [2026-01-02] Split-candidate rule with a nested sub-bullet. Trigger: x.
  - qualifier one
  - qualifier two
- [2026-01-03] Keep-candidate rule, multi paragraph.

  Continuation paragraph for the keep candidate.
- [2026-01-04] Merge-source rule, multi paragraph.

  Continuation paragraph for the merge source.
- [2026-01-05] Retire-candidate rule with a nested sub-bullet.
  - qualifier
EOF

mkdir -p "$rec75/.agent/docs"
cat >"$rec75/.agent/docs/architecture.md" <<'EOF'
# Architecture

### `dup.md`
- **Read when:** first dup entry.

### `dup.md`
- **Read when:** second dup entry.

### `badtable.md`
Hand-edited row with no bold marker: whatever hook text.
EOF
cat >"$rec75/.agent/docs/dup.md" <<'EOF'
# Dup

Body.
EOF
cat >"$rec75/.agent/docs/badtable.md" <<'EOF'
# Badtable

Body.
EOF
cat >"$rec75/.agent/docs/noentry.md" <<'EOF'
# Noentry

Body.
EOF

"$NODE" update "$rec75" >"$WORK/rec75-update.out" 2>&1
rec75_updrc=$?
[ "$rec75_updrc" -eq 0 ] && pass "reconcile fixture: generated-mode update exits 0" || fail "reconcile fixture: generated-mode update exits 0 (rc=$rec75_updrc)"

REC="$rec75/.agent/scripts/learn.sh"
RECDOCS="$rec75/.agent/scripts/docs.sh"
rec75_inv="$rec75/.agent/migration-inventory.md"
rec75_learned="$rec75/.agent/rules/learned"

rec75_flat=$(grep -lF 'Flat merge-target rule' "$rec75_learned"/*.md)
rec75_split=$(grep -lF 'Split-candidate rule' "$rec75_learned"/*.md)
rec75_keep=$(grep -lF 'Keep-candidate rule' "$rec75_learned"/*.md)
rec75_mergesrc=$(grep -lF 'Merge-source rule' "$rec75_learned"/*.md)
rec75_retire=$(grep -lF 'Retire-candidate rule' "$rec75_learned"/*.md)
rec75_flat_id=$(basename "$rec75_flat" .md)
rec75_split_id=$(basename "$rec75_split" .md)
rec75_keep_id=$(basename "$rec75_keep" .md)
rec75_mergesrc_id=$(basename "$rec75_mergesrc" .md)
rec75_retire_id=$(basename "$rec75_retire" .md)

rec75_label_for_id() {
  rli_line=$(grep -F "id=$2 | " "$1")
  rli_rest="${rli_line% | *}"
  printf '%s' "${rli_rest% | *}"
}

rec75_pending1=$("$REC" pending "$rec75")
rec75_split_label=$(rec75_label_for_id "$rec75_inv" "$rec75_split_id")
printf '%s\n' "$rec75_pending1" | grep -qF -- "$rec75_split_label | semantic-review-pending | $rec75_split_id | version=$(git hash-object --no-filters -- "$rec75_split")" \
  && pass "learn.sh pending: the split-candidate rule is listed with its label and a fresh version hash" \
  || fail "learn.sh pending: the split-candidate rule is listed with its label and a fresh version hash"
rec75_keep_label=$(rec75_label_for_id "$rec75_inv" "$rec75_keep_id")
printf '%s\n' "$rec75_pending1" | grep -qF -- "$rec75_keep_label | semantic-review-pending | $rec75_keep_id | version=$(git hash-object --no-filters -- "$rec75_keep")" \
  && pass "learn.sh pending: the keep-candidate rule is listed with its label and a fresh version hash" \
  || fail "learn.sh pending: the keep-candidate rule is listed with its label and a fresh version hash"
rec75_mergesrc_label=$(rec75_label_for_id "$rec75_inv" "$rec75_mergesrc_id")
printf '%s\n' "$rec75_pending1" | grep -qF -- "$rec75_mergesrc_label | semantic-review-pending | $rec75_mergesrc_id | version=$(git hash-object --no-filters -- "$rec75_mergesrc")" \
  && pass "learn.sh pending: the merge-source rule is listed with its label and a fresh version hash" \
  || fail "learn.sh pending: the merge-source rule is listed with its label and a fresh version hash"
rec75_retire_label=$(rec75_label_for_id "$rec75_inv" "$rec75_retire_id")
printf '%s\n' "$rec75_pending1" | grep -qF -- "$rec75_retire_label | semantic-review-pending | $rec75_retire_id | version=$(git hash-object --no-filters -- "$rec75_retire")" \
  && pass "learn.sh pending: the retire-candidate rule is listed with its label and a fresh version hash" \
  || fail "learn.sh pending: the retire-candidate rule is listed with its label and a fresh version hash"
rec75_dup_label=$(rec75_label_for_id "$rec75_inv" "dup.md")
printf '%s\n' "$rec75_pending1" | grep -qF -- "$rec75_dup_label | hook-missing | dup.md | version=-" \
  && pass "learn.sh pending: the duplicate-entry doc is listed with its label and version=-" \
  || fail "learn.sh pending: the duplicate-entry doc is listed with its label and version=-"
rec75_badtable_label=$(rec75_label_for_id "$rec75_inv" "badtable.md")
printf '%s\n' "$rec75_pending1" | grep -qF -- "$rec75_badtable_label | hook-missing | badtable.md | version=-" \
  && pass "learn.sh pending: the hand-edited-table doc is listed with its label" \
  || fail "learn.sh pending: the hand-edited-table doc is listed with its label"
rec75_noentry_label=$(rec75_label_for_id "$rec75_inv" "noentry.md")
printf '%s\n' "$rec75_pending1" | grep -qF -- "$rec75_noentry_label | hook-missing | noentry.md | version=-" \
  && pass "learn.sh pending: the no-entry doc is listed with its label" \
  || fail "learn.sh pending: the no-entry doc is listed with its label"
printf '%s\n' "$rec75_pending1" | grep -qF "$rec75_flat_id" \
  && fail "learn.sh pending: the already-migrated flat rule is never listed" \
  || pass "learn.sh pending: the already-migrated flat rule is never listed"
[ "$(printf '%s\n' "$rec75_pending1" | tail -n1)" = "7 pending" ] \
  && pass "learn.sh pending: closes with the exact count of pending items" \
  || fail "learn.sh pending: closes with the exact count of pending items ($(printf '%s\n' "$rec75_pending1" | tail -n1))"

rec75_split_v0=$(git hash-object --no-filters -- "$rec75_split")
printf -- '- [2026-01-02] Split-candidate rule, qualifier one only. Trigger: x.\n' >"$WORK/rec75-split-revise.md"
"$REC" revise "$rec75_split_id" --file "$WORK/rec75-split-revise.md" --expected "$rec75_split_v0" "$rec75" >"$WORK/rec75-split-revise.out" 2>"$WORK/rec75-split-revise.err"
rec75_split_rev_rc=$?
[ "$rec75_split_rev_rc" -eq 0 ] && pass "reconcile split: revising the original to its first qualifier exits 0" || fail "reconcile split: revising the original to its first qualifier exits 0 (rc=$rec75_split_rev_rc)"
printf -- '- [2026-01-02] Split-candidate rule, qualifier two only. Trigger: x.\n' >"$WORK/rec75-split-new.md"
rec75_split_near=$("$REC" new --file "$WORK/rec75-split-new.md" "$rec75" 2>&1 | sed -n 's/^  .*\/\([0-9a-f]*\)\.md  .*/\1/p' | paste -sd, -)
rec75_split_new_out=$("$REC" new --file "$WORK/rec75-split-new.md" --distinct-from "$rec75_split_near" "$rec75" 2>"$WORK/rec75-split-new.err")
rec75_split_new_rc=$?
[ "$rec75_split_new_rc" -eq 0 ] && pass "reconcile split: creating the second qualifier's record exits 0" || fail "reconcile split: creating the second qualifier's record exits 0 (rc=$rec75_split_new_rc)"
rec75_split_new_id=$(printf '%s\n' "$rec75_split_new_out" | awk -F'\t' '{print $2}')
[ -n "$rec75_split_new_id" ] && [ "$rec75_split_new_id" != "$rec75_split_id" ] \
  && pass "reconcile split: the second record mints a distinct identity" \
  || fail "reconcile split: the second record mints a distinct identity"
rec75_split_resolve_out=$("$REC" resolve --id "$rec75_split_id" --disposition "migrated (split into $rec75_split_new_id)" "$rec75" 2>"$WORK/rec75-split-resolve.err")
rec75_split_resolve_rc=$?
[ "$rec75_split_resolve_rc" -eq 0 ] && pass "reconcile split: resolve exits 0" || fail "reconcile split: resolve exits 0 (rc=$rec75_split_resolve_rc)"
printf '%s\n' "$rec75_split_resolve_out" | grep -qF "resolved	$rec75_split_id	migrated (split into $rec75_split_new_id)" \
  && pass "reconcile split: resolve's result line names the id and the new disposition" \
  || fail "reconcile split: resolve's result line names the id and the new disposition ($rec75_split_resolve_out)"
grep -qF "rule 2: \`- [2026-01-02] Split-candidate rule with a nested sub-bullet. Trigger: x\` -> rules/learned/$rec75_split_id.md | id=$rec75_split_id | migrated (split into $rec75_split_new_id)" "$rec75_inv" \
  && pass "reconcile split: the inventory line now reads migrated (split into ...), nothing else on it changed" \
  || fail "reconcile split: the inventory line now reads migrated (split into ...), nothing else on it changed"
[ -f "$rec75_learned/$rec75_split_id.md" ] && [ -f "$rec75_learned/$rec75_split_new_id.md" ] \
  && pass "reconcile split: both records exist on disk under different identities" \
  || fail "reconcile split: both records exist on disk under different identities"

rec75_flat_v0=$(git hash-object --no-filters -- "$rec75_flat")
cat >"$WORK/rec75-merge-revise.md" <<'EOF'
- [2026-01-01] Flat merge-target rule, now folded together with the merge source. Trigger: something.
EOF
"$REC" revise "$rec75_flat_id" --file "$WORK/rec75-merge-revise.md" --expected "$rec75_flat_v0" "$rec75" >"$WORK/rec75-merge-revise.out" 2>"$WORK/rec75-merge-revise.err"
rec75_merge_rev_rc=$?
[ "$rec75_merge_rev_rc" -eq 0 ] && pass "reconcile merge: revising the target to fold in the source exits 0" || fail "reconcile merge: revising the target to fold in the source exits 0 (rc=$rec75_merge_rev_rc)"
rec75_mergesrc_v0=$(git hash-object --no-filters -- "$rec75_mergesrc")
"$REC" retire "$rec75_mergesrc_id" --expected "$rec75_mergesrc_v0" --enforced-by ".agent/rules/learned/$rec75_flat_id.md" "$rec75" >"$WORK/rec75-merge-retire.out" 2>"$WORK/rec75-merge-retire.err"
rec75_merge_retire_rc=$?
[ "$rec75_merge_retire_rc" -eq 0 ] && pass "reconcile merge: retiring the source's own record exits 0" || fail "reconcile merge: retiring the source's own record exits 0 (rc=$rec75_merge_retire_rc)"
rec75_merge_resolve_out=$("$REC" resolve --id "$rec75_mergesrc_id" --disposition "migrated (merged into $rec75_flat_id)" "$rec75" 2>"$WORK/rec75-merge-resolve.err")
rec75_merge_resolve_rc=$?
[ "$rec75_merge_resolve_rc" -eq 0 ] && pass "reconcile merge: resolve exits 0" || fail "reconcile merge: resolve exits 0 (rc=$rec75_merge_resolve_rc)"
printf '%s\n' "$rec75_merge_resolve_out" | grep -qF "resolved	$rec75_mergesrc_id	migrated (merged into $rec75_flat_id)" \
  && pass "reconcile merge: resolve's result line names the id and the new disposition" \
  || fail "reconcile merge: resolve's result line names the id and the new disposition ($rec75_merge_resolve_out)"
grep -qF "id=$rec75_mergesrc_id | migrated (merged into $rec75_flat_id)" "$rec75_inv" \
  && pass "reconcile merge: the source's inventory line now reads migrated (merged into ...)" \
  || fail "reconcile merge: the source's inventory line now reads migrated (merged into ...)"
grep -qF "id=$rec75_flat_id | migrated" "$rec75_inv" \
  && pass "reconcile merge: the target's own inventory line is untouched" \
  || fail "reconcile merge: the target's own inventory line is untouched"
[ ! -f "$rec75_learned/$rec75_mergesrc_id.md" ] \
  && pass "reconcile merge: the source's record no longer exists on disk" \
  || fail "reconcile merge: the source's record no longer exists on disk"

rec75_inv_snapshot() { git hash-object --no-filters -- "$rec75_inv"; }

rec75_before=$(rec75_inv_snapshot)
"$REC" resolve --id "$rec75_keep_id" --disposition "migrated (split into deadbeefcafe)" "$rec75" >/dev/null 2>"$WORK/rec75-ref-noid.err"
[ "$?" -eq 2 ] && pass "reconcile refusal: naming an identity with no record file refuses at exit 2" || fail "reconcile refusal: naming an identity with no record file refuses at exit 2"
grep -qF 'deadbeefcafe' "$WORK/rec75-ref-noid.err" \
  && pass "reconcile refusal: the no-record refusal names the identity it checked" \
  || fail "reconcile refusal: the no-record refusal names the identity it checked"
[ "$(rec75_inv_snapshot)" = "$rec75_before" ] && pass "reconcile refusal: the no-record refusal writes nothing" || fail "reconcile refusal: the no-record refusal writes nothing"

rec75_before=$(rec75_inv_snapshot)
"$REC" resolve --id "$rec75_keep_id" --disposition retired "$rec75" >/dev/null 2>"$WORK/rec75-ref-existsretire.err"
[ "$?" -eq 2 ] && pass "reconcile refusal: retired on a rule item whose record still exists refuses at exit 2" || fail "reconcile refusal: retired on a rule item whose record still exists refuses at exit 2"
grep -qF 'still exists' "$WORK/rec75-ref-existsretire.err" \
  && pass "reconcile refusal: the still-exists refusal names what it checked" \
  || fail "reconcile refusal: the still-exists refusal names what it checked"
[ "$(rec75_inv_snapshot)" = "$rec75_before" ] && pass "reconcile refusal: the still-exists refusal writes nothing" || fail "reconcile refusal: the still-exists refusal writes nothing"

rec75_records_snapshot() { find "$1/.agent/rules/learned" -maxdepth 1 -name '*.md' 2>/dev/null | sort | xargs shasum 2>/dev/null | sort; }
rec75_docs_snapshot() { find "$1/.agent/docs" -type f 2>/dev/null | sort | xargs shasum 2>/dev/null | sort; }

cp "$rec75_keep" "$WORK/rec75-keep-before.md"
cp "$rec75_inv" "$WORK/rec75-inventory-before.md"
rec75_records_before=$(rec75_records_snapshot "$rec75")
rec75_docs_before=$(rec75_docs_snapshot "$rec75")
rec75_keep_resolve_out=$("$REC" resolve --id "$rec75_keep_id" --disposition migrated "$rec75" 2>"$WORK/rec75-keep-resolve.err")
rec75_keep_resolve_rc=$?
[ "$rec75_keep_resolve_rc" -eq 0 ] && pass "reconcile keep: resolve exits 0" || fail "reconcile keep: resolve exits 0 (rc=$rec75_keep_resolve_rc)"
printf '%s\n' "$rec75_keep_resolve_out" | grep -qF "resolved	$rec75_keep_id	migrated" \
  && pass "reconcile keep: resolve's result line names the id and migrated" \
  || fail "reconcile keep: resolve's result line names the id and migrated ($rec75_keep_resolve_out)"
grep -qF "id=$rec75_keep_id | migrated" "$rec75_inv" \
  && pass "reconcile keep: the inventory line now reads migrated" \
  || fail "reconcile keep: the inventory line now reads migrated"
diff -q "$WORK/rec75-keep-before.md" "$rec75_keep" >/dev/null 2>&1 \
  && pass "reconcile keep: the record is byte-identical before and after resolve" \
  || fail "reconcile keep: the record is byte-identical before and after resolve"

cp "$rec75_inv" "$WORK/rec75-inventory-after.md"
rec75_inv_before_line=$(grep -F "id=$rec75_keep_id " "$WORK/rec75-inventory-before.md")
rec75_inv_after_line=$(grep -F "id=$rec75_keep_id " "$WORK/rec75-inventory-after.md")
[ "${rec75_inv_before_line% | *}" = "${rec75_inv_after_line% | *}" ] \
  && pass "reconcile keep: the resolved line's label, location, and id fields are unchanged" \
  || fail "reconcile keep: the resolved line's label, location, and id fields are unchanged"
[ "${rec75_inv_before_line##* | }" != "${rec75_inv_after_line##* | }" ] \
  && pass "reconcile keep: only the text after the resolved line's last field changed" \
  || fail "reconcile keep: only the text after the resolved line's last field changed"
grep -vF "id=$rec75_keep_id " "$WORK/rec75-inventory-before.md" >"$WORK/rec75-inv-before-rest.md"
grep -vF "id=$rec75_keep_id " "$WORK/rec75-inventory-after.md" >"$WORK/rec75-inv-after-rest.md"
diff -q "$WORK/rec75-inv-before-rest.md" "$WORK/rec75-inv-after-rest.md" >/dev/null 2>&1 \
  && pass "reconcile keep: every other inventory line is byte-identical across the resolve" \
  || fail "reconcile keep: every other inventory line is byte-identical across the resolve"

rec75_records_after=$(rec75_records_snapshot "$rec75")
rec75_docs_after=$(rec75_docs_snapshot "$rec75")
[ "$rec75_records_before" = "$rec75_records_after" ] \
  && pass "reconcile keep: every record under rules/learned/ is byte-identical across the resolve" \
  || fail "reconcile keep: every record under rules/learned/ is byte-identical across the resolve"
[ "$rec75_docs_before" = "$rec75_docs_after" ] \
  && pass "reconcile keep: every doc under docs/ is byte-identical across the resolve" \
  || fail "reconcile keep: every doc under docs/ is byte-identical across the resolve"

rec75_retire_v0=$(git hash-object --no-filters -- "$rec75_retire")
"$REC" retire "$rec75_retire_id" --expected "$rec75_retire_v0" --enforced-by .agent/rules/contract.md "$rec75" >"$WORK/rec75-retire.out" 2>"$WORK/rec75-retire.err"
rec75_retire_rmrc=$?
[ "$rec75_retire_rmrc" -eq 0 ] && pass "reconcile retire: retiring the record exits 0" || fail "reconcile retire: retiring the record exits 0 (rc=$rec75_retire_rmrc)"
rec75_retire_resolve_out=$("$REC" resolve --id "$rec75_retire_id" --disposition retired "$rec75" 2>"$WORK/rec75-retire-resolve.err")
rec75_retire_resolve_rc=$?
[ "$rec75_retire_resolve_rc" -eq 0 ] && pass "reconcile retire: resolve exits 0" || fail "reconcile retire: resolve exits 0 (rc=$rec75_retire_resolve_rc)"
printf '%s\n' "$rec75_retire_resolve_out" | grep -qF "resolved	$rec75_retire_id	retired" \
  && pass "reconcile retire: resolve's result line names the id and retired" \
  || fail "reconcile retire: resolve's result line names the id and retired ($rec75_retire_resolve_out)"
grep -qF "id=$rec75_retire_id | retired" "$rec75_inv" \
  && pass "reconcile retire: the inventory line now reads retired" \
  || fail "reconcile retire: the inventory line now reads retired"

cat >"$rec75/.agent/docs/architecture.md" <<'EOF'
# Architecture

### `dup.md`
- **Read when:** first dup entry.

### `badtable.md`
- **Read when:** placeholder, to be set by rehook.

### `noentry.md`
- **Read when:** placeholder, to be set by rehook.
EOF
for rec75_doc in dup badtable noentry; do
  printf '<!-- Read when: placeholder, to be set by rehook. -->\n' >"$WORK/rec75-$rec75_doc.hdr"
  cat "$WORK/rec75-$rec75_doc.hdr" "$rec75/.agent/docs/$rec75_doc.md" >"$WORK/rec75-$rec75_doc.new"
  mv "$WORK/rec75-$rec75_doc.new" "$rec75/.agent/docs/$rec75_doc.md"
done
"$RECDOCS" rehook --name dup --read-when "reading about the duplicate entry" "$rec75" >"$WORK/rec75-rehook-dup.out" 2>&1
rec75_rehook_dup_rc=$?
"$RECDOCS" rehook --name badtable --read-when "reading about the hand-edited table" "$rec75" >"$WORK/rec75-rehook-badtable.out" 2>&1
rec75_rehook_badtable_rc=$?
"$RECDOCS" rehook --name noentry --read-when "reading about the doc with no entry" "$rec75" >"$WORK/rec75-rehook-noentry.out" 2>&1
rec75_rehook_noentry_rc=$?
[ "$rec75_rehook_dup_rc" -eq 0 ] && [ "$rec75_rehook_badtable_rc" -eq 0 ] && [ "$rec75_rehook_noentry_rc" -eq 0 ] \
  && pass "reconcile doc repair: docs.sh rehook succeeds on all three repaired docs" \
  || fail "reconcile doc repair: docs.sh rehook succeeds on all three repaired docs (rc=$rec75_rehook_dup_rc/$rec75_rehook_badtable_rc/$rec75_rehook_noentry_rc)"
for rec75_doc in dup badtable noentry; do
  [ "$(sed -n 1p "$rec75/.agent/docs/$rec75_doc.md")" != '<!-- Read when: placeholder, to be set by rehook. -->' ] \
    && pass "reconcile doc repair: $rec75_doc.md's header now reads the real hook text" \
    || fail "reconcile doc repair: $rec75_doc.md's header now reads the real hook text"
  "$REC" resolve --id "$rec75_doc.md" --disposition migrated "$rec75" >"$WORK/rec75-resolve-$rec75_doc.out" 2>"$WORK/rec75-resolve-$rec75_doc.err"
  rec75_doc_resolve_rc=$?
  [ "$rec75_doc_resolve_rc" -eq 0 ] \
    && pass "reconcile doc repair: resolve $rec75_doc.md to migrated exits 0" \
    || fail "reconcile doc repair: resolve $rec75_doc.md to migrated exits 0 (rc=$rec75_doc_resolve_rc)"
  grep -qF "id=$rec75_doc.md | migrated" "$rec75_inv" \
    && pass "reconcile doc repair: $rec75_doc.md's inventory line now reads migrated" \
    || fail "reconcile doc repair: $rec75_doc.md's inventory line now reads migrated"
done

rec75_before=$(rec75_inv_snapshot)
"$REC" resolve --id deadbeef0000 --disposition migrated "$rec75" >/dev/null 2>"$WORK/rec75-ref-absent.err"
[ "$?" -eq 2 ] && pass "reconcile refusal: an id the inventory does not carry refuses at exit 2" || fail "reconcile refusal: an id the inventory does not carry refuses at exit 2"
grep -qF 'carries no item with id=deadbeef0000' "$WORK/rec75-ref-absent.err" \
  && pass "reconcile refusal: the absent-id refusal names the id it checked" \
  || fail "reconcile refusal: the absent-id refusal names the id it checked"
[ "$(rec75_inv_snapshot)" = "$rec75_before" ] && pass "reconcile refusal: the absent-id refusal writes nothing" || fail "reconcile refusal: the absent-id refusal writes nothing"

"$REC" resolve --id "$rec75_keep_id" --disposition migrated "$rec75" >/dev/null 2>"$WORK/rec75-ref-already.err"
[ "$?" -eq 2 ] && pass "reconcile refusal: an item already resolved refuses at exit 2" || fail "reconcile refusal: an item already resolved refuses at exit 2"
grep -qF 'is not pending' "$WORK/rec75-ref-already.err" \
  && pass "reconcile refusal: the already-resolved refusal names the current disposition" \
  || fail "reconcile refusal: the already-resolved refusal names the current disposition"

rec75_2="$WORK/reconcile-fixture-2"
mkdir -p "$rec75_2"
make_v6_fixture "$rec75_2"
rec75_2_modeline=$(grep -n '^  mode:' "$rec75_2/.agent/purpose.md" | head -1 | cut -d: -f1)
awk -v ln="$rec75_2_modeline" \
  'NR==ln { print; print "  indexes: generated        # manual | generated"; next } { print }' \
  "$rec75_2/.agent/purpose.md" >"$rec75_2/.agent/purpose.md.tmp"
mv "$rec75_2/.agent/purpose.md.tmp" "$rec75_2/.agent/purpose.md"
mkdir -p "$rec75_2/.agent/docs"
cat >"$rec75_2/.agent/docs/noentry.md" <<'EOF'
# Noentry

Body.
EOF
"$NODE" update "$rec75_2" >"$WORK/rec75-2-update.out" 2>&1
REC2="$rec75_2/.agent/scripts/learn.sh"
rec75_2_inv="$rec75_2/.agent/migration-inventory.md"

rec75_2_before=$(git hash-object --no-filters -- "$rec75_2_inv")
"$REC2" resolve --id noentry.md --disposition retired "$rec75_2" >/dev/null 2>"$WORK/rec75-ref-docretired.err"
[ "$?" -eq 2 ] && pass "reconcile refusal: retired on a doc item refuses at exit 2" || fail "reconcile refusal: retired on a doc item refuses at exit 2"
grep -qF 'rule-only' "$WORK/rec75-ref-docretired.err" \
  && pass "reconcile refusal: the doc-retired refusal names the three forms as rule-only" \
  || fail "reconcile refusal: the doc-retired refusal names the three forms as rule-only"
[ "$(git hash-object --no-filters -- "$rec75_2_inv")" = "$rec75_2_before" ] \
  && pass "reconcile refusal: the doc-retired refusal writes nothing" \
  || fail "reconcile refusal: the doc-retired refusal writes nothing"

rec75_2_before=$(git hash-object --no-filters -- "$rec75_2_inv")
"$REC2" resolve --id noentry.md --disposition "migrated (split into deadbeefcafe)" "$rec75_2" >/dev/null 2>"$WORK/rec75-ref-docsplit.err"
[ "$?" -eq 2 ] && pass "reconcile refusal: split on a doc item refuses at exit 2" || fail "reconcile refusal: split on a doc item refuses at exit 2"
[ "$(git hash-object --no-filters -- "$rec75_2_inv")" = "$rec75_2_before" ] \
  && pass "reconcile refusal: the doc-split refusal writes nothing" \
  || fail "reconcile refusal: the doc-split refusal writes nothing"

rec75_2_before=$(git hash-object --no-filters -- "$rec75_2_inv")
"$REC2" resolve --id noentry.md --disposition "migrated (merged into deadbeefcafe)" "$rec75_2" >/dev/null 2>"$WORK/rec75-ref-docmerge.err"
[ "$?" -eq 2 ] && pass "reconcile refusal: merge on a doc item refuses at exit 2" || fail "reconcile refusal: merge on a doc item refuses at exit 2"
[ "$(git hash-object --no-filters -- "$rec75_2_inv")" = "$rec75_2_before" ] \
  && pass "reconcile refusal: the doc-merge refusal writes nothing" \
  || fail "reconcile refusal: the doc-merge refusal writes nothing"

rec75_2_before=$(git hash-object --no-filters -- "$rec75_2_inv")
"$REC2" resolve --id noentry.md --disposition migrated "$rec75_2" >/dev/null 2>"$WORK/rec75-ref-nohook.err"
[ "$?" -eq 2 ] && pass "reconcile refusal: migrated on a doc whose hook is still missing refuses at exit 2" || fail "reconcile refusal: migrated on a doc whose hook is still missing refuses at exit 2"
grep -qF 'still carries no' "$WORK/rec75-ref-nohook.err" \
  && pass "reconcile refusal: the still-missing-hook refusal names the predicate it checked" \
  || fail "reconcile refusal: the still-missing-hook refusal names the predicate it checked"
[ "$(git hash-object --no-filters -- "$rec75_2_inv")" = "$rec75_2_before" ] \
  && pass "reconcile refusal: the still-missing-hook refusal writes nothing" \
  || fail "reconcile refusal: the still-missing-hook refusal writes nothing"

cp "$rec75_2_inv" "$WORK/rec75-2-inv-before.md"
rec75_dupline=$(grep -F 'id=noentry.md' "$rec75_2_inv")
{ cat "$rec75_2_inv"; printf '%s\n' "$rec75_dupline"; } >"$WORK/rec75-2-inv-dup.md"
cp "$WORK/rec75-2-inv-dup.md" "$rec75_2_inv"
rec75_dupline_before=$(git hash-object --no-filters -- "$rec75_2_inv")
"$REC2" resolve --id noentry.md --disposition migrated "$rec75_2" >/dev/null 2>"$WORK/rec75-ref-dupline.err"
[ "$?" -eq 2 ] && pass "reconcile refusal: an id on more than one inventory line refuses at exit 2" || fail "reconcile refusal: an id on more than one inventory line refuses at exit 2"
grep -qF 'more than one line' "$WORK/rec75-ref-dupline.err" \
  && pass "reconcile refusal: the duplicate-line refusal names what it checked" \
  || fail "reconcile refusal: the duplicate-line refusal names what it checked"
[ "$(git hash-object --no-filters -- "$rec75_2_inv")" = "$rec75_dupline_before" ] \
  && pass "reconcile refusal: the duplicate-line refusal writes nothing" \
  || fail "reconcile refusal: the duplicate-line refusal writes nothing"
cp "$WORK/rec75-2-inv-before.md" "$rec75_2_inv"

rec75_noinv="$WORK/reconcile-no-inventory"
mkdir -p "$rec75_noinv"
"$NODE" init --preset software-development --mode ignore-all --indexes generated "$rec75_noinv" >/dev/null 2>&1
[ ! -f "$rec75_noinv/.agent/migration-inventory.md" ] \
  && pass "learn.sh pending: the no-inventory fixture genuinely carries no migration-inventory.md" \
  || fail "learn.sh pending: the no-inventory fixture genuinely carries no migration-inventory.md"
RECNOINV="$rec75_noinv/.agent/scripts/learn.sh"
rec75_noinv_pending_out=$("$RECNOINV" pending "$rec75_noinv" 2>"$WORK/rec75-noinv-pending.err")
rec75_noinv_pending_rc=$?
[ "$rec75_noinv_pending_rc" -eq 0 ] \
  && pass "learn.sh pending: a node with no migration-inventory.md exits 0" \
  || fail "learn.sh pending: a node with no migration-inventory.md exits 0 (rc=$rec75_noinv_pending_rc)"
[ -z "$rec75_noinv_pending_out" ] \
  && pass "learn.sh pending: a node with no migration-inventory.md prints nothing" \
  || fail "learn.sh pending: a node with no migration-inventory.md prints nothing ($rec75_noinv_pending_out)"

rec75_pending2=$("$REC" pending "$rec75")
rec75_pending2_rc=$?
[ "$rec75_pending2_rc" -eq 0 ] \
  && pass "learn.sh pending: a fully reconciled node's second run exits 0" \
  || fail "learn.sh pending: a fully reconciled node's second run exits 0 (rc=$rec75_pending2_rc)"
[ -z "$rec75_pending2" ] \
  && pass "learn.sh pending: a fully reconciled node's second run lists nothing" \
  || fail "learn.sh pending: a fully reconciled node's second run lists nothing ($rec75_pending2)"

rec75_snapshot() {
  { find "$1/.agent/rules/learned" -maxdepth 1 -name '*.md' 2>/dev/null; printf '%s\n' "$1/.agent/migration-inventory.md"; } \
    | sort | xargs shasum 2>/dev/null | sort
}
rec75_before_update=$(rec75_snapshot "$rec75")
"$NODE" update "$rec75" >"$WORK/rec75-update2.out" 2>&1
rec75_update2_rc=$?
rec75_after_update=$(rec75_snapshot "$rec75")
[ "$rec75_update2_rc" -eq 0 ] && pass "reconcile: a second node.sh update over the reconciled node exits 0" || fail "reconcile: a second node.sh update over the reconciled node exits 0 (rc=$rec75_update2_rc)"
[ "$rec75_before_update" = "$rec75_after_update" ] \
  && pass "reconcile: a second node.sh update rewrites no record and no inventory line, rules/learned.md aside" \
  || fail "reconcile: a second node.sh update rewrites no record and no inventory line, rules/learned.md aside"
