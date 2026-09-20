# Redis Client Slice 3 (cluster routing, pool) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `Redis::Cluster` (key-slot routing over one multiplexed `Client` per master, `MOVED`/`ASK`/`TRYAGAIN` handling, topology reload, node-split pipelines) and `Redis::Pool` (bounded pool of `Connection`s, borrowed by `Client#with_connection` and `Client#watch`) to the slice 1+2 client, without changing any existing public signature.

**Architecture:** `Cluster` keeps a 16384-entry slot-to-`Node` array loaded from `CLUSTER SLOTS`, marks it stale on `MOVED`/`ConnectionError`, and reloads it lazily under a refresh mutex so concurrent redirects coalesce. Every command goes through one redirect loop (`execute`) that takes a send block; pipelines split their pre-encoded bytes by node using per-command offsets recorded by `Pipeline` in routing mode, run the groups concurrently, and scatter replies back. `Pool` is a permit channel plus an idle deque; `Client` owns one lazily. The future API is split into `resolve(Value)`/`fail(Exception)` because Crystal cannot pass a `Value | Exception`-typed argument to a restriction of the same union when `Value` contains `CommandError`.

**Tech Stack:** Crystal stdlib only (`socket`, `openssl`, `uri`, `Channel`, `Mutex`, `Deque`, `WaitGroup`, `IO::Memory`, `Process` in specs). Compiler via `bin/crystal`. Live cluster specs spawn `valkey-server`/`redis-server` themselves.

**Spec:** `docs/superpowers/specs/2026-09-20-redis-slice3-design.md` (slice 1: `2026-09-19-redis-client-design.md`, slice 2: `2026-09-20-redis-slice2-design.md`)

## Global Constraints

- Everything lives under `src/redis/` with entry `src/redis.cr`; never required from the prelude; never `require "big"`.
- No slice 1 or slice 2 public signature changes. `Pipeline.new` gains an optional second parameter; `Client.new` gains `pool_size`; `Pipeline#resolve` (`:nodoc:`) narrows to `Value` and gains a sibling `fail`.
- Routing key comes from the static table in `Cluster.route_key`, never from the server's `COMMAND` output.
- A lost connection is never retried; only `MOVED`, `ASK` and `TRYAGAIN` replies are, at most `max_redirects` times.
- The pool holds `Connection`s; a block that raises keeps the connection unless it is closed.
- Every public method gets a third-person doc comment. `bin/crystal tool format src/redis spec/std/redis spec/support/redis.cr` before every commit.
- Always `bin/crystal`, never a global `crystal`. Run one compiler at a time (8 GB machine). Foreground `sleep` in Bash is blocked (Crystal's `sleep` inside specs is fine). Live specs are pending when no server (or no server binary) answers.
- Commit messages are prefixed `Redis: ` and end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- `docs/` is gitignored: `git add -f` for files under it.
- Crystal gotchas that apply here (from the slice 1/2 ledgers): a typed splat cannot be called with zero args (keep the zero-arg overloads); a generic ancestor's implementation of an abstract def is not seen through the non-generic root for a concrete leaf (restate `resolved?`, `resolve`, `fail` on `ScriptFuture`/`ExecFuture`); a variable assigned inside a block is never narrowed afterwards (return tuples out of `synchronize`, collect into arrays); `Array(Value)` must be built with `Array(Redis::Value).new` or `[] of Redis::Value`, never `[x] of Redis::Value` with elements (the recursive alias expands); `alias V = Redis::Value` also expands, always spell `Redis::Value`; `Channel(Nil)#receive?` is always falsy.

## File map

| File | Responsibility |
|------|----------------|
| `src/redis.cr` | module doc + requires (`crc16`, `pool`, `cluster`) |
| `src/redis/crc16.cr` | `CRC16.checksum` (XMODEM table) |
| `src/redis/error.cr` | + `ClusterError`, `PoolTimeoutError` |
| `src/redis/cluster.cr` | `Cluster` (`SLOTS`, `key_slot`, `route_key`, `KEYLESS`, `SPECIAL`; `Node`; topology; `execute`; `call`; `pipelined`; `multi`; `with_connection`; `watch`; `subscriber`; `nodes`; `node_for`; `refresh`; `close`; `scan_each`) |
| `src/redis/pool.cr` | `Pool` |
| `src/redis/pipeline.cr` | future API split; routing mode (`Route`, `routes`, `offsets`, `routing?`) |
| `src/redis/transaction.cr` | future API split on `QueuedFuture`/`ExecFuture` |
| `src/redis/connection.cr` | SSL error mapping; `watching?`; `fail_futures` uses `fail` |
| `src/redis/client.cr` | `pool_size`, `with_connection`, pooled `watch`, `pipeline_raw`, `call_raw`, `pipelined` refactor, `close` closes the pool |
| `spec/support/redis.cr` | + `FakeCluster`, `LiveCluster`, `pending_cluster` |
| `spec/std/redis/crc16_spec.cr` | checksum, `key_slot`, `route_key` |
| `spec/std/redis/pipeline_spec.cr` | + `fail`, routing mode |
| `spec/std/redis/transaction_spec.cr` | `fail` at line 99; pooled `watch` expectations |
| `spec/std/redis/connection_spec.cr` | + `watching?`, TLS failure mapping |
| `spec/std/redis/pool_spec.cr` | pool behaviour |
| `spec/std/redis/client_spec.cr` | + `with_connection`, `call_raw`, `pipeline_raw` |
| `spec/std/redis/cluster_spec.cr` | fake-cluster specs |
| `spec/std/redis/cluster_live_spec.cr` | spawned three-node cluster, protocol 3 and 2 |

Key slots the fake-cluster specs rely on (computed with the XMODEM CRC, two-node split at 8192): `"b"` → 3300 (node 0), `"k"` → 7629 (node 0), `"bar"` → 5061 (node 0), `"a"` → 15495 (node 1), `"x"` → 16287 (node 1), `"y"` → 12222 (node 1), `"{t}a"`/`"{t}b"` → 15891 (node 1), `"{w}a"` → 3696 (node 0). Three-node split at 5461/10922: `"b"`, `"bar"`, `"s2"`, `"news"` on node 0; `"k"`, `"moved-key"` (9688) on node 1; `"a"`, `"x"`, `"{t}a"`, `"{ask}x"` (11420), `"q"` (11958), `"s1"` on node 2.

---

### Task 1: CRC16, `Cluster.key_slot`, `Cluster.route_key`, new errors

**Files:**
- Create: `src/redis/crc16.cr`
- Create: `src/redis/cluster.cr` (class-level helpers only; Task 7 fills the rest)
- Modify: `src/redis/error.cr` (append inside `module Redis`)
- Modify: `src/redis.cr` (requires)
- Test: `spec/std/redis/crc16_spec.cr`

**Interfaces:**
- Produces: `Redis::CRC16.checksum(data : Bytes | String) : UInt16`; `Redis::Cluster::SLOTS = 16384`; `Redis::Cluster.key_slot(key : String) : Int32`; `Redis::Cluster.route_key(args : Indexable) : String?`; `Redis::ClusterError < Redis::Error`; `Redis::PoolTimeoutError < Redis::Error`.

- [ ] **Step 1: Write the failing specs**

`spec/std/redis/crc16_spec.cr`:

```crystal
require "spec"
require "redis"

describe Redis::CRC16 do
  it "matches the XMODEM check value" do
    Redis::CRC16.checksum("123456789").should eq(0x31C3_u16)
    Redis::CRC16.checksum("123456789".to_slice).should eq(0x31C3_u16)
    Redis::CRC16.checksum("").should eq(0_u16)
    Redis::CRC16.checksum(Bytes.empty).should eq(0_u16)
  end
end

describe "Redis::Cluster.key_slot" do
  it "hashes the whole key when there is no tag" do
    Redis::Cluster.key_slot("user1000").should eq(3443)
    Redis::Cluster.key_slot("b").should eq(3300)
    Redis::Cluster.key_slot("a").should eq(15495)
    Redis::Cluster.key_slot("").should eq(0)
  end

  it "hashes only the hash tag" do
    Redis::Cluster.key_slot("{user1000}.following").should eq(3443)
    Redis::Cluster.key_slot("{user1000}.followers").should eq(3443)
    Redis::Cluster.key_slot("foo{bar}{zap}").should eq(Redis::Cluster.key_slot("bar"))
    Redis::Cluster.key_slot("foo{bar}{zap}").should eq(5061)
    Redis::Cluster.key_slot("foo{{bar}}zap").should eq(Redis::Cluster.key_slot("{bar"))
    Redis::Cluster.key_slot("foo{{bar}}zap").should eq(4015)
  end

  it "ignores an empty or unclosed tag" do
    Redis::Cluster.key_slot("foo{}{bar}").should eq(8363)
    Redis::Cluster.key_slot("foo{bar").should eq(Redis::CRC16.checksum("foo{bar").to_i32 & 0x3FFF)
    Redis::Cluster.key_slot("foo}bar{").should eq(Redis::CRC16.checksum("foo}bar{").to_i32 & 0x3FFF)
  end

  it "stays inside the slot range" do
    1000.times { |i| Redis::Cluster.key_slot("key#{i}").should be < Redis::Cluster::SLOTS }
  end
end

describe "Redis::Cluster.route_key" do
  it "takes position 1 for ordinary commands" do
    Redis::Cluster.route_key({"GET", "k"}).should eq("k")
    Redis::Cluster.route_key(["MSET", "a", "1", "b", "2"]).should eq("a")
    Redis::Cluster.route_key({"SMOVE", "src", "dst", "m"}).should eq("src")
    Redis::Cluster.route_key({"get", "k"}).should eq("k")
    Redis::Cluster.route_key({"FROBNICATE", "k", 1}).should eq("k")
    Redis::Cluster.route_key({"SPUBLISH", "shard-channel", "m"}).should eq("shard-channel")
  end

  it "answers nil for keyless and malformed commands" do
    Redis::Cluster.route_key({"PING"}).should be_nil
    Redis::Cluster.route_key({"ping", "x"}).should be_nil
    Redis::Cluster.route_key({"PUBLISH", "channel", "m"}).should be_nil
    Redis::Cluster.route_key({"INFO", "server"}).should be_nil
    Redis::Cluster.route_key({"CLUSTER", "SLOTS"}).should be_nil
    Redis::Cluster.route_key({"MEMORY", "DOCTOR"}).should be_nil
    Redis::Cluster.route_key({"GET"}).should be_nil
    Redis::Cluster.route_key({1, 2}).should be_nil
    Redis::Cluster.route_key([] of String).should be_nil
    Redis::Cluster.route_key({"FROBNICATE", 7}).should be_nil
  end

  it "finds the first key after a key count" do
    Redis::Cluster.route_key({"EVAL", "return 1", 2, "a", "b"}).should eq("a")
    Redis::Cluster.route_key({"EVALSHA", "abc", "1", "x"}).should eq("x")
    Redis::Cluster.route_key({"EVAL", "return 1", 0}).should be_nil
    Redis::Cluster.route_key({"EVAL", "return 1", "zero"}).should be_nil
    Redis::Cluster.route_key({"FCALL", "fn", 1, "k"}).should eq("k")
    Redis::Cluster.route_key({"ZUNION", 2, "a", "b"}).should eq("a")
    Redis::Cluster.route_key({"LMPOP", 1, "q", "LEFT"}).should eq("q")
    Redis::Cluster.route_key({"BLMPOP", 0, 2, "a", "b", "LEFT"}).should eq("a")
    Redis::Cluster.route_key({"SINTERCARD", 2, "a", "b"}).should eq("a")
  end

  it "finds keys after STREAMS and at position 2" do
    Redis::Cluster.route_key({"XREAD", "COUNT", 2, "STREAMS", "s1", "s2", "0", "0"}).should eq("s1")
    Redis::Cluster.route_key({"XREADGROUP", "GROUP", "g", "c", "streams", "s", ">"}).should eq("s")
    Redis::Cluster.route_key({"XREAD", "COUNT", 2}).should be_nil
    Redis::Cluster.route_key({"OBJECT", "ENCODING", "k"}).should eq("k")
    Redis::Cluster.route_key({"XINFO", "STREAM", "k"}).should eq("k")
    Redis::Cluster.route_key({"XGROUP", "CREATE", "k", "g", "$"}).should eq("k")
    Redis::Cluster.route_key({"BITOP", "AND", "dest", "a", "b"}).should eq("dest")
    Redis::Cluster.route_key({"MEMORY", "USAGE", "k"}).should eq("k")
    Redis::Cluster.route_key({"MEMORY", "usage", "k"}).should eq("k")
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/crystal spec spec/std/redis/crc16_spec.cr`
Expected: compile error, `undefined constant Redis::CRC16`.

- [ ] **Step 3: Write `crc16.cr`**

```crystal
module Redis
  # CRC16 with the XMODEM parameters (polynomial `0x1021`, initial value
  # 0, no reflection, no final XOR): the checksum Redis Cluster hashes keys
  # with. `checksum("123456789")` is `0x31C3`.
  module CRC16
    # :nodoc:
    TABLE = begin
      table = StaticArray(UInt16, 256).new(0_u16)
      256.times do |i|
        crc = (i << 8).to_u16
        8.times do
          crc = (crc & 0x8000_u16) != 0 ? ((crc << 1) ^ 0x1021_u16) : (crc << 1)
        end
        table[i] = crc
      end
      table
    end

    # Returns the checksum of *data*.
    def self.checksum(data : Bytes) : UInt16
      crc = 0_u16
      data.each do |byte|
        crc = (crc << 8) ^ TABLE[((crc >> 8) ^ byte.to_u16).to_u8!]
      end
      crc
    end

    # :ditto:
    def self.checksum(data : String) : UInt16
      checksum(data.to_slice)
    end
  end
end
```

- [ ] **Step 4: Write the class-level part of `cluster.cr`**

```crystal
module Redis
  # A client for Redis Cluster. Task 7 replaces this doc comment.
  class Cluster
    # Number of hash slots in a Redis Cluster.
    SLOTS = 16384

    # Commands that name no key and are routed to any master. `PUBLISH`
    # is here because the cluster bus delivers a message to every node.
    KEYLESS = Set{
      "ACL", "ASKING", "AUTH", "BGREWRITEAOF", "BGSAVE", "CLIENT", "CLUSTER", "COMMAND", "CONFIG",
      "DBSIZE", "DEBUG", "DISCARD", "ECHO", "EXEC", "FLUSHALL", "FLUSHDB", "FUNCTION", "HELLO", "INFO",
      "KEYS", "LASTSAVE", "LATENCY", "LOLWUT", "MODULE", "MONITOR", "MULTI", "PING", "PSUBSCRIBE",
      "PUBLISH", "PUBSUB", "PUNSUBSCRIBE", "QUIT", "RANDOMKEY", "READONLY", "READWRITE", "REPLICAOF",
      "RESET", "ROLE", "SAVE", "SCAN", "SCRIPT", "SELECT", "SHUTDOWN", "SLOWLOG", "SUBSCRIBE", "SWAPDB",
      "TIME", "UNSUBSCRIBE", "UNWATCH", "WAIT",
    }

    # :nodoc:
    #
    # Commands whose key is not at position 1: `:count_at_N` means the
    # key count is at position N and the first key right after it;
    # `:streams` means the first key follows the word `STREAMS`;
    # `:position_2` is a fixed position; `:memory` is `MEMORY USAGE key`.
    SPECIAL = {
      "EVAL" => :count_at_2, "EVALSHA" => :count_at_2, "EVAL_RO" => :count_at_2, "EVALSHA_RO" => :count_at_2,
      "FCALL" => :count_at_2, "FCALL_RO" => :count_at_2, "BLMPOP" => :count_at_2, "BZMPOP" => :count_at_2,
      "LMPOP" => :count_at_1, "ZMPOP" => :count_at_1, "SINTERCARD" => :count_at_1, "ZINTERCARD" => :count_at_1,
      "ZUNION" => :count_at_1, "ZINTER" => :count_at_1, "ZDIFF" => :count_at_1,
      "XREAD" => :streams, "XREADGROUP" => :streams,
      "OBJECT" => :position_2, "XINFO" => :position_2, "XGROUP" => :position_2, "BITOP" => :position_2,
      "MEMORY" => :memory,
    }

    # The hash slot of *key*: the CRC16 of its hash tag (the bytes between
    # the first `{` and the first `}` after it, when there is at least one)
    # or of the whole key, modulo `SLOTS`.
    def self.key_slot(key : String) : Int32
      bytes = key.to_slice
      if (open = bytes.index('{'.ord.to_u8)) && (close = bytes[open + 1..].index('}'.ord.to_u8)) && close > 0
        bytes = bytes[open + 1, close]
      end
      CRC16.checksum(bytes).to_i32 & (SLOTS - 1)
    end

    # The key a command is routed by, or `nil` for a command that names
    # none (which a `Cluster` sends to any master). Names are matched
    # case-insensitively. Ordinary commands carry their key at position 1;
    # `SPECIAL` lists the exceptions; `KEYLESS` the commands with no key.
    # Never raises: a malformed command routes to a random master and the
    # server's error reply comes back as usual.
    #
    # ```
    # Redis::Cluster.route_key({"GET", "k"})               # => "k"
    # Redis::Cluster.route_key({"EVAL", "return 1", 1, "k"}) # => "k"
    # Redis::Cluster.route_key({"PING"})                    # => nil
    # ```
    def self.route_key(args : Indexable) : String?
      name = args[0]?
      return nil unless name.is_a?(String)
      name = name.upcase unless uppercase?(name)
      return nil if KEYLESS.includes?(name)
      case SPECIAL[name]?
      when :count_at_1 then key_after_count(args, 1)
      when :count_at_2 then key_after_count(args, 2)
      when :position_2 then string_at(args, 2)
      when :streams
        i = 1
        while i < args.size
          word = args[i]
          i += 1
          return string_at(args, i) if word.is_a?(String) && word.compare("STREAMS", case_insensitive: true) == 0
        end
        nil
      when :memory
        sub = args[1]?
        sub.is_a?(String) && sub.compare("USAGE", case_insensitive: true) == 0 ? string_at(args, 2) : nil
      else
        string_at(args, 1)
      end
    end

    private def self.uppercase?(name : String) : Bool
      name.each_byte { |b| return false if 'a'.ord <= b <= 'z'.ord }
      true
    end

    private def self.string_at(args : Indexable, index : Int32) : String?
      value = args[index]?
      value.is_a?(String) ? value : nil
    end

    private def self.key_after_count(args : Indexable, at : Int32) : String?
      count = args[at]?
      n = case count
          when String then count.to_i?
          when Int    then count
          else             nil
          end
      n && n > 0 ? string_at(args, at + 1) : nil
    end
  end
end
```

- [ ] **Step 5: Errors and requires**

Append inside `module Redis` in `src/redis/error.cr`:

```crystal
  # Raised by `Cluster` when no seed or known node answers `CLUSTER SLOTS`,
  # when the cluster reports no masters, or when a command was redirected
  # more than `max_redirects` times (the last `MOVED`/`ASK`/`TRYAGAIN`
  # reply is the `cause`).
  class ClusterError < Error
  end

  # Raised by `Pool#checkout` when no connection became available within
  # `checkout_timeout`.
  class PoolTimeoutError < Error
  end
```

In `src/redis.cr` add `require "./redis/crc16"` right after `require "./redis/value"`, and `require "./redis/cluster"` after `require "./redis/subscriber"`.

- [ ] **Step 6: Run the specs to verify they pass**

Run: `bin/crystal spec spec/std/redis/crc16_spec.cr`
Expected: all examples pass. If `Redis::Cluster.route_key({"FROBNICATE", 7})` fails to compile because `Tuple(String, Int32)` is not accepted where `Indexable` is expected, the restriction is wrong: `Tuple` includes `Indexable`, so check that `args[index]?` and `args.size` are the only calls made on it.

- [ ] **Step 7: Format and commit**

```bash
bin/crystal tool format src/redis spec/std/redis
git add src/redis/crc16.cr src/redis/cluster.cr src/redis/error.cr src/redis.cr spec/std/redis/crc16_spec.cr
git commit -m "Redis: CRC16, key slots, routing table and slice 3 errors

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Split the future API into `resolve(Value)` and `fail(Exception)`

Pure refactor, no behaviour change. Motivation, verified in this session: `pipeline.resolve(i, raw)` with `raw : Value | Exception` does not compile ("expected argument #2 ... to be (... | Exception | ...), not (... | Exception | ...)") because `Value` contains `CommandError < Exception`. Task 6 and Task 8 need to store replies and failures per index and hand them back, which the split makes possible.

**Files:**
- Modify: `src/redis/pipeline.cr` (`AbstractFuture`, `Future`, `ScriptFuture`, `Pipeline#resolve`, new `Pipeline#fail`)
- Modify: `src/redis/transaction.cr` (`QueuedFuture`, `ExecFuture`)
- Modify: `src/redis/client.cr:195,208` (`pipeline.resolve(i, error)` → `pipeline.fail(i, error)`; same for `ex`)
- Modify: `src/redis/connection.cr` (`fail_futures`)
- Test: `spec/std/redis/pipeline_spec.cr` (append), `spec/std/redis/transaction_spec.cr:99`

**Interfaces:**
- Produces: `AbstractFuture#resolve(raw : Value) : Nil`, `AbstractFuture#fail(error : Exception) : Nil`; `Pipeline#resolve(index : Int32, raw : Value) : Nil`, `Pipeline#fail(index : Int32, error : Exception) : Nil` (both `:nodoc:`).

- [ ] **Step 1: Update the specs**

In `spec/std/redis/transaction_spec.cr` change line 99 from `p.resolve(2, Redis::ConnectionError.new("connection lost"))` to `p.fail(2, Redis::ConnectionError.new("connection lost"))`.

Append to `spec/std/redis/pipeline_spec.cr` inside `describe Redis::Pipeline`:

```crystal
  it "fails a future with any exception through fail" do
    p = Redis::Pipeline.new
    f = p.get("a")
    g = p.incr("n")
    p.fail(0, IO::TimeoutError.new("slow"))
    p.fail(1, Redis::ConnectionError.new("lost"))
    f.resolved?.should be_true
    f.value?.should be_nil
    expect_raises(IO::TimeoutError, /slow/) { f.value }
    expect_raises(Redis::ConnectionError, /lost/) { g.value }
  end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/crystal spec spec/std/redis/pipeline_spec.cr spec/std/redis/transaction_spec.cr`
Expected: compile error, `undefined method 'fail' for Redis::Pipeline`.

- [ ] **Step 3: `pipeline.cr`**

Replace `AbstractFuture`, the `resolve` of `Future(T)`, `ScriptFuture#resolve`, and `Pipeline#resolve` with:

```crystal
  # :nodoc:
  abstract class AbstractFuture
    # Delivers a reply. An error reply (`CommandError`) is a value here.
    abstract def resolve(raw : Value) : Nil

    # Fails the future with *error* (`ConnectionError`, `IO::TimeoutError`,
    # `ProtocolError`, `AbortedError`, ...). Kept apart from `resolve`
    # because Crystal cannot pass a `Value | Exception`-typed argument to
    # a `Value | Exception` restriction while `Value` itself contains an
    # `Exception` subclass (`CommandError`).
    abstract def fail(error : Exception) : Nil

    abstract def resolved? : Bool
  end
```

In `Future(T)`:

```crystal
    # :nodoc:
    def resolve(raw : Value) : Nil
      @raw = raw
      @resolved = true
    end

    # :nodoc:
    def fail(error : Exception) : Nil
      @raw = error
      @resolved = true
    end
```

(`@raw : Value | Exception = nil` and `value`/`value?` stay as they are.)

In `ScriptFuture`:

```crystal
    def resolve(raw : Value) : Nil
      super
      if raw.is_a?(CommandError)
        @cache.delete(@sha) if raw.code == "NOSCRIPT"
      else
        @cache.add(@sha)
      end
    end

    # :nodoc:
    #
    # Restated for the same reason as `resolved?` below.
    def fail(error : Exception) : Nil
      super
    end
```

In `Pipeline`, replace `resolve` with:

```crystal
    # :nodoc:
    def resolve(index : Int32, raw : Value) : Nil
      @futures[index].resolve(raw)
    end

    # :nodoc:
    def fail(index : Int32, error : Exception) : Nil
      @futures[index].fail(error)
    end
```

- [ ] **Step 4: `transaction.cr`**

```crystal
  class QueuedFuture < AbstractFuture
    @resolved = false

    def initialize(@target : AbstractFuture)
    end

    def resolve(raw : Value) : Nil
      @resolved = true
      @target.resolve(raw) if raw.is_a?(CommandError)
    end

    # The `ExecFuture` fans a failure out to the targets; nothing to do here.
    def fail(error : Exception) : Nil
      @resolved = true
    end

    def resolved? : Bool
      @resolved
    end
  end
```

`ExecFuture`: keep `initialize` and the restated `resolved?`; replace `resolve` and `fail_all` with:

```crystal
    def resolve(raw : Value) : Nil
      case raw
      when Array
        if raw.size == @targets.size
          super(raw)
          @targets.each_with_index { |target, i| target.resolve(raw[i]) }
        else
          fail_all(ProtocolError.new("EXEC returned #{raw.size} replies for #{@targets.size} commands"))
        end
      when Nil
        fail_all(AbortedError.new)
      when CommandError
        # `EXECABORT`: every future that has no queue-time error yet gets it.
        fail(raw)
      else
        fail_all(ProtocolError.new("unexpected EXEC reply #{raw.inspect}"))
      end
    end

    # :nodoc:
    #
    # Restated for virtual dispatch through `AbstractFuture`, like
    # `resolved?`. A connection loss or timeout reaches every target that
    # has not already been resolved (queue-time failures keep theirs).
    def fail(error : Exception) : Nil
      super
      @targets.each { |target| target.fail(error) unless target.resolved? }
    end

    private def fail_all(error : Exception) : Nil
      @raw = error
      @resolved = true
      @targets.each { |target| target.fail(error) }
    end
```

- [ ] **Step 5: Callers**

`src/redis/client.cr` in `pipelined`: `pipeline.resolve(i, error)` → `pipeline.fail(i, error)`; `(resolved...waiters.size).each { |j| pipeline.resolve(j, ex) }` → `pipeline.fail(j, ex)`.

`src/redis/connection.cr`: replace `fail_futures` (and its comment) with:

```crystal
    # Fails every future from *from* to *pipeline*'s end with *error*.
    private def fail_futures(pipeline : Pipeline, from : Int32, error : Exception) : Nil
      (from...pipeline.size).each { |i| pipeline.fail(i, error) }
    end
```

- [ ] **Step 6: Run the whole Redis suite**

Run: `bin/crystal spec spec/std/redis/`
Expected: every example passes (the live ones are pending or pass against the local Valkey); the count is 220 + 1 new example.

- [ ] **Step 7: Format and commit**

```bash
bin/crystal tool format src/redis spec/std/redis
git add src/redis/pipeline.cr src/redis/transaction.cr src/redis/client.cr src/redis/connection.cr spec/std/redis/pipeline_spec.cr spec/std/redis/transaction_spec.cr
git commit -m "Redis: split future resolution into resolve(Value) and fail(Exception)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: `Connection`: TLS error mapping and `watching?`

**Files:**
- Modify: `src/redis/connection.cr`
- Test: `spec/std/redis/connection_spec.cr` (append)

**Interfaces:**
- Produces: `Connection#watching? : Bool` (true after `watch`, false after `unwatch` or a `multi` that sent `EXEC`); `Connection#send/read/pipeline/pipelined` raise `ConnectionError` for `OpenSSL::SSL::Error` as they do for `IO::Error`.

- [ ] **Step 1: Write the failing specs**

Append to `spec/std/redis/connection_spec.cr`:

```crystal
describe "Redis::Connection#watching?" do
  it "tracks WATCH until EXEC or UNWATCH" do
    server = RedisSpec::FakeServer.new do |io|
      while cmd = RedisSpec::FakeServer.read_command(io)
        case cmd[0]
        when "HELLO" then io << RedisSpec::HELLO_REPLY
        when "EXEC"  then io << "*1\r\n+OK\r\n"
        else              io << "+OK\r\n"
        end
        io.flush
      end
    end
    conn = Redis::Connection.new(server.url)
    conn.watching?.should be_false
    conn.watch("k")
    conn.watching?.should be_true
    conn.multi { |tx| tx.set("k", "v") }
    conn.watching?.should be_false
    conn.watch("k")
    conn.multi { |tx| } # nothing sent: still watching
    conn.watching?.should be_true
    conn.unwatch
    conn.watching?.should be_false
    conn.close
    server.close
  end
end

describe "Redis::Connection over TLS" do
  it "maps a torn-down TLS socket to ConnectionError" do
    context = OpenSSL::SSL::Context::Server.new
    context.certificate_chain = File.join(__DIR__, "..", "data", "openssl", "openssl.crt")
    context.private_key = File.join(__DIR__, "..", "data", "openssl", "openssl.key")
    server = RedisSpec::FakeServer.new do |io|
      begin
        ssl = OpenSSL::SSL::Socket::Server.new(io, context: context, sync_close: false)
        cmd = RedisSpec::FakeServer.read_command(ssl)
        ssl << RedisSpec::HELLO_REPLY if cmd && cmd[0] == "HELLO"
        ssl.flush
        RedisSpec::FakeServer.read_command(ssl) # PING
      rescue OpenSSL::SSL::Error
      end
      # Reset instead of a clean close_notify, so the client sees a failure
      # rather than a graceful EOF.
      io.as(TCPSocket).linger = 0
      io.close
    end
    client_context = OpenSSL::SSL::Context::Client.new
    client_context.verify_mode = OpenSSL::SSL::VerifyMode::NONE
    conn = Redis::Connection.new("rediss://127.0.0.1:#{server.port}", tls_context: client_context)
    conn.protocol.should eq(3)
    expect_raises(Redis::ConnectionError) { conn.ping }
    conn.closed?.should be_true
    server.close
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/crystal spec spec/std/redis/connection_spec.cr`
Expected: compile error, `undefined method 'watching?'`.

- [ ] **Step 3: Implement**

In `src/redis/connection.cr`:

1. Add the ivar and getter next to `@closed = false`:

```crystal
    # Whether a `watch` is in effect on this connection: set by `watch`,
    # cleared by `unwatch` and by a `multi` that sent `EXEC` (Redis
    # discards every watch when `EXEC` runs, even an aborted one).
    getter? watching = false
```

2. In `send`, `read`, `pipeline` and `pipelined`, change every `rescue ex : IO::Error` clause to `rescue ex : IO::Error | OpenSSL::SSL::Error` (the `IO::TimeoutError` and `ProtocolError` clauses stay first, unchanged), and widen the helpers:

```crystal
    private def fail(ex : IO::Error | OpenSSL::SSL::Error) : NoReturn
      close
      raise connection_error(ex)
    end

    private def connection_error(ex : IO::Error | OpenSSL::SSL::Error) : ConnectionError
      ConnectionError.new("connection lost: #{ex.message}", cause: ex)
    end
```

3. Replace `multi`, `watch` and `unwatch`:

```crystal
    def multi(&block : Transaction ->) : Array(Value)
      exec = nil
      sent = false
      begin
        pipelined do |p|
          exec = p.multi(&block)
          sent = p.size > 0
        end
      ensure
        # EXEC, even an aborted one, discards every WATCH server-side. An
        # empty block sends nothing and leaves the watch in place.
        @watching = false if sent
      end
      exec.not_nil!.value
    end

    # Raises `ArgumentError`: `watch` needs at least one key.
    def watch : Nil
      raise ArgumentError.new("WATCH needs at least one key")
    end

    # Marks *keys* for optimistic locking: a following `multi` on this
    # connection raises `AbortedError` if any of them changed in between.
    # `WATCH` is per connection, which is why it exists only here and not
    # on `Client`; see `Client#watch`, which also sends `UNWATCH` for you
    # when a block leaves without running `multi`. A `Connection` borrowed
    # from a `Pool` and handed back while `watching?` carries the watch to
    # its next user, so call `unwatch` yourself in that case.
    def watch(*keys : String) : Nil
      args = Array(RESP::Arg).new(keys.size + 1)
      args << "WATCH"
      keys.each { |k| args << k }
      call(args)
      @watching = true
      nil
    end

    # Forgets every key marked with `watch`.
    def unwatch : Nil
      call({"UNWATCH"})
      @watching = false
      nil
    end
```

Keep the `multi` doc comment that is already there.

- [ ] **Step 4: Run the specs to verify they pass**

Run: `bin/crystal spec spec/std/redis/connection_spec.cr`
Expected: all pass. If the TLS example raises `OpenSSL::SSL::Error` instead of `ConnectionError`, a `rescue` clause was missed; if it hangs, the server block never closed the TCP socket.

- [ ] **Step 5: Format and commit**

```bash
bin/crystal tool format src/redis spec/std/redis
git add src/redis/connection.cr spec/std/redis/connection_spec.cr
git commit -m "Redis: Connection#watching? and TLS errors mapped to ConnectionError

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: `Redis::Pool`

**Files:**
- Create: `src/redis/pool.cr`
- Modify: `src/redis.cr` (add `require "./redis/pool"` after `require "./redis/connection"`)
- Test: `spec/std/redis/pool_spec.cr`

**Interfaces:**
- Consumes: `Redis::Connection.new(url, db:, username:, password:, client_name:, protocol:, connect_timeout:, read_timeout:, tls_context:, max_bulk_size:)`, `Connection#closed?`, `Connection#close`; `Redis::PoolTimeoutError` (Task 1).
- Produces: `Redis::Pool.new(url = Connection::DEFAULT_URL, *, size = 8, checkout_timeout = 5.seconds, db:, username:, password:, client_name:, protocol:, connect_timeout:, read_timeout:, tls_context:, max_bulk_size:)`; `Pool#size : Int32`, `#checkout_timeout : Time::Span`, `#idle : Int32`, `#in_use : Int32`, `#checkout : Connection`, `#checkin(Connection) : Nil`, `#checkout(& : Connection -> T) : T forall T`, `#close : Nil`, `#closed? : Bool`.

- [ ] **Step 1: Write the failing specs**

`spec/std/redis/pool_spec.cr`:

```crystal
require "spec"
require "wait_group"
require "../../support/redis"

# HELLO → RESP3, PING → +PONG, BAD → -ERR, DIE → close the socket, else +OK.
private def pool_server
  RedisSpec::FakeServer.new do |io|
    while cmd = RedisSpec::FakeServer.read_command(io)
      case cmd[0]
      when "HELLO" then io << RedisSpec::HELLO_REPLY
      when "PING"  then io << "+PONG\r\n"
      when "BAD"   then io << "-ERR bad\r\n"
      when "DIE"
        io.close
        break
      else io << "+OK\r\n"
      end
      io.flush
    end
  end
end

describe Redis::Pool do
  it "opens connections lazily and reuses them" do
    server = pool_server
    pool = Redis::Pool.new(server.url, size: 2)
    pool.size.should eq(2)
    server.accepted.should eq(0)
    pool.idle.should eq(0)
    c1 = pool.checkout
    c2 = pool.checkout
    server.accepted.should eq(2)
    pool.in_use.should eq(2)
    c1.ping.should eq("PONG")
    pool.checkin(c1)
    pool.idle.should eq(1)
    pool.in_use.should eq(1)
    c3 = pool.checkout
    c3.should be(c1)
    server.accepted.should eq(2)
    pool.checkin(c2)
    pool.checkin(c3)
    pool.idle.should eq(2)
    pool.close
    c1.closed?.should be_true
    c2.closed?.should be_true
    server.close
  end

  it "bounds checkouts by size and times out" do
    server = pool_server
    pool = Redis::Pool.new(server.url, size: 1, checkout_timeout: 50.milliseconds)
    held = pool.checkout
    expect_raises(Redis::PoolTimeoutError, /50/) { pool.checkout }
    spawn do
      sleep 20.milliseconds
      pool.checkin(held)
    end
    pool.checkout.should be(held)
    server.accepted.should eq(1)
    pool.close
    server.close
  end

  it "drops a connection that is closed when it comes back" do
    server = pool_server
    pool = Redis::Pool.new(server.url, size: 2)
    conn = pool.checkout
    expect_raises(Redis::ConnectionError) { conn.call("DIE") }
    conn.closed?.should be_true
    pool.checkin(conn)
    pool.idle.should eq(0)
    pool.in_use.should eq(0)
    fresh = pool.checkout
    fresh.should_not be(conn)
    server.accepted.should eq(2)
    fresh.ping.should eq("PONG")
    pool.checkin(fresh)
    pool.close
    server.close
  end

  it "yields a connection and keeps it after an error reply" do
    server = pool_server
    pool = Redis::Pool.new(server.url, size: 2)
    pool.checkout { |conn| conn.ping }.should eq("PONG")
    expect_raises(Redis::CommandError, /bad/) { pool.checkout { |conn| conn.call("BAD") } }
    expect_raises(Exception, "boom") { pool.checkout { |conn| raise "boom" } }
    pool.idle.should eq(1)
    pool.in_use.should eq(0)
    server.accepted.should eq(1)
    pool.close
    server.close
  end

  it "closes idle connections, and in-use ones when they return" do
    server = pool_server
    pool = Redis::Pool.new(server.url, size: 2)
    idle = pool.checkout
    pool.checkin(idle)
    held = pool.checkout
    pool.close
    pool.closed?.should be_true
    idle.closed?.should be_true
    held.closed?.should be_false
    pool.checkin(held)
    held.closed?.should be_true
    pool.idle.should eq(0)
    expect_raises(Redis::ConnectionError, /closed/) { pool.checkout }
    pool.close # idempotent
    server.close
  end

  it "never exceeds size under concurrent use" do
    server = pool_server
    pool = Redis::Pool.new(server.url, size: 4)
    wg = WaitGroup.new(32)
    32.times do
      spawn do
        begin
          50.times { pool.checkout { |conn| conn.ping } }
        ensure
          wg.done
        end
      end
    end
    wg.wait
    server.accepted.should be <= 4
    pool.in_use.should eq(0)
    pool.idle.should be <= 4
    pool.close
    server.close
  end

  it "rejects a non-positive size and a bad protocol" do
    expect_raises(ArgumentError, /size/) { Redis::Pool.new(size: 0) }
    expect_raises(ArgumentError, /protocol/) { Redis::Pool.new(protocol: 4) }
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/crystal spec spec/std/redis/pool_spec.cr`
Expected: compile error, `undefined constant Redis::Pool`.

- [ ] **Step 3: Write `pool.cr`**

```crystal
module Redis
  # A bounded pool of `Connection`s for commands that need a socket to
  # themselves: blocking commands (`BLPOP`, `WAIT`, ...) and `WATCH`. For
  # everything else a single multiplexed `Client` is faster than a pool.
  #
  # Connections are opened lazily, up to `size` at once. `checkout` waits
  # up to `checkout_timeout` for one to come back before raising
  # `PoolTimeoutError`. A connection that is closed when it is checked in
  # (every I/O, protocol or timeout failure closes it) is dropped and the
  # next `checkout` opens a fresh one; there is no health check on
  # checkout, so a socket the server dropped while idle surfaces as
  # `ConnectionError` on its first use, and the caller retries.
  #
  # ```
  # pool = Redis::Pool.new("redis://localhost:6379", size: 8)
  # pool.checkout { |conn| conn.call("BLPOP", "jobs", 0) }
  # pool.close
  # ```
  class Pool
    # The maximum number of open connections.
    getter size : Int32
    # How long `checkout` waits for a connection.
    getter checkout_timeout : Time::Span

    @mutex = Mutex.new
    @idle = Deque(Connection).new
    @in_use = 0
    @closed = false
    @permits : Channel(Nil)
    @url : URI

    # Creates an empty pool for *url* (or `Connection::DEFAULT_URL`). The
    # remaining options are those of `Connection.new` and apply to every
    # connection the pool opens. Raises `ArgumentError` if *size* is not
    # positive or *protocol* is outside `2..3`.
    def initialize(url : String | URI = Connection::DEFAULT_URL, *, @size : Int32 = 8,
                   @checkout_timeout : Time::Span = 5.seconds, @db : Int32? = nil, @username : String? = nil,
                   @password : String? = nil, @client_name : String? = nil, @protocol : Int32 = 3,
                   @connect_timeout : Time::Span = 5.seconds, @read_timeout : Time::Span? = nil,
                   @tls_context : OpenSSL::SSL::Context::Client? = nil, @max_bulk_size : Int32 = RESP::MAX_BULK_SIZE)
      raise ArgumentError.new("pool size must be positive, got #{@size}") unless @size > 0
      raise ArgumentError.new("protocol must be 2 or 3, got #{@protocol}") unless @protocol == 2 || @protocol == 3
      @url = url.is_a?(URI) ? url : URI.parse(url)
      @permits = Channel(Nil).new(@size)
      @size.times { @permits.send(nil) }
    end

    # Open connections waiting in the pool.
    def idle : Int32
      @mutex.synchronize { @idle.size }
    end

    # Connections currently checked out.
    def in_use : Int32
      @mutex.synchronize { @in_use }
    end

    # Whether `close` has been called.
    def closed? : Bool
      @closed
    end

    # Takes a connection, opening one if none is idle and fewer than `size`
    # are out. Raises `PoolTimeoutError` after `checkout_timeout`,
    # `ConnectionError` if the pool is closed or a new connection cannot be
    # opened, `CommandError` if the server rejects the handshake. Hand it
    # back with `checkin`; the block form does that for you.
    def checkout : Connection
      raise ConnectionError.new("pool is closed") if @closed
      select
      when @permits.receive
      when timeout(@checkout_timeout)
        raise PoolTimeoutError.new("no connection available after #{@checkout_timeout}")
      end
      connection = @mutex.synchronize do
        if @closed
          @permits.send(nil)
          raise ConnectionError.new("pool is closed")
        end
        @in_use += 1
        # A connection closed by a failure while it was idle is useless;
        # skip it and open a fresh one below.
        while c = @idle.shift?
          break c unless c.closed?
        end
      end
      connection || begin
        open
      rescue ex
        @mutex.synchronize { @in_use -= 1 }
        @permits.send(nil)
        raise ex
      end
    end

    # Returns *connection* to the pool. A closed connection is dropped; if
    # the pool is closed the connection is closed too. Checking in a
    # connection twice, or one this pool never handed out, is not detected.
    def checkin(connection : Connection) : Nil
      close_it = @mutex.synchronize do
        @in_use -= 1
        if @closed || connection.closed?
          true
        else
          @idle.push(connection)
          false
        end
      end
      connection.close if close_it
      @permits.send(nil)
    end

    # Checks a connection out, yields it and checks it in again, whatever
    # the block does. An exception raised by the block does not discard the
    # connection: a failure that leaves the socket unusable already closed
    # it, and a `CommandError` (`WRONGTYPE`, an `AbortedError` from `multi`,
    # ...) leaves it healthy. The one way to hand back a desynchronised
    # connection is to `send` without `read` and then leave the block;
    # `close` the connection yourself before leaving in that case.
    def checkout(& : Connection -> T) : T forall T
      connection = checkout
      begin
        yield connection
      ensure
        checkin(connection)
      end
    end

    # Closes every idle connection and marks the pool closed; connections
    # in use are closed when they are checked in. Idempotent.
    def close : Nil
      idle = @mutex.synchronize do
        @closed = true
        drained = @idle.to_a
        @idle.clear
        drained
      end
      idle.each(&.close)
    end

    private def open : Connection
      Connection.new(@url, db: @db, username: @username, password: @password, client_name: @client_name,
        protocol: @protocol, connect_timeout: @connect_timeout, read_timeout: @read_timeout,
        tls_context: @tls_context, max_bulk_size: @max_bulk_size)
    end
  end
end
```

The `while c = @idle.shift?; break c unless c.closed?; end` loop is the value of the `synchronize` block: `Connection?` (nil when the deque ran out). If the compiler types the block's value as `Nil`, rewrite it as `found = nil; while c = @idle.shift?; if !c.closed?; found = c; break; end; end; found`.

- [ ] **Step 4: Run the specs to verify they pass**

Run: `bin/crystal spec spec/std/redis/pool_spec.cr`
Expected: 7 examples, 0 failures.

- [ ] **Step 5: Format and commit**

```bash
bin/crystal tool format src/redis spec/std/redis
git add src/redis/pool.cr src/redis.cr spec/std/redis/pool_spec.cr
git commit -m "Redis: Pool, a bounded pool of Connections

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: `Client#with_connection` and pooled `watch`

**Files:**
- Modify: `src/redis/client.cr` (constructor, `watch`, `close`, new `with_connection`, private `pool`)
- Test: `spec/std/redis/client_spec.cr` (append), `spec/std/redis/transaction_spec.cr` (the two `Client#watch` examples)

**Interfaces:**
- Consumes: `Redis::Pool` (Task 4); `Connection#watching?` (Task 3).
- Produces: `Client.new(..., pool_size : Int32 = 4)`; `Client#with_connection(& : Connection -> T) : T forall T`; `Client#watch(*keys, &)` borrowing from the pool and sending `UNWATCH` when the block leaves while `watching?`; `Client#close` closes the pool.

- [ ] **Step 1: Write the failing specs**

Append to `spec/std/redis/client_spec.cr` inside `describe Redis::Client` (the `Script` fake at the top of the file answers `+OK` to `WATCH`, `UNWATCH`, `MULTI`, `SET`, `EXEC`):

```crystal
  it "borrows a dedicated connection from its pool" do
    script = Script.new
    server = script.server
    client = Redis::Client.new(server.url, pool_size: 2)
    client.ping
    inner = nil
    client.with_connection do |conn|
      inner = conn
      conn.should be_a(Redis::Connection)
      conn.ping.should eq("PONG")
    end
    server.accepted.should eq(2)
    client.with_connection { |conn| conn.should be(inner) }
    server.accepted.should eq(2)
    inner.not_nil!.closed?.should be_false
    client.close
    inner.not_nil!.closed?.should be_true
    expect_raises(Redis::ConnectionError, /closed/) { client.with_connection { } }
    server.close
  end

  it "rejects a non-positive pool size" do
    expect_raises(ArgumentError, /pool_size/) { Redis::Client.new(pool_size: 0) }
  end
```

In `spec/std/redis/transaction_spec.cr` replace the two examples of `describe "Redis::Client#watch"` with:

```crystal
describe "Redis::Client#watch" do
  it "borrows a pooled connection, sends WATCH, yields it and hands it back" do
    fake = TxServer.new
    server = fake.server
    client = Redis::Client.new(server.url, db: 3)
    client.ping
    inner = nil
    result = client.watch("k1", "k2") do |conn|
      inner = conn
      conn.get("k1").should eq("v")
      conn.multi { |tx| tx.set("k1", "w") }
    end
    result.should eq(values("OK"))
    server.accepted.should eq(2)
    inner.not_nil!.closed?.should be_false
    # Once from the client's own connection, once from the pooled one.
    fake.seen.count(["SELECT", "3"]).should eq(2)
    fake.seen.should contain(["WATCH", "k1", "k2"])
    # EXEC discarded the watch; no UNWATCH round trip.
    fake.seen.should_not contain(["UNWATCH"])
    # A second watch reuses the pooled connection.
    client.watch("k1") { |conn| conn.should be(inner) }
    server.accepted.should eq(2)
    # That block never ran multi, so the watch was cleared by hand.
    fake.seen.last.should eq(["UNWATCH"])
    client.connected?.should be_true
    client.close
    inner.not_nil!.closed?.should be_true
    server.close
  end

  it "unwatches when the block raises before multi and refuses no keys" do
    fake = TxServer.new
    server = fake.server
    client = Redis::Client.new(server.url)
    inner = nil
    expect_raises(ArgumentError, /at least one key/) { client.watch { |conn| } }
    expect_raises(Redis::AbortedError) do
      client.watch("k") do |conn|
        inner = conn
        fake.abort = true
        conn.multi { |tx| tx.set("k", "w") }
      end
    end
    inner.not_nil!.closed?.should be_false
    fake.seen.should_not contain(["UNWATCH"])
    expect_raises(Exception, "boom") { client.watch("k") { |conn| raise "boom" } }
    fake.seen.last.should eq(["UNWATCH"])
    client.close
    server.close
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/crystal spec spec/std/redis/client_spec.cr spec/std/redis/transaction_spec.cr`
Expected: compile error, `no argument named 'pool_size'`.

- [ ] **Step 3: Implement in `client.cr`**

1. Constructor: add `@pool_size : Int32 = 4` to the parameter list (after `@max_bulk_size`), the ivar `@pool : Pool?`, and the check:

```crystal
      raise ArgumentError.new("pool_size must be positive, got #{@pool_size}") unless @pool_size > 0
```

Extend the constructor doc: "*pool_size* bounds the dedicated connections `with_connection` and `watch` borrow."

2. Add after `subscriber`:

```crystal
    # Borrows a dedicated `Connection` from the client's pool (opened on
    # first use with this client's URL and every option, `db` and
    # `read_timeout` included), yields it, and hands it back. For blocking
    # commands that must not stall the multiplexed connection:
    #
    # ```
    # redis.with_connection { |conn| conn.call("BLPOP", "jobs", 0) }
    # ```
    #
    # The connection carries the client's `read_timeout`; a blocking
    # command that may wait longer needs a client created with
    # `read_timeout: nil` or a `Connection` of its own. At most `pool_size`
    # connections are out at once; the next caller waits up to five
    # seconds and then raises `PoolTimeoutError`. See `Pool#checkout` for
    # what happens when the block raises.
    def with_connection(&block : Connection -> T) : T forall T
      pool.checkout(&block)
    end

    private def pool : Pool
      @mutex.synchronize do
        check_open
        @pool ||= Pool.new(@url, size: @pool_size, db: @db, username: @username, password: @password,
          client_name: @client_name, protocol: @protocol_option, connect_timeout: @connect_timeout,
          read_timeout: @read_timeout, tls_context: @tls_context, max_bulk_size: @max_bulk_size)
      end
    end
```

3. Replace the keyed `watch` (keep the zero-key overload):

```crystal
    # Borrows a dedicated `Connection` from the client's pool (see
    # `with_connection`), sends `WATCH` for *keys*, yields the connection
    # for the read-then-`multi` sequence, and hands it back. Returns the
    # block's value. If the block leaves without having run `multi` (it
    # returned early or raised), `UNWATCH` is sent so the watch cannot leak
    # to the connection's next borrower. An `AbortedError` raised by
    # `Connection#multi` inside the block means a watched key changed;
    # retrying is the caller's loop:
    #
    # ```
    # loop do
    #   begin
    #     redis.watch("balance") do |conn|
    #       balance = conn.get("balance").not_nil!.to_i
    #       conn.multi { |tx| tx.set("balance", balance - 10) }
    #     end
    #     break
    #   rescue Redis::AbortedError
    #   end
    # end
    # ```
    #
    # Raises `ConnectionError` if no connection can be opened and
    # `PoolTimeoutError` if none comes free in time.
    def watch(*keys : String, &block : Connection -> T) : T forall T
      with_connection do |conn|
        conn.watch(*keys)
        begin
          block.call(conn)
        ensure
          conn.unwatch if conn.watching? && !conn.closed?
        end
      end
    end
```

4. `close`:

```crystal
    def close : Nil
      conn, pool = @mutex.synchronize do
        @closed = true
        {@connection, @pool}
      end
      disconnect(conn, nil) if conn
      pool.close if pool
    end
```

Update the `close` doc comment: "Closes the connection and the pool; pending commands raise `ConnectionError`, and every later call raises too."

- [ ] **Step 4: Run the specs to verify they pass**

Run: `bin/crystal spec spec/std/redis/client_spec.cr spec/std/redis/transaction_spec.cr`
Expected: all pass. If `fake.seen.last.should eq(["UNWATCH"])` fails because `UNWATCH` is missing, `conn.watching?` was cleared too early (check Task 3's `sent` flag); if it fails because `UNWATCH` appears after the first block, `multi` did not clear it.

- [ ] **Step 5: Format and commit**

```bash
bin/crystal tool format src/redis spec/std/redis
git add src/redis/client.cr spec/std/redis/client_spec.cr spec/std/redis/transaction_spec.cr
git commit -m "Redis: Client#with_connection and watch borrowing from a pool

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: `Client#pipeline_raw`, `Client#call_raw`, `Pipeline` routing mode

**Files:**
- Modify: `src/redis/client.cr` (`pipelined` refactored onto the new `pipeline_raw`; new `call_raw`, `ASKING`)
- Modify: `src/redis/pipeline.cr` (`Route`, `routing?`, `routes`, `offsets`, recording in `typed_call`, `script_run`, `multi`)
- Test: `spec/std/redis/client_spec.cr` (append), `spec/std/redis/pipeline_spec.cr` (append)

**Interfaces:**
- Consumes: `Cluster.route_key` (Task 1); `Pipeline#fail` (Task 2).
- Produces: `Client#pipeline_raw(bytes : Bytes, count : Int32, & : Int32, Value, Exception? ->) : Nil` (`:nodoc:`); `Client#call_raw(bytes : Bytes, asking : Bool = false) : Value` (`:nodoc:`); `Pipeline.new(script_cache = ScriptCache.new, routing : Bool = false)`; `Pipeline::Route` record (`key : String?`, `retry : Bool`); `Pipeline#routing? : Bool`, `#routes : Array(Route)`, `#offsets : Array(Int32)` (`:nodoc:`, one entry per wire command in routing mode, empty otherwise).

- [ ] **Step 1: Write the failing specs**

Append to `spec/std/redis/pipeline_spec.cr` inside `describe Redis::Pipeline`:

```crystal
  it "records routes and byte offsets in routing mode" do
    p = Redis::Pipeline.new(routing: true)
    p.routing?.should be_true
    p.set("a", "1")
    p.command("PING")
    p.get("{tag}b")
    p.routes.map(&.key).should eq(["a", nil, "{tag}b"])
    p.routes.all?(&.retry).should be_true
    # "*3\r\n$3\r\nSET\r\n$1\r\na\r\n$1\r\n1\r\n" is 27 bytes, "*1\r\n$4\r\nPING\r\n" is 14.
    p.offsets.should eq([0, 27, 41])
    p.buffer.bytesize.should eq(41 + "*2\r\n$3\r\nGET\r\n$6\r\n{tag}b\r\n".bytesize)
  end

  it "routes a multi block by its first key and marks it non-retryable" do
    p = Redis::Pipeline.new(routing: true)
    p.get("x")
    p.multi do |tx|
      tx.command("PING")
      tx.incr("{t}a")
      tx.incr("{t}b")
    end
    p.get("y")
    p.size.should eq(7)
    p.routes.map(&.key).should eq(["x", "{t}a", "{t}a", "{t}a", "{t}a", "{t}a", "y"])
    p.routes.map(&.retry).should eq([true, false, false, false, false, false, true])
    p.offsets.size.should eq(7)
    p.offsets.should eq(p.offsets.sort)
    bytes = p.buffer.to_slice
    p.offsets.each { |offset| bytes[offset].should eq('*'.ord.to_u8) }
    bytes[p.offsets[1], 15].should eq("*1\r\n$5\r\nMULTI\r\n".to_slice)
    bytes[p.offsets[5], 14].should eq("*1\r\n$4\r\nEXEC\r\n".to_slice)
  end

  it "records a pipelined script run by its first key" do
    p = Redis::Pipeline.new(routing: true)
    p.run(Redis::Script.new("return 1"), keys: ["k"])
    p.run(Redis::Script.new("return 2"))
    p.routes.map(&.key).should eq(["k", nil])
  end

  it "records nothing outside routing mode" do
    p = Redis::Pipeline.new
    p.get("a")
    p.multi { |tx| tx.get("b") }
    p.routing?.should be_false
    p.routes.should be_empty
    p.offsets.should be_empty
  end
```

Append to `spec/std/redis/client_spec.cr` inside `describe Redis::Client` (the `Script` fake answers `PING x` with `x`, `BAD` with `-ERR bad`, anything else with `+OK`, and records how many commands each socket read delivered in `chunks`):

```crystal
  it "sends pre-encoded bytes through call_raw, with ASKING when asked" do
    script = Script.new
    server = script.server
    client = Redis::Client.new(server.url)
    ping_x = "*2\r\n$4\r\nPING\r\n$1\r\nx\r\n".to_slice
    client.call_raw(ping_x).should eq("x")
    client.call_raw(ping_x, asking: true).should eq("x")
    script.chunks.last.should eq(2) # ASKING and PING left in one write
    expect_raises(Redis::CommandError, /bad/) { client.call_raw("*1\r\n$3\r\nBAD\r\n".to_slice) }
    client.close
    server.close
  end

  it "yields every reply of pipeline_raw in order and the failure afterwards" do
    script = Script.new
    server = script.server
    client = Redis::Client.new(server.url)
    two = "*2\r\n$4\r\nPING\r\n$1\r\na\r\n*2\r\n$4\r\nPING\r\n$1\r\nb\r\n".to_slice
    got = [] of {Int32, Redis::Value, Exception?}
    client.pipeline_raw(two, 2) { |i, value, error| got << {i, value, error} }
    got.should eq([{0, "a", nil}, {1, "b", nil}])
    three = "*2\r\n$4\r\nPING\r\n$1\r\na\r\n*1\r\n$3\r\nDIE\r\n*2\r\n$4\r\nPING\r\n$1\r\nb\r\n".to_slice
    got.clear
    expect_raises(Redis::ConnectionError) do
      client.pipeline_raw(three, 3) { |i, value, error| got << {i, value, error} }
    end
    got.size.should eq(3)
    got[0].should eq({0, "a", nil})
    got[1][2].should be_a(Redis::ConnectionError)
    got[2][2].should be_a(Redis::ConnectionError)
    client.close
    server.close
  end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/crystal spec spec/std/redis/pipeline_spec.cr spec/std/redis/client_spec.cr`
Expected: compile errors (`no argument named 'routing'`, `undefined method 'call_raw'`).

- [ ] **Step 3: `pipeline.cr` routing mode**

In `class Pipeline`, replace the ivars and `initialize` with:

```crystal
    # Number of queued commands.
    getter size = 0
    # :nodoc:
    #
    # The encoded commands, appended to the client's outbound buffer.
    # Internal to `Client#pipelined`.
    getter buffer = IO::Memory.new
    # :nodoc:
    #
    # Whether routes and offsets are recorded (`Cluster#pipelined`).
    getter? routing : Bool
    # :nodoc:
    #
    # In routing mode, one entry per wire command: the key it is routed by
    # and whether a redirect reply may be retried on its own.
    getter routes = [] of Route
    # :nodoc:
    #
    # In routing mode, the byte offset of every wire command in `buffer`.
    getter offsets = [] of Int32
    @futures = [] of AbstractFuture

    @script_cache : ScriptCache

    # :nodoc:
    #
    # One wire command's routing information. A `multi` block's commands
    # share the transaction's first key and are never retried one by one.
    record Route, key : String?, retry : Bool = true

    # :nodoc:
    #
    # *script_cache* is the owning client's; `Client#pipelined` and
    # `Connection#pipelined` pass theirs. The default is for a pipeline
    # built by hand, which then always sends `EVAL`. With *routing* the
    # pipeline also records `routes` and `offsets` for `Cluster`.
    def initialize(@script_cache : ScriptCache = ScriptCache.new, @routing : Bool = false)
    end

    # Appends one route and the offset the next write starts at.
    private def record(args : Indexable) : Nil
      @routes << Route.new(Cluster.route_key(args))
      @offsets << @buffer.bytesize
    end
```

In `script_run`, add `record(wire) if @routing` right before `RESP.write_command(@buffer, wire)`. In `typed_call`, add `record(args) if @routing` right before `RESP.write_command(@buffer, args)`.

Replace `multi` with:

```crystal
    def multi(& : Transaction ->) : Future(Array(Value))
      tx = Transaction.new(@script_cache, @routing)
      yield tx
      targets = tx.futures
      exec = ExecFuture.new(targets)
      if targets.empty?
        exec.resolve([] of Value)
        return exec
      end
      route = Route.new(tx.routes.find(&.key).try(&.key), false)
      if @routing
        @routes << route
        @offsets << @buffer.bytesize
      end
      RESP.write_command(@buffer, {"MULTI"})
      @futures << Future(Nil).new(->(v : Value) { nil })
      base = @buffer.bytesize
      @buffer.write(tx.buffer.to_slice)
      if @routing
        tx.offsets.each do |offset|
          @routes << route
          @offsets << base + offset
        end
        @routes << route
        @offsets << @buffer.bytesize
      end
      targets.each { |target| @futures << QueuedFuture.new(target) }
      RESP.write_command(@buffer, {"EXEC"})
      @futures << exec
      @size += targets.size + 2
      exec
    end
```

Keep the existing `multi` doc comment. `Transaction` inherits `initialize`, so `Transaction.new(@script_cache, @routing)` needs no change in `transaction.cr`; its `multi` override still raises.

- [ ] **Step 4: `client.cr` raw hooks**

Add near the top of `class Client` (after `property push_handler`):

```crystal
    # :nodoc:
    ASKING = "*1\r\n$6\r\nASKING\r\n".to_slice
```

Replace `pipelined`'s body (keep its doc comment) and add the two hooks after it:

```crystal
    def pipelined(& : Pipeline ->) : Array(Value)
      pipeline = Pipeline.new(@script_cache)
      yield pipeline
      # A closed client raises even when the block queued nothing.
      @mutex.synchronize { check_open }
      return [] of Value if pipeline.size == 0
      results = Array(Value).new(pipeline.size)
      pipeline_raw(pipeline.buffer.to_slice, pipeline.size) do |i, value, error|
        if error
          pipeline.fail(i, error)
        else
          pipeline.resolve(i, value)
          results << value
        end
      end
      results
    end

    # :nodoc:
    #
    # Appends *bytes*, already RESP-encoded commands, to the outbound
    # buffer and registers *count* replies, in one critical section so no
    # other fiber's command lands between them. Yields each reply with its
    # index in order, then yields the failure (with a nil value) for every
    # reply that will not arrive, and finally raises that failure.
    # `pipelined` and `Cluster` are built on it.
    def pipeline_raw(bytes : Bytes, count : Int32, & : Int32, Value, Exception? ->) : Nil
      waiters = Array(Waiter).new(count)
      wakeup, conn = @mutex.synchronize do
        check_open
        c = ensure_connected
        @out.write(bytes)
        count.times do
          w = take_waiter
          @pending.push(w)
          waiters << w
        end
        {@wakeup, c}
      end
      signal(wakeup)
      failure = nil
      delivered = 0
      begin
        waiters.each_with_index do |waiter, i|
          value, error = wait(waiter, conn)
          failure ||= error
          yield i, value, error
          delivered = i + 1
        end
      rescue ex : IO::TimeoutError
        # The timeout already tore the connection down; the replies not
        # yet delivered are failed with it before it propagates.
        (delivered...count).each { |j| yield j, nil, ex }
        raise ex
      end
      raise failure if failure
    end

    # :nodoc:
    #
    # Sends one pre-encoded command and returns its reply, raising an error
    # reply as `CommandError` exactly like `call`. With *asking* an
    # `ASKING` goes out contiguously ahead of it (a cluster `ASK`
    # redirect); its `OK` is discarded.
    def call_raw(bytes : Bytes, asking : Bool = false) : Value
      count = 1
      if asking
        joined = Bytes.new(ASKING.size + bytes.size)
        ASKING.copy_to(joined)
        bytes.copy_to(joined + ASKING.size)
        bytes = joined
        count = 2
      end
      replies = Array(Value).new(count)
      pipeline_raw(bytes, count) { |_, value, error| replies << value unless error }
      value = replies.last
      raise value if value.is_a?(CommandError)
      value
    end
```

- [ ] **Step 5: Run the specs to verify they pass**

Run: `bin/crystal spec spec/std/redis/`
Expected: every example passes (pipelines, transactions and the client's existing pipelined examples are unchanged in behaviour).

- [ ] **Step 6: Format and commit**

```bash
bin/crystal tool format src/redis spec/std/redis
git add src/redis/client.cr src/redis/pipeline.cr spec/std/redis/client_spec.cr spec/std/redis/pipeline_spec.cr
git commit -m "Redis: raw send hooks on Client and routing mode on Pipeline

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: `Cluster` core: topology, redirect loop, `call`, `nodes`, `close`, fake cluster helper

**Files:**
- Modify: `src/redis/cluster.cr` (replace the Task 1 placeholder doc; keep `SLOTS`, `KEYLESS`, `SPECIAL`, `key_slot`, `route_key` and their private helpers)
- Modify: `spec/support/redis.cr` (append `FakeCluster` inside `module RedisSpec`)
- Test: `spec/std/redis/cluster_spec.cr`

**Interfaces:**
- Consumes: `Client.new(uri, username:, password:, client_name:, protocol:, connect_timeout:, read_timeout:, tls_context:, max_bulk_size:, pool_size:)` (Task 5), `Client#call`, `Client#pipelined`, `Client#close`, `Client#scan_each`; `Connection.new`, `Connection.db_from`; `ScriptCache`; `ClusterError` (Task 1).
- Produces: `Redis::Cluster.new(seeds : Indexable, *, username:, password:, client_name:, protocol:, connect_timeout:, read_timeout:, tls_context:, max_bulk_size:, pool_size: = 4, max_redirects: = 5)` and `Cluster.new(seed : String | URI, **options)`; `Cluster::Node` (`host`, `port`, `id`, `master?`, `address`, `client`); `Cluster#call(*args)`, `#call(args : Indexable, *, key : String? = nil)`, `#command(*args, key : String)`, `#typed_call`, `#nodes`, `#node_for(key)`, `#refresh`, `#close`, `#closed?`, `#scan_each`; private `execute(slot : Int32?, redirect : CommandError? = nil, & : Node, Bool -> Value) : Value`, `route(slot : Int32?) : Node`, `refresh_if_stale`, `check_open`, `REDIRECT_CODES` (used by Task 8). Spec helper `RedisSpec::FakeCluster` (`new(count, ranges, &handler : FakeCluster, Int32, Array(String), IO ->)`, `ranges=`, `replicas`, `port(i)`, `url(i)`, `urls`, `accepted(i)`, `commands(i)`, `slots_calls`, `moved(slot, node)`, `ask(slot, node)`, `close`).

- [ ] **Step 1: Add `FakeCluster` to the spec support**

Append inside `module RedisSpec` in `spec/support/redis.cr` (before the closing `end` of the module):

```crystal
  # Scripted cluster nodes on random loopback ports. Every node answers
  # `HELLO`, and `CLUSTER SLOTS` from `ranges` (`{first, last, node}`
  # triples naming node indexes, plus `replicas` mapping a replica's index
  # to its master's); every other command goes to the handler, which gets
  # the cluster, the node index, the parsed command and the socket. `seen`
  # records every command with its node index in arrival order.
  class FakeCluster
    getter servers = [] of FakeServer
    getter seen = [] of {Int32, Array(String)}
    getter slots_calls = 0
    property ranges : Array({Int32, Int32, Int32})
    property replicas = {} of Int32 => Int32

    def initialize(count : Int32, @ranges : Array({Int32, Int32, Int32}),
                   &handler : FakeCluster, Int32, Array(String), IO ->)
      count.times do |index|
        @servers << FakeServer.new do |io|
          while cmd = FakeServer.read_command(io)
            @seen << {index, cmd}
            case cmd[0]
            when "HELLO"
              io << HELLO_REPLY
            when "CLUSTER"
              @slots_calls += 1
              io << slots_reply
            else
              handler.call(self, index, cmd, io)
            end
            io.flush unless io.closed?
          end
        end
      end
    end

    def port(index : Int32) : Int32
      @servers[index].port
    end

    def url(index : Int32) : String
      @servers[index].url
    end

    def urls : Array(String)
      @servers.map(&.url)
    end

    def accepted(index : Int32) : Int32
      @servers[index].accepted
    end

    # Every command node *index* saw except `HELLO`, in order.
    def commands(index : Int32) : Array(Array(String))
      @seen.select { |i, _| i == index }.map { |_, cmd| cmd }.reject { |cmd| cmd[0] == "HELLO" }
    end

    def moved(slot : Int32, node : Int32) : String
      "-MOVED #{slot} 127.0.0.1:#{port(node)}\r\n"
    end

    def ask(slot : Int32, node : Int32) : String
      "-ASK #{slot} 127.0.0.1:#{port(node)}\r\n"
    end

    def self.bulk(s : String) : String
      "$#{s.bytesize}\r\n#{s}\r\n"
    end

    # The RESP `CLUSTER SLOTS` reply for `ranges` and `replicas`.
    def slots_reply : String
      String.build do |s|
        s << '*' << @ranges.size << "\r\n"
        @ranges.each do |first, last, node|
          followers = @replicas.select { |_, master| master == node }.keys
          s << '*' << 3 + followers.size << "\r\n:" << first << "\r\n:" << last << "\r\n"
          ([node] + followers).each do |n|
            s << "*3\r\n" << FakeCluster.bulk("127.0.0.1") << ':' << port(n) << "\r\n" << FakeCluster.bulk("node#{n}")
          end
        end
      end
    end

    def close : Nil
      @servers.each(&.close)
    end
  end
```

- [ ] **Step 2: Write the failing specs**

`spec/std/redis/cluster_spec.cr`:

```crystal
require "spec"
require "wait_group"
require "../../support/redis"

# Two masters: node 0 owns 0..8191, node 1 owns 8192..16383.
# Slots: "b" 3300 and "k" 7629 on node 0; "a" 15495 and "x" 16287 on node 1.
private TWO = [{0, 8191, 0}, {8192, 16383, 1}]

# Default node behaviour; *override* may answer first and return true.
private def fake_two(&override : RedisSpec::FakeCluster, Int32, Array(String), IO -> Bool)
  RedisSpec::FakeCluster.new(2, TWO) do |fake, index, cmd, io|
    next if override.call(fake, index, cmd, io)
    case cmd[0]
    when "GET"    then io << "$1\r\nv\r\n"
    when "SET"    then io << "+OK\r\n"
    when "INCR"   then io << ":1\r\n"
    when "PING"   then io << "+PONG\r\n"
    when "DBSIZE" then io << ":#{index}\r\n"
    when "ASKING" then io << "+OK\r\n"
    when "MULTI"  then io << "+OK\r\n"
    when "EXEC"   then io << "*0\r\n"
    when "SCAN"   then io << "*2\r\n$1\r\n0\r\n*1\r\n$2\r\nk#{index}\r\n"
    when "DIE"    then io.close
    else               io << "+OK\r\n"
    end
  end
end

private def dead_port : Int32
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  server.close
  port
end

describe Redis::Cluster do
  it "loads the topology from the first reachable seed and routes by slot" do
    fake = fake_two { false }
    cluster = Redis::Cluster.new(["redis://127.0.0.1:#{dead_port}", fake.url(0)], connect_timeout: 1.second)
    cluster.closed?.should be_false
    fake.slots_calls.should eq(0)
    cluster.get("b").should eq("v")
    fake.slots_calls.should eq(1)
    cluster.get("a").should eq("v")
    cluster.set("x", "1").should eq("OK")
    fake.commands(0).should eq([["CLUSTER", "SLOTS"], ["GET", "b"]])
    fake.commands(1).should eq([["GET", "a"], ["SET", "x", "1"]])
    nodes = cluster.nodes
    nodes.size.should eq(2)
    nodes.map(&.address).should eq(["127.0.0.1:#{fake.port(0)}", "127.0.0.1:#{fake.port(1)}"])
    nodes.all?(&.master?).should be_true
    nodes[0].id.should eq("node0")
    cluster.node_for("b").should be(nodes[0])
    cluster.node_for("a").should be(nodes[1])
    cluster.close
    fake.close
  end

  it "routes an explicit key and raw commands" do
    fake = fake_two { false }
    cluster = Redis::Cluster.new(fake.url(1))
    cluster.command("FROB", "x", key: "b").should eq("OK")
    cluster.call(["FROB", "y"], key: "b").should eq("OK")
    cluster.call("FROB", "a").should eq("OK")
    fake.commands(0).should eq([["FROB", "x"], ["FROB", "y"]])
    fake.commands(1).should eq([["CLUSTER", "SLOTS"], ["FROB", "a"]])
    cluster.close
    fake.close
  end

  it "follows MOVED, patches the slot and reloads the topology once" do
    redirect = true
    fake = fake_two do |f, index, cmd, io|
      if index == 0 && cmd[0] == "GET" && redirect
        redirect = false
        io << f.moved(Redis::Cluster.key_slot(cmd[1]), 1)
        true
      else
        false
      end
    end
    cluster = Redis::Cluster.new(fake.url(0))
    cluster.get("b").should eq("v")
    fake.commands(1).should eq([["GET", "b"]])
    fake.slots_calls.should eq(1)
    # The next command reloads; the fake now says node 1 owns everything.
    fake.ranges = [{0, 16383, 1}]
    cluster.get("b").should eq("v")
    fake.slots_calls.should eq(2)
    fake.commands(1).should eq([["GET", "b"], ["GET", "b"]])
    cluster.node_for("b").address.should eq("127.0.0.1:#{fake.port(1)}")
    cluster.nodes.size.should eq(1)
    cluster.close
    fake.close
  end

  it "follows ASK with ASKING and leaves the slot map alone" do
    redirect = true
    fake = fake_two do |f, index, cmd, io|
      if index == 0 && cmd[0] == "GET" && redirect
        redirect = false
        io << f.ask(Redis::Cluster.key_slot(cmd[1]), 1)
        true
      else
        false
      end
    end
    cluster = Redis::Cluster.new(fake.url(0))
    cluster.get("b").should eq("v")
    fake.commands(1).should eq([["ASKING"], ["GET", "b"]])
    cluster.get("b").should eq("v")
    fake.slots_calls.should eq(1)
    fake.commands(0).should eq([["CLUSTER", "SLOTS"], ["GET", "b"], ["GET", "b"]])
    cluster.close
    fake.close
  end

  it "retries TRYAGAIN" do
    attempts = 0
    fake = fake_two do |f, index, cmd, io|
      if cmd[0] == "GET" && (attempts += 1) <= 2
        io << "-TRYAGAIN Multiple keys request during rehashing of slot\r\n"
        true
      else
        false
      end
    end
    cluster = Redis::Cluster.new(fake.url(0))
    cluster.get("b").should eq("v")
    fake.commands(0).count(["GET", "b"]).should eq(3)
    cluster.close
    fake.close
  end

  it "gives up after max_redirects and passes other errors through" do
    fake = fake_two do |f, index, cmd, io|
      case cmd[0]
      when "GET"
        io << f.moved(Redis::Cluster.key_slot(cmd[1]), 1 - index)
        true
      when "INCR"
        io << "-WRONGTYPE Operation against a key holding the wrong kind of value\r\n"
        true
      else
        false
      end
    end
    cluster = Redis::Cluster.new(fake.url(0), max_redirects: 3)
    error = expect_raises(Redis::ClusterError, /too many redirects/) { cluster.get("b") }
    error.cause.should be_a(Redis::CommandError)
    (fake.commands(0).count(["GET", "b"]) + fake.commands(1).count(["GET", "b"])).should eq(4)
    expect_raises(Redis::CommandError, /WRONGTYPE/) { cluster.incr("b") }
    cluster.close
    fake.close
  end

  it "marks the topology stale after a lost connection and raises" do
    fake = fake_two { false }
    cluster = Redis::Cluster.new(fake.url(0))
    cluster.get("b").should eq("v")
    expect_raises(Redis::ConnectionError) { cluster.call("DIE", "b") }
    fake.slots_calls.should eq(1)
    cluster.get("b").should eq("v")
    fake.slots_calls.should eq(2)
    # The seed probe, the node client, and its reconnect.
    fake.accepted(0).should eq(3)
    cluster.close
    fake.close
  end

  it "coalesces concurrent reloads" do
    fake = fake_two do |f, index, cmd, io|
      if index == 0 && cmd[0] == "GET"
        io << f.moved(Redis::Cluster.key_slot(cmd[1]), 1)
        true
      else
        false
      end
    end
    cluster = Redis::Cluster.new(fake.url(0))
    cluster.get("a").should eq("v")
    fake.slots_calls.should eq(1)
    fake.ranges = [{0, 16383, 1}]
    results = Array(String?).new(20, nil)
    wg = WaitGroup.new(20)
    20.times do |i|
      spawn do
        begin
          results[i] = cluster.get("b")
        ensure
          wg.done
        end
      end
    end
    wg.wait
    results.should eq(Array(String?).new(20, "v"))
    # Every MOVED marked the map stale; the next round reloads exactly once.
    wg = WaitGroup.new(20)
    20.times do
      spawn do
        begin
          cluster.get("b").should eq("v")
        ensure
          wg.done
        end
      end
    end
    wg.wait
    fake.slots_calls.should eq(2)
    cluster.close
    fake.close
  end

  it "sends keyless commands to a master and exposes per-node clients" do
    fake = fake_two { false }
    cluster = Redis::Cluster.new(fake.url(1))
    cluster.ping.should eq("PONG")
    (fake.commands(0).includes?(["PING"]) || fake.commands(1).includes?(["PING"])).should be_true
    cluster.nodes.map { |n| n.client.dbsize }.sort.should eq([0_i64, 1_i64])
    keys = [] of String
    cluster.scan_each { |key| keys << key }
    keys.sort.should eq(["k0", "k1"])
    cluster.close
    fake.close
  end

  it "keeps node identity across a reload and closes nodes that vanish" do
    fake = fake_two { false }
    cluster = Redis::Cluster.new(fake.url(0))
    cluster.get("b")
    before = cluster.node_for("b")
    client = before.client
    cluster.refresh
    fake.slots_calls.should eq(2)
    cluster.node_for("b").should be(before)
    before.client.should be(client)
    client.closed?.should be_false
    fake.ranges = [{0, 16383, 1}]
    cluster.refresh
    client.closed?.should be_true
    cluster.nodes.size.should eq(1)
    cluster.close
    fake.close
  end

  it "records replicas but never routes to them" do
    fake = fake_two { false }
    fake.ranges = [{0, 16383, 0}]
    fake.replicas[1] = 0
    cluster = Redis::Cluster.new(fake.url(0))
    cluster.get("a").should eq("v")
    fake.commands(1).should be_empty
    nodes = cluster.nodes
    nodes.size.should eq(2)
    nodes[0].master?.should be_true
    nodes[1].master?.should be_false
    nodes[1].address.should eq("127.0.0.1:#{fake.port(1)}")
    expect_raises(ArgumentError, /replica/) { nodes[1].client }
    cluster.close
    fake.close
  end

  it "raises ClusterError when no seed answers or none is a cluster" do
    cluster = Redis::Cluster.new("redis://127.0.0.1:#{dead_port}", connect_timeout: 1.second)
    error = expect_raises(Redis::ClusterError, /no cluster node reachable/) { cluster.get("b") }
    error.cause.should be_a(Redis::ConnectionError)
    cluster.close

    standalone = RedisSpec::FakeServer.new do |io|
      while cmd = RedisSpec::FakeServer.read_command(io)
        io << (cmd[0] == "HELLO" ? RedisSpec::HELLO_REPLY : "-ERR This instance has cluster support disabled\r\n")
        io.flush
      end
    end
    cluster = Redis::Cluster.new(standalone.url)
    error = expect_raises(Redis::ClusterError, /cluster support disabled/) { cluster.get("b") }
    error.cause.should be_a(Redis::CommandError)
    cluster.close
    standalone.close
  end

  it "rejects bad seeds and options" do
    expect_raises(ArgumentError, /database/) { Redis::Cluster.new("redis://localhost:7000/1") }
    expect_raises(ArgumentError, /scheme/) { Redis::Cluster.new("unix:///tmp/redis.sock") }
    expect_raises(ArgumentError, /seed/) { Redis::Cluster.new([] of String) }
    expect_raises(ArgumentError, /protocol/) { Redis::Cluster.new("redis://localhost:7000", protocol: 1) }
    expect_raises(ArgumentError, /max_redirects/) { Redis::Cluster.new("redis://localhost:7000", max_redirects: -1) }
    expect_raises(ArgumentError, /pool_size/) { Redis::Cluster.new("redis://localhost:7000", pool_size: 0) }
  end

  it "closes every node client" do
    fake = fake_two { false }
    cluster = Redis::Cluster.new(fake.url(0))
    cluster.get("b")
    cluster.get("a")
    clients = cluster.nodes.map(&.client)
    clients.size.should eq(2)
    cluster.close
    cluster.closed?.should be_true
    clients.all?(&.closed?).should be_true
    expect_raises(Redis::ConnectionError, /closed/) { cluster.get("b") }
    expect_raises(Redis::ConnectionError, /closed/) { cluster.refresh }
    fake.close
  end
end
```

- [ ] **Step 3: Run them to verify they fail**

Run: `bin/crystal spec spec/std/redis/cluster_spec.cr`
Expected: compile error (`undefined method 'new' for Redis::Cluster.class` or `undefined constant RedisSpec::FakeCluster` if Step 1 was skipped).

- [ ] **Step 4: Write the rest of `cluster.cr`**

Replace the placeholder doc comment and add everything below inside `class Cluster`, keeping the Task 1 constants and class methods where they are.

```crystal
module Redis
  # A client for Redis Cluster: routes every command to the master that
  # owns its key's hash slot, follows `MOVED`, `ASK` and `TRYAGAIN`
  # redirects, and reloads the slot map when the cluster changes. Each
  # master is driven by its own multiplexed `Client`, so any number of
  # fibers can share a `Cluster`.
  #
  # ```
  # cluster = Redis::Cluster.new(["redis://10.0.0.1:7000", "redis://10.0.0.2:7000"])
  # cluster.set("user:1", "x")
  # cluster.get("user:1")                            # => "x"
  # cluster.pipelined { |p| p.get("a"); p.get("b") } # split by node, replies in order
  # cluster.multi { |tx| tx.incr("{acct}a"); tx.incr("{acct}b") }
  # cluster.close
  # ```
  #
  # Keyed commands are routed by `Cluster.route_key`; commands with no key
  # (`PING`, `INFO`, `DBSIZE`, ...) go to one master picked at random, and
  # `nodes` gives every node's own `Client` for per-node administration.
  # Multi-key commands must keep their keys in one slot (use hash tags):
  # the server's `CROSSSLOT` error is raised as a `CommandError` otherwise.
  # `scan_each` iterates every master in turn; a bare `scan` step lands on
  # a random master and is of little use here. `run` shares one script
  # cache across the cluster: a script one node has not seen yet answers
  # `NOSCRIPT` there, which `run` handles by sending `EVAL`.
  #
  # The slot map is loaded on the first command and reloaded lazily: a
  # `MOVED` reply or a lost connection marks it stale and the next command
  # reloads it before routing, with concurrent callers sharing one reload.
  # A lost connection is never retried, exactly as with `Client`;
  # redirects are followed up to `max_redirects` times, then
  # `ClusterError` is raised. Replicas are listed in `nodes` but never
  # routed to.
  #
  # `close` is required, as for `Client`.
  class Cluster
    include Commands
    include Commands::ScriptFallback

    # :nodoc:
    getter script_cache = ScriptCache.new

    # :nodoc:
    REDIRECT_CODES = {"MOVED", "ASK", "TRYAGAIN"}

    # ... SLOTS, KEYLESS, SPECIAL, key_slot, route_key and helpers from Task 1 ...

    # One node of the cluster as the last topology load reported it.
    class Node
      # The host as reported by `CLUSTER SLOTS`.
      getter host : String
      # The port.
      getter port : Int32
      # The cluster node id (`""` for a node first seen in a redirect,
      # until the next reload).
      getter id : String
      # Whether the node is a master; only masters are routed to.
      getter? master : Bool
      @client : Client?

      # :nodoc:
      def initialize(@host : String, @port : Int32, @id : String, @master : Bool,
                     @factory : Proc(String, Int32, Client))
      end

      # `"host:port"`.
      def address : String
        "#{@host}:#{@port}"
      end

      # The node's multiplexed client, created on first use with the
      # cluster's options and connected on its first command. Raises
      # `ArgumentError` on a replica.
      def client : Client
        raise ArgumentError.new("#{address} is a replica") unless @master
        @client ||= @factory.call(@host, @port)
      end

      # :nodoc:
      def master=(@master : Bool)
      end

      # :nodoc:
      def id=(@id : String)
      end

      # :nodoc:
      def close : Nil
        @client.try &.close
        @client = nil
      end

      def to_s(io : IO) : Nil
        io << address << (@master ? " (master)" : " (replica)")
      end
    end

    @mutex = Mutex.new
    @refresh_mutex = Mutex.new
    @slots = Array(Node?).new(SLOTS, nil)
    @nodes = {} of String => Node
    @masters = [] of Node
    @stale = true
    @closed = false
    @seeds : Array(URI)
    @scheme : String
    @username : String?
    @password : String?

    # Creates a cluster client. *seeds* are `redis://host:port` or
    # `rediss://host:port` URLs (`String` or `URI`) of any nodes; the rest
    # of the cluster is discovered from whichever answers first, and the
    # seeds' scheme (with *tls_context*) is used for every node. The other
    # options are those of `Client.new` and apply to every node's client;
    # there is no `db` because a cluster has only database 0. Credentials
    # in the first seed's URL are used when *username*/*password* are not
    # given. Nothing is connected until the first command. Raises
    # `ArgumentError` for no seeds, a seed with another scheme or a
    # database other than 0, *protocol* outside `2..3`, a non-positive
    # *pool_size* or a negative *max_redirects*.
    def initialize(seeds : Indexable, *, username : String? = nil, password : String? = nil,
                   @client_name : String? = nil, protocol @protocol_option : Int32 = 3,
                   @connect_timeout : Time::Span = 5.seconds, @read_timeout : Time::Span? = nil,
                   @tls_context : OpenSSL::SSL::Context::Client? = nil, @max_bulk_size : Int32 = RESP::MAX_BULK_SIZE,
                   @pool_size : Int32 = 4, @max_redirects : Int32 = 5)
      raise ArgumentError.new("at least one seed is required") if seeds.empty?
      raise ArgumentError.new("protocol must be 2 or 3, got #{@protocol_option}") unless @protocol_option == 2 || @protocol_option == 3
      raise ArgumentError.new("pool_size must be positive, got #{@pool_size}") unless @pool_size > 0
      raise ArgumentError.new("max_redirects must not be negative, got #{@max_redirects}") if @max_redirects < 0
      @seeds = Array(URI).new(seeds.size)
      seeds.each do |seed|
        uri = case seed
              when URI    then seed
              when String then URI.parse(seed)
              else             raise ArgumentError.new("a seed must be a String or URI, got #{seed.class}")
              end
        unless uri.scheme == "redis" || uri.scheme == "rediss"
          raise ArgumentError.new("unsupported cluster URL scheme #{uri.scheme.inspect} in #{uri}; expected redis or rediss")
        end
        if (db = Connection.db_from(uri)) && db != 0
          raise ArgumentError.new("a cluster has only database 0, got database #{db} in #{uri}")
        end
        @seeds << uri
      end
      @scheme = @seeds.first.scheme.not_nil!
      @username = username || @seeds.first.user.presence
      @password = password || @seeds.first.password.presence
    end

    # :ditto:
    def self.new(seed : String | URI, **options)
      new([seed] of String | URI, **options)
    end

    # Sends *args* to the master owning the routing key's slot (see
    # `Cluster.route_key`; *key* overrides it) and returns the reply,
    # following redirects. Raises `CommandError` for an error reply,
    # `ConnectionError` if a node's connection cannot be opened or drops,
    # `IO::TimeoutError` if `read_timeout` elapses, `ClusterError` if the
    # topology cannot be loaded or `max_redirects` is exceeded.
    def call(*args : RESP::Arg) : Value
      call(args)
    end

    # :ditto:
    def call(args : Indexable, *, key : String? = nil) : Value
      route = key || Cluster.route_key(args)
      slot = route ? Cluster.key_slot(route) : nil
      execute(slot) { |node, asking| asking ? ask(node, args) : node.client.call(args) }
    end

    # Sends an arbitrary command routed by *key*, for a command whose key
    # `Cluster.route_key` does not find (a module command, for example).
    #
    # ```
    # cluster.command("MYMODULE.DO", "k", 1, key: "k")
    # ```
    def command(*args : RESP::Arg, key : String)
      call(args, key: key)
    end

    # :nodoc:
    def typed_call(args : Indexable, &block : Value -> T) forall T
      block.call(call(args))
    end

    # Iterates every key matching *match* on every master in turn. `SCAN`
    # cursors are per node, so this is the only sensible form of `SCAN`
    # on a cluster.
    def scan_each(*, match : String? = nil, count : Int? = nil, type : String? = nil, & : String ->) : Nil
      check_open
      refresh_if_stale
      masters = @mutex.synchronize { @masters.dup }
      masters.each do |node|
        node.client.scan_each(match: match, count: count, type: type) { |key| yield key }
      end
    end

    # Every node the last topology load reported, masters first in the
    # order `CLUSTER SLOTS` listed them. Empty before the first command.
    def nodes : Array(Node)
      @mutex.synchronize { @masters + @nodes.values.reject(&.master?) }
    end

    # The master owning *key*'s slot, after reloading the topology if it is
    # stale. Raises `ClusterError` if the cluster has no masters.
    def node_for(key : String) : Node
      check_open
      route(Cluster.key_slot(key))
    end

    # Reloads the slot map now. Raises `ClusterError` if no known master
    # and no seed answers `CLUSTER SLOTS`.
    def refresh : Nil
      check_open
      @refresh_mutex.synchronize { load_topology }
    end

    # Whether `close` has been called.
    def closed? : Bool
      @closed
    end

    # Closes every node's client. Every later call raises `ConnectionError`.
    def close : Nil
      nodes = @mutex.synchronize do
        @closed = true
        @nodes.values
      end
      nodes.each(&.close)
    end

    private def check_open : Nil
      raise ConnectionError.new("cluster is closed") if @closed
    end

    # The redirect loop. Picks the node for *slot* (any master when nil or
    # unassigned) and calls *send* with it; a `MOVED` reply patches the
    # slot, marks the map stale and retries on the named node; an `ASK`
    # retries there once with the asking flag; a `TRYAGAIN` retries after
    # a growing pause. *redirect* is a redirect reply already received
    # (from a pipeline), processed before the first send.
    private def execute(slot : Int32?, redirect : CommandError? = nil, & : Node, Bool -> Value) : Value
      check_open
      node = route(slot)
      asking = false
      attempt = 0
      pending = redirect
      last = nil
      while attempt <= @max_redirects
        error = pending || begin
          return yield node, asking
        rescue ex : CommandError
          ex
        rescue ex : ConnectionError
          @mutex.synchronize { @stale = true }
          raise ex
        end
        pending = nil
        case error.code
        when "MOVED"
          moved_slot, node = parse_redirect(error)
          @mutex.synchronize do
            @slots[moved_slot] = node
            @stale = true
          end
          asking = false
        when "ASK"
          _, node = parse_redirect(error)
          asking = true
        when "TRYAGAIN"
          sleep({10.milliseconds * (1 << attempt), 500.milliseconds}.min)
        else
          raise error
        end
        last = error
        attempt += 1
      end
      raise ClusterError.new("too many redirects (#{@max_redirects}) for slot #{slot}: #{last.try(&.message)}", cause: last)
    end

    # Sends `ASKING` and *args* contiguously on *node*'s client and returns
    # the command's reply, raising an error reply so the loop can act on
    # a further redirect.
    private def ask(node : Node, args : Indexable) : Value
      replies = node.client.pipelined do |p|
        p.command("ASKING")
        p.command(args)
      end
      value = replies[1]
      raise value if value.is_a?(CommandError)
      value
    end

    # `MOVED 3999 127.0.0.1:6381` → `{3999, node}`; same for `ASK`.
    private def parse_redirect(error : CommandError) : {Int32, Node}
      parts = error.message.to_s.split(' ')
      slot = parts[1]?.try(&.to_i?)
      address = parts[2]?
      unless slot && address && 0 <= slot < SLOTS
        raise ProtocolError.new("malformed redirect #{error.message.inspect}")
      end
      colon = address.rindex(':') || raise ProtocolError.new("malformed redirect #{error.message.inspect}")
      host = address[0, colon]
      port = address[colon + 1..].to_i? || raise ProtocolError.new("malformed redirect #{error.message.inspect}")
      host = @seeds.first.host.presence || "localhost" if host.empty?
      {slot, node_at(host, port)}
    end

    # The known node at *host*:*port*, or a new master node for an address
    # the last reload did not list (the next reload fills in its id).
    private def node_at(host : String, port : Int32) : Node
      address = "#{host}:#{port}"
      @mutex.synchronize do
        @nodes[address] ||= new_node(host, port, "", true)
      end
    end

    # The node for *slot*, any master when *slot* is nil or unassigned,
    # after reloading a stale map. Raises `ClusterError` with no masters.
    private def route(slot : Int32?) : Node
      refresh_if_stale
      @mutex.synchronize do
        raise ClusterError.new("cluster has no masters") if @masters.empty?
        (slot ? @slots[slot] : nil) || @masters.sample
      end
    end

    private def refresh_if_stale : Nil
      return unless @stale
      @refresh_mutex.synchronize { load_topology if @stale }
    end

    # Under `@refresh_mutex`. Asks every known master, then every seed not
    # already tried, for `CLUSTER SLOTS`, and installs the first answer.
    private def load_topology : Nil
      last_error = nil
      masters = @mutex.synchronize { @masters.dup }
      masters.each do |node|
        begin
          install(node.client.call({"CLUSTER", "SLOTS"}), node.host)
          return
        rescue ex : ConnectionError | CommandError | IO::TimeoutError
          last_error = ex
        end
      end
      tried = masters.map(&.address)
      @seeds.each do |seed|
        host = seed.host.presence || "localhost"
        port = seed.port || 6379
        next if tried.includes?("#{host}:#{port}")
        begin
          conn = Connection.new(node_uri(host, port), username: @username, password: @password,
            client_name: @client_name, protocol: @protocol_option, connect_timeout: @connect_timeout,
            read_timeout: @read_timeout, tls_context: @tls_context, max_bulk_size: @max_bulk_size)
          reply = begin
            conn.call({"CLUSTER", "SLOTS"})
          ensure
            conn.close
          end
          install(reply, host)
          return
        rescue ex : ConnectionError | CommandError | IO::TimeoutError
          last_error = ex
        end
      end
      raise ClusterError.new("no cluster node reachable: #{last_error.try(&.message)}", cause: last_error)
    end

    private def node_uri(host : String, port : Int32) : URI
      URI.new(scheme: @scheme, host: host, port: port)
    end

    private def node_client(host : String, port : Int32) : Client
      Client.new(node_uri(host, port), username: @username, password: @password, client_name: @client_name,
        protocol: @protocol_option, connect_timeout: @connect_timeout, read_timeout: @read_timeout,
        tls_context: @tls_context, max_bulk_size: @max_bulk_size, pool_size: @pool_size)
    end

    private def new_node(host : String, port : Int32, id : String, master : Bool) : Node
      Node.new(host, port, id, master, ->node_client(String, Int32))
    end

    # Parses a `CLUSTER SLOTS` reply (`[[first, last, [host, port, id, ...],
    # replica...], ...]`) and swaps the topology in, keeping the `Node`
    # objects (and their clients) of addresses already known. *asked_host*
    # stands in for a node whose own address the server left empty. Nodes
    # that disappeared, and masters that turned replica, are closed.
    private def install(reply : Value, asked_host : String) : Nil
      ranges = reply.as?(Array) || raise ProtocolError.new("unexpected CLUSTER SLOTS reply #{reply.inspect}")
      slots = Array(Node?).new(SLOTS, nil)
      nodes = {} of String => Node
      masters = [] of Node
      old = @mutex.synchronize { @nodes.dup }
      ranges.each do |range|
        entry = range.as?(Array) || raise ProtocolError.new("unexpected CLUSTER SLOTS range #{range.inspect}")
        first = entry[0]?.as?(Int64)
        last = entry[1]?.as?(Int64)
        unless first && last && 0 <= first && first <= last && last < SLOTS
          raise ProtocolError.new("unexpected CLUSTER SLOTS range #{range.inspect}")
        end
        master = nil
        entry.each_with_index do |item, i|
          next if i < 2
          desc = item.as?(Array) || raise ProtocolError.new("unexpected CLUSTER SLOTS node #{item.inspect}")
          reported = desc[0]?.as?(String)
          host = reported.nil? || reported.empty? || reported == "?" ? asked_host : reported
          port = desc[1]?.as?(Int64) || raise ProtocolError.new("unexpected CLUSTER SLOTS node #{item.inspect}")
          id = desc[2]?.as?(String) || ""
          address = "#{host}:#{port}"
          is_master = i == 2
          node = nodes[address]? || old[address]? || new_node(host, port.to_i, id, is_master)
          node.master = is_master
          node.id = id unless id.empty?
          nodes[address] = node
          if is_master
            masters << node unless masters.includes?(node)
            master = node
          end
        end
        (first..last).each { |slot| slots[slot] = master }
      end
      gone = @mutex.synchronize do
        removed = @nodes.values.reject { |node| nodes.has_key?(node.address) }
        @slots = slots
        @nodes = nodes
        @masters = masters
        @stale = false
        removed
      end
      gone.each(&.close)
      nodes.each_value { |node| node.close unless node.master? }
    end
  end
end
```

Notes for the implementer:
- `error = pending || begin ... rescue ... end` types `error` as `CommandError` because the `begin` body returns from the method and the `ConnectionError` clause raises. If the compiler still reports a `Nil` in `error.code`, split it: `error = pending; unless error; error = begin ... end; end; error = error.not_nil!` is not acceptable (hides a real nil); instead check that both rescue clauses are spelled exactly as above.
- `@nodes[address] ||= new_node(...)` on a `Hash(String, Node)` is `@nodes[address]? || (@nodes[address] = new_node(...))`.
- `route` may return a node the map marks for the slot even after a `MOVED` patched it, which is the point of the patch.

- [ ] **Step 5: Run the specs to verify they pass**

Run: `bin/crystal spec spec/std/redis/cluster_spec.cr`
Expected: 14 examples, 0 failures. Then `bin/crystal spec spec/std/redis/` to confirm nothing else moved.

Debugging hints: a hang in "follows ASK" means `ASKING` was not answered by the fake (check the `fake_two` case list); `fake.accepted(0).should eq(3)` off by one means the seed probe reused a node client (the seed loop must open a plain `Connection`).

- [ ] **Step 6: Format and commit**

```bash
bin/crystal tool format src/redis spec/std/redis spec/support/redis.cr
git add src/redis/cluster.cr spec/support/redis.cr spec/std/redis/cluster_spec.cr
git commit -m "Redis: Cluster with slot routing, redirects and lazy topology reload

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: `Cluster#pipelined` and `Cluster#multi`

**Files:**
- Modify: `src/redis/cluster.cr` (add `pipelined`, `multi`, private `run_group`, `command_end`)
- Test: `spec/std/redis/cluster_spec.cr` (append a `describe "Redis::Cluster#pipelined"` block)

**Interfaces:**
- Consumes: `Pipeline.new(script_cache, routing: true)`, `Pipeline#routes`, `#offsets`, `#buffer`, `#size`, `#resolve`, `#fail` (Tasks 2, 6); `Client#pipeline_raw`, `Client#call_raw` (Task 6); `execute(slot, redirect, &)`, `route`, `refresh_if_stale`, `REDIRECT_CODES` (Task 7).
- Produces: `Cluster#pipelined(& : Pipeline ->) : Array(Value)`, `Cluster#multi(& : Transaction ->) : Array(Value)`.

- [ ] **Step 1: Write the failing specs**

Append to `spec/std/redis/cluster_spec.cr` (after the `describe Redis::Cluster` block; `fake_two` and `TWO` are the file's private helpers). Add this helper next to `dead_port`:

```crystal
private def values(*items) : Array(Redis::Value)
  Array(Redis::Value).new(items.size) { |i| items[i].as(Redis::Value) }
end
```

Then:

```crystal
describe "Redis::Cluster#pipelined" do
  it "splits by node, keeps caller order and resolves every future" do
    fake = fake_two { false }
    cluster = Redis::Cluster.new(fake.url(0))
    futures = [] of Redis::Future(String?)
    replies = cluster.pipelined do |p|
      futures << p.get("a") # node 1
      futures << p.get("b") # node 0
      p.set("x", "1")       # node 1
      futures << p.get("k") # node 0
      p.command("PING")     # any master
    end
    replies.size.should eq(5)
    replies[0..3].should eq(values("v", "v", "OK", "v"))
    replies[4].should eq("PONG")
    futures.map(&.value).should eq(["v", "v", "v"])
    fake.commands(0).reject { |c| c[0] == "PING" }.should eq([["CLUSTER", "SLOTS"], ["GET", "b"], ["GET", "k"]])
    fake.commands(1).reject { |c| c[0] == "PING" }.should eq([["GET", "a"], ["SET", "x", "1"]])
    cluster.pipelined { |p| }.should eq([] of Redis::Value)
    cluster.close
    fake.close
  end

  it "re-issues a redirected command on its own" do
    moved = true
    asked = true
    fake = fake_two do |fk, index, cmd, io|
      if index == 0 && cmd[0] == "GET" && cmd[1] == "b" && moved
        moved = false
        io << fk.moved(Redis::Cluster.key_slot("b"), 1)
        true
      elsif index == 0 && cmd[0] == "GET" && cmd[1] == "k" && asked
        asked = false
        io << fk.ask(Redis::Cluster.key_slot("k"), 1)
        true
      else
        false
      end
    end
    cluster = Redis::Cluster.new(fake.url(0))
    b = k = nil
    replies = cluster.pipelined do |p|
      p.get("a")
      b = p.get("b")
      k = p.get("k")
    end
    replies.should eq(values("v", "v", "v"))
    b.not_nil!.value.should eq("v")
    k.not_nil!.value.should eq("v")
    fake.commands(1).should eq([["GET", "a"], ["GET", "b"], ["ASKING"], ["GET", "k"]])
    cluster.close
    fake.close
  end

  it "keeps a multi block contiguous on one node" do
    fake = fake_two do |fk, index, cmd, io|
      if cmd[0] == "EXEC"
        io << "*2\r\n:1\r\n:2\r\n"
        true
      else
        false
      end
    end
    cluster = Redis::Cluster.new(fake.url(0))
    a = b = nil
    exec = nil
    replies = cluster.pipelined do |p|
      p.get("b")
      exec = p.multi do |tx|
        a = tx.incr("{t}a")
        b = tx.incr("{t}b")
      end
      p.get("k")
    end
    replies.size.should eq(6)
    exec.not_nil!.value.should eq(values(1_i64, 2_i64))
    a.not_nil!.value.should eq(1_i64)
    b.not_nil!.value.should eq(2_i64)
    fake.commands(1).should eq([["MULTI"], ["INCR", "{t}a"], ["INCR", "{t}b"], ["EXEC"]])
    fake.commands(0).should eq([["CLUSTER", "SLOTS"], ["GET", "b"], ["GET", "k"]])
    cluster.multi { |tx| tx.incr("{t}a"); tx.incr("{t}b") }.should eq(values(1_i64, 2_i64))
    cluster.close
    fake.close
  end

  it "surfaces CROSSSLOT and does not retry a redirect inside a transaction" do
    fake = fake_two do |fk, index, cmd, io|
      case cmd[0]
      when "MGET"
        io << "-CROSSSLOT Keys in request don't hash to the same slot\r\n"
        true
      when "INCR"
        io << fk.moved(Redis::Cluster.key_slot(cmd[1]), 1 - index)
        true
      when "EXEC"
        io << "-EXECABORT Transaction discarded because of previous errors.\r\n"
        true
      else
        false
      end
    end
    cluster = Redis::Cluster.new(fake.url(0))
    expect_raises(Redis::CommandError, /CROSSSLOT/) { cluster.mget("a", "b") }
    f = nil
    expect_raises(Redis::CommandError, /EXECABORT/) { cluster.multi { |tx| f = tx.incr("{t}a") } }
    expect_raises(Redis::CommandError, /MOVED/) { f.not_nil!.value }
    fake.commands(0).count { |c| c[0] == "INCR" }.should eq(0)
    fake.commands(1).count { |c| c[0] == "INCR" }.should eq(1)
    cluster.close
    fake.close
  end

  it "fails one node's futures on a lost connection and raises after the rest answered" do
    fake = fake_two { false }
    cluster = Redis::Cluster.new(fake.url(0))
    cluster.ping
    fa = fb = nil
    expect_raises(Redis::ConnectionError) do
      cluster.pipelined do |p|
        fa = p.get("a")
        p.command("DIE", "b")
        fb = p.get("b")
      end
    end
    fa.not_nil!.value.should eq("v")
    expect_raises(Redis::ConnectionError) { fb.not_nil!.value }
    fake.slots_calls.should eq(1)
    cluster.get("a").should eq("v")
    fake.slots_calls.should eq(2)
    cluster.close
    fake.close
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/crystal spec spec/std/redis/cluster_spec.cr`
Expected: compile error, `undefined method 'pipelined' for Redis::Cluster`.

- [ ] **Step 3: Implement**

Add inside `class Cluster` (after `typed_call`):

```crystal
    # Runs the block against a `Pipeline`, sends every node its commands in
    # one write with the nodes in parallel, and returns the raw replies in
    # the order the block queued them. Commands are grouped by the master
    # owning their key's slot; keyless commands all go to one master.
    # Error replies stay in the array as `CommandError` values (and are
    # raised by the matching `Future#value`). A `MOVED`, `ASK` or
    # `TRYAGAIN` reply to a single command is followed for that command
    # alone; a `multi` block stays on its node and a redirect at queue
    # time fails it with `EXECABORT` like any queue-time error. A lost
    # connection or `read_timeout` on one node fails that node's futures
    # with it while the other nodes' replies are kept, then the first such
    # failure is raised once every node has answered.
    #
    # ```
    # first = nil
    # cluster.pipelined do |p|
    #   p.set("a", "1")
    #   first = p.get("b")
    # end
    # first.not_nil!.value
    # ```
    def pipelined(& : Pipeline ->) : Array(Value)
      pipeline = Pipeline.new(@script_cache, routing: true)
      yield pipeline
      check_open
      size = pipeline.size
      return [] of Value if size == 0
      refresh_if_stale
      routes = pipeline.routes
      offsets = pipeline.offsets
      bytes = pipeline.buffer.to_slice
      groups = {} of Node => Array(Int32)
      order = [] of Node
      @mutex.synchronize do
        raise ClusterError.new("cluster has no masters") if @masters.empty?
        fallback = @masters.sample
        size.times do |i|
          key = routes[i].key
          node = (key ? @slots[Cluster.key_slot(key)] : nil) || fallback
          indices = groups[node]?
          unless indices
            indices = groups[node] = [] of Int32
            order << node
          end
          indices << i
        end
      end
      values = Array(Value).new(size, nil)
      failures = Array(Exception?).new(size, nil)
      wg = WaitGroup.new
      order.each_with_index do |node, position|
        indices = groups[node]
        if position == order.size - 1
          run_group(node, indices, bytes, offsets, values, failures)
        else
          wg.add(1)
          spawn do
            begin
              run_group(node, indices, bytes, offsets, values, failures)
            ensure
              wg.done
            end
          end
        end
      end
      wg.wait
      size.times do |i|
        next if failures[i]
        value = values[i]
        next unless value.is_a?(CommandError) && routes[i].retry && REDIRECT_CODES.includes?(value.code)
        slot = routes[i].key.try { |key| Cluster.key_slot(key) }
        command = bytes[offsets[i], command_end(offsets, i, bytes.size) - offsets[i]]
        begin
          values[i] = execute(slot, value) { |node, asking| node.client.call_raw(command, asking) }
        rescue ex : CommandError
          values[i] = ex
        rescue ex : ClusterError | ConnectionError | IO::TimeoutError
          failures[i] = ex
        end
      end
      results = Array(Value).new(size)
      first_failure = nil
      size.times do |i|
        if error = failures[i]
          pipeline.fail(i, error)
          first_failure ||= error
        else
          pipeline.resolve(i, values[i])
          results << values[i]
        end
      end
      raise first_failure if first_failure
      results
    end

    # Runs the block's commands as one `MULTI`..`EXEC` transaction on the
    # master owning the first keyed command's slot, in one write, and
    # returns the `EXEC` array; every key must be in that slot (hash tags).
    # Raises `AbortedError` if a key marked with `watch` changed, the
    # `EXECABORT` `CommandError` if a command was rejected at queue time
    # (a `MOVED` at queue time included), `ConnectionError` if the socket
    # drops. Error replies inside the array stay values; the matching
    # command's future raises them.
    #
    # ```
    # cluster.multi { |tx| tx.incr("{acct}a"); tx.incr("{acct}b") } # => [1_i64, 1_i64]
    # ```
    def multi(&block : Transaction ->) : Array(Value)
      exec = nil
      pipelined { |p| exec = p.multi(&block) }
      exec.not_nil!.value
    end

    # Copies the group's commands out of *bytes* and runs them on *node*,
    # storing each reply or failure at its original index. A connection
    # loss or timeout marks the map stale; the failures are already stored
    # by `pipeline_raw`, except when the send itself failed.
    private def run_group(node : Node, indices : Array(Int32), bytes : Bytes, offsets : Array(Int32),
                          values : Array(Value), failures : Array(Exception?)) : Nil
      chunk = IO::Memory.new
      indices.each do |i|
        chunk.write(bytes[offsets[i], command_end(offsets, i, bytes.size) - offsets[i]])
      end
      node.client.pipeline_raw(chunk.to_slice, indices.size) do |j, value, error|
        i = indices[j]
        values[i] = value
        failures[i] = error
      end
    rescue ex : ConnectionError | IO::TimeoutError
      @mutex.synchronize { @stale = true }
      indices.each { |i| failures[i] ||= ex }
    end

    # The byte offset just past command *i*.
    private def command_end(offsets : Array(Int32), i : Int32, total : Int32) : Int32
      i + 1 < offsets.size ? offsets[i + 1] : total
    end
```

- [ ] **Step 4: Run the specs to verify they pass**

Run: `bin/crystal spec spec/std/redis/cluster_spec.cr`
Expected: 19 examples, 0 failures. If "re-issues a redirected command" sees `["GET", "b"]` twice on node 0, `execute` ignored its *redirect* argument; if the multi example reports a `ProtocolError` size mismatch, the override did not catch `EXEC` (the default answers `*0`).

- [ ] **Step 5: Format and commit**

```bash
bin/crystal tool format src/redis spec/std/redis
git add src/redis/cluster.cr spec/std/redis/cluster_spec.cr
git commit -m "Redis: Cluster#pipelined split by node and Cluster#multi

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: `Cluster#with_connection`, `#watch`, `#subscriber`; live three-node cluster specs

**Files:**
- Modify: `src/redis/cluster.cr` (add the three methods after `multi`)
- Modify: `spec/support/redis.cr` (add `require "file_utils"` at the top, `LiveCluster` inside `module RedisSpec`, `pending_cluster` at file level)
- Test: `spec/std/redis/cluster_spec.cr` (append), `spec/std/redis/cluster_live_spec.cr` (new)

**Interfaces:**
- Consumes: `Client#with_connection`, `Client#watch` (Task 5); `Subscriber.new(url, username:, password:, client_name:, protocol:, connect_timeout:, read_timeout:, tls_context:, max_bulk_size:, capacity:, reconnect:)`; `route`, `node_uri`, `check_open` (Task 7); `RedisSpec.pubsub_frame`.
- Produces: `Cluster#with_connection(key : String, & : Connection -> T) : T forall T`; `Cluster#watch(*keys : String, & : Connection -> T) : T forall T` (plus the zero-key overload raising `ArgumentError`); `Cluster#subscriber(*, capacity = 64, reconnect = true) : Subscriber`; `RedisSpec::LiveCluster` (`.instance : LiveCluster?`, `.failure : String`, `#urls`); `pending_cluster(description, &block : RedisSpec::LiveCluster ->)`.

- [ ] **Step 1: Write the failing fake-cluster specs**

Append to `spec/std/redis/cluster_spec.cr`:

```crystal
describe "Redis::Cluster blocking, watch and pub/sub" do
  it "borrows a dedicated connection to the key's master" do
    fake = fake_two { false }
    cluster = Redis::Cluster.new(fake.url(0))
    cluster.get("b")
    cluster.with_connection("b") { |conn| conn.ping }.should eq("PONG")
    # The seed probe, the node client, the pooled connection.
    fake.accepted(0).should eq(3)
    fake.accepted(1).should eq(0)
    cluster.with_connection("b") { |conn| conn.ping }
    fake.accepted(0).should eq(3)
    cluster.close
    fake.close
  end

  it "watches keys of one slot on that master and unwatches on the way out" do
    fake = fake_two { false }
    cluster = Redis::Cluster.new(fake.url(1))
    cluster.watch("{w}a", "{w}b") { |conn| conn.get("{w}a") }.should eq("v")
    fake.commands(0).should eq([["WATCH", "{w}a", "{w}b"], ["GET", "{w}a"], ["UNWATCH"]])
    expect_raises(ArgumentError, /one slot/) { cluster.watch("a", "b") { |conn| } }
    expect_raises(ArgumentError, /at least one key/) { cluster.watch { |conn| } }
    cluster.close
    fake.close
  end

  it "opens a subscriber on a master" do
    fake = fake_two do |fk, index, cmd, io|
      if cmd[0] == "SUBSCRIBE"
        io << RedisSpec.pubsub_frame(3, "subscribe", cmd[1], 1)
        true
      else
        false
      end
    end
    cluster = Redis::Cluster.new(fake.url(0))
    sub = cluster.subscriber(reconnect: false)
    sub.subscribe("news")
    (fake.commands(0).includes?(["SUBSCRIBE", "news"]) || fake.commands(1).includes?(["SUBSCRIBE", "news"])).should be_true
    sub.close
    cluster.close
    fake.close
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/crystal spec spec/std/redis/cluster_spec.cr`
Expected: compile error, `undefined method 'with_connection' for Redis::Cluster`.

- [ ] **Step 3: Implement the three methods**

Add inside `class Cluster` after `multi`:

```crystal
    # Borrows a dedicated `Connection` to the master owning *key*'s slot
    # (from that node client's pool, see `Client#with_connection`), yields
    # it, and hands it back. For blocking commands:
    #
    # ```
    # cluster.with_connection("jobs") { |conn| conn.call("BLPOP", "jobs", 0) }
    # ```
    #
    # Redirects are not followed inside the block: a `MOVED` or `ASK`
    # reply is raised as a `CommandError`, and the caller retries the block.
    def with_connection(key : String, & : Connection -> T) : T forall T
      check_open
      node = route(Cluster.key_slot(key))
      node.client.with_connection { |conn| yield conn }
    end

    # Raises `ArgumentError`: `watch` needs at least one key.
    def watch(&block : Connection -> T) : T forall T
      raise ArgumentError.new("WATCH needs at least one key")
    end

    # Optimistic locking on the master owning *keys*' slot: borrows a
    # dedicated connection there, sends `WATCH`, yields the connection
    # for the read-then-`multi` sequence, and hands it back (see
    # `Client#watch`). Every key must hash to one slot (use hash tags);
    # raises `ArgumentError` otherwise. Redirects are not followed inside
    # the block: a `MOVED` or `ASK` reply is raised as a `CommandError`,
    # and the caller retries the block just as for `AbortedError`.
    def watch(*keys : String, &block : Connection -> T) : T forall T
      check_open
      slot = Cluster.key_slot(keys[0])
      keys.each do |key|
        unless Cluster.key_slot(key) == slot
          raise ArgumentError.new("WATCH keys must hash to one slot; #{key.inspect} is not in slot #{slot}")
        end
      end
      route(slot).client.watch(*keys, &block)
    end

    # Opens a `Subscriber` on one master, chosen at random, with the
    # cluster's options; the cluster bus delivers every `publish` to it
    # whichever node received the message. Its reconnects go back to the
    # same node. The subscriber is independent of the cluster afterwards
    # and must be closed on its own.
    def subscriber(*, capacity : Int32 = 64, reconnect : Bool = true) : Subscriber
      check_open
      node = route(nil)
      Subscriber.new(node_uri(node.host, node.port), username: @username, password: @password,
        client_name: @client_name, protocol: @protocol_option, connect_timeout: @connect_timeout,
        read_timeout: @read_timeout, tls_context: @tls_context, max_bulk_size: @max_bulk_size,
        capacity: capacity, reconnect: reconnect)
    end
```

Run `bin/crystal spec spec/std/redis/cluster_spec.cr`: 22 examples, 0 failures.

- [ ] **Step 4: Add `LiveCluster` and `pending_cluster` to the spec support**

At the top of `spec/support/redis.cr` add `require "file_utils"`. Inside `module RedisSpec` append:

```crystal
  # A three-master cluster for the live cluster specs, spawned on first
  # use from `valkey-server` or `redis-server` on `PATH`: three random
  # loopback ports, a temp dir, slots split evenly, `CLUSTER MEET`, and a
  # wait for `cluster_state:ok` on every node; terminated at exit. Set
  # `REDIS_CLUSTER_URL` to a comma-separated list of seeds to use an
  # existing cluster instead. `failure` explains why none is available.
  class LiveCluster
    @@instance : LiveCluster?
    @@failure : String?

    getter urls : Array(String)
    @processes : Array(Process)
    @dir : String?

    def self.instance : LiveCluster?
      return @@instance if @@instance
      return nil if @@failure
      if env = ENV["REDIS_CLUSTER_URL"]?
        return @@instance = new(env.split(','), [] of Process, nil)
      end
      @@instance = spawn_local
    rescue ex
      @@failure = ex.message
      nil
    end

    def self.failure : String
      @@failure || "not started"
    end

    def initialize(@urls : Array(String), @processes : Array(Process), @dir : String?)
    end

    private def self.spawn_local : LiveCluster
      binary = Process.find_executable("valkey-server") || Process.find_executable("redis-server") ||
               raise "no valkey-server or redis-server on PATH"
      ports = Array.new(3) { free_port }
      dir = File.tempname("redis-cluster")
      Dir.mkdir_p(dir)
      processes = ports.map do |port|
        node_dir = File.join(dir, port.to_s)
        Dir.mkdir_p(node_dir)
        Process.new(binary, ["--port", port.to_s, "--cluster-enabled", "yes", "--cluster-config-file", "nodes.conf",
                             "--dir", node_dir, "--save", "", "--appendonly", "no", "--bind", "127.0.0.1",
                             "--logfile", "log.txt"],
          output: Process::Redirect::Close, error: Process::Redirect::Close)
      end
      cluster = new(ports.map { |port| "redis://127.0.0.1:#{port}" }, processes, dir)
      at_exit { cluster.stop }
      begin
        cluster.configure(ports)
      rescue ex
        cluster.stop
        raise ex
      end
      cluster
    end

    private def self.free_port : Int32
      server = TCPServer.new("127.0.0.1", 0)
      port = server.local_address.port
      server.close
      port
    end

    # Assigns the slots, meets the nodes and waits for convergence.
    def configure(ports : Array(Int32)) : Nil
      conns = ports.map { |port| wait_for(port) }
      begin
        step = Redis::Cluster::SLOTS // ports.size
        conns.each_with_index do |conn, i|
          first = i * step
          last = i == ports.size - 1 ? Redis::Cluster::SLOTS - 1 : (i + 1) * step - 1
          conn.call("CLUSTER", "ADDSLOTSRANGE", first, last)
        end
        ports[1..].each { |port| conns[0].call("CLUSTER", "MEET", "127.0.0.1", port) }
        started = Time.instant
        until conns.all? { |conn| conn.call("CLUSTER", "INFO").as(String).includes?("cluster_state:ok") }
          raise "cluster did not converge within 15 s" if Time.instant - started > 15.seconds
          sleep 100.milliseconds
        end
      ensure
        conns.each(&.close)
      end
    end

    private def wait_for(port : Int32) : Redis::Connection
      started = Time.instant
      loop do
        begin
          return Redis::Connection.new("redis://127.0.0.1:#{port}", connect_timeout: 1.second)
        rescue Redis::ConnectionError
          raise "node on port #{port} did not start within 5 s" if Time.instant - started > 5.seconds
          sleep 50.milliseconds
        end
      end
    end

    # Terminates the nodes and removes their directory. Idempotent.
    def stop : Nil
      @processes.each do |process|
        process.terminate rescue nil
        process.wait rescue nil
      end
      @processes.clear
      if dir = @dir
        FileUtils.rm_rf(dir) rescue nil
        @dir = nil
      end
    end
  end
```

At file level (next to `pending_redis`):

```crystal
# Like `it`, but the example is pending when no live cluster is available;
# the block receives the `RedisSpec::LiveCluster` (spawned on first use).
def pending_cluster(description = "assert", file = __FILE__, line = __LINE__, end_line = __END_LINE__,
                    &block : RedisSpec::LiveCluster ->)
  it(description, file, line, end_line) do
    cluster = RedisSpec::LiveCluster.instance
    pending!("no cluster: #{RedisSpec::LiveCluster.failure}", file, line) unless cluster
    block.call(cluster)
  end
end
```

`Redis::Connection.new` against a port whose server has not started yet raises `ConnectionError` (connect refused, or on macOS a connect that "succeeds" and fails on the `HELLO` read; both are mapped).

- [ ] **Step 5: Write the live specs**

`spec/std/redis/cluster_live_spec.cr`:

```crystal
require "spec"
require "../../support/redis"

private def values(*items) : Array(Redis::Value)
  Array(Redis::Value).new(items.size) { |i| items[i].as(Redis::Value) }
end

# Opens a cluster client, flushes every master, yields, closes.
private def with_cluster(live : RedisSpec::LiveCluster, protocol : Int32, &block : Redis::Cluster ->)
  cluster = Redis::Cluster.new(live.urls, protocol: protocol)
  begin
    cluster.refresh
    cluster.nodes.select(&.master?).each { |node| node.client.flushall }
    block.call(cluster)
  ensure
    cluster.close
  end
end

private def other_master(cluster : Redis::Cluster, than : Redis::Cluster::Node) : Redis::Cluster::Node
  cluster.nodes.find { |node| node.master? && !node.same?(than) }.not_nil!
end

private def live_cluster_specs(protocol : Int32)
  describe "Redis::Cluster live (RESP#{protocol})" do
    pending_cluster "discovers three masters and negotiates the protocol" do |live|
      with_cluster(live, protocol) do |c|
        masters = c.nodes.select(&.master?)
        masters.size.should eq(3)
        masters.all? { |node| node.id.size == 40 }.should be_true
        c.ping.should eq("PONG")
        masters.first.client.ping
        masters.first.client.protocol.should eq(protocol)
      end
    end

    pending_cluster "computes the same slots as CLUSTER KEYSLOT" do |live|
      with_cluster(live, protocol) do |c|
        rng = Random.new(42)
        node = c.nodes.first.client
        200.times do |i|
          key = i.even? ? rng.hex(4) : "{#{rng.hex(2)}}:#{i}"
          node.call("CLUSTER", "KEYSLOT", key).should eq(Redis::Cluster.key_slot(key).to_i64)
        end
      end
    end

    pending_cluster "spreads keys over every master and pipelines across them" do |live|
      with_cluster(live, protocol) do |c|
        keys = Array.new(50) { |i| "key#{i}" }
        keys.each { |key| c.set(key, key.upcase).should eq("OK") }
        c.nodes.select(&.master?).all? { |node| node.client.dbsize > 0 }.should be_true
        keys.each { |key| c.get(key).should eq(key.upcase) }
        replies = c.pipelined { |p| keys.each { |key| p.get(key) } }
        replies.should eq(keys.map(&.upcase))
        seen = [] of String
        c.scan_each(match: "key*") { |key| seen << key }
        seen.sort.should eq(keys.sort)
      end
    end

    pending_cluster "runs multi on one slot and raises CROSSSLOT across slots" do |live|
      with_cluster(live, protocol) do |c|
        c.multi { |tx| tx.incr("{m}a"); tx.incr("{m}b") }.should eq(values(1_i64, 1_i64))
        error = expect_raises(Redis::CommandError, /CROSSSLOT/) { c.mget("a", "b") }
        error.code.should eq("CROSSSLOT")
      end
    end

    pending_cluster "follows MOVED after a slot moves behind its back" do |live|
      with_cluster(live, protocol) do |c|
        key = "moved-key"
        slot = Redis::Cluster.key_slot(key)
        owner = c.node_for(key)
        target = other_master(c, owner)
        target.client.call("CLUSTER", "SETSLOT", slot, "NODE", target.id)
        owner.client.call("CLUSTER", "SETSLOT", slot, "NODE", target.id)
        expect_raises(Redis::CommandError, /MOVED/) { owner.client.set(key, "x") }
        c.set(key, "1").should eq("OK")
        c.node_for(key).should be(target)
        target.client.get(key).should eq("1")
      end
    end

    pending_cluster "follows ASK while a slot is migrating" do |live|
      with_cluster(live, protocol) do |c|
        key = "{ask}x"
        slot = Redis::Cluster.key_slot(key)
        source = c.node_for(key)
        target = other_master(c, source)
        c.set(key, "here")
        target.client.call("CLUSTER", "SETSLOT", slot, "IMPORTING", source.id)
        source.client.call("CLUSTER", "SETSLOT", slot, "MIGRATING", target.id)
        begin
          c.get(key).should eq("here")
          c.get("{ask}missing").should be_nil
          c.node_for(key).should be(source)
        ensure
          source.client.call("CLUSTER", "SETSLOT", slot, "STABLE")
          target.client.call("CLUSTER", "SETSLOT", slot, "STABLE")
        end
      end
    end

    pending_cluster "delivers a publish from any node to a subscriber" do |live|
      with_cluster(live, protocol) do |c|
        sub = c.subscriber
        begin
          sub.subscribe("news")
          masters = c.nodes.select(&.master?)
          masters.each { |node| node.client.publish("news", node.address) }
          received = Array.new(3) { sub.receive.payload }
          received.sort.should eq(masters.map(&.address).sort)
        ensure
          sub.close
        end
      end
    end

    pending_cluster "runs a blocking command on a dedicated connection" do |live|
      with_cluster(live, protocol) do |c|
        spawn do
          sleep 50.milliseconds
          c.rpush("q", "job")
        end
        c.with_connection("q") { |conn| conn.call("BLPOP", "q", 2) }.should eq(values("q", "job"))
      end
    end

    pending_cluster "runs scripts and watches on the owning master" do |live|
      with_cluster(live, protocol) do |c|
        script = Redis::Script.new("return redis.call('INCR', KEYS[1])")
        c.run(script, keys: ["s1"]).should eq(1_i64)
        c.run(script, keys: ["s2"]).should eq(1_i64)
        c.run(script, keys: ["s2"]).should eq(2_i64)
        c.watch("{w}a") { |conn| conn.multi { |tx| tx.set("{w}a", "1") } }.should eq(values("OK"))
        c.get("{w}a").should eq("1")
      end
    end
  end
end

live_cluster_specs(3)
live_cluster_specs(2)
```

- [ ] **Step 6: Run the live specs against a spawned cluster**

Run: `bin/crystal spec spec/std/redis/cluster_live_spec.cr`
Expected: 18 examples, 0 failures, 0 pending (Valkey 9.1 is on `PATH` on this machine). Then `REDIS_CLUSTER_URL=redis://127.0.0.1:1 bin/crystal spec spec/std/redis/cluster_live_spec.cr` must report 18 examples all raising `ClusterError` quickly (the env override is honoured), and `PATH=/usr/bin:/bin bin/crystal spec spec/std/redis/cluster_live_spec.cr` must report 18 pending with "no valkey-server or redis-server on PATH".

If "follows MOVED" fails because `owner.client.set` succeeds instead of answering `MOVED`, the owner has not yet accepted the reassignment: poll `owner.client.set(key, "x")` for up to two seconds until it raises, then continue. If "follows ASK" fails with `MOVED` from the target, the `ASKING` was not sent contiguously (check `ask` in Task 7 and `call_raw` in Task 6).

- [ ] **Step 7: Format and commit**

```bash
bin/crystal tool format src/redis spec/std/redis spec/support/redis.cr
git add src/redis/cluster.cr spec/support/redis.cr spec/std/redis/cluster_spec.cr spec/std/redis/cluster_live_spec.cr
git commit -m "Redis: Cluster blocking commands, watch, subscriber and live cluster specs

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 10: Module docs, formatting, full standard-library suite

**Files:**
- Modify: `src/redis.cr` (module doc)
- Verify: everything under `src/redis/`, `spec/std/redis/`, `spec/support/redis.cr`

- [ ] **Step 1: Update the module doc**

In `src/redis.cr`, replace the paragraph starting "Pub/sub: `Redis::Subscriber`" and the "Not in this slice" line with:

```crystal
# Pub/sub: `Redis::Subscriber` (or `Client#subscriber`) receives on its
# own connection and reconnects by itself; `Client#publish` sends.
# Transactions: `Client#multi { |tx| ... }` runs a `MULTI`..`EXEC` block
# atomically with typed futures; `Client#watch(*keys) { |conn| ... }`
# gives optimistic locking on a pooled dedicated connection. Scripts:
# `Redis::Script` with `run`, which sends `EVALSHA` and falls back to
# `EVAL` when the server has not cached the script.
#
# ```
# sub = redis.subscriber
# sub.subscribe("news")
# redis.publish("news", "hello")
# sub.receive.payload # => "hello"
#
# redis.multi { |tx| tx.set("a", "1"); tx.incr("hits") } # => ["OK", 1_i64]
#
# script = Redis::Script.new("return redis.call('INCRBY', KEYS[1], ARGV[1])")
# redis.run(script, keys: ["hits"], args: [5]) # => 6_i64
# ```
#
# Blocking commands: `Client#with_connection { |conn| ... }` borrows a
# dedicated `Connection` from the client's pool, and `Redis::Pool` is
# that pool on its own. Cluster: `Redis::Cluster` routes every command
# by key slot to the owning master, follows `MOVED`/`ASK`, reloads the
# topology when it changes, and splits pipelines by node.
#
# ```
# redis.with_connection { |conn| conn.call("BLPOP", "jobs", 0) }
#
# cluster = Redis::Cluster.new(["redis://10.0.0.1:7000", "redis://10.0.0.2:7000"])
# cluster.set("user:1", "x")
# cluster.pipelined { |p| p.get("a"); p.get("b") } # split by node, replies in order
# cluster.close
# ```
#
# Not included: replica reads, sharded pub/sub, Sentinel, streams helpers.
```

Also add `Redis::ClusterError` and `Redis::PoolTimeoutError` to the "Errors:" sentence of the first paragraph.

- [ ] **Step 2: Format check and the Redis suite**

Run:

```bash
bin/crystal tool format --check src/redis spec/std/redis spec/support/redis.cr
bin/crystal spec spec/std/redis/
```

Expected: format clean; every example passes (live ones against the local Valkey and the spawned cluster). Count the examples: slice 2 ended at 220 plus 1 pending; this slice adds roughly 75.

- [ ] **Step 3: Doc build and the full suite**

Run:

```bash
bin/crystal docs src/redis.cr -o /tmp/redis-docs >/dev/null && echo docs-ok
make std_spec 2>&1 | tail -5
```

Expected: `docs-ok`; `std_spec` reports only the 14 known environment failures (none under `spec/std/redis`). The suite takes several minutes; run nothing else that compiles meanwhile.

- [ ] **Step 4: Format and commit**

```bash
bin/crystal tool format src/redis
git add src/redis.cr
git commit -m "Redis: slice 3 module docs

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 11: Benchmarks (harness only, no commit to the tree)

**Files:**
- Create: `.remember/harness-2026-09-19/redis/cluster.sh` (spawns three Valkey nodes on 7100-7102)
- Create: `.remember/harness-2026-09-19/redis/bench_slice3.cr`
- Modify: `.remember/harness-2026-09-19/redis/rs/Cargo.toml` (add the `cluster-async` feature), `rs/src/main.rs` (a `slice3` case)
- Modify: `.remember/harness-2026-09-19/redis/go/main.go` (a `slice3` case)
- Modify: `.remember/harness-2026-09-19/redis/README.md` (a "Slice 3" section)

All under `.remember/` (gitignored). Targets from the spec section 8: routing overhead under 0.5 µs per sequential `GET`; 64-fiber `GET` across three masters versus redis-rs and go-redis; 300-`GET` split pipeline versus three 100-`GET` pipelines by hand; pooled `watch` at least 2× faster than a fresh connection per call; `checkout`/`checkin` under 200 ns.

- [ ] **Step 1: The cluster script**

`cluster.sh` (run from the harness directory; `./cluster.sh start` / `./cluster.sh stop`):

```bash
#!/bin/bash
set -eu
D="$(cd "$(dirname "$0")" && pwd)/cluster-data"
PORTS="7100 7101 7102"
case "${1:-start}" in
start)
  mkdir -p "$D"
  for p in $PORTS; do
    mkdir -p "$D/n$p"
    valkey-server --port $p --cluster-enabled yes --cluster-config-file nodes.conf --dir "$D/n$p" \
      --save "" --appendonly no --daemonize no --logfile log.txt --bind 127.0.0.1 >/dev/null 2>&1 &
    echo $! >> "$D/pids"
  done
  for p in $PORTS; do
    for _ in $(seq 1 50); do valkey-cli -p $p ping 2>/dev/null | grep -q PONG && break; sleep 0.1; done
  done
  valkey-cli -p 7100 cluster addslotsrange 0 5460 >/dev/null
  valkey-cli -p 7101 cluster addslotsrange 5461 10922 >/dev/null
  valkey-cli -p 7102 cluster addslotsrange 10923 16383 >/dev/null
  valkey-cli -p 7100 cluster meet 127.0.0.1 7101 >/dev/null
  valkey-cli -p 7100 cluster meet 127.0.0.1 7102 >/dev/null
  for _ in $(seq 1 100); do
    ok=0; for p in $PORTS; do valkey-cli -p $p cluster info 2>/dev/null | grep -q 'cluster_state:ok' && ok=$((ok+1)); done
    [ $ok = 3 ] && break; sleep 0.1
  done
  echo "cluster up on $PORTS (ok=$ok)"
  ;;
stop)
  [ -f "$D/pids" ] && kill $(cat "$D/pids") 2>/dev/null || true
  rm -rf "$D"
  echo "cluster stopped"
  ;;
esac
```

- [ ] **Step 2: The Crystal benchmark**

`bench_slice3.cr`:

```crystal
require "redis"
require "wait_group"

def report(name, ops, t)
  puts "#{name.ljust(34)} #{(ops / t.total_seconds).round(0).to_i.to_s.rjust(9)} ops/s  #{(t.total_nanoseconds / ops / 1000).round(2)} µs/op"
end

seeds = ["redis://127.0.0.1:7100", "redis://127.0.0.1:7101", "redis://127.0.0.1:7102"]
cluster = Redis::Cluster.new(seeds)
cluster.refresh
cluster.nodes.each { |n| n.client.flushall if n.master? }
keys = Array.new(300) { |i| "k#{i}" }
keys.each { |k| cluster.set(k, "v") }

# 1. Sequential GET: cluster versus a plain client on the owning node.
n = 50_000
owner = cluster.node_for("k0").client
t = Time.measure { n.times { owner.get("k0") } }
report "GET plain client", n, t
t = Time.measure { n.times { cluster.get("k0") } }
report "GET via cluster", n, t

# 2. 64 fibers, GET over keys spread across the three masters.
total = 500_000
wg = WaitGroup.new(64)
t = Time.measure do
  64.times do |f|
    spawn do
      begin
        (total // 64).times { |i| cluster.get(keys[(f + i * 64) % 300]) }
      ensure
        wg.done
      end
    end
  end
  wg.wait
end
report "64 fibers GET (3 masters)", total, t

# 3. One 300-GET split pipeline versus 3 × 100 by hand.
groups = keys.group_by { |k| cluster.node_for(k) }
iters = 2_000
t = Time.measure { iters.times { cluster.pipelined { |p| keys.each { |k| p.get(k) } } } }
report "pipelined 300 GET split", iters, t
t = Time.measure do
  iters.times do
    groups.each { |node, ks| node.client.pipelined { |p| ks.each { |k| p.get(k) } } }
  end
end
report "3 pipelines by hand (sequential)", iters, t

# 4. watch: pooled versus a fresh connection per call (slice 2 shape).
client = Redis::Client.new(seeds[0])
n = 5_000
t = Time.measure { n.times { client.watch("k0") { |c| c.get("k0") } } }
report "watch via pool", n, t
t = Time.measure do
  n.times do
    conn = Redis::Connection.new(seeds[0])
    conn.watch("k0")
    conn.get("k0")
    conn.close
  end
end
report "watch fresh connection", n, t

# 5. Pool checkout/checkin with an idle connection.
pool = Redis::Pool.new(seeds[0], size: 2)
pool.checkout { }
n = 1_000_000
t = Time.measure { n.times { pool.checkout { } } }
puts "pool checkout/checkin: #{(t.total_nanoseconds / n).round(0)} ns"
pool.close
client.close
cluster.close
```

Build and run: `bin/crystal build --release .remember/harness-2026-09-19/redis/bench_slice3.cr -o .build/bench_slice3 && .build/bench_slice3`.

- [ ] **Step 3: Baselines**

Rust, in `rs/Cargo.toml` change the redis line to `redis = { version = "0.27", features = ["tokio-comp", "cluster-async"] }` and add a `slice3` case to `main.rs` (dispatch on `std::env::args().nth(2)`, as the existing cases do):

```rust
async fn run_slice3() -> redis::RedisResult<()> {
    use redis::cluster::ClusterClient;
    use redis::AsyncCommands;
    let nodes = vec!["redis://127.0.0.1:7100/", "redis://127.0.0.1:7101/", "redis://127.0.0.1:7102/"];
    let client = ClusterClient::new(nodes)?;
    let mut con = client.get_async_connection().await?;
    let keys: Vec<String> = (0..300).map(|i| format!("k{}", i)).collect();
    for k in &keys { let _: () = con.set(k, "v").await?; }
    let n = 50_000;
    let t = std::time::Instant::now();
    for _ in 0..n { let _: String = con.get("k0").await?; }
    println!("GET via cluster (rs)            {:>9.0} ops/s  {:.2} µs/op", n as f64 / t.elapsed().as_secs_f64(), t.elapsed().as_nanos() as f64 / n as f64 / 1000.0);
    let total = 500_000;
    let t = std::time::Instant::now();
    let mut tasks = Vec::new();
    for f in 0..64 {
        let mut con = con.clone();
        let keys = keys.clone();
        tasks.push(tokio::spawn(async move {
            for i in 0..(total / 64) { let _: String = con.get(&keys[(f + i * 64) % 300]).await.unwrap(); }
        }));
    }
    for t in tasks { t.await.unwrap(); }
    println!("64 tasks GET (rs)               {:>9.0} ops/s", total as f64 / t.elapsed().as_secs_f64());
    Ok(())
}
```

Go, in `go/main.go` add a `slice3` case:

```go
func runSlice3() {
	ctx := context.Background()
	c := redis.NewClusterClient(&redis.ClusterOptions{Addrs: []string{"127.0.0.1:7100", "127.0.0.1:7101", "127.0.0.1:7102"}})
	keys := make([]string, 300)
	for i := range keys {
		keys[i] = fmt.Sprintf("k%d", i)
		c.Set(ctx, keys[i], "v", 0)
	}
	n := 50000
	t := time.Now()
	for i := 0; i < n; i++ {
		c.Get(ctx, "k0").Result()
	}
	el := time.Since(t)
	fmt.Printf("GET via cluster (go)            %9.0f ops/s  %.2f µs/op\n", float64(n)/el.Seconds(), float64(el.Nanoseconds())/float64(n)/1000)
	total := 500000
	var wg sync.WaitGroup
	t = time.Now()
	for f := 0; f < 64; f++ {
		wg.Add(1)
		go func(f int) {
			defer wg.Done()
			for i := 0; i < total/64; i++ {
				c.Get(ctx, keys[(f+i*64)%300]).Result()
			}
		}(f)
	}
	wg.Wait()
	fmt.Printf("64 goroutines GET (go)          %9.0f ops/s\n", float64(total)/time.Since(t).Seconds())
}
```

Build and run each after `./cluster.sh start`: `cd rs && cargo build --release && ./target/release/bench redis://127.0.0.1:7100 slice3`; `cd go && go build -o bench . && ./bench slice3`. Adapt the argument dispatch to whatever the existing `main` functions use.

- [ ] **Step 4: Record**

Append a "Slice 3 — 2026-09-20" section to the README with the environment (Valkey version, redis-rs and go-redis versions), a results table, the targets and whether each was met, and any variant tried and rejected. Run `./cluster.sh stop` at the end. Nothing is committed; the memory file gets the headline numbers in the session wrap-up.

---

## Self-review notes

- Spec §2 → Task 1; §3.1–3.3, 3.6 → Task 7; §3.4 → Tasks 6 and 8; §3.5 → Task 9; §4, 4.1, 4.2 → Tasks 3, 4, 5; §5 → Task 3; §6 → Task 1; §7.1–7.5 → Tasks 1, 7/8/9, 4, 5/6, 9; §8 → Task 11; §9 needs no task.
- Deviation from the spec, deliberate: the future API is split into `resolve(Value)`/`fail(Exception)` (Task 2) and `pipeline_raw` yields `(index, value, error)` rather than a `Value | Exception`, because the union form does not compile (verified). `Cluster#node_for` is added as public API (the live specs need the slot's owner; it is cheap and useful).
- Names used across tasks: `Pipeline::Route` (`key`, `retry`), `Pipeline#routes`, `#offsets`, `#routing?`; `Client#pipeline_raw(bytes, count, &)`, `#call_raw(bytes, asking)`, `Client::ASKING`; `Cluster#execute(slot, redirect = nil, &)`, `#route(slot)`, `#refresh_if_stale`, `#node_uri`, `#node_client`, `#new_node`, `#install`, `#node_at`, `#parse_redirect`, `#ask`, `#run_group`, `#command_end`, `Cluster::REDIRECT_CODES`; `RedisSpec::FakeCluster`, `RedisSpec::LiveCluster`, `pending_cluster`.
