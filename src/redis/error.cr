module Redis
  # Base class of every error raised by this client.
  class Error < Exception
  end

  # Raised when a connection cannot be established, is lost, or is used
  # after `close`. In-flight commands on a multiplexed `Client` receive this
  # error when the connection drops.
  class ConnectionError < Error
  end

  # Raised on a malformed frame, an exceeded size or depth guard, an
  # unsolicited reply, or a typed command receiving an unexpected reply shape.
  class ProtocolError < Error
  end

  # An error reply (`-` or `!` frame) from the server. Raised by `call`
  # at the top level; stored as a value when nested inside an aggregate
  # reply (for example inside pipeline results).
  class CommandError < Error
    # The leading upper-case word of the message (`ERR`, `WRONGTYPE`,
    # `NOAUTH`, `NOPROTO`, `MOVED`, ...) or `""` when the message has none.
    getter code : String

    def initialize(message : String, cause : Exception? = nil)
      super(message, cause)
      @code = CommandError.parse_code(message)
    end

    # :nodoc:
    def self.parse_code(message : String) : String
      space = message.index(' ') || message.bytesize
      word = message.byte_slice(0, space)
      return "" if word.empty?
      word.each_byte do |b|
        next if 'A'.ord <= b <= 'Z'.ord || '0'.ord <= b <= '9'.ord || b == '_'.ord
        return ""
      end
      word
    end
  end
end
