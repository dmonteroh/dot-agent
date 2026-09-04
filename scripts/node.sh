#!/usr/bin/env bash
# .agent/ node bootstrap and update — the mechanical parts only. Judgement
# (exploring the project, filling Project guardrails, reconciling content
# during an update) stays with the agent. This script never does either.
#
# Full documentation: scripts/docs/node.md.
#
# Usage:
#   node.sh init --preset <name> --mode <mode> [root]
#   node.sh update [root]
#
#   <name> matches a file in the source repo's presets/ (currently
#   software-development, academic-research, domain-knowledge).
#   <mode> is one of: ignore-all | track-shared | track-all.
#   root defaults to . — the script reads/writes <root>/.agent.

set -u
unset CDPATH   # an exported CDPATH corrupts $(cd … && pwd) for relative paths

TARGET_VERSION="6.2"
SOURCE_URL="https://github.com/dmonteroh/dot-agent"

selfdir=$(cd "$(dirname "$0")" && pwd)
srcroot=$(cd "$selfdir/.." && pwd)

usage() {
  cat <<'EOF'
Usage:
  node.sh init --preset <software-development|academic-research|domain-knowledge> --mode <ignore-all|track-shared|track-all> [root]
  node.sh update [root]

root defaults to . — the script operates on <root>/.agent
EOF
}

cmd="${1:-}"
[ $# -ge 1 ] && shift

# The fact-file header contract lives in memory.md's header, so a fact file
# holds its frontmatter and the fact and nothing else. A current version may
# still carry an earlier pre-release header: version-current is not shape-current.
memory_index_header_stale() {
  mih_memory="$1"
  [ -f "$mih_memory" ] || return 1
  grep -qF 'This contract covers memory/ too' "$mih_memory" || return 0
  grep -qF 'If one already states it, update that source or its routing, write no fact, and say which source states it.' "$mih_memory" || return 0
  return 1
}

memory_headers_stale() {
  mh_agent="$1"
  memory_index_header_stale "$mh_agent/memory.md" && return 0
  for mh_f in "$mh_agent"/memory/*.md; do
    [ -e "$mh_f" ] || continue
    grep -q '^<!-- One durable fact per file' "$mh_f" && return 0
  done
  return 1
}

# The memory.md index header. node.sh writes memory.md down four paths:
# init, the pre-6.1 header migration, and both branches of update. One
# writer keeps them identical, so a node created today and a node updated
# today carry the same contract. The operating model quotes this text and
# test.sh section 39 checks that quote.
write_memory_header() {
  cat >"$1" <<'EOF'
# Memory
<!-- Index only, one line per fact file, newest last. Reorder by relevance only when grooming. Format: - [Title](memory/slug.md) — hook. No prose, no facts inline: a fact that lives only as a line here and not as its own file under memory/ is not recorded. Delete the line when its file is deleted. Preferred writer: .agent/scripts/memory.sh new (scaffolds the fact file and its index line together). This contract covers memory/ too, so fact files carry no header of their own. Each holds one durable fact under date, scope, and type frontmatter. Keep a fact only if work in this node changes when it is true: one carried in from another repo or a migration earns its place again or is dropped. Before writing, search purpose, rules, routed docs, source, and existing facts. If one already states it, update that source or its routing, write no fact, and say which source states it. A defect fixed in the harness or a tool creates no compensating fact. Two halves that would be superseded at different times are two files. Supersede in place with .agent/scripts/memory.sh supersede --slug <slug> --fact "…", which rewrites the fact, restamps the date, and keeps the filename. No dated narratives, no command output, no history. As small as the fact allows. Stable knowledge about how the system works goes to docs/ without a pointer fact; architecture.md already routes it. type: reference points outward at a URL, dashboard, ticket, or spec the node does not own: checked for reachability, not superseded like a fact. -->
EOF
}

# Both edits are exact-string: the header comment is deleted whole and the
# fact below it is never read. memory.md keeps every index line under a
# replaced header. Sets migrate_note.
migrate_memory_headers() {
  mg_agent="$1"
  mg_memory="$mg_agent/memory.md"
  mg_stripped=0
  mg_index_refreshed=0
  migrate_note="memory headers already current"
  for mg_f in "$mg_agent"/memory/*.md; do
    [ -e "$mg_f" ] || continue
    grep -q '^<!-- One durable fact per file' "$mg_f" || continue
    awk '
      /^<!-- One durable fact per file/ { drop = 1 }
      drop { if (/-->/) drop = 0; next }
      { print }
    ' "$mg_f" >"$mg_f.tmp" && mv "$mg_f.tmp" "$mg_f"
    mg_stripped=$((mg_stripped + 1))
  done
  if memory_index_header_stale "$mg_memory"; then
    mg_body="$mg_agent/.memory-index.tmp"
    mg_end=""
    if head -n 5 "$mg_memory" | grep -qF '<!--'; then
      mg_end=$(grep -n -- '-->' "$mg_memory" | head -n1 | cut -d: -f1)
    fi
    mg_end=${mg_end:-0}
    tail -n +"$((mg_end + 1))" "$mg_memory" \
      | awk 'NR == 1 && /^# Memory[[:space:]]*$/ { next } { print }' \
      | sed -e '/./,$!d' >"$mg_body"
    write_memory_header "$mg_memory"
    printf '\n' >>"$mg_memory"
    cat "$mg_body" >>"$mg_memory"
    rm -f "$mg_body"
    mg_index_refreshed=1
  fi
  if [ "$mg_stripped" -gt 0 ]; then
    migrate_note="memory.md header refreshed; $mg_stripped fact file(s) stripped of their own"
  elif [ "$mg_index_refreshed" -eq 1 ]; then
    migrate_note="memory.md header refreshed"
  fi
  return 0
}

# The docs shape contract moved out of every area doc and into the preset
# and docs.sh's output: docs/ is the N-file tier, so a header there is paid
# by every session that only reads the doc. A 6.1 node carries a copy in
# each doc, sub-docs under docs/<area>/ included.
doc_headers_stale() {
  dh_docs="$1/docs"
  [ -d "$dh_docs" ] || return 1
  # Non-empty output, not find's exit status: with -exec … + that status is
  # the last grep's, which is 1 on the common case of a clean tail file.
  [ -n "$(find "$dh_docs" -name '*.md' -type f \
    -exec grep -lF '<!-- Agent-facing reference, not a human narrative' {} + 2>/dev/null)" ]
}

# Exact-string, like the memory strip: the comment is deleted whole and the
# doc below it is never read. Sets migrate_doc_note.
migrate_doc_headers() {
  dm_docs="$1/docs"
  dm_stripped=0
  migrate_doc_note="doc headers already current"
  [ -d "$dm_docs" ] || return 0
  # The match list goes through a file, not a pipeline: `while read` on the
  # right of a pipe runs in a subshell, where dm_stripped would not survive.
  dm_list="$1/.doc-headers.tmp"
  find "$dm_docs" -name '*.md' -type f \
    -exec grep -lF '<!-- Agent-facing reference, not a human narrative' {} + \
    >"$dm_list" 2>/dev/null
  while IFS= read -r dm_f; do
    [ -n "$dm_f" ] || continue
    awk '
      /<!-- Agent-facing reference, not a human narrative/ { drop = 1 }
      drop { if (/-->/) drop = 0; next }
      { print }
    ' "$dm_f" >"$dm_f.tmp" && mv "$dm_f.tmp" "$dm_f"
    dm_stripped=$((dm_stripped + 1))
  done <"$dm_list"
  rm -f "$dm_list"
  [ "$dm_stripped" -gt 0 ] \
    && migrate_doc_note="$dm_stripped area doc(s) stripped of the shape header the preset now carries"
  return 0
}

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

  # A filename that starts with "_" marks a maintainer file in presets/
  # (_shared.md is the index of text that must stay identical across
  # presets). It is not a preset and must never land in a node as
  # rules/contract.md.
  case "$preset" in
  _*)
    echo "node.sh: '$preset' is a maintainer file in presets/, not a preset" >&2
    usage >&2
    exit 1 ;;
  esac
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

  mkdir -p "$agent/rules" "$agent/memory" "$agent/docs" "$agent/archive" "$agent/scripts" \
    || { echo "node.sh: could not create the node skeleton under $agent" >&2; exit 1; }

  cat >"$agent/session-log.md" <<'EOF'
# Session log
<!-- One entry per session, newest last. Format: - [YYYY-MM-DD] (tool) <task, area, outcome — ≤25 words>. verify: pass|fail|n/a. The summary text never contains `verify:`; log.sh stamps the tag from --verify and rejects a summary that carries one. Append the model to the tool tag when the harness states one — (claude/sonnet). Never guess it. The verify tag is this change's own verification result: a baseline failure that predates the change goes in the summary text, not the tag. No file lists, SHAs, test counts, reviewer verdicts, or narrative. Preferred writer: .agent/scripts/log.sh, which stamps the date and enforces the ceiling. With log.conf's LOG_INCLUDE_BRANCH=true it also stamps `branch: <name>.` before verify, read from git. -->
EOF

  write_memory_header "$agent/memory.md"

  cat >"$agent/rules/learned.md" <<'EOF'
# Learned rules

Binding rules distilled from operator corrections and failed verifications on this project, after the canonical-source check in `contract.md`. A correction that exposes a defect in the contract, docs, code, or tooling is fixed there and produces no compensating rule. Merging and compressing entries is allowed. Drop a rule when its failure mode becomes mechanically enforced. Behavioral rules stay here. Area gotchas go to the matching `.agent/docs/` file under `## Gotchas`. Authoring and curation rules: `contract.md`, Self-learning.

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

<!-- Filled by the agent during bootstrap: why this project exists, who it's for, key constraints, and where to change what. -->
EOF

  cp "$srcroot/presets/$preset.md" "$agent/rules/contract.md" \
    || { echo "node.sh: preset copy into rules/contract.md failed" >&2; exit 1; }

  for script in status.sh log.sh memory.sh docs.sh links.sh comments.sh; do
    cp "$srcroot/scripts/$script" "$agent/scripts/$script" \
      || { echo "node.sh: script copy failed: $script" >&2; exit 1; }
    chmod +x "$agent/scripts/$script"
  done
  # Starter confs — the comment gate's vocabulary and the status check's
  # tunables. Configs, so the node edits or deletes them freely from here
  # on. Without the files on disk the knobs are undiscoverable, since
  # agents execute these scripts rather than read them.
  for conffile in comments.conf status.conf log.conf; do
    cp "$srcroot/scripts/$conffile" "$agent/scripts/$conffile" \
      || { echo "node.sh: $conffile copy failed" >&2; exit 1; }
  done

  # A gitignore at $HOME is commonly git's global core.excludesFile. A
  # `.agent/` pattern there would ignore every project node in every repo.
  if [ "$(cd "$root" && pwd -P)" = "$(cd "${HOME:-/nonexistent}" 2>/dev/null && pwd -P)" ]; then
    [ "$mode" = "track-all" ] \
      || echo "node.sh: skipped gitignore at \$HOME (a pattern there can apply to every repo) — if ~ is version-controlled, add the entries to that repo's gitignore by hand"
  else
  case "$mode" in
  ignore-all)
    gitignore="$root/.gitignore"
    if [ ! -e "$gitignore" ] || ! grep -qxF ".agent/" "$gitignore"; then
      # A missing final newline would splice ".agent/" onto the last pattern.
      [ -s "$gitignore" ] && [ -n "$(tail -c 1 "$gitignore")" ] && echo >>"$gitignore"
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
  fi

  echo "node.sh: initialized $agent (preset=$preset, mode=$mode)"
  exit 0
  ;;

update)
  root="${1:-.}"
  agent="$root/.agent"
  purpose="$agent/purpose.md"

  if [ ! -d "$agent" ]; then
    echo "node.sh: no .agent directory at $agent — run from the node's project root, or pass that root as an argument" >&2
    exit 1
  fi

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
  case "$oldversion" in
  *[!0-9.]* | *..* | .* | *.)
    echo "node.sh: manifest version '$oldversion' is not a dotted number — not touching the node" >&2
    exit 1 ;;
  esac

  lowest=$(printf '%s\n%s\n' "$oldversion" "$TARGET_VERSION" | sort -V | head -n1)
  if [ "$lowest" != "$oldversion" ]; then
    # Newer than this script: never touched, not even to migrate a shape
    # this version happens to know about. Its memory.md is a later format's
    # to define.
    echo "node.sh: node is current (version $oldversion)"
    exit 0
  fi
  if [ "$oldversion" = "$TARGET_VERSION" ]; then
    # Version-current is not shape-current: the fact-file header moved into
    # memory.md after 6.1 shipped, so a node already on 6.1 needs the same
    # migration and would never reach the block below. Only when there is
    # something to migrate, and behind the same backup, since memory/ is
    # untracked in every mode but track-all.
    if memory_headers_stale "$agent" || doc_headers_stale "$agent"; then
      if [ "$mode" != "track-all" ]; then
        # Same-version pre-release refreshes must not collide with the backup
        # created by an earlier version migration or shape refresh.
        backup="$root/.agent.backup-v$oldversion-shape"
        if [ -e "$backup" ]; then
          echo "node.sh: backup path already exists: $backup — refusing to proceed" >&2
          exit 1
        fi
        cp -R "$agent" "$backup" \
          || { echo "node.sh: backup to $backup failed — aborting before touching the node" >&2; exit 1; }
        echo "node.sh: backed up node to $backup"
      fi
      migrate_memory_headers "$agent"
      echo "node.sh: $migrate_note"
      migrate_doc_headers "$agent"
      echo "node.sh: $migrate_doc_note"
    fi
    echo "node.sh: node is current (version $oldversion)"
    exit 0
  fi

  # memory.md and memory/ are untracked in every mode except track-all, so
  # git holds no copy of what the migration below rewrites: back up first,
  # and never proceed on a failed backup.
  if [ "$mode" != "track-all" ]; then
    backup="$root/.agent.backup-v$oldversion"
    if [ -e "$backup" ]; then
      echo "node.sh: backup path already exists: $backup — refusing to proceed" >&2
      exit 1
    fi
    cp -R "$agent" "$backup" \
      || { echo "node.sh: backup to $backup failed — aborting before touching the node" >&2; exit 1; }
    echo "node.sh: backed up node to $backup"
  fi

  # Memory split baseline (guarded by memory/ absence — safe to re-run).
  memdir="$agent/memory"
  memory="$agent/memory.md"
  split_note="memory/ already present — split step skipped"
  if [ ! -d "$memdir" ]; then
    mkdir -p "$memdir"
    body_tmp="$agent/.memory-body.tmp"
    if [ -f "$memory" ]; then
      # Honor a closing --> only when a header comment actually opens near
      # the top. Keying on the first --> alone would silently drop every
      # fact above an arrow token in the body of a header-less file.
      header_end=""
      if head -n 5 "$memory" | grep -qF '<!--'; then
        header_end=$(grep -n -- '-->' "$memory" | head -n1 | cut -d: -f1)
      fi
      header_end=${header_end:-0}
      tail -n +"$((header_end + 1))" "$memory" \
        | awk 'NR == 1 && /^# Memory[[:space:]]*$/ { next } { print }' >"$body_tmp"
    else
      : >"$body_tmp"
    fi
    if grep -q '[^[:space:]]' "$body_tmp" 2>/dev/null; then
      sed -e '/./,$!d' "$body_tmp" >"$memdir/legacy.md"
      write_memory_header "$memory"
      printf '\n%s\n' '- [Legacy memory](memory/legacy.md) — unsplit pre-6.1 memory, split per its GROOM flag' >>"$memory"
      split_note="memory.md body moved to memory/legacy.md (GROOM flag will prompt the fact split)"
    else
      write_memory_header "$memory"
      split_note="memory.md was empty/header-only — replaced with the index header, no legacy file"
    fi
    rm -f "$body_tmp"
  fi

  migrate_memory_headers "$agent"
  migrate_doc_headers "$agent"
  header_note="$migrate_note; $migrate_doc_note"

  # Refresh the shipped scripts from the source repo — by exactly these
  # names. Anything else under scripts/ is the node's own and is never
  # overwritten. A missing starter conf is seeded, the one write that
  # cannot clobber node content.
  mkdir -p "$agent/scripts"
  for script in status.sh log.sh memory.sh docs.sh links.sh comments.sh; do
    cp "$srcroot/scripts/$script" "$agent/scripts/$script"
    chmod +x "$agent/scripts/$script"
  done
  for conffile in comments.conf status.conf log.conf; do
    if [ ! -f "$agent/scripts/$conffile" ]; then
      cp "$srcroot/scripts/$conffile" "$agent/scripts/$conffile"
      echo "node.sh: $conffile seeded with the starter (node-owned from here on)"
    fi
  done

  # Bump version — nothing else in the frontmatter changes. Rewrite exactly
  # the line the version was read from, so the read and the write can never
  # disagree about where the version lives.
  vline=$(grep -n -m1 '^  version:' "$purpose" | cut -d: -f1)
  purpose_new="$agent/.purpose.md.new"
  sed -E "${vline}s/^(  version:).*/\1 \"$TARGET_VERSION\"/" "$purpose" >"$purpose_new"
  mv "$purpose_new" "$purpose"

  echo "node.sh: updated $agent from version $oldversion to $TARGET_VERSION"
  echo "node.sh: $split_note"
  echo "node.sh: $header_note"
  echo "node.sh: status.sh, log.sh, memory.sh, docs.sh, links.sh, and comments.sh refreshed from source repo"
  echo "node.sh: remaining for the agent — split memory/legacy.md into fact files (status.sh flags it with GROOM), reconcile rules/contract.md and docs/ against the current presets and operating model"
  exit 0
  ;;

*)
  usage >&2
  exit 1
  ;;
esac
