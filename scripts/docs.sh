#!/usr/bin/env bash

set -u
export LC_ALL=C
unset CDPATH

usage() {
  cat <<'EOF'
Usage: docs.sh new --name <file> --read-when "…" [root]
       docs.sh rehook --name <file> --read-when "…" [root]
       docs.sh sync --name <file> [--read-when "…"] [root]
       docs.sh catalog --catalog <file> --name <symbol> --path <project-path> --when "…" [root]

root defaults to . — new writes <root>/.agent/docs/<file> and a routing row
in <root>/.agent/docs/architecture.md; rehook rewrites an existing doc's
"Read when:" header and its routing row to the new text, both or neither.
EOF
}

need_value() {
  case "${2-}" in
  --name|--read-when|--catalog|--path|--when)
    echo "docs.sh: $1 needs a value, got the flag $2" >&2
    usage >&2
    exit 1 ;;
  esac
  if [ $# -lt 2 ]; then
    echo "docs.sh: $1 needs a value" >&2
    usage >&2
    exit 1
  fi
}

validate_cell() {
  vc_flag="$1"
  vc_value="$2"
  vc_nl='
'
  vc_tab=$(printf '\t')
  case "$vc_value" in
  ""|*"$vc_nl"*|*"$vc_tab"*|*'|'*|*'\'*)
    echo "docs.sh: $vc_flag must be nonempty and contain no newline, tab, |, or backslash" >&2
    exit 1 ;;
  esac
  if printf '%s' "$vc_value" | grep -q '[[:cntrl:]]'; then
    echo "docs.sh: $vc_flag must contain no control characters" >&2
    exit 1
  fi
}

doc_filename() {
  df_nl='
'
  case "$1" in *.md) df_name="$1" ;; *) df_name="$1.md" ;; esac
  case "$df_name" in
  /*|.|..|../*|*/../*|*/..|*/.|*'/./'*|./*|*'`'*|*'|'*|*'\'*|*"$df_nl"*) return 1 ;;
  esac
  printf '%s' "$df_name" | grep -q '[[:cntrl:]]' && return 1
  printf '%s\n' "$df_name"
}

derive_sections() {
  awk '
    function run(s,ch, i) { for(i=1;i<=length(s) && substr(s,i,1)==ch;i++); return i-1 }
    {
      line=$0; sub(/^[[:space:]]*/,"",line)
      ch=substr(line,1,1); count=run(line,ch)
      if(!fence && (ch=="`" || ch=="~") && count>=3) { fence=ch; width=count; next }
      if(fence) {
        if(ch==fence && count>=width) { rest=substr(line,count+1); if(rest ~ /^[[:space:]]*$/) { fence=""; width=0 } }
        next
      }
    }
    /^## [^#]/ {
      h=substr($0,4); sub(/[[:space:]]+#+[[:space:]]*$/, "", h)
      if(out!="") out=out " · "; out=out h
    }
    END { print out }
  ' "$1"
}

write_arch_header() {
  cat <<'EOF'
# Architecture routing table
<!-- Entries route the canonical docs in this directory. -->
EOF
}

cmd="${1:-}"
[ $# -ge 1 ] && shift

case "$cmd" in
-h|--help)
  usage
  exit 0 ;;
new)
  name=""
  readwhen=""
  root="."
  while [ $# -gt 0 ]; do
    case "$1" in
    --name)
      need_value "$@"
      name="$2"; shift 2 ;;
    --read-when)
      need_value "$@"
      readwhen="$2"; shift 2 ;;
    -h | --help)
      usage; exit 0 ;;
    --*)
      echo "docs.sh: unknown flag: $1" >&2; usage >&2; exit 1 ;;
    *)
      root="$1"; shift ;;
    esac
  done

  if [ -z "$name" ] || [ -z "$readwhen" ]; then
    echo "docs.sh: --name and --read-when are both required" >&2
    usage >&2
    exit 1
  fi

  nl='
'
  case "$readwhen" in
  *"$nl"*)
    echo "docs.sh: --read-when must be single-line" >&2
    exit 1 ;;
  *"|"*)
    echo "docs.sh: --read-when must not contain | — it becomes a routing-table cell" >&2
    exit 1 ;;
  *"-->"*)
    echo "docs.sh: --read-when must not contain --> — it would close the \"Read when:\" header comment early" >&2
    exit 1 ;;
  esac

  case "$name" in
  *.md) base="${name%.md}" ;;
  *) base="$name" ;;
  esac
  filename="$base.md"

  case "$base" in
  */*/*)
    echo "docs.sh: --name may nest at most one folder deep (got '$name')" >&2
    exit 1 ;;
  */*)
    subdir="${base%%/*}"
    leaf="${base##*/}"
    if [ -z "$subdir" ]; then
      echo "docs.sh: --name parts must match [a-z0-9-]+ (got '$name')" >&2
      exit 1
    fi ;;
  *)
    subdir=""
    leaf="$base" ;;
  esac
  case "$subdir" in
  -*)
    echo "docs.sh: --name parts must not start with - (got '$name') — the filename would read as a flag" >&2
    exit 1 ;;
  esac
  case "$leaf" in
  -*)
    echo "docs.sh: --name parts must not start with - (got '$name') — the filename would read as a flag" >&2
    exit 1 ;;
  esac
  case "$subdir" in
  *[!abcdefghijklmnopqrstuvwxyz0123456789-]*)
    echo "docs.sh: --name parts must match [a-z0-9-]+ (got '$name')" >&2
    exit 1 ;;
  esac
  case "$leaf" in
  *[!abcdefghijklmnopqrstuvwxyz0123456789-]* | "")
    echo "docs.sh: --name parts must match [a-z0-9-]+ (got '$name')" >&2
    exit 1 ;;
  esac

  if [ "$leaf" = "architecture" ]; then
    echo "docs.sh: 'architecture' is the routing table itself, not a scaffoldable doc" >&2
    exit 1
  fi

  agent="$root/.agent"
  docs="$agent/docs"
  doc="$docs/$filename"
  arch="$docs/architecture.md"

  if [ ! -d "$agent" ]; then
    echo "docs.sh: $agent does not exist — refusing to write outside an initialized node" >&2
    exit 1
  fi
  if [ -e "$doc" ]; then
    echo "docs.sh: $doc already exists — refusing to overwrite" >&2
    exit 1
  fi
  if [ -e "$arch" ] && [ ! -w "$arch" ]; then
    echo "docs.sh: $arch is not writable — refusing to publish an unrouted document" >&2
    exit 1
  fi

  mkdir -p "$(dirname "$doc")"

  title=$(printf '%s' "$leaf" | tr '-' ' ' | awk '{for(i=1;i<=NF;i++){$i=toupper(substr($i,1,1)) substr($i,2)} print}')

  new_doc_tmp="$doc.new.tmp.$$"
  new_arch_tmp="$arch.new.tmp.$$"
  if cat >"$new_doc_tmp" <<EOF
<!-- Read when: $readwhen -->
# $title
EOF
  then :
  else
    echo "docs.sh: could not stage $doc — nothing was written" >&2
    rm -f "$new_doc_tmp"
    exit 1
  fi

  if [ -s "$arch" ]; then
    cat "$arch" >"$new_arch_tmp" || { rm -f "$new_doc_tmp" "$new_arch_tmp"; exit 1; }
  else
    cat >"$new_arch_tmp" <<'EOF'
# Architecture routing table
<!-- One entry per doc in this directory, in this format:

### `<file>`
- **Read when:** <hook — the same text as the doc's own "Read when:" header>
- **Sections:** <the doc's `## ` headings, separated by " · ">

Read when: is precision — skip the doc when the hook doesn't match. Sections: is recall — find the doc that holds a topic its hook never names. Refresh both when the doc changes: status.sh flags a hook that disagrees with the doc's own header, and a `## ` heading missing from Sections. A section entry may say more than its heading. It may not say less. A doc whose hook is unconditional ("ANY <area> work — check here before creating a new …") is a catalog. It loads for every task in its area, even when no hook matches.

The docs in this table are the node's design of record: a design fact, number, or open question lives in one of them, and a design change lands there. Material under `archive/` is superseded — never an entry here, never routed, and never cited as intent by a routed or always-loaded file. -->
EOF
  fi

  if {
    printf -- '\n### `%s`\n' "$filename"
    printf -- '- **Read when:** %s\n' "$readwhen"
    printf -- '- **Sections:**\n'
  } >>"$new_arch_tmp" && mv "$new_doc_tmp" "$doc" && mv "$new_arch_tmp" "$arch"; then
    echo "docs.sh: wrote $doc and added its routing entry to $arch"
    echo "docs.sh: agent-facing reference — facts as tables or one-fact-per-line bullets, prose only for the *why*, timeless, area traps under ## Gotchas. Restructuring changes shape, never content: no tightening or split may drop a name, value, command, path, or gotcha. Full contract: the preset's docs/ bullet."
    exit 0
  fi

  echo "docs.sh: could not publish the document and routing entry — removed $doc" >&2
  rm -f "$doc"
  rm -f "$new_doc_tmp" "$new_arch_tmp"
  exit 1
  ;;

sync)
  name=""
  readwhen=""
  readwhen_supplied=0
  root="."
  while [ $# -gt 0 ]; do
    case "$1" in
    --name) need_value "$@"; name="$2"; shift 2 ;;
    --read-when) need_value "$@"; readwhen="$2"; readwhen_supplied=1; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --*) echo "docs.sh: unknown flag: $1" >&2; usage >&2; exit 1 ;;
    *) root="$1"; shift ;;
    esac
  done
  [ -n "$name" ] || { echo "docs.sh: sync requires --name <file>" >&2; exit 1; }
  filename=$(doc_filename "$name") || { echo "docs.sh: --name must be a safe path under .agent/docs/ (got '$name')" >&2; exit 1; }
  [ "$readwhen_supplied" -eq 0 ] || validate_cell --read-when "$readwhen"
  docs="$root/.agent/docs"
  doc="$docs/$filename"
  arch="$docs/architecture.md"
  [ -f "$doc" ] && [ ! -L "$doc" ] || { echo "docs.sh: $doc is not a regular document" >&2; exit 1; }
  if [ -L "$arch" ]; then
    echo "docs.sh: $arch is a symlink; sync refuses an ambiguous routing table" >&2
    exit 1
  fi
  if [ -e "$arch" ] && [ ! -f "$arch" ]; then
    echo "docs.sh: $arch is not a regular routing table" >&2
    exit 1
  fi
  sync_root_phys=$(cd "$root" 2>/dev/null && pwd -P) || exit 1
  sync_parent_phys=$(cd "$(dirname "$doc")" 2>/dev/null && pwd -P) || exit 1
  case "$sync_parent_phys" in "$sync_root_phys"|"$sync_root_phys"/*) ;; *) echo "docs.sh: --name resolves outside the project" >&2; exit 1 ;; esac

  hook_count=$(head -n 5 "$doc" | grep -c '^<!-- Read when: .* -->$')
  [ "$hook_count" -le 1 ] || { echo "docs.sh: $doc has ambiguous Read when headers" >&2; exit 1; }
  existing_hook=""
  [ "$hook_count" -eq 0 ] || existing_hook=$(head -n 5 "$doc" | sed -n 's/^<!-- Read when: \(.*\) -->$/\1/p')
  if [ -z "$readwhen" ]; then
    [ "$hook_count" -eq 1 ] || { echo "docs.sh: $doc has no hook; supply --read-when" >&2; exit 1; }
    readwhen=$(head -n 5 "$doc" | sed -n 's/^<!-- Read when: \(.*\) -->$/\1/p')
  fi

  doc_tmp="$doc.sync.tmp.$$"
  if [ "$hook_count" -eq 1 ] && { [ "$readwhen_supplied" -eq 0 ] || [ "$readwhen" = "$existing_hook" ]; }; then
    cp "$doc" "$doc_tmp" || exit 1
  elif [ "$hook_count" -eq 1 ]; then
    HOOK="$readwhen" awk 'NR<=5 && !done && /^<!-- Read when: .* -->$/ { print "<!-- Read when: " ENVIRON["HOOK"] " -->"; done=1; next } {print}' "$doc" >"$doc_tmp" || exit 1
  else
    { printf '<!-- Read when: %s -->\n' "$readwhen"; cat "$doc"; } >"$doc_tmp" || exit 1
  fi
  sections=$(derive_sections "$doc_tmp") || { rm -f "$doc_tmp"; exit 1; }

  arch_tmp="$arch.sync.tmp.$$"
  if [ -f "$arch" ]; then
    entry_count=$(grep -Fxc "### \`$filename\`" "$arch")
  else
    entry_count=0
  fi
  [ "$entry_count" -le 1 ] || { rm -f "$doc_tmp"; echo "docs.sh: $arch has more than one entry for $filename" >&2; exit 1; }
  if [ "$entry_count" -eq 1 ]; then
    row_counts=$(FILE="$filename" awk '
      $0=="### `" ENVIRON["FILE"] "`" {inb=1; next}
      inb && /^### `/ {inb=0}
      inb && /^- \*\*Read when:\*\*/ {r++}
      inb && /^- \*\*Sections:\*\*/ {s++}
      END {print r+0, s+0}
    ' "$arch")
    set -- $row_counts
    [ "$1" -le 1 ] && [ "$2" -le 1 ] || { rm -f "$doc_tmp"; echo "docs.sh: $arch has ambiguous metadata rows for $filename" >&2; exit 1; }
    FILE="$filename" HOOK="$readwhen" SECTIONS="$sections" awk '
      function missing() {
        if(!rw) print "- **Read when:** " ENVIRON["HOOK"]
        if(!ss) print "- **Sections:** " ENVIRON["SECTIONS"]
      }
      $0=="### `" ENVIRON["FILE"] "`" { if(inb) missing(); inb=1; rw=ss=0; print; next }
      inb && /^### `/ { missing(); inb=0 }
      inb && /^- \*\*Read when:\*\*/ { if(!rw) print "- **Read when:** " ENVIRON["HOOK"]; rw=1; next }
      inb && /^- \*\*Sections:\*\*/ { if(!ss) print "- **Sections:** " ENVIRON["SECTIONS"]; ss=1; next }
      {print}
      END {if(inb) missing()}
    ' "$arch" >"$arch_tmp" || { rm -f "$doc_tmp" "$arch_tmp"; exit 1; }
  else
    if [ -f "$arch" ]; then cat "$arch" >"$arch_tmp"; else write_arch_header >"$arch_tmp"; fi
    { printf '\n### `%s`\n' "$filename"; printf '%s\n' "- **Read when:** $readwhen" "- **Sections:** $sections"; } >>"$arch_tmp"
  fi

  doc_backup="$doc.sync.backup.$$"
  cp "$doc" "$doc_backup" || { rm -f "$doc_tmp" "$arch_tmp"; exit 1; }
  if mv "$doc_tmp" "$doc" && mv "$arch_tmp" "$arch"; then
    rm -f "$doc_backup"
    printf 'synced\t.agent/docs/%s\t%s\n' "$filename" "$(git hash-object --no-filters -- "$doc")"
    exit 0
  fi
  mv "$doc_backup" "$doc" 2>/dev/null || :
  rm -f "$doc_tmp" "$arch_tmp"
  echo "docs.sh: sync could not publish both files; the document was restored" >&2
  exit 1
  ;;

catalog)
  catalog=""
  name=""
  project_path=""
  when=""
  root="."
  while [ $# -gt 0 ]; do
    case "$1" in
    --catalog) need_value "$@"; catalog="$2"; shift 2 ;;
    --name) need_value "$@"; name="$2"; shift 2 ;;
    --path) need_value "$@"; project_path="$2"; shift 2 ;;
    --when) need_value "$@"; when="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --*) echo "docs.sh: unknown flag: $1" >&2; usage >&2; exit 1 ;;
    *) root="$1"; shift ;;
    esac
  done
  [ -n "$catalog" ] && [ -n "$name" ] && [ -n "$project_path" ] && [ -n "$when" ] || { echo "docs.sh: catalog requires --catalog, --name, --path, and --when" >&2; exit 1; }
  validate_cell --name "$name"
  validate_cell --path "$project_path"
  validate_cell --when "$when"
  case "$name" in *'`'*) echo "docs.sh: --name contains unsafe Markdown-table characters" >&2; exit 1 ;; esac
  case "$project_path" in /*|.|..|../*|*/../*|*/..|*/.|*'/./'*|./*|*'`'*) echo "docs.sh: --path must be a safe project-relative path" >&2; exit 1 ;; esac
  catfile=$(doc_filename "$catalog") || { echo "docs.sh: --catalog must name a file under .agent/docs/" >&2; exit 1; }
  catdoc="$root/.agent/docs/$catfile"
  [ -f "$catdoc" ] && [ ! -L "$catdoc" ] || { echo "docs.sh: $catdoc is not a regular catalog" >&2; exit 1; }
  root_phys=$(cd "$root" 2>/dev/null && pwd -P) || exit 1
  catalog_parent_phys=$(cd "$(dirname "$catdoc")" 2>/dev/null && pwd -P) || exit 1
  case "$catalog_parent_phys" in "$root_phys"|"$root_phys"/*) ;; *) echo "docs.sh: --catalog resolves outside the project" >&2; exit 1 ;; esac
  [ -e "$root/$project_path" ] || { echo "docs.sh: --path $project_path does not exist in the project" >&2; exit 1; }
  check_path="$root"
  old_ifs=$IFS
  IFS=/
  for path_part in $project_path; do
    check_path="$check_path/$path_part"
    if [ -L "$check_path" ]; then
      IFS=$old_ifs
      echo "docs.sh: --path must not traverse a symlink" >&2
      exit 1
    fi
  done
  IFS=$old_ifs
  if [ -d "$root/$project_path" ]; then path_phys=$(cd "$root/$project_path" 2>/dev/null && pwd -P) || exit 1
  else path_dir=$(dirname "$root/$project_path"); path_phys=$(cd "$path_dir" 2>/dev/null && pwd -P)/$(basename "$project_path") || exit 1
  fi
  case "$path_phys" in "$root_phys"|"$root_phys"/*) ;; *) echo "docs.sh: --path resolves outside the project" >&2; exit 1 ;; esac

  table_lines=$(awk '
    function trim(s){gsub(/^[[:space:]]+|[[:space:]]+$/,"",s); return s}
    function compatible(s, n,c){n=split(s,c,"|"); return n>=4 && tolower(trim(c[2])) ~ /^(block|symbol|name)$/ && tolower(trim(c[3]))=="path" && tolower(trim(c[4])) ~ /when/}
    function separator(s, n,c){n=split(s,c,"|"); return n>=4 && trim(c[2]) ~ /^:?-+:?$/ && trim(c[3]) ~ /^:?-+:?$/ && trim(c[4]) ~ /^:?-+:?$/}
    { if(previous && separator($0)) print NR-1; previous=compatible($0) }
  ' "$catdoc")
  table_count=$(printf '%s\n' "$table_lines" | awk 'NF{n++} END{print n+0}')
  [ "$table_count" -eq 1 ] || { echo "docs.sh: $catdoc must contain exactly one unambiguous Symbol/Path/When catalog table" >&2; exit 1; }
  table_start=$(printf '%s\n' "$table_lines" | awk 'NF{print; exit}')
  if ! START="$table_start" awk '
    function key(line, c,k){split(line,c,"|"); k=c[2]; gsub(/^[[:space:]`]+|[[:space:]`]+$/,"",k); return k}
    NR<ENVIRON["START"]+2 {next}
    /^\|/ {
      copy=$0; pipes=gsub(/\|/,"|",copy); if(pipes!=4) exit 3
      k=key($0); if(k in seen) exit 4; seen[k]=1; next
    }
    {exit 0}
  ' "$catdoc"; then
    echo "docs.sh: $catdoc has duplicate keys or an unsafe table row" >&2
    exit 1
  fi
  cat_tmp="$catdoc.catalog.tmp.$$"
  NAME="$name" PTH="$project_path" WHEN="$when" START="$table_start" awk '
    function key(line, c,n,k){n=split(line,c,"|"); k=c[2]; gsub(/^[[:space:]`]+|[[:space:]`]+$/,"",k); return k}
    NR==ENVIRON["START"] {intable=1; print; next}
    intable && /^\|/ {
      if(NR==ENVIRON["START"]+1) {print; next}
      if(key($0)==ENVIRON["NAME"]) {hits++; if(hits==1) print "| `" ENVIRON["NAME"] "` | `" ENVIRON["PTH"] "` | " ENVIRON["WHEN"] " |"; next}
      print; next
    }
    intable {if(!hits) print "| `" ENVIRON["NAME"] "` | `" ENVIRON["PTH"] "` | " ENVIRON["WHEN"] " |"; intable=0}
    {print}
    END {if(intable && !hits) print "| `" ENVIRON["NAME"] "` | `" ENVIRON["PTH"] "` | " ENVIRON["WHEN"] " |"; if(hits>1) exit 4}
  ' "$catdoc" >"$cat_tmp"
  cat_status=$?
  if [ "$cat_status" -eq 4 ]; then rm -f "$cat_tmp"; echo "docs.sh: duplicate catalog key: $name" >&2; exit 1; fi
  [ "$cat_status" -eq 0 ] || { rm -f "$cat_tmp"; exit 1; }
  mv "$cat_tmp" "$catdoc" || { rm -f "$cat_tmp"; exit 1; }
  printf 'cataloged\t%s\t%s\n' "$name" "$(git hash-object --no-filters -- "$catdoc")"
  exit 0
  ;;

rehook)
  name=""
  readwhen=""
  root="."
  while [ $# -gt 0 ]; do
    case "$1" in
    --name)
      need_value "$@"
      name="$2"; shift 2 ;;
    --read-when)
      need_value "$@"
      readwhen="$2"; shift 2 ;;
    -h | --help)
      usage; exit 0 ;;
    --*)
      echo "docs.sh: unknown flag: $1" >&2; usage >&2; exit 1 ;;
    *)
      root="$1"; shift ;;
    esac
  done
  if [ -z "$name" ] || [ -z "$readwhen" ]; then
    echo "docs.sh: --name and --read-when are both required" >&2
    usage >&2
    exit 1
  fi
  nl='
'
  case "$readwhen" in
  *"$nl"*)
    echo "docs.sh: --read-when must be single-line" >&2
    exit 1 ;;
  *"|"*)
    echo "docs.sh: --read-when must not contain | — it becomes a routing-table cell" >&2
    exit 1 ;;
  *"-->"*)
    echo "docs.sh: --read-when must not contain --> — it would close the \"Read when:\" header comment early" >&2
    exit 1 ;;
  esac
  case "$name" in
  *.md) filename="$name" ;;
  *) filename="$name.md" ;;
  esac
  case "$filename" in
  /* | ../* | */../* | *"$nl"*)
    echo "docs.sh: --name must be a path under .agent/docs/ (got '$name')" >&2
    exit 1 ;;
  esac
  docs="$root/.agent/docs"
  doc="$docs/$filename"
  arch="$docs/architecture.md"
  if [ ! -s "$doc" ]; then
    echo "docs.sh: $doc does not exist — rehook edits an existing doc; use new to create one" >&2
    exit 1
  fi
  if ! head -n 5 "$doc" | grep -qF "Read when:"; then
    echo "docs.sh: $doc has no \"Read when:\" header in its first five lines — add one by hand, then rehook" >&2
    exit 1
  fi
  if [ ! -s "$arch" ] || ! grep -qF "### \`$filename\`" "$arch"; then
    echo "docs.sh: $arch has no entry for $filename — add the routing entry first" >&2
    exit 1
  fi
  HOOK="$readwhen" awk '
    NR <= 5 && !done && /<!-- Read when: .* -->$/ { print "<!-- Read when: " ENVIRON["HOOK"] " -->"; done = 1; next }
    { print }
  ' "$doc" >"$doc.rehook.tmp" || { rm -f "$doc.rehook.tmp"; exit 1; }
  HOOK="$readwhen" FILE="$filename" awk '
    $0 == "### `" ENVIRON["FILE"] "`" { inb = 1; print; next }
    inb && index($0, "### ") == 1 { inb = 0 }
    inb && /^- \*\*Read when:\*\* / { print "- **Read when:** " ENVIRON["HOOK"]; inb = 0; next }
    { print }
  ' "$arch" >"$arch.rehook.tmp" || { rm -f "$doc.rehook.tmp" "$arch.rehook.tmp"; exit 1; }
  if ! grep -qF -- "- **Read when:** $readwhen" "$arch.rehook.tmp"; then
    rm -f "$doc.rehook.tmp" "$arch.rehook.tmp"
    echo "docs.sh: could not find a \"- **Read when:**\" line under the $filename entry in $arch — nothing was changed" >&2
    exit 1
  fi
  rehook_backup="$doc.rehook.backup.$$"
  cp "$doc" "$rehook_backup" || { rm -f "$doc.rehook.tmp" "$arch.rehook.tmp"; exit 1; }
  mv "$doc.rehook.tmp" "$doc" && mv "$arch.rehook.tmp" "$arch" || {
    mv "$rehook_backup" "$doc" 2>/dev/null || :
    rm -f "$doc.rehook.tmp" "$arch.rehook.tmp"
    echo "docs.sh: rehook could not publish both files; the document was restored" >&2
    exit 1
  }
  rm -f "$rehook_backup"
  echo "docs.sh: rehooked docs/$filename — header and routing row now read: $readwhen"
  exit 0
  ;;

"")
  usage >&2
  exit 1
  ;;

*)
  echo "docs.sh: unknown command: $cmd" >&2
  usage >&2
  exit 1
  ;;
esac
