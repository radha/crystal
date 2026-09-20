# Redis Client Slice 2 (pub/sub, transactions, scripts) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `Redis::Subscriber` (pub/sub on a dedicated auto-reconnecting connection), `multi { |tx| }` transactions with typed futures plus `Client#watch`, and `Redis::Script` with an `EVALSHA`→`EVAL` fallback to the slice 1 client, without changing any slice 1 public signature.

**Architecture:** `Subscriber` owns one `Connection` and a reader fiber; control commands push an `Ack` onto a FIFO and wait for confirmation frames; a drop runs a backoff reconnect and resubscribes from the desired sets. `Pipeline#multi` appends `MULTI`, the transaction bytes and `EXEC` to the pipeline buffer, with a `QueuedFuture` per command and one `ExecFuture` that fans the `EXEC` array out to the transaction's futures, so `Client#pipelined` stays flat. `Script` computes its SHA1 locally; `run` on `Client`/`Connection` falls back to `EVAL` on `NOSCRIPT`, and pipelines choose from a per-client `ScriptCache` of accepted SHAs.

**Tech Stack:** Crystal stdlib only (`socket`, `openssl`, `uri`, `digest/sha1`, `Channel`, `Mutex`, `Deque`, `Set`, `IO::Memory`). Compiler via `bin/crystal`. Live specs need a local Redis/Valkey.

**Spec:** `docs/superpowers/specs/2026-09-20-redis-slice2-design.md` (slice 1: `docs/superpowers/specs/2026-09-19-redis-client-design.md`)

## Global Constraints

- Everything lives under `src/redis/` with entry `src/redis.cr`; never required from the prelude; never `require "big"`.
- No slice 1 public signature changes. `Pipeline.new` gains an *optional* first parameter only.
- A subscription always lives on its own `Connection`, opened with `read_timeout: nil`. The multiplexed `Client` never enters subscribed mode and never issues `WATCH`.
- `multi` returns the `EXEC` array; nil `EXEC` raises `Redis::AbortedError`; no automatic retry anywhere.
- Every public method gets a third-person doc comment. `bin/crystal tool format src/redis spec/std/redis spec/support/redis.cr` before every commit.
- Always `bin/crystal`, never a global `crystal`. Run one compiler at a time (8 GB machine). Foreground `sleep` in Bash is blocked (Crystal's `sleep` inside specs is fine); live specs are `pending` when no server answers.
- Commit messages are prefixed `Redis: ` and end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- `docs/` is gitignored: `git add -f` for files under it.
- Command family files under `src/redis/commands/` are picked up by `require "./commands/*"` at the bottom of `src/redis/commands.cr`; no require line is needed for a new family file.

## File map

| File | Responsibility |
|------|----------------|
| `src/redis.cr` | module doc + requires (`digest/sha1`, `script`, `transaction`, `subscriber`) |
| `src/redis/error.cr` | + `AbortedError` |
| `src/redis/script.cr` | `Script` (source, sha, `load`), `ScriptCache` (mutex-guarded `Set(String)`) |
| `src/redis/commands.cr` | + `Commands#run`, `Commands::ScriptFallback` module |
| `src/redis/commands/pubsub.cr` | `publish` |
| `src/redis/pipeline.cr` | + `Pipeline.new(script_cache)`, `script_run`, `multi`, `ScriptFuture`, `AbstractFuture#resolved?` |
| `src/redis/transaction.cr` | `Transaction`, `QueuedFuture`, `ExecFuture` |
| `src/redis/connection.cr` | + `script_cache`, `pipelined`, `multi`, `watch`, `unwatch` |
| `src/redis/client.cr` | + `script_cache`, `multi`, `watch`, `subscriber` |
| `src/redis/subscriber.cr` | `Subscriber`, `Subscriber::Message`, reader fiber, reconnect |
| `spec/support/redis.cr` | + `RedisSpec.pubsub_frame` |
| `spec/std/redis/script_spec.cr` | SHA, fallback, cache hint, pipelined `NOSCRIPT` |
| `spec/std/redis/transaction_spec.cr` | fan-out unit specs + fake-server specs for `multi`/`watch`/`pipelined` |
| `spec/std/redis/subscriber_spec.cr` | fake-server specs at both protocols |
| `spec/std/redis/live_spec.cr` | + pub/sub, multi, watch, run |
| `spec/std/redis/commands_spec.cr` | + `publish` |

---

### Task 1: `AbortedError`, `Script` with a local SHA1, `publish`

**Files:**
- Modify: `src/redis/error.cr` (append inside `module Redis`)
- Create: `src/redis/script.cr`
- Create: `src/redis/commands/pubsub.cr`
- Modify: `src/redis.cr` (requires)
- Test: `spec/std/redis/script_spec.cr` (created here, extended in Task 2), `spec/std/redis/commands_spec.cr` (append)

**Interfaces:**
- Produces: `Redis::AbortedError < Redis::Error` (default message `"transaction aborted: a watched key changed"`); `Redis::Script` struct with `source : String`, `sha : String` (lowercase hex SHA1 of `source`); `Redis::Commands#publish(channel : String, message : String)` → `Int64` (typed).

- [ ] **Step 1: Write the failing specs**

```crystal
# spec/std/redis/script_spec.cr
require "spec"
require "../../support/redis"

describe Redis::Script do
  it "computes the SHA1 of the source locally" do
    Redis::Script.new("").sha.should eq("da39a3ee5e6b4b0d3255bfef95601890afd80709")
    s = Redis::Script.new("return 1")
    s.source.should eq("return 1")
    s.sha.should eq(Digest::SHA1.hexdigest("return 1"))
    s.sha.size.should eq(40)
  end
end

describe Redis::AbortedError do
  it "is a Redis::Error with a default message" do
    err = Redis::AbortedError.new
    err.should be_a(Redis::Error)
    err.message.should eq("transaction aborted: a watched key changed")
    Redis::AbortedError.new("custom").message.should eq("custom")
  end
end
```

Append to `spec/std/redis/commands_spec.cr`:

```crystal
describe "pubsub commands" do
  it "publish" do
    expect_call(2_i64, ["PUBLISH", "news", "hi"], &.publish("news", "hi")).should eq(2_i64)
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/crystal spec spec/std/redis/script_spec.cr`
Expected: compile error `undefined constant Redis::Script`.

Run: `bin/crystal spec spec/std/redis/commands_spec.cr -e publish`
Expected: compile error `undefined method 'publish'`.

- [ ] **Step 3: Write the code**

Append inside `module Redis` in `src/redis/error.cr` (after `CommandError`):

```crystal
  # Raised by `multi` when `EXEC` replies nil: a key marked with `WATCH`
  # changed before the transaction ran, so none of its commands executed.
  # Retry the whole read-then-`multi` sequence.
  class AbortedError < Error
    def initialize(message : String = "transaction aborted: a watched key changed", cause : Exception? = nil)
      super(message, cause)
    end
  end
```

```crystal
# src/redis/script.cr
require "digest/sha1"

module Redis
  # A Lua script with its SHA1 computed locally, so that `run` can send
  # `EVALSHA` without asking the server for the hash first.
  #
  # ```
  # script = Redis::Script.new("return redis.call('INCRBY', KEYS[1], ARGV[1])")
  # redis.run(script, keys: ["hits"], args: [5]) # => 5_i64
  # ```
  struct Script
    # The Lua source.
    getter source : String
    # The lowercase hex SHA1 of `source`, which is what Redis uses as the
    # script's cache key.
    getter sha : String

    def initialize(@source : String)
      @sha = Digest::SHA1.hexdigest(@source)
    end
  end
end
```

```crystal
# src/redis/commands/pubsub.cr
module Redis::Commands
  # Posts *message* to *channel* and returns the number of clients that
  # received it. To receive, see `Redis::Subscriber`.
  def_command publish, "PUBLISH", channel : String, message : String, cast: :int
end
```

In `src/redis.cr`, add `require "digest/sha1"` after `require "set"` and `require "./redis/script"` after `require "./redis/value"`.

- [ ] **Step 4: Run the specs to verify they pass**

Run: `bin/crystal spec spec/std/redis/script_spec.cr spec/std/redis/commands_spec.cr`
Expected: all examples pass (the existing commands examples plus the three new ones).

- [ ] **Step 5: Format and commit**

```bash
bin/crystal tool format src/redis spec/std/redis spec/support/redis.cr
git add src/redis.cr src/redis/error.cr src/redis/script.cr src/redis/commands/pubsub.cr spec/std/redis/script_spec.cr spec/std/redis/commands_spec.cr
git commit -m "Redis: AbortedError, Script with local SHA1, publish

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: `run` with `NOSCRIPT` fallback, `ScriptCache`, pipelined `EVALSHA`/`EVAL` choice

**Files:**
- Modify: `src/redis/script.cr` (add `Script#load`, `ScriptCache`)
- Modify: `src/redis/commands.cr` (add `run` and `ScriptFallback` inside `module Commands`, before `macro def_command`)
- Modify: `src/redis/commands/scripting.cr` (widen `script_args` to `Indexable`)
- Modify: `src/redis/pipeline.cr` (`Pipeline.new(script_cache)`, `script_run`, `ScriptFuture`)
- Modify: `src/redis/connection.cr` (`include Commands::ScriptFallback`, `script_cache`)
- Modify: `src/redis/client.cr` (`include Commands::ScriptFallback`, `script_cache`, `Pipeline.new(@script_cache)` in `pipelined`)
- Test: `spec/std/redis/script_spec.cr` (extend)

**Interfaces:**
- Consumes: `Redis::Script` (Task 1); `Commands#script_args(cmd, body, keys, args)` (exists in `commands/scripting.cr`, private, callable from includers); `Commands#script_load`.
- Produces: `Redis::ScriptCache` (`:nodoc:`) with `known?(sha) : Bool`, `add(sha) : Nil`, `delete(sha) : Nil`; `Script#load(redis : Client | Connection) : String`; `Commands#run(script : Script, *, keys : Indexable(String) = [] of String, args : Indexable = [] of RESP::Arg)` → `Value` on `Client`/`Connection`, `Future(Value)` on `Pipeline` (`args` is an unrestricted `Indexable` so that a literal like `[5]` compiles: a Crystal array literal does not adopt a union restriction such as `Array(RESP::Arg)`; each element must still be a `RESP::Arg` member or `<<` fails to compile); `Client#script_cache`, `Connection#script_cache` (`:nodoc:` getters); `Pipeline.new(script_cache : ScriptCache = ScriptCache.new)`; `Redis::ScriptFuture < Future(Value)` (`:nodoc:`).

- [ ] **Step 1: Write the failing specs**

Replace `spec/std/redis/script_spec.cr` with:

```crystal
# spec/std/redis/script_spec.cr
require "spec"
require "../../support/redis"

# A fake server with a script cache: EVALSHA answers NOSCRIPT until the
# script was loaded by EVAL or SCRIPT LOAD; SCRIPT FLUSH empties it. A
# script whose source is exactly "error" fails at run time.
private class ScriptServer
  getter seen = [] of Array(String)
  @loaded = {} of String => String

  def server
    RedisSpec::FakeServer.new do |io|
      while cmd = RedisSpec::FakeServer.read_command(io)
        @seen << cmd
        case cmd[0]
        when "HELLO"
          io << RedisSpec::HELLO_REPLY
        when "EVALSHA"
          if source = @loaded[cmd[1]]?
            io << run_reply(source)
          else
            io << "-NOSCRIPT No matching script. Please use EVAL.\r\n"
          end
        when "EVAL"
          @loaded[Digest::SHA1.hexdigest(cmd[1])] = cmd[1]
          io << run_reply(cmd[1])
        when "SCRIPT"
          case cmd[1]
          when "LOAD"
            sha = Digest::SHA1.hexdigest(cmd[2])
            @loaded[sha] = cmd[2]
            io << "$#{sha.bytesize}\r\n#{sha}\r\n"
          when "FLUSH"
            @loaded.clear
            io << "+OK\r\n"
          else
            io << "+OK\r\n"
          end
        else
          io << "+OK\r\n"
        end
        io.flush
      end
    end
  end

  # Commands seen after the handshake, first element only.
  def names : Array(String)
    @seen.reject { |c| c[0] == "HELLO" }.map(&.first)
  end

  private def run_reply(source : String) : String
    source == "error" ? "-ERR Error running script\r\n" : ":1\r\n"
  end
end

describe Redis::Script do
  it "computes the SHA1 of the source locally" do
    Redis::Script.new("").sha.should eq("da39a3ee5e6b4b0d3255bfef95601890afd80709")
    s = Redis::Script.new("return 1")
    s.source.should eq("return 1")
    s.sha.should eq(Digest::SHA1.hexdigest("return 1"))
    s.sha.size.should eq(40)
  end

  it "run sends EVALSHA, falls back to EVAL on NOSCRIPT, then EVALSHA again" do
    fake = ScriptServer.new
    server = fake.server
    conn = Redis::Connection.new(server.url)
    script = Redis::Script.new("return 1")
    conn.run(script, keys: ["k"], args: [5]).should eq(1_i64)
    fake.seen[1].should eq(["EVALSHA", script.sha, "1", "k", "5"])
    fake.seen[2].should eq(["EVAL", "return 1", "1", "k", "5"])
    conn.run(script, keys: ["k"], args: [5]).should eq(1_i64)
    fake.names.should eq(["EVALSHA", "EVAL", "EVALSHA"])
    conn.script_cache.known?(script.sha).should be_true
    conn.close
    server.close
  end

  it "raises a non-NOSCRIPT error without falling back" do
    fake = ScriptServer.new
    server = fake.server
    conn = Redis::Connection.new(server.url)
    script = Redis::Script.new("error")
    script.load(conn).should eq(script.sha)
    fake.seen[1].should eq(["SCRIPT", "LOAD", "error"])
    conn.script_cache.known?(script.sha).should be_true
    ex = expect_raises(Redis::CommandError) { conn.run(script) }
    ex.code.should eq("ERR")
    fake.names.should eq(["SCRIPT", "EVALSHA"])
    conn.close
    server.close
  end

  it "works on the multiplexed client" do
    fake = ScriptServer.new
    server = fake.server
    client = Redis::Client.new(server.url)
    script = Redis::Script.new("return 1")
    client.run(script).should eq(1_i64)
    client.run(script).should eq(1_i64)
    fake.names.should eq(["EVALSHA", "EVAL", "EVALSHA"])
    client.close
    server.close
  end

  it "pipelines send EVAL for an unknown SHA and EVALSHA for a known one" do
    fake = ScriptServer.new
    server = fake.server
    client = Redis::Client.new(server.url)
    script = Redis::Script.new("return 1")
    f = nil
    client.pipelined { |p| f = p.run(script, keys: ["k"]) }
    f.not_nil!.value.should eq(1_i64)
    fake.names.should eq(["EVAL"])
    client.script_cache.known?(script.sha).should be_true
    client.pipelined { |p| f = p.run(script, keys: ["k"]) }
    f.not_nil!.value.should eq(1_i64)
    fake.names.should eq(["EVAL", "EVALSHA"])
    client.close
    server.close
  end

  it "a pipelined NOSCRIPT surfaces on the future and clears the hint" do
    fake = ScriptServer.new
    server = fake.server
    client = Redis::Client.new(server.url)
    script = Redis::Script.new("return 1")
    client.run(script).should eq(1_i64)
    client.script_flush
    f = nil
    client.pipelined { |p| f = p.run(script) }
    ex = expect_raises(Redis::CommandError) { f.not_nil!.value }
    ex.code.should eq("NOSCRIPT")
    client.script_cache.known?(script.sha).should be_false
    client.pipelined { |p| f = p.run(script) }
    f.not_nil!.value.should eq(1_i64)
    fake.names.should eq(["EVALSHA", "EVAL", "SCRIPT", "EVALSHA", "EVAL"])
    client.close
    server.close
  end
end

describe Redis::AbortedError do
  it "is a Redis::Error with a default message" do
    err = Redis::AbortedError.new
    err.should be_a(Redis::Error)
    err.message.should eq("transaction aborted: a watched key changed")
    Redis::AbortedError.new("custom").message.should eq("custom")
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/crystal spec spec/std/redis/script_spec.cr`
Expected: compile error `undefined method 'run'` (or `script_cache`).

- [ ] **Step 3: `ScriptCache` and `Script#load`**

Append to `src/redis/script.cr` inside `module Redis` (after `struct Script`), and add `load` inside `struct Script`:

```crystal
    # Loads the script into the server's cache with `SCRIPT LOAD` and
    # returns its SHA1 (equal to `sha`). Useful to warm the cache before a
    # pipeline, which cannot fall back to `EVAL` mid-flight.
    def load(redis : Client | Connection) : String
      sha = redis.script_load(@source)
      redis.script_cache.add(sha)
      sha
    end
```

```crystal
  # :nodoc:
  #
  # The SHAs a client has seen the server accept. Pipelines consult it to
  # choose between `EVALSHA` and `EVAL`; a `NOSCRIPT` reply removes the
  # SHA again. Shared between a client, its pipelines and their futures,
  # which may run on different fibers, hence the mutex.
  class ScriptCache
    @mutex = Mutex.new
    @known = Set(String).new

    def known?(sha : String) : Bool
      @mutex.synchronize { @known.includes?(sha) }
    end

    def add(sha : String) : Nil
      @mutex.synchronize { @known << sha }
    end

    def delete(sha : String) : Nil
      @mutex.synchronize { @known.delete(sha) }
    end
  end
```

- [ ] **Step 4: `Commands#run` and the fallback module**

In `src/redis/commands.cr`, inside `module Commands`, right after the two `command` methods:

```crystal
    # Runs *script*. On a `Client` or `Connection` this sends `EVALSHA` and,
    # when the server replies `NOSCRIPT`, `EVAL` with the source, which also
    # caches it server-side. On a `Pipeline` the choice is made up front:
    # `EVALSHA` if this client has seen the server accept the script,
    # `EVAL` otherwise; a `NOSCRIPT` reply then surfaces on the returned
    # future and the next pipeline goes back to `EVAL`.
    def run(script : Script, *, keys : Indexable(String) = [] of String, args : Indexable = [] of RESP::Arg)
      script_run(script, keys, args)
    end

    # :nodoc:
    #
    # `script_run` for includers that execute synchronously (`Client`,
    # `Connection`): `EVALSHA`, then `EVAL` on `NOSCRIPT`. The includer
    # provides `script_cache : ScriptCache`.
    module ScriptFallback
      # :nodoc:
      def script_run(script : Script, keys : Indexable(String), args : Indexable) : Value
        value = begin
          call(script_args("EVALSHA", script.sha, keys, args))
        rescue ex : CommandError
          raise ex unless ex.code == "NOSCRIPT"
          call(script_args("EVAL", script.source, keys, args))
        end
        script_cache.add(script.sha)
        value
      end
    end
```

In `src/redis/commands/scripting.cr`, widen the existing helper's restrictions (its body is unchanged; `Indexable` has both `size` and `each`, and `all << a` still requires each element to be a `RESP::Arg` member):

```crystal
  private def script_args(cmd : String, body : String, keys : Indexable(String), args : Indexable) : Array(RESP::Arg)
```

`eval`/`evalsha` keep their `Array(...)` signatures; `Array` is an `Indexable`, so they still compile.

- [ ] **Step 5: Pipeline side**

In `src/redis/pipeline.cr`:

Add to `AbstractFuture`:

```crystal
    abstract def resolved? : Bool
```

Add after `class Future(T)`:

```crystal
  # :nodoc:
  #
  # The future of a pipelined `run`: keeps the client's `ScriptCache`
  # honest. A `NOSCRIPT` reply forgets the SHA, any successful reply
  # records it (the pipeline may have sent `EVAL`, which loads the script).
  class ScriptFuture < Future(Value)
    def initialize(@cache : ScriptCache, @sha : String)
      super(->(v : Value) { v })
    end

    def resolve(raw : Value | Exception) : Nil
      super
      if raw.is_a?(CommandError)
        @cache.delete(@sha) if raw.code == "NOSCRIPT"
      elsif !raw.is_a?(Exception)
        @cache.add(@sha)
      end
    end
  end
```

In `class Pipeline`, add a constructor and `script_run` (after `getter buffer`):

```crystal
    @script_cache : ScriptCache

    # :nodoc:
    #
    # *script_cache* is the owning client's; `Client#pipelined` and
    # `Connection#pipelined` pass theirs. The default is for a pipeline
    # built by hand, which then always sends `EVAL`.
    def initialize(@script_cache : ScriptCache = ScriptCache.new)
    end

    # :nodoc:
    def script_run(script : Script, keys : Indexable(String), args : Indexable) : Future(Value)
      wire = if @script_cache.known?(script.sha)
               script_args("EVALSHA", script.sha, keys, args)
             else
               script_args("EVAL", script.source, keys, args)
             end
      RESP.write_command(@buffer, wire)
      future = ScriptFuture.new(@script_cache, script.sha)
      @futures << future
      @size += 1
      future
    end
```

- [ ] **Step 6: Client and Connection side**

In `src/redis/connection.cr`, inside `class Connection` after `include Commands`:

```crystal
    include Commands::ScriptFallback

    # :nodoc:
    getter script_cache = ScriptCache.new
```

In `src/redis/client.cr`, inside `class Client` after `include Commands`:

```crystal
    include Commands::ScriptFallback

    # :nodoc:
    getter script_cache = ScriptCache.new
```

and in `Client#pipelined` change `pipeline = Pipeline.new` to `pipeline = Pipeline.new(@script_cache)`.

- [ ] **Step 7: Run the specs to verify they pass**

Run: `bin/crystal spec spec/std/redis/script_spec.cr spec/std/redis/pipeline_spec.cr spec/std/redis/client_spec.cr`
Expected: all pass. If `fake.names` differs by an extra `"EVALSHA"` in the pipelined examples, the cache was not consulted: check `Pipeline.new(@script_cache)` in `Client#pipelined`.

- [ ] **Step 8: Format and commit**

```bash
bin/crystal tool format src/redis spec/std/redis spec/support/redis.cr
git add src/redis/script.cr src/redis/commands.cr src/redis/commands/scripting.cr src/redis/pipeline.cr src/redis/connection.cr src/redis/client.cr spec/std/redis/script_spec.cr
git commit -m "Redis: run(script) with NOSCRIPT fallback and a per-client script cache

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: `Transaction`, `Pipeline#multi`, `ExecFuture` fan-out (no network)

**Files:**
- Create: `src/redis/transaction.cr`
- Modify: `src/redis/pipeline.cr` (add `multi`)
- Modify: `src/redis.cr` (`require "./redis/transaction"` after `require "./redis/pipeline"`)
- Test: `spec/std/redis/transaction_spec.cr`

**Interfaces:**
- Consumes: `Pipeline` internals `@buffer`, `@futures : Array(AbstractFuture)`, `@size`, `@script_cache` (Task 2); `AbstractFuture#resolve`/`#resolved?`; `Future(T).new(mapper)`; `AbortedError` (Task 1).
- Produces: `Redis::Transaction < Pipeline` with `futures : Array(AbstractFuture)` (`:nodoc:`) and `multi` raising `ArgumentError`; `Pipeline#multi(& : Transaction ->) : Future(Array(Value))`; `Redis::QueuedFuture`, `Redis::ExecFuture` (`:nodoc:`).

- [ ] **Step 1: Write the failing spec**

```crystal
# spec/std/redis/transaction_spec.cr
require "spec"
require "../../support/redis"

private def values(*items) : Array(Redis::Value)
  items.map(&.as(Redis::Value)).to_a
end

describe Redis::Transaction do
  it "wraps the commands in MULTI and EXEC and fans the EXEC array out" do
    p = Redis::Pipeline.new
    before = p.get("x")
    f1 = nil
    f2 = nil
    exec = p.multi do |tx|
      f1 = tx.set("a", "1")
      f2 = tx.incr("n")
    end
    p.size.should eq(5)
    p.buffer.to_s.should eq(
      "*2\r\n$3\r\nGET\r\n$1\r\nx\r\n" \
      "*1\r\n$5\r\nMULTI\r\n" \
      "*3\r\n$3\r\nSET\r\n$1\r\na\r\n$1\r\n1\r\n" \
      "*2\r\n$4\r\nINCR\r\n$1\r\nn\r\n" \
      "*1\r\n$4\r\nEXEC\r\n")
    exec.should be_a(Redis::Future(Array(Redis::Value)))
    exec.resolved?.should be_false
    p.resolve(0, "v")
    p.resolve(1, "OK")
    p.resolve(2, "QUEUED")
    p.resolve(3, "QUEUED")
    f1.not_nil!.resolved?.should be_false
    p.resolve(4, values("OK", 7_i64))
    before.value.should eq("v")
    exec.value.should eq(values("OK", 7_i64))
    f1.not_nil!.value.should eq("OK")
    f2.not_nil!.value.should eq(7_i64)
  end

  it "nil EXEC raises AbortedError on the exec future and every command" do
    p = Redis::Pipeline.new
    f = nil
    exec = p.multi { |tx| f = tx.incr("n") }
    p.resolve(0, "OK")
    p.resolve(1, "QUEUED")
    p.resolve(2, nil)
    exec.resolved?.should be_true
    exec.value?.should be_nil
    expect_raises(Redis::AbortedError) { exec.value }
    expect_raises(Redis::AbortedError) { f.not_nil!.value }
  end

  it "EXECABORT reaches every future, a queue-time rejection keeps its own error" do
    p = Redis::Pipeline.new
    f1 = nil
    f2 = nil
    exec = p.multi do |tx|
      f1 = tx.command("BADARITY")
      f2 = tx.incr("n")
    end
    p.resolve(0, "OK")
    p.resolve(1, Redis::CommandError.new("ERR wrong number of arguments"))
    p.resolve(2, "QUEUED")
    p.resolve(3, Redis::CommandError.new("EXECABORT Transaction discarded because of previous errors."))
    expect_raises(Redis::CommandError, /EXECABORT/) { exec.value }
    expect_raises(Redis::CommandError, /wrong number/) { f1.not_nil!.value }
    expect_raises(Redis::CommandError, /EXECABORT/) { f2.not_nil!.value }
  end

  it "a runtime error inside EXEC stays a value and only its future raises" do
    p = Redis::Pipeline.new
    f1 = nil
    f2 = nil
    exec = p.multi do |tx|
      f1 = tx.command("FAILRUN")
      f2 = tx.incr("n")
    end
    p.resolve(0, "OK")
    p.resolve(1, "QUEUED")
    p.resolve(2, "QUEUED")
    err = Redis::CommandError.new("ERR runtime failure")
    p.resolve(3, values(err, 1_i64))
    exec.value.should eq(values(err, 1_i64))
    expect_raises(Redis::CommandError, /runtime/) { f1.not_nil!.value }
    f2.not_nil!.value.should eq(1_i64)
  end

  it "a connection failure reaches every unresolved future" do
    p = Redis::Pipeline.new
    f = nil
    exec = p.multi { |tx| f = tx.incr("n") }
    p.resolve(0, "OK")
    p.resolve(1, "QUEUED")
    p.resolve(2, Redis::ConnectionError.new("connection lost"))
    expect_raises(Redis::ConnectionError) { exec.value }
    expect_raises(Redis::ConnectionError) { f.not_nil!.value }
  end

  it "a size mismatch is a ProtocolError everywhere" do
    p = Redis::Pipeline.new
    f = nil
    exec = p.multi { |tx| f = tx.incr("n") }
    p.resolve(0, "OK")
    p.resolve(1, "QUEUED")
    p.resolve(2, values(1_i64, 2_i64))
    expect_raises(Redis::ProtocolError, /2 replies for 1/) { exec.value }
    expect_raises(Redis::ProtocolError) { f.not_nil!.value }
  end

  it "an unexpected EXEC reply is a ProtocolError" do
    p = Redis::Pipeline.new
    f = nil
    exec = p.multi { |tx| f = tx.incr("n") }
    p.resolve(0, "OK")
    p.resolve(1, "QUEUED")
    p.resolve(2, "OK")
    expect_raises(Redis::ProtocolError) { exec.value }
    expect_raises(Redis::ProtocolError) { f.not_nil!.value }
  end

  it "an empty block appends nothing and resolves to an empty array" do
    p = Redis::Pipeline.new
    exec = p.multi { |tx| }
    p.size.should eq(0)
    p.buffer.to_s.should eq("")
    exec.resolved?.should be_true
    exec.value.should eq([] of Redis::Value)
  end

  it "refuses a nested multi" do
    p = Redis::Pipeline.new
    expect_raises(ArgumentError, /nested/) do
      p.multi { |tx| tx.multi { |inner| } }
    end
  end

  it "runs scripts inside a transaction with the pipeline's cache" do
    cache = Redis::ScriptCache.new
    script = Redis::Script.new("return 1")
    cache.add(script.sha)
    p = Redis::Pipeline.new(cache)
    f = nil
    p.multi { |tx| f = tx.run(script) }
    p.buffer.to_s.should contain("EVALSHA")
    p.resolve(0, "OK")
    p.resolve(1, "QUEUED")
    p.resolve(2, values(1_i64))
    f.not_nil!.value.should eq(1_i64)
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/crystal spec spec/std/redis/transaction_spec.cr`
Expected: compile error `undefined method 'multi'`.

- [ ] **Step 3: Write `transaction.cr`**

```crystal
# src/redis/transaction.cr
module Redis
  # Collects the commands of one `MULTI`..`EXEC` block. Created by
  # `Pipeline#multi`, and through it by `Client#multi` and
  # `Connection#multi`; never instantiated directly. Every typed command
  # method returns a `Future(T)` that is resolved from the `EXEC` reply.
  class Transaction < Pipeline
    # Not available: Redis does not allow a `MULTI` inside another.
    def multi(& : Transaction ->) : NoReturn
      raise ArgumentError.new("MULTI cannot be nested")
    end

    # :nodoc:
    def futures : Array(AbstractFuture)
      @futures
    end
  end

  # :nodoc:
  #
  # Stands in for the `QUEUED` reply of one command inside a transaction.
  # A queue-time rejection (for example a wrong arity) is forwarded to the
  # command's own future so that `value` raises the specific error rather
  # than the `EXECABORT` that follows.
  class QueuedFuture < AbstractFuture
    @resolved = false

    def initialize(@target : AbstractFuture)
    end

    def resolve(raw : Value | Exception) : Nil
      @resolved = true
      @target.resolve(raw) if raw.is_a?(CommandError)
    end

    def resolved? : Bool
      @resolved
    end
  end

  # :nodoc:
  #
  # The future of the `EXEC` reply. Fans an array out to the transaction's
  # futures element by element; turns nil into `AbortedError`; fails every
  # future that is not already resolved with any error reply or exception.
  class ExecFuture < Future(Array(Value))
    def initialize(@targets : Array(AbstractFuture))
      super(->(v : Value) { v.as(Array(Value)) })
    end

    def resolve(raw : Value | Exception) : Nil
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
      when Exception
        super(raw)
        @targets.each { |target| target.resolve(raw) unless target.resolved? }
      else
        fail_all(ProtocolError.new("unexpected EXEC reply #{raw.inspect}"))
      end
    end

    private def fail_all(error : Exception) : Nil
      @raw = error
      @resolved = true
      @targets.each { |target| target.resolve(error) }
    end
  end
end
```

- [ ] **Step 4: Add `Pipeline#multi`**

In `src/redis/pipeline.cr`, inside `class Pipeline` after `script_run`:

```crystal
    # Queues a `MULTI`..`EXEC` block. The block's commands return futures
    # resolved from the `EXEC` array; the returned future resolves to that
    # array itself, raises `AbortedError` if `EXEC` replied nil (a watched
    # key changed), the `EXECABORT` error if a command was rejected at
    # queue time, and `ProtocolError` on a malformed reply. Error replies
    # inside the array stay values; only the matching command's future
    # raises them.
    #
    # `size` grows by the block's command count plus two. The raw replies
    # returned by `Client#pipelined` include the `MULTI` `"OK"`, one
    # `"QUEUED"` per command, and the `EXEC` array. An empty block queues
    # nothing and returns a future already resolved to an empty array.
    def multi(& : Transaction ->) : Future(Array(Value))
      tx = Transaction.new(@script_cache)
      yield tx
      targets = tx.futures
      exec = ExecFuture.new(targets)
      if targets.empty?
        exec.resolve([] of Value)
        return exec
      end
      RESP.write_command(@buffer, {"MULTI"})
      @futures << Future(Nil).new(->(v : Value) { nil })
      @buffer.write(tx.buffer.to_slice)
      targets.each { |target| @futures << QueuedFuture.new(target) }
      RESP.write_command(@buffer, {"EXEC"})
      @futures << exec
      @size += targets.size + 2
      exec
    end
```

Add `require "./redis/transaction"` to `src/redis.cr` after `require "./redis/pipeline"`.

- [ ] **Step 5: Run the specs to verify they pass**

Run: `bin/crystal spec spec/std/redis/transaction_spec.cr spec/std/redis/pipeline_spec.cr`
Expected: all pass. If the nested-multi example fails to raise, the override signature differs from `Pipeline#multi`'s (`& : Transaction ->`); they must match exactly or Crystal treats them as two overloads.

- [ ] **Step 6: Format and commit**

```bash
bin/crystal tool format src/redis spec/std/redis spec/support/redis.cr
git add src/redis.cr src/redis/transaction.cr src/redis/pipeline.cr spec/std/redis/transaction_spec.cr
git commit -m "Redis: Transaction and Pipeline#multi with EXEC fan-out

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: `multi` and `watch` on `Client` and `Connection`, `Connection#pipelined`

**Files:**
- Modify: `src/redis/connection.cr` (add `pipelined`, `multi`, `watch`, `unwatch` after `pipeline`)
- Modify: `src/redis/client.cr` (add `multi`, `watch` after `pipelined`)
- Test: `spec/std/redis/transaction_spec.cr` (append a fake-server section)

**Interfaces:**
- Consumes: `Pipeline#multi` (Task 3); `Pipeline#buffer`, `#size`, `#resolve(index, raw)`; `Connection#check_open`, `#close`, `@socket`, `@max_bulk_size`, `@push_handler`; `Client#pipelined` and its constructor options (`@url`, `@db`, `@username`, `@password`, `@client_name`, `@protocol_option`, `@connect_timeout`, `@read_timeout`, `@tls_context`, `@max_bulk_size`).
- Produces: `Connection#pipelined(& : Pipeline ->) : Array(Value)`; `Connection#multi(&block : Transaction ->) : Array(Value)`; `Connection#watch(*keys : String) : Nil`; `Connection#unwatch : Nil`; `Client#multi(&block : Transaction ->) : Array(Value)`; `Client#watch(*keys : String, &block : Connection -> T) : T`.

- [ ] **Step 1: Append the failing specs**

Append to `spec/std/redis/transaction_spec.cr`:

```crystal
# A fake server with MULTI state per connection. Inside MULTI every
# command is queued and answered +QUEUED, except BADARITY which is
# rejected at queue time; EXEC answers -EXECABORT after a rejection, *-1
# when `abort` is set, an empty array if a SHORT command was queued, and
# otherwise one reply per queued command. `chunks` records how many
# commands each socket read returned.
private class TxServer
  getter chunks = [] of Int32
  getter seen = [] of Array(String)
  property abort = false

  def server
    RedisSpec::FakeServer.new do |io|
      queued = nil.as(Array(Array(String))?)
      buffer = Bytes.new(65536)
      loop do
        n = io.read(buffer)
        break if n == 0
        mem = IO::Memory.new(buffer[0, n])
        count = 0
        while cmd = RedisSpec::FakeServer.read_command(mem)
          count += 1
          @seen << cmd
          if q = queued
            if cmd[0] == "EXEC"
              queued = nil
              if q.any? { |c| c[0] == "BADARITY" }
                io << "-EXECABORT Transaction discarded because of previous errors.\r\n"
              elsif @abort
                io << "*-1\r\n"
              elsif q.any? { |c| c[0] == "SHORT" }
                io << "*0\r\n"
              else
                io << "*#{q.size}\r\n"
                q.each { |c| io << reply_for(c) }
              end
            else
              q << cmd
              io << (cmd[0] == "BADARITY" ? "-ERR wrong number of arguments for 'badarity' command\r\n" : "+QUEUED\r\n")
            end
          else
            case cmd[0]
            when "HELLO"
              io << RedisSpec::HELLO_REPLY
            when "MULTI"
              queued = [] of Array(String)
              io << "+OK\r\n"
            else
              io << reply_for(cmd)
            end
          end
        end
        @chunks << count if count > 0
        io.flush
      end
    end
  end

  # Commands seen after the handshake, first element only.
  def names : Array(String)
    @seen.reject { |c| c[0] == "HELLO" }.map(&.first)
  end

  private def reply_for(cmd : Array(String)) : String
    case cmd[0]
    when "INCR"    then ":1\r\n"
    when "GET"     then "$1\r\nv\r\n"
    when "FAILRUN" then "-ERR runtime failure\r\n"
    else                "+OK\r\n"
    end
  end
end

describe "Redis::Client#multi" do
  it "sends MULTI, the commands and EXEC in one chunk and returns the EXEC array" do
    fake = TxServer.new
    server = fake.server
    client = Redis::Client.new(server.url)
    client.ping
    f1 = nil
    f2 = nil
    replies = client.multi do |tx|
      f1 = tx.set("a", "1")
      f2 = tx.incr("n")
    end
    replies.should eq(values("OK", 1_i64))
    f1.not_nil!.value.should eq("OK")
    f2.not_nil!.value.should eq(1_i64)
    fake.chunks.should eq([1, 1, 4])
    fake.names.should eq(["PING", "MULTI", "SET", "INCR", "EXEC"])
    client.close
    server.close
  end

  it "inside pipelined returns the raw replies including OK and QUEUED" do
    fake = TxServer.new
    server = fake.server
    client = Redis::Client.new(server.url)
    exec = nil
    raw = client.pipelined do |p|
      p.get("x")
      exec = p.multi { |tx| tx.incr("n") }
    end
    raw.should eq(values("v", "OK", "QUEUED", values(1_i64)))
    exec.not_nil!.value.should eq(values(1_i64))
    client.close
    server.close
  end

  it "raises EXECABORT and keeps the queue-time error on its own future" do
    fake = TxServer.new
    server = fake.server
    client = Redis::Client.new(server.url)
    f1 = nil
    f2 = nil
    ex = expect_raises(Redis::CommandError) do
      client.multi do |tx|
        f1 = tx.command("BADARITY")
        f2 = tx.incr("n")
      end
    end
    ex.code.should eq("EXECABORT")
    expect_raises(Redis::CommandError, /wrong number/) { f1.not_nil!.value }
    expect_raises(Redis::CommandError, /EXECABORT/) { f2.not_nil!.value }
    client.close
    server.close
  end

  it "raises AbortedError when EXEC replies nil" do
    fake = TxServer.new
    fake.abort = true
    server = fake.server
    client = Redis::Client.new(server.url)
    f = nil
    expect_raises(Redis::AbortedError) { client.multi { |tx| f = tx.incr("n") } }
    expect_raises(Redis::AbortedError) { f.not_nil!.value }
    client.close
    server.close
  end

  it "keeps a runtime error as a value" do
    fake = TxServer.new
    server = fake.server
    client = Redis::Client.new(server.url)
    f1 = nil
    f2 = nil
    replies = client.multi do |tx|
      f1 = tx.command("FAILRUN")
      f2 = tx.incr("n")
    end
    replies.size.should eq(2)
    replies[0].should be_a(Redis::CommandError)
    replies[1].should eq(1_i64)
    expect_raises(Redis::CommandError, /runtime/) { f1.not_nil!.value }
    f2.not_nil!.value.should eq(1_i64)
    client.close
    server.close
  end

  it "an empty block does nothing" do
    fake = TxServer.new
    server = fake.server
    client = Redis::Client.new(server.url)
    client.multi { |tx| }.should eq([] of Redis::Value)
    fake.seen.should be_empty
    client.close
    server.close
  end
end

describe "Redis::Connection#pipelined and #multi" do
  it "produce the same bytes and results as the client" do
    fake = TxServer.new
    server = fake.server
    conn = Redis::Connection.new(server.url)
    f = nil
    raw = conn.pipelined do |p|
      p.get("x")
      f = p.incr("n")
    end
    raw.should eq(values("v", 1_i64))
    f.not_nil!.value.should eq(1_i64)
    fake.chunks.should eq([1, 2])
    g = nil
    conn.multi { |tx| g = tx.incr("n") }.should eq(values(1_i64))
    g.not_nil!.value.should eq(1_i64)
    fake.chunks.should eq([1, 2, 3])
    # The mismatch is detected when the future is read, not on the socket,
    # so the connection stays usable.
    expect_raises(Redis::ProtocolError) { conn.multi { |tx| tx.command("SHORT") } }
    conn.closed?.should be_false
    conn.ping.should eq("OK")
    conn.close
    server.close
  end

  it "resolves the remaining futures when the connection drops mid-pipeline" do
    server = RedisSpec::FakeServer.new do |io|
      while cmd = RedisSpec::FakeServer.read_command(io)
        case cmd[0]
        when "HELLO" then io << RedisSpec::HELLO_REPLY
        when "DIE"   then io.close
        else              io << "+OK\r\n"
        end
        io.flush
      end
    end
    conn = Redis::Connection.new(server.url)
    f1 = nil
    f2 = nil
    expect_raises(Redis::ConnectionError) do
      conn.pipelined do |p|
        f1 = p.command("ONE")
        f2 = p.command("DIE")
      end
    end
    f1.not_nil!.value.should eq("OK")
    expect_raises(Redis::ConnectionError) { f2.not_nil!.value }
    server.close
  end
end

describe "Redis::Client#watch" do
  it "opens a dedicated connection, sends WATCH, yields it and closes it" do
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
    inner.not_nil!.closed?.should be_true
    # Once from the client's own connection, once from the dedicated one.
    fake.seen.count(["SELECT", "3"]).should eq(2)
    fake.seen.should contain(["WATCH", "k1", "k2"])
    client.connected?.should be_true
    client.close
    server.close
  end

  it "closes the connection when the block raises and refuses no keys" do
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
    inner.not_nil!.closed?.should be_true
    client.close
    server.close
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/crystal spec spec/std/redis/transaction_spec.cr`
Expected: compile error `undefined method 'multi' for Redis::Client`.

- [ ] **Step 3: `Connection#pipelined`, `multi`, `watch`, `unwatch`**

In `src/redis/connection.cr`, after `def pipeline(commands : Indexable)`:

```crystal
    # Runs the block against a `Pipeline`, sends every queued command in a
    # single write, and returns the raw replies in order. Error replies
    # stay in the array as `CommandError` values and are raised by the
    # corresponding `Future#value`. `IO::TimeoutError` and `ProtocolError`
    # close the connection and propagate; a lost socket raises
    # `ConnectionError`. In every failure case the futures not yet given a
    # reply are resolved with that exception first.
    def pipelined(& : Pipeline ->) : Array(Value)
      pipeline = Pipeline.new(@script_cache)
      yield pipeline
      check_open
      return [] of Value if pipeline.size == 0
      results = Array(Value).new(pipeline.size)
      begin
        @socket.write(pipeline.buffer.to_slice)
        @socket.flush
        pipeline.size.times do |i|
          value = RESP.read(@socket, max_bulk_size: @max_bulk_size, push: @push_handler)
          pipeline.resolve(i, value)
          results << value
        end
      rescue ex : IO::TimeoutError | ProtocolError
        close
        fail_futures(pipeline, results.size, ex)
        raise ex
      rescue ex : IO::Error
        close
        error = ConnectionError.new("connection lost: #{ex.message}", cause: ex)
        fail_futures(pipeline, results.size, error)
        raise error
      end
      results
    end

    # Runs the block's commands as one `MULTI`..`EXEC` transaction and
    # returns the `EXEC` array. Raises `AbortedError` if a key marked with
    # `watch` changed (`EXEC` replied nil), the `EXECABORT` `CommandError`
    # if a command was rejected at queue time, `ConnectionError` if the
    # socket drops. Error replies inside the array stay values; the
    # matching command's future raises them.
    #
    # ```
    # conn.watch("balance")
    # balance = conn.get("balance").not_nil!.to_i
    # conn.multi { |tx| tx.set("balance", balance - 10) } # => ["OK"]
    # ```
    def multi(&block : Transaction ->) : Array(Value)
      exec = nil
      pipelined { |p| exec = p.multi(&block) }
      exec.not_nil!.value
    end

    # Marks *keys* for optimistic locking: a following `multi` on this
    # connection raises `AbortedError` if any of them changed in between.
    # Raises `ArgumentError` without keys. `WATCH` is per connection, which
    # is why it exists only here and not on `Client`; see `Client#watch`.
    def watch(*keys : String) : Nil
      raise ArgumentError.new("WATCH needs at least one key") if keys.empty?
      args = Array(RESP::Arg).new(keys.size + 1)
      args << "WATCH"
      keys.each { |k| args << k }
      call(args)
      nil
    end

    # Forgets every key marked with `watch`.
    def unwatch : Nil
      call({"UNWATCH"})
      nil
    end

    private def fail_futures(pipeline : Pipeline, from : Int32, error : Exception) : Nil
      (from...pipeline.size).each { |i| pipeline.resolve(i, error) }
    end
```

- [ ] **Step 4: `Client#multi` and `Client#watch`**

In `src/redis/client.cr`, after `def pipelined`:

```crystal
    # Runs the block's commands as one `MULTI`..`EXEC` transaction, sent in
    # a single write so that no other fiber's command can land between
    # `MULTI` and `EXEC`, and returns the `EXEC` array. Typed methods on the
    # transaction return futures resolved from that array. Raises the
    # `EXECABORT` `CommandError` if a command was rejected at queue time,
    # `ConnectionError` if the socket drops. Error replies inside the array
    # stay values; only the matching command's future raises them.
    #
    # `WATCH` is not available here (it is per-connection state that
    # concurrent fibers would clobber); use `watch` for optimistic locking.
    #
    # ```
    # count = nil
    # redis.multi do |tx|
    #   tx.set("a", "1")
    #   count = tx.incr("hits")
    # end                     # => ["OK", 1_i64]
    # count.not_nil!.value    # => 1_i64
    # ```
    def multi(&block : Transaction ->) : Array(Value)
      exec = nil
      pipelined { |p| exec = p.multi(&block) }
      exec.not_nil!.value
    end

    # Opens a dedicated `Connection` with this client's options, sends
    # `WATCH` for *keys*, yields the connection for the read-then-`multi`
    # sequence, and closes it afterwards, whatever the block does. Returns
    # the block's value. An `AbortedError` raised by `Connection#multi`
    # inside the block means a watched key changed; retrying is the
    # caller's loop:
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
    # Raises `ArgumentError` without keys, `ConnectionError` if the
    # dedicated connection cannot be opened.
    def watch(*keys : String, &block : Connection -> T) : T forall T
      raise ArgumentError.new("WATCH needs at least one key") if keys.empty?
      conn = Connection.new(@url, db: @db, username: @username, password: @password, client_name: @client_name,
        protocol: @protocol_option, connect_timeout: @connect_timeout, read_timeout: @read_timeout,
        tls_context: @tls_context, max_bulk_size: @max_bulk_size)
      begin
        conn.watch(*keys)
        block.call(conn)
      ensure
        conn.close
      end
    end
```

- [ ] **Step 5: Run the specs to verify they pass**

Run: `bin/crystal spec spec/std/redis/transaction_spec.cr spec/std/redis/connection_spec.cr spec/std/redis/client_spec.cr`
Expected: all pass. If `fake.chunks` shows `[1, 1, 1, 3]` instead of `[1, 1, 4]`, the transaction bytes were written in more than one critical section; `Client#multi` must go through `pipelined`, which appends the whole buffer at once.

- [ ] **Step 6: Format and commit**

```bash
bin/crystal tool format src/redis spec/std/redis spec/support/redis.cr
git add src/redis/connection.cr src/redis/client.cr spec/std/redis/transaction_spec.cr
git commit -m "Redis: multi on Client and Connection, Connection#pipelined, watch on a dedicated connection

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: `Subscriber` core: connect, control commands with confirmations, message delivery, close

**Files:**
- Create: `src/redis/subscriber.cr`
- Modify: `src/redis.cr` (`require "./redis/subscriber"` after `require "./redis/client"`)
- Modify: `spec/support/redis.cr` (add `RedisSpec.pubsub_frame`)
- Test: `spec/std/redis/subscriber_spec.cr`

**Interfaces:**
- Consumes: `Connection.new(url, username:, password:, client_name:, protocol:, connect_timeout:, read_timeout:, tls_context:, max_bulk_size:)`, `Connection#socket`, `#send(args : Indexable)`, `#close`, `#protocol`; `RESP.read(io, max_bulk_size:, push:)`.
- Produces: `Redis::Subscriber` with `Message` record (`channel`, `payload`, `pattern`), `new(url, *, username, password, client_name, protocol, connect_timeout, read_timeout, tls_context, max_bulk_size, capacity = 64, reconnect = true)`, `subscribe(*channels)`, `psubscribe(*patterns)`, `unsubscribe(*channels)`, `punsubscribe(*patterns)`, `ping`, `receive`, `receive?`, `each`, `messages`, `channels`, `patterns`, `protocol`, `connected?`, `closed?`, `error`, `on_disconnect`, `on_reconnect`, `close`. In this task a drop always closes the subscriber (`reconnect` is stored but only honoured in Task 6). `RedisSpec.pubsub_frame(protocol, *items)`.

- [ ] **Step 1: Add the frame helper to the spec support**

Append inside `module RedisSpec` in `spec/support/redis.cr` (after `class FakeServer`):

```crystal
  # One pub/sub frame as the server sends it: a RESP3 push (`>`) or a
  # RESP2 array (`*`). Strings become bulk strings, integers become
  # integers, nil becomes a null bulk string.
  def self.pubsub_frame(protocol : Int32, *items : String | Int32 | Nil) : String
    String.build do |s|
      s << (protocol == 3 ? '>' : '*') << items.size << "\r\n"
      items.each do |item|
        case item
        when Int32  then s << ':' << item << "\r\n"
        when String then s << '$' << item.bytesize << "\r\n" << item << "\r\n"
        when Nil    then s << "$-1\r\n"
        end
      end
    end
  end
```

- [ ] **Step 2: Write the failing spec**

```crystal
# spec/std/redis/subscriber_spec.cr
require "spec"
require "../../support/redis"

# A fake pub/sub server for one protocol. Confirms every SUBSCRIBE-family
# command frame by frame (after `confirm_delay`, or never when
# `swallow_control` is set), answers PING in subscribed-mode shape, and
# lets the spec inject frames on the newest connection.
private class PubSubServer
  # Commands per accepted connection, in order, handshake excluded. (A
  # `protocol: 2` subscriber sends no HELLO at all, so connections are
  # tracked by socket, not by handshake.)
  getter seen = [] of Array(Array(String))
  property confirm_delay : Time::Span? = nil
  property swallow_control = false
  @sockets = [] of IO
  @protocol : Int32

  def initialize(@protocol : Int32)
  end

  def connections : Int32
    @seen.size
  end

  # Commands seen on the *n*th connection (1-based).
  def commands_on(n : Int32) : Array(Array(String))
    @seen[n - 1]
  end

  def server
    RedisSpec::FakeServer.new do |io|
      mine = [] of Array(String)
      @seen << mine
      @sockets << io
      while cmd = RedisSpec::FakeServer.read_command(io)
        mine << cmd unless cmd[0] == "HELLO"
        case cmd[0]
        when "HELLO"
          io << (@protocol == 3 ? RedisSpec::HELLO_REPLY : "-ERR unknown command 'HELLO'\r\n")
        when "SUBSCRIBE", "PSUBSCRIBE", "UNSUBSCRIBE", "PUNSUBSCRIBE"
          next if @swallow_control
          if delay = @confirm_delay
            sleep delay
          end
          kind = cmd[0].downcase
          names = cmd[1..]
          if names.empty?
            io << RedisSpec.pubsub_frame(@protocol, kind, nil, 0)
          else
            names.each_with_index { |name, i| io << RedisSpec.pubsub_frame(@protocol, kind, name, i + 1) }
          end
        when "PING"
          io << (@protocol == 3 ? "+PONG\r\n" : RedisSpec.pubsub_frame(2, "pong", ""))
        else
          io << "+OK\r\n"
        end
        io.flush
      end
    end
  end

  def publish(channel : String, payload : String) : Nil
    inject RedisSpec.pubsub_frame(@protocol, "message", channel, payload)
  end

  def ppublish(pattern : String, channel : String, payload : String) : Nil
    inject RedisSpec.pubsub_frame(@protocol, "pmessage", pattern, channel, payload)
  end

  def inject(raw : String) : Nil
    io = @sockets.last
    io << raw
    io.flush
  end

  # Closes the newest client socket from the server side.
  def kill : Nil
    @sockets.last.close
  end
end

private def wait_until(timeout = 2.seconds, &)
  deadline = Time.monotonic + timeout
  until yield
    raise "timed out waiting" if Time.monotonic > deadline
    sleep 5.milliseconds
  end
end

private def subscriber_specs(protocol : Int32)
  describe "Redis::Subscriber (RESP#{protocol})" do
    it "connects eagerly and subscribe waits for every confirmation" do
      fake = PubSubServer.new(protocol)
      fake.confirm_delay = 50.milliseconds
      server = fake.server
      sub = Redis::Subscriber.new(server.url, protocol: protocol)
      sub.connected?.should be_true
      sub.protocol.should eq(protocol)
      started = Time.monotonic
      sub.subscribe("a", "b")
      (Time.monotonic - started).should be >= 50.milliseconds
      sub.channels.should eq(["a", "b"])
      fake.commands_on(1).should eq([["SUBSCRIBE", "a", "b"]])
      sub.close
      sub.closed?.should be_true
      server.close
    end

    it "delivers messages and pattern messages in order" do
      fake = PubSubServer.new(protocol)
      server = fake.server
      sub = Redis::Subscriber.new(server.url, protocol: protocol)
      sub.subscribe("a")
      sub.psubscribe("log.*")
      sub.patterns.should eq(["log.*"])
      fake.publish("a", "hi")
      fake.ppublish("log.*", "log.x", "p")
      fake.publish("a", "again")
      sub.receive.should eq(Redis::Subscriber::Message.new("a", "hi"))
      sub.receive.should eq(Redis::Subscriber::Message.new("log.x", "p", "log.*"))
      m = sub.receive
      m.channel.should eq("a")
      m.payload.should eq("again")
      m.pattern.should be_nil
      sub.close
      server.close
    end

    it "unsubscribes by name and all at once" do
      fake = PubSubServer.new(protocol)
      server = fake.server
      sub = Redis::Subscriber.new(server.url, protocol: protocol)
      sub.subscribe("a", "b", "c")
      sub.unsubscribe("a")
      sub.channels.should eq(["b", "c"])
      sub.unsubscribe
      sub.channels.should be_empty
      sub.unsubscribe # nothing subscribed: server answers one nil frame
      sub.psubscribe("p.*")
      sub.punsubscribe
      sub.patterns.should be_empty
      fake.commands_on(1).should eq([
        ["SUBSCRIBE", "a", "b", "c"], ["UNSUBSCRIBE", "a"], ["UNSUBSCRIBE"], ["UNSUBSCRIBE"],
        ["PSUBSCRIBE", "p.*"], ["PUNSUBSCRIBE"],
      ])
      sub.close
      server.close
    end

    it "pings" do
      fake = PubSubServer.new(protocol)
      server = fake.server
      sub = Redis::Subscriber.new(server.url, protocol: protocol)
      sub.subscribe("a")
      sub.ping
      fake.commands_on(1).last.should eq(["PING"])
      sub.close
      server.close
    end

    it "a capacity of 1 still delivers everything in order" do
      fake = PubSubServer.new(protocol)
      server = fake.server
      sub = Redis::Subscriber.new(server.url, protocol: protocol, capacity: 1)
      sub.subscribe("a")
      20.times { |i| fake.publish("a", i.to_s) }
      got = [] of String
      20.times { got << sub.receive.payload }
      got.should eq((0...20).map(&.to_s))
      sub.close
      server.close
    end

    it "each iterates until close, and close drains buffered messages first" do
      fake = PubSubServer.new(protocol)
      server = fake.server
      sub = Redis::Subscriber.new(server.url, protocol: protocol, capacity: 8)
      sub.subscribe("a")
      fake.publish("a", "1")
      fake.publish("a", "2")
      sub.receive.payload.should eq("1")
      sleep 20.milliseconds # let "2" reach the channel before closing
      sub.close
      sub.receive?.try(&.payload).should eq("2")
      sub.receive?.should be_nil
      expect_raises(Redis::ConnectionError, /closed/) { sub.receive }
      expect_raises(Redis::ConnectionError, /closed/) { sub.subscribe("b") }
      seen = [] of String
      sub.each { |m| seen << m.payload }
      seen.should be_empty
      server.close
    end

    it "rejects an empty subscribe" do
      fake = PubSubServer.new(protocol)
      server = fake.server
      sub = Redis::Subscriber.new(server.url, protocol: protocol)
      expect_raises(ArgumentError) { sub.subscribe }
      expect_raises(ArgumentError) { sub.psubscribe }
      sub.close
      server.close
    end

    it "with reconnect: false a drop closes the subscriber and reports the cause" do
      fake = PubSubServer.new(protocol)
      server = fake.server
      sub = Redis::Subscriber.new(server.url, protocol: protocol, reconnect: false)
      causes = [] of Exception
      sub.on_disconnect = ->(ex : Exception) { causes << ex; nil }
      sub.subscribe("a")
      fake.kill
      sub.receive?.should be_nil
      sub.closed?.should be_true
      sub.connected?.should be_false
      sub.error.should be_a(IO::Error)
      causes.size.should eq(1)
      expect_raises(Redis::ConnectionError) { sub.subscribe("b") }
      server.close
    end

    it "an unknown frame is a ProtocolError drop" do
      fake = PubSubServer.new(protocol)
      server = fake.server
      sub = Redis::Subscriber.new(server.url, protocol: protocol, reconnect: false)
      sub.subscribe("a")
      fake.inject(RedisSpec.pubsub_frame(protocol, "weird", "x"))
      sub.receive?.should be_nil
      sub.error.should be_a(Redis::ProtocolError)
      server.close
    end

    it "read_timeout bounds a control command the server never confirms" do
      fake = PubSubServer.new(protocol)
      fake.swallow_control = true
      server = fake.server
      sub = Redis::Subscriber.new(server.url, protocol: protocol, read_timeout: 100.milliseconds, reconnect: false)
      expect_raises(IO::TimeoutError) { sub.subscribe("a") }
      sub.channels.should eq(["a"])
      sub.receive?.should be_nil
      server.close
    end
  end
end

subscriber_specs(3)
subscriber_specs(2)
```

- [ ] **Step 3: Run it to verify it fails**

Run: `bin/crystal spec spec/std/redis/subscriber_spec.cr`
Expected: compile error `undefined constant Redis::Subscriber`.

- [ ] **Step 4: Write `subscriber.cr`**

```crystal
# src/redis/subscriber.cr
module Redis
  # A pub/sub subscription on its own connection.
  #
  # Messages arrive on `messages`, a bounded `Channel`; read them with
  # `receive`, `receive?` or `each`. `subscribe` and friends return once
  # the server has confirmed. A full channel blocks the reader fiber, so
  # a slow consumer applies backpressure to the server rather than
  # dropping messages; the server's own `client-output-buffer-limit` may
  # then disconnect it, which shows up as a reconnect.
  #
  # ```
  # sub = Redis::Subscriber.new("redis://localhost:6379")
  # sub.subscribe("news")
  # sub.psubscribe("log.*")
  # sub.each do |msg|
  #   puts "#{msg.channel}: #{msg.payload}"
  # end
  # ```
  #
  # A lost connection is reconnected with exponential backoff (100 ms up
  # to 5 s) and every channel and pattern is resubscribed, unless
  # `reconnect: false`, in which case the subscriber closes and `error`
  # holds the cause. Messages published while disconnected are lost: Redis
  # pub/sub has no history. `on_disconnect` and `on_reconnect` observe the
  # gap. Pub/sub is database-independent, so there is no `db` option.
  #
  # `close` is required: the subscriber owns a reader fiber and has no
  # finalizer. `Client#subscriber` opens one with the client's options.
  class Subscriber
    # One delivered publication. *pattern* is set when it arrived through
    # `psubscribe`.
    record Message, channel : String, payload : String, pattern : String? = nil

    # A control command waiting for its confirmation frames. *waiter* is
    # nil for the subscriber's own resubscribe after a reconnect.
    private class Ack
      property remaining : Int32
      getter waiter : Channel(Exception?)?

      def initialize(@remaining : Int32, @waiter : Channel(Exception?)?)
      end
    end

    # The delivered messages. Exposed so that a caller can `select` over it
    # together with other channels.
    getter messages : Channel(Message)
    # The exception that ended the current connection, or the last one
    # while reconnecting; `nil` while the connection is healthy.
    getter error : Exception?
    # Called on the reader fiber with the cause each time the connection
    # drops. An exception raised by the hook closes the subscriber.
    property on_disconnect : (Exception ->)?
    # Called on the reader fiber after a reconnect has resubscribed every
    # channel and pattern. An exception raised by the hook closes the
    # subscriber.
    property on_reconnect : (->)?

    @mutex = Mutex.new
    @connection : Connection?
    @channels = Set(String).new
    @patterns = Set(String).new
    @pending = Deque(Ack).new
    @closed = false
    @close_signal = Channel(Nil).new
    @url : URI

    # Connects to *url* (or `Connection::DEFAULT_URL`) and runs the same
    # handshake as `Connection.new`, raising the same errors. *capacity*
    # sizes the message channel; *read_timeout* bounds how long
    # `subscribe` and the other control commands wait for the server's
    # confirmation, not how long the connection may stay idle. Raises
    # `ArgumentError` if *protocol* is outside `2..3`.
    def initialize(url : String | URI = Connection::DEFAULT_URL, *, @username : String? = nil,
                   @password : String? = nil, @client_name : String? = nil, protocol @protocol_option : Int32 = 3,
                   @connect_timeout : Time::Span = 5.seconds, @read_timeout : Time::Span? = nil,
                   @tls_context : OpenSSL::SSL::Context::Client? = nil, @max_bulk_size : Int32 = RESP::MAX_BULK_SIZE,
                   capacity : Int32 = 64, @reconnect : Bool = true)
      @url = url.is_a?(URI) ? url : URI.parse(url)
      @messages = Channel(Message).new(capacity)
      conn = connect
      @connection = conn
      spawn(name: "redis-subscriber") { run(conn) }
    end

    # The negotiated protocol version, or `nil` while disconnected. An
    # advisory snapshot read without the lock.
    def protocol : Int32?
      @connection.try &.protocol
    end

    # Whether a connection is currently open. An advisory snapshot read
    # without the lock.
    def connected? : Bool
      !@connection.nil?
    end

    # Whether `close` has been called or a drop closed the subscriber.
    def closed? : Bool
      @closed
    end

    # The channels this subscriber wants, sorted. They are resubscribed
    # after a reconnect.
    def channels : Array(String)
      @mutex.synchronize { @channels.to_a.sort! }
    end

    # The patterns this subscriber wants, sorted.
    def patterns : Array(String)
      @mutex.synchronize { @patterns.to_a.sort! }
    end

    # Subscribes to *channels* and returns once the server confirmed each.
    # Raises `ArgumentError` without channels, `ConnectionError` if the
    # subscriber is closed or the connection drops before the confirmation
    # (the channels stay recorded and are subscribed on reconnect),
    # `IO::TimeoutError` if `read_timeout` elapses. While the subscriber is
    # reconnecting the channels are only recorded and the call returns
    # immediately.
    def subscribe(*channels : String) : Nil
      raise ArgumentError.new("subscribe needs at least one channel") if channels.empty?
      names = channels.to_a
      control("SUBSCRIBE", names) do
        @channels.concat(names)
        names.size
      end
    end

    # Subscribes to *patterns* (glob style, `log.*`); otherwise like
    # `subscribe`.
    def psubscribe(*patterns : String) : Nil
      raise ArgumentError.new("psubscribe needs at least one pattern") if patterns.empty?
      names = patterns.to_a
      control("PSUBSCRIBE", names) do
        @patterns.concat(names)
        names.size
      end
    end

    # Unsubscribes from *channels*, or from every channel when none is
    # given, and returns once the server confirmed. Errors as `subscribe`.
    def unsubscribe(*channels : String) : Nil
      names = [] of String
      channels.each { |c| names << c }
      control("UNSUBSCRIBE", names) do
        if names.empty?
          count = @channels.size
          @channels.clear
          count == 0 ? 1 : count
        else
          names.each { |n| @channels.delete(n) }
          names.size
        end
      end
    end

    # Unsubscribes from *patterns*, or from every pattern when none is
    # given; otherwise like `unsubscribe`.
    def punsubscribe(*patterns : String) : Nil
      names = [] of String
      patterns.each { |p| names << p }
      control("PUNSUBSCRIBE", names) do
        if names.empty?
          count = @patterns.size
          @patterns.clear
          count == 0 ? 1 : count
        else
          names.each { |n| @patterns.delete(n) }
          names.size
        end
      end
    end

    # Sends `PING` and returns once the server answered. A cheap liveness
    # check for an idle subscription. Errors as `subscribe`.
    def ping : Nil
      control("PING", [] of String) { 1 }
    end

    # Blocks until the next message. Raises `ConnectionError` once the
    # subscriber is closed and no buffered message is left.
    def receive : Message
      @messages.receive
    rescue Channel::ClosedError
      raise ConnectionError.new("subscriber is closed")
    end

    # Blocks until the next message; `nil` once the subscriber is closed
    # and no buffered message is left.
    def receive? : Message?
      @messages.receive?
    end

    # Yields every message until the subscriber is closed.
    def each(& : Message ->) : Nil
      while message = receive?
        yield message
      end
    end

    # Closes the connection and the message channel. Control commands in
    # flight raise `ConnectionError`; messages already buffered can still
    # be read with `receive?`. Idempotent.
    def close : Nil
      conn, acks = @mutex.synchronize do
        return if @closed
        @closed = true
        c = @connection
        @connection = nil
        drained = @pending.to_a
        @pending.clear
        {c, drained}
      end
      @close_signal.close
      conn.try &.close
      error = ConnectionError.new("subscriber is closed")
      acks.each { |ack| ack.waiter.try &.send(error) }
      @messages.close
    end

    private def connect : Connection
      Connection.new(@url, username: @username, password: @password, client_name: @client_name,
        protocol: @protocol_option, connect_timeout: @connect_timeout, read_timeout: nil,
        tls_context: @tls_context, max_bulk_size: @max_bulk_size)
    end

    # Records the change (the block runs under the mutex and returns the
    # number of confirmation frames to expect), sends *cmd* if connected,
    # and waits for the confirmations.
    private def control(cmd : String, names : Array(String), & : -> Int32) : Nil
      # Returns `{connection, waiter}` or nil when only recorded. Both
      # come out of the block together: a variable assigned inside a block
      # is closured and the compiler will not narrow it afterwards.
      sent = @mutex.synchronize do
        raise ConnectionError.new("subscriber is closed") if @closed
        remaining = yield
        c = @connection
        next nil unless c
        args = Array(RESP::Arg).new(names.size + 1)
        args << cmd
        names.each { |n| args << n }
        w = Channel(Exception?).new(1)
        @pending.push(Ack.new(remaining, w))
        c.send(args)
        {c, w}
      end
      return unless sent
      wait_ack(sent[1], sent[0])
    end

    private def wait_ack(waiter : Channel(Exception?), conn : Connection) : Nil
      error = if deadline = @read_timeout
                select
                when e = waiter.receive
                  e
                when timeout(deadline)
                  timeout_error = IO::TimeoutError.new("Redis subscriber command timed out after #{deadline}")
                  drop(conn, timeout_error)
                  raise timeout_error
                end
              else
                waiter.receive
              end
      raise error if error
    end

    # The reader fiber. Reads until the connection fails, then closes the
    # subscriber (Task 6 adds the reconnect loop here).
    private def run(conn : Connection) : Nil
      cause = read_loop(conn)
      return if @closed
      drop(conn, cause)
      on_disconnect.try &.call(cause)
      close
    rescue ex
      # A hook raised: there is nobody to report it to, so shut down.
      @mutex.synchronize { @error = ex }
      close
    end

    # Reads frames until the connection fails; returns the failure.
    private def read_loop(conn : Connection) : Exception
      socket = conn.socket
      push = ->(frame : Array(Value)) { dispatch(frame) }
      loop do
        value = RESP.read(socket, max_bulk_size: @max_bulk_size, push: push)
        case value
        when Array  then dispatch(value)  # RESP2: pub/sub frames are plain arrays
        when String then confirm          # RESP3: `PING` answers `+PONG`
        else             raise ProtocolError.new("unexpected reply in subscribed mode: #{value.inspect}")
        end
      end
    rescue ex
      ex
    end

    private def dispatch(frame : Array(Value)) : Nil
      case frame[0]?
      when "message"
        if frame.size == 3 && (channel = frame[1]).is_a?(String) && (payload = frame[2]).is_a?(String)
          @messages.send(Message.new(channel, payload))
          return
        end
      when "pmessage"
        if frame.size == 4 && (pattern = frame[1]).is_a?(String) && (channel = frame[2]).is_a?(String) &&
           (payload = frame[3]).is_a?(String)
          @messages.send(Message.new(channel, payload, pattern))
          return
        end
      when "subscribe", "psubscribe", "unsubscribe", "punsubscribe", "pong"
        confirm
        return
      end
      raise ProtocolError.new("unexpected pub/sub frame #{frame.inspect}")
    end

    # One confirmation frame arrived: count it against the oldest pending
    # control command and wake its caller when it is complete.
    private def confirm : Nil
      waiter = @mutex.synchronize do
        ack = @pending.first? || raise ProtocolError.new("unsolicited confirmation")
        ack.remaining -= 1
        next nil if ack.remaining > 0
        @pending.shift
        ack.waiter
      end
      waiter.try &.send(nil)
    end

    # Tears *conn* down if it is still current: records *cause*, fails
    # every pending control command, closes the socket. Idempotent per
    # connection, safe from any fiber.
    private def drop(conn : Connection, cause : Exception) : Nil
      acks = @mutex.synchronize do
        next nil unless @connection.same?(conn)
        @connection = nil
        @error = cause
        drained = @pending.to_a
        @pending.clear
        drained
      end
      return unless acks
      conn.close
      error = ConnectionError.new("connection lost: #{cause.message}", cause: cause)
      acks.each { |ack| ack.waiter.try &.send(error) }
    end
  end
end
```

Add `require "./redis/subscriber"` to `src/redis.cr` after `require "./redis/client"`.

- [ ] **Step 5: Run the specs to verify they pass**

Run: `bin/crystal spec spec/std/redis/subscriber_spec.cr`
Expected: all examples pass at both protocols. Notes for likely failures:
- The "reconnect: false" examples pass here because `run` always closes on a drop; Task 6 keeps that behaviour behind `@reconnect`.
- If the RESP2 "pings" example hangs, the server's `pong` frame is not reaching `dispatch`: on RESP2 `RESP.read` returns the array and `read_loop` must call `dispatch` on it.
- If `close` deadlocks, `return if @closed` inside `synchronize` is being used with a captured block; it must be a plain `synchronize { }` block so `return` leaves the method.

- [ ] **Step 6: Format and commit**

```bash
bin/crystal tool format src/redis spec/std/redis spec/support/redis.cr
git add src/redis.cr src/redis/subscriber.cr spec/support/redis.cr spec/std/redis/subscriber_spec.cr
git commit -m "Redis: Subscriber on a dedicated connection with confirmed control commands

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: `Subscriber` reconnect with backoff and resubscribe

**Files:**
- Modify: `src/redis/subscriber.cr` (replace `run`, add `reconnect_loop`, `resubscribe`)
- Test: `spec/std/redis/subscriber_spec.cr` (append examples inside `subscriber_specs`)

**Interfaces:**
- Consumes: everything from Task 5; `@close_signal`, `@reconnect`, `drop`, `connect`.
- Produces: the documented reconnect behaviour: backoff 100 ms doubling to 5 s, `SUBSCRIBE` then `PSUBSCRIBE` of the desired sets on the new connection, `on_reconnect`, `error` cleared, `close` interrupting the backoff.

- [ ] **Step 1: Append the failing specs**

Inside `subscriber_specs` in `spec/std/redis/subscriber_spec.cr`, before the closing `end` of the `describe`:

```crystal
    it "reconnects, resubscribes channels then patterns, and keeps delivering" do
      fake = PubSubServer.new(protocol)
      server = fake.server
      sub = Redis::Subscriber.new(server.url, protocol: protocol)
      disconnected = Channel(Exception).new(1)
      reconnected = Channel(Nil).new(1)
      sub.on_disconnect = ->(ex : Exception) { disconnected.send(ex); nil }
      sub.on_reconnect = -> { reconnected.send(nil); nil }
      sub.subscribe("a", "b")
      sub.psubscribe("log.*")
      fake.kill
      disconnected.receive.should be_a(IO::Error)
      sub.error.should be_a(IO::Error)
      reconnected.receive
      # The hook fires when the resubscribe has been sent, which can be
      # before the fake server has read it.
      wait_until { fake.connections == 2 && fake.commands_on(2).size == 2 }
      fake.commands_on(2).should eq([["SUBSCRIBE", "a", "b"], ["PSUBSCRIBE", "log.*"]])
      sub.connected?.should be_true
      sub.error.should be_nil
      sub.channels.should eq(["a", "b"])
      fake.publish("a", "after")
      sub.receive.payload.should eq("after")
      sub.ping
      sub.close
      server.close
    end

    it "records a subscribe made while disconnected and applies it on reconnect" do
      fake = PubSubServer.new(protocol)
      server = fake.server
      sub = Redis::Subscriber.new(server.url, protocol: protocol)
      disconnected = Channel(Nil).new(1)
      reconnected = Channel(Nil).new(1)
      sub.on_disconnect = ->(ex : Exception) { disconnected.send(nil); nil }
      sub.on_reconnect = -> { reconnected.send(nil); nil }
      sub.subscribe("a")
      fake.kill
      disconnected.receive
      sub.subscribe("late") # returns at once: recorded only
      sub.channels.should eq(["a", "late"])
      reconnected.receive
      wait_until { fake.connections == 2 && fake.commands_on(2).size >= 1 }
      fake.commands_on(2).first.should eq(["SUBSCRIBE", "a", "late"])
      sub.close
      server.close
    end

    it "keeps retrying with backoff while the server is down and close interrupts the wait" do
      fake = PubSubServer.new(protocol)
      server = fake.server
      sub = Redis::Subscriber.new(server.url, protocol: protocol, connect_timeout: 200.milliseconds)
      disconnected = Channel(Nil).new(1)
      sub.on_disconnect = ->(ex : Exception) { disconnected.send(nil); nil }
      sub.subscribe("a")
      server.close
      fake.kill
      disconnected.receive
      sleep 400.milliseconds # at least the 100 ms and 200 ms attempts have failed
      sub.connected?.should be_false
      sub.closed?.should be_false
      started = Time.monotonic
      sub.close
      (Time.monotonic - started).should be < 100.milliseconds
      sub.receive?.should be_nil
    end

    it "a hook that raises closes the subscriber" do
      fake = PubSubServer.new(protocol)
      server = fake.server
      sub = Redis::Subscriber.new(server.url, protocol: protocol)
      sub.on_disconnect = ->(ex : Exception) : Nil { raise "hook failed" }
      sub.subscribe("a")
      fake.kill
      sub.receive?.should be_nil
      sub.closed?.should be_true
      sub.error.try(&.message).should eq("hook failed")
      server.close
    end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/crystal spec spec/std/redis/subscriber_spec.cr -e reconnect`
Expected: the "reconnects" example fails (the subscriber closes instead; `reconnected.receive` never returns, so the example hangs. If it hangs, stop it and treat that as the failure.)

- [ ] **Step 3: Replace `run` and add the reconnect loop**

In `src/redis/subscriber.cr` replace the whole `private def run(conn : Connection) : Nil ... end` method with:

```crystal
    # The reader fiber: reads until the connection fails, then either
    # reconnects and resubscribes or, with `reconnect: false`, closes.
    private def run(conn : Connection) : Nil
      loop do
        cause = read_loop(conn)
        return if @closed
        drop(conn, cause)
        on_disconnect.try &.call(cause)
        unless @reconnect
          close
          return
        end
        conn = reconnect_loop || return
        on_reconnect.try &.call
      end
    rescue ex
      # A hook raised: there is nobody to report it to, so shut down.
      @mutex.synchronize { @error = ex }
      close
    end

    # Tries to reconnect with exponential backoff until it succeeds or the
    # subscriber is closed (nil). On success the desired channels and
    # patterns have been resubscribed on the returned connection.
    private def reconnect_loop : Connection?
      delay = 100.milliseconds
      loop do
        select
        when @close_signal.receive?
          return nil
        when timeout(delay)
        end
        delay = {delay * 2, 5.seconds}.min
        conn = begin
          connect
        rescue Error | IO::Error | OpenSSL::SSL::Error
          next
        end
        installed = begin
          @mutex.synchronize do
            if @closed
              false
            else
              @connection = conn
              @error = nil
              resubscribe(conn)
              true
            end
          end
        rescue ex : ConnectionError
          # The fresh socket died while resubscribing; count it as a
          # failed attempt.
          drop(conn, ex)
          next
        end
        unless installed
          conn.close
          return nil
        end
        return conn
      end
    end

    # Under @mutex. Sends one SUBSCRIBE for every desired channel and one
    # PSUBSCRIBE for every desired pattern, with acks nobody waits on.
    private def resubscribe(conn : Connection) : Nil
      unless @channels.empty?
        args = Array(RESP::Arg).new(@channels.size + 1)
        args << "SUBSCRIBE"
        @channels.each { |c| args << c }
        @pending.push(Ack.new(@channels.size, nil))
        conn.send(args)
      end
      unless @patterns.empty?
        args = Array(RESP::Arg).new(@patterns.size + 1)
        args << "PSUBSCRIBE"
        @patterns.each { |p| args << p }
        @pending.push(Ack.new(@patterns.size, nil))
        conn.send(args)
      end
    end
```

- [ ] **Step 4: Run the whole subscriber spec to verify it passes**

Run: `bin/crystal spec spec/std/redis/subscriber_spec.cr`
Expected: all examples at both protocols pass, including the Task 5 `reconnect: false` ones. The "keeps retrying" example takes about half a second by design. If `fake.commands_on(2)` shows the channels in a different order, `Set` iteration is insertion-ordered and the test subscribed `a` before `b`; check `resubscribe` iterates `@channels` directly.

- [ ] **Step 5: Format and commit**

```bash
bin/crystal tool format src/redis spec/std/redis spec/support/redis.cr
git add src/redis/subscriber.cr spec/std/redis/subscriber_spec.cr
git commit -m "Redis: Subscriber reconnects with backoff and resubscribes

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: `Client#subscriber` and live specs at both protocols

**Files:**
- Modify: `src/redis/client.cr` (add `subscriber` after `watch`)
- Modify: `spec/std/redis/live_spec.cr` (add a `live_slice2_specs(protocol)` function and its two calls)

**Interfaces:**
- Consumes: `Subscriber.new` (Task 5), `Client#multi`/`watch` (Task 4), `run` (Task 2), `publish` (Task 1); `with_redis(protocol)` and `pending_redis` from the live spec.
- Produces: `Client#subscriber(*, capacity : Int32 = 64, reconnect : Bool = true) : Subscriber`.

- [ ] **Step 1: Write the failing live specs**

In `spec/std/redis/live_spec.cr`, add before the line `live_command_specs(3)`:

```crystal
private def live_slice2_specs(protocol : Int32)
  describe "Redis live pub/sub, transactions, scripts (RESP#{protocol})" do
    pending_redis "publishes to a subscriber on a channel and a pattern" do
      with_redis(protocol) do |r|
        sub = r.subscriber
        begin
          sub.protocol.should eq(protocol)
          sub.subscribe("news")
          sub.psubscribe("log.*")
          r.publish("news", "hello").should eq(1_i64)
          r.publish("log.app", "line").should eq(1_i64)
          sub.receive.should eq(Redis::Subscriber::Message.new("news", "hello"))
          sub.receive.should eq(Redis::Subscriber::Message.new("log.app", "line", "log.*"))
          sub.ping
          sub.unsubscribe("news")
          r.publish("news", "nobody").should eq(0_i64)
          sub.punsubscribe
          r.publish("log.app", "nobody").should eq(0_i64)
        ensure
          sub.close
        end
      end
    end

    pending_redis "multi runs atomically and resolves typed futures" do
      with_redis(protocol) do |r|
        r.set("hits", "41")
        hits = nil
        got = nil
        replies = r.multi do |tx|
          tx.set("a", "1")
          hits = tx.incr("hits")
          got = tx.get("a")
          tx.lpush("l", "x")
        end
        replies.should eq(["OK", 42_i64, "1", 1_i64] of Redis::Value)
        hits.not_nil!.value.should eq(42_i64)
        got.not_nil!.value.should eq("1")
        f = nil
        r.multi { |tx| tx.set("l", "y"); f = tx.incr("l") }
        expect_raises(Redis::CommandError, /WRONGTYPE|ERR/) { f.not_nil!.value }
        r.get("l").should eq("y")
      end
    end

    pending_redis "watch aborts when another client changes the key, and a retry converges" do
      with_redis(protocol) do |r|
        r.set("balance", "100")
        expect_raises(Redis::AbortedError) do
          r.watch("balance") do |conn|
            balance = conn.get("balance").not_nil!.to_i
            r.set("balance", "50")
            conn.multi { |tx| tx.set("balance", (balance - 10).to_s) }
          end
        end
        r.get("balance").should eq("50")

        attempts = 0
        loop do
          begin
            r.watch("balance") do |conn|
              attempts += 1
              balance = conn.get("balance").not_nil!.to_i
              r.set("balance", "70") if attempts == 1
              conn.multi { |tx| tx.set("balance", (balance - 10).to_s) }
            end
            break
          rescue Redis::AbortedError
          end
        end
        attempts.should eq(2)
        r.get("balance").should eq("60")
      end
    end

    pending_redis "run caches scripts and heals after SCRIPT FLUSH" do
      with_redis(protocol) do |r|
        script = Redis::Script.new("return redis.call('INCRBY', KEYS[1], ARGV[1])")
        r.script_flush
        r.script_load(script.source).should eq(script.sha)
        r.script_flush
        r.run(script, keys: ["n"], args: [5]).should eq(5_i64)
        r.run(script, keys: ["n"], args: [5]).should eq(10_i64)
        r.script_exists(script.sha).should eq([true])
        f = nil
        r.pipelined { |p| f = p.run(script, keys: ["n"], args: [1]) }
        f.not_nil!.value.should eq(11_i64)
        r.script_flush
        r.pipelined { |p| f = p.run(script, keys: ["n"], args: [1]) }
        ex = expect_raises(Redis::CommandError) { f.not_nil!.value }
        ex.code.should eq("NOSCRIPT")
        r.pipelined { |p| f = p.run(script, keys: ["n"], args: [1]) }
        f.not_nil!.value.should eq(12_i64)
        r.run(script, keys: ["n"], args: [1]).should eq(13_i64)
      end
    end
  end
end
```

and after `live_command_specs(2)` add:

```crystal
live_slice2_specs(3)
live_slice2_specs(2)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/crystal spec spec/std/redis/live_spec.cr`
Expected: compile error `undefined method 'subscriber' for Redis::Client`.

- [ ] **Step 3: Add `Client#subscriber`**

In `src/redis/client.cr`, after `def watch`:

```crystal
    # Opens a `Subscriber` on its own connection with this client's URL,
    # credentials, client name, protocol, timeouts and TLS context. The
    # client's database is not applied: pub/sub is database-independent.
    # The subscriber is independent of the client afterwards and must be
    # closed on its own.
    def subscriber(*, capacity : Int32 = 64, reconnect : Bool = true) : Subscriber
      Subscriber.new(@url, username: @username, password: @password, client_name: @client_name,
        protocol: @protocol_option, connect_timeout: @connect_timeout, read_timeout: @read_timeout,
        tls_context: @tls_context, max_bulk_size: @max_bulk_size, capacity: capacity, reconnect: reconnect)
    end
```

- [ ] **Step 4: Run the live specs against a server**

Start a server if none is running: `valkey-server --daemonize yes --save "" --appendonly no` (or `redis-server`). Then:

Run: `bin/crystal spec spec/std/redis/live_spec.cr`
Expected: every example passes (none pending). Without a server the new examples show as pending, which is also correct but does not verify anything; the live run is required for this task.

If `sub.protocol.should eq(2)` fails at RESP2, `Client#subscriber` is not forwarding `@protocol_option`.

- [ ] **Step 5: Format and commit**

```bash
bin/crystal tool format src/redis spec/std/redis spec/support/redis.cr
git add src/redis/client.cr spec/std/redis/live_spec.cr
git commit -m "Redis: Client#subscriber and live specs for pub/sub, multi, watch and run

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: Module docs, formatting, full standard-library suite

**Files:**
- Modify: `src/redis.cr` (module doc comment)
- Verify: everything under `src/redis`, `spec/std/redis`, `spec/support/redis.cr`

- [ ] **Step 1: Update the module doc**

In `src/redis.cr`, replace the line

```crystal
# Not in this slice: pub/sub, MULTI/EXEC, script caching, cluster routing.
```

with

```crystal
# Pub/sub: `Redis::Subscriber` (or `Client#subscriber`) receives on its
# own connection and reconnects by itself; `Client#publish` sends.
# Transactions: `Client#multi { |tx| ... }` runs a `MULTI`..`EXEC` block
# atomically with typed futures; `Client#watch(*keys) { |conn| ... }`
# gives optimistic locking on a dedicated connection. Scripts:
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
# Not in this slice: cluster routing, connection pools, sharded pub/sub.
```

- [ ] **Step 2: Format check and the Redis suite**

Run: `bin/crystal tool format --check src/redis spec/std/redis spec/support/redis.cr`
Expected: no output, exit 0.

Run: `bin/crystal spec spec/std/redis/`
Expected: all examples pass (live ones pass with a server running, pending without).

- [ ] **Step 3: Doc build and the full suite**

Run: `bin/crystal docs src/redis.cr -o .build/redis-docs 2>&1 | tail -5`
Expected: no warnings about the new files (ignore pre-existing ones).

Run: `make std_spec 2>&1 | tail -5`
Expected: only the 14 known environment failures from slice 1 (none under `spec/std/redis/`). This takes several minutes and needs the machine to itself.

- [ ] **Step 4: Commit**

```bash
git add src/redis.cr
git commit -m "Redis: slice 2 module docs

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: Benchmarks vs redis-rs and go-redis

**Files:**
- Create (gitignored): `.remember/harness-2026-09-19/redis/bench_slice2.cr`, additions to `rs/src/main.rs` and `go/main.go`, a "Slice 2" section in `README.md`

- [ ] **Step 1: Crystal benchmark**

```crystal
# .remember/harness-2026-09-19/redis/bench_slice2.cr
require "redis"

url = ARGV[0]? || "redis://127.0.0.1:6379"
redis = Redis::Client.new(url, db: 14)
redis.flushdb

def report(name, ops, t)
  puts "#{name.ljust(30)} #{(ops / t.total_seconds).round(0).to_i.to_s.rjust(9)} ops/s  #{(t.total_nanoseconds / ops / 1000).round(2)} µs/op"
end

# 1. publish → receive latency, one channel, sequential round trips.
sub = redis.subscriber
sub.subscribe("bench")
n = 10_000
latencies = Array(Float64).new(n)
n.times do |i|
  t0 = Time.monotonic
  redis.publish("bench", i.to_s)
  sub.receive
  latencies << (Time.monotonic - t0).total_nanoseconds / 1000
end
latencies.sort!
puts "pubsub round trip: median #{latencies[n // 2].round(1)} µs, p99 #{latencies[n * 99 // 100].round(1)} µs"

# 2. subscriber throughput: 64 channels, 1M pipelined publishes.
64.times { |i| sub.subscribe("c#{i}") }
total = 1_000_000
done = Channel(Nil).new
spawn do
  total.times { sub.receive }
  done.send(nil)
end
t = Time.measure do
  (total // 10_000).times do
    redis.pipelined { |p| 10_000.times { |j| p.publish("c#{j % 64}", "m") } }
  end
  done.receive
end
report "subscriber throughput", total, t
sub.close

# 3. multi with 10 INCR vs the same 10 in a plain pipeline.
iters = 10_000
t = Time.measure { iters.times { redis.pipelined { |p| 10.times { p.incr("pl") } } } }
report "pipeline 10 INCR", iters, t
t = Time.measure { iters.times { redis.multi { |tx| 10.times { tx.incr("tx") } } } }
report "multi 10 INCR", iters, t

# 4. run(script) vs evalsha by hand.
script = Redis::Script.new("return redis.call('INCR', KEYS[1])")
redis.run(script, keys: ["s"])
n = 100_000
t = Time.measure { n.times { redis.evalsha(script.sha, keys: ["s"]) } }
report "evalsha by hand", n, t
t = Time.measure { n.times { redis.run(script, keys: ["s"]) } }
report "run(script)", n, t
redis.close
```

Run: `bin/crystal build --release .remember/harness-2026-09-19/redis/bench_slice2.cr -o .build/bench_slice2 && .build/bench_slice2`

- [ ] **Step 2: Rust and Go equivalents**

Add to `rs/src/main.rs` (behind a `slice2` CLI argument so the slice 1 cases still run alone): a `PubSub` connection from `client.get_async_pubsub().await?` subscribed to `bench`, the 10k publish/receive round trip with median and p99; the 64-channel receive of 1M messages published through a `redis::pipe()` in 10k batches; `redis::pipe().atomic()` with 10 `incr` for 10k iterations against a plain `redis::pipe()`; and `redis::Script::new(...).key("s").invoke_async(&mut con)` for 100k calls against `redis::cmd("EVALSHA")`. Same output format.

Add to `go/main.go` (behind a `slice2` argument): `client.Subscribe(ctx, "bench")` with `ReceiveMessage`; the 64-channel throughput via `client.Pipeline()` publishes; `client.TxPipelined` with 10 `Incr` against `client.Pipelined`; `redis.NewScript(...).Run(ctx, client, []string{"s"})` against `client.EvalSha`. Same output format.

Run each twice and keep the second, against the same local server.

- [ ] **Step 3: Record**

Add a "Slice 2 — 2026-09-20" section to the harness `README.md` with the table (Crystal / Rust / Go per case), the two targets from the spec (`multi` overhead within a few percent of the plain pipeline; `run` no slower than a direct `EVALSHA`), and any variant tried and rejected. If `multi` is more than a few percent slower than the pipeline in the client (not the server), the suspects are the two extra futures per transaction and `tx.buffer.to_slice` being copied twice; measure before changing anything and record findings.

Then update memory (`stdlib-batteries-direction.md`) with the shipped state, the numbers, and lessons.

No commit for this task (harness is gitignored) beyond the memory note.
