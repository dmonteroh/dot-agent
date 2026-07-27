# Claude Code compliance hooks

Optional compliance tooling for the [dot-agent operating model](../../operating-model.md), Claude-Code-only.

Without these hooks, the operating model's trust contracts are convention: the agent follows them because the rules say to. These hooks add a mechanical check on top: they block the session when a contract is violated. They are optional and unused in the reference deployments, where the trust contract carries compliance.

**V6.1 realignment:** `pre-work.py` and `retro.py` hold up unchanged. Two hooks predated the V6 contracts and needed a decision, not just an align-in-place:

- `self-maintenance.py` is **unsupported** and not wired in `settings-example.json`. It blocked Stop until `memory.md` changed checksum in every discovered node — wrong once V6 made the memory update conditional (write it only if durable facts changed) and made the orchestrator the single session-log writer, and wronger once V6.1 turned `memory.md` into an index rather than a fact store. No mechanical check replaces it: whether "durable facts changed" is true this session is a judgement call a file diff can't make. The file stays in the repo with a header explaining this; do not install it without rewriting it.
- `correctness.py` is **supported**, unchanged in behavior. Its re-read check only ever required *a* re-read of an edited file's path, full or partial — it never actually enforced full-file re-reads. This README previously described it as if it did; that description is now corrected to match the code, which already matched the presets' "re-read edited regions with context" calibration.

`settings-example.json` also ships `"autoMemoryEnabled": false`. Independent of the hooks, this is the setting the bootstrap copies so `.agent/` stays the sole durable memory (see the operating model's [Native tool memory](../../operating-model.md#native-tool-memory)).

## What's enforced

| Hook | Status | Events | What it does |
|------|--------|--------|-------------|
| `pre-work.py` | Supported | PreToolUse | Blocks edits to project files until that project's `.agent/purpose.md` and `.agent/memory.md` have been read. Only triggers for projects with `.agent/`. |
| `correctness.py` | Supported | PreToolUse + Stop | Tracks file edits, re-reads, and test/build commands during the session. On Stop, blocks if edited files weren't read again or if source files changed without tests being run. |
| `self-maintenance.py` | **Unsupported — not wired by default** | PreToolUse + Stop | V5-era: blocked session end until `session-log.md` and `memory.md` both changed checksum in every discovered `.agent/` dir. See the V6.1 realignment note above; kept for reference only. |
| `retro.py` | Supported | Stop | After substantial sessions (source files changed, hooks caught mistakes, or long session), prompts the agent to reflect on behavioral lessons and write rules to `rules/learned.md`. |

### Hook execution order

**PreToolUse:** pre-work → correctness

**Stop:** correctness → retro

Order matters for Stop: correctness checks your work, retro reflects on the whole session — it reads correctness's checkpoint to know if the safety valve fired. `self-maintenance.py` is not wired; if you install it anyway after rewriting it, it was designed to run between the two.

## Prerequisites

- **Python 3.10+**: hooks use modern type syntax (`Path | None`) that requires 3.10 or later. Check with `python3 --version`.

## Install

```bash
mkdir -p ~/.claude/hooks
cp hooks/pre-work.py hooks/correctness.py hooks/retro.py ~/.claude/hooks/

# Merge settings-example.json into your ~/.claude/settings.json
# (add the hooks and permissions sections)
```

Or symlink for auto-updates:

```bash
for hook in pre-work.py correctness.py retro.py; do
    ln -sf /path/to/dot-agent/tools/claude-code/hooks/$hook ~/.claude/hooks/$hook
done
```

`self-maintenance.py` is excluded from both: it's unsupported (see above) and `settings-example.json` doesn't wire it. It's still readable in `hooks/` if you want to rewrite it yourself.

## Safety valves

All Stop hooks follow the same pattern: block once, then let through on second attempt. This prevents infinite loops when the agent genuinely can't satisfy the contract (e.g. no tests exist in the project, or a read-only session that doesn't need documentation).

## Checkpoints

Each hook stores session state in `/tmp/`:

| Hook | Checkpoint dir |
|------|---------------|
| `pre-work.py` | `/tmp/claude-pre-work/` |
| `correctness.py` | `/tmp/claude-correctness/` |
| `retro.py` | `/tmp/claude-retro/` |

(`self-maintenance.py` still has a checkpoint dir, `/tmp/claude-self-maintenance/`, in its own code — moot while it's unwired.)

Checkpoints are per-session (keyed by session ID) and auto-cleaned after 24 hours.

## Extending

These are **core** hooks: they enforce the operating model contract and nothing more.

To add custom behavior (daily bootstrap, inbox enforcement, maintenance prompts, diary nudges, etc.), copy the hooks and extend them. Extensions should be a strict superset: include all core behavior plus your additions. Installing extended hooks replaces the core ones.
