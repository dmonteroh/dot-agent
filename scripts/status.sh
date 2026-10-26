#!/usr/bin/env bash

set -u

LOG_MAX_ENTRIES=120
LOG_MAX_WORDS=5000
LOG_ENTRY_MAX_WORDS=50
MEMORY_MAX_WORDS=300
MEMORY_MAX_ENTRIES=100
LEARNED_MAX_RULES=60
LEARNED_MAX_WORDS=2400
DOCS_MAX_WORDS=2000
ENTRYPOINT_MAX_WORDS=800
TAIL_LINES=25
PROBE_TOOLS="rg fd jq gh python3 curl tree"
PAYLOAD_MAX_BYTES=30000

root="."
load=0
format=text
while [ $# -gt 0 ]; do
  case "$1" in
  -h | --help)
    cat <<'EOF'
Usage: status.sh [--load] [--format tsv] [root]

Prints the recent session-log entries, then one line per finding: GROOM: (a
file crossed a grooming threshold), REPAIR: (a canonical file or bootstrap
step is missing), INDEX: (a docs/ file and the routing table disagree), plus
advisory TOOLS: and LOAD: lines. No finding prints on pass.

--load then prints the always-loaded set, each under a "==== <path> ===="
marker, so the bootstrap is one call. In manual mode (indexes: manual, the
default) that set is rules/learned.md, rules/contract.md, purpose.md,
memory.md. In generated mode (indexes: generated) it is purpose.md and
memory.md only, preceded by one line pointing at the index pages that carry
the rule bodies instead. A PAYLOAD: line reports the exact bytes this set
would write against PAYLOAD_MAX_BYTES; over budget, --load prints one line
(REPAIR:, naming the mode's paths) instead, with no marker and no file
content written.

root defaults to . — checks <root>/.agent/ and exits 0 whatever it finds. A
root holding no .agent/ is a usage error and exits 1.

--format tsv prints findings only as severity<TAB>code<TAB>path<TAB>message.
Tabs, carriage returns, and newlines in fields are escaped. It cannot be
combined with --load.
EOF
    exit 0 ;;
  --load) load=1 ;;
  --format)
    if [ $# -lt 2 ] || [ "$2" != tsv ]; then
      echo "status.sh: --format requires tsv" >&2
      exit 1
    fi
    format=tsv
    shift ;;
  --*)
    echo "status.sh: unknown flag: $1" >&2
    exit 1 ;;
  *) root="$1" ;;
  esac
  shift
done

if [ "$format" = tsv ] && [ "$load" -eq 1 ]; then
  echo "status.sh: --format tsv cannot be combined with --load" >&2
  exit 1
fi

escape_tsv() {
  REPLY=$1
  REPLY=${REPLY//$'\t'/\\t}
  REPLY=${REPLY//$'\r'/\\r}
  REPLY=${REPLY//$'\n'/\\n}
}

finding() { # severity code path message default-text
  if [ "$format" = tsv ]; then
    escape_tsv "$3"; finding_path=$REPLY
    escape_tsv "$4"; finding_message=$REPLY
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$finding_path" "$finding_message"
  else
    printf '%s\n' "$5"
  fi
}

agent="$root/.agent"
if [ ! -d "$agent" ]; then
  echo "status.sh: no .agent directory at $agent — run from the node's project root, or pass that root as an argument" >&2
  exit 1
fi

conf="$agent/scripts/status.conf"
conf_get() { sed -n "s/^$1=//p" "$conf" 2>/dev/null | head -n 1 | sed 's/[[:space:]]*$//'; }
conf_repair_messages=()
conf_num() { # $1: key name — the current value is its shipped default
  local v
  v=$(conf_get "$1")
  [[ -n "$v" ]] || return 0
  case "$v" in
  *[!0-9]*)
    conf_message="$1=$v is not a whole number — the default ${!1} is in use; fix the line, which takes digits only (no inline comment, no units)"
    conf_repair_messages+=("$conf_message")
    return 0 ;;
  esac
  printf -v "$1" '%s' "$v"
}
if [[ -f "$conf" ]]; then
  conf_num LOG_MAX_ENTRIES
  conf_num LOG_MAX_WORDS
  conf_num LOG_ENTRY_MAX_WORDS
  conf_num MEMORY_MAX_WORDS
  conf_num MEMORY_MAX_ENTRIES
  conf_num LEARNED_MAX_RULES
  conf_num LEARNED_MAX_WORDS
  conf_num DOCS_MAX_WORDS
  conf_num ENTRYPOINT_MAX_WORDS
  conf_num TAIL_LINES
  conf_num PAYLOAD_MAX_BYTES
  v=$(conf_get PROBE_TOOLS);          [[ -n "$v" ]] && PROBE_TOOLS="$v"
fi
log="$agent/session-log.md"
memory="$agent/memory.md"
memdir="$agent/memory"
learned="$agent/rules/learned.md"
learned_dir="$agent/rules/learned"
contract="$agent/rules/contract.md"
qualitybar="$agent/rules/quality-bar.md"
purpose="$agent/purpose.md"
indexes_line=$(grep -m1 '^  indexes:' "$purpose" 2>/dev/null)
indexes=$(printf '%s\n' "$indexes_line" | sed -E 's/^[[:space:]]*indexes:[[:space:]]*([A-Za-z-]+).*/\1/')
[ -n "$indexes" ] || indexes=manual
indexer="$agent/scripts/index.sh"
load_mode="$indexes"
if [[ "$indexes" == generated ]] && [[ ! -f "$indexer" ]]; then
  load_mode=manual
fi
docs="$agent/docs"
arch="$docs/architecture.md"

words() { wc -w <"$1" | tr -d '[:space:]'; }

body_words() {
  awk '
    NR == 1 && $0 == "---" { infm = 1; next }
    infm { if ($0 == "---") infm = 0; next }
    incm { if (/-->/) { incm = 0; sub(/.*-->/, "") } else next }
    { gsub(/<!--.*-->/, "") }
    /<!--/ { incm = 1; sub(/<!--.*/, "") }
    { print }
  ' "$1" | wc -w | tr -d '[:space:]'
}

learned_dir_active() {
  [[ -d "$learned_dir" ]] && [[ ! -L "$learned_dir" ]] || return 1
  [[ -n "$(find "$learned_dir" -type f -name '*.md' -print -quit 2>/dev/null)" ]]
}

if [[ "$format" == text && -s "$log" ]]; then
  recent=$(grep '^- \[' "$log" | tail -n "$TAIL_LINES")
  if [[ -n "$recent" ]]; then
    printf '%s\n\n' "$recent"
  fi
fi

if [[ "${#conf_repair_messages[@]}" -gt 0 ]]; then
  for conf_i in "${!conf_repair_messages[@]}"; do
    conf_message=${conf_repair_messages[$conf_i]}
    finding block STATUS_CONFIG_INVALID status.conf "$conf_message" \
      "REPAIR: status.conf $conf_message"
  done
fi

[[ -s "$memory" ]] || finding block CANONICAL_MEMORY_MISSING memory.md "missing/empty" "REPAIR: memory.md missing/empty"
[[ -s "$log" ]] || finding block CANONICAL_LOG_MISSING session-log.md "missing/empty" "REPAIR: session-log.md missing/empty"
[[ -s "$contract" ]] || finding block CANONICAL_CONTRACT_MISSING rules/contract.md "missing/empty — restore it, the entry point loads it every session" "REPAIR: rules/contract.md missing/empty — restore it, the entry point loads it every session"
if ! learned_dir_active && [[ ! -s "$learned" ]]; then
  finding block CANONICAL_LEARNED_MISSING rules/learned/ "missing/empty — restore the records, or rules/learned.md on a node that keeps no record directory; the entry point loads them every session" "REPAIR: rules/learned/ missing/empty — restore the records, or rules/learned.md on a node that keeps no record directory; the entry point loads them every session"
fi
if ! head -n 10 "$purpose" 2>/dev/null | grep -qF "dot-agent:"; then
  finding block MANIFEST_INVALID purpose.md "missing dot-agent frontmatter — restore manifest" "REPAIR: purpose.md missing dot-agent frontmatter — restore manifest"
fi

# Installed skills live beside the node at <root>/.agents/skills/, where most
# agent tools read them. They follow the Agent Skills specification
# (agentskills.io/specification): a SKILL.md whose frontmatter name equals its
# directory and whose description holds 1 to 1024 characters. Several tools
# drop a skill that breaks these without a message. Other installers write
# there too, so the findings are advisory.
skill_frontmatter() { # $1: SKILL.md — prints "name<TAB>description"
  awk '
    NR == 1 { if ($0 != "---") exit; inside = 1; next }
    inside && $0 == "---" { exit }
    inside && /^name:/ { v = $0; sub(/^name:[ \t]*/, "", v); name = v; block = 0; next }
    inside && /^description:/ {
      v = $0; sub(/^description:[ \t]*/, "", v)
      if (v ~ /^[>|][-+]?$/) { block = 1; desc = ""; next }
      desc = v; block = 0; next
    }
    inside && block && /^[ \t]/ { v = $0; sub(/^[ \t]+/, "", v); desc = desc (desc == "" ? "" : " ") v; next }
    inside { block = 0 }
    END {
      if (name ~ /^".*"$/ || name ~ /^\047.*\047$/) name = substr(name, 2, length(name) - 2)
      if (desc ~ /^".*"$/ || desc ~ /^\047.*\047$/) desc = substr(desc, 2, length(desc) - 2)
      printf "%s\t%s\n", name, desc
    }
  ' "$1"
}
if [[ -d "$root/.agents/skills" ]]; then
  for skill_path in "$root/.agents/skills"/*/; do
    [[ -d "$skill_path" ]] || continue
    skill_path=${skill_path%/}
    skill_dir=${skill_path##*/}
    skill_rel=".agents/skills/$skill_dir"
    if [[ ! -f "$skill_path/SKILL.md" ]]; then
      finding advisory SKILL_FILE_MISSING "$skill_rel" "has no SKILL.md — tools that read .agents/skills/ skip it; add one or remove the directory" "GROOM: $skill_rel has no SKILL.md — tools that read .agents/skills/ skip it; add one or remove the directory"
      continue
    fi
    IFS=$'\t' read -r skill_name skill_desc < <(skill_frontmatter "$skill_path/SKILL.md")
    if [[ "$skill_name" != "$skill_dir" ]]; then
      finding advisory SKILL_NAME_MISMATCH "$skill_rel/SKILL.md" "frontmatter name '${skill_name}' does not match the directory '$skill_dir' — the Agent Skills spec requires the match; fix it here, or upstream when an installer wrote it" "GROOM: $skill_rel/SKILL.md frontmatter name '${skill_name}' does not match the directory '$skill_dir' — the Agent Skills spec requires the match; fix it here, or upstream when an installer wrote it"
    fi
    if [[ -z "$skill_desc" ]]; then
      finding advisory SKILL_DESCRIPTION_MISSING "$skill_rel/SKILL.md" "has no frontmatter description — tools match a skill to a task by it; add one" "GROOM: $skill_rel/SKILL.md has no frontmatter description — tools match a skill to a task by it; add one"
    elif [[ "${#skill_desc}" -gt 1024 ]]; then
      finding advisory SKILL_DESCRIPTION_OVERSIZE "$skill_rel/SKILL.md" "description is ${#skill_desc} characters, over the spec's 1024 — shorten it" "GROOM: $skill_rel/SKILL.md description is ${#skill_desc} characters, over the spec's 1024 — shorten it"
    fi
    if [[ -d "$root/.claude/skills/$skill_dir" && ! -L "$root/.claude/skills" && ! -L "$root/.claude/skills/$skill_dir" ]]; then
      finding advisory SKILL_DUPLICATE "$skill_rel" "a separate copy also lives at .claude/skills/$skill_dir — tools that read both directories list it twice or pick one; keep one and link the other" "GROOM: $skill_rel has a separate copy at .claude/skills/$skill_dir — tools that read both directories list it twice or pick one; keep one and link the other"
    fi
  done
fi

migration_target_line=$(grep -m1 '^  migration_target:' "$purpose" 2>/dev/null)
if [[ -n "$migration_target_line" ]]; then
  migration_target=$(printf '%s\n' "$migration_target_line" | sed -E 's/^[[:space:]]*migration_target:[[:space:]]*"?([^"[:space:]]*)"?.*/\1/')
  finding block MIGRATION_PENDING purpose.md "has migration_target \"$migration_target\" pending — run node.sh finalize to stamp version $migration_target and clear migration_target" "REPAIR: purpose.md has migration_target \"$migration_target\" pending — run node.sh finalize to stamp version $migration_target and clear migration_target"
fi

if [[ -s "$contract" ]]; then
  guardrails=$(awk '/^## Project guardrails/ { inb = 1; next }
                    inb && /^## / { exit }
                    inb { print }' "$contract")
  if printf '%s\n' "$guardrails" | grep -qE '^- .*<[^>]* [^>]*>'; then
    finding block GUARDRAILS_PLACEHOLDER rules/contract.md "Project guardrails still holds template placeholders — fill them with this project's exact commands" "REPAIR: contract.md Project guardrails still holds template placeholders — fill them with this project's exact commands"
  fi
  if grep -q '^## Quality bar' "$contract"; then
    finding block QUALITY_BAR_UNSPLIT rules/contract.md "still contains ## Quality bar — split it into rules/quality-bar.md so it loads on demand, not every session" "REPAIR: contract.md still contains ## Quality bar — split it into rules/quality-bar.md so it loads on demand, not every session"
  elif [[ ! -s "$qualitybar" ]]; then
    finding block QUALITY_BAR_MISSING rules/quality-bar.md "missing — the verifier rubric was never split out of the preset" "REPAIR: rules/quality-bar.md missing — the verifier rubric was never split out of the preset"
  fi
fi

entrypoints=()
for candidate in "$root/CLAUDE.md" "$root/AGENTS.md" "$root/.cursorrules" \
  "$root/.github/copilot-instructions.md" "$root/.claude/CLAUDE.md"; do
  [[ -s "$candidate" ]] || continue
  grep -qF ".agent/scripts/status.sh" "$candidate" || continue
  entrypoints+=("$candidate")
done
if [[ "${#entrypoints[@]}" -gt 1 ]]; then
  first="${entrypoints[0]}"
  for other in "${entrypoints[@]:1}"; do
    if ! cmp -s "$first" "$other"; then
      other_rel=${other#"$root"/}; first_rel=${first#"$root"/}
      finding block ENTRYPOINT_DRIFT "$other_rel" "differs from $first_rel — entry points must stay identical; mirror the edit" "REPAIR: $other_rel differs from $first_rel — entry points must stay identical; mirror the edit"
    fi
  done
fi

first_extra_heading() {
  awk '
    /^```/ { fence = 1 - fence; next }
    fence { next }
    /^###?#?#?#?[ \t]/ { print; exit }
    /^#[ \t]/ { if (seen_title++) { print; exit } }
  ' "$1"
}
for ep in "${entrypoints[@]-}"; do
  [[ -n "$ep" ]] || continue
  extra=$(first_extra_heading "$ep")
  if [[ -n "$extra" ]]; then
    ep_rel=${ep#"$root"/}
    finding block ENTRYPOINT_SECTION "$ep_rel" "carries the section \"$extra\" — an entry point is its title and the load path, nothing else: move that content to rules/contract.md's Project guardrails, purpose.md, or a routed doc, and mirror the removal to every other entry point" "GROOM: $ep_rel carries the section \"$extra\" — an entry point is its title and the load path, nothing else: move that content to rules/contract.md's Project guardrails, purpose.md, or a routed doc, and mirror the removal to every other entry point"
  fi
  if [[ "$(body_words "$ep")" -gt "$ENTRYPOINT_MAX_WORDS" ]]; then
    ep_rel=${ep#"$root"/}
    finding advisory ENTRYPOINT_OVERSIZE "$ep_rel" "> $ENTRYPOINT_MAX_WORDS words — an entry point is wiring only: move project scope, constraints, and architecture into purpose.md or docs/, keep the load path, and mirror the trim to every other entry point" "GROOM: $ep_rel > $ENTRYPOINT_MAX_WORDS words — an entry point is wiring only: move project scope, constraints, and architecture into purpose.md or docs/, keep the load path, and mirror the trim to every other entry point"
  fi
done

if [[ -s "$log" ]]; then
  entries=$(grep -c '^- \[' "$log")
  if [[ "$entries" -gt "$LOG_MAX_ENTRIES" || "$(words "$log")" -gt "$LOG_MAX_WORDS" ]]; then
    finding advisory LOG_OVERSIZE session-log.md "> $LOG_MAX_ENTRIES entries or > $LOG_MAX_WORDS words — move the oldest entries to archive/session-log-archive.md, keep the newest ~$((LOG_MAX_ENTRIES / 2))" "GROOM: session-log.md > $LOG_MAX_ENTRIES entries or > $LOG_MAX_WORDS words — move the oldest entries to archive/session-log-archive.md, keep the newest ~$((LOG_MAX_ENTRIES / 2))"
  fi
  oversized=$(awk -v max="$LOG_ENTRY_MAX_WORDS" '
    /^- \[/ { if (inentry && cnt > max) { n++; if (cnt > big) big = cnt }
              inentry = 1; cnt = 0 }
    inentry { cnt += NF }
    END { if (inentry && cnt > max) { n++; if (cnt > big) big = cnt }
          printf "%d %d", n, big }' "$log")
  over_n=${oversized% *}
  over_big=${oversized#* }
  if [[ "$over_n" -gt 0 ]]; then
    finding advisory LOG_ENTRY_OVERSIZE session-log.md "entries over $LOG_ENTRY_MAX_WORDS words: $over_n (largest $over_big; the header format is ≤25) — distill them to format, route surviving detail to memory/ or docs/, write new entries via log.sh" "GROOM: session-log.md entries over $LOG_ENTRY_MAX_WORDS words: $over_n (largest $over_big; the header format is ≤25) — distill them to format, route surviving detail to memory/ or docs/, write new entries via log.sh"
  fi
fi
keep_tokens() {
  {
    grep -oE '`[^`]+`' "$1" 2>/dev/null
    grep -oE 'npm (run )?[a-z:-]+( -- (--?[a-z-]+( [a-z0-9_.:\/-]+)?)*)?' "$1" 2>/dev/null
    awk '
      NR == 1 && $0 == "---" { infm = 1; next }
      infm { if ($0 == "---") infm = 0; next }
      {
      for (i = 1; i <= NF; i++) {
        t = $i
        gsub(/^[("\x27\[]+|(\x27s)?[)"\x27\],.;:!?]*$/, "", t)
        if (t == "") continue
        if (t ~ /^[A-Z][A-Z0-9]+-[0-9]+$/ || t ~ /^[A-Z][A-Z0-9_][A-Z0-9_][A-Z0-9_]+$/ || t ~ /^[A-Z][a-z]+-[A-Z][a-z]+$/ || t ~ /^[a-z]+:\/\// || t ~ /^[A-Za-z0-9_.-]*\/[A-Za-z0-9_.\/-]+$/ || t ~ /^[a-z0-9.-]+\.[a-z][a-z]+(:[0-9]+)?$/ || t ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ || t ~ /^[0-9]+(ms|s|rps|%)$/) print t
        if (t ~ /^[0-9]+$/ && i < NF && $(i+1) ~ /^(ms|rps|s|seconds|requests|attempts)[,.;:]?$/) print t " " $(i+1)
      }
    }' "$1"
  } | awk 'NF && !seen[$0]++' | head -n 15 | paste -sd '|' - | sed 's/|/, /g'
}
if [[ -d "$memdir" ]]; then
  for f in "$memdir"/*.md; do
    [[ -e "$f" ]] || continue
    if [[ "$(body_words "$f")" -gt "$MEMORY_MAX_WORDS" ]]; then
      keep=$(keep_tokens "$f")
      memory_rel="memory/$(basename "$f")"
      finding advisory MEMORY_RECORD_OVERSIZE "$memory_rel" "> $MEMORY_MAX_WORDS body words — likely more than one fact: split current state, or move stable system knowledge to docs/ and remove the duplicate fact. Shape, never content: every name, value, command, and path survives somewhere under .agent/${keep:+ — keep at least: $keep}" "GROOM: $memory_rel > $MEMORY_MAX_WORDS body words — likely more than one fact: split current state, or move stable system knowledge to docs/ and remove the duplicate fact. Shape, never content: every name, value, command, and path survives somewhere under .agent/${keep:+ — keep at least: $keep}"
    fi
  done
fi
if [[ -s "$memory" ]]; then
  mem_entries=$(grep -c '^- \[' "$memory")
  if [[ "$mem_entries" -gt "$MEMORY_MAX_ENTRIES" ]]; then
    finding advisory MEMORY_INDEX_OVERSIZE memory.md "> $MEMORY_MAX_ENTRIES index entries — review for stale or superseded lines; move retired fact files to archive/ and drop their index lines, raise the threshold if all are live" "GROOM: memory.md > $MEMORY_MAX_ENTRIES index entries — review for stale or superseded lines; move retired fact files to archive/ and drop their index lines, raise the threshold if all are live"
  fi
fi
if [[ -e "$memdir/legacy.md" ]]; then
  finding block MEMORY_LEGACY_UNSPLIT memory/legacy.md "exists — split legacy.md into fact files" "GROOM: memory/legacy.md exists — split legacy.md into fact files"
fi
if learned_dir_active; then
  learned_rules=0
  learned_words=0
  while IFS= read -r learned_rec; do
    learned_rules=$((learned_rules + $(grep -c '^- ' "$learned_rec")))
    learned_words=$((learned_words + $(body_words "$learned_rec")))
  done < <(find "$learned_dir" -type f -name '*.md')
  if [[ "$learned_rules" -gt "$LEARNED_MAX_RULES" ]]; then
    finding advisory LEARNED_RULES_OVERSIZE rules/learned/ "> $LEARNED_MAX_RULES rules — merge near-duplicates; route area-specific gotchas to their area doc (see rules)" "GROOM: rules/learned/ > $LEARNED_MAX_RULES rules — merge near-duplicates; route area-specific gotchas to their area doc (see rules)"
  elif [[ "$learned_words" -gt "$LEARNED_MAX_WORDS" ]]; then
    finding advisory LEARNED_WORDS_OVERSIZE rules/learned/ "> $LEARNED_MAX_WORDS words under the rule count — entries are over the ~40-word target: compress them, or move domain detail to the matching docs/ file and keep a pointer" "GROOM: rules/learned/ > $LEARNED_MAX_WORDS words under the rule count — entries are over the ~40-word target: compress them, or move domain detail to the matching docs/ file and keep a pointer"
  fi
elif [[ -s "$learned" ]]; then
  if [[ "$(grep -c '^- ' "$learned")" -gt "$LEARNED_MAX_RULES" ]]; then
    finding advisory LEARNED_RULES_OVERSIZE rules/learned.md "> $LEARNED_MAX_RULES rules — merge near-duplicates; route area-specific gotchas to their area doc (see rules)" "GROOM: learned.md > $LEARNED_MAX_RULES rules — merge near-duplicates; route area-specific gotchas to their area doc (see rules)"
  elif [[ "$(body_words "$learned")" -gt "$LEARNED_MAX_WORDS" ]]; then
    finding advisory LEARNED_WORDS_OVERSIZE rules/learned.md "> $LEARNED_MAX_WORDS words under the rule count — entries are over the ~40-word target: compress them, or move domain detail to the matching docs/ file and keep a pointer" "GROOM: learned.md > $LEARNED_MAX_WORDS words under the rule count — entries are over the ~40-word target: compress them, or move domain detail to the matching docs/ file and keep a pointer"
  fi
fi
if [[ -d "$docs" ]]; then
  for doc in "$docs"/*.md "$docs"/*/*.md; do
    [[ -e "$doc" ]] || continue
    rel=${doc#"$docs"/}
    [[ "$rel" == "architecture.md" ]] && continue
    [[ "$rel" == references/* || "$rel" == */references/* ]] && continue
    if [[ "$(body_words "$doc")" -gt "$DOCS_MAX_WORDS" ]]; then
      finding advisory DOC_OVERSIZE "docs/$rel" "> $DOCS_MAX_WORDS body words — restructure without dropping facts: tighten in place (tables, one fact per line), or split into docs/<area>/ sub-docs, each with its own \"Read when:\" header and routing entry" "GROOM: docs/$rel > $DOCS_MAX_WORDS body words — restructure without dropping facts: tighten in place (tables, one fact per line), or split into docs/<area>/ sub-docs, each with its own \"Read when:\" header and routing entry"
    fi
  done
fi

doc_hook() { # the doc's own routing hook, from its opening lines
  head -n 5 "$1" | sed -n 's/^<!-- Read when: \(.*\) -->$/\1/p' | head -n 1
}
entry_block() { # the doc's routing entry in architecture.md ($1 arch, $2 rel)
  awk -v want="### \`$2\`" '
    $0 == want { inb = 1; next }
    inb && index($0, "### ") == 1 { exit }
    inb { print }
  ' "$1"
}
doc_headings() { # level-two ATX headings outside Markdown fenced code blocks
  awk '
    function fence_run(s, ch,    i) {
      for (i = 1; i <= length(s) && substr(s, i, 1) == ch; i++) { }
      return i - 1
    }
    {
      line = $0
      indent = 0
      while (indent < 3 && substr(line, 1, 1) == " ") {
        line = substr(line, 2)
        indent++
      }
      if (fenced) {
        run = fence_run(line, fence_char)
        rest = substr(line, run + 1)
        if (run >= fence_len && rest ~ /^[ \t]*$/) fenced = 0
        next
      }
      fence_char = substr(line, 1, 1)
      if (fence_char == "`" || fence_char == "~") {
        fence_len = fence_run(line, fence_char)
        if (fence_len >= 3) { fenced = 1; next }
      }
      if (line ~ /^## /) print substr(line, 4)
    }
  ' "$1"
}
if [[ -d "$docs" ]]; then
  for doc in "$docs"/*.md "$docs"/*/*.md; do
    [[ -e "$doc" ]] || continue
    rel=${doc#"$docs"/}
    [[ "$rel" == "architecture.md" ]] && continue
    [[ "$rel" == references/* || "$rel" == */references/* ]] && continue
    if ! head -n 5 "$doc" | grep -qF "Read when:"; then
      finding block DOC_HOOK_MISSING "docs/$rel" "missing its \"Read when:\" header — add a one-line routing hint" "INDEX: docs/$rel missing its \"Read when:\" header — add a one-line routing hint"
    fi
    if [[ -s "$arch" ]]; then
      entry_count=$(grep -cxF "### \`$rel\`" "$arch")
      if ! grep -qF "### \`$rel\`" "$arch"; then
        finding block DOC_ROUTE_MISSING "docs/$rel" "not in the architecture.md routing table — add an entry from its \"Read when:\" header" "INDEX: docs/$rel not in the architecture.md routing table — add an entry from its \"Read when:\" header"
      elif [[ "$entry_count" -gt 1 ]]; then
        finding block DOC_ROUTE_DUPLICATE "docs/$rel" "has $entry_count entries in architecture.md — keep exactly one, carrying the doc's own \"Read when:\" hook, and delete the rest" "INDEX: docs/$rel has $entry_count entries in architecture.md — keep exactly one, carrying the doc's own \"Read when:\" hook, and delete the rest"
      else
        block=$(entry_block "$arch" "$rel")
        entry_hook=$(printf '%s\n' "$block" | sed -n 's/^- \*\*Read when:\*\* //p' | head -n 1)
        own_hook=$(doc_hook "$doc")
        if [[ -n "$own_hook" && "$entry_hook" != "$own_hook" ]]; then
          finding block DOC_HOOK_MISMATCH "docs/$rel" "hook disagrees with its architecture.md entry — refresh both to the same text" "INDEX: docs/$rel hook disagrees with its architecture.md entry — refresh both to the same text"
        fi
        sections=$(printf '%s\n' "$block" | sed -n 's/^- \*\*Sections:\*\* //p' | head -n 1)
        missing=""
        while IFS= read -r heading; do
          [[ -n "$heading" ]] || continue
          printf '%s' "$sections" | grep -qF -- "$heading" || missing="$missing · $heading"
        done < <(doc_headings "$doc")
        if [[ -n "$missing" ]]; then
          finding block DOC_SECTIONS_MISSING "docs/$rel" "sections missing from its architecture.md entry:${missing# }" "INDEX: docs/$rel sections missing from its architecture.md entry:${missing# }"
        fi
      fi
    fi
  done
fi

if [[ -d "$docs" && ! -s "$arch" ]]; then
  for routing_candidate in "$docs"/*.md "$docs"/*/*.md; do
    [[ -e "$routing_candidate" ]] || continue
    routing_candidate_rel=${routing_candidate#"$docs"/}
    [[ "$routing_candidate_rel" == "architecture.md" ]] && continue
    [[ "$routing_candidate_rel" == references/* || "$routing_candidate_rel" == */references/* ]] && continue
    finding block ROUTING_TABLE_MISSING docs/architecture.md "missing/empty but docs/ holds routed documents - recreate the table with scripts/docs.sh new --name <placeholder> --read-when \"...\" using a name NOT already used in docs/ (it refuses to overwrite an existing doc; delete the placeholder's doc file and its table entry afterward), then add an entry for each existing routed doc" "REPAIR: docs/architecture.md missing/empty but docs/ holds routed documents - recreate the table with scripts/docs.sh new --name <placeholder> --read-when \"...\" using a name NOT already used in docs/ (it refuses to overwrite an existing doc; delete the placeholder's doc file and its table entry afterward), then add an entry for each existing routed doc"
    break
  done
fi

if [[ -s "$memory" ]]; then
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    if [[ ! -e "$agent/$target" ]]; then
      finding block MEMORY_TARGET_MISSING "$target" "memory.md indexes $target — file missing" "REPAIR: memory.md indexes $target — file missing"
    fi
  done < <(sed -nE 's|^- \[[^]]*\]\((memory/[^)]+)\).*|\1|p' "$memory")
fi
if [[ -d "$memdir" ]]; then
  for f in "$memdir"/*.md; do
    [[ -e "$f" ]] || continue
    name="memory/$(basename "$f")"
    if [[ ! -s "$memory" ]] \
      || ! sed -nE 's|^- \[[^]]*\]\((memory/[^)]+)\).*|\1|p' "$memory" | grep -qxF "$name"; then
      finding block MEMORY_RECORD_UNINDEXED "$name" "has no index line in memory.md" "REPAIR: $name has no index line in memory.md"
    fi
  done
fi

for settings in "$root/.claude/settings.json" "$root/.claude/settings.local.json"; do
  [[ -s "$settings" ]] || continue
  if grep -q '"autoMemoryEnabled"[[:space:]]*:[[:space:]]*true' "$settings"; then
    settings_rel=${settings#"$root"/}
    finding block NATIVE_MEMORY_ENABLED "$settings_rel" "sets autoMemoryEnabled true — set it false and harvest any silo (see retro)" "REPAIR: $settings_rel sets autoMemoryEnabled true — set it false and harvest any silo (see retro)"
  fi
done
if [[ -d "$root/.claude" ]] \
  && ! grep -qs '"autoMemoryEnabled"' \
    "$root/.claude/settings.json" "$root/.claude/settings.local.json" \
    "${HOME:-/nonexistent}/.claude/settings.json"; then
  finding block NATIVE_MEMORY_UNSET .claude/ "present but autoMemoryEnabled is set nowhere — add \"autoMemoryEnabled\": false to .claude/settings.json so it requests the tool's own store off" "REPAIR: .claude/ present but autoMemoryEnabled is set nowhere — add \"autoMemoryEnabled\": false to .claude/settings.json so it requests the tool's own store off"
fi

missing=""
set -f
for tool in $PROBE_TOOLS; do
  command -v "$tool" >/dev/null 2>&1 || missing="$missing, $tool"
done
set +f
if [[ -n "$missing" ]]; then
  fallbacks=""
  case " $missing" in *" rg"*) fallbacks="grep -rn" ;; esac
  case " $missing" in *" fd"*) fallbacks="${fallbacks:+$fallbacks / }find" ;; esac
  line="TOOLS: not installed: ${missing#, }"
  [[ -n "$fallbacks" ]] && line="$line — use $fallbacks instead"
  if [[ "$format" == text ]]; then
    printf '%s\n' "$line"
  fi
fi
if ! sed --version >/dev/null 2>&1; then
  if [[ "$format" == text ]]; then
    echo "TOOLS: sed/grep are BSD flavor — sed -i requires ''"
  fi
fi

load_total=0
load_detail=""
load_add() {
  [[ -s "$2" ]] || return 0
  lw=$(words "$2")
  load_total=$((load_total + lw))
  load_detail="$load_detail, $1 $lw"
}
load_add entry "${entrypoints[0]-}"
load_add contract "$contract"
load_add learned "$learned"
load_add purpose "$purpose"
load_add memory "$memory"
load_add routing "$arch"
if [[ "$format" == text && "$load_total" -gt 0 ]]; then
  tailwords=0
  [[ -n "${recent:-}" ]] && tailwords=$(printf '%s' "$recent" | wc -w | tr -d '[:space:]')
  echo "LOAD: always-loaded set ~$load_total words (${load_detail#, }) + log tail ~$tailwords"
fi

payload_total=0
payload_detail=""
payload_add() { # $1: label  $2: file path
  [[ -s "$2" ]] || return 0
  local marker fbytes
  marker=$(printf '\n==== %s ====\n' "${2#"$root"/}" | wc -c | tr -d '[:space:]')
  fbytes=$((marker + $(wc -c <"$2" | tr -d '[:space:]')))
  payload_total=$((payload_total + fbytes))
  payload_detail="$payload_detail, $1 $fbytes"
}
if [[ "$load_mode" == generated ]]; then
  payload_add purpose "$purpose"
  payload_add memory "$memory"
else
  payload_add learned "$learned"
  payload_add contract "$contract"
  payload_add purpose "$purpose"
  payload_add memory "$memory"
fi
if [[ "$format" == text && "$payload_total" -gt 0 ]]; then
  echo "PAYLOAD: --load would write $payload_total bytes of a $PAYLOAD_MAX_BYTES byte budget (${payload_detail#, })"
fi

if [[ "$load" -eq 1 ]]; then
  if [[ "$load_mode" == generated ]]; then
    if [[ "$payload_total" -gt "$PAYLOAD_MAX_BYTES" ]]; then
      finding block LOAD_PAYLOAD_OVERSIZE purpose.md "--load payload is $payload_total bytes, over the $PAYLOAD_MAX_BYTES byte budget — open these two files directly this session: ${purpose#"$root"/}, ${memory#"$root"/}" "REPAIR: --load payload is $payload_total bytes, over the $PAYLOAD_MAX_BYTES byte budget — open these two files directly this session: ${purpose#"$root"/}, ${memory#"$root"/}"
    else
      echo "Rule bodies are not printed here — read every page listed in .agent/indexes/current.md."
      for f in "$purpose" "$memory"; do
        [[ -s "$f" ]] || continue
        printf '\n==== %s ====\n' "${f#"$root"/}"
        cat "$f"
      done
    fi
  else
    if [[ "$indexes" == generated ]]; then
      echo "Indexer missing: purpose.md says indexes: generated but scripts/index.sh is not installed, so the cache under .agent/indexes/ cannot be rebuilt or verified — the canonical files print below; run node.sh update to reinstall the indexer."
    fi
    if [[ "$payload_total" -gt "$PAYLOAD_MAX_BYTES" ]]; then
      finding block LOAD_PAYLOAD_OVERSIZE rules/learned.md "--load payload is $payload_total bytes, over the $PAYLOAD_MAX_BYTES byte budget — open these four files directly this session: ${learned#"$root"/}, ${contract#"$root"/}, ${purpose#"$root"/}, ${memory#"$root"/}" "REPAIR: --load payload is $payload_total bytes, over the $PAYLOAD_MAX_BYTES byte budget — open these four files directly this session: ${learned#"$root"/}, ${contract#"$root"/}, ${purpose#"$root"/}, ${memory#"$root"/}"
    else
      for f in "$learned" "$contract" "$purpose" "$memory"; do
        [[ -s "$f" ]] || continue
        printf '\n==== %s ====\n' "${f#"$root"/}"
        cat "$f"
      done
    fi
  fi
fi

exit 0
