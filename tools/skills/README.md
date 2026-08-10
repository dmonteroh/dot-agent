# `.agent/` skills

Claude Code [skills](https://docs.claude.com/en/docs/claude-code/skills) for
the rare-but-detailed procedures that arise mid-session: grooming and
retro. Each is plain markdown with a YAML frontmatter block, so anything
that can read a file can read one. The auto-loading mechanism (matching a
task to a skill's `description`) is Claude Code's, but the content itself
is tool-neutral.

These are optional and additive. A node works fully with none of them
installed: the binding rules live in `.agent/rules/contract.md` (adapted
from a `presets/` file at bootstrap) and in `operating-model.md`. Each
skill only expands *how* to carry out a procedure the contract already
names: it introduces no new obligation and duplicates no rule text from
the presets.

Only in-session procedures ship as skills. Bootstrap and update are
operator ceremonies driven by the README prompts, which run with the
operating model and this repo already in context; a skill adds nothing
there, so none exists (V6.1 decision).

## Install

Skills live inside the node at `.agent/skills/` (one reviewable,
tool-neutral location), and each tool reads them through a symlink:

```bash
# Project node, from the project root
mkdir -p .agent/skills .claude
cp -r <clone>/tools/skills/groom <clone>/tools/skills/retro .agent/skills/
ln -s ../.agent/skills .claude/skills             # Claude Code
mkdir -p .codex && ln -s ../.agent/skills .codex/skills   # Codex, if used

# Root node
mkdir -p ~/.agent/skills ~/.claude
cp -r <clone>/tools/skills/groom <clone>/tools/skills/retro ~/.agent/skills/
ln -s ../.agent/skills ~/.claude/skills
```

If the tool's skills directory already exists with other content, symlink
the individual skill directories into it instead of replacing it. To track
this source repo as it updates, symlink from the clone rather than copying.

In `ignore-all` and `track-shared`, `.agent/skills/` stays out of git by
default (the `track-shared` allowlist never negates it). Negate it
explicitly if the team wants to share installed skills through git. In
`track-all`, which commits everything, installed skills are committed too.

## Skills

| Skill | Use when |
|---|---|
| [`groom/`](groom/) | `status.sh` prints a `GROOM:` flag |
| [`retro/`](retro/) | deciding whether to distill a learned rule, end of session |
