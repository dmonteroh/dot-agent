<!-- Canonical entry-point template — manual indexes mode (the default). Copy into each tool's entry-point filename (CLAUDE.md and AGENTS.md, plus .github/copilot-instructions.md when the team uses Copilot Chat or code review). Use templates/entry-point-generated.md instead when the node's purpose.md manifest carries `indexes: generated`; the two stay identical mirrors only within one node's own set of tool files, never across the two modes. The operating model's wiring matrix records what each tool reads. Fill every <…> placeholder, then delete this comment. Root nodes write every path absolute (bash ~/.agent/scripts/status.sh ~, ~/.agent/rules/…) since sessions run from project directories. Keep all entry points identical. This file is wiring — the load path and nothing else. Never grow it into a second copy of `.agent/purpose.md`: `status.sh` flags any heading below the title, because a new section here is project content that never reached `.agent/`. -->
# <Project> — Session Bootstrap

<One line: stack, key dirs, package managers.> Everything else about this project lives in `.agent/` and loads in the steps below. Never restate it here.

**The whole conversation is one session, and the steps below run once in it.** A new user message does not start a new session. If earlier turns completed steps 1–2, they are still in effect: continue from that context, do not run them again, and do not re-read those files. Do not open this file with a tool when its content is already present in your context. Do not answer, plan, or edit before the steps have run; a one-line request — remember this, summarise that, handle that — is a task like any other.

Execute with tools, in order:

1. Run `bash .agent/scripts/status.sh --load` — one call. It prints recent session-log entries, any GROOM:/REPAIR:/INDEX: flags and TOOLS: notes, then the four always-loaded files in order: `.agent/rules/learned.md` (accumulated corrections, binding), `.agent/rules/contract.md` (binding), `.agent/purpose.md` (scope and boundaries), `.agent/memory.md` (the fact index). Read them from that output; do not open them again with a tool. Resolve REPAIR:/INDEX: findings before relying on affected context. GROOM: handling follows checkpoint policy.
2. Open the `memory/` fact files whose hooks match the task.
3. <Routing: pick area docs via the table in `.agent/docs/architecture.md`. Read only what the task needs.>

The one re-run. After a context compaction or handoff, run step 1 again. A summary is lossy by construction, so a compacted session is a session operating without it, and it is not in a position to judge what it kept. Re-route step 3 only if the work moved.

Before handing back changed work, run `bash .agent/scripts/checkpoint.sh --tool <tool> --area <area> --checks <configured-check> --summary "<task and outcome, at most 25 words>"`. It runs verification, review, status, and logging. Reuse a current receipt with `--verification <id>`. For failed or manual-only work, use `--verify fail` or `--verify n/a`. Use `--base <ref>` for committed work, or `--node-only` for an explicit ignored-node write. Fix blocking findings and retry. Unchanged completed content logs once. Read-only turns need no entry.

Check names live in `.agent/scripts/checks.sh`. Helper `--help` explains details. `checkpoint.conf` controls maintenance policy.

Exception — subagents: flags are the orchestrator's to handle, and so is `checkpoint.sh`. Read everything else. Write `.agent/` only through its scripts, and log with `log.sh`.

Keep every entry-point mirror identical. When editing one, mirror the others.
