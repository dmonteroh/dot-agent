<!-- Canonical entry-point template — generated indexes mode. Copy into each tool's entry-point filename (CLAUDE.md and AGENTS.md, plus .github/copilot-instructions.md when the team uses Copilot Chat or code review). Use this file, not templates/entry-point.md, when the node's purpose.md manifest carries `indexes: generated`; the two stay identical mirrors only within one node's own set of tool files, never across the two modes. The operating model's wiring matrix records what each tool reads. Fill every <…> placeholder, then delete this comment. Root nodes write every path absolute (bash ~/.agent/scripts/status.sh ~, ~/.agent/rules/…) since sessions run from project directories. Keep all entry points identical. This file is wiring — the load path and nothing else. Never grow it into a second copy of `.agent/purpose.md`: `status.sh` flags any heading below the title, because a new section here is project content that never reached `.agent/`. -->
# <Project> — Session Bootstrap

<One line: stack, key dirs, package managers.> Everything else lives in `.agent/` and loads below. Never restate it here and never add a section.

**One conversation is one session: the steps below run once in it**, with tools. A new user message does not start a new session. Do not open this file with a tool when its content is already present in your context. Do not answer, plan, or edit before the steps have run; a one-line request — remember this, summarise that, handle that — is a task like any other.

1. Run `bash .agent/scripts/index.sh ensure` and read the entry path it prints.
2. Run `bash .agent/scripts/status.sh --load` — recent log entries, GROOM:/REPAIR:/INDEX: flags (handle them this session; GROOM: may go to one subagent writing only the flagged files — wait, then re-run), TOOLS: notes (advisory), then `rules/learned.md` and `rules/contract.md` (binding), `purpose.md`, `memory.md`. Read them from that output; never open them again.
3. Open the `memory/` fact files whose hooks match the task.
4. <Routing: pick area docs via the table in `.agent/docs/architecture.md`. Read only what the task needs.>

After a context compaction or handoff, run step 2 again; re-route step 4 if the work moved.

Before handing back a turn that changed files, run `bash .agent/scripts/finish.sh --tool <tool> --area <area> --verify <pass|fail|n/a> --summary "<task, outcome, ≤25 words>"` — the comment gate (`--base <ref>` for committed work), the status check, then the log entry, written once on the clean run. Fix what it names and run it again. A turn that only answered writes no entry: finish.sh refuses one over an unchanged tree. Your final message is the report itself, never a wrap-up line.

Subagents: flags and `finish.sh` are the orchestrator's; read the rest; edit `.agent/` only when assigned.

Keep every entry-point mirror identical.
