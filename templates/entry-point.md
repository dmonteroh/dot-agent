<!-- Canonical entry-point template. Copy into each tool's entry-point filename (CLAUDE.md and AGENTS.md, plus .github/copilot-instructions.md when the team uses Copilot Chat or code review). The operating model's wiring matrix records what each tool reads. Fill every <…> placeholder, then delete this comment. Root nodes write every path absolute (bash ~/.agent/scripts/status.sh ~, ~/.agent/rules/…) since sessions run from project directories. Keep all entry points identical. This file is wiring — the load path and nothing else. Never grow it into a second copy of `.agent/purpose.md`. -->
# <Project> — Session Bootstrap

<One line: stack, key dirs, package managers.> Everything else about this project lives in `.agent/` and loads in the steps below. Never restate it here.

**The whole conversation is one session, and the steps below run once in it.** A new user message does not start a new session. Steps completed in earlier turns are still in effect: do not run them again or re-read those files. Do not open this file with a tool when its content is already present in your context. Do not answer, plan, or edit before the steps have run; a one-line request — remember this, summarise that, handle that — is a task like any other.

Execute with tools, in order:

1. Run `bash .agent/scripts/status.sh --load` — one call: recent session-log entries, any GROOM:/REPAIR:/INDEX: flags and TOOLS: notes, then the four always-loaded files: `.agent/rules/learned.md` (binding), `.agent/rules/contract.md` (binding), `.agent/purpose.md`, `.agent/memory.md` (the fact index). Read them from that output; never open them again with a tool. Handle flags as part of this session. TOOLS: notes are advisory. GROOM: work may go to one dispatched subagent (a small model is fine) writing only the flagged files; wait for it, then re-run `status.sh` to confirm.
2. Open the `memory/` fact files whose hooks match the task.
3. <Routing: pick area docs via the table in `.agent/docs/architecture.md`. Read only what the task needs.>

The one re-run: after a context compaction or handoff, run step 1 again. A summary is lossy; a compacted session cannot judge what it kept. Re-route step 3 only if the work moved.

Before handing back, run `bash .agent/scripts/finish.sh --tool <tool> --area <area> --verify <pass|fail|n/a> --summary "<task, outcome, ≤25 words>"` — one call: the comment gate against the change's true parent (`--base <branch base>` when committed, `HEAD` while uncommitted, never `HEAD` on a clean tree), the status check, then the session-log entry. Delete what it blocks, justify or delete what it lists, handle any flag, then run it again; the entry is written once, on the clean run (Verification contract). Your final message is the answer or the report itself, complete on its own, never a wrap-up line pointing at an earlier message.

Exception — subagents: flags and `finish.sh` are the orchestrator's. Read everything else. Never edit `.agent/` unless explicitly assigned — the orchestrator is the single session-log writer.

Keep every entry-point mirror identical: when editing one, mirror the others.
