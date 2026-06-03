# A JSON builder generates valid JSON.
#
# A `JSON::Error` is raised if attempting to generate an invalid JSON
# (for example, if invoking `end_array` without a matching `start_array`,
# or trying to use a non-string value as an object's field name).
class JSON::Builder
  private getter io

  record StartState
  record DocumentStartState
  record ArrayState, empty : Bool
  record ObjectState, empty : Bool, name : Bool
  record DocumentEndState

  alias State = StartState | DocumentStartState | ArrayState | ObjectState | DocumentEndState

  @indent : String?

  # By default the maximum nesting of arrays/objects is 99. Nesting more
  # than this will result in a JSON::Error. Changing the value of this property
  # allows more/less nesting.
  property max_nesting = 99

  # Creates a `JSON::Builder` that will write to the given `IO`.
  def initialize(@io : IO)
    @state = [StartState.new] of State
    @current_indent = 0
    @escape = Escape.new(io)
  end

  # Starts a document.
  def start_document : Nil
    case @state.last
    when StartState
      @state[-1] = DocumentStartState.new
    when DocumentEndState
      @state[-1] = DocumentStartState.new
    else
      raise JSON::Error.new("Starting document before ending previous one")
    end
  end

  # Signals the end of a JSON document.
  def end_document : Nil
    case @state.last
    when StartState
      raise JSON::Error.new("Empty JSON")
    when DocumentStartState
      raise JSON::Error.new("Empty JSON")
    when ArrayState
      raise JSON::Error.new("Unterminated JSON array")
    when ObjectState
      raise JSON::Error.new("Unterminated JSON object")
    when DocumentEndState
      # okay
    end
    flush
  end

  def document(&)
    start_document
    yield.tap { end_document }
  end

  # Writes a `null` value.
  def null : Nil
    scalar do
      @io << "null"
    end
  end

  # Writes a boolean value.
  def bool(value : Bool) : Nil
    scalar do
      @io << value
    end
  end

  # Writes an integer.
  def number(number : Int) : Nil
    scalar do
      @io << number
    end
  end

  # Writes a float.
  def number(number : Float) : Nil
    scalar do
      case number
      when .nan?
        raise JSON::Error.new("NaN not allowed in JSON")
      when .infinite?
        raise JSON::Error.new("Infinity not allowed in JSON")
      else
        @io << number
      end
    end
  end

  # Writes a string with the content of `value`.
  # The payload is stringified via `to_s(IO)` and escaped for JSON representation.
  #
  # ```
  # JSON.build do |builder|
  #   builder.string("foo")
  # end # => %("foo")
  # JSON.build do |builder|
  #   builder.string([1, 2])
  # end # => %("[1, 2]")
  # ```
  #
  # This method can also be used to write the name of an object field.
  def string(value : _) : Nil
    string do |io|
      value.to_s(io)
    end
  end

  # Writes a string with the contents written to the yielded `IO`.
  # The payload gets escaped for JSON representation.
  #
  # ```
  # JSON.build do |builder|
  #   builder.string do |io|
  #     io << "foo"
  #     io << [1, 2]
  #   end # => %("foo[1, 2]")
  # end
  # ```
  #
  # This method can also be used to write the name of an object field.
  def string(& : IO ->) : Nil
    scalar(string: true) do
      io << '"'
      yield @escape
      io << '"'
    end
  end

  private class Escape < IO
    # Marker for bytes that must be emitted as a `\u00XX` escape.
    private UNICODE_ESCAPE = 'u'.ord.to_u8

    # 256-entry classification table indexed by byte value. `0` means the byte
    # can be copied through verbatim. For the seven short escapes the entry is
    # the suffix character (e.g. `'b'` for `\b`, `'"'` for `\"`); for the
    # remaining control bytes (`0x00`-`0x1f` and `0x7f`) it is `UNICODE_ESCAPE`,
    # meaning `\u00XX`. Replaces a per-byte chained `case` with one table lookup.
    private ESCAPE_TABLE = begin
      table = StaticArray(UInt8, 256).new(0_u8)
      table[0x08] = 'b'.ord.to_u8
      table[0x09] = 't'.ord.to_u8
      table[0x0a] = 'n'.ord.to_u8
      table[0x0c] = 'f'.ord.to_u8
      table[0x0d] = 'r'.ord.to_u8
      table[0x22] = '"'.ord.to_u8
      table[0x5c] = '\\'.ord.to_u8
      (0x00..0x1f).each { |i| table[i] = UNICODE_ESCAPE if table[i] == 0_u8 }
      table[0x7f] = UNICODE_ESCAPE
      table
    end

    def initialize(@io : IO)
    end

    delegate :flush, :tty?, :pos, :pos=, :seek, to: @io

    def read(slice : Bytes)
      raise ""
    end

    def write(slice : Bytes) : Nil
      table = ESCAPE_TABLE.to_unsafe
      cursor = start = slice.to_unsafe
      fin = cursor + slice.bytesize

      while cursor < fin
        byte = cursor.value
        code = table[byte]
        if code == 0_u8
          cursor += 1
          next
        end

        @io.write_string Slice.new(start, cursor - start)
        if code == UNICODE_ESCAPE
          @io << "\\u00"
          @io << '0' if byte < 0x10
          byte.to_s(@io, 16)
        else
          # Emit the two-byte `\x` escape in a single write rather than two
          # separate `IO#<<` (each of which would UTF-8-encode a Char).
          pair = uninitialized UInt8[2]
          pair.to_unsafe[0] = 0x5c_u8 # '\\'
          pair.to_unsafe[1] = code
          @io.write_string pair.to_slice
        end
        cursor += 1
        start = cursor
      end

      @io.write_string Slice.new(start, cursor - start)
    end
  end

  # Writes a raw value, considered a scalar, directly into
  # the IO without processing. This is the only method that
  # might lead to invalid JSON being generated, so you must
  # be sure that *string* contains a valid JSON string.
  def raw(string : String) : Nil
    scalar do
      @io << string
    end
  end

  # Writes the start of an array.
  def start_array : Nil
    start_scalar
    increase_indent
    @state.push ArrayState.new(empty: true)
    @io << '['
  end

  # Writes the end of an array.
  def end_array : Nil
    case state = @state.last
    when ArrayState
      @state.pop
    else
      raise JSON::Error.new("Can't do end_array: not inside an array")
    end
    write_indent state
    @io << ']'
    decrease_indent
    end_scalar
  end

  # Writes the start of an array, invokes the block,
  # and the writes the end of it.
  def array(&)
    start_array
    yield.tap { end_array }
  end

  # Writes the start of an object.
  def start_object : Nil
    start_scalar
    increase_indent
    @state.push ObjectState.new(empty: true, name: true)
    @io << '{'
  end

  # Writes the end of an object.
  def end_object : Nil
    case state = @state.last
    when ObjectState
      unless state.name
        raise JSON::Error.new("Missing object value")
      end
      @state.pop
    else
      raise JSON::Error.new("Can't do end_object: not inside an object")
    end
    write_indent state
    @io << '}'
    decrease_indent
    end_scalar
  end

  # Writes the start of an object, invokes the block,
  # and the writes the end of it.
  def object(&)
    start_object
    yield.tap { end_object }
  end

  # Writes a scalar value.
  def scalar(value : Nil)
    null
  end

  # :ditto:
  def scalar(value : Bool)
    bool(value)
  end

  # :ditto:
  def scalar(value : Int | Float) : Nil
    number(value)
  end

  # :ditto:
  def scalar(value : String) : Nil
    string(value)
  end

  # Writes an object's field and value.
  # The field's name is first converted to a `String` by invoking
  # `to_s` on it.
  def field(name : _, value : _) : Nil
    string(name)
    value.to_json(self)
  end

  # Writes an object's field and then invokes the block.
  # This is equivalent of invoking `string(value)` and then
  # invoking the block.
  def field(name, &)
    string(name)
    yield
  end

  # Flushes the underlying `IO`.
  def flush : Nil
    @io.flush
  end

  # Sets the indent *string*.
  def indent=(string : String) : String?
    if string.empty?
      @indent = nil
    else
      @indent = string
    end
  end

  # Sets the indent *level* (number of spaces).
  def indent=(level : Int) : String?
    if level < 0
      @indent = nil
    else
      @indent = " " * level
    end
  end

  # Returns `true` if the next thing that must pushed into this
  # builder is an object key (so a string) or the end of an object.
  def next_is_object_key? : Bool
    state = @state.last
    state.is_a?(ObjectState) && state.name
  end

  private def scalar(string = false, &)
    start_scalar(string)
    yield.tap { end_scalar(string) }
  end

  private def start_scalar(string = false)
    object_value = false
    case state = @state.last
    when DocumentStartState
      # okay
    when StartState
      raise JSON::Error.new("Write before start_document")
    when DocumentEndState
      raise JSON::Error.new("Write past end_document and before start_document")
    when ArrayState
      comma unless state.empty
    when ObjectState
      if state.name && !string
        raise JSON::Error.new("Expected string for object name")
      end
      comma if state.name && !state.empty
      object_value = !state.name
    end
    write_indent unless object_value
  end

  private def end_scalar(string = false)
    case state = @state.last
    when DocumentStartState
      @state[-1] = DocumentEndState.new
    when ArrayState
      @state[-1] = ArrayState.new(empty: false)
    when ObjectState
      colon if state.name
      @state[-1] = ObjectState.new(empty: false, name: !state.name)
    else
      raise "Bug: unexpected state: #{state.class}"
    end
  end

  private def comma
    @io << ','
  end

  private def colon
    @io << ':'
    @io << ' ' if @indent
  end

  private def newline
    @io << '\n'
  end

  private def write_indent
    indent = @indent
    return unless indent

    return if @current_indent == 0

    write_indent(indent, @current_indent)
  end

  private def write_indent(state : State)
    return if state.empty

    indent = @indent
    return unless indent

    write_indent(indent, @current_indent - 1)
  end

  private def write_indent(indent, times)
    newline
    times.times do
      @io << indent
    end
  end

  private def increase_indent
    @current_indent += 1
    if @current_indent > @max_nesting
      raise JSON::Error.new("Nesting of #{@current_indent} is too deep")
    end
  end

  private def decrease_indent
    @current_indent -= 1
  end
end

module JSON
  # Returns the resulting `String` of writing JSON to the yielded `JSON::Builder`.
  #
  # ```
  # require "json"
  #
  # string = JSON.build do |json|
  #   json.object do
  #     json.field "name", "foo"
  #     json.field "values" do
  #       json.array do
  #         json.number 1
  #         json.number 2
  #         json.number 3
  #       end
  #     end
  #   end
  # end
  # string # => %<{"name":"foo","values":[1,2,3]}>
  # ```
  #
  # Accepts an indent parameter which can either be an `Int` (number of spaces to indent)
  # or a `String`, which will prefix each level with the string a corresponding amount of times.
  def self.build(indent : String | Int | Nil = nil, &)
    String.build do |str|
      build(str, indent) do |json|
        yield json
      end
    end
  end

  # Writes JSON into the given `IO`. A `JSON::Builder` is yielded to the block.
  def self.build(io : IO, indent : String | Int | Nil = nil, &) : Nil
    builder = JSON::Builder.new(io)
    builder.indent = indent if indent
    builder.document do
      yield builder
    end
  end
end
