# docs.sh — the area-doc writer

Scaffolds an area doc and its `architecture.md` routing-table row as one operation. This is a two-place write that drifts when done by hand. The point of the script is to make that drift impossible. (`status.sh`'s `INDEX:` check does the detecting for docs written by hand.)

```
Usage: docs.sh new --name <file> --read-when "…" [root]
       docs.sh rehook --name <file> --read-when "…" [root]
```

`root` defaults to `.` and `.md` is appended to `<file>` if missing. `new` writes `<root>/.agent/docs/<file>` and appends a row to `<root>/.agent/docs/architecture.md`, creating it with a minimal routing header if it does not already exist.

`rehook` rewrites an existing doc's `Read when:` header line and its `- **Read when:**` routing row to the new text, both or neither (each is written to a temporary and swapped in together). It is the fix for a routed doc a session failed to reach: the hook did not name the word the task used. The preset's Self-learning rule sends that case here rather than to a learned rule, because the row was the source and the row is now fixed.
