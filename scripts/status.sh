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
HOOK_MAX_BYTES=10000
MEMORY_INDEX_BYTES=5000
# Not a tunable: the worker-load contract revision this script implements
# (scripts/docs/worker-contract.md). node.sh describe reads it from here.
# shellcheck disable=SC2034 # read by node.sh describe, not by this script
WORKER_CONTRACT=1

root="."
load=0
tail_arg=""
format=text
while [ $# -gt 0 ]; do
  case "$1" in
  -h | --help)
    cat <<'EOF'
Usage: status.sh [--load] [--tail <n>] [--format tsv] [root]

Prints one line per finding: GROOM: (a file crossed a grooming
threshold), REPAIR: (a canonical file or bootstrap step is missing),
INDEX: (a docs/ file and the routing table disagree), plus advisory
TOOLS:, LOAD:, PAYLOAD:, and HOOK: lines, then the recent session-log
entries under a "==== .agent/session-log.md, newest <n> entries ===="
marker. No finding prints on pass.

--load prints the always-loaded set between the findings and the log tail,
each file under a "==== <path> ====" marker, so the bootstrap is one call.
In manual mode (indexes: manual, the default) that set is rules/learned.md,
rules/contract.md, purpose.md, memory.md. In generated mode (indexes:
generated) it is purpose.md and memory.md only, preceded by the index pages
to open (index.sh check FRESH) or the canonical paths to read when the
cache is stale. PAYLOAD: reports the exact bytes --load writes, every line
included, against PAYLOAD_MAX_BYTES; over budget, --load prints one line
(REPAIR:, naming the mode's paths) in place of the files and pages. HOOK:
prints when the session-start hook could not deliver this output whole.

--tail <n> prints the newest n session-log entries in place of TAIL_LINES;
0 prints none.

root defaults to . — checks <root>/.agent/ and exits 0 whatever it finds. A
root holding no .agent/ is a usage error and exits 1.

--format tsv prints findings only as severity<TAB>code<TAB>path<TAB>message.
Tabs, carriage returns, and newlines in fields are escaped. It cannot be
combined with --load.
EOF
    exit 0 ;;
  --load) load=1 ;;
  --tail)
    case "${2:-}" in
    '' | *[!0-9]*)
      echo "status.sh: --tail requires a whole number" >&2
      exit 1 ;;
    esac
    tail_arg=$2
    shift ;;
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

# Text output is collected in notes and written at the end, so PAYLOAD: can
# count every byte --load writes before any of it is written.
notes=""
finding() { # severity code path message default-text
  if [ "$format" = tsv ]; then
    escape_tsv "$3"; finding_path=$REPLY
    escape_tsv "$4"; finding_message=$REPLY
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$finding_path" "$finding_message"
  else
    notes+="$5"$'\n'
  fi
}

agent="$root/.agent"
if [ ! -d "$agent" ]; then
  echo "status.sh: no .agent directory at $agent — run from the node's project root, or pass that root as an argument" >&2
  exit 1
fi

conf="$agent/scripts/status.conf"
conf_lines=()
if [[ -f "$conf" && -r "$conf" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in '' | '#'*) ;; *) conf_lines+=("$line") ;; esac
  done <"$conf"
fi
conf_get() { # $1: key — sets REPLY
  local line
  REPLY=""
  for line in ${conf_lines[@]+"${conf_lines[@]}"}; do
    case "$line" in
    "$1="*)
      REPLY=${line#*=}
      REPLY=${REPLY%"${REPLY##*[![:space:]]}"}
      return 0 ;;
    esac
  done
}
conf_repair_messages=()
conf_num() { # $1: key name — the current value is its shipped default
  local v
  conf_get "$1"
  v=$REPLY
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
  conf_num HOOK_MAX_BYTES
  conf_num MEMORY_INDEX_BYTES
  conf_get PROBE_TOOLS
  [[ -n "$REPLY" ]] && PROBE_TOOLS=$REPLY
fi
# MEMORY_INDEX_BYTES is half of HOOK_MAX_BYTES unless the conf pins it, so a
# node that lowers its hook limit moves the memory trigger with it.
conf_get MEMORY_INDEX_BYTES
[[ -n "$REPLY" ]] || MEMORY_INDEX_BYTES=$((HOOK_MAX_BYTES / 2))
[[ -n "$tail_arg" ]] && TAIL_LINES=$tail_arg
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

# shellcheck disable=SC2016 # an awk program
strip_awk='
  FNR == 1 { incm = 0; infm = ($0 == "---"); if (infm) next }
  infm { if ($0 == "---") infm = 0; next }
  incm { if (/-->/) { incm = 0; sub(/.*-->/, "") } else next }
  { gsub(/<!--.*-->/, "") }
  /<!--/ { incm = 1; sub(/<!--.*/, "") }
'
body_words() { awk "$strip_awk"'{ print }' "$@" | wc -w | tr -d '[:space:]'; }

# wc -w counts words by the caller's locale, so no awk program repeats its
# count on every platform. This one counts each run of visible ASCII and each
# other byte as a word, which is never less than wc -w. One process clears
# every file whose bound is inside the limit, and body_words counts the rest.
bound_awk="$strip_awk"'{ bound += gsub(/[^ -~\t]/, " "); bound += NF }'
may_exceed() { # $1: word limit  $2...: files — prints the files whose body may pass it
  local limit=$(($1)) f
  local readable=()
  shift
  for f in "$@"; do
    if [[ -f "$f" && -r "$f" ]]; then readable+=("$f"); else printf '%s\n' "$f"; fi
  done
  [[ "${#readable[@]}" -gt 0 ]] || return 0
  LC_ALL=C awk -v limit="$limit" '
    FNR == 1 { if (bound > limit) print path; path = FILENAME; bound = 0 }
    '"$bound_awk"'
    END { if (bound > limit) print path }
  ' "${readable[@]}"
}

learned_dir_active() {
  [[ -d "$learned_dir" ]] && [[ ! -L "$learned_dir" ]] || return 1
  [[ -n "$(find "$learned_dir" -type f -name '*.md' -print -quit 2>/dev/null)" ]]
}

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
memory_files=()
if [[ -d "$memdir" ]]; then
  for f in "$memdir"/*.md; do
    [[ -e "$f" ]] && memory_files+=("$f")
  done
fi
if [[ "${#memory_files[@]}" -gt 0 ]]; then
  while IFS= read -r f; do
    if [[ "$(body_words "$f")" -gt "$MEMORY_MAX_WORDS" ]]; then
      keep=$(keep_tokens "$f")
      memory_rel="memory/${f##*/}"
      finding advisory MEMORY_RECORD_OVERSIZE "$memory_rel" "> $MEMORY_MAX_WORDS body words — likely more than one fact: split current state, or move stable system knowledge to docs/ and remove the duplicate fact. Shape, never content: every name, value, command, and path survives somewhere under .agent/${keep:+ — keep at least: $keep}" "GROOM: $memory_rel > $MEMORY_MAX_WORDS body words — likely more than one fact: split current state, or move stable system knowledge to docs/ and remove the duplicate fact. Shape, never content: every name, value, command, and path survives somewhere under .agent/${keep:+ — keep at least: $keep}"
    fi
  done < <(may_exceed "$MEMORY_MAX_WORDS" "${memory_files[@]}")
fi
if [[ -s "$memory" ]]; then
  mem_entries=$(grep -c '^- \[' "$memory")
  if [[ "$mem_entries" -gt "$MEMORY_MAX_ENTRIES" ]]; then
    finding advisory MEMORY_INDEX_OVERSIZE memory.md "> $MEMORY_MAX_ENTRIES index entries — review for stale or superseded lines; move retired fact files to archive/ and drop their index lines, raise the threshold if all are live" "GROOM: memory.md > $MEMORY_MAX_ENTRIES index entries — review for stale or superseded lines; move retired fact files to archive/ and drop their index lines, raise the threshold if all are live"
  fi
  mem_bytes=$(wc -c <"$memory" | tr -d '[:space:]')
  if [[ "$mem_bytes" -gt "$MEMORY_INDEX_BYTES" ]]; then
    finding advisory MEMORY_INDEX_BYTES_OVERSIZE memory.md "is $mem_bytes bytes, over MEMORY_INDEX_BYTES ($MEMORY_INDEX_BYTES, half the session-start hook's HOOK_MAX_BYTES) — every session loads it whole: shorten hooks to one clause, retire superseded lines to archive/, or raise the threshold in status.conf if all are live and short" "GROOM: memory.md is $mem_bytes bytes, over MEMORY_INDEX_BYTES ($MEMORY_INDEX_BYTES, half the session-start hook's HOOK_MAX_BYTES) — every session loads it whole: shorten hooks to one clause, retire superseded lines to archive/, or raise the threshold in status.conf if all are live and short"
  fi
fi
if [[ -e "$memdir/legacy.md" ]]; then
  finding block MEMORY_LEGACY_UNSPLIT memory/legacy.md "exists — split legacy.md into fact files" "GROOM: memory/legacy.md exists — split legacy.md into fact files"
fi
if learned_dir_active; then
  learned_files=()
  while IFS= read -r learned_rec; do
    learned_files+=("$learned_rec")
  done < <(find "$learned_dir" -type f -name '*.md')
  IFS=' ' read -r learned_rules learned_bound < <(LC_ALL=C awk '
    /^- / { rules++ }
    '"$bound_awk"'
    END { printf "%d %d\n", rules, bound }
  ' "${learned_files[@]}")
  if [[ "$learned_rules" -gt "$LEARNED_MAX_RULES" ]]; then
    finding advisory LEARNED_RULES_OVERSIZE rules/learned/ "> $LEARNED_MAX_RULES rules — merge near-duplicates; route area-specific gotchas to their area doc (see rules)" "GROOM: rules/learned/ > $LEARNED_MAX_RULES rules — merge near-duplicates; route area-specific gotchas to their area doc (see rules)"
  elif [[ "$learned_bound" -gt "$LEARNED_MAX_WORDS" && "$(body_words "${learned_files[@]}")" -gt "$LEARNED_MAX_WORDS" ]]; then
    finding advisory LEARNED_WORDS_OVERSIZE rules/learned/ "> $LEARNED_MAX_WORDS words under the rule count — entries are over the ~40-word target: compress them, or move domain detail to the matching docs/ file and keep a pointer" "GROOM: rules/learned/ > $LEARNED_MAX_WORDS words under the rule count — entries are over the ~40-word target: compress them, or move domain detail to the matching docs/ file and keep a pointer"
  fi
elif [[ -s "$learned" ]]; then
  if [[ "$(grep -c '^- ' "$learned")" -gt "$LEARNED_MAX_RULES" ]]; then
    finding advisory LEARNED_RULES_OVERSIZE rules/learned.md "> $LEARNED_MAX_RULES rules — merge near-duplicates; route area-specific gotchas to their area doc (see rules)" "GROOM: learned.md > $LEARNED_MAX_RULES rules — merge near-duplicates; route area-specific gotchas to their area doc (see rules)"
  elif [[ "$(body_words "$learned")" -gt "$LEARNED_MAX_WORDS" ]]; then
    finding advisory LEARNED_WORDS_OVERSIZE rules/learned.md "> $LEARNED_MAX_WORDS words under the rule count — entries are over the ~40-word target: compress them, or move domain detail to the matching docs/ file and keep a pointer" "GROOM: learned.md > $LEARNED_MAX_WORDS words under the rule count — entries are over the ~40-word target: compress them, or move domain detail to the matching docs/ file and keep a pointer"
  fi
fi
doc_files=()
doc_rels=()
if [[ -d "$docs" ]]; then
  for doc in "$docs"/*.md "$docs"/*/*.md; do
    [[ -e "$doc" ]] || continue
    rel=${doc#"$docs"/}
    [[ "$rel" == "architecture.md" ]] && continue
    [[ "$rel" == references/* || "$rel" == */references/* ]] && continue
    doc_files+=("$doc")
    doc_rels+=("$rel")
  done
fi
if [[ "${#doc_files[@]}" -gt 0 ]]; then
  while IFS= read -r doc; do
    if [[ "$(body_words "$doc")" -gt "$DOCS_MAX_WORDS" ]]; then
      rel=${doc#"$docs"/}
      finding advisory DOC_OVERSIZE "docs/$rel" "> $DOCS_MAX_WORDS body words — restructure without dropping facts: tighten in place (tables, one fact per line), or split into docs/<area>/ sub-docs, each with its own \"Read when:\" header and routing entry" "GROOM: docs/$rel > $DOCS_MAX_WORDS body words — restructure without dropping facts: tighten in place (tables, one fact per line), or split into docs/<area>/ sub-docs, each with its own \"Read when:\" header and routing entry"
    fi
  done < <(may_exceed "$DOCS_MAX_WORDS" "${doc_files[@]}")
fi

# One pass over the routing table and every routed doc. Stdin lists the docs'
# table names in argument order, a doc that cannot be read is passed as
# /dev/null, and each output line is a code, the doc's number, and a detail.
# shellcheck disable=SC2016 # an awk program
routing_awk='
  function fence_run(s, ch,    i) {
    for (i = 1; i <= length(s) && substr(s, i, 1) == ch; i++) { }
    return i - 1
  }
  function listed(want,    i) {
    if (want in count) return 1
    for (i = 1; i <= nentry; i++) if (index(entry[i], want)) return 1
    return 0
  }
  BEGIN {
    arg = 1
    entry_hook = "- **Read when:** "
    entry_sections = "- **Sections:** "
    doc_hook = "<!-- Read when: "
  }
  NR == FNR { rel[++docs] = $0; next }
  FNR == 1 {
    for (arg++; arg < ARGC && ARGV[arg] != FILENAME; arg++) { }
    doc = arg - 2
    fenced = 0
  }
  doc == 0 {
    if (index($0, "### `")) entry[++nentry] = $0
    if (index($0, "### ") == 1) { current = $0; count[current]++ }
    else if (index($0, entry_hook) == 1 && !(current in hook)) hook[current] = substr($0, length(entry_hook) + 1)
    else if (index($0, entry_sections) == 1 && !(current in sections)) sections[current] = substr($0, length(entry_sections) + 1)
    next
  }
  FNR <= 5 {
    if (index($0, "Read when:")) hooked[doc] = 1
    if (!(doc in own) && index($0, doc_hook) == 1 && length($0) >= length(doc_hook) + 4 && substr($0, length($0) - 3) == " -->")
      own[doc] = substr($0, length(doc_hook) + 1, length($0) - length(doc_hook) - 4)
  }
  { # level-two ATX headings outside Markdown fenced code blocks
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
    if (line ~ /^## ./) heading[doc, ++headings[doc]] = substr(line, 4)
  }
  END {
    for (d = 1; d <= docs; d++) {
      if (!(d in hooked)) print "DOC_HOOK_MISSING", d
      if (!routed) continue
      want = "### `" rel[d] "`"
      if (!listed(want)) { print "DOC_ROUTE_MISSING", d; continue }
      if (count[want] > 1) { print "DOC_ROUTE_DUPLICATE", d, count[want]; continue }
      if (own[d] != "" && hook[want] != own[d]) print "DOC_HOOK_MISMATCH", d
      missing = ""
      for (i = 1; i <= headings[d]; i++)
        if (!index(sections[want], heading[d, i])) missing = missing " · " heading[d, i]
      if (missing != "") print "DOC_SECTIONS_MISSING", d, missing
    }
  }
'
doc_routing() {
  local routed=0 table=/dev/null doc
  local inputs=()
  if [[ -s "$arch" ]]; then
    routed=1
    [[ -f "$arch" && -r "$arch" ]] && table=$arch
  fi
  for doc in "${doc_files[@]}"; do
    [[ -f "$doc" && -r "$doc" ]] || doc=/dev/null
    inputs+=("$doc")
  done
  printf '%s\n' "${doc_rels[@]}" | LC_ALL=C awk -v routed="$routed" "$routing_awk" - "$table" "${inputs[@]}"
}
if [[ "${#doc_files[@]}" -gt 0 ]]; then
  while IFS= read -r line; do
    code=${line%% *}
    detail=${line#* }
    rel=${doc_rels[${detail%% *} - 1]}
    detail=${detail#* }
    case "$code" in
    DOC_HOOK_MISSING)
      finding block "$code" "docs/$rel" "missing its \"Read when:\" header — add a one-line routing hint" "INDEX: docs/$rel missing its \"Read when:\" header — add a one-line routing hint" ;;
    DOC_ROUTE_MISSING)
      finding block "$code" "docs/$rel" "not in the architecture.md routing table — add an entry from its \"Read when:\" header" "INDEX: docs/$rel not in the architecture.md routing table — add an entry from its \"Read when:\" header" ;;
    DOC_ROUTE_DUPLICATE)
      finding block "$code" "docs/$rel" "has $detail entries in architecture.md — keep exactly one, carrying the doc's own \"Read when:\" hook, and delete the rest" "INDEX: docs/$rel has $detail entries in architecture.md — keep exactly one, carrying the doc's own \"Read when:\" hook, and delete the rest" ;;
    DOC_HOOK_MISMATCH)
      finding block "$code" "docs/$rel" "hook disagrees with its architecture.md entry — refresh both to the same text" "INDEX: docs/$rel hook disagrees with its architecture.md entry — refresh both to the same text" ;;
    DOC_SECTIONS_MISSING)
      finding block "$code" "docs/$rel" "sections missing from its architecture.md entry:${detail# }" "INDEX: docs/$rel sections missing from its architecture.md entry:${detail# }" ;;
    esac
  done < <(doc_routing)
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

memory_targets() { sed -nE 's|^- \[[^]]*\]\((memory/[^)]+)\).*|\1|p' "$memory"; }
if [[ -s "$memory" ]]; then
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    if [[ ! -e "$agent/$target" ]]; then
      finding block MEMORY_TARGET_MISSING "$target" "memory.md indexes $target — file missing" "REPAIR: memory.md indexes $target — file missing"
    fi
  done < <(memory_targets)
fi
if [[ "${#memory_files[@]}" -gt 0 ]]; then
  while IFS= read -r name; do
    finding block MEMORY_RECORD_UNINDEXED "$name" "has no index line in memory.md" "REPAIR: $name has no index line in memory.md"
  done < <({
    [[ -s "$memory" ]] && memory_targets | sed 's/^/indexed /'
    printf 'file memory/%s\n' "${memory_files[@]##*/}"
  } | LC_ALL=C awk '
    { name = substr($0, index($0, " ") + 1) }
    /^indexed / { indexed[name] = 1; next }
    !(name in indexed) { print name }
  ')
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
  notes+="$line"$'\n'
fi
if ! sed --version >/dev/null 2>&1; then
  notes+="TOOLS: sed/grep are BSD flavor — sed -i requires ''"$'\n'
fi

# Everything below is text output only: findings-only TSV is complete.
[[ "$format" == tsv ]] && exit 0

count_bytes() { local LC_ALL=C; nbytes=${#1}; }
# Restoring an LC_ALL that names no installed locale makes bash warn, so the
# redirect sits outside the function that sets it.
bytes_of() { count_bytes "$1" 2>/dev/null; } # sets nbytes
file_bytes() { wc -c <"$1" | tr -d '[:space:]'; }

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

if [[ "$load_mode" == generated ]]; then
  load_files=("$purpose" "$memory")
  load_labels=(purpose memory)
else
  load_files=("$learned" "$contract" "$purpose" "$memory")
  load_labels=(learned contract purpose memory)
fi
files_bytes=0
files_detail=""
for load_i in "${!load_files[@]}"; do
  f=${load_files[$load_i]}
  [[ -s "$f" ]] || continue
  bytes_of $'\n'"==== ${f#"$root"/} ===="$'\n'
  fbytes=$((nbytes + $(file_bytes "$f")))
  files_bytes=$((files_bytes + fbytes))
  files_detail="$files_detail, ${load_labels[$load_i]} $fbytes"
done

# What --load prints ahead of the files. In generated mode it is the index
# pages to open when index.sh check reads the cache as FRESH, and the
# canonical paths otherwise. check writes nothing, so neither does --load.
notice=""
notice_label=""
if [[ "$load_mode" == generated ]]; then
  pages=""
  if [[ "$(bash "$indexer" check --root "$root" 2>/dev/null)" == FRESH ]]; then
    pages=$(sed -n '/^READ: /p' "$agent/indexes/current.md" 2>/dev/null)
  fi
  if [[ -n "$pages" ]]; then
    notice="Index pages: open every page listed here before the work. They carry the rule bodies and the routes catalog, which this output does not print. Paths are relative to the folder that holds .agent/."$'\n'"$pages"$'\n'
  else
    notice="Index cache is stale or missing, so no page is listed. Run \`bash .agent/scripts/index.sh ensure\` and open the file it prints: its READ: lines name the pages. A subagent never runs it, because it writes: as a subagent, read .agent/rules/ and .agent/docs/architecture.md directly this session."$'\n'
  fi
  bytes_of "$notice"
  notice_label=", index $nbytes"
elif [[ "$indexes" == generated ]]; then
  notice="Indexer missing: purpose.md says indexes: generated but scripts/index.sh is not installed, so the cache under .agent/indexes/ cannot be rebuilt or verified — the canonical files print below; run node.sh update to reinstall the indexer."$'\n'
fi
bytes_of "$notice"
notice_bytes=$nbytes

tail_for() { # $1: entry count — sets tail_text and tail_words
  local entries="" count
  tail_text=""
  tail_words=0
  if [[ -s "$log" && "$1" -gt 0 ]]; then
    entries=$(grep '^- \[' "$log" | tail -n "$1")
  fi
  [[ -n "$entries" ]] || return 0
  count=$(printf '%s\n' "$entries" | wc -l | tr -d '[:space:]')
  tail_words=$(printf '%s' "$entries" | wc -w | tr -d '[:space:]')
  tail_text=$'\n'"==== ${log#"$root"/}, newest $count entries ===="$'\n'"$entries"$'\n'
}

load_line_for() { # $1: tail words — sets REPLY
  REPLY=""
  [[ "$load_total" -gt 0 ]] || return 0
  REPLY="LOAD: always-loaded set ~$load_total words (${load_detail#, }) + log tail ~$1"$'\n'
}

payload_line_for() { # $1: total bytes  $2: tail bytes — sets REPLY
  REPLY=""
  [[ "$files_bytes" -gt 0 ]] || return 0
  REPLY="PAYLOAD: --load would write $1 bytes of a $PAYLOAD_MAX_BYTES byte budget (notes $(($1 - notice_bytes - files_bytes - $2))$notice_label$files_detail, tail $2)"$'\n'
}

# settle FIXED TAIL_BYTES [HOOK_TEXT_FN] — the PAYLOAD: line counts itself
# and the HOOK: line, whose digits change their own length, so the total is
# recomputed until it stops moving. Each pass can only grow it.
settle() {
  local fixed=$1 tb=$2 fn=${3:-} total next
  total=$fixed
  for _ in 1 2 3 4 5 6 7 8; do
    payload_line_for "$total" "$tb"; settled_payload=$REPLY
    settled_hook=""
    if [[ -n "$fn" ]]; then "$fn" "$total"; settled_hook=$REPLY; fi
    bytes_of "$settled_payload$settled_hook"
    next=$((fixed + nbytes))
    [[ "$next" -eq "$total" ]] && break
    total=$next
  done
  settled_total=$total
}

# The session-start hook prints its own header line ahead of this output and
# cuts to a pointer line past HOOK_MAX_BYTES, retrying once with --tail 0.
hooks_line=$(grep -m1 '^  hooks:' "$purpose" 2>/dev/null)
hook_on=0
if [[ -f "$agent/scripts/session-start.sh" && "$hooks_line" != *"hooks: none"* && "$files_bytes" -gt 0 ]]; then
  hook_on=1
fi
hook_header_bytes() { # $1: full | tail0
  local h
  h=$(bash "$agent/scripts/session-start.sh" --header "$1" 2>/dev/null) || h=""
  [[ -n "$h" ]] || { echo 0; return; }
  bytes_of "$h"
  echo $((nbytes + 1))
}

tail_for "$TAIL_LINES"
main_tail=$tail_text
bytes_of "$main_tail"
main_tail_bytes=$nbytes
load_line_for "$tail_words"
main_load_line=$REPLY
bytes_of "$notes$main_load_line"
main_fixed=$((nbytes + notice_bytes + files_bytes + main_tail_bytes))
settle "$main_fixed" "$main_tail_bytes"

hook_line=""
if [[ "$hook_on" -eq 1 ]]; then
  header_full=$(hook_header_bytes full)
  if [[ "$header_full" -gt 0 && $((settled_total + header_full)) -gt "$HOOK_MAX_BYTES" ]]; then
    hook_fallback="prints a pointer line in place of this output"
    if [[ "$TAIL_LINES" -gt 0 && "$main_tail_bytes" -gt 0 ]]; then
      header_tail0=$(hook_header_bytes tail0)
      tail_for 0
      load_line_for 0
      bytes_of "$notes$REPLY"
      t0_fixed=$((nbytes + notice_bytes + files_bytes))
      settle "$t0_fixed" 0
      if [[ "$header_tail0" -gt 0 && $((settled_total + header_tail0)) -le "$HOOK_MAX_BYTES" ]]; then
        hook_fallback="delivers it without the session-log tail (--tail 0, $settled_total bytes)"
      fi
    fi
    hook_mem_bytes=0
    [[ -s "$memory" ]] && hook_mem_bytes=$(file_bytes "$memory")
    hook_text_for() { # $1: total bytes — sets REPLY
      REPLY="HOOK: the session-start hook adds a $header_full-byte header to these $1 bytes, $(($1 + header_full - HOOK_MAX_BYTES)) over its HOOK_MAX_BYTES limit of $HOOK_MAX_BYTES, so it $hook_fallback. Two levers shrink it: TAIL_LINES in status.conf (the tail is $main_tail_bytes bytes here) and the memory index (memory.md is $hook_mem_bytes bytes, MEMORY_INDEX_BYTES $MEMORY_INDEX_BYTES)."$'\n'
    }
    settle "$main_fixed" "$main_tail_bytes" hook_text_for
    hook_line=$settled_hook
  fi
fi
payload_line=$settled_payload
payload_total=$settled_total

printf '%s' "$notes$main_load_line$payload_line$hook_line"
if [[ "$load" -eq 1 ]]; then
  if [[ "$payload_total" -gt "$PAYLOAD_MAX_BYTES" ]]; then
    if [[ "$load_mode" == generated ]]; then
      repair="--load payload is $payload_total bytes, over the $PAYLOAD_MAX_BYTES byte budget — open these two files directly this session: ${purpose#"$root"/}, ${memory#"$root"/}"
    else
      repair="--load payload is $payload_total bytes, over the $PAYLOAD_MAX_BYTES byte budget — open these four files directly this session: ${learned#"$root"/}, ${contract#"$root"/}, ${purpose#"$root"/}, ${memory#"$root"/}"
    fi
    printf 'REPAIR: %s\n' "$repair"
  else
    printf '%s' "$notice"
    for f in "${load_files[@]}"; do
      [[ -s "$f" ]] || continue
      printf '\n==== %s ====\n' "${f#"$root"/}"
      cat "$f"
    done
  fi
fi
printf '%s' "$main_tail"

exit 0
