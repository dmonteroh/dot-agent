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
      HELP_TEXT="$help_text" FLAG="$flag" python3 -c '
import os, re, sys
flag = re.escape(os.environ["FLAG"])
text = os.environ["HELP_TEXT"]
sys.exit(0 if re.search(r"(?<![A-Za-z0-9_-])" + flag + r"(?=$|[\s,=<\[])", text) else 1)
' || missing="$missing $surface:$flag"
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
  python3 - "$secs" "$stdinfile" "$cwd" "$pidfile" "$@" <<'PY' &
import os, signal, subprocess, sys, time

secs = float(sys.argv[1])
stdin_path = sys.argv[2]
cwd = None if sys.argv[3] == "-" else sys.argv[3]
pid_path = sys.argv[4]
argv = sys.argv[5:]

stdin_fh = None
if stdin_path != "-":
    stdin_fh = open(stdin_path, "rb")

proc = None

def group_exists():
    try:
        os.killpg(proc.pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True

def terminate_process():
    if proc is None:
        return

    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass

    deadline = time.monotonic() + 5
    while group_exists() and time.monotonic() < deadline:
        proc.poll()
        time.sleep(0.05)
    if group_exists():
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        deadline = time.monotonic() + 5
        while group_exists() and time.monotonic() < deadline:
            proc.poll()
            time.sleep(0.05)

    if proc.poll() is None:
        proc.wait()

def interrupted(signum, _frame):
    terminate_process()
    raise SystemExit(128 + signum)

for handled in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
    signal.signal(handled, interrupted)

proc = subprocess.Popen(argv, stdin=stdin_fh, cwd=cwd, start_new_session=True)
with open(pid_path, "w", encoding="ascii") as pf:
    pf.write(str(proc.pid))
timed_out = False
try:
    rc = proc.wait(timeout=secs)
except subprocess.TimeoutExpired:
    timed_out = True
    terminate_process()
    rc = 124
finally:
    if stdin_fh is not None:
        stdin_fh.close()

if not timed_out:
    # The leader exiting on its own — success or failure — does not reap
    # any process-group member it left running. Clear the group before
    # returning control to the caller's artifact capture, the same way a
    # timeout or a forwarded signal already does above.
    terminate_process()

if group_exists():
    # Cleanup itself failed to clear the group: fail closed rather than
    # report the leader's exit status as if capture were now safe to run
    # against a group that still has live members.
    sys.exit(97)
sys.exit(rc)
PY
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
      DURATION="$(( $(date +%s) - start_epoch ))" python3 -c '
import json, os
path = os.environ["META_PATH"]
m = json.load(open(path, encoding="utf-8"))
m["ended"] = os.environ["ENDED"]
m["exit_status"] = int(os.environ["RC"])
m["duration_seconds"] = int(os.environ["DURATION"])
m["status"] = "cancelled"
m["void"] = True
with open(path, "w", encoding="utf-8") as f:
    json.dump(m, f, indent=2, sort_keys=True)
' 2>/dev/null
  fi
  rm -rf "$ACTIVE_RUN_DIR/outputs"
  rm -f "$ACTIVE_RUN_DIR/grading.json"
  ACTIVE_RUN_DIR=""
}

mark_stage_void() {
  local rundir="$1" status="$2" reason="$3" rc="$4" duration
  duration=$(( $(date +%s) - start_epoch ))
  META_PATH="$rundir/run-meta.json" STATUS="$status" REASON="$reason" RC="$rc" \
    ENDED="$(date -u +%Y-%m-%dT%H:%M:%SZ)" DURATION="$duration" python3 -c '
import json, os
path = os.environ["META_PATH"]
m = json.load(open(path, encoding="utf-8"))
m["ended"] = os.environ["ENDED"]
m["exit_status"] = int(os.environ["RC"])
m["duration_seconds"] = int(os.environ["DURATION"])
m["status"] = os.environ["STATUS"]
m["failure_reason"] = os.environ["REASON"]
m["void"] = True
with open(path, "w", encoding="utf-8") as f:
    json.dump(m, f, indent=2, sort_keys=True)
' 2>/dev/null
  rm -rf "$rundir/outputs"
  rm -f "$rundir/grading.json"
  verifier_cleanup
  ACTIVE_RUN_DIR=""
  echo "run.sh: $reason. Run marked $status; no outputs or grading retained." >&2
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
    if ! CRED_PATH="$cred" python3 -c '
import json, os, sys
try:
    data = json.load(open(os.environ["CRED_PATH"], encoding="utf-8"))
except Exception:
    sys.exit(1)
oauth = data.get("claudeAiOauth")
sub = oauth.get("subscriptionType") if isinstance(oauth, dict) else None
sys.exit(0 if isinstance(sub, str) and sub.strip() else 1)
' 2>/dev/null; then
      AUTH_ERR="Claude credentials at $cred are not a claude.ai subscription login (no active subscriptionType) — API-key auth is not accepted"
      return 1
    fi
    return 0
  fi
  if [ -z "${CLAUDE_CONFIG_DIR+set}" ] && [ "$(uname -s)" = "Darwin" ] && command -v security >/dev/null 2>&1; then
    local keychain_json
    keychain_json="$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)"
    if [ -n "$keychain_json" ]; then
      if printf '%s' "$keychain_json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
oauth = data.get("claudeAiOauth")
sub = oauth.get("subscriptionType") if isinstance(oauth, dict) else None
sys.exit(0 if isinstance(sub, str) and sub.strip() else 1)
' 2>/dev/null; then
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
  if ! AUTH_PATH="$auth" python3 -c '
import json, os, sys
try:
    data = json.load(open(os.environ["AUTH_PATH"], encoding="utf-8"))
except Exception:
    sys.exit(1)
sys.exit(0 if data.get("auth_mode") == "chatgpt" else 1)
' 2>/dev/null; then
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
    json=$(TXT="$turntext" python3 -c '
import json, os
print(json.dumps({"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": os.environ["TXT"]}]}}))
')
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
  counts=$(python3 - "$stdout" <<'PY'
import json, sys
terminals = 0
successes = 0
invalid = 0
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    if not line.strip():
        continue
    try:
        event = json.loads(line)
    except ValueError:
        invalid += 1
        continue
    if not isinstance(event, dict):
        invalid += 1
        continue
    etype = event.get("type")
    if etype == "assistant":
        message = event.get("message")
        content = message.get("content") if isinstance(message, dict) else None
        if not isinstance(content, list):
            invalid += 1
            continue
        for item in content:
            if not isinstance(item, dict):
                invalid += 1
            elif item.get("type") == "tool_use" and (
                    not isinstance(item.get("name"), str) or not item.get("name")
                    or not isinstance(item.get("input"), dict)):
                invalid += 1
    if etype != "result":
        continue
    terminals += 1
    if not isinstance(event.get("subtype"), str) or not isinstance(event.get("is_error"), bool):
        invalid += 1
        continue
    if event.get("subtype") == "success" and event.get("is_error") is False:
        successes += 1
print("%d %d %d" % (terminals, successes, invalid))
PY
)
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
    terminal_counts=$(TURNINDEX="$turnindex" EXPECTED_THREAD="$thread_id" python3 -c '
import json, os, sys
completed = failed = errors = invalid = 0
turnindex = int(os.environ["TURNINDEX"])
expected_thread = os.environ.get("EXPECTED_THREAD", "")
thread_started_ids = []
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    if not line.strip():
        continue
    try:
        event = json.loads(line)
    except ValueError:
        invalid += 1
        continue
    if not isinstance(event, dict):
        invalid += 1
        continue
    etype = event.get("type")
    if etype == "thread.started":
        tid = event.get("thread_id") or event.get("id")
        if not isinstance(tid, str) or not tid:
            invalid += 1
        else:
            thread_started_ids.append(tid)
    if etype in ("item.started", "item.completed"):
        item = event.get("item")
        if not isinstance(item, dict) or not isinstance(item.get("type") or item.get("item_type"), str):
            invalid += 1
        else:
            itype = item.get("type") or item.get("item_type")
            if itype == "command_execution":
                if etype != "item.started":
                    invalid += 1
                elif not isinstance(item.get("command") or item.get("cmd"), str):
                    invalid += 1
            elif itype == "file_change":
                if etype != "item.completed":
                    invalid += 1
                else:
                    changes = item.get("changes")
                    if not isinstance(changes, list) or any(
                            not isinstance(change, dict) or not isinstance(change.get("path"), str)
                            for change in changes):
                        invalid += 1
            elif itype == "agent_message" and not isinstance(item.get("text") or item.get("message") or "", str):
                invalid += 1
    if etype == "turn.completed":
        completed += 1
    elif etype == "turn.failed":
        failed += 1
    elif etype == "error":
        errors += 1
if turnindex == 1:
    if len(thread_started_ids) != 1:
        invalid += 1
else:
    if len(thread_started_ids) > 1:
        invalid += 1
    elif len(thread_started_ids) == 1 and thread_started_ids[0] != expected_thread:
        invalid += 1
print("%d %d %d %d" % (completed, failed, errors, invalid))
' "$turnout")
    rm -f "$turnout"
    if [ "$terminal_counts" != "1 0 0 0" ]; then
      echo "run.sh: codex turn $turnindex completed/failed/error/malformed counts were $terminal_counts; expected 1 0 0 0" >&2
      overall_rc=1
      break
    fi

    if [ "$turnindex" -eq 1 ]; then
      thread_id=$(python3 -c '
import json, sys
tid = ""
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        ev = json.loads(line)
    except ValueError:
        continue
    if ev.get("type") == "thread.started":
        tid = ev.get("thread_id") or ev.get("id") or ""
        break
print(tid)
' "$stdout")
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
  python3 - "$rundir/outputs/agent-stdout.txt" "$rundir/outputs/trace.jsonl" \
    "$rundir/outputs/session-transcript.txt" "$fixdir" "$runid" "$runner_root" <<'PY'
import datetime, json, os, re, sys

src, trace_out, transcript_out, fixdir, run_id, runner_root = sys.argv[1:7]
fixdir_real = os.path.realpath(fixdir)
fixture_roots = sorted({fixdir.rstrip(os.sep), os.path.abspath(fixdir), fixdir_real}, key=len, reverse=True)
runner_roots = sorted({runner_root.rstrip(os.sep), os.path.abspath(runner_root), os.path.realpath(runner_root)}, key=len, reverse=True)

def normalize_text(value):
    value = value or ""

    def root_pattern(root):
        parts = [re.escape(part) for part in root.split(os.sep) if part]
        return r"/+" + r"/+".join(parts)

    for root in fixture_roots:
        pattern = root_pattern(root)
        value = re.sub(pattern + r"/+", "", value)
        value = re.sub(pattern, ".", value)
    for root in runner_roots:
        pattern = root_pattern(root)
        value = re.sub(pattern + r"/+", "<runner-root>/", value)
        value = re.sub(pattern, "<runner-root>", value)
    return value

def relpath(p):
    if not p:
        return p
    ap = p if os.path.isabs(p) else os.path.join(fixdir_real, p)
    ap = os.path.realpath(ap)
    if ap.startswith(fixdir_real + os.sep):
        return ap[len(fixdir_real) + 1:]
    return normalize_text(p)

TOOL_ACTION = {"Read": "read", "Write": "write", "Edit": "write",
               "Bash": "execute", "Grep": "search", "Glob": "search"}

seq = 0
transcript = []
with open(trace_out, "w", encoding="utf-8") as tf:
    for line in open(src, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        etype = ev.get("type")

        # The turn's transcript line is its final result, never an
        # intermediate assistant text block — those can be planning prose
        # the harness itself never treated as the deliverable.
        if etype == "result":
            t = (ev.get("result") or "").strip()
            transcript.append(t)
            continue

        if etype != "assistant":
            continue
        for item in (ev.get("message", {}) or {}).get("content", []) or []:
            if not isinstance(item, dict) or item.get("type") != "tool_use":
                continue
            name = item.get("name", "")
            inp = item.get("input", {}) or {}
            action = TOOL_ACTION.get(name, "other")
            rec = {"seq": seq, "event": "call", "tool": name, "action": action,
                   "timestamp": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
                   "run_id": run_id}
            if action in ("read", "write", "search"):
                path = relpath(inp.get("file_path") or inp.get("path") or inp.get("pattern") or "")
                rec["text"] = "%s:%s" % (action, path) if path else "%s:%s" % (action, name)
                if path:
                    rec["path"] = path
            elif action == "execute":
                command = normalize_text(inp.get("command", ""))
                rec["text"] = "execute:%s" % command
                rec["command"] = command
            else:
                rec["text"] = "other:%s" % name
            tf.write(json.dumps(rec) + "\n")
            seq += 1

with open(transcript_out, "a", encoding="utf-8") as xf:
    for n, t in enumerate(transcript, 1):
        xf.write("## Turn %d\n" % n)
        xf.write((t if t else "[empty final response]") + "\n\n")
PY
}

extract_codex_trace() {
  local rundir fixdir runid runner_root
  rundir="$1"; fixdir="$2"; runid="$3"; runner_root="$4"
  : >"$rundir/outputs/session-transcript.txt"
  python3 - "$rundir/outputs/agent-stdout.txt" "$rundir/outputs/trace.jsonl" \
    "$rundir/outputs/session-transcript.txt" "$fixdir" "$runid" "$runner_root" <<'PY'
import datetime, json, os, re, sys

src, trace_out, transcript_out, fixdir, run_id, runner_root = sys.argv[1:7]
fixdir_real = os.path.realpath(fixdir)
fixture_roots = sorted({fixdir.rstrip(os.sep), os.path.abspath(fixdir), fixdir_real}, key=len, reverse=True)
runner_roots = sorted({runner_root.rstrip(os.sep), os.path.abspath(runner_root), os.path.realpath(runner_root)}, key=len, reverse=True)

def normalize_text(value):
    value = value or ""

    def root_pattern(root):
        parts = [re.escape(part) for part in root.split(os.sep) if part]
        return r"/+" + r"/+".join(parts)

    for root in fixture_roots:
        pattern = root_pattern(root)
        value = re.sub(pattern + r"/+", "", value)
        value = re.sub(pattern, ".", value)
    for root in runner_roots:
        pattern = root_pattern(root)
        value = re.sub(pattern + r"/+", "<runner-root>/", value)
        value = re.sub(pattern, "<runner-root>", value)
    return value

def relpath(p):
    if not p:
        return p
    ap = p if os.path.isabs(p) else os.path.join(fixdir_real, p)
    ap = os.path.realpath(ap)
    if ap.startswith(fixdir_real + os.sep):
        return ap[len(fixdir_real) + 1:]
    return normalize_text(p)

def ts():
    return datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")

seq = 0
transcript = []
last_agent_message = None
with open(trace_out, "w", encoding="utf-8") as tf:
    for line in open(src, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        etype = ev.get("type")

        if etype == "turn.completed":
            # The last agent_message seen before this turn closes is that
            # turn's deliverable; nothing before it and nothing after.
            transcript.append(last_agent_message or "")
            last_agent_message = None
            continue

        item = ev.get("item") if isinstance(ev.get("item"), dict) else None
        if item is None:
            continue
        itype = item.get("item_type") or item.get("type")

        if etype == "item.completed" and itype == "agent_message":
            t = (item.get("text") or item.get("message") or "").strip()
            if t:
                last_agent_message = t
            continue

        # Current Codex emits command execution when it starts and file
        # changes only when they complete. Normalize each on that lifecycle.
        if etype == "item.started" and itype == "command_execution":
            command = normalize_text(item.get("command") or item.get("cmd") or "")
            rec = {"seq": seq, "event": "call", "tool": "codex.command_execution",
                   "action": "execute", "text": "execute:%s" % command, "command": command,
                   "timestamp": ts(), "run_id": run_id}
            tf.write(json.dumps(rec) + "\n")
            seq += 1
        elif etype == "item.completed" and itype == "file_change":
            for chg in item.get("changes") or []:
                if not isinstance(chg, dict):
                    continue
                path = relpath(chg.get("path") or "")
                kind = (chg.get("kind") or "modify").lower()
                action = "read" if kind == "read" else "write"
                rec = {"seq": seq, "event": "call", "tool": "codex.file_change",
                       "action": action, "text": "%s:%s" % (action, path), "path": path,
                       "timestamp": ts(), "run_id": run_id}
                tf.write(json.dumps(rec) + "\n")
                seq += 1

with open(transcript_out, "a", encoding="utf-8") as xf:
    for n, t in enumerate(transcript, 1):
        xf.write("## Turn %d\n" % n)
        xf.write((t if t else "[empty final response]") + "\n\n")
PY
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
      AR="$bin_real" AH="$bin_hash" AO="$ver_output" python3 -c '
import json, os
av = os.environ["AV"]
cfg = {
    "treatment_arm": os.environ["TA"],
    "arm_variable": av,
    "locked_agent": os.environ["AG"] if av == "corpus" else None,
    "locked_model": os.environ["MD"] if av == "corpus" else None,
    "locked_corpus_ref": os.environ["CR"] if av == "agent" else None,
    "repeats_per_cell": int(os.environ["RP"]),
    "arms": {
        os.environ["AM"]: {"agent": os.environ["AG"], "corpus_ref": os.environ["CR"],
                            "model": os.environ["MD"], "effort": os.environ["AE"] or None}
    },
    "resolved": {
        os.environ["AG"]: {"bin": os.environ["AB"] or None,
                            "bin_realpath": os.environ["AR"] or None,
                            "bin_sha256": os.environ["AH"] or None,
                            "version": os.environ["AV2"] or None,
                            "version_output": os.environ["AO"] or None,
                            "model": os.environ["MD"], "effort": os.environ["AE"] or None}
    },
}
path = os.path.join(os.environ["IT"], "run-config.json")
tmp = path + ".tmp-%d" % os.getpid()
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, sort_keys=True)
os.replace(tmp, path)
' || return 2
    return 0
  fi

  IT="$iterdir" AV="$arm_variable" TA="$treatment" AG="$agent" AM="$arm" MD="$model" \
    CR="$corpus_ref" RP="$repeats" AB="$bin" AV2="$ver" AE="$effort" \
    AR="$bin_real" AH="$bin_hash" AO="$ver_output" python3 -c '
import json, os, sys
path = os.path.join(os.environ["IT"], "run-config.json")
cfg = json.load(open(path, encoding="utf-8"))
errs = []
ta = os.environ.get("TA")
if ta and ta != cfg["treatment_arm"]:
    errs.append("treatment arm %r != recorded %r" % (ta, cfg["treatment_arm"]))
if os.environ["AV"] != cfg["arm_variable"]:
    errs.append("arm variable %r != recorded %r" % (os.environ["AV"], cfg["arm_variable"]))
if int(os.environ["RP"]) != cfg["repeats_per_cell"]:
    errs.append("repeat budget %s != recorded %s" % (os.environ["RP"], cfg["repeats_per_cell"]))
if cfg["arm_variable"] == "corpus":
    if os.environ["AG"] != cfg["locked_agent"]:
        errs.append("agent %r != recorded %r for a corpus-variable comparison" % (os.environ["AG"], cfg["locked_agent"]))
    if os.environ["MD"] != cfg["locked_model"]:
        errs.append("model %r != recorded %r for a corpus-variable comparison" % (os.environ["MD"], cfg["locked_model"]))
else:
    if os.environ["CR"] != cfg["locked_corpus_ref"]:
        errs.append("corpus-ref (target revision) %r != recorded %r for an agent-variable comparison" % (os.environ["CR"], cfg["locked_corpus_ref"]))
resolved = cfg.setdefault("resolved", {})
ag = os.environ["AG"]
arms = cfg.setdefault("arms", {})
arm = os.environ["AM"]
arm_entry = {"agent": ag, "corpus_ref": os.environ["CR"],
             "model": os.environ["MD"], "effort": os.environ["AE"] or None}
prior_arm = arms.get(arm)
if prior_arm is not None and prior_arm != arm_entry:
    errs.append("arm %r configuration drifted: %r != recorded %r" % (arm, arm_entry, prior_arm))
new_entry = {"bin": os.environ["AB"] or None,
             "bin_realpath": os.environ["AR"] or None,
             "bin_sha256": os.environ["AH"] or None,
             "version": os.environ["AV2"] or None,
             "version_output": os.environ["AO"] or None,
             "model": os.environ["MD"], "effort": os.environ["AE"] or None}
prior = resolved.get(ag)
if prior is not None and prior != new_entry:
    errs.append("resolved %s configuration drifted: %r != recorded %r — binary identity, CLI version, model and effort are held constant for the life of this iteration" % (ag, new_entry, prior))
if errs:
    sys.stderr.write("run.sh: this run violates the comparison recorded in %s:\n" % path)
    for e in errs:
        sys.stderr.write("  - %s\n" % e)
    sys.exit(2)
resolved[ag] = new_entry
arms[arm] = arm_entry
tmp = path + ".tmp-%d" % os.getpid()
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, sort_keys=True)
os.replace(tmp, path)
'
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

entry=$(EVALID="$evalid" SPEC="$spec" python3 -c '
import json, os, sys
spec = json.load(open(os.environ["SPEC"], encoding="utf-8"))
for e in spec["evals"]:
    if e["id"] == os.environ["EVALID"]:
        json.dump(e, sys.stdout); break
else:
    sys.exit(1)') || {
  echo "run.sh: no eval with id '$evalid' in spec.json" >&2; exit 2; }

fixture=$(printf '%s' "$entry" | python3 -c 'import json,sys; print(json.load(sys.stdin)["fixture"])')

arm_variable=$(printf '%s' "$entry" | SPEC="$spec" python3 -c '
import json, os, sys
e = json.load(sys.stdin)
default = json.load(open(os.environ["SPEC"], encoding="utf-8"))["arms"]["variable"]
print(e.get("arm_variable") or default)
')

# Turns: a "turns" array if the spec entry carries one, else the current
# bootstrap-once " || TURN n: " delimiter split into turns, else the prompt
# as a single turn. NUL-delimited on disk — bash strings cannot hold a NUL.
turnstmp=$(mktemp "${TMPDIR:-/tmp}/dot-agent-eval-turns.XXXXXX") || exit 1
TURNSTMP="$turnstmp"
printf '%s' "$entry" | python3 -c '
import json, re, sys
e = json.load(sys.stdin)
turns = e.get("turns")
if not turns:
    prompt = e.get("prompt", "")
    if " || " in prompt:
        parts = [p.strip() for p in prompt.split(" || ")]
        turns = [re.sub(r"^TURN\s+\d+:\s*", "", p) for p in parts]
    else:
        turns = [prompt]
sys.stdout.buffer.write(("\0".join(turns) + "\0").encode("utf-8"))
' >"$turnstmp"

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
    META_PATH="$rundir/run-meta.json" python3 -c '
import json, os
cfg = {
    "run_id": os.environ["RUNID"],
    "eval": os.environ["EVALID"],
    "fixture": os.environ["FIXTURE"],
    "fixture_base": None,
    "corpus_ref": os.environ["CORPUS_REF"],
    "agent": os.environ["AGENT"],
    "agent_bin": os.environ["AGENT_BIN"],
    "agent_bin_realpath": os.environ["AGENT_BIN_REAL"],
    "agent_bin_sha256": os.environ["AGENT_BIN_HASH"],
    "agent_version": os.environ["AGENT_VERSION"],
    "agent_version_output": os.environ["AGENT_VERSION_OUTPUT"],
    "model": os.environ["MODEL"],
    "effort": os.environ["EFFORT"],
    "trace_format": os.environ["TRACE_FORMAT"],
    "turns": int(os.environ["TURNS"]),
    "arm_variable": os.environ["ARM_VARIABLE"],
    "timeout_s": int(os.environ["TIMEOUT_S"]),
    "repeats_per_cell": int(os.environ["REPEATS_PER_CELL"]),
    "started": os.environ["STARTED"],
    "status": "building_fixture",
}
with open(os.environ["META_PATH"], "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, sort_keys=True)
'

  acquire_iter_lock "$iterdir/.metadata.lock" || exit 1
  python3 - "$iterdir/arm-map.json" "$runid" "$arm" <<'PY'
import json, os, sys
path, runid, arm = sys.argv[1], sys.argv[2], sys.argv[3]
m = json.load(open(path, encoding="utf-8")) if os.path.exists(path) else {}
m[runid] = arm
tmp = path + ".tmp-%d" % os.getpid()
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(m, f, indent=2, sort_keys=True)
os.replace(tmp, path)
PY
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
  META_PATH="$rundir/run-meta.json" FIXTURE_BASE="$base" python3 -c '
import json, os
path = os.environ["META_PATH"]
m = json.load(open(path, encoding="utf-8"))
m["fixture_base"] = os.environ["FIXTURE_BASE"]
m["status"] = "running"
with open(path, "w", encoding="utf-8") as f:
    json.dump(m, f, indent=2, sort_keys=True)
' || exit 1
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
    STATUS="$status" REASON="$AGENT_FAILURE_REASON" python3 -c '
import json, os
path = os.environ["META_PATH"]
m = json.load(open(path, encoding="utf-8"))
m["ended"] = os.environ["ENDED"]
m["exit_status"] = int(os.environ["RC"])
m["duration_seconds"] = int(os.environ["DURATION"])
m["status"] = os.environ["STATUS"]
m["void"] = int(os.environ["RC"]) != 0
if os.environ["REASON"]:
    m["failure_reason"] = os.environ["REASON"]
with open(path, "w", encoding="utf-8") as f:
    json.dump(m, f, indent=2, sort_keys=True)
'

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
    echo "run.sh: $evalid iteration $iteration repeat $rep void — $reason. No artifacts captured, no grading.json written." >&2
    rm -rf "$rundir/outputs"
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
