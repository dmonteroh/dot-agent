# node.sh — bootstrap and update

The mechanical parts of standing a node up and moving it forward. Judgement — exploring the project, filling Project guardrails, reconciling content during an update — stays with the agent. This script never does either.

Run from the source repo. It is not copied into a node.

```
Usage:
  node.sh init --preset <name> --mode <mode> [root]
  node.sh update [root]
```

- `<name>` matches a file in `presets/` (currently `software-development`, `academic-research`, `domain-knowledge`).
- `<mode>` is one of `ignore-all`, `track-shared`, `track-all`.
- `root` defaults to `.` and the script reads and writes `<root>/.agent`.

Header contracts in `operating-model.md` remain the format authority: this script writes files that carry their own header contracts, and produces nothing a header contract does not already describe.

## What init writes

The skeleton, the manifest, the gitignore for the chosen mode, the preset as `rules/contract.md`, the six shipped scripts, and the three starter confs.

The starter confs are seeded because the scripts are executed rather than read: without the file on disk, a knob is one nobody finds. They are configs from that moment on — the node edits or deletes them freely.

A `.gitignore` at `$HOME` is commonly git's global `core.excludesFile`, so a `.agent/` pattern there would ignore every project node in every repo. init skips writing one in that case and says so.

## What update does

Refreshes the shipped scripts from the source repo **by exactly their six names**. Anything else under `scripts/` is the node's own and is never overwritten. A missing starter conf is seeded — the one write that cannot clobber node content — and an existing one is never touched.

It also reaches the mechanical migration baseline: memory body moved verbatim to `memory/legacy.md`, the old per-fact header stripped behind a backup, and `version` bumped. Every node with untracked memory is backed up first.

A node already on the current version can still be shape-stale: version- current is not shape-current, so shape migrations run regardless.
