require "spec"
require "wait_group"
require "../../support/redis"

# Two masters: node 0 owns 0..8191, node 1 owns 8192..16383.
# Slots: "b" 3300 and "k" 7629 on node 0; "a" 15495 and "x" 16287 on node 1.
private TWO = [{0, 8191, 0}, {8192, 16383, 1}]

# Default node behaviour; *override* may answer first and return true.
private def fake_two(&override : RedisSpec::FakeCluster, Int32, Array(String), IO -> Bool)
  RedisSpec::FakeCluster.new(2, TWO) do |fake, index, cmd, io|
    next if override.call(fake, index, cmd, io)
    case cmd[0]
    when "GET"    then io << "$1\r\nv\r\n"
    when "SET"    then io << "+OK\r\n"
    when "INCR"   then io << ":1\r\n"
    when "PING"   then io << "+PONG\r\n"
    when "DBSIZE" then io << ":#{index}\r\n"
    when "ASKING" then io << "+OK\r\n"
    when "MULTI"  then io << "+OK\r\n"
    when "EXEC"   then io << "*0\r\n"
    when "SCAN"   then io << "*2\r\n$1\r\n0\r\n*1\r\n$2\r\nk#{index}\r\n"
    when "DIE"    then io.close
    else               io << "+OK\r\n"
    end
  end
end

private def dead_port : Int32
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  server.close
  port
end

describe Redis::Cluster do
  it "loads the topology from the first reachable seed and routes by slot" do
    fake = fake_two { false }
    cluster = Redis::Cluster.new(["redis://127.0.0.1:#{dead_port}", fake.url(0)], connect_timeout: 1.second)
    cluster.closed?.should be_false
    fake.slots_calls.should eq(0)
    cluster.get("b").should eq("v")
    fake.slots_calls.should eq(1)
    cluster.get("a").should eq("v")
    cluster.set("x", "1").should eq("OK")
    fake.commands(0).should eq([["CLUSTER", "SLOTS"], ["GET", "b"]])
    fake.commands(1).should eq([["GET", "a"], ["SET", "x", "1"]])
    nodes = cluster.nodes
    nodes.size.should eq(2)
    nodes.map(&.address).should eq(["127.0.0.1:#{fake.port(0)}", "127.0.0.1:#{fake.port(1)}"])
    nodes.all?(&.master?).should be_true
    nodes[0].id.should eq("node0")
    cluster.node_for("b").should be(nodes[0])
    cluster.node_for("a").should be(nodes[1])
    cluster.close
    fake.close
  end

  it "routes an explicit key and raw commands" do
    fake = fake_two { false }
    cluster = Redis::Cluster.new(fake.url(1))
    cluster.command("FROB", "x", key: "b").should eq("OK")
    cluster.call(["FROB", "y"], key: "b").should eq("OK")
    cluster.call("FROB", "a").should eq("OK")
    fake.commands(0).should eq([["FROB", "x"], ["FROB", "y"]])
    fake.commands(1).should eq([["CLUSTER", "SLOTS"], ["FROB", "a"]])
    cluster.close
    fake.close
  end

  it "follows MOVED, patches the slot and reloads the topology once" do
    redirect = true
    fake = fake_two do |f, index, cmd, io|
      if index == 0 && cmd[0] == "GET" && redirect
        redirect = false
        io << f.moved(Redis::Cluster.key_slot(cmd[1]), 1)
        true
      else
        false
      end
    end
    cluster = Redis::Cluster.new(fake.url(0))
    cluster.get("b").should eq("v")
    fake.commands(1).should eq([["GET", "b"]])
    fake.slots_calls.should eq(1)
    # The next command reloads; the fake now says node 1 owns everything.
    fake.ranges = [{0, 16383, 1}]
    cluster.get("b").should eq("v")
    fake.slots_calls.should eq(2)
    fake.commands(1).should eq([["GET", "b"], ["GET", "b"]])
    cluster.node_for("b").address.should eq("127.0.0.1:#{fake.port(1)}")
    cluster.nodes.size.should eq(1)
    cluster.close
    fake.close
  end

  it "follows ASK with ASKING and leaves the slot map alone" do
    redirect = true
    fake = fake_two do |f, index, cmd, io|
      if index == 0 && cmd[0] == "GET" && redirect
        redirect = false
        io << f.ask(Redis::Cluster.key_slot(cmd[1]), 1)
        true
      else
        false
      end
    end
    cluster = Redis::Cluster.new(fake.url(0))
    cluster.get("b").should eq("v")
    fake.commands(1).should eq([["ASKING"], ["GET", "b"]])
    cluster.get("b").should eq("v")
    fake.slots_calls.should eq(1)
    fake.commands(0).should eq([["CLUSTER", "SLOTS"], ["GET", "b"], ["GET", "b"]])
    cluster.close
    fake.close
  end

  it "retries TRYAGAIN" do
    attempts = 0
    fake = fake_two do |f, index, cmd, io|
      if cmd[0] == "GET" && (attempts += 1) <= 2
        io << "-TRYAGAIN Multiple keys request during rehashing of slot\r\n"
        true
      else
        false
      end
    end
    cluster = Redis::Cluster.new(fake.url(0))
    cluster.get("b").should eq("v")
    fake.commands(0).count(["GET", "b"]).should eq(3)
    cluster.close
    fake.close
  end

  it "gives up after max_redirects and passes other errors through" do
    fake = fake_two do |f, index, cmd, io|
      case cmd[0]
      when "GET"
        io << f.moved(Redis::Cluster.key_slot(cmd[1]), 1 - index)
        true
      when "INCR"
        io << "-WRONGTYPE Operation against a key holding the wrong kind of value\r\n"
        true
      else
        false
      end
    end
    cluster = Redis::Cluster.new(fake.url(0), max_redirects: 3)
    error = expect_raises(Redis::ClusterError, /too many redirects/) { cluster.get("b") }
    error.cause.should be_a(Redis::CommandError)
    (fake.commands(0).count(["GET", "b"]) + fake.commands(1).count(["GET", "b"])).should eq(4)
    expect_raises(Redis::CommandError, /WRONGTYPE/) { cluster.incr("b") }
    cluster.close
    fake.close
  end

  it "marks the topology stale after a lost connection and raises" do
    fake = fake_two { false }
    cluster = Redis::Cluster.new(fake.url(0))
    cluster.get("b").should eq("v")
    expect_raises(Redis::ConnectionError) { cluster.call("DIE", "b") }
    fake.slots_calls.should eq(1)
    cluster.get("b").should eq("v")
    fake.slots_calls.should eq(2)
    # The seed probe, the node client, and its reconnect.
    fake.accepted(0).should eq(3)
    cluster.close
    fake.close
  end

  it "coalesces concurrent reloads" do
    fake = fake_two do |f, index, cmd, io|
      if index == 0 && cmd[0] == "GET"
        io << f.moved(Redis::Cluster.key_slot(cmd[1]), 1)
        true
      else
        false
      end
    end
    cluster = Redis::Cluster.new(fake.url(0))
    cluster.get("a").should eq("v")
    fake.slots_calls.should eq(1)
    fake.ranges = [{0, 16383, 1}]
    results = Array(String?).new(20, nil)
    wg = WaitGroup.new(20)
    20.times do |i|
      spawn do
        begin
          results[i] = cluster.get("b")
        ensure
          wg.done
        end
      end
    end
    wg.wait
    results.should eq(Array(String?).new(20, "v"))
    # Every MOVED marked the map stale; the next round reloads exactly once.
    wg = WaitGroup.new(20)
    20.times do
      spawn do
        begin
          cluster.get("b").should eq("v")
        ensure
          wg.done
        end
      end
    end
    wg.wait
    fake.slots_calls.should eq(2)
    cluster.close
    fake.close
  end

  it "sends keyless commands to a master and exposes per-node clients" do
    fake = fake_two { false }
    cluster = Redis::Cluster.new(fake.url(1))
    cluster.ping.should eq("PONG")
    (fake.commands(0).includes?(["PING"]) || fake.commands(1).includes?(["PING"])).should be_true
    cluster.nodes.map { |n| n.client.dbsize }.sort.should eq([0_i64, 1_i64])
    keys = [] of String
    cluster.scan_each { |key| keys << key }
    keys.sort.should eq(["k0", "k1"])
    cluster.close
    fake.close
  end

  it "keeps node identity across a reload and closes nodes that vanish" do
    fake = fake_two { false }
    cluster = Redis::Cluster.new(fake.url(0))
    cluster.get("b")
    before = cluster.node_for("b")
    client = before.client
    cluster.refresh
    fake.slots_calls.should eq(2)
    cluster.node_for("b").should be(before)
    before.client.should be(client)
    client.closed?.should be_false
    fake.ranges = [{0, 16383, 1}]
    cluster.refresh
    client.closed?.should be_true
    cluster.nodes.size.should eq(1)
    cluster.close
    fake.close
  end

  it "records replicas but never routes to them" do
    fake = fake_two { false }
    fake.ranges = [{0, 16383, 0}]
    fake.replicas[1] = 0
    cluster = Redis::Cluster.new(fake.url(0))
    cluster.get("a").should eq("v")
    fake.commands(1).should be_empty
    nodes = cluster.nodes
    nodes.size.should eq(2)
    nodes[0].master?.should be_true
    nodes[1].master?.should be_false
    nodes[1].address.should eq("127.0.0.1:#{fake.port(1)}")
    expect_raises(ArgumentError, /replica/) { nodes[1].client }
    cluster.close
    fake.close
  end

  it "raises ClusterError when no seed answers or none is a cluster" do
    cluster = Redis::Cluster.new("redis://127.0.0.1:#{dead_port}", connect_timeout: 1.second)
    error = expect_raises(Redis::ClusterError, /no cluster node reachable/) { cluster.get("b") }
    error.cause.should be_a(Redis::ConnectionError)
    cluster.close

    standalone = RedisSpec::FakeServer.new do |io|
      while cmd = RedisSpec::FakeServer.read_command(io)
        io << (cmd[0] == "HELLO" ? RedisSpec::HELLO_REPLY : "-ERR This instance has cluster support disabled\r\n")
        io.flush
      end
    end
    cluster = Redis::Cluster.new(standalone.url)
    error = expect_raises(Redis::ClusterError, /cluster support disabled/) { cluster.get("b") }
    error.cause.should be_a(Redis::CommandError)
    cluster.close
    standalone.close
  end

  it "rejects bad seeds and options" do
    expect_raises(ArgumentError, /database/) { Redis::Cluster.new("redis://localhost:7000/1") }
    expect_raises(ArgumentError, /scheme/) { Redis::Cluster.new("unix:///tmp/redis.sock") }
    expect_raises(ArgumentError, /seed/) { Redis::Cluster.new([] of String) }
    expect_raises(ArgumentError, /protocol/) { Redis::Cluster.new("redis://localhost:7000", protocol: 1) }
    expect_raises(ArgumentError, /max_redirects/) { Redis::Cluster.new("redis://localhost:7000", max_redirects: -1) }
    expect_raises(ArgumentError, /pool_size/) { Redis::Cluster.new("redis://localhost:7000", pool_size: 0) }
  end

  it "closes every node client" do
    fake = fake_two { false }
    cluster = Redis::Cluster.new(fake.url(0))
    cluster.get("b")
    cluster.get("a")
    clients = cluster.nodes.map(&.client)
    clients.size.should eq(2)
    cluster.close
    cluster.closed?.should be_true
    clients.all?(&.closed?).should be_true
    expect_raises(Redis::ConnectionError, /closed/) { cluster.get("b") }
    expect_raises(Redis::ConnectionError, /closed/) { cluster.refresh }
    fake.close
  end
end
