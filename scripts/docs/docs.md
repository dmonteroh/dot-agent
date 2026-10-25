# docs.sh — the area-doc writer

Scaffolds an area doc and its `architecture.md` routing-table row as one operation. This is a two-place write that drifts when done by hand. The point of the script is to make that drift impossible. (`status.sh`'s `INDEX:` check does the detecting for docs written by hand.)

```
Usage: docs.sh new --name <file> --read-when "…" [root]
       docs.sh rehook --name <file> --read-when "…" [root]
       docs.sh sync --name <file> [--read-when "…"] [root]
       docs.sh catalog --catalog <file> --name <symbol> --path <project-path> --when "…" [root]
```

`root` defaults to `.` and `.md` is appended to `<file>` if missing. `new` writes `<root>/.agent/docs/<file>` and appends a row to `<root>/.agent/docs/architecture.md`, creating it with a minimal routing header if it does not already exist.

`rehook` rewrites an existing doc's `Read when:` header line and its `- **Read when:**` routing row to the new text, both or neither (each is written to a temporary and swapped in together). It is the fix for a routed doc a session failed to reach: the hook did not name the word the task used. The preset's Self-learning rule sends that case here rather than to a learned rule, because the row was the source and the row is now fixed.

## Syncing routing metadata

`sync` preserves the document body while reconciling its own `<!-- Read when: … -->` header and exactly one `architecture.md` entry. An existing header supplies the hook when `--read-when` is omitted. A headerless document requires explicit text. The command prepends that text as its hook. Duplicate document headers, duplicate routing entries, duplicate metadata rows, or a symlink at `architecture.md` are ambiguous and refused before the routing table is read or replaced.

The `Sections:` value is derived from exact `## ` headings. A fence-aware scan ignores headings inside backtick or tilde code fences. The document and routing table are staged before either is published, and the original document is restored if the paired publication fails.

## Catalog upsert

`catalog` updates the row whose first cell is `<symbol>`, or inserts one when absent, in exactly one compatible three-column catalog table. Its columns are `Block`, `Symbol`, or `Name`, then `Path`, then a `When` column. It refuses no table, more than one compatible table, duplicate keys, and values containing Markdown table escaping hazards. The emitted row quotes the symbol and path with backticks.

`--path` is project-relative and must already exist. Ordinary spaces are accepted. Absolute paths, `..`, newlines, tabs, pipes, backticks, unsafe characters, symlink traversal, and a physical location outside the project are refused. `--catalog` is likewise confined to a regular file below `.agent/docs/`. A successful upsert prints the symbol and the catalog's new content digest.
