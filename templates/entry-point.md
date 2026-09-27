<!-- Canonical entry-point template — manual indexes mode (the default). Copy into each tool's entry-point filename (CLAUDE.md and AGENTS.md, plus .github/copilot-instructions.md when the team uses Copilot Chat or code review). Use templates/entry-point-generated.md instead when the node's purpose.md manifest carries `indexes: generated`; the two stay identical mirrors only within one node's own set of tool files, never across the two modes. The operating model's wiring matrix records what each tool reads. Fill every <…> placeholder, then delete this comment. Root nodes write every path absolute (bash ~/.agent/scripts/status.sh ~, ~/.agent/rules/…) since sessions run from project directories. Keep all entry points identical. This file is wiring — the load path and nothing else. Never grow it into a second copy of `.agent/purpose.md`: `status.sh` flags any heading below the title, because a new section here is project content that never reached `.agent/`. -->
# <Project> — Session Bootstrap

<One line: stack, key dirs, package managers.> Everything else lives in `.agent/` and loads below. Never restate it here and never add a section.

**One conversation is one session: the steps below run once in it**, with tools. A new user message does not start a new session. Do not open this file with a tool when its content is already present in your context. Load the node before working on the request.

1. Run `bash .agent/scripts/status.sh --load` and read its output: rules, purpose, memory index, and recent entries. Resolve REPAIR:/INDEX: findings before relying on affected context. GROOM: handling follows checkpoint policy.
2. Open the `memory/` fact files whose hooks match the task.
3. <Routing: pick area docs via the table in `.agent/docs/architecture.md`. Read only what the task needs.>

After a context compaction or handoff, run step 1 again. re-route step 3 if the work moved.

Before handing back changed work, run `bash .agent/scripts/checkpoint.sh --tool <tool> --area <area> --checks <configured-check> --summary "<task and outcome, at most 25 words>"`. It runs verification, review, status, and logging. Reuse a current receipt with `--verification <id>`. For failed or manual-only work, use `--verify fail` or `--verify n/a`. Use `--base <ref>` for committed work, or `--node-only` for an explicit ignored-node write. Fix blocking findings and retry. Unchanged completed content logs once. Read-only turns need no entry.

Check names live in `.agent/scripts/checks.sh`. Helper `--help` explains details. `checkpoint.conf` controls maintenance policy.

Subagents: flags and `checkpoint.sh` are the orchestrator's. read the rest. edit `.agent/` only when assigned.

Keep every entry-point mirror identical.
