# `Redis` client design (Tier 3b, slice 2: pub/sub, transactions, scripts)

Date: 2026-09-20. Builds on the slice 1 spec
(`2026-09-19-redis-client-design.md`), which shipped at master `c589b000f`.

## Goal

Add the three features every application needs beyond plain commands, on
top of the slice 1 client without changing any of its public signatures:

1. **Pub/sub** — `Redis::Subscriber`, a dedicated connection that delivers
   messages on a `Channel`, reconnects and resubscribes on its own.
2. **Transactions** — `multi { |tx| ... }` on `Client`, `Connection` and
   `Pipeline`, sending `MULTI`..`EXEC` as one atomic flush with typed
   futures; `Client#watch(*keys) { |conn| ... }` for optimistic locking on
   a dedicated connection.
3. **Script cache** — `Redis::Script` with a locally computed SHA1,
   `run(script)` sending `EVALSHA` and falling back to `EVAL` on
   `NOSCRIPT`.

Decisions taken in the brainstorm and not to be reopened:

- Slice 2 is exactly these three. Cluster `MOVED`/`ASK` routing and a
  connection `Pool` are slice 3; sharded pub/sub (`SSUBSCRIBE`), streams,
  Sentinel and client-side caching stay out.
- A subscription always lives on its own connection, on RESP2 and RESP3
  alike. The multiplexed `Client` never enters subscribed mode.
- Message consumption is a bounded `Channel(Message)`. A full channel
  applies backpressure to the server through TCP; nothing is dropped
  client-side.
- A dropped subscriber connection reconnects with backoff and resubscribes
  by default. Messages published during the gap are lost; that is inherent
  to Redis pub/sub and is documented, not papered over.
- `WATCH` is never issued on the multiplexed connection. `Client#watch`
  opens a fresh `Connection` for the block and closes it after.
- `multi` returns the `EXEC` array; a nil `EXEC` raises
  `Redis::AbortedError`. Retrying is the caller's loop.
- Pipelines pick `EVALSHA` or `EVAL` from a per-client set of SHAs the
  server is known to have accepted. That set is the only new client state.

## 1. Public surface

```crystal
require "redis"

redis = Redis::Client.new("redis://localhost:6379/0")

# Pub/sub on a dedicated connection.
sub = redis.subscriber                 # or Redis::Subscriber.new(url, ...)
sub.subscribe("news", "alerts")        # returns once the server confirmed
sub.psubscribe("log.*")
spawn do
  sub.each do |msg|                    # Redis::Subscriber::Message
    puts "#{msg.channel}: #{msg.payload}"
  end
end
redis.publish("news", "hello")         # => 1_i64 (receivers)
sub.close

# Atomic transaction, one flush, typed futures.
count = nil
replies = redis.multi do |tx|
  tx.set("a", "1")
  count = tx.incr("hits")              # => Redis::Future(Int64)
end
replies                                # => ["OK", 1_i64] : Array(Redis::Value)
count.not_nil!.value                   # => 1_i64

# Optimistic locking on a dedicated connection.
loop do
  begin
    redis.watch("balance") do |conn|
      balance = conn.get("balance").not_nil!.to_i
      conn.multi { |tx| tx.set("balance", balance - 10) }
    end
    break
  rescue Redis::AbortedError
    # a watched key changed; try again
  end
end

# Cached Lua script.
script = Redis::Script.new("return redis.call('INCRBY', KEYS[1], ARGV[1])")
redis.run(script, keys: ["hits"], args: [5])   # EVALSHA, then EVAL on NOSCRIPT
```

### 1.1 Files

```
src/redis.cr                     # + requires, doc update
src/redis/subscriber.cr          # NEW: Subscriber, Message
src/redis/transaction.cr         # NEW: Transaction, exec/queued futures
src/redis/script.cr              # NEW: Script
src/redis/error.cr               # + AbortedError
src/redis/client.cr              # + subscriber, multi, watch, run, known scripts
src/redis/connection.cr          # + pipelined, multi, watch, unwatch, run, known scripts
src/redis/pipeline.cr            # + multi, run; Pipeline.new takes the known-script set
src/redis/commands.cr            # + run (delegating to includer hook)
src/redis/commands/pubsub.cr     # NEW: publish
spec/std/redis/subscriber_spec.cr
spec/std/redis/transaction_spec.cr
spec/std/redis/script_spec.cr
spec/std/redis/live_spec.cr      # + pub/sub, multi, watch, run at protocol 3 and 2
spec/support/redis.cr            # + pub/sub frame helpers for the fake server
```

## 2. Subscriber (`src/redis/subscriber.cr`)

```crystal
class Redis::Subscriber
  record Message, channel : String, payload : String, pattern : String? = nil

  def initialize(url : String | URI = Connection::DEFAULT_URL, *,
                 username : String? = nil, password : String? = nil, client_name : String? = nil,
                 protocol : Int32 = 3, connect_timeout : Time::Span = 5.seconds,
                 read_timeout : Time::Span? = nil, tls_context : OpenSSL::SSL::Context::Client? = nil,
                 max_bulk_size : Int32 = RESP::MAX_BULK_SIZE,
                 capacity : Int32 = 64, reconnect : Bool = true)

  def subscribe(*channels : String) : Nil
  def psubscribe(*patterns : String) : Nil
  def unsubscribe(*channels : String) : Nil      # none = every channel
  def punsubscribe(*patterns : String) : Nil     # none = every pattern
  def ping : Nil

  def receive : Message                          # raises ConnectionError once closed
  def receive? : Message?                        # nil once closed
  def each(& : Message ->) : Nil                 # until closed
  getter messages : Channel(Message)

  def channels : Array(String)                   # desired, sorted
  def patterns : Array(String)
  def connected? : Bool
  def closed? : Bool
  getter error : Exception?                      # cause of the last drop, nil while healthy
  property on_disconnect : (Exception ->)?
  property on_reconnect : (->)?
  def close : Nil
end

class Redis::Client
  def subscriber(*, capacity : Int32 = 64, reconnect : Bool = true) : Subscriber
end
```

`Client#subscriber` passes the client's URL, username, password,
client_name, protocol, connect_timeout, read_timeout, tls_context and
max_bulk_size. It does not pass `db`: pub/sub is database-independent and a
`SELECT` would only add a round trip.

`new` connects eagerly (a subscriber with nothing to subscribe to is
useless) and runs the slice 1 handshake through `Connection.new`. It raises
the same errors `Connection.new` does. The reader fiber is spawned after
the handshake.

The `Connection` is always opened with `read_timeout: nil`, exactly as
`Client` does: a subscribed socket is idle for as long as nobody
publishes, and a socket-level timeout would tear it down. The
subscriber's `read_timeout` option bounds only the wait for a control
command's confirmation (section 2.2).

### 2.1 State

- `@mutex : Mutex` guarding everything below except `@messages`.
- `@connection : Connection?` — nil while reconnecting or after `close`.
- `@channels : Set(String)`, `@patterns : Set(String)` — *desired*
  subscriptions, the source of truth for resubscribe.
- `@pending : Deque(Ack)` — FIFO of control commands awaiting server
  confirmation. `Ack` holds `remaining : Int32` (confirmation frames
  still expected) and `waiter : Channel(Exception?)?` (nil for the
  subscriber's own resubscribe, whose confirmations nobody waits on).
- `@messages : Channel(Message)` with `capacity`.
- `@closed : Bool`, `@error : Exception?`.
- `@close_signal : Channel(Nil)` — closed by `close`, used to interrupt a
  backoff sleep.

### 2.2 Control commands

`subscribe`, `psubscribe`, `unsubscribe`, `punsubscribe` and `ping` share
one path:

1. Under the mutex: raise `ConnectionError("subscriber is closed")` if
   `@closed`. Update the desired sets (`subscribe` adds,
   `unsubscribe` removes; with no arguments `unsubscribe` clears the set).
   If `@connection` is nil (reconnecting), return now: the change is
   recorded and will be applied by the resubscribe step. Otherwise encode
   the command, write and flush it on the connection's socket, and push an
   `Ack` with a fresh waiter and `remaining` set as below.
2. Outside the mutex: wait on the waiter, under `select` with
   `timeout(read_timeout)` when set. A timeout tears the connection down
   (as if it had dropped, so the reconnect path runs) and raises
   `IO::TimeoutError`. An `Exception` received on the waiter is raised.

`remaining` per command: `SUBSCRIBE`/`PSUBSCRIBE`/`UNSUBSCRIBE`/
`PUNSUBSCRIBE` with N names → N (Redis confirms each name, including names
that were never subscribed). `UNSUBSCRIBE` with no names → the size of the
desired channel set *before* clearing, or 1 if it was empty (Redis answers
with a single frame carrying a nil channel). Same for `PUNSUBSCRIBE` with
the pattern set. `PING` → 1.

The socket is written only under the mutex, so writes from concurrent
callers never interleave; the reader fiber only reads. Every send happens
in the same critical section that pushes its `Ack`, which keeps `@pending`
in wire order.

Subscribing to a channel already in the desired set still sends the
command (the server confirms idempotently); it is the simplest way to keep
`remaining` exact.

### 2.3 Reader fiber and frame dispatch

One loop reads frames with `RESP.read(socket, push: dispatch)`. On RESP3
every pub/sub frame is a push and arrives through `dispatch`, and `read`
only returns for `PING` (`+PONG` in subscribed mode). On RESP2 every frame
is a plain array returned by `read`. Both go through the same
`dispatch(value)`:

| frame | action |
|---|---|
| `["message", ch, payload]` | `@messages.send(Message.new(ch, payload))` |
| `["pmessage", pattern, ch, payload]` | `@messages.send(Message.new(ch, payload, pattern))` |
| `["subscribe" \| "psubscribe" \| "unsubscribe" \| "punsubscribe", name, count]` | decrement head `Ack`; complete it at 0 |
| `["pong", arg]` (RESP2) or `"PONG"` (RESP3) | same |
| anything else | `ProtocolError`, treated as a drop |

Completing an `Ack`: under the mutex shift it off `@pending`, then send
`nil` on its waiter if it has one. A confirmation with an empty `@pending`
is a desync → `ProtocolError`.

`@messages.send` blocks when the channel is full. That stalls the reader,
which stalls the socket, which stalls the server's output buffer: the
intended backpressure. The server's `client-output-buffer-limit pubsub`
may then disconnect the client; that shows up as a drop and reconnect.

### 2.4 Drop, reconnect, resubscribe

Any exception in the reader loop (`IO::Error`, `ProtocolError`,
`Channel::ClosedError` from `@messages` after `close`) is a drop:

1. Under the mutex: if `@closed`, exit the fiber. Otherwise set
   `@error`, set `@connection = nil`, close the socket, drain `@pending`
   and fail every waiter with `ConnectionError("connection lost: ...",
   cause:)`.
2. Call `on_disconnect` with the cause (outside the mutex, on the reader
   fiber).
3. If `reconnect` is false: close `@messages`, mark `@closed`, exit.
4. Backoff loop: sleep `delay` via `select` over `@close_signal.receive`
   and `timeout(delay)`; a close ends the fiber. Try `Connection.new`
   with the original options. On failure double `delay` (start 100 ms, cap
   5 s) and loop. On success reset `delay`.
5. Under the mutex: if `@closed` meanwhile, close the new connection and
   exit. Set `@connection`. If the desired channel set is non-empty send
   one `SUBSCRIBE` with all of them and push an `Ack` with no waiter;
   same for patterns with `PSUBSCRIBE`. Clear `@error`.
6. Call `on_reconnect`, then continue the read loop on the new connection.

A caller's `subscribe` that raced with the drop raises `ConnectionError`
but its names are already in the desired set, so they come back with the
resubscribe. The doc comment says so.

### 2.5 Close and receive

`close`: under the mutex set `@closed`, take `@connection` and set it nil,
close `@close_signal`; outside the mutex close the socket (the reader's
read raises and the fiber exits via step 1), fail pending waiters, and
close `@messages`. Idempotent.

`receive` is `@messages.receive` with `Channel::ClosedError` mapped to
`ConnectionError("subscriber is closed")`. `receive?` maps it to nil.
`each` loops on `receive?`. Messages already buffered in the channel
before `close` are still delivered by `receive?` until the channel is
empty, matching `Channel` semantics.

Hooks run on the reader fiber. An exception raised by one closes the
subscriber (as `close` does, with `error` set to that exception): there
is no caller to report it to, and silently swallowing it would hide a bug.
Documented.

## 3. Transactions (`src/redis/transaction.cr`)

### 3.1 Transaction

```crystal
class Redis::Transaction < Redis::Pipeline
  def multi(&) : NoReturn      # raises ArgumentError: nested MULTI is not allowed
end
```

A `Transaction` records commands exactly like a `Pipeline` (same buffer,
same `Future(T)` per typed method, same `run` rules from section 4). It is
only ever created by `Pipeline#multi`.

### 3.2 `Pipeline#multi`

```crystal
class Redis::Pipeline
  def multi(& : Transaction ->) : Future(Array(Value))
end
```

1. Create a `Transaction` sharing the pipeline's known-script set and
   yield it. If it queued nothing, append nothing and return a future
   already resolved to `[] of Value`; `size` does not change.
2. Append to the pipeline buffer, in order: `MULTI`, the transaction's
   buffer, `EXEC`. Register one future per wire command, so `size` grows
   by `tx.size + 2`:
   - `MULTI` → a `Future(Nil)` that discards its reply.
   - each queued command → a `QueuedFuture` wrapping the corresponding
     transaction future. On `resolve` it ignores `"QUEUED"`; on a
     `CommandError` (a queue-time rejection such as wrong arity) it
     resolves the wrapped future with that error, so `Future#value` for
     that command raises the specific error rather than `EXECABORT`.
   - `EXEC` → an `ExecFuture` holding the transaction's futures. On
     `resolve`:
     - `Array` → resolve future *i* with element *i*. A size mismatch
       resolves every future with `ProtocolError`.
     - `nil` → resolve every future with `AbortedError`.
     - `Exception` (`CommandError` `EXECABORT`, `ConnectionError`,
       `IO::TimeoutError`) → resolve every future *not already resolved*
       (the queue-time failures keep their own error) with it.
   The `ExecFuture` is what `multi` returns, typed `Future(Array(Value))`;
   its `value` raises `AbortedError` on nil and the `EXEC` error otherwise.
3. Runtime errors inside the `EXEC` array stay `CommandError` values, the
   same rule as pipelines: the array returned by `multi`'s future contains
   them, and only the corresponding transaction future raises.

`Client#pipelined` still returns every raw reply in wire order, so a
pipeline that contains a `multi` returns the `"OK"`, the `"QUEUED"`s and
the `EXEC` array as separate elements. The doc comment says so and points
at the transaction's own futures for the results that matter.

`Pipeline#resolve(index, raw)` is unchanged: the fan-out lives entirely in
`ExecFuture#resolve`, so the client's indexing stays flat.

### 3.3 `Client#multi` and `Connection#multi`

```crystal
class Redis::Client
  def multi(& : Transaction ->) : Array(Value)
end

class Redis::Connection
  def pipelined(& : Pipeline ->) : Array(Value)    # NEW, mirrors Client#pipelined
  def multi(& : Transaction ->) : Array(Value)
end
```

`Client#multi` is `exec = nil; pipelined { |p| exec = p.multi(&block) };
exec.not_nil!.value`. Because `pipelined` appends the whole
`MULTI`..`EXEC` byte range in one critical section, another fiber's
commands can never land between a transaction's `MULTI` and `EXEC` on the
shared connection. A block that queues nothing returns `[] of Value`
without touching the connection (the pipeline stays empty, see 3.2, and
`pipelined` returns early on an empty pipeline).

`Connection#pipelined` writes `pipeline.buffer`, flushes once, reads
`pipeline.size` replies with error replies kept as values, resolves every
future in order, and returns the raw replies. Error handling follows
`Connection#pipeline`: `IO::TimeoutError` and `ProtocolError` close the
connection and propagate, `IO::Error` becomes `ConnectionError`; in every
failure case the futures not yet resolved are resolved with the exception
first. `Connection#multi` is built on it exactly like `Client#multi`.

### 3.4 `WATCH`

```crystal
class Redis::Connection
  def watch(*keys : String) : Nil      # raises ArgumentError on no keys
  def unwatch : Nil
end

class Redis::Client
  def watch(*keys : String, & : Connection -> T) : T forall T
end
```

`Client#watch` opens a new `Connection` with the client's URL and every
option including `db` and `read_timeout`, calls `conn.watch(*keys)`,
yields the connection, and closes it in an `ensure`. It returns whatever
the block returns and raises whatever it raises; `AbortedError` from an
inner `multi` is the signal to retry. No `UNWATCH` is needed because the
connection is closed. `watch` and `unwatch` are defined on `Connection`
only, not in `Commands`, so they cannot be called on a `Client` or inside
a pipeline by accident.

The one-connection-per-`watch` cost is a TCP connect plus handshake. It is
acceptable for this slice; slice 3's `Pool` will let `watch` borrow
instead.

## 4. Scripts (`src/redis/script.cr`)

```crystal
struct Redis::Script
  getter source : String
  getter sha : String                              # lowercase hex SHA1 of source
  def initialize(@source : String)
  def load(redis : Client | Connection) : String   # SCRIPT LOAD; returns sha
end

module Redis::Commands
  def run(script : Script, *, keys : Indexable(String) = [] of String, args : Indexable = [] of RESP::Arg)
end
```

`args` is an unrestricted `Indexable` on purpose: a Crystal array literal
does not adopt a union restriction, so `args: [5]` would not compile
against `Array(RESP::Arg)`. Each element must still be a `RESP::Arg`
member, which the encoder enforces at compile time.

`sha` is computed in `initialize` with `Digest::SHA1.hexdigest(source)`
(stdlib, no new dependency). Redis computes the same digest, so the
client knows the cache key without a round trip.

`run` on `Client` and `Connection`: send `EVALSHA sha n keys args`. On a
`CommandError` with `code == "NOSCRIPT"`, send `EVAL source n keys args`
instead; `EVAL` also loads the script server-side. Any other error is
raised as is. On success add `sha` to the includer's known-script set.
`Script#load` calls `script_load` and adds the SHA too.

`run` on `Pipeline` (and so `Transaction`): a pipeline cannot fall back
mid-flight, so it sends `EVALSHA` when `sha` is in the known set and
`EVAL` otherwise. Its future is a `ScriptFuture` that, when resolved with
a `NOSCRIPT` error, removes `sha` from the set, so the next pipeline goes
back to `EVAL`. A `SCRIPT FLUSH` or server restart therefore costs one
failed pipelined call per script, surfaced on that future, and heals
itself.

The known-script set is `Set(String)` on `Client` (guarded by the client
mutex; `Pipeline.new` receives it and reads it without the lock, which is
safe because a stale read only costs one fallback) and on `Connection`
(single-fiber by contract). `Connection.new` and `Client.new` start empty;
the client's set survives reconnects because a reconnect does not imply
the server restarted, and the healing rule above covers the case where it
did.

## 5. Commands additions

- `commands/pubsub.cr`: `def_command publish, "PUBLISH", channel : String, message : String, cast: :int`.
  `PUBLISH` is an ordinary command and belongs on the multiplexed client.
- `commands.cr`: `run` as above. `def_command` is unchanged.

## 6. Errors (`src/redis/error.cr`)

```crystal
class Redis::AbortedError < Redis::Error; end   # EXEC replied nil: a watched key changed
```

No other error class changes. `CommandError#code` already exposes
`NOSCRIPT` and `EXECABORT`.

## 7. Testing

All under `spec/std/redis/`, using `spec/support/redis.cr`.

1. **Subscriber** (`subscriber_spec.cr`, fake server, no live server): a
   scripted server that answers `HELLO` per a protocol switch (RESP3 push
   frames or RESP2 arrays) and confirms `SUBSCRIBE`/`PSUBSCRIBE`/
   `UNSUBSCRIBE`/`PUNSUBSCRIBE`/`PING` frame-for-frame, plus a side
   channel the spec uses to inject `message`/`pmessage` frames. Examples,
   each run for both protocols via a macro like the live suite:
   `subscribe` returns only after the confirmation frames (the server
   delays them and the spec checks `subscribe` had not returned);
   `message` and `pmessage` delivery with the right `pattern`;
   `unsubscribe` with names and with none (count from the desired set,
   and the nil-channel single frame); `ping`; a `capacity: 1` subscriber
   with 20 injected messages receives all 20 in order; a server that
   closes the socket → `on_disconnect` fires, the server sees a second
   connection whose first commands are `SUBSCRIBE` with every desired
   channel then `PSUBSCRIBE`, `on_reconnect` fires, and a message on the
   new connection is delivered; `subscribe` called while disconnected is
   recorded and appears in the resubscribe; `close` during backoff
   returns within 100 ms; `reconnect: false` closes the channel and sets
   `error`; an unknown frame → `ProtocolError` drop and reconnect;
   `read_timeout` on a `subscribe` the server never confirms;
   `receive?` after `close` returns buffered messages then nil.
2. **Transactions** (`transaction_spec.cr`, fake server): the wire bytes
   for a `multi` arrive as one chunk `MULTI`, commands, `EXEC`; futures
   resolve from the `EXEC` array and `multi` returns it; `pipelined`
   containing a `multi` returns `"OK"`, `"QUEUED"`s and the array;
   `EXECABORT` raised by `multi` and by every future; a queue-time error
   on the second command is raised by that future while the first raises
   `EXECABORT`; nil `EXEC` raises `AbortedError`; a runtime error inside
   the array stays a value and only its future raises; size mismatch →
   `ProtocolError`; nested `multi` raises `ArgumentError`; empty block
   sends nothing; `Connection#pipelined` and `Connection#multi` produce
   the same bytes and results; `Client#watch` opens a second connection
   (`accepted == 2`), sends `WATCH` before yielding, and closes it after
   the block and after an exception; `watch` with no keys raises
   `ArgumentError`.
3. **Scripts** (`script_spec.cr`): `sha` equals a known SHA1 for
   `"return 1"`; `run` sends `EVALSHA` first and `EVAL` after a
   `NOSCRIPT` reply, then `EVALSHA` again on the next call; a non-`NOSCRIPT`
   error is raised without fallback; `load` sends `SCRIPT LOAD`;
   a pipeline sends `EVAL` for an unknown SHA and `EVALSHA` for a known
   one; a pipelined `NOSCRIPT` clears the hint so the next pipeline sends
   `EVAL`.
4. **Live** (`live_spec.cr`, pending without a server, both protocols):
   `subscriber` + `publish` round trip on a channel and a pattern;
   `unsubscribe` stops delivery; `multi` with `set`/`incr`/`get` returns
   the right values; `watch` where a second client changes the key
   between the read and the `multi` raises `AbortedError`, and the retry
   loop from section 1 converges; `run` on a script the server has never
   seen, then again, then after `script_flush`; a pipelined `run` after
   `script_flush` surfaces `NOSCRIPT` on the future and the next pipeline
   succeeds.

`spec/support/redis.cr` gains helpers to build pub/sub frames in either
protocol so the fake-server specs do not hand-write `>3\r\n` byte strings
in twenty places.

## 8. Benchmarks

Same harness directory and discipline as slice 1
(`.remember/harness-2026-09-19/redis/`, gitignored), against Valkey on
loopback with redis-rs and go-redis as baselines:

- Publish-to-receive latency: one publisher, one subscriber, 10k
  sequential round trips, median and p99.
- Subscriber throughput: 64 channels, a publisher pipelining 1M messages,
  messages per second received.
- `multi` with 10 `INCR`s, 10k iterations, versus the same 10 commands in
  a plain pipeline: the transaction overhead in the client must be within
  a few percent of the plain pipeline; the rest is the server.
- `run` sequential 100k calls versus `evalsha` by hand: the script path
  must add no measurable cost over a direct `EVALSHA`.

Results and rejected variants go into the harness README and the memory
file, as before.

## 9. Out of scope for slice 2

Cluster slot routing with `MOVED`/`ASK`, `Pool` (and `watch` borrowing
from it), sharded pub/sub (`SSUBSCRIBE`), keyspace notifications helpers,
`CLIENT TRACKING`, streams, Sentinel, `DISCARD`-style imperative
transaction building (`multi`/`exec` as separate calls), automatic retry
of aborted transactions, and pub/sub over the multiplexed RESP3
connection.
