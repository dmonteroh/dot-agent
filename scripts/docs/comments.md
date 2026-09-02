# comments.sh — the comment gate

Flags comments a diff adds to source files, against the software preset's **Comments** rule: a comment states something the code cannot, to a reader who has only this file. Never a restatement of the code, never narration of the structure below it or of the change itself, never code left commented out, never a reply to the request, never a citation of an artifact a fresh clone cannot open.

The gate takes the decidable shapes from both halves of that rule. Dead citations and disabled code are pure shape. The two narration classes are shape in English. What stays in the listed review is what no pattern settles: whether a competent reader would have been surprised, and whether this explanation already exists elsewhere in different words.

```
Usage: comments.sh [base-ref]      # default: BASE_REF (origin/main)
```

The base ref is the change's true parent — the branch base, or the commit before the change. Never `HEAD`: after committing, `HEAD` diffs the change against itself.

## What it reports

| Finding | Exit | Meaning |
|---|---|---|
| `BLOCK:` | 1 | the comment is dead on arrival, in one of the five classes below. Delete these, or state the constraint the code cannot. Durable *why* goes to docs |
| `REVIEW:` | 0 | every other comment the diff adds. The author justifies each as a non-obvious invariant, constraint, or workaround, or deletes it |

Every finding carries its class in brackets after the path, because "delete this" and "justify this" are different instructions and a list that mixes them gets skimmed as one:

```
REVIEW: comments this diff adds — justify each as a non-obvious invariant,
        constraint, or workaround, or delete it:
  src/Thing.cs  [restates the code below]
    /// Gets the user name.

BLOCK: comments that are dead on arrival — a citation a fresh clone cannot
       open, code left commented out, narration of the change or of the
       structure below, or an answer to the prompt. Delete them, or state
       the constraint the code cannot; durable why goes to docs:
  src/app.ts  [change narration]
    // this previously returned null
  src/app.ts  [routine narration]
    // Build the rows
```

### The blocking classes

| Class | What it catches | How it decides |
|---|---|---|
| `dead citation` | a commit SHA, a git transcript, a ticket id, scope narration | `BLOCK_RE` plus the node's `BLOCK_RE_EXTRA` |
| `commented-out code` | code left in a comment instead of deleted | a code shape **and** a code character: a lone brace, a statement ending in `;` that also holds `= ( ) { } [ ] :: ->`, a keyword opening a line that also holds one of those, a bare `name(args)` call, or an assignment whose right side is a single token ending the line. A sentence that opens with "if" or ends with a semicolon is neither |
| `change narration` | the comment written from the diff's point of view — "previously", "no longer", "now returns", "renamed from", "in this change" | `NARRATION_RE` plus the node's `NARRATION_RE_EXTRA` |
| `answers the prompt` | "as you requested", "as discussed", "per your comment" | a fixed pattern; the answer belongs in the reply, not the file |
| `routine narration` | the comment that says in English what the code under it says: "build the rows", "gets the user name", "loop over the items", "increment the counter" | `ROUTINE_RE` — a verb of routine action plus an article — minus two guards, below |

A comment matching more than one is reported under the first in that order.

### The two guards on `routine narration`

It is the only class that reasons about English rather than about shape, and it is the one that would otherwise delete real comments.

**The constraint escape.** A comment naming a cause, a constraint, or an external actor never blocks, whatever verb it opens with. `update the cache because the vendor SDK holds a stale handle` is doing the job the rule asks for. The shipped vocabulary covers `because`, `otherwise`, `unless`, `must`, `workaround`, `race`, `invariant`, `vendor`, `upstream`, `protocol`, `deliberate` and the rest; `CONSTRAINT_RE_EXTRA` adds a node's own — a subsystem, a standard, a vendor its comments name.

**The word cap.** Blocking stops at `ROUTINE_MAX_WORDS` (8, chosen default: structure narration is a fragment, not a sentence with a consequence). `Build the rows` is three words and blocks. `Update the cache after every write, or a reader sees the previous generation` is twelve, carries a clause the opening verb cannot account for, and is labeled in `REVIEW:` instead. `ROUTINE_MAX_WORDS=0` stops the class blocking at all; the label stays.

A false positive here is repaired by naming the constraint — rewriting `Create a client because the SDK caches credentials` as `The SDK caches credentials, so each request needs an isolated client` — not by an exception.

### The review label

`REVIEW:` lines carry one label of their own: `restates the code below`. The comment's content words are lowercased, stripped of function words and anything under three characters, and matched against the identifiers on the next line of code — `camelCase` and `PascalCase` split into their words first, and a trailing `s` ignored on both sides. Every content word matching, with at least two of them, means the comment is that line spelled out.

It stays in `REVIEW:` rather than `BLOCK:` because it is a heuristic, not a decision. `RESTATE_CHECK=false` turns it off; the comment still appears, unlabeled.

The scan for that code line reaches past the rest of the comment block rather than stopping at the immediate next line. A doc comment sits above its member with the block terminator in between, so stopping short would exempt exactly the doc comments that restate the signature they sit on.

### Exit 2

Exit 2 is the third answer, and it means the gate could not run rather than that it found nothing: a base ref that does not resolve, no merge base between that base and `HEAD`, a conf regex that will not compile, a non-numeric `ROUTINE_MAX_WORDS`, or a base that describes an empty diff. It is separate from 0 because every filter in the script absorbs a no-match, and an error that arrived as 0 would report a clean diff the gate never read.

The empty-diff case is the one a session reaches by accident. A base resolving to `HEAD` with nothing uncommitted has no lines to read, so the run would exit 0 — a pass meaning "this run checked nothing", indistinguishable in a transcript from a pass meaning "the comments are clean". Committing first and then reaching for `comments.sh HEAD` lands exactly there, so it exits 2 and names the fix.

The argument is a git base ref, not the `[root]` the reporting scripts take. This one audits a diff in the repository it runs in, so `comments.sh .` resolves nothing and exits 2 rather than guessing.

## What it reads

The diff is merge-base(base, `HEAD`) → **the working tree**, plus untracked source files scanned whole. The gate runs before a diff is handed back, and hand-back is normally an uncommitted state, so a committed-only diff would pass exactly the comments this exists to catch.

That scope includes comments already sitting uncommitted in scanned files, whoever wrote them. They are part of the diff being handed back, and `REVIEW:`'s justify-or-delete decision absorbs them.

A marker opens a comment only in the languages where it does. `#` opens one in shell, python and ruby but not in C-family sources, where it is a preprocessor directive or a region marker. `//`, `/*` and `<!--` go the other way round, since in shell `//` is a string or a syntax error. `--` opens one only in SQL.

Skipped by default: **every hidden directory**, vendored and minified trees, and tooling pragmas (`eslint`, `shellcheck`, `noqa`, `@ts-`, and the rest).

Hidden directories go generically — `(^|/)\.[^/]+/` — rather than by name. An AI tool's or an editor's own directory holds hooks and helpers the comment rule was never aimed at. A list of the tools we can name today would miss whichever arrives next. Matching by shape covers it on arrival and keeps the shipped core free of vendor tokens. It also covers `.agent/` itself, which used to be its own term.

The honest cost: `.github/` is a hidden directory, so CI helpers written in a scanned language leave the scan too. A project that reviews those sets `EXCLUDE_RE` to a narrower list.

Anchoring matters here: the term requires the dot at a path start or straight after a slash, so `foo.bar/baz.ts` is not read as hidden. Every regex reaches awk through the environment rather than `-v`, because `-v` processes backslash escapes and would collapse `\.` to `.` — turning a literal-dot term into match-anything and silently excluding the whole tree.

Classification is case-insensitive: the comment's text and every pattern are lowercased before they meet. A conf pattern written with an uppercase literal (`AC-?[0-9]`) matches the same way.

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
| `NARRATION_RE_EXTRA` | ERE of change-narration phrasings that BLOCK, ORed onto the defaults |
| `CONSTRAINT_RE_EXTRA` | ERE of constraint vocabulary that rescues a comment from `routine narration`, ORed onto the defaults |
| `ROUTINE_MAX_WORDS` | longest `routine narration` comment that still BLOCKs (8). `0` leaves the class as a label only |
| `PRAGMA_RE_EXTRA` | ERE of tooling pragmas to skip, ORed onto the defaults |
| `RESTATE_CHECK` | `false` turns off the restatement label |

Ticket and task-reference shapes belong in `BLOCK_RE_EXTRA`, and house narration terms in `NARRATION_RE_EXTRA`, not in the shipped core: no two teams number or phrase work the same way. The shipped core names only the universal ones. The retro skill routes comment-hygiene lessons here — and routes nothing at all when the gate already catches the shape.

What the gate does not decide: whether a comment duplicates an explanation that already exists elsewhere in different words, and whether a competent reader would have been surprised. A regex cannot establish semantic equivalence. Those stay `REVIEW:` findings, which is what the justify-or-delete instruction is for.
