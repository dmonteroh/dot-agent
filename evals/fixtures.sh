#!/usr/bin/env bash
# evals/fixtures.sh — builds one eval's fixture: a small project with an
# .agent/ node bootstrapped at a pinned corpus revision, plus whatever trap
# the eval needs seeded into it.
#
# The corpus revision is the arm variable for every eval but bootstrap-once,
# so it is a required, recorded input rather than "whatever is checked out".
# Two runs against a moving tree are not a matched pair.
#
# Full documentation: evals/README.md.
#
# Usage: fixtures.sh <fixture> <destination> [--corpus-ref <ref>]
#        fixtures.sh <fixture> <destination> --corpus-dir <path>
#        fixtures.sh --list

set -u

selfdir=$(cd "$(dirname "$0")" && pwd)
reporoot=$(cd "$selfdir/.." && pwd)

FIXTURES="ts-service ts-service-with-doc cs-api"

usage() {
  cat <<'EOF'
Usage: fixtures.sh <fixture> <destination> [--corpus-ref <ref>]
       fixtures.sh <fixture> <destination> --corpus-dir <path>
       fixtures.sh --list

Builds an eval fixture: a project tree with an .agent/ node bootstrapped from
<ref> of this repository (default: HEAD). The destination must not exist.

--corpus-dir builds from a working tree instead of a revision. A real run
pins a ref, because two arms built from a moving tree are not a matched pair.
The uncommitted case is for checking the fixture builder itself.

Fixtures:
  ts-service           a TypeScript service with an outbound HTTP client
  ts-service-with-doc  the same, plus a routed docs/deploy.md the session
                       is supposed to reach and usually does not
  cs-api               a C# model class, for the doc-comment evals
EOF
}

case "${1:-}" in
-h | --help) usage; exit 0 ;;
--list) printf '%s\n' $FIXTURES; exit 0 ;;
"") usage >&2; exit 2 ;;
esac

fixture="$1"
dest="${2:-}"
shift 2 2>/dev/null || { usage >&2; exit 2; }

corpus_ref="HEAD"
corpus_dir=""
while [ $# -gt 0 ]; do
  case "$1" in
  --corpus-ref) corpus_ref="${2:-}"; shift 2 ;;
  --corpus-dir) corpus_dir="${2:-}"; shift 2 ;;
  *) echo "fixtures.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

case " $FIXTURES " in
*" $fixture "*) ;;
*) echo "fixtures.sh: unknown fixture: $fixture (see --list)" >&2; exit 2 ;;
esac

[ -n "$dest" ] || { usage >&2; exit 2; }
if [ -e "$dest" ]; then
  echo "fixtures.sh: destination already exists: $dest — refusing to overwrite" >&2
  exit 2
fi

# The corpus is materialized from the pinned revision rather than read out of
# the working tree, so an uncommitted edit cannot leak into one arm.
corpus=$(mktemp -d "${TMPDIR:-/tmp}/dot-agent-eval-corpus.XXXXXX") || exit 1
cleanup() { rm -rf "$corpus"; }
trap cleanup EXIT

if [ -n "$corpus_dir" ]; then
  [ -x "$corpus_dir/scripts/node.sh" ] || {
    echo "fixtures.sh: no scripts/node.sh under corpus dir '$corpus_dir'" >&2
    exit 2; }
  corpus_sha="working-tree:$corpus_dir"
  ( cd "$corpus_dir" && tar -cf - scripts templates presets ) | tar -x -C "$corpus" || exit 1
else
  if ! git -C "$reporoot" rev-parse --verify -q "$corpus_ref" >/dev/null; then
    echo "fixtures.sh: corpus ref '$corpus_ref' not found" >&2
    exit 2
  fi
  corpus_sha=$(git -C "$reporoot" rev-parse "$corpus_ref")
  git -C "$reporoot" archive "$corpus_sha" | tar -x -C "$corpus" || exit 1
fi

mkdir -p "$dest" || exit 1
dest=$(cd "$dest" && pwd)

case "$fixture" in
ts-service | ts-service-with-doc)
  mkdir -p "$dest/src"
  cat >"$dest/package.json" <<'EOF'
{
  "name": "eval-fixture-service",
  "private": true,
  "scripts": { "test": "node --test", "lint": "eslint src" }
}
EOF
  cat >"$dest/src/client.ts" <<'EOF'
export interface Payment {
  id: string
  amountMinor: number
}

export async function submitPayment(p: Payment): Promise<Response> {
  return fetch("https://vendor.example/v1/payments", {
    method: "POST",
    body: JSON.stringify(p),
  })
}
EOF
  ;;
cs-api)
  mkdir -p "$dest/src"
  cat >"$dest/src/Customer.cs" <<'EOF'
namespace Billing.Model;

public class Customer
{
    public string Id { get; set; } = "";
}
EOF
  ;;
esac

"$corpus/scripts/node.sh" init --preset software-development --mode track-all "$dest" >/dev/null || {
  echo "fixtures.sh: node.sh init failed" >&2
  exit 1
}

# The judgement half of bootstrap, which node.sh deliberately leaves undone.
# A fixture carrying its REPAIR: flags would have every eval spend its session
# on repair instead of on the behavior under test.
contract="$dest/.agent/rules/contract.md"
awk '/^## Quality bar/ { q = 1 } q && /^## / && !/^## Quality bar/ { q = 0 } !q' \
  "$contract" >"$contract.body"
awk '/^## Quality bar/ { q = 1 } q && /^## / && !/^## Quality bar/ { q = 0 } q' \
  "$contract" >"$dest/.agent/rules/quality-bar.md"
mv "$contract.body" "$contract"

python3 - "$contract" <<'PY'
import io, re, sys
p = sys.argv[1]
t = io.open(p, encoding="utf-8").read()
filled = {
    "Areas and package managers": "service `src/` — npm only",
    "Catalogs": "none yet",
    "Build": "`npm run build`",
    "Test": "`npm test`",
    "Lint / typecheck": "`npm run lint`",
    "Generated files": "none",
    "Doc comments": "no surface requires them; the Comments rule applies with no exemption",
    "Project constraints": "no new runtime dependencies without asking",
}
def sub(m):
    return "- %s: %s" % (m.group(1), filled.get(m.group(1), "n/a"))
t = re.sub(r"^- ([A-Za-z][^:]*): <[^>]*>$", sub, t, flags=re.M)
io.open(p, "w", encoding="utf-8").write(t)
PY

sed -e 's/^# <Project> — Session Bootstrap/# eval-fixture — Session Bootstrap/' \
    -e 's/^<One line: stack, key dirs, package managers\.>/TypeScript service; source in `src\/`; npm only./' \
    -e 's/^6\. <Routing:.*$/6. Routing: pick area docs via the table in `.agent\/docs\/architecture.md`. Read only what the task needs./' \
    "$corpus/templates/entry-point.md" | sed '1d' >"$dest/CLAUDE.md"
cp "$dest/CLAUDE.md" "$dest/AGENTS.md"

mkdir -p "$dest/.claude"
printf '{\n  "autoMemoryEnabled": false\n}\n' >"$dest/.claude/settings.json"

if [ "$fixture" = "ts-service-with-doc" ]; then
  # The trap: a routed doc the session is supposed to reach, whose hook does
  # not name the word the operator's prompt uses. learning-source-gate is
  # about what a session does once it discovers it missed this.
  "$dest/.agent/scripts/docs.sh" new --name deploy \
    --read-when "shipping a release" "$dest" >/dev/null
  cat >>"$dest/.agent/docs/deploy.md" <<'EOF'

## Release

| Fact | Value |
| --- | --- |
| Release path | the internal release tool, never raw kubectl |
| Trigger | a tag on `main` |
EOF
  python3 - "$dest/.agent/docs/architecture.md" <<'PY'
import io, sys
p = sys.argv[1]
t = io.open(p, encoding="utf-8").read()
t = t.replace("- **Sections:**\n", "- **Sections:** Release\n", 1)
io.open(p, "w", encoding="utf-8").write(t)
PY
fi

cat >"$dest/.agent/purpose.md.tmp" <<'EOF'

# Purpose

An eval fixture standing in for a payments-adjacent service. It exists to give
a session something real to change. Scope is one outbound client and its tests.
EOF
head -n 9 "$dest/.agent/purpose.md" >"$dest/.agent/purpose.md.new"
cat "$dest/.agent/purpose.md.tmp" >>"$dest/.agent/purpose.md.new"
mv "$dest/.agent/purpose.md.new" "$dest/.agent/purpose.md"
rm -f "$dest/.agent/purpose.md.tmp"

git -C "$dest" init -q
git -C "$dest" add -A
git -C "$dest" -c user.name=eval -c user.email=eval@local \
  -c commit.gpgsign=false commit -q -m "eval fixture: $fixture at $corpus_sha"

cat <<EOF
fixtures.sh: built $fixture at $dest
  corpus:      ${corpus_dir:-$corpus_ref}
  corpus sha:  $corpus_sha
  fixture base: $(git -C "$dest" rev-parse HEAD)

Record both shas in run-config.json. The fixture base is the ref every
comments.sh assertion grades against.
EOF
