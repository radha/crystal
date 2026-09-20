require "spec"
require "file_utils"
require "socket"
require "redis"

module RedisSpec
  URL = ENV.fetch("REDIS_URL", "redis://localhost:6379")
  DB  = 15

  HELLO_REPLY = "%3\r\n$6\r\nserver\r\n$5\r\nredis\r\n$5\r\nproto\r\n:3\r\n$2\r\nid\r\n:1\r\n"

  # Whether a server answers at URL. Probed once, at load, with a short
  # round trip: a bare TCP connect can appear to succeed on some hosts even
  # with nothing listening (the refusal only surfaces on a later syscall),
  # so this sends a real PING and requires a real reply instead of trusting
  # `connect` alone.
  AVAILABLE = begin
    uri = URI.parse(URL)
    sock = TCPSocket.new(uri.host || "localhost", uri.port || 6379, connect_timeout: 0.2.seconds)
    begin
      sock.read_timeout = 0.2.seconds
      sock << "*1\r\n$4\r\nPING\r\n"
      sock.flush
      reply = Redis::RESP.read(sock)
      reply.is_a?(String) || reply.is_a?(Redis::CommandError)
    ensure
      sock.close
    end
  rescue
    false
  end

  # A scripted RESP server on a random loopback port. The handler runs in
  # its own fiber for every accepted connection and gets the raw socket.
  class FakeServer
    getter port : Int32
    getter accepted = 0

    def initialize(&handler : IO ->)
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.local_address.port
      spawn do
        while client = @server.accept?
          @accepted += 1
          spawn serve(client, handler)
        end
      end
    end

    private def serve(client : TCPSocket, handler : IO ->) : Nil
      handler.call(client)
    rescue IO::Error
    ensure
      client.close rescue nil
    end

    def url : String
      "redis://127.0.0.1:#{@port}"
    end

    def close : Nil
      @server.close
    end

    # Reads one client command (a RESP array of bulk strings). Returns nil at EOF.
    def self.read_command(io : IO) : Array(String)?
      value = Redis::RESP.read(io)
      value.as(Array).map(&.as(String))
    rescue IO::EOFError
      nil
    end

    # If *cmd* is HELLO, answers with `HELLO_REPLY` and returns true.
    def self.serve_hello(io : IO, cmd : Array(String)) : Bool
      return false unless cmd[0]? == "HELLO"
      io << HELLO_REPLY
      io.flush
      true
    end
  end

  # One pub/sub frame as the server sends it: a RESP3 push (`>`) or a
  # RESP2 array (`*`). Strings become bulk strings, integers become
  # integers, nil becomes a null bulk string.
  def self.pubsub_frame(protocol : Int32, *items : String | Int32 | Nil) : String
    String.build do |s|
      s << (protocol == 3 ? '>' : '*') << items.size << "\r\n"
      items.each do |item|
        case item
        when Int32  then s << ':' << item << "\r\n"
        when String then s << '$' << item.bytesize << "\r\n" << item << "\r\n"
        when Nil    then s << "$-1\r\n"
        end
      end
    end
  end

  # Scripted cluster nodes on random loopback ports. Every node answers
  # `HELLO`, and `CLUSTER SLOTS` from `ranges` (`{first, last, node}`
  # triples naming node indexes, plus `replicas` mapping a replica's index
  # to its master's); every other command goes to the handler, which gets
  # the cluster, the node index, the parsed command and the socket. `seen`
  # records every command with its node index in arrival order.
  #
  # Every node serves its connections on fibers of its own, so the command
  # log and the `CLUSTER SLOTS` counter are written from several of them:
  # both are guarded by a lock, and `seen`, `commands` and `slots_calls`
  # read them under it.
  class FakeCluster
    getter servers = [] of FakeServer
    property ranges : Array({Int32, Int32, Int32})
    property replicas = {} of Int32 => Int32
    # The host `CLUSTER SLOTS` reports for every node; `""` makes the
    # fake answer like a node that does not know its own address.
    property host = "127.0.0.1"

    def initialize(count : Int32, @ranges : Array({Int32, Int32, Int32}),
                   &handler : FakeCluster, Int32, Array(String), IO ->)
      @lock = Mutex.new
      @seen = [] of {Int32, Array(String)}
      @slots_calls = 0
      count.times do |index|
        @servers << FakeServer.new do |io|
          while cmd = FakeServer.read_command(io)
            @lock.synchronize do
              @seen << {index, cmd}
              @slots_calls += 1 if cmd[0] == "CLUSTER"
            end
            case cmd[0]
            when "HELLO"
              io << HELLO_REPLY
            when "CLUSTER"
              io << slots_reply
            else
              handler.call(self, index, cmd, io)
            end
            io.flush unless io.closed?
          end
        end
      end
    end

    # Every command every node saw, with its node index, in arrival order.
    def seen : Array({Int32, Array(String)})
      @lock.synchronize { @seen.dup }
    end

    # How many `CLUSTER SLOTS` commands the fake has answered.
    def slots_calls : Int32
      @lock.synchronize { @slots_calls }
    end

    def port(index : Int32) : Int32
      @servers[index].port
    end

    def url(index : Int32) : String
      @servers[index].url
    end

    def urls : Array(String)
      @servers.map(&.url)
    end

    def accepted(index : Int32) : Int32
      @servers[index].accepted
    end

    # Every command node *index* saw except `HELLO`, in order.
    def commands(index : Int32) : Array(Array(String))
      seen.select { |i, _| i == index }.map { |_, cmd| cmd }.reject { |cmd| cmd[0] == "HELLO" }
    end

    def moved(slot : Int32, node : Int32) : String
      "-MOVED #{slot} 127.0.0.1:#{port(node)}\r\n"
    end

    def ask(slot : Int32, node : Int32) : String
      "-ASK #{slot} 127.0.0.1:#{port(node)}\r\n"
    end

    def self.bulk(s : String) : String
      "$#{s.bytesize}\r\n#{s}\r\n"
    end

    # The RESP `CLUSTER SLOTS` reply for `ranges` and `replicas`.
    def slots_reply : String
      String.build do |s|
        s << '*' << @ranges.size << "\r\n"
        @ranges.each do |first, last, node|
          followers = @replicas.select { |_, master| master == node }.keys
          s << '*' << 3 + followers.size << "\r\n:" << first << "\r\n:" << last << "\r\n"
          ([node] + followers).each do |n|
            s << "*3\r\n" << FakeCluster.bulk(@host) << ':' << port(n) << "\r\n" << FakeCluster.bulk("node#{n}")
          end
        end
      end
    end

    def close : Nil
      @servers.each(&.close)
    end
  end

  # A three-master cluster for the live cluster specs, spawned on first
  # use from `valkey-server` or `redis-server` on `PATH`: three random
  # loopback ports, a temp dir, slots split evenly, `CLUSTER MEET`, and a
  # wait for `cluster_state:ok` on every node; terminated at exit. Set
  # `REDIS_CLUSTER_URL` to a comma-separated list of seeds to use an
  # existing cluster instead. `failure` explains why none is available.
  class LiveCluster
    @@instance : LiveCluster?
    @@failure : String?

    getter urls : Array(String)
    @processes : Array(Process)
    @dir : String?

    def self.instance : LiveCluster?
      return @@instance if @@instance
      return nil if @@failure
      if env = ENV["REDIS_CLUSTER_URL"]?
        return @@instance = new(env.split(','), [] of Process, nil)
      end
      @@instance = spawn_local
    rescue ex
      @@failure = ex.message
      nil
    end

    def self.failure : String
      @@failure || "not started"
    end

    def initialize(@urls : Array(String), @processes : Array(Process), @dir : String?)
    end

    private def self.spawn_local : LiveCluster
      binary = Process.find_executable("valkey-server") || Process.find_executable("redis-server") ||
               raise "no valkey-server or redis-server on PATH"
      ports = free_ports(3)
      dir = File.tempname("redis-cluster")
      Dir.mkdir_p(dir)
      processes = ports.map do |port|
        node_dir = File.join(dir, port.to_s)
        Dir.mkdir_p(node_dir)
        Process.new(binary, ["--port", port.to_s, "--cluster-enabled", "yes", "--cluster-config-file", "nodes.conf",
                             "--dir", node_dir, "--save", "", "--appendonly", "no", "--bind", "127.0.0.1",
                             "--logfile", "log.txt"],
          output: Process::Redirect::Close, error: Process::Redirect::Close)
      end
      cluster = new(ports.map { |port| "redis://127.0.0.1:#{port}" }, processes, dir)
      at_exit { cluster.stop }
      begin
        cluster.configure(ports)
      rescue ex
        cluster.stop
        raise ex
      end
      cluster
    end

    # *count* free loopback ports for cluster nodes. A node also listens
    # on the cluster bus port `port + 10000`, so both must be free and a
    # node whose port is above 55535 refuses to start at all; the
    # ephemeral ports the kernel hands out for port 0 are all above that,
    # so the ports are probed upwards from a random low base instead.
    # Every socket is held until all of them are picked, so no two nodes
    # can be given the same port.
    private def self.free_ports(count : Int32) : Array(Int32)
      held = [] of TCPServer
      ports = [] of Int32
      begin
        port = Random.rand(20000..40000)
        while ports.size < count
          raise "no free port and cluster bus port below 55536" if port > 55535
          node = bind(port)
          bus = node ? bind(port + 10000) : nil
          if node && bus
            held << node << bus
            ports << port
          else
            node.try &.close
          end
          port += 1
        end
      ensure
        held.each(&.close)
      end
      ports
    end

    private def self.bind(port : Int32) : TCPServer?
      TCPServer.new("127.0.0.1", port)
    rescue Socket::BindError
      nil
    end

    # Assigns the slots, meets the nodes and waits for convergence.
    def configure(ports : Array(Int32)) : Nil
      conns = ports.map { |port| wait_for(port) }
      begin
        step = Redis::Cluster::SLOTS // ports.size
        conns.each_with_index do |conn, i|
          first = i * step
          last = i == ports.size - 1 ? Redis::Cluster::SLOTS - 1 : (i + 1) * step - 1
          conn.call("CLUSTER", "ADDSLOTSRANGE", first, last)
        end
        ports[1..].each { |port| conns[0].call("CLUSTER", "MEET", "127.0.0.1", port) }
        started = Time.instant
        until conns.all? { |conn| conn.call("CLUSTER", "INFO").as(String).includes?("cluster_state:ok") }
          raise "cluster did not converge within 15 s" if Time.instant - started > 15.seconds
          sleep 100.milliseconds
        end
      ensure
        conns.each(&.close)
      end
    end

    private def wait_for(port : Int32) : Redis::Connection
      started = Time.instant
      loop do
        begin
          return Redis::Connection.new("redis://127.0.0.1:#{port}", connect_timeout: 1.second)
        rescue Redis::ConnectionError
          raise "node on port #{port} did not start within 5 s" if Time.instant - started > 5.seconds
          sleep 50.milliseconds
        end
      end
    end

    # Terminates the nodes and removes their directory. Idempotent.
    def stop : Nil
      @processes.each do |process|
        process.terminate rescue nil
        process.wait rescue nil
      end
      @processes.clear
      if dir = @dir
        FileUtils.rm_rf(dir) rescue nil
        @dir = nil
      end
    end
  end
end

def pending_redis(description = "assert", file = __FILE__, line = __LINE__, end_line = __END_LINE__, &block)
  if RedisSpec::AVAILABLE
    it(description, file, line, end_line, &block)
  else
    pending("#{description} [no redis server at #{RedisSpec::URL}]", file, line, end_line)
  end
end

# Like `it`, but the example is pending when no live cluster is available;
# the block receives the `RedisSpec::LiveCluster` (spawned on first use).
def pending_cluster(description = "assert", file = __FILE__, line = __LINE__, end_line = __END_LINE__,
                    &block : RedisSpec::LiveCluster ->)
  it(description, file, line, end_line) do
    cluster = RedisSpec::LiveCluster.instance
    pending!("no cluster: #{RedisSpec::LiveCluster.failure}", file, line) unless cluster
    block.call(cluster)
  end
end
