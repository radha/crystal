module Postgres
  # Base class of every error the client raises.
  class Error < Exception
  end

  # Raised when a connection cannot be opened, is refused TLS it requires,
  # or fails on I/O. The connection is closed.
  class ConnectionError < Error
  end

  # Raised when the server rejects the credentials, asks for an
  # unsupported method, or fails SCRAM server verification.
  class AuthenticationError < Error
  end

  # Raised for a malformed or unexpected message. The connection is closed.
  class ProtocolError < Error
  end

  # Raised when a column cannot be decoded into the requested type.
  class DecodeError < Error
  end

  # Raised when an argument cannot be encoded as its parameter's type.
  class EncodeError < Error
  end

  # Raised by `query_one` when the query returned no rows.
  class NoRowsError < Error
  end

  # An `ErrorResponse` from the server. The connection stays usable.
  class QueryError < Error
    # Every field of the response by its one-letter code (`'C'` is the
    # SQLSTATE, `'M'` the message, ...).
    getter fields : Hash(Char, String)

    def initialize(@fields : Hash(Char, String))
      super(QueryError.format(@fields))
    end

    # The SQLSTATE code, e.g. `"23505"` for a unique violation.
    def code : String
      @fields['C']? || ""
    end

    # `ERROR`, `FATAL` or `PANIC` (never localized).
    def severity : String
      @fields['V']? || @fields['S']? || "ERROR"
    end

    # The primary message.
    def detail_message : String
      @fields['M']? || ""
    end

    # The optional detail line.
    def detail : String?
      @fields['D']?
    end

    # The optional hint line.
    def hint : String?
      @fields['H']?
    end

    # The 1-based character position of the error in the query, if given.
    def position : Int32?
      @fields['P']?.try(&.to_i?)
    end

    # :nodoc:
    def self.format(fields : Hash(Char, String)) : String
      String.build do |s|
        s << (fields['V']? || fields['S']? || "ERROR") << ' ' << (fields['C']? || "?????") << ": " << fields['M']?
        fields['D']?.try { |d| s << "\nDETAIL: " << d }
        fields['H']?.try { |h| s << "\nHINT: " << h }
      end
    end
  end
end
