# Batteries-Included Stdlib Roadmap

Brainstormed 2026-09-17. Direction decisions made in that session:

- Goal: a stdlib that covers what most apps need, so a Crystal app depends on nothing else. "A simple Rust app pulls hundreds of dependencies."
- Upstream acceptance is the last priority. Everything lands on the fork; no RFC-shaped compromises.
- RPC over HTTP is off the table (no HTTP/2, gRPC, JSON-RPC). Native RPC = binary transport over TCP / Unix sockets, QUIC possible later.
- Wire format: middle path. A custom Crystal-native format with a published spec so other languages *could* implement it. The spec itself is deferred; layers below it are format-agnostic and start first.
- Perf discipline from the 2026-06..09 work carries over: baseline-vs-candidate benchmarks against Rust/Go equivalents, differential tests, specs, `make format`.

Open question left for next session: start with the binary foundation (recommended) or containers, and whether the macro struct layout is in the first slice or only the primitives.

Existing anchors in the tree: `IO#read_bytes` / `IO#write_bytes` + `IO::ByteFormat` (src/io.cr:1049, src/io/byte_format.cr), `JSON::Serializable` pattern (src/json/serialization.cr:157, `annotation Field` at :2), `Channel` select actions (src/channel.cr:322), `Socket::Server`, `OpenSSL::SSL::Socket`, `BitArray`, `Deque`, `Big*` over GMP.

---

## Tier 1 — Binary foundation (`src/binary/`)

Format-agnostic primitives every later layer needs. No dependency on the deferred wire spec.

### 1a. Varints
- `IO#read_varint(T)` / `IO#write_varint(x)` for unsigned LEB128; `read_zigzag` / `write_zigzag` for signed. Also on `Slice(UInt8)` returning `{value, bytes_consumed}` and on `IO::Memory` fast paths.
- Bound loops at 10 bytes for 64-bit; raise on overflow / truncation. Reject non-canonical encodings only under an opt-in strict flag (protobuf accepts them).
- Bench: encode/decode 1M mixed-width ints vs Go `binary.PutUvarint` / Rust `integer-encoding`. Target: within 10% of Rust.
- Effort: small. One file, ~30 specs.

### 1b. Bit-level IO
- `Binary::BitReader(IO or Slice)` / `BitWriter` with `read_bits(n) : UInt64`, `write_bits(x, n)`, `align!`, MSB-first and LSB-first modes (deflate is LSB, most codecs MSB).
- Keeps a 64-bit accumulator; refill 8 bytes at a time when the source is a Slice.
- Users: compression codecs, bitfield structs in 1d, Golomb/Elias codes in probabilistic containers.
- Effort: small-medium.

### 1c. Framing
- `Binary::Frame` module: length-prefixed frames over any `IO`. Prefix kinds: `UInt32` big/little, varint. Max-frame guard (default 16 MiB, raises `Binary::FrameTooLarge`).
- `read_frame : Bytes` (allocates exact), `read_frame(into : IO::Memory)`, `write_frame(bytes)` and a `write_frame { |io| ... }` builder that presizes via a scratch `IO::Memory` and writes length + body in one `writev`-shaped call (two writes today; `writev` was rejected earlier as needing five event-loop backends, so keep two writes and rely on buffered socket).
- Optional frame header struct via 1d: `{type : UInt8, flags : UInt8, stream_id : UInt32, length : UInt32}`. This is the RPC transport header.
- Effort: small.

### 1d. Declarative struct layout (`Binary::Format`)
The design-heavy item. A macro module in the shape of `JSON::Serializable`:

```crystal
struct PgStartup
  include Binary::Format
  endian :big
  field length : UInt32
  field version : UInt32 = 196608
  field params : Array({String, String}), terminator: 0_u8, cstring: true
end
```

Design points:
- `field name : Type, **opts` with opts: `endian`, `varint: true`, `length: :field_name | Int | proc`, `cstring: true`, `pad: n`, `if: ->{ cond }`, `bits: n` (packs consecutive `bits:` fields via 1b), `default`, `const` (asserted on read, e.g. magic numbers).
- Fixed-layout structs (all primitive fields, no lengths) get `sizeof`-computed `SIZE` and a zero-copy `from_slice(Bytes)` that reads fields by pointer offset with byte-swap only when endian differs from host. This is the seed of the later zero-copy RPC.
- Generated: `self.read(io)`, `#write(io)`, `self.from_slice`, `#to_slice`, `#byte_size`, `#inspect`.
- Nested formats, `Array(T)` with count-prefix or terminator, `Bytes` with length field, `StaticArray` inline.
- Precedent to read before designing: Ruby `bindata`, Python `construct`, Rust `binrw`, Kaitai Struct. Take `binrw`'s attribute set as the feature ceiling and cut.
- Risk: macro complexity and compile-time cost. Mitigate by generating straight-line code per field, no runtime reflection.
- Spec approach: round-trip property tests over random instances plus known-answer byte dumps for PNG header, ELF header, Postgres startup message.
- Effort: medium-large. This is a full brainstorming + spec cycle on its own.

---

## Tier 2 — Serializer (`Binary::Serializable`, name TBD)

The generic `to_binary` / `from_binary` codec for arbitrary Crystal types, paired with the wire spec. Deferred per the decision above, but the shape to aim for:

- Same macro entry as JSON: `include Binary::Serializable`, `@[Binary::Field(...)]`.
- Schema is the Crystal type graph. Field IDs are positional by default with an explicit `id:` override for evolution; unknown IDs are skipped, missing IDs get defaults. This is what makes the format versionable without an IDL.
- Two encodings behind one API: compact (varints, no names) for the wire, and a self-describing variant (with a schema hash prefix) for storage and debugging.
- Publish the spec as `docs/binary-format.md` when written. Until then MessagePack could be a *secondary* codec with the same API for interop debugging only.

---

## Tier 3 — Database and cache clients (real-world validation of Tier 1)

### 3a. Postgres (`src/pg/`)
- Pure-Crystal wire protocol v3 over `TCPSocket` / `UNIXSocket` with `OpenSSL::SSL::Socket` upgrade. Messages defined with `Binary::Format` (1d) — the protocol is the acceptance test for 1d.
- Startup, SCRAM-SHA-256 and MD5 auth (SCRAM needs HMAC + PBKDF2, both in `OpenSSL`), simple and extended query, prepared statements with statement cache, portals, binary result format by default, `COPY FROM STDIN` / `COPY TO STDOUT` streaming, LISTEN/NOTIFY, pipelining (send N Parse/Bind/Execute before Sync).
- Type mapping: Int16/32/64, Float32/64, Bool, String, Bytes, UUID, Time (timestamptz), Time::Span (interval), JSON/JSONB, arrays of the above, Numeric → BigDecimal.
- Typed rows: `conn.query_all("select ...", as: {Int32, String})` returning tuples, and `as: MyStruct` via a `PG::Serializable` macro sharing the annotation style.
- Pool: fiber-safe connection pool with health check, max size, checkout timeout. Lives in `src/pg/pool.cr` but designed reusable (`Pool(T)` generic in `src/pool.cr`).
- Bench vs Rust `tokio-postgres` and Go `pgx`: simple select 1 latency, 10k-row binary fetch, COPY 1M rows.
- Effort: large. Split into: protocol messages → auth → simple query → extended query → types → COPY → pool.

### 3b. Redis (`src/redis/`)
- RESP3 with RESP2 fallback (HELLO negotiation). Pipelining by default (commands queue, flush on `sync`/block), pub/sub as a `Channel`, transactions, Lua `EVALSHA` cache, cluster slot routing as a stretch goal.
- Command surface: typed methods for the common 80 commands generated from a table by macro; `command(*args)` escape hatch returning a RESP3 value union.
- Small compared to Postgres; good second protocol to shake out framing and `IO` buffering.

### 3c. SQLite (`src/sqlite/`) — optional
- Needs the C library, so it breaks the pure-Crystal line. Include only as `require "sqlite"` behind a link flag, mirroring how `Big` needs GMP. Common enough in CLI tools to justify.

---

## Tier 4 — Native RPC (`src/rpc/`)

- Interface module in, client and server out:

```crystal
module BoardService
  include RPC::Service
  abstract def list(board_id : Int64) : Array(Task)
  abstract def move(task_id : Int64, to : Int32) : Task
end
server = RPC::Server.new(BoardServiceImpl.new); server.bind_tcp("0.0.0.0", 9000); server.listen
client = BoardService.client("10.0.0.5", 9000); client.list(42)
```

- Macro reads the abstract defs, assigns method IDs (hash of name + arity, override with annotation), generates dispatch table and client stubs. Type inference has the signatures; no IDL.
- Transport: Tier 1c frames with `{type, flags, stream_id, length}` header. Multiplexed streams over one connection so a client is a single socket with N in-flight calls, fiber-per-request on the server.
- Message kinds: request, response, error, cancel, ping, stream-chunk (for `Iterator(T)` return types → server streaming), and later client streaming when a param is `Iterator(T)`.
- Errors: typed `RPC::Error` with code + message + optional serialized payload; app exceptions annotated `@[RPC::Transportable]` round-trip.
- Deadlines and cancellation propagated in the header; server fiber checks `RPC.current.cancelled?`.
- TLS via `OpenSSL::SSL::Socket`, Unix sockets for same-host, optional zero-copy for fixed-layout params via 1d `from_slice`.
- Later: service discovery hooks, load-balanced client over N addresses, QUIC when a pure-Crystal QUIC exists (not soon).
- Bench: round-trip latency and throughput vs gRPC (Rust `tonic`) and Cap'n Proto RPC on loopback + Unix socket.
- Effort: large, but Tier 1c + Tier 2 do most of the work. The RPC layer itself is dispatch, streams, and lifecycle.

---

## Tier 5 — Containers

Each is a self-contained session: implement, spec, bench vs Rust `std::collections`.

- **Heap(T) / PriorityQueue**: binary heap over Array with `push`, `pop`, `peek`, `replace_top`, `push_pop`, `heapify` from Enumerable, min/max via comparator block. Consider 4-ary layout (fewer levels, cache-friendlier) and benchmark both. Rust `BinaryHeap` is the target.
- **SortedMap(K,V) / SortedSet(T)**: B-tree, node fanout ~11 like Rust `BTreeMap` (tune by sizeof(K)+sizeof(V)). Ops: `[]`, `first`/`last`, `floor`/`ceiling`/`lower`/`higher`, `range(a..b)` iterator, `delete`, `min_by`-style extraction, bulk build from sorted input. This is the biggest gap vs Java/Rust/C++.
- **LRUCache(K,V)**: Hash + intrusive doubly-linked list on indices (no per-entry allocation), capacity by count with optional `cost` proc, `fetch(key) { compute }`, hit/miss counters. Fiber-safe variant behind a Mutex flag. Consider S3-FIFO or W-TinyLFU as a second policy if benchmarks warrant.
- **Trie / RadixTree(V)**: byte-keyed compressed radix tree with `longest_prefix`, `each_prefix`, `insert`, `delete`. Users: routers, autocomplete, IP tables.
- **Probabilistic**: `BloomFilter` (k hashes via double hashing from one 64-bit hash), `HyperLogLog` (14-bit precision default, merge), `CountMinSketch`. Sit beside `BitArray`.
- **DisjointSet**: union-by-rank + path halving over an Int32 array. Tiny.
- **Persistent Vector / Map** (HAMT): defer until execution contexts stabilize; the value is in concurrent sharing.
- Skip: LinkedList (Deque covers it), Rope (String immutable, Builder covers it).

---

## Tier 6 — App glue

- **TOML**: `TOML.parse` → `TOML::Any`, `TOML::Serializable`, `to_toml`. Full v1.0.0 including tables, arrays of tables, datetimes → `Time`. Port the toml-test suite for conformance.
- **CLI subcommands**: `Command` tree on top of `OptionParser`: nested subcommands, typed flags with defaults, positional args, auto help, `--version`, shell completion generation (bash/zsh/fish). Reference: Go cobra, Rust clap derive. Keep `OptionParser` untouched for compatibility.
- **High-level crypto** (`src/crypto/`): `Crypto::AEAD` (ChaCha20-Poly1305, AES-256-GCM) with `seal`/`open` and nonce handling; `Crypto::Ed25519` sign/verify, `Crypto::X25519` key exchange; `Crypto::Argon2id` (pure Crystal or via OpenSSL 3.2+); `Crypto::HKDF`. All over `LibCrypto`; the value is the safe API, not new primitives. Constant-time compare exists in `Crypto::Subtle`.
- **Statistics** (`src/statistics.cr` or on Enumerable): mean, variance (Welford), stddev, median (reuse quickselect from the min/max work), quantiles, mode, histogram buckets, covariance, Pearson, simple linear regression. Return Float64; generic over Number input.
- **Diff**: Myers diff over `Indexable`, unified-diff formatter for Strings. Helps `spec` failure output and tooling.
- **Text**: word wrap, table formatting, fuzzy match score (Levenshtein exists).
- **Structured concurrency**: `Fiber::Pool` / task group with `spawn_in` + `wait` + first-error cancellation, `Channel.select` with timeout. Coordinate with the execution contexts work.
- **Metrics/tracing hooks in Log**: counters, gauges, histograms, span context; exporter interface only (no OTLP client, that would be HTTP).

---

## Tier 7 — Numerics

- **Matrix(T) / Vector(T)**: dynamic shape with row-major `Slice(T)` storage plus macro-generated fixed `Matrix(T, R, C)` for 2x2/3x3/4x4 with unrolled multiply. Ops: `*`, `+`, transpose, determinant, inverse, LU / QR / Cholesky, `solve`, eigen for symmetric (Jacobi). Generic over Float32/Float64/Complex/BigRational.
- **BLAS/LAPACK bridge** behind `-Dblas`: Accelerate on macOS, OpenBLAS on Linux. Pure Crystal is the default.
- **SIMD(T, N)**: struct over LLVM vector types with lane ops, shuffles, reductions, masks; `Slice#each_simd(N)`. Compiler work: new primitive type mapping in `llvm_typer.cr` + `primitives.cr`. Pays back across `String`, `Slice`, `JSON`, `Base64` where SWAR is hand-written today. Do this before Matrix so Matrix can use it.
- **Fixed-point Decimal**: Int128 mantissa + Int8 scale, no GMP, no allocation; for money. Interop with `BigDecimal`.
- **Int256 / Float16 / BFloat16**: cheap via LLVM.

---

## Suggested sequencing

1. Tier 1a + 1c (varints, framing) — one session.
2. Tier 5 Heap — one session, quick win while 1d is designed.
3. Tier 1d design (own brainstorm + spec) → implement. Tier 1b bit IO lands as part of it.
4. Tier 3b Redis (small, shakes out framing) → Tier 3a Postgres (large).
5. Tier 5 SortedMap, LRU.
6. Tier 2 wire spec + serializer.
7. Tier 4 RPC.
8. Tier 6 items as fillers between large pieces (TOML and CLI subcommands first).
9. Tier 7 SIMD → Matrix.

Each tier: bench vs the Rust/Go equivalent, differential/known-answer specs, `make format`, self-contained `require` under `src/` (never prelude).
