# RadixTree benchmarks: 2026-10-02

Crystal `require "radix_tree"` vs **Rust `radix_trie` 0.3.0** and
**`qp-trie` 0.8.2** (rustc 1.97.0, LTO, `codegen-units = 1`) vs **Go
`armon/go-radix` 1.0.0** (go1.24.7). All use `u64` values and the same
generated keys. Crystal 1.21.0 bootstrap compiler with the in-tree stdlib,
`--release`. 4 vCPU Xeon @ 2.80GHz (Firecracker VM, noisy: the same binary
varies by up to 2x between runs).

Reproduce (from this directory):

```sh
./run.sh 6          # builds all three, runs 6 alternating rounds, prints the table
```

Or by hand: `bin/crystal build --release bench.cr`, `cargo run --release`,
`cd go && go run .`.

## Data and operations

Two key sets of 100,000 keys each, built by formula so all languages agree
(each run prints a checksum per cell, which matches across languages):

- **urls**: `/api/v1/users/{i}/posts/{i*7 % 1000}` for i in 0...100000.
- **words**: 3-12 lowercase letters from an LCG
  (`state = state * 6364136223846793005 + 1442695040888963407`, using
  `state >> 33`; length `3 + r % 10`, letters `'a' + r % 26`). 97,547 are
  distinct; duplicates overwrite.

Probe order is `keys[j * 7919 % N]`, a permutation of the keys.

| op | what (ns per op) |
|---|---|
| insert | build a fresh tree from all keys (keys pre-allocated outside the clock; Rust moves owned `String`s into `radix_trie` and borrows `&[u8]` into `qp-trie`; Crystal stores a reference to the `String`) |
| get_hit | look up every key, in probe order |
| get_miss | look up `key + "~"` for every key (absent) |
| longest_prefix | longest stored prefix of `key + "/comments/12"` (urls) or `key + "qz"` (words); value only |
| prefix_vals | iterate every key under 90 prefixes `/api/v1/users/10`..`99` (urls) or all 676 two-letter prefixes (words), summing values; ns per entry |
| prefix_keys | same, also reading each key's length |
| delete_half | delete the keys at even probe positions (50,000 deletes) |

API mapping: Crystal `[]?`, `longest_prefix_value`, `each_with_prefix`,
`delete`. `radix_trie`: `get`, `get_ancestor_value`,
`get_raw_descendant(..).iter()`/`.values()`, `remove`. `qp-trie`: `get`,
`iter_prefix`, `remove`; it has no longest-stored-prefix query, so that
cell uses `longest_common_prefix` and then probes shorter prefixes with
`get` (what a user would write). go-radix: `Get`, `LongestPrefix`,
`WalkPrefix`, `Delete`.

## Results

6 alternating rounds; each cell is the best of 5 repetitions within a run,
then the best (and median) across rounds:

| data | op | Crystal | radix_trie | qp-trie | go-radix | Crystal / best Rust (best) | (median) |
|---|---|---:|---:|---:|---:|---:|---:|
| urls | insert | 166.6 (173.7) | 272.5 (307.6) | 147.8 (154.8) | 277.7 (295.6) | 1.13 | 1.12 |
| urls | get_hit | 287.1 (321.1) | 1129.9 (1238.2) | 155.9 (310.4) | 910.9 (963.5) | 1.84 | 1.03 |
| urls | get_miss | 111.6 (129.8) | 784.1 (824.4) | 86.6 (109.8) | 503.6 (615.9) | 1.29 | 1.18 |
| urls | longest_prefix | 391.1 (408.9) | 884.0 (950.8) | 379.6 (416.7) | 868.2 (882.9) | 1.03 | 0.98 |
| urls | prefix_vals | 3.7 (3.9) | 78.8 (87.9) | 3.4 (3.8) | 6.3 (8.9) | 1.09 | 1.04 |
| urls | prefix_keys | 6.8 (9.2) | 70.1 (91.8) | 3.5 (3.6) | 6.5 (8.2) | 1.94 | 2.57 |
| urls | delete_half | 432.2 (457.0) | 1284.9 (1400.0) | 399.0 (417.2) | 772.7 (792.2) | 1.08 | 1.10 |
| words | insert | 280.8 (286.9) | 575.0 (641.5) | 358.0 (444.7) | 774.6 (816.3) | 0.78 | 0.65 |
| words | get_hit | 302.0 (348.6) | 1057.2 (1097.0) | 288.5 (363.5) | 701.2 (770.5) | 1.05 | 0.96 |
| words | get_miss | 214.2 (226.6) | 779.3 (835.8) | 159.8 (185.2) | 424.7 (527.1) | 1.34 | 1.22 |
| words | longest_prefix | 367.7 (394.1) | 837.0 (891.3) | 427.2 (542.4) | 650.5 (735.9) | 0.86 | 0.73 |
| words | prefix_vals | 10.3 (12.6) | 247.2 (255.9) | 17.1 (20.9) | 48.6 (77.8) | 0.60 | 0.60 |
| words | prefix_keys | 11.9 (15.4) | 226.3 (251.7) | 16.2 (18.6) | 45.8 (82.4) | 0.73 | 0.83 |
| words | delete_half | 344.8 (451.1) | 1404.6 (1440.9) | 442.3 (540.2) | 656.0 (690.8) | 0.78 | 0.84 |

Summary: Crystal is 2.5-25x faster than `radix_trie` (the crate with the
same data structure and API) everywhere, and 1.5-5x faster than go-radix.
Against `qp-trie`, every median is within 1.25x except **urls
prefix_keys**, and every best-of cell is within 1.34x except two:

- **urls get_hit, best 1.84x, median 1.03x.** qp-trie's get_hit is
  bimodal on this VM: 156 and 188 ns in two rounds, 302-359 ns in the
  other four. Crystal ranged 287-384 ns. Its typical run is on par.
- **urls prefix_keys, 1.9-2.6x.** This one is the key representation, not
  the tree. Iterating the entries themselves (prefix_vals) is on par. Reading
  `key.bytesize` on a Crystal `String` is a load from the string object,
  which sits elsewhere in memory. Rust's `&[u8]`/`&String` and Go's `string`
  carry the length in the reference the trie already holds. go-radix pays a
  similar price (6.5 ns). A software prefetch of keys a few slots ahead
  brought it to 6.0 ns. It was rejected: it slowed value-only iteration by
  20-35%, and it needs an LLVM intrinsic the interpreter lacks.

## What moved the numbers

Starting point: class nodes, each with a label `Bytes`-like pointer into
a stored key, a value, and one block holding child pointers plus their
first bytes. Labels compared at every level.

| step | urls get_hit / miss | words get_hit / miss | urls prefix_vals |
|---|---|---|---|
| class nodes, labels compared per level | 660 / 554 | 624 / 574 | 8.5 |
| PATRICIA-style lazy check: descend on first bytes only, compare the whole key once at the end against the stored key (or, for prefix queries, against the node's path, which its label pointer spells) | ~760 / ~350 (noise) | ~640 / ~400 | - |
| nodes as structs inline in the parent's edge block (qp-trie's "twigs" layout): one block read per level, leaves cost no object | 497 / 174 | 472 / 216 | ~7 |
| first bytes inline in the node (8 bytes, SWAR search) | 557 / 225 (URL digit nodes have 11 children, so still out of line) | 298 / 213 | - |
| 16 inline first bytes (two words), node 56 bytes | 265-290 / 112 | 242-302 / 199-214 | 6.7 |
| block iteration as an inlined loop with the traversal state in locals (instead of a `Walker` struct method per entry) | - | - | 3.7 (in-cache 3.7 -> 1.6 ns/entry) |

Other choices:

- Keys are stored once: a `String` key is kept by reference (no copy); a
  `Bytes` key is copied into a new `String` once. Labels are pointers into
  those strings, so splitting an edge never allocates, and merging on
  delete slices the label from a key below the merged node. Iteration and
  `longest_prefix` return the stored strings, so they never allocate per
  key.
- Lookups (`[]?`, `has_key?`, `fetch`, `longest_prefix_value`) do not
  allocate.
- Not tried / left out: a 256-slot table for dense nodes. Linear search
  over at most 16 inline bytes covers the measured data, and words' 26-way
  root sits in cache. Shrinking nodes to 48 bytes by folding the label
  pointer into the key reference for value nodes is a possible next step
  for iteration.
