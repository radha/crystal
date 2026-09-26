require "../../support/postgres"

# A port nothing listens on.
private def dead_port : Int32
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  server.close
  port
end

private def primary_port : Int32
  Postgres::Config.parse(PostgresSpec::URL).port
end

describe "Postgres connecting" do
  pending_postgres "fails over to the next host" do
    dead = dead_port
    conn = Postgres::Connection.new("postgres://postgres@127.0.0.1:#{dead},127.0.0.1:#{primary_port}/crystal_test?sslmode=disable",
      connect_timeout: 1.second)
    conn.host.port.should eq(primary_port)
    conn.query_one("select 1", as: Int32).should eq(1)
    conn.close
  end

  pending_postgres "lists every host's failure when none accepts" do
    a = dead_port
    b = dead_port
    error = expect_raises(Postgres::ConnectionError, /no host accepted the connection/) do
      Postgres::Connection.new("postgres://postgres@127.0.0.1:#{a},127.0.0.1:#{b}/crystal_test?sslmode=disable", connect_timeout: 1.second)
    end
    error.message.not_nil!.should contain("127.0.0.1:#{a}")
    error.message.not_nil!.should contain("127.0.0.1:#{b}")
    # One host: its own error.
    expect_raises(Postgres::ConnectionError, /cannot connect to 127.0.0.1:#{a}/) do
      Postgres::Connection.new("postgres://postgres@127.0.0.1:#{a}/crystal_test?sslmode=disable", connect_timeout: 1.second)
    end
  end

  pending_postgres "sends options and search_path at startup" do
    conn = Postgres::Connection.new(PostgresSpec::URL, search_path: "spec_schema, public", options: "-c statement_timeout=1234")
    begin
      conn.query_one("show search_path", as: String).should eq("spec_schema, public")
      conn.query_one("show statement_timeout", as: String).should eq("1234ms")
    ensure
      conn.close
    end
  end

  pending_postgres_env "POSTGRES_MD5_URL", "reads the password from a pgpass file" do |url|
    config = Postgres::Config.parse(url)
    File.tempfile("pgpass") do |file|
      file << "# comment\n" << "otherhost:*:*:*:nope\n"
      file << "127.0.0.1:" << config.port << ":*:" << config.user << ":" << config.password << "\n"
    end.tap do |file|
      File.chmod(file.path, 0o600)
      begin
        bare = "postgres://#{config.user}@127.0.0.1:#{config.port}/#{config.database}?sslmode=disable"
        conn = Postgres::Connection.new(bare, passfile: file.path)
        conn.query_one("select current_user", as: String).should eq(config.user)
        conn.close
        # A group-readable file is ignored, as libpq does.
        File.chmod(file.path, 0o644)
        expect_raises(Postgres::AuthenticationError, /no password was given/) { Postgres::Connection.new(bare, passfile: file.path) }
      ensure
        file.delete
      end
    end
  end

  pending_postgres "takes settings from a service file" do
    config = Postgres::Config.parse(PostgresSpec::URL)
    file = File.tempfile("pg_service") do |f|
      f << "[other]\nport=1\n\n[spec]\nhost=127.0.0.1\nport=" << config.port << "\ndbname=" << config.database
      f << "\nuser=" << config.user << "\napplication_name=from_service\nsslmode=disable\n"
    end
    begin
      conn = Postgres::Connection.new(config: Postgres::Config.parse(nil, service: "spec", env: {"PGSERVICEFILE" => file.path}))
      conn.query_one("show application_name", as: String).should eq("from_service")
      conn.close
    ensure
      file.delete
    end
  end

  pending_postgres_env "POSTGRES_STANDBY_URL", "picks servers by target_session_attrs" do |standby_url|
    standby = Postgres::Config.parse(standby_url)
    both = "postgres://postgres@127.0.0.1:#{standby.port},127.0.0.1:#{primary_port}/crystal_test?sslmode=disable"
    {
      "any"            => standby.port,
      "read-write"     => primary_port,
      "primary"        => primary_port,
      "read-only"      => standby.port,
      "standby"        => standby.port,
      "prefer-standby" => standby.port,
    }.each do |attrs, port|
      conn = Postgres::Connection.new("#{both}&target_session_attrs=#{attrs}")
      conn.host.port.should eq(port)
      conn.close
    end
    # prefer-standby falls back to a primary when no standby answers.
    only_primary = "postgres://postgres@127.0.0.1:#{primary_port}/crystal_test?sslmode=disable&target_session_attrs=prefer-standby"
    Postgres::Connection.new(only_primary).tap { |c| c.host.port.should eq(primary_port) }.close
    expect_raises(Postgres::ConnectionError, /not standby/) do
      Postgres::Connection.new("postgres://postgres@127.0.0.1:#{primary_port}/crystal_test?sslmode=disable&target_session_attrs=standby")
    end
    # A pooled client connects every connection to the primary.
    db = Postgres::Client.new("#{both}&target_session_attrs=read-write", pool_size: 2)
    db.query_one("select pg_is_in_recovery()", as: Bool).should be_false
    db.close
  end

  pending_postgres_env "POSTGRES_SSL_URL", "uses SCRAM-SHA-256-PLUS over TLS and enforces channel_binding=require" do |url|
    conn = Postgres::Connection.new(url, sslmode: :require, channel_binding: :require)
    conn.tls?.should be_true
    conn.query_one("select 1", as: Int32).should eq(1)
    conn.close
    plain = URI.parse(url)
    expect_raises(Postgres::AuthenticationError, /needs a TLS connection/) do
      Postgres::Connection.new(plain, sslmode: :disable, channel_binding: :require)
    end
  end

  pending_postgres_env "POSTGRES_MD5_URL", "refuses md5 under channel_binding=require" do |url|
    # This role authenticates with md5 over TLS as well (hba "host" lines
    # match TLS connections too).
    expect_raises(Postgres::AuthenticationError, /asked for md5/) do
      Postgres::Connection.new(url, sslmode: :require, channel_binding: :require)
    end
  end
end
