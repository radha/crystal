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
    def call(args : Indexable) : Future(Value)
      typed_call(args) { |v| v }
    end

    # :nodoc:
    def typed_call(args : Indexable, &block : Value -> T) : Future(T) forall T
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
