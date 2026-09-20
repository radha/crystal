require "digest/sha1"

module Redis
  # A Lua script with its SHA1 computed locally, so that `run` can send
  # `EVALSHA` without asking the server for the hash first.
  #
  # ```
  # script = Redis::Script.new("return redis.call('INCRBY', KEYS[1], ARGV[1])")
  # redis.run(script, keys: ["hits"], args: [5]) # => 5_i64
  # ```
  struct Script
    # The Lua source.
    getter source : String
    # The lowercase hex SHA1 of `source`, which is what Redis uses as the
    # script's cache key.
    getter sha : String

    # Creates a script from *source*, computing its SHA1 immediately.
    def initialize(@source : String)
      @sha = Digest::SHA1.hexdigest(@source)
    end

    # Loads the script into the server's cache with `SCRIPT LOAD` and
    # returns its SHA1 (equal to `sha`). Useful to warm the cache before a
    # pipeline, which cannot fall back to `EVAL` mid-flight.
    def load(redis : Client | Connection) : String
      sha = redis.script_load(@source)
      redis.script_cache.add(sha)
      sha
    end
  end

  # :nodoc:
  #
  # The SHAs a client has seen the server accept. Pipelines consult it to
  # choose between `EVALSHA` and `EVAL`; a `NOSCRIPT` reply removes the
  # SHA again. Shared between a client, its pipelines and their futures,
  # which may run on different fibers, hence the mutex.
  class ScriptCache
    @mutex = Mutex.new
    @known = Set(String).new

    def known?(sha : String) : Bool
      @mutex.synchronize { @known.includes?(sha) }
    end

    def add(sha : String) : Nil
      @mutex.synchronize { @known << sha }
    end

    def delete(sha : String) : Nil
      @mutex.synchronize { @known.delete(sha) }
    end
  end
end
