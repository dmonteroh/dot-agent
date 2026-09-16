# human-text.sh — the human-facing text scanner

Scans an explicit commit message, pull-request body, or release note — text read by someone who was not in the session that produced it — for chat residue left behind by drafting it in conversation instead of writing it as that text.

```
Usage: human-text.sh --kind commit|pr|release [--] [FILE ...]
Read stdin when FILE is omitted. Use - for stdin once.
Exit 0: clean. Exit 1: residue. Exit 2: invalid input or scan failure.
Clean scans are silent. Findings and errors use stderr.
```

`--kind` records which audience boundary the text crosses. All three kinds share one rule set today: the value does not change detection, only the label a caller supplies for its own bookkeeping.

## What it reports

| Class | Finding line (stderr) |
|---|---|
| `chat-reference` | `<source>:<line>: chat-reference` |
| `apology` | `<source>:<line>: apology` |
| `revision-label` | `<source>:<line>: revision-label` |

A clean scan writes nothing to either stream. A finding writes nothing to stdout and one line per hit to stderr, `<source>:<line>: <class>`, where `<source>` is the path as given (or `-` for stdin) and `<line>` is the 1-based line number within that input.

### `chat-reference`

Catches a line pointing at a conversation instead of standing on its own: "as discussed", "as agreed", "per your feedback", "per our discussion", "you asked". A sentence describing a decision without pointing back at the exchange that made it survives — "Reject expired tokens before opening the socket" names the behavior itself, not the conversation that produced it.

### `apology`

Catches a line opening with an apology to whoever is reading it: "Sorry, ...", "I apologize for ...", "My apologies", "Apologies:". Only the opening of a line counts, so a sentence that discusses being sorry without opening with it survives — a negative property such as `test_retries_without_network verifies retries without network access` never matches, since it neither opens with nor contains the pattern.

### `revision-label`

Catches a standalone label marking a redraft rather than reporting one: a bare "Fixed version:", "Here's the fixed version", "This is the corrected version". A sentence that reports an actual version survives, because the label shape requires either a trailing colon or one of the fixed phrasings — "The fixed version is 2.3.1." is a real version report, not a label, and stays clean. Supplied release history ("The previous version could delete unsaved work. This release preserves it.") also survives: it describes past and current behavior, not a redraft of the text itself.

## Shapes that survive

Four shapes read as legitimate rather than as residue, across all three classes above.

| Shape | Example | Why it survives |
|---|---|---|
| A negative property | `test_retries_without_network verifies retries without network access` | Opens with none of the three patterns and contains no opening apology |
| A real version report | "The fixed version is 2.3.1." | The `revision-label` shape needs a trailing colon or one of the fixed introductory phrasings; a plain report has neither |
| Supplied release history | "The previous version could delete unsaved work. This release preserves it." | Describes past and current behavior, not a reference to how the text itself was produced |
| An accepted correction stated as the new behavior | "Reject expired tokens before opening the socket. Preserve offline retries." | States what the code now does rather than pointing back at the exchange that decided it, so it carries no `chat-reference` |

## Exit status

| Exit | Meaning |
|---|---|
| 0 | clean — no finding in any input. Silent on both streams |
| 1 | residue — at least one finding. Findings on stderr, nothing on stdout |
| 2 | invalid input, or a failed read or scan |

Exit 2 covers: no `--kind` or an invalid one, `--kind` given twice, an unknown option, a missing or unreadable file, a directory given where a file was expected, stdin requested twice, stdin read with nothing piped to it, empty or whitespace-only input, and a read or scan failure on any input — including one that occurs after an earlier input already produced a finding. Every input is validated before any of them is scanned, and every finding is held until the last input has been scanned, so a later failure never lets an earlier finding reach stderr on its own.

## What it reads

The scanner opens exactly the paths it was given, plus stdin when no path is given or `-` appears among them. It discovers no file, reads no `.agent/` file, and inspects no code comment. It makes no network call and no Git call, and takes no configuration file, configuration key, or environment override.

Detection is line-oriented and lexical, so multiline residue can pass a scan and a quoted example can produce a finding: this is a lexical pass, and a lexical pass can only rule a shape out, never rule one in. A clean scan is silence, not endorsement — it does not conclude that requirements were met or that the text is well written, only that none of the three residue shapes above were found.
