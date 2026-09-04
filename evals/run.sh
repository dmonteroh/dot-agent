#!/usr/bin/env bash
# evals/run.sh — runs one eval in one arm: builds the fixture at that arm's
# corpus revision, drives the agent through every turn of the eval prompt in
# one session, captures the artifact set, and grades the auto assertions.
#
# The arm never reaches a path, a filename, or a grading record. It is written
# to arm-map.json and run-config.json alone, neither of which the grader
# opens. A run id is 128 random bits, drawn fresh per run, and carries no
# condition token.
#
# Claude and Codex are driven directly: resolved executables, argv-array
# invocations, no shell string built from the prompt, every turn's prompt
# delivered on stdin rather than as a process argument. Nothing here calls
# the provider API — both adapters drive the operator's own logged-in CLI.
#
# Tunables: agents.conf beside this script, or the path in EVALS_AGENTS_CONF
# if set (scripts/test.sh points this at a disposable conf so its fake-CLI
# coverage never touches the operator's own agents.conf). CLAUDE_* and
# CODEX_* ship with the reference model and effort filled in.
#
# Full documentation: evals/README.md.
#
# Usage: run.sh --eval <id> --arm <name> --agent <claude|codex>
#                --corpus-ref <ref> --workspace <dir> [--iteration <n>]
#                [--treatment-arm <name>]
#        run.sh --dry-run ...        # build and print every turn, drive nothing
#        run.sh --list-arms          # resolved executables and versions, no model call
#        run.sh --probe-agent <claude|codex>   # one live readiness call
#
# --iteration selects which iteration-<n> directory this invocation targets
# (default 1); it never selects a repeat. REPEATS (agents.conf) is how many
# repeat run directories one invocation creates *inside* that one iteration,
# each with its own fixture and run id, all under iteration-<n>/eval-<id>/.

set -u

# Subscription-backed auth only: strip provider credential and
# alternate-provider environment variables from run.sh's own environment,
# before any child process (including a `--version` probe) is spawned, so
# neither adapter's subprocess can silently fall back to API-key or
# cloud-passthrough billing instead of the operator's own claude.ai / ChatGPT
# login. Unsetting them here means nothing downstream ever sees one.
for _provider_var in \
  ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_CUSTOM_HEADERS \
  CLAUDE_API_KEY CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX \
  ANTHROPIC_VERTEX_PROJECT_ID CLOUD_ML_REGION GOOGLE_APPLICATION_CREDENTIALS \
  AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_BEARER_TOKEN_BEDROCK \
  OPENAI_API_KEY OPENAI_ORG_ID OPENAI_PROJECT_ID CODEX_API_KEY; do
  unset "$_provider_var"
done
unset _provider_var

selfdir=$(cd "$(dirname "$0")" && pwd)
conf="${EVALS_AGENTS_CONF:-$selfdir/agents.conf}"
spec="$selfdir/spec.json"

# Declared before --list-arms/--probe-agent can run, not just before the main
# argument parser: agent_identity_check reads these globals from inside
# claude_run/codex_run, and --probe-agent drives those same adapters before
# the main parser ever assigns them. Left unset here, `set -u` turns the
# first probe call into an unbound-variable error instead of a clean result.
agent_bin=""; agent_bin_real=""; agent_bin_hash=""; agent_ver=""; agent_ver_output=""

conf_get() { sed -n "s/^$1=//p" "$conf" 2>/dev/null | head -n 1; }

usage() { sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//;$d'; }

REPEATS=$(conf_get REPEATS); REPEATS=${REPEATS:-1}
TIMEOUT=$(conf_get TIMEOUT); TIMEOUT=${TIMEOUT:-900}
PROBE_TIMEOUT=120

DEFAULT_CLAUDE_MODEL="claude-sonnet-5"
DEFAULT_CLAUDE_EFFORT="medium"
DEFAULT_CODEX_MODEL="gpt-5.6-terra"
DEFAULT_CODEX_EFFORT="medium"
DEFAULT_CODEX_APP_BIN="/Applications/ChatGPT.app/Contents/Resources/codex"

# ---------------------------------------------------------------------------
# small utilities
# ---------------------------------------------------------------------------

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# Prints the first x.y.z-ish token from `<bin> --version`. Empty if it can't
# be read — a resolved binary that won't report its own version is still
# reported as resolved, with version left blank rather than guessed.
bin_version() {
  local bin="$1"
  "$bin" --version 2>/dev/null | head -n 1 | "$selfdir/run_lib.py" bin-version
}

bin_version_output() {
  local bin="$1"
  "$bin" --version 2>/dev/null | head -n 1
}

canonical_path() {
  "$selfdir/run_lib.py" canonical-path "$1"
}

file_sha256() {
  "$selfdir/run_lib.py" file-sha256 "$1"
}

# Generates an opaque run id: "r" + 128 random bits as hex. Long enough that
# a collision under a live workspace is a signal, not an expectation — the
# caller refuses rather than reusing or overwriting one.
gen_run_id() { "$selfdir/run_lib.py" gen-run-id; }

# ---------------------------------------------------------------------------
# executable resolution — never hardcodes a path on this machine except the
# one well-known ChatGPT desktop app location every candidate below falls
# back to; every other candidate comes from PATH lookup or an
# operator-supplied conf value.
# ---------------------------------------------------------------------------

resolve_claude_bin() {
  local want
  want=$(conf_get CLAUDE_BIN)
  want=${want:-claude}
  if [ "$want" = "auto" ]; then
    if have_cmd claude; then RESOLVED_BIN=$(command -v claude); RESOLVED_ERR=""; return 0; fi
    RESOLVED_BIN=""; RESOLVED_ERR="no 'claude' found on PATH"; return 1
  fi
  case "$want" in
  */*)
    [ -x "$want" ] || { RESOLVED_BIN=""; RESOLVED_ERR="CLAUDE_BIN '$want' is not an executable file"; return 1; }
    RESOLVED_BIN="$want"; RESOLVED_ERR=""; return 0 ;;
  *)
    have_cmd "$want" || { RESOLVED_BIN=""; RESOLVED_ERR="CLAUDE_BIN '$want' not found on PATH"; return 1; }
    RESOLVED_BIN=$(command -v "$want"); RESOLVED_ERR=""; return 0 ;;
  esac
}

# A version threshold cannot prove a Codex build exposes the flags this adapter
# requires. Probe each candidate's actual global, exec, and resume help surfaces
# before accepting it, including configured absolute paths and app fallbacks.
codex_feature_probe() {
  local candidate root_help exec_help resume_help missing surface flag help_text flags
  candidate="$1"
  root_help=$("$candidate" --help 2>/dev/null) || {
    CODEX_FEATURE_ERR="cannot read --help"; return 1; }
  exec_help=$("$candidate" exec --help 2>/dev/null) || {
    CODEX_FEATURE_ERR="cannot read exec --help"; return 1; }
  resume_help=$("$candidate" exec resume --help 2>/dev/null) || {
    CODEX_FEATURE_ERR="cannot read exec resume --help"; return 1; }

  missing=""
  for surface in root exec resume; do
    case "$surface" in
    root) help_text="$root_help"; flags="--ask-for-approval -c" ;;
    exec) help_text="$exec_help"; flags="--json --ignore-user-config --sandbox -C --model" ;;
    resume) help_text="$resume_help"; flags="--json --model" ;;
    esac
    for flag in $flags; do
      HELP_TEXT="$help_text" FLAG="$flag" "$selfdir/run_lib.py" codex-flag-check \
        || missing="$missing $surface:$flag"
    done
  done
  if [ -n "$missing" ]; then
    CODEX_FEATURE_ERR="missing required help features:${missing}"
    return 1
  fi
  CODEX_FEATURE_ERR=""
  return 0
}

resolve_codex_bin() {
  local want app path_bin rejected

  fallback() {
    local candidate
    for candidate in "$app" "$DEFAULT_CODEX_APP_BIN"; do
      [ -n "$candidate" ] && [ -x "$candidate" ] || continue
      if codex_feature_probe "$candidate"; then
        RESOLVED_BIN="$candidate"; RESOLVED_ERR=""; return 0
      fi
      rejected="$rejected; $candidate: $CODEX_FEATURE_ERR"
    done
    return 1
  }

  want=$(conf_get CODEX_BIN); want=${want:-auto}
  app=$(conf_get CODEX_APP_BIN)
  rejected=""

  if [ "$want" != "auto" ]; then
    case "$want" in
    */*)
      [ -x "$want" ] || { RESOLVED_BIN=""; RESOLVED_ERR="CODEX_BIN '$want' is not an executable file"; return 1; }
      path_bin="$want" ;;
    *)
      have_cmd "$want" || { RESOLVED_BIN=""; RESOLVED_ERR="CODEX_BIN '$want' not found on PATH"; return 1; }
      path_bin=$(command -v "$want") ;;
    esac
    if codex_feature_probe "$path_bin"; then
      RESOLVED_BIN="$path_bin"; RESOLVED_ERR=""; return 0
    fi
    RESOLVED_BIN=""; RESOLVED_ERR="CODEX_BIN '$path_bin' is incompatible: $CODEX_FEATURE_ERR"
    return 1
  fi

  if have_cmd codex; then
    path_bin=$(command -v codex)
    if codex_feature_probe "$path_bin"; then
      RESOLVED_BIN="$path_bin"; RESOLVED_ERR=""; return 0
    fi
    rejected="$path_bin: $CODEX_FEATURE_ERR"
    if fallback; then return 0; fi
    RESOLVED_BIN=""
    RESOLVED_ERR="no feature-compatible Codex candidate found ($rejected)"
    return 1
  fi

  if fallback; then return 0; fi

  RESOLVED_BIN=""; RESOLVED_ERR="no 'codex' on PATH and no feature-compatible CODEX_APP_BIN or ChatGPT.app codex is available${rejected:+ ($rejected)}"
  return 1
}

agent_identity_check() {
  local target phase current_bin current_real current_hash current_version_output
  target="$1"; phase="$2"
  case "$target" in
  claude)
    resolve_claude_bin || {
      AGENT_FAILURE_STATUS="agent_identity_mismatch"
      AGENT_FAILURE_REASON="$target identity check $phase launch failed: $RESOLVED_ERR"
      return 1
    } ;;
  codex)
    resolve_codex_bin || {
      AGENT_FAILURE_STATUS="agent_identity_mismatch"
      AGENT_FAILURE_REASON="$target identity check $phase launch failed: $RESOLVED_ERR"
      return 1
    } ;;
  esac
  current_bin="$RESOLVED_BIN"
  current_real=$(canonical_path "$current_bin") || current_real=""
  current_hash=$(file_sha256 "$current_real") || current_hash=""
  current_version_output=$(bin_version_output "$current_bin")
  if [ "$current_bin" != "$agent_bin" ] \
    || [ "$current_real" != "$agent_bin_real" ] \
    || [ "$current_hash" != "$agent_bin_hash" ] \
    || [ "$current_version_output" != "$agent_ver_output" ]; then
    AGENT_FAILURE_STATUS="agent_identity_mismatch"
    AGENT_FAILURE_REASON="$target identity changed $phase launch"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# portable timeout — Python process groups, so a kill reaches every
# descendant a driven CLI spawned, not just the process run.sh started
# directly. No GNU coreutils; works on a stock macOS and on Linux.
# ---------------------------------------------------------------------------

# run_with_timeout <timeout_secs> <stdin_file|-> <cwd|-> <pid_file> <argv...>
# Runs argv as the leader of a new session (Python's start_new_session), so
# a timeout's kill -TERM/-KILL reaches the whole process group. Exit 124
# marks a timeout, the same convention GNU timeout uses.
run_with_timeout() {
  local secs stdinfile cwd pidfile rc
  secs="$1"; stdinfile="$2"; cwd="$3"; pidfile="$4"; shift 4
  ACTIVE_PROCESS_PID_FILE="$pidfile"
  rm -f "$pidfile"
  "$selfdir/run_lib.py" run-with-timeout "$secs" "$stdinfile" "$cwd" "$pidfile" "$@" &
  ACTIVE_WRAPPER_PID=$!
  wait "$ACTIVE_WRAPPER_PID"
  rc=$?
  ACTIVE_WRAPPER_PID=""
  ACTIVE_PROCESS_PID_FILE=""
  rm -f "$pidfile"
  return "$rc"
}

# The only homes this runner may recursively remove.  They live in system
# temporary storage, never in a retained run directory.  Keep the active path
# in one variable so normal returns and shell signals use the same cleanup.
CODEX_TEMP_PREFIX="${TMPDIR:-/tmp}/dot-agent-codex-home."
VERIFIER_TEMP_PREFIX="${TMPDIR:-/tmp}/dot-agent-eval-verifiers."
CODEX_ACTIVE_HOME=""
VERIFIER_ACTIVE_DIR=""
VERIFIER_STATUS_HASH=""
VERIFIER_COMMENTS_HASH=""
VERIFIER_STATUS_CONF_HASH=""
VERIFIER_COMMENTS_CONF_HASH=""
ACTIVE_WRAPPER_PID=""
ACTIVE_PROCESS_PID_FILE=""
PROBE_SCRATCH=""
TURNSTMP=""
ACTIVE_RUN_DIR=""
ACTIVE_ITER_LOCK=""

codex_home_remove() {
  local disposable
  disposable="$1"
  case "$disposable" in
    "$CODEX_TEMP_PREFIX"*) [ -d "$disposable" ] && rm -rf "$disposable" ;;
    "") ;;
    *) echo "run.sh: refusing to remove unexpected Codex temporary home: $disposable" >&2 ;;
  esac
}

codex_home_cleanup() {
  local disposable
  disposable="${CODEX_ACTIVE_HOME:-}"
  CODEX_ACTIVE_HOME=""
  codex_home_remove "$disposable"
}

verifier_cleanup() {
  local snapshot
  snapshot="${VERIFIER_ACTIVE_DIR:-}"
  VERIFIER_ACTIVE_DIR=""
  VERIFIER_STATUS_HASH=""
  VERIFIER_COMMENTS_HASH=""
  VERIFIER_STATUS_CONF_HASH=""
  VERIFIER_COMMENTS_CONF_HASH=""
  case "$snapshot" in
    "$VERIFIER_TEMP_PREFIX"*)
      if [ -d "$snapshot" ]; then chmod 700 "$snapshot" 2>/dev/null; rm -rf "$snapshot"; fi ;;
    "") ;;
    *) echo "run.sh: refusing to remove unexpected verifier snapshot: $snapshot" >&2 ;;
  esac
}

# Ownership of the snapshot directory is registered in VERIFIER_ACTIVE_DIR
# immediately after mktemp succeeds — before any copy, chmod, or hash below
# — so a cancellation mid-setup still cleans it up via the same EXIT/signal
# traps that cover a finished snapshot. Every early return after that point
# leaves cleanup to the caller (mark_stage_void -> verifier_cleanup) instead
# of removing the directory inline, which is what makes the early-registration
# safe rather than redundant.
verifier_snapshot() {
  local fixdir="$1" snapshot
  snapshot=$(mktemp -d "${VERIFIER_TEMP_PREFIX}XXXXXX") || return 1
  VERIFIER_ACTIVE_DIR="$snapshot"
  chmod 700 "$snapshot" || return 1
  cp "$fixdir/.agent/scripts/status.sh" "$snapshot/status.sh" || return 1
  cp "$fixdir/.agent/scripts/comments.sh" "$snapshot/comments.sh" || return 1
  if [ -f "$fixdir/.agent/scripts/status.conf" ]; then
    cp "$fixdir/.agent/scripts/status.conf" "$snapshot/status.conf" || return 1
  fi
  if [ -f "$fixdir/.agent/scripts/comments.conf" ]; then
    cp "$fixdir/.agent/scripts/comments.conf" "$snapshot/comments.conf" || return 1
  fi
  chmod 500 "$snapshot/status.sh" "$snapshot/comments.sh" || return 1
  [ ! -f "$snapshot/status.conf" ] || chmod 400 "$snapshot/status.conf"
  [ ! -f "$snapshot/comments.conf" ] || chmod 400 "$snapshot/comments.conf"
  VERIFIER_STATUS_HASH=$(file_sha256 "$snapshot/status.sh") || return 1
  VERIFIER_COMMENTS_HASH=$(file_sha256 "$snapshot/comments.sh") || return 1
  VERIFIER_STATUS_CONF_HASH=""
  if [ -f "$snapshot/status.conf" ]; then
    VERIFIER_STATUS_CONF_HASH=$(file_sha256 "$snapshot/status.conf") || return 1
  fi
  VERIFIER_COMMENTS_CONF_HASH=""
  if [ -f "$snapshot/comments.conf" ]; then
    VERIFIER_COMMENTS_CONF_HASH=$(file_sha256 "$snapshot/comments.conf") || return 1
  fi
  chmod 500 "$snapshot" || return 1
}

# path, expected hash (empty means "no conf was captured — it must still be
# absent"). A conf that goes from absent to present between snapshot and use
# is exactly as much a forgery as an edited one, so an empty expected hash is
# a check, not a skip — that closes the unhashed-config gap: a comments.conf
# or status.conf the agent plants after the snapshot was taken can never
# reach the verifier, whether or not the node shipped one originally.
verifier_conf_intact() {
  local path="$1" expected="$2"
  if [ -z "$expected" ]; then
    [ ! -f "$path" ]
    return
  fi
  [ "$(file_sha256 "$path" 2>/dev/null)" = "$expected" ]
}

verifier_integrity_check() {
  [ -n "$VERIFIER_ACTIVE_DIR" ] \
    && [ "$(file_sha256 "$VERIFIER_ACTIVE_DIR/status.sh" 2>/dev/null)" = "$VERIFIER_STATUS_HASH" ] \
    && [ "$(file_sha256 "$VERIFIER_ACTIVE_DIR/comments.sh" 2>/dev/null)" = "$VERIFIER_COMMENTS_HASH" ] \
    && verifier_conf_intact "$VERIFIER_ACTIVE_DIR/status.conf" "$VERIFIER_STATUS_CONF_HASH" \
    && verifier_conf_intact "$VERIFIER_ACTIVE_DIR/comments.conf" "$VERIFIER_COMMENTS_CONF_HASH"
}

# Overwrites the fixture's own status.conf with the trusted snapshot's copy
# (or removes it, if none was captured) immediately before status.sh runs
# against final artifacts. status.sh always resolves its conf relative to
# the root it is passed — the fixture, not the snapshot directory it was
# copied from — so hashing the snapshot alone is not enough: without this
# restore, an agent-mutated status.conf sitting in the fixture would still
# be the one the trusted status.sh binary reads.
verifier_restore_status_conf() {
  local fixdir="$1" target
  target="$fixdir/.agent/scripts/status.conf"
  if [ -n "$VERIFIER_STATUS_CONF_HASH" ]; then
    cp "$VERIFIER_ACTIVE_DIR/status.conf" "$target"
  else
    rm -f "$target"
  fi
}

# EXIT handles all normal Codex return paths.  The signal traps clean first,
# then restore the signal's conventional termination status instead of turning
# an interruption into a successful run.  No earlier run.sh trap exists, so
# this is additive to the script's cleanup responsibilities.
# shellcheck disable=SC2329  # invoked from EXIT and signal traps
active_process_cleanup() {
  local wrapper pgid i
  wrapper="${ACTIVE_WRAPPER_PID:-}"
  pgid=""
  if [ -n "${ACTIVE_PROCESS_PID_FILE:-}" ] && [ -f "$ACTIVE_PROCESS_PID_FILE" ]; then
    pgid=$(sed -n '1p' "$ACTIVE_PROCESS_PID_FILE")
  fi
  case "$pgid" in *[!0-9]* | "") pgid="" ;; esac

  [ -n "$pgid" ] && kill -TERM -- "-$pgid" 2>/dev/null
  [ -n "$wrapper" ] && kill -TERM "$wrapper" 2>/dev/null
  if [ -n "$pgid" ]; then
    i=0
    while kill -0 -- "-$pgid" 2>/dev/null && [ "$i" -lt 50 ]; do
      sleep 0.1
      i=$((i + 1))
    done
    kill -0 -- "-$pgid" 2>/dev/null && kill -KILL -- "-$pgid" 2>/dev/null
  fi
  [ -n "$wrapper" ] && wait "$wrapper" 2>/dev/null
  [ -n "${ACTIVE_PROCESS_PID_FILE:-}" ] && rm -f "$ACTIVE_PROCESS_PID_FILE"
  ACTIVE_WRAPPER_PID=""
  ACTIVE_PROCESS_PID_FILE=""
}

# shellcheck disable=SC2329  # invoked from the EXIT trap
runner_cleanup() {
  active_process_cleanup
  codex_home_cleanup
  verifier_cleanup
  release_iter_lock
  [ -n "${TURNSTMP:-}" ] && rm -f "$TURNSTMP"
  [ -n "${PROBE_SCRATCH:-}" ] && rm -rf "$PROBE_SCRATCH"
}

# shellcheck disable=SC2329  # invoked from the signal trap
cancel_active_run() {
  local sig="$1" signal_number meta
  [ -n "${ACTIVE_RUN_DIR:-}" ] || return 0
  case "$sig" in HUP) signal_number=1 ;; INT) signal_number=2 ;; TERM) signal_number=15 ;; esac
  meta="$ACTIVE_RUN_DIR/run-meta.json"
  if [ -f "$meta" ]; then
    META_PATH="$meta" RC="$((128 + signal_number))" ENDED="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      DURATION="$(( $(date +%s) - start_epoch ))" "$selfdir/run_lib.py" cancel-run-meta 2>/dev/null
  fi
  discard_derived_outputs "$ACTIVE_RUN_DIR"
  rm -f "$ACTIVE_RUN_DIR/grading.json"
  ACTIVE_RUN_DIR=""
}

# A void withholds the grade, not the evidence. The raw agent stream is the
# only artifact that can explain why a cell voided — a second terminal
# `result` record, an auth rejection, a truncated turn — so it survives while
# every derived artifact is discarded.
discard_derived_outputs() {
  local outdir="$1/outputs"
  [ -d "$outdir" ] || return 0
  find "$outdir" -mindepth 1 -maxdepth 1 \
    ! -name agent-stdout.txt ! -name agent-stderr.txt -exec rm -rf {} + 2>/dev/null
  return 0
}

mark_stage_void() {
  local rundir="$1" status="$2" reason="$3" rc="$4" duration
  duration=$(( $(date +%s) - start_epoch ))
  META_PATH="$rundir/run-meta.json" STATUS="$status" REASON="$reason" RC="$rc" \
    ENDED="$(date -u +%Y-%m-%dT%H:%M:%SZ)" DURATION="$duration" \
    "$selfdir/run_lib.py" mark-stage-void-meta 2>/dev/null
  discard_derived_outputs "$rundir"
  rm -f "$rundir/grading.json"
  verifier_cleanup
  ACTIVE_RUN_DIR=""
  echo "run.sh: $reason. Run marked $status; the raw agent stream is retained, no grading." >&2
}

# shellcheck disable=SC2329  # invoked from HUP, INT, and TERM traps
runner_signal() {
  local sig="$1"
  active_process_cleanup
  cancel_active_run "$sig"
  runner_cleanup
  trap - "$sig"
  kill -s "$sig" "$$"
}

trap 'runner_cleanup' EXIT
trap 'runner_signal HUP' HUP
trap 'runner_signal INT' INT
trap 'runner_signal TERM' TERM

# Subscription-backed authentication only. AUTH_ERR carries a diagnostic that
# names the file and the check that failed, never a credential value — every
# message below stays a path and a field name, nothing read out of the file.

# Requires a claude.ai login with an active subscription: a `claudeAiOauth`
# object carrying a non-empty subscriptionType. An API-key login (billed
# through the console, not a claude.ai plan) has no such object and is
# rejected rather than silently accepted as a fallback.
#
# Current Claude Code CLI versions store this credential in the macOS
# Keychain (service "Claude Code-credentials") rather than the on-disk file
# once a Keychain is available. That storage is global to the machine, not
# namespaced per config dir, so the Keychain fallback below only applies
# when CLAUDE_CONFIG_DIR is unset — the default-location case a real
# operator hits. An explicit CLAUDE_CONFIG_DIR (as every auth test below
# uses, to isolate from the operator's real login) is file-only: it names an
# isolated credentials file, not a request to also consult the machine-wide
# Keychain.
claude_auth_check() {
  local dir cred
  dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  cred="$dir/.credentials.json"
  AUTH_ERR=""
  if [ -f "$cred" ]; then
    if ! CRED_PATH="$cred" "$selfdir/run_lib.py" claude-auth-check-file 2>/dev/null; then
      AUTH_ERR="Claude credentials at $cred are not a claude.ai subscription login (no active subscriptionType) — API-key auth is not accepted"
      return 1
    fi
    return 0
  fi
  if [ -z "${CLAUDE_CONFIG_DIR+set}" ] && [ "$(uname -s)" = "Darwin" ] && command -v security >/dev/null 2>&1; then
    local keychain_json
    keychain_json="$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)"
    if [ -n "$keychain_json" ]; then
      if printf '%s' "$keychain_json" | "$selfdir/run_lib.py" claude-auth-check-stdin 2>/dev/null; then
        return 0
      fi
      AUTH_ERR="Claude credentials in the macOS Keychain (service \"Claude Code-credentials\") are not a claude.ai subscription login (no active subscriptionType) — API-key auth is not accepted"
      return 1
    fi
    AUTH_ERR="no Claude credentials at $cred or in the macOS Keychain — run 'claude login' with a claude.ai account"
    return 1
  fi
  AUTH_ERR="no Claude credentials at $cred — run 'claude login' with a claude.ai account"
  return 1
}

# Requires Codex's own auth.json to record auth_mode "chatgpt": a ChatGPT
# account login, not an API key. Checked before codex_home_setup copies a
# single byte of that file into the disposable home, so a key-mode auth.json
# is never even staged for a run.
codex_auth_check() {
  local dir auth
  dir="${CODEX_HOME:-$HOME/.codex}"
  auth="$dir/auth.json"
  AUTH_ERR=""
  if [ ! -f "$auth" ]; then
    AUTH_ERR="no Codex credentials at $auth — run 'codex login' with a ChatGPT account"
    return 1
  fi
  if ! AUTH_PATH="$auth" "$selfdir/run_lib.py" codex-auth-check 2>/dev/null; then
    AUTH_ERR="Codex credentials at $auth are not auth_mode=chatgpt — API-key auth is not accepted"
    return 1
  fi
  return 0
}

# -> a disposable CODEX_HOME in system temporary storage, seeded with a copy
# of the operator's authentication state (never their session history).
# Codex only sees it while executing a turn, and it is removed on every normal
# or signalled exit. Codex never writes into the operator's normal ~/.codex.
#
# Ownership is registered in CODEX_ACTIVE_HOME immediately after mktemp
# succeeds, before chmod or the copy — not via `x=$(codex_home_setup)`, which
# would run this whole function in a subshell and make that assignment
# invisible to the parent shell's cleanup traps. A cancellation between here
# and the copy still leaves the directory owned and reachable by
# codex_home_cleanup.
codex_home_setup() {
  local real disposable
  if ! codex_auth_check; then
    return 1
  fi
  real="${CODEX_HOME:-$HOME/.codex}"
  disposable=$(mktemp -d "${CODEX_TEMP_PREFIX}XXXXXX") || return 1
  CODEX_ACTIVE_HOME="$disposable"
  chmod 700 "$disposable" || return 1
  cp -p "$real/auth.json" "$disposable/auth.json" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# iteration-metadata lock — a portable, Bash-3.2/macOS-and-Linux mutex around
# run-config.json and arm-map.json. mkdir is atomic on every POSIX filesystem
# this runs on, unlike creating a lockfile with `>`, which can race two
# writers into believing they both created it first.
# ---------------------------------------------------------------------------

acquire_iter_lock() {
  local lockdir="$1" waited=0 owner_pid
  while ! mkdir "$lockdir" 2>/dev/null; do
    owner_pid=""
    [ -f "$lockdir/owner.pid" ] && owner_pid=$(cat "$lockdir/owner.pid" 2>/dev/null)
    case "$owner_pid" in
    *[!0-9]* | "") : ;;
    *)
      # Only a lock whose recorded owner is provably dead is stale. A lock
      # with no owner.pid yet, or a live owner, is left alone — removing
      # either would let a second writer into the same critical section.
      if ! kill -0 "$owner_pid" 2>/dev/null; then
        rm -rf "$lockdir" 2>/dev/null
        continue
      fi
      ;;
    esac
    waited=$((waited + 1))
    if [ "$waited" -ge 300 ]; then
      echo "run.sh: timed out waiting for iteration lock $lockdir" >&2
      return 1
    fi
    sleep 0.1
  done
  echo $$ >"$lockdir/owner.pid" 2>/dev/null
  ACTIVE_ITER_LOCK="$lockdir"
  return 0
}

release_iter_lock() {
  local lockdir="${ACTIVE_ITER_LOCK:-}"
  ACTIVE_ITER_LOCK=""
  [ -n "$lockdir" ] && rm -rf "$lockdir" 2>/dev/null
  return 0
}

# ---------------------------------------------------------------------------
# Claude adapter — one streamed `--input-format stream-json` process for the
# whole session. Every turn's stream-json user message is precomputed before
# the process starts; nothing is generated mid-session and nothing is
# interpolated into a shell command line. --safe-mode keeps Claude's own
# customizations (CLAUDE.md auto-load, skills, plugins) off, so the
# fixture's CLAUDE.md is delivered as a system prompt via
# --append-system-prompt-file instead — never as part of a user message,
# which would otherwise compete with the eval prompt at the same precedence.
# --allowedTools is a closed set: Agent, Skill, plugin, browser and MCP
# capability are excluded by omission, and --strict-mcp-config with an empty
# server map keeps MCP off outright.
# ---------------------------------------------------------------------------

claude_run() {
  local fixdir outdir model effort bin stdout stderr claude_args sysfile inputfile
  local json counts terminals successes invalid rc turntext
  fixdir="$1"; outdir="$2"; model="$3"; effort="$4"; bin="$5"

  stdout="$outdir/agent-stdout.txt"; stderr="$outdir/agent-stderr.txt"
  : >"$stdout"; : >"$stderr"
  inputfile="$outdir/.claude-input.jsonl"
  : >"$inputfile"

  for turntext in "${turns[@]}"; do
    json=$(TXT="$turntext" "$selfdir/run_lib.py" claude-turn-json)
    printf '%s\n' "$json" >>"$inputfile"
  done

  claude_args=(--print --input-format stream-json --output-format stream-json --verbose
               --model "$model" --strict-mcp-config --mcp-config '{"mcpServers":{}}'
               --allowedTools "Read,Write,Edit,Bash" --permission-mode acceptEdits
               --safe-mode --no-session-persistence --no-chrome)
  [ -n "$effort" ] && claude_args+=(--effort "$effort")
  sysfile="$fixdir/CLAUDE.md"
  [ -f "$sysfile" ] && claude_args+=(--append-system-prompt-file "$sysfile")

  if ! claude_auth_check; then
    echo "run.sh: $AUTH_ERR" >&2
    AGENT_FAILURE_STATUS="agent_auth_rejected"
    AGENT_FAILURE_REASON="$AUTH_ERR"
    rm -f "$inputfile"
    return 88
  fi
  if ! agent_identity_check claude before; then
    rm -f "$inputfile"
    return 86
  fi
  run_with_timeout "$TIMEOUT" "$inputfile" "$fixdir" "$outdir/.active-process.pid" \
    "$bin" "${claude_args[@]}" >"$stdout" 2>"$stderr"
  rc=$?
  agent_identity_check claude after || rc=86
  rm -f "$inputfile"

  # A session that ended with fewer results than turns sent — a crash, a
  # dropped continuation — must not report success just because the process
  # itself happened to exit 0.
  counts=$("$selfdir/run_lib.py" claude-count-results "$stdout")
  terminals=${counts%% *}
  counts=${counts#* }
  successes=${counts%% *}
  invalid=${counts##* }
  if [ "$rc" -eq 0 ] \
    && { [ "$terminals" -ne "${#turns[@]}" ] || [ "$successes" -ne "${#turns[@]}" ] || [ "$invalid" -ne 0 ]; }; then
    echo "run.sh: claude stream had $terminals terminal result(s), $successes successful, and $invalid malformed record(s) for ${#turns[@]} turn(s)" >&2
    return 1
  fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# Codex adapter — turn one starts a thread with `codex exec`; every later
# turn resumes that same thread.started id with only the flags `codex exec
# resume` accepts, so the whole eval is one session. --ignore-user-config
# keeps the run off the operator's skills and profiles while a disposable,
# system-temporary CODEX_HOME (copied login state only) keeps it off the
# operator's normal session history too. Every turn's prompt is delivered
# on stdin with the `-` argument, never as a process argument.
# ---------------------------------------------------------------------------

codex_run() {
  local fixdir outdir model effort bin stdout stderr thread_id start_ts codex_home
  local overall_rc turnindex turntext now remaining args turnout rc promptfile terminal_counts
  fixdir="$1"; outdir="$2"; model="$3"; effort="$4"; bin="$5"

  stdout="$outdir/agent-stdout.txt"; stderr="$outdir/agent-stderr.txt"
  : >"$stdout"; : >"$stderr"

  if ! codex_home_setup; then
    if [ -n "${AUTH_ERR:-}" ]; then
      echo "run.sh: $AUTH_ERR" >&2
      AGENT_FAILURE_STATUS="agent_auth_rejected"
      AGENT_FAILURE_REASON="$AUTH_ERR"
    fi
    return 88
  fi
  codex_home="$CODEX_ACTIVE_HOME"

  thread_id=""
  start_ts=$(date +%s)
  overall_rc=0
  turnindex=0

  for turntext in "${turns[@]}"; do
    turnindex=$((turnindex + 1))
    now=$(date +%s)
    remaining=$((TIMEOUT - (now - start_ts)))
    if [ "$remaining" -le 0 ]; then
      echo "run.sh: codex session exceeded ${TIMEOUT}s before turn $turnindex" >&2
      overall_rc=124; break
    fi

    if [ "$turnindex" -eq 1 ]; then
      args=(--ask-for-approval never)
      [ -n "$effort" ] && args+=(-c "model_reasoning_effort=\"$effort\"")
      args+=(exec --json --ignore-user-config --sandbox workspace-write -C "$fixdir" --model "$model")
    else
      if [ -z "$thread_id" ]; then
        echo "run.sh: no codex thread id captured after turn 1 — cannot continue the session" >&2
        overall_rc=1; break
      fi
      args=(exec resume --json --model "$model" "$thread_id")
    fi
    args+=(-)

    promptfile="$outdir/.codex-turn-$turnindex.prompt"
    printf '%s' "$turntext" >"$promptfile"

    turnout="$outdir/.codex-turn-$turnindex.json"
    if ! agent_identity_check codex before; then
      rm -f "$promptfile"
      overall_rc=86
      break
    fi
    CODEX_HOME="$codex_home" run_with_timeout "$remaining" "$promptfile" - \
      "$outdir/.active-process.pid" "$bin" "${args[@]}" >"$turnout" 2>>"$stderr"
    rc=$?
    agent_identity_check codex after || rc=86
    rm -f "$promptfile"
    overall_rc=$rc
    if [ "$rc" -ne 0 ]; then
      cat "$turnout" >>"$stdout" 2>/dev/null
      rm -f "$turnout"
      break
    fi

    # The turn file is preserved until this append succeeds. Canonical
    # stdout is what thread-id capture and trace extraction read next, so a
    # silently dropped append here would make either fail invisibly instead
    # of voiding the run with a status that names what actually happened.
    if ! cat "$turnout" >>"$stdout" 2>>"$stderr"; then
      echo "run.sh: failed to append codex turn $turnindex output to canonical stdout" >&2
      AGENT_FAILURE_STATUS="codex_stream_append_failed"
      AGENT_FAILURE_REASON="failed to append codex turn $turnindex output to canonical stdout"
      overall_rc=1
      break
    fi

    # One Codex process is one requested turn. An exit 0 without exactly one
    # turn.completed event is a dropped turn, including the final turn where
    # there is no later resume attempt to expose it. thread.started is
    # required exactly once on the initial turn; a resume turn may legitimately
    # emit it again, but never more than once and never for a different
    # thread than the one requested. command_execution is only accepted from
    # its start lifecycle event and file_change only from its completion
    # lifecycle event — the shapes trace extraction itself already assumes.
    terminal_counts=$(TURNINDEX="$turnindex" EXPECTED_THREAD="$thread_id" \
      "$selfdir/run_lib.py" codex-terminal-counts "$turnout")
    rm -f "$turnout"
    if [ "$terminal_counts" != "1 0 0 0" ]; then
      echo "run.sh: codex turn $turnindex completed/failed/error/malformed counts were $terminal_counts; expected 1 0 0 0" >&2
      overall_rc=1
      break
    fi

    if [ "$turnindex" -eq 1 ]; then
      thread_id=$("$selfdir/run_lib.py" codex-thread-id "$stdout")
    fi
  done
  codex_home_cleanup
  return "$overall_rc"
}

# ---------------------------------------------------------------------------
# trace + transcript extraction — normalizes each built-in adapter's own
# event shape into the shared Trace event contract: one {"seq","event",
# "tool","action","text"} object per gradeable tool call, "text" canonical
# and fixture-relative — both the fixture root and every event path resolved
# with realpath first, so a /tmp vs /private/tmp or /var vs /private/var
# alias never breaks the match. Assistant final text goes to explicit,
# numbered transcript sections; multiline text stays intact and an empty final
# response has a visible placeholder.
# ---------------------------------------------------------------------------

extract_claude_trace() {
  local rundir fixdir runid runner_root
  rundir="$1"; fixdir="$2"; runid="$3"; runner_root="$4"
  : >"$rundir/outputs/session-transcript.txt"
  "$selfdir/run_lib.py" extract-claude-trace "$rundir/outputs/agent-stdout.txt" \
    "$rundir/outputs/trace.jsonl" "$rundir/outputs/session-transcript.txt" \
    "$fixdir" "$runid" "$runner_root"
}

extract_codex_trace() {
  local rundir fixdir runid runner_root
  rundir="$1"; fixdir="$2"; runid="$3"; runner_root="$4"
  : >"$rundir/outputs/session-transcript.txt"
  "$selfdir/run_lib.py" extract-codex-trace "$rundir/outputs/agent-stdout.txt" \
    "$rundir/outputs/trace.jsonl" "$rundir/outputs/session-transcript.txt" \
    "$fixdir" "$runid" "$runner_root"
}

# ---------------------------------------------------------------------------
# run-config lock — records the comparison design once per iteration
# directory and refuses a later run that would silently move it. Every
# held-constant input — arm variable, repeat budget, and per-agent resolved
# bin path, CLI version, model and effort — is immutable once recorded.
# ---------------------------------------------------------------------------

lock_run_config() {
  local iterdir arm_variable treatment agent arm model corpus_ref repeats bin ver effort cfgfile
  local bin_real bin_hash ver_output
  iterdir="$1"; arm_variable="$2"; treatment="$3"; agent="$4"; arm="$5"; model="$6"
  corpus_ref="$7"; repeats="$8"; bin="$9"; ver="${10}"; effort="${11}"
  bin_real="${12}"; bin_hash="${13}"; ver_output="${14}"
  cfgfile="$iterdir/run-config.json"

  if [ ! -f "$cfgfile" ]; then
    if [ -z "$treatment" ]; then
      echo "run.sh: no run-config.json yet under $iterdir — the first run must name the treatment arm with --treatment-arm <name>. Nothing is guessed from lexical order." >&2
      return 2
    fi
    if [ "$treatment" != "$arm" ]; then
      echo "run.sh: --treatment-arm '$treatment' must equal this run's own --arm '$arm' — the first run into a fresh iteration establishes the treatment by being it, not by naming a different arm." >&2
      return 2
    fi
    IT="$iterdir" AV="$arm_variable" TA="$treatment" AG="$agent" AM="$arm" MD="$model" \
      CR="$corpus_ref" RP="$repeats" AB="$bin" AV2="$ver" AE="$effort" \
      AR="$bin_real" AH="$bin_hash" AO="$ver_output" \
      "$selfdir/run_lib.py" lock-run-config-create || return 2
    return 0
  fi

  IT="$iterdir" AV="$arm_variable" TA="$treatment" AG="$agent" AM="$arm" MD="$model" \
    CR="$corpus_ref" RP="$repeats" AB="$bin" AV2="$ver" AE="$effort" \
    AR="$bin_real" AH="$bin_hash" AO="$ver_output" \
    "$selfdir/run_lib.py" lock-run-config-update
  return $?
}

# ---------------------------------------------------------------------------
# --list-arms — resolved readiness and versions, no model call.
# ---------------------------------------------------------------------------

if [ "${1:-}" = "--list-arms" ]; then
  echo "Agents configured in agents.conf:"

  cmodel=$(conf_get CLAUDE_MODEL); cmodel=${cmodel:-$DEFAULT_CLAUDE_MODEL}
  ceffort=$(conf_get CLAUDE_EFFORT); ceffort=${ceffort:-$DEFAULT_CLAUDE_EFFORT}
  if resolve_claude_bin; then
    v=$(bin_version "$RESOLVED_BIN")
    printf '  claude   bin=%s  version=%s  model=%s  effort=%s\n' \
      "$RESOLVED_BIN" "${v:-unknown}" "$cmodel" "$ceffort"
  else
    printf '  claude   not ready — %s  (model=%s effort=%s)\n' "$RESOLVED_ERR" "$cmodel" "$ceffort"
  fi

  xmodel=$(conf_get CODEX_MODEL); xmodel=${xmodel:-$DEFAULT_CODEX_MODEL}
  xeffort=$(conf_get CODEX_EFFORT); xeffort=${xeffort:-$DEFAULT_CODEX_EFFORT}
  if resolve_codex_bin; then
    v=$(bin_version "$RESOLVED_BIN")
    printf '  codex    bin=%s  version=%s  model=%s  effort=%s\n' \
      "$RESOLVED_BIN" "${v:-unknown}" "$xmodel" "$xeffort"
  else
    printf '  codex    not ready — %s  (model=%s effort=%s)\n' "$RESOLVED_ERR" "$xmodel" "$xeffort"
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# --probe-agent <claude|codex> — one live call through the resolved CLI,
# reporting an authentication or version failure from that invocation.
# ---------------------------------------------------------------------------

if [ "${1:-}" = "--probe-agent" ]; then
  target="${2:-}"
  case "$target" in
  claude | codex) ;;
  *) echo "run.sh: --probe-agent needs 'claude' or 'codex'" >&2; exit 2 ;;
  esac
  command -v python3 >/dev/null 2>&1 || { echo "run.sh: python3 not found" >&2; exit 2; }

  if [ "$target" = claude ]; then
    resolve_claude_bin || { echo "run.sh: claude not ready — $RESOLVED_ERR" >&2; exit 1; }
    model=$(conf_get CLAUDE_MODEL); model=${model:-$DEFAULT_CLAUDE_MODEL}
    effort=$(conf_get CLAUDE_EFFORT); effort=${effort:-$DEFAULT_CLAUDE_EFFORT}
  else
    resolve_codex_bin || { echo "run.sh: codex not ready — $RESOLVED_ERR" >&2; exit 1; }
    model=$(conf_get CODEX_MODEL); model=${model:-$DEFAULT_CODEX_MODEL}
    effort=$(conf_get CODEX_EFFORT); effort=${effort:-$DEFAULT_CODEX_EFFORT}
  fi
  bin="$RESOLVED_BIN"
  ver=$(bin_version "$bin")

  # agent_identity_check compares its "before"/"after" launch snapshot
  # against these globals — populated here the same way the main argument
  # path populates them, so a probe's identity check compares the resolved
  # binary against itself instead of against an empty placeholder.
  agent_bin="$bin"
  agent_bin_real=$(canonical_path "$agent_bin")
  agent_bin_hash=$(file_sha256 "$agent_bin_real")
  agent_ver_output=$(bin_version_output "$agent_bin")

  scratch=$(mktemp -d "${TMPDIR:-/tmp}/dot-agent-eval-probe.XXXXXX") || exit 1
  PROBE_SCRATCH="$scratch"
  outdir="$scratch/outputs"
  mkdir -p "$outdir"
  TIMEOUT="$PROBE_TIMEOUT"
  turns=("Reply with exactly: OK")

  if [ "$target" = claude ]; then
    claude_run "$scratch" "$outdir" "$model" "$effort" "$bin"
  else
    codex_run "$scratch" "$outdir" "$model" "$effort" "$bin"
  fi
  rc=$?

  echo "run.sh: probe $target"
  echo "  bin:     $bin"
  echo "  version: ${ver:-unknown}"
  echo "  model:   $model  effort: $effort"
  if [ "$rc" -eq 0 ]; then
    echo "  result:  PASS (exit 0)"
    exit 0
  fi
  reason=$(tail -n 5 "$outdir/agent-stderr.txt" 2>/dev/null)
  echo "  result:  FAIL (exit $rc)"
  [ -n "$reason" ] && printf '  stderr:  %s\n' "$reason"
  exit 1
fi

case "${1:-}" in -h | --help | "") usage; exit 0 ;; esac

# ---------------------------------------------------------------------------
# main: argument parsing
# ---------------------------------------------------------------------------

evalid=""; arm=""; agent=""; corpus_ref=""; workspace=""; iteration=""; dry=0; treatment=""
while [ $# -gt 0 ]; do
  case "$1" in
  --eval) evalid="${2:-}"; shift 2 ;;
  --arm) arm="${2:-}"; shift 2 ;;
  --agent) agent="${2:-}"; shift 2 ;;
  --corpus-ref) corpus_ref="${2:-}"; shift 2 ;;
  --workspace) workspace="${2:-}"; shift 2 ;;
  --iteration) iteration="${2:-}"; shift 2 ;;
  --treatment-arm) treatment="${2:-}"; shift 2 ;;
  --dry-run) dry=1; shift ;;
  *) echo "run.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

for req in evalid arm agent corpus_ref workspace; do
  v="${!req}"
  [ -n "$v" ] || { echo "run.sh: --${req%id} is required" >&2; usage >&2; exit 2; }
done

command -v python3 >/dev/null 2>&1 || { echo "run.sh: python3 not found" >&2; exit 2; }

entry=$(EVALID="$evalid" SPEC="$spec" "$selfdir/run_lib.py" eval-lookup) || {
  echo "run.sh: no eval with id '$evalid' in spec.json" >&2; exit 2; }

fixture=$(printf '%s' "$entry" | "$selfdir/run_lib.py" fixture-name)

arm_variable=$(printf '%s' "$entry" | SPEC="$spec" "$selfdir/run_lib.py" arm-variable)

# Turns: a "turns" array if the spec entry carries one, else the current
# bootstrap-once " || TURN n: " delimiter split into turns, else the prompt
# as a single turn. NUL-delimited on disk — bash strings cannot hold a NUL.
turnstmp=$(mktemp "${TMPDIR:-/tmp}/dot-agent-eval-turns.XXXXXX") || exit 1
TURNSTMP="$turnstmp"
printf '%s' "$entry" | "$selfdir/run_lib.py" split-turns >"$turnstmp"

turns=()
while IFS= read -r -d '' t; do turns+=("$t"); done <"$turnstmp"
[ "${#turns[@]}" -ge 1 ] || { echo "run.sh: eval '$evalid' produced no turns" >&2; exit 1; }

# ---------------------------------------------------------------------------
# agent identity — direct, argument-safe adapters for claude and codex.
# ---------------------------------------------------------------------------

agent_ver=""; agent_ver_output=""
agent_model=""; agent_effort=""; trace_format="none"
case "$agent" in
claude)
  if resolve_claude_bin; then
    agent_bin="$RESOLVED_BIN"; agent_ver=$(bin_version "$agent_bin")
  elif [ "$dry" -eq 0 ]; then
    echo "run.sh: agent 'claude' is not ready — $RESOLVED_ERR" >&2
    echo "run.sh: --list-arms shows current resolution." >&2
    exit 2
  fi
  agent_model=$(conf_get CLAUDE_MODEL); agent_model=${agent_model:-$DEFAULT_CLAUDE_MODEL}
  agent_effort=$(conf_get CLAUDE_EFFORT); agent_effort=${agent_effort:-$DEFAULT_CLAUDE_EFFORT}
  trace_format="claude-stream-json"
  ;;
codex)
  if resolve_codex_bin; then
    agent_bin="$RESOLVED_BIN"; agent_ver=$(bin_version "$agent_bin")
  elif [ "$dry" -eq 0 ]; then
    echo "run.sh: agent 'codex' is not ready — $RESOLVED_ERR" >&2
    echo "run.sh: --list-arms shows current resolution." >&2
    exit 2
  fi
  agent_model=$(conf_get CODEX_MODEL); agent_model=${agent_model:-$DEFAULT_CODEX_MODEL}
  agent_effort=$(conf_get CODEX_EFFORT); agent_effort=${agent_effort:-$DEFAULT_CODEX_EFFORT}
  trace_format="codex-json"
  ;;
*)
  echo "run.sh: unknown agent '$agent' — use claude or codex" >&2
  exit 2
  ;;
esac

if [ -n "$agent_bin" ]; then
  agent_bin_real=$(canonical_path "$agent_bin")
  agent_bin_hash=$(file_sha256 "$agent_bin_real")
  agent_ver_output=$(bin_version_output "$agent_bin")
fi

# ---------------------------------------------------------------------------
# one iteration, REPEATS run directories under it — REPEATS is a repeat
# budget within a single benchmark iteration, never a driver of separate
# iteration-<n> directories. --iteration selects which iteration this
# invocation targets (default 1); a dry run always does exactly one repeat.
# ---------------------------------------------------------------------------

iteration=${iteration:-1}
iterdir="$workspace/iteration-$iteration"
mkdir -p "$iterdir" || exit 1

# The read-check-write in lock_run_config must run as one atomic unit across
# concurrent invocations targeting the same iteration, not just its final
# write — two processes both seeing "no run-config.json yet" is exactly the
# race a lock this narrow would still allow.
acquire_iter_lock "$iterdir/.metadata.lock" || exit 2
lock_run_config "$iterdir" "$arm_variable" "$treatment" "$agent" "$arm" "$agent_model" \
  "$corpus_ref" "$REPEATS" "$agent_bin" "$agent_ver" "$agent_effort" \
  "$agent_bin_real" "$agent_bin_hash" "$agent_ver_output"
lock_run_config_rc=$?
release_iter_lock
[ "$lock_run_config_rc" -eq 0 ] || exit 2

evaldir="$iterdir/eval-$evalid"
mkdir -p "$evaldir" || exit 1
printf '%s\n' "$entry" | python3 -m json.tool >"$evaldir/eval-snapshot.json"

repeats_eff="$REPEATS"
[ "$dry" -eq 1 ] && repeats_eff=1

any_void=0
rep=1
while [ "$rep" -le "$repeats_eff" ]; do
  runid=$(gen_run_id)
  rundir="$evaldir/$runid"
  if [ -e "$rundir" ]; then
    echo "run.sh: run directory $rundir already exists — refusing to reuse or overwrite it" >&2
    exit 1
  fi
  mkdir -p "$rundir" || exit 1
  start_epoch=$(date +%s)
  RUNID="$runid" EVALID="$evalid" FIXTURE="$fixture" CORPUS_REF="$corpus_ref" \
    AGENT="$agent" AGENT_BIN="${agent_bin:-not resolved}" \
    AGENT_BIN_REAL="${agent_bin_real:-not resolved}" AGENT_BIN_HASH="${agent_bin_hash:-not resolved}" \
    AGENT_VERSION="${agent_ver:-unknown}" AGENT_VERSION_OUTPUT="${agent_ver_output:-unknown}" \
    MODEL="${agent_model:-not recorded}" EFFORT="${agent_effort:-not recorded}" \
    TRACE_FORMAT="$trace_format" TURNS="${#turns[@]}" ARM_VARIABLE="$arm_variable" \
    TIMEOUT_S="$TIMEOUT" REPEATS_PER_CELL="$REPEATS" STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    META_PATH="$rundir/run-meta.json" "$selfdir/run_lib.py" run-meta-init

  acquire_iter_lock "$iterdir/.metadata.lock" || exit 1
  "$selfdir/run_lib.py" arm-map-update "$iterdir/arm-map.json" "$runid" "$arm"
  arm_map_rc=$?
  release_iter_lock
  [ "$arm_map_rc" -eq 0 ] || exit 1

  # Metadata and the arm mapping exist before fixture construction, so a bad
  # corpus ref still leaves a diagnostic run rather than an unshaped directory.
  ACTIVE_RUN_DIR="$rundir"
  fixdir="$rundir/fixture"
  "$selfdir/fixtures.sh" "$fixture" "$fixdir" --corpus-ref "$corpus_ref" \
    >"$rundir/fixture-build.txt" 2>&1
  stage_rc=$?
  if [ "$stage_rc" -ne 0 ]; then
    mark_stage_void "$rundir" fixture_build_failed \
      "fixture build failed (exit $stage_rc)" "$stage_rc"
    any_void=1; rep=$((rep + 1)); continue
  fi
  base=$(git -C "$fixdir" rev-parse HEAD 2>/dev/null)
  stage_rc=$?
  if [ "$stage_rc" -ne 0 ]; then
    mark_stage_void "$rundir" fixture_build_failed \
      "fixture base resolution failed (exit $stage_rc)" "$stage_rc"
    any_void=1; rep=$((rep + 1)); continue
  fi
  META_PATH="$rundir/run-meta.json" FIXTURE_BASE="$base" \
    "$selfdir/run_lib.py" run-meta-set-fixture-base || exit 1
  mkdir -p "$rundir/outputs" || {
    mark_stage_void "$rundir" artifact_capture_failed \
      "could not create outputs directory" 1
    any_void=1; rep=$((rep + 1)); continue
  }

  if [ "$dry" -eq 1 ]; then
    cat <<EOF
run.sh: dry run — nothing was driven.
  eval:     $evalid  (iteration $iteration, repeat $rep of ${repeats_eff})
  fixture:  $fixdir  (base $base)
  agent:    $agent  bin=${agent_bin:-unresolved}  model=${agent_model:-unset}  effort=${agent_effort:-unset}
  trace:    $trace_format
  run dir:  $rundir

Turns, verbatim:
EOF
    n=0
    for t in "${turns[@]}"; do
      n=$((n + 1))
      echo "------------------------------------------------------------------ turn $n"
      printf '%s\n' "$t"
    done
    cat <<EOF
------------------------------------------------------------------

Drive it by hand in the fixture directory, then capture the artifacts into
$rundir/outputs/ and run:
  evals/grade.py $rundir $evaldir/eval-snapshot.json
EOF
    ACTIVE_RUN_DIR=""
    rep=$((rep + 1))
    continue
  fi

  if ! verifier_snapshot "$fixdir"; then
    mark_stage_void "$rundir" verifier_snapshot_failed \
      "trusted verifier snapshot failed" 1
    any_void=1; rep=$((rep + 1)); continue
  fi

  # ACTIVE_RUN_DIR stays available to the signal trap through capture and
  # grading, so cancellation can void metadata and discard partial artifacts.
  AGENT_FAILURE_STATUS=""
  AGENT_FAILURE_REASON=""
  case "$agent" in
  claude) claude_run "$fixdir" "$rundir/outputs" "$agent_model" "$agent_effort" "$agent_bin" ;;
  codex) codex_run "$fixdir" "$rundir/outputs" "$agent_model" "$agent_effort" "$agent_bin" ;;
  esac
  rc=$?

  end_epoch=$(date +%s)
  duration=$((end_epoch - start_epoch))
  end_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  status="ok"
  [ "$rc" -ne 0 ] && status="void"
  [ "$rc" -eq 124 ] && status="timeout"
  [ "$rc" -eq 97 ] && status="process_group_cleanup_failed"
  [ -n "$AGENT_FAILURE_STATUS" ] && status="$AGENT_FAILURE_STATUS"
  META_PATH="$rundir/run-meta.json" RC="$rc" ENDED="$end_ts" DURATION="$duration" \
    STATUS="$status" REASON="$AGENT_FAILURE_REASON" \
    "$selfdir/run_lib.py" run-meta-finalize

  # A run that drove nothing to completion — a timeout, a nonzero exit, a
  # dropped session continuation — must not produce a grading record that
  # reads like one that did, and must make the whole invocation exit
  # nonzero: a silently-void repeat inside an otherwise-clean run is exactly
  # the failure a "did it pass" check on exit status alone must not miss.
  if [ "$rc" -ne 0 ]; then
    reason="agent exited $rc"
    [ "$rc" -eq 124 ] && reason="hit the ${TIMEOUT}s timeout"
    [ "$rc" -eq 127 ] && reason="command not found — check the resolved binary"
    [ "$rc" -eq 97 ] && reason="left live process-group members behind that could not be cleaned up before capture"
    [ -n "$AGENT_FAILURE_REASON" ] && reason="$AGENT_FAILURE_REASON"
    echo "run.sh: $evalid iteration $iteration repeat $rep void — $reason. Raw agent stream retained under outputs/; no grading.json written." >&2
    discard_derived_outputs "$rundir"
    verifier_cleanup
    ACTIVE_RUN_DIR=""
    any_void=1
    rep=$((rep + 1))
    continue
  fi

  # ---- capture the artifact set ------------------------------------------
  git -C "$fixdir" add -A >/dev/null 2>&1
  stage_rc=$?
  if [ "$stage_rc" -ne 0 ]; then
    mark_stage_void "$rundir" artifact_capture_failed \
      "artifact capture failed while staging the fixture (exit $stage_rc)" "$stage_rc"
    any_void=1; rep=$((rep + 1)); continue
  fi
  git -C "$fixdir" diff --cached "$base" -- . ':(exclude).agent' \
    >"$rundir/outputs/diff.patch" 2>/dev/null
  stage_rc=$?
  if [ "$stage_rc" -ne 0 ]; then
    mark_stage_void "$rundir" artifact_capture_failed \
      "artifact capture failed while reading the project diff (exit $stage_rc)" "$stage_rc"
    any_void=1; rep=$((rep + 1)); continue
  fi
  git -C "$fixdir" diff --cached "$base" -- .agent \
    >"$rundir/outputs/node-diff.patch" 2>/dev/null
  stage_rc=$?
  if [ "$stage_rc" -ne 0 ]; then
    mark_stage_void "$rundir" artifact_capture_failed \
      "artifact capture failed while reading the node diff (exit $stage_rc)" "$stage_rc"
    any_void=1; rep=$((rep + 1)); continue
  fi

  node_files="$rundir/outputs/.node-files"
  ( cd "$fixdir" && find .agent -type f -print0 2>/dev/null ) >"$node_files"
  stage_rc=$?
  if [ "$stage_rc" -ne 0 ]; then
    mark_stage_void "$rundir" artifact_capture_failed \
      "artifact capture failed while listing node files (exit $stage_rc)" "$stage_rc"
    any_void=1; rep=$((rep + 1)); continue
  fi
  ( cd "$fixdir" || exit 1
    while IFS= read -r -d '' node_file; do
      printf '== %s\n' "$node_file"
      cat "$node_file" || exit 1
    done <"$node_files"
  ) >"$rundir/outputs/node-tree.txt" 2>/dev/null
  stage_rc=$?
  rm -f "$node_files"
  if [ "$stage_rc" -ne 0 ]; then
    mark_stage_void "$rundir" artifact_capture_failed \
      "artifact capture failed while reading node files (exit $stage_rc)" "$stage_rc"
    any_void=1; rep=$((rep + 1)); continue
  fi

  if ! verifier_integrity_check; then
    mark_stage_void "$rundir" verifier_snapshot_failed \
      "trusted verifier snapshot changed before status capture" 1
    any_void=1; rep=$((rep + 1)); continue
  fi
  # status.sh resolves its own conf relative to the root it is passed — the
  # fixture, not the snapshot directory — so the trusted status.conf is
  # restored into the fixture right before this call, overwriting whatever
  # the agent may have left there. Hashing the snapshot alone would not
  # stop status.sh from reading a mutated fixture-side status.conf.
  if ! verifier_restore_status_conf "$fixdir"; then
    mark_stage_void "$rundir" verifier_snapshot_failed \
      "could not restore the trusted status.conf before status capture" 1
    any_void=1; rep=$((rep + 1)); continue
  fi
  bash "$VERIFIER_ACTIVE_DIR/status.sh" "$fixdir" \
    >"$rundir/outputs/status-after.txt" 2>&1
  stage_rc=$?
  if [ "$stage_rc" -ne 0 ]; then
    mark_stage_void "$rundir" artifact_capture_failed \
      "artifact capture failed while running status.sh (exit $stage_rc)" "$stage_rc"
    any_void=1; rep=$((rep + 1)); continue
  fi

  if [ ! -s "$rundir/outputs/diff.patch" ]; then
    : >"$rundir/outputs/gate.txt"
    stage_rc=0
  else
    if ! verifier_integrity_check; then
      mark_stage_void "$rundir" verifier_snapshot_failed \
        "trusted verifier snapshot changed before comment capture" 1
      any_void=1; rep=$((rep + 1)); continue
    fi
    ( cd "$fixdir" && bash "$VERIFIER_ACTIVE_DIR/comments.sh" "$base" ) \
      >"$rundir/outputs/gate.txt" 2>&1
    stage_rc=$?
  fi
  if [ "$stage_rc" -ne 0 ] && [ "$stage_rc" -ne 1 ]; then
    mark_stage_void "$rundir" artifact_capture_failed \
      "artifact capture failed while running comments.sh (exit $stage_rc)" "$stage_rc"
    any_void=1; rep=$((rep + 1)); continue
  fi

  case "$agent" in
  claude) extract_claude_trace "$rundir" "$fixdir" "$runid" "$selfdir/.." ;;
  codex) extract_codex_trace "$rundir" "$fixdir" "$runid" "$selfdir/.." ;;
  esac
  stage_rc=$?
  if [ "$stage_rc" -ne 0 ]; then
    mark_stage_void "$rundir" trace_extraction_failed \
      "trace extraction failed for $agent (exit $stage_rc)" "$stage_rc"
    any_void=1; rep=$((rep + 1)); continue
  fi

  "$selfdir/grade.py" "$rundir" "$evaldir/eval-snapshot.json"
  stage_rc=$?
  if [ "$stage_rc" -ne 0 ]; then
    mark_stage_void "$rundir" grading_failed \
      "grading failed (exit $stage_rc)" "$stage_rc"
    any_void=1; rep=$((rep + 1)); continue
  fi
  verifier_cleanup
  ACTIVE_RUN_DIR=""

  cat <<EOF

run.sh: $evalid iteration $iteration repeat $rep / arm hidden in arm-map.json / agent $agent (${agent_model:-model not recorded})
  run dir: $rundir
  agent exit: $rc
Run the other arm before reading anything into this. A single arm's pass rate
is not a result.
EOF
  rep=$((rep + 1))
done

[ "$any_void" -ne 0 ] && exit 1
exit 0
