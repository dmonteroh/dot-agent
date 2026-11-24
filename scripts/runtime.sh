#!/usr/bin/env bash

# Shared runtime primitives.  Sourcing this file deliberately installs no traps.

# da_refuse WHAT NEXT_STEP [STATUS]: the message a script ends on when it
# declines. One line with the next step last, because callers pipe helpers
# through tail, head, and grep, and a second line can be cut from its first.
da_refuse() {
  [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "runtime.sh: da_refuse needs what was refused and the next step" >&2; return 2; }
  printf '%s: %s. %s\n' "${0##*/}" "$1" "$2" >&2
  return "${3:-1}"
}

da_root() {
  [ "$#" -eq 1 ] || { echo "runtime.sh: da_root needs one argument" >&2; return 2; }
  [ -d "$1" ] || { echo "runtime.sh: not a directory: $1. Pass the folder that holds .agent/ as the last argument" >&2; return 2; }
  (CDPATH='' cd -- "$1" 2>/dev/null && pwd -P) || {
    echo "runtime.sh: cannot resolve root: $1. Pass a folder this user can read as the last argument" >&2
    return 2
  }
}

da__git_common_dir() {
  (CDPATH='' cd -- "$1" 2>/dev/null && da_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
    && CDPATH='' cd -- "$da_gc" 2>/dev/null && pwd -P)
}

# The physical node directory of a project root. A checkout may hold .agent as
# a symlink to the node of another checkout of the same Git repository, as an
# orchestrator links it into worker worktrees: that is a shared node, and its
# writers write the target under the target's own locks. Any other symlink is
# refused, so a stray link cannot send node writes or private state into
# another project or into a directory that is not a node.
da_node_dir() {
  [ "$#" -eq 1 ] || { echo "runtime.sh: da_node_dir needs one argument" >&2; return 2; }
  da_nd_root=$(da_root "$1") || return
  if [ ! -L "$da_nd_root/.agent" ]; then
    printf '%s\n' "$da_nd_root/.agent"
    return 0
  fi
  da_nd_target=$(CDPATH='' cd -- "$da_nd_root/.agent" 2>/dev/null && pwd -P) || {
    echo "runtime.sh: refusing symlink .agent directory that does not resolve to a directory: $da_nd_root/.agent. Replace the link with a node, or with a link to the .agent of another checkout of this repository" >&2
    return 2
  }
  if [ "${da_nd_target##*/}" != .agent ] || [ ! -f "$da_nd_target/purpose.md" ]; then
    echo "runtime.sh: refusing symlink .agent directory whose target is not a node: $da_nd_root/.agent -> $da_nd_target. Replace the link with a node, or with a link to the .agent of another checkout of this repository" >&2
    return 2
  fi
  da_nd_here=$(da__git_common_dir "$da_nd_root") || da_nd_here=
  da_nd_there=$(da__git_common_dir "${da_nd_target%/*}") || da_nd_there=
  if [ -z "$da_nd_here" ] || [ "$da_nd_here" != "$da_nd_there" ]; then
    echo "runtime.sh: refusing symlink .agent directory that names a node outside this Git repository: $da_nd_root/.agent -> $da_nd_target. Replace the link with a node, or with a link to the .agent of another checkout of this repository" >&2
    return 2
  fi
  printf '%s\n' "$da_nd_target"
}

# Succeeds when root's .agent is an accepted link to another checkout's node.
da_node_shared() {
  [ "$#" -eq 1 ] || { echo "runtime.sh: da_node_shared needs one argument" >&2; return 2; }
  da_ns_root=$(da_root "$1") || return
  [ -L "$da_ns_root/.agent" ] && da_node_dir "$da_ns_root" >/dev/null 2>&1
}

da_state_dir() {
  [ "$#" -eq 1 ] || { echo "runtime.sh: da_state_dir needs one argument" >&2; return 2; }
  da_sd_node=$(da_node_dir "$1") || return
  da_sd_path="$da_sd_node/.state"
  if [ -L "$da_sd_path" ]; then
    echo "runtime.sh: refusing symlink state directory: $da_sd_path. Inspect that path, then run this call again" >&2
    return 2
  fi
  (umask 077 && mkdir -p -- "$da_sd_path") || {
    echo "runtime.sh: cannot create state directory: $da_sd_path. Inspect that path, then run this call again" >&2
    return 2
  }
  [ -d "$da_sd_path" ] && [ ! -L "$da_sd_path" ] || {
    echo "runtime.sh: state path is not a physical directory: $da_sd_path. Inspect that path, then run this call again" >&2
    return 2
  }
  chmod 700 "$da_sd_path" 2>/dev/null || :
  da_sd_ignore="$da_sd_path/.gitignore"
  if [ -L "$da_sd_ignore" ]; then
    echo "runtime.sh: refusing symlink self-ignore file: $da_sd_ignore. Inspect that path, then run this call again" >&2
    return 2
  fi
  if [ -e "$da_sd_ignore" ]; then
    [ "$(cat -- "$da_sd_ignore" 2>/dev/null)" = '*' ] || {
      echo "runtime.sh: unsafe self-ignore file: $da_sd_ignore. Inspect that path, then run this call again" >&2
      return 2
    }
  else
    (umask 077; set -C; printf '*\n' >"$da_sd_ignore") 2>/dev/null || {
      echo "runtime.sh: cannot write self-ignore file: $da_sd_ignore. Inspect that path, then run this call again" >&2
      return 2
    }
  fi
  printf '%s\n' "$da_sd_path"
}

da__excluded_path() {
  da_ep_root=$1 da_ep_path=$2
  case "$da_ep_path" in
    .git | .git/* | .agent/session-log.md | .agent/.session-log.checkpoint.* | .agent/indexes | .agent/indexes/* | .agent/.state | .agent/.state/* | .agent/*-log.tmp | .agent/*-log.tmp.*)
      return 0 ;;
  esac
  if [ "$da_ep_path" = .agent/rules/learned.md ] \
    && [ -d "$da_ep_root/.agent/rules/learned" ] \
    && grep -qF '<!-- Generated by index.sh from rules/learned/' "$da_ep_root/$da_ep_path" 2>/dev/null; then
    return 0
  fi
  return 1
}

# Sets REPLY to its arguments as one line of tab-separated fields. printf %q
# would spell a non-ASCII name differently in another locale.
da__line() {
  REPLY=
  for da_ln_field in "$@"; do
    da_ln_field=${da_ln_field//\\/\\\\}
    da_ln_field=${da_ln_field//$'\n'/\\n}
    da_ln_field=${da_ln_field//$'\t'/\\t}
    REPLY="$REPLY$da_ln_field"$'\t'
  done
}

# Appends one path's record to a file, and leaves in da_hp_content what a file
# or a link holds, empty for anything else.
da__hash_path() {
  da_hp_root=$1 da_hp_rel=$2 da_hp_out=$3
  da_hp_content=
  da_hp_rest=$da_hp_rel
  da_hp_prefix=
  while [ "${da_hp_rest#*/}" != "$da_hp_rest" ]; do
    da_hp_part=${da_hp_rest%%/*}
    da_hp_rest=${da_hp_rest#*/}
    if [ -n "$da_hp_prefix" ]; then da_hp_prefix="$da_hp_prefix/$da_hp_part"; else da_hp_prefix=$da_hp_part; fi
    if [ -L "$da_hp_root/$da_hp_prefix" ]; then
      da_hp_target=$(readlink "$da_hp_root/$da_hp_prefix") || return 1
      printf 'A\0%s\0%s\0%s\0' "$da_hp_rel" "$da_hp_prefix" "$da_hp_target" >>"$da_hp_out"
      return 0
    fi
  done
  if [ -L "$da_hp_root/$da_hp_rel" ]; then
    da_hp_target=$(readlink "$da_hp_root/$da_hp_rel") || return 1
    printf 'L\0%s\0%s\0' "$da_hp_rel" "$da_hp_target" >>"$da_hp_out"
    da_hp_content="link $da_hp_target"
  elif [ -f "$da_hp_root/$da_hp_rel" ]; then
    da_hp_hash=$(git hash-object --no-filters -- "$da_hp_root/$da_hp_rel") || return 1
    if [ -x "$da_hp_root/$da_hp_rel" ]; then da_hp_exec=1; else da_hp_exec=0; fi
    printf 'F\0%s\0%s\0%s\0' "$da_hp_rel" "$da_hp_exec" "$da_hp_hash" >>"$da_hp_out"
    da_hp_content="file $da_hp_exec $da_hp_hash"
  elif [ -e "$da_hp_root/$da_hp_rel" ]; then
    printf 'O\0%s\0' "$da_hp_rel" >>"$da_hp_out"
  else
    printf 'M\0%s\0' "$da_hp_rel" >>"$da_hp_out"
  fi
}

# da_fingerprint ROOT [FILE]: a digest of the current inputs. In a Git root, FILE
# receives a second digest from the same pass: the content of the tracked and
# unignored files alone, with no commit and no index in it, so the same work
# reads alike before and after it is committed. A missing file and a path behind
# a link are left out, because the commit that records them drops their index
# entries.
da_fingerprint() {
  [ "$#" -eq 1 ] || [ "$#" -eq 2 ] || { echo "runtime.sh: da_fingerprint needs one or two arguments" >&2; return 2; }
  da_fp_content_out=${2-}
  da_fp_root=$(da_root "$1") || return
  da_fp_tmp=$(mktemp "${TMPDIR:-/tmp}/da-fingerprint.XXXXXX") || {
    echo "runtime.sh: cannot create fingerprint temporary file" >&2
    return 2
  }
  da_fp_list=$(mktemp "${TMPDIR:-/tmp}/da-paths.XXXXXX") || {
    rm -f "$da_fp_tmp"; echo "runtime.sh: cannot create path-list temporary file" >&2; return 2;
  }
  : >"$da_fp_tmp"
  da_fp_rc=0
  da_fp_lines=
  if [ -n "$da_fp_content_out" ]; then
    da_fp_lines=$(mktemp "${TMPDIR:-/tmp}/da-content.XXXXXX") || {
      rm -f "$da_fp_tmp" "$da_fp_list"; echo "runtime.sh: cannot create content temporary file. Check that the temporary folder is writable, then run this call again" >&2; return 2
    }
  fi
  printf 'root\0%s\0' "$da_fp_root" >>"$da_fp_tmp"
  da_fp_config=${DA_VERIFY_CONFIG:-.agent/scripts/verify.conf}
  da_fp_driver=${DA_CHECK_DRIVER:-.agent/scripts/checks.sh}
  for da_fp_required in "$da_fp_config" "$da_fp_driver"; do
    case "$da_fp_required" in '' | /* | *'/../'* | ../* | */.. | *'//'*) da_fp_rc=1; break ;; esac
  done
  if git -C "$da_fp_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    da_fp_head=$(git -C "$da_fp_root" rev-parse --verify HEAD 2>/dev/null || printf 'unborn')
    printf 'git\0%s\0' "$da_fp_head" >>"$da_fp_tmp"
    git -C "$da_fp_root" ls-files --stage -z >"$da_fp_list" || da_fp_rc=1
    if [ "$da_fp_rc" -eq 0 ]; then
      while IFS= read -r -d '' da_fp_entry; do
        case "$da_fp_entry" in *$'\t'*) ;; *) da_fp_rc=1; break ;; esac
        da_fp_meta=${da_fp_entry%%$'\t'*}
        da_fp_path=${da_fp_entry#*$'\t'}
        da_fp_stage=${da_fp_meta##* }
        case "$da_fp_stage" in
          0) ;;
          *) echo "runtime.sh: unresolved index stage for: $da_fp_path" >&2; da_fp_rc=1; break ;;
        esac
        da__excluded_path "$da_fp_root" "$da_fp_path" && continue
        printf 'I\0%s\0%s\0' "$da_fp_meta" "$da_fp_path" >>"$da_fp_tmp"
        case "$da_fp_meta" in
          160000\ *)
            da_fp_sub_probe=$da_fp_path
            da_fp_sub_symlink=0
            while :; do
              if [ -L "$da_fp_root/$da_fp_sub_probe" ]; then
                da_fp_sub_symlink=1
                break
              fi
              case "$da_fp_sub_probe" in
                */*) da_fp_sub_probe=${da_fp_sub_probe%/*} ;;
                *) break ;;
              esac
            done
            if [ "$da_fp_sub_symlink" -eq 1 ]; then
              # da__hash_path records the exact link boundary later.  This
              # marker makes explicit that no repository beyond it was read.
              printf 'SL\0%s\0' "$da_fp_path" >>"$da_fp_tmp"
            elif [ -d "$da_fp_root/$da_fp_path" ]; then
              da_fp_sub_root=$(da_root "$da_fp_root/$da_fp_path") || { da_fp_rc=1; break; }
              da_fp_sub_top=$(git -C "$da_fp_sub_root" rev-parse --show-toplevel 2>/dev/null || :)
              if [ -n "$da_fp_sub_top" ]; then
                da_fp_sub_top=$(da_root "$da_fp_sub_top") || { da_fp_rc=1; break; }
              fi
              if [ "$da_fp_sub_top" = "$da_fp_sub_root" ]; then
                da_fp_sub_digest=$(
                  trap - EXIT HUP INT TERM
                  da_fingerprint "$da_fp_sub_root" ${da_fp_lines:+"$da_fp_lines.sub"}
                ) || { da_fp_rc=1; break; }
                printf 'SR\0%s\0%s\0' "$da_fp_path" "$da_fp_sub_digest" >>"$da_fp_tmp"
                if [ -n "$da_fp_lines" ]; then
                  da__line "$da_fp_path" submodule "$(cat "$da_fp_lines.sub")"
                  printf '%s\n' "$REPLY" >>"$da_fp_lines" || { da_fp_rc=1; break; }
                fi
              elif [ ! -e "$da_fp_sub_root/.git" ]; then
                # Do not mistake the parent repository reported by Git for an
                # uninitialized submodule checkout.
                if ! da_fp_sub_contents=$(find "$da_fp_sub_root" -mindepth 1 -print -quit 2>/dev/null); then
                  echo "runtime.sh: cannot inspect uninitialized submodule: $da_fp_path" >&2
                  da_fp_rc=1
                  break
                elif [ -n "$da_fp_sub_contents" ]; then
                  echo "runtime.sh: unsupported nonempty uninitialized submodule: $da_fp_path" >&2
                  da_fp_rc=1
                  break
                else
                  printf 'SU\0%s\0' "$da_fp_path" >>"$da_fp_tmp"
                fi
              else
                echo "runtime.sh: unsupported submodule boundary: $da_fp_path" >&2
                da_fp_rc=1
                break
              fi
            else
              printf 'SU\0%s\0' "$da_fp_path" >>"$da_fp_tmp"
            fi
            ;;
        esac
      done <"$da_fp_list"
    fi
    if [ "$da_fp_rc" -eq 0 ]; then
      git -C "$da_fp_root" ls-files -co --exclude-standard -z >"$da_fp_list" || da_fp_rc=1
    fi
    if [ "$da_fp_rc" -eq 0 ]; then
      while IFS= read -r -d '' da_fp_path; do
        da__excluded_path "$da_fp_root" "$da_fp_path" && continue
        da__hash_path "$da_fp_root" "$da_fp_path" "$da_fp_tmp" || { da_fp_rc=1; break; }
        [ -n "$da_fp_lines" ] && [ -n "$da_hp_content" ] || continue
        da__line "$da_fp_path" "$da_hp_content"
        printf '%s\n' "$REPLY" >>"$da_fp_lines" || { da_fp_rc=1; break; }
      done <"$da_fp_list"
    fi
    if [ "$da_fp_rc" -eq 0 ] && [ -n "$da_fp_lines" ]; then
      LC_ALL=C sort -u "$da_fp_lines" -o "$da_fp_lines" && git hash-object --no-filters -- "$da_fp_lines" >"$da_fp_content_out" || da_fp_rc=1
    fi
    if [ "$da_fp_rc" -eq 0 ]; then
      : >"$da_fp_list"
      git -C "$da_fp_root" ls-files --others --ignored --exclude-standard -z -- .agent \
        >>"$da_fp_list" || da_fp_rc=1
      printf '%s\0%s\0' "$da_fp_config" "$da_fp_driver" >>"$da_fp_list"
    fi
    if [ "$da_fp_rc" -eq 0 ]; then
      while IFS= read -r -d '' da_fp_path; do
        da__excluded_path "$da_fp_root" "$da_fp_path" && continue
        da__hash_path "$da_fp_root" "$da_fp_path" "$da_fp_tmp" || { da_fp_rc=1; break; }
      done <"$da_fp_list"
    fi
  else
    printf 'non-git\0' >>"$da_fp_tmp"
    da_fp_roots=${DA_NON_GIT_INPUT_ROOTS:-.agent}
    da_fp_roots="$da_fp_roots .agent"
    case "$da_fp_roots" in *$'\n'* | *$'\r'* | *$'\t'*) da_fp_rc=1 ;; esac
    if [ "$da_fp_rc" -eq 0 ]; then
      : >"$da_fp_list"
      da_fp_oldifs=$IFS; IFS=' '
      for da_fp_input in $da_fp_roots; do
        IFS=$da_fp_oldifs
        case "$da_fp_input" in '' | /* | *'/../'* | ../* | */.. | *'//'*) da_fp_rc=1; break ;; esac
        da_fp_probe=$da_fp_input
        da_fp_symlink_parent=0
        while [ "${da_fp_probe#*/}" != "$da_fp_probe" ]; do
          da_fp_probe=${da_fp_probe%/*}
          if [ -L "$da_fp_root/$da_fp_probe" ]; then da_fp_symlink_parent=1; break; fi
        done
        if [ "$da_fp_symlink_parent" -eq 1 ]; then
          printf '%s\n' "$da_fp_input" >>"$da_fp_list"
        elif [ -d "$da_fp_root/$da_fp_input" ] && [ ! -L "$da_fp_root/$da_fp_input" ]; then
          da_fp_nl=$'\n'; da_fp_cr=$'\r'; da_fp_tab=$'\t'
          if (cd "$da_fp_root" && find "./$da_fp_input" \( -name "*$da_fp_nl*" -o -name "*$da_fp_cr*" -o -name "*$da_fp_tab*" \) -print -quit) | grep -q .; then
            da_fp_rc=1; break
          fi
          (cd "$da_fp_root" && find "./$da_fp_input" \( -type f -o -type l \) -print) >>"$da_fp_list" || { da_fp_rc=1; break; }
        elif [ -e "$da_fp_root/$da_fp_input" ] || [ -L "$da_fp_root/$da_fp_input" ]; then
          printf '%s\n' "$da_fp_input" >>"$da_fp_list"
        else
          printf 'R\0%s\0missing\0' "$da_fp_input" >>"$da_fp_tmp"
        fi
        IFS=' '
      done
      IFS=$da_fp_oldifs
      for da_fp_required in "$da_fp_config" "$da_fp_driver"; do
        printf './%s\n' "$da_fp_required" >>"$da_fp_list"
      done
    fi
    if [ "$da_fp_rc" -eq 0 ]; then
      LC_ALL=C sort -u "$da_fp_list" -o "$da_fp_list" || da_fp_rc=1
    fi
    if [ "$da_fp_rc" -eq 0 ]; then
      while IFS= read -r da_fp_path; do
        while [ "${da_fp_path#./}" != "$da_fp_path" ]; do da_fp_path=${da_fp_path#./}; done
        da__excluded_path "$da_fp_root" "$da_fp_path" && continue
        da__hash_path "$da_fp_root" "$da_fp_path" "$da_fp_tmp" || { da_fp_rc=1; break; }
      done <"$da_fp_list"
    fi
  fi
  if [ "$da_fp_rc" -eq 0 ]; then
    da_fp_digest=$(git hash-object --no-filters -- "$da_fp_tmp") || da_fp_rc=1
  fi
  rm -f "$da_fp_tmp" "$da_fp_list"
  [ -z "$da_fp_lines" ] || rm -f "$da_fp_lines" "$da_fp_lines.sub"
  [ "$da_fp_rc" -eq 0 ] || { echo "runtime.sh: could not fingerprint project inputs. Fix what the lines above name, or check that .agent/scripts/verify.conf and checks.sh exist, then run this call again" >&2; return 2; }
  printf '%s\n' "$da_fp_digest"
}

da_lock() {
  [ "$#" -eq 1 ] || { echo "runtime.sh: da_lock needs one argument" >&2; return 2; }
  da_lk_path=$1
  if (umask 077 && mkdir -- "$da_lk_path") 2>/dev/null; then
    printf '%s\n' "$$" >"$da_lk_path/owner" || { rmdir "$da_lk_path" 2>/dev/null; return 2; }
    return 0
  fi
  # Gone again: its holder released it between the mkdir and this check.
  if [ ! -e "$da_lk_path" ] && [ ! -L "$da_lk_path" ]; then
    echo "runtime.sh: lock was released while being taken: $da_lk_path. Run this call again" >&2; return 1
  fi
  [ -d "$da_lk_path" ] || { echo "runtime.sh: lock path is not a directory: $da_lk_path. If no node script is running, remove that path and run this call again" >&2; return 2; }
  # A writer that has made the lock directory but not yet recorded its pid
  # looks like this too, so it counts as held (1), which da_lock_wait retries.
  if [ ! -f "$da_lk_path/owner" ]; then
    echo "runtime.sh: lock has no demonstrable owner: $da_lk_path. A lock left with no owner for a whole wait is taken over. Run this call again" >&2; return 1
  fi
  da_lk_owner=$(cat "$da_lk_path/owner" 2>/dev/null) || {
    echo "runtime.sh: lock was released while being read: $da_lk_path. Run this call again" >&2; return 1
  }
  case "$da_lk_owner" in
    '') echo "runtime.sh: lock has no demonstrable owner: $da_lk_path. A lock left with no owner for a whole wait is taken over. Run this call again" >&2; return 1 ;;
    *[!0-9]*) echo "runtime.sh: lock has an invalid owner: $da_lk_path. If no node script is running, remove that directory and run this call again" >&2; return 2 ;;
  esac
  if kill -0 "$da_lk_owner" 2>/dev/null; then
    echo "runtime.sh: lock is held by live pid $da_lk_owner: $da_lk_path. Another writer is running. Wait for it and run this call again" >&2; return 1
  fi
  ps -p "$da_lk_owner" -o pid= >/dev/null 2>&1
  da_lk_ps=$?
  if [ "$da_lk_ps" -eq 0 ]; then
    echo "runtime.sh: lock owner pid $da_lk_owner exists but cannot be signalled: $da_lk_path. Another writer is running. Wait for it and run this call again" >&2; return 1
  fi
  if [ "$da_lk_ps" -ne 1 ]; then
    echo "runtime.sh: cannot demonstrate that lock owner pid $da_lk_owner is dead: $da_lk_path. If no node script is running, remove that directory and run this call again" >&2; return 2
  fi
  # A holder that released the lock and exited also reads as dead, and another
  # writer may hold the lock by now: recover only a lock that still names the
  # dead pid.
  if [ "$(cat "$da_lk_path/owner" 2>/dev/null)" != "$da_lk_owner" ]; then
    echo "runtime.sh: lock changed hands while being checked: $da_lk_path. Run this call again" >&2; return 1
  fi
  rm -f -- "$da_lk_path/owner" 2>/dev/null && rmdir -- "$da_lk_path" 2>/dev/null || {
    echo "runtime.sh: could not recover dead lock: $da_lk_path. If no node script is running, remove that directory and run this call again" >&2; return 2;
  }
  if (umask 077 && mkdir -- "$da_lk_path") 2>/dev/null; then
    printf '%s\n' "$$" >"$da_lk_path/owner" || { rmdir "$da_lk_path" 2>/dev/null; return 2; }
    return 0
  fi
  echo "runtime.sh: lock was acquired concurrently: $da_lk_path. Another writer is running. Wait for it and run this call again" >&2
  return 1
}

# da_lock, retried while a live writer holds the lock, for at most
# DA_LOCK_WAIT_SECONDS (default 10, a chosen default: a record writer holds its
# lock for one append or one file write, so parallel workers clear in well
# under a second, and a checkpoint that holds the log lock through its checks
# still ends in a refusal the caller sees). Other failures return at once.
#
# A writer records its pid right after it makes the lock directory, so a
# directory with no owner file at every attempt of a whole wait was left by a
# writer killed while releasing it, and no dead-owner check can clear it. The
# wait ends by removing it and taking the lock. rmdir removes only an empty
# directory, so a lock that gained an owner in the meantime stays held. A wait
# of 0 makes one attempt and never removes anything.
da_lock_wait() {
  [ "$#" -eq 1 ] || { echo "runtime.sh: da_lock_wait needs one argument" >&2; return 2; }
  da_lw_wait=${DA_LOCK_WAIT_SECONDS:-10}
  case "$da_lw_wait" in '' | *[!0-9]*) da_lw_wait=10 ;; esac
  # SECONDS is bash's own clock, so the wait needs no external command and a
  # project that puts its own date on PATH cannot disturb it.
  da_lw_end=$((SECONDS + da_lw_wait))
  da_lw_ownerless=1
  while :; do
    da_lw_err=$({ da_lock "$1" 2>&1 >&3; } 3>&1)
    da_lw_rc=$?
    if [ "$da_lw_rc" -ne 1 ] || [ ! -d "$1" ] || [ -e "$1/owner" ]; then da_lw_ownerless=0; fi
    [ "$da_lw_rc" -eq 1 ] && [ "$SECONDS" -lt "$da_lw_end" ] || break
    sleep 0.2
  done
  if [ "$da_lw_rc" -eq 1 ] && [ "$da_lw_ownerless" -eq 1 ] && [ "$da_lw_wait" -gt 0 ] \
    && rmdir -- "$1" 2>/dev/null; then
    da_lw_err=$({ da_lock "$1" 2>&1 >&3; } 3>&1)
    da_lw_rc=$?
    [ "$da_lw_rc" -ne 0 ] || echo "runtime.sh: took a lock left with no owner: $1" >&2
  fi
  [ -z "$da_lw_err" ] || printf '%s\n' "$da_lw_err" >&2
  return "$da_lw_rc"
}

da_unlock() {
  [ "$#" -eq 1 ] || { echo "runtime.sh: da_unlock needs one argument" >&2; return 2; }
  da_ul_path=$1
  [ -f "$da_ul_path/owner" ] || { echo "runtime.sh: lock has no owner: $da_ul_path" >&2; return 2; }
  da_ul_owner=$(cat "$da_ul_path/owner" 2>/dev/null) || return 2
  [ "$da_ul_owner" = "$$" ] || { echo "runtime.sh: refusing to release another process's lock: $da_ul_path" >&2; return 2; }
  rm -f -- "$da_ul_path/owner" && rmdir -- "$da_ul_path" || {
    echo "runtime.sh: could not release lock: $da_ul_path" >&2; return 2;
  }
}
