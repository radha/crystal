# Varint + frame throughput. Same datasets as bench_varint.go / bench_varint.rs.
#   bin/crystal build --release -o /tmp/bv_cr bench_varint.cr && /tmp/bv_cr
require "binary"

N = 1_000_000

def dataset(kind : Symbol) : Array(UInt64)
  x = 0x9E3779B97F4A7C15_u64
  Array(UInt64).new(N) do
    x ^= x << 13; x ^= x >> 7; x ^= x << 17
    case kind
    when :small  then x & 0x7f
    when :medium then x & 0x0fff_ffff
    else              x >> (x & 63)
    end
  end
end

def best(iters = 20, &)
  best = Float64::INFINITY
  iters.times do
    t = Time.monotonic
    yield
    d = (Time.monotonic - t).total_nanoseconds
    best = d if d < best
  end
  best
end

def report(name, ns, bytes)
  printf "%-28s %7.2f ns/op %8.1f MB/s\n", name, ns / N, bytes / ns * 1e3
end

sink = 0_u64
{:small, :medium, :full}.each do |kind|
  values = dataset(kind)
  buffer = Bytes.new(N * 10)
  total = 0

  ns = best do
    pos = 0
    values.each { |v| pos += Binary::Varint.encode(v, buffer[pos..]) }
    total = pos
  end
  report "#{kind} encode slice", ns, total

  ns = best do
    pos = 0
    N.times do
      v, n = Binary::Varint.decode(UInt64, buffer[pos..])
      sink &+= v
      pos += n
    end
  end
  report "#{kind} decode slice", ns, total

  io = IO::Memory.new(total)
  ns = best do
    io.clear
    values.each { |v| io.write_varint(v) }
  end
  report "#{kind} encode IO::Memory", ns, total

  ns = best do
    io.rewind
    N.times { sink &+= io.read_varint }
  end
  report "#{kind} decode IO::Memory", ns, total
end

# Frames: 1M frames of 32 bytes through IO::Memory.
body = Bytes.new(32, 0xab_u8)
io = IO::Memory.new(N * 36)
ns = best(10) do
  io.clear
  N.times { io.write_frame(body) }
end
report "frame write 32B u32be", ns, N * 36

ns = best(10) do
  io.rewind
  N.times { sink &+= io.read_frame.size }
end
report "frame read 32B u32be", ns, N * 36

scratch = IO::Memory.new
ns = best(10) do
  io.rewind
  N.times { sink &+= io.read_frame(into: scratch) }
end
report "frame read(into:) 32B", ns, N * 36

puts "sink #{sink}"
