require "pool"

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
  # Built on the generic `::Pool(T)`, translating its errors into the
  # `Redis` ones.
  #
  # ```
  # pool = Redis::Pool.new("redis://localhost:6379", size: 8)
  # pool.checkout { |conn| conn.call("BLPOP", "jobs", 0) }
  # pool.close
  # ```
  class Pool
    @pool : ::Pool(Connection)

    # Creates an empty pool for *url* (or `Connection::DEFAULT_URL`). The
    # remaining options are those of `Connection.new` and apply to every
    # connection the pool opens. Raises `ArgumentError` if *size* is not
    # positive or *protocol* is outside `2..3`.
    def initialize(url : String | URI = Connection::DEFAULT_URL, *, size : Int32 = 8,
                   checkout_timeout : Time::Span = 5.seconds, db : Int32? = nil, username : String? = nil,
                   password : String? = nil, client_name : String? = nil, protocol : Int32 = 3,
                   connect_timeout : Time::Span = 5.seconds, read_timeout : Time::Span? = nil,
                   tls_context : OpenSSL::SSL::Context::Client? = nil, max_bulk_size : Int32 = RESP::MAX_BULK_SIZE)
      raise ArgumentError.new("pool size must be positive, got #{size}") unless size > 0
      raise ArgumentError.new("protocol must be 2 or 3, got #{protocol}") unless protocol == 2 || protocol == 3
      uri = url.is_a?(URI) ? url : URI.parse(url)
      @pool = ::Pool(Connection).new(size: size, checkout_timeout: checkout_timeout) do
        Connection.new(uri, db: db, username: username, password: password, client_name: client_name,
          protocol: protocol, connect_timeout: connect_timeout, read_timeout: read_timeout,
          tls_context: tls_context, max_bulk_size: max_bulk_size)
      end
    end

    # The maximum number of open connections.
    def size : Int32
      @pool.size
    end

    # How long `checkout` waits for a connection.
    def checkout_timeout : Time::Span
      @pool.checkout_timeout
    end

    # Open connections waiting in the pool.
    def idle : Int32
      @pool.idle
    end

    # Connections currently checked out.
    def in_use : Int32
      @pool.in_use
    end

    # Whether `close` has been called. An advisory snapshot: it is read
    # without the lock, so it can be stale by the time the caller acts on
    # it under a concurrent `close`.
    def closed? : Bool
      @pool.closed?
    end

    # Takes a connection, opening one if none is idle and fewer than `size`
    # are out. Raises `PoolTimeoutError` after `checkout_timeout`,
    # `ConnectionError` if the pool is closed or a new connection cannot be
    # opened, `CommandError` if the server rejects the handshake. Hand it
    # back with `checkin`; the block form does that for you.
    def checkout : Connection
      @pool.checkout
    rescue ex : ::Pool::TimeoutError
      raise PoolTimeoutError.new(ex.message)
    rescue ::Pool::ClosedError
      raise ConnectionError.new("pool is closed")
    end

    # Returns *connection* to the pool. A closed connection is dropped; if
    # the pool is closed the connection is closed too. Checking in a
    # connection twice, or one this pool never handed out, is not detected.
    def checkin(connection : Connection) : Nil
      @pool.checkin(connection)
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
      @pool.close
    end
  end
end
