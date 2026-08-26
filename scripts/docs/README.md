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
