#!/usr/bin/env bash
# Adds, or with --remove takes out, the session-start hook that runs
# .agent/scripts/session-start.sh in Claude Code and Codex. node.sh init and
# update call it; it also runs on its own against an existing node.
#
# The node's tracking mode picks the files, so the hook lands where the node's
# own settings already live:
#   track-shared, track-all   .claude/settings.json and .codex/hooks.json,
#                             committed with the project for every developer
#   ignore-all                .claude/settings.local.json and .codex/hooks.json,
#                             both listed in .git/info/exclude, which git never shares
#   a root node at $HOME      ~/.claude/settings.json and ~/.codex/hooks.json
#
# Each file is merged, never replaced: other keys and other hooks stay as they
# are, a second run changes nothing, and a file that is not valid JSON is left
# alone with the snippet to add by hand. The merge needs python3 (override with
# DOT_AGENT_PYTHON). Without it, nothing is written and the snippets print.
set -u
unset CDPATH

usage() {
  echo "Usage: install.sh [--remove] [root]" >&2
  echo "root defaults to . and must hold a .agent/ node with a manifest." >&2
}

remove=0
root="."
while [ $# -gt 0 ]; do
  case "$1" in
  --remove) remove=1; shift ;;
  -h | --help) usage; exit 0 ;;
  --*) echo "install.sh: unknown flag: $1" >&2; usage; exit 2 ;;
  *) root="$1"; shift ;;
  esac
done

purpose="$root/.agent/purpose.md"
if [ ! -f "$purpose" ] || ! head -n 10 "$purpose" | grep -qF 'dot-agent:'; then
  echo "install.sh: no dot-agent manifest at $purpose" >&2
  exit 2
fi
mode=$(grep -m1 '^  mode:' "$purpose" | sed -E 's/^[[:space:]]*mode:[[:space:]]*([A-Za-z-]+).*/\1/')
case "$mode" in
ignore-all | track-shared | track-all) ;;
*) echo "install.sh: unreadable mode '$mode' in $purpose" >&2; exit 2 ;;
esac

root_abs=$(cd "$root" && pwd -P)
home_abs=$(cd "${HOME:-/nonexistent}" 2>/dev/null && pwd -P)
py="${DOT_AGENT_PYTHON:-python3}"

# Claude Code cuts hook output past 10,000 characters to a file and a preview
# (code.claude.com/docs/en/hooks), so its hook asks for at most 10,000 bytes.
# Codex takes additionalContextLimit per handler, and 0 passes the whole
# output: the script's own default limit then applies.
# A Codex user approves the exact definition once with /hooks, and any change
# to it asks again. Change these strings only with that cost in mind.
if [ -n "$home_abs" ] && [ "$root_abs" = "$home_abs" ]; then
  claude_file="$home_abs/.claude/settings.json"
  codex_file="$home_abs/.codex/hooks.json"
  claude_cmd='[ ! -f "$HOME/.agent/scripts/session-start.sh" ] || bash "$HOME/.agent/scripts/session-start.sh" --max-bytes 10000'
  codex_cmd='[ ! -f "$HOME/.agent/scripts/session-start.sh" ] || bash "$HOME/.agent/scripts/session-start.sh"'
  is_home=1
else
  if [ "$mode" = ignore-all ]; then
    claude_file="$root_abs/.claude/settings.local.json"
  else
    claude_file="$root_abs/.claude/settings.json"
  fi
  codex_file="$root_abs/.codex/hooks.json"
  claude_cmd='[ ! -f "$CLAUDE_PROJECT_DIR/.agent/scripts/session-start.sh" ] || bash "$CLAUDE_PROJECT_DIR/.agent/scripts/session-start.sh" --max-bytes 10000'
  codex_cmd='[ ! -f .agent/scripts/session-start.sh ] || bash .agent/scripts/session-start.sh'
  is_home=0
fi
matcher='startup|clear|compact'

show() {
  if [ "$is_home" -eq 1 ]; then
    printf '%s/%s' '~' "${1#"$home_abs"/}"
    return
  fi
  case "$1" in
  "$root_abs"/*) printf '%s' "${1#"$root_abs"/}" ;;
  *) printf '%s' "$1" ;;
  esac
}

tracked() {
  git -C "$root_abs" ls-files --error-unmatch -- "${1#"$root_abs"/}" >/dev/null 2>&1
}

# Personal files go in the repository's own exclude file, never the shared
# .gitignore. Outside git there is nothing to share, so nothing is written.
exclude_line() {
  exclude=$(git -C "$root_abs" rev-parse --git-path info/exclude 2>/dev/null) || return 0
  case "$exclude" in
  /*) ;;
  *) exclude="$root_abs/$exclude" ;;
  esac
  mkdir -p "$(dirname "$exclude")" || return 0
  if [ ! -e "$exclude" ] || ! grep -qxF "/$1" "$exclude"; then
    [ -s "$exclude" ] && [ -n "$(tail -c 1 "$exclude")" ] && echo >>"$exclude"
    printf '/%s\n' "$1" >>"$exclude"
  fi
}

# snippet <command> <extra handler JSON>
snippet() {
  sn_extra=${2#\{}
  sn_extra=${sn_extra%\}}
  [ -z "$sn_extra" ] || sn_extra=", $sn_extra"
  printf '{"hooks": {"SessionStart": [{"matcher": "%s", "hooks": [{"type": "command", "command": %s, "timeout": 30%s}]}]}}\n' \
    "$matcher" "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/"/')" "$sn_extra"
}

# merge <add|remove> <file> <command> <extra handler JSON> <set autoMemoryEnabled: 0|1>
# prints added, updated, unchanged, removed, or absent; exits 3 on a file it will not touch.
merge() {
  "$py" -I - "$@" <<'PY'
import json, os, sys, tempfile

action, path, command, extra, automem = sys.argv[1:6]
marker = ".agent/scripts/session-start.sh"
matcher = "startup|clear|compact"

data = {}
if os.path.exists(path) and os.path.getsize(path) > 0:
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (ValueError, OSError):
        sys.exit(3)
if not isinstance(data, dict):
    sys.exit(3)
hooks = data.get("hooks", {})
if not isinstance(hooks, dict):
    sys.exit(3)
groups = hooks.get("SessionStart", [])
if not isinstance(groups, list):
    sys.exit(3)

def ours(handler):
    return isinstance(handler, dict) and marker in str(handler.get("command", ""))

handler = {"type": "command", "command": command, "timeout": 30}
handler.update(json.loads(extra))
group = {"matcher": matcher, "hooks": [handler]}

found = [i for i, g in enumerate(groups)
         if isinstance(g, dict) and isinstance(g.get("hooks"), list)
         and any(ours(h) for h in g["hooks"])]
changed = False
if action == "add":
    if len(found) == 1 and groups[found[0]] == group:
        result = "unchanged"
    elif len(found) == 1 and all(ours(h) for h in groups[found[0]]["hooks"]):
        groups[found[0]] = group
        result, changed = "updated", True
    else:
        for i in found:
            groups[i]["hooks"] = [h for h in groups[i]["hooks"] if not ours(h)]
        groups[:] = [g for i, g in enumerate(groups) if i not in found or g["hooks"]]
        groups.append(group)
        result, changed = ("updated" if found else "added"), True
    hooks["SessionStart"] = groups
    data["hooks"] = hooks
    if automem == "1" and "autoMemoryEnabled" not in data:
        data = {"autoMemoryEnabled": False, **data}
        changed = True
else:
    if not found:
        result = "absent"
    else:
        for i in found:
            groups[i]["hooks"] = [h for h in groups[i]["hooks"] if not ours(h)]
        groups[:] = [g for g in groups if not (isinstance(g, dict) and g.get("hooks") == [])]
        if groups:
            hooks["SessionStart"] = groups
        else:
            hooks.pop("SessionStart", None)
        if hooks:
            data["hooks"] = hooks
        else:
            data.pop("hooks", None)
        result, changed = "removed", True

if changed and not data:
    os.remove(path)
elif changed:
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".hooks.", dir=os.path.dirname(path) or ".")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    if os.path.exists(path):
        os.chmod(tmp, os.stat(path).st_mode & 0o777)
    else:
        os.chmod(tmp, 0o644)
    os.replace(tmp, path)
print(result)
PY
}

# apply <label> <file> <command> <extra handler JSON> <automem>
apply() {
  label=$1 file=$2 command=$3 extra=$4 automem=$5
  rel=$(show "$file")
  applied=0
  if [ "$is_home" -eq 0 ] && [ "$mode" = ignore-all ] && tracked "$file"; then
    echo "hooks: $label skipped — $rel is tracked by this repository, and ignore-all keeps the node out of shared files"
    return 0
  fi
  if ! command -v "$py" >/dev/null 2>&1; then
    if [ "$remove" -eq 1 ]; then
      echo "hooks: $label not removed — $py is not available; delete the SessionStart entry that runs session-start.sh from $rel by hand"
    else
      echo "hooks: $label not added — $py is not available; merge this into $rel by hand:"
      snippet "$command" "$extra"
    fi
    return 0
  fi
  if [ "$remove" -eq 1 ]; then
    result=$(merge remove "$file" "$command" "$extra" 0)
  else
    result=$(merge add "$file" "$command" "$extra" "$automem")
  fi
  case $? in
  0) ;;
  3)
    echo "hooks: $label left alone — $rel is not a JSON object with a hooks table this script can edit; merge this by hand:"
    snippet "$command" "$extra"
    return 0 ;;
  *) echo "hooks: $label failed on $rel" >&2; return 1 ;;
  esac
  echo "hooks: $label $result in $rel"
  applied=1
  if [ "$remove" -eq 0 ] && [ "$is_home" -eq 0 ] && [ "$mode" = ignore-all ]; then
    exclude_line "${file#"$root_abs"/}"
  fi
}

status=0
apply 'Claude Code session-start hook' "$claude_file" "$claude_cmd" '{}' 1 || status=1
apply 'Codex session-start hook' "$codex_file" "$codex_cmd" '{"additionalContextLimit": 0}' 0 || status=1
if [ "$remove" -eq 0 ] && [ "$applied" -eq 1 ]; then
  if [ "$is_home" -eq 1 ]; then
    echo 'hooks: Codex runs the hook only after you approve it once with /hooks; until then it skips it and the entry point loads the node instead'
  else
    echo 'hooks: Codex runs the hook only in a trusted project, after each developer approves it once with /hooks in that checkout; until then it skips it and the entry point loads the node instead'
  fi
fi
exit "$status"
