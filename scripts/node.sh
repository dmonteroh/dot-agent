#!/usr/bin/env bash

set -u
unset CDPATH

TARGET_VERSION="6.3"
SOURCE_URL="https://github.com/dmonteroh/dot-agent"

selfdir=$(cd "$(dirname "$0")" && pwd)
srcroot=$(cd "$selfdir/.." && pwd)

SHIPPED_SCRIPTS=(status.sh log.sh memory.sh docs.sh links.sh comments.sh checkpoint.sh index.sh learn.sh runtime.sh verify.sh review.sh capture.sh)
SHIPPED_CONFIGS=(comments.conf status.conf log.conf checkpoint.conf verify.conf review.conf)

install_node_scripts() {
  local target script conf temp
  target="$1/scripts"
  mkdir -p "$target" || return 1
  for script in "${SHIPPED_SCRIPTS[@]}"; do
    temp="$target/.$script.update.$$"
    if ! cp "$srcroot/scripts/$script" "$temp" || ! chmod +x "$temp" || ! mv -f "$temp" "$target/$script"; then
      rm -f "$temp"
      echo "node.sh: could not refresh $script" >&2
      return 1
    fi
  done
  for conf in "${SHIPPED_CONFIGS[@]}" checks.sh; do
    [ ! -e "$target/$conf" ] || continue
    temp="$target/.$conf.update.$$"
    cp "$srcroot/scripts/$conf" "$temp" && mv -f "$temp" "$target/$conf" || {
      rm -f "$temp"; echo "node.sh: could not seed $conf" >&2; return 1;
    }
    [ "$conf" != checks.sh ] || chmod +x "$target/$conf"
  done
}

# The node owns only these paths under .agents/. Everything else there
# (skills/, other tools' files) belongs to the project, so no tracking mode
# ignores the directory as a whole.
NODE_SHARED_PATHS=(purpose.md rules/ docs/)
NODE_PERSONAL_PATHS=(memory.md memory/ session-log.md archive/ scripts/ indexes/ migration-inventory.md '.*' '*.tmp' '*.tmp.*')

node_gitignore_lines() {
  local mode="$1" indexes="$2" path
  case "$mode" in
  ignore-all)
    for path in "${NODE_SHARED_PATHS[@]}" "${NODE_PERSONAL_PATHS[@]}"; do printf '.agents/%s\n' "$path"; done ;;
  track-shared)
    for path in "${NODE_PERSONAL_PATHS[@]}"; do printf '.agents/%s\n' "$path"; done
    [ "$indexes" != generated ] || printf '.agents/rules/learned.md\n' ;;
  track-all)
    [ "$indexes" != generated ] || printf '.agents/indexes/\n.agents/rules/learned.md\n' ;;
  esac
}

# Appends each missing line of the mode's block; never removes a line.
write_node_gitignore() {
  local gitignore="$1/.gitignore" line missing=""
  while IFS= read -r line; do
    [ -e "$gitignore" ] && grep -qxF -- "$line" "$gitignore" && continue
    missing="$missing$line"$'\n'
  done < <(node_gitignore_lines "$2" "$3")
  [ -n "$missing" ] || return 0
  if [ -s "$gitignore" ] && [ -n "$(tail -c 1 "$gitignore")" ]; then echo >>"$gitignore"; fi
  printf '%s' "$missing" >>"$gitignore"
}

usage() {
  cat <<'EOF'
Usage:
  node.sh init --preset <software-development|academic-research|domain-knowledge> --mode <ignore-all|track-shared|track-all> [--indexes <manual|generated>] [root]
  node.sh update [--indexes <manual|generated>] [root]
  node.sh finalize [root]

init defaults --indexes to manual. update preserves the manifest value when
--indexes is omitted. root defaults to . — the script operates on <root>/.agents
EOF
}

cmd="${1:-}"
[ $# -ge 1 ] && shift
if [ "$cmd" = -h ] || [ "$cmd" = --help ]; then
  usage
  exit 0
fi

memory_index_header_stale() {
  mih_memory="$1"
  [ -f "$mih_memory" ] || return 1
  grep -qF 'This contract covers memory/ too' "$mih_memory" || return 0
  grep -qF 'If one already states it, update that source or its routing, write no fact, and say which source states it.' "$mih_memory" || return 0
  return 1
}

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

write_session_log_header() {
  cat >"$1" <<'EOF'
# Session log
<!-- One entry per turn that changed files, newest last. Format: - [YYYY-MM-DD] (tool) <task, area, outcome — ≤25 words>. verify: pass|fail|n/a. The summary text never contains `verify:`; log.sh stamps the tag from --verify and rejects a summary that carries one. Append the model to the tool tag when the harness states one — (claude/sonnet). Never guess it. The verify tag records the observed check outcome. Name pre-existing failures in the summary without changing a failed check into a pass. No file lists, SHAs, test counts, reviewer verdicts, or narrative. Preferred writer: .agents/scripts/log.sh, which stamps the date and enforces the ceiling. With log.conf's LOG_INCLUDE_BRANCH=true it also stamps `branch: <name>.` before verify, read from git. -->
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

write_memory_header() {
  cat >"$1" <<'EOF'
# Memory
<!-- Index only, one line per fact file, newest last. Reorder by relevance only when grooming. Format: - [Title](memory/slug.md) — hook. No prose, no facts inline: a fact that lives only as a line here and not as its own file under memory/ is not recorded. Delete the line when its file is deleted. Preferred writer: .agents/scripts/memory.sh new (scaffolds the fact file and its index line together). This contract covers memory/ too, so fact files carry no header of their own. Each holds one durable fact under date, scope, and type frontmatter. Keep a fact only if work in this node changes when it is true: one carried in from another repo or a migration earns its place again or is dropped. Before writing, search purpose, rules, routed docs, source, and existing facts. If one already states it, update that source or its routing, write no fact, and say which source states it. A defect fixed in the harness or a tool creates no compensating fact. Two halves that would be superseded at different times are two files. Supersede in place with .agents/scripts/memory.sh supersede --slug <slug> --fact "…", which rewrites the fact, restamps the date, and keeps the filename. No dated narratives, no command output, no history. As small as the fact allows. Stable knowledge about how the system works goes to docs/ without a pointer fact; architecture.md already routes it. type: reference points outward at a URL, dashboard, ticket, or spec the node does not own: checked for reachability, not superseded like a fact. -->
EOF
}

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

doc_headers_stale() {
  dh_docs="$1/docs"
  [ -d "$dh_docs" ] || return 1
  [ -n "$(find "$dh_docs" -name '*.md' -type f \
    -exec grep -lF '<!-- Agent-facing reference, not a human narrative' {} + 2>/dev/null)" ]
}

migrate_doc_headers() {
  dm_docs="$1/docs"
  dm_stripped=0
  migrate_doc_note="doc headers already current"
  [ -d "$dm_docs" ] || return 0
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

session_log_header_stale() {
  slh_log="$1"
  [ -f "$slh_log" ] || return 1
  grep -qF 'One entry per turn that changed files, newest last.' "$slh_log" || return 0
  grep -qF 'The verify tag records the observed check outcome.' "$slh_log" || return 0
  return 1
}

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

extract_learned_rules() {
  elr_agent="$1"
  elr_inventory="$2"
  elr_dir="$3"
  elr_learned="$elr_agent/rules/learned.md"
  [ -f "$elr_learned" ] || return 0
  elr_starts="$elr_agent/.learned-bullet-starts.tmp"
  grep -n '^- ' "$elr_learned" | cut -d: -f1 >"$elr_starts"
  if [ ! -s "$elr_starts" ]; then
    rm -f "$elr_starts"
    return 0
  fi
  elr_total=$(awk 'END { print NR }' "$elr_learned")
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

migrate_learned_and_docs() {
  mld_agent="$1"
  mld_dir="$mld_agent/rules/learned"
  for mld_existing in "$mld_dir"/*.md; do
    [ -e "$mld_existing" ] && return 0
  done

  mld_staging="$mld_agent/.learned-staging"
  rm -rf "$mld_staging"
  rm -f "$mld_agent"/.learned-*.tmp
  mkdir -p "$mld_staging" || return 1

  mld_learned="$mld_agent/rules/learned.md"
  mld_before="$mld_agent/.learned-bullets-before"
  if [ -f "$mld_learned" ] && [ ! -e "$mld_before" ]; then
    grep '^- ' "$mld_learned" >"$mld_before" 2>/dev/null || : >"$mld_before"
  fi

  mld_inventory_tmp="$mld_agent/.migration-inventory.tmp"
  : >"$mld_inventory_tmp"
  extract_learned_rules "$mld_agent" "$mld_inventory_tmp" "$mld_staging" \
    || { rm -rf "$mld_staging"; rm -f "$mld_inventory_tmp"; return 1; }
  backfill_doc_hooks "$mld_agent" "$mld_inventory_tmp"
  { printf '# Migration inventory\n\nOne line per original authoritative item: its new location, identity, and disposition.\n\n'
    cat "$mld_inventory_tmp"
  } >"$mld_agent/migration-inventory.md"
  rm -f "$mld_inventory_tmp"

  if [ -d "$mld_dir" ]; then
    rmdir "$mld_dir" 2>/dev/null || { rm -rf "$mld_staging"; return 1; }
  fi
  mv "$mld_staging" "$mld_dir" || return 1
  return 0
}

enable_generated_indexes() {
  egi_root="$1"
  egi_agent="$2"
  egi_mode="$3"

  migrate_learned_and_docs "$egi_agent" \
    || { echo "node.sh: learned-rule extraction or doc-hook backfill failed under $egi_agent — aborting" >&2; return 1; }

  egi_home=0
  if [ "$(cd "$egi_root" && pwd -P)" = "$(cd "${HOME:-/nonexistent}" 2>/dev/null && pwd -P)" ]; then
    egi_home=1
    echo "node.sh: skipped gitignore at \$HOME (a pattern there can apply to every repo) — if ~ is version-controlled, add the entries to that repo's gitignore by hand"
  fi

  # ignore-all may live in .git/info/exclude instead, so adoption writes no
  # .gitignore for it.
  if [ "$egi_home" -eq 0 ] && [ "$egi_mode" != ignore-all ]; then
    write_node_gitignore "$egi_root" "$egi_mode" generated
  fi

  "$egi_agent/scripts/index.sh" ensure --root "$egi_root" >/dev/null \
    || { echo "node.sh: index.sh ensure failed while regenerating rules/learned.md under $egi_agent — aborting before untracking" >&2; return 1; }

  egi_learned_md="$egi_agent/rules/learned.md"
  egi_bullets_before="$egi_agent/.learned-bullets-before"
  egi_source_bullets="$egi_bullets_before"
  [ -f "$egi_source_bullets" ] || egi_source_bullets="$egi_learned_md"
  egi_before_tmp="$egi_agent/.learned-bullets-before-check.tmp"
  egi_after_tmp="$egi_agent/.learned-bullets-after-check.tmp"
  grep '^- ' "$egi_source_bullets" 2>/dev/null | sort >"$egi_before_tmp"
  grep '^- ' "$egi_learned_md" 2>/dev/null | sort >"$egi_after_tmp"
  if diff -q "$egi_before_tmp" "$egi_after_tmp" >/dev/null 2>&1; then
    rm -f "$egi_before_tmp" "$egi_after_tmp"
  else
    rm -f "$egi_before_tmp" "$egi_after_tmp"
    echo "node.sh: regenerated $egi_learned_md does not reproduce every original bullet under $egi_agent — aborting before untracking" >&2
    return 1
  fi

  egi_untrack_skip=""
  if [ "$egi_home" -eq 1 ]; then
    egi_untrack_skip="\$HOME needs its generated-mode gitignore entries reconciled by hand"
  elif [ "$egi_mode" = ignore-all ]; then
    egi_untrack_skip="mode is ignore-all"
  elif ! git -C "$egi_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    egi_untrack_skip="$egi_root is not inside a git work tree"
  elif ! git -C "$egi_root" ls-files --error-unmatch -- .agents/rules/learned.md >/dev/null 2>&1; then
    egi_untrack_skip=".agents/rules/learned.md is not tracked"
  fi
  if [ -z "$egi_untrack_skip" ]; then
    git -C "$egi_root" rm --cached --quiet -- .agents/rules/learned.md \
      || { echo "node.sh: git rm --cached .agents/rules/learned.md failed under $egi_root — aborting" >&2; return 1; }
  else
    echo "node.sh: skipped untracking .agents/rules/learned.md ($egi_untrack_skip)"
  fi
  rm -f "$egi_bullets_before"
  return 0
}

# Rewrites every `.agent` path token in a file to `.agents`; prints the file
# when it changed.
rewrite_node_token() {
  [ -f "$1" ] && [ ! -L "$1" ] || return 0
  grep -q '\.agent\([^A-Za-z0-9_]\|$\)' "$1" || return 0
  perl -pi -e 's/\.agent(?![A-Za-z0-9_])/.agents/g' "$1" || return 1
  printf '%s\n' "$1"
}

move_node_entry() {
  if [ "$3" -eq 1 ] && [ -n "$(git -C "$1" ls-files -- ".agent/$2" 2>/dev/null)" ]; then
    git -C "$1" mv -- ".agent/$2" ".agents/$2" && return 0
  else
    mv -- "$1/.agent/$2" "$1/.agents/$2" && return 0
  fi
  echo "node.sh: moving .agent/$2 failed — re-run update to resume" >&2
  return 1
}

# Moves a node from <root>/.agent (before 6.3) to <root>/.agents. Resumable:
# purpose.md moves last, so an interrupted run still finds the old manifest.
relocate_legacy_node() {
  local root="$1" old="$1/.agent" new="$1/.agents" entry name clashes="" in_git=0
  local mode indexes version backup changed="" link target file
  [ -d "$old" ] && [ ! -L "$old" ] && [ -f "$old/purpose.md" ] || return 0
  if [ -L "$new" ] || { [ -e "$new" ] && [ ! -d "$new" ]; }; then
    echo "node.sh: $new exists and is not a plain directory — cannot move $old there" >&2
    return 1
  fi
  if [ -e "$new/purpose.md" ]; then
    echo "node.sh: both $old and $new hold a node manifest — reconcile them by hand, then re-run update" >&2
    return 1
  fi
  for entry in "$old"/* "$old"/.[!.]* "$old"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    name=${entry##*/}
    if [ -e "$new/$name" ] || [ -L "$new/$name" ]; then clashes="$clashes $name"; fi
  done
  if [ -n "$clashes" ]; then
    echo "node.sh: cannot move $old to $new — these names exist in both:$clashes. Move the copies in $new aside, then re-run update" >&2
    return 1
  fi

  mode=$(grep -m1 '^  mode:' "$old/purpose.md" | sed -E 's/^[[:space:]]*mode:[[:space:]]*([A-Za-z-]+).*/\1/')
  indexes=$(grep -m1 '^  indexes:' "$old/purpose.md" | sed -E 's/^[[:space:]]*indexes:[[:space:]]*([A-Za-z-]+).*/\1/')
  version=$(grep -m1 '^  version:' "$old/purpose.md" | sed -E 's/^[[:space:]]*version:[[:space:]]*"?([^"[:space:]]*)"?.*/\1/')
  if [ "$mode" != track-all ]; then
    backup="$root/.agent.backup-v$version-relocate"
    if [ ! -e "$backup" ]; then
      cp -R "$old" "$backup" || { echo "node.sh: backup to $backup failed — aborting before moving the node" >&2; return 1; }
      echo "node.sh: backed up node to $backup"
    fi
  fi

  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 && in_git=1
  mkdir -p "$new" || { echo "node.sh: could not create $new" >&2; return 1; }
  for entry in "$old"/* "$old"/.[!.]* "$old"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    name=${entry##*/}
    [ "$name" = purpose.md ] || move_node_entry "$root" "$name" "$in_git" || return 1
  done
  move_node_entry "$root" purpose.md "$in_git" || return 1
  rmdir "$old" 2>/dev/null || echo "node.sh: $old is not empty after the move — inspect what is left there" >&2
  echo "node.sh: moved the node from $old to $new"

  # Node text names its own paths. The session log and archive/ are history.
  while IFS= read -r file; do
    changed="$changed$(rewrite_node_token "$file")"$'\n'
  done < <(find "$new" \( -path "$new/archive" -o -path "$new/skills" -o -path "$new/indexes" -o -path "$new/.state" \) -prune -o \
    -type f \( -name '*.md' -o -name '*.conf' -o -name 'checks.sh' \) ! -path "$new/session-log.md" -print)
  for file in CLAUDE.md AGENTS.md GEMINI.md .github/copilot-instructions.md .claude/CLAUDE.md .codex/AGENTS.md \
    .claude/settings.json .claude/settings.local.json .git/info/exclude; do
    changed="$changed$(rewrite_node_token "$root/$file")"$'\n'
  done
  changed=$(printf '%s' "$changed" | sed '/^$/d')
  [ -z "$changed" ] || printf 'node.sh: rewrote .agent paths to .agents in:\n%s\n' "$changed"

  link="$root/.claude/skills"
  if [ -L "$link" ]; then
    target=$(readlink "$link")
    case "$target" in
    *.agent/skills | *.agent/skills/)
      ln -sfn "${target%.agent/skills*}.agents/skills" "$link" && echo "node.sh: repointed $link to ${target%.agent/skills*}.agents/skills" ;;
    esac
  fi
  link="$root/.codex/skills"
  if [ -L "$link" ]; then
    case "$(readlink "$link")" in
    *.agent/skills | *.agent/skills/)
      rm -f "$link" && echo "node.sh: removed $link — Codex reads .agents/skills natively" ;;
    esac
  fi

  if [ "$(cd "$root" && pwd -P)" != "$(cd "${HOME:-/nonexistent}" 2>/dev/null && pwd -P)" ] && [ -f "$root/.gitignore" ]; then
    grep -vxF -e '.agent/' -e '.agent/*' -e '!.agent/purpose.md' -e '!.agent/rules/' -e '!.agent/docs/' \
      -e '.agent/indexes/' -e '.agent/rules/learned.md' "$root/.gitignore" >"$root/.gitignore.node-tmp"
    if ! cmp -s "$root/.gitignore" "$root/.gitignore.node-tmp"; then
      cat "$root/.gitignore.node-tmp" >"$root/.gitignore"
      echo "node.sh: removed the pre-6.3 node entries from $root/.gitignore"
      write_node_gitignore "$root" "$mode" "${indexes:-manual}"
    fi
    rm -f "$root/.gitignore.node-tmp"
  fi
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

  agent="$root/.agents"
  # .agents/ may already exist for other tools (skills/ from an installer, say).
  # A node exists only when its manifest does; init never touches foreign content.
  if [ -L "$agent" ] || { [ -e "$agent" ] && [ ! -d "$agent" ]; }; then
    echo "node.sh: $agent exists and is not a plain directory — refusing" >&2
    exit 1
  fi
  if [ -f "$root/.agent/purpose.md" ]; then
    echo "node.sh: a node from before 6.3 lives at $root/.agent — run node.sh update to move it to .agents/ instead of init" >&2
    exit 1
  fi
  if [ -e "$agent/purpose.md" ]; then
    echo "node.sh: $agent/purpose.md already exists — refusing to overwrite a live node" >&2
    exit 1
  fi
  for owned in rules memory docs archive scripts indexes memory.md session-log.md; do
    if [ -e "$agent/$owned" ]; then
      echo "node.sh: $agent/$owned already exists but no node manifest does — init never overwrites it; move it aside first" >&2
      exit 1
    fi
  done

  mkdir -p "$agent/rules" "$agent/memory" "$agent/docs" "$agent/archive" "$agent/scripts" \
    || { echo "node.sh: could not create the node skeleton under $agent" >&2; exit 1; }

  write_session_log_header "$agent/session-log.md"

  write_memory_header "$agent/memory.md"

  cat >"$agent/rules/learned.md" <<'EOF'
# Learned rules

Binding rules distilled from operator corrections and failed verifications on this project, after the canonical-source check in `contract.md`. A correction that exposes a defect in the contract, docs, code, or tooling is fixed there and produces no compensating rule. Merging and compressing entries is allowed. Drop a rule when its failure mode becomes mechanically enforced. Behavioral rules stay here. Area gotchas go to the matching `.agents/docs/` file under `## Gotchas`. Authoring and curation rules: `contract.md`, Self-learning.

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
  children: []              # repo-relative paths to child .agents/ nodes
---

# Purpose

<!-- Filled by the agent during bootstrap: why this project exists, who it's for, key constraints, and where to change what. -->
EOF

  cp "$srcroot/presets/$preset.md" "$agent/rules/contract.md" \
    || { echo "node.sh: preset copy into rules/contract.md failed" >&2; exit 1; }

  install_node_scripts "$agent" || exit 1

  if [ "$(cd "$root" && pwd -P)" = "$(cd "${HOME:-/nonexistent}" 2>/dev/null && pwd -P)" ]; then
    { [ "$mode" = "track-all" ] && [ "$indexes" != generated ]; } \
      || echo "node.sh: skipped gitignore at \$HOME (a pattern there can apply to every repo) — if ~ is version-controlled, add the entries to that repo's gitignore by hand"
  else
    write_node_gitignore "$root" "$mode" "$indexes"
  fi

  echo "node.sh: initialized $agent (preset=$preset, mode=$mode, indexes=$indexes)"
  echo 'node.sh: configure scripts/checks.sh and verify.conf for project checks; existing drivers and configuration survive updates'
  exit 0
  ;;

update)
  requested_indexes=""
  root="."
  root_seen=0
  while [ $# -gt 0 ]; do
    case "$1" in
    --indexes)
      [ $# -ge 2 ] || { echo "node.sh: --indexes needs a value" >&2; usage >&2; exit 1; }
      requested_indexes="$2"; shift 2 ;;
    -h | --help)
      usage; exit 0 ;;
    --*)
      echo "node.sh: unknown flag: $1" >&2; usage >&2; exit 1 ;;
    *)
      [ "$root_seen" -eq 0 ] || { echo "node.sh: update accepts one root" >&2; usage >&2; exit 1; }
      root="$1"; root_seen=1; shift ;;
    esac
  done
  case "$requested_indexes" in
  "" | manual | generated) ;;
  *)
    echo "node.sh: unknown --indexes: '$requested_indexes' (must be manual or generated)" >&2
    usage >&2
    exit 1 ;;
  esac
  relocate_legacy_node "$root" || exit 1
  agent="$root/.agents"
  purpose="$agent/purpose.md"

  if [ ! -d "$agent" ]; then
    echo "node.sh: no .agents directory at $agent — run from the node's project root, or pass that root as an argument" >&2
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

  if [ "$indexes" = generated ] && [ "$requested_indexes" = manual ]; then
    echo "node.sh: refusing generated-to-manual conversion during update — follow scripts/docs/node.md#reverting-to-manual-mode" >&2
    exit 1
  fi
  desired_indexes="${requested_indexes:-$indexes}"

  version_order=$(awk -v old="$oldversion" -v target="$TARGET_VERSION" 'BEGIN {
    a=split(old,x,"."); b=split(target,y,"."); n=(a>b?a:b)
    for(i=1;i<=n;i++) {
      if((x[i]+0)<(y[i]+0)) {print -1; exit}
      if((x[i]+0)>(y[i]+0)) {print 1; exit}
    }
    print 0
  }') || { echo 'node.sh: version comparison failed' >&2; exit 1; }
  case "$version_order" in
  -1|0|1) ;;
  *) echo 'node.sh: version comparison returned an invalid result' >&2; exit 1 ;;
  esac
  if [ "$version_order" -gt 0 ]; then
    echo "node.sh: node is current (version $oldversion)"
    exit 0
  fi

  if [ "$version_order" -lt 0 ] && [ "$migration_target" != "$TARGET_VERSION" ]; then
    for new_helper in runtime.sh verify.sh review.sh capture.sh; do
      existing="$agent/scripts/$new_helper"
      if [ -L "$existing" ] || { [ -e "$existing" ] && ! cmp -s "$existing" "$srcroot/scripts/$new_helper"; }; then
        echo "node.sh: $existing occupies a new managed helper name; preserve and relocate the custom helper before updating" >&2
        exit 1
      fi
    done
  fi

  if [ "$version_order" -eq 0 ]; then
    shape_stale=0
    if memory_headers_stale "$agent" || doc_headers_stale "$agent" || session_log_header_stale "$agent/session-log.md"; then
      shape_stale=1
    fi

    adoption_backup=""
    shape_backup=""
    if [ "$mode" != "track-all" ]; then
      if [ "$desired_indexes" = generated ] && [ "$indexes" != generated ]; then
        adoption_backup="$root/.agents.backup-v$oldversion-indexes-generated"
      fi
      if [ "$shape_stale" -eq 1 ]; then
        shape_backup="$root/.agents.backup-v$oldversion-shape"
      fi
      for candidate_backup in "$adoption_backup" "$shape_backup"; do
        [ -n "$candidate_backup" ] || continue
        if [ -e "$candidate_backup" ]; then
          echo "node.sh: backup path already exists: $candidate_backup — refusing to proceed" >&2
          exit 1
        fi
      done
    fi

    if [ "$desired_indexes" = generated ] && [ "$indexes" != generated ]; then
      if [ "$mode" != "track-all" ]; then
        cp -R "$agent" "$adoption_backup" \
          || { echo "node.sh: backup to $adoption_backup failed — aborting before touching the node" >&2; exit 1; }
        echo "node.sh: backed up node to $adoption_backup"
      fi
    fi

    if [ "$shape_stale" -eq 1 ] && [ "$mode" != track-all ]; then
      cp -R "$agent" "$shape_backup" || { echo "node.sh: shape backup failed" >&2; exit 1; }
      echo "node.sh: backed up node to $shape_backup"
    fi

    if [ -z "$indexes_line" ] || [ "$desired_indexes" != "$indexes" ]; then
      write_indexes "$purpose" "$desired_indexes" \
        || { echo "node.sh: failed to record indexes in $purpose — aborting before touching node content" >&2; exit 1; }
      if [ -z "$indexes_line" ] && [ "$desired_indexes" = manual ]; then
        echo "node.sh: indexes: manual backfilled into $purpose"
      else
        echo "node.sh: indexes: $desired_indexes recorded in $purpose"
      fi
      indexes="$desired_indexes"
    fi

    install_node_scripts "$agent" || exit 1

    if [ "$requested_indexes" = generated ]; then
      enable_generated_indexes "$root" "$agent" "$mode" || exit 1
      echo "node.sh: generated indexes adopted for $agent"
    fi

    if [ "$shape_stale" -eq 1 ]; then
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

  if [ "$mode" != "track-all" ]; then
    backup="$root/.agents.backup-v$oldversion"
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

  write_migration_target "$purpose" "$TARGET_VERSION" \
    || { echo "node.sh: failed to record migration_target in $purpose — aborting before touching node content" >&2; exit 1; }

  if [ -z "$indexes_line" ] || [ "$desired_indexes" != "$indexes" ]; then
    write_indexes "$purpose" "$desired_indexes" \
      || { echo "node.sh: failed to record indexes in $purpose — aborting before touching node content" >&2; exit 1; }
    if [ -z "$indexes_line" ] && [ "$desired_indexes" = manual ]; then
      echo "node.sh: indexes: manual backfilled into $purpose"
    else
      echo "node.sh: indexes: $desired_indexes recorded in $purpose"
    fi
    indexes="$desired_indexes"
  fi

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

  install_node_scripts "$agent" || exit 1

  if [ "$indexes" = generated ]; then
    enable_generated_indexes "$root" "$agent" "$mode" || exit 1
  fi

  echo "node.sh: migrated $agent from version $oldversion toward $TARGET_VERSION (migration_target set; version unchanged)"
  echo "node.sh: $split_note"
  echo "node.sh: $header_note"
  echo "node.sh: runtime scripts refreshed atomically: ${SHIPPED_SCRIPTS[*]}"
  echo 'node.sh: check driver and existing configuration preserved'
  echo 'node.sh: configure checks.sh and verify.conf, reconcile entry-point checkpoint flags, and retain customized contract rules'
  echo "node.sh: remaining for the agent — split memory/legacy.md into fact files (status.sh flags it with GROOM), reconcile rules/contract.md and docs/ against the current presets and operating model, then run finalize to stamp version $TARGET_VERSION"
  exit 0
  ;;

finalize)
  root="${1:-.}"
  agent="$root/.agents"
  purpose="$agent/purpose.md"

  if [ -f "$root/.agent/purpose.md" ]; then
    echo "node.sh: the node still lives at $root/.agent — run node.sh update first; it moves the node to .agents/" >&2
    exit 1
  fi
  if [ ! -d "$agent" ]; then
    echo "node.sh: no .agents directory at $agent — run from the node's project root, or pass that root as an argument" >&2
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

  statussh="$agent/scripts/status.sh"
  if [ ! -x "$statussh" ]; then
    echo "node.sh: $statussh missing or not executable — cannot verify the node before finalize (refusing)" >&2
    exit 1
  fi

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
  repairs=$(printf '%s\n' "$status_out" | grep '^REPAIR:' | grep -v '^REPAIR: purpose\.md has migration_target ')
  if [ -n "$repairs" ]; then
    echo "node.sh: finalize refused — $agent has outstanding REPAIR findings; reconcile these, then re-run finalize:" >&2
    printf '%s\n' "$repairs" >&2
    exit 1
  fi

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
