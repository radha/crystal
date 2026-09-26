# LRUCache benchmark; mirrors bench.rs and go/bench.go (same key streams).
require "lru_cache"

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

def bench(name, n, ops, reps, &)
  best = Float64::MAX
  sink = 0_u64
  reps.times do
    t = Time.instant
    sink &+= yield
    dt = (Time.instant - t).total_nanoseconds
    best = dt if dt < best
  end
  printf "%-14s n=%-8d %8.1f ns/op  (sink %d)\n", name, n, best / ops, sink & 0xff
end

sync = ARGV[0]? == "sync"
[1_000, 100_000, 1_000_000].each do |cap|
  r = SplitMix.new(1)
  universe = Array(UInt64).new(cap * 2) { r.next }
  r = SplitMix.new(3)
  stream = Array(UInt64).new(cap * 2) { universe[r.next % (cap * 2)] }
  reps = cap >= 1_000_000 ? 3 : (cap >= 100_000 ? 5 : 200)
  full = universe[0, cap]
  probes = full.shuffle(Random.new(2))

  {% for kind in ["LRUCache", "SyncLRUCache"] %}
    if sync == ({{kind}} == "SyncLRUCache")
      cache = {{kind.id}}(UInt64, UInt64).new(cap)
      full.each { |k| cache[k] = k }
      bench("get_hit", cap, cap, reps) { s = 0_u64; probes.each { |k| s &+= cache[k]? || 0_u64 }; s }
      bench("set_evict", cap, cap * 2, reps) { c = {{kind.id}}(UInt64, UInt64).new(cap); universe.each { |k| c[k] = k }; c.size.to_u64 }
      bench("fetch_mix", cap, cap * 2, reps) do
        c = {{kind.id}}(UInt64, UInt64).new(cap)
        s = 0_u64
        stream.each { |k| s &+= c.fetch(k) { |key| key &* 3 } }
        s
      end
    end
  {% end %}
end
