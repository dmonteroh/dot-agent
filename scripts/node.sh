#!/usr/bin/env bash
# .agent/ node bootstrap and update — the mechanical parts only. Judgement
# (exploring the project, filling Project guardrails, reconciling content
# during an update) stays with the agent; this script never does either.
#
# Usage:
#   node.sh init --preset <name> --mode <mode> [root]
#   node.sh update [root]
#
#   <name> matches a file in the source repo's presets/ (currently
#   software-development, academic-research, domain-knowledge).
#   <mode> is one of: ignore-all | track-shared | track-all.
#   root defaults to . ; the script reads/writes <root>/.agent.
#
# Header contracts in operating-model.md remain the format authority: this
# script writes files that carry their own header contracts, and produces
# nothing a header contract doesn't already describe.

set -u

TARGET_VERSION="6.1"
SOURCE_URL="https://github.com/dmonteroh/dot-agent"

selfdir=$(cd "$(dirname "$0")" && pwd)
srcroot=$(cd "$selfdir/.." && pwd)

usage() {
  cat <<'EOF'
Usage:
  node.sh init --preset <software-development|academic-research|domain-knowledge> --mode <ignore-all|track-shared|track-all> [root]
  node.sh update [root]

root defaults to . ; the script operates on <root>/.agent
EOF
}

cmd="${1:-}"
[ $# -ge 1 ] && shift

case "$cmd" in
init)
  preset=""
  mode=""
  root="."
  while [ $# -gt 0 ]; do
    case "$1" in
    --preset)
      [ $# -ge 2 ] || { echo "node.sh: --preset needs a value" >&2; usage >&2; exit 1; }
      preset="$2"; shift 2 ;;
    --mode)
      [ $# -ge 2 ] || { echo "node.sh: --mode needs a value" >&2; usage >&2; exit 1; }
      mode="$2"; shift 2 ;;
    -h | --help)
      usage; exit 0 ;;
    --*)
      echo "node.sh: unknown flag: $1" >&2; usage >&2; exit 1 ;;
    *)
      root="$1"; shift ;;
    esac
  done

  if [ -z "$preset" ] || [ ! -f "$srcroot/presets/$preset.md" ]; then
    echo "node.sh: unknown --preset: '$preset' (must match a file in $srcroot/presets/)" >&2
    usage >&2
    exit 1
  fi
  case "$mode" in
  ignore-all | track-shared | track-all) ;;
  *)
    echo "node.sh: unknown --mode: '$mode' (must be ignore-all, track-shared, or track-all)" >&2
    usage >&2
    exit 1 ;;
  esac

  agent="$root/.agent"
  if [ -e "$agent" ]; then
    echo "node.sh: $agent already exists — refusing to overwrite a live node" >&2
    exit 1
  fi

  mkdir -p "$agent/rules" "$agent/memory" "$agent/docs" "$agent/archive" "$agent/scripts"

  cat >"$agent/session-log.md" <<'EOF'
# Session log
<!-- One entry per session, newest last.
Format: - [YYYY-MM-DD] (tool) <task, area, outcome — ≤25 words>. verify: pass|fail|n/a.
Append the model to the tag when the harness states one — (claude/sonnet) —
never guess it. No file lists, SHAs, test counts, reviewer verdicts, or
narrative. -->
EOF

  cat >"$agent/memory.md" <<'EOF'
# Memory
<!-- Index only, one line per fact file, newest or most-relevant first.
Format: - [Title](memory/slug.md) — hook. No prose, no facts inline: a
fact that lives only as a line here and not as its own file under
memory/ is not recorded. Delete the line when its file is deleted. -->
EOF

  cat >"$agent/rules/learned.md" <<'EOF'
# Learned rules

Binding rules distilled from operator corrections and failed verifications
on this project. Append new rules; when updating you may merge or compress
entries, but never drop operational content. Keep each entry to roughly 40
words: imperative rule first, cause/trigger only where it adds information.
Write the rule, not the story — no incident retelling or justification
narrative; merge near-duplicates instead of appending; move domain detail
beyond ~40 words into the matching `.agent/docs/` file and keep a pointer
here (authoring rules: `contract.md`, Self-learning). Behavioral rules stay
here; area gotchas go to the matching `.agent/docs/` file under `## Gotchas`.

<!-- Format: - [YYYY-MM-DD] <imperative rule>. Trigger: <cause, optional>. -->
EOF

  cat >"$agent/purpose.md" <<EOF
---
# Do not remove or rewrite this block; update passes may change only \`version\`.
dot-agent:
  source: $SOURCE_URL
  version: "$TARGET_VERSION"
  preset: $preset
  mode: $mode        # ignore-all | track-shared | track-all
  children: []              # repo-relative paths to child .agent/ nodes
---

# Purpose

<!-- Filled by the agent during bootstrap: why this project exists, who
it's for, key constraints, and where to change what. -->
EOF

  cp "$srcroot/presets/$preset.md" "$agent/rules/contract.md"

  cp "$srcroot/scripts/status.sh" "$agent/scripts/status.sh"
  chmod +x "$agent/scripts/status.sh"

  case "$mode" in
  ignore-all)
    gitignore="$root/.gitignore"
    if [ ! -e "$gitignore" ] || ! grep -qxF ".agent/" "$gitignore"; then
      printf '.agent/\n' >>"$gitignore"
    fi
    ;;
  track-shared)
    gitignore="$root/.gitignore"
    if [ ! -e "$gitignore" ] || ! grep -qxF ".agent/*" "$gitignore"; then
      {
        [ -s "$gitignore" ] && echo
        echo ".agent/*"
        echo "!.agent/purpose.md"
        echo "!.agent/rules/"
        echo "!.agent/docs/"
      } >>"$gitignore"
    fi
    ;;
  track-all) ;;
  esac

  echo "node.sh: initialized $agent (preset=$preset, mode=$mode)"
  exit 0
  ;;

update)
  root="${1:-.}"
  agent="$root/.agent"
  purpose="$agent/purpose.md"

  if [ ! -f "$purpose" ] || ! head -n 10 "$purpose" | grep -qF "dot-agent:"; then
    cat >&2 <<EOF
node.sh: no dot-agent manifest found at $purpose.
This looks like a pre-V6 node. node.sh update only handles manifested
(V6+) nodes — restoring a missing manifest is an agent-driven task, not a
mechanical one. Read CHANGELOG.md (the pre-V6 migration checklist) and
update this node by hand in a normal session.
EOF
    exit 1
  fi

  version_line=$(grep -m1 '^  version:' "$purpose")
  oldversion=$(printf '%s\n' "$version_line" | sed -E 's/^[[:space:]]*version:[[:space:]]*"?([^"[:space:]]*)"?.*/\1/')
  mode_line=$(grep -m1 '^  mode:' "$purpose")
  mode=$(printf '%s\n' "$mode_line" | sed -E 's/^[[:space:]]*mode:[[:space:]]*([A-Za-z-]+).*/\1/')

  if [ -z "$oldversion" ]; then
    echo "node.sh: could not read a version from $purpose — not touching the node" >&2
    exit 1
  fi

  lowest=$(printf '%s\n%s\n' "$oldversion" "$TARGET_VERSION" | sort -V | head -n1)
  if [ "$oldversion" = "$TARGET_VERSION" ] || [ "$lowest" != "$oldversion" ]; then
    echo "node.sh: node is current (version $oldversion)"
    exit 0
  fi

  if [ "$mode" = "ignore-all" ]; then
    backup="$root/.agent.backup-v$oldversion"
    if [ -e "$backup" ]; then
      echo "node.sh: backup path already exists: $backup — refusing to proceed" >&2
      exit 1
    fi
    cp -R "$agent" "$backup"
    echo "node.sh: backed up untracked node to $backup"
  fi

  # Memory split baseline (guarded by memory/ absence — safe to re-run).
  memdir="$agent/memory"
  memory="$agent/memory.md"
  split_note="memory/ already present — split step skipped"
  if [ ! -d "$memdir" ]; then
    mkdir -p "$memdir"
    body_tmp="$agent/.memory-body.tmp"
    if [ -f "$memory" ]; then
      header_end=$(grep -n -- '-->' "$memory" | head -n1 | cut -d: -f1)
      header_end=${header_end:-0}
      tail -n +"$((header_end + 1))" "$memory" >"$body_tmp"
    else
      : >"$body_tmp"
    fi
    if grep -q '[^[:space:]]' "$body_tmp" 2>/dev/null; then
      sed -e '/./,$!d' "$body_tmp" >"$memdir/legacy.md"
      cat >"$memory" <<'EOF'
# Memory
<!-- Index only, one line per fact file, newest or most-relevant first.
Format: - [Title](memory/slug.md) — hook. No prose, no facts inline: a
fact that lives only as a line here and not as its own file under
memory/ is not recorded. Delete the line when its file is deleted. -->

- [Legacy memory](memory/legacy.md) — unsplit pre-6.1 memory, split per its GROOM flag
EOF
      split_note="memory.md body moved to memory/legacy.md (GROOM flag will prompt the fact split)"
    else
      cat >"$memory" <<'EOF'
# Memory
<!-- Index only, one line per fact file, newest or most-relevant first.
Format: - [Title](memory/slug.md) — hook. No prose, no facts inline: a
fact that lives only as a line here and not as its own file under
memory/ is not recorded. Delete the line when its file is deleted. -->
EOF
      split_note="memory.md was empty/header-only — replaced with the index header, no legacy file"
    fi
    rm -f "$body_tmp"
  fi

  # Refresh status.sh from the source repo.
  mkdir -p "$agent/scripts"
  cp "$srcroot/scripts/status.sh" "$agent/scripts/status.sh"
  chmod +x "$agent/scripts/status.sh"

  # Bump version — nothing else in the frontmatter changes.
  purpose_new="$agent/.purpose.md.new"
  sed -E '1,10s/^(  version:).*/\1 "'"$TARGET_VERSION"'"/' "$purpose" >"$purpose_new"
  mv "$purpose_new" "$purpose"

  echo "node.sh: updated $agent from version $oldversion to $TARGET_VERSION"
  echo "node.sh: $split_note"
  echo "node.sh: status.sh refreshed from source repo"
  echo "node.sh: remaining for the agent — split memory/legacy.md into fact files (status.sh flags it with GROOM), reconcile rules/contract.md and docs/ against the current presets and operating model"
  exit 0
  ;;

*)
  usage >&2
  exit 1
  ;;
esac
