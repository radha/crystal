# spec/std/redis/resp_spec.cr
require "spec"
require "redis"

private def encode(*args)
  io = IO::Memory.new
  Redis::RESP.write_command(io, *args)
  io.to_s
end

describe Redis::RESP do
  describe ".write_command" do
    it "encodes strings as a bulk array" do
      encode("SET", "key", "value").should eq("*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nvalue\r\n")
    end

    it "uses bytesize for multibyte strings" do
      encode("ECHO", "héllo").should eq("*2\r\n$4\r\nECHO\r\n$6\r\nhéllo\r\n")
    end

    it "encodes ints, floats, symbols and bytes" do
      encode("SET", :k, 42, -7_i64, 1.5, Bytes[0, 255]).should eq(
        "*6\r\n$3\r\nSET\r\n$1\r\nk\r\n$2\r\n42\r\n$2\r\n-7\r\n$3\r\n1.5\r\n$2\r\n\u0000\xFF\r\n")
    end

    it "accepts an Enumerable of args" do
      io = IO::Memory.new
      Redis::RESP.write_command(io, ["PING"])
      io.to_s.should eq("*1\r\n$4\r\nPING\r\n")
    end

    it "encodes an empty string" do
      encode("SET", "k", "").should eq("*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$0\r\n\r\n")
    end

    it "encodes Int64::MIN" do
      encode("X", Int64::MIN).should eq("*2\r\n$1\r\nX\r\n$20\r\n-9223372036854775808\r\n")
    end

    it "encodes Int128::MIN" do
      encode("X", Int128::MIN).should eq("*2\r\n$1\r\nX\r\n$40\r\n-170141183460469231731687303715884105728\r\n")
    end

    it "encodes UInt128::MAX" do
      encode("X", UInt128::MAX).should eq("*2\r\n$1\r\nX\r\n$39\r\n340282366920938463463374607431768211455\r\n")
    end
  end
end
