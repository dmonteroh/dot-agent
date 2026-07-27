# `.agent/` skills

Claude Code [skills](https://docs.claude.com/en/docs/claude-code/skills) for
the rare-but-detailed `.agent/` procedures: grooming, bootstrap, update,
retro. Each is plain markdown with a YAML frontmatter block, so anything
that can read a file can read one — the auto-loading mechanism (matching a
task to a skill's `description`) is Claude Code's, but the content itself
is tool-neutral.

These are optional and additive, the same status as the hooks in
[`tools/claude-code/`](../claude-code/). A node works fully with none of
them installed: the binding rules live in `.agent/rules/contract.md`
(adapted from a `presets/` file at bootstrap) and in `operating-model.md`.
Each skill only expands *how* to carry out a procedure the contract already
names — it introduces no new obligation and duplicates no rule text from
the presets.

## Install

Copy or symlink the directories you want into a location Claude Code reads
for skills:

```bash
# User-level, every project
cp -r tools/skills/* ~/.claude/skills/

# Project-level, this repo only
cp -r tools/skills/* .claude/skills/
```

Symlink instead of copy if you want them to track this source repo as it
updates.

## Skills

| Skill | Use when |
|---|---|
| [`groom/`](groom/) | `status.sh` prints a `GROOM:` flag |
| [`bootstrap/`](bootstrap/) | setting up a new `.agent/` node |
| [`update/`](update/) | bringing an existing node up to date |
| [`retro/`](retro/) | deciding whether to distill a learned rule, end of session |
