<!-- Canonical entry-point template. Copy into each tool's entry-point filename (CLAUDE.md and AGENTS.md, plus .github/copilot-instructions.md when the team uses Copilot Chat or code review). The operating model's wiring matrix records what each tool reads. Fill every <…> placeholder, then delete this comment. Root nodes write every path absolute (bash ~/.agent/scripts/status.sh ~, ~/.agent/rules/…) since sessions run from project directories. Keep all entry points identical. This file is wiring — the load path and nothing else. Never grow it into a second copy of `.agent/purpose.md`. -->
# <Project> — Session Bootstrap

<One line: stack, key dirs, package managers.> Everything else about this project lives in `.agent/` and loads in the steps below. Never restate it here.

**The whole conversation is one session, and the steps below run once in it.** A new user message does not start a new session. If earlier turns completed steps 1–5, they are still in effect: continue from that context, do not run them again, and do not re-read those files. Do not open this file with a tool when its content is already present in your context. Do not answer, plan, or edit before the steps have run; a one-line request — remember this, summarise that, handle that — is a task like any other.

Execute with tools, in order:

1. Run `bash .agent/scripts/status.sh` — prints recent session-log entries plus any GROOM:/REPAIR:/INDEX: flags and TOOLS: notes. Handle flags as part of this session. Treat TOOLS: notes as advisory. GROOM: work may go to one dispatched subagent (a small model is fine) explicitly assigned to write only the flagged files. Wait for it, then re-run status.sh to confirm.
2. Read `.agent/rules/learned.md` — accumulated corrections. Binding.
3. Read `.agent/rules/contract.md` — binding.
4. Read `.agent/purpose.md` — scope and boundaries.
5. Read `.agent/memory.md` — the fact index. Open the `memory/` fact files whose hooks match the task.
6. <Routing: pick area docs via the table in `.agent/docs/architecture.md`. Read only what the task needs.>

The one re-run: after a context compaction or handoff, run steps 1–5 again. A summary is lossy by construction, so a compacted session is a session operating without them, and it is not in a position to judge what it kept. Re-route step 6 only if the work moved.

Before handing back a diff, run `bash .agent/scripts/comments.sh <base-ref>` against the change's true parent — the branch base, or `HEAD` while the change is uncommitted, never `HEAD` on a clean tree — and delete what it blocks, justify or delete what it lists (Verification contract).

Exception — subagents: skip step 1 (flags are the orchestrator's to handle). Read everything else. Never edit `.agent/` unless explicitly assigned — the orchestrator is the single session-log writer.

Keep every entry-point mirror identical. When editing one, mirror the others.
