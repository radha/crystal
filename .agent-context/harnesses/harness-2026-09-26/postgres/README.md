# PostgreSQL client benchmarks — 2026-09-26

Crystal `require "postgres"` (in-tree `src/postgres/`, slice 1) vs **Go pgx v5.11.0**
(`pgxpool`) and **Rust tokio-postgres 0.7.18** (`deadpool-postgres` 0.14.2 for the pool),
per design doc §13 (`docs/superpowers/specs/2026-09-26-postgres-client-design.md`).

Reproduce: `./run.sh` (builds all three in release mode, loads `setup.sql`, runs each
benchmark 3× per implementation sequentially, prints the table; raw lines in `results/`).

## Environment

| | |
|---|---|
| Machine | cloud VM (Firecracker kernel `6.18.44-fc-v37`), `nproc` = **4**, `Intel(R) Xeon(R) Processor @ 2.80GHz`, 15 GiB RAM |
| Server | PostgreSQL 16.13 (Ubuntu 16.13-0ubuntu0.24.04.1), same VM, loopback TCP `127.0.0.1:5432`, trust auth, `sslmode=disable` |
| Crystal | compiler 1.21.0 (LLVM 20.1.8, bootstrap) driven via `bin/crystal` with the in-tree stdlib (`src/VERSION` 1.22.0-dev, HEAD `c5047a6`), `--release`. Default build = execution-context runtime with the default context at **1 worker** |
| Crystal MT | same, plus `-Dpreview_mt -Dexecution_context`; bench 3 runs inside `Fiber::ExecutionContext::Parallel.new("bench", 4)` with `CRYSTAL_WORKERS=4` |
| Go | go1.24.7 linux/amd64, `github.com/jackc/pgx/v5` v5.11.0 (+ `pgxpool`, puddle v2.2.2). `GOMAXPROCS` left at its default = nproc = **4** |
| Rust | rustc/cargo 1.94.1, `tokio` 1.53.1 (`#[tokio::main(flavor = "multi_thread")]`, default worker count = 4), `tokio-postgres` 0.7.18, `deadpool-postgres` 0.14.2 (`RecyclingMethod::Fast`), `chrono` 0.4.45; `--release`, `lto = true`, `codegen-units = 1` |

## What each benchmark does (identical in all three)

1. **seq** — one connection; 1000 warm-up then 20 000 × `select $1::int4` with the loop index
   (prepared/cached statement), per-op latency timed individually. Mean = total wall time / 20 000.
2. **fetch** — one connection; `select id, name, score, at, ok from bench_rows` (10 000 rows of
   `int8, text, float8, timestamptz, bool`) decoded into a struct: Crystal
   `include Postgres::Serializable`, Go `pgx.CollectRows(rows, pgx.RowToStructByPos[BenchRow])`,
   Rust `row.get(i)` into a struct (`chrono::DateTime<Utc>` for `at`). 10 warm-up, 200 timed.
3. **pool** — 64 concurrent tasks × 2000 `select $1::int4`, each op checks a connection out of a
   pool of 8 and back in: Crystal 64 fibers on `Postgres::Client.new(url, pool_size: 8)`; Go
   64 goroutines on `pgxpool` `MaxConns = 8`; Rust 64 tokio tasks on a **deadpool-postgres** pool
   of 8 (`pool.get()` + `prepare_cached` per op). A 64 × 50 warm-up opens all 8 connections and
   prepares the statement on each before timing.

Statement caching: Crystal's per-connection LRU; pgx default `QueryExecModeCacheStatement`;
tokio-postgres `prepare` once (seq/fetch) / deadpool `prepare_cached` (pool). All binary format.

## Results

Median of 3 runs (the three runs in brackets), from the final `./run.sh`:

| metric | Crystal | Go pgx | Rust tokio-postgres | Crystal MT (4 workers) |
|---|---:|---:|---:|---:|
| 1. seq mean µs/op | **62.8** (69.3 62.8 61.4) | 83.7 (81.7 83.7 87.8) | 126.3 (128.1 126.3 119.1) | — |
| 1. seq p50 µs | **58.1** (64.4 58.1 56.3) | 79.3 (77.3 79.3 82.0) | 116.4 (117.9 116.4 111.2) | — |
| 1. seq p99 µs | **120.4** (132.5 119.7 120.4) | 160.2 (158.5 160.2 160.9) | 225.9 (242.6 225.9 220.2) | — |
| 2. fetch ms / 10k rows | **4.81** (4.52 4.92 4.81) | 7.98 (7.50 7.98 8.01) | 7.24 (7.24 7.21 7.48) | — |
| 2. fetch rows/s | **2.08 M** (2.21 2.03 2.08) | 1.25 M (1.33 1.25 1.25) | 1.38 M (1.38 1.39 1.34) | — |
| 3. pool ops/s | 37 597 (37 317 37 597 40 665) | **61 586** (66 405 61 586 54 798) | 56 592 (56 592 56 485 57 553) | 43 948 (43 948 43 312 45 039) |

Diagnostic (not a §13 benchmark): the same 64 × 2000 load on the default Crystal runtime, but
8 raw `Postgres::Connection`s handed out through a `Channel(Connection)` instead of `Pool(T)`:
**40 430** ops/s (40 430 42 743 39 112).

Against the §13 targets:

| target | result |
|---|---|
| (1) seq within 5 % of pgx | **met** — Crystal 0.75× pgx's mean latency (25 % lower) |
| (2) fetch ≥ pgx | **met** — 1.66× pgx's rows/s (and 1.51× tokio-postgres) |
| (3) pool ≥ pgx | **missed** — 0.61× pgx single-threaded (1.64× slower); 0.71× pgx with the 4-worker MT context (1.40× slower) |

## Notes (read before quoting numbers)

- **Noise.** This is a shared 4-vCPU VM, client and server on the same box. Run-to-run spread
  is ~±10 %. The seq numbers in particular are dominated by wake-up latency of an idle vCPU,
  not client code: a stand-alone Go seq run executed straight after `go build` (CPUs still hot)
  measured **29 µs** mean, while every run in the quiet, sequential harness gave 82–98 µs;
  interleaved re-runs (Crystal, Go, Crystal, Go, …) reproduced 66–72 µs vs 90–93 µs. The *order*
  Crystal < Go < Rust for seq was stable across every run I did; the absolute values are not.
  libpq for reference: `pgbench -M prepared -c1 -j1 -t 20000` with `select :i::int4` gave
  71 µs average latency on the same machine.
- **Rust seq is slow because of the multi-thread runtime**, which the task specified: the
  tokio-postgres `Connection` future runs on a different worker from the caller, so each round
  trip incurs cross-thread wake-ups. A `current_thread` runtime would very likely be much faster;
  not measured here.
- **Crystal CPU split in bench 3.** `time ./bench_cr pool`: 3.40 s real, 0.49 s user, 2.63 s sys —
  one OS thread doing all the work at ~92 % busy, ~20 µs of kernel time per op (loopback TCP
  `write`/`read`, plus a `timerfd_settime` per checkout). Go (1.35 s user / 2.20 s sys)
  and Rust (0.77 s user / 2.22 s sys) spend similar kernel time per op but spread it over 4
  threads. Crystal's user-space cost is small (~3.7 µs/op including runtime and GC); the gap is
  that the single worker serializes the syscalls.
- **Crystal MT only partially helps.** With a 4-worker `Parallel` context the pool bench reached
  ~44 k ops/s. Per-thread CPU sampled mid-run: only 2 of the 4 workers had started
  (`bench-0` utime 16 / stime 99 ticks, `bench-1` 12 / 60) and total CPU stayed ≈ 1 core (2.9 s CPU
  in 3.0 s real). Nearly all reads find data already there (`strace`: 3.5 k EAGAIN out of 135 k
  reads), so fibers rarely park in the event loop; they are woken by `Channel` sends on the same
  thread and land on its local queue, and the other workers seldom get anything to steal.
- `strace -c` confirms ~1 `write` + ~1 `read` per op for Crystal (Bind+Execute+Sync coalesced
  in one write), i.e. the wire path itself is tight.
- No `perf` on this VM; profiling was done with `valgrind --tool=callgrind` (instruction
  counts, pool bench) plus `strace -c` and `/proc/<pid>/task/*/stat`.
- The Crystal and Go `fetch` loops build the full 10 000-element array per iteration; Rust
  collects into a `Vec` from `client.query` (which itself buffers all rows). All three verify the
  row count; Crystal/Go/Rust also verify the seq checksum.

## Suspected hotspots (bench 3; no `src/` changes made)

From callgrind on `./bench_cr pool` (1.13 G instructions for ~135 k ops ≈ 8.3 k instr/op) and
`strace -c` (131 k ops):

1. **`src/pool.cr:105-109`** — `select … when @permits.receive … when timeout(@checkout_timeout)`
   on every checkout arms and disarms a timer: **130 800 `timerfd_settime` syscalls ≈ 1 per op**,
   plus two `SelectContext` heap allocations per op (`Channel::StrictReceiveAction` /
   `Channel::TimeoutAction#create_context_and_wait`, ~3.5 % of instructions). A fast path that
   tries a non-blocking `@permits.receive?`/`select … else` first and only falls back to the
   timed select when no permit is free would remove both. The Channel-pool diagnostic above
   (no timer, no timestamps) gains ~8 %.
2. **`src/postgres/result.cr:37-44` via `src/postgres/connection.cr:492`** —
   `ExecResult.from_tag(CommandComplete.from_slice(body).tag)` runs for every query even though
   `query_one`/`query_all` discard the result: allocates the tag `String`, `tag.split(' ')`
   (an `Array(String)` + 2 more strings), then `to_i64?`. **~9.5 % of all instructions**, 3 of the
   ~17 heap allocations per op. Parse lazily (keep the bytes) or only for `exec`.
3. **`src/postgres/connection.cr:475` + `src/postgres/result.cr:55-56`** — a fresh `RowReader` per
   query, with two empty `Array(Int32)` (`@starts`, `@sizes`) that then grow on first `<<`:
   3 objects + 2 buffer allocations per query (`Array(Int32)#check_needs_resize` 262 k calls
   = 2/op, ~1.9 %). Reuse one `RowReader` per connection (reset columns) or pre-size the arrays
   to `columns.size`.
4. **Allocation overall** — `GC_malloc_kind` is the #1 self-cost symbol (11 %), plus `memset`
   5.8 % and `GC_allochblk`/`GC_build_fl` ~4 %; ≈ 10 `GC_malloc` + 7 `GC_malloc_atomic` per op.
   Items 1–3 account for about half of them.
5. **`src/postgres/connection.cr:567-599` (`write_bind`)** — ~13 separate `IO::Memory#write`
   calls per op (each `write_bytes` goes through `increase_capacity_by`), `write_bind` 7 % and
   `IO::Memory#write` 6.8 % inclusive. Writing into a pre-reserved slice with
   `IO::ByteFormat::BigEndian.encode` would cut this; minor next to the syscalls.
6. **`src/postgres/statement_cache.cr:50-54`** — every cache hit does `@entries.delete(sql)` then
   `@entries[sql] = …` to maintain LRU order: the SQL string is hashed twice per query and the
   Hash accumulates deleted slots (periodic compaction). `String#hash` + `Hash#delete` ≈ 1.8 %.
   A hit counter or an intrusive list would avoid the churn.
7. **`src/pool.cr:135` / `:176`** — `Time.instant` at every checkin and checkout
   (`Pool#checkin` 3.4 % inclusive, with its mutex + Deque push + channel send). Cheap (vDSO)
   but per-op.
8. **Runtime, not `src/postgres`** — the dominant factor is that the default runtime runs all
   64 fibers and 8 connections on one thread, so ~20 µs/op of kernel time is serialized; and the
   4-worker `Parallel` context does not spread this load (see notes). Fixing 1–7 would plausibly
   gain 10–20 % of the ~0.5 s user time, not close a 1.6× gap on its own.

Benchmarks 1 and 2 need no profiling (Crystal is fastest on both).

## Rerun after hotspot fixes 1–3 (same day)

Fixed after the profile above: `Pool#checkout` takes a free permit with a
non-blocking `select … else` before arming the timeout (hotspot 1);
`query_*` no longer build an `ExecResult` from the command tag, only
`exec` does (2); one `RowReader` per connection is reused (3). Medians
of 3 runs of `./run.sh`:

| metric | crystal | go | rust | crystal-mt(4w) | crystal-chanpool(diag) |
|---|---:|---:|---:|---:|---:|
| seq mean µs | **68.3** | 88.9 | 119.0 | — | — |
| seq p50 / p99 µs | **62.4 / 137.7** | 83.2 / 173.9 | 110.5 / 208.3 | — | — |
| fetch ms per 10k rows | **4.56** | 8.94 | 7.59 | — | — |
| fetch rows/s | **2.19 M** | 1.12 M | 1.32 M | — | — |
| pool ops/s | 41 579 | **57 414** | 55 304 | 44 871 | 43 216 |

Bench 3 moved from 37.6k to 41.6k ops/s (+11 %; 1.64× → 1.38× behind
pgx; MT 1.28× behind). `Postgres::Client` on `Pool(T)` now matches the
raw channel pool, so the pool overhead is gone; the remaining gap is the
single-threaded runtime serializing the syscalls (see note 8). Target
(3) is still missed. Hotspots 4–7 remain open (slice 2 backlog).

## Rerun after runtime fixes (2026-09-26, after the container restart)

Three more changes, all in the stdlib:

- `98496ad` event loop: lazy system-timer re-arm. Every pool waiter's
  cancelled `select ... timeout` cost a `timerfd_settime`; 129,804 calls
  per run → 6.
- `11537bd` `Pool(T)`: permit counter under the mutex, channel only for
  hand-offs to real waiters; an uncontended checkout allocates nothing
  (`Client#query_one` 64 → 0 bytes/op).
- `91fc30e` `Parallel` scheduler: after the event loop readies several
  fibers, wake up to one parked scheduler per extra fiber. Before, a
  4-worker context ran this benchmark on 2 threads.

Medians of 3 runs of `./run.sh`, same sitting for all:

| metric | crystal | go | rust | crystal-mt(4w) |
|---|---:|---:|---:|---:|
| seq mean µs | **60.2** | 92.9 | 130.1 | — |
| seq p50 / p99 µs | **55.8 / 113.0** | 84.5 / 200.3 | 120.3 / 249.5 | — |
| fetch ms per 10k rows | **4.77** | 8.34 | 7.12 | — |
| pool ops/s | 42 500 | 57 191 | 58 896 | **67 645** |

With the multi-threaded runtime Crystal now leads bench 3 too (1.18× pgx,
1.15× tokio-postgres). The single-threaded default stays ~1.35× behind:
it is one core against Go's and tokio's four, spending most of it in the
kernel on `write`/`read` (one of each per query, the minimum).
