require "spec"
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
end

def pending_redis(description = "assert", file = __FILE__, line = __LINE__, end_line = __END_LINE__, &block)
  if RedisSpec::AVAILABLE
    it(description, file, line, end_line, &block)
  else
    pending("#{description} [no redis server at #{RedisSpec::URL}]", file, line, end_line)
  end
end
