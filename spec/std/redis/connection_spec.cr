# spec/std/redis/connection_spec.cr
require "spec"
require "../../support/redis"

# A fake server that speaks RESP3 for HELLO and echoes PING as +PONG.
private def echo_server(hello : Symbol = :resp3, &extra : IO, Array(String) -> Bool)
  RedisSpec::FakeServer.new do |io|
    while cmd = RedisSpec::FakeServer.read_command(io)
      case cmd[0]
      when "HELLO"
        case hello
        when :resp3   then io << RedisSpec::HELLO_REPLY
        when :unknown then io << "-ERR unknown command 'HELLO'\r\n"
        when :noproto then io << "-NOPROTO unsupported protocol version\r\n"
        end
      when "PING"
        io << (cmd[1]? ? "$#{cmd[1].bytesize}\r\n#{cmd[1]}\r\n" : "+PONG\r\n")
      else
        io << "+OK\r\n" unless extra.call(io, cmd)
      end
      io.flush
    end
  end
end

private def echo_server(hello : Symbol = :resp3)
  echo_server(hello) { |_, _| false }
end

describe Redis::Connection do
  it "negotiates RESP3 and answers commands" do
    server = echo_server
    conn = Redis::Connection.new(server.url)
    conn.protocol.should eq(3)
    conn.ping.should eq("PONG")
    conn.call("PING", "hi").should eq("hi")
    conn.close
    conn.closed?.should be_true
    server.close
  end

  it "falls back to RESP2 on ERR unknown command or NOPROTO" do
    {:unknown, :noproto}.each do |mode|
      server = echo_server(mode)
      conn = Redis::Connection.new(server.url)
      conn.protocol.should eq(2)
      conn.ping.should eq("PONG")
      conn.close
      server.close
    end
  end

  it "sends AUTH and SETNAME inside HELLO, and SELECT after" do
    seen = [] of Array(String)
    server = RedisSpec::FakeServer.new do |io|
      while cmd = RedisSpec::FakeServer.read_command(io)
        seen << cmd
        io << (cmd[0] == "HELLO" ? RedisSpec::HELLO_REPLY : "+OK\r\n")
        io.flush
      end
    end
    conn = Redis::Connection.new(server.url, username: "u", password: "p", client_name: "app", db: 3)
    conn.close
    seen.should eq([["HELLO", "3", "AUTH", "u", "p", "SETNAME", "app"], ["SELECT", "3"]])
    server.close
  end

  it "uses AUTH and CLIENT SETNAME on RESP2" do
    seen = [] of Array(String)
    server = RedisSpec::FakeServer.new do |io|
      while cmd = RedisSpec::FakeServer.read_command(io)
        seen << cmd
        io << (cmd[0] == "HELLO" ? "-ERR unknown command 'HELLO'\r\n" : "+OK\r\n")
        io.flush
      end
    end
    Redis::Connection.new(server.url, password: "p", client_name: "app").close
    seen.should eq([["HELLO", "3", "AUTH", "default", "p", "SETNAME", "app"], ["AUTH", "p"], ["CLIENT", "SETNAME", "app"]])
    seen.clear
    Redis::Connection.new(server.url, username: "u", password: "p", client_name: "app").close
    seen.should eq([["HELLO", "3", "AUTH", "u", "p", "SETNAME", "app"], ["AUTH", "u", "p"], ["CLIENT", "SETNAME", "app"]])
    seen.clear
    Redis::Connection.new(server.url, protocol: 2, password: "p").close
    seen.should eq([["AUTH", "p"]])
    server.close
  end

  it "parses url parts: userinfo, db path, unix scheme" do
    seen = [] of Array(String)
    server = RedisSpec::FakeServer.new do |io|
      while cmd = RedisSpec::FakeServer.read_command(io)
        seen << cmd
        io << (cmd[0] == "HELLO" ? RedisSpec::HELLO_REPLY : "+OK\r\n")
        io.flush
      end
    end
    Redis::Connection.new("redis://me:secret@127.0.0.1:#{server.port}/2").close
    seen.should eq([["HELLO", "3", "AUTH", "me", "secret"], ["SELECT", "2"]])
    server.close
    expect_raises(ArgumentError, /scheme/) { Redis::Connection.new("http://localhost") }
    expect_raises(ArgumentError, /protocol/) { Redis::Connection.new("redis://localhost", protocol: 4) }
  end

  it "raises the server's auth error" do
    server = RedisSpec::FakeServer.new do |io|
      while RedisSpec::FakeServer.read_command(io)
        io << "-WRONGPASS invalid username-password pair\r\n"
        io.flush
      end
    end
    ex = expect_raises(Redis::CommandError) { Redis::Connection.new(server.url, password: "x") }
    ex.code.should eq("WRONGPASS")
    server.close
  end

  it "raises ConnectionError when nothing listens" do
    server = RedisSpec::FakeServer.new { }
    port = server.port
    server.close
    expect_raises(Redis::ConnectionError) { Redis::Connection.new("redis://127.0.0.1:#{port}", connect_timeout: 1.second) }
  end

  it "wraps a failed TLS handshake in ConnectionError" do
    server = RedisSpec::FakeServer.new do |io|
      io << "nope\r\n"
      io.flush
    end
    context = OpenSSL::SSL::Context::Client.new
    context.verify_mode = OpenSSL::SSL::VerifyMode::NONE
    expect_raises(Redis::ConnectionError) do
      Redis::Connection.new("rediss://127.0.0.1:#{server.port}", tls_context: context)
    end
    server.close
  end

  it "closes and raises ProtocolError on a truncated frame" do
    server = RedisSpec::FakeServer.new do |io|
      cmd = RedisSpec::FakeServer.read_command(io)
      RedisSpec::FakeServer.serve_hello(io, cmd.not_nil!)
      RedisSpec::FakeServer.read_command(io)
      io << "+PON"
      io.flush
      io.close
    end
    conn = Redis::Connection.new(server.url)
    expect_raises(Redis::ProtocolError) { conn.ping }
    conn.closed?.should be_true
    server.close
  end

  it "does not resend AUTH/SETNAME when HELLO succeeds and reports proto 2" do
    seen = [] of Array(String)
    server = RedisSpec::FakeServer.new do |io|
      while cmd = RedisSpec::FakeServer.read_command(io)
        seen << cmd
        io << (cmd[0] == "HELLO" ? "%1\r\n$5\r\nproto\r\n:2\r\n" : "+OK\r\n")
        io.flush
      end
    end
    conn = Redis::Connection.new(server.url, password: "p", client_name: "app")
    conn.protocol.should eq(2)
    seen.should eq([["HELLO", "3", "AUTH", "default", "p", "SETNAME", "app"]])
    conn.close
    server.close
  end

  it "reads proto from a flat-array HELLO reply" do
    server = RedisSpec::FakeServer.new do |io|
      while cmd = RedisSpec::FakeServer.read_command(io)
        io << (cmd[0] == "HELLO" ? "*2\r\n$5\r\nproto\r\n:2\r\n" : "+OK\r\n")
        io.flush
      end
    end
    conn = Redis::Connection.new(server.url)
    conn.protocol.should eq(2)
    conn.close
    server.close
  end

  it "raises CommandError on error replies and keeps the connection usable" do
    server = echo_server { |io, cmd| cmd[0] == "BAD" && (io << "-WRONGTYPE nope\r\n"; true) }
    conn = Redis::Connection.new(server.url)
    expect_raises(Redis::CommandError, /WRONGTYPE/) { conn.call("BAD") }
    conn.ping.should eq("PONG")
    conn.close
    server.close
  end

  it "pipeline sends all then reads all, keeping errors as values" do
    server = echo_server { |io, cmd| cmd[0] == "BAD" && (io << "-ERR x\r\n"; true) }
    conn = Redis::Connection.new(server.url)
    results = conn.pipeline([["PING"], ["BAD"], ["PING", "z"]])
    results[0].should eq("PONG")
    results[1].as(Redis::CommandError).code.should eq("ERR")
    results[2].should eq("z")
    conn.close
    server.close
  end

  it "turns a dropped connection into ConnectionError and closes" do
    server = RedisSpec::FakeServer.new do |io|
      cmd = RedisSpec::FakeServer.read_command(io)
      RedisSpec::FakeServer.serve_hello(io, cmd.not_nil!)
      RedisSpec::FakeServer.read_command(io)
      io.close
    end
    conn = Redis::Connection.new(server.url)
    expect_raises(Redis::ConnectionError) { conn.ping }
    conn.closed?.should be_true
    expect_raises(Redis::ConnectionError) { conn.ping }
    server.close
  end

  it "applies read_timeout to read and closes on timeout" do
    server = RedisSpec::FakeServer.new do |io|
      cmd = RedisSpec::FakeServer.read_command(io)
      RedisSpec::FakeServer.serve_hello(io, cmd.not_nil!)
      RedisSpec::FakeServer.read_command(io)
      sleep 2.seconds
    end
    conn = Redis::Connection.new(server.url, read_timeout: 50.milliseconds)
    expect_raises(IO::TimeoutError) { conn.ping }
    conn.closed?.should be_true
    server.close
  end

  it "routes push frames to push_handler" do
    server = echo_server { |io, cmd| cmd[0] == "PUSHY" && (io << ">2\r\n+message\r\n+hello\r\n+OK\r\n"; true) }
    conn = Redis::Connection.new(server.url)
    pushes = [] of Array(Redis::Value)
    conn.push_handler = ->(p : Array(Redis::Value)) { pushes << p }
    conn.call("PUSHY").should eq("OK")
    pushes.should eq([["message", "hello"] of Redis::Value])
    conn.close
    server.close
  end

  it "connects over a unix socket" do
    path = File.tempname("redis-spec", ".sock")
    unix = UNIXServer.new(path)
    spawn do
      if client = unix.accept?
        while cmd = RedisSpec::FakeServer.read_command(client)
          client << (cmd[0] == "HELLO" ? RedisSpec::HELLO_REPLY : "+PONG\r\n")
          client.flush
        end
      end
    end
    conn = Redis::Connection.new("redis+unix://#{path}")
    conn.ping.should eq("PONG")
    conn.close
    unix.close
    File.delete?(path)
  end
end
