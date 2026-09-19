# spec/std/redis/live_spec.cr
require "spec"
require "../../support/redis"

# Opens a client on the spec database, flushes it, yields, closes.
private def with_redis(protocol : Int32, &block : Redis::Client ->)
  client = Redis::Client.new(RedisSpec::URL, db: RedisSpec::DB, protocol: protocol)
  begin
    client.flushdb
    block.call(client)
  ensure
    client.close
  end
end

private def live_command_specs(protocol : Int32)
  describe "Redis live commands (RESP#{protocol})" do
    pending_redis "negotiates the requested protocol" do
      with_redis(protocol) do |r|
        r.ping.should eq("PONG")
        r.protocol.should eq(protocol)
      end
    end

    pending_redis "strings" do
      with_redis(protocol) do |r|
        r.set("k", "v").should eq("OK")
        r.get("k").should eq("v")
        r.get("missing").should be_nil
        r.set("k", "w", nx: true).should be_nil
        r.set("k", "w", get: true).should eq("v")
        r.set("t", "1", ex: 100.seconds).should eq("OK")
        r.ttl("t").should be > 90
        r.setex("t2", 10, "x")
        r.pttl("t2").should be > 5000
        r.mset({"a" => "1", "b" => "2"})
        r.mget("a", "b", "zz").should eq(["1", "2", nil])
        r.incr("n").should eq(1_i64)
        r.incrby("n", 4).should eq(5_i64)
        r.incrbyfloat("n", 0.5).should eq(5.5)
        r.decr("n2").should eq(-1_i64)
        r.append("k", "!!").should eq(3_i64)
        r.strlen("k").should eq(3_i64)
        r.getrange("k", 0, 0).should eq("w")
        r.setrange("k", 1, "XY").should eq(3_i64)
        r.getset("k", "new").should eq("wXY")
        r.getdel("k").should eq("new")
        r.exists("k").should eq(0_i64)
        r.set("bin", Bytes[0, 1, 255])
        r.get("bin").not_nil!.to_slice.should eq(Bytes[0, 1, 255])
      end
    end

    pending_redis "keys" do
      with_redis(protocol) do |r|
        r.set("a", "1")
        r.set("b", "2")
        r.type("a").should eq("string")
        r.type("nope").should eq("none")
        r.rename("a", "c")
        r.renamenx("c", "b").should be_false
        r.keys("*").sort.should eq(["b", "c"])
        r.expire("b", 100).should be_true
        r.persist("b").should be_true
        r.ttl("b").should eq(-1_i64)
        r.pexpire("b", 100.seconds, nx: true).should be_true
        r.expireat("c", Time.utc.to_unix + 100).should be_true
        r.pexpireat("c", (Time.utc.to_unix + 200) * 1000, gt: true).should be_true
        seen = [] of String
        r.scan_each(match: "*", count: 1) { |k| seen << k }
        seen.sort.should eq(["b", "c"])
        cursor, keys = r.scan("0", count: 100)
        cursor.should eq("0")
        keys.sort.should eq(["b", "c"])
        r.del("b", "c").should eq(2_i64)
        r.unlink("b").should eq(0_i64)
        r.dbsize.should eq(0_i64)
        r.info("server").has_key?("redis_version").should be_true
        r.time[0].should be > 1_600_000_000_i64
        r.echo("x").should eq("x")
      end
    end

    pending_redis "hashes" do
      with_redis(protocol) do |r|
        r.hset("h", "f", "1").should eq(1_i64)
        r.hset("h", {"g" => "2", "i" => "3"}).should eq(2_i64)
        r.hget("h", "f").should eq("1")
        r.hget("h", "zz").should be_nil
        r.hmget("h", "f", "zz").should eq(["1", nil])
        r.hgetall("h").should eq({"f" => "1", "g" => "2", "i" => "3"})
        r.hsetnx("h", "f", "9").should be_false
        r.hexists("h", "f").should be_true
        r.hkeys("h").sort.should eq(["f", "g", "i"])
        r.hvals("h").sort.should eq(["1", "2", "3"])
        r.hlen("h").should eq(3_i64)
        r.hincrby("h", "f", 2).should eq(3_i64)
        r.hincrbyfloat("h", "f", 0.5).should eq(3.5)
        r.hdel("h", "g", "i").should eq(2_i64)
        cursor, fields = r.hscan("h", "0")
        cursor.should eq("0")
        fields.should eq({"f" => "3.5"})
      end
    end

    pending_redis "lists" do
      with_redis(protocol) do |r|
        r.rpush("l", "a", "b", "c").should eq(3_i64)
        r.lpush("l", "z").should eq(4_i64)
        r.lpushx("nope", "x").should eq(0_i64)
        r.rpushx("l", "d").should eq(5_i64)
        r.llen("l").should eq(5_i64)
        r.lrange("l", 0, -1).should eq(["z", "a", "b", "c", "d"])
        r.lindex("l", 1).should eq("a")
        r.lset("l", 1, "A")
        r.linsert("l", :before, "b", "ab").should eq(6_i64)
        r.lrem("l", 0, "ab").should eq(1_i64)
        r.lpop("l").should eq("z")
        r.rpop("l", 2).should eq(["d", "c"])
        r.lmove("l", "m", :left, :right).should eq("A")
        r.lrange("m", 0, -1).should eq(["A"])
        r.ltrim("l", 0, 0)
        r.lrange("l", 0, -1).should eq(["b"])
        r.lpop("nope", 2).should eq([] of String)
        r.rpop("nope").should be_nil
      end
    end

    pending_redis "sets" do
      with_redis(protocol) do |r|
        r.sadd("s", "a", "b", "c").should eq(3_i64)
        r.sadd("t", "b", "c", "d")
        r.smembers("s").sort.should eq(["a", "b", "c"])
        r.sismember("s", "a").should be_true
        r.smismember("s", "a", "zz").should eq([true, false])
        r.scard("s").should eq(3_i64)
        r.sinter("s", "t").sort.should eq(["b", "c"])
        r.sunion("s", "t").sort.should eq(["a", "b", "c", "d"])
        r.sdiff("s", "t").should eq(["a"])
        r.sinterstore("u", "s", "t").should eq(2_i64)
        r.sunionstore("u", "s", "t").should eq(4_i64)
        r.sdiffstore("u", "s", "t").should eq(1_i64)
        r.smove("s", "t", "a").should be_true
        r.srem("t", "a").should eq(1_i64)
        r.srandmember("s").should_not be_nil
        r.srandmember("s", 2).size.should eq(2)
        r.spop("s").should_not be_nil
        r.spop("s", 5).size.should eq(1)
        cursor, members = r.sscan("t", "0")
        cursor.should eq("0")
        members.sort.should eq(["b", "c", "d"])
      end
    end

    pending_redis "sorted sets" do
      with_redis(protocol) do |r|
        r.zadd("z", 1.0, "a").should eq(1_i64)
        r.zadd("z", [{"b", 2.0}, {"c", 3.0}]).should eq(2_i64)
        r.zadd("z", [{"a", 5.0}], nx: true).should eq(0_i64)
        r.zadd("z", [{"a", 1.5}], xx: true, ch: true).should eq(1_i64)
        r.zadd_incr("z", 0.5, "a").should eq(2.0)
        r.zscore("z", "a").should eq(2.0)
        r.zscore("z", "zz").should be_nil
        r.zmscore("z", "a", "zz").should eq([2.0, nil])
        r.zcard("z").should eq(3_i64)
        r.zcount("z", "-inf", "(3").should eq(2_i64)
        r.zincrby("z", 1.0, "c").should eq(4.0)
        r.zrange("z", 0, -1).should eq(["a", "b", "c"])
        r.zrange("z", 0, -1, rev: true).should eq(["c", "b", "a"])
        r.zrange("z", "(2", "+inf", by_score: true, limit: {0, 1}).should eq(["c"])
        r.zrange_with_scores("z", 0, 1).should eq([{"a", 2.0}, {"b", 2.0}])
        r.zrank("z", "c").should eq(2_i64)
        r.zrevrank("z", "c").should eq(0_i64)
        r.zrank("z", "zz").should be_nil
        cursor, pairs = r.zscan("z", "0")
        cursor.should eq("0")
        pairs.sort_by(&.[0]).should eq([{"a", 2.0}, {"b", 2.0}, {"c", 4.0}])
        r.zpopmin("z").should eq([{"a", 2.0}])
        r.zpopmax("z", 2).should eq([{"c", 4.0}, {"b", 2.0}])
        r.zrem("z", "a").should eq(0_i64)
        r.zpopmin("z").should eq([] of {String, Float64})
      end
    end

    pending_redis "scripting" do
      with_redis(protocol) do |r|
        r.eval("return {KEYS[1], ARGV[1], 7}", keys: ["k"], args: ["v"] of Redis::RESP::Arg).should eq(["k", "v", 7_i64] of Redis::Value)
        sha = r.script_load("return 1")
        r.evalsha(sha).should eq(1_i64)
        r.script_exists(sha, "0" * 40).should eq([true, false])
        r.script_flush
        r.script_exists(sha).should eq([false])
        ex = expect_raises(Redis::CommandError) { r.evalsha(sha) }
        ex.code.should eq("NOSCRIPT")
      end
    end

    pending_redis "error replies and the escape hatch" do
      with_redis(protocol) do |r|
        r.rpush("l", "x")
        ex = expect_raises(Redis::CommandError) { r.get("l") }
        ex.code.should eq("WRONGTYPE")
        r.command("CLIENT", "ID").should be_a(Int64)
        r.command(["ECHO", "hi"]).should eq("hi")
      end
    end
  end
end

live_command_specs(3)
live_command_specs(2)

describe "Redis live concurrency" do
  pending_redis "64 fibers × 100 incr on one multiplexed client" do
    with_redis(3) do |r|
      done = Channel(Nil).new
      64.times do
        spawn do
          100.times { r.incr("hits") }
          done.send(nil)
        end
      end
      64.times { done.receive }
      r.get("hits").should eq("6400")
    end
  end

  pending_redis "10k-command pipeline round-trips" do
    with_redis(3) do |r|
      futures = [] of Redis::Future(Int64)
      results = r.pipelined do |p|
        10_000.times { futures << p.incr("n") }
      end
      results.size.should eq(10_000)
      futures.last.value.should eq(10_000_i64)
      r.get("n").should eq("10000")
    end
  end

  pending_redis "dedicated Connection runs a blocking command" do
    with_redis(3) do |r|
      conn = Redis::Connection.new(RedisSpec::URL, db: RedisSpec::DB)
      spawn { sleep 0.05.seconds; r.rpush("q", "job") }
      conn.call("BLPOP", "q", 2).should eq(["q", "job"] of Redis::Value)
      conn.close
    end
  end

  pending_redis "unix socket connection when the server exposes one" do
    path = ENV["REDIS_UNIX_SOCKET"]?
    pending! "set REDIS_UNIX_SOCKET to run" unless path
    conn = Redis::Connection.new("redis+unix://#{path}?db=#{RedisSpec::DB}")
    conn.ping.should eq("PONG")
    conn.close
  end
end
