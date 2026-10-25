#!/usr/bin/env bash
# shellcheck disable=SC2034

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/review-v63-test.XXXXXX") || exit 1
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT HUP INT TERM

passes=0
failures=0
pass() { printf 'ok - %s\n' "$1"; passes=$((passes + 1)); }
fail() { printf 'not ok - %s\n' "$1"; failures=$((failures + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

bin="$tmp/bin"
mkdir -p "$bin"
cp "$repo_root/scripts/review.sh" "$repo_root/scripts/review.conf" \
  "$repo_root/scripts/comments.sh" "$repo_root/scripts/comments.conf" "$bin/"
chmod +x "$bin/review.sh" "$bin/comments.sh"

work="$tmp/work"
mkdir -p "$work/src" "$work/tests" "$work/.agents/docs"
git -C "$work" init -q
git -C "$work" config user.email test@example.invalid
git -C "$work" config user.name test
printf 'export const existing = 1;\n' >"$work/src/base.ts"
git -C "$work" add src/base.ts
git -C "$work" commit -qm base
base=$(git -C "$work" rev-parse HEAD)

set +e
noop_out=$("$bin/review.sh" --base HEAD --root "$work" 2>&1)
noop_rc=$?
set -e
check "zero-diff review fails closed" '[ "$noop_rc" -eq 2 ] && printf "%s" "$noop_out" | grep -q "diff is empty"'

printf 'export function committedHelper() { return 1; }\n' >"$work/src/committed.ts"
git -C "$work" add src/committed.ts
git -C "$work" commit -qm committed
printf 'export function stagedHelper() { return 2; }\n' >"$work/src/staged.ts"
printf 'stagedHelper();\n' >"$work/tests/staged.test.ts"
git -C "$work" add src/staged.ts tests/staged.test.ts
printf 'export function helperAdded() { return existing; }\n' >>"$work/src/base.ts"
printf 'helperAdded();\n' >"$work/tests/base.test.ts"
printf 'export function spacedHelper() { return 3; }\n' >"$work/src/path with space.ts"
printf '| helper | path |\n|---|---|\n| committedHelper | src/committed.ts |\n' >"$work/.agents/docs/api-catalog.md"

before_index=$(git -C "$work" write-tree)
before_status=$(git -C "$work" status --porcelain=v1)
set +e
review_out=$("$bin/review.sh" --base "$base" --root "$work" 2>&1)
review_rc=$?
set -e
after_index=$(git -C "$work" write-tree)
after_status=$(git -C "$work" status --porcelain=v1)
check "committed staged unstaged and untracked changes are inspected without staging" \
  '[ "$review_rc" -eq 0 ] && [ "$before_index" = "$after_index" ] && [ "$before_status" = "$after_status" ] && printf "%s" "$review_out" | grep -q "src/path with space.ts"'
check "new export in an existing file is a catalog candidate" \
  'printf "%s" "$review_out" | grep -q "REVIEW: CATALOG_CANDIDATE src/base.ts new helper .helperAdded."'
check "catalog text suppresses only the catalog candidate" \
  '! printf "%s" "$review_out" | grep "CATALOG_CANDIDATE src/committed.ts" >/dev/null && printf "%s" "$review_out" | grep -q "TEST_COVERAGE src/committed.ts"'
check "related changed test filename suppresses coverage candidate" \
  '! printf "%s" "$review_out" | grep "TEST_COVERAGE src/base.ts" >/dev/null && ! printf "%s" "$review_out" | grep "TEST_COVERAGE src/staged.ts" >/dev/null'
check "source without a related changed test gets an advisory" \
  'printf "%s" "$review_out" | grep -q "TEST_COVERAGE src/path with space.ts"'

sed 's/^MAX_FINDINGS=.*/MAX_FINDINGS=1/' "$bin/review.conf" >"$bin/review.conf.tmp"
mv "$bin/review.conf.tmp" "$bin/review.conf"
set +e
bounded_out=$("$bin/review.sh" --base "$base" --root "$work" 2>&1)
bounded_rc=$?
set -e
check "bounded review makes omitted findings visible" \
  '[ "$bounded_rc" -eq 0 ] && [ "$(printf "%s\n" "$bounded_out" | grep -c "^REVIEW: \(CATALOG_CANDIDATE\|TEST_COVERAGE\) ")" -eq 1 ] && printf "%s" "$bounded_out" | grep -q "^REVIEW: FINDINGS_TRUNCATED review.conf [1-9][0-9]* additional candidate(s) omitted by MAX_FINDINGS=1$"'

sed 's/^MAX_FINDINGS=.*/MAX_FINDINGS=0/' "$bin/review.conf" >"$bin/review.conf.tmp"
mv "$bin/review.conf.tmp" "$bin/review.conf"
set +e
zero_max_out=$("$bin/review.sh" --base "$base" --root "$work" 2>&1)
zero_max_rc=$?
set -e
check "MAX_FINDINGS zero is rejected instead of certifying clean" \
  '[ "$zero_max_rc" -eq 2 ] && printf "%s" "$zero_max_out" | grep -q "must be greater than zero"'
sed 's/^MAX_FINDINGS=.*/MAX_FINDINGS=20/' "$bin/review.conf" >"$bin/review.conf.tmp"
mv "$bin/review.conf.tmp" "$bin/review.conf"

set +e
bad_base_out=$("$bin/review.sh" --base refs/heads/does-not-exist --root "$work" 2>&1)
bad_base_rc=$?
set -e
check "missing base is a clear inspection failure" \
  '[ "$bad_base_rc" -eq 2 ] && printf "%s" "$bad_base_out" | grep -q "base ref.*not found"'

printf '// Build the rows\n' >>"$work/src/path with space.ts"
set +e
blocked_out=$("$bin/review.sh" --base "$base" --root "$work" 2>&1)
blocked_rc=$?
set -e
check "comment gate retains ownership of blocking status" \
  '[ "$blocked_rc" -eq 1 ] && printf "%s" "$blocked_out" | grep -q "^BLOCK:" && printf "%s" "$blocked_out" | grep -q "REVIEW: TEST_COVERAGE"'

node="$tmp/node"
mkdir -p "$node/.agents/scripts" "$node/.agents/rules" "$node/.agents/docs" "$node/.agents/memory"
cp "$repo_root/scripts/status.sh" "$node/.agents/scripts/status.sh"
cat >"$node/.agents/scripts/status.conf" <<'EOF'
PROBE_TOOLS=dot-agent-v63-missing-tool
MEMORY_MAX_WORDS=1
EOF
cat >"$node/.agents/session-log.md" <<'EOF'
- [2026-09-27] (test) fixture. verify: pass
EOF
cat >"$node/.agents/memory.md" <<'EOF'
- [fact](memory/fact.md) — fixture
EOF
printf 'several words in fact\n' >"$node/.agents/memory/fact.md"
cat >"$node/.agents/rules/contract.md" <<'EOF'
# Contract
## Project guardrails
- Test: true
EOF
printf '# Quality bar\n' >"$node/.agents/rules/quality-bar.md"
printf -- '- Keep the fixture deterministic.\n' >"$node/.agents/rules/learned.md"
cat >"$node/.agents/purpose.md" <<'EOF'
---
dot-agent:
  version: 6.3
  indexes: manual
---
# Purpose
EOF
cat >"$node/.agents/docs/fenced.md" <<'EOF'
<!-- Read when: testing fenced headings -->
# Fenced
## Real section

```markdown
## Example heading
```

~~~text
## Another example heading
~~~
EOF
cat >"$node/.agents/docs/architecture.md" <<'EOF'
# Architecture

### `fenced.md`
- **Read when:** testing fenced headings
- **Sections:** Real section
EOF

set +e
status_tsv=$(HOME="$tmp/home" bash "$repo_root/scripts/status.sh" --format tsv "$node" 2>&1)
status_rc=$?
set -e
check "size-only status finding is advisory with a stable code" \
  '[ "$status_rc" -eq 0 ] && printf "%s" "$status_tsv" | grep -q $'"'"'^advisory\tMEMORY_RECORD_OVERSIZE\tmemory/fact.md\t'"'"''
check "fenced example headings are not treated as routed sections" \
  '! printf "%s" "$status_tsv" | grep -q $'"'"'\tDOC_SECTIONS_MISSING\tdocs/fenced.md\t'"'"''
check "tool availability is omitted from findings-only TSV" \
  '! printf "%s" "$status_tsv" | grep -Eq $'"'"'\tTOOLS_(MISSING|BSD_SED)\t'"'"''
status_tools_text=$(HOME="$tmp/home" bash "$repo_root/scripts/status.sh" "$node")
check "tool availability remains in default status text" \
  'printf "%s" "$status_tools_text" | grep -q "^TOOLS: not installed: dot-agent-v63-missing-tool$"'

printf 'legacy migration payload\n' >"$node/.agents/memory/legacy.md"
legacy_tsv=$(HOME="$tmp/home" bash "$repo_root/scripts/status.sh" --format tsv "$node")
check "legacy unsplit memory is blocking migration state" \
  'printf "%s" "$legacy_tsv" | grep -q $'"'"'^block\tMEMORY_LEGACY_UNSPLIT\tmemory/legacy.md\t'"'"''
rm "$node/.agents/memory/legacy.md"

rm "$node/.agents/memory.md"
set +e
status_text=$(HOME="$tmp/home" bash "$repo_root/scripts/status.sh" "$node" 2>&1)
text_rc=$?
status_tsv=$(HOME="$tmp/home" bash "$repo_root/scripts/status.sh" --format tsv "$node" 2>&1)
tsv_rc=$?
set -e
check "default status text remains byte-compatible for canonical finding" \
  '[ "$text_rc" -eq 0 ] && printf "%s\n" "$status_text" | grep -qx "REPAIR: memory.md missing/empty"'
check "canonical status finding is blocking and coded" \
  '[ "$tsv_rc" -eq 0 ] && printf "%s" "$status_tsv" | grep -q $'"'"'^block\tCANONICAL_MEMORY_MISSING\tmemory.md\tmissing/empty$'"'"''
check "TSV contains findings only" \
  '! printf "%s" "$status_tsv" | grep -Eq "^(LOAD:|PAYLOAD:|- \[)"'

tab_doc=$'tab\tname.md'
printf '# Tab doc\n' >"$node/.agents/docs/$tab_doc"
escaped=$(HOME="$tmp/home" bash "$repo_root/scripts/status.sh" --format tsv "$node")
check "TSV escapes control characters in paths" \
  'printf "%s" "$escaped" | grep -Fq $'"'"'block\tDOC_HOOK_MISSING\tdocs/tab\\tname.md\t'"'"''

set +e
missing_root_out=$(bash "$repo_root/scripts/status.sh" "$tmp/no-node" 2>&1)
missing_root_rc=$?
combo_out=$(bash "$repo_root/scripts/status.sh" --format tsv --load "$node" 2>&1)
combo_rc=$?
set -e
check "status preserves usage-error exit code" '[ "$missing_root_rc" -eq 1 ]'
check "structured load refusal is clear" \
  '[ "$combo_rc" -eq 1 ] && printf "%s" "$combo_out" | grep -q "cannot be combined"'

printf '1..%d\n' "$((passes + failures))"
[ "$failures" -eq 0 ]
