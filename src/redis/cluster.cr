module Redis
  # A client for Redis Cluster. Task 7 replaces this doc comment.
  class Cluster
    # Number of hash slots in a Redis Cluster.
    SLOTS = 16384

    # Commands that name no key and are routed to any master. `PUBLISH`
    # is here because the cluster bus delivers a message to every node.
    KEYLESS = Set{
      "ACL", "ASKING", "AUTH", "BGREWRITEAOF", "BGSAVE", "CLIENT", "CLUSTER", "COMMAND", "CONFIG",
      "DBSIZE", "DEBUG", "DISCARD", "ECHO", "EXEC", "FLUSHALL", "FLUSHDB", "FUNCTION", "HELLO", "INFO",
      "KEYS", "LASTSAVE", "LATENCY", "LOLWUT", "MODULE", "MONITOR", "MULTI", "PING", "PSUBSCRIBE",
      "PUBLISH", "PUBSUB", "PUNSUBSCRIBE", "QUIT", "RANDOMKEY", "READONLY", "READWRITE", "REPLICAOF",
      "RESET", "ROLE", "SAVE", "SCAN", "SCRIPT", "SELECT", "SHUTDOWN", "SLOWLOG", "SUBSCRIBE", "SWAPDB",
      "TIME", "UNSUBSCRIBE", "UNWATCH", "WAIT",
    }

    # :nodoc:
    #
    # Commands whose key is not at position 1: `:count_at_N` means the
    # key count is at position N and the first key right after it;
    # `:streams` means the first key follows the word `STREAMS`;
    # `:position_2` is a fixed position; `:memory` is `MEMORY USAGE key`.
    SPECIAL = {
      "EVAL" => :count_at_2, "EVALSHA" => :count_at_2, "EVAL_RO" => :count_at_2, "EVALSHA_RO" => :count_at_2,
      "FCALL" => :count_at_2, "FCALL_RO" => :count_at_2, "BLMPOP" => :count_at_2, "BZMPOP" => :count_at_2,
      "LMPOP" => :count_at_1, "ZMPOP" => :count_at_1, "SINTERCARD" => :count_at_1, "ZINTERCARD" => :count_at_1,
      "ZUNION" => :count_at_1, "ZINTER" => :count_at_1, "ZDIFF" => :count_at_1,
      "XREAD" => :streams, "XREADGROUP" => :streams,
      "OBJECT" => :position_2, "XINFO" => :position_2, "XGROUP" => :position_2, "BITOP" => :position_2,
      "MEMORY" => :memory,
    }

    # The hash slot of *key*: the CRC16 of its hash tag (the bytes between
    # the first `{` and the first `}` after it, when there is at least one)
    # or of the whole key, modulo `SLOTS`.
    def self.key_slot(key : String) : Int32
      bytes = key.to_slice
      if (open = bytes.index('{'.ord.to_u8)) && (close = bytes[open + 1..].index('}'.ord.to_u8)) && close > 0
        bytes = bytes[open + 1, close]
      end
      CRC16.checksum(bytes).to_i32 & (SLOTS - 1)
    end

    # The key a command is routed by, or `nil` for a command that names
    # none (which a `Cluster` sends to any master). Names are matched
    # case-insensitively. Ordinary commands carry their key at position 1;
    # `SPECIAL` lists the exceptions; `KEYLESS` the commands with no key.
    # Never raises: a malformed command routes to a random master and the
    # server's error reply comes back as usual.
    #
    # ```
    # Redis::Cluster.route_key({"GET", "k"})                 # => "k"
    # Redis::Cluster.route_key({"EVAL", "return 1", 1, "k"}) # => "k"
    # Redis::Cluster.route_key({"PING"})                     # => nil
    # ```
    def self.route_key(args : Indexable) : String?
      name = args[0]?
      return nil unless name.is_a?(String)
      name = name.upcase unless uppercase?(name)
      return nil if KEYLESS.includes?(name)
      case SPECIAL[name]?
      when :count_at_1 then key_after_count(args, 1)
      when :count_at_2 then key_after_count(args, 2)
      when :position_2 then string_at(args, 2)
      when :streams
        i = 1
        while i < args.size
          word = args[i]
          i += 1
          return string_at(args, i) if word.is_a?(String) && word.compare("STREAMS", case_insensitive: true) == 0
        end
        nil
      when :memory
        sub = args[1]?
        sub.is_a?(String) && sub.compare("USAGE", case_insensitive: true) == 0 ? string_at(args, 2) : nil
      else
        string_at(args, 1)
      end
    end

    private def self.uppercase?(name : String) : Bool
      name.each_byte { |b| return false if 'a'.ord <= b <= 'z'.ord }
      true
    end

    private def self.string_at(args : Indexable, index : Int32) : String?
      value = args[index]?
      value.is_a?(String) ? value : nil
    end

    private def self.key_after_count(args : Indexable, at : Int32) : String?
      count = args[at]?
      n = case count
          when String then count.to_i?
          when Int    then count
          else             nil
          end
      n && n > 0 ? string_at(args, at + 1) : nil
    end
  end
end
