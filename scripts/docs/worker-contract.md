# The worker-load contract

This page states what an orchestrator may rely on when it hands a task to a worker in a project that holds a dot-agent node. It covers the call a worker makes to load the node, the shape of what that call prints, and which helpers a worker may run. An orchestrator reads this page, or `node.sh describe` for one node, instead of branching on the manifest's `version`.

A worker is any session another session dispatched: a subagent in the same checkout, or a session in its own checkout with a copy of the node. The orchestrator is the session or program that dispatched it. The operating model's [subagents section](../../operating-model.md#subagents-and-parallel-sessions) is the policy. This page is the interface that policy runs on.

## The bootstrap call

```
bash .agent/scripts/status.sh --load --tail 0
```

A root node at the home directory takes `bash ~/.agent/scripts/status.sh --load --tail 0 ~`. `--tail 0` leaves the session-log tail out. The tail is the main session's recent history, and the task packet carries what a worker needs of it. The same call without `--tail 0` prints it, and it is the call for a node whose `status.sh` has no `--tail`. The call writes nothing under the node or anywhere else, in both index modes, so it runs in a read-only copy, a sandbox, or a checkout that is not the node's own (`scripts/docs/status.md`). It exits 0 for every node it can read, whatever it finds, and 1 only for a root that holds no `.agent/`.

A worker whose session-start hook already printed a `dot-agent session-start hook` block has the output and makes no call.

## The output shape

In order:

1. Finding lines, one per line, each opening with a prefix: `GROOM:`, `REPAIR:`, `INDEX:`. Then the informational lines: `TOOLS:`, `LOAD:`, `PAYLOAD:`, `HOOK:`.
2. In generated mode only, either the line `Index pages: …` followed by one `READ: <path>` line per page to open, or one line beginning `Index cache is stale or missing`. That line names `.agent/rules/` and `.agent/docs/architecture.md` for a worker to read directly, and tells the orchestrator's own session to run `index.sh ensure`. `READ:` paths are relative to the folder that holds `.agent/`.
3. Each always-loaded file under a line `==== <path> ====`, the path relative to the folder that holds `.agent/`. Manual mode prints `rules/learned.md`, `rules/contract.md`, `purpose.md`, `memory.md`. Generated mode prints `purpose.md` and `memory.md`.
4. The newest session-log entries under `==== .agent/session-log.md, newest <n> entries ====`. `--tail <n>` sets the count for one call and `--tail 0` leaves the section out.

When the whole output would pass `PAYLOAD_MAX_BYTES`, one `REPAIR:` line naming the files to open directly takes the place of parts 2 and 3. `--format tsv` prints findings only, as `severity<TAB>CODE<TAB>PATH<TAB>MESSAGE`.

## What a worker may run

```worker-commands
WORKER_MAY_RUN=status.sh, links.sh, comments.sh, review.sh, index.sh check, log.sh, memory.sh, learn.sh, docs.sh
ORCHESTRATOR_ONLY=checkpoint.sh, verify.sh, index.sh ensure, absorb.sh
```

- **Readers:** `status.sh`, `links.sh`, `comments.sh`, `review.sh`, and `index.sh check` read and print.
- **Focused tests:** a worker runs the tests for the code it changed directly, outside `verify.sh`, and reports each command and its result.
- **Experience records:** `memory.sh` and `learn.sh` for a lesson, and `log.sh`. Each takes the node's lock, waiting up to `DA_LOCK_WAIT_SECONDS` for a held one, so workers in one checkout, or in checkouts whose `.agent` links to the main node, write the shared files directly.
- **Code-coupled docs:** `docs.sh`. A doc a worker writes in its own checkout reaches the main node only through `absorb.sh docs`, when the worker's code is integrated.
- **The orchestrator's:** `checkpoint.sh` (verification, review, and completion), `verify.sh` (the configured checks, run once on the integrated change rather than again by each worker), `index.sh ensure` (it writes the generated cache), `absorb.sh` (it merges a worker's node into the main one), and handling the `GROOM:`, `REPAIR:`, and `INDEX:` flags the bootstrap prints. A helper this page does not list is the orchestrator's.

Permission to run the record writers does not produce records. An orchestrator that wants lessons asks for them in the report it validates, and either lets the worker run `learn.sh` or `memory.sh` or runs them itself from the report. The session-log entry is the orchestrator's: one per integrated task, through its own checkpoint. `log.sh` stays in the worker's list, so an orchestrator may still ask for an entry.

## Exit codes

| Helper | 0 | 1 | Other |
| --- | --- | --- | --- |
| `status.sh`, `links.sh` | Inspection ran, whatever it found | Usage error, or the root holds no `.agent/` | |
| `comments.sh`, `review.sh` | Nothing blocks | A finding blocks | 2 inspection failed |
| `verify.sh run` | The check passed | The check failed or was inconclusive | 2 invocation error, 124 timed out (`scripts/docs/verify.md`) |
| `index.sh` | Fresh or rebuilt | Stale or fell back | 2 invocation error |
| `log.sh` | Entry written | Refused | |
| `memory.sh` | Written or found | Refused | 3 stale `--expected` |
| `learn.sh` | Written or found | | 2 usage or failed operation, 3 stale `--expected`, 4 near a record or a contract section, 5 exact duplicate, 6 malformed candidate, 7 wrong surface |
| `docs.sh` | Written | Refused | |
| `checkpoint.sh` | Recorded, or nothing to record | Refused or blocked | |
| `absorb.sh` | Merged | | 2 refused, 3 merged around conflicts |

The last line a refusing `checkpoint.sh`, `log.sh`, `memory.sh`, or `learn.sh` prints on stderr says what was refused and the next step. `memory.sh` and `learn.sh` end a successful write on stdout with `<action><TAB><id><TAB><version>`, where the version is what `--expected` takes. A `learn.sh retire` line has no version.

`node.sh` runs from the dot-agent source repository and is never installed in a node, so neither side runs it inside a task.

## What stays stable

These hold across versions. A version that changes one of them raises `WORKER_CONTRACT` in the node's `status.sh` and says so in its changelog entry. `node.sh describe` prints that number from the node's own copy, so an orchestrator compares one number scoped to this interface, never the release version. This page describes revision 1. A node that prints `WORKER_CONTRACT=0` predates the page: its bootstrap call and markers match revision 1, and its output puts the log tail first.

- The bootstrap call above, and its write-free, exit-0 behavior.
- The `==== <path> ====` marker form, and the order of the four parts.
- The meaning of each prefix listed under the output shape. New prefixes may be added. A consumer ignores one it does not know.
- The `READ: <path>` line form.
- `--format tsv`'s four fields and their order.
- `verify.sh`'s stdout record, `receipt<TAB>id<TAB>status<TAB>check<TAB>exit<TAB>count`, and its exit codes (`scripts/docs/verify.md`).
- The split between `WORKER_MAY_RUN` and `ORCHESTRATOR_ONLY`. A command may move from the second list to the first. Moving one the other way is a change to this contract.

These are not promised: the wording after a prefix, the order of finding lines among themselves, any byte or word count, the labels in `PAYLOAD:`'s breakdown, and the text of the generated-mode lines other than `READ:`.

## `node.sh describe`

```
node.sh describe [root]
```

Prints one `KEY=value` line per fact, parsed as data and never sourced. First `ROOT`, then the manifest's `VERSION`, `PRESET`, `MODE`, `INDEXES` (`manual` when the manifest has no line), `HOOKS`, and `MIGRATION_TARGET` while a migration is pending. Then `WORKER_CONTRACT`, `BOOTSTRAP` (the call above, written for a root node where the root is the home directory), `WORKER_MAY_RUN`, and `ORCHESTRATOR_ONLY`. The two lists are comma-separated and name only commands whose script the node holds, so a helper missing from an older node is missing from the list too. `node.sh` runs from the source repository, but everything it prints is read from the node.

## Worker checkouts and versions

`absorb.sh` merges a worker's node only when both manifests carry the same `version`, and refuses otherwise (`scripts/docs/absorb.md`). That is the one place a version comparison stays. Two nodes at different versions can hold records in different shapes, and a merge across them could write one shape into a node that reads the other. A worker checkout made from the main checkout's own commit carries the same version by construction. A worker whose `.agent` links to the main node shares it, so `absorb.sh` reports `shared` and merges nothing.
