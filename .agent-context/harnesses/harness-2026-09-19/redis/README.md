# Redis client benchmarks — 2026-09-19

Crystal `require "redis"` (branch `redis-client`) vs **redis-rs 0.27.6** (tokio
multiplexed) and **go-redis v9.22.0** (RESP3, pooled).

Everything in this directory is gitignored; nothing here is committed.

## Environment

| | |
|---|---|
| Machine | Apple M1, 8 cores, macOS 27.0 |
| Server | Valkey 9.1.2 (`redis_version` 7.2.4), local, `--save "" --appendonly no --port 6379`, db 14 |
| Crystal | 1.22.0-dev `798ddd2cd`, LLVM 22.1.8, `--release` |
| Rust | cargo 1.97.1, `redis` 0.27.6 + `tokio` 1 (full), `--release`, `lto = true` |
| Go | go1.27.1 darwin/arm64, `github.com/redis/go-redis/v9` v9.22.0 |

Each benchmark was run twice back to back; the **second** run is recorded.
`FLUSHDB` on db 14 before every run (each harness also flushes on startup).

## Codec (Crystal only, in-process, 1 M replies per row)

| reply | ns/reply | MB/s |
|---|---:|---:|
| `:42` (int) | 15.7 | 318 |
| `$10` bulk (10 B) | 28.5 | 597 |
| `$1024` bulk (1 KiB) | 133.8 | 7 719 |
| `*10` array of 10 × `$3` | 308.0 | 308 |
| `%10` map of 10 × (`$3`,int) | 624.5 | 216 |
| encode `SET key:12345 value-value-value` | 91.4 ns/command | — |

Run 1 of the codec bench reported `int` at 32.0 ns and `bulk10` at 38.7 ns;
runs 2 and 3 agreed to 0.1 ns (15.7 / 28.4–28.5). Run 1 is cold-start noise
(page faults + CPU ramp), not variance in the code — the warm-up loop in the
harness is not enough for the first row measured.

Per-element cost is consistent: array10 is 30.8 ns per bulk element vs 28.5 ns
for a standalone bulk10, and map10 is 62.5 ns per key/value pair
(≈ 30 ns bulk + ≈ 16 ns int + Hash insert).

## Live, against the same local Valkey

50 000 sequential ops; 64 fibers/tasks/goroutines × 5 000 ops; 10 000-command pipeline.

| case | Crystal | redis-rs | go-redis |
|---|---:|---:|---:|
| sequential GET | **13 263 ops/s** (75.4 µs) | 11 710 ops/s (85.4 µs) | 11 131 ops/s (89.8 µs) |
| 64 × GET | **546 546 ops/s** (1.8 µs) | 329 966 ops/s (3.0 µs) | 146 566 ops/s (6.8 µs) |
| 64 × INCR | **550 355 ops/s** (1.8 µs) | 347 371 ops/s (2.9 µs) | 141 193 ops/s (7.1 µs) |
| 10k pipeline INCR | 1 875 205 ops/s (0.5 µs) | **1 953 061 ops/s** (0.5 µs) | 1 888 351 ops/s (0.5 µs) |

Ratios (Crystal ÷ other):

| case | vs redis-rs | vs go-redis |
|---|---:|---:|
| sequential GET | 1.13× | 1.19× |
| 64 × GET | 1.66× | 3.73× |
| 64 × INCR | 1.58× | 3.90× |
| 10k pipeline | 0.96× | 0.99× |

## Targets (from the spec)

* **Within 20 % of redis-rs on the 64-fiber case** — **met**, with room:
  Crystal is 1.66× (GET) and 1.58× (INCR) *faster* than redis-rs, not within
  20 % below it.
* **Not worse than go-redis sequentially** — **met**: 13 263 vs 11 131 ops/s,
  19 % faster; Crystal is also 13 % faster than redis-rs here.

Nothing missed a target, so no library change was needed and `src/redis/` was
not touched.

## Why the sequential numbers look low (RTT floor)

All three clients land in the 11–13 k ops/s band, i.e. 75–90 µs per round trip.
That is the machine, not the clients. `bench_raw.cr` opens a plain `TCPSocket`
(no fibers, no channels, no mutex, no client at all) and does
`RESP.write_command` / `flush` / `RESP.read` in a tight loop:

```
raw socket sequential GET      13406 ops/s  74.6 µs/op
```

So the loopback + Valkey round-trip floor on this box is **74.6 µs**, and:

| | µs/op | over the floor |
|---|---:|---:|
| raw socket | 74.6 | — |
| Crystal `Redis::Client` | 75.4 | **+0.8 µs (+1.1 %)** |
| redis-rs multiplexed | 85.4 | +10.8 µs (+14 %) |
| go-redis pooled | 89.8 | +15.2 µs (+20 %) |

The Crystal client's whole per-command path — mutex, `Array(RESP::Arg)`,
encode, writer-fiber wakeup channel, waiter channel, reply cast — costs **0.8 µs**
on top of a bare socket. There is no room to win here without attacking the
74.6 µs itself, which is macOS loopback + the server's event loop.

## Why Crystal wins the concurrent case

The client multiplexes one socket: a writer fiber flushes everything that
accumulated during the previous flush, so 64 concurrent fibers turn into large
automatic pipelines (546 k ops/s is **41×** the sequential rate on the same
single socket).

redis-rs's multiplexed connection does the same thing and gets 330 k; the gap is
tokio task wake-up and its per-command `Vec<u8>` + oneshot channel versus
Crystal's cheaper fiber switch and pooled `Waiter`.

go-redis does *not* multiplex — `redis.NewClient` is a pool (default
`PoolSize = 10 × GOMAXPROCS`), so 64 goroutines contend for ~80 sockets each
doing a real blocking round trip with no cross-goroutine pipelining. That is a
design difference, not a code-quality one, and it explains the 3.7–3.9× gap.

The 10k pipeline case is the reverse situation: all three do exactly one write
and one bulk read, so all three sit at 0.5 µs/op and the numbers are within 4 %
of each other — the server is the bottleneck.

## Profiling

Not required (no target was missed), but the raw-socket comparison above was
run precisely to bound the client's own overhead, and it is the same evidence a
profile would give: **0.8 µs of client per command**. The two suspects called
out in the brief were checked by reading:

* per-call `Array(RESP::Arg)` in `def_command`
  (`src/redis/commands.cr:46-47`) — one heap array per command. Real, but it is
  part of that 0.8 µs and the 64-fiber case already beats redis-rs by 1.6×.
* `Channel` per waiter — already mitigated: `Client#take_waiter`
  (`src/redis/client.cr:221`) pops from a `@waiter_pool` `Deque` and pushes the
  waiter back after the reply, so a steady-state command reuses its
  `Channel(Value)` instead of allocating one.

## Follow-up proposals (not done, no evidence of need)

1. `def_command` could build a stack `Tuple` (or a small fixed-capacity
   inline buffer) instead of `Array(::Redis::RESP::Arg).new(n)` for the common
   ≤4-argument case. `call(args : Indexable)` already accepts a `Tuple`, so this
   is a macro-only change. Expected win is a fraction of the 0.8 µs — measure
   before doing it.
2. The codec's `%N` map path (62.5 ns/pair) is the slowest per-element reply
   shape. The `Hash` is already presized from `N` (`src/redis/resp.cr:242`,
   `initial_capacity: hint`), so what is left is the two nested `read` calls per
   pair plus hashing a `Value`-union key. A specialized string-key path is the
   only obvious lever and is not worth it without a workload that shows it.
3. The codec benchmark should discard its first measured row or warm up per row;
   the run-1/run-2 spread on `int` is entirely cold start.

## Variants tried and rejected

* **`redis-benchmark` as the sequential baseline** — rejected: it has no
  `--dbnum`, so it would have written into db 0. Replaced with `bench_raw.cr`,
  which is a better baseline anyway (same language, same codec, `SELECT 14`,
  isolates exactly the client machinery).
* **Recording codec run 1** — rejected as cold-start noise after run 3
  reproduced run 2 to 0.1 ns.
* **`out` as a variable name in `bench_codec.cr`** — `out` is a Crystal keyword
  (out-parameter); it fails to compile with "expecting variable or instance
  variable after out". Renamed to `buf`.

## Files / commands

```
bin/crystal build --release .remember/harness-2026-09-19/redis/bench_codec.cr -o .build/bench_codec
bin/crystal build --release .remember/harness-2026-09-19/redis/bench_live.cr  -o .build/bench_live
bin/crystal build --release .remember/harness-2026-09-19/redis/bench_raw.cr   -o .build/bench_raw
.build/bench_codec
redis-cli -n 14 flushdb && .build/bench_live
.build/bench_raw

cd rs && cargo build --release && ./target/release/bench redis://127.0.0.1:6379/14
cd go && go mod init bench && go get github.com/redis/go-redis/v9 && go build -o bench . && ./bench
```

---

# Slice 2 — 2026-09-20

Pub/sub, `MULTI`/`EXEC` and scripting, same three clients, same box, same
server. Everything in this section is gitignored too.

## Environment

| | |
|---|---|
| Machine | Apple M1, 8 cores, macOS 27.0 |
| Server | Valkey 9.1.2 (`redis_version` 7.2.4), local, db 14 |
| Crystal | 1.22.0-dev, branch `redis-slice2` @ `449e9ab43`, compiler `[ab99c0e02]`, LLVM 23.1.1, `--release` |
| Rust | cargo 1.98.1, `redis` 0.27.6 (`tokio-comp`) + `tokio` 1 + `futures-util` 0.3.32, `--release`, `lto = true` |
| Go | go1.27.1 darwin/arm64, `github.com/redis/go-redis/v9` v9.22.0, RESP3 |

Each program was run twice back to back against the same live server; the
**second** run is what is recorded below. Every harness `FLUSHDB`s db 14 on
startup.

## Results

| case | Crystal | redis-rs | go-redis |
|---|---:|---:|---:|
| pub/sub round trip, median | **77.2 µs** | 99.3 µs | 94.1 µs |
| pub/sub round trip, p99 | **93.5 µs** | 114.7 µs | 107.2 µs |
| subscriber throughput, 64 ch × 1 M | 1 088 021 ops/s (0.92 µs) | 1 101 052 ops/s (0.91 µs) | **1 196 626 ops/s** (0.84 µs) |
| pipeline 10 INCR | **11 797 ops/s** (84.76 µs) | 10 348 ops/s (96.6 µs) | 10 647 ops/s (93.9 µs) |
| multi 10 INCR | **11 543 ops/s** (86.63 µs) | 9 962 ops/s (100.4 µs) | 10 592 ops/s (94.4 µs) |
| evalsha by hand | **12 501 ops/s** (79.99 µs) | 10 840 ops/s (92.3 µs) | 11 258 ops/s (88.8 µs) |
| run(script) | **12 469 ops/s** (80.20 µs) | 10 728 ops/s (93.2 µs) | 11 235 ops/s (89.0 µs) |

Ratios (Crystal ÷ other, on µs/op; >1 means Crystal is faster):

| case | vs redis-rs | vs go-redis |
|---|---:|---:|
| pub/sub round trip (median) | 1.29× | 1.22× |
| pub/sub round trip (p99) | 1.23× | 1.15× |
| subscriber throughput | 0.99× | 0.91× |
| pipeline 10 INCR | 1.14× | 1.11× |
| multi 10 INCR | 1.16× | 1.09× |
| evalsha by hand | 1.15× | 1.11× |
| run(script) | 1.16× | 1.11× |

Within-client overheads, which is what the spec's targets are actually about:

| | multi ÷ pipeline | run(script) ÷ evalsha |
|---|---:|---:|
| Crystal | **+2.2 %** | **+0.3 %** |
| redis-rs | +3.9 % (run 1: −3.7 %) | +1.0 % |
| go-redis | +0.5 % | +0.2 % |

redis-rs's `multi` column swung from 3.7 % *faster* than its own pipeline in
run 1 to 3.9 % slower in run 2, so treat ±4 % here as the noise band for a
case whose absolute cost is one ~90 µs loopback round trip.

## Targets (from the spec)

* **`multi`'s client overhead within a few percent of the plain pipeline** —
  **met**: 86.63 µs vs 84.76 µs, **+2.2 %**. Broken down below, only
  **+1.4 %** of that is the client; the rest is the two extra commands on the
  wire and the server's own transaction handling.
* **`run` no slower than a direct `EVALSHA`** — **met**: 80.20 µs vs
  79.99 µs, **+0.3 %**, inside the noise band (run 1 had `run` 0.2 % *faster*
  than hand-written `EVALSHA`). `Script#sha` is computed locally at
  construction and `run` sends `EVALSHA` directly, so the only difference
  from the hand-written call is a `ScriptCache` lookup.

Both targets are met, so `src/redis/` was not touched.

## Where `multi`'s 2.2 % goes

The brief named two suspects (the two extra futures per transaction and
`tx.buffer.to_slice` being copied twice) and said to measure before changing
anything. `bench_multi_overhead.cr` splits the difference four ways by adding
back one variable at a time; each row is 10 000 iterations, after a 1 000-round
warm-up (second run recorded):

| | µs/op | delta |
|---|---:|---:|
| `pipelined` 10 INCR (10 commands) | 84.25 | — |
| `pipelined` 12 INCR (12 commands) | 84.71 | +0.46 µs — two more commands on the wire |
| `pipelined` with raw `call("MULTI")` + 10 × `call("INCR")` + `call("EXEC")` | 85.54 | +0.83 µs — the server queuing 10 commands and running them at `EXEC` |
| `multi { 10 × tx.incr }` | 86.76 | +1.22 µs — the client's transaction machinery |

So of the 2.51 µs that separates `multi` from a 10-command pipeline,
**1.22 µs (1.4 % of a transaction) is Crystal code** — the `Transaction`
object, the ten typed futures, the two extra futures for `MULTI` and `EXEC`,
and the `EXEC`-array demux. The third row is the honest control: it puts the
*identical bytes* on the wire as `multi` with none of the client's transaction
objects, and it is already 1.29 µs above the plain pipeline.

1.22 µs per transaction is 0.12 µs per queued command, i.e. the same order as
the 0.8 µs whole-command overhead measured in slice 1. No profile was taken
beyond this decomposition, because it already bounds the suspect code to a
number well inside the target and no change was warranted.

## Why Crystal wins the round-trip cases and not the throughput one

The four sequential cases (pub/sub round trip, pipeline, multi, evalsha, run)
are all one loopback round trip per iteration, and they land exactly where
slice 1's raw-socket measurement predicts: the floor on this box is 74.6 µs,
Crystal sits 2–12 µs above it, redis-rs and go-redis 14–26 µs above it. The
pub/sub round trip is the clearest: at a 77.2 µs median it is 2.6 µs over the
bare-socket floor even though it is a `PUBLISH` reply *and* a server push
arriving on a second connection — the push lands essentially concurrently
with the reply.

The subscriber-throughput row is the one case where Crystal is not ahead, and
the threading models are genuinely different, so the comparison is not
apples-to-apples:

* **Crystal** — the subscriber owns a reader fiber that decodes frames into a
  bounded `Channel(Message)` (capacity 64), and the benchmark's consumer fiber
  drains it. Publisher, reader and consumer are three fibers on **one OS
  thread** (default runtime; no `-Dpreview_mt`), so every message costs two
  fiber switches and none of the work overlaps.
* **redis-rs** — the receiving task polls `on_message()` on a tokio worker
  thread while the publisher runs on another; decode and publish overlap on
  two cores.
* **go-redis** — same, on two goroutines scheduled onto two Ps.

Crystal still matches redis-rs to within 1 % and is 9 % behind go-redis on one
core against their two, and all three are within 10 % of each other because the
real limit is the server's fan-out of 1 M publishes.

## Variants tried and rejected

* **go-redis `pubsub.Channel()` instead of `ReceiveMessage`** for the
  throughput case (added behind a `chan` argument, since `Channel()`'s
  buffered goroutine is structurally the closer analogue of Crystal's reader
  fiber → bounded channel → consumer fiber). Measured 1 181 469 ops/s vs
  1 196 626 with `ReceiveMessage` — 1.3 % apart, i.e. the same. The receive API
  is not what bounds this case, so the `ReceiveMessage` number is the one
  recorded.
* **`futures-util = "0.3"` unpinned in Cargo.toml** — cargo resolved 0.3.34,
  whose `futures-macro = "=0.3.34"` is not in this machine's crates.io index
  (`candidate versions found which didn't match: 0.3.33, 0.3.32, …`). Pinned to
  `=0.3.32`, which is in the local registry cache.
* **One shared `aio::PubSub` across the Rust cases** — does not compile:
  `on_message()` takes `&mut self` and the returned `Stream` borrows the
  `PubSub` for its whole lifetime, so it cannot be subscribed to more channels
  while a stream is alive, nor moved into a `tokio::spawn`. Case 1 scopes its
  stream and case 2 opens a second `PubSub` that is moved into the receiving
  task.
* **Timing the publish side only in case 2** — rejected; the timer brackets the
  publishes *and* the `done` rendezvous in all three harnesses, so the number is
  end-to-end delivery, not just how fast a client can write `PUBLISH`.

## Files / commands

```
bin/crystal build --release .remember/harness-2026-09-19/redis/bench_slice2.cr          -o .build/bench_slice2
bin/crystal build --release .remember/harness-2026-09-19/redis/bench_multi_overhead.cr  -o .build/bench_multi_overhead
.build/bench_slice2            # run twice, keep the second
.build/bench_multi_overhead    # run twice, keep the second

cd rs && cargo build --release && ./target/release/bench redis://127.0.0.1:6379/14 slice2
cd go && go build -o bench . && ./bench slice2        # add `chan` for the Channel() variant
```

Without the `slice2` argument both `rs` and `go` still run the slice 1 cases
exactly as before.

---

# Slice 3 — 2026-09-20

Cluster routing (`Redis::Cluster`) and the connection `Redis::Pool`, against a
real three-master Valkey Cluster on one box (no replicas), same three
clients. Everything in this section is gitignored too.

## Environment

| | |
|---|---|
| Machine | Apple M1, 8 cores, macOS 27.0 |
| Cluster | Valkey 9.1.2, 3 masters, `--cluster-enabled yes`, ports 7100/7101/7102, no replicas, slots split 0-5460 / 5461-10922 / 10923-16383, started by `cluster.sh` |
| Crystal | 1.22.0-dev, branch `redis-slice3` @ `9a2932119`, compiler `[ab99c0e02]`, LLVM 23.1.1, `--release` |
| Rust | cargo 1.98.1, `redis` 0.27.6 (`tokio-comp` + `cluster-async`) + `tokio` 1 (full) + `futures-util` 0.3.32, `--release`, `lto = true` |
| Go | go1.27.1 darwin/arm64, `github.com/redis/go-redis/v9` v9.22.0, `ClusterClient` |

Each program was run three times back to back against the same live cluster;
the table below reports the **median** of the three. Every harness
`FLUSHALL`s every master (Crystal) or writes its 300 keys fresh (Rust/Go) on
startup.

## Results

| case | Crystal | redis-rs | go-redis |
|---|---:|---:|---:|
| sequential GET, plain client on owner | 24.32 µs/op (41 122 ops/s) | — | — |
| sequential GET, via cluster routing | 24.32 µs/op (41 120 ops/s) | 42.16 µs/op (23 718 ops/s) | 27.61 µs/op (36 217 ops/s) |
| 64 fibers/tasks/goroutines GET, 3 masters | **915 545 ops/s** (1.09 µs) | 500 284 ops/s | 178 562 ops/s |
| pipelined 300-GET, split by node automatically | **177.48 µs/op** (5 635 ops/s) | — | — |
| 3 × 100-GET pipeline, split by hand, sequential | 259.11 µs/op (3 858 ops/s) | — | — |
| `watch` via pooled connection | 71.65 µs/op (13 956 ops/s) | — | — |
| `watch`, fresh connection per call | 129.05 µs/op (7 749 ops/s) | — | — |
| `Pool#checkout`/`checkin`, idle connection | **45.0 ns** | — | — |

Ratios (Crystal ÷ other, on µs/op or ops/s as noted; >1 means Crystal ahead):

| case | vs redis-rs | vs go-redis |
|---|---:|---:|
| sequential GET via cluster | 1.73× | 1.14× |
| 64-fiber/task/goroutine GET | 1.83× | 5.13× |

## Targets (from the spec §8)

* **Cluster routing overhead ≤ 0.5 µs per sequential GET, versus a plain
  `Client` on the owning node** — **met**. Per-run overhead (cluster − plain)
  was −0.43, +0.50, +0.04 µs across the three runs; the median is **+0.04 µs**,
  and even the noisiest single run (+0.50 µs) is at the target, not over it.
  `Cluster#call` for an already-loaded slot map is one mutex-free array
  lookup (`@slots[slot]`, read under `@mutex.synchronize`) plus the same
  `Client#call` the plain-client path uses, so this is expected: routing adds
  a slot-map read, not a network hop.
* **64-fiber GET across three masters, versus redis-rs `cluster-async` and
  go-redis `ClusterClient`** — **met, well ahead of both**: 915 545 ops/s vs
  500 284 (redis-rs, **1.83×**) and 178 562 (go-redis, **5.13×**). Same shape
  as slice 1's single-node 64-fiber case (1.66× / 3.73× there): Crystal's
  `Cluster` still multiplexes one socket per master and lets 64 fibers turn
  into large automatic pipelines on each of the three sockets; go-redis's
  `ClusterClient` pools per-node connections with no cross-goroutine
  pipelining, so the 3-master case does not close its gap with Crystal the
  way a naive "3× the nodes, 3× the throughput" guess would suggest — if
  anything the go-redis ratio is worse here (5.13× vs 3.73×) because 64
  goroutines are now split three ways across per-node pools instead of
  hitting one.
* **300-GET split pipeline versus three 100-GET pipelines by hand** — **met,
  split is faster**: `cluster.pipelined` (one call, 300 commands, grouped by
  node and sent to all three masters concurrently) is 177.48 µs/op vs
  259.11 µs/op for three sequential `node.client.pipelined` calls done by
  hand — a **1.46× speedup**, entirely explained by concurrency: the built-in
  split runs all three nodes' groups on their own fiber (`Cluster#pipelined`,
  `cluster.cr:333-347`, every group but the last gets `spawn` + a
  `WaitGroup`), while "by hand" in this benchmark iterates `groups.each`
  sequentially — three round trips back to back instead of three round trips
  overlapped. This is comparing the library's actual behavior (automatic
  concurrent split) against the most natural hand-written alternative, which
  is sequential; a hand-rolled *concurrent* 3-pipeline version would likely
  close most of this gap, but that is exactly the code
  `Cluster#pipelined` already is.
* **Pooled `watch` at least 2× faster than a fresh connection per call** —
  **missed, by a modest margin**: median 71.65 µs/op (pool) vs 129.05 µs/op
  (fresh) is a **1.80× speedup** (per-run ratios 1.808×, 1.798×, 1.803× — this
  is a stable result, not noise). Root cause, found by reading
  `Client#watch` (`src/redis/client.cr:311-320`): the pooled path sends
  **three** commands per call — `WATCH`, the block's `GET`, and then
  `UNWATCH` (because the block returns without calling `multi`, so
  `conn.watching?` is true when the `ensure` runs) — while the fresh-connection
  comparison in this benchmark sends only **two** — `WATCH` and `GET` — before
  closing the socket outright. The pooled path is paying for a real extra
  round trip that the fresh-connection path skips by discarding the
  connection instead of cleaning up its `WATCH` state. That is not a bug in
  `Client#watch` (leaking a `WATCH` onto a pooled connection's next borrower
  would be a real correctness problem), but it does mean this specific A/B is
  not apples-to-apples: pooled avoids one TCP handshake per call and pays one
  `UNWATCH`; fresh avoids the `UNWATCH` and pays the handshake. On this box
  the handshake is worth more (1.80× net win for pooling) but not quite 2×.
  No product code was touched (harness-only task); see the follow-up
  proposal below.
* **`Pool#checkout`/`checkin` < 200 ns, idle connection** — **met, with
  large margin**: **45.0 ns**, under a quarter of the target, identical
  across all three runs. `checkout` on a warm pool is a `Channel(Nil)`
  receive (buffered, uncontended) + a mutex-protected `Deque#shift?`;
  `checkin` is the mirror. No fresh connection, no syscall.

## Fixing the brief's benchmark: `watch`'s key does not live on `seeds[0]`

The brief's `bench_slice3.cr` step 4 opens `Redis::Client.new(seeds[0])` (node
7100) and calls `client.watch("k0") { ... }`. `Redis::Cluster.key_slot("k0")`
is **8579**, which is owned by node **7101** (slot range 5461-10922), not
7100 (0-5460, seed 0). Running the brief's code as written raises
`Redis::CommandError: MOVED 8579 127.0.0.1:7101` from `Connection#call`,
because a plain `Client`/`Connection` (unlike `Cluster`) does not follow
redirects — that is `Cluster`'s job, and case 4 is deliberately testing the
non-cluster pooled-connection and fresh-connection paths on their own.
Fixed by routing to the actual owner: `owner_url =
"redis://#{cluster.node_for("k0").address}"`, then using `owner_url` in place
of `seeds[0]` for the `Client`, `Connection`, and `Pool` constructions in that
section. This is a benchmark-harness fix, not a product change.

## Variants tried and rejected

* **Reporting the routing-overhead target from a single run** — rejected;
  run 1 alone showed cluster routing 0.43 µs *faster* than the plain client
  (noise: the "plain client" and "cluster" cases both hit the same server
  round-trip floor from slice 1, ~24 µs here since Valkey Cluster's own
  per-command cost is slightly different from the standalone server, and the
  ±0.4 µs spread between runs is bigger than the ~0.04 µs true median
  overhead). Recorded the median of three runs and the per-run spread
  instead, per the benchmark-discipline instructions.
* **`redis-rs`/`go-redis` baselines for the pipeline-split, `watch`-pool and
  `Pool#checkout` cases** — not attempted. The brief's Rust/Go `slice3` code
  (Step 3) only covers sequential GET and the 64-task/goroutine case; those
  are the only two targets that ask for a cross-client comparison (spec §8).
  The pipeline-split, `watch`, and `checkout`/`checkin` targets are
  Crystal-internal (this client's pooled `watch` vs its own fresh connection,
  this client's automatic split vs its own hand-written split, this client's
  pool overhead in absolute ns) — redis-rs's `cluster-async` has no
  `WATCH`-on-a-dedicated-connection API comparable to `Redis::Pool`, and
  go-redis's cluster `Pipeline()` already auto-splits by node the same way
  `Cluster#pipelined` does, so a "by hand" baseline in those clients is not
  what the spec is asking about.
* **A concurrent hand-written 3-pipeline variant** (to isolate whether
  `cluster.pipelined`'s 1.46× win over the sequential-by-hand baseline is
  "automatic splitting" or just "runs the 3 groups concurrently") — not
  built; flagged as a follow-up below instead of expanding scope in a
  harness-only task.

## Follow-up proposals (not done, no product code touched)

1. If a *stricter* 2× pooled-`watch` target matters later, the honest lever
   is not `Client#watch` (its `UNWATCH` is correct behavior, not overhead to
   cut) but the benchmark's fresh-connection baseline: have it call
   `conn.unwatch` before `conn.close` too, which would make both paths send
   three commands and isolate the comparison to "pooled socket reuse vs a
   fresh TCP handshake" — the number this target actually seems aimed at.
   That is a benchmark change, not a product change, and was not made here
   because it changes what the brief's own code measures.
2. A concurrent (fiber-per-group) hand-written 3-pipeline baseline, to
   separate "automatic node-grouping" from "concurrent sends" as the source
   of `cluster.pipelined`'s 1.46× edge over the sequential-by-hand version
   recorded above.

## Files / commands

```
.remember/harness-2026-09-19/redis/cluster.sh start
bin/crystal build --release .remember/harness-2026-09-19/redis/bench_slice3.cr -o .build/bench_slice3
.build/bench_slice3            # run 3×, keep the median per row

cd rs && cargo build --release && ./target/release/bench redis://127.0.0.1:7100 slice3   # run 3×
cd go && go build -o bench . && ./bench slice3                                            # run 3×

.remember/harness-2026-09-19/redis/cluster.sh stop
```
