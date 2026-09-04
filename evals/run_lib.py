#!/usr/bin/env python3
"""evals/run_lib.py — the Python logic run.sh drives, as a module rather than
a scatter of `python3 -c` one-liners and heredocs embedded in bash strings.

run.sh stays the orchestrator: control flow, exit codes, locking, and
cleanup ordering all live there. Every subcommand here is a direct
extraction of one previously-inline block, with the same inputs (argv,
environment variable, or stdin — whichever the original block used, kept
exactly as it was) and the same output contract (stdout text, exit code, or
JSON file written). Untrusted or arbitrary-shaped content — eval turn text,
agent stdout, credential JSON, CLI help/version output — is never accepted
as a positional argument; it arrives the same way it always did, on stdin or
in an environment variable, so it never has to survive being built into a
shell command line.

Full documentation: evals/README.md.

Usage: run_lib.py <subcommand> [args...]
"""

import datetime
import hashlib
import json
import os
import re
import secrets
import signal
import subprocess
import sys
import time

USAGE = """Usage: run_lib.py <subcommand> [args...]

Subcommands (one per extracted run.sh block; see run.sh for call sites):
  bin-version                            stdin: version text  -> stdout: token
  canonical-path <path>
  file-sha256 <path>
  gen-run-id
  codex-flag-check                       env: HELP_TEXT, FLAG
  run-with-timeout <secs> <stdinfile> <cwd> <pidfile> <argv...>
  cancel-run-meta                        env: META_PATH, RC, ENDED, DURATION
  mark-stage-void-meta                   env: META_PATH, STATUS, REASON, RC, ENDED, DURATION
  claude-auth-check-file                 env: CRED_PATH
  claude-auth-check-stdin                stdin: credential JSON
  codex-auth-check                       env: AUTH_PATH
  claude-turn-json                       env: TXT
  claude-count-results <stdout-path>     -> "<terminals> <successes> <invalid> <injected>"
  codex-terminal-counts <turnout-path>   env: TURNINDEX, EXPECTED_THREAD
  codex-thread-id <stdout-path>
  extract-claude-trace <src> <trace-out> <transcript-out> <fixdir> <runid> <runner-root>
  extract-codex-trace <src> <trace-out> <transcript-out> <fixdir> <runid> <runner-root>
  lock-run-config-create                 env: IT AV TA AG AM MD CR RP AB AV2 AE AR AH AO HM
  lock-run-config-update                 env: IT AV TA AG AM MD CR RP AB AV2 AE AR AH AO HM
  eval-lookup                            env: EVALID, SPEC
  fixture-name                           stdin: eval entry JSON
  arm-variable                           env: SPEC   stdin: eval entry JSON
  split-turns                            stdin: eval entry JSON
  arm-map-update <path> <runid> <arm>
  run-meta-init                          env: RUNID EVALID FIXTURE CORPUS_REF AGENT
                                               AGENT_BIN AGENT_BIN_REAL AGENT_BIN_HASH
                                               AGENT_VERSION AGENT_VERSION_OUTPUT MODEL
                                               EFFORT TRACE_FORMAT TURNS ARM_VARIABLE
                                               TIMEOUT_S REPEATS_PER_CELL STARTED META_PATH
  run-meta-set-fixture-base              env: META_PATH, FIXTURE_BASE
  agent-usage <stdout-path> <trace-format>  trace-format: claude-stream-json | codex-json
                                             -> stdout: JSON usage totals (null fields, not 0,
                                                for anything the stream never reported)
  run-meta-set-usage                     env: META_PATH   stdin: JSON from agent-usage
  run-meta-finalize                      env: META_PATH RC ENDED DURATION STATUS REASON
"""


def die(msg):
    sys.stderr.write("run_lib.py: %s\n" % msg)
    sys.exit(2)


# ---------------------------------------------------------------------------
# small utilities
# ---------------------------------------------------------------------------

def cmd_bin_version(args):
    t = sys.stdin.read()
    m = re.search(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.]+)?", t)
    print(m.group(0) if m else "")
    return 0


def cmd_canonical_path(args):
    print(os.path.realpath(args[0]))
    return 0


def cmd_file_sha256(args):
    h = hashlib.sha256()
    with open(args[0], "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    print(h.hexdigest())
    return 0


def cmd_gen_run_id(args):
    print("r" + secrets.token_hex(16))
    return 0


# ---------------------------------------------------------------------------
# executable resolution
# ---------------------------------------------------------------------------

def cmd_codex_flag_check(args):
    flag = re.escape(os.environ["FLAG"])
    text = os.environ["HELP_TEXT"]
    return 0 if re.search(r"(?<![A-Za-z0-9_-])" + flag + r"(?=$|[\s,=<\[])", text) else 1


# ---------------------------------------------------------------------------
# portable timeout — Python process groups, so a kill reaches every
# descendant a driven CLI spawned, not just the process run.sh started
# directly. No GNU coreutils; works on a stock macOS and on Linux.
#
# Runs argv as the leader of a new session (Python's start_new_session), so
# a timeout's kill -TERM/-KILL reaches the whole process group. Exit 124
# marks a timeout, the same convention GNU timeout uses. run.sh backgrounds
# this subcommand with `&` and reaps it with `wait`, so a signal delivered to
# run.sh still reaches this process through the same job-control machinery a
# plain background child would use.
# ---------------------------------------------------------------------------

def cmd_run_with_timeout(args):
    secs = float(args[0])
    stdin_path = args[1]
    cwd = None if args[2] == "-" else args[2]
    pid_path = args[3]
    argv = args[4:]

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


# ---------------------------------------------------------------------------
# run-meta.json mutation — cancellation and void-stage marking
# ---------------------------------------------------------------------------

def cmd_cancel_run_meta(args):
    path = os.environ["META_PATH"]
    m = json.load(open(path, encoding="utf-8"))
    m["ended"] = os.environ["ENDED"]
    m["exit_status"] = int(os.environ["RC"])
    m["duration_seconds"] = int(os.environ["DURATION"])
    m["status"] = "cancelled"
    m["void"] = True
    with open(path, "w", encoding="utf-8") as f:
        json.dump(m, f, indent=2, sort_keys=True)
    return 0


def cmd_mark_stage_void_meta(args):
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
    return 0


# ---------------------------------------------------------------------------
# subscription-backed auth checks. Credential content stays off argv: the
# file-based check takes only a path (env CRED_PATH), and the Keychain check
# reads the JSON itself on stdin — the credential value is never a command
# line or an environment variable that a process listing could expose.
# ---------------------------------------------------------------------------

def _oauth_subscription_ok(data):
    oauth = data.get("claudeAiOauth")
    sub = oauth.get("subscriptionType") if isinstance(oauth, dict) else None
    return isinstance(sub, str) and bool(sub.strip())


def cmd_claude_auth_check_file(args):
    try:
        data = json.load(open(os.environ["CRED_PATH"], encoding="utf-8"))
    except Exception:
        return 1
    return 0 if _oauth_subscription_ok(data) else 1


def cmd_claude_auth_check_stdin(args):
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 1
    return 0 if _oauth_subscription_ok(data) else 1


def cmd_codex_auth_check(args):
    try:
        data = json.load(open(os.environ["AUTH_PATH"], encoding="utf-8"))
    except Exception:
        return 1
    return 0 if data.get("auth_mode") == "chatgpt" else 1


# ---------------------------------------------------------------------------
# Claude adapter
# ---------------------------------------------------------------------------

def cmd_claude_turn_json(args):
    print(json.dumps({"type": "user", "message": {"role": "user",
          "content": [{"type": "text", "text": os.environ["TXT"]}]}}))
    return 0


def _claude_result_is_injected(event):
    """True for a result that closes a turn the harness did not send.

    Claude Code emits one top-level `result` per turn its main loop ran, and
    that is not the same as one per turn fed in over --input-format
    stream-json. A session that dispatches a background subagent gets the
    agent's completion delivered back as a turn of its own: a fresh
    system/init, its own assistant messages, and its own `result`. Counting
    those as turn boundaries voided `groom-acts-on-flags` for doing exactly
    what the eval asks of it (2 terminal results for 1 turn sent, both
    successful) — a false positive in the crash detector, not a failure.

    The turn's initiator is on the result itself, in `origin.kind`: an
    injected continuation carries "task-notification" (also "auto-continuation",
    "channel", "peer" and friends), while a turn this harness wrote onto the
    CLI's stdin carries no `origin` at all. Verified against claude 2.1.245:
    one prompt that launched a background Agent produced two success results,
    the second and only the second carrying {"origin": {"kind":
    "task-notification"}}. Anything with an origin other than a plain human
    turn came from somewhere other than our input stream.
    """
    origin = event.get("origin")
    if not isinstance(origin, dict):
        return False
    return origin.get("kind") not in (None, "human")


def cmd_claude_count_results(args):
    terminals = 0
    successes = 0
    invalid = 0
    injected = 0
    for line in open(args[0], encoding="utf-8", errors="replace"):
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
        # Shape is checked on every result, ours or injected: a malformed one
        # is evidence about the stream itself, whoever's turn it closed.
        malformed = (not isinstance(event.get("subtype"), str)
                     or not isinstance(event.get("is_error"), bool))
        if malformed:
            invalid += 1
        if _claude_result_is_injected(event):
            injected += 1
            continue
        terminals += 1
        if malformed:
            continue
        if event.get("subtype") == "success" and event.get("is_error") is False:
            successes += 1
    print("%d %d %d %d" % (terminals, successes, invalid, injected))
    return 0


# ---------------------------------------------------------------------------
# Codex adapter
# ---------------------------------------------------------------------------

def cmd_codex_terminal_counts(args):
    completed = failed = errors = invalid = 0
    turnindex = int(os.environ["TURNINDEX"])
    expected_thread = os.environ.get("EXPECTED_THREAD", "")
    thread_started_ids = []
    for line in open(args[0], encoding="utf-8", errors="replace"):
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
    return 0


def cmd_codex_thread_id(args):
    tid = ""
    for line in open(args[0], encoding="utf-8", errors="replace"):
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
    return 0


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

def _root_pattern(root):
    parts = [re.escape(part) for part in root.split(os.sep) if part]
    return r"/+" + r"/+".join(parts)


def _root_aliases(root):
    """Every spelling one root can wear: as given, absolute, resolved, and
    both sides of macOS's /private alias. normalize_text matches literally,
    so a root it was never told about is a root it cannot strip."""
    out = {root.rstrip(os.sep), os.path.abspath(root), os.path.realpath(root)}
    for r in list(out):
        if r.startswith("/private/"):
            out.add(r[len("/private"):])
        else:
            out.add("/private" + r)
    return sorted({r for r in out if r and r != "/"}, key=len, reverse=True)


_NODE_PATH_RE = re.compile(r"(?:^|\s)/\S*/\.agent/")


def _reject_absolute(rec):
    for field in ("text", "path", "command"):
        v = rec.get(field)
        if isinstance(v, str) and _NODE_PATH_RE.search(v):
            die("trace record %d still carries an absolute node path (%s=%r) — "
                "the fixture root was not stripped, and a grader cannot read "
                "a path it cannot match" % (rec["seq"], field, v[:200]))


def _normalize_text_fn(fixture_roots, runner_roots):
    def normalize_text(value):
        value = value or ""
        for root in fixture_roots:
            pattern = _root_pattern(root)
            value = re.sub(pattern + r"/+", "", value)
            value = re.sub(pattern, ".", value)
        for root in runner_roots:
            pattern = _root_pattern(root)
            value = re.sub(pattern + r"/+", "<runner-root>/", value)
            value = re.sub(pattern, "<runner-root>", value)
        return value
    return normalize_text


def cmd_extract_claude_trace(args):
    src, trace_out, transcript_out, fixdir, run_id, runner_root = args[:6]
    fixdir_real = os.path.realpath(fixdir)
    fixture_roots = _root_aliases(fixdir)
    runner_roots = _root_aliases(runner_root)
    normalize_text = _normalize_text_fn(fixture_roots, runner_roots)

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
                    path = normalize_text(relpath(inp.get("file_path") or inp.get("path") or inp.get("pattern") or ""))
                    rec["text"] = normalize_text("%s:%s" % (action, path) if path else "%s:%s" % (action, name))
                    if path:
                        rec["path"] = path
                elif action == "execute":
                    command = normalize_text(inp.get("command", ""))
                    rec["text"] = "execute:%s" % command
                    rec["command"] = command
                else:
                    rec["text"] = "other:%s" % name
                _reject_absolute(rec)
                tf.write(json.dumps(rec) + "\n")
                seq += 1

    with open(transcript_out, "a", encoding="utf-8") as xf:
        for n, t in enumerate(transcript, 1):
            xf.write("## Turn %d\n" % n)
            xf.write((t if t else "[empty final response]") + "\n\n")
    return 0


def cmd_extract_codex_trace(args):
    src, trace_out, transcript_out, fixdir, run_id, runner_root = args[:6]
    fixdir_real = os.path.realpath(fixdir)
    fixture_roots = _root_aliases(fixdir)
    runner_roots = _root_aliases(runner_root)
    normalize_text = _normalize_text_fn(fixture_roots, runner_roots)

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
                _reject_absolute(rec)
                tf.write(json.dumps(rec) + "\n")
                seq += 1
            elif etype == "item.completed" and itype == "file_change":
                for chg in item.get("changes") or []:
                    if not isinstance(chg, dict):
                        continue
                    path = normalize_text(relpath(chg.get("path") or ""))
                    kind = (chg.get("kind") or "modify").lower()
                    action = "read" if kind == "read" else "write"
                    rec = {"seq": seq, "event": "call", "tool": "codex.file_change",
                           "action": action, "text": normalize_text("%s:%s" % (action, path)), "path": path,
                           "timestamp": ts(), "run_id": run_id}
                    _reject_absolute(rec)
                    tf.write(json.dumps(rec) + "\n")
                    seq += 1

    with open(transcript_out, "a", encoding="utf-8") as xf:
        for n, t in enumerate(transcript, 1):
            xf.write("## Turn %d\n" % n)
            xf.write((t if t else "[empty final response]") + "\n\n")
    return 0


# ---------------------------------------------------------------------------
# run-config lock — records the comparison design once per iteration
# directory and refuses a later run that would silently move it. Every
# held-constant input — arm variable, repeat budget, and per-agent resolved
# bin path, CLI version, model and effort — is immutable once recorded.
# ---------------------------------------------------------------------------

def cmd_lock_run_config_create(args):
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
                                "model": os.environ["MD"], "effort": os.environ["AE"] or None,
                                "harness": os.environ.get("HM") or "node"}
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
    return 0


def cmd_lock_run_config_update(args):
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
                 "model": os.environ["MD"], "effort": os.environ["AE"] or None,
                 "harness": os.environ.get("HM") or "node"}
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
        return 2
    resolved[ag] = new_entry
    arms[arm] = arm_entry
    tmp = path + ".tmp-%d" % os.getpid()
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2, sort_keys=True)
    os.replace(tmp, path)
    return 0


# ---------------------------------------------------------------------------
# eval-spec entry lookup, fixture name, arm variable, and turn splitting
# ---------------------------------------------------------------------------

def cmd_eval_lookup(args):
    spec = json.load(open(os.environ["SPEC"], encoding="utf-8"))
    for e in spec["evals"]:
        if e["id"] == os.environ["EVALID"]:
            json.dump(e, sys.stdout)
            return 0
    return 1


def cmd_fixture_name(args):
    print(json.load(sys.stdin)["fixture"])
    return 0


def cmd_arm_variable(args):
    e = json.load(sys.stdin)
    default = json.load(open(os.environ["SPEC"], encoding="utf-8"))["arms"]["variable"]
    print(e.get("arm_variable") or default)
    return 0


def cmd_split_turns(args):
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
    return 0


def cmd_arm_map_update(args):
    path, runid, arm = args[0], args[1], args[2]
    m = json.load(open(path, encoding="utf-8")) if os.path.exists(path) else {}
    m[runid] = arm
    tmp = path + ".tmp-%d" % os.getpid()
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(m, f, indent=2, sort_keys=True)
    os.replace(tmp, path)
    return 0


# ---------------------------------------------------------------------------
# run-meta.json construction and updates
# ---------------------------------------------------------------------------

def cmd_run_meta_init(args):
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
    return 0


def cmd_run_meta_set_fixture_base(args):
    path = os.environ["META_PATH"]
    m = json.load(open(path, encoding="utf-8"))
    m["fixture_base"] = os.environ["FIXTURE_BASE"]
    m["status"] = "running"
    with open(path, "w", encoding="utf-8") as f:
        json.dump(m, f, indent=2, sort_keys=True)
    return 0


_USAGE_FIELDS = ("input_tokens", "cache_creation_input_tokens",
                  "cache_read_input_tokens", "output_tokens", "usd")


def cmd_agent_usage(args):
    # One pass over the canonical stdout, whichever adapter wrote it. A field
    # no record carried is null, never 0 — a 0 claims the run used nothing, a
    # null admits the CLI never reported the field. A stream with no usage
    # block at all still exits 0: an older CLI must not void a run over a
    # field it never had.
    stdout_path, trace_format = args[0], args[1]
    totals = {k: None for k in _USAGE_FIELDS}

    def add(field, value):
        if value is None:
            return
        totals[field] = (totals[field] or 0) + value

    with open(stdout_path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            if trace_format == "claude-stream-json":
                if ev.get("type") != "result":
                    continue
                usage = ev.get("usage") or {}
                add("input_tokens", usage.get("input_tokens"))
                add("cache_creation_input_tokens", usage.get("cache_creation_input_tokens"))
                add("cache_read_input_tokens", usage.get("cache_read_input_tokens"))
                add("output_tokens", usage.get("output_tokens"))
                add("usd", ev.get("total_cost_usd"))
            elif trace_format == "codex-json":
                if ev.get("type") != "turn.completed":
                    continue
                usage = ev.get("usage") or {}
                add("input_tokens", usage.get("input_tokens"))
                add("output_tokens", usage.get("output_tokens"))
                add("cache_read_input_tokens", usage.get("cached_input_tokens"))
                # Codex reports no cost; usd stays null.

    print(json.dumps(totals, sort_keys=True))
    return 0


def cmd_run_meta_set_usage(args):
    path = os.environ["META_PATH"]
    usage = json.load(sys.stdin)
    m = json.load(open(path, encoding="utf-8"))
    m["usage"] = usage
    with open(path, "w", encoding="utf-8") as f:
        json.dump(m, f, indent=2, sort_keys=True)
    return 0


def cmd_run_meta_finalize(args):
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
    return 0


COMMANDS = {
    "bin-version": cmd_bin_version,
    "canonical-path": cmd_canonical_path,
    "file-sha256": cmd_file_sha256,
    "gen-run-id": cmd_gen_run_id,
    "codex-flag-check": cmd_codex_flag_check,
    "run-with-timeout": cmd_run_with_timeout,
    "cancel-run-meta": cmd_cancel_run_meta,
    "mark-stage-void-meta": cmd_mark_stage_void_meta,
    "claude-auth-check-file": cmd_claude_auth_check_file,
    "claude-auth-check-stdin": cmd_claude_auth_check_stdin,
    "codex-auth-check": cmd_codex_auth_check,
    "claude-turn-json": cmd_claude_turn_json,
    "claude-count-results": cmd_claude_count_results,
    "codex-terminal-counts": cmd_codex_terminal_counts,
    "codex-thread-id": cmd_codex_thread_id,
    "extract-claude-trace": cmd_extract_claude_trace,
    "extract-codex-trace": cmd_extract_codex_trace,
    "lock-run-config-create": cmd_lock_run_config_create,
    "lock-run-config-update": cmd_lock_run_config_update,
    "eval-lookup": cmd_eval_lookup,
    "fixture-name": cmd_fixture_name,
    "arm-variable": cmd_arm_variable,
    "split-turns": cmd_split_turns,
    "arm-map-update": cmd_arm_map_update,
    "run-meta-init": cmd_run_meta_init,
    "run-meta-set-fixture-base": cmd_run_meta_set_fixture_base,
    "agent-usage": cmd_agent_usage,
    "run-meta-set-usage": cmd_run_meta_set_usage,
    "run-meta-finalize": cmd_run_meta_finalize,
}


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        sys.stdout.write(USAGE)
        return 0
    command, args = argv[0], argv[1:]
    fn = COMMANDS.get(command)
    if fn is None:
        die("unknown command: %s (see --help)" % command)
    return fn(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
