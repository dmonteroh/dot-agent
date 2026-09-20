# checkpoint.sh — the hand-back call

The one command a session runs before handing back. It runs the comment gate, the status check, and the session-log writer in that order, each of which lives in its own script; on a node running generated indexes (`indexes: generated`) it also refreshes the index cache between the status check and the log entry. This one only sequences them and stops at the first refusal that blocks a hand-back — the cache refresh never does.

```
Usage: checkpoint.sh --tool <name> --area <name> --verify <pass|fail|n/a> --summary "…" [--base <ref>] [root]
```

`root` defaults to `.` — the project root holding `.agent/`. `--tool`, `--area`, `--verify`, and `--summary` are passed through to `log.sh` unchanged and are held to its checks.

## What it runs

| Step | Runs | Stops when |
|---|---|---|
| 1 | `comments.sh <base>` from the project root | exit 1 (a `BLOCK:` finding) or exit 2 (could not run) |
| 2 | `status.sh`, printing only its `GROOM:` / `REPAIR:` / `INDEX:` lines | any flag line stands, or the check could not be run cleanly |
| 3 | on a node running generated indexes only: `index.sh ensure`, refreshing `.agent/indexes/` from this session's canonical writes | never |
| 4 | `log.sh --tool … --area … --verify … --summary …` | `log.sh` refuses the entry |

A stop leaves no log entry behind. That ordering is the point: a log entry is a claim that the session finished, and it is not written over a diff the gate refused or a node still flagged. The session fixes what was named and runs the command again; the entry is appended once, on the clean run, so a second run never duplicates the first.

A manual-mode node (`indexes: manual`, the default) runs no refresh step at all — step 3 exists only when the manifest reads `indexes: generated`. The cache is disposable: a missing `.agent/scripts/index.sh` or a failing `ensure` prints a warning to stderr naming the canonical `.agent/rules/` and `.agent/docs/` directories to read directly meanwhile, and changes neither the exit status below nor whether the log entry is written — the next successful `ensure` catches the cache back up.

## The base ref

`--base <ref>` names the change's true parent for the gate — the branch base when the work is committed. Without it, uncommitted work is gated against `HEAD`. That matches `comments.sh`'s own refusal of `HEAD` over a clean tree: a run that reads nothing must not report as a pass.

## The unchanged tree

A clean tree with no `--base` is a turn that changed nothing, and the script stops there: no gate to run, no verification to record, no entry written.

The session log holds one entry per turn that changed files, not one per session — a stated design, not an unresolved tension the runtime is merely working around. The entry point scopes bootstrap to the conversation — one conversation is one session — but a hand-back happens on every message, and no stable session or conversation identifier reaches a tool call inside one to key the log on instead. Measured before this rule existed: a three-turn session on Codex ran `checkpoint.sh` three times and wrote three entries, two of them a question answered and nothing else — the evidence for why the boundary is "changed files," not "every hand-back." At a hundred messages without the rule that is a hundred entries, riding the printed tail into every future session.

The agent cannot observe the end of a session. It can observe whether the turn changed anything, so that is the boundary the script reads: a clean tree with no `--base`. That is not "an answering turn never logs" — a turn that only answers but follows uncommitted prior work still finds a dirty tree and still writes an entry. Committed work still logs — `--base <ref>` names its parent. A project that is not a git checkout gives no signal either way, so it keeps the old behavior: the gate is skipped, and the entry is written.

## Why one call

A session's cost scales with its tool calls, not its words: every call re-reads the whole context. The hand-back was three calls — gate, log entry, status re-check — and the bootstrap five; measured across every corpus size tried, USD per call was flat and the harness made three to four times the calls of a plain instructions file. Folding the hand-back into one call and the bootstrap into `status.sh --load` cut calls per session by a quarter with the rules unchanged. What each step does did not move: `comments.sh`, `status.sh`, and `log.sh` are unchanged and remain callable on their own.

## Exit status

| 0 | 1 |
|---|---|
| gate clean or skipped, no flag standing, entry written | the gate blocked or could not run, a flag stands, the status check itself failed to run cleanly (nonzero exit or unexpected stderr from `status.sh`), `log.sh` refused, or the tree was clean with no `--base` — read the line above the refusal; nothing was written |

An inspection that did not run is not a clean node: the log entry is a claim that the node's state was actually read, and a `status.sh` that crashed, exited nonzero, or wrote to stderr never made that claim true.

The generated-mode cache refresh (step 3) sits outside this table: whatever it prints and however `index.sh` exits, the codes above are unaffected — only `comments.sh`, `status.sh`, and `log.sh` decide them.

## Subagents

Workers never run it. The orchestrator is the single session-log writer, and flags are the orchestrator's to handle; a worker that ran `checkpoint.sh` would write an entry for work it did not own.
