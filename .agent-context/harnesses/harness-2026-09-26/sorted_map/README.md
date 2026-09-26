# SortedMap benchmarks: 2026-09-26

Crystal `require "sorted_map"` vs **Rust `std::collections::BTreeMap`** vs
**Go `github.com/google/btree` v1.1.3** (`BTreeG`, degree 32). All three use
`u64` keys and values from the same SplitMix64 stream (seed 1). Each
benchmark reports the best of several runs (200 at 1K, 5 at 100K, 3 at 1M)
in ns per operation.

Reproduce:

```sh
S=/tmp/sm && mkdir -p $S
CRYSTAL_PATH=$PWD/../../../../src crystal build --release bench.cr -o $S/bench_cr && $S/bench_cr
cargo build --release && ./target/release/bench
(cd go && go build -o $S/bench_go . && $S/bench_go)
```

## Environment

Cloud VM, 4 vCPU Intel Xeon @ 2.10GHz. Crystal 1.21.0 bootstrap compiler
with the in-tree stdlib, `--release`. rustc 1.94.1 with `lto = true`,
`codegen-units = 1`. go1.24.7.

## Workloads

| name | what |
|---|---|
| insert_rand | fresh map, insert n keys in random order |
| insert_seq | fresh map, insert n keys in ascending order |
| bulk_sorted | build from n sorted entries (`from_sorted` / `collect()`) |
| get_hit | n lookups of present keys, shuffled |
| iter_all | sum every value in order |
| range_100 | 1000 range scans (`lo..`) of 100 entries each |
| floor | n "largest key <= probe" queries (`floor` / `range(..=k).next_back()`) |
| delete_rand | bulk-build, then delete every key in shuffled order |

The map read by get_hit, iter_all, range_100 and floor is built by sorting
and bulk-building in all three languages (Rust's `collect()` does this under
the hood). An earlier Crystal run built it by random insertion. That gives
~70%-full, scattered nodes, and made iteration look 3-8× slower than Rust
when it is actually faster.

## Results (ns/op; ratio = Crystal / Rust)

Best of three alternating runs, after the second round (split point, split/join).

| op | n | Crystal | Rust | ratio | Go |
|---|---|---:|---:|---:|---:|
| insert_rand | 1000 | 51.3 | 42.6 | 1.20 | 85.7 |
| insert_seq | 1000 | 47.6 | 46.3 | 1.03 | 48.2 |
| bulk_sorted | 1000 | 7.9 | 6.5 | 1.22 | n/a |
| get_hit | 1000 | 16.2 | 15.5 | 1.05 | 74.3 |
| iter_all | 1000 | 0.7 | 1.2 | 0.58 | 3.7 |
| range_100 | 1000 | 1.4 | 1.5 | 0.93 | 4.6 |
| floor | 1000 | 12.8 | 19.9 | 0.64 | 93.0 |
| delete_rand | 1000 | 51.6 | 46.8 | 1.10 | 91.7 |
| insert_rand | 100000 | 148.3 | 133.7 | 1.11 | 231.6 |
| insert_seq | 100000 | 89.7 | 79.1 | 1.13 | 87.0 |
| bulk_sorted | 100000 | 12.9 | 11.6 | 1.11 | n/a |
| get_hit | 100000 | 100.5 | 104.4 | 0.96 | 231.6 |
| iter_all | 100000 | 0.8 | 1.2 | 0.67 | 3.9 |
| range_100 | 100000 | 2.3 | 2.2 | 1.05 | 6.9 |
| floor | 100000 | 112.0 | 108.2 | 1.04 | 256.4 |
| delete_rand | 100000 | 147.5 | 131.4 | 1.12 | 249.2 |
| insert_rand | 1000000 | 259.5 | 269.7 | 0.96 | 395.9 |
| insert_seq | 1000000 | 103.9 | 98.4 | 1.06 | 107.7 |
| bulk_sorted | 1000000 | 14.9 | 8.8 | 1.69 | n/a |
| get_hit | 1000000 | 194.5 | 215.4 | 0.90 | 444.8 |
| iter_all | 1000000 | 0.9 | 1.5 | 0.60 | 4.3 |
| range_100 | 1000000 | 5.3 | 5.3 | 1.00 | 10.6 |
| floor | 1000000 | 201.2 | 228.9 | 0.88 | 465.6 |
| delete_rand | 1000000 | 249.7 | 253.7 | 0.98 | 411.8 |

The target was within 1.5× of Rust everywhere. Every cell is at or under
1.22×, except the 1M bulk build (1.69× here; Rust's own time swings from 8.9
to 15.8 ns between runs, and the gap is fresh-memory cost). The shared VM
adds ±15% noise between runs, mostly at 1K.

## What moved the numbers

1. **Node layout.** Crystal placed `@len`, which was declared through its
   initializer, after both key arrays (offset 184). Declaring the ivar types
   explicitly puts it at offset 4, in the type id's padding, on the same
   cache line as the first keys.
2. **Leaf fast loop.** Block iteration walks a leaf's keys in a plain loop
   and only uses the cursor between leaves. iter_all went from 13.1 to
   1.4 ns at 1M.
3. **Direct floor/ceiling/lower/higher.** One descent that keeps the best
   candidate, instead of positioning a cursor: 1.5× to ~0.9-1.0× of Rust.

## Second round (same day)

4. **Rust's split point.** A full node now splits at index 4, 5 or 6
   depending on where the new key lands, so in-order inserts leave nodes
   with 6 keys instead of 5. Sequential insert at 1K: 59 -> 53 ns.
5. **delete_range by split and join** (see the design doc): 10K keys out
   of 1M 585 -> 13 us, 100K keys 5.8 ms -> 55 us.

Measured and rejected:

- A one-compare-per-key search for integer keys. It helped sequential
  insert by 3%, but random get went 14.0 -> 16.5 ns and floor
  19.5 -> 26.6 ns at 1K.
- `GC_DONT_GC=1` or a 512 MB initial heap for bulk builds. Both were
  slower: the 1M bulk-build gap is fresh memory (17 MB of nodes), not
  collection.

## Follow-ups (not done)

- bulk_sorted at 1M stays 1.2-1.7x (Rust itself swings 8.9-15.8 ns): it
  would need a node arena.
