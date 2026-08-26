#!/usr/bin/env bash
# .agent/ status check — run as the entry point's first step.
#
# Prints the recent session-log entries, then one line per finding:
#   GROOM:  a file crossed its grooming threshold
#   REPAIR: a canonical file is missing, lost its manifest, or a bootstrap
#           step was never completed
#   INDEX:  a docs/ file and the routing table disagree
#   TOOLS:  environment availability note — advisory, not actionable
#   LOAD:   what the always-loaded set costs, in words — an advisory
#           measurement printed every run, deliberately without a threshold
# No finding prints on pass; the recent entries and the LOAD line are
# information, not flags. Always exits 0: this is information on the load
# path, not a completion gate — the binding instruction ("handle flags as
# part of this session") lives in the entry point.
#
# Usage: status.sh [root]    # root defaults to . ; checks <root>/.agent/

set -u

# Tunable per project — in the node's status.conf (see below), never by
# editing these lines: node.sh update refreshes this script and discards
# edits. Thresholds are review triggers, not caps: nothing refuses a
# write, and each number states its source. Log: ~120 entries
# is a heavy week at the field's peak pace; the 5,000-word trigger sits
# just under the 5,834-word log that caused the lost-history incident.
# Memory file: 300 sits well above the largest
# field fact (~130 words), so a flag means "probably more than one fact".
# Index: chosen default — a proposed 30 proved unusable against real
# V5-era memory volume (a field instance holds ~30 facts after two
# weeks); 100 gives months of headroom, and grooming, not the cap, is
# what regulates it. Learned: the healthiest instances run 31-44 rules;
# the word trigger is that 60-rule ceiling times the file's own ~40-word
# entry target, and it fires first when entries bloat past that target
# (the field instance averages ~47 words a rule, so 60 of them would run
# ~2,800). learned.md is always-loaded and has no disclosure tier, so
# every word of it is paid on every session.
# Docs: chosen default set just under the smaller of the two field docs
# (2,200 and 3,200 words) whose density forced a manual restructuring
# pass. Tail: covers the busiest logged day (23 entries).
# Log entry: the header contract's format is ≤25 words; 50 is that ceiling
# with 2x grace (chosen default). The check exists because the format
# otherwise lives only in prose and a bypassable writer: a live node
# hand-appended narrative entries past log.sh — 32 of 32 over 50 words,
# the largest 306 — while a sibling node held 0 of 88, and no check could
# tell the two apart. Every oversized entry also rides the tail print
# below into every session's context.
LOG_MAX_ENTRIES=120
LOG_MAX_WORDS=5000
LOG_ENTRY_MAX_WORDS=50
MEMORY_MAX_WORDS=300
MEMORY_MAX_ENTRIES=100
LEARNED_MAX_RULES=60
LEARNED_MAX_WORDS=2400
DOCS_MAX_WORDS=2000
TAIL_LINES=25
PROBE_TOOLS="rg fd jq gh python3 curl tree"

root="${1:-.}"
agent="$root/.agent"

# Per-node overrides for any variable above: <node>/.agent/scripts/
# status.conf, plain KEY=value, parsed and never executed. node.sh init
# seeds a starter listing every key; update seeds it only when absent.
# Tune there, not here — update refreshes this script and discards edits
# to it, but never overwrites the conf. PROBE_TOOLS lists the tools the
# project expects; a node that doesn't use one (gh, say) lists the rest.
conf="$agent/scripts/status.conf"
conf_get() { sed -n "s/^$1=//p" "$conf" 2>/dev/null | head -n 1; }
if [[ -f "$conf" ]]; then
  v=$(conf_get LOG_MAX_ENTRIES);      [[ -n "$v" ]] && LOG_MAX_ENTRIES="$v"
  v=$(conf_get LOG_MAX_WORDS);        [[ -n "$v" ]] && LOG_MAX_WORDS="$v"
  v=$(conf_get LOG_ENTRY_MAX_WORDS);  [[ -n "$v" ]] && LOG_ENTRY_MAX_WORDS="$v"
  v=$(conf_get MEMORY_MAX_WORDS);     [[ -n "$v" ]] && MEMORY_MAX_WORDS="$v"
  v=$(conf_get MEMORY_MAX_ENTRIES);   [[ -n "$v" ]] && MEMORY_MAX_ENTRIES="$v"
  v=$(conf_get LEARNED_MAX_RULES);    [[ -n "$v" ]] && LEARNED_MAX_RULES="$v"
  v=$(conf_get LEARNED_MAX_WORDS);    [[ -n "$v" ]] && LEARNED_MAX_WORDS="$v"
  v=$(conf_get DOCS_MAX_WORDS);       [[ -n "$v" ]] && DOCS_MAX_WORDS="$v"
  v=$(conf_get TAIL_LINES);           [[ -n "$v" ]] && TAIL_LINES="$v"
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

# Word count of a file's body: YAML frontmatter and <!-- --> header
# comments excluded, so fixed per-file overhead never eats the fact budget.
# Approximation: with two comments on one line the greedy strip also drops
# the words between them — a slight undercount on a review trigger.
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

# REPAIR: canonical files present and stamped.
[[ -s "$memory" ]] || echo "REPAIR: memory.md missing/empty"
[[ -s "$log" ]] || echo "REPAIR: session-log.md missing/empty"
if ! head -n 10 "$purpose" 2>/dev/null | grep -qF "dot-agent:"; then
  echo "REPAIR: purpose.md missing dot-agent frontmatter — restore manifest"
fi

# REPAIR: bootstrap steps that produce a file the checks above cannot tell
# apart from a finished one. Each is a step the operator and agent perform
# by judgement at bootstrap, so nothing else catches a half-done node:
# guardrails left as template placeholders, and the Quality bar left inside
# contract.md instead of split into rules/quality-bar.md.
if [[ -s "$contract" ]]; then
  guardrails=$(awk '/^## Project guardrails/ { inb = 1; next }
                    inb && /^## / { exit }
                    inb { print }' "$contract")
  # A placeholder spans several words (`<exact command(s)>`); a filled-in
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

# REPAIR: entry points drifted. The model requires every tool's entry point
# to be identical; only files that are actually dot-agent entry points are
# compared, so a hand-written AGENTS.md of team instructions is left alone.
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
if [[ -d "$memdir" ]]; then
  for f in "$memdir"/*.md; do
    [[ -e "$f" ]] || continue
    if [[ "$(body_words "$f")" -gt "$MEMORY_MAX_WORDS" ]]; then
      echo "GROOM: memory/$(basename "$f") > $MEMORY_MAX_WORDS body words — likely more than one fact: split it, or move detail to a docs/ file and keep a pointer fact"
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
    # references/ is the never-auto-loaded depth tier: no routing entry, no
    # size trigger. Its files are opened only by explicit path from the area
    # doc that cites them, so neither check applies.
    [[ "$rel" == references/* || "$rel" == */references/* ]] && continue
    if [[ "$(body_words "$doc")" -gt "$DOCS_MAX_WORDS" ]]; then
      echo "GROOM: docs/$rel > $DOCS_MAX_WORDS body words — restructure without dropping facts: tighten in place (tables, one fact per line), or split into docs/<area>/ sub-docs, each with its own \"Read when:\" header and routing entry"
    fi
  done
fi

# INDEX: every area doc carries a routing hint and the routing table agrees
# with it. Walks one sublevel: an area that outgrew one file splits into
# docs/<area>/ sub-docs, still routed from the single architecture.md
# (entries carry the relative path).
#
# Three ways a doc and its entry disagree, all checkable: the doc is
# missing from the index, the hook drifted on one side, or the doc grew a
# `## ` section the Sections list never learned about. The section check
# is one-directional on purpose — an entry may say more than the heading
# (a hand-written gloss routes better than a bare title), never less.
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
    # references/ is the never-auto-loaded depth tier: no routing entry, no
    # size trigger. Its files are opened only by explicit path from the area
    # doc that cites them, so neither check applies.
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
# parse only the index line's own link — the first `[title](memory/…)` on
# the line — so a hook that mentions another memory path is never counted.
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
# mean a second store can collect knowledge this node will never see; the
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
for tool in $PROBE_TOOLS; do
  command -v "$tool" >/dev/null 2>&1 || missing="$missing, $tool"
done
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

# LOAD: the always-loaded set, measured. A per-file limit that is never
# summed is not a limit, and three members of this set (contract, purpose,
# the routing table) carry no per-file trigger at all. Advisory on purpose:
# the two live field instances measured 2026-08-23 both ran ~4,600-4,700
# words — one calibration point, not provenance for a threshold. The tail
# term prices what this check itself printed above.
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

exit 0
