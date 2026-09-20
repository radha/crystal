# A pure-Crystal Redis client speaking RESP3 (with RESP2 fallback) over TCP,
# Unix sockets or TLS.
#
# `Redis::Client` is a multiplexed connection that any number of fibers can
# share; commands from concurrent fibers are pipelined automatically.
# `Redis::Connection` is a plain synchronous connection for blocking
# commands. Both include `Redis::Commands`, the typed command methods, and
# `Client#pipelined` collects commands into one write with typed
# `Redis::Future`s.
#
# ```
# require "redis"
#
# redis = Redis::Client.new("redis://localhost:6379/0")
# redis.set("greeting", "hello", ex: 60)
# redis.get("greeting")   # => "hello"
# redis.incr("counter")   # => 1_i64
# redis.hgetall("user:1") # => {} of String => String
#
# results = redis.pipelined do |p|
#   p.set("a", "1")
#   p.get("a")
# end
# results # => ["OK", "1"]
#
# redis.command("CLIENT", "ID") # => 42_i64 (a Redis::Value)
# ```
#
# Replies are `Redis::Value`, a union of `Nil`, `Bool`, `Int64`, `Float64`,
# `String`, `Redis::BigNumber`, `Redis::CommandError`, `Array`, `Set` and
# `Hash`. Typed commands normalize RESP2 and RESP3 replies to the same
# Crystal type. Errors: `Redis::CommandError` (server error reply, with
# `code`), `Redis::ConnectionError`, `Redis::ProtocolError`,
# `Redis::ClusterError`, `Redis::PoolTimeoutError`.
#
# Pub/sub: `Redis::Subscriber` (or `Client#subscriber`) receives on its
# own connection and reconnects by itself; `Client#publish` sends.
# Transactions: `Client#multi { |tx| ... }` runs a `MULTI`..`EXEC` block
# atomically with typed futures; `Client#watch(*keys) { |conn| ... }`
# gives optimistic locking on a pooled dedicated connection. Scripts:
# `Redis::Script` with `run`, which sends `EVALSHA` and falls back to
# `EVAL` when the server has not cached the script.
#
# ```
# sub = redis.subscriber
# sub.subscribe("news")
# redis.publish("news", "hello")
# sub.receive.payload # => "hello"
#
# redis.multi { |tx| tx.set("a", "1"); tx.incr("hits") } # => ["OK", 1_i64]
#
# script = Redis::Script.new("return redis.call('INCRBY', KEYS[1], ARGV[1])")
# redis.run(script, keys: ["hits"], args: [5]) # => 6_i64
# ```
#
# Blocking commands: `Client#with_connection { |conn| ... }` borrows a
# dedicated `Connection` from the client's pool, and `Redis::Pool` is
# that pool on its own. Cluster: `Redis::Cluster` routes every command
# by key slot to the owning master, follows `MOVED`/`ASK`, reloads the
# topology when it changes, and splits pipelines by node.
#
# ```
# redis.with_connection { |conn| conn.call("BLPOP", "jobs", 0) }
#
# cluster = Redis::Cluster.new(["redis://10.0.0.1:7000", "redis://10.0.0.2:7000"])
# cluster.set("user:1", "x")
# cluster.pipelined { |p| p.get("a"); p.get("b") } # split by node, replies in order
# cluster.close
# ```
#
# Not included: replica reads, sharded pub/sub, Sentinel, streams helpers.
require "socket"
require "openssl"
require "uri"
require "set"
require "digest/sha1"
require "wait_group"
require "./redis/error"
require "./redis/value"
require "./redis/crc16"
require "./redis/script"
require "./redis/resp"
require "./redis/commands"
require "./redis/connection"
require "./redis/pool"
require "./redis/pipeline"
require "./redis/transaction"
require "./redis/client"
require "./redis/subscriber"
require "./redis/cluster"

module Redis
end
