class JSON::Token
  enum Kind
    Null
    False
    True
    Int
    Float
    String
    BeginArray
    EndArray
    BeginObject
    EndObject
    Colon
    Comma
    EOF
  end

  property kind : Kind
  property string_value : String

  # Set by the lexer when the integer value was accumulated during lexing and
  # is known to fit in `Int64` (small enough that it cannot overflow). `nil`
  # means it was not pre-computed and `int_value` must parse `raw_value`.
  @parsed_int_value : Int64? = nil

  # :nodoc:
  def parsed_int_value=(@parsed_int_value : Int64?)
  end

  def int_value : Int64
    if value = @parsed_int_value
      return value
    end
    raw_value.to_i64
  rescue exc : ArgumentError
    raise ParseException.new(exc.message, line_number, column_number)
  end

  def float_value : Float64
    if source = @raw_source
      # Parse straight out of the source string; the lexer has already
      # validated the number's syntax, so this only fails if `String#to_f64`
      # would too, which then raises with its usual message.
      value = Float::FastFloat.to_f64?(source.to_unsafe + @raw_start, source.to_unsafe + @raw_end)
      return value if value
    end
    raw_value.to_f64
  rescue exc : ArgumentError
    raise ParseException.new(exc.message, line_number, column_number)
  end

  @line_number : Int64
  @column_number : Int64

  def line_number : Int32
    @line_number.to_i32
  end

  @[Experimental]
  def line_number_i64 : Int64
    @line_number
  end

  def line_number=(line_number)
    @line_number = line_number.to_i64
  end

  def column_number : Int32
    @column_number.to_i32
  end

  @[Experimental]
  def column_number_i64
    @column_number
  end

  def column_number=(column_number)
    @column_number = column_number.to_i64
  end

  @raw_value : String

  # Set by the string-based lexer instead of `raw_value=`: the number's bytes
  # are the range `@raw_start...@raw_end` of `@raw_source`, and the substring
  # is only built if `raw_value` is read.
  @raw_source : String?
  @raw_start : Int32
  @raw_end : Int32

  def raw_value : String
    if source = @raw_source
      @raw_value = source.byte_slice(@raw_start, @raw_end - @raw_start)
      @raw_source = nil
    end
    @raw_value
  end

  def raw_value=(@raw_value : String)
    @raw_source = nil
  end

  # :nodoc:
  def set_raw_range(@raw_source : String, @raw_start : Int32, @raw_end : Int32) : Nil
  end

  # :nodoc:
  #
  # The source string and byte range of the raw value while it has not been
  # built as a substring, or `nil` once it has (or was set directly).
  def raw_range : {String, Int32, Int32}?
    if source = @raw_source
      {source, @raw_start, @raw_end}
    end
  end

  def initialize
    @kind = :EOF
    @line_number = 0
    @column_number = 0
    @string_value = ""
    @raw_value = ""
    @raw_source = nil
    @raw_start = 0
    @raw_end = 0
  end

  def to_s(io : IO) : Nil
    case @kind
    when .null?
      io << "null"
    when .false?
      io << "false"
    when .true?
      io << "true"
    when .int?
      raw_value.to_s(io)
    when .float?
      raw_value.to_s(io)
    when .string?
      string_value.to_s(io)
    when .begin_array?
      io << '['
    when .end_array?
      io << ']'
    when .begin_object?
      io << '{'
    when .end_object?
      io << '}'
    when .colon?
      io << ':'
    when .comma?
      io << ','
    when .eof?
      io << "<EOF>"
    else
      raise "Unknown token kind: #{@kind}"
    end
  end
end
