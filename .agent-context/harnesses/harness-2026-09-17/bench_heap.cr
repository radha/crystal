require "heap"

# Shared workload with bench_heap.rs: xorshift32 values, best of RUNS.
N = 1_000_000
STEADY = 1024
STEADY_OPS = 10_000_000
RUNS = 5

record Job, priority : Int32, id : Int32 do
  include Comparable(Job)

  def <=>(other : Job)
    priority <=> other.priority
  end
end

def xorshift(seed : UInt32)
  values = Array(Int32).new(N)
  x = seed
  N.times do
    x ^= x << 13
    x ^= x >> 17
    x ^= x << 5
    values << (x & 0x7fffffff).to_i32
  end
  values
end

def bench(name, ops, &)
  best = Float64::INFINITY
  sink = 0_i64
  RUNS.times do
    t = Time.monotonic
    sink &+= yield
    elapsed = (Time.monotonic - t).total_nanoseconds
    best = elapsed if elapsed < best
  end
  printf "%-32s %8.2f ns/op  (sink %d)\n", name, best / ops, sink
end

values = xorshift(2463534242_u32)

bench "push 1M + pop 1M", 2 * N do
  heap = Heap(Int32).new
  values.each { |v| heap.push(v) }
  s = 0_i64
  while v = heap.pop?
    s &+= v
  end
  s
end

bench "heapify 1M + pop 1M", 2 * N do
  heap = Heap.new(values)
  s = 0_i64
  while v = heap.pop?
    s &+= v
  end
  s
end

bench "heapify 1M only", N do
  Heap.new(values).size.to_i64
end

bench "steady push+pop (1024)", STEADY_OPS do
  heap = Heap.new(values[0, STEADY])
  s = 0_i64
  i = 0
  STEADY_OPS.times do
    heap.push(values.to_unsafe[i])
    s &+= heap.pop
    i += 1
    i = 0 if i == N
  end
  s
end

bench "steady push_pop (1024)", STEADY_OPS do
  heap = Heap.new(values[0, STEADY])
  s = 0_i64
  i = 0
  STEADY_OPS.times do
    s &+= heap.push_pop(values.to_unsafe[i])
    i += 1
    i = 0 if i == N
  end
  s
end

bench "steady replace_top (1024)", STEADY_OPS do
  heap = Heap.new(values[0, STEADY])
  s = 0_i64
  i = 0
  STEADY_OPS.times do
    s &+= heap.replace_top(values.to_unsafe[i])
    i += 1
    i = 0 if i == N
  end
  s
end

jobs = values.map_with_index { |v, i| Job.new(v, i) }

bench "Job <=> push 1M + pop 1M", 2 * N do
  heap = Heap(Job).new
  jobs.each { |j| heap.push(j) }
  s = 0_i64
  while j = heap.pop?
    s &+= j.id
  end
  s
end

bench "Job block push 1M + pop 1M", 2 * N do
  heap = Heap(Job).new { |a, b| a.priority <=> b.priority }
  jobs.each { |j| heap.push(j) }
  s = 0_i64
  while j = heap.pop?
    s &+= j.id
  end
  s
end

bench "max block push 1M + pop 1M", 2 * N do
  heap = Heap(Int32).new { |a, b| b <=> a }
  values.each { |v| heap.push(v) }
  s = 0_i64
  while v = heap.pop?
    s &+= v
  end
  s
end

bench "Job steady push+pop (1024)", STEADY_OPS do
  heap = Heap.new(jobs[0, STEADY])
  s = 0_i64
  i = 0
  STEADY_OPS.times do
    heap.push(jobs.to_unsafe[i])
    s &+= heap.pop.id
    i += 1
    i = 0 if i == N
  end
  s
end

record Wide, deadline : Int64, id : Int64, extra : Int64 do
  include Comparable(Wide)

  def <=>(other : Wide)
    deadline <=> other.deadline
  end
end

wides = values.map_with_index { |v, i| Wide.new(v.to_i64, i.to_i64, 0_i64) }

bench "Wide 24B push 1M + pop 1M", 2 * N do
  heap = Heap(Wide).new
  wides.each { |w| heap.push(w) }
  s = 0_i64
  while w = heap.pop?
    s &+= w.id
  end
  s
end

bench "Job presized push 1M + pop 1M", 2 * N do
  heap = Heap(Job).new(N)
  jobs.each { |j| heap.push(j) }
  s = 0_i64
  while j = heap.pop?
    s &+= j.id
  end
  s
end
