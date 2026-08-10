#!/usr/bin/env bash
# .agent/ status check — run as the entry point's first step.
#
# Prints the recent session-log entries, then one line per finding:
#   GROOM:  a file crossed its grooming threshold
#   REPAIR: a canonical file is missing or lost its manifest
#   INDEX:  a docs/ file and the routing table disagree
#   TOOLS:  environment availability note — advisory, not actionable
# Nothing prints on pass. Always exits 0: this is information on the load
# path, not a completion gate — the binding instruction ("handle flags as
# part of this session") lives in the entry point.
#
# Usage: status.sh [root]    # root defaults to . ; checks <root>/.agent/

set -u

# Tunable per project. Thresholds are review triggers, not caps: nothing
# refuses a write, and each number states its source. Log: ~120 entries
# is a heavy week at the field's peak pace; the 5,000-word trigger sits
# just under the 5,834-word log that caused the lost-history incident.
# Memory file: 300 sits well above the largest
# field fact (~130 words), so a flag means "probably more than one fact".
# Index: chosen default — a proposed 30 proved unusable against real
# V5-era memory volume (a field instance holds ~30 facts after two
# weeks); 100 gives months of headroom, and grooming, not the cap, is
# what regulates it. Learned: the healthiest instances run 31-44 rules.
# Docs: chosen default set just under the smaller of the two field docs
# (2,200 and 3,200 words) whose density forced a manual restructuring
# pass. Tail: covers the busiest logged day (23 entries).
LOG_MAX_ENTRIES=120
LOG_MAX_WORDS=5000
MEMORY_MAX_WORDS=300
MEMORY_MAX_ENTRIES=100
LEARNED_MAX_RULES=60
DOCS_MAX_WORDS=2000
TAIL_LINES=25
PROBE_TOOLS="rg fd jq gh python3 curl tree"

root="${1:-.}"
agent="$root/.agent"
log="$agent/session-log.md"
memory="$agent/memory.md"
memdir="$agent/memory"
learned="$agent/rules/learned.md"
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

# GROOM: grooming thresholds.
if [[ -s "$log" ]]; then
  entries=$(grep -c '^- \[' "$log")
  if [[ "$entries" -gt "$LOG_MAX_ENTRIES" || "$(words "$log")" -gt "$LOG_MAX_WORDS" ]]; then
    echo "GROOM: session-log.md > $LOG_MAX_ENTRIES entries or > $LOG_MAX_WORDS words — move the oldest entries to archive/session-log-archive.md, keep the newest ~$((LOG_MAX_ENTRIES / 2))"
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
if [[ -s "$learned" && "$(grep -c '^- ' "$learned")" -gt "$LEARNED_MAX_RULES" ]]; then
  echo "GROOM: learned.md > $LEARNED_MAX_RULES rules — merge near-duplicates; route area-specific gotchas to their area doc (see rules)"
fi
if [[ -d "$docs" ]]; then
  for doc in "$docs"/*.md "$docs"/*/*.md; do
    [[ -e "$doc" ]] || continue
    rel=${doc#"$docs"/}
    [[ "$rel" == "architecture.md" ]] && continue
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

exit 0
