<!-- Canonical entry-point template — manual indexes mode (the default). Copy into each tool's entry-point filename (CLAUDE.md and AGENTS.md, plus .github/copilot-instructions.md when the team uses Copilot Chat or code review). Use templates/entry-point-generated.md instead when the node's purpose.md manifest carries `indexes: generated`; the two stay identical mirrors only within one node's own set of tool files, never across the two modes. The operating model's wiring matrix records what each tool reads. Fill every <…> placeholder, then delete this comment. Root nodes write every path absolute (bash ~/.agent/scripts/status.sh ~, ~/.agent/rules/…) since sessions run from project directories. Keep all entry points identical. This file is wiring — the load path and nothing else. Never grow it into a second copy of `.agent/purpose.md`: `status.sh` flags any heading below the title, because a new section here is project content that never reached `.agent/`. -->
# <Project> — Session Bootstrap

<One line: stack, key dirs, package managers.> Everything else about this project lives in `.agent/` and loads in the steps below. Never restate it here.

**The whole conversation is one session, and the steps below run once in it.** A new user message does not start a new session. If earlier turns completed steps 1–2, they still hold: continue from that context without running them again or re-reading those files. Do not open this file with a tool when its content is already present in your context. Do not answer, plan, or edit before the steps have run; a one-line request — remember this, summarise that, handle that — is a task like any other.

Execute with tools, in order:

1. Run `bash .agent/scripts/status.sh --load` — one call, unless a `dot-agent session-start hook` block holds its output. It prints GROOM:/REPAIR:/INDEX: flags and TOOLS: notes, the four always-loaded files in order: `.agent/rules/learned.md` (accumulated corrections, binding), `.agent/rules/contract.md` (binding), `.agent/purpose.md` (scope and boundaries), `.agent/memory.md` (the fact index), then recent session-log entries. Read them there; do not reopen them with a tool. Resolve REPAIR:/INDEX: findings before relying on affected context. GROOM: handling follows checkpoint policy.
2. Open the `memory/` fact files whose hooks match the task.
3. <Routing: pick area docs via the table in `.agent/docs/architecture.md`. Read only what the task needs.> For a change, `bash .agent/scripts/docs.sh route --base <ref>` names the docs it touches; the table stays the catalog.

The one re-run. After a context compaction or handoff, run step 1 again. A summary is lossy, and a compacted session cannot judge what it kept. Re-route step 3 only if the work moved.

Before handing back changed work, run `bash .agent/scripts/checkpoint.sh --tool <tool> --area <area> --checks <configured-check> --summary "<task and outcome, ≤25 words, no paths or ids>"`. It runs review, status, verification, and logging. Reuse a current receipt with `--verification <id>`. Failed or manual-only work takes `--verify fail` or `--verify n/a`. Use `--node-only` for an explicit ignored-node write. Fix blocking findings and retry. Unchanged completed content logs once. Read-only turns need no entry.

Check names live in `.agent/scripts/checks.sh`. Helper `--help` explains details. `checkpoint.conf` controls maintenance policy.

Exception — subagents: flags are the orchestrator's to handle, and so is `checkpoint.sh`. So are the configured checks; run focused tests directly. Read everything else. Write `.agent/` only through its scripts, lessons only.

Keep every entry-point mirror identical.
