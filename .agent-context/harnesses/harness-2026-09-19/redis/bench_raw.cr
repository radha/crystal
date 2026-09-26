# Baseline: raw TCP socket, no client machinery (no fibers, no channels, no
# mutex) -- measures the loopback+server round-trip floor for one connection.
require "socket"
require "redis"

sock = TCPSocket.new("127.0.0.1", 6379)
sock.tcp_nodelay = true
sock.sync = false
sock.read_buffering = true

Redis::RESP.write_command(sock, "SELECT", "14")
sock.flush
Redis::RESP.read(sock)
Redis::RESP.write_command(sock, "SET", "k", "v")
sock.flush
Redis::RESP.read(sock)

5_000.times { Redis::RESP.write_command(sock, "GET", "k"); sock.flush; Redis::RESP.read(sock) }

n = 50_000
t = Time.measure do
  n.times do
    Redis::RESP.write_command(sock, "GET", "k")
    sock.flush
    Redis::RESP.read(sock)
  end
end
puts "raw socket sequential GET   #{(n / t.total_seconds).round(0).to_i.to_s.rjust(8)} ops/s  #{(t.total_nanoseconds / n / 1000).round(1)} µs/op"
sock.close
