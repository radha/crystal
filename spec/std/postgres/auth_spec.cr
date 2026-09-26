require "spec"
require "postgres/auth"

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
