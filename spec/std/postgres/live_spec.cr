require "../../support/postgres"
require "wait_group"

private struct Person
  include Postgres::Serializable
  getter id : Int64
  getter name : String
  @[Postgres::Field(key: "email_address")]
  getter email : String?
  getter role : String = "member"
  @[Postgres::Field(ignore: true)]
  getter touched = false
end

private struct Tagged
  include Postgres::Serializable
  getter id : Int32
  getter tags : Array(String)
  getter scores : Array(Float64?)?
end

private struct Strict
  include Postgres::Serializable
  getter id : Int64
  getter missing : String
end

private def with_people(conn : Postgres::Connection, &)
  conn.exec("drop table if exists spec_people")
  conn.exec("create table spec_people (id bigserial primary key, name text not null, email_address text)")
  begin
    yield
  ensure
    conn.exec("drop table if exists spec_people")
  end
end

describe "Postgres live" do
  pending_postgres "round-trips every supported type through parameters and columns" do
    PostgresSpec.connect do |conn|
      conn.query_one("select $1::bool", true, as: Bool).should be_true
      conn.query_one("select $1::int2", 7, as: Int16).should eq(7)
      conn.query_one("select $1::int4", -8, as: Int32).should eq(-8)
      conn.query_one("select $1::int8", Int64::MAX, as: Int64).should eq(Int64::MAX)
      conn.query_one("select $1::oid", 4000000000_u32, as: UInt32).should eq(4000000000_u32)
      conn.query_one("select $1::float4", 1.5_f32, as: Float32).should eq(1.5_f32)
      conn.query_one("select $1::float8", 0.1, as: Float64).should eq(0.1)
      big = BigDecimal.new("-123456789012345678901234567890.000000000123")
      conn.query_one("select $1::numeric", big, as: BigDecimal).should eq(big)
      conn.query_one("select $1::numeric(10,2)", 0.125, as: BigDecimal).should eq(BigDecimal.new("0.13"))
      conn.query_one("select $1::text", "héllo ☃", as: String).should eq("héllo ☃")
      conn.query_one("select $1::varchar(3)", "abc", as: String).should eq("abc")
      conn.query_one("select $1::char(4)", "ab", as: String).should eq("ab  ")
      conn.query_one("select $1::bytea", Bytes[0, 1, 255], as: Bytes).should eq(Bytes[0, 1, 255])
      uuid = UUID.random
      conn.query_one("select $1::uuid", uuid, as: UUID).should eq(uuid)
      conn.query_one("select $1::uuid", uuid.to_s, as: UUID).should eq(uuid)
      t = Time.utc(2026, 9, 26, 1, 2, 3, nanosecond: 456_789_000)
      conn.query_one("select $1::timestamptz", t, as: Time).should eq(t)
      conn.query_one("select $1::timestamp", t, as: Time).should eq(t)
      conn.query_one("select $1::date", t, as: Time).should eq(Time.utc(2026, 9, 26))
      conn.query_one("select '1850-03-04 05:06:07.5+00'::timestamptz", as: Time).should eq(Time.utc(1850, 3, 4, 5, 6, 7, nanosecond: 500_000_000))
      conn.query_one("select $1::time", 5.hours + 1.5.seconds, as: Time::Span).should eq(5.hours + 1.5.seconds)
      iv = Postgres::Interval.new(months: 13, days: -2, microseconds: 3_000_001_i64)
      conn.query_one("select $1::interval", iv, as: Postgres::Interval).should eq(iv)
      conn.query_one("select $1::interval", 36.hours, as: Time::Span).should eq(36.hours)
      conn.query_one("select $1::jsonb", JSON.parse(%({"a":[1,null]})), as: JSON::Any).should eq(JSON.parse(%({"a":[1,null]})))
      conn.query_one("select $1::json", %({"b": 2}), as: String).should eq(%({"b": 2}))
      conn.query_one("select $1::jsonb", %({"b": 2}), as: JSON::Any)["b"].should eq(2)
      conn.query_one("select $1::int4 + 1", nil, as: Int32?).should be_nil
      conn.query_one("select array[1,2,3]", as: Array(Int32)).should eq([1, 2, 3])
      conn.query_one("select $1::int[]", "{4,5}", as: Array(Int64)).should eq([4_i64, 5_i64])
      conn.query_one("select '10.0.0.0/8'::cidr", as: String).should eq("10.0.0.0/8")
    end
  end

  pending_postgres "round-trips one-dimensional arrays" do
    PostgresSpec.connect do |conn|
      conn.query_one("select $1::int4[]", [1, nil, 3], as: Array(Int32?)).should eq([1, nil, 3])
      conn.query_one("select $1::int8[]", [] of Int64, as: Array(Int64)).should eq([] of Int64)
      conn.query_one("select $1::text[]", ["a", "b\"c", "", nil], as: Array(String?)).should eq(["a", "b\"c", "", nil])
      conn.query_one("select $1::float8[]", [1.5, -0.25], as: Array(Float64)).should eq([1.5, -0.25])
      conn.query_one("select $1::bool[]", [true, false], as: Array(Bool)).should eq([true, false])
      uuids = [UUID.random, UUID.random]
      conn.query_one("select $1::uuid[]", uuids, as: Array(UUID)).should eq(uuids)
      times = [Time.utc(2020, 1, 2, 3, 4, 5), Time.utc(1999, 12, 31)]
      conn.query_one("select $1::timestamptz[]", times, as: Array(Time)).should eq(times)
      nums = [BigDecimal.new("1.25"), BigDecimal.new("-99999999999999999999.5")]
      conn.query_one("select $1::numeric[]", nums, as: Array(BigDecimal)).should eq(nums)
      conn.query_one("select $1::bytea[]", [Bytes[1, 2], Bytes.empty], as: Array(Bytes)).should eq([Bytes[1, 2], Bytes.empty])
      conn.query_one("select $1::jsonb[]", [JSON.parse(%({"a":1}))], as: Array(JSON::Any)).should eq([JSON.parse(%({"a":1}))])
      # Strings for a non-text element type go as a quoted text literal.
      conn.query_one("select $1::int4[]", ["7", "8"], as: Array(Int32)).should eq([7, 8])
      # An element type the codec does not know: sent as text, read as text.
      conn.query_one("select $1::inet[]::text", ["10.0.0.1", "::1"], as: String).should eq("{10.0.0.1,::1}")
      conn.query_one("select array_length($1::int4[], 1)", [5, 6, 7], as: Int32).should eq(3)
      conn.query_all("select g from generate_series(1, 5) g where g = any($1)", [2, 4], as: Int32).should eq([2, 4])
      expect_raises(Postgres::DecodeError, /2-dimensional/) { conn.query_one("select array[[1,2],[3,4]]", as: Array(Int32)) }
      expect_raises(Postgres::DecodeError, /NULL element/) { conn.query_one("select array[1,null]", as: Array(Int32)) }
      conn.query_one("select array[1]::int4[]", as: Array(Int32)?).should eq([1])
      conn.query_one("select null::int4[]", as: Array(Int32)?).should be_nil
    end
  end

  pending_postgres "reports encode and decode mismatches clearly" do
    PostgresSpec.connect do |conn|
      expect_raises(Postgres::EncodeError, /parameter \$1: 70000 is out of range for int2/) { conn.query_one("select $1::int2", 70_000, as: Int16) }
      expect_raises(Postgres::DecodeError, /NULL but Int32 is not nilable/) { conn.query_one("select null::int4", as: Int32) }
      expect_raises(Postgres::DecodeError, /int8 cannot be decoded as Int32/) { conn.query_one("select 1::int8", as: Int32) }
      expect_raises(Postgres::DecodeError, /single column/) { conn.query_one("select 1, 2", as: Int32) }
      expect_raises(ArgumentError, /expects 1 parameters, got 0/) { conn.query_one("select $1::int", as: Int32) }
      conn.query_one("select 1", as: Int32).should eq(1) # still usable
    end
  end

  pending_postgres "maps rows onto Serializable structs" do
    PostgresSpec.connect do |conn|
      with_people(conn) do
        conn.exec("insert into spec_people (name, email_address) values ($1, $2), ($3, $4)", "ana", nil, "bo", "bo@x").rows_affected.should eq(2)
        people = conn.query_all("select * from spec_people order by id", as: Person)
        people.map(&.name).should eq(["ana", "bo"])
        people.map(&.email).should eq([nil, "bo@x"])
        people.all? { |p| p.role == "member" && !p.touched }.should be_true
        conn.query_one("select 'admin' as role, * from spec_people where name = $1", "bo", as: Person).role.should eq("admin")
        conn.query_one?("select * from spec_people where id = $1", -1, as: Person).should be_nil
        expect_raises(Postgres::NoRowsError) { conn.query_one("select * from spec_people where id = $1", -1, as: Person) }
        expect_raises(Postgres::DecodeError, /no column missing for Strict.missing/) { conn.query_all("select id from spec_people", as: Strict) }
        names = [] of String
        conn.query_each("select * from spec_people order by id", as: Person) { |p| names << p.name }
        names.should eq(["ana", "bo"])
      end
    end
  end

  pending_postgres "maps array columns onto Serializable fields" do
    PostgresSpec.connect do |conn|
      rows = conn.query_all("select 1 as id, array['a','b'] as tags, array[1.5, null]::float8[] as scores union all select 2, '{}', null order by id", as: Tagged)
      rows.map(&.tags).should eq([["a", "b"], [] of String])
      rows.map(&.scores).should eq([[1.5, nil], nil])
    end
  end

  pending_postgres "keeps the connection usable after errors and a raising query_each block" do
    PostgresSpec.connect do |conn|
      error = expect_raises(Postgres::QueryError) { conn.exec("select 1/0") }
      error.code.should eq("22012")
      error.severity.should eq("ERROR")
      expect_raises(Postgres::QueryError, /syntax error/) { conn.query_one("selec 1", as: Int32) }.position.should eq(1)
      expect_raises(Exception, "stop") do
        conn.query_each("select generate_series(1, 10000)", as: Int32) { |i| raise "stop" if i == 3 }
      end
      conn.query_one("select 2", as: Int32).should eq(2)
      conn.exec("select 1; select 2").command.should eq("SELECT")
    end
  end

  pending_postgres "commits, rolls back and nests transactions with savepoints" do
    PostgresSpec.connect do |conn|
      with_people(conn) do
        conn.transaction { |tx| tx.exec("insert into spec_people (name) values ('a')") }
        expect_raises(Exception, "undo") do
          conn.transaction do |tx|
            tx.exec("insert into spec_people (name) values ('b')")
            raise "undo"
          end
        end
        conn.transaction do |tx|
          tx.exec("insert into spec_people (name) values ('c')")
          expect_raises(Postgres::QueryError) do
            tx.transaction { |sp| sp.exec("insert into spec_people (name) values (null)") }
          end
          tx.transaction_status.should eq('T') # the savepoint rolled back, the outer one is fine
          tx.transaction { |sp| sp.exec("insert into spec_people (name) values ('d')") }
        end
        conn.query_all("select name from spec_people order by id", as: String).should eq(["a", "c", "d"])
        expect_raises(Postgres::Error, /aborted by an earlier error/) do
          conn.transaction do |tx|
            tx.exec("insert into spec_people (name) values ('e')")
            tx.exec("select 1/0") rescue nil
          end
        end
        conn.transaction_status.should eq('I')
        conn.query_one("select count(*) from spec_people where name = 'e'", as: Int64).should eq(0)
        conn.transaction(isolation: :serializable, read_only: true) do |tx|
          tx.query_one("show transaction_isolation", as: String).should eq("serializable")
          tx.query_one("show transaction_read_only", as: String).should eq("on")
        end
        expect_raises(Postgres::QueryError, /read-only/) do
          conn.transaction(read_only: true) { |tx| tx.exec("insert into spec_people (name) values ('f')") }
        end
        conn.transaction_status.should eq('I')
      end
    end
  end

  pending_postgres "caches statements and survives a schema change and DISCARD ALL" do
    PostgresSpec.connect do |conn|
      conn.exec("drop table if exists spec_cache")
      conn.exec("create table spec_cache (a int)")
      conn.exec("insert into spec_cache values (1)")
      conn.query_all("select * from spec_cache", as: Int32).should eq([1])
      conn.statement_cache_size.should eq(1)
      conn.query_all("select * from spec_cache", as: Int32).should eq([1])
      conn.statement_cache_size.should eq(1)
      conn.query_one("select count(*) from pg_prepared_statements", as: Int64).should eq(2)
      # The cached plan's result type changes: re-prepared transparently.
      conn.exec("alter table spec_cache alter column a type text")
      conn.query_all("select * from spec_cache", as: String).should eq(["1"])
      conn.exec("discard all")
      conn.query_all("select * from spec_cache", as: String).should eq(["1"])
      conn.clear_statement_cache
      conn.statement_cache_size.should eq(0)
      conn.query_one("select count(*) from pg_prepared_statements", as: Int64).should eq(1)
      conn.exec("drop table spec_cache")
    end
  end

  pending_postgres "closes evicted statements and runs uncached" do
    PostgresSpec.connect(statement_cache_size: 2) do |conn|
      5.times { |i| conn.query_one("select #{i}", as: Int32).should eq(i) }
      conn.query_one("select count(*) from pg_prepared_statements", as: Int64).should eq(2)
    end
    PostgresSpec.connect(statement_cache_size: 1) do |conn|
      conn.query_one("select 1", as: Int32)
      # Preparing this evicts "select 1" (its Close is queued), then the
      # argument fails to encode: the queued Close must still go out.
      expect_raises(Postgres::EncodeError) { conn.query_one("select $1::int2", 70_000, as: Int16) }
      conn.query_one("select 3", as: Int32)
      # Only the inspecting query itself is left prepared: every evicted
      # statement, including the one queued before the encode error, is gone.
      sql = "select array_agg(statement) from pg_prepared_statements"
      conn.query_one(sql, as: Array(String)).should eq([sql])
    end
    PostgresSpec.connect(statement_cache_size: 0) do |conn|
      conn.query_one("select $1::int * 2", 21, as: Int32).should eq(42)
      conn.query_one("select count(*) from pg_prepared_statements", as: Int64).should eq(0)
    end
  end

  pending_postgres "delivers notices" do
    PostgresSpec.connect do |conn|
      notices = [] of String
      conn.on_notice = ->(n : Postgres::Notice) { notices << n.message; nil }
      conn.exec("do $$ begin raise notice 'hi %', 1; end $$")
      notices.should eq(["hi 1"])
    end
  end

  pending_postgres "times out a slow query and closes the connection" do
    PostgresSpec.connect(read_timeout: 100.milliseconds) do |conn|
      expect_raises(IO::TimeoutError) { conn.exec("select pg_sleep(1)") }
      conn.closed?.should be_true
      expect_raises(Postgres::ConnectionError, /closed/) { conn.exec("select 1") }
    end
  end

  pending_postgres "shares a pooled client between many fibers" do
    db = Postgres::Client.new(PostgresSpec::URL, pool_size: 4)
    begin
      wg = WaitGroup.new
      sums = Channel(Int64).new(64)
      64.times do |i|
        wg.spawn do
          sums.send db.query_one("select $1::int8 + 1 from pg_sleep(0.001)", i, as: Int64)
        end
      end
      wg.wait
      64.times.sum { sums.receive }.should eq((1..64).sum)
      (db.idle + db.in_use).should be <= 4
      db.transaction { |tx| tx.query_one("select txid_current() is not null", as: Bool) }.should be_true
      db.with_connection { |c| c.exec("set application_name = 'spec'"); c.query_one("show application_name", as: String) }.should eq("spec")
    ensure
      db.close
    end
    expect_raises(Pool::ClosedError) { db.exec("select 1") }
  end

  pending_postgres "drops a pooled connection the server terminated" do
    db = Postgres::Client.new(PostgresSpec::URL, pool_size: 1)
    begin
      pid = db.query_one("select pg_backend_pid()", as: Int32)
      PostgresSpec.connect { |admin| admin.exec("select pg_terminate_backend($1)", pid) }
      sleep 50.milliseconds
      # Idle for less than the health-check age: the dead socket surfaces
      # as a ConnectionError and the pool drops it.
      expect_raises(Postgres::ConnectionError) { db.query_one("select 1", as: Int32) }
      db.query_one("select pg_backend_pid()", as: Int32).should_not eq(pid)
    ensure
      db.close
    end
  end

  pending_postgres "reads server parameters" do
    PostgresSpec.connect do |conn|
      conn.parameters["server_encoding"].should eq("UTF8")
      conn.server_version.should be >= 100000
      conn.backend_pid.should eq(conn.query_one("select pg_backend_pid()", as: Int32))
    end
  end

  {"POSTGRES_MD5_URL" => "md5", "POSTGRES_CLEARTEXT_URL" => "cleartext", "POSTGRES_SCRAM_URL" => "SCRAM-SHA-256"}.each do |env, method|
    pending_postgres_env env, "authenticates with #{method}" do |url|
      conn = Postgres::Connection.new(url)
      conn.query_one("select 1", as: Int32).should eq(1)
      conn.close
      bad = URI.parse(url)
      bad.password = "wrong-password"
      expect_raises(Postgres::AuthenticationError, /28P01/) { Postgres::Connection.new(bad) }
    end
  end

  pending_postgres_env "POSTGRES_SSL_URL", "connects over TLS" do |url|
    conn = Postgres::Connection.new(url, sslmode: :require)
    conn.tls?.should be_true
    conn.query_one("select ssl from pg_stat_ssl where pid = pg_backend_pid()", as: Bool).should be_true
    conn.close
  end
end
