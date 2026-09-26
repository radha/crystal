require "./connection"

module Postgres
  # `LISTEN` on its own connection.
  #
  # Notifications arrive on a bounded channel; read them with `receive`,
  # `receive?`, `receive(timeout)` or `each`. `listen` and `unlisten`
  # return once the server has confirmed. A full channel blocks the reader
  # fiber, so a slow consumer applies backpressure (the server queues
  # notifications, up to its `max_notify_queue_pages`).
  #
  # ```
  # listener = db.listener
  # listener.listen("jobs")
  # db.notify("jobs", "42")
  # listener.receive.payload # => "42"
  # listener.close
  # ```
  #
  # A lost connection is reconnected with exponential backoff (100 ms up
  # to 5 s) and every channel is listened on again, unless
  # `reconnect: false`, in which case the listener closes and `error`
  # holds the cause. Notifications sent while disconnected are **lost**:
  # PostgreSQL keeps no history for a session that is gone. Use
  # `on_reconnect` to catch up from the data itself (e.g. re-read a jobs
  # table), and `on_disconnect` to observe the gap.
  #
  # The hooks run on the reader fiber, so they must not call `listen`,
  # `unlisten`, `receive`, `receive?` or `each` on this listener (each
  # waits for the very fiber running the hook; it raises `ArgumentError`).
  #
  # `close` is required: the listener owns a reader fiber and a socket.
  class Listener
    # :nodoc:
    private class Ack
      getter waiter : Channel(Exception?)?
      property error : Exception?

      def initialize(@waiter : Channel(Exception?)?)
      end
    end

    # Called on the reader fiber with the cause when the connection drops.
    property on_disconnect : Proc(Exception, Nil)? = nil
    # Called on the reader fiber after a reconnect re-listened every
    # channel.
    property on_reconnect : Proc(Nil)? = nil

    @mutex = Mutex.new
    @channels = [] of String
    @pending = Deque(Ack).new
    @closed = false
    @error : Exception?
    @connection : Connection?
    @notifications : Channel(Notification)
    @close_signal = Channel(Nil).new
    @reader : Fiber

    # Opens a listener with *config* (see `Config.parse`). *capacity* bounds
    # the notifications buffered for `receive`. Raises `ConnectionError`
    # or `AuthenticationError` if the first connection fails.
    def initialize(*, @config : Config, capacity : Int32 = 256, @reconnect : Bool = true,
                   @tls_context : OpenSSL::SSL::Context::Client? = nil)
      @notifications = Channel(Notification).new(capacity)
      conn = connect
      @connection = conn
      @reader = spawn(name: "Postgres::Listener") { run(conn) }
    end

    # Opens a listener for *url* (see `Config.parse`).
    def self.new(url : String | URI | Nil = nil, *, capacity : Int32 = 256, reconnect : Bool = true,
                 tls_context : OpenSSL::SSL::Context::Client? = nil) : self
      new(config: Config.parse(url), capacity: capacity, reconnect: reconnect, tls_context: tls_context)
    end

    # The channels listened on.
    def channels : Array(String)
      @mutex.synchronize { @channels.dup }
    end

    # Whether a connection is currently up.
    def connected? : Bool
      @mutex.synchronize { !@connection.nil? }
    end

    # Whether `close` has been called (or the listener closed itself).
    def closed? : Bool
      @closed
    end

    # The last connection failure, or the exception a hook raised.
    def error : Exception?
      @mutex.synchronize { @error }
    end

    # Starts listening on *channels* and waits for the server. While
    # disconnected the channels are only recorded, and listened on at
    # the reconnect.
    def listen(*channels : String) : Nil
      control("LISTEN", channels.to_a) do
        channels.each { |c| @channels << c unless @channels.includes?(c) }
      end
    end

    # Stops listening on *channels*.
    def unlisten(*channels : String) : Nil
      control("UNLISTEN", channels.to_a) do
        channels.each { |c| @channels.delete(c) }
      end
    end

    # Stops listening on every channel.
    def unlisten : Nil
      control("UNLISTEN", ["*"], quote: false) { @channels.clear }
    end

    # Blocks until the next notification. Raises `ConnectionError` once
    # the listener is closed and nothing is buffered.
    def receive : Notification
      guard_hook("receive")
      @notifications.receive
    rescue Channel::ClosedError
      raise ConnectionError.new("listener is closed")
    end

    # Blocks until the next notification, or returns `nil` once the
    # listener is closed and nothing is buffered.
    def receive? : Notification?
      guard_hook("receive?")
      @notifications.receive?
    end

    # The next notification, or `nil` if none arrives within *timeout*.
    def receive(timeout : Time::Span) : Notification?
      guard_hook("receive")
      select
      when n = @notifications.receive?
        n
      when timeout(timeout)
        nil
      end
    end

    # Yields every notification until the listener is closed.
    def each(& : Notification ->) : Nil
      while n = receive?
        yield n
      end
    end

    # Closes the connection and the notification channel. Buffered
    # notifications can still be read with `receive?`. Idempotent.
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
      error = ConnectionError.new("listener is closed")
      acks.each { |ack| ack.waiter.try &.send(error) }
      @notifications.close
    end

    private def connect : Connection
      Connection.new(config: @config, read_timeout: nil, tls_context: @tls_context)
    end

    private def guard_hook(method : String) : Nil
      return unless Fiber.current.same?(@reader)
      raise ArgumentError.new("Postgres::Listener##{method} cannot be called from a listener hook (reader fiber)")
    end

    # `"na""me"`: channel names are identifiers.
    protected def self.quote(name : String) : String
      %("#{name.gsub('"', %(""))}")
    end

    protected def self.statement(command : String, names : Array(String), quote : Bool = true) : String
      names.join("; ") { |n| "#{command} #{quote ? quote(n) : n}" }
    end

    # Records the change (the block runs under the mutex), sends *command*
    # if connected, and waits for the server's `ReadyForQuery`.
    private def control(command : String, names : Array(String), quote : Bool = true, &) : Nil
      guard_hook(command.downcase)
      return if names.empty?
      waiter = @mutex.synchronize do
        raise ConnectionError.new("listener is closed") if @closed
        yield
        c = @connection
        next nil unless c
        w = Channel(Exception?).new(1)
        @pending.push(Ack.new(w))
        begin
          c.unsafe_send_query(Listener.statement(command, names, quote))
        rescue ex
          @pending.pop
          raise ex
        end
        w
      end
      return unless waiter
      error = waiter.receive
      raise error if error
    end

    # The reader fiber: reads until the connection fails, then reconnects
    # and listens again or, with `reconnect: false`, closes.
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
        return if @closed
        on_reconnect.try &.call
      end
    rescue ex
      @mutex.synchronize { @error = ex }
      close
    end

    # Reads messages until the connection fails; returns the failure.
    private def read_loop(conn : Connection) : Exception
      loop do
        type, body = conn.unsafe_read_message
        case type
        when 'A'
          notification = conn.unsafe_notification(body)
          begin
            @notifications.send(notification)
          rescue Channel::ClosedError
            return ConnectionError.new("listener is closed")
          end
        when 'E'
          error = conn.unsafe_query_error(body)
          @mutex.synchronize { @pending.first?.try { |ack| ack.error ||= error } }
        when 'Z'
          ack = @mutex.synchronize { @pending.shift? }
          ack.try { |a| a.waiter.try &.send(a.error) }
        when 'C', 'I'
          # the LISTEN/UNLISTEN command tags
        else
          conn.close
          return ProtocolError.new("unexpected message #{type.inspect} on a listener")
        end
      end
    rescue ex : Error | IO::Error
      ex
    end

    # Reconnects with exponential backoff until it succeeds or the
    # listener is closed (nil); the channels are listened on again.
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
        rescue Error | IO::Error
          next
        end
        installed = begin
          @mutex.synchronize do
            if @closed
              false
            else
              @connection = conn
              @error = nil
              unless @channels.empty?
                @pending.push(Ack.new(nil))
                conn.unsafe_send_query(Listener.statement("LISTEN", @channels))
              end
              true
            end
          end
        rescue ex : Error | IO::Error
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

    # Tears *conn* down if it is still current: records *cause*, fails the
    # pending control commands, closes the socket.
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
