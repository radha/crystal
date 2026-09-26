require "digest/sha256"
require "csv"

r = Random.new(ARGV[0]?.try(&.to_i) || 7)
alphabet = [
  Bytes[0x61], Bytes[0x20], Bytes[0x22], Bytes[0x5C], Bytes[0x23], Bytes[0x7B], Bytes[0x27], Bytes[0x0A], Bytes[0x00], Bytes[0x7F], Bytes[0x1B],
  "é".to_slice, "日".to_slice, "💎".to_slice, Bytes[0xFF], Bytes[0xC3], Bytes[0xE2, 0x82], Bytes[0x80], Bytes[0xF0, 0x9F], Bytes[0xED, 0xA0, 0x80],
]
def rand_bytes(r, alphabet, len)
  io = IO::Memory.new
  len.times do
    if r.rand(10) < 7
      io.write_byte (0x20 + r.rand(0x5F)).to_u8
    else
      io.write alphabet[r.rand(alphabet.size)]
    end
  end
  io.to_slice.dup
end

digest = Digest::SHA256.new
cases = 0
[0, 1, 2, 3, 7, 8, 9, 15, 16, 17, 31, 32, 63, 64, 65, 127, 128, 129, 200, 511, 512, 1000, 4096].each do |len|
  reps = len > 200 ? 40 : 300
  reps.times do
    b = rand_bytes(r, alphabet, len)
    s = String.new(b)
    digest << (s.valid_encoding? ? "V" : "I")
    digest << s.inspect << s.dump << s.inspect_unquoted << s.dump_unquoted
    # CSV quoting with default and custom quote chars (ASCII and non-ASCII)
    {'"', '\'', 'a', 'é'}.each do |q|
      io = IO::Memory.new
      CSV::Builder.new(io, quote_char: q, quoting: :all).row { |row| row << s }
      digest << io.to_slice
    end
    cases += 1
  end
end

# Deque sorts: contiguous and wrapped ring buffers, ints and stable pairs
1500.times do |t|
  n = r.rand(0..40)
  ints = Array.new(n) { r.rand(0..15) }
  cap = n + r.rand(0..8)
  d = Deque(Int32).new(cap == 0 ? 1 : cap)
  shift = r.rand(0..(cap == 0 ? 0 : cap))
  shift.times { d.push 0 }
  shift.times { d.shift }
  ints.each { |v| d.push v }
  pairs = ints.map_with_index { |v, i| {v, i} }
  dp = Deque({Int32, Int32}).new(cap == 0 ? 1 : cap)
  shift.times { dp.push({0, 0}) }
  shift.times { dp.shift }
  pairs.each { |v| dp.push v }
  case t % 6
  when 0 then d.sort!
  when 1 then d.unstable_sort!
  when 2 then d.sort! { |a, b| b <=> a }
  when 3 then d.unstable_sort! { |a, b| b <=> a }
  when 4 then d.sort_by! { |v| -v }
  else        d.unstable_sort_by! { |v| -v }
  end
  dp.sort_by! { |p| p[0] }
  digest << d.to_a.to_s << dp.to_a.to_s
  # Deque still usable after sorting
  d.push 99; d.unshift -1; d.shift; d.pop
  digest << d.to_a.to_s << d.size.to_s
  cases += 1
end
puts "#{cases} cases #{digest.hexfinal}"
