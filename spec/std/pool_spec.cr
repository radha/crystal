require "spec"
require "wait_group"
require "pool"

private class FakeConnection
  getter id : Int32
  getter? closed = false

  def initialize(@id : Int32)
  end

  def close : Nil
    @closed = true
  end
end

# A pool whose factory numbers the connections it opens; `opened` returns
# how many it opened so far.
private class Factory
  getter opened = 0

  def call : FakeConnection
    @opened += 1
    FakeConnection.new(@opened)
  end
end

private def new_pool(factory, **options)
  Pool(FakeConnection).new(**options) { factory.call }
end

describe Pool do
  it "opens connections lazily and reuses them in FIFO order" do
    factory = Factory.new
    pool = new_pool(factory, size: 3)
    pool.size.should eq(3)
    factory.opened.should eq(0)
    pool.idle.should eq(0)
    c1 = pool.checkout
    c2 = pool.checkout
    factory.opened.should eq(2)
    pool.in_use.should eq(2)
    pool.checkin(c1)
    pool.checkin(c2)
    pool.idle.should eq(2)
    pool.in_use.should eq(0)
    pool.checkout.should be(c1)
    pool.checkout.should be(c2)
    factory.opened.should eq(2)
    pool.close
  end

  it "bounds checkouts by size and times out" do
    factory = Factory.new
    pool = new_pool(factory, size: 1, checkout_timeout: 50.milliseconds)
    held = pool.checkout
    expect_raises(Pool::TimeoutError, "no connection available after 00:00:00.050000000") { pool.checkout }
    pool.in_use.should eq(1)
    spawn do
      sleep 20.milliseconds
      pool.checkin(held)
    end
    pool.checkout.should be(held)
    factory.opened.should eq(1)
    pool.close
  end

  it "drops a connection that is closed when it comes back" do
    factory = Factory.new
    pool = new_pool(factory, size: 2)
    conn = pool.checkout
    conn.close
    pool.checkin(conn)
    pool.idle.should eq(0)
    pool.in_use.should eq(0)
    fresh = pool.checkout
    fresh.should_not be(conn)
    factory.opened.should eq(2)
    pool.checkin(fresh)
    pool.close
  end

  it "skips a connection closed while idle" do
    factory = Factory.new
    pool = new_pool(factory, size: 2)
    c1 = pool.checkout
    c2 = pool.checkout
    pool.checkin(c1)
    pool.checkin(c2)
    c1.close
    pool.checkout.should be(c2)
    pool.idle.should eq(0)
    pool.checkout.id.should eq(3)
    pool.close
  end

  it "yields a connection and keeps it after the block raises" do
    factory = Factory.new
    pool = new_pool(factory, size: 2)
    pool.checkout(&.id).should eq(1)
    expect_raises(Exception, "boom") { pool.checkout { raise "boom" } }
    pool.idle.should eq(1)
    pool.in_use.should eq(0)
    pool.checkout(&.closed?).should be_false
    factory.opened.should eq(1)
    pool.close
  end

  it "returns the permit when the factory raises" do
    fail = true
    pool = Pool(FakeConnection).new(size: 1, checkout_timeout: 50.milliseconds) do
      raise IO::Error.new("refused") if fail
      FakeConnection.new(1)
    end
    expect_raises(IO::Error, "refused") { pool.checkout }
    pool.in_use.should eq(0)
    fail = false
    conn = pool.checkout
    conn.id.should eq(1)
    pool.in_use.should eq(1)
    pool.checkin(conn)
    pool.close
  end

  it "closes idle connections, and in-use ones when they return" do
    factory = Factory.new
    pool = new_pool(factory, size: 2)
    idle = pool.checkout
    held = pool.checkout
    pool.checkin(idle)
    pool.closed?.should be_false
    pool.close
    pool.closed?.should be_true
    idle.closed?.should be_true
    held.closed?.should be_false
    pool.checkin(held)
    held.closed?.should be_true
    pool.idle.should eq(0)
    pool.in_use.should eq(0)
    pool.close # idempotent
  end

  it "raises ClosedError on checkout after close" do
    pool = new_pool(Factory.new, size: 1)
    pool.close
    expect_raises(Pool::ClosedError, "pool is closed") { pool.checkout }
    expect_raises(Pool::ClosedError) { pool.checkout { } }
    pool.in_use.should eq(0)
  end

  describe "health check" do
    it "is not run on a connection idle for less than health_check_after" do
      checks = 0
      factory = Factory.new
      pool = Pool(FakeConnection).new(size: 1, health_check: ->(c : FakeConnection) { checks += 1; false },
        health_check_after: 1.hour) { factory.call }
      pool.health_check_after.should eq(1.hour)
      conn = pool.checkout
      pool.checkin(conn)
      pool.checkout.should be(conn)
      checks.should eq(0)
      conn.closed?.should be_false
      pool.close
    end

    it "is not run on a freshly opened connection" do
      checks = 0
      pool = Pool(FakeConnection).new(size: 1, health_check: ->(c : FakeConnection) { checks += 1; false },
        health_check_after: 0.seconds) { FakeConnection.new(1) }
      pool.checkout.closed?.should be_false
      checks.should eq(0)
    end

    it "keeps a connection that passes" do
      checked = [] of Int32
      factory = Factory.new
      pool = Pool(FakeConnection).new(size: 1, health_check: ->(c : FakeConnection) { checked << c.id; true },
        health_check_after: 0.seconds) { factory.call }
      conn = pool.checkout
      pool.checkin(conn)
      pool.checkout.should be(conn)
      checked.should eq([1])
      factory.opened.should eq(1)
      pool.close
    end

    it "closes a connection that fails and opens a replacement" do
      factory = Factory.new
      pool = Pool(FakeConnection).new(size: 1, health_check: ->(c : FakeConnection) { false },
        health_check_after: 0.seconds) { factory.call }
      conn = pool.checkout
      pool.checkin(conn)
      fresh = pool.checkout
      fresh.should_not be(conn)
      conn.closed?.should be_true
      fresh.id.should eq(2)
      pool.in_use.should eq(1)
      pool.idle.should eq(0)
      pool.close
    end

    it "closes a connection whose check raises and tries the next idle one" do
      factory = Factory.new
      pool = Pool(FakeConnection).new(size: 2,
        health_check: ->(c : FakeConnection) { c.id == 1 ? raise("broken") : true },
        health_check_after: 0.seconds) { factory.call }
      c1 = pool.checkout
      c2 = pool.checkout
      pool.checkin(c1)
      pool.checkin(c2)
      pool.checkout.should be(c2)
      c1.closed?.should be_true
      pool.idle.should eq(0)
      pool.in_use.should eq(1)
      factory.opened.should eq(2)
      pool.close
    end
  end

  it "rejects a non-positive size" do
    expect_raises(ArgumentError, /size/) { Pool(FakeConnection).new(size: 0) { FakeConnection.new(1) } }
    expect_raises(ArgumentError, /size/) { Pool(FakeConnection).new(size: -1) { FakeConnection.new(1) } }
  end

  it "never exceeds size under concurrent use" do
    factory = Factory.new
    pool = new_pool(factory, size: 4)
    open_now = Atomic(Int32).new(0)
    max_open = Atomic(Int32).new(0)
    wg = WaitGroup.new(50)
    50.times do
      spawn do
        begin
          20.times do
            pool.checkout do
              max_open.max(open_now.add(1) + 1)
              Fiber.yield
              open_now.sub(1)
            end
          end
        ensure
          wg.done
        end
      end
    end
    wg.wait
    max_open.get.should be <= 4
    factory.opened.should be <= 4
    pool.in_use.should eq(0)
    pool.idle.should be <= 4
    pool.close
  end
end
