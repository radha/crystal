require "spec"
require "redis"

describe Redis::CRC16 do
  it "matches the XMODEM check value" do
    Redis::CRC16.checksum("123456789").should eq(0x31C3_u16)
    Redis::CRC16.checksum("123456789".to_slice).should eq(0x31C3_u16)
    Redis::CRC16.checksum("").should eq(0_u16)
    Redis::CRC16.checksum(Bytes.empty).should eq(0_u16)
  end
end

describe "Redis::Cluster.key_slot" do
  it "hashes the whole key when there is no tag" do
    Redis::Cluster.key_slot("user1000").should eq(3443)
    Redis::Cluster.key_slot("b").should eq(3300)
    Redis::Cluster.key_slot("a").should eq(15495)
    Redis::Cluster.key_slot("").should eq(0)
  end

  it "hashes only the hash tag" do
    Redis::Cluster.key_slot("{user1000}.following").should eq(3443)
    Redis::Cluster.key_slot("{user1000}.followers").should eq(3443)
    Redis::Cluster.key_slot("foo{bar}{zap}").should eq(Redis::Cluster.key_slot("bar"))
    Redis::Cluster.key_slot("foo{bar}{zap}").should eq(5061)
    Redis::Cluster.key_slot("foo{{bar}}zap").should eq(Redis::Cluster.key_slot("{bar"))
    Redis::Cluster.key_slot("foo{{bar}}zap").should eq(4015)
  end

  it "ignores an empty or unclosed tag" do
    Redis::Cluster.key_slot("foo{}{bar}").should eq(8363)
    Redis::Cluster.key_slot("foo{bar").should eq(Redis::CRC16.checksum("foo{bar").to_i32 & 0x3FFF)
    Redis::Cluster.key_slot("foo}bar{").should eq(Redis::CRC16.checksum("foo}bar{").to_i32 & 0x3FFF)
  end

  it "stays inside the slot range" do
    1000.times { |i| Redis::Cluster.key_slot("key#{i}").should be < Redis::Cluster::SLOTS }
  end
end

describe "Redis::Cluster.route_key" do
  it "takes position 1 for ordinary commands" do
    Redis::Cluster.route_key({"GET", "k"}).should eq("k")
    Redis::Cluster.route_key(["MSET", "a", "1", "b", "2"]).should eq("a")
    Redis::Cluster.route_key({"SMOVE", "src", "dst", "m"}).should eq("src")
    Redis::Cluster.route_key({"get", "k"}).should eq("k")
    Redis::Cluster.route_key({"FROBNICATE", "k", 1}).should eq("k")
    Redis::Cluster.route_key({"SPUBLISH", "shard-channel", "m"}).should eq("shard-channel")
  end

  it "answers nil for keyless and malformed commands" do
    Redis::Cluster.route_key({"PING"}).should be_nil
    Redis::Cluster.route_key({"ping", "x"}).should be_nil
    Redis::Cluster.route_key({"PUBLISH", "channel", "m"}).should be_nil
    Redis::Cluster.route_key({"INFO", "server"}).should be_nil
    Redis::Cluster.route_key({"CLUSTER", "SLOTS"}).should be_nil
    Redis::Cluster.route_key({"MEMORY", "DOCTOR"}).should be_nil
    Redis::Cluster.route_key({"GET"}).should be_nil
    Redis::Cluster.route_key({1, 2}).should be_nil
    Redis::Cluster.route_key([] of String).should be_nil
    Redis::Cluster.route_key({"FROBNICATE", 7}).should be_nil
  end

  it "finds the first key after a key count" do
    Redis::Cluster.route_key({"EVAL", "return 1", 2, "a", "b"}).should eq("a")
    Redis::Cluster.route_key({"EVALSHA", "abc", "1", "x"}).should eq("x")
    Redis::Cluster.route_key({"EVAL", "return 1", 0}).should be_nil
    Redis::Cluster.route_key({"EVAL", "return 1", "zero"}).should be_nil
    Redis::Cluster.route_key({"FCALL", "fn", 1, "k"}).should eq("k")
    Redis::Cluster.route_key({"ZUNION", 2, "a", "b"}).should eq("a")
    Redis::Cluster.route_key({"LMPOP", 1, "q", "LEFT"}).should eq("q")
    Redis::Cluster.route_key({"BLMPOP", 0, 2, "a", "b", "LEFT"}).should eq("a")
    Redis::Cluster.route_key({"SINTERCARD", 2, "a", "b"}).should eq("a")
  end

  it "finds keys after STREAMS and at position 2" do
    Redis::Cluster.route_key({"XREAD", "COUNT", 2, "STREAMS", "s1", "s2", "0", "0"}).should eq("s1")
    Redis::Cluster.route_key({"XREADGROUP", "GROUP", "g", "c", "streams", "s", ">"}).should eq("s")
    Redis::Cluster.route_key({"XREAD", "COUNT", 2}).should be_nil
    Redis::Cluster.route_key({"OBJECT", "ENCODING", "k"}).should eq("k")
    Redis::Cluster.route_key({"XINFO", "STREAM", "k"}).should eq("k")
    Redis::Cluster.route_key({"XGROUP", "CREATE", "k", "g", "$"}).should eq("k")
    Redis::Cluster.route_key({"BITOP", "AND", "dest", "a", "b"}).should eq("dest")
    Redis::Cluster.route_key({"MEMORY", "USAGE", "k"}).should eq("k")
    Redis::Cluster.route_key({"MEMORY", "usage", "k"}).should eq("k")
  end
end
