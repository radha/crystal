# SortedMap benchmark; mirrors bench.rs and bench.go (same key streams).
require "sorted_map"

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

def keys(n, seed)
  r = SplitMix.new(seed)
  Array(UInt64).new(n) { r.next }
end

def bench(name, n, ops, reps = 5, &)
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

[1_000, 100_000, 1_000_000].each do |n|
  ks = keys(n, 1_u64)
  probes = keys(n, 1_u64).shuffle(Random.new(2))
  sorted = ks.sort
  reps = n >= 1_000_000 ? 3 : (n >= 100_000 ? 5 : 200)
  # Built like Rust's collect(): sort once, then bulk build.
  map = SortedMap.new(ks.map { |k| {k, k} })

  bench("insert_rand", n, n, reps) { m = SortedMap(UInt64, UInt64).new; ks.each { |k| m[k] = k }; m.size.to_u64 }
  bench("insert_seq", n, n, reps) { m = SortedMap(UInt64, UInt64).new; sorted.each { |k| m[k] = k }; m.size.to_u64 }
  bench("bulk_sorted", n, n, reps) { SortedMap.from_sorted(sorted.map { |k| {k, k} }).size.to_u64 }
  bench("get_hit", n, n, reps) { s = 0_u64; probes.each { |k| s &+= map[k]? || 0_u64 }; s }
  bench("iter_all", n, n, reps) { s = 0_u64; map.each { |k, v| s &+= v }; s }
  q = Math.min(1000, n)
  bench("range_100", n, q * 100, reps) do
    s = 0_u64
    q.times do |i|
      lo = sorted[(i * 7919) % (n - 100)]
      c = 0
      map.each(lo..) { |k, v| s &+= v; c += 1; break if c == 100 }
    end
    s
  end
  bench("floor", n, n, reps) { s = 0_u64; probes.each { |k| s &+= (map.floor(k &+ 1).try(&.[0]) || 0_u64) }; s }
  bench("delete_rand", n, n, reps) do
    m = SortedMap.from_sorted(sorted.map { |k| {k, k} })
    probes.each { |k| m.delete(k) }
    m.size.to_u64
  end
end
