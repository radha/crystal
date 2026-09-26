# Harnesses for the 2026-09-17 queue-drain batch (commits 25e2a8a9a..798ddd2cd)

Method: never inline-reimplement; build a BASE binary from the pre-change tree and a NEW
binary from the changed tree, then compare.

    bin/crystal build --release -o /tmp/x_base bench_valid.cr   # at the old commit / stash
    bin/crystal build --release -o /tmp/x_new  bench_valid.cr   # with the change
    /tmp/x_base; /tmp/x_new

Differentials print `<cases> cases <sha256>`; base and new must match for every seed:

    /tmp/diff_small_base 7; /tmp/diff_small_new 7     # valid?, inspect/dump, CSV quote_cell, Deque sorts
    /tmp/diff_json_base 5;  /tmp/diff_json_new 5      # both JSON lexers, PullParser, parse, from_json

Baseline commit for this batch: 461bbcba5. Sinks are Int64 `&+=` (Int32 overflows in Benchmark.ips).

## Binary foundation batch (Tier 1a + 1c, 2026-09-17)

`bench_varint.cr` / `bench_varint.go` / `bench_varint.rs` share one workload: 1M xorshift
values in three width mixes (small < 128, medium < 2^28, full = uniform bit length 1..64),
encoded into a 10 MB buffer and decoded back, plus 1M 32-byte frames through a memory buffer.

    bin/crystal build --release -o /tmp/bv_cr bench_varint.cr && /tmp/bv_cr
    go build -o /tmp/bv_go bench_varint.go && /tmp/bv_go
    rustc -C opt-level=3 -C target-cpu=native -o /tmp/bv_rs bench_varint.rs && /tmp/bv_rs

Numbers at commit time (ns/op, Apple Silicon, best of 20):

    case                   crystal   go     rust
    small encode slice      1.55    1.80   1.27
    small decode slice      1.13    1.51   0.92
    medium encode slice     2.05    2.53   2.28
    medium decode slice     2.06    3.22   1.64
    full encode slice       6.87    7.30   7.11
    full decode slice       8.52    9.49   7.18
    small encode IO         1.37    4.06   -      (Go: bytes.Buffer)
    small decode IO         2.30    3.17   -      (Go: bytes.Reader)
    full decode IO          9.07   18.45   -
    frame read(into:) 32B   8.13    7.28   -      (Go allocates; Crystal into: does not)
    frame read 32B         11.53    7.28   -      (GC malloc_atomic vs Go bump alloc)

The codec itself is ~0.5 ns encode / 0.6 ns decode for 1-byte values; the rest of the
"slice" rows is `Bytes#[](Range)` in the harness, which this batch cut from ~2 ns to ~1 ns
(`Slice#[](Range)` single-pass rewrite). Rust's harness slices too (`&buf[pos..]`).
Frame write measures 2.8 ns in isolation (same as a bare 36-byte `IO::Memory#write`) but
8-11 ns inside this harness; not chased, 3+ GB/s either way.

## Heap batch (Tier 5, 2026-09-17)

`bench_heap.cr` / `bench_heap.rs` share one workload: 1M xorshift32 values pushed then
popped, heapified then popped, a 1024-element steady state (push+pop, push_pop,
replace_top = Rust `peek_mut`), an 8-byte `Job` struct ordered by one field, and a 24-byte
`Wide` struct. Rust uses `BinaryHeap<Reverse<_>>` so both are min-heaps.

    bin/crystal build --release -o /tmp/bh_cr bench_heap.cr && /tmp/bh_cr
    rustc -C opt-level=3 -C target-cpu=native -o /tmp/bh_rs bench_heap.rs && /tmp/bh_rs

Numbers at commit time (ns/op, Apple Silicon, best of 5), binary layout as shipped, plus
the 4-ary layout that was tried and dropped:

    case                          crystal  4-ary   rust
    push 1M + pop 1M                31.7    32.1   27.9
    heapify 1M + pop 1M             27.1    28.7   25.2
    heapify 1M only                  3.3     1.5    3.1
    steady push+pop (1024)          34.1    36.5   37.1   (layout-noise band ±30%: Rust read 26 in a smaller binary)
    steady push_pop (1024)           1.0     1.1    -
    steady replace_top (1024)        2.6     3.6    1.5
    Job <=> push 1M + pop 1M        52.3    40.9   32.4
    Job block push 1M + pop 1M      63.9    66.5   -      (comparator Proc, indirect call per compare)
    max block push 1M + pop 1M      43.6    50.8   27.7
    Job steady push+pop (1024)      29.8    49.1   39.3
    Wide 24B push 1M + pop 1M       70.9    57.4   59.3

What moved the numbers: the first version resolved the comparator (`@compare` nil check)
inside a `less?` method called per level; because the sift stores through a raw pointer,
LLVM reloaded `@compare` after every store. Passing the comparison as a yield block chosen
once per operation (`with_less` macro) took push+pop from 52 to 34 ns and Job from 62 to
54. Wrapping index arithmetic (`&+`, `&*`) removed the overflow branches: 34 -> 32.

4-ary layout: wins only where the heap is cache-miss bound with wide elements (heapify-only
2x, Job/Wide 1M 1.2x) and loses every in-cache case (steady state, replace_top, small
structs), so the binary layout stays; Rust's `BinaryHeap` is binary too.

Open: `Job` (8-byte struct) trails Rust 1.6x while `Int32` trails 1.14x; not allocation
(presized run is identical) and the `<=>` sift loops compile to a single `cmp` plus an
8-byte copy per level. Not chased.
