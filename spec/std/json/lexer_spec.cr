require "spec"
require "json"

private def it_lexes(string, expected_kind : JSON::Token::Kind, expected_to_s = string, file = __FILE__, line = __LINE__)
  it "lexes #{string} from string", file, line do
    lexer = JSON::Lexer.new string
    token = lexer.next_token
    token.kind.should eq(expected_kind)
    token.to_s.should eq(expected_to_s)
  end

  it "lexes #{string} from IO", file, line do
    lexer = JSON::Lexer.new IO::Memory.new(string)
    token = lexer.next_token
    token.kind.should eq(expected_kind)
    token.to_s.should eq(expected_to_s)
  end
end

private def it_lexes_string(string, string_value, file = __FILE__, line = __LINE__)
  it "lexes #{string} from String", file, line do
    lexer = JSON::Lexer.new string
    token = lexer.next_token
    token.kind.should eq(JSON::Token::Kind::String)
    token.string_value.should eq(string_value)
    token.to_s.should eq(token.string_value)
  end

  it "lexes #{string} from IO", file, line do
    lexer = JSON::Lexer.new IO::Memory.new(string)
    token = lexer.next_token
    token.kind.should eq(JSON::Token::Kind::String)
    token.string_value.should eq(string_value)
    token.to_s.should eq(token.string_value)
  end
end

private def it_lexes_int(string, int_value, file = __FILE__, line = __LINE__)
  it "lexes #{string} from String", file, line do
    lexer = JSON::Lexer.new string
    token = lexer.next_token
    token.kind.should eq(JSON::Token::Kind::Int)
    token.int_value.should eq(int_value)
    token.raw_value.should eq(string)
    token.to_s.should eq(token.raw_value)
  end

  it "lexes #{string} from IO", file, line do
    lexer = JSON::Lexer.new IO::Memory.new(string)
    token = lexer.next_token
    token.kind.should eq(JSON::Token::Kind::Int)
    token.int_value.should eq(int_value)
    token.raw_value.should eq(string)
    token.to_s.should eq(token.raw_value)
  end
end

private def it_lexes_float(string, float_value, file = __FILE__, line = __LINE__)
  it "lexes #{string} from String", file, line do
    lexer = JSON::Lexer.new string
    token = lexer.next_token
    token.kind.should eq(JSON::Token::Kind::Float)
    token.float_value.should eq(float_value)
    token.raw_value.should eq(string)
    token.to_s.should eq(token.raw_value)
  end

  it "lexes #{string} from IO", file, line do
    lexer = JSON::Lexer.new IO::Memory.new(string)
    token = lexer.next_token
    token.kind.should eq(JSON::Token::Kind::Float)
    token.float_value.should eq(float_value)
    token.raw_value.should eq(string)
    token.to_s.should eq(token.raw_value)
  end
end

private def it_errors_to_lex(string, *, file = __FILE__, line = __LINE__)
  it "errors if lexing #{string} from String", file: file, line: line do
    expect_raises(Exception) { JSON::Lexer.new(string).next_token }
  end

  it "errors if lexing #{string} from IO", file: file, line: line do
    expect_raises(Exception) { JSON::Lexer.new(IO::Memory.new(string)).next_token }
  end
end

# Lexes *string* from an `IO::Memory`, a buffered `File` with a tiny buffer
# (so plain-ASCII runs cross buffer refills), and a `File` with a UTF-8
# decoder (which disables the IO-based lexer's peek fast path).
private def each_io_lexer(string, &)
  yield JSON::Lexer.new(IO::Memory.new(string)), "IO::Memory"
  File.tempfile("json_lexer_spec") do |file|
    file.print string
    file.flush
    File.open(file.path) do |io|
      io.buffer_size = 16
      yield JSON::Lexer.new(io), "File"
    end
    File.open(file.path) do |io|
      io.set_encoding("UTF-8", invalid: :skip)
      yield JSON::Lexer.new(io), "File with decoder"
    end
  end
end

describe JSON::Lexer do
  it_lexes "", :EOF, expected_to_s: "<EOF>"
  it_lexes "{", :begin_object
  it_lexes "}", :end_object
  it_lexes "[", :begin_array
  it_lexes "]", :end_array
  it_lexes ",", :comma
  it_lexes ":", :colon
  it_lexes " \n\t\r :", :colon, expected_to_s: ":"
  it_lexes "true", :true
  it_lexes "false", :false
  it_lexes "null", :null
  it_lexes_string "\"hello\"", "hello"
  it_lexes_string "\"hello\\\"world\"", "hello\"world"
  it_lexes_string "\"hello\\\\world\"", "hello\\world"
  it_lexes_string "\"hello\\/world\"", "hello/world"
  it_lexes_string "\"hello\\bworld\"", "hello\bworld"
  it_lexes_string "\"hello\\fworld\"", "hello\fworld"
  it_lexes_string "\"hello\\nworld\"", "hello\nworld"
  it_lexes_string "\"hello\\rworld\"", "hello\rworld"
  it_lexes_string "\"hello\\tworld\"", "hello\tworld"
  it_lexes_string "\"\\u201chello world\\u201d\"", "“hello world”"
  it_lexes_string "\"\\uD800\\uDC00\"", 0x10000.unsafe_chr.to_s
  it_lexes_string "\"\\uD840\\uDC00\"", 0x20000.unsafe_chr.to_s
  it_lexes_string "\"\\uDBFF\\uDFFF\"", 0x10ffff.unsafe_chr.to_s
  it_lexes_string "\"\\uD834\\uDD1E\"", "𝄞"
  it_errors_to_lex %("\\uD800")
  it_errors_to_lex %("\\uDC00")
  it_errors_to_lex %("\\uD800\\u0020")

  # SWAR string scan: content lengths straddling the 8-byte word boundary.
  it_lexes_string "\"\"", ""
  it_lexes_string "\"aaaaaaa\"", "aaaaaaa"
  it_lexes_string "\"aaaaaaaa\"", "aaaaaaaa"
  it_lexes_string "\"aaaaaaaaa\"", "aaaaaaaaa"
  it_lexes_string "\"aaaaaaaaaaaaaaa\"", "aaaaaaaaaaaaaaa"
  it_lexes_string "\"aaaaaaaaaaaaaaaa\"", "aaaaaaaaaaaaaaaa"
  it_lexes_string "\"aaaaaaaaaaaaaaaaa\"", "aaaaaaaaaaaaaaaaa"

  # UTF-8 content takes the exact per-codepoint fallback (incl. at boundaries).
  it_lexes_string "\"中文字符串\"", "中文字符串"
  it_lexes_string "\"aaaaaaaa中aaaaaaaa\"", "aaaaaaaa中aaaaaaaa"
  it_lexes_string "\"\u{1F600}\u{1F600}\u{1F600}\u{1F600}\"", "\u{1F600}\u{1F600}\u{1F600}\u{1F600}"
  it_lexes_string "\"aaaaaaa中\"", "aaaaaaa中"

  # A raw control byte inside a string is rejected (SWAR ctrl detection), at
  # the start, mid-word, and across the 8-byte word boundary.
  it_errors_to_lex "\"\u0001\""
  it_errors_to_lex "\"abc\u0001\""
  it_errors_to_lex "\"aaaaaaaa\u0001\""
  it_errors_to_lex "\"aaaaaaaaaaaaaaaa\u0001\""

  it "tracks column across a SWAR word-skipped string" do
    # '[' col1, '"' col2, 16 'a' cols 3..18, '"' col19, ',' col20.
    lexer = JSON::Lexer.new("[\"aaaaaaaaaaaaaaaa\",1]")
    lexer.next_token.kind.begin_array?.should be_true
    lexer.next_token.kind.string?.should be_true
    comma = lexer.next_token
    comma.kind.comma?.should be_true
    comma.column_number.should eq(20)
  end

  it "tracks column after a multibyte string (fallback path)" do
    # '"' col1, U+4E2D (1 codepoint) col2, '"' col3, ',' col4.
    lexer = JSON::Lexer.new("\"中\",1")
    lexer.next_token.kind.string?.should be_true
    comma = lexer.next_token
    comma.kind.comma?.should be_true
    comma.column_number.should eq(4)
  end

  describe "skip mode (consume_string_skip SWAR)" do
    it "tracks column across a SWAR word-skipped string" do
      lexer = JSON::Lexer.new("[\"aaaaaaaaaaaaaaaa\",1]")
      lexer.skip = true
      lexer.next_token.kind.begin_array?.should be_true
      lexer.next_token.kind.string?.should be_true
      comma = lexer.next_token
      comma.kind.comma?.should be_true
      comma.column_number.should eq(20)
    end

    it "tracks column after a multibyte skipped string (fallback path)" do
      lexer = JSON::Lexer.new("\"中\",1")
      lexer.skip = true
      lexer.next_token.kind.string?.should be_true
      comma = lexer.next_token
      comma.kind.comma?.should be_true
      comma.column_number.should eq(4)
    end

    it "skips a string containing an escape sequence" do
      lexer = JSON::Lexer.new("\"ab\\ncd\",1")
      lexer.skip = true
      lexer.next_token.kind.string?.should be_true
      lexer.next_token.kind.comma?.should be_true
    end

    it "rejects a control byte in a skipped string at every word offset" do
      ["\"\u0001\"", "\"abc\u0001\"", "\"aaaaaaaa\u0001\"", "\"aaaaaaaaaaaaaaaa\u0001\""].each do |doc|
        lexer = JSON::Lexer.new(doc)
        lexer.skip = true
        expect_raises(JSON::ParseException) { loop { break if lexer.next_token.kind.eof? } }
      end
    end

    it "rejects an embedded null after a skipped string's closing quote" do
      lexer = JSON::Lexer.new("\"aaaaaaaaaaaaaaaa\"\u0000x")
      lexer.skip = true
      expect_raises(JSON::ParseException) { loop { break if lexer.next_token.kind.eof? } }
    end

    it "raises on an unterminated skipped string" do
      lexer = JSON::Lexer.new("\"abcdefghijklmnop")
      lexer.skip = true
      expect_raises(JSON::ParseException, "Unterminated string") { loop { break if lexer.next_token.kind.eof? } }
    end
  end

  it_lexes_int "0", 0
  it_lexes_int "1", 1
  it_lexes_int "1234", 1234
  it_lexes_float "0.123", 0.123
  it_lexes_float "1234.567", 1234.567
  it_lexes_float "0e1", 0
  it_lexes_float "0E1", 0
  it_lexes_float "0.1e1", 0.1e1
  it_lexes_float "0e+12", 0
  it_lexes_float "0e-12", 0
  it_lexes_float "1e2", 1e2
  it_lexes_float "1E2", 1e2
  it_lexes_float "1e+12", 1e12
  it_lexes_float "1.2e-3", 1.2e-3
  it_lexes_float "9.91343313498688", 9.91343313498688
  it_lexes_int "-1", -1
  it_lexes_float "-1.23", -1.23
  it_lexes_float "-1.23e4", -1.23e4
  it_lexes_float "-1.23e4", -1.23e4
  it_lexes_float "1000000000000000000.0", 1000000000000000000.0
  it_lexes_float "6000000000000000000.0", 6000000000000000000.0
  it_lexes_float "9000000000000000000.0", 9000000000000000000.0
  it_lexes_float "9876543212345678987654321.0", 9876543212345678987654321.0
  it_lexes_float "9876543212345678987654321e20", 9876543212345678987654321e20
  it_lexes_float "10.100000000000000000000", 10.1

  # Integer value caching: <= 18 digits is accumulated during lexing, >= 19
  # digits falls back to parsing raw_value. The boundary and Int64 extremes
  # must all yield identical int_values.
  it_lexes_int "999999999999999999", 999999999999999999   # 18 digits (cached)
  it_lexes_int "-999999999999999999", -999999999999999999 # 18 digits (cached)
  it_lexes_int "1000000000000000000", 1000000000000000000 # 19 digits (fallback)
  it_lexes_int "9223372036854775807", Int64::MAX          # 19 digits (fallback)
  it_lexes_int "-9223372036854775808", Int64::MIN         # fallback
  it_lexes_int "100000000000000000", 100000000000000000   # 18 digits, leading 1

  it "raises on an integer that overflows Int64" do
    token = JSON::Lexer.new("99999999999999999999").next_token
    token.kind.int?.should be_true
    expect_raises(JSON::ParseException) { token.int_value }
  end

  describe "IO-based lexer plain-ASCII runs" do
    it "lexes runs that end at escapes, quotes, non-ASCII and control bytes" do
      value = "aaaaaaaa" * 3 + "\"q\" \\ " + "b" * 17 + "中" + "c" * 9 + "\n" + "d" * 8 + "\u{1F600}"
      json = "[" + value.to_json + ",1]"
      each_io_lexer(json) do |lexer, label|
        lexer.next_token.kind.begin_array?.should be_true
        token = lexer.next_token
        token.kind.string?.should(be_true, label)
        token.string_value.should eq(value), label
        comma = lexer.next_token
        comma.kind.comma?.should be_true
        # "[" + the quoted value's codepoints + the following comma
        comma.column_number.should eq(1 + value.to_json.size + 1), label
        lexer.next_token.kind.int?.should be_true
      end
    end

    it "skips strings with runs in skip mode" do
      value_json = ("x" * 40 + "\\n" + "y" * 10 + "é").to_json
      json = "[" + value_json + ",2]"
      each_io_lexer(json) do |lexer, label|
        lexer.next_token.kind.begin_array?.should be_true
        lexer.skip = true
        lexer.next_token.kind.string?.should(be_true, label)
        lexer.skip = false
        comma = lexer.next_token
        comma.kind.comma?.should be_true
        comma.column_number.should eq(1 + value_json.size + 1), label
        lexer.next_token.int_value.should eq(2)
      end
    end

    it "still rejects control bytes, invalid UTF-8 and unterminated strings after a run" do
      each_io_lexer("\"" + "a" * 20 + "\"") do |lexer, label|
        expect_raises(JSON::ParseException, "Unexpected char") { lexer.next_token }
      end
      each_io_lexer("\"" + "a" * 20) do |lexer, label|
        expect_raises(JSON::ParseException, "Unterminated string") { lexer.next_token }
      end
      lexer = JSON::Lexer.new(IO::Memory.new(("\"" + "a" * 20).to_slice + Bytes[0xFF, 0x22]))
      expect_raises(InvalidByteSequenceError) { lexer.next_token }
    end

    it "pools object keys lexed as runs" do
      lexer = JSON::Lexer.new(IO::Memory.new(%({"longer_than_eight_bytes":1,"longer_than_eight_bytes":2})))
      lexer.next_token
      first = lexer.next_token_expect_object_key.string_value
      3.times { lexer.next_token }
      second = lexer.next_token_expect_object_key.string_value
      first.should eq("longer_than_eight_bytes")
      first.should be(second)
    end
  end

end
