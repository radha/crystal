# spec/std/redis/script_spec.cr
require "spec"
require "../../support/redis"

# A fake server with a script cache: EVALSHA answers NOSCRIPT until the
# script was loaded by EVAL or SCRIPT LOAD; SCRIPT FLUSH empties it. A
# script whose source is exactly "error" fails at run time.
private class ScriptServer
  getter seen = [] of Array(String)
  @loaded = {} of String => String

  def server
    RedisSpec::FakeServer.new do |io|
      while cmd = RedisSpec::FakeServer.read_command(io)
        @seen << cmd
        case cmd[0]
        when "HELLO"
          io << RedisSpec::HELLO_REPLY
        when "EVALSHA"
          if source = @loaded[cmd[1]]?
            io << run_reply(source)
          else
            io << "-NOSCRIPT No matching script. Please use EVAL.\r\n"
          end
        when "EVAL"
          @loaded[Digest::SHA1.hexdigest(cmd[1])] = cmd[1]
          io << run_reply(cmd[1])
        when "SCRIPT"
          case cmd[1]
          when "LOAD"
            sha = Digest::SHA1.hexdigest(cmd[2])
            @loaded[sha] = cmd[2]
            io << "$#{sha.bytesize}\r\n#{sha}\r\n"
          when "FLUSH"
            @loaded.clear
            io << "+OK\r\n"
          else
            io << "+OK\r\n"
          end
        else
          io << "+OK\r\n"
        end
        io.flush
      end
    end
  end

  # Commands seen after the handshake, first element only.
  def names : Array(String)
    @seen.reject { |c| c[0] == "HELLO" }.map(&.first)
  end

  private def run_reply(source : String) : String
    source == "error" ? "-ERR Error running script\r\n" : ":1\r\n"
  end
end

describe Redis::Script do
  it "computes the SHA1 of the source locally" do
    Redis::Script.new("").sha.should eq("da39a3ee5e6b4b0d3255bfef95601890afd80709")
    s = Redis::Script.new("return 1")
    s.source.should eq("return 1")
    s.sha.should eq(Digest::SHA1.hexdigest("return 1"))
    s.sha.size.should eq(40)
  end

  it "run sends EVALSHA, falls back to EVAL on NOSCRIPT, then EVALSHA again" do
    fake = ScriptServer.new
    server = fake.server
    conn = Redis::Connection.new(server.url)
    script = Redis::Script.new("return 1")
    conn.run(script, keys: ["k"], args: [5]).should eq(1_i64)
    fake.seen[1].should eq(["EVALSHA", script.sha, "1", "k", "5"])
    fake.seen[2].should eq(["EVAL", "return 1", "1", "k", "5"])
    conn.run(script, keys: ["k"], args: [5]).should eq(1_i64)
    fake.names.should eq(["EVALSHA", "EVAL", "EVALSHA"])
    conn.script_cache.known?(script.sha).should be_true
    conn.close
    server.close
  end

  it "raises a non-NOSCRIPT error without falling back" do
    fake = ScriptServer.new
    server = fake.server
    conn = Redis::Connection.new(server.url)
    script = Redis::Script.new("error")
    script.load(conn).should eq(script.sha)
    fake.seen[1].should eq(["SCRIPT", "LOAD", "error"])
    conn.script_cache.known?(script.sha).should be_true
    ex = expect_raises(Redis::CommandError) { conn.run(script) }
    ex.code.should eq("ERR")
    fake.names.should eq(["SCRIPT", "EVALSHA"])
    conn.close
    server.close
  end

  it "works on the multiplexed client" do
    fake = ScriptServer.new
    server = fake.server
    client = Redis::Client.new(server.url)
    script = Redis::Script.new("return 1")
    client.run(script).should eq(1_i64)
    client.run(script).should eq(1_i64)
    fake.names.should eq(["EVALSHA", "EVAL", "EVALSHA"])
    client.close
    server.close
  end

  it "pipelines send EVAL for an unknown SHA and EVALSHA for a known one" do
    fake = ScriptServer.new
    server = fake.server
    client = Redis::Client.new(server.url)
    script = Redis::Script.new("return 1")
    f = nil
    client.pipelined { |p| f = p.run(script, keys: ["k"]) }
    f.not_nil!.value.should eq(1_i64)
    fake.names.should eq(["EVAL"])
    client.script_cache.known?(script.sha).should be_true
    client.pipelined { |p| f = p.run(script, keys: ["k"]) }
    f.not_nil!.value.should eq(1_i64)
    fake.names.should eq(["EVAL", "EVALSHA"])
    client.close
    server.close
  end

  it "a pipelined NOSCRIPT surfaces on the future and clears the hint" do
    fake = ScriptServer.new
    server = fake.server
    client = Redis::Client.new(server.url)
    script = Redis::Script.new("return 1")
    client.run(script).should eq(1_i64)
    client.script_flush
    f = nil
    client.pipelined { |p| f = p.run(script) }
    ex = expect_raises(Redis::CommandError) { f.not_nil!.value }
    ex.code.should eq("NOSCRIPT")
    client.script_cache.known?(script.sha).should be_false
    client.pipelined { |p| f = p.run(script) }
    f.not_nil!.value.should eq(1_i64)
    fake.names.should eq(["EVALSHA", "EVAL", "SCRIPT", "EVALSHA", "EVAL"])
    client.close
    server.close
  end
end

describe Redis::AbortedError do
  it "is a Redis::Error with a default message" do
    err = Redis::AbortedError.new
    err.should be_a(Redis::Error)
    err.message.should eq("transaction aborted: a watched key changed")
    Redis::AbortedError.new("custom").message.should eq("custom")
  end
end
