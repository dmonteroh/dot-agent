# log.sh — the session-log writer

Appends one session-log entry per `session-log.md`'s header contract. It
stamps the date and enforces the summary word ceiling, so neither is
something an agent can get wrong by hand.

```
Usage: log.sh --tool <name> --area <name> --verify <pass|fail|n/a> --summary "…" [root]
```

`root` defaults to `.` ; appends to `<root>/.agent/session-log.md`. Refuses
to run if that file does not already exist — an uninitialized node.

## The entry

One line: `- [date] (tool) summary (area). verify: …`

Newlines are refused because they would forge extra entries, and parentheses
in the tags are refused because they would corrupt the `(tool)` and `(area)`
delimiters.

Words are counted, not punctuation: a free-standing separator — an em dash, a
lone hyphen — does not spend the ceiling. Separators are matched as literal
bytes rather than by asking the locale what counts as a letter, because under
a single-byte locale `[[:alnum:]]` treats the em dash's leading byte as
alphanumeric and the dash spends a word.

## Configuration

`log.conf` beside the script, seeded by `node.sh init` and by `update` only
when absent. Plain `KEY=value`, parsed and never executed.

| Key | Default | Effect |
|---|---|---|
| `SUMMARY_MAX_WORDS` | 25 | the header contract's format ceiling |
| `LOG_INCLUDE_BRANCH` | `false` | stamp each entry with the checked-out branch |

With `LOG_INCLUDE_BRANCH=true` the entry also carries `branch: <name>.`
before the verify tag, read from git at write time — mechanical, never asked
of the agent. It uses `symbolic-ref` rather than `rev-parse` so it names the
branch even before the first commit, and stays empty (stamp omitted) when
detached or outside a git checkout.

The stamp spends no summary budget: the ceiling is enforced on `--summary`
alone, before the line is assembled.
