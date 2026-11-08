#!/usr/bin/env bash
# shellcheck disable=SC2034

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/drift-v63-test.XXXXXX") || exit 1
tmp=$(cd "$tmp" && pwd -P)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT HUP INT TERM
# The non-git cases must not find a repository above the scratch directory.
export GIT_CEILING_DIRECTORIES="$tmp"

passes=0
failures=0
pass() { printf 'ok - %s\n' "$1"; passes=$((passes + 1)); }
fail() { printf 'not ok - %s\n' "$1"; failures=$((failures + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

proj="$tmp/proj"
mkdir -p "$proj"
bash "$repo_root/scripts/node.sh" init --preset software-development --mode track-all \
  --indexes generated --hooks none "$proj" >/dev/null 2>&1
DOCS="$proj/.agent/scripts/docs.sh"
LINKS="$proj/.agent/scripts/links.sh"
STATUS="$proj/.agent/scripts/status.sh"
g() { git -C "$proj" "$@"; }
commit() { g add -A && g commit -qm "$1"; }

g init -q
g config user.email test@example.invalid
g config user.name test
mkdir -p "$proj/src/util"
printf 'export const client = 1;\n' >"$proj/src/client.ts"
printf 'export const other = 1;\n' >"$proj/src/other.ts"
printf 'export const helper = 1;\n' >"$proj/src/util/helper.ts"
commit base
base=$(g rev-parse --short HEAD)

"$DOCS" new --name payments --read-when "touching payments" "$proj" >/dev/null 2>&1
pay="$proj/.agent/docs/payments.md"
check "docs.sh new stamps the doc at HEAD on the line after its Read when header" \
  '[ "$(sed -n 1p "$pay")" = "<!-- Read when: touching payments -->" ] && [ "$(sed -n 2p "$pay")" = "<!-- Checked: $base -->" ] && [ "$(sed -n 3p "$pay")" = "# Payments" ]'

cat >>"$pay" <<'EOF'

## Flow
The client lives in `src/client.ts:12`, helpers under [util](../../src/util/).
`src/other.ts` holds the rest. Routing: `docs/architecture.md`.
EOF
printf '%s\n' '<!-- Read when: legacy billing -->' '# Legacy' '' 'Calls `src/client.ts` directly.' >"$proj/.agent/docs/legacy.md"
"$DOCS" sync --name payments "$proj" >/dev/null 2>&1
"$DOCS" sync --name legacy "$proj" >/dev/null 2>&1
check "docs.sh sync keeps the stamp and the hook" \
  '[ "$(sed -n 2p "$pay")" = "<!-- Checked: $base -->" ] && grep -qF -- "- **Read when:** touching payments" "$proj/.agent/docs/architecture.md" && grep -qF -- "- **Sections:** Flow" "$proj/.agent/docs/architecture.md"'
"$DOCS" rehook --name payments --read-when "touching payments or refunds" "$proj" >/dev/null 2>&1
check "docs.sh rehook rewrites the hook and keeps the stamp" \
  '[ "$(sed -n 1p "$pay")" = "<!-- Read when: touching payments or refunds -->" ] && [ "$(sed -n 2p "$pay")" = "<!-- Checked: $base -->" ]'
status_out=$("$STATUS" "$proj" 2>&1)
check "status.sh routing and INDEX checks read a stamped doc cleanly" \
  '[ -n "$status_out" ] && ! printf "%s\n" "$status_out" | grep -q "^INDEX:"'
bash "$proj/.agent/scripts/index.sh" ensure --root "$proj" >/dev/null 2>&1
check "index.sh takes the hook and title of a stamped doc" \
  'grep -rqF -- "- Payments | touching payments or refunds | READ: .agent/docs/payments.md" "$proj/.agent/indexes"'
commit docs

out=$("$LINKS" "$proj" 2>&1)
rc=$?
check "untouched cited paths produce no STALE line" \
  '[ "$rc" -eq 0 ] && ! printf "%s\n" "$out" | grep -q "^STALE:"'
check "the drift summary counts stamped and unstamped docs" \
  'printf "%s\n" "$out" | grep -qF "drift check — 1 stamped docs, 1 unstamped, no cited project path changed"'
check "the stamp comment is not read as a citation" \
  '! printf "%s\n" "$out" | grep -qE "^BROKEN: \.agent/docs/|Checked"'

printf 'export const client = 2;\n' >"$proj/src/client.ts"
commit "client change"
out=$("$LINKS" "$proj" 2>&1)
rc=$?
check "a commit touching a cited file after the stamp is a STALE line" \
  '[ "$rc" -eq 0 ] && printf "%s\n" "$out" | grep -qxF "STALE: docs/payments.md cites src/client.ts, changed in 1 commit since checked at $base"'
check "an unstamped doc citing the same file has no finding" \
  '! printf "%s\n" "$out" | grep -qF "docs/legacy.md"'
check "a cited file no commit touched stays quiet" \
  '! printf "%s\n" "$out" | grep -qF "cites src/other.ts"'

printf 'export const helper = 2;\n' >"$proj/src/util/helper.ts"
printf 'export const client = 3;\n' >"$proj/src/client.ts"
commit "util change"
out=$("$LINKS" "$proj" 2>&1)
check "a cited directory counts commits under it, and counts accumulate" \
  'printf "%s\n" "$out" | grep -qxF "STALE: docs/payments.md cites src/util/, changed in 1 commit since checked at $base" && printf "%s\n" "$out" | grep -qxF "STALE: docs/payments.md cites src/client.ts, changed in 2 commits since checked at $base"'

printf 'export const other = 2;\n' >"$proj/src/other.ts"
printf '%s\n' 'Other now exports two.' >>"$pay"
commit "other and doc together"
out=$("$LINKS" "$proj" 2>&1)
check "a commit that also changes the doc is not counted against it" \
  '! printf "%s\n" "$out" | grep -qF "cites src/other.ts"'

mkdir -p "$proj/.agent/docs/payments/references"
printf '# Codes\n' >"$proj/.agent/docs/payments/references/codes.md"
printf 'See [queues](docs/payments/queues.md).\n' >>"$pay"
out=$("$LINKS" "$proj" 2>&1)
check "ORPHAN and BROKEN still report beside the drift pass" \
  'printf "%s\n" "$out" | grep -qF "ORPHAN: docs/payments/references/codes.md" && printf "%s\n" "$out" | grep -qF "BROKEN: .agent/docs/payments.md cites docs/payments/queues.md"'
rm -rf "$proj/.agent/docs/payments"
sed '$d' "$pay" >"$pay.tmp" && mv "$pay.tmp" "$pay"

before="$tmp/payments.before"
cp "$pay" "$before"
check_out=$("$DOCS" check --name payments "$proj" 2>&1)
check_rc=$?
head_now=$(g rev-parse --short HEAD)
check "docs.sh check replaces the stamp with HEAD" \
  '[ "$check_rc" -eq 0 ] && [ "$(sed -n 2p "$pay")" = "<!-- Checked: $head_now -->" ] && printf "%s" "$check_out" | grep -qF "checked at $head_now"'
check "docs.sh check leaves the rest of the doc byte-identical" \
  '{ head -n 1 "$pay"; tail -n +3 "$pay"; } | cmp -s - <({ head -n 1 "$before"; tail -n +3 "$before"; })'
out=$("$LINKS" "$proj" 2>&1)
check "a restamped doc has no STALE line" \
  '! printf "%s\n" "$out" | grep -q "^STALE:"'

leg="$proj/.agent/docs/legacy.md"
printf '%s\n%s' '<!-- Read when: legacy billing -->' '# Legacy without a final newline' >"$leg"
cp "$leg" "$before"
"$DOCS" check --name legacy "$proj" >/dev/null 2>&1
check "docs.sh check inserts a stamp after the hook and copies the rest byte for byte" \
  '[ "$(sed -n 2p "$leg")" = "<!-- Checked: $head_now -->" ] && { head -n 1 "$leg"; tail -n +3 "$leg"; } | cmp -s - "$before"'
check "docs.sh check refuses the routing table" \
  '! "$DOCS" check --name architecture "$proj" >/dev/null 2>&1'

printf '%s\n' '<!-- Read when: ghost -->' '<!-- Checked: deadbee -->' '# Ghost' 'See `src/client.ts`.' >"$proj/.agent/docs/ghost.md"
printf '%s\n' '<!-- Read when: junk -->' '<!-- Checked: not-a-sha -->' '# Junk' >"$proj/.agent/docs/junk.md"
out=$("$LINKS" "$proj" 2>&1)
rc=$?
check "a stamp that is not a commit is a one-line note, not a failure" \
  '[ "$rc" -eq 0 ] && [ "$(printf "%s\n" "$out" | grep -c "docs/ghost.md is stamped at deadbee, which is not a commit")" -eq 1 ] && printf "%s\n" "$out" | grep -qF "docs/junk.md is stamped at not-a-sha, which is not a commit" && ! printf "%s\n" "$out" | grep -qF "STALE: docs/ghost.md"'

plain="$tmp/plain"
cp -R "$proj" "$plain"
rm -rf "$plain/.git"
plain_doc="$plain/.agent/docs/payments.md"
cp "$plain_doc" "$before"
out=$("$plain/.agent/scripts/links.sh" "$plain" 2>&1)
rc=$?
check "outside a git repository the drift pass says so in one line and exits 0" \
  '[ "$rc" -eq 0 ] && [ "$(printf "%s\n" "$out" | grep -c "not a git repository with commits — drift check skipped")" -eq 1 ] && ! printf "%s\n" "$out" | grep -q "^STALE:"'
check "docs.sh check outside a git repository fails and writes nothing" \
  '! "$plain/.agent/scripts/docs.sh" check --name payments "$plain" >/dev/null 2>&1 && cmp -s "$plain_doc" "$before"'
"$plain/.agent/scripts/docs.sh" new --name fresh --read-when "fresh area" "$plain" >/dev/null 2>&1
check "docs.sh new outside a git repository writes an unstamped doc" \
  '[ "$(wc -l <"$plain/.agent/docs/fresh.md")" -eq 2 ] && ! grep -qF "Checked:" "$plain/.agent/docs/fresh.md"'

bare="$tmp/bare"
mkdir -p "$bare/.agent/docs"
printf '%s\n' '<!-- Read when: x -->' '# X' >"$bare/.agent/docs/x.md"
out=$(bash "$repo_root/scripts/links.sh" "$bare" 2>&1)
check "a node with no stamp prints nothing from the drift pass" \
  '! printf "%s\n" "$out" | grep -qE "drift|Checked|STALE"'

printf '1..%d\n' "$((passes + failures))"
[ "$failures" -eq 0 ]
