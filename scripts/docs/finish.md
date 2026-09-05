# finish.sh — the hand-back call

The one command a session runs before handing back. It runs the comment gate, the status check, and the session-log writer in that order, each of which lives in its own script; this one only sequences them and stops at the first refusal.

```
Usage: finish.sh --tool <name> --area <name> --verify <pass|fail|n/a> --summary "…" [--base <ref>] [root]
```

`root` defaults to `.` — the project root holding `.agent/`. `--tool`, `--area`, `--verify`, and `--summary` are passed through to `log.sh` unchanged and are held to its checks.

## What it runs

| Step | Runs | Stops when |
|---|---|---|
| 1 | `comments.sh <base>` from the project root | exit 1 (a `BLOCK:` finding) or exit 2 (could not run) |
| 2 | `status.sh`, printing only its `GROOM:` / `REPAIR:` / `INDEX:` lines | any flag line stands |
| 3 | `log.sh --tool … --area … --verify … --summary …` | `log.sh` refuses the entry |

A stop leaves no log entry behind. That ordering is the point: a log entry is a claim that the session finished, and it is not written over a diff the gate refused or a node still flagged. The session fixes what was named and runs the command again; the entry is appended once, on the clean run, so a second run never duplicates the first.

## The base ref

`--base <ref>` names the change's true parent for the gate — the branch base when the work is committed. Without it, uncommitted work is gated against `HEAD`, and a clean tree has no diff to gate, so the gate is skipped and says so. That matches `comments.sh`'s own refusal of `HEAD` over a clean tree: a run that reads nothing must not report as a pass.

## Why one call

A session's cost scales with its tool calls, not its words: every call re-reads the whole context. The hand-back was three calls — gate, log entry, status re-check — and the bootstrap five; measured across every corpus size tried, USD per call was flat and the harness made three to four times the calls of a plain instructions file. Folding the hand-back into one call and the bootstrap into `status.sh --load` cut calls per session by a quarter with the rules unchanged. What each step does did not move: `comments.sh`, `status.sh`, and `log.sh` are unchanged and remain callable on their own.

## Exit status

| 0 | 1 |
|---|---|
| gate clean or skipped, no flag standing, entry written | the gate blocked or could not run, a flag stands, or `log.sh` refused — read the line above the refusal; nothing was written |

## Subagents

Workers never run it. The orchestrator is the single session-log writer, and flags are the orchestrator's to handle; a worker that ran `finish.sh` would write an entry for work it did not own.
