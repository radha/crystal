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

  # Which kind of server a connection attempt accepts, as libpq's
  # `target_session_attrs`. With several hosts, servers that do not match
  # are skipped.
  enum TargetSessionAttrs
    # Any server is acceptable.
    Any
    # The session must accept writes (`transaction_read_only` is off).
    ReadWrite
    # The session must be read-only (`transaction_read_only` is on).
    ReadOnly
    # The server must not be in hot standby.
    Primary
    # The server must be in hot standby.
    Standby
    # A standby is preferred; any server is accepted when none is found.
    PreferStandby

    # Parses a libpq `target_session_attrs` value: `any`, `read-write`,
    # `read-only`, `primary`, `standby` or `prefer-standby`. Raises
    # `ArgumentError` otherwise.
    def self.from_param(s : String) : TargetSessionAttrs
      case s
      when "any"            then Any
      when "read-write"     then ReadWrite
      when "read-only"      then ReadOnly
      when "primary"        then Primary
      when "standby"        then Standby
      when "prefer-standby" then PreferStandby
      else
        raise ArgumentError.new("Invalid target_session_attrs: #{s.inspect} (expected any, read-write, read-only, primary, standby or prefer-standby)")
      end
    end

    # Returns the libpq spelling of this value (`"read-write"`, ...).
    def to_param : String
      case self
      in Any           then "any"
      in ReadWrite     then "read-write"
      in ReadOnly      then "read-only"
      in Primary       then "primary"
      in Standby       then "standby"
      in PreferStandby then "prefer-standby"
      end
    end
  end

  # The order in which several hosts are tried, as libpq's
  # `load_balance_hosts`.
  enum LoadBalanceHosts
    # Hosts are tried in the order given.
    Disable
    # Hosts are tried in a random order.
    Random

    # Parses a libpq `load_balance_hosts` value: `disable` or `random`.
    # Raises `ArgumentError` otherwise.
    def self.from_param(s : String) : LoadBalanceHosts
      case s
      when "disable" then Disable
      when "random"  then Random
      else
        raise ArgumentError.new("Invalid load_balance_hosts: #{s.inspect} (expected disable or random)")
      end
    end

    # Returns the libpq spelling of this value.
    def to_param : String
      case self
      in Disable then "disable"
      in Random  then "random"
      end
    end
  end

  # Connection settings resolved, as in libpq, from (highest priority
  # first) keyword overrides, a URL, a service file entry, the `PG*`
  # environment variables and defaults. A password missing from all of
  # these is looked up in the password file (`~/.pgpass`).
  #
  # ```
  # config = Postgres::Config.parse("postgres://alice:secret@db.example:5433/app?sslmode=require")
  # config.host    # => "db.example"
  # config.sslmode # => Postgres::SSLMode::Require
  # ```
  #
  # Several hosts may be given (`postgres://h1,h2:5433/app`); `#hosts`
  # lists them and `#host`, `#port` and `#socket_path` describe the first.
  #
  # `#inspect` and `#to_s` never reveal the password.
  struct Config
    # One server to try: a host name or address with a port, or a Unix
    # socket directory.
    struct Host
      # The host name or address, or a Unix socket directory (starting with `/`).
      getter host : String

      # The port (also used in the Unix socket file name).
      getter port : Int32

      # The Unix socket file (`"<host>/.s.PGSQL.<port>"`) when `#host` is a
      # directory, else `nil`.
      getter socket_path : String?

      # Creates a host entry; a *host* starting with `/` is a Unix socket
      # directory.
      def initialize(@host : String, @port : Int32)
        @socket_path = @host.starts_with?('/') ? "#{@host}/.s.PGSQL.#{@port}" : nil
      end

      # Returns `true` if this entry is a Unix socket directory.
      def unix_socket? : Bool
        !@socket_path.nil?
      end

      # Writes the socket path, or `host:port` (with an IPv6 address in
      # brackets).
      def to_s(io : IO) : Nil
        if path = @socket_path
          io << path
        elsif @host.includes?(':')
          io << '[' << @host << "]:" << @port
        else
          io << @host << ':' << @port
        end
      end

      # Same as `#to_s`.
      def inspect(io : IO) : Nil
        to_s(io)
      end
    end

    # The servers to try, in the order given. Never empty.
    getter hosts : Array(Host)

    # The role to connect as. Defaults to `$PGUSER`, then `$USER`, then `"postgres"`.
    getter user : String

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

    # The number of prepared statements cached per connection (`0`
    # disables the cache). Defaults to `256`.
    getter statement_cache_size : Int32

    # The `options` startup parameter (command-line options for the
    # server, such as `"-c search_path=app"`), if any.
    getter options : String?

    # Which kind of server is acceptable. Defaults to `TargetSessionAttrs::Any`.
    getter target_session_attrs : TargetSessionAttrs

    # Whether `#ordered_hosts` shuffles the hosts. Defaults to `LoadBalanceHosts::Disable`.
    getter load_balance_hosts : LoadBalanceHosts

    # The password file consulted when no password was given, or `nil`
    # when there is none to consult.
    getter passfile : String?

    # The password given by keyword, URL, service file or `PGPASSWORD`.
    @explicit_password : String?
    # The password file match for each of `@hosts`.
    @file_passwords : Array(String?)

    # :nodoc:
    DEFAULT_HOST = "localhost"
    # :nodoc:
    DEFAULT_PORT = 5432
    # :nodoc:
    DEFAULT_CONNECT_TIMEOUT = 10.seconds
    # :nodoc:
    DEFAULT_STATEMENT_CACHE_SIZE = 256

    # :nodoc:
    def initialize(@hosts : Array(Host), @user : String, @explicit_password : String?, @database : String,
                   @sslmode : SSLMode, @sslrootcert : String?, @application_name : String?,
                   @connect_timeout : Time::Span, @statement_cache_size : Int32, @options : String?,
                   @target_session_attrs : TargetSessionAttrs, @load_balance_hosts : LoadBalanceHosts,
                   @passfile : String?)
      @file_passwords = if @explicit_password.presence
                          [] of String?
                        else
                          entries = PassFile.read(@passfile)
                          @hosts.map { |h| PassFile.lookup(entries, h, @database, @user) }
                        end
    end

    # The first host's name or address, or Unix socket directory.
    def host : String
      @hosts.first.host
    end

    # The first host's port.
    def port : Int32
      @hosts.first.port
    end

    # The first host's Unix socket file, or `nil` when it is not a socket
    # directory.
    def socket_path : String?
      @hosts.first.socket_path
    end

    # The password for the first host: see `#password_for`.
    def password : String?
      password_for(@hosts.first)
    end

    # Returns the password to use with *host*: the one given by keyword,
    # URL, service file or `PGPASSWORD` when not empty, else the first
    # matching line of the password file (`#passfile`), else `nil`. As in
    # libpq, a Unix socket host matches the `localhost` host name there.
    def password_for(host : Host) : String?
      if (explicit = @explicit_password) && !explicit.empty?
        return explicit
      end
      from_file = if index = @hosts.index(host)
                    @file_passwords[index]?
                  else
                    PassFile.lookup(PassFile.read(@passfile), host, @database, @user)
                  end
      from_file || @explicit_password
    end

    # Returns the hosts in the order to try them: as given, or shuffled
    # with *random* when `#load_balance_hosts` is `LoadBalanceHosts::Random`.
    def ordered_hosts(random : ::Random = ::Random::DEFAULT) : Array(Host)
      if @load_balance_hosts.random?
        @hosts.shuffle(random)
      else
        @hosts.dup
      end
    end

    # Resolves a configuration.
    #
    # *url* is a `postgres://` or `postgresql://` URL of the form
    # `postgres://user:password@host:port,host:port/database?key=value&...`;
    # every part is optional and percent-decoded (a `+` stays a `+`). A
    # bracketed IPv6 host (`[::1]`) yields the bare address and a host
    # starting with `/` (such as `%2Ftmp`) is a Unix socket directory.
    # Accepted query keys are `sslmode`, `sslrootcert`, `application_name`,
    # `connect_timeout` (integer seconds), `host` and `port` (comma
    # separated lists; a single port applies to every host), `user`,
    # `password`, `dbname`, `options`, `service`, `passfile`,
    # `target_session_attrs`, `load_balance_hosts` and
    # `statement_cache_size`; query values override the corresponding URL
    # parts. Any other key raises `ArgumentError`, as in libpq.
    #
    # When *url* is given as a `URI`, its user and password are taken
    # as already decoded by `URI.parse`, and it names a single host.
    #
    # The keyword arguments override the URL; *host* may be a comma
    # separated list and *search_path* appends `-c search_path=...` to the
    # options. A service (keyword, URL `service` or `PGSERVICE`) is looked
    # up in `PGSERVICEFILE` (default `~/.pg_service.conf`), then in
    # `PGSYSCONFDIR/pg_service.conf`; its settings apply below the URL.
    # Settings still missing are read from `PGHOST`, `PGPORT`, `PGUSER`,
    # `PGPASSWORD`, `PGDATABASE`, `PGSSLMODE`, `PGSSLROOTCERT`, `PGAPPNAME`,
    # `PGCONNECT_TIMEOUT`, `PGOPTIONS`, `PGTARGETSESSIONATTRS`,
    # `PGLOADBALANCEHOSTS` and `PGPASSFILE` (`USER` is the fallback for the
    # user) in *env*, which defaults to the process environment (`ENV`)
    # when `nil`; pass a hash to isolate from it.
    #
    # Without a password, the password file (`passfile`, else `PGPASSFILE`,
    # else `~/.pgpass` with `HOME` from *env*) is consulted; it is skipped
    # when missing or readable by group or others.
    #
    # Raises `ArgumentError` for a bad scheme, an unknown query or service
    # file key, an unknown service, a port list that does not match the
    # host list, or an invalid port, timeout, cache size or enum value.
    def self.parse(url : String | URI | Nil = nil, *, env : Hash(String, String)? = nil,
                   host : String? = nil, port : Int32? = nil, user : String? = nil, password : String? = nil,
                   database : String? = nil, sslmode : SSLMode? = nil, sslrootcert : String? = nil,
                   application_name : String? = nil, connect_timeout : Time::Span? = nil,
                   statement_cache_size : Int32? = nil, service : String? = nil, options : String? = nil,
                   search_path : String? = nil, target_session_attrs : TargetSessionAttrs? = nil,
                   load_balance_hosts : LoadBalanceHosts? = nil, passfile : String? = nil) : Config
      from_url = url ? Params.parse_url(url) : Params.new

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

      kw_hosts = host.try { |h| split_hosts(h) }
      kw_ports = port.try { |p| [p.as(Int32?)] }

      service_name = service.presence || from_url.service || getenv.call("PGSERVICE")
      from_service = service_name ? ServiceFile.lookup(service_name, getenv) : Params.new

      r_hosts = kw_hosts || from_url.hosts || from_service.hosts ||
                getenv.call("PGHOST").try { |v| split_hosts(v) } || [""]
      r_ports = kw_ports || from_url.ports || from_service.ports ||
                getenv.call("PGPORT").try { |v| split_ports(v) } || [nil.as(Int32?)]
      hosts = build_hosts(r_hosts, r_ports)

      r_user = user || from_url.user || from_service.user || getenv.call("PGUSER") || getenv.call("USER") || "postgres"
      r_password = password || from_url.password || from_service.password || getenv.call("PGPASSWORD")
      r_database = database || from_url.database || from_service.database || getenv.call("PGDATABASE") || r_user
      r_sslmode = sslmode || from_url.sslmode || from_service.sslmode ||
                  getenv.call("PGSSLMODE").try { |v| SSLMode.from_param(v) } || SSLMode::Prefer
      r_sslrootcert = sslrootcert || from_url.sslrootcert || from_service.sslrootcert || getenv.call("PGSSLROOTCERT")
      r_app = application_name || from_url.application_name || from_service.application_name || getenv.call("PGAPPNAME")
      r_timeout = connect_timeout || from_url.connect_timeout || from_service.connect_timeout ||
                  getenv.call("PGCONNECT_TIMEOUT").try { |v| parse_timeout(v) } || DEFAULT_CONNECT_TIMEOUT
      r_cache = statement_cache_size || from_url.statement_cache_size || DEFAULT_STATEMENT_CACHE_SIZE
      r_options = options.presence || from_url.options || from_service.options || getenv.call("PGOPTIONS")
      if search_path
        r_options = [r_options, "-c search_path=#{escape_option(search_path)}"].compact.join(' ')
      end
      r_attrs = target_session_attrs || from_url.target_session_attrs || from_service.target_session_attrs ||
                getenv.call("PGTARGETSESSIONATTRS").try { |v| TargetSessionAttrs.from_param(v) } || TargetSessionAttrs::Any
      r_balance = load_balance_hosts || from_url.load_balance_hosts || from_service.load_balance_hosts ||
                  getenv.call("PGLOADBALANCEHOSTS").try { |v| LoadBalanceHosts.from_param(v) } || LoadBalanceHosts::Disable
      r_passfile = passfile.presence || from_url.passfile || from_service.passfile ||
                   getenv.call("PGPASSFILE") || default_passfile(getenv)

      new(hosts, r_user, r_password, r_database, r_sslmode, r_sslrootcert, r_app, r_timeout, r_cache,
        r_options, r_attrs, r_balance, r_passfile)
    end

    # Writes a representation of this configuration with the password
    # replaced by `[FILTERED]`.
    def inspect(io : IO) : Nil
      io << "Postgres::Config(host: " << host.inspect
      io << ", port: " << port
      io << ", hosts: [" << @hosts.join(", ") << ']'
      io << ", user: " << @user.inspect
      io << ", password: " << (password ? "[FILTERED]" : "nil")
      io << ", database: " << @database.inspect
      io << ", sslmode: " << @sslmode
      io << ", sslrootcert: " << @sslrootcert.inspect
      io << ", application_name: " << @application_name.inspect
      io << ", connect_timeout: " << @connect_timeout
      io << ", socket_path: " << socket_path.inspect
      io << ", statement_cache_size: " << @statement_cache_size
      io << ", options: " << @options.inspect
      io << ", target_session_attrs: " << @target_session_attrs
      io << ", load_balance_hosts: " << @load_balance_hosts
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
    # Splits a comma separated host list (`nil` when every entry is empty);
    # brackets around IPv6 addresses are removed.
    def self.split_hosts(value : String) : Array(String)?
      hosts = value.split(',').map { |h| URI.unwrap_ipv6(h) }
      hosts.all?(&.empty?) ? nil : hosts
    end

    # :nodoc:
    #
    # Splits a comma separated port list; an empty entry means the default
    # port. `nil` when every entry is empty.
    def self.split_ports(value : String) : Array(Int32?)?
      ports = value.split(',').map { |p| p.empty? ? nil : parse_port(p) }
      ports.all?(&.nil?) ? nil : ports
    end

    # :nodoc:
    #
    # Pairs hosts with ports as libpq does: a single port applies to every
    # host, otherwise the lists must have the same length.
    def self.build_hosts(hosts : Array(String), ports : Array(Int32?)) : Array(Host)
      unless ports.size == 1 || ports.size == hosts.size
        raise ArgumentError.new("Could not match #{ports.size} port numbers to #{hosts.size} hosts")
      end
      hosts.map_with_index do |h, i|
        Host.new(h.empty? ? DEFAULT_HOST : h, ports[ports.size == 1 ? 0 : i] || DEFAULT_PORT)
      end
    end

    # :nodoc:
    #
    # Escapes whitespace and backslashes for the server's `options` parsing.
    def self.escape_option(value : String) : String
      String.build do |io|
        value.each_char do |char|
          io << '\\' if char == '\\' || char.whitespace?
          io << char
        end
      end
    end

    # :nodoc:
    def self.default_passfile(getenv : String -> String?) : String?
      {% if flag?(:win32) %}
        getenv.call("APPDATA").try { |dir| File.join(dir, "postgresql", "pgpass.conf") }
      {% else %}
        getenv.call("HOME").try { |dir| File.join(dir, ".pgpass") }
      {% end %}
    end

    # :nodoc:
    #
    # Settings found in a URL or a service file entry, each `nil` when absent.
    class Params
      property hosts : Array(String)?
      property ports : Array(Int32?)?
      property user : String?
      property password : String?
      property database : String?
      property sslmode : SSLMode?
      property sslrootcert : String?
      property application_name : String?
      property connect_timeout : Time::Span?
      property statement_cache_size : Int32?
      property options : String?
      property service : String?
      property target_session_attrs : TargetSessionAttrs?
      property load_balance_hosts : LoadBalanceHosts?
      property passfile : String?

      def initialize
      end

      # Applies a key shared by URLs and service files; returns `false`
      # for an unknown key.
      def set(key : String, value : String) : Bool
        case key
        when "host"                 then @hosts = Config.split_hosts(value)
        when "port"                 then @ports = Config.split_ports(value)
        when "user"                 then @user = value.presence
        when "password"             then @password = value
        when "dbname"               then @database = value.presence
        when "sslmode"              then @sslmode = SSLMode.from_param(value)
        when "sslrootcert"          then @sslrootcert = value.presence
        when "application_name"     then @application_name = value.presence
        when "connect_timeout"      then @connect_timeout = Config.parse_timeout(value)
        when "options"              then @options = value.presence
        when "target_session_attrs" then @target_session_attrs = TargetSessionAttrs.from_param(value)
        when "load_balance_hosts"   then @load_balance_hosts = LoadBalanceHosts.from_param(value)
        when "passfile"             then @passfile = value.presence
        else                             return false
        end
        true
      end

      def self.parse_url(url : URI) : Params
        check_scheme(url.scheme)
        params = new
        params.user = url.user.presence
        params.password = url.password
        params.hosts = url.hostname.presence.try { |h| [h] }
        params.ports = url.port.try { |port| Config.check_port(port); [port.as(Int32?)] }
        params.parse_path_and_query(url.path, url.query)
        params
      end

      def self.parse_url(url : String) : Params
        sep = url.index("://")
        check_scheme(sep ? url[0, sep] : nil)
        sep = sep.not_nil!

        authority_start = sep + 3
        authority_end = url.index(/[\/?#]/, authority_start) || url.size
        authority = url[authority_start...authority_end]
        rest = url[authority_end..]
        rest = rest[0, rest.index('#') || rest.size]

        params = new
        if at = authority.rindex('@')
          userinfo = authority[0...at]
          authority = authority[(at + 1)..]
          raw_user, colon, raw_password = userinfo.partition(':')
          params.user = URI.decode(raw_user).presence
          params.password = URI.decode(raw_password) unless colon.empty?
        end
        params.parse_hostspec(authority)

        path, _, query = rest.partition('?')
        params.parse_path_and_query(path, query)
        params
      end

      private def self.check_scheme(scheme : String?) : Nil
        unless scheme == "postgres" || scheme == "postgresql"
          raise ArgumentError.new("Invalid PostgreSQL URL scheme: #{scheme.inspect} (expected postgres or postgresql)")
        end
      end

      # Parses `host:port,[v6]:port,...`.
      protected def parse_hostspec(spec : String) : Nil
        return if spec.empty?
        hosts = [] of String
        ports = [] of Int32?
        spec.split(',').each do |entry|
          if entry.starts_with?('[')
            close = entry.index(']') || raise ArgumentError.new("Invalid PostgreSQL URL: unterminated IPv6 address in #{entry.inspect}")
            host = entry[1...close]
            tail = entry[(close + 1)..]
            unless tail.empty? || tail.starts_with?(':')
              raise ArgumentError.new("Invalid PostgreSQL URL: unexpected #{tail.inspect} after IPv6 address")
            end
            port = tail.empty? ? "" : tail[1..]
          else
            raw_host, _, port = entry.partition(':')
            host = URI.decode(raw_host)
          end
          hosts << host
          ports << (port.empty? ? nil : Config.parse_port(port))
        end
        @hosts = hosts.all?(&.empty?) ? nil : hosts
        @ports = ports.all?(&.nil?) ? nil : ports
      end

      protected def parse_path_and_query(path : String, query : String?) : Nil
        path = path[1..] if path.starts_with?('/')
        @database = URI.decode(path).presence

        (query || "").split('&').each do |pair|
          next if pair.empty?
          raw_key, _, raw_value = pair.partition('=')
          key = URI.decode(raw_key)
          value = URI.decode(raw_value)
          next if set(key, value)
          case key
          when "statement_cache_size" then @statement_cache_size = Config.parse_statement_cache_size(value)
          when "service"              then @service = value.presence
          else
            raise ArgumentError.new("Unknown PostgreSQL URL parameter: #{key.inspect}")
          end
        end
      end
    end

    # :nodoc:
    #
    # Connection service file lookup (`pg_service.conf`).
    module ServiceFile
      def self.lookup(name : String, getenv : String -> String?) : Params
        user_file = getenv.call("PGSERVICEFILE") || Config.default_service_file(getenv)
        files = [user_file, getenv.call("PGSYSCONFDIR").try { |dir| File.join(dir, "pg_service.conf") }]
        files.each do |path|
          next unless path
          if params = read(path, name)
            return params
          end
        end
        raise ArgumentError.new("Definition of service #{name.inspect} not found")
      end

      # Returns the settings of section *name* in *path*, or `nil` when the
      # file does not exist or has no such section.
      def self.read(path : String, name : String) : Params?
        return nil unless File.file?(path)
        params : Params? = nil
        File.each_line(path, chomp: true) do |raw|
          line = raw.strip
          next if line.empty? || line.starts_with?('#')
          if line.starts_with?('[')
            break if params # only the first matching section counts
            params = Params.new if line == "[#{name}]"
            next
          end
          next unless current = params
          key, eq, value = line.partition('=')
          key = key.strip
          value = value.strip
          if eq.empty?
            raise ArgumentError.new("Syntax error in service file #{path.inspect}: #{line.inspect}")
          end
          case key
          when "service"
            raise ArgumentError.new("Nested service specifications not supported in service file #{path.inspect}")
          when "hostaddr"
            current.hosts ||= Config.split_hosts(value)
          else
            unless current.set(key, value)
              raise ArgumentError.new("Unknown service file parameter #{key.inspect} in #{path.inspect}")
            end
          end
        end
        params
      end
    end

    # :nodoc:
    def self.default_service_file(getenv : String -> String?) : String?
      {% if flag?(:win32) %}
        getenv.call("APPDATA").try { |dir| File.join(dir, "postgresql", ".pg_service.conf") }
      {% else %}
        getenv.call("HOME").try { |dir| File.join(dir, ".pg_service.conf") }
      {% end %}
    end

    # :nodoc:
    #
    # Password file (`.pgpass`) parsing and matching, as in libpq.
    module PassFile
      # Returns the lines of *path* split into five unescaped fields, with
      # `nil` for a `*` wildcard; empty when the file is missing, not a
      # regular file, or accessible by group or others.
      def self.read(path : String?) : Array(Array(String?))
        entries = [] of Array(String?)
        return entries unless path
        info = File.info?(path)
        return entries unless info && info.file?
        {% unless flag?(:win32) %}
          return entries if info.permissions.value & 0o077 != 0
        {% end %}
        File.each_line(path, chomp: true) do |line|
          line = line.rchop('\r')
          next if line.empty? || line.starts_with?('#')
          if fields = split(line)
            entries << fields
          end
        end
        entries
      rescue File::Error
        [] of Array(String?)
      end

      # Splits a line at unescaped colons; `nil` if it has fewer than five
      # fields. A backslash escapes the next character; an unescaped colon
      # ends the password.
      def self.split(line : String) : Array(String?)?
        fields = [] of String?
        field = String::Builder.new
        literal = false # whether the field has an escaped character
        chars = line.chars
        i = 0
        while i < chars.size
          char = chars[i]
          i += 1
          if char == '\\' && i < chars.size
            field << chars[i]
            literal = true
            i += 1
          elsif char == ':'
            break if fields.size == 4
            text = field.to_s
            fields << (!literal && text == "*" ? nil : text)
            field = String::Builder.new
            literal = false
          else
            field << char
          end
        end
        return nil unless fields.size == 4
        fields << field.to_s
        fields
      end

      # Returns the password of the first entry matching *host*, *database*
      # and *user*, or `nil` (also for an empty password).
      def self.lookup(entries : Array(Array(String?)), host : Host, database : String, user : String) : String?
        return nil if entries.empty?
        hostname = host.unix_socket? ? "localhost" : host.host
        port = host.port.to_s
        entries.each do |fields|
          next unless matches?(fields[0], hostname) && matches?(fields[1], port) &&
                      matches?(fields[2], database) && matches?(fields[3], user)
          return fields[4].presence
        end
        nil
      end

      private def self.matches?(field : String?, value : String) : Bool
        field.nil? || field == value
      end
    end
  end
end
