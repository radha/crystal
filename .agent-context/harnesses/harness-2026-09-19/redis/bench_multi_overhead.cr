# Isolates the client-side cost of `Client#multi` from the two extra
# commands (MULTI, EXEC) that a transaction necessarily puts on the wire.
require "redis"

url = ARGV[0]? || "redis://127.0.0.1:6379"
redis = Redis::Client.new(url, db: 14)
redis.flushdb

def report(name, ops, t)
  puts "#{name.ljust(34)} #{(ops / t.total_seconds).round(0).to_i.to_s.rjust(9)} ops/s  #{(t.total_nanoseconds / ops / 1000).round(2)} µs/op"
end

iters = 10_000

# Warm-up so that nothing below pays for a cold connection.
1_000.times { redis.pipelined { |p| 10.times { p.incr("w") } } }

t = Time.measure { iters.times { redis.pipelined { |p| 10.times { p.incr("pl") } } } }
report "pipeline 10 INCR (10 cmds)", iters, t

# Wire-count control: same number of commands as MULTI..EXEC, no transaction.
t = Time.measure { iters.times { redis.pipelined { |p| 12.times { p.incr("pl12") } } } }
report "pipeline 12 INCR (12 cmds)", iters, t

# Exact wire equivalent of `multi`, built by hand out of raw calls: no
# Transaction object, no per-command future, no EXEC-array demux.
t = Time.measure do
  iters.times do
    redis.pipelined do |p|
      p.call("MULTI")
      10.times { p.call("INCR", "hand") }
      p.call("EXEC")
    end
  end
end
report "hand MULTI+10 INCR+EXEC", iters, t

t = Time.measure { iters.times { redis.multi { |tx| 10.times { tx.incr("tx") } } } }
report "multi 10 INCR", iters, t

redis.close
