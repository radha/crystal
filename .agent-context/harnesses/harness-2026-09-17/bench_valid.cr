require "benchmark"
ascii16 = "The quick brown "
ascii64 = ascii16 * 4
ascii1k = ascii16 * 64
ascii64k = ascii16 * 4096
mixed1k = ("héllo wörld, ça va? ") * 51
cjk1k = "日本語のテキスト" * 43
late_multibyte = ascii16 * 63 + "é" + ascii16
invalid = ascii1k.to_slice.dup; invalid[invalid.size - 3] = 0xFF_u8
inv_str = String.new(invalid)
sink = 0_i64
Benchmark.ips do |x|
  {% for name in %w(ascii16 ascii64 ascii1k ascii64k mixed1k cjk1k late_multibyte inv_str) %}
    x.report({{name}}) { sink &+= {{name.id}}.valid_encoding? ? 1 : 0 }
  {% end %}
end
puts sink
