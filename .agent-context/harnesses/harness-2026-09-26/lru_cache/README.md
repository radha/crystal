# LRUCache benchmarks: 2026-09-26

Crystal `require "lru_cache"` vs **Rust `lru` 0.12.5** (default hasher,
foldhash) vs **Go `hashicorp/golang-lru/v2` v2.0.7**. All three use
`u64` keys and values from the same SplitMix64 streams. Each cell is the
best of three alternating runs (each run itself the best of 200 / 5 / 3
repetitions at 1K / 100K / 1M), in ns per operation.

Reproduce:

```sh
S=/tmp/lru && mkdir -p $S
CRYSTAL_PATH=$PWD/../../../../src crystal build --release bench.cr -o $S/bench_cr
$S/bench_cr; $S/bench_cr sync          # LRUCache, SyncLRUCache
cargo build --release && ./target/release/bench
(cd go && go build -o $S/bench_go . && $S/bench_go && $S/bench_go sync)
```

Same VM as the SortedMap harness (4 vCPU Xeon @ 2.10GHz; Crystal 1.21.0
bootstrap with the in-tree stdlib, `--release`; rustc 1.94.1 with LTO;
go1.24.7).

## Workloads (n = cache capacity)

| name | what |
|---|---|
| get_hit | full cache, read every key in shuffled order (all hits, each promotes) |
| set_evict | fresh cache, write 2n distinct keys (the second half evicts) |
| fetch_mix | fresh cache, 2n reads from a universe of 2n keys; a miss computes and stores (`fetch` / `get_or_insert` / Get+Add) |

## Results (ns/op; ratio = Crystal / Rust)

Go "simplelru" is the unlocked cache, the fair match for `LRUCache`. Go
"locked" is `lru.Cache` (a mutex, no single-flight), next to
`SyncLRUCache` (a mutex, plus single-flight `fetch`). Everything runs on
one fiber, so this measures lock overhead, not contention.

| op | n | Crystal | Rust | ratio | Go simplelru | Crystal Sync | Go locked |
|---|---|---:|---:|---:|---:|---:|---:|
| get_hit | 1000 | 7.0 | 4.7 | 1.49 | 15.7 | 24.9 | 38.5 |
| set_evict | 1000 | 32.1 | 28.8 | 1.11 | 82.7 | 45.4 | 103.2 |
| fetch_mix | 1000 | 15.4 | 27.6 | 0.56 | 74.5 | 61.3 | 106.7 |
| get_hit | 100000 | 22.5 | 14.2 | 1.58 | 45.7 | 39.2 | 69.1 |
| set_evict | 100000 | 57.9 | 65.2 | 0.89 | 166.0 | 73.2 | 221.1 |
| fetch_mix | 100000 | 55.8 | 63.5 | 0.88 | 156.1 | 106.6 | 202.2 |
| get_hit | 1000000 | 43.6 | 37.0 | 1.18 | 148.7 | 103.9 | 215.0 |
| set_evict | 1000000 | 90.4 | 150.4 | 0.60 | 271.1 | 110.8 | 339.2 |
| fetch_mix | 1000000 | 87.5 | 161.1 | 0.54 | 290.0 | 193.7 | 373.6 |

Reads are 1.2-1.6× Rust. Writes and fetches match or beat it, up to 1.85×
faster at 1M. Go is 2-3× slower than Crystal throughout. 100K reads varied
between 1.43× and 1.70× across runs.

## What moved the numbers

Starting point: slots in parallel buffers (keys, values, prev, next) and a
`Hash(K, Int32)` index. Reads were 13.5 / 50 / 154 ns (2.4-2.8× Rust).

1. **One struct per slot and a custom index.** An open-addressing table of
   `tag << 32 | slot + 1` entries with linear probing, at most half full,
   and backward-shift deletion (no tombstones). The home bucket comes
   from the tag, so rehash and deletion never rehash keys. 1M reads
   154 -> 53 ns, 1M writes 167 -> 108.
2. **A cheap hash for integer keys.** `Int#hash` goes through
   `Crystal::Hasher` (a modulo by a prime plus mixing): 14% of
   instructions in callgrind. Now a seeded folded multiply (foldhash's
   construction, with a secret per-process seed against HashDoS), plus
   `unsafe_shr` on hot shifts. 1K reads 12.5 -> 7 ns. Other key types
   keep `key.hash`.
3. **Links in their own dense array** (prev and next interleaved), so
   relinking touches 8 bytes per neighbour instead of their slots. Also
   the table mask is cached in an ivar.
4. **SyncLRUCache:** a waiter channel is created only when a second fiber
   waits on the same key. Sync fetch_mix at 1K 73 -> 61 ns.

## Follow-ups (not done)

- Reads at 100K: memory-level parity would need prefetching or a smaller
  slot (for example, storing values out of line for large V).
- Sync: two lock acquisitions per miss (lookup, then store). A
  lock-striped or sharded variant would scale better under contention.
