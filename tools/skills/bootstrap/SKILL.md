---
name: bootstrap
description: Use when setting up a new .agent/ node (root or project) — the judgement steps around node.sh init, such as exploring the project, choosing a preset and mode, adapting contract.md, and wiring tools.
---

# Bootstrapping a node

The binding sequence lives in `operating-model.md`'s "What happens during
bootstrap" and the two prompts in `README.md`; `scripts/node.sh init` (see
its header comment) executes the mechanical parts of that sequence — the
skeleton, the manifest, the gitignore, the script copies. This skill covers
the judgement parts the script can't do for you. Nothing here is
load-bearing: a node bootstrapped by hand from those two sources is exactly
as valid as one bootstrapped with this skill open.

## Explore before proposing anything

Read the manifest files (`package.json`, `pyproject.toml`, or equivalent),
the README, recent git log, and any existing tool configs (`.cursor/`,
`AGENTS.md`, CI files) — migration candidates worth folding into `.agent/`
rather than discarding. For an empty project, there's nothing to explore;
go straight to a conversation instead of a findings summary.

## Confirm before writing

State what you found and which of the three `presets/*.md` files fits best,
then let the operator correct you and choose the tracking mode before
`node.sh init` runs. Findings and the tracking-mode choice both belong in
this conversation, not baked into a guess.

## Run `node.sh init`

`bash scripts/node.sh init --preset <name> --mode <mode> <root>`, from a
clone of the source repo. It refuses to run over an existing `.agent/`, so
it's safe to invoke once the findings above are settled. Read its stdout —
it confirms the preset and mode it applied.

## Adapt `rules/contract.md`

The script copies the chosen preset in verbatim; the adaptation is yours.
Keep `## Kernel` intact. Fill `## Project guardrails` with the exact
commands the section's own template comment asks for. Split `## Quality
bar` out into `.agent/rules/quality-bar.md` per that section's own header
comment — it's a rubric that loads on demand, not every session.

## Wire tools and finish

Write the canonical entry-point template (`operating-model.md`, "The
canonical entry point") into each tool's filename, filling the project line
and the doc-routing placeholder; keep every entry point identical to the
others. For Claude Code, also set `"autoMemoryEnabled": false` in
`.claude/settings.json`. If a parent root node exists, add this node's path
to the parent manifest's `children` list so the parent's next update pass
walks it too.
