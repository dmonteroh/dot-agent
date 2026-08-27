# comments.sh — the comment gate

Flags comments a diff adds to source files, against the contract's comment rule: a comment states a constraint the code cannot express, never change narration or citations of artifacts a fresh clone cannot open.

The rule splits into a half a machine can decide and a half it cannot. "Is this comment narrative?" is a judgement call a reviewer can wave through. The question "can a fresh clone open what this cites?" is not. So the objective half is mechanical and the judgement half stays a listed review.

```
Usage: comments.sh [base-ref]      # default: BASE_REF (origin/main)
```

## What it reports

| Finding | Exit | Meaning |
|---|---|---|
| `BLOCK:` | 1 | the added comment cites something a fresh clone cannot open — a commit SHA, a git command transcript, scope narration. Delete these. Durable *why* goes to docs |
| `REVIEW:` | 0 | every other comment the diff adds. The author justifies each as a non-obvious invariant, constraint, or workaround, or deletes it |

Exit 2 is the third answer, and it means the gate could not run rather than that it found nothing: a base ref that does not resolve, no merge base between that base and `HEAD`, or a conf regex that will not compile. It is separate from 0 because every filter in the script absorbs a no-match, and an error that arrived as 0 would report a clean diff the gate never read.

The argument is a git base ref, not the `[root]` the reporting scripts take. This one audits a diff in the repository it runs in, so `comments.sh .` resolves nothing and exits 2 rather than guessing.

## What it reads

The diff is merge-base(base, `HEAD`) → **the working tree**, plus untracked source files scanned whole. The gate runs before a diff is handed back, and hand-back is normally an uncommitted state, so a committed-only diff would pass exactly the comments this exists to catch.

That scope includes comments already sitting uncommitted in scanned files, whoever wrote them. They are part of the diff being handed back, and `REVIEW:`'s justify-or-delete decision absorbs them.

A marker opens a comment only in the languages where it does. `#` opens one in shell, python and ruby but not in C-family sources, where it is a preprocessor directive or a region marker. `//`, `/*` and `<!--` go the other way round, since in shell `//` is a string or a syntax error. `--` opens one only in SQL.

Skipped by default: **every hidden directory**, vendored and minified trees, and tooling pragmas (`eslint`, `shellcheck`, `noqa`, `@ts-`, and the rest).

Hidden directories go generically — `(^|/)\.[^/]+/` — rather than by name. An AI tool's or an editor's own directory holds hooks and helpers the comment rule was never aimed at. A list of the tools we can name today would miss whichever arrives next. Matching by shape covers it on arrival and keeps the shipped core free of vendor tokens. It also covers `.agent/` itself, which used to be its own term.

The honest cost: `.github/` is a hidden directory, so CI helpers written in a scanned language leave the scan too. A project that reviews those sets `EXCLUDE_RE` to a narrower list.

Anchoring matters here: the term requires the dot at a path start or straight after a slash, so `foo.bar/baz.ts` is not read as hidden. The exclusion regex reaches awk through the environment rather than `-v`, because `-v` processes backslash escapes and would collapse `\.` to `.` — turning a literal-dot term into match-anything and silently excluding the whole tree.

## Configuration

Node vocabulary lives in `comments.conf` beside the script, which `node.sh init` seeds and `update` seeds only when absent — never overwriting it. The file lists every key with its default. It is the documentation a node reads.

Plain `KEY=value`, parsed and never executed: a config the gate reads on every run is an injection surface, and this one cannot run code. Everything after `=` is the raw value — no quoting, no escaping. A key written twice takes its first line, the same way every conf in the node resolves one.

| Key | Effect |
|---|---|
| `BASE_REF` | default base when none is passed |
| `EXTENSIONS` | replaces the scanned extension list |
| `EXCLUDE_RE` | ERE of paths to skip, **replacing** the shipped list |
| `EXCLUDE_RE_EXTRA` | ERE of paths to skip, ORed onto whatever `EXCLUDE_RE` holds |
| `BLOCK_RE_EXTRA` | ERE of citation shapes that BLOCK, ORed onto the defaults |
| `PRAGMA_RE_EXTRA` | ERE of tooling pragmas to skip, ORed onto the defaults |

Ticket and task-reference shapes belong in `BLOCK_RE_EXTRA`, not in the shipped core: no two teams number work the same way. The shipped core names only universal dead citations. The retro skill routes comment-hygiene lessons here.
