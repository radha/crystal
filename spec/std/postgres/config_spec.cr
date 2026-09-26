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

private def with_file(content : String, mode = 0o600, &)
  file = File.tempfile("pgconf") { |io| io << content }
  begin
    File.chmod(file.path, mode)
    yield file.path
  ensure
    file.delete
  end
end

private def host(name, port = 5432)
  Postgres::Config::Host.new(name, port)
end

describe Postgres::TargetSessionAttrs do
  it "parses and round-trips libpq values" do
    Postgres::TargetSessionAttrs.from_param("read-write").should eq(Postgres::TargetSessionAttrs::ReadWrite)
    Postgres::TargetSessionAttrs.from_param("prefer-standby").should eq(Postgres::TargetSessionAttrs::PreferStandby)
    Postgres::TargetSessionAttrs.each do |attrs|
      Postgres::TargetSessionAttrs.from_param(attrs.to_param).should eq(attrs)
    end
    expect_raises(ArgumentError, /target_session_attrs/) { Postgres::TargetSessionAttrs.from_param("read_write") }
  end
end

describe Postgres::LoadBalanceHosts do
  it "parses and round-trips libpq values" do
    Postgres::LoadBalanceHosts.each do |value|
      Postgres::LoadBalanceHosts.from_param(value.to_param).should eq(value)
    end
    expect_raises(ArgumentError, /load_balance_hosts/) { Postgres::LoadBalanceHosts.from_param("yes") }
  end
end

describe Postgres::Config::Host do
  it "formats host, IPv6 and socket entries" do
    host("db", 5433).to_s.should eq("db:5433")
    host("::1", 5433).to_s.should eq("[::1]:5433")
    sock = host("/tmp", 6000)
    sock.socket_path.should eq("/tmp/.s.PGSQL.6000")
    sock.to_s.should eq("/tmp/.s.PGSQL.6000")
    host("db").socket_path.should be_nil
  end
end

describe "Postgres::Config multi-host" do
  it "has one default host" do
    parse.hosts.should eq([host("localhost")])
  end

  it "parses a host list with ports and IPv6 in the URL" do
    config = parse("postgres://u@h1:5432,h2,[::1]:5433/db")
    config.hosts.should eq([host("h1", 5432), host("h2", 5432), host("::1", 5433)])
    config.host.should eq("h1")
    config.port.should eq(5432)
    config.database.should eq("db")
  end

  it "uses the default port for hosts without one even when PGPORT is set" do
    config = parse("postgres://h1:6000,h2/db", env: {"PGPORT" => "7000"})
    config.hosts.should eq([host("h1", 6000), host("h2", 5432)])
  end

  it "applies PGPORT when the URL gives no port" do
    parse("postgres://h1,h2/db", env: {"PGPORT" => "7000"}).hosts.should eq([host("h1", 7000), host("h2", 7000)])
  end

  it "mixes socket directories with TCP hosts" do
    config = parse("postgres://%2Fvar%2Frun%2Fpostgresql,db.example:5433/app")
    config.hosts.should eq([host("/var/run/postgresql"), host("db.example", 5433)])
    config.socket_path.should eq("/var/run/postgresql/.s.PGSQL.5432")
    config.hosts[1].socket_path.should be_nil
  end

  it "parses host and port lists in the query" do
    config = parse("postgres:///db?host=h1,h2,/tmp&port=5432,5433,5434")
    config.hosts.should eq([host("h1", 5432), host("h2", 5433), host("/tmp", 5434)])
    config.hosts[2].socket_path.should eq("/tmp/.s.PGSQL.5434")
  end

  it "applies a single query port to every host" do
    parse("postgres:///db?host=h1,h2&port=6000").hosts.should eq([host("h1", 6000), host("h2", 6000)])
  end

  it "unwraps IPv6 hosts in the query" do
    parse("postgres:///db?host=[::1],h2").hosts.should eq([host("::1"), host("h2")])
  end

  it "reads PGHOST and PGPORT lists" do
    config = parse(env: {"PGHOST" => "h1,/tmp,h3", "PGPORT" => "1,2,3"})
    config.hosts.should eq([host("h1", 1), host("/tmp", 2), host("h3", 3)])
  end

  it "uses the default host for empty entries" do
    parse(env: {"PGHOST" => "h1,", "PGPORT" => "1,"}).hosts.should eq([host("h1", 1), host("localhost", 5432)])
  end

  it "accepts a host list keyword with a single port keyword" do
    config = parse("postgres://urlhost/db", host: "k1,k2", port: 7777)
    config.hosts.should eq([host("k1", 7777), host("k2", 7777)])
  end

  it "rejects mismatched port lists" do
    expect_raises(ArgumentError, /2 port numbers to 3 hosts/) { parse("postgres:///db?host=a,b,c&port=1,2") }
    expect_raises(ArgumentError, /port numbers/) { parse(env: {"PGHOST" => "a,b", "PGPORT" => "1,2,3"}) }
    expect_raises(ArgumentError, /port/) { parse("postgres://a:1,b:x/db") }
  end

  it "rejects an unterminated IPv6 address" do
    expect_raises(ArgumentError, /IPv6/) { parse("postgres://[::1/db") }
  end

  it "reads target_session_attrs and load_balance_hosts with precedence" do
    config = parse
    config.target_session_attrs.should eq(Postgres::TargetSessionAttrs::Any)
    config.load_balance_hosts.should eq(Postgres::LoadBalanceHosts::Disable)

    env = {"PGTARGETSESSIONATTRS" => "standby", "PGLOADBALANCEHOSTS" => "random"}
    config = parse(env: env)
    config.target_session_attrs.should eq(Postgres::TargetSessionAttrs::Standby)
    config.load_balance_hosts.should eq(Postgres::LoadBalanceHosts::Random)

    config = parse("postgres://h/db?target_session_attrs=read-write&load_balance_hosts=disable", env: env)
    config.target_session_attrs.should eq(Postgres::TargetSessionAttrs::ReadWrite)
    config.load_balance_hosts.should eq(Postgres::LoadBalanceHosts::Disable)

    config = parse("postgres://h/db?target_session_attrs=read-write", env: env,
      target_session_attrs: Postgres::TargetSessionAttrs::Primary)
    config.target_session_attrs.should eq(Postgres::TargetSessionAttrs::Primary)

    expect_raises(ArgumentError, /target_session_attrs/) { parse("postgres://h/db?target_session_attrs=master") }
    expect_raises(ArgumentError, /load_balance_hosts/) { parse(env: {"PGLOADBALANCEHOSTS" => "on"}) }
  end

  it "keeps the host order unless load balancing" do
    config = parse("postgres://a,b,c,d,e/db")
    config.ordered_hosts(Random.new(42)).map(&.host).should eq(%w(a b c d e))
  end

  it "shuffles hosts reproducibly with a seeded Random" do
    config = parse("postgres://a,b,c,d,e,f,g,h/db?load_balance_hosts=random")
    first = config.ordered_hosts(Random.new(42))
    first.should eq(config.hosts.shuffle(Random.new(42)))
    first.should_not eq(config.hosts)
    first.map(&.host).sort.should eq(%w(a b c d e f g h))
    config.ordered_hosts(Random.new(42)).should eq(first)
    config.hosts.map(&.host).should eq(%w(a b c d e f g h))
  end

  it "shows hosts in inspect" do
    parse("postgres://a,[::1]:6000/db").inspect.should contain("hosts: [a:5432, [::1]:6000]")
  end
end

describe "Postgres::Config password file" do
  it "splits lines with escapes and wildcards" do
    Postgres::Config::PassFile.split("h:5432:db:u:pw").should eq(["h", "5432", "db", "u", "pw"])
    Postgres::Config::PassFile.split("*:*:*:*:pw").should eq([nil, nil, nil, nil, "pw"])
    Postgres::Config::PassFile.split(%q(h\:x:\*:d\\b:u:p\:w\\d)).should eq(["h:x", "*", %q(d\b), "u", %q(p:w\d)])
    Postgres::Config::PassFile.split("h:5432:db:u:pw:extra").should eq(["h", "5432", "db", "u", "pw"])
    Postgres::Config::PassFile.split("h:5432:db").should be_nil
  end

  it "uses the first matching line of PGPASSFILE" do
    content = <<-PGPASS
      # comment
      other:*:*:*:nope
      db.example:5432:app:alice:first
      *:*:*:alice:second

      PGPASS
    with_file(content) do |path|
      env = {"PGPASSFILE" => path}
      parse("postgres://alice@db.example/app", env: env).password.should eq("first")
      parse("postgres://alice@db.example:5433/app", env: env).password.should eq("second")
      parse("postgres://bob@db.example/app", env: env).password.should be_nil
    end
  end

  it "reads ~/.pgpass from HOME in env" do
    dir = File.tempname("pghome")
    Dir.mkdir(dir)
    begin
      path = File.join(dir, ".pgpass")
      File.write(path, "*:*:*:*:homepw\n")
      File.chmod(path, 0o600)
      config = parse(env: {"HOME" => dir})
      config.passfile.should eq(path)
      config.password.should eq("homepw")
    ensure
      File.delete?(File.join(dir, ".pgpass"))
      Dir.delete(dir)
    end
  end

  it "matches escaped fields" do
    with_file(%q(h:5432:my\:db:u\\x:pw) + "\n") do |path|
      parse(env: {"PGPASSFILE" => path, "PGHOST" => "h", "PGDATABASE" => "my:db", "PGUSER" => %q(u\x)}).password.should eq("pw")
    end
  end

  it "treats an escaped star literally" do
    with_file(%q(\*:*:*:*:pw) + "\n") do |path|
      parse(env: {"PGPASSFILE" => path, "PGHOST" => "h"}).password.should be_nil
      parse(env: {"PGPASSFILE" => path, "PGHOST" => "*"}).password.should eq("pw")
    end
  end

  it "matches localhost for a Unix socket" do
    with_file("localhost:6000:*:*:sockpw\n") do |path|
      parse(env: {"PGPASSFILE" => path, "PGHOST" => "/tmp", "PGPORT" => "6000"}).password.should eq("sockpw")
    end
  end

  it "prefers an explicit password" do
    with_file("*:*:*:*:filepw\n") do |path|
      env = {"PGPASSFILE" => path}
      parse(env: env.merge({"PGPASSWORD" => "envpw"})).password.should eq("envpw")
      parse("postgres://u:urlpw@h/db", env: env).password.should eq("urlpw")
      parse(env: env, password: "kwpw").password.should eq("kwpw")
      parse(env: env).password.should eq("filepw")
    end
  end

  it "consults the file for an empty explicit password" do
    with_file("*:*:*:*:filepw\n") do |path|
      parse("postgres://u:@h/db", env: {"PGPASSFILE" => path}).password.should eq("filepw")
    end
    parse("postgres://u:@h/db").password.should eq("")
  end

  it "prefers the passfile key to PGPASSFILE" do
    with_file("*:*:*:*:envfile\n") do |env_path|
      with_file("*:*:*:*:urlfile\n") do |url_path|
        env = {"PGPASSFILE" => env_path}
        parse("postgres://h/db?passfile=#{URI.encode_www_form(url_path)}", env: env).password.should eq("urlfile")
        parse(env: env, passfile: url_path).password.should eq("urlfile")
        parse(env: env).password.should eq("envfile")
      end
    end
  end

  it "ignores a missing file" do
    parse(env: {"PGPASSFILE" => "/nonexistent/pgpass"}).password.should be_nil
  end

  {% unless flag?(:win32) %}
    it "skips a file readable by group or others" do
      with_file("*:*:*:*:leaked\n", mode: 0o644) do |path|
        parse(env: {"PGPASSFILE" => path}).password.should be_nil
      end
      with_file("*:*:*:*:leaked\n", mode: 0o640) do |path|
        parse(env: {"PGPASSFILE" => path}).password.should be_nil
      end
    end
  {% end %}

  it "looks up a password per host" do
    content = "h1:5432:*:*:pw1\nh2:5433:*:*:pw2\nlocalhost:5432:*:*:pwsock\n"
    with_file(content) do |path|
      config = parse("postgres://h1,h2:5433,%2Ftmp,h4/db", env: {"PGPASSFILE" => path})
      config.hosts.map { |h| config.password_for(h) }.should eq(["pw1", "pw2", "pwsock", nil])
      config.password.should eq("pw1")
      config.password_for(host("h2", 5433)).should eq("pw2")
      config.password_for(host("h9")).should be_nil
      config.inspect.should_not contain("pw1")
    end
  end

  it "uses the explicit password for every host" do
    with_file("*:*:*:*:filepw\n") do |path|
      config = parse("postgres://u:x@h1,h2/db", env: {"PGPASSFILE" => path})
      config.hosts.map { |h| config.password_for(h) }.should eq(["x", "x"])
    end
  end
end

describe "Postgres::Config service file" do
  service_file = <<-CONF
    # services
    [main]
    host=svc.example
    port=6432
    dbname=svcdb
    user=svcuser
    password=svcpw
    sslmode=require
    application_name = svcapp
    options=-c statement_timeout=5000

    [other]
    hostaddr=10.0.0.1
    port=1111
    connect_timeout=7
    target_session_attrs=primary
    load_balance_hosts=random

    [multi]
    host=a,b
    port=1,2

    [main]
    dbname=ignored
    CONF

  it "reads a section from PGSERVICEFILE" do
    with_file(service_file) do |path|
      config = parse(env: {"PGSERVICEFILE" => path, "PGSERVICE" => "main"})
      config.host.should eq("svc.example")
      config.port.should eq(6432)
      config.database.should eq("svcdb")
      config.user.should eq("svcuser")
      config.password.should eq("svcpw")
      config.sslmode.should eq(Postgres::SSLMode::Require)
      config.application_name.should eq("svcapp")
      config.options.should eq("-c statement_timeout=5000")
    end
  end

  it "treats hostaddr as host and reads the remaining keys" do
    with_file(service_file) do |path|
      config = parse(service: "other", env: {"PGSERVICEFILE" => path})
      config.hosts.should eq([host("10.0.0.1", 1111)])
      config.connect_timeout.should eq(7.seconds)
      config.target_session_attrs.should eq(Postgres::TargetSessionAttrs::Primary)
      config.load_balance_hosts.should eq(Postgres::LoadBalanceHosts::Random)
    end
  end

  it "reads host lists" do
    with_file(service_file) do |path|
      parse("postgres:///db?service=multi", env: {"PGSERVICEFILE" => path}).hosts.should eq([host("a", 1), host("b", 2)])
    end
  end

  it "ranks between the URL and the environment" do
    with_file(service_file) do |path|
      env = {"PGSERVICEFILE" => path, "PGHOST" => "envhost", "PGDATABASE" => "envdb", "PGAPPNAME" => "envapp",
             "PGSSLROOTCERT" => "/env.pem"}
      config = parse("postgres://urlhost/?service=main&application_name=urlapp", env: env)
      config.host.should eq("urlhost")
      config.port.should eq(6432)
      config.database.should eq("svcdb")
      config.application_name.should eq("urlapp")
      config.sslrootcert.should eq("/env.pem")
      parse("postgres://urlhost/?service=main", env: env, database: "kwdb").database.should eq("kwdb")
    end
  end

  it "prefers the service keyword to the URL and PGSERVICE" do
    with_file(service_file) do |path|
      env = {"PGSERVICEFILE" => path, "PGSERVICE" => "main"}
      parse("postgres:///?service=main", env: env, service: "multi").host.should eq("a")
      parse("postgres:///?service=multi", env: env).host.should eq("a")
    end
  end

  it "uses the service password before the password file" do
    with_file(service_file) do |path|
      with_file("*:*:*:*:filepw\n") do |pgpass|
        parse(service: "main", env: {"PGSERVICEFILE" => path, "PGPASSFILE" => pgpass}).password.should eq("svcpw")
        parse(service: "multi", env: {"PGSERVICEFILE" => path, "PGPASSFILE" => pgpass}).password.should eq("filepw")
      end
    end
  end

  it "reads the passfile key" do
    with_file("*:*:*:*:filepw\n") do |pgpass|
      with_file("[s]\npassfile=#{pgpass}\n") do |path|
        parse(service: "s", env: {"PGSERVICEFILE" => path}).password.should eq("filepw")
      end
    end
  end

  it "falls back to PGSYSCONFDIR and to ~/.pg_service.conf" do
    dir = File.tempname("pgsys")
    Dir.mkdir(dir)
    begin
      File.write(File.join(dir, "pg_service.conf"), "[sys]\nhost=syshost\n")
      File.write(File.join(dir, ".pg_service.conf"), "[home]\nhost=homehost\n")
      env = {"PGSYSCONFDIR" => dir, "HOME" => dir}
      parse(service: "sys", env: env).host.should eq("syshost")
      parse(service: "home", env: env).host.should eq("homehost")
      with_file("[sys]\nhost=userhost\n") do |path|
        parse(service: "sys", env: env.merge({"PGSERVICEFILE" => path})).host.should eq("userhost")
      end
    ensure
      File.delete?(File.join(dir, "pg_service.conf"))
      File.delete?(File.join(dir, ".pg_service.conf"))
      Dir.delete(dir)
    end
  end

  it "raises for an unknown service" do
    with_file(service_file) do |path|
      expect_raises(ArgumentError, /"nope" not found/) { parse(service: "nope", env: {"PGSERVICEFILE" => path}) }
    end
    expect_raises(ArgumentError, /not found/) { parse(service: "nope") }
  end

  it "raises for unknown keys and bad lines" do
    with_file("[s]\nfrobnicate=1\n") do |path|
      expect_raises(ArgumentError, /"frobnicate"/) { parse(service: "s", env: {"PGSERVICEFILE" => path}) }
    end
    with_file("[s]\nstatement_cache_size=1\n") do |path|
      expect_raises(ArgumentError, /"statement_cache_size"/) { parse(service: "s", env: {"PGSERVICEFILE" => path}) }
    end
    with_file("[s]\nservice=t\n") do |path|
      expect_raises(ArgumentError, /[Nn]ested/) { parse(service: "s", env: {"PGSERVICEFILE" => path}) }
    end
    with_file("[s]\nhost\n") do |path|
      expect_raises(ArgumentError, /[Ss]yntax/) { parse(service: "s", env: {"PGSERVICEFILE" => path}) }
    end
    with_file("[s]\nport=abc\n") do |path|
      expect_raises(ArgumentError, /port/) { parse(service: "s", env: {"PGSERVICEFILE" => path}) }
    end
  end

  it "ignores errors in other sections" do
    with_file("[bad]\nfrobnicate=1\n[good]\nhost=g\n") do |path|
      parse(service: "good", env: {"PGSERVICEFILE" => path}).host.should eq("g")
    end
  end
end

describe "Postgres::Config options" do
  it "is nil by default" do
    parse.options.should be_nil
  end

  it "reads options with precedence" do
    env = {"PGOPTIONS" => "-c env=1"}
    parse(env: env).options.should eq("-c env=1")
    parse("postgres://h/db?options=-c%20url%3D1", env: env).options.should eq("-c url=1")
    parse("postgres://h/db?options=-c%20url%3D1", env: env, options: "-c kw=1").options.should eq("-c kw=1")
  end

  it "appends an escaped search_path" do
    parse(search_path: "app").options.should eq("-c search_path=app")
    parse(search_path: %q(my schema, pub\lic), options: "-c statement_timeout=5000").options
      .should eq(%q(-c statement_timeout=5000 -c search_path=my\ schema,\ pub\\lic))
  end
end
