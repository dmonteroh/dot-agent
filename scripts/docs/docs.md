# docs.sh — the area-doc writer

Scaffolds an area doc and its `architecture.md` routing-table row as one operation. This is a two-place write that drifts when done by hand. The point of the script is to make that drift impossible. (`status.sh`'s `INDEX:` check does the detecting for docs written by hand.)

```
Usage: docs.sh new --name <file> --read-when "…" [root]
```

`root` defaults to `.` and `.md` is appended to `<file>` if missing. Writes `<root>/.agent/docs/<file>` and appends a row to `<root>/.agent/docs/architecture.md`, creating it with a minimal routing header if it does not already exist.
