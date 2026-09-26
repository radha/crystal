require "pool"
require "./connection"

module Postgres
  # A fiber-safe PostgreSQL client backed by a pool of `Connection`s.
  # Nothing connects until the first query; each query method borrows a
  # connection for the call, `query_each` for the whole iteration, and
  # `transaction`/`with_connection` for the block.
  #
  # ```
  # db = Postgres::Client.new("postgres://app@localhost/app_dev", pool_size: 16)
  # 64.times { spawn { db.query_one("select $1::int", 1, as: Int32) } }
  # db.transaction do |tx|
  #   tx.exec("update accounts set balance = balance - $1 where id = $2", 10, 1)
  # end
  # db.close
  # ```
  #
  # A connection that failed (closed by a `ConnectionError`,
  # `IO::TimeoutError` or `ProtocolError`) is dropped from the pool and the
  # error raised; queries are never retried automatically. Connections
  # idle for a second or more are checked with an empty query before they
  # are handed out.
  class Client
    # The settings every connection is opened with.
    getter config : Config

    @pool : Pool(Connection)

    # Creates a client for *url* and the connection keywords of
    # `Config.parse`. At most *pool_size* connections are open at once; a
    # caller waits up to *checkout_timeout* for one and then gets
    # `Pool::TimeoutError`. *read_timeout* and *tls_context* are those of
    # `Connection.new`.
    def self.new(url : String | URI | Nil = nil, *, pool_size : Int32 = 10, checkout_timeout : Time::Span = 5.seconds,
                 read_timeout : Time::Span? = nil, tls_context : OpenSSL::SSL::Context::Client? = nil,
                 host : String? = nil, port : Int32? = nil, user : String? = nil, password : String? = nil,
                 database : String? = nil, sslmode : SSLMode? = nil, sslrootcert : String? = nil,
                 application_name : String? = nil, connect_timeout : Time::Span? = nil,
                 statement_cache_size : Int32? = nil, service : String? = nil, options : String? = nil,
                 search_path : String? = nil, target_session_attrs : TargetSessionAttrs? = nil,
                 load_balance_hosts : LoadBalanceHosts? = nil, passfile : String? = nil,
                 channel_binding : Auth::ChannelBinding? = nil) : self
      config = Config.parse(url, host: host, port: port, user: user, password: password, database: database,
        sslmode: sslmode, sslrootcert: sslrootcert, application_name: application_name,
        connect_timeout: connect_timeout, statement_cache_size: statement_cache_size, service: service,
        options: options, search_path: search_path, target_session_attrs: target_session_attrs,
        load_balance_hosts: load_balance_hosts, passfile: passfile, channel_binding: channel_binding)
      new(config: config, pool_size: pool_size, checkout_timeout: checkout_timeout,
        read_timeout: read_timeout, tls_context: tls_context)
    end

    # Creates a client for *config*.
    def initialize(*, @config : Config, pool_size : Int32 = 10, checkout_timeout : Time::Span = 5.seconds,
                   read_timeout : Time::Span? = nil, @tls_context : OpenSSL::SSL::Context::Client? = nil)
      config = @config
      tls_context = @tls_context
      @pool = Pool(Connection).new(size: pool_size, checkout_timeout: checkout_timeout,
        health_check: ->(conn : Connection) { conn.ping; true }) do
        Connection.new(config: config, read_timeout: read_timeout, tls_context: tls_context)
      end
    end

    # See `Connection#exec`.
    def exec(sql : String, *args) : ExecResult
      @pool.checkout(&.exec(sql, *args))
    end

    # See `Connection#query_all`.
    def query_all(sql : String, *args, as type : T.class) : Array(T) forall T
      @pool.checkout(&.query_all(sql, *args, as: T))
    end

    # See `Connection#query_one`.
    def query_one(sql : String, *args, as type : T.class) : T forall T
      @pool.checkout(&.query_one(sql, *args, as: T))
    end

    # See `Connection#query_one?`.
    def query_one?(sql : String, *args, as type : T.class) : T? forall T
      @pool.checkout(&.query_one?(sql, *args, as: T))
    end

    ::Postgres.def_tuple_queries(query_all, query_one, query_one?)

    # :ditto:
    def query_each(sql : String, *args, as types : Tuple, &) : Nil
      query_each(sql, *args, as: ::Postgres.tuple_type(types)) { |row| yield row }
    end

    # See `Connection#query_each`. One connection is held until the
    # iteration ends.
    def query_each(sql : String, *args, as type : T.class, & : T ->) : Nil forall T
      @pool.checkout do |conn|
        conn.query_each(sql, *args, as: T) { |value| yield value }
      end
    end

    # Runs the block in a transaction on one borrowed connection; see
    # `Connection#transaction`.
    def transaction(*, isolation : Connection::Isolation? = nil, read_only : Bool? = nil, & : Connection -> T) : T forall T
      @pool.checkout do |conn|
        conn.transaction(isolation: isolation, read_only: read_only) { |tx| yield tx }
      end
    end

    # Borrows a connection for the block, for session state (`SET`,
    # temporary tables, advisory locks) that must stay on one session.
    def with_connection(& : Connection -> T) : T forall T
      @pool.checkout { |conn| yield conn }
    end

    # Sends `NOTIFY` on *channel* with *payload*; see `Connection#notify`.
    def notify(channel : String, payload : String = "") : Nil
      @pool.checkout(&.notify(channel, payload))
    end

    # Opens a `Listener` on a connection of its own (not from the pool)
    # with this client's settings.
    def listener(*, capacity : Int32 = 256, reconnect : Bool = true) : Listener
      Listener.new(config: @config, capacity: capacity, reconnect: reconnect, tls_context: @tls_context)
    end

    # Open connections waiting in the pool.
    def idle : Int32
      @pool.idle
    end

    # Connections currently borrowed.
    def in_use : Int32
      @pool.in_use
    end

    # Whether `close` has been called.
    def closed? : Bool
      @pool.closed?
    end

    # Closes idle connections now and borrowed ones when they come back.
    # Later calls raise `Pool::ClosedError`.
    def close : Nil
      @pool.close
    end
  end
end
