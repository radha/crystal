require "../../support/postgres"
require "../../support/postgres_fake"

private struct Pet
  include Postgres::Serializable
  getter id : Int32
  getter name : String
end

describe "Postgres pipeline" do
  it "sends every statement's prepare in one write and every query in a second one" do
    int4 = [{"?column?", Postgres::OID::INT4}]
    server = PostgresSpec::FakeServer.new do |peer|
      peer.handshake
      # Round 1: three Parse/Describe/Sync batches, all read before any
      # answer; a client waiting per query would deadlock here.
      prepares = Array.new(3) { peer.read_until_sync }
      prepares.each { |batch| peer.answer_prepare(batch, [Postgres::OID::INT4], int4) }
      # Round 2: three Bind/Execute/Sync batches, likewise.
      executes = Array.new(3) { peer.read_until_sync }
      executes.each_with_index do |batch, i|
        peer.answer_execute(batch, [[Bytes[0, 0, 0, i.to_u8]]])
      end
      peer.read_message
    end
    begin
      conn = Postgres::Connection.new(server.url, read_timeout: 1.second)
      futures = [] of Postgres::Future(Int32)
      conn.pipeline do |p|
        3.times { |i| futures << p.query_one("select $1::int4 + #{i}", i, as: Int32) }
      end
      futures.map(&.value).should eq([0, 1, 2])
      types = server.received.map(&.[0]).join
      types.should eq("PDSPDSPDSBESBESBES")
      conn.close
    ensure
      server.close
    end
  end

  pending_postgres "runs typed queries and keeps a failure to its own future" do
    PostgresSpec.connect do |conn|
      conn.exec("create temp table pets (id int, name text)")
      inserted = nil
      pets = nil
      one = nil
      none = nil
      bad = nil
      missing = nil
      count = nil
      conn.pipeline do |p|
        inserted = p.exec("insert into pets values ($1, $2), ($3, $4)", 1, "rex", 2, "tom")
        bad = p.query_one("select 1 / $1::int", 0, as: Int32)
        pets = p.query_all("select * from pets order by id", as: Pet)
        one = p.query_one("select name from pets where id = $1", 2, as: String)
        none = p.query_one?("select name from pets where id = $1", 9, as: String)
        missing = p.query_one("select name from pets where id = $1", 9, as: String)
        count = p.query_one("select count(*) from pets", as: Int64)
      end
      inserted.not_nil!.value.rows_affected.should eq(2)
      expect_raises(Postgres::QueryError, /division by zero/) { bad.not_nil!.value }
      bad.not_nil!.failed?.should be_true
      pets.not_nil!.value.map(&.name).should eq(["rex", "tom"])
      one.not_nil!.value.should eq("tom")
      none.not_nil!.value.should be_nil
      expect_raises(Postgres::NoRowsError) { missing.not_nil!.value }
      count.not_nil!.value.should eq(2) # independent: the failure did not roll back the insert
      conn.query_one("select 1", as: Int32).should eq(1)
    end
  end

  pending_postgres "fails only the queries whose statement or arguments are bad" do
    PostgresSpec.connect do |conn|
      syntax = nil
      encode = nil
      arity = nil
      good = nil
      conn.pipeline do |p|
        syntax = p.query_one("selec 1", as: Int32)
        encode = p.query_one("select $1::int2", 70_000, as: Int16)
        arity = p.query_one("select $1::int", as: Int32)
        good = p.query_one("select $1::int * 2", 21, as: Int32)
      end
      expect_raises(Postgres::QueryError, /syntax error/) { syntax.not_nil!.value }
      expect_raises(Postgres::EncodeError, /out of range/) { encode.not_nil!.value }
      expect_raises(ArgumentError, /expects 1 parameters, got 0/) { arity.not_nil!.value }
      good.not_nil!.value.should eq(42)
    end
  end

  pending_postgres "is atomic inside a transaction" do
    PostgresSpec.connect do |conn|
      conn.exec("create temp table t (a int)")
      expect_raises(Postgres::QueryError) do
        conn.transaction do |tx|
          f = nil
          tx.pipeline do |p|
            p.exec("insert into t values ($1)", 1)
            f = p.exec("insert into t values ($1)", "x")
          end
          f.not_nil!.value
        end
      end
      conn.query_one("select count(*) from t", as: Int64).should eq(0)
    end
  end

  pending_postgres "reuses cached statements, survives evictions and works uncached" do
    PostgresSpec.connect(statement_cache_size: 2) do |conn|
      results = [] of Postgres::Future(Int32)
      conn.pipeline do |p|
        5.times { |i| results << p.query_one("select #{i}", as: Int32) }
      end
      results.map(&.value).should eq([0, 1, 2, 3, 4])
      conn.statement_cache_size.should eq(2)
      # Preparing this query evicts one more; its Close goes out first.
      conn.query_one("select count(*) from pg_prepared_statements", as: Int64).should eq(2)
    end
    PostgresSpec.connect(statement_cache_size: 0) do |conn|
      a = nil
      b = nil
      conn.pipeline do |p|
        a = p.query_one("select $1::int + 1", 1, as: Int32)
        b = p.query_one("select $1::int + 1", 2, as: Int32)
      end
      {a.not_nil!.value, b.not_nil!.value}.should eq({2, 3})
      conn.query_one("select count(*) from pg_prepared_statements", as: Int64).should eq(0)
    end
  end

  pending_postgres "cancels only the query that exceeds read_timeout" do
    PostgresSpec.connect(read_timeout: 200.milliseconds) do |conn|
      slow = nil
      after = nil
      conn.pipeline do |p|
        slow = p.exec("select pg_sleep(5)")
        after = p.query_one("select 7", as: Int32)
      end
      expect_raises(IO::TimeoutError) { slow.not_nil!.value }
      after.not_nil!.value.should eq(7)
      conn.closed?.should be_false
    end
  end

  pending_postgres "runs on a pooled client" do
    db = Postgres::Client.new(PostgresSpec::URL, pool_size: 2)
    begin
      f = nil
      db.pipeline { |p| f = p.query_all("select generate_series(1, $1)", 3, as: Int32) }
      f.not_nil!.value.should eq([1, 2, 3])
    ensure
      db.close
    end
  end

  it "leaves futures unresolved when the block raises" do
    fut = nil
    expect_raises(Exception, "stop") do
      Postgres::Pipeline.new.tap { |p| fut = p.exec("select 1") }
      raise "stop"
    end
    expect_raises(Postgres::Error, /has not run/) { fut.not_nil!.value }
  end
end
