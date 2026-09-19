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
# `code`), `Redis::ConnectionError`, `Redis::ProtocolError`.
#
# Not in this slice: pub/sub, MULTI/EXEC, script caching, cluster routing.
require "socket"
require "openssl"
require "uri"
require "set"
require "./redis/error"
require "./redis/value"
require "./redis/resp"
require "./redis/commands"
require "./redis/connection"
require "./redis/pipeline"
require "./redis/client"

module Redis
end
