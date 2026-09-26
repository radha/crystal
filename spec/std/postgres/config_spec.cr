require "spec"
require "postgres/config"

private EMPTY_ENV = {} of String => String

private def parse(url = nil, env = EMPTY_ENV, **opts)
  Postgres::Config.parse(url, **opts, env: env)
end

describe Postgres::SSLMode do
  it "parses libpq values" do
    Postgres::SSLMode.from_param("disable").should eq(Postgres::SSLMode::Disable)
    Postgres::SSLMode.from_param("prefer").should eq(Postgres::SSLMode::Prefer)
    Postgres::SSLMode.from_param("require").should eq(Postgres::SSLMode::Require)
    Postgres::SSLMode.from_param("verify-ca").should eq(Postgres::SSLMode::VerifyCA)
    Postgres::SSLMode.from_param("verify-full").should eq(Postgres::SSLMode::VerifyFull)
  end

  it "rejects other values" do
    {"allow-ish", "Require", "verify_ca", ""}.each do |value|
      expect_raises(ArgumentError, /sslmode/) { Postgres::SSLMode.from_param(value) }
    end
  end

  it "round-trips to_param" do
    Postgres::SSLMode.each { |mode| Postgres::SSLMode.from_param(mode.to_param).should eq(mode) }
  end
end

describe Postgres::Config do
  it "uses defaults with an empty env" do
    config = parse
    config.host.should eq("localhost")
    config.port.should eq(5432)
    config.user.should eq("postgres")
    config.password.should be_nil
    config.database.should eq("postgres")
    config.sslmode.should eq(Postgres::SSLMode::Prefer)
    config.sslrootcert.should be_nil
    config.application_name.should be_nil
    config.connect_timeout.should eq(10.seconds)
    config.socket_path.should be_nil
    config.statement_cache_size.should eq(256)
  end

  it "falls back to USER, and database to user" do
    config = parse(env: {"USER" => "alice"})
    config.user.should eq("alice")
    config.database.should eq("alice")
  end

  it "reads each PG* variable" do
    env = {
      "PGHOST"            => "db.example",
      "PGPORT"            => "6543",
      "PGUSER"            => "bob",
      "USER"              => "ignored",
      "PGPASSWORD"        => "hunter2",
      "PGDATABASE"        => "app",
      "PGSSLMODE"         => "verify-full",
      "PGSSLROOTCERT"     => "/etc/ca.pem",
      "PGAPPNAME"         => "worker",
      "PGCONNECT_TIMEOUT" => "3",
    }
    config = parse(env: env)
    config.host.should eq("db.example")
    config.port.should eq(6543)
    config.user.should eq("bob")
    config.password.should eq("hunter2")
    config.database.should eq("app")
    config.sslmode.should eq(Postgres::SSLMode::VerifyFull)
    config.sslrootcert.should eq("/etc/ca.pem")
    config.application_name.should eq("worker")
    config.connect_timeout.should eq(3.seconds)
  end

  it "rejects invalid env values" do
    expect_raises(ArgumentError, /port/) { parse(env: {"PGPORT" => "abc"}) }
    expect_raises(ArgumentError, /port/) { parse(env: {"PGPORT" => "70000"}) }
    expect_raises(ArgumentError, /connect_timeout/) { parse(env: {"PGCONNECT_TIMEOUT" => "-1"}) }
    expect_raises(ArgumentError, /sslmode/) { parse(env: {"PGSSLMODE" => "nope"}) }
  end

  it "parses a full URL" do
    config = parse("postgres://alice:secret@db.example:5433/app?sslmode=require&application_name=web&connect_timeout=5&sslrootcert=/ca.pem&statement_cache_size=16")
    config.host.should eq("db.example")
    config.port.should eq(5433)
    config.user.should eq("alice")
    config.password.should eq("secret")
    config.database.should eq("app")
    config.sslmode.should eq(Postgres::SSLMode::Require)
    config.application_name.should eq("web")
    config.connect_timeout.should eq(5.seconds)
    config.sslrootcert.should eq("/ca.pem")
    config.statement_cache_size.should eq(16)
  end

  it "accepts a URI" do
    config = parse(URI.parse("postgres://alice:secret@db.example/app"))
    config.user.should eq("alice")
    config.password.should eq("secret")
    config.database.should eq("app")
  end

  it "prefers the URL to the env" do
    env = {"PGHOST" => "envhost", "PGPORT" => "1111", "PGUSER" => "envuser", "PGPASSWORD" => "envpw",
           "PGDATABASE" => "envdb", "PGSSLMODE" => "disable", "PGAPPNAME" => "envapp"}
    config = parse("postgres://u:p@urlhost:2222/urldb?sslmode=require&application_name=urlapp", env: env)
    config.host.should eq("urlhost")
    config.port.should eq(2222)
    config.user.should eq("u")
    config.password.should eq("p")
    config.database.should eq("urldb")
    config.sslmode.should eq(Postgres::SSLMode::Require)
    config.application_name.should eq("urlapp")
  end

  it "fills gaps in the URL from the env" do
    config = parse("postgres://urlhost", env: {"PGUSER" => "envuser", "PGPASSWORD" => "envpw"})
    config.host.should eq("urlhost")
    config.user.should eq("envuser")
    config.password.should eq("envpw")
    config.database.should eq("envuser")
  end

  it "prefers overrides to the URL" do
    config = parse("postgres://u:p@urlhost:2222/urldb?sslmode=require&connect_timeout=5&statement_cache_size=8",
      host: "kwhost", port: 3333, user: "kwuser", password: "kwpw", database: "kwdb",
      sslmode: Postgres::SSLMode::Disable, sslrootcert: "/kw.pem", application_name: "kwapp",
      connect_timeout: 2.seconds, statement_cache_size: 0)
    config.host.should eq("kwhost")
    config.port.should eq(3333)
    config.user.should eq("kwuser")
    config.password.should eq("kwpw")
    config.database.should eq("kwdb")
    config.sslmode.should eq(Postgres::SSLMode::Disable)
    config.sslrootcert.should eq("/kw.pem")
    config.application_name.should eq("kwapp")
    config.connect_timeout.should eq(2.seconds)
    config.statement_cache_size.should eq(0)
  end

  it "rejects invalid overrides" do
    expect_raises(ArgumentError, /port/) { parse(port: 0) }
    expect_raises(ArgumentError, /connect_timeout/) { parse(connect_timeout: -1.seconds) }
    expect_raises(ArgumentError, /statement_cache_size/) { parse(statement_cache_size: -1) }
  end

  it "percent-decodes user, password and database" do
    password = "p@ss:w/rd"
    url = "postgres://#{URI.encode_www_form("us@r")}:#{URI.encode_www_form(password)}@host/#{URI.encode_path_segment("my db")}"
    config = parse(url)
    config.user.should eq("us@r")
    config.password.should eq(password)
    config.database.should eq("my db")
  end

  it "keeps '+' in the userinfo and query" do
    config = parse("postgres://a+b:c+d@host/db?application_name=x+y")
    config.user.should eq("a+b")
    config.password.should eq("c+d")
    config.application_name.should eq("x+y")
  end

  it "accepts the postgresql scheme" do
    parse("postgresql://host/db").database.should eq("db")
  end

  it "rejects other schemes" do
    expect_raises(ArgumentError, /scheme/) { parse("mysql://host/db") }
    expect_raises(ArgumentError, /scheme/) { parse("host/db") }
  end

  it "rejects unknown query keys" do
    expect_raises(ArgumentError, /"frobnicate"/) { parse("postgres://host/db?frobnicate=1") }
  end

  it "rejects invalid query values" do
    expect_raises(ArgumentError, /port/) { parse("postgres://host/db?port=x") }
    expect_raises(ArgumentError, /connect_timeout/) { parse("postgres://host/db?connect_timeout=soon") }
    expect_raises(ArgumentError, /sslmode/) { parse("postgres://host/db?sslmode=maybe") }
    expect_raises(ArgumentError, /statement_cache_size/) { parse("postgres://host/db?statement_cache_size=-2") }
    expect_raises(ArgumentError) { parse("postgres://host:abc/db") }
  end

  it "lets query parameters override URL parts" do
    config = parse("postgres://u:p@h:1/d?host=qh&port=2&user=qu&password=qp&dbname=qd")
    config.host.should eq("qh")
    config.port.should eq(2)
    config.user.should eq("qu")
    config.password.should eq("qp")
    config.database.should eq("qd")
  end

  it "treats an empty path as unset" do
    parse("postgres://host/", env: {"PGDATABASE" => "envdb"}).database.should eq("envdb")
  end

  it "uses a Unix socket from the host query parameter" do
    config = parse("postgres:///mydb?host=/var/run/postgresql")
    config.host.should eq("/var/run/postgresql")
    config.socket_path.should eq("/var/run/postgresql/.s.PGSQL.5432")
    config.database.should eq("mydb")
  end

  it "uses a percent-encoded Unix socket directory" do
    config = parse("postgres:///mydb?host=%2Ftmp&port=5433")
    config.socket_path.should eq("/tmp/.s.PGSQL.5433")
  end

  it "uses a Unix socket from PGHOST" do
    config = parse(env: {"PGHOST" => "/tmp", "PGPORT" => "6000"})
    config.socket_path.should eq("/tmp/.s.PGSQL.6000")
  end

  it "unwraps a bracketed IPv6 host" do
    config = parse("postgres://[::1]:5433/db")
    config.host.should eq("::1")
    config.port.should eq(5433)
    config.socket_path.should be_nil
  end

  it "hides the password in inspect and to_s" do
    config = parse("postgres://u:topsecret@h/d")
    config.inspect.should_not contain("topsecret")
    config.inspect.should contain("[FILTERED]")
    config.to_s.should_not contain("topsecret")
    parse("postgres://u@h/d").inspect.should contain("password: nil")
  end

  it "reads ENV when no env is given" do
    Postgres::Config.parse("postgres://h/d").host.should eq("h")
  end
end
