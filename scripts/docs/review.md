# review.sh — bounded change review candidates

`review.sh` runs the existing comment gate once. It then reports newly declared helpers absent from configured catalog text, and changed source files without a filename-related changed test. These are prompts for review, not proof of reuse, catalog completeness, coverage, or missing coverage.

```
Usage: review.sh [--base REF] [--root ROOT]
       review.sh --help | --version
```

It exits 0 when inspection completes, even with advisory `REVIEW:` lines. Exit 1 means `comments.sh` blocked. Exit 2 means inspection failed. The empty diff behavior is inherited from `comments.sh`: a base resolving to `HEAD` with a clean tree is an inspection failure, not a clean review.

## Change scope

The inspected set is merge-base(base, `HEAD`) through the current working tree, plus untracked files. It therefore includes committed, staged, unstaged, and untracked work, including additions inside existing files. It does not run `git add` or otherwise modify the index or working files.

Paths are passed to Git as separate quoted arguments, so spaces are supported. The shipped lexical detectors support JavaScript/TypeScript, Python, Ruby, Go, and shell source files under configured source roots. JavaScript and TypeScript catalog candidates are limited to explicit `export` declarations. The scan does not inspect or prohibit imports, including extensionless ones. Python considers top-level public functions, Go exported functions or methods, Ruby methods, and shell function declarations. Other languages remain outside this advisory detector rather than being guessed at.

## Findings

Each advisory is one line:

```
REVIEW: CODE PATH MESSAGE
```

- `CATALOG_CANDIDATE` means a newly added supported helper declaration was not found as fixed text in the configured catalogs, or no catalog was available.
- `TEST_COVERAGE` means no changed test filename contains the changed source file's basename. A related filename suppresses the candidate but does not prove that the test exercises the change.

`MAX_FINDINGS` bounds the ordinary candidate lines. When more candidates exist, one additional `FINDINGS_TRUNCATED` line reports exactly how many were omitted, so bounded output cannot look like a complete clean review. The comment gate's own output and blocking decision are unchanged and remain authoritative.

## Configuration

`review.conf` is plain, non-executed `KEY=value`. The first value wins.

- `SOURCE_ROOTS=src` is a space-separated list of project-relative roots.
- `TEST_PATH_RE=...` is an extended regular expression for test paths.
- `CATALOGS=auto` discovers `.agent/docs/*catalog*.md`. Otherwise it is a space-separated list of project-relative catalog paths.
- `MAX_FINDINGS=20` caps ordinary candidate lines and must be a positive whole number. `0` is invalid rather than meaning “hide every finding.”

Configuration lists intentionally do not encode paths containing spaces. Such paths are supported for changed files, while projects needing spaced source roots or catalog paths should choose a stable unspaced parent/root.
