<!-- Canonical entry-point template. Copy into each tool's entry-point filename (CLAUDE.md and AGENTS.md, plus .github/copilot-instructions.md when the team uses Copilot Chat or code review). The operating model's wiring matrix records what each tool reads. Fill every <…> placeholder, then delete this comment. Root nodes write every path absolute (bash ~/.agent/scripts/status.sh ~, ~/.agent/rules/…) since sessions run from project directories. Keep all entry points identical. This file is wiring — the load path and nothing else. Never grow it into a second copy of `.agent/purpose.md`. -->
# <Project> — Session Bootstrap

<One line: stack, key dirs, package managers.> Everything else about this project lives in `.agent/` and loads in the steps below. Never restate it here.

**The whole conversation is one session, and the steps below run once in it.** A new user message does not start a new session. If earlier turns completed steps 1–2, they are still in effect: continue from that context, do not run them again, and do not re-read those files. Do not open this file with a tool when its content is already present in your context. Do not answer, plan, or edit before the steps have run; a one-line request — remember this, summarise that, handle that — is a task like any other.

Execute with tools, in order:

1. Run `bash .agent/scripts/status.sh --load` — one call. It prints recent session-log entries, any GROOM:/REPAIR:/INDEX: flags and TOOLS: notes, then the four always-loaded files in order: `.agent/rules/learned.md` (accumulated corrections, binding), `.agent/rules/contract.md` (binding), `.agent/purpose.md` (scope and boundaries), `.agent/memory.md` (the fact index). Read them from that output; do not open them again with a tool. Handle flags as part of this session. Treat TOOLS: notes as advisory. GROOM: work may go to one dispatched subagent (a small model is fine) explicitly assigned to write only the flagged files. Wait for it, then re-run `status.sh` to confirm.
2. Open the `memory/` fact files whose hooks match the task.
3. <Routing: pick area docs via the table in `.agent/docs/architecture.md`. Read only what the task needs.>

The one re-run: after a context compaction or handoff, run step 1 again. A summary is lossy by construction, so a compacted session is a session operating without it, and it is not in a position to judge what it kept. Re-route step 3 only if the work moved.

Before handing back, run `bash .agent/scripts/finish.sh --tool <tool> --area <area> --verify <pass|fail|n/a> --summary "<task, outcome, ≤25 words>"` — one call: the comment gate against the change's true parent (uncommitted work gates against `HEAD`; a committed branch needs `--base <branch base>`), the status check, then the session-log entry. Delete what the gate blocks, justify or delete what it lists, handle any flag it prints, and run it again; the entry is written once, on the clean run (Verification contract). Your final message is the answer or the report itself, complete on its own — never a one-line wrap-up that points back at an earlier message.

Exception — subagents: flags are the orchestrator's to handle, and so is `finish.sh`. Read everything else. Never edit `.agent/` unless explicitly assigned — the orchestrator is the single session-log writer.

Keep every entry-point mirror identical. When editing one, mirror the others.
