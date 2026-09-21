# links.sh — the link audit

An on-demand audit of a node's link graph. Not on the load path: run it when grooming, before a restructuring pass, or whenever you want to know what the node holds that nothing points at.

```
Usage: links.sh [root]    # root defaults to . — audits <root>/.agent/
```

## What it reports

| Finding | Meaning |
|---|---|
| `ORPHAN:` | a file nothing in the node cites |
| `BROKEN:` | a path a node file cites that does not exist |

Findings are review triggers, not errors: an orphan is often a file that should be cited, sometimes one that should be deleted, occasionally neither. **No finding reaches the exit status** — the report is the product. The one non-zero exit is a usage error: a root holding no `.agent/`, which is not a finding about a node.

## Scope

The reference tier is what motivated it. `docs/<area>/references/` files carry no routing entry by design, so an uncited one is unreachable and `status.sh` cannot see it. The walk covers every non-exempt file.

Scope is the node's own link graph. A path pointing outside `.agent/` — a source file, a task brief under `temp/` — is the project's to manage and its lifecycle is not the node's business, so it is never reported. Without that rule the report is dominated by session-log entries citing task briefs that were legitimately archived months earlier: a record of what happened, not a claim that the path still resolves.

Shape alone cannot tell a project file from a node file. A bare `SKILL.md` looks exactly like a bare `learned.md`, and node docs really do cite each other by bare name. So an unresolved name is checked against the project's markdown too, not only the node's. A memory fact naming a real project file that sits in a subdirectory rather than at the project root is not a broken link.

What no script can settle is a path naming a file in a *third* repo — a skill documenting where its consuming project should keep its config. That one stays reported, because the audit is tuned to over-report rather than to miss a real dangling link, and because a finding here is a review trigger and not an error.

The session log, `archive/`, and `rules/` are read as records and instructions rather than as citations.

## Exemptions

Files exempt from the `ORPHAN:` check, and why each is reached by a route the link graph cannot see:

| Exempt | Reason |
|---|---|
| the canonical files | loaded by name from the entry point, so nothing cites them by path |
| `memory/` | already checked both directions by `status.sh`'s `REPAIR:` pass |
| `archive/` | retired content, on purpose |
| `scripts/` | executables wired by the entry point, which lives outside the node |
| `skills/` and its siblings | the operating model places them outside itself: never loaded, never groomed, never audited |

Three sources are excluded from the `BROKEN:` walk because they name files in a different genre than citation:

- **`session-log.md` and `archive/`** are historical records. An entry naming a since-archived brief is doing its job.
- **`rules/`** is instruction, naming the node's furniture prescriptively ("pick area docs via architecture.md") whether or not the node has grown that file yet.

## Implementation notes

- Matching is loose on purpose: a citation resolves against a file's node-relative path *or* its bare basename, because docs cite each other both ways — `docs/backend.md` from the routing table, `references/error-codes.md` from the doc beside it. A false "cited" is quieter than a false orphan.
- One `grep -l` over the whole corpus per candidate, never one per (candidate, file) pair. The pairwise form is quadratic in processes and becomes unusable on a large node while returning the same answer.
- `<!-- -->` comments are stripped before a file is read for citations. Header contracts live in comments and state formats by example — `memory.md`'s says `- [Title](memory/slug.md) — hook` — so a comment is a spec, not a citation, and reading one as a link invents a broken path on every node.
