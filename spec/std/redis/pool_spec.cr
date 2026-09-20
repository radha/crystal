require "spec"
require "wait_group"
require "../../support/redis"

# HELLO → RESP3, PING → +PONG, BAD → -ERR, DIE → close the socket, else +OK.
private def pool_server
  RedisSpec::FakeServer.new do |io|
    while cmd = RedisSpec::FakeServer.read_command(io)
      case cmd[0]
      when "HELLO" then io << RedisSpec::HELLO_REPLY
      when "PING"  then io << "+PONG\r\n"
      when "BAD"   then io << "-ERR bad\r\n"
      when "DIE"
        io.close
        break
      else io << "+OK\r\n"
      end
      io.flush
    end
  end
end

describe Redis::Pool do
  it "opens connections lazily and reuses them" do
    server = pool_server
    pool = Redis::Pool.new(server.url, size: 2)
    pool.size.should eq(2)
    server.accepted.should eq(0)
    pool.idle.should eq(0)
    c1 = pool.checkout
    c2 = pool.checkout
    server.accepted.should eq(2)
    pool.in_use.should eq(2)
    c1.ping.should eq("PONG")
    pool.checkin(c1)
    pool.idle.should eq(1)
    pool.in_use.should eq(1)
    c3 = pool.checkout
    c3.should be(c1)
    server.accepted.should eq(2)
    pool.checkin(c2)
    pool.checkin(c3)
    pool.idle.should eq(2)
    pool.close
    c1.closed?.should be_true
    c2.closed?.should be_true
    server.close
  end

  it "bounds checkouts by size and times out" do
    server = pool_server
    pool = Redis::Pool.new(server.url, size: 1, checkout_timeout: 50.milliseconds)
    held = pool.checkout
    expect_raises(Redis::PoolTimeoutError, /50/) { pool.checkout }
    spawn do
      sleep 20.milliseconds
      pool.checkin(held)
    end
    pool.checkout.should be(held)
    server.accepted.should eq(1)
    pool.close
    server.close
  end

  it "drops a connection that is closed when it comes back" do
    server = pool_server
    pool = Redis::Pool.new(server.url, size: 2)
    conn = pool.checkout
    expect_raises(Redis::ConnectionError) { conn.call("DIE") }
    conn.closed?.should be_true
    pool.checkin(conn)
    pool.idle.should eq(0)
    pool.in_use.should eq(0)
    fresh = pool.checkout
    fresh.should_not be(conn)
    server.accepted.should eq(2)
    fresh.ping.should eq("PONG")
    pool.checkin(fresh)
    pool.close
    server.close
  end

  it "yields a connection and keeps it after an error reply" do
    server = pool_server
    pool = Redis::Pool.new(server.url, size: 2)
    pool.checkout { |conn| conn.ping }.should eq("PONG")
    expect_raises(Redis::CommandError, /bad/) { pool.checkout { |conn| conn.call("BAD") } }
    expect_raises(Exception, "boom") { pool.checkout { |conn| raise "boom" } }
    pool.idle.should eq(1)
    pool.in_use.should eq(0)
    server.accepted.should eq(1)
    pool.close
    server.close
  end

  it "closes idle connections, and in-use ones when they return" do
    server = pool_server
    pool = Redis::Pool.new(server.url, size: 2)
    idle = pool.checkout
    held = pool.checkout
    pool.checkin(idle)
    pool.close
    pool.closed?.should be_true
    idle.closed?.should be_true
    held.closed?.should be_false
    pool.checkin(held)
    held.closed?.should be_true
    pool.idle.should eq(0)
    expect_raises(Redis::ConnectionError, /closed/) { pool.checkout }
    pool.close # idempotent
    server.close
  end

  it "never exceeds size under concurrent use" do
    server = pool_server
    pool = Redis::Pool.new(server.url, size: 4)
    wg = WaitGroup.new(32)
    32.times do
      spawn do
        begin
          50.times { pool.checkout { |conn| conn.ping } }
        ensure
          wg.done
        end
      end
    end
    wg.wait
    server.accepted.should be <= 4
    pool.in_use.should eq(0)
    pool.idle.should be <= 4
    pool.close
    server.close
  end

  it "rejects a non-positive size and a bad protocol" do
    expect_raises(ArgumentError, /size/) { Redis::Pool.new(size: 0) }
    expect_raises(ArgumentError, /protocol/) { Redis::Pool.new(protocol: 4) }
  end
end
