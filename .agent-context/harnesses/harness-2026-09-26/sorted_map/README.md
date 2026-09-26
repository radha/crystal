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

| op | n | Crystal | Rust | ratio | Go |
|---|---|---:|---:|---:|---:|
| insert_rand | 1K | 60.5 | 44.9 | 1.35 | 87.5 |
| insert_seq | 1K | 78.9 | 60.3 | 1.31 | 49.4 |
| bulk_sorted | 1K | 12.5 | 8.5 | 1.47 | n/a |
| get_hit | 1K | 26.8 | 22.3 | 1.20 | 75.6 |
| iter_all | 1K | 0.9 | 1.6 | 0.56 | 3.7 |
| range_100 | 1K | 1.9 | 1.5 | 1.27 | 4.6 |
| floor | 1K | 20.9 | 21.9 | 0.95 | 93.5 |
| delete_rand | 1K | 73.0 | 49.9 | 1.46 | 93.5 |
| insert_rand | 100K | 163.2 | 135.0 | 1.21 | 275.4 |
| insert_seq | 100K | 99.1 | 80.5 | 1.23 | 93.0 |
| bulk_sorted | 100K | 12.9 | 12.3 | 1.05 | n/a |
| get_hit | 100K | 111.0 | 111.3 | 1.00 | 292.1 |
| iter_all | 100K | 0.8 | 1.3 | 0.62 | 7.0 |
| range_100 | 100K | 2.3 | 2.2 | 1.05 | 11.7 |
| floor | 100K | 128.1 | 123.4 | 1.04 | 299.9 |
| delete_rand | 100K | 158.1 | 137.1 | 1.15 | 270.4 |
| insert_rand | 1M | 301.2 | 310.3 | 0.97 | 437.6 |
| insert_seq | 1M | 120.5 | 102.5 | 1.18 | 104.8 |
| bulk_sorted | 1M | 17.0 | 15.8 | 1.08 | n/a |
| get_hit | 1M | 222.5 | 279.5 | 0.80 | 492.6 |
| iter_all | 1M | 1.4 | 1.8 | 0.78 | 5.3 |
| range_100 | 1M | 6.0 | 5.6 | 1.07 | 10.8 |
| floor | 1M | 233.3 | 264.3 | 0.88 | 571.3 |
| delete_rand | 1M | 312.7 | 277.2 | 1.13 | 556.3 |

The target was within 1.5× of Rust everywhere, and it is met. The shared VM
adds ±15% noise between runs, mostly at 1K. The slowest cells are small-map
insert, delete and bulk build: GC allocation of nodes costs more than
Rust's allocator when nodes are small and short-lived.

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

## Follow-ups (not done)

- `delete_range` collects the keys and deletes them one by one,
  O(k log n). A split/join implementation would be O(log n + k).
- Small-n insert/delete: try a free list of nodes, or allocating leaves
  with `malloc_atomic` for pointer-free K and V (GC already does this for
  `Node(UInt64, UInt64)`).
