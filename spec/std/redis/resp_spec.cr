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

    it "accepts an Indexable of args" do
      io = IO::Memory.new
      Redis::RESP.write_command(io, ["PING"])
      io.to_s.should eq("*1\r\n$4\r\nPING\r\n")
    end

    it "accepts a Deque of args" do
      io = IO::Memory.new
      Redis::RESP.write_command(io, Deque{"PING"})
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

private def parse(bytes : String, **opts)
  Redis::RESP.read(IO::Memory.new(bytes), **opts)
end

describe Redis::RESP do
  describe ".read scalars" do
    it "simple string" { parse("+OK\r\n").should eq("OK") }
    it "empty simple string" { parse("+\r\n").should eq("") }
    it "integer" { parse(":1000\r\n").should eq(1000_i64) }
    it "negative integer" { parse(":-1\r\n").should eq(-1_i64) }
    it "integer with explicit plus" { parse(":+5\r\n").should eq(5_i64) }
    it "bulk string" { parse("$5\r\nhello\r\n").should eq("hello") }
    it "empty bulk string" { parse("$0\r\n\r\n").should eq("") }
    it "binary bulk string" { parse("$4\r\na\r\nb\r\n").should eq("a\r\nb") }
    it "null bulk (RESP2)" { parse("$-1\r\n").should be_nil }
    it "null array (RESP2)" { parse("*-1\r\n").should be_nil }
    it "null (RESP3)" { parse("_\r\n").should be_nil }
    it "booleans" do
      parse("#t\r\n").should eq(true)
      parse("#f\r\n").should eq(false)
    end
    it "doubles" do
      parse(",1.23\r\n").should eq(1.23)
      parse(",10\r\n").should eq(10.0)
      parse(",inf\r\n").should eq(Float64::INFINITY)
      parse(",-inf\r\n").should eq(-Float64::INFINITY)
      parse(",nan\r\n").as(Float64).nan?.should be_true
    end
    it "big number" do
      parse("(3492890328409238509324850943850943825024385\r\n").should eq(
        Redis::BigNumber.new("3492890328409238509324850943850943825024385"))
    end
    it "verbatim string strips the format prefix" do
      parse("=15\r\ntxt:Some string\r\n").should eq("Some string")
    end
    it "simple error becomes a CommandError value" do
      err = parse("-ERR unknown command 'FOO'\r\n").as(Redis::CommandError)
      err.code.should eq("ERR")
      err.message.should eq("ERR unknown command 'FOO'")
    end
    it "bulk error becomes a CommandError value" do
      err = parse("!21\r\nSYNTAX invalid syntax\r\n").as(Redis::CommandError)
      err.code.should eq("SYNTAX")
      err.message.should eq("SYNTAX invalid syntax")
    end
    it "leaves following frames unread" do
      io = IO::Memory.new("+A\r\n+B\r\n")
      Redis::RESP.read(io).should eq("A")
      Redis::RESP.read(io).should eq("B")
    end
  end

  describe ".read errors" do
    it "raises IO::EOFError at a frame boundary" do
      expect_raises(IO::EOFError) { parse("") }
    end
    it "raises ProtocolError on EOF inside a frame" do
      expect_raises(Redis::ProtocolError) { parse("+OK") }
      expect_raises(Redis::ProtocolError) { parse("$5\r\nhel") }
      expect_raises(Redis::ProtocolError) { parse(":12") }
    end
    it "raises ProtocolError on a bad terminator" do
      expect_raises(Redis::ProtocolError) { parse("$2\r\nab\n\n") }
      expect_raises(Redis::ProtocolError) { parse(":1\n\r") }
    end
    it "raises ProtocolError on an unknown type byte" do
      expect_raises(Redis::ProtocolError, /unknown RESP type/) { parse("?x\r\n") }
    end
    it "raises ProtocolError on non-numeric length or integer" do
      expect_raises(Redis::ProtocolError) { parse(":abc\r\n") }
      expect_raises(Redis::ProtocolError) { parse("$x\r\n") }
      expect_raises(Redis::ProtocolError) { parse("$-2\r\n") }
    end
    it "raises ProtocolError on an oversized bulk before allocating" do
      expect_raises(Redis::ProtocolError, /exceeds/) { parse("$100\r\nabc", max_bulk_size: 10) }
    end
    it "raises ProtocolError on a bad double or boolean" do
      expect_raises(Redis::ProtocolError) { parse(",abc\r\n") }
      expect_raises(Redis::ProtocolError) { parse("#x\r\n") }
    end
    it "raises ProtocolError on integer overflow" do
      expect_raises(Redis::ProtocolError) { parse(":99999999999999999999\r\n") }
    end
  end
end
