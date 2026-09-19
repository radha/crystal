# Redis Client (Tier 3b, slice 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A pure-Crystal `require "redis"` client: RESP3 codec with RESP2 fallback, a synchronous `Connection`, a multiplexed auto-pipelining `Client`, a `pipelined` block with typed futures, and ~85 typed commands.

**Architecture:** `Redis::RESP` is a pure codec over any `IO`. `Redis::Connection` owns one socket and does the HELLO handshake. `Redis::Client` drives a `Connection` with a writer fiber (double-buffered outbound bytes, one flush per wakeup) and a reader fiber (replies delivered in order to a `Deque` of pooled waiters). `Redis::Commands` is one module of typed methods mixed into `Connection`, `Client` and `Pipeline`; each includer supplies `typed_call(args, &block : Value -> T)` so the same method bodies return `T` on connections and `Future(T)` on pipelines.

**Tech Stack:** Crystal stdlib only (`socket`, `openssl`, `uri`, `Channel`, `Mutex`, `Deque`, `IO::Memory`). Compiler via `bin/crystal`. Live specs need a local Redis/Valkey (`redis-server` from Homebrew).

**Spec:** `docs/superpowers/specs/2026-09-19-redis-client-design.md`

## Global Constraints

- Everything lives under `src/redis/` with entry `src/redis.cr`; never required from the prelude; never `require "big"`.
- Values are the bare union `Redis::Value`; bulk strings are `String`.
- Parser guards: `MAX_BULK_SIZE = 512 * 1024 * 1024`, `MAX_DEPTH = 512`, element counts checked before presizing.
- No automatic command retry. Connect and reconnect are lazy on the next call. `read_timeout` on `Client` is a per-command deadline enforced by the caller, and on expiry the whole connection is torn down.
- Every public method gets a third-person doc comment. `bin/crystal tool format src/redis spec/std/redis spec/support/redis.cr` before every commit.
- Always `bin/crystal`, never a global `crystal`. Run one compiler at a time (8 GB machine). Foreground `sleep` in Bash is blocked; live specs are `pending` when no server answers.
- Commit messages are prefixed `Redis: ` and end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- `docs/` is gitignored: `git add -f` for files under it.

## File map

| File | Responsibility |
|------|----------------|
| `src/redis.cr` | module doc + requires |
| `src/redis/value.cr` | `Value` alias, `BigNumber` |
| `src/redis/error.cr` | `Error`, `ConnectionError`, `ProtocolError`, `CommandError` |
| `src/redis/resp.cr` | `RESP.write_command`, `RESP.read`, `RESP::Parser` |
| `src/redis/commands.cr` | `Commands` module, `def_command` macro, `Cast` helpers, `command` escape hatch |
| `src/redis/commands/{server,keys,strings,hashes,lists,sets,sorted_sets,scripting}.cr` | typed commands per family |
| `src/redis/connection.cr` | URL parsing, sockets, HELLO/AUTH/SELECT, `send`/`read`/`call`/`pipeline` |
| `src/redis/client.cr` | multiplexer, waiters, fibers, reconnect, `pipelined` |
| `src/redis/pipeline.cr` | `Pipeline`, `AbstractFuture`, `Future(T)` |
| `spec/support/redis.cr` | `pending_redis`, `RedisSpec::FakeServer`, `RedisSpec.hello_reply` |
| `spec/std/redis/{resp,commands,connection,client,pipeline}_spec.cr` | codec, cast, fake-server, and multiplexer specs |
| `spec/std/redis/live_spec.cr` | live-server specs, run for RESP3 and RESP2 |

---

### Task 1: Scaffold, values, errors

**Files:**
- Create: `src/redis.cr`, `src/redis/value.cr`, `src/redis/error.cr`
- Test: `spec/std/redis/value_spec.cr`

**Interfaces:**
- Produces: `Redis::Value` alias; `Redis::BigNumber#digits : String`; `Redis::Error < Exception`; `Redis::ConnectionError`, `Redis::ProtocolError`; `Redis::CommandError#code : String` (first word if it is all `A-Z0-9_`, else `""`).

- [ ] **Step 1: Write the failing spec**

```crystal
# spec/std/redis/value_spec.cr
require "spec"
require "redis"

describe Redis::BigNumber do
  it "compares and hashes by digits" do
    a = Redis::BigNumber.new("-3492890328409238509324850943850943825024385")
    b = Redis::BigNumber.new("-3492890328409238509324850943850943825024385")
    a.should eq(b)
    a.hash.should eq(b.hash)
    a.to_s.should eq("-3492890328409238509324850943850943825024385")
  end
end

describe Redis::CommandError do
  it "extracts the upper-case code" do
    Redis::CommandError.new("WRONGTYPE Operation against a key holding the wrong kind of value").code.should eq("WRONGTYPE")
    Redis::CommandError.new("ERR unknown command 'HELLO'").code.should eq("ERR")
    Redis::CommandError.new("NOPROTO").code.should eq("NOPROTO")
    Redis::CommandError.new("MOVED 3999 127.0.0.1:6381").code.should eq("MOVED")
    Redis::CommandError.new("lower case message").code.should eq("")
  end

  it "is a Redis::Error and a Redis::Value" do
    err = Redis::CommandError.new("ERR x")
    err.should be_a(Redis::Error)
    (err.as(Redis::Value)).should be(err)
  end
end

describe Redis::Value do
  it "admits every RESP3 shape" do
    v = [nil, true, 1_i64, 1.5, "s", Redis::BigNumber.new("1"), Set(Redis::Value){1_i64},
         {"k" => "v"} of Redis::Value => Redis::Value] of Redis::Value
    v.size.should eq(8)
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/crystal spec spec/std/redis/value_spec.cr`
Expected: error `can't find file 'redis'`.

- [ ] **Step 3: Write the files**

```crystal
# src/redis.cr
# Pure-Crystal Redis client. See `Redis::Client`.
require "socket"
require "openssl"
require "uri"
require "./redis/error"
require "./redis/value"
require "./redis/resp"
require "./redis/commands"
require "./redis/connection"
require "./redis/pipeline"
require "./redis/client"

module Redis
end
```

(`resp`, `commands`, `connection`, `pipeline`, `client` do not exist yet; for this task create each of them as an empty file containing only `module Redis\nend\n` so the require chain compiles. Later tasks replace them.)

```crystal
# src/redis/value.cr
module Redis
  # A reply value. RESP3 maps become `Hash`, sets become `Set`, arrays and
  # pushes become `Array`, bulk and simple strings become `String`, error
  # replies nested inside aggregates stay as `CommandError` values.
  alias Value = Nil | Bool | Int64 | Float64 | String | BigNumber | CommandError |
                Array(Value) | Set(Value) | Hash(Value, Value)

  # A RESP3 big number (`(` frame), kept as its decimal text so that
  # `require "redis"` does not depend on GMP. Convert with
  # `BigInt.new(big_number.digits)` after `require "big"`.
  struct BigNumber
    # The decimal text exactly as sent by the server.
    getter digits : String

    def initialize(@digits : String)
    end

    def to_s(io : IO) : Nil
      io << @digits
    end

    def_equals_and_hash @digits
  end
end
```

```crystal
# src/redis/error.cr
module Redis
  # Base class of every error raised by this client.
  class Error < Exception
  end

  # Raised when a connection cannot be established, is lost, or is used
  # after `close`. In-flight commands on a multiplexed `Client` receive this
  # error when the connection drops.
  class ConnectionError < Error
  end

  # Raised on a malformed frame, an exceeded size or depth guard, an
  # unsolicited reply, or a typed command receiving an unexpected reply shape.
  class ProtocolError < Error
  end

  # An error reply (`-` or `!` frame) from the server. Raised by `call`
  # at the top level; stored as a value when nested inside an aggregate
  # reply (for example inside pipeline results).
  class CommandError < Error
    # The leading upper-case word of the message (`ERR`, `WRONGTYPE`,
    # `NOAUTH`, `NOPROTO`, `MOVED`, ...) or `""` when the message has none.
    getter code : String

    def initialize(message : String, cause : Exception? = nil)
      super(message, cause)
      @code = CommandError.parse_code(message)
    end

    # :nodoc:
    def self.parse_code(message : String) : String
      space = message.index(' ') || message.bytesize
      word = message.byte_slice(0, space)
      return "" if word.empty?
      word.each_byte do |b|
        next if 'A'.ord <= b <= 'Z'.ord || '0'.ord <= b <= '9'.ord || b == '_'.ord
        return ""
      end
      word
    end
  end
end
```

- [ ] **Step 4: Run the spec to verify it passes**

Run: `bin/crystal spec spec/std/redis/value_spec.cr`
Expected: `4 examples, 0 failures`.

- [ ] **Step 5: Format and commit**

```bash
bin/crystal tool format src/redis.cr src/redis spec/std/redis
git add src/redis.cr src/redis spec/std/redis
git commit -m "Redis: scaffold, Value alias, BigNumber, error hierarchy

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: RESP encoder

**Files:**
- Modify: `src/redis/resp.cr` (replace the stub)
- Test: `spec/std/redis/resp_spec.cr`

**Interfaces:**
- Produces: `Redis::RESP::Arg = String | Bytes | Int | Float | Symbol`; `Redis::RESP.write_command(io : IO, args : Enumerable) : Nil`; `Redis::RESP.write_command(io : IO, *args : Arg) : Nil`. Never flushes.

- [ ] **Step 1: Write the failing spec**

```crystal
# spec/std/redis/resp_spec.cr
require "spec"
require "redis"

private def encode(*args)
  io = IO::Memory.new
  Redis::RESP.write_command(io, *args)
  io.to_s
end

describe Redis::RESP do
  describe ".write_command" do
    it "encodes strings as a bulk array" do
      encode("SET", "key", "value").should eq("*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nvalue\r\n")
    end

    it "uses bytesize for multibyte strings" do
      encode("ECHO", "héllo").should eq("*2\r\n$4\r\nECHO\r\n$6\r\nhéllo\r\n")
    end

    it "encodes ints, floats, symbols and bytes" do
      encode("SET", :k, 42, -7_i64, 1.5, Bytes[0, 255]).should eq(
        "*6\r\n$3\r\nSET\r\n$1\r\nk\r\n$2\r\n42\r\n$2\r\n-7\r\n$3\r\n1.5\r\n$2\r\n\u0000ÿ\r\n")
    end

    it "accepts an Enumerable of args" do
      io = IO::Memory.new
      Redis::RESP.write_command(io, ["PING"])
      io.to_s.should eq("*1\r\n$4\r\nPING\r\n")
    end

    it "encodes an empty string" do
      encode("SET", "k", "").should eq("*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$0\r\n\r\n")
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/crystal spec spec/std/redis/resp_spec.cr`
Expected: `undefined method 'write_command'`.

- [ ] **Step 3: Write the encoder**

```crystal
# src/redis/resp.cr
module Redis
  # RESP2/RESP3 codec over any `IO`. `write_command` encodes a command as a
  # bulk-string array (the form every Redis version accepts); `read` parses
  # one reply into a `Value`.
  module RESP
    # Types accepted as command arguments. Everything but `Bytes` is written
    # with its `to_s` form.
    alias Arg = String | Bytes | Int | Float | Symbol

    # Redis' own `proto-max-bulk-len` default.
    MAX_BULK_SIZE = 512 * 1024 * 1024
    # Maximum aggregate nesting accepted by `read`.
    MAX_DEPTH = 512

    # Writes *args* as a RESP command into *io* without flushing.
    def self.write_command(io : IO, *args : Arg) : Nil
      write_command(io, args)
    end

    # :ditto:
    def self.write_command(io : IO, args : Enumerable) : Nil
      io << '*' << args.size << "\r\n"
      args.each { |arg| write_bulk(io, arg) }
    end

    private def self.write_bulk(io : IO, arg : String) : Nil
      io << '$' << arg.bytesize << "\r\n" << arg << "\r\n"
    end

    private def self.write_bulk(io : IO, arg : Bytes) : Nil
      io << '$' << arg.size << "\r\n"
      io.write(arg)
      io << "\r\n"
    end

    private def self.write_bulk(io : IO, arg : Symbol) : Nil
      write_bulk(io, arg.to_s)
    end

    private def self.write_bulk(io : IO, arg : Int) : Nil
      io << '$' << decimal_length(arg) << "\r\n" << arg << "\r\n"
    end

    private def self.write_bulk(io : IO, arg : Float) : Nil
      write_bulk(io, arg.to_s)
    end

    # Number of characters `Int#to_s` produces, without allocating.
    private def self.decimal_length(value : Int) : Int32
      length = value < 0 ? 1 : 0
      magnitude = value.abs.to_u64!
      loop do
        length += 1
        magnitude //= 10
        break if magnitude == 0
      end
      length
    end
  end
end
```

`value.abs.to_u64!` is wrong for `Int64::MIN` (abs overflows). Handle it: replace `magnitude = value.abs.to_u64!` with

```crystal
      magnitude = value < 0 ? (0_u64 &- value.to_i64!.to_u64!) : value.to_u64!
```

which yields the correct two's-complement magnitude for every Int64 including MIN. Add a spec line: `encode("X", Int64::MIN).should eq("*2\r\n$1\r\nX\r\n$20\r\n-9223372036854775808\r\n")`.

- [ ] **Step 4: Run the spec to verify it passes**

Run: `bin/crystal spec spec/std/redis/resp_spec.cr`
Expected: all encoder examples pass.

- [ ] **Step 5: Format and commit**

```bash
bin/crystal tool format src/redis spec/std/redis
git add src/redis/resp.cr spec/std/redis/resp_spec.cr
git commit -m "Redis: RESP command encoder

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: RESP parser, scalar frames

**Files:**
- Modify: `src/redis/resp.cr`
- Test: `spec/std/redis/resp_spec.cr`

**Interfaces:**
- Produces: `Redis::RESP.read(io : IO, *, max_bulk_size : Int32 = MAX_BULK_SIZE, max_depth : Int32 = MAX_DEPTH, push : (Array(Value) ->)? = nil) : Value` and `Redis::RESP::Parser` (used again in Task 4). EOF at a frame boundary raises `IO::EOFError`; EOF or garbage inside a frame raises `Redis::ProtocolError`.

- [ ] **Step 1: Write the failing spec (append to `resp_spec.cr`)**

```crystal
private def parse(bytes : String, **opts)
  Redis::RESP.read(IO::Memory.new(bytes), **opts)
end

describe Redis::RESP do
  describe ".read scalars" do
    it "simple string" { parse("+OK\r\n").should eq("OK") }
    it "empty simple string" { parse("+\r\n").should eq("") }
    it "integer" { parse(":1000\r\n").should eq(1000_i64) }
    it "negative integer" { parse(":-1\r\n").should eq(-1_i64) }
    it "integer with explicit plus" { parse(":+5\r\n").should eq(5_i64) }
    it "bulk string" { parse("$5\r\nhello\r\n").should eq("hello") }
    it "empty bulk string" { parse("$0\r\n\r\n").should eq("") }
    it "binary bulk string" { parse("$3\r\na\r\nb\r\n").should eq("a\r\nb") }
    it "null bulk (RESP2)" { parse("$-1\r\n").should be_nil }
    it "null array (RESP2)" { parse("*-1\r\n").should be_nil }
    it "null (RESP3)" { parse("_\r\n").should be_nil }
    it "booleans" do
      parse("#t\r\n").should eq(true)
      parse("#f\r\n").should eq(false)
    end
    it "doubles" do
      parse(",1.23\r\n").should eq(1.23)
      parse(",10\r\n").should eq(10.0)
      parse(",inf\r\n").should eq(Float64::INFINITY)
      parse(",-inf\r\n").should eq(-Float64::INFINITY)
      parse(",nan\r\n").as(Float64).nan?.should be_true
    end
    it "big number" do
      parse("(3492890328409238509324850943850943825024385\r\n").should eq(
        Redis::BigNumber.new("3492890328409238509324850943850943825024385"))
    end
    it "verbatim string strips the format prefix" do
      parse("=15\r\ntxt:Some string\r\n").should eq("Some string")
    end
    it "simple error becomes a CommandError value" do
      err = parse("-ERR unknown command 'FOO'\r\n").as(Redis::CommandError)
      err.code.should eq("ERR")
      err.message.should eq("ERR unknown command 'FOO'")
    end
    it "bulk error becomes a CommandError value" do
      err = parse("!21\r\nSYNTAX invalid syntax\r\n").as(Redis::CommandError)
      err.code.should eq("SYNTAX")
      err.message.should eq("SYNTAX invalid syntax")
    end
    it "leaves following frames unread" do
      io = IO::Memory.new("+A\r\n+B\r\n")
      Redis::RESP.read(io).should eq("A")
      Redis::RESP.read(io).should eq("B")
    end
  end

  describe ".read errors" do
    it "raises IO::EOFError at a frame boundary" do
      expect_raises(IO::EOFError) { parse("") }
    end
    it "raises ProtocolError on EOF inside a frame" do
      expect_raises(Redis::ProtocolError) { parse("+OK") }
      expect_raises(Redis::ProtocolError) { parse("$5\r\nhel") }
      expect_raises(Redis::ProtocolError) { parse(":12") }
    end
    it "raises ProtocolError on a bad terminator" do
      expect_raises(Redis::ProtocolError) { parse("$2\r\nab\n\n") }
      expect_raises(Redis::ProtocolError) { parse(":1\n\r") }
    end
    it "raises ProtocolError on an unknown type byte" do
      expect_raises(Redis::ProtocolError, /unknown RESP type/) { parse("?x\r\n") }
    end
    it "raises ProtocolError on non-numeric length or integer" do
      expect_raises(Redis::ProtocolError) { parse(":abc\r\n") }
      expect_raises(Redis::ProtocolError) { parse("$x\r\n") }
      expect_raises(Redis::ProtocolError) { parse("$-2\r\n") }
    end
    it "raises ProtocolError on an oversized bulk before allocating" do
      expect_raises(Redis::ProtocolError, /exceeds/) { parse("$100\r\nabc", max_bulk_size: 10) }
    end
    it "raises ProtocolError on a bad double or boolean" do
      expect_raises(Redis::ProtocolError) { parse(",abc\r\n") }
      expect_raises(Redis::ProtocolError) { parse("#x\r\n") }
    end
    it "raises ProtocolError on integer overflow" do
      expect_raises(Redis::ProtocolError) { parse(":99999999999999999999\r\n") }
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/crystal spec spec/std/redis/resp_spec.cr`
Expected: `undefined method 'read' for Redis::RESP:Module`.

- [ ] **Step 3: Write the scalar parser (append inside `module RESP`)**

```crystal
    # Reads one reply from *io*. Push frames (`>`) are handed to *push* (or
    # dropped) and reading continues with the next frame, so the return
    # value is always a non-push reply. Attribute frames (`|`) are parsed
    # and discarded. An error reply is returned as a `CommandError` value,
    # not raised.
    #
    # Raises `IO::EOFError` if *io* is at EOF before the first byte of a
    # frame, `ProtocolError` on malformed input, on EOF inside a frame, on
    # a bulk string or aggregate count above *max_bulk_size*, or on nesting
    # deeper than *max_depth*.
    def self.read(io : IO, *, max_bulk_size : Int32 = MAX_BULK_SIZE, max_depth : Int32 = MAX_DEPTH,
                  push : (Array(Value) ->)? = nil) : Value
      Parser.new(io, max_bulk_size, max_depth, push).read_reply
    end

    # :nodoc:
    struct Parser
      def initialize(@io : IO, @max_bulk_size : Int32, @max_depth : Int32, @push : (Array(Value) ->)?)
      end

      def read_reply : Value
        loop do
          type = @io.read_byte || raise IO::EOFError.new
          begin
            if type === '>'
              array = read_array_body(0) || raise ProtocolError.new("null push frame")
              @push.try &.call(array)
              next
            end
            return read_value(type, 0)
          rescue ex : IO::EOFError
            raise ProtocolError.new("unexpected EOF inside a RESP frame", cause: ex)
          end
        end
      end

      private def read_value(depth : Int32) : Value
        read_value(next_byte, depth)
      end

      private def read_value(type : UInt8, depth : Int32) : Value
        case type.unsafe_chr
        when '+' then read_line
        when '-' then CommandError.new(read_line)
        when ':' then read_int
        when '$' then read_bulk
        when '_' then expect_crlf; nil
        when '#' then read_bool
        when ',' then read_double
        when '(' then BigNumber.new(read_line)
        when '!' then CommandError.new(read_bulk || raise ProtocolError.new("null bulk error"))
        when '=' then read_verbatim
        when '*' then read_array_body(depth)
        when '%' then read_map_body(depth)
        when '~' then read_set_body(depth)
        when '|' then read_map_body(depth); read_value(depth)
        when '>' then raise ProtocolError.new("push frame inside an aggregate")
        else          raise ProtocolError.new("unknown RESP type byte #{type.unsafe_chr.inspect}")
        end
      end

      private def next_byte : UInt8
        @io.read_byte || raise IO::EOFError.new
      end

      private def expect_crlf : Nil
        raise ProtocolError.new("expected CRLF") unless next_byte === '\r' && next_byte === '\n'
      end

      private def read_line : String
        line = @io.gets('\r', chomp: true) || raise IO::EOFError.new
        raise ProtocolError.new("expected LF after CR") unless next_byte === '\n'
        line
      end

      private def read_int : Int64
        byte = next_byte
        negative = false
        case byte.unsafe_chr
        when '-' then negative = true; byte = next_byte
        when '+' then byte = next_byte
        end
        raise ProtocolError.new("expected a digit") unless '0'.ord <= byte <= '9'.ord
        value = 0_i64
        loop do
          value = value * 10 + (byte - '0'.ord)
          byte = next_byte
          break if byte === '\r'
          raise ProtocolError.new("expected a digit") unless '0'.ord <= byte <= '9'.ord
        end
        raise ProtocolError.new("expected LF after CR") unless next_byte === '\n'
        negative ? -value : value
      rescue ex : OverflowError
        raise ProtocolError.new("integer out of range", cause: ex)
      end

      private def read_length : Int32
        length = read_int
        return -1 if length == -1
        raise ProtocolError.new("negative length #{length}") if length < 0
        raise ProtocolError.new("length #{length} exceeds max_bulk_size #{@max_bulk_size}") if length > @max_bulk_size
        length.to_i32
      end

      private def read_bulk : String?
        length = read_length
        return nil if length < 0
        read_bulk_body(length)
      end

      private def read_bulk_body(length : Int32) : String
        io = @io
        string = String.new(length) do |buffer|
          io.read_fully(Slice.new(buffer, length))
          {length, 0}
        end
        expect_crlf
        string
      end

      private def read_verbatim : String
        length = read_length
        raise ProtocolError.new("null verbatim string") if length < 0
        body = read_bulk_body(length)
        if body.bytesize >= 4 && body.byte_at(3) === ':'
          body.byte_slice(4)
        else
          raise ProtocolError.new("verbatim string without format prefix")
        end
      end

      private def read_bool : Bool
        value = case next_byte.unsafe_chr
                when 't' then true
                when 'f' then false
                else          raise ProtocolError.new("expected 't' or 'f'")
                end
        expect_crlf
        value
      end

      private def read_double : Float64
        line = read_line
        case line
        when "inf"  then Float64::INFINITY
        when "-inf" then -Float64::INFINITY
        when "nan"  then Float64::NAN
        else             line.to_f64? || raise ProtocolError.new("invalid double #{line.inspect}")
        end
      end

      # Aggregates are implemented in Task 4; keep these stubs so Task 3 compiles.
      private def read_array_body(depth : Int32) : Array(Value)?
        raise ProtocolError.new("aggregates not implemented")
      end

      private def read_map_body(depth : Int32) : Hash(Value, Value)
        raise ProtocolError.new("aggregates not implemented")
      end

      private def read_set_body(depth : Int32) : Set(Value)
        raise ProtocolError.new("aggregates not implemented")
      end
    end
```

Notes for the implementer: `byte === '\r'` compares a `UInt8` with a `Char` via `Char#===(Int)`; it is the idiom used across the stdlib lexers. `String.new(capacity) { {bytesize, 0} }` with size 0 lets the String compute its character count lazily. `"*-1\r\n"` returns nil through `read_array_body` in Task 4; in this task that example stays failing until Task 4 (note it in the commit message, or temporarily make the stub return `nil` when `read_length` is -1: do the latter, it is two lines).

- [ ] **Step 4: Run the spec to verify it passes**

Run: `bin/crystal spec spec/std/redis/resp_spec.cr`
Expected: all scalar and error examples pass.

- [ ] **Step 5: Format and commit**

```bash
bin/crystal tool format src/redis spec/std/redis
git add src/redis/resp.cr spec/std/redis/resp_spec.cr
git commit -m "Redis: RESP parser for scalar frames

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: RESP parser, aggregates, push and attribute frames, guards

**Files:**
- Modify: `src/redis/resp.cr` (replace the three stubs)
- Test: `spec/std/redis/resp_spec.cr`

**Interfaces:**
- Consumes: `Parser#read_length`, `#read_value(depth)` from Task 3.
- Produces: arrays, maps, sets, push routing via the `push` argument, attribute discard, `max_depth` and count guards.

- [ ] **Step 1: Write the failing spec (append to `resp_spec.cr`)**

```crystal
describe Redis::RESP do
  describe ".read aggregates" do
    it "array" { parse("*2\r\n$3\r\nfoo\r\n:42\r\n").should eq(["foo", 42_i64] of Redis::Value) }
    it "empty array" { parse("*0\r\n").should eq([] of Redis::Value) }
    it "nested array with nulls" do
      parse("*3\r\n*1\r\n+a\r\n$-1\r\n_\r\n").should eq([["a"] of Redis::Value, nil, nil] of Redis::Value)
    end
    it "map" do
      parse("%2\r\n+first\r\n:1\r\n+second\r\n:2\r\n").should eq(
        {"first" => 1_i64, "second" => 2_i64} of Redis::Value => Redis::Value)
    end
    it "set" do
      parse("~3\r\n+a\r\n:1\r\n#t\r\n").should eq(Set(Redis::Value){"a", 1_i64, true})
    end
    it "nested errors stay values" do
      arr = parse("*2\r\n+OK\r\n-ERR bad\r\n").as(Array)
      arr[1].as(Redis::CommandError).code.should eq("ERR")
    end
    it "discards attributes and returns the following value" do
      parse("|1\r\n+ttl\r\n:3600\r\n:2039123\r\n").should eq(2039123_i64)
    end
    it "routes push frames to the handler and keeps reading" do
      pushes = [] of Array(Redis::Value)
      io = IO::Memory.new(">2\r\n+message\r\n+hi\r\n+PONG\r\n")
      Redis::RESP.read(io, push: ->(p : Array(Redis::Value)) { pushes << p }).should eq("PONG")
      pushes.should eq([["message", "hi"] of Redis::Value])
    end
    it "drops push frames without a handler" do
      parse(">1\r\n+x\r\n+PONG\r\n").should eq("PONG")
    end
    it "rejects a push frame inside an aggregate" do
      expect_raises(Redis::ProtocolError, /push frame inside/) { parse("*1\r\n>1\r\n+x\r\n") }
    end
    it "rejects an oversized element count before presizing" do
      expect_raises(Redis::ProtocolError, /exceeds/) { parse("*2147483647\r\n", max_bulk_size: 1000) }
      expect_raises(Redis::ProtocolError, /exceeds/) { parse("%2147483647\r\n", max_bulk_size: 1000) }
      expect_raises(Redis::ProtocolError, /exceeds/) { parse("~2147483647\r\n", max_bulk_size: 1000) }
    end
    it "rejects nesting deeper than max_depth" do
      deep = "*1\r\n" * 5 + "+x\r\n"
      parse(deep, max_depth: 5).should eq([[[[["x"] of Redis::Value] of Redis::Value] of Redis::Value] of Redis::Value] of Redis::Value)
      expect_raises(Redis::ProtocolError, /depth/) { parse(deep, max_depth: 4) }
    end
    it "raises ProtocolError on EOF inside an aggregate" do
      expect_raises(Redis::ProtocolError) { parse("*2\r\n+a\r\n") }
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/crystal spec spec/std/redis/resp_spec.cr`
Expected: aggregate examples fail with `aggregates not implemented`.

- [ ] **Step 3: Replace the stubs**

```crystal
      private def read_array_body(depth : Int32) : Array(Value)?
        count = read_length
        return nil if count < 0
        depth = enter(depth)
        Array(Value).new(count) { read_value(depth) }
      end

      private def read_map_body(depth : Int32) : Hash(Value, Value)
        count = read_length
        raise ProtocolError.new("null map") if count < 0
        depth = enter(depth)
        hash = Hash(Value, Value).new(initial_capacity: count)
        count.times do
          key = read_value(depth)
          hash[key] = read_value(depth)
        end
        hash
      end

      private def read_set_body(depth : Int32) : Set(Value)
        count = read_length
        raise ProtocolError.new("null set") if count < 0
        depth = enter(depth)
        set = Set(Value).new(count)
        count.times { set << read_value(depth) }
        set
      end

      private def enter(depth : Int32) : Int32
        depth += 1
        raise ProtocolError.new("nesting depth #{depth} exceeds max_depth #{@max_depth}") if depth > @max_depth
        depth
      end
```

- [ ] **Step 4: Run the spec to verify it passes**

Run: `bin/crystal spec spec/std/redis/resp_spec.cr`
Expected: all examples pass, including `"*-1\r\n"` from Task 3.

- [ ] **Step 5: Format and commit**

```bash
bin/crystal tool format src/redis spec/std/redis
git add src/redis/resp.cr spec/std/redis/resp_spec.cr
git commit -m "Redis: RESP aggregates, push and attribute frames, guards

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Commands module: `typed_call` contract, `Cast`, `def_command` macro

**Files:**
- Modify: `src/redis/commands.cr` (replace the stub)
- Test: `spec/std/redis/commands_spec.cr`

**Interfaces:**
- Consumes: `Redis::Value`, `Redis::RESP::Arg`, `Redis::ProtocolError`.
- Produces:
  - `module Redis::Commands` expecting the includer to define `call(args : Enumerable)` and `typed_call(args : Enumerable, &block : Value -> T) forall T`.
  - `Redis::Commands#command(*args : RESP::Arg)` and `#command(args : Enumerable)`: escape hatch, returns whatever `call` returns.
  - `macro def_command(name, cmd, *params, cast, splat = false)`.
  - `module Redis::Commands::Cast` with class methods `string`, `string?`, `int`, `float`, `bool`, `bools`, `strings`, `strings?`, `string_hash`, `scored_pairs`, `floats?`, `ok`, `value`, each `(Value) -> T` and raising `ProtocolError` on the wrong shape.
  - Generated methods carry no explicit return type: their type is inferred from the includer's `typed_call` (`T` on connections, `Future(T)` on pipelines).

- [ ] **Step 1: Write the failing spec**

```crystal
# spec/std/redis/commands_spec.cr
require "spec"
require "redis"

# Records the args of each call and answers from a queue of canned replies.
private class Stub
  include Redis::Commands

  getter calls = [] of Array(Redis::RESP::Arg)
  property replies = [] of Redis::Value

  def call(args : Enumerable) : Redis::Value
    @calls << args.map(&.as(Redis::RESP::Arg)).to_a
    @replies.shift
  end

  def typed_call(args : Enumerable, &block : Redis::Value -> T) forall T
    block.call(call(args))
  end

  def_command echo_test, "ECHO", message : String, cast: :string
  def_command del_test, "DEL", keys : String, cast: :int, splat: true
  def_command noargs_test, "PING", cast: :string
end

private def stub(*replies : Redis::Value)
  s = Stub.new
  s.replies = replies.to_a
  s
end

describe Redis::Commands do
  describe "def_command" do
    it "builds the arg array and casts the reply" do
      s = stub("hi")
      s.echo_test("hi").should eq("hi")
      s.calls.should eq([["ECHO", "hi"]])
    end

    it "supports a trailing splat" do
      s = stub(2_i64)
      s.del_test("a", "b").should eq(2_i64)
      s.calls.should eq([["DEL", "a", "b"]])
    end

    it "supports no params" do
      stub("PONG").noargs_test.should eq("PONG")
    end

    it "raises ProtocolError on a wrong reply shape" do
      expect_raises(Redis::ProtocolError, /expected string/) { stub(1_i64).echo_test("x") }
    end
  end

  describe "command" do
    it "passes args straight to call" do
      s = stub(42_i64)
      s.command("CLIENT", "ID").should eq(42_i64)
      s.calls.should eq([["CLIENT", "ID"]])
    end
  end

  describe Redis::Commands::Cast do
    alias Cast = Redis::Commands::Cast

    it "string / string?" do
      Cast.string("a").should eq("a")
      Cast.string?(nil).should be_nil
      expect_raises(Redis::ProtocolError) { Cast.string(nil) }
    end
    it "int" do
      Cast.int(3_i64).should eq(3_i64)
      expect_raises(Redis::ProtocolError) { Cast.int("3") }
    end
    it "float accepts double, integer and numeric string" do
      Cast.float(1.5).should eq(1.5)
      Cast.float(2_i64).should eq(2.0)
      Cast.float("3.25").should eq(3.25)
      expect_raises(Redis::ProtocolError) { Cast.float("x") }
    end
    it "bool accepts boolean and 0/1" do
      Cast.bool(true).should be_true
      Cast.bool(0_i64).should be_false
      Cast.bool(1_i64).should be_true
      expect_raises(Redis::ProtocolError) { Cast.bool(2_i64) }
    end
    it "strings accepts array or set of strings" do
      Cast.strings(["a", "b"] of Redis::Value).should eq(["a", "b"])
      Cast.strings(Set(Redis::Value){"a"}).should eq(["a"])
      expect_raises(Redis::ProtocolError) { Cast.strings(["a", 1_i64] of Redis::Value) }
    end
    it "strings? keeps nils" do
      Cast.strings?(["a", nil] of Redis::Value).should eq(["a", nil])
    end
    it "string_hash accepts a map or a flat array" do
      Cast.string_hash({"a" => "1"} of Redis::Value => Redis::Value).should eq({"a" => "1"})
      Cast.string_hash(["a", "1", "b", "2"] of Redis::Value).should eq({"a" => "1", "b" => "2"})
      expect_raises(Redis::ProtocolError) { Cast.string_hash(["a"] of Redis::Value) }
    end
    it "scored_pairs accepts pairs (RESP3) or a flat array (RESP2)" do
      Cast.scored_pairs([["a", 1.5] of Redis::Value, ["b", 2.0] of Redis::Value] of Redis::Value).should eq([{"a", 1.5}, {"b", 2.0}])
      Cast.scored_pairs(["a", "1.5", "b", "2"] of Redis::Value).should eq([{"a", 1.5}, {"b", 2.0}])
    end
    it "floats? and bools" do
      Cast.floats?([1.0, nil, "2.5"] of Redis::Value).should eq([1.0, nil, 2.5])
      Cast.bools([1_i64, 0_i64] of Redis::Value).should eq([true, false])
    end
    it "ok" do
      Cast.ok("OK").should be_nil
      expect_raises(Redis::ProtocolError) { Cast.ok("QUEUED") }
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/crystal spec spec/std/redis/commands_spec.cr`
Expected: `undefined macro 'def_command'`.

- [ ] **Step 3: Write the module**

```crystal
# src/redis/commands.cr
module Redis
  # Typed command methods shared by `Connection`, `Client` and `Pipeline`.
  #
  # An includer defines `call(args : Enumerable)` and
  # `typed_call(args : Enumerable, &block : Value -> T)`. On `Connection`
  # and `Client` a typed method returns `T`; on `Pipeline` it returns a
  # `Future(T)`. Method bodies here are written once and carry no explicit
  # return type for that reason.
  #
  # Blocking commands (`BLPOP`, `BRPOP`, `BLMOVE`, `WAIT`, ...) have no typed
  # method: on a multiplexed `Client` they would stall every other caller.
  # Run them through `Connection#call` on a dedicated connection.
  module Commands
    # Sends an arbitrary command and returns the raw `Value` (a `Future(Value)`
    # on a pipeline). Error replies are raised as `CommandError`.
    #
    # ```
    # redis.command("CLIENT", "ID") # => 42_i64
    # ```
    def command(*args : RESP::Arg)
      call(args)
    end

    # :ditto:
    def command(args : Enumerable)
      call(args)
    end

    # Defines a typed command method. *params* are the fixed parameters in
    # wire order; with `splat: true` the last one becomes a splat. *cast* names
    # the `Cast` method applied to the reply. (`as` cannot be a macro
    # parameter name: it is a keyword.)
    #
    # ```
    # def_command get, "GET", key : String, cast: :string?
    # def_command del, "DEL", keys : String, cast: :int, splat: true
    # ```
    macro def_command(name, cmd, *params, cast, splat = false)
      {% if splat %}
        {% fixed = params[0...-1] %}
        {% last = params.last %}
      {% else %}
        {% fixed = params %}
      {% end %}
      def {{name.id}}({{fixed.splat}}{% if splat %}{% unless fixed.empty? %}, {% end %}*{{last.var}} : {{last.type}}{% end %})
        args = Array(RESP::Arg).new({{fixed.size + 1}}{% if splat %} + {{last.var}}.size{% end %})
        args << {{cmd}}
        {% for p in fixed %}
          args << {{p.var}}
        {% end %}
        {% if splat %}
          {{last.var}}.each { |v| args << v }
        {% end %}
        typed_call(args) { |v| Cast.{{cast.id}}(v) }
      end
    end

    # Reply-shape conversions. Each accepts the RESP3 shape and the RESP2
    # shape of the same command and raises `ProtocolError` otherwise.
    module Cast
      def self.value(v : Value) : Value
        v
      end

      def self.string(v : Value) : String
        v.as?(String) || unexpected(v, "string")
      end

      def self.string?(v : Value) : String?
        v.nil? ? nil : string(v)
      end

      def self.int(v : Value) : Int64
        v.as?(Int64) || unexpected(v, "integer")
      end

      def self.float(v : Value) : Float64
        case v
        when Float64 then v
        when Int64   then v.to_f64
        when String  then v.to_f64? || unexpected(v, "double")
        else              unexpected(v, "double")
        end
      end

      def self.float?(v : Value) : Float64?
        v.nil? ? nil : float(v)
      end

      def self.bool(v : Value) : Bool
        case v
        when Bool  then v
        when 0_i64 then false
        when 1_i64 then true
        else            unexpected(v, "boolean")
        end
      end

      def self.ok(v : Value) : Nil
        unexpected(v, "OK") unless v == "OK"
      end

      def self.strings(v : Value) : Array(String)
        elements(v, "array of strings").map { |e| string(e) }
      end

      def self.strings?(v : Value) : Array(String?)
        elements(v, "array of strings").map { |e| string?(e) }
      end

      def self.bools(v : Value) : Array(Bool)
        elements(v, "array of booleans").map { |e| bool(e) }
      end

      def self.floats?(v : Value) : Array(Float64?)
        elements(v, "array of doubles").map { |e| float?(e) }
      end

      def self.string_hash(v : Value) : Hash(String, String)
        case v
        when Hash
          v.each_with_object(Hash(String, String).new(initial_capacity: v.size)) do |(k, val), h|
            h[string(k)] = string(val)
          end
        when Array
          unexpected(v, "flat key-value array") if v.size.odd?
          h = Hash(String, String).new(initial_capacity: v.size // 2)
          i = 0
          while i < v.size
            h[string(v[i])] = string(v[i + 1])
            i += 2
          end
          h
        else
          unexpected(v, "map")
        end
      end

      def self.scored_pairs(v : Value) : Array({String, Float64})
        array = elements(v, "array of member-score pairs")
        if !array.empty? && array[0].is_a?(Array)
          array.map do |pair|
            p = pair.as?(Array) || unexpected(pair, "member-score pair")
            unexpected(pair, "member-score pair") unless p.size == 2
            {string(p[0]), float(p[1])}
          end
        else
          unexpected(v, "flat member-score array") if array.size.odd?
          result = Array({String, Float64}).new(array.size // 2)
          i = 0
          while i < array.size
            result << {string(array[i]), float(array[i + 1])}
            i += 2
          end
          result
        end
      end

      # Array, or Set for RESP3 set replies (SMEMBERS, SINTER, ...).
      # Public (`:nodoc:`) because hand-written commands use it.
      # :nodoc:
      def self.elements(v : Value, expected : String) : Array(Value)
        case v
        when Array then v
        when Set   then v.to_a
        else            unexpected(v, expected)
        end
      end

      # :nodoc:
      def self.unexpected(v : Value, expected : String) : NoReturn
        raise ProtocolError.new("unexpected reply: expected #{expected}, got #{v.inspect}")
      end
    end
  end
end
```

Also delete the empty stub bodies from `src/redis/commands/*.cr` if any were created; the family files are created in Tasks 6-8. Add `require "./commands/*"` at the bottom of `commands.cr` only once the first family file exists (Task 6).

- [ ] **Step 4: Run the spec to verify it passes**

Run: `bin/crystal spec spec/std/redis/commands_spec.cr`
Expected: all pass.

- [ ] **Step 5: Format and commit**

```bash
bin/crystal tool format src/redis spec/std/redis
git add src/redis/commands.cr spec/std/redis/commands_spec.cr
git commit -m "Redis: Commands module, def_command macro, Cast helpers

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: Command families: server, keys, strings

**Files:**
- Create: `src/redis/commands/server.cr`, `src/redis/commands/keys.cr`, `src/redis/commands/strings.cr`
- Modify: `src/redis/commands.cr` (append `require "./commands/*"` at file end, outside the module)
- Test: `spec/std/redis/commands_spec.cr`

**Interfaces:**
- Consumes: `def_command`, `Cast`, `typed_call` (Task 5).
- Produces: the methods listed in spec §7.3 for these families. Options use keyword args; `Time::Span` or `Int` for TTLs. `scan` returns `{String, Array(String)}`; `scan_each` yields keys.

Tests use the `Stub` class from Task 5 (same file). Every method gets at least one example asserting the exact arg array and the cast. Reuse this helper in the spec file:

```crystal
private def expect_call(reply : Redis::Value, expected_args : Array, &block : Stub -> _)
  s = stub(reply)
  result = block.call(s)
  s.calls.should eq([expected_args])
  result
end
```

- [ ] **Step 1: Write the failing spec (append to `commands_spec.cr`)**

```crystal
describe "server commands" do
  it "ping / echo / select / dbsize / time / flushdb / flushall" do
    expect_call("PONG", ["PING"], &.ping).should eq("PONG")
    expect_call("hi", ["PING", "hi"], &.ping("hi")).should eq("hi")
    expect_call("x", ["ECHO", "x"], &.echo("x")).should eq("x")
    expect_call("OK", ["SELECT", 2], &.select(2)).should be_nil
    expect_call(3_i64, ["DBSIZE"], &.dbsize).should eq(3_i64)
    expect_call(["1700000000", "123"] of Redis::Value, ["TIME"], &.time).should eq({1700000000_i64, 123_i64})
    expect_call("OK", ["FLUSHDB"], &.flushdb).should be_nil
    expect_call("OK", ["FLUSHDB", "ASYNC"], &.flushdb(async: true)).should be_nil
    expect_call("OK", ["FLUSHALL"], &.flushall).should be_nil
  end

  it "info parses key:value lines" do
    raw = "# Server\r\nredis_version:7.2.4\r\nuptime_in_seconds:10\r\n\r\n# Clients\r\nconnected_clients:1\r\n"
    expect_call(raw, ["INFO"], &.info).should eq({"redis_version" => "7.2.4", "uptime_in_seconds" => "10", "connected_clients" => "1"})
    expect_call("", ["INFO", "server"], &.info("server")).should eq({} of String => String)
  end
end

describe "key commands" do
  it "del / unlink / exists / type / rename / renamenx / keys / persist" do
    expect_call(2_i64, ["DEL", "a", "b"], &.del("a", "b")).should eq(2_i64)
    expect_call(1_i64, ["UNLINK", "a"], &.unlink("a")).should eq(1_i64)
    expect_call(1_i64, ["EXISTS", "a", "b"], &.exists("a", "b")).should eq(1_i64)
    expect_call("string", ["TYPE", "a"], &.type("a")).should eq("string")
    expect_call("OK", ["RENAME", "a", "b"], &.rename("a", "b")).should be_nil
    expect_call(1_i64, ["RENAMENX", "a", "b"], &.renamenx("a", "b")).should be_true
    expect_call(["a"] of Redis::Value, ["KEYS", "*"], &.keys("*")).should eq(["a"])
    expect_call(1_i64, ["PERSIST", "a"], &.persist("a")).should be_true
  end

  it "expire family with spans, ints and flags" do
    expect_call(1_i64, ["EXPIRE", "a", 60], &.expire("a", 60.seconds)).should be_true
    expect_call(1_i64, ["EXPIRE", "a", 5, "NX"], &.expire("a", 5, nx: true)).should be_true
    expect_call(1_i64, ["PEXPIRE", "a", 1500], &.pexpire("a", 1.5.seconds)).should be_true
    expect_call(0_i64, ["EXPIREAT", "a", 1700000000], &.expireat("a", 1700000000)).should be_false
    expect_call(1_i64, ["PEXPIREAT", "a", 1700000000000, "GT"], &.pexpireat("a", 1700000000000, gt: true)).should be_true
    expect_call(-2_i64, ["TTL", "a"], &.ttl("a")).should eq(-2_i64)
    expect_call(900_i64, ["PTTL", "a"], &.pttl("a")).should eq(900_i64)
  end

  it "scan returns cursor and keys" do
    reply = ["17", ["a", "b"] of Redis::Value] of Redis::Value
    expect_call(reply, ["SCAN", "0"], &.scan("0")).should eq({"17", ["a", "b"]})
    expect_call(reply, ["SCAN", "0", "MATCH", "a*", "COUNT", 10, "TYPE", "string"],
      &.scan("0", match: "a*", count: 10, type: "string")).should eq({"17", ["a", "b"]})
  end

  it "scan_each iterates until cursor 0" do
    s = Stub.new
    s.replies = [["5", ["a"] of Redis::Value] of Redis::Value, ["0", ["b"] of Redis::Value] of Redis::Value] of Redis::Value
    seen = [] of String
    s.scan_each(match: "*") { |k| seen << k }
    seen.should eq(["a", "b"])
    s.calls.should eq([["SCAN", "0", "MATCH", "*"], ["SCAN", "5", "MATCH", "*"]])
  end
end

describe "string commands" do
  it "get / set with options" do
    expect_call("v", ["GET", "k"], &.get("k")).should eq("v")
    expect_call(nil, ["GET", "k"], &.get("k")).should be_nil
    expect_call("OK", ["SET", "k", "v"], &.set("k", "v")).should eq("OK")
    expect_call("OK", ["SET", "k", "v", "EX", 60], &.set("k", "v", ex: 60.seconds)).should eq("OK")
    expect_call("OK", ["SET", "k", "v", "PX", 1500, "NX"], &.set("k", "v", px: 1500, nx: true)).should eq("OK")
    expect_call(nil, ["SET", "k", "v", "XX", "KEEPTTL"], &.set("k", "v", xx: true, keepttl: true)).should be_nil
    expect_call("old", ["SET", "k", "v", "GET"], &.set("k", "v", get: true)).should eq("old")
    expect_call("OK", ["SET", "k", "v", "EXAT", 1700000000], &.set("k", "v", exat: 1700000000)).should eq("OK")
    expect_call("OK", ["SET", "k", "v", "PXAT", 1700000000000], &.set("k", "v", pxat: 1700000000000)).should eq("OK")
  end

  it "rejects contradictory set options" do
    expect_raises(ArgumentError) { stub("OK").set("k", "v", nx: true, xx: true) }
    expect_raises(ArgumentError) { stub("OK").set("k", "v", ex: 1, px: 1) }
  end

  it "setnx / setex / psetex / getset / getdel / mget / mset / msetnx" do
    expect_call(1_i64, ["SETNX", "k", "v"], &.setnx("k", "v")).should be_true
    expect_call("OK", ["SETEX", "k", 10, "v"], &.setex("k", 10.seconds, "v")).should be_nil
    expect_call("OK", ["PSETEX", "k", 10, "v"], &.psetex("k", 10, "v")).should be_nil
    expect_call("old", ["GETSET", "k", "v"], &.getset("k", "v")).should eq("old")
    expect_call("v", ["GETDEL", "k"], &.getdel("k")).should eq("v")
    expect_call(["a", nil] of Redis::Value, ["MGET", "x", "y"], &.mget("x", "y")).should eq(["a", nil])
    expect_call("OK", ["MSET", "a", "1", "b", "2"], &.mset({"a" => "1", "b" => "2"})).should be_nil
    expect_call(1_i64, ["MSETNX", "a", "1"], &.msetnx({"a" => "1"})).should be_true
  end

  it "counters and substrings" do
    expect_call(2_i64, ["INCR", "c"], &.incr("c")).should eq(2_i64)
    expect_call(5_i64, ["INCRBY", "c", 3], &.incrby("c", 3)).should eq(5_i64)
    expect_call("2.5", ["INCRBYFLOAT", "c", 0.5], &.incrbyfloat("c", 0.5)).should eq(2.5)
    expect_call(1_i64, ["DECR", "c"], &.decr("c")).should eq(1_i64)
    expect_call(-1_i64, ["DECRBY", "c", 2], &.decrby("c", 2)).should eq(-1_i64)
    expect_call(5_i64, ["APPEND", "k", "xx"], &.append("k", "xx")).should eq(5_i64)
    expect_call(5_i64, ["STRLEN", "k"], &.strlen("k")).should eq(5_i64)
    expect_call("ell", ["GETRANGE", "k", 1, 3], &.getrange("k", 1, 3)).should eq("ell")
    expect_call(5_i64, ["SETRANGE", "k", 1, "xy"], &.setrange("k", 1, "xy")).should eq(5_i64)
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/crystal spec spec/std/redis/commands_spec.cr`
Expected: `undefined method 'ping'`.

- [ ] **Step 3: Write the three family files**

```crystal
# src/redis/commands/server.cr
module Redis::Commands
  # Returns `"PONG"`, or *message* when given.
  def ping
    typed_call({"PING"}) { |v| Cast.string(v) }
  end

  # :ditto:
  def ping(message : String)
    typed_call({"PING", message}) { |v| Cast.string(v) }
  end

  # Returns *message*.
  def_command echo, "ECHO", message : String, cast: :string

  # Selects logical database *index* for this connection. Hand-written:
  # `select` is a keyword, so it cannot appear as a bare macro argument.
  def select(index : Int)
    typed_call({"SELECT", index}) { |v| Cast.ok(v) }
  end

  # Returns the number of keys in the current database.
  def_command dbsize, "DBSIZE", cast: :int

  # Deletes all keys of the current database.
  def flushdb(*, async : Bool = false)
    typed_call(async ? {"FLUSHDB", "ASYNC"} : {"FLUSHDB"}) { |v| Cast.ok(v) }
  end

  # Deletes all keys of all databases.
  def flushall(*, async : Bool = false)
    typed_call(async ? {"FLUSHALL", "ASYNC"} : {"FLUSHALL"}) { |v| Cast.ok(v) }
  end

  # Returns the server time as `{unix_seconds, microseconds}`.
  def time
    typed_call({"TIME"}) do |v|
      parts = Cast.strings(v)
      Cast.unexpected(v, "TIME pair") unless parts.size == 2
      {parts[0].to_i64? || Cast.unexpected(v, "integer"), parts[1].to_i64? || Cast.unexpected(v, "integer")}
    end
  end

  # Returns `INFO` output (optionally one *section*) parsed into a hash of
  # `key => value`; comment and blank lines are dropped.
  def info(section : String? = nil)
    typed_call(section ? {"INFO", section} : {"INFO"}) do |v|
      hash = {} of String => String
      Cast.string(v).each_line(chomp: true) do |line|
        next if line.empty? || line.starts_with?('#')
        key, _, value = line.partition(':')
        hash[key] = value
      end
      hash
    end
  end
end
```


```crystal
# src/redis/commands/keys.cr
module Redis::Commands
  # Deletes *keys*; returns how many existed.
  def_command del, "DEL", keys : String, cast: :int, splat: true
  # Like `del` but reclaims memory asynchronously.
  def_command unlink, "UNLINK", keys : String, cast: :int, splat: true
  # Returns how many of *keys* exist.
  def_command exists, "EXISTS", keys : String, cast: :int, splat: true
  # Returns the type name of *key* (`"string"`, `"list"`, ..., `"none"`).
  def_command type, "TYPE", key : String, cast: :string
  # Renames *key* to *newkey*.
  def_command rename, "RENAME", key : String, newkey : String, cast: :ok
  # Renames *key* only if *newkey* does not exist.
  def_command renamenx, "RENAMENX", key : String, newkey : String, cast: :bool
  # Returns keys matching *pattern*. Prefer `scan_each` on large databases.
  def_command keys, "KEYS", pattern : String, cast: :strings
  # Removes the expiration of *key*.
  def_command persist, "PERSIST", key : String, cast: :bool
  # Remaining time to live in seconds (-1 no expiry, -2 no key).
  def_command ttl, "TTL", key : String, cast: :int
  # Remaining time to live in milliseconds.
  def_command pttl, "PTTL", key : String, cast: :int

  # Sets a timeout on *key*. *ttl* is a `Time::Span` or seconds. Returns
  # `true` if the timeout was set. Flags map to `NX`/`XX`/`GT`/`LT`.
  def expire(key : String, ttl : Time::Span | Int, *, nx = false, xx = false, gt = false, lt = false)
    expire_command("EXPIRE", key, ttl.is_a?(Time::Span) ? ttl.total_seconds.to_i64 : ttl, nx, xx, gt, lt)
  end

  # Like `expire` with a millisecond *ttl*.
  def pexpire(key : String, ttl : Time::Span | Int, *, nx = false, xx = false, gt = false, lt = false)
    expire_command("PEXPIRE", key, ttl.is_a?(Time::Span) ? ttl.total_milliseconds.to_i64 : ttl, nx, xx, gt, lt)
  end

  # Sets the expiration of *key* to a Unix timestamp in seconds.
  def expireat(key : String, timestamp : Int, *, nx = false, xx = false, gt = false, lt = false)
    expire_command("EXPIREAT", key, timestamp, nx, xx, gt, lt)
  end

  # Sets the expiration of *key* to a Unix timestamp in milliseconds.
  def pexpireat(key : String, timestamp : Int, *, nx = false, xx = false, gt = false, lt = false)
    expire_command("PEXPIREAT", key, timestamp, nx, xx, gt, lt)
  end

  private def expire_command(cmd : String, key : String, value : Int, nx, xx, gt, lt)
    args = Array(RESP::Arg).new(4)
    args << cmd << key << value
    args << "NX" if nx
    args << "XX" if xx
    args << "GT" if gt
    args << "LT" if lt
    typed_call(args) { |v| Cast.bool(v) }
  end

  # One `SCAN` step. Returns `{next_cursor, keys}`; the cursor `"0"` marks
  # the end of the iteration.
  def scan(cursor : String, *, match : String? = nil, count : Int? = nil, type : String? = nil)
    args = Array(RESP::Arg).new(8)
    args << "SCAN" << cursor
    args << "MATCH" << match if match
    args << "COUNT" << count if count
    args << "TYPE" << type if type
    typed_call(args) { |v| Cast.scan_page(v) }
  end

  # Iterates every key matching *match*, issuing `SCAN` until the cursor
  # returns to `"0"`. Not available on a pipeline.
  def scan_each(*, match : String? = nil, count : Int? = nil, type : String? = nil, & : String ->) : Nil
    cursor = "0"
    loop do
      cursor, keys = scan(cursor, match: match, count: count, type: type)
      keys.each { |key| yield key }
      break if cursor == "0"
    end
  end
end
```

Add to `Cast` in `commands.cr`:

```crystal
      # `{cursor, elements}` as returned by the SCAN family.
      def self.scan_page(v : Value) : {String, Array(String)}
        page = elements(v, "scan page")
        unexpected(v, "scan page") unless page.size == 2
        {string(page[0]), strings(page[1])}
      end
```

`scan_each` calls `scan` and destructures its result, which only type-checks when `typed_call` returns `T` directly. In `Pipeline` (Task 11) `scan` returns a `Future`, so `Pipeline` must `undef`-guard it: the plan handles that in Task 11 by defining `scan_each` in `Pipeline` to raise `ArgumentError.new("scan_each is not available on a pipeline")`. Also `sscan_each`/`hscan_each`/`zscan_each` are deliberately not provided (YAGNI); only `scan_each`.

```crystal
# src/redis/commands/strings.cr
module Redis::Commands
  # Returns the string value of *key*, or `nil` if it does not exist.
  def_command get, "GET", key : String, cast: :string?

  # Sets *key* to *value*. Options: `ex`/`px` relative TTL (`Time::Span` or
  # seconds/milliseconds), `exat`/`pxat` absolute Unix timestamps, `nx` only
  # if absent, `xx` only if present, `keepttl`, and `get` to return the old
  # value. Returns `"OK"`, `nil` when an `nx`/`xx` condition fails, or the
  # previous value with `get: true`.
  def set(key : String, value : RESP::Arg, *, ex : Time::Span | Int | Nil = nil, px : Time::Span | Int | Nil = nil,
          exat : Int? = nil, pxat : Int? = nil, nx : Bool = false, xx : Bool = false,
          keepttl : Bool = false, get : Bool = false)
    raise ArgumentError.new("nx and xx are mutually exclusive") if nx && xx
    ttl_options = {ex, px, exat, pxat}.count { |o| !o.nil? } + (keepttl ? 1 : 0)
    raise ArgumentError.new("ex, px, exat, pxat and keepttl are mutually exclusive") if ttl_options > 1
    args = Array(RESP::Arg).new(8)
    args << "SET" << key << value
    if ex
      args << "EX" << (ex.is_a?(Time::Span) ? ex.total_seconds.to_i64 : ex)
    elsif px
      args << "PX" << (px.is_a?(Time::Span) ? px.total_milliseconds.to_i64 : px)
    elsif exat
      args << "EXAT" << exat
    elsif pxat
      args << "PXAT" << pxat
    end
    args << "NX" if nx
    args << "XX" if xx
    args << "KEEPTTL" if keepttl
    args << "GET" if get
    typed_call(args) { |v| Cast.string?(v) }
  end

  # Sets *key* only if it does not exist.
  def_command setnx, "SETNX", key : String, value : RESP::Arg, cast: :bool

  # Sets *key* with a TTL in seconds.
  def setex(key : String, ttl : Time::Span | Int, value : RESP::Arg)
    typed_call({"SETEX", key, ttl.is_a?(Time::Span) ? ttl.total_seconds.to_i64 : ttl, value}) { |v| Cast.ok(v) }
  end

  # Sets *key* with a TTL in milliseconds.
  def psetex(key : String, ttl : Time::Span | Int, value : RESP::Arg)
    typed_call({"PSETEX", key, ttl.is_a?(Time::Span) ? ttl.total_milliseconds.to_i64 : ttl, value}) { |v| Cast.ok(v) }
  end

  # Sets *key* and returns its previous value.
  def_command getset, "GETSET", key : String, value : RESP::Arg, cast: :string?
  # Returns and deletes *key*.
  def_command getdel, "GETDEL", key : String, cast: :string?
  # Returns the values of *keys*, `nil` for missing ones.
  def_command mget, "MGET", keys : String, cast: :strings?, splat: true
  # Increments *key* by one.
  def_command incr, "INCR", key : String, cast: :int
  # Increments *key* by *increment*.
  def_command incrby, "INCRBY", key : String, increment : Int, cast: :int
  # Increments *key* by a float *increment*.
  def_command incrbyfloat, "INCRBYFLOAT", key : String, increment : Float, cast: :float
  # Decrements *key* by one.
  def_command decr, "DECR", key : String, cast: :int
  # Decrements *key* by *decrement*.
  def_command decrby, "DECRBY", key : String, decrement : Int, cast: :int
  # Appends *value*; returns the new length.
  def_command append, "APPEND", key : String, value : RESP::Arg, cast: :int
  # Returns the byte length of *key*'s value.
  def_command strlen, "STRLEN", key : String, cast: :int
  # Returns the substring from *start* to *stop* (inclusive, negative from end).
  def_command getrange, "GETRANGE", key : String, start : Int, stop : Int, cast: :string
  # Overwrites from *offset*; returns the new length.
  def_command setrange, "SETRANGE", key : String, offset : Int, value : RESP::Arg, cast: :int

  # Sets several keys at once.
  def mset(pairs : Hash(String, RESP::Arg) | Hash(String, String))
    typed_call(kv_args("MSET", pairs)) { |v| Cast.ok(v) }
  end

  # Sets several keys only if none exists.
  def msetnx(pairs : Hash(String, RESP::Arg) | Hash(String, String))
    typed_call(kv_args("MSETNX", pairs)) { |v| Cast.bool(v) }
  end

  private def kv_args(cmd : String, pairs : Hash) : Array(RESP::Arg)
    args = Array(RESP::Arg).new(1 + pairs.size * 2)
    args << cmd
    pairs.each { |k, v| args << k << v }
    args
  end
end
```

Note: `typed_call` accepts `Enumerable`, so tuples like `{"PING", message}` pass straight through without allocating an Array. `def_command` uses `RESP::Arg` for values so `set("n", 1)` works.

- [ ] **Step 4: Run the spec to verify it passes**

Run: `bin/crystal spec spec/std/redis/commands_spec.cr`
Expected: all pass.

- [ ] **Step 5: Format and commit**

```bash
bin/crystal tool format src/redis spec/std/redis
git add src/redis/commands.cr src/redis/commands spec/std/redis/commands_spec.cr
git commit -m "Redis: server, key and string commands

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Command families: hashes, lists, sets

**Files:**
- Create: `src/redis/commands/hashes.cr`, `src/redis/commands/lists.cr`, `src/redis/commands/sets.cr`
- Test: `spec/std/redis/commands_spec.cr`

**Interfaces:**
- Consumes: `def_command`, `Cast`, `kv_args` (Task 6).
- Produces: spec §7.3 methods for these families. `hscan`/`sscan` return `{String, Hash(String, String)}` / `{String, Array(String)}`.

- [ ] **Step 1: Write the failing spec (append to `commands_spec.cr`)**

```crystal
describe "hash commands" do
  it "hget / hset / hsetnx / hmget / hgetall / hdel / hexists / hkeys / hvals / hlen" do
    expect_call("v", ["HGET", "h", "f"], &.hget("h", "f")).should eq("v")
    expect_call(1_i64, ["HSET", "h", "f", "v"], &.hset("h", "f", "v")).should eq(1_i64)
    expect_call(2_i64, ["HSET", "h", "a", "1", "b", "2"], &.hset("h", {"a" => "1", "b" => "2"})).should eq(2_i64)
    expect_call(1_i64, ["HSETNX", "h", "f", "v"], &.hsetnx("h", "f", "v")).should be_true
    expect_call(["1", nil] of Redis::Value, ["HMGET", "h", "a", "z"], &.hmget("h", "a", "z")).should eq(["1", nil])
    expect_call({"a" => "1"} of Redis::Value => Redis::Value, ["HGETALL", "h"], &.hgetall("h")).should eq({"a" => "1"})
    expect_call(["a", "1"] of Redis::Value, ["HGETALL", "h"], &.hgetall("h")).should eq({"a" => "1"})
    expect_call(1_i64, ["HDEL", "h", "a", "b"], &.hdel("h", "a", "b")).should eq(1_i64)
    expect_call(0_i64, ["HEXISTS", "h", "a"], &.hexists("h", "a")).should be_false
    expect_call(["a"] of Redis::Value, ["HKEYS", "h"], &.hkeys("h")).should eq(["a"])
    expect_call(["1"] of Redis::Value, ["HVALS", "h"], &.hvals("h")).should eq(["1"])
    expect_call(1_i64, ["HLEN", "h"], &.hlen("h")).should eq(1_i64)
    expect_call(3_i64, ["HINCRBY", "h", "n", 2], &.hincrby("h", "n", 2)).should eq(3_i64)
    expect_call("1.5", ["HINCRBYFLOAT", "h", "n", 0.5], &.hincrbyfloat("h", "n", 0.5)).should eq(1.5)
  end

  it "hscan returns cursor and a hash" do
    reply = ["0", ["a", "1"] of Redis::Value] of Redis::Value
    expect_call(reply, ["HSCAN", "h", "0", "MATCH", "a*", "COUNT", 5], &.hscan("h", "0", match: "a*", count: 5)).should eq({"0", {"a" => "1"}})
  end
end

describe "list commands" do
  it "push / pop / len / range" do
    expect_call(2_i64, ["LPUSH", "l", "a", "b"], &.lpush("l", "a", "b")).should eq(2_i64)
    expect_call(2_i64, ["RPUSH", "l", "a"], &.rpush("l", "a")).should eq(2_i64)
    expect_call(0_i64, ["LPUSHX", "l", "a"], &.lpushx("l", "a")).should eq(0_i64)
    expect_call(0_i64, ["RPUSHX", "l", "a"], &.rpushx("l", "a")).should eq(0_i64)
    expect_call("a", ["LPOP", "l"], &.lpop("l")).should eq("a")
    expect_call(nil, ["RPOP", "l"], &.rpop("l")).should be_nil
    expect_call(["a", "b"] of Redis::Value, ["LPOP", "l", 2], &.lpop("l", 2)).should eq(["a", "b"])
    expect_call(nil, ["RPOP", "l", 2], &.rpop("l", 2)).should eq([] of String)
    expect_call(3_i64, ["LLEN", "l"], &.llen("l")).should eq(3_i64)
    expect_call(["a"] of Redis::Value, ["LRANGE", "l", 0, -1], &.lrange("l", 0, -1)).should eq(["a"])
    expect_call("a", ["LINDEX", "l", 0], &.lindex("l", 0)).should eq("a")
    expect_call("OK", ["LSET", "l", 0, "z"], &.lset("l", 0, "z")).should be_nil
    expect_call(1_i64, ["LREM", "l", 0, "a"], &.lrem("l", 0, "a")).should eq(1_i64)
    expect_call("OK", ["LTRIM", "l", 0, 1], &.ltrim("l", 0, 1)).should be_nil
    expect_call(2_i64, ["LINSERT", "l", "BEFORE", "b", "a"], &.linsert("l", :before, "b", "a")).should eq(2_i64)
    expect_call("a", ["LMOVE", "l", "m", "LEFT", "RIGHT"], &.lmove("l", "m", :left, :right)).should eq("a")
  end
end

describe "set commands" do
  it "add / rem / members / card / pop / rand / move / is-member" do
    expect_call(2_i64, ["SADD", "s", "a", "b"], &.sadd("s", "a", "b")).should eq(2_i64)
    expect_call(1_i64, ["SREM", "s", "a"], &.srem("s", "a")).should eq(1_i64)
    expect_call(Set(Redis::Value){"a"}, ["SMEMBERS", "s"], &.smembers("s")).should eq(["a"])
    expect_call(["a"] of Redis::Value, ["SMEMBERS", "s"], &.smembers("s")).should eq(["a"])
    expect_call(1_i64, ["SISMEMBER", "s", "a"], &.sismember("s", "a")).should be_true
    expect_call([1_i64, 0_i64] of Redis::Value, ["SMISMEMBER", "s", "a", "b"], &.smismember("s", "a", "b")).should eq([true, false])
    expect_call(1_i64, ["SCARD", "s"], &.scard("s")).should eq(1_i64)
    expect_call("a", ["SPOP", "s"], &.spop("s")).should eq("a")
    expect_call(["a"] of Redis::Value, ["SPOP", "s", 1], &.spop("s", 1)).should eq(["a"])
    expect_call("a", ["SRANDMEMBER", "s"], &.srandmember("s")).should eq("a")
    expect_call(["a"] of Redis::Value, ["SRANDMEMBER", "s", 1], &.srandmember("s", 1)).should eq(["a"])
    expect_call(1_i64, ["SMOVE", "s", "t", "a"], &.smove("s", "t", "a")).should be_true
  end

  it "set algebra" do
    expect_call(["a"] of Redis::Value, ["SINTER", "s", "t"], &.sinter("s", "t")).should eq(["a"])
    expect_call(["a"] of Redis::Value, ["SUNION", "s", "t"], &.sunion("s", "t")).should eq(["a"])
    expect_call(["a"] of Redis::Value, ["SDIFF", "s", "t"], &.sdiff("s", "t")).should eq(["a"])
    expect_call(1_i64, ["SINTERSTORE", "d", "s", "t"], &.sinterstore("d", "s", "t")).should eq(1_i64)
    expect_call(1_i64, ["SUNIONSTORE", "d", "s", "t"], &.sunionstore("d", "s", "t")).should eq(1_i64)
    expect_call(1_i64, ["SDIFFSTORE", "d", "s", "t"], &.sdiffstore("d", "s", "t")).should eq(1_i64)
  end

  it "sscan" do
    reply = ["0", ["a"] of Redis::Value] of Redis::Value
    expect_call(reply, ["SSCAN", "s", "0", "COUNT", 3], &.sscan("s", "0", count: 3)).should eq({"0", ["a"]})
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/crystal spec spec/std/redis/commands_spec.cr`
Expected: `undefined method 'hget'`.

- [ ] **Step 3: Write the three family files**

```crystal
# src/redis/commands/hashes.cr
module Redis::Commands
  # Returns the value of *field* in hash *key*.
  def_command hget, "HGET", key : String, field : String, cast: :string?
  # Sets *field* to *value*; returns the number of fields added.
  def_command hset, "HSET", key : String, field : String, value : RESP::Arg, cast: :int
  # Sets *field* only if it does not exist.
  def_command hsetnx, "HSETNX", key : String, field : String, value : RESP::Arg, cast: :bool
  # Returns the values of *fields*, `nil` for missing ones.
  def_command hmget, "HMGET", key : String, fields : String, cast: :strings?, splat: true
  # Returns all fields and values of hash *key*.
  def_command hgetall, "HGETALL", key : String, cast: :string_hash
  # Deletes *fields*; returns how many were removed.
  def_command hdel, "HDEL", key : String, fields : String, cast: :int, splat: true
  # Whether *field* exists in hash *key*.
  def_command hexists, "HEXISTS", key : String, field : String, cast: :bool
  # Returns the field names of hash *key*.
  def_command hkeys, "HKEYS", key : String, cast: :strings
  # Returns the values of hash *key*.
  def_command hvals, "HVALS", key : String, cast: :strings
  # Returns the number of fields in hash *key*.
  def_command hlen, "HLEN", key : String, cast: :int
  # Increments *field* by *increment*.
  def_command hincrby, "HINCRBY", key : String, field : String, increment : Int, cast: :int
  # Increments *field* by a float *increment*.
  def_command hincrbyfloat, "HINCRBYFLOAT", key : String, field : String, increment : Float, cast: :float

  # Sets several fields at once; returns the number of fields added.
  def hset(key : String, pairs : Hash(String, RESP::Arg) | Hash(String, String))
    args = Array(RESP::Arg).new(2 + pairs.size * 2)
    args << "HSET" << key
    pairs.each { |f, v| args << f << v }
    typed_call(args) { |v| Cast.int(v) }
  end

  # One `HSCAN` step. Returns `{next_cursor, fields}`.
  def hscan(key : String, cursor : String, *, match : String? = nil, count : Int? = nil)
    typed_call(scan_args("HSCAN", key, cursor, match, count)) do |v|
      page = Cast.elements(v, "scan page")
      Cast.unexpected(v, "scan page") unless page.size == 2
      {Cast.string(page[0]), Cast.string_hash(page[1])}
    end
  end

  private def scan_args(cmd : String, key : String, cursor : String, match : String?, count : Int?) : Array(RESP::Arg)
    args = Array(RESP::Arg).new(7)
    args << cmd << key << cursor
    args << "MATCH" << match if match
    args << "COUNT" << count if count
    args
  end
end
```


```crystal
# src/redis/commands/lists.cr
module Redis::Commands
  # Prepends *values*; returns the new length.
  def_command lpush, "LPUSH", key : String, values : RESP::Arg, cast: :int, splat: true
  # Appends *values*; returns the new length.
  def_command rpush, "RPUSH", key : String, values : RESP::Arg, cast: :int, splat: true
  # Prepends only if the list exists.
  def_command lpushx, "LPUSHX", key : String, values : RESP::Arg, cast: :int, splat: true
  # Appends only if the list exists.
  def_command rpushx, "RPUSHX", key : String, values : RESP::Arg, cast: :int, splat: true
  # Removes and returns the first element.
  def_command lpop, "LPOP", key : String, cast: :string?
  # Removes and returns the last element.
  def_command rpop, "RPOP", key : String, cast: :string?
  # Returns the length of the list.
  def_command llen, "LLEN", key : String, cast: :int
  # Returns elements from *start* to *stop* (inclusive, negative from end).
  def_command lrange, "LRANGE", key : String, start : Int, stop : Int, cast: :strings
  # Returns the element at *index*.
  def_command lindex, "LINDEX", key : String, index : Int, cast: :string?
  # Sets the element at *index*.
  def_command lset, "LSET", key : String, index : Int, value : RESP::Arg, cast: :ok
  # Removes up to *count* occurrences of *value* (0 = all); returns how many.
  def_command lrem, "LREM", key : String, count : Int, value : RESP::Arg, cast: :int
  # Trims the list to the range *start*..*stop*.
  def_command ltrim, "LTRIM", key : String, start : Int, stop : Int, cast: :ok

  # Removes and returns up to *count* first elements (empty array when the key is missing).
  def lpop(key : String, count : Int)
    typed_call({"LPOP", key, count}) { |v| v.nil? ? [] of String : Cast.strings(v) }
  end

  # Removes and returns up to *count* last elements.
  def rpop(key : String, count : Int)
    typed_call({"RPOP", key, count}) { |v| v.nil? ? [] of String : Cast.strings(v) }
  end

  # Inserts *value* before or after *pivot*; returns the new length, -1 if
  # *pivot* was not found.
  def linsert(key : String, where : Symbol, pivot : RESP::Arg, value : RESP::Arg)
    typed_call({"LINSERT", key, where_arg(where), pivot, value}) { |v| Cast.int(v) }
  end

  # Atomically pops from *source* (`:left`/`:right`) and pushes to
  # *destination* (`:left`/`:right`); returns the moved element.
  def lmove(source : String, destination : String, from : Symbol, to : Symbol)
    typed_call({"LMOVE", source, destination, side_arg(from), side_arg(to)}) { |v| Cast.string?(v) }
  end

  private def where_arg(where : Symbol) : String
    case where
    when :before then "BEFORE"
    when :after  then "AFTER"
    else              raise ArgumentError.new("expected :before or :after, got #{where.inspect}")
    end
  end

  private def side_arg(side : Symbol) : String
    case side
    when :left  then "LEFT"
    when :right then "RIGHT"
    else             raise ArgumentError.new("expected :left or :right, got #{side.inspect}")
    end
  end
end
```

```crystal
# src/redis/commands/sets.cr
module Redis::Commands
  # Adds *members*; returns how many were new.
  def_command sadd, "SADD", key : String, members : RESP::Arg, cast: :int, splat: true
  # Removes *members*; returns how many were removed.
  def_command srem, "SREM", key : String, members : RESP::Arg, cast: :int, splat: true
  # Returns all members.
  def_command smembers, "SMEMBERS", key : String, cast: :strings
  # Whether *member* is in the set.
  def_command sismember, "SISMEMBER", key : String, member : RESP::Arg, cast: :bool
  # Membership of each of *members*.
  def_command smismember, "SMISMEMBER", key : String, members : RESP::Arg, cast: :bools, splat: true
  # Returns the number of members.
  def_command scard, "SCARD", key : String, cast: :int
  # Removes and returns a random member.
  def_command spop, "SPOP", key : String, cast: :string?
  # Removes and returns up to *count* random members.
  def_command spop, "SPOP", key : String, count : Int, cast: :strings
  # Returns a random member.
  def_command srandmember, "SRANDMEMBER", key : String, cast: :string?
  # Returns *count* random members (negative allows repeats).
  def_command srandmember, "SRANDMEMBER", key : String, count : Int, cast: :strings
  # Moves *member* from *source* to *destination*.
  def_command smove, "SMOVE", source : String, destination : String, member : RESP::Arg, cast: :bool
  # Intersection of *keys*.
  def_command sinter, "SINTER", keys : String, cast: :strings, splat: true
  # Union of *keys*.
  def_command sunion, "SUNION", keys : String, cast: :strings, splat: true
  # Difference of the first key against the rest.
  def_command sdiff, "SDIFF", keys : String, cast: :strings, splat: true
  # Stores the intersection of *keys* in *destination*; returns its size.
  def_command sinterstore, "SINTERSTORE", destination : String, keys : String, cast: :int, splat: true
  # Stores the union of *keys* in *destination*.
  def_command sunionstore, "SUNIONSTORE", destination : String, keys : String, cast: :int, splat: true
  # Stores the difference in *destination*.
  def_command sdiffstore, "SDIFFSTORE", destination : String, keys : String, cast: :int, splat: true

  # One `SSCAN` step. Returns `{next_cursor, members}`.
  def sscan(key : String, cursor : String, *, match : String? = nil, count : Int? = nil)
    typed_call(scan_args("SSCAN", key, cursor, match, count)) { |v| Cast.scan_page(v) }
  end
end
```

- [ ] **Step 4: Run the spec to verify it passes**

Run: `bin/crystal spec spec/std/redis/commands_spec.cr`
Expected: all pass.

- [ ] **Step 5: Format and commit**

```bash
bin/crystal tool format src/redis spec/std/redis
git add src/redis/commands.cr src/redis/commands spec/std/redis/commands_spec.cr
git commit -m "Redis: hash, list and set commands

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: Command families: sorted sets, scripting

**Files:**
- Create: `src/redis/commands/sorted_sets.cr`, `src/redis/commands/scripting.cr`
- Test: `spec/std/redis/commands_spec.cr`

**Interfaces:**
- Consumes: `def_command`, `Cast.scored_pairs`, `Cast.floats?`, `scan_args`.
- Produces: `zadd`, `zadd_incr`, `zrem`, `zscore`, `zmscore`, `zcard`, `zcount`, `zincrby`, `zrange`, `zrange_with_scores`, `zrank`, `zrevrank`, `zpopmin`, `zpopmax`, `zscan`, `eval`, `evalsha`, `script_load`, `script_exists`, `script_flush`.

- [ ] **Step 1: Write the failing spec (append to `commands_spec.cr`)**

```crystal
describe "sorted set commands" do
  it "zadd forms and flags" do
    expect_call(1_i64, ["ZADD", "z", 1.5, "a"], &.zadd("z", 1.5, "a")).should eq(1_i64)
    expect_call(2_i64, ["ZADD", "z", "NX", "CH", 1.0, "a", 2.0, "b"],
      &.zadd("z", [{"a", 1.0}, {"b", 2.0}], nx: true, ch: true)).should eq(2_i64)
    expect_call(1_i64, ["ZADD", "z", "GT", 1.0, "a"], &.zadd("z", [{"a", 1.0}], gt: true)).should eq(1_i64)
    expect_call("3.5", ["ZADD", "z", "INCR", 2.0, "a"], &.zadd_incr("z", 2.0, "a")).should eq(3.5)
    expect_call(nil, ["ZADD", "z", "XX", "INCR", 2.0, "a"], &.zadd_incr("z", 2.0, "a", xx: true)).should be_nil
    expect_raises(ArgumentError) { stub(1_i64).zadd("z", [{"a", 1.0}], nx: true, xx: true) }
  end

  it "scores, ranks, counts" do
    expect_call(1_i64, ["ZREM", "z", "a", "b"], &.zrem("z", "a", "b")).should eq(1_i64)
    expect_call("1.5", ["ZSCORE", "z", "a"], &.zscore("z", "a")).should eq(1.5)
    expect_call(nil, ["ZSCORE", "z", "a"], &.zscore("z", "a")).should be_nil
    expect_call([1.5, nil] of Redis::Value, ["ZMSCORE", "z", "a", "b"], &.zmscore("z", "a", "b")).should eq([1.5, nil])
    expect_call(2_i64, ["ZCARD", "z"], &.zcard("z")).should eq(2_i64)
    expect_call(1_i64, ["ZCOUNT", "z", "-inf", "(2"], &.zcount("z", "-inf", "(2")).should eq(1_i64)
    expect_call("2.5", ["ZINCRBY", "z", 1.0, "a"], &.zincrby("z", 1.0, "a")).should eq(2.5)
    expect_call(0_i64, ["ZRANK", "z", "a"], &.zrank("z", "a")).should eq(0_i64)
    expect_call(nil, ["ZREVRANK", "z", "a"], &.zrevrank("z", "a")).should be_nil
  end

  it "zrange variants" do
    expect_call(["a"] of Redis::Value, ["ZRANGE", "z", 0, -1], &.zrange("z", 0, -1)).should eq(["a"])
    expect_call(["a"] of Redis::Value, ["ZRANGE", "z", "(1", "+inf", "BYSCORE", "LIMIT", 0, 10],
      &.zrange("z", "(1", "+inf", by_score: true, limit: {0, 10})).should eq(["a"])
    expect_call(["a"] of Redis::Value, ["ZRANGE", "z", "[a", "[z", "BYLEX", "REV"],
      &.zrange("z", "[a", "[z", by_lex: true, rev: true)).should eq(["a"])
    expect_call([["a", 1.0] of Redis::Value] of Redis::Value, ["ZRANGE", "z", 0, -1, "WITHSCORES"],
      &.zrange_with_scores("z", 0, -1)).should eq([{"a", 1.0}])
    expect_call(["a", "1"] of Redis::Value, ["ZRANGE", "z", 0, -1, "REV", "WITHSCORES"],
      &.zrange_with_scores("z", 0, -1, rev: true)).should eq([{"a", 1.0}])
    expect_raises(ArgumentError) { stub(nil).zrange("z", 0, 1, by_score: true, by_lex: true) }
  end

  it "zpopmin / zpopmax" do
    expect_call(["a", "1"] of Redis::Value, ["ZPOPMIN", "z"], &.zpopmin("z")).should eq([{"a", 1.0}])
    expect_call([["a", 1.0] of Redis::Value] of Redis::Value, ["ZPOPMAX", "z", 2], &.zpopmax("z", 2)).should eq([{"a", 1.0}])
    expect_call([] of Redis::Value, ["ZPOPMIN", "z"], &.zpopmin("z")).should eq([] of {String, Float64})
  end

  it "zscan" do
    reply = ["0", ["a", "1.5"] of Redis::Value] of Redis::Value
    expect_call(reply, ["ZSCAN", "z", "0", "MATCH", "a*"], &.zscan("z", "0", match: "a*")).should eq({"0", [{"a", 1.5}]})
  end
end

describe "scripting commands" do
  it "eval / evalsha with keys and args" do
    expect_call(2_i64, ["EVAL", "return 2", 0], &.eval("return 2")).should eq(2_i64)
    expect_call("x", ["EVAL", "s", 2, "k1", "k2", "a", 1], &.eval("s", keys: ["k1", "k2"], args: ["a", 1] of Redis::RESP::Arg)).should eq("x")
    expect_call("x", ["EVALSHA", "abc", 1, "k"], &.evalsha("abc", keys: ["k"])).should eq("x")
  end

  it "script load / exists / flush" do
    expect_call("abc", ["SCRIPT", "LOAD", "return 1"], &.script_load("return 1")).should eq("abc")
    expect_call([1_i64, 0_i64] of Redis::Value, ["SCRIPT", "EXISTS", "a", "b"], &.script_exists("a", "b")).should eq([true, false])
    expect_call("OK", ["SCRIPT", "FLUSH"], &.script_flush).should be_nil
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/crystal spec spec/std/redis/commands_spec.cr`
Expected: `undefined method 'zadd'`.

- [ ] **Step 3: Write the two family files**

```crystal
# src/redis/commands/sorted_sets.cr
module Redis::Commands
  # Adds *member* with *score*; returns how many members were added.
  def zadd(key : String, score : Float | Int, member : RESP::Arg)
    typed_call({"ZADD", key, score, member}) { |v| Cast.int(v) }
  end

  # Adds several `{member, score}` pairs. Flags: `nx` only add, `xx` only
  # update, `gt`/`lt` only update when the new score is greater/less, `ch`
  # count changed members instead of added ones.
  def zadd(key : String, members : Enumerable({String, Float64}), *, nx = false, xx = false,
           gt = false, lt = false, ch = false)
    args = zadd_args(key, members.size, nx, xx, gt, lt, ch, incr: false)
    members.each { |(member, score)| args << score << member }
    typed_call(args) { |v| Cast.int(v) }
  end

  # `ZADD ... INCR`: increments *member* by *increment* and returns the new
  # score, or `nil` when an `nx`/`xx`/`gt`/`lt` condition prevented it.
  def zadd_incr(key : String, increment : Float | Int, member : RESP::Arg, *, nx = false, xx = false,
                gt = false, lt = false)
    args = zadd_args(key, 1, nx, xx, gt, lt, false, incr: true)
    args << increment << member
    typed_call(args) { |v| Cast.float?(v) }
  end

  private def zadd_args(key, count, nx, xx, gt, lt, ch, *, incr) : Array(RESP::Arg)
    raise ArgumentError.new("nx and xx are mutually exclusive") if nx && xx
    raise ArgumentError.new("gt and lt are mutually exclusive") if gt && lt
    raise ArgumentError.new("nx cannot be combined with gt or lt") if nx && (gt || lt)
    args = Array(RESP::Arg).new(7 + count * 2)
    args << "ZADD" << key
    args << "NX" if nx
    args << "XX" if xx
    args << "GT" if gt
    args << "LT" if lt
    args << "CH" if ch
    args << "INCR" if incr
    args
  end

  # Removes *members*; returns how many were removed.
  def_command zrem, "ZREM", key : String, members : RESP::Arg, cast: :int, splat: true
  # Returns the score of *member*, or `nil`.
  def_command zscore, "ZSCORE", key : String, member : RESP::Arg, cast: :float?
  # Returns the scores of *members*, `nil` for missing ones.
  def_command zmscore, "ZMSCORE", key : String, members : RESP::Arg, cast: :floats?, splat: true
  # Returns the number of members.
  def_command zcard, "ZCARD", key : String, cast: :int
  # Counts members with scores between *min* and *max* (Redis range syntax, e.g. `"(1"`, `"+inf"`).
  def_command zcount, "ZCOUNT", key : String, min : RESP::Arg, max : RESP::Arg, cast: :int
  # Increments the score of *member*; returns the new score.
  def_command zincrby, "ZINCRBY", key : String, increment : Float | Int, member : RESP::Arg, cast: :float
  # Rank of *member* ascending, or `nil`.
  def zrank(key : String, member : RESP::Arg)
    typed_call({"ZRANK", key, member}) { |v| v.nil? ? nil : Cast.int(v) }
  end

  # Rank of *member* descending, or `nil`.
  def zrevrank(key : String, member : RESP::Arg)
    typed_call({"ZREVRANK", key, member}) { |v| v.nil? ? nil : Cast.int(v) }
  end

  # Members between *start* and *stop*: by rank (default), by score
  # (`by_score: true`, Redis range syntax) or lexicographically
  # (`by_lex: true`). `rev: true` reverses, `limit: {offset, count}` pages.
  def zrange(key : String, start : RESP::Arg, stop : RESP::Arg, *, by_score = false, by_lex = false,
             rev = false, limit : {Int32, Int32}? = nil)
    typed_call(zrange_args(key, start, stop, by_score, by_lex, rev, limit, with_scores: false)) { |v| Cast.strings(v) }
  end

  # Like `zrange`, returning `{member, score}` pairs.
  def zrange_with_scores(key : String, start : RESP::Arg, stop : RESP::Arg, *, by_score = false, by_lex = false,
                         rev = false, limit : {Int32, Int32}? = nil)
    typed_call(zrange_args(key, start, stop, by_score, by_lex, rev, limit, with_scores: true)) { |v| Cast.scored_pairs(v) }
  end

  private def zrange_args(key, start, stop, by_score, by_lex, rev, limit, *, with_scores) : Array(RESP::Arg)
    raise ArgumentError.new("by_score and by_lex are mutually exclusive") if by_score && by_lex
    raise ArgumentError.new("with_scores cannot be combined with by_lex") if with_scores && by_lex
    args = Array(RESP::Arg).new(10)
    args << "ZRANGE" << key << start << stop
    args << "BYSCORE" if by_score
    args << "BYLEX" if by_lex
    args << "REV" if rev
    if limit
      args << "LIMIT" << limit[0] << limit[1]
    end
    args << "WITHSCORES" if with_scores
    args
  end

  # Removes and returns the lowest-scored members (one, or *count*).
  def zpopmin(key : String, count : Int? = nil)
    typed_call(count ? {"ZPOPMIN", key, count} : {"ZPOPMIN", key}) { |v| Cast.scored_pairs(v) }
  end

  # Removes and returns the highest-scored members (one, or *count*).
  def zpopmax(key : String, count : Int? = nil)
    typed_call(count ? {"ZPOPMAX", key, count} : {"ZPOPMAX", key}) { |v| Cast.scored_pairs(v) }
  end

  # One `ZSCAN` step. Returns `{next_cursor, pairs}`.
  def zscan(key : String, cursor : String, *, match : String? = nil, count : Int? = nil)
    typed_call(scan_args("ZSCAN", key, cursor, match, count)) do |v|
      page = Cast.elements(v, "scan page")
      Cast.unexpected(v, "scan page") unless page.size == 2
      {Cast.string(page[0]), Cast.scored_pairs(page[1])}
    end
  end
end
```

`count ? {"ZPOPMIN", key, count} : {"ZPOPMIN", key}` produces a union of two tuple types, which `typed_call(args : Enumerable)` accepts; the RESP encoder's `args.size`/`each` work on both. `Cast.scored_pairs` returns `[]` for an empty array by the flat branch.

```crystal
# src/redis/commands/scripting.cr
module Redis::Commands
  # Runs a Lua *script* with *keys* and *args*. Returns the raw `Value`.
  def eval(script : String, *, keys : Array(String) = [] of String, args : Array(RESP::Arg) = [] of RESP::Arg)
    typed_call(script_args("EVAL", script, keys, args)) { |v| Cast.value(v) }
  end

  # Runs a cached script by its SHA1.
  def evalsha(sha : String, *, keys : Array(String) = [] of String, args : Array(RESP::Arg) = [] of RESP::Arg)
    typed_call(script_args("EVALSHA", sha, keys, args)) { |v| Cast.value(v) }
  end

  private def script_args(cmd : String, body : String, keys : Array(String), args : Array(RESP::Arg)) : Array(RESP::Arg)
    all = Array(RESP::Arg).new(3 + keys.size + args.size)
    all << cmd << body << keys.size
    keys.each { |k| all << k }
    args.each { |a| all << a }
    all
  end

  # Loads *script* into the script cache; returns its SHA1.
  def script_load(script : String)
    typed_call({"SCRIPT", "LOAD", script}) { |v| Cast.string(v) }
  end

  # Whether each of *shas* is in the script cache.
  def script_exists(*shas : String)
    args = Array(RESP::Arg).new(2 + shas.size)
    args << "SCRIPT" << "EXISTS"
    shas.each { |s| args << s }
    typed_call(args) { |v| Cast.bools(v) }
  end

  # Empties the script cache.
  def script_flush
    typed_call({"SCRIPT", "FLUSH"}) { |v| Cast.ok(v) }
  end
end
```

`args` is typed `Array(RESP::Arg)`, so call sites with mixed element types need `[...] of Redis::RESP::Arg` (as the spec does); an `Array(String)` literal is not an `Array(RESP::Arg)` either, hence the explicit `of` in the live spec too.

- [ ] **Step 4: Run the spec to verify it passes**

Run: `bin/crystal spec spec/std/redis/commands_spec.cr`
Expected: all pass.

- [ ] **Step 5: Format and commit**

```bash
bin/crystal tool format src/redis spec/std/redis
git add src/redis/commands spec/std/redis/commands_spec.cr
git commit -m "Redis: sorted set and scripting commands

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: Spec support: `pending_redis` and the fake server

**Files:**
- Create: `spec/support/redis.cr`
- Test: `spec/std/redis/fake_server_spec.cr` (small, proves the helper works)

**Interfaces:**
- Produces:
  - `RedisSpec::URL` (`ENV["REDIS_URL"]` or `redis://localhost:6379`), `RedisSpec::DB = 15`, `RedisSpec::AVAILABLE : Bool` (200 ms TCP probe at load).
  - `pending_redis(description, &)` / `pending_redis(describe:, &)` in the style of `pending_win32`.
  - `RedisSpec::FakeServer.new(&handler : IO ->)`: listens on `127.0.0.1:0`, spawns the handler per accepted socket; `#url : String`, `#port : Int32`, `#close`, `#accepted : Int32` (count of accepted connections).
  - `RedisSpec::FakeServer.read_command(io : IO) : Array(String)?` (nil at EOF).
  - `RedisSpec::FakeServer.serve_hello(io, cmd) : Bool`: answers a `HELLO` with a RESP3 map (`proto` 3) and returns true when *cmd* was HELLO.
  - `RedisSpec::HELLO_REPLY = "%3\r\n$6\r\nserver\r\n$5\r\nredis\r\n$5\r\nproto\r\n:3\r\n$2\r\nid\r\n:1\r\n"`.

- [ ] **Step 1: Write the failing spec**

```crystal
# spec/std/redis/fake_server_spec.cr
require "spec"
require "../../support/redis"

describe RedisSpec::FakeServer do
  it "reads commands and answers" do
    server = RedisSpec::FakeServer.new do |io|
      while cmd = RedisSpec::FakeServer.read_command(io)
        next if RedisSpec::FakeServer.serve_hello(io, cmd)
        io << "+" << cmd.join(' ') << "\r\n"
        io.flush
      end
    end
    begin
      sock = TCPSocket.new("127.0.0.1", server.port)
      Redis::RESP.write_command(sock, "HELLO", "3")
      sock.flush
      Redis::RESP.read(sock).as(Hash)["proto"]?.should eq(3_i64)
      Redis::RESP.write_command(sock, "PING", "x")
      sock.flush
      Redis::RESP.read(sock).should eq("PING x")
      sock.close
      server.accepted.should eq(1)
    ensure
      server.close
    end
  end

  it "reports availability of a live server as a Bool" do
    RedisSpec::AVAILABLE.should be_a(Bool)
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/crystal spec spec/std/redis/fake_server_spec.cr`
Expected: `can't find file '../../support/redis'`.

- [ ] **Step 3: Write the helper**

```crystal
# spec/support/redis.cr
require "spec"
require "socket"
require "redis"

module RedisSpec
  URL = ENV.fetch("REDIS_URL", "redis://localhost:6379")
  DB  = 15

  HELLO_REPLY = "%3\r\n$6\r\nserver\r\n$5\r\nredis\r\n$5\r\nproto\r\n:3\r\n$2\r\nid\r\n:1\r\n"

  # Whether a server answers at URL. Probed once, at load, with a short timeout.
  AVAILABLE = begin
    uri = URI.parse(URL)
    TCPSocket.new(uri.host || "localhost", uri.port || 6379, connect_timeout: 0.2.seconds).close
    true
  rescue
    false
  end

  # A scripted RESP server on a random loopback port. The handler runs in
  # its own fiber for every accepted connection and gets the raw socket.
  class FakeServer
    getter port : Int32
    getter accepted = 0

    def initialize(&handler : IO ->)
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.local_address.port
      spawn do
        while client = @server.accept?
          @accepted += 1
          spawn serve(client, handler)
        end
      end
    end

    private def serve(client : TCPSocket, handler : IO ->) : Nil
      handler.call(client)
    rescue IO::Error
    ensure
      client.close rescue nil
    end

    def url : String
      "redis://127.0.0.1:#{@port}"
    end

    def close : Nil
      @server.close
    end

    # Reads one client command (a RESP array of bulk strings). Returns nil at EOF.
    def self.read_command(io : IO) : Array(String)?
      value = Redis::RESP.read(io)
      value.as(Array).map(&.as(String))
    rescue IO::EOFError
      nil
    end

    # If *cmd* is HELLO, answers with `HELLO_REPLY` and returns true.
    def self.serve_hello(io : IO, cmd : Array(String)) : Bool
      return false unless cmd[0]? == "HELLO"
      io << HELLO_REPLY
      io.flush
      true
    end
  end
end

def pending_redis(description = "assert", file = __FILE__, line = __LINE__, end_line = __END_LINE__, &block)
  if RedisSpec::AVAILABLE
    it(description, file, line, end_line, &block)
  else
    pending("#{description} [no redis server at #{RedisSpec::URL}]", file, line, end_line)
  end
end

def pending_redis(*, describe, file = __FILE__, line = __LINE__, end_line = __END_LINE__, &block)
  if RedisSpec::AVAILABLE
    describe(describe, file, line, end_line, &block)
  else
    pending("#{describe} [no redis server at #{RedisSpec::URL}]", file, line, end_line)
  end
end
```

`spawn serve(client, handler)` is the call form of `spawn`: arguments are evaluated before the fiber starts, so the closure does not capture the loop variable (the stdlib uses the same idiom in `HTTP::Server`).

- [ ] **Step 4: Run the spec to verify it passes**

Run: `bin/crystal spec spec/std/redis/fake_server_spec.cr`
Expected: `2 examples, 0 failures`.

- [ ] **Step 5: Format and commit**

```bash
bin/crystal tool format spec/support/redis.cr spec/std/redis
git add spec/support/redis.cr spec/std/redis/fake_server_spec.cr
git commit -m "Redis: spec support (pending_redis, FakeServer)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 10: `Redis::Connection`

**Files:**
- Modify: `src/redis/connection.cr` (replace stub)
- Test: `spec/std/redis/connection_spec.cr`

**Interfaces:**
- Consumes: `RESP`, `Commands`, errors, `RedisSpec::FakeServer`.
- Produces:

```crystal
class Redis::Connection
  include Redis::Commands
  DEFAULT_URL = "redis://localhost:6379"
  def initialize(url : String | URI = DEFAULT_URL, *, db : Int32? = nil, username : String? = nil,
                 password : String? = nil, client_name : String? = nil, protocol : Int32 = 3,
                 connect_timeout : Time::Span = 5.seconds, read_timeout : Time::Span? = nil,
                 tls_context : OpenSSL::SSL::Context::Client? = nil, max_bulk_size : Int32 = RESP::MAX_BULK_SIZE)
  getter url : URI
  getter protocol : Int32
  property push_handler : (Array(Value) ->)?
  def socket : IO
  def send(*args : RESP::Arg) : Nil;  def send(args : Enumerable) : Nil
  def read : Value
  def call(*args : RESP::Arg) : Value;  def call(args : Enumerable) : Value
  def typed_call(args : Enumerable, &block : Value -> T) forall T   # => T
  def pipeline(commands : Enumerable) : Array(Value)
  def close : Nil;  def closed? : Bool
end
```

- [ ] **Step 1: Write the failing spec**

```crystal
# spec/std/redis/connection_spec.cr
require "spec"
require "../../support/redis"

# A fake server that speaks RESP3 for HELLO and echoes PING as +PONG.
private def echo_server(hello : Symbol = :resp3, &extra : IO, Array(String) -> Bool)
  RedisSpec::FakeServer.new do |io|
    while cmd = RedisSpec::FakeServer.read_command(io)
      case cmd[0]
      when "HELLO"
        case hello
        when :resp3   then io << RedisSpec::HELLO_REPLY
        when :unknown then io << "-ERR unknown command 'HELLO'\r\n"
        when :noproto then io << "-NOPROTO unsupported protocol version\r\n"
        end
      when "PING"
        io << (cmd[1]? ? "$#{cmd[1].bytesize}\r\n#{cmd[1]}\r\n" : "+PONG\r\n")
      else
        io << "+OK\r\n" unless extra.call(io, cmd)
      end
      io.flush
    end
  end
end

private def echo_server(hello : Symbol = :resp3)
  echo_server(hello) { |_, _| false }
end

describe Redis::Connection do
  it "negotiates RESP3 and answers commands" do
    server = echo_server
    conn = Redis::Connection.new(server.url)
    conn.protocol.should eq(3)
    conn.ping.should eq("PONG")
    conn.call("PING", "hi").should eq("hi")
    conn.close
    conn.closed?.should be_true
    server.close
  end

  it "falls back to RESP2 on ERR unknown command or NOPROTO" do
    {:unknown, :noproto}.each do |mode|
      server = echo_server(mode)
      conn = Redis::Connection.new(server.url)
      conn.protocol.should eq(2)
      conn.ping.should eq("PONG")
      conn.close
      server.close
    end
  end

  it "sends AUTH and SETNAME inside HELLO, and SELECT after" do
    seen = [] of Array(String)
    server = RedisSpec::FakeServer.new do |io|
      while cmd = RedisSpec::FakeServer.read_command(io)
        seen << cmd
        io << (cmd[0] == "HELLO" ? RedisSpec::HELLO_REPLY : "+OK\r\n")
        io.flush
      end
    end
    conn = Redis::Connection.new(server.url, username: "u", password: "p", client_name: "app", db: 3)
    conn.close
    seen.should eq([["HELLO", "3", "AUTH", "u", "p", "SETNAME", "app"], ["SELECT", "3"]])
    server.close
  end

  it "uses AUTH and CLIENT SETNAME on RESP2" do
    seen = [] of Array(String)
    server = RedisSpec::FakeServer.new do |io|
      while cmd = RedisSpec::FakeServer.read_command(io)
        seen << cmd
        io << (cmd[0] == "HELLO" ? "-ERR unknown command 'HELLO'\r\n" : "+OK\r\n")
        io.flush
      end
    end
    Redis::Connection.new(server.url, password: "p", client_name: "app").close
    seen.should eq([["HELLO", "3", "AUTH", "default", "p", "SETNAME", "app"], ["AUTH", "default", "p"], ["CLIENT", "SETNAME", "app"]])
    seen.clear
    Redis::Connection.new(server.url, protocol: 2, password: "p").close
    seen.should eq([["AUTH", "default", "p"]])
    server.close
  end

  it "parses url parts: userinfo, db path, unix scheme" do
    seen = [] of Array(String)
    server = RedisSpec::FakeServer.new do |io|
      while cmd = RedisSpec::FakeServer.read_command(io)
        seen << cmd
        io << (cmd[0] == "HELLO" ? RedisSpec::HELLO_REPLY : "+OK\r\n")
        io.flush
      end
    end
    Redis::Connection.new("redis://me:secret@127.0.0.1:#{server.port}/2").close
    seen.should eq([["HELLO", "3", "AUTH", "me", "secret"], ["SELECT", "2"]])
    server.close
    expect_raises(ArgumentError, /scheme/) { Redis::Connection.new("http://localhost") }
    expect_raises(ArgumentError, /protocol/) { Redis::Connection.new("redis://localhost", protocol: 4) }
  end

  it "raises the server's auth error" do
    server = RedisSpec::FakeServer.new do |io|
      while RedisSpec::FakeServer.read_command(io)
        io << "-WRONGPASS invalid username-password pair\r\n"
        io.flush
      end
    end
    ex = expect_raises(Redis::CommandError) { Redis::Connection.new(server.url, password: "x") }
    ex.code.should eq("WRONGPASS")
    server.close
  end

  it "raises ConnectionError when nothing listens" do
    server = RedisSpec::FakeServer.new { }
    port = server.port
    server.close
    expect_raises(Redis::ConnectionError) { Redis::Connection.new("redis://127.0.0.1:#{port}", connect_timeout: 1.second) }
  end

  it "raises CommandError on error replies and keeps the connection usable" do
    server = echo_server { |io, cmd| cmd[0] == "BAD" && (io << "-WRONGTYPE nope\r\n"; true) }
    conn = Redis::Connection.new(server.url)
    expect_raises(Redis::CommandError, /WRONGTYPE/) { conn.call("BAD") }
    conn.ping.should eq("PONG")
    conn.close
    server.close
  end

  it "pipeline sends all then reads all, keeping errors as values" do
    server = echo_server { |io, cmd| cmd[0] == "BAD" && (io << "-ERR x\r\n"; true) }
    conn = Redis::Connection.new(server.url)
    results = conn.pipeline([["PING"], ["BAD"], ["PING", "z"]])
    results[0].should eq("PONG")
    results[1].as(Redis::CommandError).code.should eq("ERR")
    results[2].should eq("z")
    conn.close
    server.close
  end

  it "turns a dropped connection into ConnectionError and closes" do
    server = RedisSpec::FakeServer.new do |io|
      cmd = RedisSpec::FakeServer.read_command(io)
      RedisSpec::FakeServer.serve_hello(io, cmd.not_nil!)
      RedisSpec::FakeServer.read_command(io)
      io.close
    end
    conn = Redis::Connection.new(server.url)
    expect_raises(Redis::ConnectionError) { conn.ping }
    conn.closed?.should be_true
    expect_raises(Redis::ConnectionError) { conn.ping }
    server.close
  end

  it "applies read_timeout to read and closes on timeout" do
    server = RedisSpec::FakeServer.new do |io|
      cmd = RedisSpec::FakeServer.read_command(io)
      RedisSpec::FakeServer.serve_hello(io, cmd.not_nil!)
      RedisSpec::FakeServer.read_command(io)
      sleep 2.seconds
    end
    conn = Redis::Connection.new(server.url, read_timeout: 50.milliseconds)
    expect_raises(IO::TimeoutError) { conn.ping }
    conn.closed?.should be_true
    server.close
  end

  it "routes push frames to push_handler" do
    server = echo_server { |io, cmd| cmd[0] == "PUSHY" && (io << ">2\r\n+message\r\n+hello\r\n+OK\r\n"; true) }
    conn = Redis::Connection.new(server.url)
    pushes = [] of Array(Redis::Value)
    conn.push_handler = ->(p : Array(Redis::Value)) { pushes << p }
    conn.call("PUSHY").should eq("OK")
    pushes.should eq([["message", "hello"] of Redis::Value])
    conn.close
    server.close
  end

  it "connects over a unix socket" do
    path = File.tempname("redis-spec", ".sock")
    unix = UNIXServer.new(path)
    spawn do
      if client = unix.accept?
        while cmd = RedisSpec::FakeServer.read_command(client)
          client << (cmd[0] == "HELLO" ? RedisSpec::HELLO_REPLY : "+PONG\r\n")
          client.flush
        end
      end
    end
    conn = Redis::Connection.new("redis+unix://#{path}")
    conn.ping.should eq("PONG")
    conn.close
    unix.close
    File.delete?(path)
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/crystal spec spec/std/redis/connection_spec.cr`
Expected: `undefined method 'new'` / missing initialize args.

- [ ] **Step 3: Write the connection**

```crystal
# src/redis/connection.cr
module Redis
  # One socket to one server, used by one fiber at a time.
  #
  # Connects and negotiates the protocol in `new` (`HELLO 3`, falling back
  # to RESP2 when the server does not support it). Use it directly for
  # blocking commands (`BLPOP`, `WAIT`, ...) that must not share a
  # multiplexed `Client`, or as the substrate that `Client` drives.
  #
  # ```
  # conn = Redis::Connection.new("redis://localhost:6379/0")
  # conn.call("BLPOP", "queue", 0) # => ["queue", "job"]
  # conn.close
  # ```
  #
  # URL forms: `redis://[user[:pass]@]host[:port][/db]`, `rediss://...`
  # (TLS), `redis+unix:///path[?db=N]`, `unix:///path`. Keyword options
  # override URL parts.
  class Connection
    include Commands

    DEFAULT_URL = "redis://localhost:6379"

    # The parsed server URL.
    getter url : URI
    # The negotiated protocol version, 2 or 3.
    getter protocol : Int32
    # Receives RESP3 push frames (`>`) as they are read. Unused in slice 1
    # unless the server sends pushes; pub/sub builds on it.
    property push_handler : (Array(Value) ->)?

    @socket : IO
    @closed = false

    def initialize(url : String | URI = DEFAULT_URL, *, db : Int32? = nil, username : String? = nil,
                   password : String? = nil, client_name : String? = nil, protocol : Int32 = 3,
                   connect_timeout : Time::Span = 5.seconds, read_timeout : Time::Span? = nil,
                   tls_context : OpenSSL::SSL::Context::Client? = nil, max_bulk_size : Int32 = RESP::MAX_BULK_SIZE)
      raise ArgumentError.new("protocol must be 2 or 3, got #{protocol}") unless protocol == 2 || protocol == 3
      @url = url.is_a?(URI) ? url : URI.parse(url)
      @protocol = protocol
      @max_bulk_size = max_bulk_size
      @db = db || Connection.db_from(@url)
      @username = username || @url.user.presence
      @password = password || @url.password.presence
      @socket = Connection.open_socket(@url, connect_timeout, read_timeout, tls_context)
      begin
        handshake(client_name)
      rescue ex
        @socket.close rescue nil
        @closed = true
        raise ex
      end
    end

    # :nodoc:
    def self.db_from(url : URI) : Int32?
      if db = url.query_params["db"]?
        return db.to_i
      end
      path = url.path
      return nil if path.empty? || path == "/"
      path.lchop('/').to_i? || raise ArgumentError.new("invalid database in URL path #{path.inspect}")
    end

    # :nodoc:
    def self.open_socket(url : URI, connect_timeout : Time::Span, read_timeout : Time::Span?,
                         tls_context : OpenSSL::SSL::Context::Client?) : IO
      case url.scheme
      when "redis", "rediss"
        host = url.host.presence || "localhost"
        port = url.port || 6379
        tcp = TCPSocket.new(host, port, connect_timeout: connect_timeout)
        tcp.tcp_nodelay = true
        tcp.sync = false
        tcp.read_timeout = read_timeout if read_timeout
        if url.scheme == "rediss"
          context = tls_context || OpenSSL::SSL::Context::Client.new
          ssl = OpenSSL::SSL::Socket::Client.new(tcp, context: context, sync_close: true, hostname: host)
          ssl.sync = false
          ssl
        else
          tcp
        end
      when "redis+unix", "unix"
        sock = UNIXSocket.new(url.path)
        sock.sync = false
        sock.read_timeout = read_timeout if read_timeout
        sock
      else
        raise ArgumentError.new("unsupported URL scheme #{url.scheme.inspect}; expected redis, rediss or redis+unix")
      end
    rescue ex : IO::Error | Socket::Error
      raise ConnectionError.new("failed to connect to #{url}: #{ex.message}", cause: ex)
    end

    private def handshake(client_name : String?) : Nil
      if @protocol == 3
        args = Array(RESP::Arg).new(7)
        args << "HELLO" << "3"
        if password = @password
          args << "AUTH" << (@username || "default") << password
        end
        args << "SETNAME" << client_name if client_name
        begin
          reply = call(args)
          if proto = reply.as?(Hash).try(&.["proto"]?).as?(Int64)
            @protocol = proto.to_i
          end
        rescue ex : CommandError
          fallback = ex.code == "NOPROTO" || (ex.code == "ERR" && ex.message.to_s.includes?("unknown command"))
          raise ex unless fallback
          @protocol = 2
        end
      end
      if @protocol == 2
        if password = @password
          call({"AUTH", @username || "default", password})
        end
        call({"CLIENT", "SETNAME", client_name}) if client_name
      end
      if (db = @db) && db != 0
        call({"SELECT", db})
      end
    end

    # The underlying socket. `Client` reads and writes it from its fibers;
    # nobody else should.
    def socket : IO
      @socket
    end

    # Encodes and flushes one command without reading the reply.
    def send(*args : RESP::Arg) : Nil
      send(args)
    end

    # :ditto:
    def send(args : Enumerable) : Nil
      check_open
      RESP.write_command(@socket, args)
      @socket.flush
    rescue ex : IO::Error
      fail(ex)
    end

    # Reads one reply. Raises `CommandError` for an error reply.
    def read : Value
      check_open
      value = RESP.read(@socket, max_bulk_size: @max_bulk_size, push: @push_handler)
      raise value if value.is_a?(CommandError)
      value
    rescue ex : IO::TimeoutError
      close
      raise ex
    rescue ex : IO::Error
      fail(ex)
    end

    # Sends *args* and returns the reply. Raises `CommandError` for an
    # error reply. Blocking commands are fine here.
    def call(*args : RESP::Arg) : Value
      call(args)
    end

    # :ditto:
    def call(args : Enumerable) : Value
      send(args)
      read
    end

    # :nodoc:
    def typed_call(args : Enumerable, &block : Value -> T) forall T
      block.call(call(args))
    end

    # Sends every command in *commands*, flushes once, then reads every
    # reply in order. Error replies are returned as `CommandError` values.
    def pipeline(commands : Enumerable) : Array(Value)
      check_open
      count = 0
      commands.each do |command|
        RESP.write_command(@socket, command)
        count += 1
      end
      @socket.flush
      Array(Value).new(count) { RESP.read(@socket, max_bulk_size: @max_bulk_size, push: @push_handler) }
    rescue ex : IO::TimeoutError
      close
      raise ex
    rescue ex : IO::Error
      fail(ex)
    end

    # Closes the socket. Every later call raises `ConnectionError`.
    def close : Nil
      return if @closed
      @closed = true
      @socket.close rescue nil
    end

    def closed? : Bool
      @closed
    end

    private def check_open : Nil
      raise ConnectionError.new("connection is closed") if @closed
    end

    private def fail(ex : IO::Error) : NoReturn
      close
      raise ConnectionError.new("connection lost: #{ex.message}", cause: ex)
    end
  end
end
```

Implementation notes:
- `Socket::ConnectError` is an `IO::Error` subclass, so the single `rescue ex : IO::Error` in `open_socket` covers connect refusals; drop the `| Socket::Error` if the formatter or compiler complains about redundancy.
- Sockets default to `sync = true` (every write is a syscall); `sync = false` is what makes `pipeline` and the `Client` writer batch. `IO#read_timeout=` accepts a `Time::Span`.
- `OpenSSL::SSL::Socket` includes `IO::Buffered`, so `ssl.sync = false` is valid.
- `call(args)` inside `handshake` receives an `Array(RESP::Arg)` or a tuple; both are `Enumerable`.
- A `CommandError` from `read` passes through `rescue ex : IO::Error` untouched because it is not an `IO::Error`.
- `scan_each` on a `Connection` works as written in Task 6 since `typed_call` returns `T`.

- [ ] **Step 4: Run the spec to verify it passes**

Run: `bin/crystal spec spec/std/redis/connection_spec.cr`
Expected: all pass. The timeout example takes ~50 ms; the fake server's `sleep 2.seconds` fiber ends when the spec process exits.

- [ ] **Step 5: Format and commit**

```bash
bin/crystal tool format src/redis spec/std/redis
git add src/redis/connection.cr spec/std/redis/connection_spec.cr
git commit -m "Redis: Connection with HELLO negotiation and RESP2 fallback

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 11: `Redis::Pipeline` and `Redis::Future(T)`

**Files:**
- Modify: `src/redis/pipeline.cr` (replace stub)
- Test: `spec/std/redis/pipeline_spec.cr`

**Interfaces:**
- Consumes: `Commands`, `RESP.write_command`.
- Produces:

```crystal
abstract class Redis::AbstractFuture
  abstract def resolve(raw : Value | Exception) : Nil
end
class Redis::Future(T) < Redis::AbstractFuture
  def initialize(@mapper : Proc(Value, T))
  def resolved? : Bool
  def value : T        # ArgumentError if unresolved; raises the Exception if resolved to one; ProtocolError from the mapper
  def value? : T?      # nil when unresolved or resolved to an Exception
end
class Redis::Pipeline
  include Redis::Commands
  def size : Int32
  def buffer : IO::Memory                                   # encoded commands
  def call(args : Enumerable) : Future(Value);  def call(*args : RESP::Arg) : Future(Value)
  def typed_call(args : Enumerable, &block : Value -> T) : Future(T) forall T
  def resolve(index : Int32, raw : Value | Exception) : Nil  # used by Client
  def scan_each(**opts, &) : NoReturn                       # ArgumentError
end
```

- [ ] **Step 1: Write the failing spec**

```crystal
# spec/std/redis/pipeline_spec.cr
require "spec"
require "redis"

describe Redis::Pipeline do
  it "records commands into one buffer and hands out futures" do
    p = Redis::Pipeline.new
    f1 = p.set("a", "1")
    f2 = p.get("a")
    f3 = p.incr("n")
    f4 = p.command("CLIENT", "ID")
    p.size.should eq(4)
    p.buffer.to_s.should eq(
      "*3\r\n$3\r\nSET\r\n$1\r\na\r\n$1\r\n1\r\n*2\r\n$3\r\nGET\r\n$1\r\na\r\n*2\r\n$4\r\nINCR\r\n$1\r\nn\r\n*2\r\n$6\r\nCLIENT\r\n$2\r\nID\r\n")
    f1.should be_a(Redis::Future(String?))
    f2.should be_a(Redis::Future(String?))
    f3.should be_a(Redis::Future(Int64))
    f4.should be_a(Redis::Future(Redis::Value))
    f1.resolved?.should be_false
    expect_raises(ArgumentError, /not executed/) { f1.value }
    f1.value?.should be_nil

    p.resolve(0, "OK")
    p.resolve(1, "1")
    p.resolve(2, 1_i64)
    p.resolve(3, 42_i64)
    f1.value.should eq("OK")
    f2.value.should eq("1")
    f3.value.should eq(1_i64)
    f4.value.should eq(42_i64)
  end

  it "raises the exception a future was resolved to" do
    p = Redis::Pipeline.new
    f = p.get("a")
    p.resolve(0, Redis::CommandError.new("WRONGTYPE nope"))
    f.resolved?.should be_true
    f.value?.should be_nil
    expect_raises(Redis::CommandError, /WRONGTYPE/) { f.value }
  end

  it "applies the cast at resolution time" do
    p = Redis::Pipeline.new
    f = p.incr("n")
    p.resolve(0, "not an int")
    expect_raises(Redis::ProtocolError) { f.value }
  end

  it "refuses scan_each" do
    expect_raises(ArgumentError) { Redis::Pipeline.new.scan_each { } }
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/crystal spec spec/std/redis/pipeline_spec.cr`
Expected: `undefined method 'set'` / `undefined constant Redis::Future`.

- [ ] **Step 3: Write the file**

```crystal
# src/redis/pipeline.cr
module Redis
  # :nodoc:
  abstract class AbstractFuture
    abstract def resolve(raw : Value | Exception) : Nil
  end

  # The pending result of a command issued inside `Client#pipelined`.
  # Typed command methods on a `Pipeline` return one of these; read it with
  # `value` after the block has run.
  class Future(T) < AbstractFuture
    @raw : Value | Exception = nil
    @resolved = false

    def initialize(@mapper : Proc(Value, T))
    end

    # :nodoc:
    def resolve(raw : Value | Exception) : Nil
      @raw = raw
      @resolved = true
    end

    # Whether the pipeline that owns this future has executed.
    def resolved? : Bool
      @resolved
    end

    # The typed reply. Raises `ArgumentError` before the pipeline executes,
    # the `CommandError` or `ConnectionError` the command failed with, or
    # `ProtocolError` if the reply has an unexpected shape.
    def value : T
      raise ArgumentError.new("pipeline not executed yet") unless @resolved
      raw = @raw
      raise raw if raw.is_a?(Exception)
      @mapper.call(raw)
    end

    # Like `value`, but `nil` when unresolved or failed.
    def value? : T?
      return nil unless @resolved
      raw = @raw
      return nil if raw.is_a?(Exception)
      @mapper.call(raw)
    end
  end

  # Collects commands inside `Client#pipelined`. Every typed command
  # method returns a `Future(T)` instead of `T`.
  class Pipeline
    include Commands

    # Number of queued commands.
    getter size = 0
    # The encoded commands, appended to the client's outbound buffer.
    getter buffer = IO::Memory.new
    @futures = [] of AbstractFuture

    # Queues *args* and returns a future for its raw reply.
    def call(*args : RESP::Arg) : Future(Value)
      call(args)
    end

    # :ditto:
    def call(args : Enumerable) : Future(Value)
      typed_call(args) { |v| v }
    end

    # :nodoc:
    def typed_call(args : Enumerable, &block : Value -> T) : Future(T) forall T
      RESP.write_command(@buffer, args)
      future = Future(T).new(block)
      @futures << future
      @size += 1
      future
    end

    # :nodoc:
    def resolve(index : Int32, raw : Value | Exception) : Nil
      @futures[index].resolve(raw)
    end

    # Not available on a pipeline: iteration needs each cursor reply
    # before issuing the next command.
    def scan_each(*, match : String? = nil, count : Int? = nil, type : String? = nil, &) : NoReturn
      raise ArgumentError.new("scan_each is not available on a pipeline")
    end
  end
end
```

- [ ] **Step 4: Run the spec to verify it passes**

Run: `bin/crystal spec spec/std/redis/pipeline_spec.cr`
Expected: `4 examples, 0 failures`.

- [ ] **Step 5: Format and commit**

```bash
bin/crystal tool format src/redis spec/std/redis
git add src/redis/pipeline.cr spec/std/redis/pipeline_spec.cr
git commit -m "Redis: Pipeline and Future

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 12: `Redis::Client` multiplexer

**Files:**
- Modify: `src/redis/client.cr` (replace stub)
- Test: `spec/std/redis/client_spec.cr`

**Interfaces:**
- Consumes: `Connection` (Task 10), `Pipeline`/`Future` (Task 11), `RedisSpec::FakeServer`.
- Produces:

```crystal
class Redis::Client
  include Redis::Commands
  def initialize(url : String | URI = Connection::DEFAULT_URL, *, db : Int32? = nil, username : String? = nil,
                 password : String? = nil, client_name : String? = nil, protocol : Int32 = 3,
                 connect_timeout : Time::Span = 5.seconds, read_timeout : Time::Span? = nil,
                 tls_context : OpenSSL::SSL::Context::Client? = nil, max_bulk_size : Int32 = RESP::MAX_BULK_SIZE)
  def call(*args : RESP::Arg) : Value;  def call(args : Enumerable) : Value
  def typed_call(args : Enumerable, &block : Value -> T) forall T   # => T
  def pipelined(& : Pipeline ->) : Array(Value)
  def protocol : Int32?;  def connected? : Bool
  property push_handler : (Array(Value) ->)?
  def close : Nil;  def closed? : Bool
end
```

- [ ] **Step 1: Write the failing spec**

```crystal
# spec/std/redis/client_spec.cr
require "spec"
require "../../support/redis"

# Fake server: HELLO → RESP3, PING → +PONG or the echoed arg, INCR → :1,
# HANG → never reply, DIE → close socket, BAD → -ERR, PUSHY → push then +OK.
# `chunks` records how many commands each socket read returned.
private class Script
  getter chunks = [] of Int32
  getter connections = 0

  def server
    RedisSpec::FakeServer.new do |io|
      @connections += 1
      buffer = Bytes.new(65536)
      loop do
        n = io.read(buffer)
        break if n == 0
        mem = IO::Memory.new(buffer[0, n])
        count = 0
        while cmd = RedisSpec::FakeServer.read_command(mem)
          count += 1
          case cmd[0]
          when "HELLO" then io << RedisSpec::HELLO_REPLY
          when "PING"  then io << (cmd[1]? ? "$#{cmd[1].bytesize}\r\n#{cmd[1]}\r\n" : "+PONG\r\n")
          when "INCR"  then io << ":1\r\n"
          when "BAD"   then io << "-ERR bad\r\n"
          when "PUSHY" then io << ">2\r\n+message\r\n+hi\r\n+OK\r\n"
          when "DESYNC" then io << "+OK\r\n+EXTRA\r\n"
          when "HANG"  then nil
          when "DIE"   then io.close; break
          else              io << "+OK\r\n"
          end
        end
        @chunks << count if count > 0
        break if io.closed?
        io.flush
      end
    end
  end
end

describe Redis::Client do
  it "connects lazily on first call and answers" do
    script = Script.new
    server = script.server
    client = Redis::Client.new(server.url)
    client.connected?.should be_false
    client.protocol.should be_nil
    client.ping.should eq("PONG")
    client.connected?.should be_true
    client.protocol.should eq(3)
    client.call("PING", "x").should eq("x")
    client.command("PING", "y").should eq("y")
    script.connections.should eq(1)
    client.close
    client.closed?.should be_true
    expect_raises(Redis::ConnectionError, /closed/) { client.ping }
    server.close
  end

  it "batches commands from concurrent fibers into one write" do
    script = Script.new
    server = script.server
    client = Redis::Client.new(server.url)
    client.ping
    script.chunks.clear
    done = Channel(Int64).new
    32.times { spawn { done.send(client.incr("n")) } }
    32.times { done.receive.should eq(1_i64) }
    script.chunks.sum.should eq(32)
    script.chunks.max.should be > 1
    client.close
    server.close
  end

  it "raises CommandError for error replies and keeps working" do
    server = Script.new.server
    client = Redis::Client.new(server.url)
    expect_raises(Redis::CommandError, /bad/) { client.call("BAD") }
    client.ping.should eq("PONG")
    client.close
    server.close
  end

  it "fails every pending caller when the connection drops, then reconnects" do
    script = Script.new
    server = script.server
    client = Redis::Client.new(server.url)
    client.ping
    errors = Channel(Exception?).new
    3.times do
      spawn do
        begin
          client.call("HANG")
          errors.send(nil)
        rescue ex
          errors.send(ex)
        end
      end
    end
    spawn { client.call("DIE") rescue nil }
    3.times { errors.receive.should be_a(Redis::ConnectionError) }
    client.connected?.should be_false
    client.ping.should eq("PONG")
    script.connections.should eq(2)
    client.close
    server.close
  end

  it "enforces read_timeout per command and tears the connection down" do
    script = Script.new
    server = script.server
    client = Redis::Client.new(server.url, read_timeout: 50.milliseconds)
    expect_raises(IO::TimeoutError) { client.call("HANG") }
    client.connected?.should be_false
    client.ping.should eq("PONG")
    script.connections.should eq(2)
    client.close
    server.close
  end

  it "treats an unsolicited reply as a protocol desync" do
    server = Script.new.server
    client = Redis::Client.new(server.url)
    client.call("DESYNC").should eq("OK")
    # the extra +EXTRA reply arrives with no waiter: the reader disconnects
    sleep 0.05.seconds
    client.connected?.should be_false
    client.ping.should eq("PONG")
    client.close
    server.close
  end

  it "routes push frames to push_handler without consuming a waiter" do
    server = Script.new.server
    client = Redis::Client.new(server.url)
    pushes = [] of Array(Redis::Value)
    client.push_handler = ->(p : Array(Redis::Value)) { pushes << p }
    client.call("PUSHY").should eq("OK")
    pushes.should eq([["message", "hi"] of Redis::Value])
    client.close
    server.close
  end

  it "pipelined sends once, resolves futures and returns raw values" do
    script = Script.new
    server = script.server
    client = Redis::Client.new(server.url)
    client.ping
    script.chunks.clear
    f = nil
    results = client.pipelined do |p|
      p.ping
      f = p.incr("n")
      p.call("BAD")
      p.ping("z")
    end
    results.size.should eq(4)
    results[0].should eq("PONG")
    results[1].should eq(1_i64)
    results[2].as(Redis::CommandError).code.should eq("ERR")
    results[3].should eq("z")
    f.not_nil!.value.should eq(1_i64)
    script.chunks.should eq([4])
    client.pipelined { |p| }.should eq([] of Redis::Value)
    client.close
    server.close
  end

  it "pipelined raises ConnectionError when the connection drops mid-pipeline" do
    server = Script.new.server
    client = Redis::Client.new(server.url)
    client.ping
    f = nil
    expect_raises(Redis::ConnectionError) do
      client.pipelined do |p|
        f = p.ping
        p.call("DIE")
      end
    end
    f.not_nil!.resolved?.should be_true
    client.close
    server.close
  end

  it "raises ConnectionError from connect failures and stays usable" do
    server = RedisSpec::FakeServer.new { }
    port = server.port
    server.close
    client = Redis::Client.new("redis://127.0.0.1:#{port}", connect_timeout: 1.second)
    expect_raises(Redis::ConnectionError) { client.ping }
    client.closed?.should be_false
    client.close
  end
end
```

`HANG` never answers, so the three pending callers only complete when `DIE` closes the socket (or when `read_timeout` fires); replies are flushed per chunk, and a chunk containing `DIE` is never flushed. The `sleep 0.05.seconds` in the desync example is ordinary Crystal `sleep` inside the spec binary (the "no foreground sleep" rule is about the Bash tool).

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/crystal spec spec/std/redis/client_spec.cr`
Expected: `undefined method` errors on `Redis::Client`.

- [ ] **Step 3: Write the client**

```crystal
# src/redis/client.cr
module Redis
  # A multiplexed connection shared by any number of fibers.
  #
  # Commands from concurrent fibers are written by one writer fiber, which
  # flushes everything that accumulated while the previous flush was in
  # progress, so pipelining happens automatically under load. A reader fiber
  # delivers replies in order. The socket is opened on the first call and
  # reopened lazily after a failure; commands in flight when a connection
  # drops raise `ConnectionError` and are not retried.
  #
  # ```
  # redis = Redis::Client.new("redis://localhost:6379/0")
  # redis.set("greeting", "hello", ex: 60)
  # redis.get("greeting") # => "hello"
  # 64.times { spawn { redis.incr("hits") } }
  # ```
  #
  # `call` accepts any command, including blocking ones, but a blocking
  # command holds up every other caller until it returns; use a dedicated
  # `Connection` for those.
  class Client
    include Commands

    private class Waiter
      getter channel = Channel(Value | Exception).new(1)
    end

    # Receives RESP3 push frames. Set before the first call, or it applies
    # from the next reconnect.
    property push_handler : (Array(Value) ->)?

    @mutex = Mutex.new
    @connection : Connection?
    @wakeup = Channel(Nil).new(1)
    @out = IO::Memory.new
    @spare = IO::Memory.new
    @pending = Deque(Waiter).new
    @waiter_pool = Deque(Waiter).new
    @closed = false

    def initialize(url : String | URI = Connection::DEFAULT_URL, *, @db : Int32? = nil, @username : String? = nil,
                   @password : String? = nil, @client_name : String? = nil, protocol @protocol_option : Int32 = 3,
                   @connect_timeout : Time::Span = 5.seconds, @read_timeout : Time::Span? = nil,
                   @tls_context : OpenSSL::SSL::Context::Client? = nil, @max_bulk_size : Int32 = RESP::MAX_BULK_SIZE)
      @url = url.is_a?(URI) ? url : URI.parse(url)
      raise ArgumentError.new("protocol must be 2 or 3, got #{@protocol_option}") unless @protocol_option == 2 || @protocol_option == 3
    end

    # The negotiated protocol version, or `nil` while disconnected.
    def protocol : Int32?
      @connection.try &.protocol
    end

    # Whether a connection is currently open.
    def connected? : Bool
      !@connection.nil?
    end

    def closed? : Bool
      @closed
    end

    # Sends *args* and returns the reply. Raises `CommandError` for an
    # error reply, `ConnectionError` if the connection cannot be opened or
    # drops, `IO::TimeoutError` if `read_timeout` elapses.
    def call(*args : RESP::Arg) : Value
      call(args)
    end

    # :ditto:
    def call(args : Enumerable) : Value
      waiter, wakeup = @mutex.synchronize do
        check_open
        ensure_connected
        RESP.write_command(@out, args)
        w = take_waiter
        @pending.push(w)
        {w, @wakeup}
      end
      signal(wakeup)
      result = wait(waiter)
      raise result if result.is_a?(Exception)
      result
    end

    # :nodoc:
    def typed_call(args : Enumerable, &block : Value -> T) forall T
      block.call(call(args))
    end

    # Runs the block against a `Pipeline`, sends every queued command in a
    # single write, and returns the raw replies in order. Error replies
    # stay in the array as `CommandError` values (and are raised by the
    # corresponding `Future#value`); a lost connection raises
    # `ConnectionError` after every future has been resolved.
    #
    # ```
    # first = nil
    # redis.pipelined do |p|
    #   p.set("a", "1")
    #   first = p.get("a")
    # end
    # first.not_nil!.value # => "1"
    # ```
    def pipelined(& : Pipeline ->) : Array(Value)
      pipeline = Pipeline.new
      yield pipeline
      return [] of Value if pipeline.size == 0
      waiters = Array(Waiter).new(pipeline.size)
      wakeup = @mutex.synchronize do
        check_open
        ensure_connected
        @out.write(pipeline.buffer.to_slice)
        pipeline.size.times do
          w = take_waiter
          @pending.push(w)
          waiters << w
        end
        @wakeup
      end
      signal(wakeup)
      results = Array(Value).new(waiters.size)
      failure = nil
      waiters.each_with_index do |waiter, i|
        raw = wait(waiter)
        pipeline.resolve(i, raw)
        case raw
        when ConnectionError then failure ||= raw
        when Exception       then results << raw.as(CommandError)
        else                      results << raw
        end
      end
      raise failure if failure
      results
    end

    # Closes the connection; pending commands raise `ConnectionError`, and
    # every later call raises too.
    def close : Nil
      conn = @mutex.synchronize do
        @closed = true
        @connection
      end
      disconnect(conn, nil) if conn
    end

    private def check_open : Nil
      raise ConnectionError.new("client is closed") if @closed
    end

    # Under @mutex.
    private def ensure_connected : Connection
      @connection || connect
    end

    # Under @mutex.
    private def connect : Connection
      conn = Connection.new(@url, db: @db, username: @username, password: @password, client_name: @client_name,
        protocol: @protocol_option, connect_timeout: @connect_timeout, read_timeout: nil,
        tls_context: @tls_context, max_bulk_size: @max_bulk_size)
      conn.push_handler = @push_handler
      wakeup = Channel(Nil).new(1)
      @connection = conn
      @wakeup = wakeup
      @out.clear
      @spare.clear
      spawn(name: "redis-writer") { write_loop(conn, wakeup) }
      spawn(name: "redis-reader") { read_loop(conn) }
      conn
    end

    # Under @mutex.
    private def take_waiter : Waiter
      @waiter_pool.pop? || Waiter.new
    end

    private def signal(wakeup : Channel(Nil)) : Nil
      select
      when wakeup.send(nil)
      else
      end
    rescue Channel::ClosedError
    end

    # Blocks until the reader or a disconnect delivers into *waiter*.
    # A waiter that timed out is abandoned (its channel will still receive
    # the disconnect error), so only clean completions return to the pool.
    private def wait(waiter : Waiter) : Value | Exception
      result = if deadline = @read_timeout
                 select
                 when r = waiter.channel.receive
                   r
                 when timeout(deadline)
                   conn = @connection
                   disconnect(conn, IO::TimeoutError.new("Redis command timed out after #{deadline}")) if conn
                   raise IO::TimeoutError.new("Redis command timed out after #{deadline}")
                 end
               else
                 waiter.channel.receive
               end
      @mutex.synchronize { @waiter_pool.push(waiter) }
      result
    end

    private def write_loop(conn : Connection, wakeup : Channel(Nil)) : Nil
      socket = conn.socket
      while wakeup.receive?
        full = @mutex.synchronize do
          if @connection.same?(conn) && !@out.empty?
            @out, @spare = @spare, @out
            @spare
          end
        end
        next unless full
        begin
          socket.write(full.to_slice)
          socket.flush
        rescue ex : IO::Error
          disconnect(conn, ex)
          return
        end
        full.clear
      end
    end

    private def read_loop(conn : Connection) : Nil
      socket = conn.socket
      loop do
        value = RESP.read(socket, max_bulk_size: @max_bulk_size, push: @push_handler)
        waiter = @mutex.synchronize { @pending.shift? }
        raise ProtocolError.new("unsolicited reply #{value.inspect}") unless waiter
        waiter.channel.send(value)
      end
    rescue ex : IO::Error | ProtocolError
      disconnect(conn, ex)
    end

    # Tears down *conn* if it is still the current connection: fails every
    # pending waiter, drops unsent bytes, and lets both fibers exit. Safe to
    # call from any fiber, idempotent per connection.
    private def disconnect(conn : Connection, cause : Exception?) : Nil
      waiters = @mutex.synchronize do
        next nil unless @connection.same?(conn)
        @connection = nil
        @out.clear
        @spare.clear
        @wakeup.close
        drained = @pending.to_a
        @pending.clear
        drained
      end
      return unless waiters
      conn.close
      error = ConnectionError.new(cause ? "connection lost: #{cause.message}" : "client closed", cause: cause)
      waiters.each { |w| w.channel.send(error) }
    end
  end
end
```

Implementation notes:
- `Deque#to_a` exists; `@pending.clear` after copying.
- `full.clear` after a successful write runs outside the mutex; only the writer touches `@spare`'s contents between swaps, and swaps happen under the mutex in this same fiber.
- `protocol @protocol_option` gives the keyword its public name `protocol:` while the ivar avoids clashing with the `protocol` reader.
- In `wait`, the timed-out waiter is not returned to the pool: the `raise` skips the `@waiter_pool.push`. That is intentional (see spec §5.3).
- The `select ... else` in `signal` is a non-blocking send; the `rescue Channel::ClosedError` covers a wakeup channel closed by a concurrent disconnect.
- The `push_handler=` setter only affects future connections; the spec sets it before the first call. Document that in the property comment (already done above).
- `pipelined` with a `ConnectionError` still receives every waiter so none leaks a stale delivery.
- `DESYNC` spec: the reader gets `+EXTRA` with an empty pending queue, raises `ProtocolError`, disconnects. The spec sleeps 50 ms to let the reader fiber run before asserting; with the scheduler being cooperative the reader has run by then.

- [ ] **Step 4: Run the spec to verify it passes**

Run: `bin/crystal spec spec/std/redis/client_spec.cr`
Expected: `10 examples, 0 failures`. If the batching example is flaky, widen the `32` to `64`; the fibers are spawned before the writer gets a turn, so all commands land in one write on the single-threaded scheduler.

- [ ] **Step 5: Format and commit**

```bash
bin/crystal tool format src/redis spec/std/redis
git add src/redis/client.cr spec/std/redis/client_spec.cr
git commit -m "Redis: multiplexed Client with writer/reader fibers and lazy reconnect

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 13: Live integration specs (RESP3 and RESP2)

**Files:**
- Create: `spec/std/redis/live_spec.cr`

**Interfaces:**
- Consumes: everything above, `pending_redis`, `RedisSpec::URL`, `RedisSpec::DB`.
- Produces: a live suite that is pending without a server. Requires a local server for the green run: start one with

```bash
redis-server --daemonize yes --save "" --appendonly no --port 6379
```

(Homebrew's `redis-server` is Valkey; it answers `HELLO 3`.) Stop it afterwards with `redis-cli shutdown nosave`.

- [ ] **Step 1: Write the spec**

```crystal
# spec/std/redis/live_spec.cr
require "spec"
require "../../support/redis"

# Opens a client on the spec database, flushes it, yields, closes.
private def with_redis(protocol : Int32, &block : Redis::Client ->)
  client = Redis::Client.new(RedisSpec::URL, db: RedisSpec::DB, protocol: protocol)
  begin
    client.flushdb
    block.call(client)
  ensure
    client.close
  end
end

private def live_command_specs(protocol : Int32)
  describe "Redis live commands (RESP#{protocol})" do
    pending_redis "negotiates the requested protocol" do
      with_redis(protocol) do |r|
        r.ping.should eq("PONG")
        r.protocol.should eq(protocol)
      end
    end

    pending_redis "strings" do
      with_redis(protocol) do |r|
        r.set("k", "v").should eq("OK")
        r.get("k").should eq("v")
        r.get("missing").should be_nil
        r.set("k", "w", nx: true).should be_nil
        r.set("k", "w", get: true).should eq("v")
        r.set("t", "1", ex: 100.seconds).should eq("OK")
        r.ttl("t").should be > 90
        r.setex("t2", 10, "x")
        r.pttl("t2").should be > 5000
        r.mset({"a" => "1", "b" => "2"})
        r.mget("a", "b", "zz").should eq(["1", "2", nil])
        r.incr("n").should eq(1_i64)
        r.incrby("n", 4).should eq(5_i64)
        r.incrbyfloat("n", 0.5).should eq(5.5)
        r.decr("n2").should eq(-1_i64)
        r.append("k", "!!").should eq(3_i64)
        r.strlen("k").should eq(3_i64)
        r.getrange("k", 0, 0).should eq("w")
        r.setrange("k", 1, "XY").should eq(3_i64)
        r.getset("k", "new").should eq("wXY")
        r.getdel("k").should eq("new")
        r.exists("k").should eq(0_i64)
        r.set("bin", Bytes[0, 1, 255])
        r.get("bin").not_nil!.to_slice.should eq(Bytes[0, 1, 255])
      end
    end

    pending_redis "keys" do
      with_redis(protocol) do |r|
        r.set("a", "1")
        r.set("b", "2")
        r.type("a").should eq("string")
        r.type("nope").should eq("none")
        r.rename("a", "c")
        r.renamenx("c", "b").should be_false
        r.keys("*").sort.should eq(["b", "c"])
        r.expire("b", 100).should be_true
        r.persist("b").should be_true
        r.ttl("b").should eq(-1_i64)
        r.pexpire("b", 100.seconds, nx: true).should be_true
        r.expireat("c", Time.utc.to_unix + 100).should be_true
        r.pexpireat("c", (Time.utc.to_unix + 200) * 1000, gt: true).should be_true
        seen = [] of String
        r.scan_each(match: "*", count: 1) { |k| seen << k }
        seen.sort.should eq(["b", "c"])
        cursor, keys = r.scan("0", count: 100)
        cursor.should eq("0")
        keys.sort.should eq(["b", "c"])
        r.del("b", "c").should eq(2_i64)
        r.unlink("b").should eq(0_i64)
        r.dbsize.should eq(0_i64)
        r.info("server").has_key?("redis_version").should be_true
        r.time[0].should be > 1_600_000_000_i64
        r.echo("x").should eq("x")
      end
    end

    pending_redis "hashes" do
      with_redis(protocol) do |r|
        r.hset("h", "f", "1").should eq(1_i64)
        r.hset("h", {"g" => "2", "i" => "3"}).should eq(2_i64)
        r.hget("h", "f").should eq("1")
        r.hget("h", "zz").should be_nil
        r.hmget("h", "f", "zz").should eq(["1", nil])
        r.hgetall("h").should eq({"f" => "1", "g" => "2", "i" => "3"})
        r.hsetnx("h", "f", "9").should be_false
        r.hexists("h", "f").should be_true
        r.hkeys("h").sort.should eq(["f", "g", "i"])
        r.hvals("h").sort.should eq(["1", "2", "3"])
        r.hlen("h").should eq(3_i64)
        r.hincrby("h", "f", 2).should eq(3_i64)
        r.hincrbyfloat("h", "f", 0.5).should eq(3.5)
        r.hdel("h", "g", "i").should eq(2_i64)
        cursor, fields = r.hscan("h", "0")
        cursor.should eq("0")
        fields.should eq({"f" => "3.5"})
      end
    end

    pending_redis "lists" do
      with_redis(protocol) do |r|
        r.rpush("l", "a", "b", "c").should eq(3_i64)
        r.lpush("l", "z").should eq(4_i64)
        r.lpushx("nope", "x").should eq(0_i64)
        r.rpushx("l", "d").should eq(5_i64)
        r.llen("l").should eq(5_i64)
        r.lrange("l", 0, -1).should eq(["z", "a", "b", "c", "d"])
        r.lindex("l", 1).should eq("a")
        r.lset("l", 1, "A")
        r.linsert("l", :before, "b", "ab").should eq(6_i64)
        r.lrem("l", 0, "ab").should eq(1_i64)
        r.lpop("l").should eq("z")
        r.rpop("l", 2).should eq(["d", "c"])
        r.lmove("l", "m", :left, :right).should eq("A")
        r.lrange("m", 0, -1).should eq(["A"])
        r.ltrim("l", 0, 0)
        r.lrange("l", 0, -1).should eq(["b"])
        r.lpop("nope", 2).should eq([] of String)
        r.rpop("nope").should be_nil
      end
    end

    pending_redis "sets" do
      with_redis(protocol) do |r|
        r.sadd("s", "a", "b", "c").should eq(3_i64)
        r.sadd("t", "b", "c", "d")
        r.smembers("s").sort.should eq(["a", "b", "c"])
        r.sismember("s", "a").should be_true
        r.smismember("s", "a", "zz").should eq([true, false])
        r.scard("s").should eq(3_i64)
        r.sinter("s", "t").sort.should eq(["b", "c"])
        r.sunion("s", "t").sort.should eq(["a", "b", "c", "d"])
        r.sdiff("s", "t").should eq(["a"])
        r.sinterstore("u", "s", "t").should eq(2_i64)
        r.sunionstore("u", "s", "t").should eq(4_i64)
        r.sdiffstore("u", "s", "t").should eq(1_i64)
        r.smove("s", "t", "a").should be_true
        r.srem("t", "a").should eq(1_i64)
        r.srandmember("s").should_not be_nil
        r.srandmember("s", 2).size.should eq(2)
        r.spop("s").should_not be_nil
        r.spop("s", 5).size.should eq(1)
        cursor, members = r.sscan("t", "0")
        cursor.should eq("0")
        members.sort.should eq(["b", "c", "d"])
      end
    end

    pending_redis "sorted sets" do
      with_redis(protocol) do |r|
        r.zadd("z", 1.0, "a").should eq(1_i64)
        r.zadd("z", [{"b", 2.0}, {"c", 3.0}]).should eq(2_i64)
        r.zadd("z", [{"a", 5.0}], nx: true).should eq(0_i64)
        r.zadd("z", [{"a", 1.5}], xx: true, ch: true).should eq(1_i64)
        r.zadd_incr("z", 0.5, "a").should eq(2.0)
        r.zscore("z", "a").should eq(2.0)
        r.zscore("z", "zz").should be_nil
        r.zmscore("z", "a", "zz").should eq([2.0, nil])
        r.zcard("z").should eq(3_i64)
        r.zcount("z", "-inf", "(3").should eq(2_i64)
        r.zincrby("z", 1.0, "c").should eq(4.0)
        r.zrange("z", 0, -1).should eq(["a", "b", "c"])
        r.zrange("z", 0, -1, rev: true).should eq(["c", "b", "a"])
        r.zrange("z", "(2", "+inf", by_score: true, limit: {0, 1}).should eq(["c"])
        r.zrange_with_scores("z", 0, 1).should eq([{"a", 2.0}, {"b", 2.0}])
        r.zrank("z", "c").should eq(2_i64)
        r.zrevrank("z", "c").should eq(0_i64)
        r.zrank("z", "zz").should be_nil
        cursor, pairs = r.zscan("z", "0")
        cursor.should eq("0")
        pairs.sort_by(&.[0]).should eq([{"a", 2.0}, {"b", 2.0}, {"c", 4.0}])
        r.zpopmin("z").should eq([{"a", 2.0}])
        r.zpopmax("z", 2).should eq([{"c", 4.0}, {"b", 2.0}])
        r.zrem("z", "a").should eq(0_i64)
        r.zpopmin("z").should eq([] of {String, Float64})
      end
    end

    pending_redis "scripting" do
      with_redis(protocol) do |r|
        r.eval("return {KEYS[1], ARGV[1], 7}", keys: ["k"], args: ["v"] of Redis::RESP::Arg).should eq(["k", "v", 7_i64] of Redis::Value)
        sha = r.script_load("return 1")
        r.evalsha(sha).should eq(1_i64)
        r.script_exists(sha, "0" * 40).should eq([true, false])
        r.script_flush
        r.script_exists(sha).should eq([false])
        ex = expect_raises(Redis::CommandError) { r.evalsha(sha) }
        ex.code.should eq("NOSCRIPT")
      end
    end

    pending_redis "error replies and the escape hatch" do
      with_redis(protocol) do |r|
        r.rpush("l", "x")
        ex = expect_raises(Redis::CommandError) { r.get("l") }
        ex.code.should eq("WRONGTYPE")
        r.command("CLIENT", "ID").should be_a(Int64)
        r.command(["ECHO", "hi"]).should eq("hi")
      end
    end
  end
end

live_command_specs(3)
live_command_specs(2)

describe "Redis live concurrency" do
  pending_redis "64 fibers × 100 incr on one multiplexed client" do
    with_redis(3) do |r|
      done = Channel(Nil).new
      64.times do
        spawn do
          100.times { r.incr("hits") }
          done.send(nil)
        end
      end
      64.times { done.receive }
      r.get("hits").should eq("6400")
    end
  end

  pending_redis "10k-command pipeline round-trips" do
    with_redis(3) do |r|
      futures = [] of Redis::Future(Int64)
      results = r.pipelined do |p|
        10_000.times { futures << p.incr("n") }
      end
      results.size.should eq(10_000)
      futures.last.value.should eq(10_000_i64)
      r.get("n").should eq("10000")
    end
  end

  pending_redis "dedicated Connection runs a blocking command" do
    with_redis(3) do |r|
      conn = Redis::Connection.new(RedisSpec::URL, db: RedisSpec::DB)
      spawn { sleep 0.05.seconds; r.rpush("q", "job") }
      conn.call("BLPOP", "q", 2).should eq(["q", "job"] of Redis::Value)
      conn.close
    end
  end

  pending_redis "unix socket connection when the server exposes one" do
    path = ENV["REDIS_UNIX_SOCKET"]?
    pending! "set REDIS_UNIX_SOCKET to run" unless path
    conn = Redis::Connection.new("redis+unix://#{path}?db=#{RedisSpec::DB}")
    conn.ping.should eq("PONG")
    conn.close
  end
end
```

- [ ] **Step 2: Run without a server: everything pending**

Run: `redis-cli shutdown nosave 2>/dev/null; bin/crystal spec spec/std/redis/live_spec.cr`
Expected: `0 failures`, all examples `pending`, with the `[no redis server ...]` suffix.

- [ ] **Step 3: Run with a server**

Run: `redis-server --daemonize yes --save "" --appendonly no --port 6379 && bin/crystal spec spec/std/redis/live_spec.cr`
Expected: all examples pass in both protocol blocks (the unix-socket one stays pending unless `REDIS_UNIX_SOCKET` is set). Fix any normalization gap in `Cast` uncovered here; the RESP2 block is the one most likely to reveal one (`HGETALL`, `ZRANGE WITHSCORES`, `ZPOPMIN`, `ZSCAN`, `INCRBYFLOAT`, `ZSCORE`, `ZMSCORE` on RESP2 all come back as strings).

- [ ] **Step 4: Format and commit**

```bash
bin/crystal tool format spec/std/redis
git add spec/std/redis/live_spec.cr src/redis
git commit -m "Redis: live integration specs for RESP3 and RESP2

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 14: Module docs, formatting, full standard-library suite

**Files:**
- Modify: `src/redis.cr` (module documentation)
- Verify: `make format check=1`, `make std_spec`

- [ ] **Step 1: Write the module doc in `src/redis.cr`**

Replace the one-line comment with:

```crystal
# A pure-Crystal Redis client speaking RESP3 (with RESP2 fallback) over TCP,
# Unix sockets or TLS.
#
# `Redis::Client` is a multiplexed connection that any number of fibers can
# share; commands from concurrent fibers are pipelined automatically.
# `Redis::Connection` is a plain synchronous connection for blocking
# commands. Both include `Redis::Commands`, the typed command methods, and
# `Client#pipelined` collects commands into one write with typed
# `Redis::Future`s.
#
# ```
# require "redis"
#
# redis = Redis::Client.new("redis://localhost:6379/0")
# redis.set("greeting", "hello", ex: 60)
# redis.get("greeting")   # => "hello"
# redis.incr("counter")   # => 1_i64
# redis.hgetall("user:1") # => {} of String => String
#
# results = redis.pipelined do |p|
#   p.set("a", "1")
#   p.get("a")
# end
# results # => ["OK", "1"]
#
# redis.command("CLIENT", "ID") # => 42_i64 (a Redis::Value)
# ```
#
# Replies are `Redis::Value`, a union of `Nil`, `Bool`, `Int64`, `Float64`,
# `String`, `Redis::BigNumber`, `Redis::CommandError`, `Array`, `Set` and
# `Hash`. Typed commands normalize RESP2 and RESP3 replies to the same
# Crystal type. Errors: `Redis::CommandError` (server error reply, with
# `code`), `Redis::ConnectionError`, `Redis::ProtocolError`.
#
# Not in this slice: pub/sub, MULTI/EXEC, script caching, cluster routing.
module Redis
end
```

- [ ] **Step 2: Format check and doc build**

Run: `make format check=1` then `bin/crystal docs src/redis.cr -o .build/redis-docs >/dev/null && echo docs-ok`
Expected: format clean; docs build without warnings about missing doc comments on public methods (the build simply must succeed).

- [ ] **Step 3: Full suites**

Run: `make std_spec 2>&1 | tail -5` (with the local server up so the live block runs; then once more with it down to see the pending count).
Expected: `0 failures` apart from the 14 known environment failures recorded in memory; the new Redis examples appear in the totals.

- [ ] **Step 4: Commit**

```bash
git add src/redis.cr
git commit -m "Redis: module documentation

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 15: Benchmarks vs redis-rs and go-redis

**Files:**
- Create (gitignored): `.remember/harness-2026-09-19/redis/bench_codec.cr`, `bench_live.cr`, `rs/src/main.rs`, `rs/Cargo.toml`, `go/main.go`, `go/go.mod`, `README.md`

- [ ] **Step 1: Codec benchmark**

```crystal
# .remember/harness-2026-09-19/redis/bench_codec.cr
require "benchmark"
require "redis"

REPLIES = {
  "int"      => ":42\r\n",
  "bulk10"   => "$10\r\n0123456789\r\n",
  "bulk1k"   => "$1024\r\n" + "x" * 1024 + "\r\n",
  "array10"  => "*10\r\n" + "$3\r\nabc\r\n" * 10,
  "map10"    => "%10\r\n" + "$3\r\nkey\r\n:1\r\n" * 10,
}

REPLIES.each do |name, frame|
  data = (frame * 1000).to_slice
  io = IO::Memory.new(data)
  n = 1_000_000 // 1000
  t = Time.measure do
    n.times do
      io.rewind
      1000.times { Redis::RESP.read(io) }
    end
  end
  puts "parse #{name.ljust(8)} #{(t.total_nanoseconds / 1_000_000).round(1)} ns/reply  #{(data.size * n / t.total_seconds / 1e6).round(0)} MB/s"
end

out = IO::Memory.new
t = Time.measure { 1_000_000.times { out.clear; Redis::RESP.write_command(out, "SET", "key:12345", "value-value-value") } }
puts "encode SET #{(t.total_nanoseconds / 1_000_000).round(1)} ns/command"
```

Run: `bin/crystal build --release .remember/harness-2026-09-19/redis/bench_codec.cr -o .build/bench_codec && .build/bench_codec`

- [ ] **Step 2: Live benchmark (Crystal)**

```crystal
# .remember/harness-2026-09-19/redis/bench_live.cr
require "redis"

url = ARGV[0]? || "redis://127.0.0.1:6379"
redis = Redis::Client.new(url, db: 14)
redis.flushdb
redis.set("k", "v")

def report(name, ops, t)
  puts "#{name.ljust(28)} #{(ops / t.total_seconds).round(0).to_i.to_s.rjust(8)} ops/s  #{(t.total_nanoseconds / ops / 1000).round(1)} µs/op"
end

n = 50_000
t = Time.measure { n.times { redis.get("k") } }
report "sequential GET", n, t

fibers = 64
per = 5_000
done = Channel(Nil).new
t = Time.measure do
  fibers.times { spawn { per.times { redis.get("k") }; done.send(nil) } }
  fibers.times { done.receive }
end
report "64 fibers GET", fibers * per, t

t = Time.measure do
  fibers.times { spawn { per.times { redis.incr("c") }; done.send(nil) } }
  fibers.times { done.receive }
end
report "64 fibers INCR", fibers * per, t

t = Time.measure { redis.pipelined { |p| 10_000.times { p.incr("p") } } }
report "10k pipeline INCR", 10_000, t
redis.close
```

- [ ] **Step 3: Rust and Go equivalents**

`rs/Cargo.toml` depends on `redis = { version = "0.27", features = ["tokio-comp"] }` and `tokio = { version = "1", features = ["full"] }`. `main.rs` opens `Client::open(url)?.get_multiplexed_tokio_connection().await?`, then runs the same four cases: sequential `GET` loop; 64 `tokio::spawn` tasks each doing 5000 `GET` on a cloned multiplexed connection; same with `INCR`; and a `redis::pipe()` with 10 000 `incr` calls. Print the same `ops/s` format.

`go/main.go` uses `github.com/redis/go-redis/v9` (`redis.NewClient(&redis.Options{Addr: "127.0.0.1:6379", DB: 14, Protocol: 3})`), sequential `Get`, 64 goroutines × 5000 `Get`, same with `Incr`, and a `client.Pipeline()` with 10 000 `Incr`. Same output format.

Run all three against the same local server (`redis-server --daemonize yes --save "" --port 6379`), Crystal built with `--release`, Rust with `cargo run --release`, Go with `go run .`. Run each twice and keep the second.

- [ ] **Step 4: Record**

Write `README.md` in the harness dir with the table (Crystal / Rust / Go per case, plus codec numbers), the target check from the spec (within 20% of redis-rs on the 64-fiber case, not worse than go-redis sequentially), and any variant tried and rejected. If the 64-fiber case misses the target, profile with `--release -Ddebug` and `perf`/`sample` before changing the design: the usual suspects are per-call `Array(RESP::Arg)` allocation in `def_command` (could be a stack tuple) and `Channel` overhead per waiter. Record findings; do not silently redesign.

Then update memory (`stdlib-batteries-direction.md`) with the shipped state, the numbers, and lessons, as the previous tiers did.

No commit for this task (harness is gitignored) beyond the memory note.
