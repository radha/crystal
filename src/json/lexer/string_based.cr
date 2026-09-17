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

  # Skips a string token (its contents are not needed) using the same
  # word-at-a-time scan as `#consume_string`, but without materialising any
  # value. A non-ASCII byte or an escape (`\`) hands off to the exact
  # per-codepoint loop (`consume_string_skip_chars`); because the scan never
  # advances `@reader.pos`, both fall back by simply re-scanning from the
  # opening quote, keeping `@column_number`, the reader position and every
  # raise byte-identical to the base `#consume_string_skip`.
  private def consume_string_skip
    string = @reader.string
    ptr = string.to_unsafe
    bytesize = string.bytesize
    start_pos = current_pos
    word_limit = bytesize &- 8

    pos = start_pos + 1
    while pos < bytesize
      if pos <= word_limit
        word = (ptr + pos).as(UInt64*).value
        if string_scan_word(word) == 0
          return consume_string_skip_chars(start_pos) if word & 0x8080808080808080_u64 != 0
          pos &+= 8
          next
        end
      end
      byte = ptr[pos]
      return consume_string_skip_chars(start_pos) if byte >= 0x80
      break if byte < 0x20 || byte == 0x22 || byte == 0x5c
      pos &+= 1
    end

    if pos == bytesize
      @column_number += pos - start_pos
      @reader.pos = pos
      raise "Unterminated string"
    end

    case ptr[pos]
    when 0x22 # '"'
      @column_number += pos - start_pos + 1
      @reader.pos = pos + 1
      if pos + 1 != bytesize && ptr[pos + 1] == 0
        unexpected_char
      end
    when 0x5c # '\\'
      consume_string_skip_chars(start_pos)
    else # control byte (< 0x20)
      @column_number += pos - start_pos
      @reader.pos = pos
      unexpected_char
    end
  end

  # The original, exact per-codepoint skip loop (identical to the base
  # `#consume_string_skip`). Used unchanged whenever the string contains a
  # non-ASCII byte or an escape, so column counting and every raise stay
  # byte-identical. The reader is positioned at the opening quote on entry.
  private def consume_string_skip_chars(start_pos)
    while true
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

  # The number's substring is only built if `Token#raw_value` is read;
  # `Token#int_value` and `#float_value` usually never need it.
  private def number_end
    @token.set_raw_range(@reader.string, @number_start, current_pos)
  end
end
