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
| `STALE:` | a project path a stamped doc cites changed, or was removed or renamed, in a commit after the doc's stamp |

Findings are review triggers, not errors: an orphan is often a file that should be cited, sometimes one that should be deleted, occasionally neither. **No finding reaches the exit status** — the report is the product. The two non-zero exits are not findings about a node: a root holding no `.agent/`, which is a usage error, and a temporary folder links.sh cannot create. The file lists it reads go through that folder rather than the command line, so a node with thousands of docs is audited in full.

## Scope

The reference tier is what motivated it. `docs/<area>/references/` files carry no routing entry by design, so an uncited one is unreachable and `status.sh` cannot see it. The walk covers every non-exempt file.

Scope is the node's own link graph. A path pointing outside `.agent/` — a source file, a task brief under `temp/` — is the project's to manage and its lifecycle is not the node's business, so it is never reported as `ORPHAN:` or `BROKEN:`. The drift check below reads such paths for a different question. Without that rule the report is dominated by session-log entries citing task briefs that were legitimately archived months earlier: a record of what happened, not a claim that the path still resolves.

Shape alone cannot tell a project file from a node file. A bare `SKILL.md` looks exactly like a bare `learned.md`, and node docs really do cite each other by bare name. So an unresolved name is checked against the project's markdown too, not only the node's. A memory fact naming a real project file that sits in a subdirectory rather than at the project root is not a broken link.

Which project files count depends on the root:

| Root | Project files that resolve a name |
|---|---|
| in a git repository | the Markdown git lists under the root: tracked files, the tracked files of initialized submodules, and untracked files that no ignore rule covers |
| outside git, or ignored by the repository around it | every Markdown file a `find` walk reaches under the root |

In a git repository, an ignored file does not resolve a citation by its bare name or by the end of its path. Such a citation reports `BROKEN:`. A citation whose whole path exists still resolves when git ignores the file. The path is tried from the project root, from the node, and from the citing file's directory. A tracked file deleted from the checkout does not count. The node's own files under `.agent/` keep their own walk, so a node that git ignores is audited in full. A child node that git ignores is an ignored file like any other, so its files no longer resolve a bare name cited by the parent node.

What no script can settle is a path naming a file in a *third* repo — a skill documenting where its consuming project should keep its config. That one stays reported, because the audit is tuned to over-report rather than to miss a real dangling link, and because a finding here is a review trigger and not an error.

The session log, `archive/`, and `rules/` are read as records and instructions rather than as citations.

## The drift check

`ORPHAN:` and `BROKEN:` check the node's structure. Neither notices that the code a doc describes changed after the doc was written. The drift check covers that case, for the docs that opt in.

A doc under `docs/` opts in by carrying a stamp on the line after its `Read when:` header:

```markdown
<!-- Read when: touching payments -->
<!-- Checked: abc1234 -->
# Payments
```

The stamp is the commit at which someone last read the code the doc cites and confirmed the doc matches it. `docs.sh check --name <doc>` writes it, and `docs.sh new` stamps a new doc at creation. links.sh only reads the stamp. It never moves it, because a stamp moved by the audit would record a check nobody made. `absorb.sh docs` drops a worker's stamp that names a commit the main checkout's `HEAD` does not contain, so a doc integrated by cherry-pick reads as unchecked instead of stale (see `absorb.md`).

For each stamped doc, links.sh collects the project paths it cites: backticked tokens and markdown link targets that resolve to an existing file or directory outside `.agent/`. A path resolves against the project root or against the doc's own directory. A trailing `:<line>` on a backticked path is dropped. It then asks git which commits after the stamp touched each path:

```
STALE: docs/payments.md cites src/client.ts, changed in 3 commits since checked at abc1234
```

A cited path that no longer exists is checked against the tree at the stamp. If git held it there, it was removed or renamed since, and the line says so:

```
STALE: docs/payments.md cites src/retry.ts, removed or renamed in 1 commit since checked at abc1234
```

A backticked word that git never held at the stamp is not a path, so it is never reported.

A commit that also changed the doc is not counted. The doc moved with the code, which is what restamping in the same change records. One summary line follows: how many docs are stamped, how many are not, and how many citations are stale.

Three cases print one line instead of findings, and none of them changes the exit status:

| Case | Line |
|---|---|
| no doc carries a stamp | nothing, the check is opt-in |
| the root is not a git repository with commits | `links.sh: N docs carry a Checked stamp, but <root> is not a git repository with commits — drift check skipped` |
| a stamp is not a commit in this repository | `links.sh: docs/<doc> is stamped at <stamp>, which is not a commit in this repository — …` |

A doc with no stamp is unchecked. It produces no finding and is counted in the summary line only.

## Exemptions

Files exempt from the `ORPHAN:` check, and why each is reached by a route the link graph cannot see:

| Exempt | Reason |
|---|---|
| the canonical files | loaded by name from the entry point, so nothing cites them by path |
| `memory/` | already checked both directions by `status.sh`'s `REPAIR:` pass |
| `archive/` | retired content, on purpose |
| `scripts/` | executables wired by the entry point, which lives outside the node |
| `indexes/` | the generated cache: `index.sh ensure` prints its entry path and the entry point says to read it, so no node file cites it |
| `skills/` and its siblings | the operating model places them outside itself: never loaded, never groomed, never audited |

Three sources are excluded from the `BROKEN:` walk because they name files in a different genre than citation:

- **`session-log.md` and `archive/`** are historical records. An entry naming a since-archived brief is doing its job.
- **`rules/`** is instruction, naming the node's furniture prescriptively ("pick area docs via architecture.md") whether or not the node has grown that file yet.

## Implementation notes

- Matching is loose on purpose: a citation resolves against a file's node-relative path *or* its bare basename, because docs cite each other both ways — `docs/backend.md` from the routing table, `references/error-codes.md` from the doc beside it. A false "cited" is quieter than a false orphan.
- The node is walked with `find -H`, so a worktree whose `.agent` is a link to another checkout's node is audited like the node itself.
- The project list comes from `git ls-files`, one call for the index with `--recurse-submodules` and one for `--others --exclude-standard`. Ignored folders such as run stores and test output can hold tens of thousands of Markdown files, and the `find` walk visits all of them. When either call fails, the `find` walk runs instead.
- Both lists leave out `.git` and the common dependency and build directories.
- A linked worktree is another checkout of the project, so a file that exists only there does not resolve a citation. Git does not list its files, and the `find` walk skips every worktree under the root that `git worktree list` names. An orchestrator can keep dozens of worktrees under the root, and walking them made one run take minutes. Git lists no files of any other nested checkout either, unless it is a submodule.
- The orphan and broken walks and the stamp read take a fixed number of processes, whatever the node's size. One `awk` pass over the corpus answers the orphan check for every candidate, one reads every source's citations, and one reads every doc's stamp. A line that cites a file's path also holds its basename, so the basename decides, looked up at each `.md` ending. The earlier form ran a `grep` per candidate and several processes per source and per doc: at 200 records, `timing-benchmark.sh` measured a 3,548 ms median for it against 142 ms for the batched form (macOS arm64, bash 3.2, 2026-11-27).
- `<!-- -->` comments are stripped before a file is read for citations. Header contracts live in comments and state formats by example — `memory.md`'s says `- [Title](memory/slug.md) — hook` — so a comment is a spec, not a citation, and reading one as a link invents a broken path on every node.
