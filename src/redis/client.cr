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
    include Commands::ScriptFallback

    # :nodoc:
    getter script_cache = ScriptCache.new

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

    # :nodoc:
    ASKING = "*1\r\n$6\r\nASKING\r\n".to_slice

    @mutex = Mutex.new
    @connection : Connection?
    @wakeup : Channel(Nil) = Channel(Nil).new(1)
    @out : IO::Memory = IO::Memory.new
    @spare : IO::Memory = IO::Memory.new
    @pending = Deque(Waiter).new
    @waiter_pool = Deque(Waiter).new
    @closed = false
    @pool : Pool?

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
    # *pool_size* bounds the dedicated connections `with_connection` and
    # `watch` borrow. Raises `ArgumentError` if *protocol* is outside
    # `2..3`.
    def initialize(url : String | URI = Connection::DEFAULT_URL, *, @db : Int32? = nil, @username : String? = nil,
                   @password : String? = nil, @client_name : String? = nil, protocol @protocol_option : Int32 = 3,
                   @connect_timeout : Time::Span = 5.seconds, @read_timeout : Time::Span? = nil,
                   @tls_context : OpenSSL::SSL::Context::Client? = nil, @max_bulk_size : Int32 = RESP::MAX_BULK_SIZE,
                   @pool_size : Int32 = 4)
      @url = url.is_a?(URI) ? url : URI.parse(url)
      raise ArgumentError.new("protocol must be 2 or 3, got #{@protocol_option}") unless @protocol_option == 2 || @protocol_option == 3
      raise ArgumentError.new("pool_size must be positive, got #{@pool_size}") unless @pool_size > 0
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
    # A `multi` block inside the pipeline contributes its `MULTI` `"OK"`,
    # one `"QUEUED"` per queued command, and the `EXEC` array as separate
    # elements of these raw replies; read the transaction's own results
    # through its commands' futures or the future `multi` returns, not by
    # indexing into this array.
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

    # Runs the block's commands as one `MULTI`..`EXEC` transaction, sent in
    # a single write so that no other fiber's command can land between
    # `MULTI` and `EXEC`, and returns the `EXEC` array. Typed methods on the
    # transaction return futures resolved from that array. Raises
    # `AbortedError` if a key marked with `watch` changed (`EXEC` replied
    # nil), the `EXECABORT` `CommandError` if a command was rejected at
    # queue time, `ConnectionError` if the socket drops. Error replies
    # inside the array stay values; only the matching command's future
    # raises them.
    #
    # `WATCH` is not available here (it is per-connection state that
    # concurrent fibers would clobber); use `watch` for optimistic locking.
    #
    # ```
    # count = nil
    # redis.multi do |tx|
    #   tx.set("a", "1")
    #   count = tx.incr("hits")
    # end                  # => ["OK", 1_i64]
    # count.not_nil!.value # => 1_i64
    # ```
    def multi(&block : Transaction ->) : Array(Value)
      exec = nil
      pipelined { |p| exec = p.multi(&block) }
      exec.not_nil!.value
    end

    # Raises `ArgumentError`: `watch` needs at least one key.
    def watch(&block : Connection -> T) : T forall T
      raise ArgumentError.new("WATCH needs at least one key")
    end

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

    # Closes the connection and the pool; pending commands raise
    # `ConnectionError`, and every later call raises too.
    def close : Nil
      conn, pool = @mutex.synchronize do
        @closed = true
        {@connection, @pool}
      end
      disconnect(conn, nil) if conn
      pool.close if pool
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
