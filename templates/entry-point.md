<!-- Canonical entry-point template. Copy into each tool's entry-point filename (CLAUDE.md and AGENTS.md, plus .github/copilot-instructions.md when the team uses Copilot Chat or code review). The operating model's wiring matrix records what each tool reads. Fill every <…> placeholder, then delete this comment. Root nodes write every path absolute (bash ~/.agent/scripts/status.sh ~, ~/.agent/rules/…) since sessions run from project directories. Keep all entry points identical. This file is wiring — the load path and nothing else. Never grow it into a second copy of `.agent/purpose.md`. -->
# <Project> — Session Bootstrap

<One line: stack, key dirs, package managers.> Everything else about this project — scope, boundaries, constraints, architecture, conventions — lives in `.agent/` and loads in the steps below. Never restate it here: a fact written in two places goes stale in one, and this file is the copy no check reads.

**The steps run once, at the start of a session.** Some tools re-read this file on every message. If this session has already run them, they are still in effect: do not run them again, do not re-read those files, continue the work. Do not answer, plan, or edit before they have run.

Execute with tools, in order:

1. Run `bash .agent/scripts/status.sh` — prints recent session-log entries plus any GROOM:/REPAIR:/INDEX: flags and TOOLS: notes. Handle flags as part of this session. Treat TOOLS: notes as advisory. GROOM: work may go to one dispatched subagent (a small model is fine) explicitly assigned to write only the flagged files. Re-run status.sh to confirm.
2. Read `.agent/rules/learned.md` — accumulated corrections. Binding.
3. Read `.agent/rules/contract.md` — binding.
4. Read `.agent/purpose.md` — scope and boundaries.
5. Read `.agent/memory.md` — the fact index. Open the `memory/` fact files whose hooks match the task.
6. <Routing: pick area docs via the table in `.agent/docs/architecture.md`. Read only what the task needs.>

The one re-run: after a context compaction or handoff, run steps 1–5 again. The steps ran once at session start, so a compacted session is a session operating without them. Re-route step 6 only if the work moved.

Before handing back a diff, run `bash .agent/scripts/comments.sh <base-ref>` against the change's true parent — the branch base, never `HEAD`, which diffs a committed change against itself and reads nothing. Delete every comment it blocks. Justify or delete every comment it lists. Its vocabulary lives in `.agent/scripts/comments.conf`.

Exception — subagents: skip step 1 (flags are the orchestrator's to handle). Read everything else. Never edit `.agent/` unless explicitly assigned — the orchestrator is the single session-log writer.

Keep every entry-point mirror identical. When editing one, mirror the others.
