require "redis"

url = ARGV[0]? || "redis://127.0.0.1:6379"
redis = Redis::Client.new(url, db: 14)
redis.flushdb

def report(name, ops, t)
  puts "#{name.ljust(30)} #{(ops / t.total_seconds).round(0).to_i.to_s.rjust(9)} ops/s  #{(t.total_nanoseconds / ops / 1000).round(2)} µs/op"
end

# 1. publish → receive latency, one channel, sequential round trips.
sub = redis.subscriber
sub.subscribe("bench")
n = 10_000
latencies = Array(Float64).new(n)
n.times do |i|
  t0 = Time.monotonic
  redis.publish("bench", i.to_s)
  sub.receive
  latencies << (Time.monotonic - t0).total_nanoseconds / 1000
end
latencies.sort!
puts "pubsub round trip: median #{latencies[n // 2].round(1)} µs, p99 #{latencies[n * 99 // 100].round(1)} µs"

# 2. subscriber throughput: 64 channels, 1M pipelined publishes.
64.times { |i| sub.subscribe("c#{i}") }
total = 1_000_000
done = Channel(Nil).new
spawn do
  total.times { sub.receive }
  done.send(nil)
end
t = Time.measure do
  (total // 10_000).times do
    redis.pipelined { |p| 10_000.times { |j| p.publish("c#{j % 64}", "m") } }
  end
  done.receive
end
report "subscriber throughput", total, t
sub.close

# 3. multi with 10 INCR vs the same 10 in a plain pipeline.
iters = 10_000
t = Time.measure { iters.times { redis.pipelined { |p| 10.times { p.incr("pl") } } } }
report "pipeline 10 INCR", iters, t
t = Time.measure { iters.times { redis.multi { |tx| 10.times { tx.incr("tx") } } } }
report "multi 10 INCR", iters, t

# 4. run(script) vs evalsha by hand.
script = Redis::Script.new("return redis.call('INCR', KEYS[1])")
redis.run(script, keys: ["s"])
n = 100_000
t = Time.measure { n.times { redis.evalsha(script.sha, keys: ["s"]) } }
report "evalsha by hand", n, t
t = Time.measure { n.times { redis.run(script, keys: ["s"]) } }
report "run(script)", n, t
redis.close
