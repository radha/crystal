require "benchmark"
s10 = "hello worl"
s100 = "the quick brown fox jumps over the lazy dog " * 2 + "0123456789ab"
s1k = "the quick brown fox jumps over the lazy dog " * 23 + "01234567"
esc1k = ("say \"hi\"\n and \\ #{"x"} tab\t" * 40)
mixed1k = ("héllo wörld, ça va? ") * 51
cjk1k = "日本語のテキスト" * 43
inv = String.new(Bytes.new(900) { |i| i % 3 == 1 ? 0xFF_u8 : 0x61_u8 })
sink = 0_i64
Benchmark.ips do |x|
  {% for name in %w(s10 s100 s1k esc1k mixed1k cjk1k inv) %}
    x.report({{name}} + " inspect") { sink &+= {{name.id}}.inspect.bytesize }
  {% end %}
  x.report("s1k dump") { sink &+= s1k.dump.bytesize }
  x.report("mixed1k dump") { sink &+= mixed1k.dump.bytesize }
end
puts sink
