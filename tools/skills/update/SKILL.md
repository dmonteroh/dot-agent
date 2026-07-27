---
name: update
description: Use when bringing an existing .agent/ node up to date with a newer operating-model version — running node.sh update, reconciling its output, and propagating the update to child nodes.
---

# Updating a node

The binding sequence lives in `operating-model.md`'s "Updating existing
nodes" section and `README.md`'s update prompt; `scripts/node.sh update`
(see its header comment) executes the mechanical parts. This skill covers
the judgement work around it. Nothing here is load-bearing — an operator
reading those two sources directly can update a node without this file.

## Run the script first

`bash scripts/node.sh update <root>`, from a clone of the source repo. Read
its stdout literally before doing anything else:

- "node is current" — stop, there's nothing to do.
- No `dot-agent` manifest found — this is a pre-V6 node; skip to
  "Pre-V6 nodes" below instead of retrying the script.
- Otherwise it reports what it did: the version bump, whether it backed up
  an `ignore-all` node first, which scripts it refreshed, and — for a
  V6→6.1 jump — whether it moved `memory.md`'s prior body to
  `memory/legacy.md`.

## Reconcile what the script can't

The script only ever changes `version` in the manifest and refreshes files
that carry no project content. Everything else is judgement: diff the
node's `rules/contract.md` against the current preset and fold in additions
without discarding project-specific adaptations (guardrails, any Kernel
edits); refresh terminology that changed. If `status.sh` now flags
`memory/legacy.md`, that split is the groom skill's job
(`tools/skills/groom/`), not this one. Where new operating-model content
directly conflicts with something project-specific, flag it for the
operator per operating-model.md's conflict-resolution rule rather than
resolving it yourself.

## Pre-V6 nodes

`node.sh update` only handles manifested (V6+) nodes. For a node with no
`dot-agent` frontmatter, read `CHANGELOG.md` — the pre-V6 migration
checklist by design — restore the manifest and structure by hand, then
re-run the script so its mechanical parts (scripts, version) still land.

## Propagate and report

If the manifest's `children` list is non-empty, repeat this whole process
for each child, current node first. Report what changed, what was
preserved, and anything you flagged for the operator instead of resolving
yourself.
