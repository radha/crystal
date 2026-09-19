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

private def expect_call(reply : Redis::Value, expected_args : Array, &block : Stub -> _)
  s = stub(reply)
  result = block.call(s)
  s.calls.should eq([expected_args])
  result
end

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

describe "server commands" do
  it "ping / echo / select / dbsize / time / flushdb / flushall" do
    expect_call("PONG", ["PING"], &.ping).should eq("PONG")
    expect_call("hi", ["PING", "hi"], &.ping("hi")).should eq("hi")
    expect_call("x", ["ECHO", "x"], &.echo("x")).should eq("x")
    expect_call("OK", ["SELECT", 2], &.select(2)).should be_nil
    expect_call(3_i64, ["DBSIZE"], &.dbsize).should eq(3_i64)
    expect_call(["1700000000", "123"] of Redis::Value, ["TIME"], &.time).should eq({1700000000_i64, 123_i64})
    expect_call("OK", ["FLUSHDB"], &.flushdb).should be_nil
    expect_call("OK", ["FLUSHDB", "ASYNC"], &.flushdb(async: true)).should be_nil
    expect_call("OK", ["FLUSHALL"], &.flushall).should be_nil
  end

  it "info parses key:value lines" do
    raw = "# Server\r\nredis_version:7.2.4\r\nuptime_in_seconds:10\r\n\r\n# Clients\r\nconnected_clients:1\r\n"
    expect_call(raw, ["INFO"], &.info).should eq({"redis_version" => "7.2.4", "uptime_in_seconds" => "10", "connected_clients" => "1"})
    expect_call("", ["INFO", "server"], &.info("server")).should eq({} of String => String)
  end
end

describe "key commands" do
  it "del / unlink / exists / type / rename / renamenx / keys / persist" do
    expect_call(2_i64, ["DEL", "a", "b"], &.del("a", "b")).should eq(2_i64)
    expect_call(1_i64, ["UNLINK", "a"], &.unlink("a")).should eq(1_i64)
    expect_call(1_i64, ["EXISTS", "a", "b"], &.exists("a", "b")).should eq(1_i64)
    expect_call("string", ["TYPE", "a"], &.type("a")).should eq("string")
    expect_call("OK", ["RENAME", "a", "b"], &.rename("a", "b")).should be_nil
    expect_call(1_i64, ["RENAMENX", "a", "b"], &.renamenx("a", "b")).should be_true
    expect_call(["a"] of Redis::Value, ["KEYS", "*"], &.keys("*")).should eq(["a"])
    expect_call(1_i64, ["PERSIST", "a"], &.persist("a")).should be_true
  end

  it "expire family with spans, ints and flags" do
    expect_call(1_i64, ["EXPIRE", "a", 60], &.expire("a", 60.seconds)).should be_true
    expect_call(1_i64, ["EXPIRE", "a", 5, "NX"], &.expire("a", 5, nx: true)).should be_true
    expect_call(1_i64, ["PEXPIRE", "a", 1500], &.pexpire("a", 1.5.seconds)).should be_true
    expect_call(1_i64, ["PEXPIRE", "a", 1500, "NX"], &.expire("a", 1.5.seconds, nx: true)).should be_true
    expect_call(0_i64, ["EXPIREAT", "a", 1700000000], &.expireat("a", 1700000000)).should be_false
    expect_call(1_i64, ["PEXPIREAT", "a", 1700000000000, "GT"], &.pexpireat("a", 1700000000000, gt: true)).should be_true
    expect_call(-2_i64, ["TTL", "a"], &.ttl("a")).should eq(-2_i64)
    expect_call(900_i64, ["PTTL", "a"], &.pttl("a")).should eq(900_i64)
  end

  it "scan returns cursor and keys" do
    reply = ["17", ["a", "b"] of Redis::Value] of Redis::Value
    expect_call(reply, ["SCAN", "0"], &.scan("0")).should eq({"17", ["a", "b"]})
    expect_call(reply, ["SCAN", "0", "MATCH", "a*", "COUNT", 10, "TYPE", "string"],
      &.scan("0", match: "a*", count: 10, type: "string")).should eq({"17", ["a", "b"]})
  end

  it "scan_each iterates until cursor 0" do
    s = Stub.new
    s.replies = [["5", ["a"] of Redis::Value] of Redis::Value, ["0", ["b"] of Redis::Value] of Redis::Value] of Redis::Value
    seen = [] of String
    s.scan_each(match: "*") { |k| seen << k }
    seen.should eq(["a", "b"])
    s.calls.should eq([["SCAN", "0", "MATCH", "*"], ["SCAN", "5", "MATCH", "*"]])
  end
end

describe "string commands" do
  it "get / set with options" do
    expect_call("v", ["GET", "k"], &.get("k")).should eq("v")
    expect_call(nil, ["GET", "k"], &.get("k")).should be_nil
    expect_call("OK", ["SET", "k", "v"], &.set("k", "v")).should eq("OK")
    expect_call("OK", ["SET", "k", "v", "EX", 60], &.set("k", "v", ex: 60.seconds)).should eq("OK")
    expect_call("OK", ["SET", "k", "v", "EX", 2], &.set("k", "v", ex: 2.seconds)).should eq("OK")
    expect_call("OK", ["SET", "k", "v", "PX", 1500], &.set("k", "v", ex: 1.5.seconds)).should eq("OK")
    expect_call("OK", ["SET", "k", "v", "PX", 1500, "NX"], &.set("k", "v", px: 1500, nx: true)).should eq("OK")
    expect_call(nil, ["SET", "k", "v", "XX", "KEEPTTL"], &.set("k", "v", xx: true, keepttl: true)).should be_nil
    expect_call("old", ["SET", "k", "v", "GET"], &.set("k", "v", get: true)).should eq("old")
    expect_call("OK", ["SET", "k", "v", "EXAT", 1700000000], &.set("k", "v", exat: 1700000000)).should eq("OK")
    expect_call("OK", ["SET", "k", "v", "PXAT", 1700000000000], &.set("k", "v", pxat: 1700000000000)).should eq("OK")
  end

  it "rejects contradictory set options" do
    expect_raises(ArgumentError) { stub("OK").set("k", "v", nx: true, xx: true) }
    expect_raises(ArgumentError) { stub("OK").set("k", "v", ex: 1, px: 1) }
  end

  it "setnx / setex / psetex / getset / getdel / mget / mset / msetnx" do
    expect_call(1_i64, ["SETNX", "k", "v"], &.setnx("k", "v")).should be_true
    expect_call("OK", ["SETEX", "k", 10, "v"], &.setex("k", 10.seconds, "v")).should be_nil
    expect_call("OK", ["PSETEX", "k", 1500, "v"], &.setex("k", 1.5.seconds, "v")).should be_nil
    expect_call("OK", ["PSETEX", "k", 10, "v"], &.psetex("k", 10, "v")).should be_nil
    expect_call("old", ["GETSET", "k", "v"], &.getset("k", "v")).should eq("old")
    expect_call("v", ["GETDEL", "k"], &.getdel("k")).should eq("v")
    expect_call(["a", nil] of Redis::Value, ["MGET", "x", "y"], &.mget("x", "y")).should eq(["a", nil])
    expect_call("OK", ["MSET", "a", "1", "b", "2"], &.mset({"a" => "1", "b" => "2"})).should be_nil
    expect_call(1_i64, ["MSETNX", "a", "1"], &.msetnx({"a" => "1"})).should be_true
  end

  it "counters and substrings" do
    expect_call(2_i64, ["INCR", "c"], &.incr("c")).should eq(2_i64)
    expect_call(5_i64, ["INCRBY", "c", 3], &.incrby("c", 3)).should eq(5_i64)
    expect_call("2.5", ["INCRBYFLOAT", "c", 0.5], &.incrbyfloat("c", 0.5)).should eq(2.5)
    expect_call(1_i64, ["DECR", "c"], &.decr("c")).should eq(1_i64)
    expect_call(-1_i64, ["DECRBY", "c", 2], &.decrby("c", 2)).should eq(-1_i64)
    expect_call(5_i64, ["APPEND", "k", "xx"], &.append("k", "xx")).should eq(5_i64)
    expect_call(5_i64, ["STRLEN", "k"], &.strlen("k")).should eq(5_i64)
    expect_call("ell", ["GETRANGE", "k", 1, 3], &.getrange("k", 1, 3)).should eq("ell")
    expect_call(5_i64, ["SETRANGE", "k", 1, "xy"], &.setrange("k", 1, "xy")).should eq(5_i64)
  end
end

describe "hash commands" do
  it "hget / hset / hsetnx / hmget / hgetall / hdel / hexists / hkeys / hvals / hlen" do
    expect_call("v", ["HGET", "h", "f"], &.hget("h", "f")).should eq("v")
    expect_call(1_i64, ["HSET", "h", "f", "v"], &.hset("h", "f", "v")).should eq(1_i64)
    expect_call(2_i64, ["HSET", "h", "a", "1", "b", "2"], &.hset("h", {"a" => "1", "b" => "2"})).should eq(2_i64)
    expect_call(1_i64, ["HSETNX", "h", "f", "v"], &.hsetnx("h", "f", "v")).should be_true
    expect_call(["1", nil] of Redis::Value, ["HMGET", "h", "a", "z"], &.hmget("h", "a", "z")).should eq(["1", nil])
    expect_call({"a" => "1"} of Redis::Value => Redis::Value, ["HGETALL", "h"], &.hgetall("h")).should eq({"a" => "1"})
    expect_call(["a", "1"] of Redis::Value, ["HGETALL", "h"], &.hgetall("h")).should eq({"a" => "1"})
    expect_call(1_i64, ["HDEL", "h", "a", "b"], &.hdel("h", "a", "b")).should eq(1_i64)
    expect_call(0_i64, ["HEXISTS", "h", "a"], &.hexists("h", "a")).should be_false
    expect_call(["a"] of Redis::Value, ["HKEYS", "h"], &.hkeys("h")).should eq(["a"])
    expect_call(["1"] of Redis::Value, ["HVALS", "h"], &.hvals("h")).should eq(["1"])
    expect_call(1_i64, ["HLEN", "h"], &.hlen("h")).should eq(1_i64)
    expect_call(3_i64, ["HINCRBY", "h", "n", 2], &.hincrby("h", "n", 2)).should eq(3_i64)
    expect_call("1.5", ["HINCRBYFLOAT", "h", "n", 0.5], &.hincrbyfloat("h", "n", 0.5)).should eq(1.5)
  end

  it "hscan returns cursor and a hash" do
    reply = ["0", ["a", "1"] of Redis::Value] of Redis::Value
    expect_call(reply, ["HSCAN", "h", "0", "MATCH", "a*", "COUNT", 5], &.hscan("h", "0", match: "a*", count: 5)).should eq({"0", {"a" => "1"}})
  end
end

describe "list commands" do
  it "push / pop / len / range" do
    expect_call(2_i64, ["LPUSH", "l", "a", "b"], &.lpush("l", "a", "b")).should eq(2_i64)
    expect_call(2_i64, ["RPUSH", "l", "a"], &.rpush("l", "a")).should eq(2_i64)
    expect_call(0_i64, ["LPUSHX", "l", "a"], &.lpushx("l", "a")).should eq(0_i64)
    expect_call(0_i64, ["RPUSHX", "l", "a"], &.rpushx("l", "a")).should eq(0_i64)
    expect_call("a", ["LPOP", "l"], &.lpop("l")).should eq("a")
    expect_call(nil, ["RPOP", "l"], &.rpop("l")).should be_nil
    expect_call(["a", "b"] of Redis::Value, ["LPOP", "l", 2], &.lpop("l", 2)).should eq(["a", "b"])
    expect_call(nil, ["RPOP", "l", 2], &.rpop("l", 2)).should eq([] of String)
    expect_call(3_i64, ["LLEN", "l"], &.llen("l")).should eq(3_i64)
    expect_call(["a"] of Redis::Value, ["LRANGE", "l", 0, -1], &.lrange("l", 0, -1)).should eq(["a"])
    expect_call("a", ["LINDEX", "l", 0], &.lindex("l", 0)).should eq("a")
    expect_call("OK", ["LSET", "l", 0, "z"], &.lset("l", 0, "z")).should be_nil
    expect_call(1_i64, ["LREM", "l", 0, "a"], &.lrem("l", 0, "a")).should eq(1_i64)
    expect_call("OK", ["LTRIM", "l", 0, 1], &.ltrim("l", 0, 1)).should be_nil
    expect_call(2_i64, ["LINSERT", "l", "BEFORE", "b", "a"], &.linsert("l", :before, "b", "a")).should eq(2_i64)
    expect_call("a", ["LMOVE", "l", "m", "LEFT", "RIGHT"], &.lmove("l", "m", :left, :right)).should eq("a")
  end

  it "rejects unknown position symbols" do
    expect_raises(ArgumentError, /:before or :after/) { stub(nil).linsert("l", :middle, "b", "a") }
    expect_raises(ArgumentError, /:left or :right/) { stub(nil).lmove("l", "m", :up, :left) }
    expect_raises(ArgumentError, /:left or :right/) { stub(nil).lmove("l", "m", :left, :down) }
  end
end

describe "set commands" do
  it "add / rem / members / card / pop / rand / move / is-member" do
    expect_call(2_i64, ["SADD", "s", "a", "b"], &.sadd("s", "a", "b")).should eq(2_i64)
    expect_call(1_i64, ["SREM", "s", "a"], &.srem("s", "a")).should eq(1_i64)
    expect_call(Set(Redis::Value){"a"}, ["SMEMBERS", "s"], &.smembers("s")).should eq(["a"])
    expect_call(["a"] of Redis::Value, ["SMEMBERS", "s"], &.smembers("s")).should eq(["a"])
    expect_call(1_i64, ["SISMEMBER", "s", "a"], &.sismember("s", "a")).should be_true
    expect_call([1_i64, 0_i64] of Redis::Value, ["SMISMEMBER", "s", "a", "b"], &.smismember("s", "a", "b")).should eq([true, false])
    expect_call(1_i64, ["SCARD", "s"], &.scard("s")).should eq(1_i64)
    expect_call("a", ["SPOP", "s"], &.spop("s")).should eq("a")
    expect_call(["a"] of Redis::Value, ["SPOP", "s", 1], &.spop("s", 1)).should eq(["a"])
    expect_call("a", ["SRANDMEMBER", "s"], &.srandmember("s")).should eq("a")
    expect_call(["a"] of Redis::Value, ["SRANDMEMBER", "s", 1], &.srandmember("s", 1)).should eq(["a"])
    expect_call(1_i64, ["SMOVE", "s", "t", "a"], &.smove("s", "t", "a")).should be_true
  end

  it "set algebra" do
    expect_call(["a"] of Redis::Value, ["SINTER", "s", "t"], &.sinter("s", "t")).should eq(["a"])
    expect_call(["a"] of Redis::Value, ["SUNION", "s", "t"], &.sunion("s", "t")).should eq(["a"])
    expect_call(["a"] of Redis::Value, ["SDIFF", "s", "t"], &.sdiff("s", "t")).should eq(["a"])
    expect_call(1_i64, ["SINTERSTORE", "d", "s", "t"], &.sinterstore("d", "s", "t")).should eq(1_i64)
    expect_call(1_i64, ["SUNIONSTORE", "d", "s", "t"], &.sunionstore("d", "s", "t")).should eq(1_i64)
    expect_call(1_i64, ["SDIFFSTORE", "d", "s", "t"], &.sdiffstore("d", "s", "t")).should eq(1_i64)
  end

  it "sscan" do
    reply = ["0", ["a"] of Redis::Value] of Redis::Value
    expect_call(reply, ["SSCAN", "s", "0", "COUNT", 3], &.sscan("s", "0", count: 3)).should eq({"0", ["a"]})
  end
end

describe "sorted set commands" do
  it "zadd forms and flags" do
    expect_call(1_i64, ["ZADD", "z", 1.5, "a"], &.zadd("z", 1.5, "a")).should eq(1_i64)
    expect_call(2_i64, ["ZADD", "z", "NX", "CH", 1.0, "a", 2.0, "b"],
      &.zadd("z", [{"a", 1.0}, {"b", 2.0}], nx: true, ch: true)).should eq(2_i64)
    expect_call(1_i64, ["ZADD", "z", "GT", 1.0, "a"], &.zadd("z", [{"a", 1.0}], gt: true)).should eq(1_i64)
    expect_call("3.5", ["ZADD", "z", "INCR", 2.0, "a"], &.zadd_incr("z", 2.0, "a")).should eq(3.5)
    expect_call(nil, ["ZADD", "z", "XX", "INCR", 2.0, "a"], &.zadd_incr("z", 2.0, "a", xx: true)).should be_nil
    expect_raises(ArgumentError) { stub(1_i64).zadd("z", [{"a", 1.0}], nx: true, xx: true) }
  end

  it "scores, ranks, counts" do
    expect_call(1_i64, ["ZREM", "z", "a", "b"], &.zrem("z", "a", "b")).should eq(1_i64)
    expect_call("1.5", ["ZSCORE", "z", "a"], &.zscore("z", "a")).should eq(1.5)
    expect_call(nil, ["ZSCORE", "z", "a"], &.zscore("z", "a")).should be_nil
    expect_call([1.5, nil] of Redis::Value, ["ZMSCORE", "z", "a", "b"], &.zmscore("z", "a", "b")).should eq([1.5, nil])
    expect_call(2_i64, ["ZCARD", "z"], &.zcard("z")).should eq(2_i64)
    expect_call(1_i64, ["ZCOUNT", "z", "-inf", "(2"], &.zcount("z", "-inf", "(2")).should eq(1_i64)
    expect_call("2.5", ["ZINCRBY", "z", 1.0, "a"], &.zincrby("z", 1.0, "a")).should eq(2.5)
    expect_call(0_i64, ["ZRANK", "z", "a"], &.zrank("z", "a")).should eq(0_i64)
    expect_call(nil, ["ZREVRANK", "z", "a"], &.zrevrank("z", "a")).should be_nil
  end

  it "zrange variants" do
    expect_call(["a"] of Redis::Value, ["ZRANGE", "z", 0, -1], &.zrange("z", 0, -1)).should eq(["a"])
    expect_call(["a"] of Redis::Value, ["ZRANGE", "z", "(1", "+inf", "BYSCORE", "LIMIT", 0, 10],
      &.zrange("z", "(1", "+inf", by_score: true, limit: {0, 10})).should eq(["a"])
    expect_call(["a"] of Redis::Value, ["ZRANGE", "z", "[a", "[z", "BYLEX", "REV"],
      &.zrange("z", "[a", "[z", by_lex: true, rev: true)).should eq(["a"])
    expect_call([["a", 1.0] of Redis::Value] of Redis::Value, ["ZRANGE", "z", 0, -1, "WITHSCORES"],
      &.zrange_with_scores("z", 0, -1)).should eq([{"a", 1.0}])
    expect_call(["a", "1"] of Redis::Value, ["ZRANGE", "z", 0, -1, "REV", "WITHSCORES"],
      &.zrange_with_scores("z", 0, -1, rev: true)).should eq([{"a", 1.0}])
    expect_raises(ArgumentError) { stub(nil).zrange("z", 0, 1, by_score: true, by_lex: true) }
  end

  it "rejects contradictory zadd and zrange options" do
    expect_raises(ArgumentError, /gt and lt/) { stub(1_i64).zadd("z", [{"a", 1.0}], gt: true, lt: true) }
    expect_raises(ArgumentError, /nx cannot/) { stub(1_i64).zadd("z", [{"a", 1.0}], nx: true, gt: true) }
    expect_raises(ArgumentError, /nx cannot/) { stub(1.0).zadd_incr("z", 1.0, "a", nx: true, lt: true) }
    expect_raises(ArgumentError, /with_scores/) { stub(nil).zrange_with_scores("z", "[a", "[z", by_lex: true) }
  end

  it "zpopmin / zpopmax" do
    expect_call(["a", "1"] of Redis::Value, ["ZPOPMIN", "z"], &.zpopmin("z")).should eq([{"a", 1.0}])
    expect_call([["a", 1.0] of Redis::Value] of Redis::Value, ["ZPOPMAX", "z", 2], &.zpopmax("z", 2)).should eq([{"a", 1.0}])
    expect_call([] of Redis::Value, ["ZPOPMIN", "z"], &.zpopmin("z")).should eq([] of {String, Float64})
  end

  it "zscan" do
    reply = ["0", ["a", "1.5"] of Redis::Value] of Redis::Value
    expect_call(reply, ["ZSCAN", "z", "0", "MATCH", "a*"], &.zscan("z", "0", match: "a*")).should eq({"0", [{"a", 1.5}]})
  end
end

describe "scripting commands" do
  it "eval / evalsha with keys and args" do
    expect_call(2_i64, ["EVAL", "return 2", 0], &.eval("return 2")).should eq(2_i64)
    expect_call("x", ["EVAL", "s", 2, "k1", "k2", "a", 1], &.eval("s", keys: ["k1", "k2"], args: ["a", 1] of Redis::RESP::Arg)).should eq("x")
    expect_call("x", ["EVALSHA", "abc", 1, "k"], &.evalsha("abc", keys: ["k"])).should eq("x")
  end

  it "script load / exists / flush" do
    expect_call("abc", ["SCRIPT", "LOAD", "return 1"], &.script_load("return 1")).should eq("abc")
    expect_call([1_i64, 0_i64] of Redis::Value, ["SCRIPT", "EXISTS", "a", "b"], &.script_exists("a", "b")).should eq([true, false])
    expect_call("OK", ["SCRIPT", "FLUSH"], &.script_flush).should be_nil
  end
end
