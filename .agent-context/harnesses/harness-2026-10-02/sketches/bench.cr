# Sketch / union-find benchmark; mirrors bench.rs (same key streams, sizes).
require "rapidhash"
require "bloom_filter"
require "hyper_log_log"
require "count_min_sketch"
require "disjoint_set"

struct SplitMix
  def initialize(@s : UInt64)
  end

  def next : UInt64
    @s &+= 0x9E3779B97F4A7C15_u64
    z = @s
    z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9_u64
    z = (z ^ (z >> 27)) &* 0x94D049BB133111EB_u64
    z ^ (z >> 31)
  end
end

def bench(name, ops, reps, &)
  best = Float64::MAX
  sink = 0_u64
  reps.times do
    t = Time.instant
    sink &+= yield
    dt = (Time.instant - t).total_nanoseconds
    best = dt if dt < best
  end
  printf "%-28s %8.2f ns/op  (sink %d)\n", name, best / ops, sink & 0xff
end

n = 1_000_000
r = SplitMix.new(1)
keys = Array(UInt64).new(n) { r.next }
misses = Array(UInt64).new(n) { r.next }
words = Array(String).new(n) { |i| "item-#{i}" }
blob = Bytes.new(4096) { |i| (i &* 31 &+ 7).to_u8! }

bench("hash/str ~11B", n, 5) { s = 0_u64; words.each { |w| s &+= Rapidhash.v3(w) }; s }
bench("hash/int (16B)", n, 5) { s = 0_u64; keys.each { |k| s &+= Rapidhash.of(k) }; s }
[64, 1024, 4096].each do |len|
  reps = 4_000_000 // len
  bench("hash/#{len}B", reps, 5) { s = 0_u64; reps.times { s &+= Rapidhash.v3(blob[0, len]) }; s }
end

bench("bloom/insert", n, 3) { b = BloomFilter.new(n, 0.01); keys.each { |k| b << k }; b.includes?(keys[0]) ? 1_u64 : 0_u64 }
b = BloomFilter.new(n, 0.01)
keys.each { |k| b << k }
bench("bloom/hit", n, 3) { s = 0_u64; keys.each { |k| s += 1 if b.includes?(k) }; s }
bench("bloom/miss", n, 3) { s = 0_u64; misses.each { |k| s += 1 if b.includes?(k) }; s }

bench("hll/insert", n, 3) { h = HyperLogLog.new(14); keys.each { |k| h << k }; h.size.to_u64 }
h = HyperLogLog.new(14)
keys.each { |k| h << k }
h2 = HyperLogLog.new(14)
misses.each { |k| h2 << k }
bench("hll/merge+count", 1, 50) { (h | h2).size.to_u64 }
bench("hll/merge", 1, 50) { (h | h2).@registers[0].to_u64 }

bench("cms(conservative)/add", n, 3) do
  c = CountMinSketch.new(width: 32768, depth: 6, conservative: true)
  keys.each { |k| c.add(k & 0xffff) }
  c.count(1)
end
c = CountMinSketch.new(width: 32768, depth: 6, conservative: true)
keys.each { |k| c.add(k & 0xffff) }
bench("cms(conservative)/estimate", n, 3) { s = 0_u64; keys.each { |k| s &+= c.count(k & 0xffff) }; s }
bench("cms(plain)/add", n, 3) do
  c = CountMinSketch.new(width: 32768, depth: 6)
  keys.each { |k| c.add(k & 0xffff) }
  c.count(1)
end

pairs = Array({Int32, Int32}).new(n) { {(r.next % n).to_i32, (r.next % n).to_i32} }
bench("uf/union", n, 5) { u = DisjointSet(Int32).new(n); s = 0_u64; pairs.each { |(a, b)| s += 1 if u.union(a, b) }; s }
u = DisjointSet(Int32).new(n)
pairs.each { |(a, b)| u.union(a, b) }
bench("uf/find", n, 5) { s = 0_u64; pairs.each { |(a, _)| s &+= u.find(a) }; s }
bench("uf(String)/union", n, 3) { u = DisjointSet(String).new; s = 0_u64; pairs.each { |(a, b)| s += 1 if u.union(words[a], words[b]) }; s }
