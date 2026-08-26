# test.sh — the suite

Self-contained smoke tests for every script this repo ships. It is the gate: it must pass before a change ships.

```
Usage: scripts/test.sh    # run from anywhere; resolves the repo from $0
```

Builds every fixture under a fresh `mktemp -d` directory, never writes inside this repo, and removes the directory on exit. Prints one `ok`/`FAIL` line per check and a summary line. Exits 0 only if every check passed.

Written bash 3.2 / BSD portable: no associative arrays, no GNU-only flags. CI runs it on Ubuntu and macOS alongside ShellCheck, and once more under `LC_ALL=C` — a single-byte locale changes what `[[:alnum:]]` matches, which the word counters depend on.

## Three conventions worth keeping

**The expected set is written out here, not read from the script under test.** The presence loop names all six shipped scripts and all three starter confs literally. Deriving the list from `node.sh` would drop with it and pass.

**Fixtures that are written to be blocked are C-family files.** Section 34 plants comments into `.ts`, `.cs` and `.py` fixtures. The suite itself is shell, where `//` opens no comment, so the gate scanning this repo does not read its own fixture strings back as findings.

**The markdown corpus is soft-wrapped, and section 38 is what holds it there.** Every `.md` file outside `tmp/` is authored one line per paragraph and wrapped by the reader's renderer. Hard-wrapped prose turns a one-word edit into a whole-paragraph reflow, and the real change then hides among the moved line breaks. The check treats any prose line whose next line is also prose as a continuation, because in markdown two consecutive non-blank lines are one paragraph. Width is not the test. Fenced blocks, tables, frontmatter, headings and list markers are exempt, because there the line break carries meaning.

Section 38 checks a generated node as well as this repo. A node's markdown comes from heredocs in `node.sh` and `docs.sh` rather than from any file the corpus sweep can see, so the two need separate checks. The node copy is the one that matters more: the corpus is read by whoever maintains this repo, and a node is read by every agent that works in it.
