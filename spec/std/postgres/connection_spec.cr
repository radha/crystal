require "../../support/postgres_fake"

# Protocol-level specs for `Postgres::Connection` against a scripted fake
# backend: replies a real server does not easily produce.

private alias Fake = PostgresSpec::FakeServer
private alias Peer = PostgresSpec::FakeServer::Peer

private INT4 = Postgres::OID::INT4
private TEXT = Postgres::OID::TEXT

private def fake(&handler : Peer ->) : Fake
  Fake.new(&handler)
end

# Runs the block, closes *server* and re-raises what a handler raised.
private def using(server : Fake, &) : Nil
  begin
    yield
  ensure
    server.close
  end
  server.errors.first?.try { |ex| raise ex }
end

private def connect(url : String, read_timeout : Time::Span = 2.seconds) : Postgres::Connection
  Postgres::Connection.new(url, read_timeout: read_timeout)
end

private def receive_within(channel : Channel(T), timeout = 2.seconds) : T forall T
  select
  when value = channel.receive
    value
  when timeout(timeout)
    raise "the fake server did not report in time"
  end
end

private def one_int4 : Array({String, UInt32})
  [{"x", INT4}]
end

private def int4_rows(*values : Int32) : Array(Array(Bytes?))
  values.map { |v| [Fake.int4(v).as(Bytes?)] }.to_a
end

# The frontend messages of *type* the server read.
private def received(server : Fake, type : Char) : Array(Bytes)
  server.received.select { |m| m[0] == type }.map(&.[1])
end

private def error_fields(code : String, message : String = "boom") : Hash(Char, String)
  {'S' => "ERROR", 'V' => "ERROR", 'C' => code, 'M' => message}
end

describe Postgres::Connection do
  describe "startup" do
    it "sends user, database and client_encoding and reads the session state" do
      params = Channel(Hash(String, String)).new(1)
      server = fake do |peer|
        peer.read_startup
        params.send(peer.startup_params)
        peer.auth_ok
        peer.default_parameters
        peer.parameter_status("TimeZone", "Etc/UTC")
        peer.backend_key_data(pid: 777)
        peer.ready
      end
      using(server) do
        conn = connect(server.url)
        receive_within(params).should eq({"user" => "tester", "database" => "db", "client_encoding" => "UTF8"})
        conn.backend_pid.should eq(777)
        conn.server_version.should eq(160004)
        conn.parameters["TimeZone"].should eq("Etc/UTC")
        conn.parameters["server_encoding"].should eq("UTF8")
        conn.transaction_status.should eq('I')
        conn.tls?.should be_false
        conn.closed?.should be_false
        conn.close
        conn.closed?.should be_true
      end
      server.accepted.should eq(1)
    end

    it "sends application_name when configured" do
      params = Channel(Hash(String, String)).new(1)
      server = fake do |peer|
        peer.handshake
        params.send(peer.startup_params)
      end
      using(server) do
        conn = connect(server.url(application_name: "specs"))
        receive_within(params)["application_name"].should eq("specs")
        conn.close
      end
    end

    it "refuses a server without integer_datetimes" do
      server = fake do |peer|
        peer.read_startup
        peer.auth_ok
        peer.parameter_status("server_version", "16.4")
        peer.parameter_status("integer_datetimes", "off")
        peer.ready
      end
      using(server) do
        expect_raises(Postgres::ConnectionError, /floating-point datetimes/) { connect(server.url) }
      end
    end

    it "raises AuthenticationError for SQLSTATE 28P01" do
      server = fake do |peer|
        peer.read_startup
        peer.error({'S' => "FATAL", 'V' => "FATAL", 'C' => "28P01", 'M' => "password authentication failed for user \"tester\""})
      end
      using(server) do
        expect_raises(Postgres::AuthenticationError, /28P01.*password authentication failed/) { connect(server.url) }
      end
    end

    it "raises ConnectionError for other startup errors (3D000)" do
      server = fake do |peer|
        peer.read_startup
        peer.error({'S' => "FATAL", 'V' => "FATAL", 'C' => "3D000", 'M' => "database \"db\" does not exist"})
      end
      using(server) do
        ex = expect_raises(Postgres::ConnectionError, /3D000/) { connect(server.url) }
        ex.should_not be_a(Postgres::AuthenticationError)
      end
    end

    it "rejects an unsupported authentication method" do
      server = fake do |peer|
        peer.read_startup
        peer.auth(7) # GSS
      end
      using(server) do
        expect_raises(Postgres::AuthenticationError, /unsupported authentication method 7/) { connect(server.url) }
      end
    end

    it "raises IO::TimeoutError when the server never answers the startup" do
      server = fake do |peer|
        peer.read_startup
        peer.read_message # blocks until the client gives up
      end
      using(server) do
        expect_raises(IO::TimeoutError) { connect(server.url, read_timeout: 100.milliseconds) }
      end
    end
  end

  describe "password authentication" do
    it "sends a cleartext password" do
      password = Channel(String).new(1)
      server = fake do |peer|
        peer.read_startup
        peer.auth(3)
        password.send(Fake.cstring(peer.expect('p')))
        peer.auth_ok
        peer.default_parameters
        peer.backend_key_data
        peer.ready
      end
      using(server) do
        conn = Postgres::Connection.new(server.url_with_password("s3cret"), read_timeout: 2.seconds)
        receive_within(password).should eq("s3cret")
        conn.close
      end
    end

    it "sends the MD5 digest with the server's salt" do
      salt = Bytes[0xde, 0xad, 0xbe, 0xef]
      password = Channel(String).new(1)
      server = fake do |peer|
        peer.read_startup
        peer.auth(5, salt)
        password.send(Fake.cstring(peer.expect('p')))
        peer.auth_ok
        peer.default_parameters
        peer.backend_key_data
        peer.ready
      end
      using(server) do
        conn = Postgres::Connection.new(server.url_with_password("s3cret"), read_timeout: 2.seconds)
        receive_within(password).should eq(Postgres::Auth.md5_password("tester", "s3cret", salt))
        conn.close
      end
    end

    it "raises AuthenticationError without sending anything when no password is set" do
      sent = Channel(Char?).new(1)
      server = fake do |peer|
        peer.read_startup
        peer.auth(3)
        type = begin
          peer.read_message[0]
        rescue IO::Error
          nil
        end
        sent.send(type)
      end
      using(server) do
        expect_raises(Postgres::AuthenticationError, /cleartext authentication but no password/) { connect(server.url) }
        receive_within(sent).should be_nil
      end
    end
  end

  describe "SCRAM-SHA-256" do
    it "authenticates against a server that checks the proof" do
      server = fake do |peer|
        scram = Fake::ScramServer.new("pencil")
        peer.read_startup
        peer.auth(10, "SCRAM-SHA-256\0\0".to_slice)
        body = peer.expect('p')
        mechanism = Fake.cstring(body)
        raise "mechanism #{mechanism}" unless mechanism == "SCRAM-SHA-256"
        size = IO::ByteFormat::BigEndian.decode(Int32, body + (mechanism.bytesize + 1))
        client_first = String.new(body[mechanism.bytesize + 5, size])
        peer.auth(11, scram.first(client_first).to_slice)
        signature = scram.final(String.new(peer.expect('p')))
        if signature
          peer.auth(12, "v=#{signature}".to_slice)
          peer.auth_ok
          peer.default_parameters
          peer.backend_key_data
          peer.ready
        else
          peer.error({'S' => "FATAL", 'C' => "28P01", 'M' => "password authentication failed"})
        end
      end
      using(server) do
        conn = Postgres::Connection.new(server.url_with_password("pencil"), read_timeout: 2.seconds)
        conn.closed?.should be_false
        conn.close
        # And the fake really checks the proof: a wrong password is refused.
        expect_raises(Postgres::AuthenticationError, /28P01/) do
          Postgres::Connection.new(server.url_with_password("wrong"), read_timeout: 2.seconds)
        end
      end
    end

    it "raises AuthenticationError when the server signature is wrong" do
      server = fake do |peer|
        scram = Fake::ScramServer.new("pencil")
        peer.read_startup
        peer.auth(10, "SCRAM-SHA-256\0\0".to_slice)
        body = peer.expect('p')
        client_first = String.new(body[18..]) # "SCRAM-SHA-256\0" + Int32 length
        peer.auth(11, scram.first(client_first).to_slice)
        scram.final(String.new(peer.expect('p'))) || raise "bad client proof"
        peer.auth(12, "v=#{Base64.strict_encode(Bytes.new(32))}".to_slice)
        peer.auth_ok
        peer.default_parameters
        peer.backend_key_data
        peer.ready
      end
      using(server) do
        expect_raises(Postgres::AuthenticationError, /signature mismatch/) do
          Postgres::Connection.new(server.url_with_password("pencil"), read_timeout: 2.seconds)
        end
      end
    end

    it "rejects a server offering only other SASL mechanisms" do
      server = fake do |peer|
        peer.read_startup
        peer.auth(10, "SCRAM-SHA-256-PLUS\0\0".to_slice)
      end
      using(server) do
        expect_raises(Postgres::AuthenticationError, /unsupported SASL mechanisms SCRAM-SHA-256-PLUS/) do
          Postgres::Connection.new(server.url_with_password("pencil"), read_timeout: 2.seconds)
        end
      end
    end
  end

  describe "sslmode" do
    it "continues in plain text with prefer when the server answers N" do
      requested = Channel(Bool).new(1)
      server = fake do |peer|
        peer.handshake
        requested.send(peer.ssl_requested?)
      end
      using(server) do
        conn = connect(server.url("prefer"))
        receive_within(requested).should be_true
        conn.tls?.should be_false
        conn.close
      end
    end

    it "raises ConnectionError with require when the server answers N" do
      server = fake(&.handshake)
      using(server) do
        expect_raises(Postgres::ConnectionError, /does not support TLS \(sslmode=require\)/) do
          connect(server.url("require"))
        end
      end
    end

    it "raises ConnectionError when the server closes on SSLRequest" do
      server = fake(&.handshake)
      server.ssl_answer = nil
      using(server) do
        expect_raises(Postgres::ConnectionError, /SSLRequest/) { connect(server.url("prefer")) }
      end
    end

    it "raises ProtocolError for an unknown SSLRequest answer" do
      server = fake(&.handshake)
      server.ssl_answer = 'X'
      using(server) do
        expect_raises(Postgres::ProtocolError, /SSLRequest answer 'X'/) { connect(server.url("prefer")) }
      end
    end

    it "does not send SSLRequest with disable" do
      requested = Channel(Bool).new(1)
      server = fake do |peer|
        peer.handshake
        requested.send(peer.ssl_requested?)
      end
      using(server) do
        conn = connect(server.url("disable"))
        receive_within(requested).should be_false
        conn.close
      end
    end
  end

  describe "query errors" do
    it "raises QueryError from Parse with its fields and stays usable" do
      server = fake do |peer|
        peer.handshake
        batch = peer.read_until_sync
        raise "expected Parse/Describe/Sync, got #{batch.map(&.[0])}" unless batch.map(&.[0]) == ['P', 'D', 'S']
        peer.error({'S' => "ERROR", 'V' => "ERROR", 'C' => "42P01", 'M' => "relation \"nope\" does not exist",
                    'D' => "some detail", 'H' => "some hint", 'P' => "15"})
        peer.ready
        peer.serve_query(columns: one_int4, rows: int4_rows(1))
      end
      using(server) do
        conn = connect(server.url)
        ex = expect_raises(Postgres::QueryError) { conn.query_one("select * from nope", as: Int32) }
        ex.code.should eq("42P01")
        ex.severity.should eq("ERROR")
        ex.detail_message.should eq("relation \"nope\" does not exist")
        ex.detail.should eq("some detail")
        ex.hint.should eq("some hint")
        ex.position.should eq(15)
        ex.message.should eq("ERROR 42P01: relation \"nope\" does not exist\nDETAIL: some detail\nHINT: some hint")
        conn.closed?.should be_false
        conn.query_one("select 1", as: Int32).should eq(1)
        conn.close
      end
    end

    it "raises QueryError from Execute and stays usable" do
      server = fake do |peer|
        peer.handshake
        peer.answer_prepare(peer.read_until_sync, params: [INT4])
        batch = peer.read_until_sync
        raise "expected Bind/Execute/Sync, got #{batch.map(&.[0])}" unless batch.map(&.[0]) == ['B', 'E', 'S']
        peer.bind_complete
        peer.error(error_fields("23505", "duplicate key value violates unique constraint \"t_pkey\""))
        peer.ready
        peer.serve_query(params: [INT4], tag: "INSERT 0 1")
      end
      using(server) do
        conn = connect(server.url)
        ex = expect_raises(Postgres::QueryError, /23505/) { conn.exec("insert into t values ($1)", 1) }
        ex.code.should eq("23505")
        conn.exec("insert into t values ($1)", 2).rows_affected.should eq(1)
        conn.close
      end
    end

    it "raises QueryError from a simple query after reading to ReadyForQuery" do
      server = fake do |peer|
        peer.handshake
        peer.expect('Q')
        peer.error(error_fields("42601", "syntax error"))
        peer.ready
        peer.expect('Q')
        peer.command_complete("SELECT 1")
        peer.ready
      end
      using(server) do
        conn = connect(server.url)
        expect_raises(Postgres::QueryError, /42601/) { conn.exec("selec") }
        conn.exec("select 1").rows_affected.should eq(1)
        conn.close
      end
    end
  end

  describe "statement cache" do
    it "does not send Parse again for a cached statement" do
      server = fake do |peer|
        peer.handshake
        peer.serve_query(columns: one_int4, rows: int4_rows(1))
        peer.serve_query(columns: one_int4, rows: int4_rows(1))
      end
      using(server) do
        conn = connect(server.url)
        conn.query_one("select 1", as: Int32).should eq(1)
        conn.query_one("select 1", as: Int32).should eq(1)
        conn.statement_cache_size.should eq(1)
        server.received_types.should eq(['P', 'D', 'S', 'B', 'E', 'S', 'B', 'E', 'S'])
        Fake.cstring(received(server, 'P')[0]).should eq("s1")
        received(server, 'B').map { |b| Fake.bind_statement(b) }.should eq(["s1", "s1"])
        conn.close
      end
    end

    it "uses unnamed statements when the cache is disabled" do
      server = fake do |peer|
        peer.handshake
        peer.serve_query(columns: one_int4, rows: int4_rows(1))
        peer.serve_query(columns: one_int4, rows: int4_rows(1))
      end
      using(server) do
        conn = connect(server.url(statement_cache_size: 0))
        conn.query_one("select 1", as: Int32).should eq(1)
        conn.query_one("select 1", as: Int32).should eq(1)
        received(server, 'P').map { |b| Fake.cstring(b) }.should eq(["", ""])
        conn.statement_cache_size.should eq(0)
        conn.close
      end
    end

    it "re-prepares and retries once when a cached statement is gone (26000), outside a transaction" do
      server = fake do |peer|
        peer.handshake
        peer.serve_query(columns: one_int4, rows: int4_rows(1))
        batch = peer.read_until_sync
        raise "expected Bind/Execute/Sync, got #{batch.map(&.[0])}" unless batch.map(&.[0]) == ['B', 'E', 'S']
        peer.error(error_fields("26000", "prepared statement \"s1\" does not exist"))
        peer.ready('I')
        peer.serve_query(columns: one_int4, rows: int4_rows(2))
      end
      using(server) do
        conn = connect(server.url)
        conn.query_one("select 1", as: Int32).should eq(1)
        conn.query_one("select 1", as: Int32).should eq(2)
        received(server, 'P').map { |b| Fake.cstring(b) }.should eq(["s1", "s2"])
        received(server, 'B').map { |b| Fake.bind_statement(b) }.should eq(["s1", "s1", "s2"])
        conn.statement_cache_size.should eq(1)
        conn.close
      end
    end

    it "re-prepares after 0A000 cached plan must not change result type" do
      server = fake do |peer|
        peer.handshake
        peer.serve_query(columns: one_int4, rows: int4_rows(1))
        peer.read_until_sync
        peer.error(error_fields("0A000", "cached plan must not change result type"))
        peer.ready('I')
        peer.serve_query(columns: one_int4, rows: int4_rows(3))
      end
      using(server) do
        conn = connect(server.url)
        conn.query_one("select * from t", as: Int32).should eq(1)
        conn.query_one("select * from t", as: Int32).should eq(3)
        received(server, 'P').size.should eq(2)
        conn.close
      end
    end

    it "raises the 26000 QueryError inside a transaction instead of retrying" do
      server = fake do |peer|
        peer.handshake
        peer.serve_query(columns: one_int4, rows: int4_rows(1), status: 'T')
        peer.read_until_sync
        peer.error(error_fields("26000", "prepared statement \"s1\" does not exist"))
        peer.ready('E')
        peer.expect('Q') # ROLLBACK
        peer.command_complete("ROLLBACK")
        peer.ready('I')
      end
      using(server) do
        conn = connect(server.url)
        conn.query_one("select 1", as: Int32).should eq(1)
        conn.transaction_status.should eq('T')
        ex = expect_raises(Postgres::QueryError) { conn.query_one("select 1", as: Int32) }
        ex.code.should eq("26000")
        conn.transaction_status.should eq('E')
        received(server, 'P').size.should eq(1)
        conn.exec("ROLLBACK")
        conn.transaction_status.should eq('I')
        conn.close
      end
    end

    it "queues the Close of an evicted statement ahead of the next round trip" do
      server = fake do |peer|
        peer.handshake
        3.times { peer.serve_query(columns: one_int4, rows: int4_rows(1)) }
      end
      using(server) do
        conn = connect(server.url(statement_cache_size: 1))
        conn.query_one("select 1", as: Int32)
        conn.query_one("select 2", as: Int32)
        conn.statement_cache_size.should eq(1)
        types = server.received_types
        types[0, 9].should eq(['P', 'D', 'S', 'B', 'E', 'S', 'P', 'D', 'S'])
        # The Close rides with the Bind/Execute/Sync round trip.
        types[9..].sort.should eq(['B', 'C', 'E', 'S'])
        types.last.should eq('S')
        close = received(server, 'C')[0]
        close[0].unsafe_chr.should eq('S')
        Fake.cstring(close, 1).should eq("s1")
        # "select 1" was evicted: prepared again as s3, closing s2.
        conn.query_one("select 1", as: Int32)
        received(server, 'P').map { |b| Fake.cstring(b) }.should eq(["s1", "s2", "s3"])
        received(server, 'C').map { |b| Fake.cstring(b, 1) }.should eq(["s1", "s2"])
        conn.close
      end
    end

    it "sends the Closes of clear_statement_cache with the next round trip" do
      server = fake do |peer|
        peer.handshake
        peer.serve_query(columns: one_int4, rows: int4_rows(1))
        peer.expect('C')
        peer.expect('Q')
        peer.close_complete
        peer.command_complete("SELECT 1")
        peer.ready
      end
      using(server) do
        conn = connect(server.url)
        conn.query_one("select 1", as: Int32)
        conn.clear_statement_cache
        conn.statement_cache_size.should eq(0)
        conn.exec("select 1")
        Fake.cstring(received(server, 'C')[0], 1).should eq("s1")
        conn.close
      end
    end

    # `write_bind` discards the half-written `Bind` on `EncodeError`; the
    # queued `Close`s must survive that.
    it "keeps queued Closes when a Bind fails to encode" do
      server = fake do |peer|
        peer.handshake
        peer.serve_query(columns: one_int4, rows: int4_rows(1))
        peer.answer_prepare(peer.read_until_sync, params: [INT4])
        peer.serve_query(params: [INT4], tag: "INSERT 0 1")
      end
      using(server) do
        conn = connect(server.url(statement_cache_size: 1))
        conn.query_one("select 1", as: Int32)
        # Prepares s2, evicting s1; the Bind then fails before it is sent.
        expect_raises(Postgres::EncodeError) { conn.exec("insert into t values ($1)", 5_000_000_000_i64) }
        conn.exec("insert into t values ($1)", 5).rows_affected.should eq(1)
        received(server, 'C').map { |b| Fake.cstring(b, 1) }.should eq(["s1"])
        conn.close
      end
    end
  end

  describe "malformed input" do
    it "raises ProtocolError for an invalid length and closes the connection" do
      server = fake do |peer|
        peer.handshake
        peer.expect('Q')
        peer.send_raw(Bytes['Z'.ord, 0, 0, 0, 2])
      end
      using(server) do
        conn = connect(server.url)
        expect_raises(Postgres::ProtocolError, /invalid message length 2/) { conn.exec("select 1") }
        conn.closed?.should be_true
        expect_raises(Postgres::ConnectionError, /closed/) { conn.exec("select 1") }
      end
    end

    it "raises ProtocolError for an unexpected message during a simple query" do
      server = fake do |peer|
        peer.handshake
        peer.expect('Q')
        peer.send('W', Bytes[0, 0, 0]) # CopyBothResponse
      end
      using(server) do
        conn = connect(server.url)
        expect_raises(Postgres::ProtocolError, /unexpected message 'W'/) { conn.exec("select 1") }
        conn.closed?.should be_true
      end
    end

    it "raises ProtocolError for an unexpected message during an extended query" do
      server = fake do |peer|
        peer.handshake
        peer.answer_prepare(peer.read_until_sync, columns: one_int4)
        peer.read_until_sync
        peer.bind_complete
        peer.send('G', Bytes[0, 0, 0]) # CopyInResponse
      end
      using(server) do
        conn = connect(server.url)
        expect_raises(Postgres::ProtocolError, /unexpected message 'G'/) { conn.query_one("select 1", as: Int32) }
        conn.closed?.should be_true
      end
    end

    # Regression: the length used to be decoded and reduced by 4 unchecked,
    # raising OverflowError and leaving the connection open.
    it "raises ProtocolError for a length that overflows" do
      server = fake do |peer|
        peer.handshake
        peer.expect('Q')
        peer.send_raw(Bytes['Z'.ord, 0x80, 0, 0, 0])
      end
      using(server) do
        conn = connect(server.url)
        expect_raises(Postgres::ProtocolError, /invalid message length/) { conn.exec("select 1") }
        conn.closed?.should be_true
      end
    end

    # Regression: a malformed DataRow must close the connection, or its
    # remaining replies are read as the answer to the next query.
    it "closes the connection on a truncated DataRow" do
      server = fake do |peer|
        peer.handshake
        peer.answer_prepare(peer.read_until_sync, columns: one_int4)
        peer.read_until_sync
        peer.bind_complete
        peer.send('D', Bytes[0, 1, 0, 0, 0, 4, 0]) # 1 column of 4 bytes, 1 present
        peer.command_complete("SELECT 1")
        peer.ready
      end
      using(server) do
        conn = connect(server.url)
        expect_raises(Postgres::ProtocolError, /truncated DataRow/) { conn.query_one("select 1", as: Int32) }
        conn.closed?.should be_true
      end
    end

    # Regression: a short Binary::Format body used to leak IO::EOFError
    # and leave the connection open and out of step.
    it "raises ProtocolError for a truncated RowDescription and closes" do
      server = fake do |peer|
        peer.handshake
        peer.read_until_sync
        peer.parse_complete
        peer.parameter_description([] of UInt32)
        peer.send('T', Bytes[0, 1]) # one column, none described
        peer.ready
      end
      using(server) do
        conn = connect(server.url)
        expect_raises(Postgres::ProtocolError) { conn.query_one("select 1", as: Int32) }
        conn.closed?.should be_true
      end
    end

    # Regression: an empty ReadyForQuery used to raise IndexError.
    it "raises ProtocolError for an empty ReadyForQuery" do
      server = fake do |peer|
        peer.handshake
        peer.expect('Q')
        peer.send('Z')
      end
      using(server) do
        conn = connect(server.url)
        expect_raises(Postgres::ProtocolError) { conn.exec("select 1") }
        conn.closed?.should be_true
      end
    end
  end

  describe "I/O failures" do
    it "raises IO::TimeoutError after read_timeout and closes the connection" do
      server = fake do |peer|
        peer.handshake
        peer.expect('Q')
        peer.read_message # never answers; returns when the client goes away
      end
      using(server) do
        conn = connect(server.url, read_timeout: 100.milliseconds)
        expect_raises(IO::TimeoutError) { conn.exec("select pg_sleep(10)") }
        conn.closed?.should be_true
        expect_raises(Postgres::ConnectionError, /closed/) { conn.exec("select 1") }
      end
    end

    it "raises ConnectionError when the server closes the socket mid-query" do
      server = fake do |peer|
        peer.handshake
        peer.expect('Q')
        peer.close
      end
      using(server) do
        conn = connect(server.url)
        expect_raises(Postgres::ConnectionError, /server closed the connection/) { conn.exec("select 1") }
        conn.closed?.should be_true
      end
    end

    it "raises ConnectionError when the server closes the socket mid-result" do
      server = fake do |peer|
        peer.handshake
        peer.answer_prepare(peer.read_until_sync, columns: one_int4)
        peer.read_until_sync
        peer.bind_complete
        peer.data_row([Fake.int4(1).as(Bytes?)])
        peer.send_raw(Bytes['D'.ord, 0, 0, 0, 20, 0]) # cut short
        peer.close
      end
      using(server) do
        conn = connect(server.url)
        rows = [] of Int32
        expect_raises(Postgres::ConnectionError) do
          conn.query_each("select 1", as: Int32) { |v| rows << v }
        end
        rows.should eq([1])
        conn.closed?.should be_true
      end
    end
  end

  describe "#query_each" do
    it "drains the rest of the result when the block raises and stays usable" do
      server = fake do |peer|
        peer.handshake
        peer.serve_query(columns: one_int4, rows: int4_rows(1, 2, 3))
        peer.serve_query(columns: one_int4, rows: int4_rows(4))
      end
      using(server) do
        conn = connect(server.url)
        seen = [] of Int32
        expect_raises(Exception, "stop at 1") do
          conn.query_each("select x from t", as: Int32) do |v|
            seen << v
            raise "stop at #{v}"
          end
        end
        seen.should eq([1])
        conn.closed?.should be_false
        conn.query_one("select x from t", as: Int32).should eq(4)
        conn.close
      end
    end

    it "raises Postgres::Error (busy) for a query from inside the block" do
      server = fake do |peer|
        peer.handshake
        peer.serve_query(columns: one_int4, rows: int4_rows(1, 2))
        peer.expect('Q')
        peer.command_complete("SELECT 1")
        peer.ready
      end
      using(server) do
        conn = connect(server.url)
        expect_raises(Postgres::Error, /busy/) do
          conn.query_each("select x from t", as: Int32) { conn.exec("select 1") }
        end
        conn.exec("select 1").rows_affected.should eq(1)
        conn.close
      end
    end
  end

  describe "asynchronous messages" do
    it "passes NoticeResponse to on_notice and applies ParameterStatus mid-query" do
      server = fake do |peer|
        peer.handshake
        peer.answer_prepare(peer.read_until_sync, columns: one_int4)
        peer.read_until_sync
        peer.bind_complete
        peer.notice({'S' => "WARNING", 'V' => "WARNING", 'C' => "01000", 'M' => "careful"})
        peer.parameter_status("TimeZone", "Europe/Lisbon")
        peer.data_row([Fake.int4(7).as(Bytes?)])
        peer.send('A', Fake.build { |io| io.write_bytes(1, IO::ByteFormat::BigEndian); io << "chan\0payload\0" })
        peer.command_complete("SELECT 1")
        peer.ready
      end
      using(server) do
        conn = connect(server.url)
        notices = [] of Postgres::Notice
        conn.on_notice = ->(n : Postgres::Notice) { notices << n; nil }
        conn.query_one("select 7", as: Int32).should eq(7)
        notices.size.should eq(1)
        notices[0].severity.should eq("WARNING")
        notices[0].code.should eq("01000")
        notices[0].message.should eq("careful")
        conn.parameters["TimeZone"].should eq("Europe/Lisbon")
        conn.close
      end
    end

    it "drops notices when on_notice is nil" do
      server = fake do |peer|
        peer.handshake
        peer.expect('Q')
        peer.notice({'S' => "NOTICE", 'M' => "ignored"})
        peer.command_complete("DO")
        peer.ready
      end
      using(server) do
        conn = connect(server.url)
        conn.exec("do $$ begin raise notice 'x'; end $$").command.should eq("DO")
        conn.close
      end
    end
  end

  describe "#exec" do
    it "uses the simple protocol without arguments and reads rows_affected from the tag" do
      sql = Channel(String).new(1)
      server = fake do |peer|
        peer.handshake
        sql.send(Fake.cstring(peer.expect('Q')))
        peer.command_complete("UPDATE 3")
        peer.ready
      end
      using(server) do
        conn = connect(server.url)
        result = conn.exec("update t set x = 1")
        result.command.should eq("UPDATE")
        result.rows_affected.should eq(3)
        receive_within(sql).should eq("update t set x = 1")
        server.received_types.should eq(['Q'])
        conn.close
      end
    end

    it "returns the last command's result for several statements" do
      server = fake do |peer|
        peer.handshake
        peer.expect('Q')
        peer.command_complete("INSERT 0 1")
        peer.row_description([{"x", TEXT}])
        peer.data_row(["a".to_slice.as(Bytes?)])
        peer.command_complete("SELECT 1")
        peer.command_complete("DELETE 2")
        peer.ready('T')
      end
      using(server) do
        conn = connect(server.url)
        result = conn.exec("begin; insert ...; select ...; delete ...")
        result.command.should eq("DELETE")
        result.rows_affected.should eq(2)
        conn.transaction_status.should eq('T')
        conn.close
      end
    end

    it "handles EmptyQueryResponse (ping)" do
      server = fake do |peer|
        peer.handshake
        Fake.cstring(peer.expect('Q')).should eq("")
        peer.empty_query
        peer.ready
      end
      using(server) do
        conn = connect(server.url)
        conn.ping
        conn.closed?.should be_false
        conn.close
      end
    end

    it "uses the extended protocol with arguments" do
      server = fake do |peer|
        peer.handshake
        peer.serve_query(params: [INT4, TEXT], tag: "INSERT 0 1")
      end
      using(server) do
        conn = connect(server.url)
        conn.exec("insert into t values ($1, $2)", 5, "five").rows_affected.should eq(1)
        server.received_types.should eq(['P', 'D', 'S', 'B', 'E', 'S'])
        bind = received(server, 'B')[0]
        # portal "", statement "s1", 2 format codes (int4 binary, text), 2 values
        io = IO::Memory.new(bind)
        io.gets('\0').should eq("\0")
        io.gets('\0').should eq("s1\0")
        io.read_bytes(Int16, IO::ByteFormat::BigEndian).should eq(2)
        conn.close
      end
    end
  end

  it "raises ArgumentError for the wrong number of arguments and stays usable" do
    server = fake do |peer|
      peer.handshake
      peer.answer_prepare(peer.read_until_sync, params: [INT4])
      peer.serve_query(params: [INT4], tag: "DELETE 1")
    end
    using(server) do
      conn = connect(server.url)
      expect_raises(ArgumentError, "query expects 1 parameters, got 2") do
        conn.exec("delete from t where id = $1", 1, 2)
      end
      expect_raises(ArgumentError, "query expects 1 parameters, got 0") do
        conn.query_one?("delete from t where id = $1", as: Int32)
      end
      conn.exec("delete from t where id = $1", 1).rows_affected.should eq(1)
      server.received_types.should eq(['P', 'D', 'S', 'B', 'E', 'S'])
      conn.close
    end
  end
end
