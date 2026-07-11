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

# Tunable per project.
LOG_MAX_ENTRIES=80
LOG_MAX_WORDS=5000
MEMORY_MAX_WORDS=800
LEARNED_MAX_RULES=25
TAIL_LINES=10
PROBE_TOOLS="rg fd jq gh python3 curl tree"

root="${1:-.}"
agent="$root/.agent"
log="$agent/session-log.md"
memory="$agent/memory.md"
learned="$agent/rules/learned.md"
purpose="$agent/purpose.md"
docs="$agent/docs"
arch="$docs/architecture.md"

words() { wc -w <"$1" | tr -d '[:space:]'; }

# Recent session-log entries — printed even when every check passes.
if [[ -s "$log" ]]; then
  tail -n "$TAIL_LINES" "$log"
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
    echo "GROOM: session-log.md > $LOG_MAX_ENTRIES entries or > $LOG_MAX_WORDS words — move entries older than 30 days to archive/session-log-archive.md"
  fi
fi
if [[ -s "$memory" && "$(words "$memory")" -gt "$MEMORY_MAX_WORDS" ]]; then
  echo "GROOM: memory.md > $MEMORY_MAX_WORDS words — compact to durable state only"
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
