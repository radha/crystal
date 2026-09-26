require "../../support/postgres"

private def with_items(conn, &)
  conn.exec("drop table if exists spec_items")
  conn.exec("create table spec_items (id int8, name text, price numeric, at timestamptz, tags text[])")
  begin
    yield
  ensure
    conn.exec("drop table if exists spec_items")
  end
end

describe "Postgres COPY" do
  pending_postgres "copies text and CSV in and out, streaming" do
    PostgresSpec.connect do |conn|
      with_items(conn) do
        conn.copy_from("copy spec_items (id, name) from stdin") do |io|
          io << "1\tapple\n" << "2\t\\N\n"
        end.should eq(2)
        conn.copy_from("copy spec_items (id, name) from stdin (format csv)", IO::Memory.new("3,\"pear, ripe\"\n")).should eq(1)
        buffer = IO::Memory.new
        conn.copy_to("copy (select id, name from spec_items order by id) to stdout (format csv)", buffer).should eq(3)
        buffer.to_s.should eq("1,apple\n2,\n3,\"pear, ripe\"\n")
        lines = [] of String
        conn.copy_to("copy (select id from spec_items order by id) to stdout") do |io|
          io.each_line { |l| lines << l }
        end
        lines.should eq(["1", "2", "3"])
        conn.query_one("select count(*) from spec_items", as: Int64).should eq(3)
      end
    end
  end

  pending_postgres "streams more than one chunk each way" do
    PostgresSpec.connect do |conn|
      with_items(conn) do
        n = 50_000
        conn.copy_from("copy spec_items (id, name) from stdin") do |io|
          n.times { |i| io << i << '\t' << "name-" << i << '\n' }
        end.should eq(n)
        count = 0
        bytes = 0
        conn.copy_to("copy spec_items (id, name) to stdout") do |io|
          io.each_line { |l| count += 1; bytes += l.bytesize }
        end.should eq(n)
        count.should eq(n)
        bytes.should be > 2 * Postgres::Connection::COPY_CHUNK
      end
    end
  end

  pending_postgres "aborts a copy whose block raises, leaving the session usable" do
    PostgresSpec.connect do |conn|
      with_items(conn) do
        expect_raises(Exception, "halfway") do
          conn.copy_from("copy spec_items (id) from stdin") do |io|
            io << "1\n"
            raise "halfway"
          end
        end
        conn.query_one("select count(*) from spec_items", as: Int64).should eq(0)
        # Bad data: the server rejects it at the end.
        expect_raises(Postgres::QueryError, /invalid input syntax/) do
          conn.copy_from("copy spec_items (id) from stdin") { |io| io << "x\n" }
        end
        conn.query_one("select 1", as: Int32).should eq(1)
        # A block that stops reading early: the rest is discarded.
        conn.copy_from("copy spec_items (id) from stdin") { |io| 100.times { |i| io << i << '\n' } }
        conn.copy_to("copy spec_items (id) to stdout") { |io| io.gets.should eq("0") }.should eq(100)
        conn.query_one("select 2", as: Int32).should eq(2)
      end
    end
  end

  pending_postgres "reports a failing COPY TO and a COPY of the wrong direction" do
    PostgresSpec.connect do |conn|
      expect_raises(Postgres::QueryError, /division by zero/) do
        conn.copy_to("copy (select 1 / (3 - g) from generate_series(1, 5) g) to stdout") { |io| io.gets_to_end }
      end
      conn.query_one("select 1", as: Int32).should eq(1)
      # The block swallows the error: it is raised anyway.
      expect_raises(Postgres::QueryError, /division by zero/) do
        conn.copy_to("copy (select 1 / (3 - g) from generate_series(1, 5) g) to stdout") do |io|
          io.gets_to_end rescue nil
        end
      end
      expect_raises(Postgres::Error, /not a COPY FROM STDIN/) { conn.copy_from("copy (select 1) to stdout") { } }
      conn.exec("create temp table spec_dir (a int)")
      expect_raises(Postgres::Error, /not a COPY TO STDOUT/) { conn.copy_to("copy spec_dir from stdin") { } }
      expect_raises(Postgres::QueryError, /does not exist/) { conn.copy_from("copy spec_missing from stdin") { } }
      expect_raises(Postgres::Error, /did not start a COPY/) { conn.copy_from("select 1") { } }
      conn.query_one("select 3", as: Int32).should eq(3)
    end
  end

  pending_postgres "bulk-inserts typed rows with binary COPY" do
    PostgresSpec.connect do |conn|
      with_items(conn) do
        t = Time.utc(2026, 9, 26, 1, 2, 3)
        conn.copy_rows("spec_items", {"id", "name", "price", "at", "tags"}) do |copy|
          copy.row(1, "apple", BigDecimal.new("1.25"), t, ["red", "fruit"])
          copy.row(2_i64, nil, 3, nil, [] of String)
        end.should eq(2)
        conn.query_one("select name from spec_items where id = 1", as: String).should eq("apple")
        conn.query_one("select price from spec_items where id = 2", as: BigDecimal).should eq(BigDecimal.new(3))
        conn.query_one("select at from spec_items where id = 1", as: Time).should eq(t)
        conn.query_one("select tags from spec_items where id = 1", as: Array(String)).should eq(["red", "fruit"])
        expect_raises(ArgumentError, /expects 2 values/) do
          conn.copy_rows("spec_items", {"id", "name"}) { |copy| copy.row(1) }
        end
        expect_raises(Postgres::EncodeError, /column id: binary COPY cannot send String as int8/) do
          conn.copy_rows("spec_items", {"id"}) { |copy| copy.row("seven") }
        end
        conn.query_one("select count(*) from spec_items", as: Int64).should eq(2)
      end
    end
  end
end
