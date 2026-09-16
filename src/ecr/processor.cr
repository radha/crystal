require "./lexer"

module ECR
  extend self

  DefaultBufferName = "__str__"

  # `ECR.render` presizes its `String.build` to this multiple of the template's
  # literal text: the output is at least the literal text, so the buffer never
  # shrinks in `String::Builder#to_s`, and a template whose interpolations add
  # up to as much again as its literal text renders without a single realloc.
  private RENDER_CAPACITY_FACTOR = 2

  # :nodoc:
  #
  # With *render* the generated program is wrapped in a `String.build` block
  # over *buffer_name*, presized from the template's literal text (this is what
  # `ECR.render` embeds).
  def process_file(filename, buffer_name = DefaultBufferName, *, render = false) : String
    process_string File.read(filename), filename, buffer_name, render: render
  end

  # :nodoc:
  def process_string(string, filename, buffer_name = DefaultBufferName, *, render = false) : String
    lexer = Lexer.new string
    token = lexer.next_token
    literal_bytesize = 0

    program = String.build do |str|
      while true
        case token.type
        when .string?
          string = token.value
          token = lexer.next_token

          string = suppress_leading_indentation(token, string)
          literal_bytesize += string.bytesize

          str << buffer_name
          str << " << "
          string.inspect(str)
          str << '\n'
        when .output?
          string = token.value
          line_number = token.line_number
          column_number = token.column_number
          suppress_trailing = token.suppress_trailing?
          token = lexer.next_token

          suppress_trailing_whitespace(token, suppress_trailing)

          str << "#<loc:push>("
          append_loc(str, filename, line_number, column_number)
          str << string
          str << ")#<loc:pop>.to_s "
          str << buffer_name
          str << '\n'
        when .control?
          string = token.value
          line_number = token.line_number
          column_number = token.column_number
          suppress_trailing = token.suppress_trailing?
          token = lexer.next_token

          suppress_trailing_whitespace(token, suppress_trailing)

          str << "#<loc:push>"
          append_loc(str, filename, line_number, column_number)
          str << ' ' unless string.starts_with?(' ')
          str << string
          str << "#<loc:pop>"
          str << '\n'
        when .eof?
          break
        end
      end
    end

    return program unless render

    capacity = Math.max(64, literal_bytesize * RENDER_CAPACITY_FACTOR)
    "::String.build(#{capacity}) do |#{buffer_name}|\n#{program}end\n"
  end

  private def suppress_leading_indentation(token, string)
    # To suppress leading indentation we find the last index of a newline and
    # then check if all chars after that are whitespace.
    # We use a Char::Reader for this for maximum efficiency.
    if (token.type.output? || token.type.control?) && token.suppress_leading?
      char_index = string.rindex('\n')
      char_index = char_index ? char_index + 1 : 0
      byte_index = string.char_index_to_byte_index(char_index).not_nil!
      reader = Char::Reader.new(string)
      reader.pos = byte_index
      while reader.current_char.ascii_whitespace? && reader.has_next?
        reader.next_char
      end
      if reader.pos == string.bytesize
        string = string.byte_slice(0, byte_index)
      end
    end
    string
  end

  private def suppress_trailing_whitespace(token, suppress_trailing)
    if suppress_trailing && token.type.string?
      newline_index = token.value.index('\n')
      token.value = token.value[newline_index + 1..-1] if newline_index
    end
  end

  private def append_loc(str, filename, line_number, column_number)
    str << "#<loc:"
    filename.inspect(str)
    str << ','
    str << line_number
    str << ','
    str << column_number
    str << '>'
  end
end
