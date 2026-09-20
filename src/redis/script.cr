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
  end
end
