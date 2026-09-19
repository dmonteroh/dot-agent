# status.sh — the status check

Runs as the entry point's first step, on the load path rather than at the end of a session. It prints the recent session-log entries, then one line per finding. Grooming rides the load path because routine end-of-task checks breed fatigue and agent-claimed compliance can be phantom. This checks artifacts, not claims.

```
Usage: status.sh [--load] [root]    # root defaults to . — checks <root>/.agent/
```

## What it reports

| Prefix | Meaning |
|---|---|
| `GROOM:` | a file crossed its grooming threshold |
| `REPAIR:` | a canonical file is missing, lost its manifest, or a bootstrap step was never completed |
| `INDEX:` | a `docs/` file and the routing table disagree |
| `TOOLS:` | environment availability — advisory, not actionable |
| `LOAD:` | what the always-loaded set costs, in words — an advisory measurement printed every run, deliberately without a threshold |
| `PAYLOAD:` | the exact bytes `--load` would write — the mode's own emitted set, markers included — against `PAYLOAD_MAX_BYTES` |

No finding prints on pass. The recent entries and the `LOAD:` and `PAYLOAD:` lines are information, not flags. **No finding reaches the exit status**, which is 0 for every node the check can read: this is information on the load path, not a completion gate. The one non-zero exit is a usage error — a root holding no `.agent/` — which is not a finding about a node and must never be reported as one. The binding instruction ("handle flags as part of this session") lives in the entry point, which also names the delegation path. `GROOM:` work may go to one subagent scoped to the flagged files.

## Thresholds

Review triggers, not caps: nothing refuses a write for size. Every number is either a derivation from another stated value or an explicit chosen default.

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
| `ENTRYPOINT_MAX_WORDS` | 600 | the canonical template's ~289-word body, ~300 once filled, with 2× grace |
| `TAIL_LINES` | 25 | chosen default |
| `PAYLOAD_MAX_BYTES` | 30000 | the harness's tool-result cap — "about 30 KB on Claude Code, measured" (see `--load` below and `operating-model.md`) — not a chosen headroom figure |
| `PROBE_TOOLS` | `rg fd jq gh python3 curl tree` | the tools a session is expected to have |

`learned.md` is always-loaded and has no disclosure tier, so every word of it is paid on every session — which is why it carries both a rule count and a word trigger.

## `--load`

`status.sh --load` prints the always-loaded set after the findings, in the entry point's order, each under a `==== <path> ====` marker naming it. In manual mode (`indexes: manual`, the default) that set is `rules/learned.md`, `rules/contract.md`, `purpose.md`, `memory.md`, unchanged from before generated mode existed. In generated mode (`indexes: generated`) it is `purpose.md` and `memory.md` only: the rule bodies and the routing table already arrived as the pages named by the entry file at `.agent/indexes/current.md`, which bootstrap's first step opens before this one runs, so printing them again here would pay for the same context twice. `--load` marks the difference with one line ahead of the files it does print in that mode: `Rule bodies are not printed here — read every page listed in .agent/indexes/current.md.` The entry point's bootstrap is then one tool call instead of several, and the session reads the mode's files from that output rather than opening them again. The text is the same either way; only the call count, and in generated mode the file count, changes, and a session's cost scales with its calls. The printed set must fit the harness's tool-result cap (about 30 KB on Claude Code, measured); a filled contract plus the three small files is under 20 KB in manual mode and well under it in generated mode, and the `LOAD:` line is the number to watch as a node grows.

The cap is enforced, not just watched. Every run prints a `PAYLOAD:` line measuring the exact bytes `--load` would write — the mode's own set, in bytes, with each file's `==== <path> ====` marker overhead included — against `PAYLOAD_MAX_BYTES` (default 30000, tunable in `status.conf`). `LOAD:` and `PAYLOAD:` price what the mode actually emits, on purpose measuring different things: `LOAD:` is what the session ends up holding, in words, and includes members `--load` never prints (`architecture.md`, the entry point, and in generated mode the index pages themselves); `PAYLOAD:` is what one tool call carries, in bytes, and covers only what `--load` actually emits in that mode. When the total exceeds the budget — strictly, a payload exactly at the budget still emits in full — `--load` prints one `REPAIR:` line naming the mode's own paths (all four in manual mode, the two in generated mode) and writes no marker and no file content at all: overflow suppresses the whole payload rather than risk the harness truncating mid-file, which is the same failure with a different cause. The `REPAIR:` line does not change the exit status.

The memory `GROOM:` line names what a groom must carry over: every ticket id, constant, path, host, command, date, number with a unit, and backticked span the flagged fact holds, extracted by word shape. An undercount leaves a fact unlisted and an overcount lists a plain word; neither is a judgement about meaning. It turns "shape, never content" into a checklist the session can tick.

The entry-shape check reads an entry as everything from its `- [` marker to the next one, so a hand-wrapped narrative counts whole. It exists because the format otherwise lives only in prose and in a writer any hand edit bypasses, and every oversized entry rides the printed tail into every session's context.

## The LOAD line

The one always-printed measurement: the always-loaded set's word total with a per-file breakdown, plus the log tail the check just printed.

No threshold, on purpose. A per-file limit that is never summed is not a limit, and three members of the set — `contract.md`, `purpose.md`, the routing table — carry no per-file trigger at all. The line is what accumulates the provenance a threshold would need.

## Configuration

`status.conf` beside the script, seeded by `node.sh init` and by `update` only when absent. Plain `KEY=value`, parsed and never executed. A key written twice takes its first line. Tune there, never in the script: `node.sh update` refreshes the script and discards edits to it, while the conf survives.

An uncommented line pins the value for this node. A commented line shows the shipped default and keeps tracking the script until uncommented. `test.sh` pins the conf's shown defaults to the script's own, so a default cannot drift into documenting a lie.

## Notes on specific checks

- **Body word counts** exclude YAML frontmatter and `<!-- -->` header comments, so fixed per-file overhead never eats the fact budget. With two comments on one line the greedy strip also drops the words between them — a slight undercount on a review trigger.
- **`rules/contract.md` and the learned rules** are canonical and always-loaded — the entry point's bootstrap step reads both every session — so either one missing or empty draws its own `REPAIR:` finding, the same `[[ -s "$f" ]]` shape used for `memory.md` and `session-log.md`: `REPAIR: rules/contract.md missing/empty — restore it, the entry point loads it every session`, and, only when neither `rules/learned/` holds a record nor `rules/learned.md` has content, `REPAIR: rules/learned/ missing/empty — restore the records, or rules/learned.md on a node that keeps no record directory; the entry point loads them every session`. Whenever `rules/learned/` exists and holds at least one `*.md` record, those records are the canonical source in place of the aggregate: the `LEARNED_MAX_RULES` and `LEARNED_MAX_WORDS` thresholds above then sum every record file's own bullets and body words rather than one file's, and still draw the same `GROOM: rules/learned/ > …` line at the same numbers; `rules/learned.md` is read only as the fallback on a node with no record directory yet. This is separate from the bootstrap-completion checks below, which only run once `contract.md` exists and test its content, not its presence.
- **A missing, stale, or damaged `.agent/indexes/`** draws no `GROOM:`, `REPAIR:`, or `INDEX:` line: no status finding names a path under it, because the cache is disposable and the next `index.sh ensure` rebuilds it from the canonical `rules/` and `docs/` sources this check already reads. The fault surfaces instead as `index.sh`'s own non-zero exit and its `ERROR:` and `FALLBACK:` stderr lines, which name those canonical directories to read directly meanwhile.
- **A pending migration** draws its own `REPAIR:` finding: `node.sh update` sets `migration_target` in the manifest before it mutates anything else and leaves `version` at its pre-migration value until `node.sh finalize` stamps it, so a manifest holding `migration_target` is mid-migration no matter how clean everything else checks — this line names the pending target and the `finalize` command so the finding is actionable without opening the manifest: `REPAIR: purpose.md has migration_target "<target>" pending — run node.sh finalize to stamp version <target> and clear migration_target`. `finalize` itself excludes this one line from the findings that gate it — true by definition until the run that clears it — so a pending node isn't refused unconditionally.
- **Bootstrap completion** is checked because guardrails left as template placeholders, and a `## Quality bar` left inside `contract.md` instead of split into `rules/quality-bar.md`, are the two judgement steps nothing else can tell apart from a finished node. A placeholder spans several words (`<exact command(s)>`). A filled-in line's own angle brackets are single-token (`--grep <name>`), so the required space is what keeps a real command from reading as a stub.
- **Entry-point drift** compares only files that are actually dot-agent entry points, so a hand-written `AGENTS.md` of team instructions is left alone. The same set carries the `ENTRYPOINT_MAX_WORDS` threshold: an entry point is wiring, and what grows past the template's size is project scope, constraints, or architecture restated from `purpose.md` and `docs/`, which the load path opens two steps later anyway. It is the copy no check reads and no groom pass touches, paid on every message by every tool that keeps the file resident.
- **Entry-point sections** are flagged whatever the file's size. The threshold measures bloat and the boundary is what actually breaks: a deploy command and a branch convention appended under a new `## Operations` heading cost a tenth of `ENTRYPOINT_MAX_WORDS` and never reach the node at all, so no later session finds them where the rules say they live. The canonical template is a title and a load path with no second heading anywhere, so any heading below the title is a section — content that belongs in `Project guardrails`, `purpose.md`, or a routed doc — and the flag names the first one it finds. Mirroring keeps the drift check quiet while the content stays in the wrong file, which is why the shape is checked and not only the count.
- **`docs/<area>/references/`** is the never-auto-loaded depth tier: no routing entry, no size trigger. Its files open only by explicit path from the area doc that cites them, so neither check applies.
- **The `INDEX:` section check is one-directional**: a routing entry may say more than the heading — a hand-written gloss routes better than a bare title — never less.
- **A missing `architecture.md` with routed docs already present** draws its own `REPAIR:` finding, not an `INDEX:` one. The three routing checks above all sit inside `[[ -s "$arch" ]]`, correctly — each compares a doc against its entry in a table that has to exist first — but that guard leaves the table's own absence unchecked: a node whose `docs/` holds routed documents and no `architecture.md` at all passed silently. `docs.sh` creates `architecture.md` automatically the first time a doc is scaffolded, so this state only reaches a hand-edited or partially copied node. It is `REPAIR:` and not `INDEX:` because `INDEX:` means a `docs/` file and the routing table *disagree* — both sides have to exist for there to be a disagreement. A missing table is an absent canonical file, the same class as a missing `contract.md` or `learned.md`, so it takes the `REPAIR:` prefix instead. The check walks `docs/*.md` and `docs/*/*.md`, the same membership the routing loop above uses — excluding `architecture.md` itself and anything under a `references/` path, since that tier has nothing to route — and stops at the first routed doc found, so the node draws exactly one line no matter how many routed docs it holds.
- **The memory index check** parses only each index line's own link, the first `[title](memory/…)`, so a hook that mentions another memory path is never counted.
- **The native-memory check** reads only three settings files — `.claude/settings.json`, `.claude/settings.local.json`, and `$HOME/.claude/settings.json` — textually, for one key, `autoMemoryEnabled`. It does not evaluate the tool's managed or enterprise settings, command-line setting overrides, or environment overrides, so a clean result establishes only that these files request the tool's own store off, not that it is off.
