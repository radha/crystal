# spec/std/redis/transaction_spec.cr
require "spec"
require "../../support/redis"

private def values(*items) : Array(Redis::Value)
  items.map(&.as(Redis::Value)).to_a
end

describe Redis::Transaction do
  it "wraps the commands in MULTI and EXEC and fans the EXEC array out" do
    p = Redis::Pipeline.new
    before = p.get("x")
    f1 = nil
    f2 = nil
    exec = p.multi do |tx|
      f1 = tx.set("a", "1")
      f2 = tx.incr("n")
    end
    p.size.should eq(5)
    p.buffer.to_s.should eq(
      "*2\r\n$3\r\nGET\r\n$1\r\nx\r\n" \
      "*1\r\n$5\r\nMULTI\r\n" \
      "*3\r\n$3\r\nSET\r\n$1\r\na\r\n$1\r\n1\r\n" \
      "*2\r\n$4\r\nINCR\r\n$1\r\nn\r\n" \
      "*1\r\n$4\r\nEXEC\r\n")
    exec.should be_a(Redis::Future(Array(Redis::Value)))
    exec.resolved?.should be_false
    p.resolve(0, "v")
    p.resolve(1, "OK")
    p.resolve(2, "QUEUED")
    p.resolve(3, "QUEUED")
    f1.not_nil!.resolved?.should be_false
    p.resolve(4, values("OK", 7_i64))
    before.value.should eq("v")
    exec.value.should eq(values("OK", 7_i64))
    f1.not_nil!.value.should eq("OK")
    f2.not_nil!.value.should eq(7_i64)
  end

  it "nil EXEC raises AbortedError on the exec future and every command" do
    p = Redis::Pipeline.new
    f = nil
    exec = p.multi { |tx| f = tx.incr("n") }
    p.resolve(0, "OK")
    p.resolve(1, "QUEUED")
    p.resolve(2, nil)
    exec.resolved?.should be_true
    exec.value?.should be_nil
    expect_raises(Redis::AbortedError) { exec.value }
    expect_raises(Redis::AbortedError) { f.not_nil!.value }
  end

  it "EXECABORT reaches every future, a queue-time rejection keeps its own error" do
    p = Redis::Pipeline.new
    f1 = nil
    f2 = nil
    exec = p.multi do |tx|
      f1 = tx.command("BADARITY")
      f2 = tx.incr("n")
    end
    p.resolve(0, "OK")
    p.resolve(1, Redis::CommandError.new("ERR wrong number of arguments"))
    p.resolve(2, "QUEUED")
    p.resolve(3, Redis::CommandError.new("EXECABORT Transaction discarded because of previous errors."))
    expect_raises(Redis::CommandError, /EXECABORT/) { exec.value }
    expect_raises(Redis::CommandError, /wrong number/) { f1.not_nil!.value }
    expect_raises(Redis::CommandError, /EXECABORT/) { f2.not_nil!.value }
  end

  it "a runtime error inside EXEC stays a value and only its future raises" do
    p = Redis::Pipeline.new
    f1 = nil
    f2 = nil
    exec = p.multi do |tx|
      f1 = tx.command("FAILRUN")
      f2 = tx.incr("n")
    end
    p.resolve(0, "OK")
    p.resolve(1, "QUEUED")
    p.resolve(2, "QUEUED")
    err = Redis::CommandError.new("ERR runtime failure")
    p.resolve(3, values(err, 1_i64))
    exec.value.should eq(values(err, 1_i64))
    expect_raises(Redis::CommandError, /runtime/) { f1.not_nil!.value }
    f2.not_nil!.value.should eq(1_i64)
  end

  it "a connection failure reaches every unresolved future" do
    p = Redis::Pipeline.new
    f = nil
    exec = p.multi { |tx| f = tx.incr("n") }
    p.resolve(0, "OK")
    p.resolve(1, "QUEUED")
    p.resolve(2, Redis::ConnectionError.new("connection lost"))
    expect_raises(Redis::ConnectionError) { exec.value }
    expect_raises(Redis::ConnectionError) { f.not_nil!.value }
  end

  it "a size mismatch is a ProtocolError everywhere" do
    p = Redis::Pipeline.new
    f = nil
    exec = p.multi { |tx| f = tx.incr("n") }
    p.resolve(0, "OK")
    p.resolve(1, "QUEUED")
    p.resolve(2, values(1_i64, 2_i64))
    expect_raises(Redis::ProtocolError, /2 replies for 1/) { exec.value }
    expect_raises(Redis::ProtocolError) { f.not_nil!.value }
  end

  it "an unexpected EXEC reply is a ProtocolError" do
    p = Redis::Pipeline.new
    f = nil
    exec = p.multi { |tx| f = tx.incr("n") }
    p.resolve(0, "OK")
    p.resolve(1, "QUEUED")
    p.resolve(2, "OK")
    expect_raises(Redis::ProtocolError) { exec.value }
    expect_raises(Redis::ProtocolError) { f.not_nil!.value }
  end

  it "an empty block appends nothing and resolves to an empty array" do
    p = Redis::Pipeline.new
    exec = p.multi { |tx| }
    p.size.should eq(0)
    p.buffer.to_s.should eq("")
    exec.resolved?.should be_true
    exec.value.should eq([] of Redis::Value)
  end

  it "refuses a nested multi" do
    p = Redis::Pipeline.new
    expect_raises(ArgumentError, /nested/) do
      p.multi { |tx| tx.multi { |inner| } }
    end
  end

  it "runs scripts inside a transaction with the pipeline's cache" do
    cache = Redis::ScriptCache.new
    script = Redis::Script.new("return 1")
    cache.add(script.sha)
    p = Redis::Pipeline.new(cache)
    f = nil
    p.multi { |tx| f = tx.run(script) }
    p.buffer.to_s.should contain("EVALSHA")
    p.resolve(0, "OK")
    p.resolve(1, "QUEUED")
    p.resolve(2, values(1_i64))
    f.not_nil!.value.should eq(1_i64)
  end
end
