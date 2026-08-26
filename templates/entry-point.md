<!-- Canonical entry-point template. Copy into each tool's entry-point
filename (CLAUDE.md, AGENTS.md; plus .github/copilot-instructions.md when
the team uses Copilot Chat or code review — the operating model's wiring
matrix records what each tool reads), fill every <…> placeholder, and
delete this comment. Root nodes write every path absolute (bash
~/.agent/scripts/status.sh ~, ~/.agent/rules/…) since sessions run from
project directories. Keep all entry points identical. -->
# <Project> — Session Bootstrap

<One line: stack, key dirs, package managers.> Binding rules and state load
in the steps below — do not answer, plan, or edit before completing them.

Execute with tools, in order:

1. Run `bash .agent/scripts/status.sh` — prints recent session-log entries
   plus any GROOM:/REPAIR:/INDEX: flags and TOOLS: notes; handle flags as
   part of this session, treat TOOLS: notes as advisory. GROOM: work may
   go to one dispatched subagent (a small model is fine) explicitly
   assigned to write only the flagged files; re-run status.sh to confirm.
2. Read `.agent/rules/learned.md` — accumulated corrections; binding.
3. Read `.agent/rules/contract.md` — binding.
4. Read `.agent/purpose.md` — scope and boundaries.
5. Read `.agent/memory.md` — the fact index; open the `memory/` fact
   files whose hooks match the task.
6. <Routing: pick area docs via the table in `.agent/docs/architecture.md`;
   read only what the task needs.>

After a context compaction or handoff, re-run steps 1–5 before continuing.
These steps run once at session start, so a compacted session is a session
operating without them; re-route step 6 only if the work moved.

Before handing back a diff, run `bash .agent/scripts/comments.sh` — delete
what it blocks (comments citing artifacts a fresh clone cannot open) and
justify or delete every comment it lists. Its vocabulary lives in
`.agent/scripts/comments.conf`.

Exception — subagents: skip step 1 (flags are the orchestrator's to
handle); read everything else. Never edit `.agent/` unless explicitly
assigned — the orchestrator is the single session-log writer.

Keep every entry-point mirror identical; when editing one, mirror the others.
