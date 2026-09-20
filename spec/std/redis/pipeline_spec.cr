# spec/std/redis/pipeline_spec.cr
require "spec"
require "redis"

describe Redis::Pipeline do
  it "records commands into one buffer and hands out futures" do
    p = Redis::Pipeline.new
    f1 = p.set("a", "1")
    f2 = p.get("a")
    f3 = p.incr("n")
    f4 = p.command("CLIENT", "ID")
    p.size.should eq(4)
    p.buffer.to_s.should eq(
      "*3\r\n$3\r\nSET\r\n$1\r\na\r\n$1\r\n1\r\n*2\r\n$3\r\nGET\r\n$1\r\na\r\n*2\r\n$4\r\nINCR\r\n$1\r\nn\r\n*2\r\n$6\r\nCLIENT\r\n$2\r\nID\r\n")
    f1.should be_a(Redis::Future(String?))
    f2.should be_a(Redis::Future(String?))
    f3.should be_a(Redis::Future(Int64))
    f4.should be_a(Redis::Future(Redis::Value))
    f1.resolved?.should be_false
    expect_raises(ArgumentError, /not executed/) { f1.value }
    f1.value?.should be_nil

    p.resolve(0, "OK")
    p.resolve(1, "1")
    p.resolve(2, 1_i64)
    p.resolve(3, 42_i64)
    f1.value.should eq("OK")
    f2.value.should eq("1")
    f3.value.should eq(1_i64)
    f4.value.should eq(42_i64)
  end

  it "raises the exception a future was resolved to" do
    p = Redis::Pipeline.new
    f = p.get("a")
    p.resolve(0, Redis::CommandError.new("WRONGTYPE nope"))
    f.resolved?.should be_true
    f.value?.should be_nil
    expect_raises(Redis::CommandError, /WRONGTYPE/) { f.value }
  end

  it "applies the cast at resolution time" do
    p = Redis::Pipeline.new
    f = p.incr("n")
    p.resolve(0, "not an int")
    expect_raises(Redis::ProtocolError) { f.value }
  end

  it "refuses scan_each" do
    expect_raises(ArgumentError) { Redis::Pipeline.new.scan_each { } }
  end

  it "fails a future with any exception through fail" do
    p = Redis::Pipeline.new
    f = p.get("a")
    g = p.incr("n")
    p.fail(0, IO::TimeoutError.new("slow"))
    p.fail(1, Redis::ConnectionError.new("lost"))
    f.resolved?.should be_true
    f.value?.should be_nil
    expect_raises(IO::TimeoutError, /slow/) { f.value }
    expect_raises(Redis::ConnectionError, /lost/) { g.value }
  end

  it "records routes and byte offsets in routing mode" do
    p = Redis::Pipeline.new(routing: true)
    p.routing?.should be_true
    p.set("a", "1")
    p.command("PING")
    p.get("{tag}b")
    p.routes.map(&.key).should eq(["a", nil, "{tag}b"])
    p.routes.all?(&.retry).should be_true
    # "*3\r\n$3\r\nSET\r\n$1\r\na\r\n$1\r\n1\r\n" is 27 bytes, "*1\r\n$4\r\nPING\r\n" is 14.
    p.offsets.should eq([0, 27, 41])
    p.buffer.bytesize.should eq(41 + "*2\r\n$3\r\nGET\r\n$6\r\n{tag}b\r\n".bytesize)
  end

  it "routes a multi block by its first key and marks it non-retryable" do
    p = Redis::Pipeline.new(routing: true)
    p.get("x")
    p.multi do |tx|
      tx.command("PING")
      tx.incr("{t}a")
      tx.incr("{t}b")
    end
    p.get("y")
    p.size.should eq(7)
    p.routes.map(&.key).should eq(["x", "{t}a", "{t}a", "{t}a", "{t}a", "{t}a", "y"])
    p.routes.map(&.retry).should eq([true, false, false, false, false, false, true])
    p.offsets.size.should eq(7)
    p.offsets.should eq(p.offsets.sort)
    bytes = p.buffer.to_slice
    p.offsets.each { |offset| bytes[offset].should eq('*'.ord.to_u8) }
    bytes[p.offsets[1], 15].should eq("*1\r\n$5\r\nMULTI\r\n".to_slice)
    bytes[p.offsets[5], 14].should eq("*1\r\n$4\r\nEXEC\r\n".to_slice)
  end

  it "records a pipelined script run by its first key" do
    p = Redis::Pipeline.new(routing: true)
    p.run(Redis::Script.new("return 1"), keys: ["k"])
    p.run(Redis::Script.new("return 2"))
    p.routes.map(&.key).should eq(["k", nil])
  end

  it "records nothing outside routing mode" do
    p = Redis::Pipeline.new
    p.get("a")
    p.multi { |tx| tx.get("b") }
    p.routing?.should be_false
    p.routes.should be_empty
    p.offsets.should be_empty
  end
end
