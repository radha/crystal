require "redis"
require "wait_group"

def report(name, ops, t)
  puts "#{name.ljust(34)} #{(ops / t.total_seconds).round(0).to_i.to_s.rjust(9)} ops/s  #{(t.total_nanoseconds / ops / 1000).round(2)} µs/op"
end

seeds = ["redis://127.0.0.1:7100", "redis://127.0.0.1:7101", "redis://127.0.0.1:7102"]
cluster = Redis::Cluster.new(seeds)
cluster.refresh
cluster.nodes.each { |n| n.client.flushall if n.master? }
keys = Array.new(300) { |i| "k#{i}" }
keys.each { |k| cluster.set(k, "v") }

# 1. Sequential GET: cluster versus a plain client on the owning node.
n = 50_000
owner = cluster.node_for("k0").client
t = Time.measure { n.times { owner.get("k0") } }
report "GET plain client", n, t
t = Time.measure { n.times { cluster.get("k0") } }
report "GET via cluster", n, t

# 2. 64 fibers, GET over keys spread across the three masters.
total = 500_000
wg = WaitGroup.new(64)
t = Time.measure do
  64.times do |f|
    spawn do
      begin
        (total // 64).times { |i| cluster.get(keys[(f + i * 64) % 300]) }
      ensure
        wg.done
      end
    end
  end
  wg.wait
end
report "64 fibers GET (3 masters)", total, t

# 3. One 300-GET split pipeline versus 3 × 100 by hand.
groups = keys.group_by { |k| cluster.node_for(k) }
iters = 2_000
t = Time.measure { iters.times { cluster.pipelined { |p| keys.each { |k| p.get(k) } } } }
report "pipelined 300 GET split", iters, t
t = Time.measure do
  iters.times do
    groups.each { |node, ks| node.client.pipelined { |p| ks.each { |k| p.get(k) } } }
  end
end
report "3 pipelines by hand (sequential)", iters, t

# 4. watch: pooled versus a fresh connection per call (slice 2 shape).
# "k0" hashes to slot 8579, owned by 7101, not seeds[0] (7100) — route to
# the actual owning node's URL so `watch`/`get` land without a MOVED redirect.
owner_url = "redis://#{cluster.node_for("k0").address}"
client = Redis::Client.new(owner_url)
n = 5_000
t = Time.measure { n.times { client.watch("k0") { |c| c.get("k0") } } }
report "watch via pool", n, t
t = Time.measure do
  n.times do
    conn = Redis::Connection.new(owner_url)
    conn.watch("k0")
    conn.get("k0")
    conn.close
  end
end
report "watch fresh connection", n, t

# 5. Pool checkout/checkin with an idle connection.
pool = Redis::Pool.new(owner_url, size: 2)
pool.checkout { }
n = 1_000_000
t = Time.measure { n.times { pool.checkout { } } }
puts "pool checkout/checkin: #{(t.total_nanoseconds / n).round(0)} ns"
pool.close
client.close
cluster.close
