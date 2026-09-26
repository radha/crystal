require "spec"
require "postgres/auth"
require "socket"
require "uri"

private RFC_NONCE        = "rOprNGfwEbeRWgbNEkqO"
private RFC_SERVER_FIRST = "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"
private RFC_CLIENT_FINAL = "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ="
private RFC_SERVER_FINAL = "v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="

private def rfc_scram
  Postgres::Auth::Scram.new("pencil", RFC_NONCE, "user")
end

describe Postgres::Auth do
  describe ".md5_password" do
    it "matches a hand-built digest" do
      salt = Bytes[1, 2, 3, 4]
      inner = Digest::MD5.hexdigest("secretbob")
      expected = "md5" + Digest::MD5.hexdigest(inner.to_slice + salt)
      Postgres::Auth.md5_password("bob", "secret", salt).should eq(expected)
    end

    it "builds on the hash postgres stores" do
      stored = Digest::MD5.hexdigest("md5pass" + "crystal_md5")
      salt = Bytes[0xde, 0xad, 0xbe, 0xef]
      io = IO::Memory.new
      io << stored
      io.write(salt)
      expected = "md5" + Digest::MD5.hexdigest(io.to_slice)
      Postgres::Auth.md5_password("crystal_md5", "md5pass", salt).should eq(expected)
      expected.size.should eq(35)
    end
  end

  describe Postgres::Auth::Scram do
    it "reproduces the RFC 7677 example" do
      scram = rfc_scram
      scram.client_first_message.should eq("n,,n=user,r=#{RFC_NONCE}")
      scram.client_final_message(RFC_SERVER_FIRST).should eq(RFC_CLIENT_FINAL)
      scram.verify_server_final(RFC_SERVER_FINAL).should be_nil
    end

    it "sends an empty username and a random nonce by default" do
      a = Postgres::Auth::Scram.new("pw")
      b = Postgres::Auth::Scram.new("pw")
      a.client_first_message.should match(/\An,,n=,r=[A-Za-z0-9+\/]{32}\z/)
      a.client_first_message.should_not eq(b.client_first_message)
      Postgres::Auth::Scram::MECHANISM.should eq("SCRAM-SHA-256")
    end

    it "rejects a server nonce that does not extend the client nonce" do
      expect_raises(Postgres::AuthenticationError, /nonce/) do
        rfc_scram.client_final_message("r=somethingelse,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096")
      end
      expect_raises(Postgres::AuthenticationError, /nonce/) do
        rfc_scram.client_final_message("r=#{RFC_NONCE},s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096")
      end
    end

    it "rejects a bad iteration count" do
      {"0", "-1", "abc", ""}.each do |i|
        expect_raises(Postgres::AuthenticationError, /iteration/) do
          rfc_scram.client_final_message("r=#{RFC_NONCE}xyz,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=#{i}")
        end
      end
    end

    it "rejects a malformed server-first-message" do
      expect_raises(Postgres::AuthenticationError, /Malformed/) do
        rfc_scram.client_final_message("r=#{RFC_NONCE}xyz,i=4096")
      end
    end

    it "rejects a wrong server signature" do
      scram = rfc_scram
      scram.client_final_message(RFC_SERVER_FIRST)
      expect_raises(Postgres::AuthenticationError, /signature mismatch/) do
        scram.verify_server_final("v=#{Base64.strict_encode(Bytes.new(32))}")
      end
    end

    it "raises the server's e= error" do
      scram = rfc_scram
      scram.client_final_message(RFC_SERVER_FIRST)
      expect_raises(Postgres::AuthenticationError, /invalid-proof/) do
        scram.verify_server_final("e=invalid-proof")
      end
    end

    it "rejects anything else" do
      scram = rfc_scram
      scram.client_final_message(RFC_SERVER_FIRST)
      expect_raises(Postgres::AuthenticationError) { scram.verify_server_final("x=nope") }
    end

    it "rejects a server-final before client-final" do
      expect_raises(Postgres::AuthenticationError) { rfc_scram.verify_server_final(RFC_SERVER_FINAL) }
    end
  end
end

private PG_HOST = "127.0.0.1"
private PG_PORT = 5432
private PG_CERT = "/opt/pgdata/server.crt"

# Opens a TLS connection to the local server (SSLRequest, then a handshake
# without verification) and yields it, or returns `nil` when no TLS server
# answers.
private def with_pg_tls(&)
  tcp = begin
    TCPSocket.new(PG_HOST, PG_PORT, connect_timeout: 1.second)
  rescue Socket::Error | IO::TimeoutError
    return nil
  end
  begin
    tcp.read_timeout = 2.seconds
    tcp.write_bytes(8, IO::ByteFormat::BigEndian)
    tcp.write_bytes(80877103, IO::ByteFormat::BigEndian)
    tcp.flush
    return nil unless tcp.read_byte == 'S'.ord
    context = OpenSSL::SSL::Context::Client.new
    context.verify_mode = OpenSSL::SSL::VerifyMode::NONE
    ssl = OpenSSL::SSL::Socket::Client.new(tcp, context, sync_close: true)
    begin
      yield ssl
    ensure
      ssl.close
    end
  ensure
    tcp.close unless tcp.closed?
  end
end

private def pg_tls_available? : Bool
  !with_pg_tls { true }.nil?
rescue
  false
end

private PG_TLS = pg_tls_available?

private def pg_write(io : IO, type : Char?, & : IO ->)
  body = IO::Memory.new
  yield body
  io.write_byte(type.ord.to_u8) if type
  io.write_bytes(body.size + 4, IO::ByteFormat::BigEndian)
  io.write(body.to_slice)
  io.flush
end

# Reads one backend message, returning its type and body.
private def pg_read(io : IO) : {Char, Bytes}
  type = io.read_byte.not_nil!.unsafe_chr
  size = io.read_bytes(Int32, IO::ByteFormat::BigEndian)
  body = Bytes.new(size - 4)
  io.read_fully(body)
  {type, body}
end

# Sends a startup message for *user* and returns the authentication
# request that follows: the code and the rest of the body.
private def pg_startup(io : IO, user : String, database : String) : {Int32, Bytes}
  pg_write(io, nil) do |body|
    body.write_bytes(196608, IO::ByteFormat::BigEndian)
    {"user", user, "database", database}.each { |s| body << s << '\0' }
    body << '\0'
  end
  pg_auth(io)
end

private def pg_auth(io : IO) : {Int32, Bytes}
  type, body = pg_read(io)
  fail "expected an authentication request, got #{type} #{String.new(body)}" unless type == 'R'
  {IO::ByteFormat::BigEndian.decode(Int32, body[0, 4]), body + 4}
end

private def pg_cstrings(body : Bytes) : Array(String)
  String.new(body).split('\0').reject(&.empty?)
end

private def pem_to_der(pem : String) : Bytes
  Base64.decode(pem.lines.reject(&.starts_with?("-----")).join)
end

# Mirror of the SCRAM algorithm: the client-final-message and
# server-final-message for the given inputs.
private def expected_scram(password, client_nonce, server_first, gs2_header, cbind_data : Bytes?) : {String, String}
  attrs = server_first.split(',').to_h { |a| {a[0, 1], a[2..]} }
  salted = OpenSSL::PKCS5.pbkdf2_hmac(password, Base64.decode(attrs["s"]), attrs["i"].to_i, OpenSSL::Algorithm::SHA256, 32)
  client_key = OpenSSL::HMAC.digest(:sha256, salted, "Client Key")
  stored_key = Digest::SHA256.digest(client_key)
  cbind = IO::Memory.new
  cbind << gs2_header
  cbind.write(cbind_data) if cbind_data
  without_proof = "c=#{Base64.strict_encode(cbind.to_slice)},r=#{attrs["r"]}"
  auth_message = "n=user,r=#{client_nonce},#{server_first},#{without_proof}"
  signature = OpenSSL::HMAC.digest(:sha256, stored_key, auth_message)
  proof = Bytes.new(32) { |i| client_key[i] ^ signature[i] }
  server_signature = OpenSSL::HMAC.digest(:sha256, OpenSSL::HMAC.digest(:sha256, salted, "Server Key"), auth_message)
  {"#{without_proof},p=#{Base64.strict_encode(proof)}", "v=#{Base64.strict_encode(server_signature)}"}
end

describe "Postgres::Auth.saslprep" do
  it "applies the RFC 4013 §3 examples" do
    Postgres::Auth.saslprep("I­X").should eq("IX")
    Postgres::Auth.saslprep("user").should eq("user")
    Postgres::Auth.saslprep("USER").should eq("USER")
    Postgres::Auth.saslprep("ª").should eq("a")
    Postgres::Auth.saslprep("Ⅸ").should eq("IX")
  end

  it "returns prohibited and bidi-violating input unchanged, like PostgreSQL" do
    Postgres::Auth.saslprep("\u0007").should eq("\u0007")             # ASCII fast path
    Postgres::Auth.saslprep("a\u0080b").should eq("a\u0080b")         # C.2.2 control
    Postgres::Auth.saslprep("pass\u{E000}").should eq("pass\u{E000}") # C.3 private use
    Postgres::Auth.saslprep("ا1").should eq("ا1")                     # RandALCat not last
    Postgres::Auth.saslprep("اaا").should eq("اaا")                   # RandALCat with LCat
    Postgres::Auth.saslprep("xȡ").should eq("xȡ")                     # unassigned in Unicode 3.2
  end

  it "accepts a well-formed right-to-left string" do
    Postgres::Auth.saslprep("ا1ب").should eq("ا1ب")
  end

  it "maps non-ASCII spaces and removes characters mapped to nothing" do
    Postgres::Auth.saslprep("a b　c").should eq("a b c")
    Postgres::Auth.saslprep("pa​ss﻿wordé").should eq("pa sswordé")
    Postgres::Auth.saslprep("­‍").should eq("­‍") # empty result
  end

  it "NFKC-normalizes" do
    Postgres::Auth.saslprep("é").should eq("é")
    Postgres::Auth.saslprep("ﬁ").should eq("fi")
  end

  it "returns invalid UTF-8 unchanged" do
    s = String.new(Bytes[0x70, 0xff, 0xc3])
    Postgres::Auth.saslprep(s).to_slice.should eq(s.to_slice)
  end

  it "is applied to the SCRAM password" do
    first = "r=#{RFC_NONCE}xyz,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"
    a = Postgres::Auth::Scram.new("I­X", RFC_NONCE, "user").client_final_message(first)
    b = Postgres::Auth::Scram.new("IX", RFC_NONCE, "user").client_final_message(first)
    a.should eq(b)
  end
end

describe "Postgres::Auth.choose_mechanism" do
  both = [Postgres::Auth::Scram::MECHANISM_PLUS, Postgres::Auth::Scram::MECHANISM]
  plain = [Postgres::Auth::Scram::MECHANISM]
  {
    {both, :prefer, true, "SCRAM-SHA-256-PLUS"},
    {both, :prefer, false, "SCRAM-SHA-256"},
    {plain, :prefer, true, "SCRAM-SHA-256"},
    {both, :require, true, "SCRAM-SHA-256-PLUS"},
    {both, :require, false, nil},
    {plain, :require, true, nil},
    {both, :disable, true, "SCRAM-SHA-256"},
    {both, :disable, false, "SCRAM-SHA-256"},
    {["SCRAM-SHA-1"], :prefer, true, nil},
    {["SCRAM-SHA-256-PLUS"], :disable, true, nil},
  }.each do |offered, policy, tls, expected|
    it "#{policy} with tls=#{tls}, offered #{offered.join(" ")} => #{expected || "error"}" do
      binding = Postgres::Auth::ChannelBinding.parse(policy.to_s)
      if expected
        Postgres::Auth.choose_mechanism(offered, binding, tls).should eq(expected)
      else
        expect_raises(Postgres::AuthenticationError) do
          Postgres::Auth.choose_mechanism(offered, binding, tls)
        end
      end
    end
  end
end

describe "Postgres::Auth::Scram with channel binding" do
  cert_hash = Digest::SHA256.digest("not really a certificate")

  it "computes SCRAM-SHA-256-PLUS messages (known answer)" do
    scram = Postgres::Auth::Scram.new("pencil", RFC_NONCE, "user", channel_binding: cert_hash)
    scram.mechanism.should eq("SCRAM-SHA-256-PLUS")
    scram.client_first_message.should eq("p=tls-server-end-point,,n=user,r=#{RFC_NONCE}")
    final, server_final = expected_scram("pencil", RFC_NONCE, RFC_SERVER_FIRST, "p=tls-server-end-point,,", cert_hash)
    actual = scram.client_final_message(RFC_SERVER_FIRST)
    actual.should eq(final)
    actual.should start_with("c=cD10bHMtc2VydmVyLWVuZC1wb2ludCws")
    actual.should_not eq(RFC_CLIENT_FINAL)
    scram.verify_server_final(server_final).should be_nil
    expect_raises(Postgres::AuthenticationError, /mismatch/) { scram.verify_server_final(RFC_SERVER_FINAL) }
  end

  it "sends the y flag when binding is possible but not offered" do
    scram = Postgres::Auth::Scram.new("pencil", RFC_NONCE, "user", binding_supported: true)
    scram.mechanism.should eq("SCRAM-SHA-256")
    scram.client_first_message.should eq("y,,n=user,r=#{RFC_NONCE}")
    final, _ = expected_scram("pencil", RFC_NONCE, RFC_SERVER_FIRST, "y,,", nil)
    scram.client_final_message(RFC_SERVER_FIRST).should eq(final)
    final.should start_with("c=eSws,")
  end

  it "negotiates the mechanism and GS2 flag" do
    plus = ["SCRAM-SHA-256-PLUS", "SCRAM-SHA-256"]
    Postgres::Auth::Scram.negotiate(plus, "pw", certificate_hash: cert_hash).client_first_message.should start_with("p=tls-server-end-point,,n=,r=")
    Postgres::Auth::Scram.negotiate(["SCRAM-SHA-256"], "pw", certificate_hash: cert_hash).client_first_message.should start_with("y,,n=,r=")
    Postgres::Auth::Scram.negotiate(plus, "pw", certificate_hash: cert_hash, channel_binding: :disable).client_first_message.should start_with("n,,n=,r=")
    Postgres::Auth::Scram.negotiate(plus, "pw", certificate_hash: nil).client_first_message.should start_with("n,,n=,r=")
    expect_raises(Postgres::AuthenticationError) do
      Postgres::Auth::Scram.negotiate(plus, "pw", certificate_hash: nil, channel_binding: :require)
    end
  end
end

describe "Postgres::Auth.certificate_hash" do
  it "is nil for garbage DER" do
    Postgres::Auth.certificate_hash(Bytes[1, 2, 3]).should be_nil
  end

  if File.exists?(PG_CERT)
    it "hashes a sha256WithRSAEncryption certificate with SHA-256" do
      der = pem_to_der(File.read(PG_CERT))
      Postgres::Auth.certificate_hash(der).should eq(Digest::SHA256.digest(der))
    end
  else
    pending "hashes a sha256WithRSAEncryption certificate with SHA-256 [no #{PG_CERT}]"
  end

  if PG_TLS && File.exists?(PG_CERT)
    it "hashes the certificate the local server presents" do
      der = pem_to_der(File.read(PG_CERT))
      with_pg_tls do |ssl|
        Postgres::Auth.certificate_hash(ssl).should eq(Digest::SHA256.digest(der))
      end
    end

    it "sees SCRAM-SHA-256-PLUS offered over TLS" do
      user = ENV["POSTGRES_SSL_URL"]?.try { |url| URI.parse(url).user } || "crystal_ssl"
      with_pg_tls do |ssl|
        code, body = pg_startup(ssl, user, "crystal_test")
        code.should eq(10)
        pg_cstrings(body).should eq(["SCRAM-SHA-256-PLUS", "SCRAM-SHA-256"])
      end
    end
  else
    pending "hashes the certificate the local server presents [no TLS server at #{PG_HOST}:#{PG_PORT}]"
    pending "sees SCRAM-SHA-256-PLUS offered over TLS [no TLS server at #{PG_HOST}:#{PG_PORT}]"
  end

  if PG_TLS && (url = ENV["POSTGRES_SSL_URL"]?.presence)
    it "logs in with SCRAM-SHA-256-PLUS" do
      uri = URI.parse(url)
      with_pg_tls do |ssl|
        code, body = pg_startup(ssl, uri.user.not_nil!, uri.path.lchop('/'))
        code.should eq(10)
        scram = Postgres::Auth::Scram.negotiate(pg_cstrings(body), uri.password.not_nil!,
          certificate_hash: Postgres::Auth.certificate_hash(ssl), channel_binding: :require)
        scram.mechanism.should eq("SCRAM-SHA-256-PLUS")
        pg_write(ssl, 'p') do |io|
          io << scram.mechanism << '\0'
          first = scram.client_first_message
          io.write_bytes(first.bytesize, IO::ByteFormat::BigEndian)
          io << first
        end
        code, body = pg_auth(ssl)
        code.should eq(11)
        pg_write(ssl, 'p') { |io| io << scram.client_final_message(String.new(body)) }
        code, body = pg_auth(ssl)
        code.should eq(12)
        scram.verify_server_final(String.new(body)).should be_nil
        pg_auth(ssl)[0].should eq(0)
      end
    end
  else
    pending "logs in with SCRAM-SHA-256-PLUS [set POSTGRES_SSL_URL]"
  end
end
