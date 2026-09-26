require "spec"
require "lru_cache"

# A slow but obviously correct model: an Array of entries, most recently
# used first.
private class ModelLRU
  getter entries = [] of {Int32, Int32}

  def initialize(@capacity : Int32)
  end

  def get(key)
    if i = @entries.index { |(k, _)| k == key }
      entry = @entries.delete_at(i)
      @entries.unshift(entry)
      entry[1]
    end
  end

  def set(key, value)
    if i = @entries.index { |(k, _)| k == key }
      @entries.delete_at(i)
    end
    @entries.unshift({key, value})
    while @entries.size > @capacity
      @entries.pop
    end
  end

  def delete(key)
    if i = @entries.index { |(k, _)| k == key }
      @entries.delete_at(i)[1]
    end
  end
end

describe LRUCache do
  describe "by count" do
    it "evicts the least recently used entry" do
      cache = LRUCache(String, Int32).new(2)
      cache["a"] = 1
      cache["b"] = 2
      cache["a"]?.should eq(1)
      cache["c"] = 3
      cache["b"]?.should be_nil
      cache.keys.should eq(["c", "a"])
      cache.size.should eq(2)
      cache.check_invariants
    end

    it "overwriting refreshes recency without growing" do
      cache = LRUCache(String, Int32).new(2)
      cache["a"] = 1
      cache["b"] = 2
      cache["a"] = 10
      cache["c"] = 3
      cache.to_a.should eq([{"c", 3}, {"a", 10}])
    end

    it "a zero-capacity cache stores nothing" do
      cache = LRUCache(Int32, Int32).new(0)
      cache[1] = 1
      cache.empty?.should be_true
      cache.evictions.should eq(1)
    end

    it "rejects a negative capacity" do
      expect_raises(ArgumentError) { LRUCache(Int32, Int32).new(-1) }
    end

    it "matches a model under random operations" do
      rng = Random.new(9)
      {1, 2, 7, 64}.each do |capacity|
        cache = LRUCache(Int32, Int32).new(capacity)
        model = ModelLRU.new(capacity)
        5000.times do |step|
          key = rng.rand(capacity * 3 + 1)
          case rng.rand(10)
          when 0..3
            cache[key] = step
            model.set(key, step)
          when 4..7
            cache[key]?.should eq(model.get(key))
          when 8
            cache.delete(key).should eq(model.delete(key))
          else
            cache.peek(key).should eq(model.entries.find { |(k, _)| k == key }.try &.[1])
          end
          cache.to_a.should eq(model.entries) if step % 50 == 0
        end
        cache.check_invariants
        cache.to_a.should eq(model.entries)
      end
    end
  end

  describe "reads" do
    it "#[] raises on a miss" do
      cache = LRUCache(String, Int32).new(2)
      expect_raises(KeyError, %(Missing LRU cache key: "x")) { cache["x"] }
    end

    it "#fetch computes once and stores" do
      cache = LRUCache(Int32, Int32).new(10)
      calls = 0
      cache.fetch(3) { |key| calls += 1; key * 2 }.should eq(6)
      cache.fetch(3) { |key| calls += 1; key * 2 }.should eq(6)
      calls.should eq(1)
    end

    it "#peek and #has_key? do not refresh recency" do
      cache = LRUCache(Int32, Int32).new(2)
      cache[1] = 1
      cache[2] = 2
      cache.peek(1).should eq(1)
      cache.has_key?(1).should be_true
      cache[3] = 3
      cache.has_key?(1).should be_false
    end

    it "keeps hit and miss counts" do
      cache = LRUCache(Int32, Int32).new(2)
      cache[1] = 1
      cache[1]?
      cache[2]?
      cache.fetch(3) { 3 }
      cache.peek(1)
      cache.hits.should eq(1)
      cache.misses.should eq(2)
      cache.hit_rate.should eq(1 / 3)
      cache.reset_stats
      cache.hits.should eq(0)
      cache.hit_rate.should eq(0.0)
    end

    it "distinguishes a stored nil from a miss in fetch" do
      cache = LRUCache(Int32, String?).new(2)
      cache[1] = nil
      cache.fetch(1) { "computed" }.should be_nil
    end
  end

  describe "by weight" do
    it "evicts until the total weight fits" do
      cache = LRUCache(String, String).new(max_weight: 10) { |_, value| value.bytesize }
      cache["a"] = "12345"
      cache["b"] = "1234"
      cache.weight.should eq(9)
      cache["c"] = "123"
      cache.keys.should eq(["c", "b"])
      cache.weight.should eq(7)
      cache["b"] = "1"
      cache.weight.should eq(4)
      cache.check_invariants
    end

    it "drops an entry heavier than the limit at once" do
      cache = LRUCache(String, String).new(max_weight: 3) { |_, value| value.bytesize }
      cache["a"] = "1"
      cache["big"] = "12345"
      cache.has_key?("big").should be_false
      cache.has_key?("a").should be_false
      cache.weight.should eq(0)
    end

    it "accepts any integer weight and rejects negative ones" do
      cache = LRUCache(Int32, Int32).new(max_weight: 100_i64) { |_, value| value.to_u8 }
      cache[1] = 60
      cache[2] = 50
      cache.keys.should eq([2])
      bad = LRUCache(Int32, Int32).new(max_weight: 100) { |_, value| value }
      expect_raises(ArgumentError, "Negative weight") { bad[1] = -1 }
    end
  end

  describe "time to live" do
    it "expires entries after they were written" do
      cache = LRUCache(Int32, Int32).new(10, ttl: 30.milliseconds)
      cache[1] = 1
      cache[2] = 2
      cache[1]?.should eq(1)
      sleep 60.milliseconds
      cache[3] = 3
      cache[1]?.should be_nil
      cache.peek(2).should be_nil
      cache[3]?.should eq(3)
      cache.evictions.should eq(2)
      cache.check_invariants
    end

    it "rewriting renews the deadline, reading does not" do
      cache = LRUCache(Int32, Int32).new(10, ttl: 50.milliseconds)
      cache[1] = 1
      cache[2] = 2
      sleep 30.milliseconds
      cache[1] = 11
      cache[2]?
      sleep 30.milliseconds
      cache[1]?.should eq(11)
      cache[2]?.should be_nil
    end

    it "#purge_expired and #each skip expired entries" do
      cache = LRUCache(Int32, Int32).new(10, ttl: 20.milliseconds)
      3.times { |i| cache[i] = i }
      sleep 40.milliseconds
      cache[9] = 9
      cache.to_a.should eq([{9, 9}])
      cache.size.should eq(4)
      cache.purge_expired.should eq(3)
      cache.size.should eq(1)
      cache.check_invariants
    end

    it "can be turned on later" do
      cache = LRUCache(Int32, Int32).new(10)
      cache[1] = 1
      cache.ttl = 20.milliseconds
      sleep 40.milliseconds
      cache[1]?.should be_nil
      expect_raises(ArgumentError) { cache.ttl = 0.seconds }
    end
  end

  describe "#on_evict" do
    it "reports every way an entry leaves" do
      events = [] of {Int32, Int32, LRUCache::EvictionReason}
      cache = LRUCache(Int32, Int32).new(2, ttl: 1.hour)
      cache.on_evict { |key, value, reason| events << {key, value, reason} }
      cache[1] = 1
      cache[2] = 2
      cache[1] = 10
      cache[3] = 3
      cache.delete(1)
      cache.clear
      events.should eq([
        {1, 1, LRUCache::EvictionReason::Replaced},
        {2, 2, LRUCache::EvictionReason::Capacity},
        {1, 10, LRUCache::EvictionReason::Deleted},
        {3, 3, LRUCache::EvictionReason::Deleted},
      ])
      cache.empty?.should be_true
    end

    it "reports expiry" do
      reasons = [] of LRUCache::EvictionReason
      cache = LRUCache(Int32, Int32).new(2, ttl: 10.milliseconds)
      cache.on_evict { |_, _, reason| reasons << reason }
      cache[1] = 1
      sleep 20.milliseconds
      cache[1]?
      reasons.should eq([LRUCache::EvictionReason::Expired])
    end
  end

  describe "resizing" do
    it "shrinks at once and grows back" do
      cache = LRUCache(Int32, Int32).new(10)
      10.times { |i| cache[i] = i }
      cache.capacity = 3
      cache.keys.should eq([9, 8, 7])
      cache.capacity = 5
      cache[20] = 20
      cache[21] = 21
      cache.size.should eq(5)
      cache.check_invariants
    end

    it "changes the maximum weight" do
      cache = LRUCache(Int32, Int32).new(max_weight: 100) { |_, value| value }
      cache[1] = 40
      cache[2] = 40
      cache.max_weight = 50
      cache.keys.should eq([2])
      expect_raises(ArgumentError, "no weigher") { LRUCache(Int32, Int32).new(1).max_weight = 5 }
    end
  end

  it "reuses freed slots for reference types without leaking values" do
    cache = LRUCache(String, String).new(100)
    10_000.times { |i| cache[i.to_s] = "v#{i}" }
    cache.size.should eq(100)
    cache["9999"]?.should eq("v9999")
    cache.check_invariants
  end

  it "#to_s" do
    cache = LRUCache(Int32, String).new(3)
    cache[1] = "a"
    cache[2] = "b"
    cache.to_s.should eq(%(LRUCache{2 => "b", 1 => "a"}))
  end
end

describe SyncLRUCache do
  it "delegates the cache operations" do
    cache = SyncLRUCache(Int32, Int32).new(2)
    cache[1] = 1
    cache[2] = 2
    cache[1]?.should eq(1)
    cache[3] = 3
    cache.has_key?(2).should be_false
    cache.size.should eq(2)
    cache.to_a.should eq([{3, 3}, {1, 1}])
    cache.delete(1).should eq(1)
    cache.capacity = 1
    cache.hits.should eq(1)
  end

  it "computes a missing key once for concurrent fetches" do
    cache = SyncLRUCache(Int32, Int32).new(10)
    calls = Atomic(Int32).new(0)
    results = Channel(Int32).new(8)
    8.times do
      spawn do
        value = cache.fetch(42) do |key|
          calls.add(1)
          sleep 20.milliseconds
          key + 1
        end
        results.send(value)
      end
    end
    8.times { results.receive.should eq(43) }
    calls.get.should eq(1)
    cache[42]?.should eq(43)
  end

  it "shares a failed computation's exception and stores nothing" do
    cache = SyncLRUCache(Int32, Int32).new(10)
    errors = Channel(String).new(4)
    4.times do
      spawn do
        begin
          cache.fetch(1) do
            sleep 10.milliseconds
            raise "boom"
          end
          errors.send("no error")
        rescue ex
          errors.send(ex.message.to_s)
        end
      end
    end
    4.times { errors.receive.should eq("boom") }
    cache.has_key?(1).should be_false
    cache.fetch(1) { 5 }.should eq(5)
  end

  it "does not block other keys while computing" do
    cache = SyncLRUCache(Int32, Int32).new(10)
    cache[2] = 2
    started = Channel(Nil).new
    release = Channel(Nil).new
    spawn do
      cache.fetch(1) do
        started.send(nil)
        release.receive
        1
      end
    end
    started.receive
    cache[2]?.should eq(2)
    release.send(nil)
  end
end
