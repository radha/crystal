require "../../support/postgres"
require "../../support/postgres_fake"

private def int4(n : Int32) : Bytes
  bytes = Bytes.new(4)
  IO::ByteFormat::BigEndian.encode(n, bytes)
  bytes
end

describe "Postgres cursors (query_each fetch_size:)" do
  it "fetches the next batch only after the block consumed the current one" do
    fetched = [] of String
    server = PostgresSpec::FakeServer.new do |peer|
      peer.handshake
      peer.answer_prepare(peer.read_until_sync, [] of UInt32, [{"n", Postgres::OID::INT4}])
      # Batch 1.
      3.times { fetched << peer.read_message[0].to_s }
      peer.bind_complete
      peer.data_row([int4(1)])
      peer.data_row([int4(2)])
      peer.send('s') # PortalSuspended
      # The client asks for the next batch only after PortalSuspended.
      2.times { fetched << peer.read_message[0].to_s }
      peer.data_row([int4(3)])
      peer.command_complete("SELECT 3")
      fetched << peer.read_message[0].to_s
      peer.ready('I')
      peer.read_message
    end
    begin
      conn = Postgres::Connection.new(server.url, read_timeout: 1.second)
      rows = [] of Int32
      conn.query_each("select n from t", as: Int32, fetch_size: 2) { |n| rows << n }
      rows.should eq([1, 2, 3])
      fetched.join.should eq("BEHEHS")
      conn.close
    ensure
      server.close
    end
  end

  pending_postgres "streams a large result in batches" do
    PostgresSpec.connect do |conn|
      sum = 0_i64
      count = 0
      conn.query_each("select g from generate_series(1, $1) g", 100_000, as: Int64, fetch_size: 1000) do |g|
        sum += g
        count += 1
      end
      count.should eq(100_000)
      sum.should eq(100_000_i64 * 100_001 // 2)
      conn.query_each("select g, 'x' from generate_series(1, 5) g", as: {Int32, String}, fetch_size: 2) { }
      expect_raises(ArgumentError, /fetch_size must be positive/) { conn.query_each("select 1", as: Int32, fetch_size: 0) { } }
    end
  end

  pending_postgres "stops fetching when the block raises and stays usable" do
    PostgresSpec.connect do |conn|
      seen = 0
      started = Time.instant
      expect_raises(Exception, "enough") do
        # Target-list generate_series streams (in FROM it is materialized
        # first, which would time the server, not the cursor).
        conn.query_each("select generate_series(1, 50000000)", as: Int64, fetch_size: 100) do |g|
          seen += 1
          raise "enough" if g == 150
        end
      end
      seen.should eq(150)
      (Time.instant - started).should be < 2.seconds # did not stream 50M rows
      conn.query_one("select 1", as: Int32).should eq(1)
    end
  end

  pending_postgres "reports a server error in a later batch" do
    PostgresSpec.connect do |conn|
      rows = 0
      expect_raises(Postgres::QueryError, /division by zero/) do
        conn.query_each("select 1 / (150 - g) from generate_series(1, 300) g", as: Int32, fetch_size: 100) { rows += 1 }
      end
      rows.should be >= 100
      conn.query_one("select 2", as: Int32).should eq(2)
    end
  end

  pending_postgres "works inside a transaction and on a pooled client" do
    PostgresSpec.connect do |conn|
      conn.transaction do |tx|
        n = 0
        tx.query_each("select g from generate_series(1, 250) g", as: Int32, fetch_size: 100) { n += 1 }
        n.should eq(250)
        tx.query_one("select 3", as: Int32).should eq(3)
      end
    end
    db = Postgres::Client.new(PostgresSpec::URL, pool_size: 1)
    begin
      total = 0
      db.query_each("select g from generate_series(1, 10) g", as: Int32, fetch_size: 3) { |g| total += g }
      total.should eq(55)
    ensure
      db.close
    end
  end
end
