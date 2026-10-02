# RadixTree benchmark: same generated keys and operations as src/main.rs.
# Build: bin/crystal build --release bench.cr -o /tmp/radix_bench_cr
require "radix_tree"

N    = 100_000
REPS =       5

def urls : Array(String)
  Array.new(N) { |i| "/api/v1/users/#{i}/posts/#{i * 7 % 1000}" }
end

def words : Array(String)
  state = 12345_u64
  rand = -> do
    state = state &* 6364136223846793005_u64 &+ 1442695040888963407_u64
    state >> 33
  end
  Array.new(N) do
    len = 3 + rand.call % 10
    String.build { |io| len.times { io << ('a'.ord + rand.call % 26).chr } }
  end
end

record Data, name : String, keys : Array(String), probes : Array(Int32),
  misses : Array(String), queries : Array(String), prefixes : Array(String)

def data(name) : Data
  keys = name == "urls" ? urls : words
  probes = Array.new(N) { |j| (j.to_i64 * 7919 % N).to_i32 }
  misses = probes.map { |i| keys[i] + "~" }
  suffix = name == "urls" ? "/comments/12" : "qz"
  queries = probes.map { |i| keys[i] + suffix }
  prefixes = if name == "urls"
               (10..99).map { |d| "/api/v1/users/#{d}" }
             else
               ('a'..'z').flat_map { |a| ('a'..'z').map { |b| "#{a}#{b}" } }
             end
  Data.new(name, keys, probes, misses, queries, prefixes)
end

def report(d, op, ops, best, check)
  printf("%-10s %-6s %-14s %8.1f ns/op  (ops %d, check %d)\n", "crystal", d.name, op, best / ops, ops, check)
end

def time(d, op, &)
  best = Float64::MAX
  check = 0_u64
  ops = 0
  REPS.times do
    t = Time.instant
    check, ops = yield
    dt = (Time.instant - t).total_nanoseconds
    best = dt if dt < best
  end
  report(d, op, ops, best, check)
end

def build(d) : RadixTree(UInt64)
  t = RadixTree(UInt64).new
  d.keys.each_with_index { |k, i| t[k] = i.to_u64 }
  t
end

def bench(d : Data)
  best = Float64::MAX
  len = 0
  REPS.times do
    t0 = Time.instant
    t = RadixTree(UInt64).new
    d.keys.each_with_index { |k, i| t[k] = i.to_u64 }
    dt = (Time.instant - t0).total_nanoseconds
    best = dt if dt < best
    len = t.size
  end
  report(d, "insert", N, best, len)

  t = build(d)
  time(d, "get_hit") do
    s = 0_u64
    d.probes.each { |i| s &+= t[d.keys[i]]?.not_nil! }
    {s, N}
  end
  time(d, "get_miss") do
    s = 0_u64
    d.misses.each { |k| s += 1 if t[k]? }
    {s, N}
  end
  time(d, "longest_prefix") do
    s = 0_u64
    d.queries.each { |q| s &+= t.longest_prefix_value(q) || 0_u64 }
    {s, N}
  end
  time(d, "prefix_vals") do
    s = 0_u64
    n = 0
    d.prefixes.each do |p|
      t.each_with_prefix(p) do |_, v|
        s &+= v
        n += 1
      end
    end
    {s, n}
  end
  # Also reads each key's length, which in Crystal is a load from the
  # String object (Rust keeps the length in the reference).
  time(d, "prefix_keys") do
    s = 0_u64
    n = 0
    d.prefixes.each do |p|
      t.each_with_prefix(p) do |k, v|
        s &+= v &+ k.bytesize
        n += 1
      end
    end
    {s, n}
  end

  best = Float64::MAX
  left = 0
  REPS.times do
    t = build(d)
    t0 = Time.instant
    d.probes.each_with_index { |i, j| t.delete(d.keys[i]) if j.even? }
    dt = (Time.instant - t0).total_nanoseconds
    best = dt if dt < best
    left = t.size
  end
  report(d, "delete_half", N // 2, best, left)
end

{"urls", "words"}.each { |name| bench(data(name)) }
