# dot-agent skills

Claude Code [skills](https://docs.claude.com/en/docs/claude-code/skills) for the rare-but-detailed procedures that arise mid-session: grooming and retro. Each is plain markdown with a YAML frontmatter block, so anything that can read a file can read one. The auto-loading mechanism (matching a task to a skill's `description`) is Claude Code's, but the content itself is tool-neutral.

These are optional and additive. A node works fully with none of them installed: the binding rules live in `.agent/rules/contract.md` (adapted from a `presets/` file at bootstrap) and in `operating-model.md`. Each skill only expands *how* to carry out a procedure the contract already names. It introduces no new obligation and duplicates no rule text from the presets.

Only in-session procedures ship as skills. Bootstrap and update are operator ceremonies driven by the README prompts, which run with the operating model and this repo already in context. A skill adds nothing there, so none exists (V6.1 decision).

## Install

Skills live beside the node at `.agents/skills/`, which Codex, Gemini CLI, OpenCode, GitHub Copilot, Cursor, Amp, and Antigravity read directly. Claude Code reads only `.claude/skills/`, so it gets a symlink:

```bash
# Project node, from the project root
mkdir -p .agents/skills .claude
cp -r <clone>/tools/skills/groom <clone>/tools/skills/retro .agents/skills/
ln -s ../.agents/skills .claude/skills             # Claude Code

# Root node
mkdir -p ~/.agents/skills ~/.claude
cp -r <clone>/tools/skills/groom <clone>/tools/skills/retro ~/.agents/skills/
ln -s ../.agents/skills ~/.claude/skills
```

At the root, every tool that reads `~/.agents/skills/` sees the skills in every project. If `.claude/skills` already exists with other content, symlink the individual skill directories into it instead of replacing it. To track this source repo as it updates, symlink from the clone rather than copying.

The skills sit outside `.agent/`, so no tracking mode touches them: the project decides whether `.agents/skills/` enters git. The node stays at `.agent/` because Codex's `workspace-write` sandbox keeps `.agents/` read-only, which suits skills an agent only reads and would block every write a node needs. Other tools and installers write into `.agents/skills/` too, so `status.sh` checks every installed skill against the Agent Skills specification and reports a `GROOM:` line for a missing `SKILL.md`, a `name` that differs from its directory, a missing description, a description over 1024 characters, or a separate copy under `.claude/skills/`.

## Skills

| Skill | Use when |
| --- | --- |
| [`groom/`](groom/) | `status.sh` prints a `GROOM:` flag |
| [`retro/`](retro/) | a retro trigger fired (user correction, failed verification, plan deviation, comment-hygiene breach), or session close before the log entry |
