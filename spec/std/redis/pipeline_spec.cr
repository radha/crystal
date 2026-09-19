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
end
