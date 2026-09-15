# index.sh latency benchmark

Real measurements from `scripts/index-benchmark.sh`, run on this machine against this commit's `index.sh`. Reports median and p95 process latency (`/usr/bin/time -p`, real time) at 100 and 1,000 canonical-source records, cold and warm cache — the F14 acceptance criterion. All numbers below were actually measured on this run, not estimated or carried over from the spike.

## Machine and revision

- Commit: `d3cbfb96884438f35dfdcc53fa882057eda61132` (this branch)
- macOS 26.6.2, Darwin 25.6.0, arm64 (Apple Silicon)
- Bash 3.2.57, system `awk`, `git` for hashing
- 20 repeats per case; cold removes `.agent/indexes/` before every invocation, warm primes one verified `HIT` before timing repeated hits

## Results

| Records | Mode | n | Median | p95 |
| --- | --- | --- | --- | --- |
| 100 | Cold | 20 | 130 ms | 160 ms |
| 100 | Warm | 20 | 50 ms | 50 ms |
| 1,000 | Cold | 20 | 380 ms | 470 ms |
| 1,000 | Warm | 20 | 110 ms | 120 ms |

Reproduce with:

```
scripts/index-benchmark.sh 20
```

## Comparison against the spike (`tmp/merge-6.2/spikes/indexes/RESULTS.md`)

| Records | Mode | Spike (mean / min / max) | This run (median / p95) |
| --- | --- | --- | --- |
| 100 | Cold | 182 / 150 / 210 ms | 130 / 160 ms |
| 100 | Warm | 88 / 60 / 180 ms | 50 / 50 ms |
| 1,000 | Cold | 478 / 430 / 550 ms | 380 / 470 ms |
| 1,000 | Warm | 143 / 120 / 230 ms | 110 / 120 ms |

On the surface this run is faster everywhere, not slower. That is **not** an honest apples-to-apples win, and should not be read as one:

- The spike's fixture was a real `docs/`+`rules/` corpus — 288,817 bytes across 100 records (~2.9 KB/record) per its own RESULTS.md. That fixture (`spikes/indexes/sources/`) is not checked into the repository, so it could not be reproduced for this run.
- `scripts/index-benchmark.sh` instead generates a synthetic fixture (`make_fixture`) with a ~80-byte, three-line body per record, roughly 35x smaller per record than the spike's corpus. Less content means less for `git hash-object` to hash and less for `awk` to scan and copy — that gap plausibly accounts for most or all of the difference, independent of any change in the mechanism itself.
- This implementation does strictly more work per record than the spike's than the number the spike measured: it computes a tree digest over every rendered page (`tree_digest`), re-fingerprints sources before publish (bounded-retry recheck), and — as of this round's fix for relative-link preservation — scans every line of every rule body with an `awk` regex loop (`rewrite_links`) looking for `](`. None of that is free, and none of it is exercised meaningfully by a fixture with one short link-free line per record in most cases.

**Conclusion: this benchmark cannot support a claim that the implementation is faster than the spike, only that it is not obviously slower at this fixture size.** A same-size, same-content comparison would need the spike's original fixture, which is not available in this repository. Anyone revisiting this budget should first restore or rebuild a byte-matched fixture (e.g. by copying `docs/` and `rules/` content of comparable size into `index-benchmark.sh`'s `make_fixture`) before drawing a real regression conclusion either way.

## Known gaps in this measurement

- Single machine, single run captured here; latency on Linux (the spike's other stated target) has not been measured.
- The synthetic fixture has no long rule bodies and only one relative link total across the whole corpus, so `rewrite_links`' per-line cost is not stress-tested by this harness.
- `/usr/bin/time -p`'s hundredths-of-a-second resolution limits precision at the low end (warm-cache runs sit near that floor).
