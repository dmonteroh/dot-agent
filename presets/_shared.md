# Shared preset text

Not a preset. Nothing copies this file into a node — `node.sh init` rejects
`--preset _shared`, and no bootstrap step reads it. It exists for whoever
edits `presets/`.

Every block below is text that must appear **word for word in all three
presets**. These are the rules that describe the `.agent/` operating model
rather than a domain: change one and you are changing all three, so change
them here first and carry the new text across in the same commit.

`scripts/test.sh` reads this file and asserts every block appears verbatim
in `software-development.md`, `academic-research.md`, and
`domain-knowledge.md`. That is what keeps this file honest — it is an
input to a check, not a description of one. A block that stops matching
fails the suite; a rule that stops being shared gets deleted from here in
the same change that makes it domain-specific.

Blocks are single-line substrings, not whole files: a shared sentence may
sit after domain-specific lead-in text on the same line, which is why the
check is a substring match rather than a line comparison. Section headings
are not tracked — all three presets carry the same ten, and where a rule
lives differs by design (the provenance rule sits under `Implementation`,
`Evidence and sources`, and `Knowledge discipline` respectively).

## Preamble

The retention test that governs what stays in any preset:

```
Retention test for every rule below: would a competent engineer joining this project already do this? Cut it. Is it specific to this project, this operating model, or a mistake this project actually made? Keep it at full strength.
```

## Kernel

The continuity obligation. Its slot number differs per preset — each domain
orders its own priorities — so only the text is shared:

```
Before finishing: append one session-log entry per its header template; add or update a `memory/` fact file and its index line only if durable facts changed.
```

## The domain section

`Implementation` / `Evidence and sources` / `Knowledge discipline` — one
rule, three section names:

```
- Numbers, defaults, and thresholds carry stated provenance: measured data, a named source, or an explicit chosen-default note. Fix an unjustified one when found; never defend it because it ships.
```

## Quality bar

The rubric's load-boundary preamble, the bootstrap instruction, and the two
criteria that judge `.agent/` rather than the domain:

```
<!-- Bootstrap splits this section out into `.agent/rules/quality-bar.md`. -->
```

```
This rubric is the judgement layer on top of the Verification contract above: that contract's behavioral rules (run the commands, classify failures, report honestly) stay always-loaded, every session. This rubric loads on demand: verifier subagents always, the main session only for substantial work. A verifier judges the result against:
```

```
- If a doc was tightened or split, the pass changed shape only: every name, value, command, path, and gotcha in the pre-edit version is still present, and the word count is backed by that check rather than standing in for it.
```

```
- `.agent/` reflects the change: memory superseded where durable facts changed, a session-log entry present.
```

## Continuity contract

The write-back contract. Only the `session-log.md` and `docs/` bullets carry
domain-specific text; everything else here is shared:

```
- Subagents: report continuity facts to the orchestrator; never edit `.agent/` unless explicitly assigned. The orchestrator is the single session-log writer.
```

```
- Before marking work complete, update `.agent/` per each file's header contract:
```

```
  - `memory/`: write the fact to `memory/<slug>.md` (prefer `.agent/scripts/memory.sh new`) — one fact per file, per its header contract: a decision, term, preference, or active blocker — then add or update its index line in `memory.md`. Supersede in place, don't append. If nothing durable changed, leave both unchanged and say so in the log entry.
```

The shared tail of the `docs/` bullet — each preset writes its own lead-in
clause naming what triggers a docs update in that domain, then joins here:

```
Area docs are agent-facing reference: state facts as tables or one-fact-per-line bullets and let prose carry only the *why*. Tightening or splitting a doc changes its shape, never its content — no such pass may drop a name, value, command, path, or gotcha. When a doc's headings or scope change, refresh its `architecture.md` entry — the hook and the `Sections:` list both — in the same change; `status.sh` flags either one drifting.
```

```
- Record user corrections, durable preferences, and repeated patterns in memory with a trigger or confidence tag.
```

```
- Fix stale memory, outdated docs, and duplication when encountered.
```

```
- Act on GROOM:/REPAIR:/INDEX: flags from the bootstrap status check in the same session. GROOM: work may be delegated to one subagent (a small model is fine) explicitly assigned to write only the flagged files; re-run status.sh to confirm it cleared. REPAIR: stays in the main session.
```

## Self-learning

The retro trigger and the entry format. What each preset routes *to* differs
(area docs, source notes, catalogs), so the routing bullet is not shared:

```
- After a user correction, a failed verification that needed a non-obvious fix, or a mid-task deviation from an agreed plan, record the lesson:
```

```
  `- [YYYY-MM-DD] <imperative rule>. Trigger: <cause, only if it adds information>.`
```
