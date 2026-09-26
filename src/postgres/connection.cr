require "socket"
require "openssl"
require "./error"
require "./config"
require "./auth"
require "./oid"
require "./messages"
require "./result"
require "./codec"
require "./statement_cache"
require "./serializable"

module Postgres
  # A notice or warning the server sent (`NoticeResponse`), with the same
  # fields as a `QueryError`.
  struct Notice
    # Every field by its one-letter code (`'M'` is the message).
    getter fields : Hash(Char, String)

    def initialize(@fields : Hash(Char, String))
    end

    # `NOTICE`, `WARNING`, `INFO`, ...
    def severity : String
      @fields['V']? || @fields['S']? || "NOTICE"
    end

    # The primary message.
    def message : String
      @fields['M']? || ""
    end

    # The SQLSTATE code.
    def code : String
      @fields['C']? || ""
    end
  end

  # A `NOTIFY` delivered to a session that `LISTEN`s on its channel.
  struct Notification
    # The server process that sent it.
    getter pid : Int32
    # The channel name.
    getter channel : String
    # The payload (empty when none was given).
    getter payload : String

    def initialize(@pid : Int32, @channel : String, @payload : String)
    end
  end

  # One PostgreSQL session. Not fiber-safe: use `Client` (or a `Pool`) to
  # share connections between fibers.
  #
  # ```
  # conn = Postgres::Connection.new("postgres://app@localhost/app_dev")
  # conn.exec("create temp table t (id int, name text)")
  # conn.exec("insert into t values ($1, $2)", 1, "one")
  # conn.query_one("select count(*) from t", as: Int64) # => 1
  # conn.close
  # ```
  #
  # Queries with arguments, and every `query_*` call, use the extended
  # protocol: the SQL is prepared once per connection (a `Parse` +
  # `Describe` round trip) and kept in an LRU of `statement_cache_size`
  # statements, so later calls cost one round trip. Parameters and results
  # travel in binary. `exec` without arguments uses the simple protocol,
  # which accepts several statements separated by `;`.
  #
  # An error reply raises `QueryError` and leaves the connection usable. When
  # a query exceeds `read_timeout` it is cancelled (a `CancelRequest` on a
  # side connection) and `IO::TimeoutError` is raised with the session
  # still usable; if the server does not answer the cancel within another
  # `read_timeout`, the connection is closed. An I/O failure raises
  # `ConnectionError` and malformed input `ProtocolError`; both close the
  # connection.
  class Connection
    # Isolation levels for `transaction`.
    enum Isolation
      ReadUncommitted
      ReadCommitted
      RepeatableRead
      Serializable

      # :nodoc:
      def to_sql : String
        case self
        in ReadUncommitted then "READ UNCOMMITTED"
        in ReadCommitted   then "READ COMMITTED"
        in RepeatableRead  then "REPEATABLE READ"
        in Serializable    then "SERIALIZABLE"
        end
      end
    end

    # Run-time parameters the server reported (`server_version`,
    # `server_encoding`, `TimeZone`, ...), kept current.
    getter parameters = {} of String => String
    # The server process id serving this session.
    getter backend_pid : Int32 = 0
    # `'I'` idle, `'T'` in a transaction, `'E'` in a failed transaction.
    getter transaction_status : Char = 'I'
    # The settings this connection was opened with.
    getter config : Config
    # Called for each `NoticeResponse`; notices are dropped when nil.
    property on_notice : Proc(Notice, Nil)? = nil
    # Called for each notification this session receives while it runs a
    # query (after a `LISTEN` on it); dropped when nil. A `Listener`
    # receives them while idle too.
    property on_notification : Proc(Notification, Nil)? = nil

    # Placeholders until `connect_to` opens the real socket.
    @io : IO = IO::Memory.new
    @socket : IO = IO::Memory.new
    @host : Config::Host?
    @out = IO::Memory.new
    @buffer = Bytes.new(8192)
    @closed = false
    @busy = false
    @secret : Int32 = 0
    @transaction_depth = 0
    # The `read_timeout` that triggered a cancel still being answered.
    @timed_out : IO::TimeoutError?
    @tls_context : OpenSSL::SSL::Context::Client?
    @cache : StatementCache
    @types = TypeMap.new
    @reader : RowReader?

    # Opens a session with *config* (see `Config.parse`).
    #
    # With several hosts they are tried in order (shuffled with
    # `load_balance_hosts=random`) until one accepts the login and matches
    # `target_session_attrs`; `prefer-standby` makes a first pass for
    # standbys only. With one host its own error is raised; with several a
    # `ConnectionError` lists what each one answered.
    def initialize(*, @config : Config, @read_timeout : Time::Span? = nil,
                   @tls_context : OpenSSL::SSL::Context::Client? = nil)
      @cache = StatementCache.new(@config.statement_cache_size)
      wanted = @config.target_session_attrs
      passes = wanted.prefer_standby? ? [TargetSessionAttrs::Standby, TargetSessionAttrs::Any] : [wanted]
      hosts = @config.ordered_hosts
      failures = [] of {Config::Host, Exception}
      passes.each do |pass|
        hosts.each do |host|
          begin
            connect_to(host)
            return if session_matches?(pass)
            raise ConnectionError.new("server is not #{pass.to_param} (target_session_attrs)")
          rescue ex
            close_quietly
            failures << {host, ex}
          end
        end
      end
      @closed = true
      raise failures[0][1] if failures.size == 1
      summary = failures.join("; ") { |host, ex| "#{host}: #{ex.message}" }
      if failures.all? { |_, ex| ex.is_a?(AuthenticationError) }
        raise AuthenticationError.new(summary, cause: failures.last[1])
      end
      raise ConnectionError.new("no host accepted the connection: #{summary}", cause: failures.last[1])
    end

    # The host this session is connected to.
    def host : Config::Host
      @host.not_nil!
    end

    private def connect_to(host : Config::Host) : Nil
      @closed = false
      @host = host
      @parameters.clear
      @backend_pid = 0
      @socket = open_socket(host)
      @io = @socket
      if host.unix_socket? || @config.sslmode.disable?
        if @config.channel_binding.require?
          raise AuthenticationError.new("channel_binding=require needs a TLS connection")
        end
      else
        @io = negotiate_tls(@socket, @tls_context, host)
      end
      startup
    end

    # Whether the server is acceptable for *wanted*: PostgreSQL 14+ reports
    # `in_hot_standby` and `default_transaction_read_only`; older servers
    # are asked.
    private def session_matches?(wanted : TargetSessionAttrs) : Bool
      return true if wanted.any?
      standby = if (value = @parameters["in_hot_standby"]?)
                  value == "on"
                else
                  query_one("select pg_is_in_recovery()", as: Bool)
                end
      read_only = standby || if (value = @parameters["default_transaction_read_only"]?)
        value == "on"
      else
        query_one("show transaction_read_only", as: String) == "on"
      end
      case wanted
      when .read_write? then !read_only
      when .read_only?  then read_only
      when .primary?    then !standby
      when .standby?    then standby
      else                   true
      end
    end

    # Opens a session with settings from *url*, the connection keywords of
    # `Config.parse`, and the `PG*` environment. *read_timeout* bounds each
    # read from the server; *tls_context* replaces the context built from
    # `sslmode`. Raises `ConnectionError`, or `AuthenticationError` if the
    # server rejects the credentials.
    def self.new(url : String | URI | Nil = nil, *, read_timeout : Time::Span? = nil,
                 tls_context : OpenSSL::SSL::Context::Client? = nil, host : String? = nil, port : Int32? = nil,
                 user : String? = nil, password : String? = nil, database : String? = nil,
                 sslmode : SSLMode? = nil, sslrootcert : String? = nil, application_name : String? = nil,
                 connect_timeout : Time::Span? = nil, statement_cache_size : Int32? = nil, service : String? = nil, options : String? = nil, search_path : String? = nil, target_session_attrs : TargetSessionAttrs? = nil, load_balance_hosts : LoadBalanceHosts? = nil, passfile : String? = nil, channel_binding : Auth::ChannelBinding? = nil) : self
      config = Config.parse(url, host: host, port: port, user: user, password: password, database: database,
        sslmode: sslmode, sslrootcert: sslrootcert, application_name: application_name,
        connect_timeout: connect_timeout, statement_cache_size: statement_cache_size, service: service,
        options: options, search_path: search_path, target_session_attrs: target_session_attrs,
        load_balance_hosts: load_balance_hosts, passfile: passfile, channel_binding: channel_binding)
      new(config: config, read_timeout: read_timeout, tls_context: tls_context)
    end

    # The server version as a number, e.g. `160013` for 16.13.
    def server_version : Int32
      # "16.13 (Ubuntu 16.13-0ubuntu0.24.04.1)" → 160013.
      parts = (@parameters["server_version"]? || "").split(/[^0-9]/, 3)
      (parts[0]?.try(&.to_i?) || 0) * 10000 + (parts[1]?.try(&.to_i?) || 0)
    end

    # Whether the session runs over TLS.
    def tls? : Bool
      @io.is_a?(OpenSSL::SSL::Socket)
    end

    # The number of statements in the cache.
    def statement_cache_size : Int32
      @cache.size
    end

    # Forgets every cached statement, closing them server-side with the
    # next round trip.
    def clear_statement_cache : Nil
      @cache.clear
    end

    # Runs *sql* and returns what the command reported. With *args* it is
    # prepared and bound like a query (`$1`, `$2`, ...); without, it goes
    # through the simple protocol and may hold several statements, in which
    # case the last one's result is returned.
    def exec(sql : String) : ExecResult
      simple_query(sql)
    end

    # :ditto:
    def exec(sql : String, *args) : ExecResult
      extended(sql, args, want_result: true) { }
    end

    # Runs *sql* and decodes every row as *type*: a `Serializable` struct or
    # class, or a single-column scalar type (`Int64`, `String`, `Time?`, ...).
    def query_all(sql : String, *args, as type : T.class) : Array(T) forall T
      rows = [] of T
      extended(sql, args) { |row| rows << Connection.decode_row(row, T) }
      rows
    end

    ::Postgres.def_tuple_queries(query_all, query_one, query_one?)

    # Like the `as type : T.class` form, with rows read as a tuple of
    # *types* by column position.
    def query_each(sql : String, *args, as types : Tuple, &) : Nil
      query_each(sql, *args, as: ::Postgres.tuple_type(types)) { |row| yield row }
    end

    # Runs *sql* and yields each row decoded as *type* as it arrives,
    # without buffering the result. The connection is busy until the
    # iteration ends; if the block raises, the rest of the result is read
    # and discarded before the exception propagates.
    def query_each(sql : String, *args, as type : T.class, & : T ->) : Nil forall T
      extended(sql, args) { |row| yield Connection.decode_row(row, T) }
    end

    # Runs *sql* and returns the first row decoded as *type*, ignoring the
    # rest. Raises `NoRowsError` if there is none.
    def query_one(sql : String, *args, as type : T.class) : T forall T
      found = false
      value = uninitialized T
      extended(sql, args) do |row|
        unless found
          value = Connection.decode_row(row, T)
          found = true
        end
      end
      raise NoRowsError.new("no rows returned by #{sql.inspect}") unless found
      value
    end

    # Like `query_one`, but returns `nil` when there is no row.
    def query_one?(sql : String, *args, as type : T.class) : T? forall T
      result = nil
      extended(sql, args) do |row|
        result = Connection.decode_row(row, T) if result.nil?
      end
      result
    end

    # Runs the block in a transaction and returns its value: `BEGIN`, then
    # `COMMIT` when the block returns, `ROLLBACK` when it raises (and the
    # exception propagates). Nested calls use savepoints. A block that
    # rescued a `QueryError` leaves the transaction aborted; `COMMIT` would
    # then silently roll back, so this raises `Error` after the rollback.
    def transaction(*, isolation : Isolation? = nil, read_only : Bool? = nil, & : Connection -> T) : T forall T
      depth = @transaction_depth
      if depth == 0
        sql = String.build do |s|
          s << "BEGIN"
          s << " ISOLATION LEVEL " << isolation.to_sql if isolation
          s << (read_only ? " READ ONLY" : " READ WRITE") unless read_only.nil?
        end
        simple_query(sql)
      else
        raise ArgumentError.new("isolation and read_only apply to the outermost transaction only") if isolation || !read_only.nil?
        simple_query("SAVEPOINT sp#{depth}")
      end
      @transaction_depth += 1
      begin
        value = yield self
      rescue ex
        @transaction_depth = depth
        unless @closed
          begin
            simple_query(depth == 0 ? "ROLLBACK" : "ROLLBACK TO SAVEPOINT sp#{depth}; RELEASE SAVEPOINT sp#{depth}")
          rescue QueryError | ConnectionError | IO::TimeoutError | ProtocolError
            # The original exception matters more; a broken connection is
            # closed by now and the pool drops it.
          end
        end
        raise ex
      end
      @transaction_depth = depth
      if depth == 0
        if @transaction_status == 'E'
          simple_query("ROLLBACK")
          raise Error.new("transaction was aborted by an earlier error and has been rolled back")
        end
        simple_query("COMMIT")
      else
        simple_query("RELEASE SAVEPOINT sp#{depth}")
      end
      value
    end

    # Sends an empty query: a cheap round trip that proves the session is
    # alive.
    def ping : Nil
      simple_query("")
    end

    # Whether `close` was called or a failure closed the connection.
    def closed? : Bool
      @closed
    end

    # Ends the session (`Terminate`) and closes the socket. Idempotent.
    def close : Nil
      return if @closed
      @closed = true
      begin
        @io.write(Messages::TERMINATE)
        @io.flush
      rescue
      end
      @io.close rescue nil
      @socket.close rescue nil
    end

    # :nodoc:
    def self.decode_row(row : RowReader, type : T.class) : T forall T
      {% if T.class.has_method?(:from_pg_row) %}
        T.from_pg_row(row)
      {% elsif T < Tuple %}
        # One composite column read as a tuple of its fields.
        {% if T.type_vars.size > 1 %}
          if row.size == 1 && row.columns[0].codec_oid == OID::RECORD
            return row.read(0, T)
          end
        {% end %}
        unless row.size == {{ T.type_vars.size }}
          raise DecodeError.new("#{T} reads {{ T.type_vars.size }} columns, but the result has #{row.size}")
        end
        { {% for i in 0...T.type_vars.size %} row.read({{ i }}, typeof(Pointer(T).null.value[{{ i }}])), {% end %} }
      {% else %}
        unless row.size == 1
          raise DecodeError.new("#{T} reads a single column, but the result has #{row.size}")
        end
        row.read(0, T)
      {% end %}
    end

    # Sends `NOTIFY` on *channel* with *payload* (through `pg_notify`, so
    # any channel name and payload are safe to pass).
    def notify(channel : String, payload : String = "") : Nil
      exec("select pg_notify($1, $2)", channel, payload)
    end

    # :nodoc:
    #
    # For `Listener`, which owns this connection's reads: writes a `Query`
    # without reading the reply.
    def unsafe_send_query(sql : String) : Nil
      raise ConnectionError.new("connection is closed") if @closed
      Messages::Query.new(query: sql).write(@out)
      flush
    end

    # :nodoc:
    #
    # For `Listener`: the next message other than `ParameterStatus` and
    # notices (which are handled). The body is valid until the next read.
    def unsafe_read_message : {Char, Bytes}
      loop do
        type, body = read_message
        next if (type == 'S' || type == 'N') && handle_async(type, body)
        return {type, body}
      end
    end

    # :nodoc:
    def unsafe_notification(body : Bytes) : Notification
      n = parse { Messages::NotificationResponse.from_slice(body) }
      Notification.new(n.pid, n.channel, n.payload)
    end

    # :nodoc:
    def unsafe_query_error(body : Bytes) : QueryError
      parse { query_error(body) }
    end

    # --- connecting -------------------------------------------------------

    private def open_socket(host : Config::Host) : IO
      socket = if path = host.socket_path
                 UNIXSocket.new(path)
               else
                 TCPSocket.new(host.host, host.port, connect_timeout: @config.connect_timeout).tap(&.tcp_nodelay = true)
               end
      socket.read_timeout = @read_timeout
      socket.sync = false
      socket
    rescue ex : Socket::Error | IO::Error
      raise ConnectionError.new("cannot connect to #{host}: #{ex.message}", cause: ex)
    end

    private def negotiate_tls(socket : IO, context : OpenSSL::SSL::Context::Client?, host : Config::Host) : IO
      Messages::SSLRequest.new.write(socket)
      socket.flush
      answer = socket.read_byte || raise ConnectionError.new("server closed the connection during SSLRequest")
      case answer.chr
      when 'S'
        context ||= tls_context
        hostname = @config.sslmode.verify_full? ? host.host : nil
        begin
          OpenSSL::SSL::Socket::Client.new(socket, context: context, sync_close: true, hostname: hostname).tap(&.sync = false)
        rescue ex : OpenSSL::Error | IO::Error
          raise ConnectionError.new("TLS handshake failed: #{ex.message}", cause: ex)
        end
      when 'N'
        return socket if @config.sslmode.prefer?
        raise ConnectionError.new("server does not support TLS (sslmode=#{@config.sslmode.to_param})")
      else
        raise ProtocolError.new("unexpected SSLRequest answer #{answer.chr.inspect}")
      end
    end

    private def tls_context : OpenSSL::SSL::Context::Client
      context = OpenSSL::SSL::Context::Client.new
      case @config.sslmode
      when .verify_ca?, .verify_full?
        context.verify_mode = OpenSSL::SSL::VerifyMode::PEER
        @config.sslrootcert.try { |path| context.ca_certificates = path }
      else
        context.verify_mode = OpenSSL::SSL::VerifyMode::NONE
      end
      context
    end

    private def startup : Nil
      scram_verified = false
      params = ["user", @config.user, "database", @config.database, "client_encoding", "UTF8"]
      @config.application_name.try { |name| params << "application_name" << name }
      @config.options.try { |options| params << "options" << options }
      Messages::Startup.new(params: params).write(@out)
      flush
      scram = nil
      loop do
        type, body = read_message
        case type
        when 'R'
          code = be(Int32, body, 0)
          case code
          when 0 # AuthenticationOk
            # With channel_binding=require only a verified SCRAM-PLUS
            # exchange may end here; otherwise a server using trust (or
            # a man in the middle) could skip the binding.
            if @config.channel_binding.require? && !(scram_verified && scram.try(&.mechanism) == Auth::Scram::MECHANISM_PLUS)
              raise AuthenticationError.new("channel_binding=require, but the server authenticated without SCRAM-SHA-256-PLUS")
            end
          when 3 # CleartextPassword
            refuse_without_binding("cleartext")
            Messages::Password.new(password: password!("cleartext")).write(@out)
            flush
          when 5 # MD5Password
            refuse_without_binding("md5")
            Messages::Password.new(password: Auth.md5_password(@config.user, password!("md5"), body[4, 4])).write(@out)
            flush
          when 10 # SASL
            mechanisms = cstrings(body + 4)
            certificate_hash = @io.as?(OpenSSL::SSL::Socket).try { |tls| Auth.certificate_hash(tls) }
            scram = Auth::Scram.negotiate(mechanisms, password!("SCRAM-SHA-256"),
              certificate_hash: certificate_hash, channel_binding: @config.channel_binding)
            Messages::SASLInitialResponse.new(mechanism: scram.mechanism, data: scram.client_first_message).write(@out)
            flush
          when 11 # SASLContinue
            s = scram || raise ProtocolError.new("SASLContinue without SASL")
            Messages::SASLResponse.new(data: s.client_final_message(String.new(body + 4))).write(@out)
            flush
          when 12 # SASLFinal
            s = scram || raise ProtocolError.new("SASLFinal without SASL")
            s.verify_server_final(String.new(body + 4))
            scram_verified = true
          else
            raise AuthenticationError.new("unsupported authentication method #{code}")
          end
        when 'K'
          key = parse { Messages::BackendKeyData.from_slice(body) }
          @backend_pid = key.pid
          @secret = key.secret
        when 'Z'
          @transaction_status = ready_status(body)
          break
        when 'E'
          fields = parse { error_fields(body) }
          message = QueryError.format(fields)
          raise AuthenticationError.new(message) if fields['C']?.try(&.starts_with?("28"))
          raise ConnectionError.new(message)
        else
          handle_async(type, body) || raise ProtocolError.new("unexpected #{type.inspect} during startup")
        end
      end
      unless @parameters["integer_datetimes"]? == "on"
        raise ConnectionError.new("server uses floating-point datetimes, which are not supported")
      end
    end

    private def refuse_without_binding(method : String) : Nil
      return unless @config.channel_binding.require?
      raise AuthenticationError.new("channel_binding=require, but the server asked for #{method} authentication")
    end

    private def password!(method : String) : String
      @config.password_for(host) || raise AuthenticationError.new("server requested #{method} authentication but no password was given")
    end

    # --- query paths ------------------------------------------------------

    private def simple_query(sql : String) : ExecResult
      enter
      begin
        flush_closes
        Messages::Query.new(query: sql).write(@out)
        flush
        result = ExecResult.new("", 0_i64)
        error = nil
        loop do
          type, body = read_message
          case type
          when 'C' then result = ExecResult.from_tag(parse { Messages::CommandComplete.from_slice(body) }.tag)
          when 'T', 'D', 'I', '3'
            # Rows of a simple query are not returned; empty query; the
            # `CloseComplete`s of queued statement closes.
          when 'E' then error ||= parse { query_error(body) }
          when 'Z'
            @transaction_status = ready_status(body)
            break
          else
            handle_async(type, body) || unexpected(type)
          end
        end
        raise error if error
        result
      ensure
        leave
      end
    end

    # Prepares (or finds) *sql*, binds *args*, executes and yields each
    # `DataRow` through a `RowReader`. Retries once after the server
    # dropped a cached statement, when that is safe (outside a transaction).
    private def extended(sql : String, args : Tuple, want_result : Bool = false, & : RowReader ->) : ExecResult
      enter
      begin
        idle = @transaction_status == 'I'
        begin
          run_extended(sql, args, want_result) { |row| yield row }
        rescue ex : StaleStatement
          raise ex.error unless idle
          run_extended(sql, args, want_result) { |row| yield row }
        end
      ensure
        leave
      end
    end

    # :nodoc:
    class StaleStatement < Exception
      getter error : QueryError

      def initialize(@error : QueryError)
        super(@error.message)
      end
    end

    private def run_extended(sql : String, args : Tuple, want_result : Bool, & : RowReader ->) : ExecResult
      statement = prepare(sql)
      unless args.size == statement.param_oids.size
        raise ArgumentError.new("query expects #{statement.param_oids.size} parameters, got #{args.size}")
      end
      # Queued closes go after `Bind`, so an argument that fails to encode
      # (which discards the half-written `Bind`) cannot drop them.
      begin
        Connection.write_bind(@out, statement, args)
      rescue ex : EncodeError
        @out.clear
        raise ex
      end
      flush_closes
      Messages::Execute.new(portal: "").write(@out)
      @out.write(Messages::SYNC)
      flush
      reader = @reader ||= RowReader.new(statement.columns)
      reader.reset(statement.columns)
      result = ExecResult.new("", 0_i64)
      error = nil
      failure = nil
      loop do
        type, body = read_message
        case type
        when 'D'
          next if error || failure
          parse { reader.load(body) }
          begin
            yield reader
          rescue ex
            # Keep reading to `ReadyForQuery` so the connection stays in
            # step, then raise.
            failure = ex
          end
        when 'C'
          # Only `exec` reports the tag; `query_*` skip building it.
          result = ExecResult.from_tag(parse { Messages::CommandComplete.from_slice(body) }.tag) if want_result
        when '2', '3', 'I', 'n', 's'
        when 'E' then error ||= parse { query_error(body) }
        when 'Z'
          @transaction_status = ready_status(body)
          break
        else
          handle_async(type, body) || unexpected(type)
        end
      end
      if error
        if statement.name.empty? || !stale?(error)
          raise error
        end
        @cache.forget(sql)
        raise StaleStatement.new(error)
      end
      raise failure if failure
      result
    end

    # `0A000` "cached plan must not change result type" after a schema
    # change, `26000` "prepared statement does not exist" after
    # `DEALLOCATE`/`DISCARD ALL`.
    private def stale?(error : QueryError) : Bool
      case error.code
      when "0A000"
        error.detail_message.includes?("cached plan")
      when "26000"
        @cache.reset
        true
      else
        false
      end
    end

    private def prepare(sql : String) : PreparedStatement
      if @cache.enabled? && (cached = @cache[sql])
        return cached
      end
      name = @cache.enabled? ? @cache.next_name : ""
      flush_closes
      Messages::Parse.new(name: name, query: sql, oids: [] of UInt32).write(@out)
      Messages::Describe.new(kind: 'S'.ord.to_u8, name: name).write(@out)
      @out.write(Messages::SYNC)
      flush
      param_oids = [] of UInt32
      columns = [] of Column
      error = nil
      loop do
        type, body = read_message
        case type
        when 't'
          param_oids = parse { Messages::ParameterDescription.from_slice(body) }.oids
        when 'T'
          columns = parse { Messages::RowDescription.from_slice(body) }.columns.map do |c|
            Column.new(c.name, c.type_oid, c.table_oid, c.type_modifier, c.format)
          end
        when '1', '3', 'n'
        when 'E' then error ||= parse { query_error(body) }
        when 'Z'
          @transaction_status = ready_status(body)
          break
        else
          handle_async(type, body) || unexpected(type)
        end
      end
      raise error if error
      introspect(param_oids + columns.map(&.type_oid))
      statement = PreparedStatement.new(name, param_oids, columns, @types)
      @cache.add(sql, statement) if @cache.enabled?
      statement
    end

    # Asks `pg_type` about the OIDs among *oids* the codec does not know
    # (domains, composites, arrays of those) and records the answers in
    # the connection's `TypeMap`. Its own query uses built-in types only,
    # so it cannot recurse. Arrays of unknown elements take a second round.
    private def introspect(oids : Enumerable(UInt32), depth : Int32 = 0) : Nil
      unknown = @types.unknown(oids)
      return if unknown.empty? || depth > 4
      rows = [] of {UInt32, String, UInt32, UInt32, UInt32, Array(UInt32)}
      run_extended(TypeMap::INTROSPECT, {unknown}, false) do |row|
        rows << {row.read(0, UInt32), row.read(1, String), row.read(2, UInt32), row.read(3, UInt32),
                 row.read(4, UInt32), row.read(5, Array(UInt32))}
      end
      # Array elements and composite fields first (an array resolves
      # through its element's entry; a record's fields are decoded by OID).
      dependencies = rows.flat_map { |r| r[5] + (r[3] == 0 ? [] of UInt32 : [r[3]]) } - unknown
      introspect(dependencies, depth + 1)
      rows.sort_by! { |r| r[3] == 0 ? 0 : 1 }
      rows.each { |oid, kind, base, element, base_array, _| @types.learn(oid, kind, base, element, base_array) }
    end

    # `Bind`: portal and statement names, parameter formats, values (each
    # length back-patched after encoding), result formats.
    #
    # Writes into *buf* (the connection's buffer or a pipeline's scratch
    # buffer). Raises `EncodeError` naming the parameter; the caller
    # discards the half-written message.
    protected def self.write_bind(buf : IO::Memory, statement : PreparedStatement, args : Tuple) : Nil
      buf.write_byte('B'.ord.to_u8)
      start = buf.pos
      buf.write_bytes(0_i32, IO::ByteFormat::BigEndian)
      buf.write_byte(0_u8) # unnamed portal
      buf << statement.name
      buf.write_byte(0_u8)
      buf.write_bytes(args.size.to_i16, IO::ByteFormat::BigEndian)
      formats_at = buf.pos
      args.size.times { buf.write_bytes(0_i16, IO::ByteFormat::BigEndian) }
      buf.write_bytes(args.size.to_i16, IO::ByteFormat::BigEndian)
      oids = statement.param_oids
      args.each_with_index do |arg, i|
        if arg.nil?
          buf.write_bytes(-1_i32, IO::ByteFormat::BigEndian)
        else
          length_at = buf.pos
          buf.write_bytes(0_i32, IO::ByteFormat::BigEndian)
          format = begin
            Codec.encode(buf, oids[i], arg)
          rescue ex : EncodeError
            raise EncodeError.new("parameter $#{i + 1}: #{ex.message}")
          end
          IO::ByteFormat::BigEndian.encode((buf.pos - length_at - 4).to_i32, buf.to_slice + length_at)
          IO::ByteFormat::BigEndian.encode(format, buf.to_slice + formats_at + i * 2) if format != 0
        end
      end
      formats = statement.result_formats
      buf.write_bytes(formats.size.to_i16, IO::ByteFormat::BigEndian)
      formats.each { |f| buf.write_bytes(f, IO::ByteFormat::BigEndian) }
      IO::ByteFormat::BigEndian.encode((buf.pos - start).to_i32, buf.to_slice + start)
    end

    private def patch(at : Int, value : Int32) : Nil
      IO::ByteFormat::BigEndian.encode(value, @out.to_slice + at)
    end

    # Queues the `Close` of evicted statements ahead of the next round trip;
    # their `CloseComplete`s are read with that round trip's replies.
    private def flush_closes : Nil
      closes = @cache.closes
      return if closes.empty?
      closes.each { |name| Messages::Close.new(kind: 'S'.ord.to_u8, name: name).write(@out) }
      closes.clear
    end

    private def enter : Nil
      raise ConnectionError.new("connection is closed") if @closed
      raise Error.new("connection is busy (a query_each block may not query the same connection)") if @busy
      @busy = true
    end

    private def leave : Nil
      @busy = false
    end

    # --- wire -------------------------------------------------------------

    private def flush : Nil
      @io.write(@out.to_slice)
      @io.flush
    rescue ex : IO::TimeoutError
      lost_timeout(ex)
    rescue ex : IO::Error | OpenSSL::SSL::Error
      lost(ex)
    ensure
      @out.clear
    end

    # Reads one backend message into the receive buffer and returns its
    # type and body; the body is valid until the next read.
    private def read_message : {Char, Bytes}
      wait_readable
      header = uninitialized UInt8[5]
      @io.read_fully(header.to_slice)
      type = header[0].unsafe_chr
      raw = IO::ByteFormat::BigEndian.decode(Int32, header.to_slice + 1)
      if raw < 4 || raw - 4 > MAX_MESSAGE_SIZE
        close_quietly
        raise ProtocolError.new("invalid message length #{raw} for #{type.inspect}")
      end
      length = raw - 4
      @buffer = Bytes.new(Math.pw2ceil(length)) if length > @buffer.size
      body = @buffer[0, length]
      @io.read_fully(body)
      {type, body}
    rescue ex : IO::TimeoutError
      lost_timeout(ex)
    rescue ex : IO::EOFError
      lost(ex, "server closed the connection")
    rescue ex : IO::Error | OpenSSL::SSL::Error
      lost(ex)
    end

    # Blocks until the next message starts arriving. A `read_timeout`
    # here, between messages, is recoverable: nothing was consumed, so
    # the running query is cancelled and reading goes on; the server
    # answers with an error and `ReadyForQuery`, where `ready_status`
    # raises `IO::TimeoutError` with the session in step. A second timeout
    # (the server ignored the cancel), one during startup, or one inside a
    # message closes the connection instead.
    private def wait_readable : Nil
      loop do
        begin
          @io.peek
          return
        rescue ex : IO::TimeoutError
          raise ex if @timed_out || @backend_pid == 0
          @timed_out = ex
          cancel_running_query
        end
      end
    end

    # Sends a `CancelRequest` for this session on a new connection and
    # waits for the server to close it (it does so once the cancel is
    # delivered), which narrows the race with a query that ends on its own
    # meanwhile. Failures are ignored: the next timeout closes the session.
    private def cancel_running_query : Nil
      socket = open_socket(host)
      begin
        io = tls? ? negotiate_tls(socket, @tls_context, host) : socket
        Messages::CancelRequest.new(pid: @backend_pid, secret: @secret).write(io)
        io.flush
        io.read_byte
      ensure
        socket.close
      end
    rescue Error | IO::Error | OpenSSL::Error
    end

    # Runs a decoder over a message body. A malformed body closes the
    # connection (it is out of step with the server) and raises
    # `ProtocolError`.
    private def parse(& : -> T) : T forall T
      yield
    rescue ex : ProtocolError
      close_quietly
      raise ex
    rescue ex : IO::EOFError | Binary::Error | IndexError | ArgumentError
      close_quietly
      raise ProtocolError.new("malformed message: #{ex.message}", cause: ex)
    end

    # The status byte of a `ReadyForQuery`.
    private def ready_status(body : Bytes) : Char
      unless body.size == 1
        close_quietly
        raise ProtocolError.new("ReadyForQuery with a #{body.size}-byte body")
      end
      status = body[0].unsafe_chr
      if timed_out = @timed_out
        # The query was cancelled after `read_timeout` (see `wait_readable`);
        # the session is in step again.
        @timed_out = nil
        @transaction_status = status
        raise IO::TimeoutError.new("#{timed_out.message}: query cancelled after read_timeout (#{@read_timeout})")
      end
      status
    end

    # The server's own limit on a message.
    MAX_MESSAGE_SIZE = 1 << 30

    # Handles messages that may arrive at any time. Returns false for any
    # other type.
    private def handle_async(type : Char, body : Bytes) : Bool
      case type
      when 'S'
        status = parse { Messages::ParameterStatus.from_slice(body) }
        @parameters[status.name] = status.value
      when 'N'
        @on_notice.try &.call(Notice.new(error_fields(body)))
      when 'A'
        if handler = @on_notification
          n = parse { Messages::NotificationResponse.from_slice(body) }
          handler.call(Notification.new(n.pid, n.channel, n.payload))
        end
      else
        return false
      end
      true
    end

    private def unexpected(type : Char) : NoReturn
      close
      raise ProtocolError.new("unexpected message #{type.inspect}")
    end

    private def query_error(body : Bytes) : QueryError
      QueryError.new(error_fields(body))
    end

    private def error_fields(body : Bytes) : Hash(Char, String)
      fields = {} of Char => String
      pos = 0
      while pos < body.size && (code = body[pos]) != 0
        stop = body.index(0_u8, pos + 1) || raise ProtocolError.new("unterminated error field")
        fields[code.unsafe_chr] = String.new(body[pos + 1, stop - pos - 1])
        pos = stop + 1
      end
      fields
    end

    private def cstrings(body : Bytes) : Array(String)
      list = [] of String
      pos = 0
      while pos < body.size && body[pos] != 0
        stop = body.index(0_u8, pos) || raise ProtocolError.new("unterminated string")
        list << String.new(body[pos, stop - pos])
        pos = stop + 1
      end
      list
    end

    private def be(type : T.class, body : Bytes, at : Int32) : T forall T
      raise ProtocolError.new("truncated message") if body.size < at + sizeof(T)
      IO::ByteFormat::BigEndian.decode(T, body + at)
    end

    private def lost(ex : Exception, message : String? = nil) : NoReturn
      close_quietly
      raise ConnectionError.new(message || "connection lost: #{ex.message}", cause: ex)
    end

    private def lost_timeout(ex : IO::TimeoutError) : NoReturn
      close_quietly
      raise ex
    end

    private def close_quietly : Nil
      @closed = true
      @io.close rescue nil
      @socket.close rescue nil
    end
  end
end
