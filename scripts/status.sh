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
# refuses a write, and each number comes from this system's own field
# instances. Log: a heavy week at the field's pace (~20 entries/day)
# fills ~120 entries; 5,000 words is the lost-history incident number.
# Memory: 300 sits well above the largest field fact (~130 words), so a
# flag means "probably more than one fact". Learned: the healthiest
# instances run 31-44 rules. Tail: covers the busiest logged day (23
# entries).
LOG_MAX_ENTRIES=120
LOG_MAX_WORDS=5000
MEMORY_MAX_WORDS=300
MEMORY_MAX_ENTRIES=100
LEARNED_MAX_RULES=60
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
body_words() {
  awk '
    NR == 1 && $0 == "---" { infm = 1; next }
    infm { if ($0 == "---") infm = 0; next }
    /<!--/ { incm = 1 }
    incm { if (/-->/) incm = 0; next }
    { print }
  ' "$1" | wc -w | tr -d '[:space:]'
}

# Recent session-log entries — printed even when every check passes.
if [[ -s "$log" ]]; then
  grep '^- \[' "$log" | tail -n "$TAIL_LINES"
  echo
fi

# REPAIR: canonical files present and stamped.
if [[ ! -s "$memory" || ! -s "$log" ]]; then
  echo "REPAIR: memory.md or session-log.md missing/empty"
fi
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
    echo "GROOM: memory.md > $MEMORY_MAX_ENTRIES index entries — review for stale or superseded lines; delete what no longer holds, raise the threshold if all are live"
  fi
fi
if [[ -e "$memdir/legacy.md" ]]; then
  echo "GROOM: memory/legacy.md exists — split legacy.md into fact files"
fi
if [[ -s "$learned" && "$(grep -c '^- ' "$learned")" -gt "$LEARNED_MAX_RULES" ]]; then
  echo "GROOM: learned.md > $LEARNED_MAX_RULES rules — merge near-duplicates; route area-specific gotchas to their area doc (see rules)"
fi

# INDEX: every area doc carries a routing hint and the routing table knows it.
if [[ -d "$docs" ]]; then
  for doc in "$docs"/*.md; do
    [[ -e "$doc" ]] || continue
    name=$(basename "$doc")
    [[ "$name" == "architecture.md" ]] && continue
    if ! head -n 5 "$doc" | grep -qF "Read when:"; then
      echo "INDEX: docs/$name missing its \"Read when:\" header — add a one-line routing hint"
    fi
    if [[ -s "$arch" ]] && ! grep -qF "$name" "$arch"; then
      echo "INDEX: docs/$name not in the architecture.md routing table — add a row from its \"Read when:\" header"
    fi
  done
fi

# REPAIR: memory.md index and memory/ fact files agree.
if [[ -s "$memory" ]]; then
  for target in $(grep '^- \[' "$memory" | grep -oE '\(memory/[^)]+\)' | tr -d '()'); do
    if [[ ! -e "$agent/$target" ]]; then
      echo "REPAIR: memory.md indexes $target — file missing"
    fi
  done
fi
if [[ -d "$memdir" ]]; then
  for f in "$memdir"/*.md; do
    [[ -e "$f" ]] || continue
    name="memory/$(basename "$f")"
    if [[ ! -s "$memory" ]] || ! grep '^- \[' "$memory" | grep -qF "($name)"; then
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
