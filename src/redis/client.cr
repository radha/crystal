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
  #
  # Connecting happens under the client's lock, so concurrent callers wait
  # for one connection attempt and `close` may block for up to
  # `connect_timeout` while a connect is in flight.
  #
  # `close` is required: a `Client` owns a reader and a writer fiber that
  # keep running for as long as it is connected, so it is never collected
  # by the GC while those fibers run, and it has no finalizer to do this
  # for you.
  class Client
    include Commands

    # One slot for one in-flight command. The reply travels on the
    # channel; a failure arrives as `nil` on the channel with `error` set,
    # because a `Channel(Value | Exception)` yields a union the compiler
    # will not pass to `Pipeline#resolve` (`Value` already contains
    # `CommandError`, so the union and the identically spelled parameter
    # restriction are not the same type).
    private class Waiter
      getter channel = Channel(Value).new(1)
      property error : ConnectionError?
    end

    # Receives RESP3 push frames as the reader fiber decodes them.
    # Assigning it takes effect on the very next frame, on the connection
    # that is open as well as on later ones. The handler runs on the
    # reader fiber, so a slow handler stalls every reply on that
    # connection; an exception raised by it tears the connection down and
    # fails every command in flight.
    property push_handler : (Array(Value) ->)?

    @mutex = Mutex.new
    @connection : Connection?
    @wakeup : Channel(Nil) = Channel(Nil).new(1)
    @out : IO::Memory = IO::Memory.new
    @spare : IO::Memory = IO::Memory.new
    @pending = Deque(Waiter).new
    @waiter_pool = Deque(Waiter).new
    @closed = false

    @url : URI
    @db : Int32?
    @username : String?
    @password : String?
    @client_name : String?
    @read_timeout : Time::Span?
    @tls_context : OpenSSL::SSL::Context::Client?

    # Creates a client for *url* (or `Connection::DEFAULT_URL`). Nothing is
    # connected until the first command; every option is remembered and
    # reapplied on each reconnect. *read_timeout* bounds how long a single
    # command waits for its reply before the connection is torn down.
    # Raises `ArgumentError` if *protocol* is outside `2..3`.
    def initialize(url : String | URI = Connection::DEFAULT_URL, *, @db : Int32? = nil, @username : String? = nil,
                   @password : String? = nil, @client_name : String? = nil, protocol @protocol_option : Int32 = 3,
                   @connect_timeout : Time::Span = 5.seconds, @read_timeout : Time::Span? = nil,
                   @tls_context : OpenSSL::SSL::Context::Client? = nil, @max_bulk_size : Int32 = RESP::MAX_BULK_SIZE)
      @url = url.is_a?(URI) ? url : URI.parse(url)
      raise ArgumentError.new("protocol must be 2 or 3, got #{@protocol_option}") unless @protocol_option == 2 || @protocol_option == 3
    end

    # The negotiated protocol version, or `nil` while disconnected. An
    # advisory snapshot: it is read without the lock, so it can be stale by
    # the time the caller acts on it under concurrent reconnects.
    def protocol : Int32?
      @connection.try &.protocol
    end

    # Whether a connection is currently open. An advisory snapshot: it is
    # read without the lock, so it can be stale by the time the caller acts
    # on it under concurrent reconnects.
    def connected? : Bool
      !@connection.nil?
    end

    # Whether `close` has been called. An advisory snapshot: it is read
    # without the lock, so it can be stale by the time the caller acts on
    # it under a concurrent `close`.
    def closed? : Bool
      @closed
    end

    # Sends *args* and returns the reply. Raises `CommandError` for an
    # error reply, `ConnectionError` if the connection cannot be opened or
    # drops, `IO::TimeoutError` if `read_timeout` elapses.
    #
    # A `ConnectionError` does not mean the command did not execute: if the
    # bytes reached the server before the connection dropped, the command
    # may have run and its reply was simply lost. There is no automatic
    # retry, so a non-idempotent command needs the caller's own judgement
    # about whether to resend it.
    def call(*args : RESP::Arg) : Value
      call(args)
    end

    # :ditto:
    def call(args : Indexable) : Value
      waiter, wakeup, conn = @mutex.synchronize do
        check_open
        c = ensure_connected
        RESP.write_command(@out, args)
        w = take_waiter
        @pending.push(w)
        {w, @wakeup, c}
      end
      signal(wakeup)
      value, error = wait(waiter, conn)
      raise error if error
      raise value if value.is_a?(CommandError)
      value
    end

    # :nodoc:
    def typed_call(args : Indexable, &block : Value -> T) forall T
      block.call(call(args))
    end

    # Runs the block against a `Pipeline`, sends every queued command in a
    # single write, and returns the raw replies in order. Error replies
    # stay in the array as `CommandError` values (and are raised by the
    # corresponding `Future#value`); a lost connection raises
    # `ConnectionError`, and an expired `read_timeout` raises
    # `IO::TimeoutError`, in both cases after every future has been
    # resolved with that failure.
    #
    # `read_timeout` applies per reply, not to the pipeline as a whole: it
    # resets for each command in turn, and the first reply that stalls past
    # it tears the connection down and fails every future that has not yet
    # been resolved.
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
      # A closed client raises even when the block queued nothing.
      @mutex.synchronize { check_open }
      return [] of Value if pipeline.size == 0
      waiters = Array(Waiter).new(pipeline.size)
      wakeup, conn = @mutex.synchronize do
        check_open
        c = ensure_connected
        @out.write(pipeline.buffer.to_slice)
        pipeline.size.times do
          w = take_waiter
          @pending.push(w)
          waiters << w
        end
        {@wakeup, c}
      end
      signal(wakeup)
      results = Array(Value).new(waiters.size)
      failure = nil
      resolved = 0
      begin
        waiters.each_with_index do |waiter, i|
          value, error = wait(waiter, conn)
          if error
            pipeline.resolve(i, error)
            failure ||= error
          else
            pipeline.resolve(i, value)
            results << value
          end
          resolved = i + 1
        end
      rescue ex : IO::TimeoutError
        # The timeout already tore the connection down. Every future that
        # has not been given a reply is resolved with it, so that
        # `Future#value` raises the timeout instead of reporting a
        # pipeline that never executed.
        (resolved...waiters.size).each { |j| pipeline.resolve(j, ex) }
        raise ex
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
      # Not `conn.push_handler = @push_handler`: `read_loop` below passes
      # `@push_handler` to `RESP.read` on every frame directly, so setting
      # it on `conn` would be write-only and never consulted.
      wakeup = Channel(Nil).new(1)
      @connection = conn
      @wakeup = wakeup
      # Fresh buffers, never the ones a writer fiber of a previous
      # connection may still hold a reference to.
      @out = IO::Memory.new
      @spare = IO::Memory.new
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

    # Blocks until the reader or a disconnect delivers into *waiter* and
    # returns its reply and the failure that ended it, if any. *conn* is
    # the connection the command was enqueued on. A waiter that timed out
    # is abandoned (its channel will still receive the disconnect), so
    # only clean completions return to the pool.
    private def wait(waiter : Waiter, conn : Connection) : {Value, ConnectionError?}
      value = if deadline = @read_timeout
                select
                when r = waiter.channel.receive
                  r
                when timeout(deadline)
                  # *conn*, never `@connection`: by the time the timeout
                  # fires the client may already have reconnected, and
                  # tearing that fresh connection down would fail commands
                  # belonging to other callers. `disconnect` compares it
                  # with the current connection, so a stale one is a no-op.
                  disconnect(conn, IO::TimeoutError.new("Redis command timed out after #{deadline}"))
                  raise IO::TimeoutError.new("Redis command timed out after #{deadline}")
                end
              else
                waiter.channel.receive
              end
      error = waiter.error
      waiter.error = nil
      @mutex.synchronize { @waiter_pool.push(waiter) }
      {value, error}
    end

    private def write_loop(conn : Connection, wakeup : Channel(Nil)) : Nil
      socket = conn.socket
      loop do
        # `Channel(Nil)#receive?` answers `nil` both for a delivered `nil`
        # and for a closed channel, so the close is caught instead.
        begin
          wakeup.receive
        rescue Channel::ClosedError
          return
        end
        full = @mutex.synchronize do
          if @connection.same?(conn) && !@out.empty?
            @out, @spare = @spare, @out
            @spare
          end
        end
        next unless full
        socket.write(full.to_slice)
        socket.flush
        full.clear
      end
    rescue ex
      # Anything at all: the writer must not die leaving callers blocked.
      disconnect(conn, ex)
    end

    private def read_loop(conn : Connection) : Nil
      socket = conn.socket
      loop do
        value = RESP.read(socket, max_bulk_size: @max_bulk_size, push: @push_handler)
        waiter = @mutex.synchronize do
          # A reader whose connection has been replaced stops, mirroring
          # `write_loop`; `disconnect` has already failed its waiters.
          return unless @connection.same?(conn)
          @pending.shift?
        end
        raise ProtocolError.new("unsolicited reply #{value.inspect}") unless waiter
        waiter.channel.send(value)
      end
    rescue ex
      # Anything at all, including an exception raised by `push_handler`:
      # the reader must not die leaving waiters blocked.
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
      waiters.each do |w|
        w.error = error
        w.channel.send(nil)
      end
    end
  end
end
