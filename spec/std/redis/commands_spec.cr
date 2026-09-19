# spec/std/redis/commands_spec.cr
require "spec"
require "redis"

# Records the args of each call and answers from a queue of canned replies.
private class Stub
  include Redis::Commands

  getter calls = [] of Array(Redis::RESP::Arg)
  property replies = [] of Redis::Value

  def call(args : Indexable) : Redis::Value
    @calls << args.map(&.as(Redis::RESP::Arg)).to_a
    @replies.shift
  end

  def typed_call(args : Indexable, &block : Redis::Value -> T) forall T
    block.call(call(args))
  end

  def_command echo_test, "ECHO", message : String, cast: :string
  def_command del_test, "DEL", keys : String, cast: :int, splat: true
  def_command noargs_test, "PING", cast: :string
end

private def stub(*replies : Redis::Value)
  s = Stub.new
  s.replies = replies.map(&.as(Redis::Value)).to_a
  s
end

private alias Cast = Redis::Commands::Cast

describe Redis::Commands do
  describe "def_command" do
    it "builds the arg array and casts the reply" do
      s = stub("hi")
      s.echo_test("hi").should eq("hi")
      s.calls.should eq([["ECHO", "hi"]])
    end

    it "supports a trailing splat" do
      s = stub(2_i64)
      s.del_test("a", "b").should eq(2_i64)
      s.calls.should eq([["DEL", "a", "b"]])
    end

    it "supports no params" do
      stub("PONG").noargs_test.should eq("PONG")
    end

    it "raises ProtocolError on a wrong reply shape" do
      expect_raises(Redis::ProtocolError, /expected string/) { stub(1_i64).echo_test("x") }
    end
  end

  describe "command" do
    it "passes args straight to call" do
      s = stub(42_i64)
      s.command("CLIENT", "ID").should eq(42_i64)
      s.calls.should eq([["CLIENT", "ID"]])
    end
  end

  describe Redis::Commands::Cast do
    it "string / string?" do
      Cast.string("a").should eq("a")
      Cast.string?(nil).should be_nil
      expect_raises(Redis::ProtocolError) { Cast.string(nil) }
    end
    it "int" do
      Cast.int(3_i64).should eq(3_i64)
      expect_raises(Redis::ProtocolError) { Cast.int("3") }
    end
    it "float accepts double, integer and numeric string" do
      Cast.float(1.5).should eq(1.5)
      Cast.float(2_i64).should eq(2.0)
      Cast.float("3.25").should eq(3.25)
      expect_raises(Redis::ProtocolError) { Cast.float("x") }
    end
    it "bool accepts boolean and 0/1" do
      Cast.bool(true).should be_true
      Cast.bool(0_i64).should be_false
      Cast.bool(1_i64).should be_true
      expect_raises(Redis::ProtocolError) { Cast.bool(2_i64) }
    end
    it "strings accepts array or set of strings" do
      Cast.strings(["a", "b"] of Redis::Value).should eq(["a", "b"])
      Cast.strings(Set(Redis::Value){"a"}).should eq(["a"])
      expect_raises(Redis::ProtocolError) { Cast.strings(["a", 1_i64] of Redis::Value) }
    end
    it "strings? keeps nils" do
      Cast.strings?(["a", nil] of Redis::Value).should eq(["a", nil])
    end
    it "string_hash accepts a map or a flat array" do
      Cast.string_hash({"a" => "1"} of Redis::Value => Redis::Value).should eq({"a" => "1"})
      Cast.string_hash(["a", "1", "b", "2"] of Redis::Value).should eq({"a" => "1", "b" => "2"})
      expect_raises(Redis::ProtocolError) { Cast.string_hash(["a"] of Redis::Value) }
    end
    it "scored_pairs accepts pairs (RESP3) or a flat array (RESP2)" do
      Cast.scored_pairs([["a", 1.5] of Redis::Value, ["b", 2.0] of Redis::Value] of Redis::Value).should eq([{"a", 1.5}, {"b", 2.0}])
      Cast.scored_pairs(["a", "1.5", "b", "2"] of Redis::Value).should eq([{"a", 1.5}, {"b", 2.0}])
    end
    it "floats? and bools" do
      Cast.floats?([1.0, nil, "2.5"] of Redis::Value).should eq([1.0, nil, 2.5])
      Cast.bools([1_i64, 0_i64] of Redis::Value).should eq([true, false])
    end
    it "ok" do
      Cast.ok("OK").should be_nil
      expect_raises(Redis::ProtocolError) { Cast.ok("QUEUED") }
    end
  end
end
