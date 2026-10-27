#!/usr/bin/env bash
set -eu
unset CDPATH
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/hooks-v63.XXXXXX")
scratch=$(cd "$scratch" && pwd -P)
trap 'rm -rf "$scratch"' EXIT
fail() { echo "FAIL hooks-v63: $*" >&2; exit 1; }
node() { bash "$repo/scripts/node.sh" "$@"; }
installer="$repo/tools/hooks/install.sh"
json() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$@"; }

# session-start.sh: the payload under a header, or a pointer when over the limit.
p="$scratch/small"
mkdir -p "$p"
node init --preset domain-knowledge --mode track-all --hooks none "$p" >/dev/null
printf '# Contract\n\nShort.\n' >"$p/.agent/rules/contract.md"
out=$(cd "$scratch" && bash "$p/.agent/scripts/session-start.sh")
printf '%s\n' "$out" | head -n 1 | grep -qF 'dot-agent session-start hook: the output of `bash .agent/scripts/status.sh --load`' || fail 'header missing'
printf '%s\n' "$out" | grep -qF '==== .agent/rules/contract.md ====' || fail 'payload missing'
expected=$(cd "$p" && bash .agent/scripts/status.sh --load)
[ "$(printf '%s\n' "$out" | tail -n +2)" = "$expected" ] || fail 'payload differs from the entry point call'
small=$(printf '%s\n' "$out" | wc -c | tr -d '[:space:]')
[ "$(bash "$p/.agent/scripts/session-start.sh" --max-bytes "$small" | wc -c | tr -d '[:space:]')" = "$small" ] || fail 'output exactly at the limit was not delivered'
over=$(bash "$p/.agent/scripts/session-start.sh" --max-bytes $((small - 1)))
[ "$(printf '%s\n' "$over" | wc -l | tr -d '[:space:]')" = 1 ] || fail 'over-limit output is more than one line'
printf '%s\n' "$over" | grep -qF "prints $small bytes, over this hook's $((small - 1))-byte limit" || fail "over-limit pointer wrong: $over"
printf '%s\n' "$over" | grep -qF 'Make that call as your first tool call' || fail 'pointer does not name the call'
[ -z "$(bash "$p/.agent/scripts/session-start.sh" --max-bytes x)" ] || fail 'bad limit printed output'
cp "$p/.agent/scripts/session-start.sh" "$scratch/lonely.sh"
mkdir -p "$scratch/no-node/.agent/scripts"
cp "$p/.agent/scripts/session-start.sh" "$scratch/no-node/.agent/scripts/"
[ -z "$(bash "$scratch/no-node/.agent/scripts/session-start.sh")" ] || fail 'printed without status.sh'
bash "$scratch/no-node/.agent/scripts/session-start.sh" || fail 'nonzero exit without status.sh'

# Root node at HOME: the pointer names the absolute call.
h="$scratch/home"
mkdir -p "$h"
HOME="$h" node init --preset domain-knowledge --mode track-all "$h" >"$scratch/home-init.out"
HOME="$h" bash "$h/.agent/scripts/session-start.sh" --max-bytes 10 | grep -qF '`bash ~/.agent/scripts/status.sh --load ~`' || fail 'root pointer is not absolute'
grep -qF '$HOME/.agent/scripts/session-start.sh' "$h/.claude/settings.json" || fail 'root Claude hook not in HOME settings'
grep -qF '$HOME/.agent/scripts/session-start.sh' "$h/.codex/hooks.json" || fail 'root Codex hook not in HOME hooks.json'
[ ! -e "$h/.gitignore" ] || fail 'root install wrote a gitignore at HOME'

# The installed commands run the hook from where each harness runs them.
t="$scratch/shared"
mkdir -p "$t/.claude"
git -C "$t" init -q
printf '{\n  "permissions": {"allow": ["Read(**)"]},\n  "hooks": {"SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "echo other"}]}], "Stop": [{"hooks": [{"type": "command", "command": "echo stop"}]}]}\n}\n' >"$t/.claude/settings.json"
node init --preset domain-knowledge --mode track-shared "$t" >"$scratch/init.out"
grep -qx '  hooks: session-start        # session-start | none' "$t/.agent/purpose.md" || fail 'manifest hooks line missing'
grep -qF 'hooks=session-start' "$scratch/init.out" || fail 'init did not report hooks'
[ "$(json "$t/.claude/settings.json" 'd["autoMemoryEnabled"]')" = False ] || fail 'autoMemoryEnabled not set'
[ "$(json "$t/.claude/settings.json" 'd["permissions"]["allow"]')" = "['Read(**)']" ] || fail 'other settings lost'
[ "$(json "$t/.claude/settings.json" 'len(d["hooks"]["SessionStart"])')" = 2 ] || fail 'other SessionStart hook lost'
[ "$(json "$t/.claude/settings.json" 'd["hooks"]["Stop"][0]["hooks"][0]["command"]')" = 'echo stop' ] || fail 'other event lost'
[ "$(json "$t/.claude/settings.json" 'd["hooks"]["SessionStart"][1]["matcher"]')" = 'startup|clear|compact' ] || fail 'Claude matcher wrong'
[ "$(json "$t/.codex/hooks.json" 'd["hooks"]["SessionStart"][0]["hooks"][0]["additionalContextLimit"]')" = 0 ] || fail 'Codex context limit missing'
claude_cmd=$(json "$t/.claude/settings.json" 'd["hooks"]["SessionStart"][1]["hooks"][0]["command"]')
codex_cmd=$(json "$t/.codex/hooks.json" 'd["hooks"]["SessionStart"][0]["hooks"][0]["command"]')
(cd "$scratch" && CLAUDE_PROJECT_DIR="$t" sh -c "$claude_cmd") | head -n 1 | grep -qF 'dot-agent session-start hook:' || fail 'Claude command did not run the hook'
(cd "$scratch" && CLAUDE_PROJECT_DIR="$t" sh -c "$claude_cmd") | head -n 1 | grep -qF 'over this hook'"'"'s 10000-byte limit' || fail 'Claude command does not apply its limit'
(cd "$t" && sh -c "$codex_cmd") | head -n 1 | grep -qF "for the node at $t follows" || fail 'Codex command did not deliver the payload'
[ -z "$(cd "$scratch" && sh -c "$codex_cmd")" ] || fail 'Codex command printed outside a node'
(cd "$scratch" && sh -c "$codex_cmd") || fail 'Codex command failed outside a node'
[ -z "$(cd "$t" && bash .agent/scripts/status.sh . | grep -E '^REPAIR: .*autoMemoryEnabled')" ] || fail 'install left a native-memory repair'

# Idempotent, and removal leaves everything else.
cp "$t/.claude/settings.json" "$scratch/claude.before"
cp "$t/.codex/hooks.json" "$scratch/codex.before"
node update "$t" >"$scratch/update.out"
cmp -s "$t/.claude/settings.json" "$scratch/claude.before" || fail 'second run changed Claude settings'
cmp -s "$t/.codex/hooks.json" "$scratch/codex.before" || fail 'second run changed Codex hooks'
grep -qF 'unchanged in .claude/settings.json' "$scratch/update.out" || fail 'update did not report unchanged'
node update --hooks none "$t" >/dev/null
grep -qx '  hooks: none        # session-start | none' "$t/.agent/purpose.md" || fail 'update --hooks none not recorded'
! grep -qF 'session-start.sh' "$t/.claude/settings.json" || fail 'Claude hook not removed'
[ ! -e "$t/.codex/hooks.json" ] || fail 'emptied Codex hooks file left behind'
[ "$(json "$t/.claude/settings.json" 'd["hooks"]["SessionStart"][0]["hooks"][0]["command"]')" = 'echo other' ] || fail 'removal took another hook'
node update "$t" >/dev/null
grep -qx '  hooks: none        # session-start | none' "$t/.agent/purpose.md" || fail 'update did not keep none'
! grep -qF 'session-start.sh' "$t/.claude/settings.json" || fail 'update reinstalled a declined hook'

# An older manifest gains the line and the hook.
o="$scratch/older"
mkdir -p "$o"
node init --preset domain-knowledge --mode track-all --hooks none "$o" >/dev/null
sed '/^  hooks:/d' "$o/.agent/purpose.md" >"$scratch/purpose" && mv "$scratch/purpose" "$o/.agent/purpose.md"
node update "$o" >"$scratch/older.out"
grep -qF 'hooks: session-start backfilled' "$scratch/older.out" || fail 'backfill not reported'
[ "$(grep -n '^  hooks:' "$o/.agent/purpose.md" | cut -d: -f1)" = "$(($(grep -n '^  indexes:' "$o/.agent/purpose.md" | cut -d: -f1) + 1))" ] || fail 'hooks line not after indexes'
grep -qF 'session-start.sh' "$o/.codex/hooks.json" || fail 'backfill did not install'
if node update --hooks bogus "$o" >/dev/null 2>&1; then fail 'bad --hooks accepted'; fi

# ignore-all keeps every file personal.
i="$scratch/ignore"
mkdir -p "$i"
git -C "$i" init -q
node init --preset domain-knowledge --mode ignore-all "$i" >/dev/null
[ ! -e "$i/.claude/settings.json" ] || fail 'ignore-all wrote the shared Claude settings'
grep -qF 'session-start.sh' "$i/.claude/settings.local.json" || fail 'ignore-all Claude hook missing'
[ "$(cat "$i/.gitignore")" = '.agent/' ] || fail 'ignore-all hook files reached the shared .gitignore'
for line in /.claude/settings.local.json /.codex/hooks.json; do
  grep -qxF "$line" "$i/.git/info/exclude" || fail "ignore-all did not exclude $line"
done
n="$scratch/ignore-nogit"
mkdir -p "$n"
node init --preset domain-knowledge --mode ignore-all "$n" >/dev/null
grep -qF 'session-start.sh' "$n/.claude/settings.local.json" || fail 'ignore-all outside git lost its hook'
[ "$(git -C "$i" status --porcelain)" = '?? .gitignore' ] || { git -C "$i" status --porcelain >&2; fail 'ignore-all left files git would share beyond its gitignore'; }

k="$scratch/ignore-tracked"
mkdir -p "$k/.codex"
git -C "$k" init -q
printf '{"hooks": {}}\n' >"$k/.codex/hooks.json"
git -C "$k" add .codex/hooks.json
node init --preset domain-knowledge --mode ignore-all "$k" >"$scratch/tracked.out"
[ "$(cat "$k/.codex/hooks.json")" = '{"hooks": {}}' ] || fail 'ignore-all edited a tracked Codex file'
grep -qF 'Codex session-start hook skipped' "$scratch/tracked.out" || fail 'tracked skip not reported'

# Files the installer cannot edit stay byte-identical, with the snippet printed.
printf '{oops' >"$o/.codex/hooks.json"
bash "$installer" "$o" >"$scratch/bad.out"
[ "$(cat "$o/.codex/hooks.json")" = '{oops' ] || fail 'invalid JSON was rewritten'
grep -qF '"additionalContextLimit": 0}' "$scratch/bad.out" || fail 'snippet missing for invalid JSON'
python3 -I -c 'import json,sys; [json.loads(l) for l in sys.stdin if l.startswith("{")]' <"$scratch/bad.out" || fail 'printed snippet is not JSON'
rm -f "$o/.codex/hooks.json"
DOT_AGENT_PYTHON=/nonexistent/python bash "$installer" "$o" >"$scratch/nopy.out"
[ ! -e "$o/.codex/hooks.json" ] || fail 'wrote without python'
grep -qF 'not added' "$scratch/nopy.out" || fail 'missing python not reported'
if bash "$installer" "$scratch/no-node" >/dev/null 2>&1; then fail 'installer accepted a root with no manifest'; fi
echo 'ok hooks-v63'
