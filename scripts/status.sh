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
ENTRYPOINT_MAX_WORDS=600
TAIL_LINES=25
PROBE_TOOLS="rg fd jq gh python3 curl tree"
PAYLOAD_MAX_BYTES=30000

root="."
load=0
for arg in "$@"; do
  case "$arg" in
  -h | --help)
    cat <<'EOF'
Usage: status.sh [--load] [root]

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
EOF
    exit 0 ;;
  --load) load=1 ;;
  *) root="$arg" ;;
  esac
done

agent="$root/.agent"
if [ ! -d "$agent" ]; then
  echo "status.sh: no .agent directory at $agent — run from the node's project root, or pass that root as an argument" >&2
  exit 1
fi

conf="$agent/scripts/status.conf"
conf_get() { sed -n "s/^$1=//p" "$conf" 2>/dev/null | head -n 1 | sed 's/[[:space:]]*$//'; }
conf_repairs=""
conf_num() { # $1: key name — the current value is its shipped default
  local v
  v=$(conf_get "$1")
  [[ -n "$v" ]] || return 0
  case "$v" in
  *[!0-9]*)
    conf_repairs="${conf_repairs}REPAIR: status.conf $1=$v is not a whole number — the default ${!1} is in use; fix the line, which takes digits only (no inline comment, no units)"$'\n'
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

if [[ -s "$log" ]]; then
  recent=$(grep '^- \[' "$log" | tail -n "$TAIL_LINES")
  if [[ -n "$recent" ]]; then
    printf '%s\n\n' "$recent"
  fi
fi

[[ -n "$conf_repairs" ]] && printf '%s' "$conf_repairs"

[[ -s "$memory" ]] || echo "REPAIR: memory.md missing/empty"
[[ -s "$log" ]] || echo "REPAIR: session-log.md missing/empty"
[[ -s "$contract" ]] || echo "REPAIR: rules/contract.md missing/empty — restore it, the entry point loads it every session"
if ! learned_dir_active && [[ ! -s "$learned" ]]; then
  echo "REPAIR: rules/learned/ missing/empty — restore the records, or rules/learned.md on a node that keeps no record directory; the entry point loads them every session"
fi
if ! head -n 10 "$purpose" 2>/dev/null | grep -qF "dot-agent:"; then
  echo "REPAIR: purpose.md missing dot-agent frontmatter — restore manifest"
fi

migration_target_line=$(grep -m1 '^  migration_target:' "$purpose" 2>/dev/null)
if [[ -n "$migration_target_line" ]]; then
  migration_target=$(printf '%s\n' "$migration_target_line" | sed -E 's/^[[:space:]]*migration_target:[[:space:]]*"?([^"[:space:]]*)"?.*/\1/')
  echo "REPAIR: purpose.md has migration_target \"$migration_target\" pending — run node.sh finalize to stamp version $migration_target and clear migration_target"
fi

if [[ -s "$contract" ]]; then
  guardrails=$(awk '/^## Project guardrails/ { inb = 1; next }
                    inb && /^## / { exit }
                    inb { print }' "$contract")
  if printf '%s\n' "$guardrails" | grep -qE '^- .*<[^>]* [^>]*>'; then
    echo "REPAIR: contract.md Project guardrails still holds template placeholders — fill them with this project's exact commands"
  fi
  if grep -q '^## Quality bar' "$contract"; then
    echo "REPAIR: contract.md still contains ## Quality bar — split it into rules/quality-bar.md so it loads on demand, not every session"
  elif [[ ! -s "$qualitybar" ]]; then
    echo "REPAIR: rules/quality-bar.md missing — the verifier rubric was never split out of the preset"
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
      echo "REPAIR: ${other#"$root"/} differs from ${first#"$root"/} — entry points must stay identical; mirror the edit"
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
    echo "GROOM: ${ep#"$root"/} carries the section \"$extra\" — an entry point is its title and the load path, nothing else: move that content to rules/contract.md's Project guardrails, purpose.md, or a routed doc, and mirror the removal to every other entry point"
  fi
  if [[ "$(body_words "$ep")" -gt "$ENTRYPOINT_MAX_WORDS" ]]; then
    echo "GROOM: ${ep#"$root"/} > $ENTRYPOINT_MAX_WORDS words — an entry point is wiring only: move project scope, constraints, and architecture into purpose.md or docs/, keep the load path, and mirror the trim to every other entry point"
  fi
done

if [[ -s "$log" ]]; then
  entries=$(grep -c '^- \[' "$log")
  if [[ "$entries" -gt "$LOG_MAX_ENTRIES" || "$(words "$log")" -gt "$LOG_MAX_WORDS" ]]; then
    echo "GROOM: session-log.md > $LOG_MAX_ENTRIES entries or > $LOG_MAX_WORDS words — move the oldest entries to archive/session-log-archive.md, keep the newest ~$((LOG_MAX_ENTRIES / 2))"
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
    echo "GROOM: session-log.md entries over $LOG_ENTRY_MAX_WORDS words: $over_n (largest $over_big; the header format is ≤25) — distill them to format, route surviving detail to memory/ or docs/, write new entries via log.sh"
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
      echo "GROOM: memory/$(basename "$f") > $MEMORY_MAX_WORDS body words — likely more than one fact: split current state, or move stable system knowledge to docs/ and remove the duplicate fact. Shape, never content: every name, value, command, and path survives somewhere under .agent/${keep:+ — keep at least: $keep}"
    fi
  done
fi
if [[ -s "$memory" ]]; then
  mem_entries=$(grep -c '^- \[' "$memory")
  if [[ "$mem_entries" -gt "$MEMORY_MAX_ENTRIES" ]]; then
    echo "GROOM: memory.md > $MEMORY_MAX_ENTRIES index entries — review for stale or superseded lines; move retired fact files to archive/ and drop their index lines, raise the threshold if all are live"
  fi
fi
if [[ -e "$memdir/legacy.md" ]]; then
  echo "GROOM: memory/legacy.md exists — split legacy.md into fact files"
fi
if learned_dir_active; then
  learned_rules=0
  learned_words=0
  while IFS= read -r learned_rec; do
    learned_rules=$((learned_rules + $(grep -c '^- ' "$learned_rec")))
    learned_words=$((learned_words + $(body_words "$learned_rec")))
  done < <(find "$learned_dir" -type f -name '*.md')
  if [[ "$learned_rules" -gt "$LEARNED_MAX_RULES" ]]; then
    echo "GROOM: rules/learned/ > $LEARNED_MAX_RULES rules — merge near-duplicates; route area-specific gotchas to their area doc (see rules)"
  elif [[ "$learned_words" -gt "$LEARNED_MAX_WORDS" ]]; then
    echo "GROOM: rules/learned/ > $LEARNED_MAX_WORDS words under the rule count — entries are over the ~40-word target: compress them, or move domain detail to the matching docs/ file and keep a pointer"
  fi
elif [[ -s "$learned" ]]; then
  if [[ "$(grep -c '^- ' "$learned")" -gt "$LEARNED_MAX_RULES" ]]; then
    echo "GROOM: learned.md > $LEARNED_MAX_RULES rules — merge near-duplicates; route area-specific gotchas to their area doc (see rules)"
  elif [[ "$(body_words "$learned")" -gt "$LEARNED_MAX_WORDS" ]]; then
    echo "GROOM: learned.md > $LEARNED_MAX_WORDS words under the rule count — entries are over the ~40-word target: compress them, or move domain detail to the matching docs/ file and keep a pointer"
  fi
fi
if [[ -d "$docs" ]]; then
  for doc in "$docs"/*.md "$docs"/*/*.md; do
    [[ -e "$doc" ]] || continue
    rel=${doc#"$docs"/}
    [[ "$rel" == "architecture.md" ]] && continue
    [[ "$rel" == references/* || "$rel" == */references/* ]] && continue
    if [[ "$(body_words "$doc")" -gt "$DOCS_MAX_WORDS" ]]; then
      echo "GROOM: docs/$rel > $DOCS_MAX_WORDS body words — restructure without dropping facts: tighten in place (tables, one fact per line), or split into docs/<area>/ sub-docs, each with its own \"Read when:\" header and routing entry"
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
if [[ -d "$docs" ]]; then
  for doc in "$docs"/*.md "$docs"/*/*.md; do
    [[ -e "$doc" ]] || continue
    rel=${doc#"$docs"/}
    [[ "$rel" == "architecture.md" ]] && continue
    [[ "$rel" == references/* || "$rel" == */references/* ]] && continue
    if ! head -n 5 "$doc" | grep -qF "Read when:"; then
      echo "INDEX: docs/$rel missing its \"Read when:\" header — add a one-line routing hint"
    fi
    if [[ -s "$arch" ]]; then
      entry_count=$(grep -cxF "### \`$rel\`" "$arch")
      if ! grep -qF "### \`$rel\`" "$arch"; then
        echo "INDEX: docs/$rel not in the architecture.md routing table — add an entry from its \"Read when:\" header"
      elif [[ "$entry_count" -gt 1 ]]; then
        echo "INDEX: docs/$rel has $entry_count entries in architecture.md — keep exactly one, carrying the doc's own \"Read when:\" hook, and delete the rest"
      else
        block=$(entry_block "$arch" "$rel")
        entry_hook=$(printf '%s\n' "$block" | sed -n 's/^- \*\*Read when:\*\* //p' | head -n 1)
        own_hook=$(doc_hook "$doc")
        if [[ -n "$own_hook" && "$entry_hook" != "$own_hook" ]]; then
          echo "INDEX: docs/$rel hook disagrees with its architecture.md entry — refresh both to the same text"
        fi
        sections=$(printf '%s\n' "$block" | sed -n 's/^- \*\*Sections:\*\* //p' | head -n 1)
        missing=""
        while IFS= read -r heading; do
          [[ -n "$heading" ]] || continue
          printf '%s' "$sections" | grep -qF -- "$heading" || missing="$missing · $heading"
        done < <(sed -n 's/^## //p' "$doc")
        if [[ -n "$missing" ]]; then
          echo "INDEX: docs/$rel sections missing from its architecture.md entry:${missing# }"
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
    echo "REPAIR: docs/architecture.md missing/empty but docs/ holds routed documents - recreate the table with scripts/docs.sh new --name <placeholder> --read-when \"...\" using a name NOT already used in docs/ (it refuses to overwrite an existing doc; delete the placeholder's doc file and its table entry afterward), then add an entry for each existing routed doc"
    break
  done
fi

if [[ -s "$memory" ]]; then
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    if [[ ! -e "$agent/$target" ]]; then
      echo "REPAIR: memory.md indexes $target — file missing"
    fi
  done < <(sed -nE 's|^- \[[^]]*\]\((memory/[^)]+)\).*|\1|p' "$memory")
fi
if [[ -d "$memdir" ]]; then
  for f in "$memdir"/*.md; do
    [[ -e "$f" ]] || continue
    name="memory/$(basename "$f")"
    if [[ ! -s "$memory" ]] \
      || ! sed -nE 's|^- \[[^]]*\]\((memory/[^)]+)\).*|\1|p' "$memory" | grep -qxF "$name"; then
      echo "REPAIR: $name has no index line in memory.md"
    fi
  done
fi

for settings in "$root/.claude/settings.json" "$root/.claude/settings.local.json"; do
  [[ -s "$settings" ]] || continue
  if grep -q '"autoMemoryEnabled"[[:space:]]*:[[:space:]]*true' "$settings"; then
    echo "REPAIR: ${settings#"$root"/} sets autoMemoryEnabled true — set it false and harvest any silo (see retro)"
  fi
done
if [[ -d "$root/.claude" ]] \
  && ! grep -qs '"autoMemoryEnabled"' \
    "$root/.claude/settings.json" "$root/.claude/settings.local.json" \
    "${HOME:-/nonexistent}/.claude/settings.json"; then
  echo "REPAIR: .claude/ present but autoMemoryEnabled is set nowhere — add \"autoMemoryEnabled\": false to .claude/settings.json so it requests the tool's own store off"
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
  echo "$line"
fi
if ! sed --version >/dev/null 2>&1; then
  echo "TOOLS: sed/grep are BSD flavor — sed -i requires ''"
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
if [[ "$load_total" -gt 0 ]]; then
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
if [[ "$payload_total" -gt 0 ]]; then
  echo "PAYLOAD: --load would write $payload_total bytes of a $PAYLOAD_MAX_BYTES byte budget (${payload_detail#, })"
fi

if [[ "$load" -eq 1 ]]; then
  if [[ "$load_mode" == generated ]]; then
    if [[ "$payload_total" -gt "$PAYLOAD_MAX_BYTES" ]]; then
      echo "REPAIR: --load payload is $payload_total bytes, over the $PAYLOAD_MAX_BYTES byte budget — open these two files directly this session: ${purpose#"$root"/}, ${memory#"$root"/}"
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
      echo "REPAIR: --load payload is $payload_total bytes, over the $PAYLOAD_MAX_BYTES byte budget — open these four files directly this session: ${learned#"$root"/}, ${contract#"$root"/}, ${purpose#"$root"/}, ${memory#"$root"/}"
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
