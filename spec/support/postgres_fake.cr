require "spec"
require "socket"
require "base64"
require "digest/sha256"
require "openssl/hmac"
require "openssl/pkcs5"
require "postgres"

module PostgresSpec
  # A scripted PostgreSQL backend on a random loopback port, for protocol
  # cases a real server cannot easily produce. The handler runs in its own
  # fiber for every accepted connection and gets a `FakeServer::Peer`.
  #
  # Every frontend message a peer reads is appended to `#received`, so an
  # example can check what the client sent once its call returned.
  class FakeServer
    getter port : Int32
    getter accepted = 0
    # Every frontend message read, from all connections, in order.
    getter received = [] of {Char, Bytes}
    # Exceptions the handlers raised (other than the socket going away).
    getter errors = [] of Exception
    # The answer to an `SSLRequest`: a byte, or nil to close the socket.
    property ssl_answer : Char? = 'N'

    @closed = false
    @peers = [] of TCPSocket

    def initialize(&@handler : Peer ->)
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.local_address.port
      spawn do
        while client = @server.accept?
          @accepted += 1
          @peers << client
          spawn serve(client)
        end
      end
    end

    # Runs the block with a server using *handler*, then closes it and
    # re-raises the first exception a handler raised.
    def self.open(handler : Peer ->, & : FakeServer ->) : Nil
      server = new(&handler)
      begin
        yield server
      ensure
        server.close
      end
      server.errors.first?.try { |ex| raise ex }
    end

    private def serve(client : TCPSocket) : Nil
      @handler.call(Peer.new(client, self))
    rescue ex
      @errors << ex unless @closed || ex.is_a?(IO::Error)
    ensure
      client.close rescue nil
    end

    # A URL for this server with *sslmode* and extra query parameters.
    def url(sslmode : String = "disable", **params) : String
      query = String.build do |s|
        s << "sslmode=" << sslmode
        params.each { |k, v| s << '&' << k << '=' << v }
      end
      "postgres://tester@127.0.0.1:#{@port}/db?#{query}"
    end

    # Like `#url`, with *password* in the userinfo.
    def url_with_password(password : String, sslmode : String = "disable") : String
      "postgres://tester:#{URI.encode_www_form(password)}@127.0.0.1:#{@port}/db?sslmode=#{sslmode}"
    end

    # The types of the frontend messages read so far.
    def received_types : Array(Char)
      @received.map(&.[0])
    end

    def close : Nil
      @closed = true
      @server.close rescue nil
      @peers.each { |p| p.close rescue nil }
    end

    # One accepted connection.
    class Peer
      getter socket : TCPSocket
      # Startup parameters (`user`, `database`, ...), once read.
      getter startup_params = {} of String => String
      # Whether the client sent an `SSLRequest`.
      getter? ssl_requested = false

      def initialize(@socket : TCPSocket, @server : FakeServer)
      end

      # Reads the startup packet, answering an `SSLRequest` first with the
      # server's `ssl_answer` (or closing the socket when that is nil).
      # Returns false if the socket was closed.
      def read_startup : Bool
        loop do
          length = @socket.read_bytes(Int32, IO::ByteFormat::BigEndian)
          code = @socket.read_bytes(Int32, IO::ByteFormat::BigEndian)
          if length == 8 && code == Postgres::Messages::SSL_REQUEST_CODE
            @ssl_requested = true
            if answer = @server.ssl_answer
              @socket.write_byte(answer.ord.to_u8)
              @socket.flush
              next
            else
              @socket.close
              return false
            end
          end
          raise "bad protocol version #{code}" unless code == Postgres::Messages::PROTOCOL_VERSION
          body = Bytes.new(length - 8)
          @socket.read_fully(body)
          strings = FakeServer.cstrings(body)
          strings.each_slice(2) { |pair| @startup_params[pair[0]] = pair[1] if pair.size == 2 }
          return true
        end
      end

      # Reads one frontend message: its type and body.
      def read_message : {Char, Bytes}
        type = @socket.read_byte || raise IO::EOFError.new
        length = @socket.read_bytes(Int32, IO::ByteFormat::BigEndian)
        body = Bytes.new(length - 4)
        @socket.read_fully(body)
        @server.received << {type.chr, body}
        {type.chr, body}
      end

      # Reads one message and checks its type.
      def expect(type : Char) : Bytes
        got, body = read_message
        raise "expected #{type.inspect} from the client, got #{got.inspect}" unless got == type
        body
      end

      # Reads messages up to and including `Sync`; returns them.
      def read_until_sync : Array({Char, Bytes})
        batch = [] of {Char, Bytes}
        loop do
          message = read_message
          batch << message
          return batch if message[0] == 'S'
        end
      end

      # Writes a message with type byte *type* and *body*.
      def send(type : Char, body : Bytes = Bytes.empty) : Nil
        @socket.write_byte(type.ord.to_u8)
        @socket.write_bytes(body.size + 4, IO::ByteFormat::BigEndian)
        @socket.write(body)
        @socket.flush
      end

      # Writes raw bytes as they are.
      def send_raw(bytes : Bytes) : Nil
        @socket.write(bytes)
        @socket.flush
      end

      def close : Nil
        @socket.close
      end

      # --- backend messages --------------------------------------------

      def auth(code : Int32, extra : Bytes = Bytes.empty) : Nil
        send('R', FakeServer.build { |io| io.write_bytes(code, IO::ByteFormat::BigEndian); io.write(extra) })
      end

      def auth_ok : Nil
        auth(0)
      end

      def parameter_status(name : String, value : String) : Nil
        send('S', FakeServer.build { |io| io << name << '\0' << value << '\0' })
      end

      def backend_key_data(pid : Int32 = 4242, secret : Int32 = 99) : Nil
        send('K', FakeServer.build do |io|
          io.write_bytes(pid, IO::ByteFormat::BigEndian)
          io.write_bytes(secret, IO::ByteFormat::BigEndian)
        end)
      end

      def ready(status : Char = 'I') : Nil
        send('Z', Bytes[status.ord.to_u8])
      end

      def error(fields : Hash(Char, String)) : Nil
        send('E', FakeServer.fields(fields))
      end

      def notice(fields : Hash(Char, String)) : Nil
        send('N', FakeServer.fields(fields))
      end

      def parse_complete : Nil
        send('1')
      end

      def bind_complete : Nil
        send('2')
      end

      def close_complete : Nil
        send('3')
      end

      def no_data : Nil
        send('n')
      end

      def empty_query : Nil
        send('I')
      end

      def parameter_description(oids : Array(UInt32)) : Nil
        send('t', FakeServer.build do |io|
          io.write_bytes(oids.size.to_i16, IO::ByteFormat::BigEndian)
          oids.each { |oid| io.write_bytes(oid, IO::ByteFormat::BigEndian) }
        end)
      end

      # *columns* are name and type OID pairs (text format).
      def row_description(columns : Array({String, UInt32})) : Nil
        send('T', FakeServer.build do |io|
          io.write_bytes(columns.size.to_i16, IO::ByteFormat::BigEndian)
          columns.each do |name, oid|
            io << name << '\0'
            io.write_bytes(0_u32, IO::ByteFormat::BigEndian) # table oid
            io.write_bytes(0_i16, IO::ByteFormat::BigEndian) # column
            io.write_bytes(oid, IO::ByteFormat::BigEndian)
            io.write_bytes(-1_i16, IO::ByteFormat::BigEndian) # size
            io.write_bytes(-1_i32, IO::ByteFormat::BigEndian) # modifier
            io.write_bytes(0_i16, IO::ByteFormat::BigEndian)  # format
          end
        end)
      end

      def data_row(values : Array(Bytes?)) : Nil
        send('D', FakeServer.build do |io|
          io.write_bytes(values.size.to_i16, IO::ByteFormat::BigEndian)
          values.each do |v|
            if v
              io.write_bytes(v.size, IO::ByteFormat::BigEndian)
              io.write(v)
            else
              io.write_bytes(-1_i32, IO::ByteFormat::BigEndian)
            end
          end
        end)
      end

      def command_complete(tag : String) : Nil
        send('C', FakeServer.build { |io| io << tag << '\0' })
      end

      # The startup parameters every session gets; `integer_datetimes=on`
      # is required by the client.
      def default_parameters : Nil
        parameter_status("server_version", "16.4 (Fake)")
        parameter_status("integer_datetimes", "on")
        parameter_status("server_encoding", "UTF8")
      end

      # Reads the startup packet and completes a trust login.
      def handshake(status : Char = 'I') : Nil
        read_startup || raise IO::EOFError.new("client went away during SSLRequest")
        auth_ok
        default_parameters
        backend_key_data
        ready(status)
      end

      # --- extended protocol replies -----------------------------------

      # Answers a `Parse`/`Describe`/`Sync` batch (plus any `Close`s ahead
      # of it) for a statement with *params* and result *columns* (none:
      # `NoData`).
      def answer_prepare(batch : Array({Char, Bytes}), params : Array(UInt32) = [] of UInt32,
                         columns : Array({String, UInt32}) = [] of {String, UInt32}, status : Char = 'I') : Nil
        batch.each do |type, _|
          case type
          when 'C' then close_complete
          when 'P' then parse_complete
          when 'D'
            parameter_description(params)
            columns.empty? ? no_data : row_description(columns)
          when 'S' then ready(status)
          end
        end
      end

      # Answers a `Bind`/`Execute`/`Sync` batch (plus any `Close`s ahead of
      # it) with *rows* and command *tag*.
      def answer_execute(batch : Array({Char, Bytes}), rows : Array(Array(Bytes?)) = [] of Array(Bytes?),
                         tag : String = "SELECT #{rows.size}", status : Char = 'I') : Nil
        batch.each do |type, _|
          case type
          when 'C' then close_complete
          when 'B' then bind_complete
          when 'E'
            rows.each { |r| data_row(r) }
            command_complete(tag)
          when 'S' then ready(status)
          end
        end
      end

      # Serves one query of the extended protocol whether or not the client
      # prepares it first. Returns the batches read.
      def serve_query(params : Array(UInt32) = [] of UInt32, columns : Array({String, UInt32}) = [] of {String, UInt32},
                      rows : Array(Array(Bytes?)) = [] of Array(Bytes?), tag : String = "SELECT #{rows.size}",
                      status : Char = 'I') : Nil
        batch = read_until_sync
        if batch.any? { |m| m[0] == 'P' }
          answer_prepare(batch, params, columns, status)
          batch = read_until_sync
        end
        answer_execute(batch, rows, tag, status)
      end
    end

    # --- encoding helpers ------------------------------------------------

    def self.build(& : IO::Memory ->) : Bytes
      io = IO::Memory.new
      yield io
      io.to_slice
    end

    def self.fields(fields : Hash(Char, String)) : Bytes
      build do |io|
        fields.each { |code, value| io << code << value << '\0' }
        io.write_byte(0_u8)
      end
    end

    def self.cstrings(body : Bytes) : Array(String)
      list = String.new(body).split('\0')
      while list.last?.try(&.empty?)
        list.pop
      end
      list
    end

    # The first cstring of *body*.
    def self.cstring(body : Bytes, offset : Int32 = 0) : String
      stop = body.index(0_u8, offset) || body.size
      String.new(body[offset, stop - offset])
    end

    def self.int4(value : Int32) : Bytes
      build { |io| io.write_bytes(value, IO::ByteFormat::BigEndian) }
    end

    def self.text(value : String) : Bytes
      value.to_slice
    end

    # The statement name of a `Bind` body.
    def self.bind_statement(body : Bytes) : String
      portal_end = body.index(0_u8) || 0
      cstring(body, portal_end + 1)
    end

    # --- SCRAM-SHA-256, server side -------------------------------------

    # The server half of a SCRAM-SHA-256 exchange for *password*, with a
    # fixed salt and iteration count.
    class ScramServer
      SALT       = "fake-salt-bytes!".to_slice
      ITERATIONS = 4096

      getter server_first = ""
      @client_first_bare = ""
      @salted = Bytes.empty

      def initialize(@password : String)
        @salted = OpenSSL::PKCS5.pbkdf2_hmac(@password, SALT, iterations: ITERATIONS, algorithm: OpenSSL::Algorithm::SHA256, key_size: 32)
      end

      # Takes the client-first-message; returns the server-first-message.
      def first(client_first : String) : String
        raise "no GS2 header: #{client_first}" unless client_first.starts_with?("n,,")
        @client_first_bare = client_first[3..]
        nonce = @client_first_bare.split(',').find!(&.starts_with?("r="))[2..]
        @server_first = "r=#{nonce}SERVERNONCE,s=#{Base64.strict_encode(SALT)},i=#{ITERATIONS}"
      end

      # Takes the client-final-message; checks the proof and returns the
      # server signature (Base64), or nil when the proof is wrong.
      def final(client_final : String) : String?
        without_proof, _, proof64 = client_final.rpartition(",p=")
        auth_message = "#{@client_first_bare},#{@server_first},#{without_proof}"
        client_key = hmac(@salted, "Client Key")
        stored_key = Digest::SHA256.digest(client_key)
        signature = hmac(stored_key, auth_message)
        proof = Base64.decode(proof64)
        recovered = Bytes.new(proof.size) { |i| proof[i] ^ signature[i] }
        return nil unless Digest::SHA256.digest(recovered) == stored_key
        Base64.strict_encode(hmac(hmac(@salted, "Server Key"), auth_message))
      end

      private def hmac(key, data) : Bytes
        OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, key, data)
      end
    end
  end
end
