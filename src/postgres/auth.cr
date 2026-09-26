require "./error"
require "base64"
require "random/secure"
require "digest/md5"
require "digest/sha256"
require "openssl"
require "openssl/hmac"
require "openssl/pkcs5"
require "crypto/subtle"

module Postgres
  # :nodoc:
  module Auth
    # Returns the response to an `AuthenticationMD5Password` request:
    # `"md5" + md5hex(md5hex(password + user) + salt)`.
    def self.md5_password(user : String, password : String, salt : Bytes) : String
      inner = Digest::MD5.hexdigest(password + user)
      outer = Digest::MD5.hexdigest do |ctx|
        ctx << inner
        ctx << salt
      end
      "md5" + outer
    end

    # A SCRAM-SHA-256 client (RFC 5802 / RFC 7677) without channel binding
    # (GS2 header `n,,`).
    #
    # SASLprep is not applied to the password: ASCII passwords are
    # unaffected.
    class Scram
      MECHANISM = "SCRAM-SHA-256"

      private GS2_HEADER = "n,,"
      # base64("n,,")
      private CHANNEL_BINDING = "biws"

      @server_signature : Bytes?

      # Creates a client for *password*. *client_nonce* defaults to 24
      # random bytes, Base64-encoded. *username* is sent in the `n=`
      # attribute; PostgreSQL ignores it, so it defaults to empty.
      def initialize(@password : String, @client_nonce : String = Base64.strict_encode(Random::Secure.random_bytes(24)), @username : String = "")
      end

      # Returns the client-first-message, sent in `SASLInitialResponse`.
      def client_first_message : String
        GS2_HEADER + client_first_bare
      end

      # Computes the client-final-message (with the client proof) from the
      # server-first-message. Raises `AuthenticationError` if the server
      # message is malformed or its nonce does not extend the client nonce.
      def client_final_message(server_first : String) : String
        nonce = nil
        salt = nil
        iterations = nil
        server_first.split(',').each do |attr|
          if attr.starts_with?("r=")
            nonce = attr[2..]
          elsif attr.starts_with?("s=")
            salt = attr[2..]
          elsif attr.starts_with?("i=")
            iterations = attr[2..]
          elsif attr.starts_with?("e=")
            raise AuthenticationError.new("SCRAM authentication failed: #{attr[2..]}")
          end
        end

        unless nonce && salt && iterations
          raise AuthenticationError.new("Malformed SCRAM server-first-message")
        end
        if !nonce.starts_with?(@client_nonce) || nonce.size <= @client_nonce.size
          raise AuthenticationError.new("SCRAM server nonce does not start with the client nonce")
        end
        count = iterations.to_i?
        unless count && count > 0
          raise AuthenticationError.new("Invalid SCRAM iteration count: #{iterations.inspect}")
        end
        salt_bytes = begin
          Base64.decode(salt)
        rescue ex : Base64::Error
          raise AuthenticationError.new("Invalid SCRAM salt", cause: ex)
        end

        salted = OpenSSL::PKCS5.pbkdf2_hmac(@password, salt_bytes, iterations: count, algorithm: OpenSSL::Algorithm::SHA256, key_size: 32)
        client_key = hmac(salted, "Client Key")
        stored_key = Digest::SHA256.digest(client_key)

        without_proof = "c=#{CHANNEL_BINDING},r=#{nonce}"
        auth_message = "#{client_first_bare},#{server_first},#{without_proof}"

        client_signature = hmac(stored_key, auth_message)
        proof = Bytes.new(client_key.size) { |i| client_key[i] ^ client_signature[i] }

        server_key = hmac(salted, "Server Key")
        @server_signature = hmac(server_key, auth_message)

        "#{without_proof},p=#{Base64.strict_encode(proof)}"
      end

      # Verifies the server-final-message. Raises `AuthenticationError` if
      # the server reports an error (`e=`), the message is malformed, or the
      # server signature does not match.
      def verify_server_final(server_final : String) : Nil
        expected = @server_signature
        raise AuthenticationError.new("SCRAM server-final-message received before client-final-message") unless expected

        if server_final.starts_with?("e=")
          raise AuthenticationError.new("SCRAM authentication failed: #{server_final[2..]}")
        end
        unless server_final.starts_with?("v=")
          raise AuthenticationError.new("Malformed SCRAM server-final-message")
        end

        value = server_final[2..].split(',', 2).first
        actual = begin
          Base64.decode(value)
        rescue ex : Base64::Error
          raise AuthenticationError.new("Invalid SCRAM server signature", cause: ex)
        end

        unless Crypto::Subtle.constant_time_compare(actual, expected)
          raise AuthenticationError.new("SCRAM server signature mismatch")
        end
      end

      private def client_first_bare : String
        "n=#{@username},r=#{@client_nonce}"
      end

      private def hmac(key, data) : Bytes
        OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, key, data)
      end
    end
  end
end
