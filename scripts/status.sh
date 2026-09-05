#!/usr/bin/env bash
# .agent/ status check — run as the entry point's first step. Prints the
# recent session-log entries, then one line per finding: GROOM (a file
# crossed a grooming threshold), REPAIR (a canonical file or bootstrap step
# is missing), INDEX (a docs/ file and the routing table disagree), plus
# advisory TOOLS and LOAD lines. No finding prints on pass.
#
# Exits 0 on every node it can check: information on the load path, not a
# completion gate. The binding instruction ("handle flags as part of this
# session") lives in the entry point. The one non-zero exit is a usage
# error — a root that holds no .agent/ — which is not a finding about a
# node and must never be reported as one.
#
# Tunables: status.conf beside this script, which lists every key.
# Full documentation: scripts/docs/status.md in the dot-agent repo.
#
# Usage: status.sh [--load] [root]    # root defaults to . — checks <root>/.agent/
#
# --load appends the always-loaded set after the findings — learned rules,
# contract, purpose, memory index, each under a marker naming its path — so
# the entry point's bootstrap is one call instead of five. Every call costs
# a re-read of the whole context; the text is the same either way.

set -u

# Review triggers, not caps: nothing refuses a write for size. Tune in the
# node's status.conf, never here — node.sh update refreshes this script and
# discards edits to it. Each default and where its number comes from:
# status.conf beside this script, and scripts/docs/status.md upstream.
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

--load then prints the always-loaded set — rules/learned.md, rules/contract.md,
purpose.md, memory.md — each under a "==== <path> ====" marker, so the
bootstrap is one call.

root defaults to . — checks <root>/.agent/ and exits 0 whatever it finds. A
root holding no .agent/ is a usage error and exits 1.
EOF
    exit 0 ;;
  --load) load=1 ;;
  *) root="$arg" ;;
  esac
done

agent="$root/.agent"
# A root with no .agent/ is a usage error, not a node with three missing
# files: printing findings for it would send an agent off to repair a node
# that was never addressed. links.sh refuses the same way.
if [ ! -d "$agent" ]; then
  echo "status.sh: no .agent directory at $agent — run from the node's project root, or pass that root as an argument" >&2
  exit 1
fi

# Per-node overrides for any variable above: plain KEY=value, parsed and
# never executed — a config read on the load path cannot be allowed to run
# code. Every numeric key is checked against ^[0-9]+$ before it reaches a
# variable, because "parsed, never executed" is not what the shell does
# next: `[[ x -gt $v ]]` and `$(( ))` evaluate their operands as arithmetic,
# and arithmetic evaluation performs command substitution inside an array
# subscript. An unvalidated value here would run whatever it named.
conf="$agent/scripts/status.conf"
# The trailing-space strip forgives a stray space or a CR from an editor on
# another platform; nothing else about the value is repaired.
conf_get() { sed -n "s/^$1=//p" "$conf" 2>/dev/null | head -n 1 | sed 's/[[:space:]]*$//'; }
# A value that is not a whole number keeps the shipped default and adds a
# REPAIR line naming the key. No finding this script makes reaches its exit
# status, so a quiet fallback would leave a broken config indistinguishable
# from a clean node — the caller reads the findings, not the exit status.
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
  v=$(conf_get PROBE_TOOLS);          [[ -n "$v" ]] && PROBE_TOOLS="$v"
fi
log="$agent/session-log.md"
memory="$agent/memory.md"
memdir="$agent/memory"
learned="$agent/rules/learned.md"
contract="$agent/rules/contract.md"
qualitybar="$agent/rules/quality-bar.md"
purpose="$agent/purpose.md"
docs="$agent/docs"
arch="$docs/architecture.md"

words() { wc -w <"$1" | tr -d '[:space:]'; }

# Body words: YAML frontmatter and <!-- --> header comments excluded, so
# fixed per-file overhead never eats the fact budget. With two comments on
# one line the greedy strip also drops the words between them — an
# undercount, the safe direction for a review trigger.
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

# Recent session-log entries — printed even when every check passes.
if [[ -s "$log" ]]; then
  recent=$(grep '^- \[' "$log" | tail -n "$TAIL_LINES")
  if [[ -n "$recent" ]]; then
    printf '%s\n\n' "$recent"
  fi
fi

# REPAIR: conf values that could not be used, held from the parse above so
# they print with the other findings rather than ahead of the log tail.
[[ -n "$conf_repairs" ]] && printf '%s' "$conf_repairs"

# REPAIR: canonical files present and stamped.
[[ -s "$memory" ]] || echo "REPAIR: memory.md missing/empty"
[[ -s "$log" ]] || echo "REPAIR: session-log.md missing/empty"
if ! head -n 10 "$purpose" 2>/dev/null | grep -qF "dot-agent:"; then
  echo "REPAIR: purpose.md missing dot-agent frontmatter — restore manifest"
fi

# REPAIR: the two bootstrap steps done by judgement, which nothing else can
# tell apart from a finished node.
if [[ -s "$contract" ]]; then
  guardrails=$(awk '/^## Project guardrails/ { inb = 1; next }
                    inb && /^## / { exit }
                    inb { print }' "$contract")
  # A placeholder spans several words (`<exact command(s)>`). A filled-in
  # line's own angle brackets are single-token (`--grep <name>`), so the
  # required space is what keeps a real command from reading as a stub.
  if printf '%s\n' "$guardrails" | grep -qE '^- .*<[^>]* [^>]*>'; then
    echo "REPAIR: contract.md Project guardrails still holds template placeholders — fill them with this project's exact commands"
  fi
  if grep -q '^## Quality bar' "$contract"; then
    echo "REPAIR: contract.md still contains ## Quality bar — split it into rules/quality-bar.md so it loads on demand, not every session"
  elif [[ ! -s "$qualitybar" ]]; then
    echo "REPAIR: rules/quality-bar.md missing — the verifier rubric was never split out of the preset"
  fi
fi

# REPAIR: entry points drifted. Only files that are actually dot-agent
# entry points are compared, so a hand-written AGENTS.md of team
# instructions is left alone.
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

# GROOM: an entry point that grew past wiring. The template's body is ~350
# words and a filled copy lands near 400, so the threshold is that with 2×
# grace — the same grace the log entry format gets. What crosses it is never
# more load path: it is project
# scope, constraints, or architecture restated from purpose.md and docs/,
# where it is loaded two steps later anyway. Paid on every message by every
# tool that keeps this file resident, and stale in one of the two copies.
for ep in "${entrypoints[@]-}"; do
  [[ -n "$ep" ]] || continue
  if [[ "$(body_words "$ep")" -gt "$ENTRYPOINT_MAX_WORDS" ]]; then
    echo "GROOM: ${ep#"$root"/} > $ENTRYPOINT_MAX_WORDS words — an entry point is wiring only: move project scope, constraints, and architecture into purpose.md or docs/, keep the load path, and mirror the trim to every other entry point"
  fi
done

# GROOM: grooming thresholds.
if [[ -s "$log" ]]; then
  entries=$(grep -c '^- \[' "$log")
  if [[ "$entries" -gt "$LOG_MAX_ENTRIES" || "$(words "$log")" -gt "$LOG_MAX_WORDS" ]]; then
    echo "GROOM: session-log.md > $LOG_MAX_ENTRIES entries or > $LOG_MAX_WORDS words — move the oldest entries to archive/session-log-archive.md, keep the newest ~$((LOG_MAX_ENTRIES / 2))"
  fi
  # Entry shape, not just file size: an entry is everything from its `- [`
  # marker to the next one, so a hand-wrapped narrative is counted whole.
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
# The tokens a restructuring pass must carry over: ticket ids, constants,
# paths, hosts, commands, dates, numbers with units, and anything in
# backticks. Listed on the GROOM: line so "shape, never content" is a
# checklist the session can tick rather than a rule it has to remember.
# Extraction is a word-shape heuristic, never a judgement about meaning:
# an undercount leaves a fact unlisted, an overcount lists a plain word.
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
        if (t ~ /^[A-Z][A-Z0-9]+-[0-9]+$/ || t ~ /^[A-Z][A-Z0-9_]{3,}$/ || t ~ /^[A-Z][a-z]+-[A-Z][a-z]+$/ || t ~ /^[a-z]+:\/\// || t ~ /^[A-Za-z0-9_.-]*\/[A-Za-z0-9_.\/-]+$/ || t ~ /^[a-z0-9.-]+\.[a-z]{2,}(:[0-9]+)?$/ || t ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/ || t ~ /^[0-9]+(ms|s|rps|%)$/) print t
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
if [[ -s "$learned" ]]; then
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
    # references/ is the never-auto-loaded depth tier: opened only by
    # explicit path, so neither check applies.
    [[ "$rel" == references/* || "$rel" == */references/* ]] && continue
    if [[ "$(body_words "$doc")" -gt "$DOCS_MAX_WORDS" ]]; then
      echo "GROOM: docs/$rel > $DOCS_MAX_WORDS body words — restructure without dropping facts: tighten in place (tables, one fact per line), or split into docs/<area>/ sub-docs, each with its own \"Read when:\" header and routing entry"
    fi
  done
fi

# INDEX: every area doc carries a routing hint and the routing table agrees
# with it. Walks one sublevel, since an area that outgrew one file splits
# into docs/<area>/ sub-docs still routed from the single architecture.md.
# The section check is one-directional: an entry may say more than the
# heading, never less.
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
    # references/ is the never-auto-loaded depth tier: opened only by
    # explicit path, so neither check applies.
    [[ "$rel" == references/* || "$rel" == */references/* ]] && continue
    if ! head -n 5 "$doc" | grep -qF "Read when:"; then
      echo "INDEX: docs/$rel missing its \"Read when:\" header — add a one-line routing hint"
    fi
    if [[ -s "$arch" ]]; then
      if ! grep -qF "### \`$rel\`" "$arch"; then
        echo "INDEX: docs/$rel not in the architecture.md routing table — add an entry from its \"Read when:\" header"
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

# REPAIR: memory.md index and memory/ fact files agree. Both directions
# parse only the index line's own link — the first `[title](memory/…)` —
# so a hook mentioning another memory path is never counted.
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

# REPAIR: .agent/ is the sole durable memory only if the tool's own store is
# off, and that rests on a setting no other check reads. Absent or true both
# mean a second store can collect knowledge this node will never see. The
# file is checked textually so the check needs no JSON parser.
for settings in "$root/.claude/settings.json" "$root/.claude/settings.local.json"; do
  [[ -s "$settings" ]] || continue
  if grep -q '"autoMemoryEnabled"[[:space:]]*:[[:space:]]*true' "$settings"; then
    echo "REPAIR: ${settings#"$root"/} sets autoMemoryEnabled true — .agent/ is not the sole durable memory; set it false and harvest any silo (see retro)"
  fi
done
# Settings merge user-level over node-level, so a node inherits a setting it
# does not carry: only a node that sets it nowhere is unconfigured.
if [[ -d "$root/.claude" ]] \
  && ! grep -qs '"autoMemoryEnabled"' \
    "$root/.claude/settings.json" "$root/.claude/settings.local.json" \
    "${HOME:-/nonexistent}/.claude/settings.json"; then
  echo "REPAIR: .claude/ present but autoMemoryEnabled is set nowhere — add \"autoMemoryEnabled\": false so .agent/ stays the sole durable memory"
fi

# TOOLS: availability facts for the environment this session runs in.
missing=""
# The list is split on spaces on purpose; globbing is off across the split
# so a `*` in the conf value stays one literal name to probe instead of
# expanding into whatever files sit in the working directory.
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

# LOAD: the always-loaded set, measured. Advisory on purpose — no threshold
# until this line has measured enough nodes to source one. The tail term
# prices what this check itself printed above.
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

# --load: the always-loaded set, in the entry point's order, after the
# findings. The marker names the path so nothing has to be re-opened to know
# where a sentence came from.
if [[ "$load" -eq 1 ]]; then
  for f in "$learned" "$contract" "$purpose" "$memory"; do
    [[ -s "$f" ]] || continue
    printf '\n==== %s ====\n' "${f#"$root"/}"
    cat "$f"
  done
fi

exit 0
