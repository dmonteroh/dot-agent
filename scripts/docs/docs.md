# docs.sh — the area-doc writer

Scaffolds an area doc and its `architecture.md` routing-table row as one operation. This is a two-place write that drifts when done by hand. The point of the script is to make that drift impossible. (`status.sh`'s `INDEX:` check does the detecting for docs written by hand.)

```
Usage: docs.sh new --name <file> --read-when "…" [root]
       docs.sh rehook --name <file> --read-when "…" [root]
       docs.sh sync [--name <file> [--read-when "…"]] [root]
       docs.sh catalog --catalog <file> --name <symbol> --path <project-path> --when "…" [root]
       docs.sh check --name <file> [root]
       docs.sh route [root] --paths <path>... [--base <ref>]
       docs.sh route [root] --base <ref>
```

`root` defaults to `.` and `.md` is appended to `<file>` if missing. `new` writes `<root>/.agent/docs/<file>` and appends a row to `<root>/.agent/docs/architecture.md`, creating it with a minimal routing header if it does not already exist.

`rehook` rewrites an existing doc's `Read when:` header line and its `- **Read when:**` routing row to the new text, both or neither (each is written to a temporary and swapped in together). It is the fix for a routed doc a session failed to reach: the hook did not name the word the task used. The preset's Self-learning rule sends that case here rather than to a learned rule, because the row was the source and the row is now fixed.

## The Checked stamp

A doc may carry `<!-- Checked: <short-sha> -->` on the line after its `Read when:` header. The stamp is the commit at which someone last read the code the doc cites and confirmed the doc matches it. `links.sh` reports a cited project path that changed in a later commit as `STALE:` (see `links.md`).

`check` writes the stamp. Run it after re-reading the cited code and fixing the doc, never in place of that. It records the current `HEAD` short sha, replacing an existing stamp in the doc's first five lines or inserting one after the `Read when:` header. A doc with neither gets the stamp as its first line. The rest of the doc is copied byte for byte. It refuses `architecture.md`, a doc with two stamps, and a root that is not a git repository with commits. When the project has uncommitted changes outside `.agent/`, it says the stamp does not cover them. Restamp after committing them if the doc describes them.

`new` stamps a new doc at `HEAD`, because its body is written against the code at that commit. Outside a git repository with commits, `new` writes the doc unstamped. A doc with no stamp is unchecked: `links.sh` reports nothing for it.

A stamp written in a worker's checkout names a commit of that checkout. `absorb.sh docs` drops it when it merges the doc back, unless the main checkout's `HEAD` contains that commit, so a doc integrated by cherry-pick arrives unchecked (see `absorb.md`).

The stamp is a separate comment line so every existing reader of the `Read when:` header keeps working unchanged. `status.sh`, `sync`, `rehook`, and `index.sh` read only the `Read when:` line, and comments are stripped before citations and word counts are taken.

## Syncing routing metadata

`sync` preserves the document body while reconciling its own `<!-- Read when: … -->` header and exactly one `architecture.md` entry. An existing header supplies the hook when `--read-when` is omitted. A headerless document requires explicit text. The command prepends that text as its hook. Duplicate document headers, duplicate routing entries, duplicate metadata rows, or a symlink at `architecture.md` are ambiguous and refused before the routing table is read or replaced.

Without `--name`, `sync` runs over every doc `architecture.md` routes, in the table's order. A doc that is refused does not stop the rest, and the call exits 1 with a line naming how many were refused. `--read-when` needs `--name`.

The `Sections:` value is derived from exact `## ` headings. A fence-aware scan ignores headings inside backtick or tilde code fences. The document and routing table are staged before either is published, and the original document is restored if the paired publication fails.

## Catalog upsert

`catalog` updates the row whose first cell is `<symbol>`, or inserts one when absent, in exactly one compatible three-column catalog table. Its columns are `Block`, `Symbol`, or `Name`, then `Path`, then a `When` column. It refuses no table, more than one compatible table, duplicate keys, and values containing Markdown table escaping hazards. The emitted row quotes the symbol and path with backticks.

`--path` is project-relative and must already exist. Ordinary spaces are accepted. Absolute paths, `..`, newlines, tabs, pipes, backticks, unsafe characters, symlink traversal, and a physical location outside the project are refused. `--catalog` is likewise confined to a regular file below `.agent/docs/`. A successful upsert prints the symbol and the catalog's new content digest.

## Route lookup

`route` answers which routed docs a change touches. The routing table answers which doc covers a topic. `route` answers which doc cites a file. It prints one line per routed doc and cited path:

```
ROUTE: docs/payments.md | touching payments | src/client.ts
```

The fields are the doc's path in the node, its `Read when:` hook, and the cited path. The hook field is empty for a doc with no hook. A cited directory carries a trailing `/`.

- Routed docs are the ones `status.sh`'s routing checks cover: `docs/*.md`, then `docs/*/*.md`, except `architecture.md` and `references/`. A stamp is not needed.
- A doc cites what `links.sh`'s drift check reads from it, through `da_doc_citations` in `runtime.sh`: link targets and backticked spans, outside HTML comments, fenced code included. So the two never disagree about what a doc cites.
- A citation names a path as written, from the project root or from the doc's folder. `route` does not check that the path exists, so a citation of a deleted file still matches.
- A cited directory matches every path under it, written as `src/billing/` or as `src/billing`.
- `--paths` takes the arguments up to the next flag, so give `root` before it. The paths are project-relative.
- `--base <ref>` adds the paths changed since the merge base of `<ref>` and `HEAD`, uncommitted changes included, and the untracked files. That is the set `review.sh` inspects, except that a deleted path, and a renamed file's old path, stay in. Git's empty tree as `<ref>` is its own base, so a first commit can be looked up. Git's paths are taken relative to the root, so a node below the repository's top sees only the changes under it. With `--paths` too, it looks up both.
- `route` writes nothing. It exits 0 whatever it finds, and prints nothing when no doc cites a given path. A usage error, a root with no `.agent/`, a `--base` it cannot resolve, and a doc it cannot read exit 1 with the next step. `docs.sh` needs `runtime.sh` beside it, as an installed node has.
