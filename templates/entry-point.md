<!-- Canonical entry-point template. Copy into each tool's entry-point filename (CLAUDE.md and AGENTS.md, plus .github/copilot-instructions.md when the team uses Copilot Chat or code review). The operating model's wiring matrix records what each tool reads. Fill every <…> placeholder, then delete this comment. Root nodes write every path absolute (bash ~/.agent/scripts/status.sh ~, ~/.agent/rules/…) since sessions run from project directories. Keep all entry points identical. This file is wiring — the load path and nothing else. Never grow it into a second copy of `.agent/purpose.md`. -->
# <Project> — Session Bootstrap

<One line: stack, key dirs, package managers.> Everything else lives in `.agent/` and loads below. Never restate it here.

**One conversation is one session: the steps below run once in it**, with tools. A new user message does not start a new session. Do not open this file with a tool when its content is already present in your context. Do not answer, plan, or edit before the steps have run; a one-line request — remember this, summarise that, handle that — is a task like any other.

1. Run `bash .agent/scripts/status.sh --load` — recent log entries, GROOM:/REPAIR:/INDEX: flags (handle them this session; GROOM: may go to one subagent writing only the flagged files — wait, then re-run), TOOLS: notes (advisory), then `rules/learned.md` and `rules/contract.md` (binding), `purpose.md`, `memory.md`. Read them from that output; never open them again.
2. Open the `memory/` fact files whose hooks match the task.
3. <Routing: pick area docs via the table in `.agent/docs/architecture.md`. Read only what the task needs.>

After a context compaction or handoff, run step 1 again; re-route step 3 if the work moved.

Before handing back, run `bash .agent/scripts/finish.sh --tool <tool> --area <area> --verify <pass|fail|n/a> --summary "<task, outcome, ≤25 words>"` — the comment gate (`--base <ref>` for committed work), the status check, then the log entry, written once on the clean run. Fix what it names and run it again. Your final message is the report itself, never a wrap-up line.

Subagents: flags and `finish.sh` are the orchestrator's; read the rest; edit `.agent/` only when assigned.

Keep every entry-point mirror identical.
