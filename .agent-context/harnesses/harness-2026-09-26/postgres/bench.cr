# Crystal side of the PostgreSQL client benchmarks (design doc section 13).
#
#   bin/crystal build --release -o bench_cr bench.cr
#   ./bench_cr [seq|fetch|pool|all]
#
# PG_URL overrides the connection URL. Output lines are machine-readable:
#   RESULT <bench> key=value ...
require "postgres"

URL = ENV["PG_URL"]? || "postgres://postgres@127.0.0.1:5432/crystal_test?sslmode=disable"

struct BenchRow
  include Postgres::Serializable
  getter id : Int64
  getter name : String
  getter score : Float64
  getter at : Time
  getter ok : Bool
end

def percentile(sorted : Array(Float64), p : Float64) : Float64
  idx = ((sorted.size - 1) * p).round.to_i
  sorted[idx]
end

def bench_seq
  conn = Postgres::Connection.new(URL)
  sql = "select $1::int4"
  1000.times { |i| conn.query_one(sql, i, as: Int32) }
  n = 20_000
  lat = Array(Float64).new(n)
  sum = 0_i64
  total_start = Time.instant
  n.times do |i|
    t0 = Time.instant
    v = conn.query_one(sql, i, as: Int32)
    lat << (Time.instant - t0).total_microseconds
    sum &+= v
  end
  total = (Time.instant - total_start).total_microseconds
  raise "bad sum #{sum}" unless sum == n.to_i64 * (n - 1) // 2
  lat.sort!
  printf("RESULT seq mean_us=%.2f p50_us=%.2f p99_us=%.2f\n", total / n, percentile(lat, 0.50), percentile(lat, 0.99))
  conn.close
end

def bench_fetch
  conn = Postgres::Connection.new(URL)
  sql = "select id, name, score, at, ok from bench_rows"
  10.times { conn.query_all(sql, as: BenchRow) }
  iters = 200
  rows = 0_i64
  checksum = 0_i64
  start = Time.instant
  iters.times do
    list = conn.query_all(sql, as: BenchRow)
    rows += list.size
    checksum &+= list.last.id
  end
  elapsed = (Time.instant - start).total_seconds
  raise "bad rows #{rows}" unless rows == iters * 10_000
  printf("RESULT fetch ms_per_fetch=%.3f rows_per_s=%.0f\n", elapsed * 1000 / iters, rows / elapsed)
  conn.close
end

def bench_pool
  db = Postgres::Client.new(URL, pool_size: 8)
  sql = "select $1::int4"
  tasks = 64
  per = 2000
  # warm up: open all 8 connections and prepare the statement on each
  done = Channel(Nil).new
  tasks.times { spawn { 50.times { |i| db.query_one(sql, i, as: Int32) }; done.send(nil) } }
  tasks.times { done.receive }
  start = Time.instant
  tasks.times do
    spawn do
      per.times { |i| db.query_one(sql, i, as: Int32) }
      done.send(nil)
    end
  end
  tasks.times { done.receive }
  elapsed = (Time.instant - start).total_seconds
  printf("RESULT pool ops_per_s=%.0f\n", (tasks * per) / elapsed)
  db.close
end

{% if flag?(:execution_context) %}
  def run_pool_mt
    workers = (ENV["CRYSTAL_WORKERS"]? || "4").to_i
    ctx = Fiber::ExecutionContext::Parallel.new("bench", workers)
    ch = Channel(Nil).new
    ctx.spawn { bench_pool; ch.send(nil) }
    ch.receive
  end
{% end %}

mode = ARGV[0]? || "all"
case mode
when "seq"   then bench_seq
when "fetch" then bench_fetch
when "pool"
  {% if flag?(:execution_context) %}
    run_pool_mt
  {% else %}
    bench_pool
  {% end %}
when "all"
  bench_seq
  bench_fetch
  bench_pool
else
  abort "usage: bench_cr [seq|fetch|pool|all]"
end
