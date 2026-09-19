require "spec"
require "../../support/redis"

# Fake server: HELLO → RESP3, PING → +PONG or the echoed arg, INCR → :1,
# HANG → never reply, DIE → close socket, BAD → -ERR, PUSHY → push then +OK.
# `chunks` records how many commands each socket read returned.
private class Script
  getter chunks = [] of Int32
  getter connections = 0

  def server
    RedisSpec::FakeServer.new do |io|
      @connections += 1
      buffer = Bytes.new(65536)
      loop do
        n = io.read(buffer)
        break if n == 0
        mem = IO::Memory.new(buffer[0, n])
        count = 0
        while cmd = RedisSpec::FakeServer.read_command(mem)
          count += 1
          case cmd[0]
          when "HELLO"  then io << RedisSpec::HELLO_REPLY
          when "PING"   then io << (cmd[1]? ? "$#{cmd[1].bytesize}\r\n#{cmd[1]}\r\n" : "+PONG\r\n")
          when "INCR"   then io << ":1\r\n"
          when "BAD"    then io << "-ERR bad\r\n"
          when "PUSHY"  then io << ">2\r\n+message\r\n+hi\r\n+OK\r\n"
          when "DESYNC" then io << "+OK\r\n+EXTRA\r\n"
          when "HANG"   then nil
          when "DIE"    then io.close; break
          else               io << "+OK\r\n"
          end
        end
        @chunks << count if count > 0
        break if io.closed?
        io.flush
      end
    end
  end
end

describe Redis::Client do
  it "connects lazily on first call and answers" do
    script = Script.new
    server = script.server
    client = Redis::Client.new(server.url)
    client.connected?.should be_false
    client.protocol.should be_nil
    client.ping.should eq("PONG")
    client.connected?.should be_true
    client.protocol.should eq(3)
    client.call("PING", "x").should eq("x")
    client.command("PING", "y").should eq("y")
    script.connections.should eq(1)
    client.close
    client.closed?.should be_true
    expect_raises(Redis::ConnectionError, /closed/) { client.ping }
    server.close
  end

  it "batches commands from concurrent fibers into one write" do
    script = Script.new
    server = script.server
    client = Redis::Client.new(server.url)
    client.ping
    script.chunks.clear
    done = Channel(Int64).new
    32.times { spawn { done.send(client.incr("n")) } }
    32.times { done.receive.should eq(1_i64) }
    script.chunks.sum.should eq(32)
    script.chunks.max.should be > 1
    client.close
    server.close
  end

  it "raises CommandError for error replies and keeps working" do
    server = Script.new.server
    client = Redis::Client.new(server.url)
    expect_raises(Redis::CommandError, /bad/) { client.call("BAD") }
    client.ping.should eq("PONG")
    client.close
    server.close
  end

  it "fails every pending caller when the connection drops, then reconnects" do
    script = Script.new
    server = script.server
    client = Redis::Client.new(server.url)
    client.ping
    errors = Channel(Exception?).new
    3.times do
      spawn do
        begin
          client.call("HANG")
          errors.send(nil)
        rescue ex
          errors.send(ex)
        end
      end
    end
    spawn { client.call("DIE") rescue nil }
    3.times { errors.receive.should be_a(Redis::ConnectionError) }
    client.connected?.should be_false
    client.ping.should eq("PONG")
    script.connections.should eq(2)
    client.close
    server.close
  end

  it "enforces read_timeout per command and tears the connection down" do
    script = Script.new
    server = script.server
    client = Redis::Client.new(server.url, read_timeout: 50.milliseconds)
    expect_raises(IO::TimeoutError) { client.call("HANG") }
    client.connected?.should be_false
    client.ping.should eq("PONG")
    script.connections.should eq(2)
    client.close
    server.close
  end

  it "treats an unsolicited reply as a protocol desync" do
    server = Script.new.server
    client = Redis::Client.new(server.url)
    client.call("DESYNC").should eq("OK")
    # the extra +EXTRA reply arrives with no waiter: the reader disconnects
    sleep 0.05.seconds
    client.connected?.should be_false
    client.ping.should eq("PONG")
    client.close
    server.close
  end

  it "routes push frames to push_handler without consuming a waiter" do
    server = Script.new.server
    client = Redis::Client.new(server.url)
    pushes = [] of Array(Redis::Value)
    client.push_handler = ->(p : Array(Redis::Value)) { pushes << p }
    client.call("PUSHY").should eq("OK")
    pushes.should eq([["message", "hi"] of Redis::Value])
    client.close
    server.close
  end

  it "pipelined sends once, resolves futures and returns raw values" do
    script = Script.new
    server = script.server
    client = Redis::Client.new(server.url)
    client.ping
    script.chunks.clear
    f = nil
    results = client.pipelined do |p|
      p.ping
      f = p.incr("n")
      p.call("BAD")
      p.ping("z")
    end
    results.size.should eq(4)
    results[0].should eq("PONG")
    results[1].should eq(1_i64)
    results[2].as(Redis::CommandError).code.should eq("ERR")
    results[3].should eq("z")
    f.not_nil!.value.should eq(1_i64)
    script.chunks.should eq([4])
    client.pipelined { |p| }.should eq([] of Redis::Value)
    client.close
    server.close
  end

  it "disconnects when the push handler raises" do
    script = Script.new
    server = script.server
    client = Redis::Client.new(server.url)
    client.push_handler = ->(p : Array(Redis::Value)) { raise "boom" }
    ex = expect_raises(Redis::ConnectionError, /boom/) { client.call("PUSHY") }
    ex.cause.try(&.message).should eq("boom")
    client.connected?.should be_false
    client.ping.should eq("PONG")
    script.connections.should eq(2)
    client.close
    server.close
  end

  it "resolves every remaining future when read_timeout fires mid-pipeline" do
    server = Script.new.server
    client = Redis::Client.new(server.url, read_timeout: 50.milliseconds)
    first = nil
    second = nil
    expect_raises(IO::TimeoutError) do
      client.pipelined do |p|
        first = p.ping
        second = p.call("HANG")
      end
    end
    first.not_nil!.value.should eq("PONG")
    second.not_nil!.resolved?.should be_true
    expect_raises(IO::TimeoutError) { second.not_nil!.value }
    client.connected?.should be_false
    client.ping.should eq("PONG")
    client.close
    server.close
  end

  it "pipelined raises ConnectionError when the connection drops mid-pipeline" do
    server = Script.new.server
    client = Redis::Client.new(server.url)
    client.ping
    f = nil
    expect_raises(Redis::ConnectionError) do
      client.pipelined do |p|
        f = p.ping
        p.call("DIE")
      end
    end
    f.not_nil!.resolved?.should be_true
    client.close
    server.close
  end

  it "raises ConnectionError from connect failures and stays usable" do
    server = RedisSpec::FakeServer.new { }
    port = server.port
    server.close
    client = Redis::Client.new("redis://127.0.0.1:#{port}", connect_timeout: 1.second)
    expect_raises(Redis::ConnectionError) { client.ping }
    client.closed?.should be_false
    client.close
  end
end
