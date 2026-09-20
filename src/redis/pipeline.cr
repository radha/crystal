module Redis
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

  # The pending result of a command issued inside `Client#pipelined`.
  # Typed command methods on a `Pipeline` return one of these; read it with
  # `value` after the block has run.
  class Future(T) < AbstractFuture
    @raw : Value | Exception = nil
    @resolved = false

    # :nodoc:
    def initialize(@mapper : Proc(Value, T))
    end

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

    # Whether the pipeline that owns this future has executed.
    def resolved? : Bool
      @resolved
    end

    # The typed reply. Raises `ArgumentError` before the pipeline executes,
    # the `CommandError`, `ConnectionError` or `IO::TimeoutError` the
    # command failed with, or `ProtocolError` if the reply has an
    # unexpected shape.
    def value : T
      raise ArgumentError.new("pipeline not executed yet") unless @resolved
      raw = @raw
      raise raw if raw.is_a?(Exception)
      @mapper.call(raw)
    end

    # Like `value`, but `nil` when unresolved or failed. For a nilable `T` a
    # `nil` result is ambiguous; check `resolved?` first to tell the cases
    # apart.
    def value? : T?
      return nil unless @resolved
      raw = @raw
      return nil if raw.is_a?(Exception)
      @mapper.call(raw)
    end
  end

  # :nodoc:
  #
  # The future of a pipelined `run`: keeps the client's `ScriptCache`
  # honest. A `NOSCRIPT` reply forgets the SHA, any successful reply
  # records it (the pipeline may have sent `EVAL`, which loads the script).
  class ScriptFuture < Future(Value)
    def initialize(@cache : ScriptCache, @sha : String)
      super(->(v : Value) { v })
    end

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

    # :nodoc:
    #
    # Restated (rather than left inherited from `Future(T)`) so that a
    # virtual call through `AbstractFuture` — as `ExecFuture#resolve` makes
    # when fanning an error out to a transaction's futures — finds it; a
    # method a generic ancestor implements for an `abstract def` is not
    # visible through the non-generic root without a direct override.
    def resolved? : Bool
      super
    end
  end

  # Collects commands inside `Client#pipelined`. Every typed command
  # method returns a `Future(T)` instead of `T`.
  class Pipeline
    include Commands

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

    # :nodoc:
    def script_run(script : Script, keys : Indexable(String), args : Indexable) : Future(Value)
      wire = if @script_cache.known?(script.sha)
               script_args("EVALSHA", script.sha, keys, args)
             else
               script_args("EVAL", script.source, keys, args)
             end
      record(wire) if @routing
      RESP.write_command(@buffer, wire)
      future = ScriptFuture.new(@script_cache, script.sha)
      @futures << future
      @size += 1
      future
    end

    # Queues *args* and returns a future for its raw reply.
    def call(*args : RESP::Arg) : Future(Value)
      call(args)
    end

    # :ditto:
    def call(args : Indexable) : Future(Value)
      typed_call(args) { |v| v }
    end

    # :nodoc:
    def typed_call(args : Indexable, &block : Value -> T) : Future(T) forall T
      record(args) if @routing
      RESP.write_command(@buffer, args)
      future = Future(T).new(block)
      @futures << future
      @size += 1
      future
    end

    # :nodoc:
    def resolve(index : Int32, raw : Value) : Nil
      @futures[index].resolve(raw)
    end

    # :nodoc:
    def fail(index : Int32, error : Exception) : Nil
      @futures[index].fail(error)
    end

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

    # Not available on a pipeline: iteration needs each cursor reply
    # before issuing the next command.
    def scan_each(*, match : String? = nil, count : Int? = nil, type : String? = nil, &) : NoReturn
      raise ArgumentError.new("scan_each is not available on a pipeline")
    end
  end
end
