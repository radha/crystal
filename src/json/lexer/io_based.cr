# :nodoc:
class JSON::Lexer::IOBased < JSON::Lexer
  def initialize(@io : IO)
    super()
    @current_char = @io.read_char || '\0'
  end

  private getter current_char

  private def next_char_no_column_increment
    @current_char = @io.read_char || '\0'
  end

  # Same as the base `#consume_string_with_buffer`, except that before each
  # character is read the plain-ASCII run at the front of the IO's read
  # buffer is copied and skipped wholesale (see `#consume_plain_ascii_run`).
  private def consume_string
    @buffer.clear
    while true
      consume_plain_ascii_run { |run| @buffer.write(run) }
      case char = next_char
      when '\0'
        raise "Unterminated string"
      when '\\'
        @buffer << consume_string_escape_sequence
      when '"'
        next_char
        break
      else
        if 0 <= current_char.ord < 32
          unexpected_char
        else
          @buffer << char
        end
      end
    end
    if @expects_object_key
      @token.string_value = @string_pool.get(@buffer)
    else
      @token.string_value = @buffer.to_s
    end
  end

  # Same as the base `#consume_string_skip`, with the plain-ASCII run at the
  # front of the IO's read buffer skipped wholesale before each character.
  private def consume_string_skip
    while true
      consume_plain_ascii_run { }
      case next_char
      when '\0'
        raise "Unterminated string"
      when '\\'
        consume_string_escape_sequence
      when '"'
        next_char
        break
      else
        if 0 <= current_char.ord < 32
          unexpected_char
        end
      end
    end
  end

  # Yields the run of plain ASCII bytes at the front of the IO's read buffer
  # and consumes it, when there is one. A plain byte is one the per-character
  # loops would only append: not `"`, `\`, a control byte (`< 0x20`), nor a
  # non-ASCII byte; the run is found a machine word at a time. Each such byte
  # is one codepoint, so `@column_number` advances by the byte count, and the
  # byte that ends the run is left in the IO for `#next_char` to read, so
  # escapes, terminators, invalid UTF-8 and every raise are handled exactly as
  # before. Requires the IO to read characters as raw UTF-8 (no decoder), so
  # that `IO#peek` shows the same bytes `IO#read_char` will decode.
  private def consume_plain_ascii_run(&)
    return unless @io.raw_utf8?
    return unless peek = @io.peek

    ptr = peek.to_unsafe
    size = peek.size
    n = 0
    while n + 8 <= size
      word = (ptr + n).as(UInt64*).value
      break if string_scan_word(word) != 0 || word & 0x8080808080808080_u64 != 0
      n &+= 8
    end
    while n < size
      byte = ptr[n]
      break if byte < 0x20 || byte == 0x22 || byte == 0x5c || byte >= 0x80
      n &+= 1
    end
    return if n == 0

    yield Slice.new(ptr, n)
    @io.skip(n)
    @column_number += n
  end

  private def number_start
    @buffer.clear
  end

  private def append_number_char
    @buffer << current_char
  end

  private def number_string
    @buffer.to_s
  end
end
