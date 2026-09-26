require "../../support/postgres"

private struct Poison
  def to_pg : Int64
    raise NilAssertionError.new("poisoned")
  end
end

private def first_row(conn : Postgres::Connection) : Int32
  conn.query_each("select generate_series(1, 3)", as: Int32) { |n| return n }
  -1
end

private def commit_by_return(conn : Postgres::Connection) : Int32
  conn.transaction do |tx|
    tx.exec("insert into spec_reg values (1)")
    return 1
  end
  0
end

# Replays of the pre-merge review's reproductions (2026-09-26).
describe "Postgres review regressions" do
  pending_postgres "keeps the session in step after break/return out of query_each" do
    PostgresSpec.connect do |conn|
      conn.query_each("select generate_series(1, 3)", as: Int32) { break }
      conn.exec("select 1").command.should eq("SELECT")
      first_row(conn).should eq(1)
      conn.query_one("select 42", as: Int32).should eq(42)
      # Cursor mode: the Sync that ends the portal is sent.
      conn.query_each("select generate_series(1, 1000)", as: Int32, fetch_size: 10) { |n| break if n == 15 }
      conn.query_one("select 43", as: Int32).should eq(43)
      conn.closed?.should be_false
    end
  end

  pending_postgres "commits a transaction left with return or break" do
    PostgresSpec.connect do |conn|
      conn.exec("create temp table spec_reg (a int)")
      commit_by_return(conn).should eq(1)
      conn.transaction_status.should eq('I')
      conn.transaction { |tx| break }
      conn.transaction_status.should eq('I')
      conn.query_one("select count(*) from spec_reg", as: Int64).should eq(1)
      # Depth was reset: a new transaction is a transaction, not a savepoint.
      conn.transaction { |tx| tx.query_one("select count(*) from pg_stat_activity where pid = pg_backend_pid() and state = 'active'", as: Int64) }
      conn.transaction_status.should eq('I')
    end
  end

  pending_postgres "never hands a pooled connection back inside a transaction" do
    db = Postgres::Client.new(PostgresSpec::URL, pool_size: 1)
    begin
      db.with_connection { |c| c.exec("begin") }
      db.query_one("select 1", as: Int32).should eq(1)
      db.with_connection(&.transaction_status).should eq('I')
    ensure
      db.close
    end
  end

  pending_postgres "keeps the unnamed statement when the cache is off and types are introspected" do
    PostgresSpec.connect(statement_cache_size: 0) do |conn|
      conn.exec("drop type if exists spec_rv_mood cascade; create type spec_rv_mood as enum ('ok', 'bad')")
      begin
        conn.query_one("select $1::spec_rv_mood::text", "ok", as: String).should eq("ok")
      ensure
        conn.exec("drop type if exists spec_rv_mood cascade")
      end
    end
  end

  pending_postgres "does not close a statement a pipeline still binds when introspection evicts it" do
    PostgresSpec.connect(statement_cache_size: 2) do |conn|
      conn.exec("drop type if exists spec_rv_color cascade; create type spec_rv_color as enum ('red')")
      begin
        conn.query_one("select 1", as: Int32)
        conn.query_one("select 2", as: Int32)
        a = nil
        b = nil
        c = nil
        conn.pipeline do |p|
          a = p.query_one("select 1", as: Int32)
          b = p.query_one("select 2", as: Int32)
          c = p.query_one("select $1::spec_rv_color::text", "red", as: String)
        end
        {a.not_nil!.value, b.not_nil!.value, c.not_nil!.value}.should eq({1, 2, "red"})
        conn.query_one("select 3", as: Int32).should eq(3)
      ensure
        conn.exec("drop type if exists spec_rv_color cascade")
      end
    end
  end

  pending_postgres "reads the rest of round 1 when one prepare times out" do
    PostgresSpec.connect do |admin|
      admin.exec("drop table if exists spec_locked; create table spec_locked (a int)")
      begin
        admin.exec("begin")
        admin.exec("lock table spec_locked in access exclusive mode")
        PostgresSpec.connect(read_timeout: 300.milliseconds) do |conn|
          x = nil
          y = nil
          conn.pipeline do |p|
            x = p.query_all("select a from spec_locked", as: Int32)
            y = p.query_one("select 5", as: Int32)
          end
          expect_raises(IO::TimeoutError) { x.not_nil!.value }
          y.not_nil!.value.should eq(5)
          conn.closed?.should be_false
          conn.query_one("select 6", as: Int32).should eq(6)
        end
      ensure
        admin.exec("rollback") rescue nil
        admin.exec("drop table if exists spec_locked")
      end
    end
  end

  pending_postgres "finishes a COPY left with break" do
    PostgresSpec.connect do |conn|
      conn.exec("create temp table spec_copy_reg (a int)")
      conn.copy_from("copy spec_copy_reg from stdin") do |io|
        io << "1\n2\n"
        break
      end
      conn.query_one("select count(*) from spec_copy_reg", as: Int64).should eq(2)
    end
  end

  pending_postgres "ends a cursor over an empty query" do
    PostgresSpec.connect(read_timeout: 1.second) do |conn|
      started = Time.instant
      conn.query_each("-- nothing", as: Int32, fetch_size: 2) { }
      (Time.instant - started).should be < 500.milliseconds
      conn.closed?.should be_false
    end
  end

  pending_postgres "survives an encoder raising something else than EncodeError" do
    PostgresSpec.connect do |conn|
      expect_raises(NilAssertionError, "poisoned") { conn.query_one("select $1::int8", Poison.new, as: Int64) }
      conn.query_one("select 1", as: Int32).should eq(1)
      f = nil
      conn.pipeline { |p| f = p.query_one("select $1::int8", Poison.new, as: Int64) }
      expect_raises(NilAssertionError) { f.not_nil!.value }
      conn.query_one("select 2", as: Int32).should eq(2)
    end
  end

  pending_postgres "closes the server-side statement after a result type change" do
    PostgresSpec.connect(statement_cache_size: 2) do |conn|
      conn.exec("create temp table spec_stale (a int)")
      conn.query_all("select * from spec_stale", as: Int32)
      conn.exec("alter table spec_stale alter column a type text")
      conn.query_all("select * from spec_stale", as: String)
      conn.query_one("select count(*) from pg_prepared_statements", as: Int64).should be <= 2
    end
  end
end
