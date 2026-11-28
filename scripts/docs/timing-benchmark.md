# timing-benchmark.sh — helper and checkpoint latency

`scripts/tools/timing-benchmark.sh` times the helpers a session or a checkpoint reads a node with. It builds fixture nodes with `node.sh init`, fills them with generated records, and reports the median and the 90th percentile of each command in milliseconds.

```
scripts/tools/timing-benchmark.sh                             # this checkout, 10 runs, sizes 10, 60, 200
scripts/tools/timing-benchmark.sh --runs 20 --sizes "60 600"
scripts/tools/timing-benchmark.sh --checkpoint-files "25 250 1000" --runs 3
scripts/tools/timing-benchmark.sh --scripts OLD/scripts --scripts scripts   # two revisions in one run
```

`--scripts` takes the `scripts/` directory of a dot-agent checkout, which must hold `node.sh`, `presets/`, and `templates/` in their usual places. `git worktree add --detach ../old <commit>` gives one for another revision. With several directories, every run times each one in turn, so a change in machine load reaches all of them. Read two revisions from one run, never from two.

Each command gets one warm-up run, which must exit 0, and then `--runs` timed runs.

## What a fixture holds

A size counts records. A quarter are memory facts of 120 words, a quarter learned records of 40 words, a quarter routed docs with four sections of 100 words, and a quarter session-log entries of 20 words. The node uses `indexes: generated` with a fresh index, and `hooks: session-start`. The project around it is a git repository. It holds one tracked Markdown note per record, ten ignored Markdown files per record, and one uncommitted source change for `review.sh` to read.

| Command | Call |
| --- | --- |
| `status.sh --load` | `status.sh --load ROOT` |
| `status.sh --format tsv` | `status.sh --format tsv ROOT` |
| `memory.sh lookup` | `memory.sh lookup --query 'area word12' ROOT` |
| `index.sh check` | `index.sh check --root ROOT` |
| `review.sh` | `review.sh --base HEAD --root ROOT` |
| `links.sh` | `links.sh ROOT` |

## Checkpoint timing

Pass `--checkpoint-files` to time a complete `checkpoint.sh --checks test` at each specified count of tracked files under `src/`. The fixture uses manual indexes and tracks its node in Git. Before each sample, the harness restores the fixture’s starting session log and changes one numeric value. This keeps the log workload constant at every repeat count. The project check confirms the value is numeric and emits one passing TAP result. Every sample must record a fresh verified log entry. Fixture creation and editing are outside the timer.

On 2026-11-26, the complete checkpoint at 1,000 tracked source files fell from a median of 44.24 s to 3.43 s with batched fingerprinting. This comparison used macOS arm64, Bash 3.2.57 and Git 2.55.0. The baseline was `2491f2a`. Both revisions ran on the same machine under other work, with one warm-up and three interleaved samples per file count. The measured fixture accumulated up to three log entries. At three samples, p90 is the slowest observation.

| Source files | Median before | Median batched | p90 before | p90 batched |
| ---: | ---: | ---: | ---: | ---: |
| 25 | 4,126 ms | 1,352 ms | 7,586 ms | 3,297 ms |
| 250 | 13,340 ms | 1,640 ms | 25,510 ms | 3,653 ms |
| 1,000 | 44,244 ms | 3,430 ms | 60,905 ms | 5,267 ms |

## Not part of test.sh

`test.sh` does not run this script and asserts no time. On one loaded machine the p90 of a command reaches more than twice its median: 198 ms and 517 ms for `status.sh --format tsv` at 200 records, in the macOS table below. A time limit in the suite would fail on runs where nothing changed.

## Results

Before is commit `785fba0`. After is commit `4f8b423` (`perf(links): build the project file list from git`), whose `status.sh` and `links.sh` differ from it. The other four commands run the same scripts in both columns, so the gap between their columns shows the noise of the run. Other work loaded the machine during both runs.

### macOS

MacBook Pro, Apple M3 Pro, 12 cores. macOS 26.7.3, Darwin 25.6.0 arm64, bash 3.2.57, git 2.55.0, 2026-11-24. 10 runs per command.

| Records | Command | Median before | p90 before | Median after | p90 after |
| --- | --- | --- | --- | --- | --- |
| 10 | `status.sh --load` | 1152 ms | 1624 ms | 606 ms | 741 ms |
| 10 | `status.sh --format tsv` | 749 ms | 945 ms | 214 ms | 269 ms |
| 10 | `memory.sh lookup` | 537 ms | 630 ms | 628 ms | 659 ms |
| 10 | `index.sh check` | 200 ms | 228 ms | 202 ms | 382 ms |
| 10 | `review.sh` | 635 ms | 839 ms | 546 ms | 707 ms |
| 10 | `links.sh` | 379 ms | 441 ms | 428 ms | 456 ms |
| 60 | `status.sh --load` | 2623 ms | 2763 ms | 444 ms | 587 ms |
| 60 | `status.sh --format tsv` | 2408 ms | 2676 ms | 207 ms | 284 ms |
| 60 | `memory.sh lookup` | 1308 ms | 1456 ms | 1281 ms | 1535 ms |
| 60 | `index.sh check` | 151 ms | 191 ms | 150 ms | 176 ms |
| 60 | `review.sh` | 444 ms | 485 ms | 430 ms | 482 ms |
| 60 | `links.sh` | 1378 ms | 1470 ms | 1372 ms | 1556 ms |
| 200 | `status.sh --load` | 7112 ms | 7763 ms | 540 ms | 602 ms |
| 200 | `status.sh --format tsv` | 6280 ms | 7265 ms | 198 ms | 517 ms |
| 200 | `memory.sh lookup` | 3310 ms | 4226 ms | 3320 ms | 3826 ms |
| 200 | `index.sh check` | 146 ms | 155 ms | 142 ms | 156 ms |
| 200 | `review.sh` | 384 ms | 425 ms | 392 ms | 422 ms |
| 200 | `links.sh` | 4942 ms | 6241 ms | 4750 ms | 6340 ms |

### Linux

A Debian container in a virtual machine on the same machine. bash 5.2.37, mawk, git 2.47.3, 2026-11-24, as a normal user. 10 runs per command.

| Records | Command | Median before | p90 before | Median after | p90 after |
| --- | --- | --- | --- | --- | --- |
| 10 | `status.sh --load` | 331 ms | 575 ms | 173 ms | 320 ms |
| 10 | `status.sh --format tsv` | 216 ms | 254 ms | 62 ms | 73 ms |
| 10 | `memory.sh lookup` | 128 ms | 162 ms | 126 ms | 144 ms |
| 10 | `index.sh check` | 53 ms | 72 ms | 54 ms | 83 ms |
| 10 | `review.sh` | 106 ms | 130 ms | 114 ms | 192 ms |
| 10 | `links.sh` | 116 ms | 162 ms | 113 ms | 134 ms |
| 60 | `status.sh --load` | 788 ms | 1237 ms | 150 ms | 223 ms |
| 60 | `status.sh --format tsv` | 602 ms | 885 ms | 56 ms | 76 ms |
| 60 | `memory.sh lookup` | 205 ms | 264 ms | 178 ms | 259 ms |
| 60 | `index.sh check` | 19 ms | 24 ms | 18 ms | 24 ms |
| 60 | `review.sh` | 56 ms | 61 ms | 52 ms | 58 ms |
| 60 | `links.sh` | 214 ms | 294 ms | 186 ms | 262 ms |
| 200 | `status.sh --load` | 1069 ms | 1216 ms | 79 ms | 98 ms |
| 200 | `status.sh --format tsv` | 1046 ms | 1329 ms | 44 ms | 66 ms |
| 200 | `memory.sh lookup` | 622 ms | 724 ms | 594 ms | 779 ms |
| 200 | `index.sh check` | 22 ms | 24 ms | 22 ms | 24 ms |
| 200 | `review.sh` | 43 ms | 70 ms | 48 ms | 74 ms |
| 200 | `links.sh` | 942 ms | 1064 ms | 744 ms | 1119 ms |

### `memory.sh lookup` without a process per file

On 2026-11-27, `memory.sh lookup` at 200 records fell from a median of 1,751 ms to 429 ms (p90 1,959 ms to 492 ms) once it stopped starting processes for each file it checks. The baseline was `342a3f6`. The run used macOS arm64, bash 3.2.57 and git 2.55.0, both revisions in one run of the harness, 10 runs each, with a load average near 20. The other five commands ran the same scripts in both columns and stayed within 50 ms of each other.

## What the numbers do not cover

- One machine, under load, with one run of the harness per system.
- Generated records. They hold no comments, no frontmatter beyond the fact header, and no file over a threshold. `status.sh` starts extra processes for each file near or over one.
- `links.sh` cost that comes from ignored files grows with their number, and the fixture holds at most 2,000.
