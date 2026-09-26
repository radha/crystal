require "benchmark"
require "redis"

REPLIES = {
  "int"     => ":42\r\n",
  "bulk10"  => "$10\r\n0123456789\r\n",
  "bulk1k"  => "$1024\r\n" + "x" * 1024 + "\r\n",
  "array10" => "*10\r\n" + "$3\r\nabc\r\n" * 10,
  "map10"   => "%10\r\n" + "$3\r\nkey\r\n:1\r\n" * 10,
}

REPLIES.each do |name, frame|
  data = (frame * 1000).to_slice
  io = IO::Memory.new(data)
  n = 1_000_000 // 1000
  # warm up
  10.times { io.rewind; 1000.times { Redis::RESP.read(io) } }
  t = Time.measure do
    n.times do
      io.rewind
      1000.times { Redis::RESP.read(io) }
    end
  end
  puts "parse #{name.ljust(8)} #{(t.total_nanoseconds / 1_000_000).round(1)} ns/reply  #{(data.size.to_f * n / t.total_seconds / 1e6).round(0)} MB/s"
end

buf = IO::Memory.new
100_000.times { buf.clear; Redis::RESP.write_command(buf, "SET", "key:12345", "value-value-value") }
t = Time.measure { 1_000_000.times { buf.clear; Redis::RESP.write_command(buf, "SET", "key:12345", "value-value-value") } }
puts "encode SET #{(t.total_nanoseconds / 1_000_000).round(1)} ns/command"
