module Redis
  # A client for Redis Cluster: routes every command to the master that
  # owns its key's hash slot, follows `MOVED`, `ASK` and `TRYAGAIN`
  # redirects, and reloads the slot map when the cluster changes. Each
  # master is driven by its own multiplexed `Client`, so any number of
  # fibers can share a `Cluster`.
  #
  # ```
  # cluster = Redis::Cluster.new(["redis://10.0.0.1:7000", "redis://10.0.0.2:7000"])
  # cluster.set("user:1", "x")
  # cluster.get("user:1")                            # => "x"
  # cluster.pipelined { |p| p.get("a"); p.get("b") } # split by node, replies in order
  # cluster.multi { |tx| tx.incr("{acct}a"); tx.incr("{acct}b") }
  # cluster.close
  # ```
  #
  # Keyed commands are routed by `Cluster.route_key`; commands with no key
  # (`PING`, `INFO`, `DBSIZE`, ...) go to one master picked at random, and
  # `nodes` gives every node's own `Client` for per-node administration.
  # Multi-key commands must keep their keys in one slot (use hash tags):
  # the server's `CROSSSLOT` error is raised as a `CommandError` otherwise.
  # `scan_each` iterates every master in turn; a bare `scan` step lands on
  # a random master and is of little use here. `run` shares one script
  # cache across the cluster: a script one node has not seen yet answers
  # `NOSCRIPT` there, which `run` handles by sending `EVAL`.
  #
  # The slot map is loaded on the first command and reloaded lazily: a
  # `MOVED` reply or a lost connection marks it stale and the next command
  # reloads it before routing, with concurrent callers sharing one reload.
  # A lost connection is never retried, exactly as with `Client`;
  # redirects are followed up to `max_redirects` times, then
  # `ClusterError` is raised. Replicas are listed in `nodes` but never
  # routed to.
  #
  # `close` is required, as for `Client`.
  class Cluster
    include Commands
    include Commands::ScriptFallback

    # :nodoc:
    getter script_cache = ScriptCache.new

    # :nodoc:
    REDIRECT_CODES = {"MOVED", "ASK", "TRYAGAIN"}

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

    # One node of the cluster as the last topology load reported it.
    class Node
      # The host as reported by `CLUSTER SLOTS`.
      getter host : String
      # The port.
      getter port : Int32
      # The cluster node id (`""` for a node first seen in a redirect,
      # until the next reload).
      getter id : String
      # Whether the node is a master; only masters are routed to.
      getter? master : Bool
      @client : Client?
      # Guards `@client` and `@closed`: a fiber that holds a `Node` can
      # ask for its client at any time, including while another fiber is
      # closing the node or the whole cluster.
      @client_mutex = Mutex.new
      @closed = false

      # :nodoc:
      def initialize(@host : String, @port : Int32, @id : String, @master : Bool,
                     @factory : Proc(String, Int32, Client))
      end

      # `"host:port"`.
      def address : String
        "#{@host}:#{@port}"
      end

      # The node's multiplexed client, created on first use with the
      # cluster's options and connected on its first command. Raises
      # `ArgumentError` on a replica and `ConnectionError` once the node
      # has been closed (because the cluster was closed, or because a
      # topology reload dropped or demoted the node): a client created
      # then would be reachable by nobody and never closed.
      def client : Client
        raise ArgumentError.new("#{address} is a replica") unless @master
        @client_mutex.synchronize do
          raise ConnectionError.new("#{address} is closed") if @closed
          @client ||= @factory.call(@host, @port)
        end
      end

      # :nodoc:
      def master=(@master : Bool)
      end

      # :nodoc:
      def id=(@id : String)
      end

      # :nodoc:
      #
      # Closes the node's client, if it opened one, and refuses to make
      # another. The client is closed outside the node's mutex.
      def close : Nil
        existing = @client_mutex.synchronize do
          @closed = true
          current, @client = @client, nil
          current
        end
        existing.try &.close
      end

      # :nodoc:
      #
      # Lets the node open a client again, for a node a reload kept (or
      # brought back) as a master after an earlier close.
      def reopen : Nil
        @client_mutex.synchronize { @closed = false }
      end

      # Appends `"host:port (master)"` or `"host:port (replica)"` to *io*.
      def to_s(io : IO) : Nil
        io << address << (@master ? " (master)" : " (replica)")
      end
    end

    @mutex = Mutex.new
    @refresh_mutex = Mutex.new
    @slots = Array(Node?).new(SLOTS, nil)
    @nodes = {} of String => Node
    @masters = [] of Node
    @stale = true
    @closed = false
    @seeds : Array(URI)
    @scheme : String
    @username : String?
    @password : String?

    # Creates a cluster client. *seeds* are `redis://host:port` or
    # `rediss://host:port` URLs (`String` or `URI`) of any nodes; the rest
    # of the cluster is discovered from whichever answers first, and the
    # seeds' scheme (with *tls_context*) is used for every node. The other
    # options are those of `Client.new` and apply to every node's client;
    # there is no `db` because a cluster has only database 0. Credentials
    # in the first seed's URL are used when *username*/*password* are not
    # given. Nothing is connected until the first command. Raises
    # `ArgumentError` for no seeds, a seed with another scheme or a
    # database other than 0, *protocol* outside `2..3`, a non-positive
    # *pool_size* or a negative *max_redirects*.
    def initialize(seeds : Indexable, *, username : String? = nil, password : String? = nil,
                   @client_name : String? = nil, protocol @protocol_option : Int32 = 3,
                   @connect_timeout : Time::Span = 5.seconds, @read_timeout : Time::Span? = nil,
                   @tls_context : OpenSSL::SSL::Context::Client? = nil, @max_bulk_size : Int32 = RESP::MAX_BULK_SIZE,
                   @pool_size : Int32 = 4, @max_redirects : Int32 = 5)
      raise ArgumentError.new("at least one seed is required") if seeds.empty?
      raise ArgumentError.new("protocol must be 2 or 3, got #{@protocol_option}") unless @protocol_option == 2 || @protocol_option == 3
      raise ArgumentError.new("pool_size must be positive, got #{@pool_size}") unless @pool_size > 0
      raise ArgumentError.new("max_redirects must not be negative, got #{@max_redirects}") if @max_redirects < 0
      @seeds = Array(URI).new(seeds.size)
      seeds.each do |seed|
        uri = case seed
              when URI    then seed
              when String then URI.parse(seed)
              else             raise ArgumentError.new("a seed must be a String or URI, got #{seed.class}")
              end
        unless uri.scheme == "redis" || uri.scheme == "rediss"
          raise ArgumentError.new("unsupported cluster URL scheme #{uri.scheme.inspect} in #{uri}; expected redis or rediss")
        end
        if (db = Connection.db_from(uri)) && db != 0
          raise ArgumentError.new("a cluster has only database 0, got database #{db} in #{uri}")
        end
        @seeds << uri
      end
      @scheme = @seeds.first.scheme.not_nil!
      @username = username || @seeds.first.user.presence
      @password = password || @seeds.first.password.presence
    end

    # :ditto:
    def self.new(seed : String | URI, **options)
      new([seed] of String | URI, **options)
    end

    # Sends *args* to the master owning the routing key's slot (see
    # `Cluster.route_key`; *key* overrides it) and returns the reply,
    # following redirects. Raises `CommandError` for an error reply,
    # `ConnectionError` if a node's connection cannot be opened or drops,
    # `IO::TimeoutError` if `read_timeout` elapses, `ClusterError` if the
    # topology cannot be loaded or `max_redirects` is exceeded.
    def call(*args : RESP::Arg) : Value
      call(args)
    end

    # :ditto:
    def call(args : Indexable, *, key : String? = nil) : Value
      route = key || Cluster.route_key(args)
      slot = route ? Cluster.key_slot(route) : nil
      execute(slot) { |node, asking| asking ? ask(node, args) : node.client.call(args) }
    end

    # Sends an arbitrary command routed by *key*, for a command whose key
    # `Cluster.route_key` does not find (a module command, for example).
    #
    # ```
    # cluster.command("MYMODULE.DO", "k", 1, key: "k")
    # ```
    def command(*args : RESP::Arg, key : String) : Value
      call(args, key: key)
    end

    # :nodoc:
    def typed_call(args : Indexable, &block : Value -> T) forall T
      block.call(call(args))
    end

    # Runs the block against a `Pipeline`, sends every node its commands in
    # one write with the nodes in parallel, and returns the raw replies in
    # the order the block queued them. Commands are grouped by the master
    # owning their key's slot; keyless commands all go to one master.
    # Error replies stay in the array as `CommandError` values (and are
    # raised by the matching `Future#value`). A `MOVED`, `ASK` or
    # `TRYAGAIN` reply to a single command is followed for that command
    # alone; a `multi` block stays on its node and a redirect at queue
    # time fails it with `EXECABORT` like any queue-time error. A lost
    # connection or `read_timeout` on one node fails that node's futures
    # with it while the other nodes' replies are kept, then the first such
    # failure is raised once every node has answered.
    #
    # ```
    # first = nil
    # cluster.pipelined do |p|
    #   p.set("a", "1")
    #   first = p.get("b")
    # end
    # first.not_nil!.value
    # ```
    def pipelined(& : Pipeline ->) : Array(Value)
      pipeline = Pipeline.new(@script_cache, routing: true)
      yield pipeline
      check_open
      size = pipeline.size
      return [] of Value if size == 0
      refresh_if_stale
      routes = pipeline.routes
      offsets = pipeline.offsets
      bytes = pipeline.buffer.to_slice
      groups = {} of Node => Array(Int32)
      order = [] of Node
      @mutex.synchronize do
        raise ClusterError.new("cluster has no masters") if @masters.empty?
        fallback = @masters.sample
        size.times do |i|
          key = routes[i].key
          node = (key ? @slots[Cluster.key_slot(key)] : nil) || fallback
          indices = groups[node]?
          unless indices
            indices = groups[node] = [] of Int32
            order << node
          end
          indices << i
        end
      end
      values = Array(Value).new(size, nil)
      failures = Array(Exception?).new(size, nil)
      wg = WaitGroup.new
      order.each_with_index do |node, position|
        indices = groups[node]
        if position == order.size - 1
          run_group(node, indices, bytes, offsets, values, failures)
        else
          wg.add(1)
          spawn do
            begin
              run_group(node, indices, bytes, offsets, values, failures)
            ensure
              wg.done
            end
          end
        end
      end
      wg.wait
      size.times do |i|
        next if failures[i]
        value = values[i]
        next unless value.is_a?(CommandError) && routes[i].retry && REDIRECT_CODES.includes?(value.code)
        slot = routes[i].key.try { |key| Cluster.key_slot(key) }
        command = bytes[offsets[i], command_end(offsets, i, bytes.size) - offsets[i]]
        begin
          values[i] = execute(slot, value) { |node, asking| node.client.call_raw(command, asking) }
        rescue ex : CommandError
          values[i] = ex
        rescue ex : ClusterError | ConnectionError | IO::TimeoutError
          failures[i] = ex
        end
      end
      results = Array(Value).new(size)
      first_failure = nil
      size.times do |i|
        if error = failures[i]
          pipeline.fail(i, error)
          first_failure ||= error
        else
          pipeline.resolve(i, values[i])
          results << values[i]
        end
      end
      raise first_failure if first_failure
      results
    end

    # Runs the block's commands as one `MULTI`..`EXEC` transaction on the
    # master owning the first keyed command's slot, in one write, and
    # returns the `EXEC` array; every key must be in that slot (hash tags).
    # Raises `AbortedError` if a key marked with `watch` changed, the
    # `EXECABORT` `CommandError` if a command was rejected at queue time
    # (a `MOVED` at queue time included), `ConnectionError` if the socket
    # drops. Error replies inside the array stay values; the matching
    # command's future raises them.
    #
    # ```
    # cluster.multi { |tx| tx.incr("{acct}a"); tx.incr("{acct}b") } # => [1_i64, 1_i64]
    # ```
    def multi(&block : Transaction ->) : Array(Value)
      exec = nil
      pipelined { |p| exec = p.multi(&block) }
      exec.not_nil!.value
    end

    # Borrows a dedicated `Connection` to the master owning *key*'s slot
    # (from that node client's pool, see `Client#with_connection`), yields
    # it, and hands it back. For blocking commands:
    #
    # ```
    # cluster.with_connection("jobs") { |conn| conn.call("BLPOP", "jobs", 0) }
    # ```
    #
    # Redirects are not followed inside the block: a `MOVED` or `ASK`
    # reply is raised as a `CommandError`, and the caller retries the block.
    def with_connection(key : String, &block : Connection -> T) : T forall T
      check_open
      node = route(Cluster.key_slot(key))
      node.client.with_connection(&block)
    end

    # Raises `ArgumentError`: `watch` needs at least one key.
    def watch(&block : Connection -> T) : T forall T
      raise ArgumentError.new("WATCH needs at least one key")
    end

    # Optimistic locking on the master owning *keys*' slot: borrows a
    # dedicated connection there, sends `WATCH`, yields the connection
    # for the read-then-`multi` sequence, and hands it back (see
    # `Client#watch`). Every key must hash to one slot (use hash tags);
    # raises `ArgumentError` otherwise. Redirects are not followed inside
    # the block: a `MOVED` or `ASK` reply is raised as a `CommandError`,
    # and the caller retries the block just as for `AbortedError`.
    def watch(*keys : String, &block : Connection -> T) : T forall T
      check_open
      slot = Cluster.key_slot(keys[0])
      keys.each do |key|
        unless Cluster.key_slot(key) == slot
          raise ArgumentError.new("WATCH keys must hash to one slot; #{key.inspect} is not in slot #{slot}")
        end
      end
      route(slot).client.watch(*keys, &block)
    end

    # Opens a `Subscriber` on one master, chosen at random, with the
    # cluster's options; the cluster bus delivers every `publish` to it
    # whichever node received the message. Its reconnects go back to the
    # same node. The subscriber is independent of the cluster afterwards
    # and must be closed on its own.
    def subscriber(*, capacity : Int32 = 64, reconnect : Bool = true) : Subscriber
      check_open
      route(nil).client.subscriber(capacity: capacity, reconnect: reconnect)
    end

    # Copies the group's commands out of *bytes* and runs them on *node*,
    # storing each reply or failure at its original index. A reply
    # `pipeline_raw` already delivered is kept; only the commands it never
    # reached are failed, with whatever it raised (a lost connection or
    # timeout, or an error from a reconnect's handshake). A connection
    # loss or timeout also marks the slot map stale. Never raises: this
    # runs on a fiber of its own for every group but the last.
    private def run_group(node : Node, indices : Array(Int32), bytes : Bytes, offsets : Array(Int32),
                          values : Array(Value), failures : Array(Exception?)) : Nil
      reached = 0
      chunk = IO::Memory.new
      indices.each do |i|
        chunk.write(bytes[offsets[i], command_end(offsets, i, bytes.size) - offsets[i]])
      end
      node.client.pipeline_raw(chunk.to_slice, indices.size) do |j, value, error|
        i = indices[j]
        values[i] = value
        failures[i] = error
        reached = j + 1
      end
    rescue ex : Exception
      @mutex.synchronize { @stale = true } if ex.is_a?(ConnectionError) || ex.is_a?(IO::TimeoutError)
      (reached...indices.size).each { |j| failures[indices[j]] ||= ex }
    end

    # The byte offset just past command *i*.
    private def command_end(offsets : Array(Int32), i : Int32, total : Int32) : Int32
      i + 1 < offsets.size ? offsets[i + 1] : total
    end

    # Iterates every key matching *match* on every master in turn. `SCAN`
    # cursors are per node, so this is the only sensible form of `SCAN`
    # on a cluster.
    def scan_each(*, match : String? = nil, count : Int? = nil, type : String? = nil, & : String ->) : Nil
      check_open
      refresh_if_stale
      masters = @mutex.synchronize { @masters.dup }
      masters.each do |node|
        node.client.scan_each(match: match, count: count, type: type) { |key| yield key }
      end
    end

    # Every node the last topology load reported, masters first in the
    # order `CLUSTER SLOTS` listed them. Empty before the first command.
    def nodes : Array(Node)
      @mutex.synchronize { @masters + @nodes.values.reject(&.master?) }
    end

    # The master owning *key*'s slot, after reloading the topology if it is
    # stale. Raises `ClusterError` if the cluster has no masters.
    def node_for(key : String) : Node
      check_open
      route(Cluster.key_slot(key))
    end

    # Reloads the slot map now. Raises `ClusterError` if no known master
    # and no seed answers `CLUSTER SLOTS`.
    def refresh : Nil
      check_open
      @refresh_mutex.synchronize { load_topology }
    end

    # Whether `close` has been called.
    def closed? : Bool
      @closed
    end

    # Closes every node's client. Every later call raises `ConnectionError`.
    def close : Nil
      nodes = @mutex.synchronize do
        @closed = true
        @nodes.values
      end
      nodes.each(&.close)
    end

    private def check_open : Nil
      raise ConnectionError.new("cluster is closed") if @closed
    end

    # The redirect loop. Picks the node for *slot* (any master when nil or
    # unassigned) and calls *send* with it; a `MOVED` reply patches the
    # slot, marks the map stale and retries on the named node; an `ASK`
    # retries there once with the asking flag; a `TRYAGAIN` retries after
    # a growing pause. *redirect* is a redirect reply already received
    # (from a pipeline), processed before the first send.
    #
    # A pending `MOVED` or `ASK` names its own node, so the slot map is
    # not consulted at all in that case: `route` would reload a map that
    # the pipeline's previous redirect has just marked stale, and a
    # pipeline retrying N redirected commands would reload N times. The
    # stale mark still stands, so the next ordinary command reloads once.
    private def execute(slot : Int32?, redirect : CommandError? = nil, & : Node, Bool -> Value) : Value
      check_open
      node = redirect && redirect.code != "TRYAGAIN" ? parse_redirect(redirect)[1] : route(slot)
      asking = false
      attempt = 0
      pending = redirect
      last = nil
      while attempt <= @max_redirects
        error = pending || begin
          return yield node, asking
        rescue ex : CommandError
          ex
        rescue ex : ConnectionError
          @mutex.synchronize { @stale = true }
          raise ex
        end
        pending = nil
        case error.code
        when "MOVED"
          moved_slot, node = parse_redirect(error)
          @mutex.synchronize do
            @slots[moved_slot] = node
            @stale = true
          end
          asking = false
        when "ASK"
          _, node = parse_redirect(error)
          asking = true
        when "TRYAGAIN"
          sleep({10.milliseconds * (1 << {attempt, 6}.min), 500.milliseconds}.min)
        else
          raise error
        end
        last = error
        attempt += 1
      end
      raise ClusterError.new("too many redirects (#{@max_redirects}) for slot #{slot}: #{last.try(&.message)}", cause: last)
    end

    # Sends `ASKING` and *args* contiguously on *node*'s client and returns
    # the command's reply, raising an error reply so the loop can act on
    # a further redirect.
    private def ask(node : Node, args : Indexable) : Value
      replies = node.client.pipelined do |p|
        p.command("ASKING")
        p.command(args)
      end
      value = replies[1]
      raise value if value.is_a?(CommandError)
      value
    end

    # `MOVED 3999 127.0.0.1:6381` → `{3999, node}`; same for `ASK`.
    private def parse_redirect(error : CommandError) : {Int32, Node}
      parts = error.message.to_s.split(' ')
      slot = parts[1]?.try(&.to_i?)
      address = parts[2]?
      unless slot && address && 0 <= slot < SLOTS
        raise ProtocolError.new("malformed redirect #{error.message.inspect}")
      end
      colon = address.rindex(':') || raise ProtocolError.new("malformed redirect #{error.message.inspect}")
      host = address[0, colon]
      port = address[colon + 1..].to_i? || raise ProtocolError.new("malformed redirect #{error.message.inspect}")
      host = @seeds.first.host.presence || "localhost" if host.empty?
      {slot, node_at(host, port)}
    end

    # The known node at *host*:*port*, or a new master node for an address
    # the last reload did not list (the next reload fills in its id).
    private def node_at(host : String, port : Int32) : Node
      address = "#{host}:#{port}"
      @mutex.synchronize do
        @nodes[address] ||= new_node(host, port, "", true)
      end
    end

    # The node for *slot*, any master when *slot* is nil or unassigned,
    # after reloading a stale map. Raises `ClusterError` with no masters.
    private def route(slot : Int32?) : Node
      refresh_if_stale
      @mutex.synchronize do
        raise ClusterError.new("cluster has no masters") if @masters.empty?
        (slot ? @slots[slot] : nil) || @masters.sample
      end
    end

    private def refresh_if_stale : Nil
      return unless @stale
      @refresh_mutex.synchronize { load_topology if @stale }
    end

    # Under `@refresh_mutex`. Asks every known master, then every seed not
    # already tried, for `CLUSTER SLOTS`, and installs the first answer.
    private def load_topology : Nil
      last_error = nil
      masters = @mutex.synchronize { @masters.dup }
      masters.each do |node|
        begin
          install(node.client.call({"CLUSTER", "SLOTS"}), node.host)
          return
        rescue ex : ConnectionError | CommandError | IO::TimeoutError
          last_error = ex
        end
      end
      tried = masters.map(&.address)
      @seeds.each do |seed|
        host = seed.host.presence || "localhost"
        port = seed.port || 6379
        next if tried.includes?("#{host}:#{port}")
        begin
          conn = Connection.new(node_uri(host, port), username: @username, password: @password,
            client_name: @client_name, protocol: @protocol_option, connect_timeout: @connect_timeout,
            read_timeout: @read_timeout, tls_context: @tls_context, max_bulk_size: @max_bulk_size)
          reply = begin
            conn.call({"CLUSTER", "SLOTS"})
          ensure
            conn.close
          end
          install(reply, host)
          return
        rescue ex : ConnectionError | CommandError | IO::TimeoutError
          last_error = ex
        end
      end
      raise ClusterError.new("no cluster node reachable: #{last_error.try(&.message)}", cause: last_error)
    end

    private def node_uri(host : String, port : Int32) : URI
      URI.new(scheme: @scheme, host: host, port: port)
    end

    private def node_client(host : String, port : Int32) : Client
      Client.new(node_uri(host, port), username: @username, password: @password, client_name: @client_name,
        protocol: @protocol_option, connect_timeout: @connect_timeout, read_timeout: @read_timeout,
        tls_context: @tls_context, max_bulk_size: @max_bulk_size, pool_size: @pool_size)
    end

    private def new_node(host : String, port : Int32, id : String, master : Bool) : Node
      Node.new(host, port, id, master, ->node_client(String, Int32))
    end

    # One node exactly as a `CLUSTER SLOTS` reply describes it, before any
    # existing `Node` is consulted.
    private alias Described = NamedTuple(host: String, port: Int32, id: String, master: Bool)

    # Parses a `CLUSTER SLOTS` reply (`[[first, last, [host, port, id, ...],
    # replica...], ...]`) and swaps the topology in, keeping the `Node`
    # objects (and their clients) of addresses already known. *asked_host*
    # stands in for a node whose own address the server left empty. Nodes
    # that disappeared, and masters that turned replica, are closed.
    #
    # The whole reply is parsed into plain descriptions first and no
    # existing `Node` is touched until that succeeded, so a malformed
    # reply leaves the topology exactly as it was. An address listed as
    # the master of any range is a master, whatever a replica entry
    # elsewhere in the reply says about it.
    private def install(reply : Value, asked_host : String) : Nil
      ranges = reply.as?(Array) || raise ProtocolError.new("unexpected CLUSTER SLOTS reply #{reply.inspect}")
      described = {} of String => Described
      master_order = [] of String
      assignments = [] of {Int32, Int32, String?}
      ranges.each do |range|
        entry = range.as?(Array) || raise ProtocolError.new("unexpected CLUSTER SLOTS range #{range.inspect}")
        first = entry[0]?.as?(Int64)
        last = entry[1]?.as?(Int64)
        unless first && last && 0 <= first && first <= last && last < SLOTS
          raise ProtocolError.new("unexpected CLUSTER SLOTS range #{range.inspect}")
        end
        master_address = nil
        entry.each_with_index do |item, i|
          next if i < 2
          desc = item.as?(Array) || raise ProtocolError.new("unexpected CLUSTER SLOTS node #{item.inspect}")
          reported = desc[0]?.as?(String)
          host = reported.nil? || reported.empty? || reported == "?" ? asked_host : reported
          port = desc[1]?.as?(Int64) || raise ProtocolError.new("unexpected CLUSTER SLOTS node #{item.inspect}")
          id = desc[2]?.as?(String) || ""
          address = "#{host}:#{port}"
          is_master = i == 2
          previous = described[address]?
          if previous
            id = previous[:id] if id.empty?
            is_master ||= previous[:master]
          end
          described[address] = {host: host, port: port.to_i, id: id, master: is_master}
          if i == 2
            master_address = address
            master_order << address unless master_order.includes?(address)
          end
        end
        assignments << {first.to_i, last.to_i, master_address}
      end
      gone, demoted = @mutex.synchronize do
        nodes = {} of String => Node
        leaving = [] of Node
        described.each do |address, desc|
          node = @nodes[address]? || new_node(desc[:host], desc[:port], desc[:id], desc[:master])
          node.master = desc[:master]
          node.id = desc[:id] unless desc[:id].empty?
          # A master this reload keeps may have been closed by an earlier
          # one that listed it as a replica, or as gone; it serves
          # commands again, so let it open a client. Never after `close`:
          # nobody would close that client.
          node.reopen if desc[:master] && !@closed
          nodes[address] = node
          leaving << node unless desc[:master]
        end
        slots = Array(Node?).new(SLOTS, nil)
        assignments.each do |first, last, address|
          master = address ? nodes[address] : nil
          (first..last).each { |slot| slots[slot] = master }
        end
        removed = @nodes.values.reject { |node| nodes.has_key?(node.address) }
        @slots = slots
        @nodes = nodes
        @masters = master_order.map { |address| nodes[address] }
        @stale = false
        {removed, leaving}
      end
      gone.each(&.close)
      demoted.each(&.close)
    end
  end
end
