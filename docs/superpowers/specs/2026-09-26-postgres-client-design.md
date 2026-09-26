# `Postgres` client design (Tier 3a, slice 1)

Date: 2026-09-26. Status: approved in brainstorm (Q&A in the 2026-09-26
session), ready for planning.

## Goal

A pure-Crystal PostgreSQL client in the stdlib (`require "postgres"`),
speaking frontend/backend protocol 3.0 over TCP, Unix sockets, or TLS. A
`Postgres::Client` is a fiber-safe handle backed by a pool of connections;
queries use the extended protocol with binary parameters and results and an
automatic per-connection prepared-statement cache. Rows map onto structs
with `include Postgres::Serializable`.

It is the third real-world consumer of the binary foundation: control
messages are `Binary::Format` layouts, and the connection reuses the
patterns Redis proved (lazy connect, closing on any I/O or protocol failure,
a pool that drops closed connections).

Decisions taken in the brainstorm and not to be reopened:

- Namespace `Postgres`, `require "postgres"` (not `PG`: the crystal-pg shard
  owns that name).
- Slice 1 = core query path **plus** the statement cache and the pool:
  startup, auth (trust, cleartext, MD5, SCRAM-SHA-256), TLS, simple and
  extended query, binary types, struct mapping, statement LRU, pool,
  transactions. Slice 2 and later: arrays, COPY, LISTEN/NOTIFY, pipelining
  N queries before one Sync, query cancellation, SCRAM channel binding.
- Top level is `Client` (pooled, fiber-safe) + `Connection` (one session,
  not fiber-safe), mirroring `Redis::Client` / `Redis::Connection`.
- The pool is a generic `::Pool(T)` in `src/pool.cr` (`require "pool"`),
  not a Postgres-specific class. `Redis::Pool` moves onto it later without
  an API change (not in this slice).
- Statement cache is automatic: every query is prepared by SQL text and
  kept in a per-connection LRU of 256; `statement_cache: false` (client or
  per call) turns it off for transaction-pooling proxies.
- Row mapping in slice 1 is `Postgres::Serializable` structs. A plain
  scalar type (`as: Int64`) is also accepted for single-column results
  (`select count(*)`), because a one-field struct for that would be silly.
  No dynamic `Value` rows and no tuple mapping in slice 1.
- `NUMERIC` decodes to `BigDecimal`, so `require "postgres"` requires `big`
  and links GMP.
- `INTERVAL` decodes to `Postgres::Interval` (months, days, microseconds);
  a `Time::Span` target also works when months is zero.
- Arrays are deferred to slice 2; until then an array column can be read
  as `String` (its text form).
- `sslmode` defaults to `prefer`, as in libpq. Modes: `disable`, `prefer`,
  `require`, `verify-ca`, `verify-full`.
- The standard `PG*` environment variables are fallbacks: URL, then
  keyword arguments, then `PGHOST`/`PGPORT`/`PGUSER`/`PGPASSWORD`/
  `PGDATABASE`/`PGSSLMODE`/`PGAPPNAME`, then defaults.
- Live-server specs are part of the suite and pend when no server answers.

## 1. Public surface

```crystal
require "postgres"

db = Postgres::Client.new("postgres://app:secret@localhost/app_dev")

struct User
  include Postgres::Serializable
  getter id : Int64
  getter name : String
  @[Postgres::Field(key: "email_address")]
  getter email : String?
end

db.exec("create table if not exists users (id bigserial primary key, name text not null, email_address text)")
db.exec("insert into users (name, email_address) values ($1, $2)", "ana", nil) # => Postgres::ExecResult(rows_affected: 1)

db.query_all("select * from users where id > $1", 0, as: User)   # => Array(User)
db.query_one("select * from users where id = $1", 1, as: User)   # => User (raises NoRowsError)
db.query_one?("select * from users where id = $1", 9, as: User)  # => User?
db.query_one("select count(*) from users", as: Int64)            # => 1_i64
db.query_each("select * from users", as: User) { |user| p user } # streams, one connection held

db.transaction do |tx| # tx : Postgres::Connection, BEGIN/COMMIT, ROLLBACK on raise
  tx.exec("update users set name = $1 where id = $2", "ana b", 1)
  tx.transaction { |sp| sp.exec("...") } # nested → SAVEPOINT
end

db.with_connection { |conn| conn.exec("set statement_timeout = 1000") }
db.close

conn = Postgres::Connection.new("postgres:///app_dev?host=/var/run/postgresql")
conn.query_one("select 1", as: Int32) # same query API on a single session
conn.close
```

### 1.1 Files

```
src/pool.cr                          # generic Pool(T)
src/postgres.cr                      # module doc, requires
src/postgres/error.cr                # error hierarchy
src/postgres/config.cr               # URL + env + keyword parsing → Config
src/postgres/oid.cr                  # OID constants
src/postgres/messages.cr             # Binary::Format frontend/backend layouts
src/postgres/wire.cr                 # buffered message reader/writer, hand-written Bind/DataRow paths
src/postgres/auth.cr                 # cleartext, MD5, SCRAM-SHA-256
src/postgres/interval.cr             # Postgres::Interval
src/postgres/codec.cr                # param encoders, column decoders
src/postgres/statement_cache.cr      # LRU of PreparedStatement
src/postgres/result.cr               # Field, RowDescription, ExecResult, RowReader
src/postgres/serializable.cr         # Postgres::Serializable, Postgres::Field
src/postgres/connection.cr           # one session: startup, query methods, transactions
src/postgres/client.cr               # pooled front end
spec/std/pool_spec.cr
spec/std/postgres/*_spec.cr
spec/support/postgres.cr             # pending_postgres gate, FakeServer, URLs
```

Not in the prelude. `require "postgres"` pulls `socket`, `openssl`, `uri`,
`big`, `uuid`, `json`, `digest/md5`, `binary`, `pool`.

## 2. Generic pool (`src/pool.cr`)

```crystal
pool = Pool(Conn).new(size: 8, checkout_timeout: 5.seconds) { Conn.new(url) }
pool.checkout { |conn| conn.query(...) }
conn = pool.checkout; pool.checkin(conn)
pool.idle; pool.in_use; pool.close; pool.closed?
```

- `T` must respond to `close` and `closed?`; the factory block opens one.
- Same permit discipline as `Redis::Pool` (a `Channel(Nil)` of `size`
  permits, idle `Deque(T)`, lazy opening, a closed connection on checkin or
  found idle is dropped, block raise keeps the connection), which the slice
  3 final review verified path by path.
- Health check: optional `health_check : Proc(T, Bool)` run on an idle
  connection that sat idle at least `health_check_after` (default 1 s)
  before handing it out; `false` or an exception closes it and the next
  idle one (or a fresh one) is tried. Postgres passes an empty-query round
  trip. Default nil (no check).
- `Pool::TimeoutError < Exception` after `checkout_timeout`; `Pool::ClosedError`
  when the pool is closed. Factory exceptions propagate unchanged.

## 3. Configuration (`src/postgres/config.cr`)

`Config` is a plain struct built once from, in priority order: the URL,
keyword arguments of `Client.new`/`Connection.new` (which override the
URL), the environment, the defaults.

- URL forms: `postgres://` and `postgresql://`, `user:password@host:port/db`,
  percent-decoded. Query keys: `sslmode`, `application_name`,
  `connect_timeout` (seconds), `host` (a directory → Unix socket
  `<dir>/.s.PGSQL.<port>`), `sslrootcert`, `statement_cache_size`.
  Unknown keys raise `ArgumentError`, as in libpq.
- Defaults: host `localhost` (Unix sockets are used only when asked),
  port 5432, user `$PGUSER || $USER`, database = user, sslmode `prefer`.
- Startup parameters sent: `user`, `database`, `client_encoding=UTF8`, and
  `application_name` when given. No `TimeZone` or `DateStyle`: binary
  timestamps are zone-free and those settings only affect text output.

## 4. Wire (`src/postgres/messages.cr`, `src/postgres/wire.cr`)

- Backend messages are read as `type : UInt8`, `length : Int32` (including
  itself), then the body. Bodies above `max_message_size` (default 1 GiB,
  the server's own limit) raise `ProtocolError` before allocating. The body
  is read into a reusable per-connection buffer that grows to the largest
  message seen; decoders work on slices of it (`DataRow` columns are slices
  into the buffer, decoded straight into the target, no per-column
  allocation for fixed-width types).
- `Binary::Format` layouts for the declarative messages: `StartupMessage`
  body, `SSLRequest`, `Authentication*` subtypes, `BackendKeyData`,
  `ParameterStatus`, `ReadyForQuery`, `ParameterDescription`,
  `RowDescription` fields, `CommandComplete`, `Parse`, `Describe`, `Close`,
  `Execute`. Error/notice field lists are a (code byte, cstring) sequence
  ending with a zero byte, parsed by hand (a sentinel of nested records is
  not something `Binary::Format` expresses).
- Hand-written hot paths: `Bind` (parameter values are encoded straight into
  the outgoing buffer with a back-patched length) and `DataRow` decoding.
  The notes justify this: `Binary::Format`'s DataRow *write* is 2.27× slower
  than Rust, and decode allocates a `Bytes` per column.
- All frontend messages of one round trip are built in one outgoing
  `IO::Memory` and written with a single `write` + `flush`.

## 5. Authentication (`src/postgres/auth.cr`)

- `AuthenticationOk` (0): done. `CleartextPassword` (3): send the password.
  `MD5Password` (5): `"md5" + md5hex(md5hex(password + user) + salt)`.
- `SASL` (10) offering `SCRAM-SHA-256`: RFC 5802/7677 client with a 24-byte
  random nonce (`Random::Secure`), `n,,` GS2 header (no channel binding),
  `PBKDF2-HMAC-SHA256` via `OpenSSL::PKCS5`, `HMAC-SHA256` via
  `OpenSSL::HMAC`; the server signature in `SASLFinal` (12) is verified and
  a mismatch raises `AuthenticationError`. SASLprep is not applied (ASCII
  passwords are unaffected; documented).
- Unsupported methods (GSS, SSPI, SCRAM-SHA-256-PLUS only) raise
  `AuthenticationError` naming the method. A password required but none
  given raises `AuthenticationError` before sending anything.
- Known-answer specs: the RFC 7677 example exchange, and MD5 against a
  value computed by the server (`select md5(...)`).

## 6. Connection (`src/postgres/connection.cr`)

One session, not fiber-safe (the pool gives each fiber its own).

- `Connection.new(url = nil, **options)` connects immediately: TCP (or Unix)
  with `connect_timeout`, `SSLRequest` per sslmode (`S` → wrap in
  `OpenSSL::SSL::Socket::Client` with SNI = host; `N` → plain for `prefer`,
  `ConnectionError` for `require`/`verify-*`), startup, auth, then
  `ParameterStatus`/`BackendKeyData` until `ReadyForQuery`.
- `parameters : Hash(String, String)` (server_version, server_encoding,
  integer_datetimes, …; `integer_datetimes` must be `on` or connect fails),
  `backend_pid`, `transaction_status : Char` (`I`, `T`, `E`),
  `server_version : Int32` (e.g. 160013).
- `read_timeout` bounds each read; `IO::TimeoutError` closes the connection
  and is re-raised (the query may still run server-side; cancellation is
  slice 2). Any `IO::Error`/`OpenSSL::SSL::Error` closes it and raises
  `ConnectionError`; malformed input raises `ProtocolError` and closes it.
  An `ErrorResponse` raises `QueryError` after reading up to
  `ReadyForQuery`, and leaves the connection usable.
- `NoticeResponse` → `on_notice : Proc(Notice, Nil)?` (default nil, notices
  dropped). `NotificationResponse` outside LISTEN support is dropped.
  `ParameterStatus` mid-session updates `parameters`.

### 6.1 Query path

`exec(sql, *args)`, `query_one`, `query_one?`, `query_all`, `query_each`.
Only `exec` without args uses the **simple** protocol (`Query`), which
also allows multi-statement strings; every `query_*` call is extended, so
results are binary and typed. Everything else uses the **extended** protocol:

1. Statement lookup by SQL text. Miss (or cache off): `Parse(name, sql,
   no param types)` + `Describe('S', name)` + `Sync` → `ParseComplete`,
   `ParameterDescription`, `RowDescription | NoData`, `ReadyForQuery`. With
   the cache on the name is `s<N>` and the statement is stored; off, the
   unnamed statement is used and this happens on every call.
2. Encode each argument against its parameter OID (§7). Result format per
   column: binary for OIDs with a binary decoder, text otherwise.
3. `Bind('', name, formats, values, result formats)` + `Execute('', 0)` +
   `Sync` → `BindComplete`, `DataRow`*, `CommandComplete`, `ReadyForQuery`.

So the first use costs two round trips and every later one (cache on)
costs one. Evicting a cached statement queues `Close('S', name)`, sent
ahead of the next round trip; its `CloseComplete` is consumed there.

Invalidation: an `ErrorResponse` with SQLSTATE `0A000` ("cached plan must
not change result type") or `26000` (statement does not exist, e.g. after
`DISCARD ALL`) for a cached statement drops it; the query is retried once
when the transaction status before it was `I` (outside a transaction a
retry is safe; inside, the transaction is already aborted and the error is
raised).

Row delivery: `DataRow`s are decoded as they arrive (no buffering of the
whole result); `query_all` appends to an array, `query_each` yields,
`query_one` keeps the first and discards the rest, raising `NoRowsError`
for none. An exception from the `query_each` block drains the rest of the
response before propagating so the connection stays in sync.

### 6.2 Transactions

`transaction { |tx| }` sends `BEGIN` (simple), yields `self`, `COMMIT` on
normal exit, `ROLLBACK` on exception (re-raised). Nested calls use
`SAVEPOINT sp<depth>` / `RELEASE` / `ROLLBACK TO`. There is no `rollback`
method: raising rolls back. A block that swallowed a `QueryError` leaves
the transaction aborted; `COMMIT` would silently roll back, so
`transaction` rolls back and raises `Error` instead. Options: `transaction(isolation: :serializable, read_only: true)`.

## 7. Types (`src/postgres/codec.cr`, `src/postgres/interval.cr`)

Binary decode by column OID into the requested Crystal type:

| Crystal target | Accepted column types |
|---|---|
| `Bool` | bool |
| `Int16` | int2 |
| `Int32` | int2, int4 |
| `Int64` | int2, int4, int8 |
| `UInt32` | oid |
| `Float32` | float4 |
| `Float64` | float4, float8 |
| `BigDecimal` | numeric (NaN/±Infinity raise `DecodeError`), int2/4/8 |
| `String` | text, varchar, bpchar, name, char, json, jsonb (text of the value), and any column received in text format |
| `Bytes` | bytea |
| `UUID` | uuid |
| `Time` | timestamptz, timestamp (both read as UTC), date (UTC midnight) |
| `Time::Span` | interval with months = 0, time (since midnight) |
| `Postgres::Interval` | interval |
| `JSON::Any` | json, jsonb |
| `T?` | as `T`, plus SQL NULL → nil |

SQL NULL into a non-nilable target, or a column type not in the target's
row, raises `DecodeError` naming the column, its type and the target.
`timestamp` `infinity`/`-infinity` raise `DecodeError`.

Parameter encoding is chosen by the server-declared parameter OID from
`ParameterDescription`:

| Crystal value | Encodable as |
|---|---|
| `nil` | any (NULL) |
| `Bool` | bool |
| `Int8`..`Int64`, `UInt8`..`UInt32` | int2/int4/int8 (range-checked → `EncodeError`), float4/8, numeric, oid |
| `Float32`, `Float64` | float4, float8, numeric |
| `BigDecimal` | numeric |
| `String` | text-like types in binary; **any other OID in text format** (the server parses it: enums, inet, a uuid given as a string, arrays written as `{1,2}`) |
| `Bytes` | bytea |
| `UUID` | uuid |
| `Time` | timestamptz, timestamp (UTC wall clock), date (the UTC calendar date) |
| `Time::Span` | interval |
| `Postgres::Interval` | interval |
| `JSON::Any` | json, jsonb |

Anything else raises `EncodeError` naming the parameter index, the value's
type and the parameter type. Unsupported Crystal types in the argument list
are a compile error (the encoder is an overload set).

`Postgres::Interval`: `months : Int32`, `days : Int32`,
`microseconds : Int64`; `to_span` (raises `ArgumentError` when months ≠ 0),
`Interval.new(span)`, `to_s` in ISO 8601 (`P1M2DT3.5S`), `==`.

## 8. Statement cache (`src/postgres/statement_cache.cr`)

Per connection. `Hash(String, PreparedStatement)` in insertion order used
as an LRU (a hit deletes and reinserts, an insert beyond capacity shifts
the oldest and queues its `Close`). `PreparedStatement` = name, parameter
OIDs, fields, result format codes. Capacity 256, 0 = off. `Connection`
exposes `statement_cache_size` and `clear_statement_cache` (queues closes).

## 9. Serializable (`src/postgres/serializable.cr`)

```crystal
struct User
  include Postgres::Serializable
  getter id : Int64
  @[Postgres::Field(key: "email_address")]
  getter email : String?
  @[Postgres::Field(ignore: true)]
  getter cache = 0
  getter role : String = "member"   # default used when the column is absent
end
```

- Generates `def self.from_pg_row(row : Postgres::RowReader) : self` and a
  constructor via `@type.instance_vars` in a method-level macro (the
  `JSON::Serializable` technique; `instance_vars` is unusable in
  `macro finished`).
- The column-to-ivar mapping is computed once per result (from the
  `RowDescription`), not per row: `RowReader` carries a per-result lookup
  table `Array(Int32)` (ivar index → column index or -1).
- Missing column: default value if the ivar has one, nil if nilable,
  otherwise `DecodeError` at the first row. Extra columns are ignored.
- A scalar `as: T` (any type in the §7 table) reads column 0 of a result
  that must have exactly one column (`DecodeError` otherwise).

## 10. Client (`src/postgres/client.cr`)

`Client.new(url = nil, *, pool_size = 10, checkout_timeout = 5.seconds,
statement_cache_size = 256, **connection options)`. Nothing connects until
the first query. Every query method checks a connection out of a
`Pool(Connection)` for the call (for `query_each` for the whole
iteration), and `transaction`/`with_connection` hold one for the block.
Pool health check: an empty `Query("")` round trip on connections idle
≥ 1 s. `close` closes the pool. After a `ConnectionError` the connection is
closed and the pool drops it; the error is raised (no automatic retry).

## 11. Errors (`src/postgres/error.cr`)

```
Postgres::Error < Exception
  ConnectionError          # connect failure, I/O failure, TLS refused
  AuthenticationError      # also for a failed SCRAM server signature
  ProtocolError            # malformed or unexpected message
  QueryError               # ErrorResponse: #code (SQLSTATE), #severity, #detail, #hint, #position, #fields
  DecodeError / EncodeError
  NoRowsError              # query_one with no rows
Pool::TimeoutError, Pool::ClosedError  (from src/pool.cr)
```

`QueryError#message` is `"<severity> <code>: <message>"` plus detail and hint
lines when present.

## 12. Testing

- `spec/std/pool_spec.cr`: permits, timeout, closed-drop, health check,
  factory failure returns the permit, close with connections out.
- Pure specs: config parsing (URL, env, precedence, unix `host=`), SCRAM and
  MD5 known answers, codec round trips for every §7 row (encode → decode
  on byte level, against byte strings taken from a real server),
  `Interval`, statement cache LRU order and queued closes.
- Fake-server specs (a scripted TCP server, like Redis'): startup and each
  auth path, `SSLRequest` answered `N` under each sslmode, ErrorResponse
  leaves the connection usable, invalidation retry, a read timeout closes
  the connection, a malformed message closes it, `query_each` block raise
  drains.
- Live specs (`POSTGRES_URL`, default
  `postgres://postgres@127.0.0.1:5432/postgres`; pending when unreachable):
  every type both ways against real columns, struct mapping, transactions
  and savepoints, statement cache hit (second call is one round trip:
  count messages) and invalidation after `alter table`, 64 fibers × pool of
  8, TLS (`sslmode=require`), and per-auth-method URLs
  (`POSTGRES_MD5_URL`, `POSTGRES_SCRAM_URL`, `POSTGRES_CLEARTEXT_URL`,
  `POSTGRES_SSL_URL`) each pending when unset.

## 13. Benchmarks

Harness under `.agent-context/harnesses/harness-2026-09-26/postgres/` with
Rust `tokio-postgres` and Go `pgx` baselines on the same local server
(`sslmode=disable`, loopback TCP):

1. Sequential `select $1::int` latency (cached statement), 10k iterations.
2. 10k-row fetch of `(int8, text, float8, timestamptz, bool)`, decode into
   a struct.
3. 64 fibers × pool of 8, `select $1::int` throughput.

Targets: (1) within 5 % of pgx; (2) ≥ pgx; (3) ≥ pgx. Report honestly
when missed.

## 14. Out of scope for slice 1

Arrays, COPY, LISTEN/NOTIFY, multi-query pipelining, CancelRequest,
SCRAM-SHA-256-PLUS, `verify-ca`/`verify-full` beyond what
`OpenSSL::SSL::Context::Client` verification gives (root cert via
`sslrootcert`), dynamic `Value` rows, tuple mapping, `Redis::Pool` moving
onto `::Pool(T)`, SASLprep, GSSAPI.

## 15. Implementation notes (2026-09-26)

Deviations settled while building slice 1:

- `Connection.new(config: cfg)` and `Client.new(config: cfg)` take a
  `Config` by keyword only. A positional `Config` overload next to
  `new(url = nil, ...)` is silently shadowed by the compiler (a def whose
  first positional has a default replaces one where it is required), so
  the URL form keeps the positional slot. The URL forms list every
  `Config.parse` keyword explicitly (not `**options`) so symbol autocast
  works (`sslmode: :require`).
- Config (built in parallel): `connect_timeout` must be positive (libpq's
  `0` = no timeout is rejected); ports 1..65535; a `+` in a URL password
  stays `+` for a `String` URL (a pre-parsed `URI` has already turned it
  into a space); `statement_cache_size` has no environment variable.
- Queued statement `Close`s are written after `Bind`, so an argument that
  fails to encode (which discards the half-written `Bind`) cannot drop
  them.

## 16. Slice 2 (2026-09-26, same session)

User decisions: order arrays → LISTEN/NOTIFY → COPY → pipelining +
cancel; pipeline queries are **independent** (a Sync after each; wrap in
`transaction` for atomicity); pipeline API is **futures**; on
`read_timeout` **cancel and keep the connection**.

- Arrays: 1-D `Array(T)`/`Array(T?)` both ways for every scalar type of
  §7; array columns travel in binary (reading one as `String` now raises);
  arrays for unknown element types, or strings for typed elements, go as
  a quoted text literal.
- `Listener` (LISTEN/NOTIFY), modelled on `Redis::Subscriber`: dedicated
  connection, reader fiber, bounded channel, acked `listen`/`unlisten`,
  reconnect with backoff and re-LISTEN, hooks guarded against
  re-entrance. `notify` via `pg_notify`. `Connection#on_notification`.
- COPY: `copy_from`/`copy_to` stream any format (64 KiB CopyData chunks,
  CopyFail on a raising block, drained on early exit); `copy_rows` writes
  binary COPY with values encoded by the real column types.
- Cancel: a timeout between messages (`IO#peek`) sends a CancelRequest,
  waits for the server to close that socket, and raises
  `IO::TimeoutError` at the following `ReadyForQuery`; a second timeout
  closes.
- Pipeline: round 1 prepares every uncached statement (Sync each), round
  2 sends Bind/Execute/Sync per query; queued Closes (evictions caused by
  round 1, temporary statements when the cache is off) go after every
  query. Stale statements fail their future (no retry inside a pipeline).

Benchmarks (harness README): COPY 1M rows 2.25M rows/s vs pgx 1.55M;
100 queries pipelined 3.1x faster than sequential on loopback.

## 17. Feature-complete round (2026-09-26, same session)

User scope decision: finish Postgres before merging to fork master, with
enums + converters, more built-in types, ranges, multi-dimensional arrays
+ composites, pgpass + service + options, multi-host failover, SCRAM
channel binding, tuple rows and cursors. Runtime fixes stay fork-only; no
upstream report for the compiler crash.

- Enums (by label or value), `@[Postgres::Field(converter: M)]`
  (`M.from_pg(row, index)`), `to_pg` for parameters, `as: {A, B}` tuples.
- inet/cidr (`Inet`, `Socket::IPAddress`), macaddr(8), timetz, bit/varbit
  (`BitArray`), money (`Int64` minor units), xml, hstore
  (`Hash(String, String?)`, text form), `Postgres::Range(T)` for the six
  built-in ranges (Crystal `Range` as a parameter). Binary types keep a
  canonical `String` form (money excepted).
- N-dimensional arrays by nesting (`Array(Array(T))`), rectangular only.
- Per-connection `TypeMap`: unknown OIDs looked up in `pg_type` lazily and
  transitively; domains act as their base type; composites and `row()`
  decode into tuples; a tuple parameter is a row literal.
- Config: multi-host lists, `target_session_attrs`, `load_balance_hosts`,
  `.pgpass`, `pg_service.conf`, `options`/`search_path`,
  `channel_binding`. Connection fails over across hosts; one host keeps
  its own error.
- Auth: SASLprep; SCRAM-SHA-256-PLUS (tls-server-end-point); `require`
  also refuses cleartext/md5 and an unverified AuthenticationOk.
- Cursors: `query_each(..., fetch_size:)` over the unnamed portal
  (Execute + Flush per batch, Sync at the end).
- Found on the way: compiler crash repro in
  `.agent-context/notes/compiler-crash-indexable-ivar-tuples.cr`; macro
  code must not spell user type names (file-private types) — use
  `typeof(...)`.
