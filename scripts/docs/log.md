# log.sh — the session-log writer

Appends one session-log entry per `session-log.md`'s header contract. It stamps the date and enforces the summary word ceiling, so neither is something an agent can get wrong by hand.

```
Usage: log.sh [--print-entry] --tool <name, no parentheses> --area <name, no parentheses> --verify <pass|fail|n/a> --summary "…" [--session <id>] [root]
```

`root` defaults to `.` and the script appends to `<root>/.agent/session-log.md`. Refuses to run if that file does not already exist — an uninitialized node.

## The entry

One line: `- [date] (tool) summary (area). verify: …`

`verify:` records the observed check outcome. Name a pre-existing failure in the summary, while keeping a failed check tagged as failed. Existing historical entries are preserved during migration.

Newlines are refused because they would forge extra entries, and parentheses in the tags are refused because they would corrupt the `(tool)` and `(area)` delimiters.

A summary may name a file or a SHA, and is written as given. The entry point's `--summary` placeholder still asks for no paths or ids, because a path goes stale when the file moves and Git already records both. Refusing them cost a session a second call and did not teach it to leave them out. The placeholder states the word ceiling as 25 whatever `log.conf` sets, because every entry point stays identical to its template.

A summary containing `verify:` is refused too. The entry already carries one verify tag, written from `--verify` at the end of the line; a second one in the middle is read as the entry's result by whoever gets there first. The tag records the observed check outcome. Describe a pre-existing failure in the summary without repeating the tag spelling. The match is case-insensitive and requires the colon, so `verified` and `verify pass` are fine.

Words are counted, not punctuation: a free-standing separator — an em dash, a lone hyphen — does not spend the ceiling. Separators are matched as literal bytes rather than by asking the locale what counts as a letter. That is because under a locale whose alphanumeric table covers the em dash's leading byte `0xE2`, such as ISO-8859-1 or UTF-8, `[[:alnum:]]` treats that byte as a letter and the dash spends a word. `LC_ALL=C` is not such a locale, so the bug hides there.

`--print-entry` validates and renders one entry without writing. Checkpoint uses this mode for recoverable publication. Direct writes share the checkpoint lock. The script needs `runtime.sh` beside it.

## Session id

`--session <id>` stamps the id of the session that wrote the entry, so a later session or a retro can find its transcript. The id comes from the harness through a runtime adapter, the same id that `capture.sh --id` takes. `log.sh` reads no environment variable and guesses no id. `checkpoint.sh --session` passes the id through.

The stamp sits after the branch stamp and before the verify tag:

`- [date] (tool) summary (area). branch: <name>. session: <id>. verify: …`

The id follows `capture.sh`'s rule: letters, digits, `.`, `_`, and `-`, at most 128 characters, and not `.` or `..`. Any other value is refused, because a space, a line break, or a parenthesis would break the entry's delimiters. Without `--session` the entry is exactly as before. The stamp spends no summary budget, and it keeps the verify tag last, so a reader that looks for the tag at the end still finds it.

Readers of the log that this format was checked against: the `status.sh` load tail and its entry-count and entry-size findings, `absorb.sh`, which merges whole lines, `checkpoint.sh`, whose rerun check uses its own identity and not the entry text, and the bench's `grade.py`, which leaves the stamp out of the summary word count and the `log_entry_absent` match.

## Configuration

`log.conf` beside the script, seeded by `node.sh init` and by `update` only when absent. Plain `KEY=value`, parsed and never executed. A key written twice takes its first line.

| Key | Default | Effect |
|---|---|---|
| `SUMMARY_MAX_WORDS` | 25 | the header contract's format ceiling |
| `LOG_INCLUDE_BRANCH` | `false` | stamp each entry with the checked-out branch |

With `LOG_INCLUDE_BRANCH=true` the entry also carries `branch: <name>.` before the verify tag, read from git at write time — mechanical, never asked of the agent. It uses `symbolic-ref` rather than `rev-parse` so it names the branch even before the first commit, and stays empty (stamp omitted) when detached or outside a git checkout.

The stamp spends no summary budget: the ceiling is enforced on `--summary` alone, before the line is assembled.
