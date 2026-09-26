require "./error"
require "uri"

module Postgres
  # How TLS is negotiated with the server, as libpq's `sslmode`.
  enum SSLMode
    # Never use TLS.
    Disable
    # Use TLS when the server supports it, else fall back to plain text.
    Prefer
    # Require TLS but do not verify the server certificate.
    Require
    # Require TLS and verify the certificate chain.
    VerifyCA
    # Require TLS, verify the certificate chain and the host name.
    VerifyFull

    # Parses a libpq `sslmode` value: `disable`, `prefer`, `require`,
    # `verify-ca` or `verify-full`. Raises `ArgumentError` otherwise.
    def self.from_param(s : String) : SSLMode
      case s
      when "disable"     then Disable
      when "prefer"      then Prefer
      when "require"     then Require
      when "verify-ca"   then VerifyCA
      when "verify-full" then VerifyFull
      else
        raise ArgumentError.new("Invalid sslmode: #{s.inspect} (expected disable, prefer, require, verify-ca or verify-full)")
      end
    end

    # Returns the libpq spelling of this mode (`"verify-ca"`, ...).
    def to_param : String
      case self
      in Disable    then "disable"
      in Prefer     then "prefer"
      in Require    then "require"
      in VerifyCA   then "verify-ca"
      in VerifyFull then "verify-full"
      end
    end
  end

  # Connection settings resolved from a URL, keyword overrides, the `PG*`
  # environment variables and defaults, in that priority: overrides beat
  # the URL, which beats the environment, which beats the defaults.
  #
  # ```
  # config = Postgres::Config.parse("postgres://alice:secret@db.example:5433/app?sslmode=require")
  # config.host    # => "db.example"
  # config.sslmode # => Postgres::SSLMode::Require
  # ```
  #
  # `#inspect` and `#to_s` never reveal the password.
  struct Config
    # The server host name or address, or a Unix socket directory (starting
    # with `/`). Defaults to `"localhost"`.
    getter host : String

    # The server port (also used in the Unix socket file name). Defaults to `5432`.
    getter port : Int32

    # The role to connect as. Defaults to `$PGUSER`, then `$USER`, then `"postgres"`.
    getter user : String

    # The password, if any.
    getter password : String?

    # The database name. Defaults to `#user`.
    getter database : String

    # The TLS negotiation mode. Defaults to `SSLMode::Prefer`.
    getter sslmode : SSLMode

    # Path of a PEM file of trusted root certificates for `verify-ca` and
    # `verify-full`.
    getter sslrootcert : String?

    # The `application_name` startup parameter, if any.
    getter application_name : String?

    # How long to wait for the connection to be established. Defaults to 10 seconds.
    getter connect_timeout : Time::Span

    # The Unix socket file (`"<host>/.s.PGSQL.<port>"`) when `#host` is a
    # directory, else `nil`.
    getter socket_path : String?

    # The number of prepared statements cached per connection (`0`
    # disables the cache). Defaults to `256`.
    getter statement_cache_size : Int32

    # :nodoc:
    DEFAULT_HOST = "localhost"
    # :nodoc:
    DEFAULT_PORT = 5432
    # :nodoc:
    DEFAULT_CONNECT_TIMEOUT = 10.seconds
    # :nodoc:
    DEFAULT_STATEMENT_CACHE_SIZE = 256

    # :nodoc:
    def initialize(@host, @port, @user, @password, @database, @sslmode, @sslrootcert,
                   @application_name, @connect_timeout, @statement_cache_size)
      @socket_path = @host.starts_with?('/') ? "#{@host}/.s.PGSQL.#{@port}" : nil
    end

    # Resolves a configuration.
    #
    # *url* is a `postgres://` or `postgresql://` URL of the form
    # `postgres://user:password@host:port/database?key=value&...`; every
    # part is optional and percent-decoded (a `+` stays a `+`). Accepted
    # query keys are `sslmode`, `sslrootcert`, `application_name`,
    # `connect_timeout` (integer seconds), `host` (a value starting with
    # `/` is a Unix socket directory), `port`, `user`, `password`, `dbname`
    # and `statement_cache_size`; query values override the corresponding
    # URL parts. Any other key raises `ArgumentError`, as in libpq. A
    # bracketed IPv6 host (`[::1]`) yields the bare address.
    #
    # When *url* is given as a `URI`, its user and password are taken
    # as already decoded by `URI.parse`.
    #
    # The keyword arguments override the URL. Settings still missing are
    # read from `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`,
    # `PGSSLMODE`, `PGSSLROOTCERT`, `PGAPPNAME` and `PGCONNECT_TIMEOUT`
    # (`USER` is the fallback for the user) in *env*, which defaults to the
    # process environment (`ENV`) when `nil`; pass a hash to isolate from it.
    #
    # Raises `ArgumentError` for a bad scheme, an unknown query key, or an
    # invalid port, timeout, cache size or sslmode.
    def self.parse(url : String | URI | Nil = nil, *, env : Hash(String, String)? = nil,
                   host : String? = nil, port : Int32? = nil, user : String? = nil, password : String? = nil,
                   database : String? = nil, sslmode : SSLMode? = nil, sslrootcert : String? = nil,
                   application_name : String? = nil, connect_timeout : Time::Span? = nil,
                   statement_cache_size : Int32? = nil) : Config
      from_url = url ? URLParts.parse(url) : URLParts.new

      getenv = ->(key : String) do
        value = env ? env[key]? : ENV[key]?
        value.presence
      end

      if port
        check_port(port)
      end
      if connect_timeout && connect_timeout <= Time::Span.zero
        raise ArgumentError.new("Invalid connect_timeout: #{connect_timeout} (must be positive)")
      end
      if statement_cache_size && statement_cache_size < 0
        raise ArgumentError.new("Invalid statement_cache_size: #{statement_cache_size} (must not be negative)")
      end

      r_host = host || from_url.host || getenv.call("PGHOST") || DEFAULT_HOST
      r_port = port || from_url.port || getenv.call("PGPORT").try { |v| parse_port(v) } || DEFAULT_PORT
      r_user = user || from_url.user || getenv.call("PGUSER") || getenv.call("USER") || "postgres"
      r_password = password || from_url.password || getenv.call("PGPASSWORD")
      r_database = database || from_url.database || getenv.call("PGDATABASE") || r_user
      r_sslmode = sslmode || from_url.sslmode || getenv.call("PGSSLMODE").try { |v| SSLMode.from_param(v) } || SSLMode::Prefer
      r_sslrootcert = sslrootcert || from_url.sslrootcert || getenv.call("PGSSLROOTCERT")
      r_app = application_name || from_url.application_name || getenv.call("PGAPPNAME")
      r_timeout = connect_timeout || from_url.connect_timeout ||
                  getenv.call("PGCONNECT_TIMEOUT").try { |v| parse_timeout(v) } || DEFAULT_CONNECT_TIMEOUT
      r_cache = statement_cache_size || from_url.statement_cache_size || DEFAULT_STATEMENT_CACHE_SIZE

      new(r_host, r_port, r_user, r_password, r_database, r_sslmode, r_sslrootcert, r_app, r_timeout, r_cache)
    end

    # Writes a representation of this configuration with the password
    # replaced by `[FILTERED]`.
    def inspect(io : IO) : Nil
      io << "Postgres::Config(host: " << @host.inspect
      io << ", port: " << @port
      io << ", user: " << @user.inspect
      io << ", password: " << (@password ? "[FILTERED]" : "nil")
      io << ", database: " << @database.inspect
      io << ", sslmode: " << @sslmode
      io << ", sslrootcert: " << @sslrootcert.inspect
      io << ", application_name: " << @application_name.inspect
      io << ", connect_timeout: " << @connect_timeout
      io << ", socket_path: " << @socket_path.inspect
      io << ", statement_cache_size: " << @statement_cache_size
      io << ')'
    end

    # Same as `#inspect`: the password is never shown.
    def to_s(io : IO) : Nil
      inspect(io)
    end

    # :nodoc:
    def self.parse_port(value : String) : Int32
      port = value.to_i? || raise ArgumentError.new("Invalid port: #{value.inspect}")
      check_port(port)
      port
    end

    # :nodoc:
    def self.check_port(port : Int32) : Nil
      unless 0 < port <= 65535
        raise ArgumentError.new("Invalid port: #{port} (must be between 1 and 65535)")
      end
    end

    # :nodoc:
    def self.parse_timeout(value : String) : Time::Span
      seconds = value.to_i?
      unless seconds && seconds > 0
        raise ArgumentError.new("Invalid connect_timeout: #{value.inspect} (must be a positive integer of seconds)")
      end
      seconds.seconds
    end

    # :nodoc:
    def self.parse_statement_cache_size(value : String) : Int32
      size = value.to_i?
      unless size && size >= 0
        raise ArgumentError.new("Invalid statement_cache_size: #{value.inspect} (must be a non-negative integer)")
      end
      size
    end

    # :nodoc:
    #
    # The settings found in a URL, each `nil` when absent.
    struct URLParts
      property host : String?
      property port : Int32?
      property user : String?
      property password : String?
      property database : String?
      property sslmode : SSLMode?
      property sslrootcert : String?
      property application_name : String?
      property connect_timeout : Time::Span?
      property statement_cache_size : Int32?

      def initialize
      end

      def self.parse(url : URI) : URLParts
        parse_uri(url, url.user, url.password, url.query)
      end

      def self.parse(url : String) : URLParts
        # `URI.parse` decodes userinfo as x-www-form (`+` becomes a space),
        # so the userinfo is split off and percent-decoded here.
        user = nil
        password = nil
        rest = url
        if sep = url.index("://")
          authority_start = sep + 3
          authority_end = url.index(/[\/?#]/, authority_start) || url.size
          if at = url.rindex('@', authority_end - 1)
            if at >= authority_start
              userinfo = url[authority_start...at]
              raw_user, colon, raw_password = userinfo.partition(':')
              user = URI.decode(raw_user)
              password = URI.decode(raw_password) unless colon.empty?
              rest = url[0...authority_start] + url[(at + 1)..]
            end
          end
        end

        uri = begin
          URI.parse(rest)
        rescue ex : URI::Error
          raise ArgumentError.new("Invalid PostgreSQL URL: #{ex.message}")
        end
        parse_uri(uri, user, password, uri.query)
      end

      private def self.parse_uri(uri : URI, user : String?, password : String?, query : String?) : URLParts
        scheme = uri.scheme
        unless scheme == "postgres" || scheme == "postgresql"
          raise ArgumentError.new("Invalid PostgreSQL URL scheme: #{scheme.inspect} (expected postgres or postgresql)")
        end

        parts = new
        parts.user = user.presence
        parts.password = password
        parts.host = uri.hostname.presence
        parts.port = uri.port.try { |port| Config.check_port(port); port }

        path = uri.path
        path = path[1..] if path.starts_with?('/')
        parts.database = URI.decode(path).presence

        (query || "").split('&').each do |pair|
          next if pair.empty?
          raw_key, _, raw_value = pair.partition('=')
          key = URI.decode(raw_key)
          value = URI.decode(raw_value)
          case key
          when "sslmode"              then parts.sslmode = SSLMode.from_param(value)
          when "sslrootcert"          then parts.sslrootcert = value.presence
          when "application_name"     then parts.application_name = value.presence
          when "connect_timeout"      then parts.connect_timeout = Config.parse_timeout(value)
          when "host"                 then parts.host = URI.unwrap_ipv6(value).presence
          when "port"                 then parts.port = Config.parse_port(value)
          when "user"                 then parts.user = value.presence
          when "password"             then parts.password = value
          when "dbname"               then parts.database = value.presence
          when "statement_cache_size" then parts.statement_cache_size = Config.parse_statement_cache_size(value)
          else
            raise ArgumentError.new("Unknown PostgreSQL URL parameter: #{key.inspect}")
          end
        end

        parts
      end
    end
  end
end
