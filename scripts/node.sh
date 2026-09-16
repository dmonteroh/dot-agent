#!/usr/bin/env bash
# .agent/ node bootstrap and update — the mechanical parts only. Judgement
# (exploring the project, filling Project guardrails, reconciling content
# during an update) stays with the agent. This script never does either.
#
# Full documentation: scripts/docs/node.md.
#
# Usage:
#   node.sh init --preset <name> --mode <mode> [--indexes <manual|generated>] [root]
#   node.sh update [root]
#   node.sh finalize [root]
#
#   <name> matches a file in the source repo's presets/ (currently
#   software-development, academic-research, domain-knowledge).
#   <mode> is one of: ignore-all | track-shared | track-all.
#   --indexes defaults to manual; generated wires up the local Markdown
#   index cache (scripts/docs/index.md).
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
  node.sh init --preset <software-development|academic-research|domain-knowledge> --mode <ignore-all|track-shared|track-all> [--indexes <manual|generated>] [root]
  node.sh update [root]
  node.sh finalize [root]

--indexes defaults to manual. root defaults to . — the script operates on
<root>/.agent
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

# Writes migration_target into the manifest frontmatter, using the same
# read/write mechanism as version: rewrite the existing line in place, or
# insert one right after `version:` if none exists yet. Idempotent —
# writing the value it already holds is a no-op edit — so callers never
# need to special-case a resumed update.
#
# Returns nonzero, and leaves $wmt_purpose byte-identical, if the write
# cannot be proven complete: the transform command itself failing, the
# scratch file ending up empty or the wrong line count (a partial or
# truncated write), or the target line missing the value once written all
# count as failure, never a silent partial replacement. Replacement of the
# manifest is write-then-rename within the same directory, so it is atomic:
# either the caller sees the fully-written new content, or the original file
# is untouched. On failure the scratch file is removed only if this call
# created it as a plain file — a pre-existing non-file collision at that
# path (e.g. a directory) is left exactly as found, since it was not this
# invocation's to clean up.
write_migration_target() {
  wmt_purpose="$1"
  wmt_value="$2"
  wmt_new="$(dirname "$wmt_purpose")/.purpose.md.new"
  wmt_old_lines=$(wc -l <"$wmt_purpose" 2>/dev/null || echo 0)
  if grep -q '^  migration_target:' "$wmt_purpose"; then
    wmt_line=$(grep -n -m1 '^  migration_target:' "$wmt_purpose" | cut -d: -f1)
    sed -E "${wmt_line}s/^(  migration_target:).*/\1 \"$wmt_value\"/" "$wmt_purpose" >"$wmt_new"
    wmt_rc=$?
    wmt_expect_lines="$wmt_old_lines"
  else
    wmt_line=$(grep -n -m1 '^  version:' "$wmt_purpose" | cut -d: -f1)
    awk -v n="$wmt_line" -v val="$wmt_value" \
      'NR==n { print; print "  migration_target: \"" val "\""; next } { print }' \
      "$wmt_purpose" >"$wmt_new"
    wmt_rc=$?
    wmt_expect_lines=$((wmt_old_lines + 1))
  fi
  wmt_new_lines=$(wc -l <"$wmt_new" 2>/dev/null || echo 0)
  if [ "$wmt_rc" -ne 0 ] || [ ! -s "$wmt_new" ] \
    || [ "$wmt_new_lines" -ne "$wmt_expect_lines" ] \
    || ! grep -qF "migration_target: \"$wmt_value\"" "$wmt_new"; then
    [ -f "$wmt_new" ] && rm -f "$wmt_new"
    return 1
  fi
  mv "$wmt_new" "$wmt_purpose"
}

# Writes indexes into the manifest frontmatter, beside mode, using the same
# read/write mechanism as write_migration_target: rewrite the existing line
# in place, or insert one right after `mode:` if none exists yet — the
# only path a manifest predating the indexes field takes, since init
# always writes the line. Same failure contract: nonzero return and an
# untouched $wi_purpose unless the scratch file is proven to hold a
# complete, correct rewrite before the atomic rename.
write_indexes() {
  wi_purpose="$1"
  wi_value="$2"
  wi_new="$(dirname "$wi_purpose")/.purpose.md.new"
  wi_old_lines=$(wc -l <"$wi_purpose" 2>/dev/null || echo 0)
  if grep -q '^  indexes:' "$wi_purpose"; then
    wi_line=$(grep -n -m1 '^  indexes:' "$wi_purpose" | cut -d: -f1)
    sed -E "${wi_line}s/^(  indexes:).*/\1 $wi_value        # manual | generated/" "$wi_purpose" >"$wi_new"
    wi_rc=$?
    wi_expect_lines="$wi_old_lines"
  else
    wi_line=$(grep -n -m1 '^  mode:' "$wi_purpose" | cut -d: -f1)
    awk -v n="$wi_line" -v val="$wi_value" \
      'NR==n { print; print "  indexes: " val "        # manual | generated"; next } { print }' \
      "$wi_purpose" >"$wi_new"
    wi_rc=$?
    wi_expect_lines=$((wi_old_lines + 1))
  fi
  wi_new_lines=$(wc -l <"$wi_new" 2>/dev/null || echo 0)
  if [ "$wi_rc" -ne 0 ] || [ ! -s "$wi_new" ] \
    || [ "$wi_new_lines" -ne "$wi_expect_lines" ] \
    || ! grep -qF "indexes: $wi_value" "$wi_new"; then
    [ -f "$wi_new" ] && rm -f "$wi_new"
    return 1
  fi
  mv "$wi_new" "$wi_purpose"
}

# Stamps version to the given value using the same read/write mechanism as
# write_migration_target: rewrite the existing line in place. version always
# exists (init writes it), so unlike write_migration_target there is no
# insert branch. Same failure contract as write_migration_target: nonzero
# return and an untouched $wv_purpose unless the scratch file is proven to
# hold a complete, correct rewrite before the atomic rename.
write_version() {
  wv_purpose="$1"
  wv_value="$2"
  wv_new="$(dirname "$wv_purpose")/.purpose.md.new"
  wv_old_lines=$(wc -l <"$wv_purpose" 2>/dev/null || echo 0)
  wv_line=$(grep -n -m1 '^  version:' "$wv_purpose" | cut -d: -f1)
  sed -E "${wv_line}s/^(  version:).*/\1 \"$wv_value\"/" "$wv_purpose" >"$wv_new"
  wv_rc=$?
  wv_new_lines=$(wc -l <"$wv_new" 2>/dev/null || echo 0)
  if [ "$wv_rc" -ne 0 ] || [ ! -s "$wv_new" ] \
    || [ "$wv_new_lines" -ne "$wv_old_lines" ] \
    || ! grep -qF "version: \"$wv_value\"" "$wv_new"; then
    [ -f "$wv_new" ] && rm -f "$wv_new"
    return 1
  fi
  mv "$wv_new" "$wv_purpose"
}

# Removes the migration_target line entirely. Called only after write_version
# has already stamped version — never the reverse, so a crash between the
# two calls leaves a node that still reads as mid-migration rather than one
# that falsely reads as finished. Same failure contract as the writers above:
# nonzero return and an untouched $rmt_purpose unless the scratch file is
# proven to hold exactly the original minus the one line removed.
remove_migration_target() {
  rmt_purpose="$1"
  rmt_new="$(dirname "$rmt_purpose")/.purpose.md.new"
  rmt_old_lines=$(wc -l <"$rmt_purpose" 2>/dev/null || echo 0)
  grep -v '^  migration_target:' "$rmt_purpose" >"$rmt_new"
  rmt_rc=$?
  rmt_new_lines=$(wc -l <"$rmt_new" 2>/dev/null || echo 0)
  if [ "$rmt_rc" -eq 2 ] || [ ! -s "$rmt_new" ] \
    || [ "$rmt_new_lines" -ne "$((rmt_old_lines - 1))" ] \
    || grep -q '^  migration_target:' "$rmt_new"; then
    [ -f "$rmt_new" ] && rm -f "$rmt_new"
    return 1
  fi
  mv "$rmt_new" "$rmt_purpose"
}

# session-log.md's title plus header comment. node.sh writes it down two
# paths: init and the migration (both the version-migration path and the
# same-version shape-refresh branch). One writer keeps a node created today
# and a node updated today on the same contract.
write_session_log_header() {
  cat >"$1" <<'EOF'
# Session log
<!-- One entry per turn that changed files, newest last. Format: - [YYYY-MM-DD] (tool) <task, area, outcome — ≤25 words>. verify: pass|fail|n/a. The summary text never contains `verify:`; log.sh stamps the tag from --verify and rejects a summary that carries one. Append the model to the tool tag when the harness states one — (claude/sonnet). Never guess it. The verify tag is this change's own verification result: a baseline failure that predates the change goes in the summary text, not the tag. No file lists, SHAs, test counts, reviewer verdicts, or narrative. Preferred writer: .agent/scripts/log.sh, which stamps the date and enforces the ceiling. With log.conf's LOG_INCLUDE_BRANCH=true it also stamps `branch: <name>.` before verify, read from git. -->
EOF
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

# session-log.md's header comment. A node may carry any earlier wording —
# the 6.2 "one entry per session" phrasing or something older still — so
# this is negative-on-the-new-sentinel, not a check for the exact old
# string, the same shape as memory_index_header_stale.
session_log_header_stale() {
  slh_log="$1"
  [ -f "$slh_log" ] || return 1
  grep -qF 'One entry per turn that changed files, newest last.' "$slh_log" || return 0
  return 1
}

# Exact-string, like migrate_memory_headers: the header comment is located
# by its closing --> and everything below it (the actual log entries) is
# preserved byte-identical, in order. A file with no header comment at all
# in its first five lines is left completely untouched — restoring a header
# a node deliberately deleted is a different decision. Sets migrate_log_note.
migrate_session_log_header() {
  msl_agent="$1"
  msl_log="$msl_agent/session-log.md"
  migrate_log_note="session log header already current"
  [ -f "$msl_log" ] || return 0
  session_log_header_stale "$msl_log" || return 0
  if ! head -n 5 "$msl_log" | grep -qF '<!--'; then
    migrate_log_note="session-log.md has no header comment — left untouched"
    return 0
  fi
  msl_end=$(grep -n -- '-->' "$msl_log" | head -n1 | cut -d: -f1)
  msl_body="$msl_agent/.session-log-body.tmp"
  tail -n +"$((msl_end + 1))" "$msl_log" \
    | awk 'NR == 1 && /^# Session log[[:space:]]*$/ { next } { print }' \
    | sed -e '/./,$!d' >"$msl_body"
  write_session_log_header "$msl_log"
  cat "$msl_body" >>"$msl_log"
  rm -f "$msl_body"
  migrate_log_note="session-log.md header refreshed"
  return 0
}

# Mints a 12-lowercase-hex-char identity unused as a filename in $1 and not
# yet minted this run (one id per line in $2), then claims it by creating
# the empty record file with `set -C` — a lost create race is one more
# rejection, never an overwrite. Every $RANDOM read happens directly in
# this shell, never inside a `$(...)` fork: forking to capture output
# perturbs bash's generator on each fork, which would make every mint
# after the first re-walk and collide with all earlier ids instead of
# advancing past them. Sets $mint_id_result on success. Returns nonzero
# after 100 consecutive rejections, having minted and written nothing.
mint_learned_id() {
  mli_dir="$1"
  mli_minted="$2"
  mli_tries=0
  mint_id_result=""
  while :; do
    mli_r1="$RANDOM"
    mli_r2="$RANDOM"
    mli_r3="$RANDOM"
    printf -v mli_id '%04x%04x%04x' "$mli_r1" "$mli_r2" "$mli_r3"
    mli_target="$mli_dir/$mli_id.md"
    if [ -e "$mli_target" ] || { [ -s "$mli_minted" ] && grep -qxF "$mli_id" "$mli_minted"; }; then
      mli_tries=$((mli_tries + 1))
      [ "$mli_tries" -lt 100 ] && continue
      return 1
    fi
    if (set -C; : >"$mli_target") 2>/dev/null; then
      printf '%s\n' "$mli_id" >>"$mli_minted"
      mint_id_result="$mli_id"
      return 0
    fi
    mli_tries=$((mli_tries + 1))
    [ "$mli_tries" -lt 100 ] || return 1
  done
}

# A rule span (verbatim lines in file $1, first line included) is
# semantic-review-pending when it carries an indented sub-bullet, or a
# second paragraph after a blank line — the two shapes a mechanical split
# cannot tell apart from one rule that reads as two subjects.
classify_rule_span() {
  crs_span="$1"
  if tail -n +2 "$crs_span" | grep -qE '^[[:space:]]+[-*][[:space:]]'; then
    printf 'semantic-review-pending'
    return 0
  fi
  if tail -n +2 "$crs_span" | awk '
    /^[[:space:]]*$/ { blank = 1; next }
    blank { multi = 1 }
    END { exit multi ? 0 : 1 }
  '; then
    printf 'semantic-review-pending'
    return 0
  fi
  printf 'migrated'
}

# One bullet span, lines $3..$4 inclusive of $2 (rules/learned.md), mints
# an identity, writes the span verbatim to $5/<id>.md, classifies it, and
# appends its inventory line to $8. $9 numbers the bullet for the
# inventory's item label only — never the identity, which is minted, not
# derived from position.
extract_one_rule_span() {
  eor_learned="$1"; eor_start="$2"; eor_end="$3"
  eor_dir="$4"; eor_minted="$5"; eor_span="$6"; eor_inventory="$7"; eor_n="$8"
  mint_learned_id "$eor_dir" "$eor_minted" \
    || { echo "node.sh: aborting learned-rule extraction — 100 consecutive identity collisions in $eor_dir" >&2; return 1; }
  eor_id="$mint_id_result"
  sed -n "${eor_start},${eor_end}p" "$eor_learned" >"$eor_span"
  cat "$eor_span" >"$eor_dir/$eor_id.md"
  eor_preview=$(head -n1 "$eor_span" | cut -c1-72)
  eor_disp=$(classify_rule_span "$eor_span")
  printf -- '- rule %s: `%s` -> rules/learned/%s.md | id=%s | %s\n' \
    "$eor_n" "$eor_preview" "$eor_id" "$eor_id" "$eor_disp" >>"$eor_inventory"
}

# Splits $1/rules/learned.md into one record per top-level "^- " bullet.
# The span starts at that line and runs to the line before the next "^- "
# line, or to end of file — indented sub-bullets, blank lines, and
# continuation paragraphs inside that span belong to the record that
# opened it. The header above the first bullet (title, prose, and the
# "<!-- Format: … -->" comment, whose own "- [" is never at line start) is
# never read. No-op when $1/rules/learned.md does not exist or holds no
# bullet. Appends one inventory line per bullet to $2.
extract_learned_rules() {
  elr_agent="$1"
  elr_inventory="$2"
  elr_learned="$elr_agent/rules/learned.md"
  elr_dir="$elr_agent/rules/learned"
  [ -f "$elr_learned" ] || return 0
  elr_starts="$elr_agent/.learned-bullet-starts.tmp"
  grep -n '^- ' "$elr_learned" | cut -d: -f1 >"$elr_starts"
  if [ ! -s "$elr_starts" ]; then
    rm -f "$elr_starts"
    return 0
  fi
  elr_total=$(wc -l <"$elr_learned" | tr -d '[:space:]')
  elr_minted="$elr_agent/.learned-minted-ids.tmp"
  : >"$elr_minted"
  elr_span="$elr_agent/.learned-span.tmp"
  elr_prev=""
  elr_n=0
  elr_rc=0
  while IFS= read -r elr_start; do
    if [ -n "$elr_prev" ]; then
      elr_n=$((elr_n + 1))
      extract_one_rule_span "$elr_learned" "$elr_prev" "$((elr_start - 1))" \
        "$elr_dir" "$elr_minted" "$elr_span" "$elr_inventory" "$elr_n" || { elr_rc=1; break; }
    fi
    elr_prev="$elr_start"
  done <"$elr_starts"
  if [ "$elr_rc" -eq 0 ] && [ -n "$elr_prev" ]; then
    elr_n=$((elr_n + 1))
    extract_one_rule_span "$elr_learned" "$elr_prev" "$elr_total" \
      "$elr_dir" "$elr_minted" "$elr_span" "$elr_inventory" "$elr_n" || elr_rc=1
  fi
  rm -f "$elr_starts" "$elr_minted" "$elr_span"
  return "$elr_rc"
}

# Backfills a doc's missing "Read when:" hook from its architecture.md
# entry. The lookup is copied from status.sh's own doc_hook/entry_block
# (read-only there) rather than sourced, since this runs during a
# migration status.sh has not walked yet. Leaves the doc byte-identical
# whenever the lookup cannot be trusted: no architecture.md, no entry line
# for $2, more than one entry line for $2, an entry block with no
# "- **Read when:**" line, or an extracted hook that is empty or contains
# "-->". Only ever inserts the hook as the doc's new first line; nothing
# else in the file changes. Prints "migrated" or "hook-missing".
backfill_doc_hook() {
  bdh_doc="$1"
  bdh_key="$2"
  bdh_arch="$3"

  if head -n 5 "$bdh_doc" | grep -q '^<!-- Read when: .* -->$'; then
    printf 'migrated'
    return 0
  fi

  if [ ! -s "$bdh_arch" ]; then
    printf 'hook-missing'
    return 0
  fi

  bdh_want="### \`$bdh_key\`"
  bdh_count=$(grep -x -F -- "$bdh_want" "$bdh_arch" | grep -c .)
  if [ "$bdh_count" -ne 1 ]; then
    printf 'hook-missing'
    return 0
  fi

  bdh_block=$(awk -v want="$bdh_want" '
    $0 == want { inb = 1; next }
    inb && index($0, "### ") == 1 { exit }
    inb { print }
  ' "$bdh_arch")
  bdh_hook=$(printf '%s\n' "$bdh_block" | sed -n 's/^- \*\*Read when:\*\* //p' | head -n 1)

  if [ -z "$bdh_hook" ]; then
    printf 'hook-missing'
    return 0
  fi
  case "$bdh_hook" in
  *'-->'*)
    printf 'hook-missing'
    return 0 ;;
  esac

  bdh_tmp="$(dirname "$bdh_doc")/.$(basename "$bdh_doc").hook.tmp"
  if { printf '<!-- Read when: %s -->\n' "$bdh_hook"; cat "$bdh_doc"; } >"$bdh_tmp" \
    && mv "$bdh_tmp" "$bdh_doc"; then
    printf 'migrated'
  else
    rm -f "$bdh_tmp"
    printf 'hook-missing'
  fi
}

# Walks $1/docs exactly as status.sh does: "$docs"/*.md and
# "$docs"/*/*.md, two levels, architecture.md and any references/ tier
# (at either level) excluded. Backfills each remaining doc's hook and
# appends one inventory line per doc to $2.
backfill_doc_hooks() {
  bfd_agent="$1"
  bfd_inventory="$2"
  bfd_docs="$bfd_agent/docs"
  bfd_arch="$bfd_docs/architecture.md"
  [ -d "$bfd_docs" ] || return 0
  for bfd_doc in "$bfd_docs"/*.md "$bfd_docs"/*/*.md; do
    [ -e "$bfd_doc" ] || continue
    bfd_rel=${bfd_doc#"$bfd_docs"/}
    [ "$bfd_rel" = "architecture.md" ] && continue
    case "$bfd_rel" in
    references/* | */references/*) continue ;;
    esac
    bfd_disp=$(backfill_doc_hook "$bfd_doc" "$bfd_rel" "$bfd_arch")
    printf -- '- doc docs/%s -> docs/%s | id=%s | %s\n' "$bfd_rel" "$bfd_rel" "$bfd_rel" "$bfd_disp" >>"$bfd_inventory"
  done
}

# Runs once per node: mints a stable identity for every rules/learned.md
# bullet, writes each as its own record under rules/learned/, backfills
# every doc's missing "Read when:" hook from architecture.md, and writes
# the combined disposition inventory to migration-inventory.md. A
# no-op — nothing minted, written, or touched — whenever rules/learned/
# already holds any *.md record, which is this pass's own completion
# marker: there is no separate resume state.
migrate_learned_and_docs() {
  mld_agent="$1"
  mkdir -p "$mld_agent/rules/learned" || return 1
  for mld_existing in "$mld_agent/rules/learned"/*.md; do
    [ -e "$mld_existing" ] && return 0
  done
  mld_inventory_tmp="$mld_agent/.migration-inventory.tmp"
  : >"$mld_inventory_tmp"
  extract_learned_rules "$mld_agent" "$mld_inventory_tmp" || { rm -f "$mld_inventory_tmp"; return 1; }
  backfill_doc_hooks "$mld_agent" "$mld_inventory_tmp"
  { printf '# Migration inventory\n\nOne line per original authoritative item: its new location, identity, and disposition.\n\n'
    cat "$mld_inventory_tmp"
  } >"$mld_agent/migration-inventory.md"
  rm -f "$mld_inventory_tmp"
  return 0
}

case "$cmd" in
init)
  preset=""
  mode=""
  indexes=""
  root="."
  while [ $# -gt 0 ]; do
    case "$1" in
    --preset)
      [ $# -ge 2 ] || { echo "node.sh: --preset needs a value" >&2; usage >&2; exit 1; }
      preset="$2"; shift 2 ;;
    --mode)
      [ $# -ge 2 ] || { echo "node.sh: --mode needs a value" >&2; usage >&2; exit 1; }
      mode="$2"; shift 2 ;;
    --indexes)
      [ $# -ge 2 ] || { echo "node.sh: --indexes needs a value" >&2; usage >&2; exit 1; }
      indexes="$2"; shift 2 ;;
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
  indexes="${indexes:-manual}"
  case "$indexes" in
  manual | generated) ;;
  *)
    echo "node.sh: unknown --indexes: '$indexes' (must be manual or generated)" >&2
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

  write_session_log_header "$agent/session-log.md"

  write_memory_header "$agent/memory.md"

  cat >"$agent/rules/learned.md" <<'EOF'
# Learned rules

Binding rules distilled from operator corrections and failed verifications on this project, after the canonical-source check in `contract.md`. A correction that exposes a defect in the contract, docs, code, or tooling is fixed there and produces no compensating rule. Merging and compressing entries is allowed. Drop a rule when its failure mode becomes mechanically enforced. Behavioral rules stay here. Area gotchas go to the matching `.agent/docs/` file under `## Gotchas`. Authoring and curation rules: `contract.md`, Self-learning.

<!-- Format: - [YYYY-MM-DD] <imperative rule>. Trigger: <cause, optional>. -->
EOF

  cat >"$agent/purpose.md" <<EOF
---
# Do not remove or rewrite this block; update passes may set \`migration_target\` — version changes only at finalize.
dot-agent:
  source: $SOURCE_URL
  version: "$TARGET_VERSION"
  preset: $preset
  mode: $mode        # ignore-all | track-shared | track-all
  indexes: $indexes        # manual | generated
  children: []              # repo-relative paths to child .agent/ nodes
---

# Purpose

<!-- Filled by the agent during bootstrap: why this project exists, who it's for, key constraints, and where to change what. -->
EOF

  cp "$srcroot/presets/$preset.md" "$agent/rules/contract.md" \
    || { echo "node.sh: preset copy into rules/contract.md failed" >&2; exit 1; }

  for script in status.sh log.sh memory.sh docs.sh links.sh comments.sh finish.sh index.sh; do
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
    # track-all with indexes: manual writes no gitignore either way, so
    # staying silent there matches today. Every other combination — every
    # non-track-all mode, and track-all with indexes: generated, which
    # would otherwise add .agent/indexes/ and .agent/rules/learned.md —
    # writes something at $HOME and must warn instead of silently skipping it.
    { [ "$mode" = "track-all" ] && [ "$indexes" != generated ]; } \
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
    if [ "$indexes" = generated ]; then
      if [ ! -e "$gitignore" ] || ! grep -qxF ".agent/indexes/" "$gitignore"; then
        [ -s "$gitignore" ] && [ -n "$(tail -c 1 "$gitignore")" ] && echo >>"$gitignore"
        printf '.agent/indexes/\n' >>"$gitignore"
      fi
      if [ ! -e "$gitignore" ] || ! grep -qxF ".agent/rules/learned.md" "$gitignore"; then
        [ -s "$gitignore" ] && [ -n "$(tail -c 1 "$gitignore")" ] && echo >>"$gitignore"
        printf '.agent/rules/learned.md\n' >>"$gitignore"
      fi
    fi
    ;;
  track-all)
    if [ "$indexes" = generated ]; then
      gitignore="$root/.gitignore"
      if [ ! -e "$gitignore" ] || ! grep -qxF ".agent/indexes/" "$gitignore"; then
        [ -s "$gitignore" ] && [ -n "$(tail -c 1 "$gitignore")" ] && echo >>"$gitignore"
        printf '.agent/indexes/\n' >>"$gitignore"
      fi
      if [ ! -e "$gitignore" ] || ! grep -qxF ".agent/rules/learned.md" "$gitignore"; then
        [ -s "$gitignore" ] && [ -n "$(tail -c 1 "$gitignore")" ] && echo >>"$gitignore"
        printf '.agent/rules/learned.md\n' >>"$gitignore"
      fi
    fi
    ;;
  esac
  fi

  echo "node.sh: initialized $agent (preset=$preset, mode=$mode, indexes=$indexes)"
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
  indexes_line=$(grep -m1 '^  indexes:' "$purpose")
  indexes=$(printf '%s\n' "$indexes_line" | sed -E 's/^[[:space:]]*indexes:[[:space:]]*([A-Za-z-]+).*/\1/')
  [ -n "$indexes" ] || indexes=manual
  migration_target_line=$(grep -m1 '^  migration_target:' "$purpose")
  migration_target=$(printf '%s\n' "$migration_target_line" | sed -E 's/^[[:space:]]*migration_target:[[:space:]]*"?([^"[:space:]]*)"?.*/\1/')

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
    # A manifest with no indexes line at all is backfilled as manual, the
    # same value an absent field already reads as, so nothing about the
    # node's behavior changes. Skipped for a node newer than this script
    # (the branch above): that path never touches the node at all.
    if [ -z "$indexes_line" ]; then
      write_indexes "$purpose" manual \
        || { echo "node.sh: failed to record indexes in $purpose — aborting before touching node content" >&2; exit 1; }
      echo "node.sh: indexes: manual backfilled into $purpose"
    fi

    # index.sh ships on every update, version-current nodes included:
    # track-shared gitignores .agent/scripts/, so a fresh clone or worktree
    # of an otherwise-current node has none of it, and this branch — which
    # otherwise has nothing to migrate — is the only refresh path such a
    # checkout ever reaches.
    mkdir -p "$agent/scripts" \
      || { echo "node.sh: could not create $agent/scripts" >&2; exit 1; }
    cp "$srcroot/scripts/index.sh" "$agent/scripts/index.sh" \
      || { echo "node.sh: index.sh copy failed" >&2; exit 1; }
    chmod +x "$agent/scripts/index.sh"

    # Version-current is not shape-current: the fact-file header moved into
    # memory.md after 6.1 shipped, so a node already on 6.1 needs the same
    # migration and would never reach the block below. Only when there is
    # something to migrate, and behind the same backup, since memory/ is
    # untracked in every mode but track-all.
    if memory_headers_stale "$agent" || doc_headers_stale "$agent" || session_log_header_stale "$agent/session-log.md"; then
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
      migrate_session_log_header "$agent"
      echo "node.sh: $migrate_log_note"
    fi
    echo "node.sh: node is current (version $oldversion)"
    exit 0
  fi

  # memory.md and memory/ are untracked in every mode except track-all, so
  # git holds no copy of what the migration below rewrites: back up first,
  # and never proceed on a failed backup. A collision is normally an
  # unexplained file and aborts — except when migration_target already
  # names this run's TARGET_VERSION, which means an earlier update reached
  # this exact backup and was interrupted before finishing: that backup
  # still holds the pre-migration node, so the retry reuses it rather than
  # re-copying over it (which would replace the pre-migration snapshot with
  # a half-migrated one).
  if [ "$mode" != "track-all" ]; then
    backup="$root/.agent.backup-v$oldversion"
    if [ -e "$backup" ]; then
      if [ "$migration_target" = "$TARGET_VERSION" ]; then
        echo "node.sh: $backup already holds the pre-migration node — resuming the interrupted update"
      else
        echo "node.sh: backup path already exists: $backup — refusing to proceed" >&2
        exit 1
      fi
    else
      cp -R "$agent" "$backup" \
        || { echo "node.sh: backup to $backup failed — aborting before touching the node" >&2; exit 1; }
      echo "node.sh: backed up node to $backup"
    fi
  fi

  # Record the pending migration before any node content is mutated, so an
  # interruption anywhere below is detectable from the manifest alone.
  # version itself is untouched here — it stays at $oldversion until
  # finalize stamps it. A failed write must abort here, before any content
  # mutation below, or a crash would be undetectable from the manifest —
  # the exact defect this record-first ordering exists to prevent.
  write_migration_target "$purpose" "$TARGET_VERSION" \
    || { echo "node.sh: failed to record migration_target in $purpose — aborting before touching node content" >&2; exit 1; }

  # A manifest with no indexes line at all is backfilled as manual, the
  # same value an absent field already reads as, so nothing about the
  # node's behavior changes. After migration_target above, not before: a
  # blocked write here must never mask a genuine migration_target failure
  # behind a different error.
  if [ -z "$indexes_line" ]; then
    write_indexes "$purpose" manual \
      || { echo "node.sh: failed to record indexes in $purpose — aborting before touching node content" >&2; exit 1; }
    echo "node.sh: indexes: manual backfilled into $purpose"
  fi

  # Memory split baseline. memdir's mere existence cannot gate this: it
  # cannot distinguish "never split" from "split, interrupted mid-write"
  # from "already fully split into real fact files" — all three leave
  # memdir present, and each needs different treatment. The outer gate
  # below instead reads two independent signals:
  #   - memdir already holding any *.md file (legacy.md or a real fact
  #     file) means some split — this migration's or an earlier one's —
  #     already produced content there, so a stale header alone (a
  #     genuinely pre-split node due for migrate_memory_headers below, not
  #     this block) must never trigger a re-extraction that would read the
  #     current index as if it were an unsplit body and discard it into a
  #     fresh legacy.md.
  #   - a dedicated in-progress marker, written before the first content
  #     write below and removed only after the last one succeeds, so a
  #     crash between those two points is distinguishable from both a
  #     fresh node and a genuinely already-split one, and a retry resumes
  #     rather than silently skipping.
  # Inside the gate, step 1 (extraction) and step 2 (the index link) are
  # each independently idempotent: step 1 is gated on memory.md's own
  # header contract (memory_index_header_stale, the same check
  # migrate_memory_headers uses below) so a crash after step 1 already
  # rewrote memory.md is never mistaken for an unsplit body; step 2 is
  # gated on legacy.md existing with no index line yet, so a crash between
  # the two writes resumes by finishing step 2 alone, without redoing step 1.
  memdir="$agent/memory"
  memory="$agent/memory.md"
  split_marker="$memdir/.split-in-progress"
  mkdir -p "$memdir" \
    || { echo "node.sh: failed to create $memdir — aborting before touching node content" >&2; exit 1; }
  memdir_has_content=0
  for mdf in "$memdir"/*.md; do
    [ -e "$mdf" ] && { memdir_has_content=1; break; }
  done
  split_note="memory/ already present — split step skipped"
  if [ -e "$split_marker" ] \
    || { [ "$memdir_has_content" -eq 0 ] && { [ ! -f "$memory" ] || memory_index_header_stale "$memory"; }; }; then
    : >"$split_marker" \
      || { echo "node.sh: failed to record $split_marker — aborting before touching node content" >&2; exit 1; }
    if [ ! -f "$memory" ] || memory_index_header_stale "$memory"; then
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
        split_note="memory.md body moved to memory/legacy.md (GROOM flag will prompt the fact split)"
      else
        write_memory_header "$memory"
        split_note="memory.md was empty/header-only — replaced with the index header, no legacy file"
      fi
      rm -f "$body_tmp"
    fi
    if [ -f "$memdir/legacy.md" ] && ! grep -qF '(memory/legacy.md)' "$memory"; then
      printf '\n%s\n' '- [Legacy memory](memory/legacy.md) — unsplit pre-6.1 memory, split per its GROOM flag' >>"$memory"
      case "$split_note" in
      "memory/ already present — split step skipped")
        split_note="memory/legacy.md already present from an interrupted split; resumed by appending its missing index link" ;;
      esac
    fi
    rm -f "$split_marker"
  fi

  migrate_memory_headers "$agent"
  migrate_doc_headers "$agent"
  migrate_session_log_header "$agent"
  header_note="$migrate_note; $migrate_doc_note; $migrate_log_note"

  # Refresh the shipped scripts from the source repo — by exactly these
  # names. Anything else under scripts/ is the node's own and is never
  # overwritten. A missing starter conf is seeded, the one write that
  # cannot clobber node content.
  mkdir -p "$agent/scripts"
  for script in status.sh log.sh memory.sh docs.sh links.sh comments.sh finish.sh index.sh; do
    cp "$srcroot/scripts/$script" "$agent/scripts/$script"
    chmod +x "$agent/scripts/$script"
  done
  for conffile in comments.conf status.conf log.conf; do
    if [ ! -f "$agent/scripts/$conffile" ]; then
      cp "$srcroot/scripts/$conffile" "$agent/scripts/$conffile"
      echo "node.sh: $conffile seeded with the starter (node-owned from here on)"
    fi
  done

  # Generated-mode only: extract rules/learned.md into rules/learned/
  # records and backfill missing doc hooks. Runs on the node the backup
  # above already covers. rules/learned.md stays tracked and in place;
  # nothing here untracks it or checks the aggregate.
  if [ "$indexes" = generated ]; then
    migrate_learned_and_docs "$agent" \
      || { echo "node.sh: learned-rule extraction or doc-hook backfill failed under $agent — aborting" >&2; exit 1; }
  fi

  # No version write here — version stays at $oldversion until finalize
  # stamps it. migration_target (set above, before any mutation) is what
  # records that this migration ran.
  echo "node.sh: migrated $agent from version $oldversion toward $TARGET_VERSION (migration_target set; version unchanged)"
  echo "node.sh: $split_note"
  echo "node.sh: $header_note"
  echo "node.sh: status.sh, log.sh, memory.sh, docs.sh, links.sh, comments.sh, finish.sh, and index.sh refreshed from source repo"
  echo "node.sh: remaining for the agent — split memory/legacy.md into fact files (status.sh flags it with GROOM), reconcile rules/contract.md and docs/ against the current presets and operating model, then run finalize to stamp version $TARGET_VERSION"
  exit 0
  ;;

finalize)
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
This looks like a pre-V6 node. node.sh finalize only handles manifested
(V6+) nodes — restoring a missing manifest is an agent-driven task, not a
mechanical one. Read CHANGELOG.md (the pre-V6 migration checklist) and
update this node by hand in a normal session.
EOF
    exit 1
  fi

  migration_target_line=$(grep -m1 '^  migration_target:' "$purpose")
  migration_target=$(printf '%s\n' "$migration_target_line" | sed -E 's/^[[:space:]]*migration_target:[[:space:]]*"?([^"[:space:]]*)"?.*/\1/')

  if [ -z "$migration_target" ]; then
    echo "node.sh: $agent already finalized — no migration_target pending"
    exit 0
  fi

  # The node's own status.sh, not this repo's copy: update already
  # refreshed it into the node, so it is current by the time a node can be
  # pending.
  statussh="$agent/scripts/status.sh"
  if [ ! -x "$statussh" ]; then
    echo "node.sh: $statussh missing or not executable — cannot verify the node before finalize (refusing)" >&2
    exit 1
  fi

  # stdout and stderr are captured separately (never folded together with
  # 2>&1) so a crash cannot be mistaken for findings: status.sh does not
  # exit non-zero for its own REPAIR/GROOM findings, so those come from
  # stdout's content below, but a nonzero exit or any stderr output means
  # the inspection itself did not complete and is refused before the
  # findings are even read. An empty stdout is refused the same way — it
  # is never a pass, no matter how it came about.
  status_stderr_file=$(mktemp "${TMPDIR:-/tmp}/node-finalize-status.XXXXXX")
  status_out=$("$statussh" "$root" 2>"$status_stderr_file")
  status_rc=$?
  status_err=$(cat "$status_stderr_file")
  rm -f "$status_stderr_file"
  if [ "$status_rc" -ne 0 ] || [ -n "$status_err" ] || [ -z "$status_out" ]; then
    echo "node.sh: $statussh did not run cleanly (exit $status_rc) — refusing to finalize (fail closed)" >&2
    [ -n "$status_err" ] && printf '%s\n' "$status_err" >&2
    exit 1
  fi
  # Every REPAIR: line gates finalize except status.sh's own pending-
  # migration line: that line exists to warn a reader who calls status.sh
  # directly, and is true by definition for as long as migration_target is
  # set — including the run that is about to clear it. Counting it here
  # would make finalize refuse every pending node unconditionally.
  repairs=$(printf '%s\n' "$status_out" | grep '^REPAIR:' | grep -v '^REPAIR: purpose\.md has migration_target ')
  if [ -n "$repairs" ]; then
    echo "node.sh: finalize refused — $agent has outstanding REPAIR findings; reconcile these, then re-run finalize:" >&2
    printf '%s\n' "$repairs" >&2
    exit 1
  fi

  # Stamp then clear, never the reverse: a crash between the two calls must
  # leave the node looking un-migrated (migration_target still present),
  # not falsely finished. A failed version write aborts before the marker
  # is touched at all; a failed marker removal still returns failure so the
  # node keeps reading as pending (detectable, retryable) rather than
  # silently finished with a stale marker.
  write_version "$purpose" "$migration_target" \
    || { echo "node.sh: failed to write version $migration_target to $purpose — aborting before removing the pending marker" >&2; exit 1; }
  remove_migration_target "$purpose" \
    || { echo "node.sh: version is now $migration_target but failed to remove the pending migration_target marker from $purpose — re-run finalize to retry" >&2; exit 1; }

  echo "node.sh: finalized $agent — version is now $migration_target"
  exit 0
  ;;

*)
  usage >&2
  exit 1
  ;;
esac
