require "digest/sha256"
require "json"

r = Random.new(ARGV[0]?.try(&.to_i) || 5)
pieces = ["a", " ", "\\n", "\\t", "\\\"", "\\\\", "\\/", "\\u00e9", "\\ud83d\\udc8e", "é", "日本", "💎", "#", "'", "0", "z"]
raw_bytes = [Bytes[0xFF], Bytes[0xC3], Bytes[0x80], Bytes[0x00], Bytes[0x01], Bytes[0x1F], Bytes[0x7F], Bytes[0x22], Bytes[0x5C], Bytes[0xED, 0xA0, 0x80]]

def gen_string(r, pieces)
  n = r.rand(0..40)
  n = r.rand(0..300) if r.rand(20) == 0
  String.build { |io| n.times { io << (r.rand(10) < 8 ? (0x20 + r.rand(0x5F)).chr : pieces[r.rand(pieces.size)]) } }
end

def gen_number(r)
  case r.rand(8)
  when 0 then r.rand(-1000..1000).to_s
  when 1 then "-0"
  when 2 then r.rand(Int64::MIN..Int64::MAX).to_s
  when 3 then "#{r.rand(1..9)}" + "#{r.rand(0..9)}" * r.rand(15..25)
  when 4 then "#{r.rand(-100..100)}.#{r.rand(0..999999)}"
  when 5 then "#{r.rand(-100..100)}.#{r.rand(0..99)}e#{r.rand(-320..320)}"
  when 6 then "#{r.rand(0..9)}E+#{r.rand(0..30)}"
  else        "0.#{r.rand(0..9)}"
  end
end

def gen_value(r, pieces, depth) : String
  case r.rand(depth > 3 ? 4 : 7)
  when 0 then %("#{gen_string(r, pieces)}")
  when 1 then gen_number(r)
  when 2 then ["true", "false", "null"][r.rand(3)]
  when 3 then gen_number(r)
  when 4 then "[" + Array.new(r.rand(0..5)) { gen_value(r, pieces, depth + 1) }.join(r.rand(3) == 0 ? " , " : ",") + "]"
  else        "{" + Array.new(r.rand(0..5)) { %("#{gen_string(r, pieces)}"#{r.rand(3) == 0 ? " : " : ":"}#{gen_value(r, pieces, depth + 1)}) }.join(",\n") + "}"
  end
end

def lex(digest, &)
  lexer = yield
  loop do
    tok = lexer.next_token
    digest << tok.kind.to_s << tok.line_number.to_s << ":" << tok.column_number.to_s << "|"
    case tok.kind
    when .string? then digest << tok.string_value
    when .int?, .float?
      digest << tok.raw_value
      digest << (tok.int_value.to_s rescue "E") if tok.kind.int?
      digest << (tok.float_value.to_s rescue "E")
    end
    digest << "\n"
    break if tok.kind.eof?
  end
rescue ex : JSON::ParseException
  digest << "EXC " << ex.message.to_s << " " << ex.line_number.to_s << ":" << ex.column_number.to_s << "\n"
rescue ex
  digest << "OTHER " << ex.class.name << " " << ex.message.to_s << "\n"
end

def run_all(digest, doc : Bytes)
  s = String.new(doc)
  lex(digest) { JSON::Lexer.new(s) }
  lex(digest) { JSON::Lexer.new(IO::Memory.new(doc)) }
  # with skip mode toggled on every third token
  {s, IO::Memory.new(doc)}.each do |src|
    i = 0
    begin
      lexer = src.is_a?(String) ? JSON::Lexer.new(src) : JSON::Lexer.new(src)
      loop do
        lexer.skip = (i % 3 == 0)
        tok = lexer.next_token
        digest << tok.kind.to_s << tok.column_number.to_s
        i += 1
        break if tok.kind.eof?
      end
    rescue ex : JSON::ParseException
      digest << "EXC " << ex.message.to_s << " " << ex.line_number.to_s << ":" << ex.column_number.to_s << "\n"
    rescue ex
      digest << "OTHER " << ex.class.name << " " << ex.message.to_s << "\n"
    end
  end
  {s, IO::Memory.new(doc)}.each do |src|
    begin
      digest << JSON.parse(src).to_json
    rescue ex
      digest << "PEXC " << ex.class.name << ex.message.to_s
    end
    begin
      p = JSON::PullParser.new(src.is_a?(String) ? src : IO::Memory.new(doc))
      digest << p.read_raw
      digest << p.kind.to_s
    rescue ex
      digest << "RAWEXC " << ex.class.name << ex.message.to_s
    end
    begin
      p = JSON::PullParser.new(src.is_a?(String) ? src : IO::Memory.new(doc))
      p.skip
      digest << p.kind.to_s
    rescue ex
      digest << "SKIPEXC " << ex.class.name << ex.message.to_s
    end
  end
  begin
    digest << Array(Float64).from_json(s).to_s
  rescue ex
    digest << "F64EXC " << ex.message.to_s
  end
  begin
    digest << Array(Int128).from_json(s).to_s
  rescue ex
    digest << "I128EXC " << ex.message.to_s
  end
end

digest = Digest::SHA256.new
cases = 0
3000.times do
  doc = gen_value(r, pieces, 0).to_slice.dup
  run_all(digest, doc); cases += 1
  # corrupted variants: truncate, inject a raw byte, inject a NUL
  if doc.size > 2
    cut = r.rand(1...doc.size)
    run_all(digest, doc[0, cut].dup); cases += 1
    inj = raw_bytes[r.rand(raw_bytes.size)]
    pos = r.rand(0..doc.size)
    run_all(digest, doc[0, pos] + inj + doc[pos, doc.size - pos]); cases += 1
  end
end
# long strings that cross IO::Buffered chunk boundaries via a File-backed IO
tmp = File.tempfile("diffjson") do |f|
  f.print JSON.build { |j| j.array { 50.times { |i| j.string(("x" * 8190) + "é\"y\\n" + ("z" * (i * 37))) } } }
end
File.open(tmp.path) { |f| lex(digest) { JSON::Lexer.new(f) } }
File.open(tmp.path) { |f| f.set_encoding("UTF-8", invalid: :skip); lex(digest) { JSON::Lexer.new(f) } }
File.open(tmp.path) { |f| digest << JSON.parse(f).to_json }
tmp.delete
puts "#{cases} cases #{digest.hexfinal}"
