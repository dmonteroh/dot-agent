# Script documentation

One file per script under `scripts/`. These describe what each script does, what it reports, and how a node tunes it.

**These files stay in the source repo.** `node.sh` copies executables and starter confs into a node, never this folder — a node's `.agent/scripts/` holds the six shipped scripts plus their confs and nothing else. That is the point: a script that lands in someone's repository carries the code and its usage line, not this repo's design notes.

So the split is:

| Where | What it holds |
|---|---|
| the script itself | a purpose line, `Usage:`, and comments that state a constraint the code cannot express |
| the starter conf beside it, in the node | every tunable key, its default, and what changing it does |
| here | what the script is for, what it reports, and why it is built the way it is |

A node needing more than its conf explains reads these files upstream.

| Script | Ships into a node | Doc |
|---|---|---|
| `status.sh` | yes | [status.md](status.md) |
| `log.sh` | yes | [log.md](log.md) |
| `memory.sh` | yes | [memory.md](memory.md) |
| `docs.sh` | yes | [docs.md](docs.md) |
| `links.sh` | yes | [links.md](links.md) |
| `comments.sh` | yes | [comments.md](comments.md) |
| `node.sh` | no — run from this repo | [node.md](node.md) |
| `test.sh` | no — this repo's gate | [test.md](test.md) |

## Arguments

Five of the shipped scripts end with an optional `[root]` — the project root holding `.agent/`, defaulting to `.`. `comments.sh` does not: its one argument is a git base ref. It audits a diff in the repository it is run from rather than a node's tree, so there is no root for it to take. A `[root]` habit carried over to it gets `base ref '.' not found` and a non-zero exit, not a silent wrong answer.

## Exit status

Each script's status answers a question about that script's own run. The codes are read per script and never pooled across them.

| Script | 0 | 1 | 2 |
|---|---|---|---|
| `status.sh`, `links.sh` | ran, whatever it found | usage error — a root holding no `.agent/` | — |
| `log.sh`, `memory.sh`, `docs.sh`, `node.sh` | wrote what was asked | refused or could not write it | — |
| `comments.sh` | no `BLOCK:` finding | a `BLOCK:` finding | could not run — bad base ref, no merge base, an uncompilable conf regex, or a base that describes an empty diff |

`comments.sh` is the only gate, and the only script whose status reports a verdict on someone else's work rather than on its own health. That is why it alone needs a second failure code: "the answer is no" and "I could not ask the question" must not arrive as the same number, or a broken conf reads as a clean diff.

The reporting scripts put no finding in the exit status at all. A caller that branched on `status.sh` would be reading grooming advice as a build failure — the binding instruction to act on flags lives in the entry point, not in a number.
