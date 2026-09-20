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
    # Raises `ConnectionError` if the subscriber is closed or the
    # connection drops before the confirmation (the channels stay
    # recorded and are subscribed on reconnect), `IO::TimeoutError` if
    # `read_timeout` elapses. While the subscriber is reconnecting the
    # channels are only recorded and the call returns immediately.
    def subscribe(*channels : String) : Nil
      names = channels.to_a
      control("SUBSCRIBE", names) do
        @channels.concat(names)
        names.size
      end
    end

    # Raises `ArgumentError`: `subscribe` needs at least one channel.
    def subscribe : Nil
      raise ArgumentError.new("subscribe needs at least one channel")
    end

    # Subscribes to *patterns* (glob style, `log.*`); otherwise like
    # `subscribe`.
    def psubscribe(*patterns : String) : Nil
      names = patterns.to_a
      control("PSUBSCRIBE", names) do
        @patterns.concat(names)
        names.size
      end
    end

    # Raises `ArgumentError`: `psubscribe` needs at least one pattern.
    def psubscribe : Nil
      raise ArgumentError.new("psubscribe needs at least one pattern")
    end

    # Unsubscribes from *channels* and returns once the server confirmed
    # each. Errors as `subscribe`. See `unsubscribe` (no arguments) to
    # unsubscribe from everything at once.
    def unsubscribe(*channels : String) : Nil
      names = channels.to_a
      control("UNSUBSCRIBE", names) do
        names.each { |n| @channels.delete(n) }
        names.size
      end
    end

    # Unsubscribes from every channel currently subscribed; see
    # `unsubscribe(*channels)`.
    def unsubscribe : Nil
      control("UNSUBSCRIBE", [] of String) do
        count = @channels.size
        @channels.clear
        count == 0 ? 1 : count
      end
    end

    # Unsubscribes from *patterns*; otherwise like `unsubscribe`.
    def punsubscribe(*patterns : String) : Nil
      names = patterns.to_a
      control("PUNSUBSCRIBE", names) do
        names.each { |n| @patterns.delete(n) }
        names.size
      end
    end

    # Unsubscribes from every pattern currently subscribed; see
    # `punsubscribe(*patterns)`.
    def punsubscribe : Nil
      control("PUNSUBSCRIBE", [] of String) do
        count = @patterns.size
        @patterns.clear
        count == 0 ? 1 : count
      end
    end

    # Sends `PING` and returns once the server answered. A cheap liveness
    # check for an idle subscription. Errors as `subscribe`. While the
    # subscriber is reconnecting there is nothing to ping: the call returns
    # immediately without contacting the server.
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
        begin
          c.send(args)
        rescue ex
          @pending.pop
          raise ex
        end
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

    # The reader fiber: reads until the connection fails, then either
    # reconnects and resubscribes or, with `reconnect: false`, closes.
    private def run(conn : Connection) : Nil
      loop do
        cause = read_loop(conn)
        return if @closed
        drop(conn, cause)
        on_disconnect.try &.call(@mutex.synchronize { @error } || cause)
        unless @reconnect
          close
          return
        end
        conn = reconnect_loop || return
        return if @closed
        on_reconnect.try &.call
      end
    rescue ex
      # A hook raised: there is nobody to report it to, so shut down. This
      # always follows a `drop`, which already recorded the disconnect
      # cause, so the hook's own exception is what the caller wants to see
      # (see the "a hook that raises" spec).
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

    # Reads frames until the connection fails; returns the failure.
    private def read_loop(conn : Connection) : Exception
      socket = conn.socket
      push = ->(frame : Array(Value)) { dispatch(frame) }
      loop do
        value = RESP.read(socket, max_bulk_size: @max_bulk_size, push: push)
        case value
        when Array
          dispatch(value) # RESP2: pub/sub frames are plain arrays
        when "PONG"
          confirm # RESP3: `PING` answers `+PONG`
        when CommandError
          raise value
        else
          raise ProtocolError.new("unexpected reply in subscribed mode: #{value.inspect}")
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
