# Binary::Format vs Rust binrw vs Go encoding/binary

Fixtures: `RpcHeader` (fixed 10-byte header: `u8, u8, u32, u32`) and `DataRow`
(variable: 1-byte tag + `size_of` length prefix + count + 10 `Column`s, each
`Column` an `Int32` length prefix followed by an optional byte blob, NULL
encoded as length `-1` with no bytes — the same `#[bw(calc=...)]` /
`field ... value: ->{ value.try(&.size) || -1 }` derived-length pattern in
all three languages).

Built/run 2026-09-18, one compiler process at a time, on the machine
running this session (8 GB, arm64 macOS 27, LLVM 22 pinned in
`Makefile.local`).

## Commands

```
bin/crystal build --release .remember/harness-2026-09-17/format/bench_format.cr \
  -o /private/tmp/claude-502/-Users-radha-projects-crystal/8b511d5b-5329-4cbf-b035-79b3965944f5/scratchpad/bench_format \
  2>&1 | grep -v "ld64.lld\|Using compiled"
/private/tmp/claude-502/-Users-radha-projects-crystal/8b511d5b-5329-4cbf-b035-79b3965944f5/scratchpad/bench_format

cd .remember/harness-2026-09-17/format && cargo run --release --quiet

cd .remember/harness-2026-09-17/format && go run bench_format.go
```

`binrw = "0.14"` resolved and compiled as-is; the brief's fallback
(`#[br(temp)] #[bw(calc(expr))]`) was not needed — `#[bw(calc = ...)]` +
`#[br(temp)]` on the same field compiled cleanly against the available
0.14.x.

## Raw output

Crystal (`Benchmark.ips`, converted iters/sec → ns/op = 1e9/ips):

```
 header from_slice   1.06G (  0.95ns) (± 2.75%)  0.0B/op         fastest
   header write_to 892.07M (  1.12ns) (± 1.57%)  0.0B/op    1.18× slower
  header write(io) 184.37M (  5.42ns) (± 0.54%)  0.0B/op    5.73× slower
datarow from_slice   3.16M (316.79ns) (± 0.52%)  720B/op  334.82× slower
 datarow write(io)   6.00M (166.65ns) (± 0.56%)  0.0B/op  176.13× slower
  datarow to_slice   4.87M (205.55ns) (± 0.81%)  224B/op  217.24× slower
```

Rust (`cargo run --release --quiet`):

```
header read                   7.6 ns/op
header write                  9.5 ns/op
datarow read                388.5 ns/op
datarow write                73.5 ns/op
```

Go (`go run bench_format.go`):

```
header read                   2.0 ns/op
header write                  2.0 ns/op
datarow read                155.0 ns/op
datarow write               218.0 ns/op
```

## Results table

Crystal ops mapped to the closest Rust/Go op (`header write_to`, which
encodes straight into a caller-owned `Bytes` with no IO layer, is the
closest match to Go's direct-buffer write and Rust's `Cursor<Vec<u8>>`
write; `header write(io)` is an extra data point with no exact Rust/Go
counterpart since neither bench has a separate "through an IO/writer
abstraction" fixed-header case).

| Operation | Crystal ns/op | Rust ns/op | Go ns/op | Crystal/Rust | Target | Met? |
|---|---:|---:|---:|---:|---|---|
| header decode (`from_slice` vs `read`) | 0.95 | 7.6 | 2.0 | 0.125× | within 10% | yes (8×faster) |
| header encode (`write_to` vs `write`) | 1.12 | 9.5 | 2.0 | 0.118× | within 10% | yes (8.5×faster) |
| header encode via IO (`write(io)`, extra) | 5.42 | 9.5* | 2.0* | 0.57× | (no direct target) | n/a |
| datarow decode (`from_slice` vs `read`) | 316.79 | 388.5 | 155.0 | 0.815× | within 30% | yes (18% faster than Rust) |
| datarow encode (`write(io)` vs `write`) | 166.65 | 73.5 | 218.0 | 2.27× | within 30% | **no** (127% over) |
| datarow encode, allocating (`to_slice`, extra) | 205.55 | 73.5* | 218.0* | 2.80× | (no direct target) | **no** |

`*` = same Rust/Go number repeated for the extra rows since they measure only one write variant each.

## What dominates each path

**Fixed header.** `RpcHeader.from_slice`/`write_to` compile to
`__binary_decode_scalar`/`__binary_encode_scalar` calls that are macros
(`src/binary/format.cr:596`, `:619`), not runtime dispatch, so at `cat ==
:int` they lower to a single `format.decode`/`.encode` per field — four
loads-with-byteswap on read, four stores-with-byteswap on write, no
allocation, no branching. That is faster than Rust/Go here because it
skips any Cursor/Reader abstraction: `from_slice`/`write_to` operate
directly on a raw pointer into the caller's `Bytes`. `header write(io)`
is slower than `write_to` (5.42 vs 1.12 ns) because it goes through the
generated fixed-layout `write(io)` (`format.cr:1254`), which builds a
10-byte stack buffer via `write_to` and then makes one `io.write` virtual
call — that extra `IO::Memory#write` dispatch plus the sink's
position/capacity bookkeeping is the whole gap. Even so it easily clears
the 10% target since the comparison basis (Rust's own `Cursor` write) pays
similar dispatch cost.

**DataRow (variable).** The decode path (`from_slice`, cat `:array` of
`:nested` `Column`s, `format.cr:611`/`:596`) meets its 30% target (18%
faster than Rust) with 720 B/op — one `Bytes` + one `read_fully` per
column plus the backing `Array(Column)`, matching the brief's expected
allocation shape; no diagnosis needed there.

The write path misses its target (2.27× Rust, 2.80× for the allocating
`to_slice`) and 0 B/op rules out allocation as the cause — the DataRow
generated `write(io)` (`format.cr:1120`) does two full passes over the
10-column array for a `size_of: :rest` field: first
`__binary_size_after_length` (`format.cr:1157`) sums each column's
`byte_size` (a real, non-inlined-across-macro-boundary method call per
column, `format.cr:587`) to fill in the derived `length` header field,
then the main `write` loop calls `__binary_write_scalar` for `:array` of
`:nested` (`format.cr:559`), which calls `Column#write(io)` once per
column; each `Column#write` in turn issues **two** separate
`io.write`/`write_bytes` calls (the derived `Int32` length, then the
value bytes) instead of one combined write. So a 10-column `DataRow`
write is ~23 separate small `IO::Memory#write`/`write_bytes` calls, each
paying `IO::Memory`'s position/capacity bounds check, versus binrw's
generated code writing directly into the `Cursor<Vec<u8>>`'s spare
capacity, which LTO+`codegen-units=1` lets LLVM fuse into far fewer,
larger stores. `to_slice` (`format.cr:1180`) adds a third full traversal
(the outer `byte_size` call, to presize the `Bytes` allocation) on top of
`write`'s two, which is consistent with the ~39 ns gap between `write(io)`
(166.65 ns, two traversals) and `to_slice` (205.55 ns, three traversals),
about 3.9 ns/column/traversal.

Full-program `--emit llvm-ir` was attempted (built a minimal
`RpcHeader.from_slice`-only program and inspected `main`'s IR) but the
function is fully inlined into `main` alongside ~89 k lines of Crystal
runtime/GC init, making a byte-swap/call-count check impractical to read
by hand in the time budget; the fixed-path target is met by a wide margin
regardless (8× faster than Rust, not just within 10%), so this diagnosis
was not pursued further. The write-path diagnosis above instead comes
from reading the macro-generated `write`/`byte_size` bodies in
`src/binary/format.cr` plus the `Benchmark.ips` allocation counts, which
were sufficient to localize the gap to call/traversal count rather than
allocation.

## Proposed change (not made in this task)

Do not change `src/binary/format.cr` here per the brief; for a follow-up
task, three independent, low-risk ideas ranked by expected payoff:

1. **Thread a precomputed size into `write` from `to_slice`.** `to_slice`
   already knows `byte_size` before calling `write`; today `write`
   recomputes the `size_of` field's value from scratch via
   `__binary_size_after_length` a second time. Passing the known total
   down (or having `to_slice` write the `size_of` field directly and
   call a size-skipping `write` variant) removes one whole array
   traversal from `to_slice`, closing roughly the `write(io)`→`to_slice`
   gap (~39 ns of the 205.55 ns, i.e. an ~19% cut for that op).
2. **Batch each `Column`'s two writes into one.** `Column#write` calls
   `io.write_bytes` for the derived length then `io.write` for the value;
   encoding both into one small stack buffer and issuing a single
   `io.write(slice)` per column would roughly halve the per-column
   `IO::Memory` dispatch/bounds-check count (23 calls → ~13 for this
   fixture), which is the largest single contributor to the 2.27×
   headline gap.
3. **`@[AlwaysInline]` on the generated per-record `write`/`byte_size`
   methods** (`format.cr:1120`, `:1154`/`:1157`, `:1180`) so that
   `Array(Column)#each { |c| c.write(io) }`/`{ |c| c.byte_size }` calls
   have a chance to inline across the array-iteration block boundary
   under `--release`; cheap to try, smaller expected payoff than 1–2
   since these are already monomorphic struct calls LLVM can often
   devirtualize on its own — worth measuring before committing to it.

None of these were implemented or measured in this task; a follow-up
should re-run this same harness after each change to confirm the
`write(io)`/`to_slice` ratios actually move before proposing them for
`src/binary/format.cr`.
