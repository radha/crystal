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

    # :nodoc:
    #
    # Restated (rather than left inherited from `Future(T)`) so that a
    # virtual call through `AbstractFuture` finds it; see the same override
    # on `ScriptFuture` in `pipeline.cr` for why.
    def resolved? : Bool
      super
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
