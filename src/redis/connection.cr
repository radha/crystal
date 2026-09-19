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

    # The default URL used when `new` is given none: localhost on the
    # standard Redis port, protocol negotiation on, no auth, database 0.
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
    @username : String?
    @password : String?
    @db : Int32?
    @max_bulk_size : Int32

    # Connects to *url* (or `DEFAULT_URL`) and runs the handshake: `HELLO 3`
    # (falling back to RESP2 if the server does not understand it, unless
    # *protocol* is `2`, which skips `HELLO` and speaks RESP2 with legacy
    # `AUTH`/`CLIENT SETNAME`), then `SELECT` if a database is set. *db*,
    # *username* and *password* override the corresponding parts of *url*
    # (its path/`?db=` query parameter and userinfo). Raises `ArgumentError`
    # for an unsupported URL scheme, an invalid database, or *protocol*
    # outside `2..3`; raises `ConnectionError` if the socket cannot be
    # opened; raises `CommandError` if the server rejects the handshake
    # (for example a bad password).
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
        return db.to_i? || raise ArgumentError.new("invalid database in URL #{url}: #{db.inspect}")
      end
      # For unix schemes the path is the socket path, not a database index.
      return nil if url.scheme == "redis+unix" || url.scheme == "unix"
      path = url.path
      return nil if path.empty? || path == "/"
      path.lchop('/').to_i? || raise ArgumentError.new("invalid database in URL #{url}: #{path.inspect}")
    end

    # :nodoc:
    def self.open_socket(url : URI, connect_timeout : Time::Span, read_timeout : Time::Span?,
                         tls_context : OpenSSL::SSL::Context::Client?) : IO
      case url.scheme
      when "redis", "rediss"
        host = url.host.presence || "localhost"
        port = url.port || 6379
        tcp = TCPSocket.new(host, port, connect_timeout: connect_timeout)
        begin
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
        rescue ex : IO::Error | OpenSSL::SSL::Error
          tcp.close rescue nil
          raise ex
        end
      when "redis+unix", "unix"
        sock = UNIXSocket.new(url.path)
        begin
          sock.sync = false
          sock.read_timeout = read_timeout if read_timeout
          sock
        rescue ex : IO::Error
          sock.close rescue nil
          raise ex
        end
      else
        raise ArgumentError.new("unsupported URL scheme #{url.scheme.inspect}; expected redis, rediss or redis+unix")
      end
    rescue ex : IO::Error | OpenSSL::SSL::Error
      raise ConnectionError.new("failed to connect to #{url}: #{ex.message}", cause: ex)
    end

    private def handshake(client_name : String?) : Nil
      # True whenever the legacy `AUTH`/`CLIENT SETNAME` commands must run:
      # either `HELLO` was never attempted (caller asked for RESP2 up
      # front) or it was attempted and the server rejected it. A `HELLO`
      # that *succeeds* never re-sends AUTH/SETNAME, whatever `proto` it
      # reports back.
      hello_failed = @protocol != 3
      if @protocol == 3
        args = Array(RESP::Arg).new(7)
        args << "HELLO" << "3"
        if password = @password
          args << "AUTH" << (@username || "default") << password
        end
        args << "SETNAME" << client_name if client_name
        begin
          reply = call(args)
          if proto = Connection.proto_from(reply)
            @protocol = proto
          end
        rescue ex : CommandError
          fallback = ex.code == "NOPROTO" || (ex.code == "ERR" && ex.message.to_s.includes?("unknown command"))
          raise ex unless fallback
          @protocol = 2
          hello_failed = true
        end
      end
      if hello_failed
        if password = @password
          # Pre-6.0 servers (the only ones that reject `HELLO`) only
          # understand single-argument `AUTH`; the two-argument form is a
          # 6.0+ addition. `HELLO`'s own `AUTH` above is unaffected: it
          # only ever runs against a 6.0+ server by construction.
          if username = @username
            call({"AUTH", username, password})
          else
            call({"AUTH", password})
          end
        end
        call({"CLIENT", "SETNAME", client_name}) if client_name
      end
      if (db = @db) && db != 0
        call({"SELECT", db})
      end
    end

    # :nodoc:
    #
    # The negotiated protocol version out of a `HELLO` reply, or `nil` if
    # none is present. Accepts the RESP3 map shape and, for servers that
    # answer `HELLO` with a flat array instead, scans it as key-value pairs.
    def self.proto_from(reply : Value) : Int32?
      case reply
      when Hash
        proto = reply["proto"]?
        proto.is_a?(Int64) ? proto.to_i : nil
      when Array
        i = 0
        while i < reply.size - 1
          if reply[i] == "proto" && (proto = reply[i + 1]).is_a?(Int64)
            return proto.to_i
          end
          i += 2
        end
        nil
      else
        nil
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
    def send(args : Indexable) : Nil
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
    rescue ex : ProtocolError
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
    def call(args : Indexable) : Value
      send(args)
      read
    end

    # :nodoc:
    def typed_call(args : Indexable, &block : Value -> T) forall T
      block.call(call(args))
    end

    # Sends every command in *commands*, flushes once, then reads every
    # reply in order. Error replies are returned as `CommandError` values.
    def pipeline(commands : Indexable) : Array(Value)
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
    rescue ex : ProtocolError
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

    # Whether `close` has been called (or a connection failure closed the
    # socket internally).
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
