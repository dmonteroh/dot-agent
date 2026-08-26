# status.sh — the status check

Runs as the entry point's first step, on the load path rather than at the
end of a session. It prints the recent session-log entries, then one line
per finding. Grooming rides the load path because routine end-of-task checks
breed fatigue and agent-claimed compliance can be phantom; this checks
artifacts, not claims.

```
Usage: status.sh [root]    # root defaults to . ; checks <root>/.agent/
```

## What it reports

| Prefix | Meaning |
|---|---|
| `GROOM:` | a file crossed its grooming threshold |
| `REPAIR:` | a canonical file is missing, lost its manifest, or a bootstrap step was never completed |
| `INDEX:` | a `docs/` file and the routing table disagree |
| `TOOLS:` | environment availability — advisory, not actionable |
| `LOAD:` | what the always-loaded set costs, in words — an advisory measurement printed every run, deliberately without a threshold |

No finding prints on pass; the recent entries and the `LOAD:` line are
information, not flags. **Always exits 0.** This is information on the load
path, not a completion gate — the binding instruction ("handle flags as part
of this session") lives in the entry point, which also names the delegation
path: `GROOM:` work may go to one subagent scoped to the flagged files.

## Thresholds

Review triggers, not caps: nothing refuses a write for size. Every number is
either a derivation from another stated value or an explicit chosen default.

| Key | Default | Where the number comes from |
|---|---|---|
| `LOG_MAX_ENTRIES` | 120 | chosen default |
| `LOG_MAX_WORDS` | 5000 | chosen default — the log is read as a tail every session, so it is groomed as a working file and archived, not grown |
| `LOG_ENTRY_MAX_WORDS` | 50 | the header contract's ≤25-word format with 2× grace |
| `MEMORY_MAX_WORDS` | 300 | chosen default, set well above one fact's natural size, so a flag reads as "probably more than one fact" |
| `MEMORY_MAX_ENTRIES` | 100 | chosen default — grooming regulates the index, the cap does not |
| `LEARNED_MAX_RULES` | 60 | chosen default |
| `LEARNED_MAX_WORDS` | 2400 | the 60-rule ceiling × the file's own ~40-word entry target, so it fires first when entries bloat past that target |
| `DOCS_MAX_WORDS` | 2000 | chosen default |
| `TAIL_LINES` | 25 | chosen default |
| `PROBE_TOOLS` | `rg fd jq gh python3 curl tree` | the tools a session is expected to have |

`learned.md` is always-loaded and has no disclosure tier, so every word of it
is paid on every session — which is why it carries both a rule count and a
word trigger.

The entry-shape check reads an entry as everything from its `- [` marker to
the next one, so a hand-wrapped narrative counts whole. It exists because the
format otherwise lives only in prose and in a writer any hand edit bypasses,
and every oversized entry rides the printed tail into every session's
context.

## The LOAD line

The one always-printed measurement: the always-loaded set's word total with
a per-file breakdown, plus the log tail the check just printed.

No threshold, on purpose. A per-file limit that is never summed is not a
limit, and three members of the set — `contract.md`, `purpose.md`, the
routing table — carry no per-file trigger at all. The line is what
accumulates the provenance a threshold would need.

## Configuration

`status.conf` beside the script, seeded by `node.sh init` and by `update`
only when absent. Plain `KEY=value`, parsed and never executed. Tune there,
never in the script: `node.sh update` refreshes the script and discards edits
to it, while the conf survives.

An uncommented line pins the value for this node; a commented line shows the
shipped default and keeps tracking the script until uncommented. `test.sh`
pins the conf's shown defaults to the script's own, so a default cannot drift
into documenting a lie.

## Notes on specific checks

- **Body word counts** exclude YAML frontmatter and `<!-- -->` header
  comments, so fixed per-file overhead never eats the fact budget. With two
  comments on one line the greedy strip also drops the words between them —
  a slight undercount on a review trigger.
- **Bootstrap completion** is checked because guardrails left as template
  placeholders, and a `## Quality bar` left inside `contract.md` instead of
  split into `rules/quality-bar.md`, are the two judgement steps nothing else
  can tell apart from a finished node. A placeholder spans several words
  (`<exact command(s)>`); a filled-in line's own angle brackets are
  single-token (`--grep <name>`), so the required space is what keeps a real
  command from reading as a stub.
- **Entry-point drift** compares only files that are actually dot-agent entry
  points, so a hand-written `AGENTS.md` of team instructions is left alone.
- **`docs/<area>/references/`** is the never-auto-loaded depth tier: no
  routing entry, no size trigger. Its files open only by explicit path from
  the area doc that cites them, so neither check applies.
- **The `INDEX:` section check is one-directional**: a routing entry may say
  more than the heading — a hand-written gloss routes better than a bare
  title — never less.
- **The memory index check** parses only each index line's own link, the
  first `[title](memory/…)`, so a hook that mentions another memory path is
  never counted.
