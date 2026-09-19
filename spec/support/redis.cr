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
end

def pending_redis(description = "assert", file = __FILE__, line = __LINE__, end_line = __END_LINE__, &block)
  if RedisSpec::AVAILABLE
    it(description, file, line, end_line, &block)
  else
    pending("#{description} [no redis server at #{RedisSpec::URL}]", file, line, end_line)
  end
end
