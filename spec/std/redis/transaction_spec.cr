# spec/std/redis/transaction_spec.cr
require "spec"
require "../../support/redis"

private def values(*items) : Array(Redis::Value)
  # Not `items.map(&.as(Redis::Value)).to_a`: `Tuple#map` fails to compile
  # once one of *items* is itself an `Array(Redis::Value)` (a nested
  # `values(...)` call), a quirk of `Redis::Value`'s self-referential
  # alias tripping up the block's inferred type across heterogeneous tuple
  # elements.
  Array(Redis::Value).new(items.size) { |i| items[i].as(Redis::Value) }
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
    p.fail(2, Redis::ConnectionError.new("connection lost"))
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

# A fake server with MULTI state per connection. Inside MULTI every
# command is queued and answered +QUEUED, except BADARITY which is
# rejected at queue time; EXEC answers -EXECABORT after a rejection, *-1
# when `abort` is set, an empty array if a SHORT command was queued, and
# otherwise one reply per queued command. `chunks` records how many
# commands each socket read returned.
private class TxServer
  getter chunks = [] of Int32
  getter seen = [] of Array(String)
  property abort = false

  def server
    RedisSpec::FakeServer.new do |io|
      queued = nil.as(Array(Array(String))?)
      buffer = Bytes.new(65536)
      loop do
        n = io.read(buffer)
        break if n == 0
        mem = IO::Memory.new(buffer[0, n])
        count = 0
        while cmd = RedisSpec::FakeServer.read_command(mem)
          count += 1
          @seen << cmd
          if q = queued
            if cmd[0] == "EXEC"
              queued = nil
              if q.any? { |c| c[0] == "BADARITY" }
                io << "-EXECABORT Transaction discarded because of previous errors.\r\n"
              elsif @abort
                io << "*-1\r\n"
              elsif q.any? { |c| c[0] == "SHORT" }
                io << "*0\r\n"
              else
                io << "*#{q.size}\r\n"
                q.each { |c| io << reply_for(c) }
              end
            else
              q << cmd
              io << (cmd[0] == "BADARITY" ? "-ERR wrong number of arguments for 'badarity' command\r\n" : "+QUEUED\r\n")
            end
          else
            case cmd[0]
            when "HELLO"
              io << RedisSpec::HELLO_REPLY
            when "MULTI"
              queued = [] of Array(String)
              io << "+OK\r\n"
            else
              io << reply_for(cmd)
            end
          end
        end
        @chunks << count if count > 0
        io.flush
      end
    end
  end

  # Commands seen after the handshake, first element only.
  def names : Array(String)
    @seen.reject { |c| c[0] == "HELLO" }.map(&.first)
  end

  private def reply_for(cmd : Array(String)) : String
    case cmd[0]
    when "INCR"    then ":1\r\n"
    when "GET"     then "$1\r\nv\r\n"
    when "FAILRUN" then "-ERR runtime failure\r\n"
    else                "+OK\r\n"
    end
  end
end

describe "Redis::Client#multi" do
  it "sends MULTI, the commands and EXEC in one chunk and returns the EXEC array" do
    fake = TxServer.new
    server = fake.server
    client = Redis::Client.new(server.url)
    client.ping
    f1 = nil
    f2 = nil
    replies = client.multi do |tx|
      f1 = tx.set("a", "1")
      f2 = tx.incr("n")
    end
    replies.should eq(values("OK", 1_i64))
    f1.not_nil!.value.should eq("OK")
    f2.not_nil!.value.should eq(1_i64)
    fake.chunks.should eq([1, 1, 4])
    fake.names.should eq(["PING", "MULTI", "SET", "INCR", "EXEC"])
    client.close
    server.close
  end

  it "inside pipelined returns the raw replies including OK and QUEUED" do
    fake = TxServer.new
    server = fake.server
    client = Redis::Client.new(server.url)
    exec = nil
    raw = client.pipelined do |p|
      p.get("x")
      exec = p.multi { |tx| tx.incr("n") }
    end
    raw.should eq(values("v", "OK", "QUEUED", values(1_i64)))
    exec.not_nil!.value.should eq(values(1_i64))
    client.close
    server.close
  end

  it "raises EXECABORT and keeps the queue-time error on its own future" do
    fake = TxServer.new
    server = fake.server
    client = Redis::Client.new(server.url)
    f1 = nil
    f2 = nil
    ex = expect_raises(Redis::CommandError) do
      client.multi do |tx|
        f1 = tx.command("BADARITY")
        f2 = tx.incr("n")
      end
    end
    ex.code.should eq("EXECABORT")
    expect_raises(Redis::CommandError, /wrong number/) { f1.not_nil!.value }
    expect_raises(Redis::CommandError, /EXECABORT/) { f2.not_nil!.value }
    client.close
    server.close
  end

  it "raises AbortedError when EXEC replies nil" do
    fake = TxServer.new
    fake.abort = true
    server = fake.server
    client = Redis::Client.new(server.url)
    f = nil
    expect_raises(Redis::AbortedError) { client.multi { |tx| f = tx.incr("n") } }
    expect_raises(Redis::AbortedError) { f.not_nil!.value }
    client.close
    server.close
  end

  it "keeps a runtime error as a value" do
    fake = TxServer.new
    server = fake.server
    client = Redis::Client.new(server.url)
    f1 = nil
    f2 = nil
    replies = client.multi do |tx|
      f1 = tx.command("FAILRUN")
      f2 = tx.incr("n")
    end
    replies.size.should eq(2)
    replies[0].should be_a(Redis::CommandError)
    replies[1].should eq(1_i64)
    expect_raises(Redis::CommandError, /runtime/) { f1.not_nil!.value }
    f2.not_nil!.value.should eq(1_i64)
    client.close
    server.close
  end

  it "an empty block does nothing" do
    fake = TxServer.new
    server = fake.server
    client = Redis::Client.new(server.url)
    client.multi { |tx| }.should eq([] of Redis::Value)
    fake.seen.should be_empty
    client.close
    server.close
  end
end

describe "Redis::Connection#pipelined and #multi" do
  it "produce the same bytes and results as the client" do
    fake = TxServer.new
    server = fake.server
    conn = Redis::Connection.new(server.url)
    f = nil
    raw = conn.pipelined do |p|
      p.get("x")
      f = p.incr("n")
    end
    raw.should eq(values("v", 1_i64))
    f.not_nil!.value.should eq(1_i64)
    fake.chunks.should eq([1, 2])
    g = nil
    conn.multi { |tx| g = tx.incr("n") }.should eq(values(1_i64))
    g.not_nil!.value.should eq(1_i64)
    fake.chunks.should eq([1, 2, 3])
    # The mismatch is detected when the future is read, not on the socket,
    # so the connection stays usable.
    expect_raises(Redis::ProtocolError) { conn.multi { |tx| tx.command("SHORT") } }
    conn.closed?.should be_false
    conn.ping.should eq("OK")
    conn.close
    server.close
  end

  it "resolves the remaining futures when the connection drops mid-pipeline" do
    server = RedisSpec::FakeServer.new do |io|
      while cmd = RedisSpec::FakeServer.read_command(io)
        case cmd[0]
        when "HELLO" then io << RedisSpec::HELLO_REPLY
        when "DIE"   then io.close
        else              io << "+OK\r\n"
        end
        io.flush
      end
    end
    conn = Redis::Connection.new(server.url)
    f1 = nil
    f2 = nil
    expect_raises(Redis::ConnectionError) do
      conn.pipelined do |p|
        f1 = p.command("ONE")
        f2 = p.command("DIE")
      end
    end
    f1.not_nil!.value.should eq("OK")
    expect_raises(Redis::ConnectionError) { f2.not_nil!.value }
    server.close
  end
end

describe "Redis::Client#watch" do
  it "borrows a pooled connection, sends WATCH, yields it and hands it back" do
    fake = TxServer.new
    server = fake.server
    client = Redis::Client.new(server.url, db: 3)
    client.ping
    inner = nil
    result = client.watch("k1", "k2") do |conn|
      inner = conn
      conn.get("k1").should eq("v")
      conn.multi { |tx| tx.set("k1", "w") }
    end
    result.should eq(values("OK"))
    server.accepted.should eq(2)
    inner.not_nil!.closed?.should be_false
    # Once from the client's own connection, once from the pooled one.
    fake.seen.count(["SELECT", "3"]).should eq(2)
    fake.seen.should contain(["WATCH", "k1", "k2"])
    # EXEC discarded the watch; no UNWATCH round trip.
    fake.seen.should_not contain(["UNWATCH"])
    # A second watch reuses the pooled connection.
    client.watch("k1") { |conn| conn.should be(inner) }
    server.accepted.should eq(2)
    # That block never ran multi, so the watch was cleared by hand.
    fake.seen.last.should eq(["UNWATCH"])
    client.connected?.should be_true
    client.close
    inner.not_nil!.closed?.should be_true
    server.close
  end

  it "unwatches when the block raises before multi and refuses no keys" do
    fake = TxServer.new
    server = fake.server
    client = Redis::Client.new(server.url)
    inner = nil
    expect_raises(ArgumentError, /at least one key/) { client.watch { |conn| } }
    expect_raises(Redis::AbortedError) do
      client.watch("k") do |conn|
        inner = conn
        fake.abort = true
        conn.multi { |tx| tx.set("k", "w") }
      end
    end
    inner.not_nil!.closed?.should be_false
    fake.seen.should_not contain(["UNWATCH"])
    expect_raises(Exception, "boom") { client.watch("k") { |conn| raise "boom" } }
    fake.seen.last.should eq(["UNWATCH"])
    client.close
    server.close
  end
end
