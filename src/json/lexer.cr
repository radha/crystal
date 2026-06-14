require "string_pool"

abstract class JSON::Lexer
  def self.new(string : String) : self
    StringBased.new(string)
  end

  def self.new(io : IO) : self
    IOBased.new(io)
  end

  getter token : Token
  property skip : Bool

  @line_number : Int64
  @column_number : Int64

  def initialize
    @token = Token.new
    @line_number = 1
    @column_number = 1
    @buffer = IO::Memory.new
    @string_pool = StringPool.new
    @skip = false
    @expects_object_key = false
  end

  private abstract def consume_string
  private abstract def next_char_no_column_increment
  private abstract def current_char
  private abstract def number_start
  private abstract def append_number_char
  private abstract def number_string

  def next_token : JSON::Token
    skip_whitespace

    @token.line_number = @line_number
    @token.column_number = @column_number

    case current_char
    when '\0'
      @token.kind = :EOF
    when '{'
      next_char :begin_object
    when '}'
      next_char :end_object
    when '['
      next_char :begin_array
    when ']'
      next_char :end_array
    when ','
      next_char :comma
    when ':'
      next_char :colon
    when 'f'
      consume_false
    when 'n'
      consume_null
    when 't'
      consume_true
    when '"'
      @token.kind = :string
      @skip ? consume_string_skip : consume_string
    else
      consume_number
    end

    @token
  end

  # Requests the next token where the parser expects a json
  # object key. In this case the lexer tries to reuse the String
  # instances by using a StringPool.
  def next_token_expect_object_key
    @expects_object_key = true
    next_token
    @expects_object_key = false
    @token
  end

  private def skip_whitespace
    while whitespace?(current_char)
      if current_char == '\n'
        @line_number += 1
        @column_number = 0
      end
      next_char
    end
  end

  private def whitespace?(char)
    case char
    when ' ', '\t', '\n', '\r'
      true
    else
      false
    end
  end

  private def consume_true
    if next_char == 'r' && next_char == 'u' && next_char == 'e'
      next_char
      @token.kind = :true
    else
      unexpected_char
    end
  end

  private def consume_false
    if next_char == 'a' && next_char == 'l' && next_char == 's' && next_char == 'e'
      next_char
      @token.kind = :false
    else
      unexpected_char
    end
  end

  private def consume_null
    if next_char == 'u' && next_char == 'l' && next_char == 'l'
      next_char
      @token.kind = :null
    else
      unexpected_char
    end
  end

  # Since we are skipping we don't care about a
  # string's contents, so we just move forward.
  private def consume_string_skip
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

  private def consume_string_with_buffer
    consume_string_with_buffer { }
  end

  private def consume_string_with_buffer(&)
    @buffer.clear
    yield
    while true
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

  private def consume_string_escape_sequence
    case char = next_char
    when '\\', '"', '/'
      char
    when 'b'
      '\b'
    when 'f'
      '\f'
    when 'n'
      '\n'
    when 'r'
      '\r'
    when 't'
      '\t'
    when 'u'
      hexnum1 = read_hex_number
      if hexnum1 < 0xd800 || hexnum1 >= 0xe000
        hexnum1.unsafe_chr
      elsif hexnum1 < 0xdc00
        if next_char != '\\' || next_char != 'u'
          raise "Unterminated UTF-16 sequence"
        end
        hexnum2 = read_hex_number
        unless 0xdc00 <= hexnum2 <= 0xdfff
          raise "Invalid UTF-16 sequence"
        end
        ((hexnum1 << 10) &+ hexnum2 &- 0x35fdc00).unsafe_chr
      else
        raise "Invalid UTF-16 sequence"
      end
    else
      raise "Unknown escape char: #{char}"
    end
  end

  private def read_hex_number
    hexnum = 0
    4.times do
      char = next_char
      hexnum = (hexnum << 4) | (char.to_i?(16) || raise "Unexpected char in hex number: #{char.inspect}")
    end
    hexnum
  end

  private def consume_number
    number_start
    # Cleared here so a float, a big integer, or a reused token never reports a
    # stale cached value; set again only for an integer that fits in `Int64`.
    @token.parsed_int_value = nil

    negative = false
    if current_char == '-'
      negative = true
      append_number_char
      next_char
    end

    # Accumulate the integer magnitude while scanning so `Token#int_value` can
    # skip a second pass over `raw_value`. Wrapping arithmetic never raises on
    # overflow; the value is only used when `digits <= 18`, which always fits
    # in `Int64` (10**18 - 1 < Int64::MAX) and negates without overflow.
    magnitude = 0_i64
    digits = 0

    case current_char
    when '0'
      digits = 1
      append_number_char
      char = next_char
      case char
      when '.'
        consume_float
      when 'e', 'E'
        consume_exponent
      when '0'..'9'
        unexpected_char
      else
        @token.kind = :int
        number_end
        cache_int_value(negative, magnitude, digits)
      end
    when '1'..'9'
      magnitude = (current_char - '0').to_i64
      digits = 1
      append_number_char
      char = next_char
      while '0' <= char <= '9'
        magnitude = magnitude &* 10_i64 &+ (char - '0').to_i64
        digits &+= 1
        append_number_char
        char = next_char
      end

      case char
      when '.'
        consume_float
      when 'e', 'E'
        consume_exponent
      else
        @token.kind = :int
        number_end
        cache_int_value(negative, magnitude, digits)
      end
    else
      unexpected_char
    end
  end

  private def cache_int_value(negative, magnitude, digits)
    if digits <= 18
      @token.parsed_int_value = negative ? -magnitude : magnitude
    end
  end

  private def consume_float
    append_number_char
    char = next_char

    unless '0' <= char <= '9'
      unexpected_char
    end

    while '0' <= char <= '9'
      append_number_char
      char = next_char
    end

    if char.in?('e', 'E')
      consume_exponent
    else
      @token.kind = :float
      number_end
    end
  end

  private def consume_exponent
    append_number_char

    char = next_char
    if char == '+'
      append_number_char
      char = next_char
    elsif char == '-'
      append_number_char
      char = next_char
    end

    if '0' <= char <= '9'
      while '0' <= char <= '9'
        append_number_char
        char = next_char
      end
    else
      unexpected_char
    end

    @token.kind = :float

    number_end
  end

  private def next_char
    @column_number += 1
    next_char_no_column_increment
  end

  private def next_char(kind : Token::Kind)
    @token.kind = kind
    next_char
  end

  private def number_end
    @token.raw_value = number_string
  end

  private def unexpected_char(char = current_char)
    raise "Unexpected char '#{char}'"
  end

  private def raise(msg)
    ::raise ParseException.new(msg, @line_number, @column_number)
  end
end

require "./lexer/*"
