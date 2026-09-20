# `Redis` client design (Tier 3b, slice 3: cluster routing and pool)

Date: 2026-09-20. Builds on the slice 1 spec
(`2026-09-19-redis-client-design.md`, master `c589b000f`) and the slice 2
spec (`2026-09-20-redis-slice2-design.md`, master `3c56f2e5c`).

## Goal

Make the client usable against Redis Cluster and give blocking commands a
home, without changing any slice 1 or slice 2 public signature:

1. **Cluster** — `Redis::Cluster`, a router over one multiplexed `Client`
   per master, that hashes keys to slots, follows `MOVED`/`ASK`/`TRYAGAIN`,
   reloads the topology when it changes, and splits pipelines by node.
2. **Pool** — `Redis::Pool`, a bounded pool of `Connection`s for blocking
   commands and `WATCH`; `Client#with_connection` borrows from a pool the
   client owns, and `Client#watch` now borrows instead of connecting.
3. **Folded in** — `Connection` maps `OpenSSL::SSL::Error` into
   `ConnectionError` alongside `IO::Error` (deferred from slice 1).

Decisions taken in the brainstorm and not to be reopened:

- The routing key is found client-side from a static table, never from the
  server's `COMMAND` output: typed commands carry their key at wire
  position 1 (verified for all ~85 of them), a hand-written list covers
  the shapes that do not, and the raw escape hatch defaults to position 1
  with an explicit `key:` override. No extra round trip, ever.
- A cluster pipeline is split by node, run concurrently, and reassembled
  in the caller's order. `multi` and `watch` stay on one slot; the server's
  `CROSSSLOT` error is surfaced, not pre-empted.
- The pool holds `Connection`s, not `Client`s. One multiplexed socket
  already outperforms the baselines; the pool exists for commands that
  need a socket to themselves.
- `Client` owns a lazily built pool for `with_connection` and `watch`.
- Live cluster specs spawn three Valkey/Redis nodes themselves and are
  pending when no server binary is on `PATH`; `REDIS_CLUSTER_URL` points
  them at an existing cluster instead.
- A lost connection is still never retried (slice 1). Only the cluster's
  own redirect replies are retried, and only up to `max_redirects`.
- Out of scope: replica reads (`READONLY`), sharded pub/sub, Sentinel,
  client-side caching, streams, aggregating keyless commands across nodes.

Verified against Valkey 9.1.2 before writing this (spike in the session
scratchpad): `CLUSTER SLOTS` reports concrete `127.0.0.1` hosts for nodes
met over loopback; `-MOVED 8338 127.0.0.1:7101` and `-ASK 8338
127.0.0.1:7102` are simple error frames; `ASKING` immediately followed by
the command on the target answers the command; a multi-key command whose
keys straddle a migrating slot answers `-TRYAGAIN`; three fresh nodes
converge to `cluster_state:ok` in about 1.4 s.

## 1. Public surface

```crystal
require "redis"

cluster = Redis::Cluster.new(["redis://127.0.0.1:7100", "redis://127.0.0.1:7101"],
  password: nil, max_redirects: 5)                  # every Client option except db
cluster.set("user:1", "x")                          # routed by key slot
cluster.get("user:1")                               # => "x"
cluster.pipelined { |p| p.get("a"); p.get("b") }    # split by node, replies in order
cluster.multi { |tx| tx.incr("{acct}a"); tx.incr("{acct}b") }   # one slot
cluster.command("MYMODULE.DO", "k", key: "k")       # explicit route for the escape hatch
cluster.with_connection("jobs") { |conn| conn.call("BLPOP", "jobs", 0) }
cluster.watch("balance") { |conn| ... }             # optimistic locking on the slot's master
cluster.publish("news", "hi"); sub = cluster.subscriber
cluster.nodes                                       # => Array(Redis::Cluster::Node)
cluster.refresh                                     # reload the slot map now
cluster.close

Redis::Cluster.key_slot("{user1000}.following")     # => 3443

pool = Redis::Pool.new("redis://localhost:6379", size: 8, checkout_timeout: 5.seconds)
pool.checkout { |conn| conn.call("BLPOP", "jobs", 0) }
pool.close

redis = Redis::Client.new("redis://localhost:6379", pool_size: 4)
redis.with_connection { |conn| conn.call("BLPOP", "jobs", 0) }   # from the client's pool
redis.watch("balance") { |conn| ... }                           # borrows from the same pool
```

### 1.1 Files

```
src/redis.cr                     # + requires, doc update
src/redis/crc16.cr               # NEW: CRC16-XMODEM table and function
src/redis/cluster.cr             # NEW: Cluster, Node, routing table, redirect loop
src/redis/pool.cr                # NEW: Pool
src/redis/error.cr               # + ClusterError, PoolTimeoutError
src/redis/pipeline.cr            # + routing mode: route keys and byte offsets per command
src/redis/transaction.cr         # + routing flag passed through
src/redis/client.cr              # + pool_size, with_connection, watch via pool, raw send hooks
src/redis/connection.cr          # + watching?, SSL error mapping
spec/std/redis/crc16_spec.cr
spec/std/redis/cluster_spec.cr   # fake nodes
spec/std/redis/pool_spec.cr
spec/std/redis/cluster_live_spec.cr
spec/std/redis/client_spec.cr    # + with_connection and pooled watch
spec/support/redis.cr            # + fake cluster helpers, LiveCluster, pending_cluster
```

## 2. Key slots (`src/redis/crc16.cr`, `src/redis/cluster.cr`)

```crystal
module Redis::CRC16
  def self.checksum(data : Bytes) : UInt16     # CRC16-XMODEM: poly 0x1021, init 0, no reflection, no xorout
end

class Redis::Cluster
  SLOTS = 16384
  def self.key_slot(key : String) : Int32        # CRC16 of the hash tag (or the whole key) % SLOTS
  def self.route_key(args : Indexable) : String? # the key a command is routed by, nil for keyless
end
```

`checksum` is a 256-entry table lookup, one byte per step (`"123456789"`
→ `0x31C3`). The stdlib has no CRC16; this one is private to Redis in
spirit but public in API so the live specs can compare it with
`CLUSTER KEYSLOT`.

`key_slot` follows the cluster spec's hash-tag rule: the first `{` and
the first `}` after it delimit the tag when at least one byte lies
between them; otherwise the whole key is hashed. Pinned cases:
`{user1000}.following` and `{user1000}.followers` share a slot;
`foo{}{bar}` hashes the whole key; `foo{{bar}}zap` hashes `{bar`;
`foo{bar}{zap}` hashes `bar`.

`route_key(args)`:

1. `args[0]` must be a `String`, else nil. The name is matched
   case-insensitively; an already-uppercase name (every typed command)
   is matched without allocating.
2. A name in `KEYLESS` → nil. The set: `ACL ASKING AUTH BGREWRITEAOF
   BGSAVE CLIENT CLUSTER COMMAND CONFIG DBSIZE DEBUG DISCARD ECHO EXEC
   FLUSHALL FLUSHDB FUNCTION HELLO INFO KEYS LASTSAVE LATENCY LOLWUT
   MODULE MONITOR MULTI PING PSUBSCRIBE PUBLISH PUBSUB PUNSUBSCRIBE QUIT
   RANDOMKEY READONLY READWRITE REPLICAOF RESET ROLE SAVE SCAN SCRIPT
   SELECT SHUTDOWN SLOWLOG SUBSCRIBE SWAPDB TIME UNSUBSCRIBE UNWATCH
   WAIT`.
3. A name in `SPECIAL` → its rule:
   - after a key count: `EVAL EVALSHA EVAL_RO EVALSHA_RO FCALL FCALL_RO`
     (count at 2, first key at 3), `LMPOP ZMPOP SINTERCARD ZINTERCARD
     ZUNION ZINTER ZDIFF` (count at 1, first key at 2), `BLMPOP BZMPOP`
     (count at 2, first key at 3). A count of 0 → nil.
   - after the word `STREAMS`: `XREAD XREADGROUP`.
   - fixed position 2: `OBJECT XINFO XGROUP BITOP`, and `MEMORY` only when
     `args[1]` is `USAGE` (any other `MEMORY` subcommand is keyless).
4. Otherwise `args[1]` if it is a `String`, else nil.

`route_key` never raises: a malformed command is routed to a random
master and the server's error reply comes back as it would on a single
node.

## 3. Cluster (`src/redis/cluster.cr`)

```crystal
class Redis::Cluster
  include Commands
  include Commands::ScriptFallback

  class Node
    getter host : String
    getter port : Int32
    getter id : String
    getter? master : Bool
    def address : String                 # "host:port"
    def client : Client                  # the node's multiplexed client; raises ArgumentError on a replica
  end

  def initialize(seeds : Indexable(String | URI), *,
                 username : String? = nil, password : String? = nil, client_name : String? = nil,
                 protocol : Int32 = 3, connect_timeout : Time::Span = 5.seconds,
                 read_timeout : Time::Span? = nil, tls_context : OpenSSL::SSL::Context::Client? = nil,
                 max_bulk_size : Int32 = RESP::MAX_BULK_SIZE, pool_size : Int32 = 4,
                 max_redirects : Int32 = 5)
  def self.new(seed : String | URI, **options)          # one seed

  def call(*args : RESP::Arg) : Value
  def call(args : Indexable, *, key : String? = nil) : Value
  def command(*args : RESP::Arg, key : String)          # explicit route; the keyless form is Commands#command
  def pipelined(& : Pipeline ->) : Array(Value)
  def multi(& : Transaction ->) : Array(Value)
  def watch(*keys : String, & : Connection -> T) : T forall T
  def with_connection(key : String, & : Connection -> T) : T forall T
  def subscriber(*, capacity : Int32 = 64, reconnect : Bool = true) : Subscriber
  def nodes : Array(Node)                               # snapshot, masters first
  def refresh : Nil
  def close : Nil
  def closed? : Bool
end
```

Every option except `max_redirects` and `pool_size` is stored and handed
to each node's `Client` unchanged; `pool_size` goes to the node clients
too (for `with_connection` and `watch`). Seeds must use the `redis` or
`rediss` scheme (a Unix socket cannot address a cluster) and carry no
database other than 0 (a cluster has only database 0); either raises
`ArgumentError`. The seeds' scheme (and `tls_context`) is used for every
node discovered later, so a `rediss` seed makes every node connection
TLS. Nothing is connected until the first command.

### 3.1 State

- `@mutex : Mutex` guarding the fields below.
- `@slots : Array(Node?)` of `SLOTS` entries.
- `@nodes : Hash(String, Node)` by address, masters and replicas.
- `@masters : Array(Node)`, the routing candidates for keyless commands.
- `@stale : Bool`, true at construction and after any `MOVED` or
  `ConnectionError`.
- `@refresh_mutex : Mutex`, held for the duration of a topology load.
- `@seeds : Array(URI)`, `@closed : Bool`, `@script_cache : ScriptCache`.

`Node#client` is created on first use under the cluster's mutex with the
stored options. A `Node` never changes identity: a reload that finds an
address it already knows keeps that `Node` (and its client and its
in-flight commands).

### 3.2 Topology

`refresh` (public) always loads; `refresh_if_stale` (private, called
before every routing decision) is
`@refresh_mutex.synchronize { load if @stale }`, so concurrent callers
that all saw `MOVED` wait for the one load in progress and then skip
theirs. A load:

1. Candidates in order: every known master, then every seed (a seed that
   is already a known master is not tried twice). Each candidate gets one
   `CLUSTER SLOTS` call; a `ConnectionError` or `CommandError` moves on to
   the next. If none answers, raise `ClusterError("no cluster node
   reachable")` with the last error as cause; `@stale` stays true.
2. Parse the reply: each entry is `[start, end, master, replica...]`
   where a node is `[host, port, id, ...]`. An empty or nil host means
   "the address you asked" and is replaced with the candidate's host.
   Build the new `@nodes` reusing existing `Node` objects by address,
   fill a fresh `@slots`, compute `@masters`.
3. Under `@mutex` swap the three in, clear `@stale`, and collect nodes
   that disappeared. Close those nodes' clients outside the mutex.

A reply with no slot ranges is accepted (an unconfigured cluster);
routing then answers with the server's own `CLUSTERDOWN` error.

### 3.3 Command execution

```
call(args, key:):
  check_open
  route = key || Cluster.route_key(args)
  slot  = route ? Cluster.key_slot(route) : nil
  execute(slot) { |node, asking| asking ? ask(node, args) : node.client.call(args) }
```

`execute(slot, &send : Node, Bool -> Value)` is the redirect loop, shared
by `call`, `typed_call` and pipeline retries:

1. `refresh_if_stale`. Pick the node: `@slots[slot]` when `slot` is set
   and assigned, otherwise a random master (`ClusterError("cluster has no
   masters")` if there are none).
2. Loop at most `max_redirects + 1` times. Call `send` with the node and
   the `asking` flag. Return its value. On `CommandError`, by `code`:
   - `MOVED slot host:port` → look up or create the node for that
     address, set `@slots[slot]` to it under the mutex, set `@stale`,
     clear `asking`, continue with that node.
   - `ASK slot host:port` → look up or create the node, set `asking`,
     continue. The slot map is not touched.
   - `TRYAGAIN` → `sleep` 10 ms doubling per attempt, capped at 500 ms,
     continue with the same node and flag.
   - anything else → raise.
   On `ConnectionError` → set `@stale` and raise (no retry, slice 1 rule).
3. After the loop raise `ClusterError("too many redirects for slot N")`
   with the last redirect error as cause.

`ask(node, args)` sends `ASKING` and the command contiguously through the
node client's `pipelined` (so no other fiber's command can land between
them on the shared socket), returns the second raw reply, and raises it
if it is a `CommandError` so the loop can handle a further redirect.
`typed_call(args, &block)` is `block.call(call(args))`, so every typed
command on a `Cluster` returns `T` exactly as on `Client`.

`run` works through `ScriptFallback` with one cluster-wide `ScriptCache`.
A script known to one node and not to another surfaces `NOSCRIPT` there,
which the fallback handles (`call`) or the pipeline heals (`ScriptFuture`
forgets the SHA); documented on `Cluster#run`.

### 3.4 Pipelines and transactions

`Pipeline.new(script_cache, routing : Bool = false)`. In routing mode
`typed_call`, `script_run` and `multi` also record, per wire command, a
`Route` (`key : String?`, `retry : Bool`) and the byte offset of the
command in `buffer`. Outside routing mode they record nothing, so
`Client#pipelined` and `Connection#pipelined` pay one predictable branch.
`Pipeline#multi` records the `MULTI`, every queued command and the `EXEC`
with the transaction's first non-nil route key and `retry: false`, so the
whole transaction goes to one node and is never re-issued piecemeal. The
`Transaction` created by `multi` inherits the routing flag.

`Cluster#pipelined`:

1. `Pipeline.new(@script_cache, routing: true)`, yield, `check_open`,
   return `[] of Value` when empty. `refresh_if_stale`.
2. Group command indices by node in first-seen order: the node for a
   command is `@slots[key_slot(route.key)]` or, for a nil key, one random
   master chosen once for the whole pipeline.
3. For each group build the wire bytes by copying the byte ranges of its
   commands out of `pipeline.buffer` (no re-encoding) and run
   `node.client.pipeline_raw(bytes, count)`, storing each yielded reply
   or failure at the command's original index. Groups run concurrently,
   one fiber per group beyond the first (which runs on the caller),
   joined with a `WaitGroup`. A `ConnectionError` or `IO::TimeoutError`
   from any group sets `@stale`; after every group has finished, every
   future is resolved with its stored reply or failure, and the first
   failure is raised (a group that succeeded keeps its values).
4. Scatter replies back to the caller's order. A reply that is a
   `CommandError` with code `MOVED`, `ASK` or `TRYAGAIN` for a command
   whose route is retryable is re-issued through `execute(slot) { |node,
   asking| node.client.call_raw(bytes, asking) }` with that command's
   bytes, and the result (value or raised error, kept as a value)
   replaces it. A non-retryable command (inside a `multi`) keeps its
   reply; on a cluster a transaction hitting `MOVED` at queue time fails
   with `EXECABORT` like any other queue-time error.
5. Resolve every future in order and return the raw replies. (Step 4
   runs before this one, so a retried command's future gets the retry's
   result.)

`Cluster#multi` is `exec = nil; pipelined { |p| exec = p.multi(&block) };
exec.not_nil!.value`, one flush on one node.

`Client#pipeline_raw(bytes : Bytes, count : Int32, & : Int32, Value |
Exception ->) : Nil` and `Client#call_raw(bytes : Bytes, asking : Bool) :
Value` are `:nodoc:` hooks. The first appends pre-encoded bytes and
registers `count` waiters in one critical section exactly as `pipelined`
does, yields each reply with its index as it arrives, yields the failure
for every reply that will never arrive, and then raises that failure; the
existing `Client#pipelined` is refactored onto it. The second appends
`ASKING` plus the bytes when *asking* is set (the bytes alone otherwise)
and returns the command's reply, raising a `CommandError` reply so the
redirect loop can act on it.

### 3.5 Blocking commands, watch, pub/sub

`with_connection(key, &)` routes the slot's master and calls that node
client's `with_connection` (section 4.2). `watch(*keys, &)` requires at
least one key (`ArgumentError`) and that all keys hash to one slot
(`ArgumentError("WATCH keys must hash to one slot")`), then calls the
master's `Client#watch`. A `MOVED` or `ASK` inside either block is not
followed (the block owns a plain `Connection`) and surfaces as
`CommandError`; the doc comment says to retry the whole block.

`publish` is keyless and lands on a random master; the cluster bus
delivers it to subscribers on every node. `subscriber` opens a
`Subscriber` on one random master's URL (built from the seeds' scheme)
with the cluster's options; its reconnects go back to that node.

### 3.6 Close

`close` sets `@closed` under the mutex, then closes every node client
outside it. Every later call raises `ConnectionError("cluster is
closed")` through `check_open`.

## 4. Pool (`src/redis/pool.cr`)

```crystal
class Redis::Pool
  def initialize(url : String | URI = Connection::DEFAULT_URL, *,
                 size : Int32 = 8, checkout_timeout : Time::Span = 5.seconds,
                 db : Int32? = nil, username : String? = nil, password : String? = nil,
                 client_name : String? = nil, protocol : Int32 = 3,
                 connect_timeout : Time::Span = 5.seconds, read_timeout : Time::Span? = nil,
                 tls_context : OpenSSL::SSL::Context::Client? = nil, max_bulk_size : Int32 = RESP::MAX_BULK_SIZE)
  getter size : Int32                     # the bound
  def idle : Int32                        # open connections waiting in the pool
  def in_use : Int32                      # connections currently checked out
  def checkout : Connection
  def checkin(connection : Connection) : Nil
  def checkout(& : Connection -> T) : T forall T
  def close : Nil
  def closed? : Bool
end
```

`size` must be positive (`ArgumentError`). Connections are created
lazily. State: `@permits : Channel(Nil)` with capacity `size`, filled
with `size` tokens at construction; `@idle : Deque(Connection)`;
`@in_use : Int32`; `@closed`; all but the channel under `@mutex`.

`checkout`: raise `ConnectionError("pool is closed")` if closed. Take a
permit with `select` over `@permits.receive` and
`timeout(checkout_timeout)`; on timeout raise `PoolTimeoutError`. Under
the mutex pop an idle connection; if none, leave the mutex and open a
`Connection` with the stored options (on failure return the permit and
raise). Increment `in_use`. A connection that is popped already closed
(a previous user's failure closed it) is dropped and a fresh one opened.

`checkin`: decrement `in_use`. If the connection is closed, or the pool
is closed (close the connection then), drop it; otherwise push it to
`@idle`. Return the permit. Checking in a connection twice, or one the
pool never handed out, is not detected (the doc says so; a `Set` of
outstanding connections is not worth a hash per checkout).

`checkout(&)`: checkout, yield, `checkin` in an `ensure`. A block that
raises does **not** discard the connection: `Connection` closes itself
on every I/O, protocol or timeout failure, and a `CommandError` (for
example `WRONGTYPE`, or an `AbortedError` from `multi`) leaves the
connection healthy. The one way to hand back a desynchronised connection
is to `send` without `read` and then leave the block; the doc comment
tells such callers to `close` the connection before leaving.

`close`: mark closed, close every idle connection; connections in use are
closed by `checkin` when they return. Idempotent.

No health check on checkout. A socket the server dropped while idle
surfaces as `ConnectionError` on its first use, the same as a `Client`'s
lazy reconnect; the caller retries the checkout. Idle connections are
never reaped.

### 4.1 `Connection#watching?`

`Connection#watch` sets `@watching = true`; `unwatch` clears it; a
`multi` on the connection clears it once the `EXEC` reply (any reply:
array, nil, or `EXECABORT`) has been read, because `EXEC` always
discards the watch server-side. `watching?` exposes it. Used by
`Client#watch` to skip a needless `UNWATCH` round trip.

### 4.2 `Client#with_connection` and pooled `watch`

`Client.new` gains `pool_size : Int32 = 4`. The client builds its `Pool`
on the first `with_connection` (under the client's mutex, from the
client's URL and every option including `db` and `read_timeout`) and
closes it in `close`.

`with_connection(&)` is `pool.checkout(&block)`. The doc comment says the
connections carry the client's `read_timeout`, so a blocking command that
may outlast it needs a client created with `read_timeout: nil` or a
`Connection` of its own.

`watch(*keys, &)` becomes:

```
with_connection do |conn|
  conn.watch(*keys)
  begin
    block.call(conn)
  ensure
    conn.unwatch if conn.watching? && !conn.closed?
  end
end
```

so a block that returns or raises between `WATCH` and `EXEC` cannot leak
watched keys to the connection's next borrower, while a block whose
`multi` ran pays no extra round trip. The zero-key overload still raises
`ArgumentError`.

## 5. Connection: TLS errors

`Connection#send`, `#read`, `#pipeline` and `#pipelined` rescue
`IO::Error | OpenSSL::SSL::Error` where they rescued `IO::Error`, and
`connection_error` accepts either. Behaviour on plain TCP is unchanged.

## 6. Errors (`src/redis/error.cr`)

```crystal
class Redis::ClusterError < Redis::Error; end       # no reachable node, too many redirects, no masters
class Redis::PoolTimeoutError < Redis::Error; end   # checkout_timeout elapsed
```

`CommandError#code` already exposes `MOVED`, `ASK`, `TRYAGAIN`,
`CROSSSLOT` and `CLUSTERDOWN`.

## 7. Testing

All under `spec/std/redis/`, using `spec/support/redis.cr`.

1. **CRC16 and slots** (`crc16_spec.cr`): `checksum("123456789") ==
   0x31C3`, empty input, the four hash-tag cases from section 2, and
   `route_key` for a representative sample: `GET`, `MSET`, `SMOVE`,
   `EVAL` with 0 and 2 keys, `XREAD ... STREAMS k id`, `OBJECT ENCODING
   k`, `MEMORY USAGE k` vs `MEMORY DOCTOR`, `PING`, `PUBLISH`, `ZUNION 2 a
   b`, lowercase `get`, an unknown command, and `command` with `key:`.
2. **Cluster** (`cluster_spec.cr`, fake nodes, no live server). The
   support file gains `FakeCluster`: N `FakeServer`s whose handler
   answers `HELLO`, answers `CLUSTER SLOTS` from a mutable slot map, and
   hands every other command to a per-node block that sees the parsed
   command and the socket. Examples:
   - first command loads the topology from the first reachable seed
     (seed 1 refuses connections, seed 2 answers), and routes `GET a` to
     the node owning `a`'s slot;
   - `MOVED` from node 1 naming node 2 → the command is re-sent to node
     2, the reply is returned, and the next command for that slot goes
     to node 2 directly after one `CLUSTER SLOTS` reload;
   - `ASK` → node 2 sees `ASKING` then the command on the same
     connection, in that order, and the slot map does not change;
   - `TRYAGAIN` twice then success;
   - a node that answers `MOVED` forever → `ClusterError` after
     `max_redirects` attempts, with the `MOVED` error as cause;
   - `ConnectionError` from a node sets stale: the next command reloads;
   - 20 concurrent fibers hitting `MOVED` at once cause exactly one
     `CLUSTER SLOTS` reload (count on the fake);
   - keyless commands (`PING`) go to some master; `DBSIZE` on
     `node.client` goes to that node;
   - `pipelined` with keys on both nodes: each node receives its
     commands in order and one write, the returned array is in caller
     order, every future is resolved; a `MOVED` reply inside the pipeline
     is re-issued to the right node and replaced;
   - `multi` inside a cluster pipeline is contiguous on one node; keys of
     two slots in one `multi` reach the server (the fake answers
     `CROSSSLOT`, which `multi` raises);
   - `with_connection(key)` opens a dedicated connection to the right
     node (`accepted` grows by one); `watch` with keys on two slots raises
     `ArgumentError`;
   - a `db: 1` seed and a `unix://` seed raise `ArgumentError`;
   - `close` closes every node client; a later call raises.
3. **Pool** (`pool_spec.cr`, fake server): connections are lazy
   (`accepted == 0` after `new`); `checkout` twice opens two, checkin
   then checkout reuses (`accepted` stays 2); `size: 1` with a held
   connection → second `checkout` raises `PoolTimeoutError` after
   `checkout_timeout`, and succeeds once the first is checked in;
   a connection closed by the server is dropped on checkin and the next
   checkout opens a new one; a block raising `CommandError` keeps the
   connection (`accepted` unchanged); `close` closes idle connections and
   a later `checkout` raises; 32 fibers × 100 checkouts on `size: 4` never
   exceed 4 accepted connections.
4. **Client** (`client_spec.cr` additions): `with_connection` yields a
   `Connection` distinct from the multiplexed socket (`accepted == 2`
   after one command and one `with_connection`); two sequential `watch`
   blocks open one dedicated connection in total (slice 2 opened one per
   block); a `watch` block that returns
   without `multi` sends `UNWATCH`; one whose `multi` ran does not;
   `close` closes the pool's connections.
5. **Live cluster** (`cluster_live_spec.cr`, `pending_cluster`, protocol
   3 and 2): `key_slot` agrees with `CLUSTER KEYSLOT` for 200 random
   keys with and without hash tags; `set`/`get` on 50 keys spread over
   all three masters; `pipelined` of those 50 `GET`s returns them in
   order; `multi` on `{tag}` keys; `mget` across slots raises
   `CommandError` `CROSSSLOT`; after moving an empty slot with
   `CLUSTER SETSLOT ... NODE` behind the client's back, a `set` on that
   slot follows `MOVED` and succeeds, and `nodes` reflects the reload;
   during a `SETSLOT IMPORTING/MIGRATING` window a `get` of a missing key
   in that slot follows `ASK` and returns nil; `publish` on one node is
   received by a `subscriber`; `with_connection` runs `BLPOP` against a
   list pushed from another fiber; `run` of a fresh script on two
   different slots.

`spec/support/redis.cr` gains `LiveCluster`, built on first use: three
free loopback ports (bind port 0, read the port, close), a temp dir from
`File.tempname`, `valkey-server` or `redis-server` (whichever is on
`PATH`) started with `Process.new` on each port with `--cluster-enabled
yes --save "" --appendonly no --dir <n> --cluster-config-file nodes.conf
--bind 127.0.0.1`, `PING` polled up to 5 s, `CLUSTER ADDSLOTSRANGE` in
three even ranges, `CLUSTER MEET` from the first node, `cluster_state:ok`
polled on all three up to 10 s, and `at_exit` termination plus directory
removal. Any failure (no binary, `ADDSLOTSRANGE` unknown on a pre-7.0
server, no convergence) marks the cluster unavailable and the examples
pending with the reason. `REDIS_CLUSTER_URL` (comma-separated seeds)
skips the spawn. `pending_cluster` mirrors `pending_redis`. Each example
runs `FLUSHALL` on every master first.

## 8. Benchmarks

Same harness directory and discipline as slices 1 and 2
(`.remember/harness-2026-09-19/redis/`, gitignored), against the spawned
three-node Valkey cluster on loopback, with redis-rs (`cluster` feature)
and go-redis `ClusterClient` as baselines:

- Sequential `GET` through `Cluster` versus a plain `Client` to the
  owning node: the routing overhead (slot hash, table lookup, node
  pick) must stay under 0.5 µs per command.
- 64 fibers doing `GET` on keys spread over the three masters, ops/s,
  versus both baselines.
- `pipelined` of 300 `GET`s over three nodes versus 100 `GET`s pipelined
  on one node ×3 by hand: the split and reassembly overhead.
- `Client#watch` round trip via the pool versus slice 2's fresh
  connection: expected at least 2× faster (no connect, no `HELLO`).
- `Pool#checkout`/`checkin` with an idle connection: under 200 ns.

Results and rejected variants go into the harness README and the memory
file, as before.

## 9. Out of scope for slice 3

Replica reads and `READONLY` routing, sharded pub/sub (`SSUBSCRIBE`),
Sentinel discovery, client-side caching (`CLIENT TRACKING`), streams
helpers, fan-out of keyless commands to every node (`nodes` plus
`node.client` is the escape hatch), automatic retry after
`ConnectionError`, pool health pings and idle reaping, and pools of
multiplexed clients.
