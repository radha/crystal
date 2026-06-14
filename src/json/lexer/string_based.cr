# :nodoc:
class JSON::Lexer::StringBased < JSON::Lexer
  def initialize(string)
    super()
    @reader = Char::Reader.new(string)
    @number_start = 0
  end

  # Consumes a string by remembering the start position of it and then
  # doing a substring of the original string.
  # If we find an escape sequence (\) we can't do that anymore so we
  # go through a slow path where we accumulate everything in a buffer
  # to build the resulting string.
  #
  # The scan for the closing quote runs a machine word at a time as long as
  # the content is plain ASCII. The slow `Char::Reader` loop only ever
  # branches on `"` (0x22), `\` (0x5C), the terminating `\0`, and control
  # bytes (`< 0x20`), so a word with none of those and no high bit is pure
  # content that can be skipped wholesale; with all bytes `< 0x80`, one byte
  # is one codepoint, so `@column_number` advances by the byte count. As soon
  # as a byte `>= 0x80` appears the exact per-codepoint loop takes over
  # (`consume_string_chars`), which keeps UTF-8 (including invalid sequences)
  # byte-identical to the original.
  private def consume_string
    string = @reader.string
    ptr = string.to_unsafe
    bytesize = string.bytesize
    start_pos = current_pos
    # Highest byte index at which a full 8-byte word still fits; wrapping
    # subtraction lets it go negative (disabling the word path) for short
    # tails, exactly like `String#size`.
    word_limit = bytesize &- 8

    pos = start_pos + 1
    while pos < bytesize
      if pos <= word_limit
        word = (ptr + pos).as(UInt64*).value
        if string_scan_word(word) == 0
          # No `"`, `\`, or control byte in this word. If it is also pure
          # ASCII, skip all 8 bytes; otherwise hand off to the char loop.
          return consume_string_chars(start_pos) if word & 0x8080808080808080_u64 != 0
          pos &+= 8
          next
        end
        # A marker byte is somewhere in this word; fall through and locate it
        # byte by byte (it is `< 0x80`, so it precedes any high byte).
      end
      byte = ptr[pos]
      return consume_string_chars(start_pos) if byte >= 0x80
      break if byte < 0x20 || byte == 0x22 || byte == 0x5c
      pos &+= 1
    end

    # Content `[start_pos + 1, pos)` is all ASCII, so codepoints == bytes and
    # each one is a single `next_char`/`@column_number` step in the slow loop.
    if pos == bytesize
      @column_number += pos - start_pos
      @reader.pos = pos
      raise "Unterminated string"
    end

    case ptr[pos]
    when 0x22 # '"'
      # `+ 1` consumes the closing quote (the extra `next_char` in the slow loop).
      @column_number += pos - start_pos + 1
      @reader.pos = pos + 1
      # That `next_char` runs through `next_char_no_column_increment`, which
      # rejects an embedded NUL right after the closing quote (only the
      # terminating NUL at `bytesize` is allowed through).
      if pos + 1 != bytesize && ptr[pos + 1] == 0
        unexpected_char
      end
      if @expects_object_key
        key_pos = start_pos + 1
        @token.string_value = @string_pool.get(ptr + key_pos, pos - key_pos)
      else
        @token.string_value = string_range(start_pos + 1, pos)
      end
    when 0x5c # '\\'
      @column_number += pos - start_pos
      @reader.pos = pos
      consume_string_slow_path start_pos
    else # control byte (< 0x20)
      @column_number += pos - start_pos
      @reader.pos = pos
      unexpected_char
    end
  end

  # The original, exact per-codepoint string scan. Used unchanged whenever the
  # string contains a non-ASCII byte, so UTF-8 decoding and column counting
  # remain byte-identical (including the resync over invalid UTF-8).
  private def consume_string_chars(start_pos)
    while true
      case next_char
      when '\0'
        raise "Unterminated string"
      when '\\'
        return consume_string_slow_path start_pos
      when '"'
        next_char
        break
      else
        if 0 <= current_char.ord < 32
          unexpected_char
        end
      end
    end

    if @expects_object_key
      start_pos += 1
      end_pos = current_pos - 1
      @token.string_value = @string_pool.get(@reader.string.to_unsafe + start_pos, end_pos - start_pos)
    else
      @token.string_value = string_range(start_pos + 1, current_pos - 1)
    end
  end

  # Returns a non-zero value when the word contains at least one byte that is
  # `"` (0x22), `\` (0x5C), or a control character (`< 0x20`). High bytes
  # (UTF-8 lead/continuation, `>= 0x80`) never match. False positives are
  # harmless — the caller re-checks the flagged word byte by byte — but there
  # are never false negatives, so no marker byte is ever skipped.
  private def string_scan_word(word : UInt64) : UInt64
    # A byte is `< 0x20` iff its top three bits are all clear, i.e. masking
    # with 0xE0 yields a zero byte; `haszero` detects that.
    ctrl = word & 0xe0e0e0e0e0e0e0e0_u64
    has_ctrl = (ctrl &- 0x0101010101010101_u64) & ~ctrl & 0x8080808080808080_u64
    quote = word ^ 0x2222222222222222_u64
    has_quote = (quote &- 0x0101010101010101_u64) & ~quote & 0x8080808080808080_u64
    backslash = word ^ 0x5c5c5c5c5c5c5c5c_u64
    has_backslash = (backslash &- 0x0101010101010101_u64) & ~backslash & 0x8080808080808080_u64
    has_ctrl | has_quote | has_backslash
  end

  private def consume_string_slow_path(start_pos)
    consume_string_with_buffer do
      @buffer.write slice_range(start_pos + 1, current_pos)
      @buffer << consume_string_escape_sequence
    end
  end

  private def current_pos
    @reader.pos
  end

  def string_range(start_pos : Int, end_pos : Int) : String
    @reader.string.byte_slice(start_pos, end_pos - start_pos)
  end

  def slice_range(start_pos : Int, end_pos : Int) : Bytes
    @reader.string.to_slice[start_pos, end_pos - start_pos]
  end

  private def next_char_no_column_increment
    char = @reader.next_char
    if char == '\0' && @reader.pos != @reader.string.bytesize
      unexpected_char
    end
    char
  end

  private def current_char
    @reader.current_char
  end

  private def number_start
    @number_start = current_pos
  end

  private def append_number_char
    # Nothing
  end

  private def number_string
    string_range(@number_start, current_pos)
  end
end
