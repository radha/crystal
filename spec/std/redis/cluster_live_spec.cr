require "spec"
require "../../support/redis"

private def values(*items) : Array(Redis::Value)
  Array(Redis::Value).new(items.size) { |i| items[i].as(Redis::Value) }
end

# Opens a cluster client, flushes every master, yields, closes.
private def with_cluster(live : RedisSpec::LiveCluster, protocol : Int32, &block : Redis::Cluster ->)
  cluster = Redis::Cluster.new(live.urls, protocol: protocol)
  begin
    cluster.refresh
    cluster.nodes.select(&.master?).each { |node| node.client.flushall }
    block.call(cluster)
  ensure
    cluster.close
  end
end

private def other_master(cluster : Redis::Cluster, than : Redis::Cluster::Node) : Redis::Cluster::Node
  cluster.nodes.find { |node| node.master? && !node.same?(than) }.not_nil!
end

private def live_cluster_specs(protocol : Int32)
  describe "Redis::Cluster live (RESP#{protocol})" do
    pending_cluster "discovers three masters and negotiates the protocol" do |live|
      with_cluster(live, protocol) do |c|
        masters = c.nodes.select(&.master?)
        masters.size.should eq(3)
        masters.all? { |node| node.id.size == 40 }.should be_true
        c.ping.should eq("PONG")
        masters.first.client.ping
        masters.first.client.protocol.should eq(protocol)
      end
    end

    pending_cluster "computes the same slots as CLUSTER KEYSLOT" do |live|
      with_cluster(live, protocol) do |c|
        rng = Random.new(42)
        node = c.nodes.first.client
        200.times do |i|
          key = i.even? ? rng.hex(4) : "{#{rng.hex(2)}}:#{i}"
          node.call("CLUSTER", "KEYSLOT", key).should eq(Redis::Cluster.key_slot(key).to_i64)
        end
      end
    end

    pending_cluster "spreads keys over every master and pipelines across them" do |live|
      with_cluster(live, protocol) do |c|
        keys = Array.new(50) { |i| "key#{i}" }
        keys.each { |key| c.set(key, key.upcase).should eq("OK") }
        c.nodes.select(&.master?).all? { |node| node.client.dbsize > 0 }.should be_true
        keys.each { |key| c.get(key).should eq(key.upcase) }
        replies = c.pipelined { |p| keys.each { |key| p.get(key) } }
        replies.should eq(keys.map(&.upcase))
        seen = [] of String
        c.scan_each(match: "key*") { |key| seen << key }
        seen.sort.should eq(keys.sort)
      end
    end

    pending_cluster "runs multi on one slot and raises CROSSSLOT across slots" do |live|
      with_cluster(live, protocol) do |c|
        c.multi { |tx| tx.incr("{m}a"); tx.incr("{m}b") }.should eq(values(1_i64, 1_i64))
        error = expect_raises(Redis::CommandError, /CROSSSLOT/) { c.mget("a", "b") }
        error.code.should eq("CROSSSLOT")
      end
    end

    pending_cluster "follows MOVED after a slot moves behind its back" do |live|
      with_cluster(live, protocol) do |c|
        key = "moved-key"
        slot = Redis::Cluster.key_slot(key)
        owner = c.node_for(key)
        target = other_master(c, owner)
        target.client.call("CLUSTER", "SETSLOT", slot, "NODE", target.id)
        owner.client.call("CLUSTER", "SETSLOT", slot, "NODE", target.id)
        expect_raises(Redis::CommandError, /MOVED/) { owner.client.set(key, "x") }
        c.set(key, "1").should eq("OK")
        c.node_for(key).should be(target)
        target.client.get(key).should eq("1")
      end
    end

    pending_cluster "follows ASK while a slot is migrating" do |live|
      with_cluster(live, protocol) do |c|
        key = "{ask}x"
        slot = Redis::Cluster.key_slot(key)
        source = c.node_for(key)
        target = other_master(c, source)
        c.set(key, "here")
        target.client.call("CLUSTER", "SETSLOT", slot, "IMPORTING", source.id)
        source.client.call("CLUSTER", "SETSLOT", slot, "MIGRATING", target.id)
        begin
          c.get(key).should eq("here")
          c.get("{ask}missing").should be_nil
          c.node_for(key).should be(source)
        ensure
          source.client.call("CLUSTER", "SETSLOT", slot, "STABLE")
          target.client.call("CLUSTER", "SETSLOT", slot, "STABLE")
        end
      end
    end

    pending_cluster "delivers a publish from any node to a subscriber" do |live|
      with_cluster(live, protocol) do |c|
        sub = c.subscriber
        begin
          sub.subscribe("news")
          masters = c.nodes.select(&.master?)
          masters.each { |node| node.client.publish("news", node.address) }
          received = Array.new(3) { sub.receive.payload }
          received.sort.should eq(masters.map(&.address).sort)
        ensure
          sub.close
        end
      end
    end

    pending_cluster "runs a blocking command on a dedicated connection" do |live|
      with_cluster(live, protocol) do |c|
        pushed = Channel(Nil).new
        spawn do
          sleep 50.milliseconds
          begin
            c.rpush("q", "job")
          ensure
            pushed.send(nil)
          end
        end
        c.with_connection("q") { |conn| conn.call("BLPOP", "q", 2) }.should eq(values("q", "job"))
        # `BLPOP` can answer before the push's own reply has been read;
        # wait for it so the client is not closed with it still in flight.
        pushed.receive
      end
    end

    pending_cluster "runs scripts and watches on the owning master" do |live|
      with_cluster(live, protocol) do |c|
        script = Redis::Script.new("return redis.call('INCR', KEYS[1])")
        c.run(script, keys: ["s1"]).should eq(1_i64)
        c.run(script, keys: ["s2"]).should eq(1_i64)
        c.run(script, keys: ["s2"]).should eq(2_i64)
        c.watch("{w}a") { |conn| conn.multi { |tx| tx.set("{w}a", "1") } }.should eq(values("OK"))
        c.get("{w}a").should eq("1")
      end
    end
  end
end

live_cluster_specs(3)
live_cluster_specs(2)
