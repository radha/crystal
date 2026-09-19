# spec/std/redis/fake_server_spec.cr
require "spec"
require "../../support/redis"

describe RedisSpec::FakeServer do
  it "reads commands and answers" do
    server = RedisSpec::FakeServer.new do |io|
      while cmd = RedisSpec::FakeServer.read_command(io)
        next if RedisSpec::FakeServer.serve_hello(io, cmd)
        io << "+" << cmd.join(' ') << "\r\n"
        io.flush
      end
    end
    begin
      sock = TCPSocket.new("127.0.0.1", server.port)
      Redis::RESP.write_command(sock, "HELLO", "3")
      sock.flush
      Redis::RESP.read(sock).as(Hash)["proto"]?.should eq(3_i64)
      Redis::RESP.write_command(sock, "PING", "x")
      sock.flush
      Redis::RESP.read(sock).should eq("PING x")
      sock.close
      server.accepted.should eq(1)
    ensure
      server.close
    end
  end

  it "reports availability of a live server as a Bool" do
    RedisSpec::AVAILABLE.should be_a(Bool)
  end
end
