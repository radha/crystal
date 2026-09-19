# `Redis` client design (Tier 3b, slice 1)

Date: 2026-09-19. Status: approved in brainstorm, ready for planning.

## Goal

A pure-Crystal Redis client in the stdlib (`require "redis"`), speaking RESP3
with RESP2 fallback, over TCP, Unix sockets, or TLS. One `Redis::Client` is a
single multiplexed connection that any number of fibers call concurrently;
commands are auto-pipelined by a writer fiber and replies dispatched in order
by a reader fiber. Typed methods cover the common commands; `command(*args)`
is the escape hatch returning a RESP value.

It is the second real-world consumer of the binary foundation after
`Binary::Format`, and the protocol that shakes out buffered socket IO, a
hand-written parser, and the fiber machinery that Tier 3a Postgres and Tier 4
RPC will reuse (writer/reader fibers, waiter queue, lazy reconnect).

Decisions taken in the brainstorm and not to be reopened:

- Slice 1 is the core client only: codec, connection, multiplexer, pipeline
  block, typed commands, errors. Pub/sub, MULTI/EXEC, the EVALSHA script cache,
  and cluster routing are slice 2 and later. Slice 1 leaves the hooks they
  need (push-frame handler, public `Connection` class, `code` on
  `CommandError`) but implements none of them.
- Concurrency model is a multiplexed connection with a writer fiber and a
  reader fiber (Approach A), not caller-driven coalescing and not futures
  by default.
- Values are a bare recursive union alias, not a wrapper struct. Bulk strings
  become `String`, not `Bytes`.
- No automatic command retry on connection loss. Reconnect is lazy on the
  next call. Connect is lazy on the first call.
- Live-server integration specs are part of the suite, marked pending when
  no server answers.

## 1. Public surface

```crystal
require "redis"

redis = Redis::Client.new("redis://localhost:6379/0")
redis.set("greeting", "hello", ex: 60)
redis.get("greeting")            # => "hello"
redis.incr("counter")            # => 1_i64
redis.hgetall("user:1")          # => {} of String => String

# Concurrent fibers share the client; commands are batched automatically.
64.times { spawn { redis.incr("hits") } }

# Explicit pipeline: one flush, typed futures.
first = nil
results = redis.pipelined do |p|
  p.set("a", "1")
  first = p.get("a")             # => Redis::Future(String?)
  p.incr("b")
end
results                          # => ["OK", "1", 1_i64] : Array(Redis::Value)
first.not_nil!.value             # => "1"

# Escape hatch.
redis.command("CLIENT", "ID")    # => 42_i64 : Redis::Value

# Dedicated connection for blocking commands.
conn = Redis::Connection.new("redis://localhost:6379")
conn.call("BLPOP", "queue", 0)
```

### 1.1 Files

```
src/redis.cr                     # require "./redis/*"
src/redis/value.cr               # Value alias, BigNumber
src/redis/error.cr               # Error hierarchy
src/redis/resp.cr                # RESP encoder + RESP2/RESP3 parser
src/redis/connection.cr          # one socket, HELLO, synchronous call/pipeline
src/redis/client.cr              # multiplexer: writer/reader fibers, waiters, reconnect
src/redis/pipeline.cr            # Pipeline + Future(T)
src/redis/commands.cr            # Commands module, def_command macro, shape casts
src/redis/commands/server.cr     # ping, echo, select, dbsize, flushdb, flushall, info, time
src/redis/commands/keys.cr
src/redis/commands/strings.cr
src/redis/commands/hashes.cr
src/redis/commands/lists.cr
src/redis/commands/sets.cr
src/redis/commands/sorted_sets.cr
src/redis/commands/scripting.cr
spec/std/redis/resp_spec.cr
spec/std/redis/connection_spec.cr   # fake server
spec/std/redis/client_spec.cr       # fake server
spec/std/redis/commands_spec.cr     # live server, RESP3 and RESP2
spec/support/redis.cr               # pending_redis gate, key prefix, fake server helper
```

Not in the prelude. `require "redis"` pulls `socket`, `openssl`, `uri`,
`set`. It does not pull `big`.

## 2. Values (`src/redis/value.cr`)

```crystal
module Redis
  alias Value = Nil | Bool | Int64 | Float64 | String | BigNumber |
                CommandError | Array(Value) | Set(Value) | Hash(Value, Value)

  struct BigNumber
    getter digits : String     # decimal text as sent, e.g. "-3492890328409238509324850943850943825024385"
    def to_s(io); def ==(other : BigNumber); def hash(hasher)
  end
end
```

Mapping from RESP frames:

| RESP3 type          | byte | Crystal            | RESP2 equivalent            |
|---------------------|------|--------------------|-----------------------------|
| simple string       | `+`  | `String`           | same                        |
| bulk string         | `$`  | `String`           | same; `$-1` → `nil`         |
| verbatim string     | `=`  | `String` (prefix `txt:`/`mkd:` stripped) | n/a |
| integer             | `:`  | `Int64`            | same                        |
| double              | `,`  | `Float64` (`inf`, `-inf`, `nan` handled) | n/a |
| boolean             | `#`  | `Bool`             | n/a                         |
| null                | `_`  | `Nil`              | `$-1`, `*-1`                |
| big number          | `(`  | `BigNumber`        | n/a                         |
| simple error        | `-`  | `CommandError`     | same                        |
| bulk error          | `!`  | `CommandError`     | n/a                         |
| array               | `*`  | `Array(Value)`     | same                        |
| push                | `>`  | `Array(Value)` routed to push handler, never returned as a reply | n/a |
| map                 | `%`  | `Hash(Value, Value)` | n/a                       |
| set                 | `~`  | `Set(Value)`       | n/a                         |
| attribute           | `\|` | parsed and discarded; the following value is returned | n/a |

Error replies: at the top level of a reply the parser returns the
`CommandError` instance and `Connection#call` / `Client#call` raise it.
Nested inside an aggregate it stays a value. `CommandError#code` is the
leading upper-case word (`ERR`, `WRONGTYPE`, `NOAUTH`, `NOPROTO`, `MOVED`,
`BUSY`, ...); `#message` is the full text after the type byte. Bulk errors
follow the same split.

`String` is used for bulk strings because Redis values are binary-safe and a
Crystal `String` carries arbitrary bytes with an exact `bytesize`. Callers
that need bytes use `String#to_slice`. Simple strings and bulk strings are not
distinguished in the value; typed methods that care (`SET` → `"OK"`) check the
text.

## 3. Codec (`src/redis/resp.cr`)

```crystal
module Redis::RESP
  MAX_BULK_SIZE = 512 * 1024 * 1024   # Redis' own proto-max-bulk-len default
  MAX_DEPTH     = 512

  # Command argument types accepted everywhere: coerced with to_s except Bytes.
  alias Arg = String | Bytes | Int | Float | Symbol

  def self.write_command(io : IO, args : Enumerable) : Nil
  def self.write_command(io : IO, *args : Arg) : Nil
  def self.read(io : IO, *, max_bulk_size = MAX_BULK_SIZE, max_depth = MAX_DEPTH,
                push : (Array(Value) ->)? = nil) : Value
end
```

Encoder: always the RESP2-compatible bulk array (`*N\r\n$len\r\narg\r\n...`),
which is what every Redis version accepts for commands. Ints and floats are
formatted with `to_s` straight into the IO (no intermediate String). `Bytes`
is written raw. The whole command lands in the IO's buffer; the encoder
never flushes.

Parser:

- Reads the type byte with `read_byte`, then integers and lengths by
  consuming ASCII digits directly from the buffered IO (no `gets`, no
  intermediate String). Simple strings, errors, doubles and big numbers use
  `gets("\r\n", chomp: true)`.
- Bulk strings: `String.new(len) { |buf| io.read_fully(Slice.new(buf, len)); {len, 0} }`
  then consume the trailing `\r\n`. Length above `max_bulk_size` raises
  `ProtocolError` before allocating. Negative length other than `-1` raises.
- Aggregates recurse with `depth + 1`; exceeding `max_depth` raises
  `ProtocolError`. Element count above `max_bulk_size` also raises (a
  malicious `*2147483647` must not presize a giant Array).
- `>` push frames: parsed as an array, handed to `push` if given, and the
  parser loops to read the next frame. With no handler the push is dropped.
  So `read` always returns a non-push reply.
- `|` attributes: parsed as a map, discarded, and the next value is returned.
- Unknown type byte, missing `\r\n`, EOF mid-frame: `ProtocolError`. EOF at
  a frame boundary: `IO::EOFError` (the connection layer turns this into
  `ConnectionError`).
- Map keys are `Value`; `Hash(Value, Value)` and `Set(Value)` work because
  every member type of `Value` is hashable (`CommandError` by identity).

No code path in the parser branches on protocol version: RESP2 frames are a
subset of RESP3 frames.

## 4. Connection (`src/redis/connection.cr`)

```crystal
class Redis::Connection
  include Redis::Commands

  DEFAULT_URL = "redis://localhost:6379"

  # Options, all keyword: also accepted by Client and forwarded.
  def initialize(url : String | URI = DEFAULT_URL, *,
                 db : Int32? = nil, username : String? = nil, password : String? = nil,
                 client_name : String? = nil, protocol : Int32 = 3,
                 connect_timeout : Time::Span = 5.seconds, read_timeout : Time::Span? = nil,
                 tls_context : OpenSSL::SSL::Context::Client? = nil,
                 max_bulk_size : Int32 = RESP::MAX_BULK_SIZE)

  getter url : URI
  getter protocol : Int32           # negotiated: 3 or 2
  property push_handler : (Array(Value) ->)?

  def send(*args : RESP::Arg) : Nil          # encode + flush
  def send(args : Enumerable) : Nil
  def read : Value                           # one reply; raises CommandError at top level
  def call(*args : RESP::Arg) : Value        # send + read
  def call(args : Enumerable) : Value
  def pipeline(commands : Enumerable(Enumerable)) : Array(Value)   # send all, flush, read all; errors stay as values
  def close : Nil
  def closed? : Bool
  def socket : IO                            # for Client's fibers
end
```

URL forms: `redis://[user[:pass]@]host[:port][/db]`, `rediss://...` (TLS
via `OpenSSL::SSL::Socket::Client` with SNI hostname, `tls_context` or a
default verifying context), `redis+unix:///path/to/sock[?db=N]` and
`unix:///path`. Keyword options override URL parts. `protocol` must be 2 or
3 (`ArgumentError` otherwise); 2 skips HELLO entirely.

Open sequence (in `initialize`, so a `Connection` is always connected or
raises):

1. Connect: `TCPSocket.new(host, port, connect_timeout: ...)` with
   `tcp_nodelay = true`, or `UNIXSocket.new(path)`. Wrap in TLS for `rediss`.
   Socket stays buffered (`sync = false`). Failure → `ConnectionError` with
   the cause chained.
2. If `protocol == 3`: `HELLO 3 [AUTH user pass] [SETNAME name]`. Reply is a
   map; store `protocol` from its `"proto"` key. On `CommandError` with code
   `ERR` whose message mentions `unknown command`, or code `NOPROTO`: fall
   back to `protocol = 2` and continue with step 3. Any other error
   (`WRONGPASS`, `NOAUTH`) propagates as the `CommandError`.
   `username` defaults to `"default"` when only a password is given.
3. If `protocol == 2`: `AUTH [user] pass` if a password is set, then
   `CLIENT SETNAME name` if set.
4. `SELECT db` if db is set and nonzero.

`read` applies `read_timeout` via `socket.read_timeout=` when set (this is
the synchronous, single-fiber use; `Client` enforces its own deadline, see
5.3); `IO::TimeoutError` propagates as itself. `send` flushes after encoding.
Any `IO::Error` (including `IO::EOFError`) during `send`/`read` closes the
socket and raises `ConnectionError`; a closed connection raises
`ConnectionError` on every call. `Connection` is not fiber-safe: one fiber
at a time. It exists for blocking commands, for the fake-server specs, and
as the substrate `Client` drives.

## 5. Client (`src/redis/client.cr`)

```crystal
class Redis::Client
  include Redis::Commands

  def initialize(url : String | URI = Connection::DEFAULT_URL, **connection_options)
  def call(*args : RESP::Arg) : Value
  def call(args : Enumerable) : Value
  def pipelined(& : Pipeline ->) : Array(Value)
  def protocol : Int32?                 # nil until connected
  def connected? : Bool
  property push_handler : (Array(Value) ->)?   # forwarded to the connection
  def close : Nil
end
```

### 5.1 State

- `@mutex : Mutex` guarding everything below except the channels.
- `@connection : Connection?` — nil until first call and after a failure.
- `@out : IO::Memory`, `@spare : IO::Memory` — double buffer of encoded
  commands, swapped under the mutex.
- `@pending : Deque(Waiter)` — waiters in send order. A waiter is appended in
  the same critical section that appends its command bytes, so the order of
  `@pending` equals the order of bytes on the wire.
- `@wakeup : Channel(Nil)` capacity 1 — a non-blocking `send` under
  `select`/`else` so signalling is idempotent while a flush is queued.
- `@writer : Fiber?`, `@reader : Fiber?` — spawned on connect, exit on
  disconnect.
- `@waiter_pool : Deque(Waiter)` — recycled waiters.
- `@closed : Bool`.

`Waiter` is a class with `channel : Channel(Value | Exception)` (capacity 1,
created once, reused) and nothing else. A pooled waiter is handed back after
its owner has received, so no stale delivery can reach a new owner.

### 5.2 `call`

1. Under the mutex: raise `ConnectionError` if `@closed`; ensure connected
   (see 5.4; connecting happens *inside* the mutex so two racing first calls
   open one socket); encode into `@out`; take or create a waiter; push it to
   `@pending`.
2. Signal `@wakeup` (non-blocking).
3. `waiter.channel.receive`, under `select` with `timeout(read_timeout)`
   when set (see 5.3). Return the waiter to the pool. Raise if the
   result is an `Exception` (`CommandError` from Redis, or
   `ConnectionError` from the reader). Otherwise return the value.

`pipelined`: the block runs against a `Pipeline` that records commands and
futures locally; at block end, one critical section appends all bytes and N
waiters, one signal, then N receives in order. Results resolve the futures
and are returned as an array. Error replies inside a pipeline are *not*
raised; they stay as `CommandError` values in the array, and
`Future#value` raises them. A `ConnectionError` fails the whole pipeline.

### 5.3 Fibers

Writer loop:

```
loop do
  @wakeup.receive? || break
  buffer = @mutex.synchronize { swap @out and @spare; return the full one }
  next if buffer.empty?
  socket.write(buffer.to_slice); socket.flush; buffer.clear
rescue IO::Error → mark disconnected (5.4), break
end
```

Because callers keep encoding into the other buffer during `write`/`flush`,
everything that arrives while a flush is in progress is sent in the next
single flush. That is the auto-pipelining. At low load each command is its
own flush with no added latency beyond a fiber switch.

Reader loop:

```
loop do
  value = RESP.read(socket, push: @push_handler)
  waiter = @mutex.synchronize { @pending.shift? }
  waiter.channel.send(value)         # value may be a CommandError
rescue IO::Error | ProtocolError → mark disconnected, break
end
```

A reply with no pending waiter is a protocol desync: mark disconnected with
`ProtocolError`.

`read_timeout` on a `Client` is a per-command deadline enforced by the
caller, not by the socket (the reader fiber's socket has no timeout, so an
idle connection never times out, and a timeout set on a socket whose read is
already blocked would not take effect anyway). The caller waits with
`select` over `waiter.channel.receive` and `timeout(read_timeout)`. On
expiry it calls `mark_disconnected` (a single command cannot be cancelled on
a multiplexed connection, so every pending caller gets `ConnectionError`)
and raises `IO::TimeoutError` itself. The `Connection` used by `Client` is
opened with `read_timeout: nil`.

### 5.4 Disconnect and reconnect

`mark_disconnected(cause)` under the mutex: close the socket, set
`@connection = nil`, clear `@out` and `@spare`, drain `@pending` sending
`ConnectionError.new("connection lost", cause: cause)` to every waiter, and
send one `@wakeup` so the writer wakes and exits (it checks `@connection`
before writing). Commands encoded but not yet flushed are lost with the same
error. Nothing is retried.

The next `call` finds `@connection == nil` and reconnects inline (inside the
mutex, so concurrent callers queue behind it). Connect failure raises
`ConnectionError` to that caller only and leaves the client reusable.

`close`: under the mutex set `@closed`, then `mark_disconnected(nil)`
(waiters get `ConnectionError("client closed")`), close `@wakeup` so the
writer exits, and the reader exits on the socket close.

### 5.5 Fiber safety

All shared state is behind `@mutex` or channels; `Mutex` and `Channel` are
execution-context safe, so the client works under `-Dpreview_mt` and
execution contexts without additional locking. `Connection` itself is
single-fiber by contract and `Client` is the only thing that touches its
socket after handing it to the fibers.

## 6. Pipeline and Future (`src/redis/pipeline.cr`)

```crystal
class Redis::Pipeline
  include Redis::Commands
  def call(*args : RESP::Arg) : Future(Value)    # records, returns a future
  def size : Int32
end

class Redis::Future(T)
  def value : T           # raises if unresolved (ArgumentError) or resolved to CommandError/ConnectionError
  def value? : T?
  def resolved? : Bool
end
```

Typed methods in `Pipeline` return `Future(T)` instead of `T`. The
`def_command` macro generates the same body for all three includers; only the
`call` return type differs, and the shape cast is applied when the future is
resolved (so a wrong-shape reply raises `ProtocolError` from `value`, not
from the reader fiber).

## 7. Commands (`src/redis/commands.cr` and `commands/*.cr`)

### 7.1 Macro

```crystal
module Redis::Commands
  # Simple commands: fixed args, one reply shape.
  macro def_command(name, cmd, *params, returns)
  # e.g.
  def_command get, "GET", key : String, returns: String?
  def_command incr, "INCR", key : String, returns: Int64
  def_command del, "DEL", *keys : String, returns: Int64
end
```

The macro emits `def name(params) : returns` whose body is
`cast(call(cmd, params...), returns)`. `cast` is a small set of overloads:
`Value → String?`, `String`, `Int64`, `Float64` (accepts an Int64 or a
numeric String, for INCRBYFLOAT under both protocols), `Bool` (accepts
`true`/`false` or `1`/`0` Int64 for RESP2), `Array(String)`, `Array(String?)`,
`Hash(String, String)` (accepts a map or a flat even-length array),
`Array({String, Float64})` (accepts an array of pairs or a flat array),
`Nil`. Anything else raises `ProtocolError("unexpected reply ...")`.

In `Pipeline` the macro emits `Future(returns)` with the same cast applied
at resolution.

### 7.2 Hand-written commands

Commands with option flags or variadic shapes are ordinary defs beside the
table, each with a doc comment:

- `set(key, value, *, ex: Time::Span? | Int?, px:, exat:, pxat:, nx: Bool, xx: Bool, keepttl: Bool, get: Bool) : String?` — returns `"OK"`, `nil` when NX/XX condition fails, or the old value with `get: true`.
- `expire`/`pexpire` with `nx/xx/gt/lt` flags → `Bool`.
- `lpop`/`rpop`: `(key) : String?` and `(key, count : Int) : Array(String)`.
- `lpush`/`rpush`/`sadd`/`srem`/`hdel`/`zrem` variadic values.
- `hset(key, field, value)` and `hset(key, hash : Hash(String, String))`.
- `zadd(key, score, member)` and `zadd(key, members : Enumerable({String, Float64}), *, nx:, xx:, gt:, lt:, ch:)`; `zadd_incr`.
- `zrange(key, start, stop, *, by_score: Bool, by_lex: Bool, rev: Bool, limit: {Int, Int}?)` → `Array(String)` and `zrange_with_scores(...)` → `Array({String, Float64})`; same for `zrevrange` via `rev:`.
- `zpopmin`/`zpopmax` (with optional count) → `Array({String, Float64})`.
- `scan`, `hscan`, `sscan`, `zscan` — return `{cursor : String, items}`; plus `scan_each(match:, count:, &)` iterating until cursor `"0"`.
- `eval(script, keys : Array(String), args : Array(RESP::Arg))`, `evalsha`, `script_load : String`, `script_exists : Array(Bool)`, `script_flush`.
- `info(section = nil) : Hash(String, String)` parsed from the `key:value` lines, `time : {Int64, Int64}`, `select(db)`, `flushdb(async: false)`, `flushall`.
- `command(*args) : Value` and `command(args : Enumerable) : Value` — aliases of `call`, the escape hatch.

### 7.3 Command list (slice 1)

- server: `ping`, `echo`, `select`, `dbsize`, `flushdb`, `flushall`, `info`, `time`
- keys: `del`, `unlink`, `exists`, `expire`, `pexpire`, `expireat`, `pexpireat`, `ttl`, `pttl`, `persist`, `type`, `rename`, `renamenx`, `keys`, `scan`, `scan_each`
- strings: `get`, `set`, `setnx`, `setex`, `psetex`, `getset`, `getdel`, `mget`, `mset`, `msetnx`, `incr`, `incrby`, `incrbyfloat`, `decr`, `decrby`, `append`, `strlen`, `getrange`, `setrange`
- hashes: `hget`, `hset`, `hsetnx`, `hmget`, `hgetall`, `hdel`, `hexists`, `hkeys`, `hvals`, `hlen`, `hincrby`, `hincrbyfloat`, `hscan`
- lists: `lpush`, `rpush`, `lpushx`, `rpushx`, `lpop`, `rpop`, `llen`, `lrange`, `lindex`, `lset`, `lrem`, `ltrim`, `linsert`, `lmove`
- sets: `sadd`, `srem`, `smembers`, `sismember`, `smismember`, `scard`, `spop`, `srandmember`, `smove`, `sinter`, `sunion`, `sdiff`, `sinterstore`, `sunionstore`, `sdiffstore`, `sscan`
- sorted sets: `zadd`, `zadd_incr`, `zrem`, `zscore`, `zmscore`, `zcard`, `zcount`, `zincrby`, `zrange`, `zrange_with_scores`, `zrank`, `zrevrank`, `zpopmin`, `zpopmax`, `zscan`
- scripting: `eval`, `evalsha`, `script_load`, `script_exists`, `script_flush`

Blocking commands (`BLPOP`, `BRPOP`, `BLMOVE`, `WAIT`, `XREAD BLOCK`, ...) are
deliberately absent from the typed surface: they would stall every other
caller on a multiplexed client. They work through `Connection#call` on a
dedicated connection, and the `Client#call` doc comment says so.

## 8. Errors (`src/redis/error.cr`)

```crystal
class Redis::Error < Exception; end
class Redis::ConnectionError < Redis::Error; end   # connect failed, lost, closed
class Redis::ProtocolError < Redis::Error; end     # malformed frame, guards, unexpected reply shape
class Redis::CommandError < Redis::Error            # "-" / "!" replies
  getter code : String                              # "ERR", "WRONGTYPE", ...
end
```

`IO::TimeoutError` from `read_timeout` and `ArgumentError` for bad options
are not wrapped.

## 9. Testing

Three layers, all under `spec/std/redis/`.

1. **Codec** (`resp_spec.cr`, no network): known-answer bytes for every
   frame type in both directions, including `$-1`/`*-1` nulls, `,inf`,
   `,nan`, verbatim prefix stripping, nested maps and sets, attribute
   discard, push routing, error code parsing; guards for oversized bulk,
   oversized count, depth; truncated input raises `ProtocolError`; EOF at a
   boundary raises `IO::EOFError`; encoder output for each `Arg` type.
2. **Fake server** (`connection_spec.cr`, `client_spec.cr`): a
   `TCPServer` bound to `127.0.0.1` port 0 inside the spec, driven by a
   scripted handler from `spec/support/redis.cr`. Covers HELLO success and
   fallback (`ERR unknown command`, `NOPROTO`), AUTH/SELECT sequencing,
   `protocol: 2`, disconnect mid-reply → `ConnectionError` to all pending
   callers, lazy reconnect on the next call, `close` semantics, push frames
   delivered to the handler and not to waiters, `read_timeout` with a stalled
   server, desync (unsolicited reply) → `ProtocolError`, pipelined block with
   an error in the middle, and one batching check: the server holds its first
   reply until it has read a second chunk, and asserts that the following N
   commands arrived in one `read`. Also `Connection` over a Unix socket.
3. **Live** (`commands_spec.cr`): against `ENV["REDIS_URL"]` or
   `redis://localhost:6379`. `spec/support/redis.cr` probes once at load with
   a 200 ms connect timeout and defines `pending_redis` in the style of
   `pending_ipv6`. Each example uses db 15, a random key prefix, and
   `FLUSHDB` in `before_each`. The typed-command examples are wrapped in a
   macro that instantiates them twice, once with `protocol: 3` and once with
   `protocol: 2`, so every normalization in `cast` is exercised on both wire
   formats. Concurrency example: 64 fibers each doing 100 `incr` on one key
   end at 6400, and a 10k-command pipeline round-trips.

Live specs run in `make std_spec` when a server is up (Homebrew's Valkey
locally) and show as pending otherwise; they never fail for lack of a server.

## 10. Benchmarks

Harness under `.remember/harness-2026-09-19/redis/` (gitignored), with the
same baseline-vs-candidate discipline as the earlier phases:

- Codec: parse 1M mixed replies (small ints, 10 B and 1 KiB bulk strings,
  10-element arrays, 10-entry maps) from memory; encode 1M `SET` commands.
  Compared to redis-rs `parse_redis_value` and go-redis `proto.Reader`.
- Live loopback against Valkey: (a) single fiber sequential GET/SET
  round-trips; (b) 64 fibers concurrent GET/SET, the multiplexing case;
  (c) 10k-command pipeline. Compared to redis-rs `MultiplexedConnection`
  on tokio and go-redis. Target: within 20% of redis-rs on (b), and no
  worse than go-redis on (a).

Results and any rejected variants go into the harness README and the memory
file, as before.

## 11. Out of scope for slice 1

Pub/sub (`Channel`-based subscriber on a dedicated connection, uses the push
hook), MULTI/EXEC/WATCH, EVALSHA script cache with NOSCRIPT fallback, cluster
slot routing with MOVED/ASK, Sentinel, client-side caching (CLIENT TRACKING),
streams (`XADD`/`XREAD`), Pool of clients, automatic retry, and RESP3
attribute exposure.
