require "redis"

url = ARGV[0]? || "redis://127.0.0.1:6379"
redis = Redis::Client.new(url, db: 14)
redis.flushdb
redis.set("k", "v")

def report(name, ops, t)
  puts "#{name.ljust(28)} #{(ops / t.total_seconds).round(0).to_i.to_s.rjust(8)} ops/s  #{(t.total_nanoseconds / ops / 1000).round(1)} µs/op"
end

n = 50_000
t = Time.measure { n.times { redis.get("k") } }
report "sequential GET", n, t

fibers = 64
per = 5_000
done = Channel(Nil).new
t = Time.measure do
  fibers.times { spawn { per.times { redis.get("k") }; done.send(nil) } }
  fibers.times { done.receive }
end
report "64 fibers GET", fibers * per, t

t = Time.measure do
  fibers.times { spawn { per.times { redis.incr("c") }; done.send(nil) } }
  fibers.times { done.receive }
end
report "64 fibers INCR", fibers * per, t

t = Time.measure { redis.pipelined { |p| 10_000.times { p.incr("p") } } }
report "10k pipeline INCR", 10_000, t
redis.close
